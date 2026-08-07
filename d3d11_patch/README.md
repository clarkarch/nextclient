# d3d11_patch — Windows zero-copy (D3D11) video path

The Windows counterpart of [`vaapi_patch/`](../vaapi_patch). The stock Windows
libwebrtc path decodes H.264 with FFmpeg and hands Flutter a CPU pixel buffer
(the renderer converts every frame to ARGB on the CPU and the engine uploads it
again — that full-screen convert + 4 B/px upload is what capped the stream at
28–33 UI fps while decode kept up at 59, see the issue #1 log).

This patch is split into two independent halves:

| Half | Lives in | Fixes | Needs a custom libwebrtc build? |
| --- | --- | --- | --- |
| GPU renderer | `packages/flutter_webrtc/windows/flutter_video_renderer_d3d.{h,cc}` | The 28–33 fps CPU-render bottleneck | **No** — works with the stock prebuilt `libwebrtc.dll` today |
| D3D11VA decoder | this directory (sources to apply to a libwebrtc wrapper) | Hardware decode + frames that never touch the CPU | **Yes** — build the wrapper for Windows and vendor the dll |

## The renderer half (works today, no rebuild)

`FlutterVideoRendererD3D` registers a `flutter::GpuSurfaceTexture`
(`kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`). The engine's ANGLE
compositor binds the plugin's D3D11 shared texture with
`EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE` and composites it directly — zero CPU
readback. Per frame the renderer uploads the Y/U/V planes (1.5 B/px instead of
the CPU path's 4 B/px convert + 4 B/px upload) and runs the YUV→RGB chroma
upsampling in an HLSL pixel shader on its own D3D11 device.

Activate it the same way as Linux: **Settings → Client → Renderer → GPU
(shader YUV→RGB)** (sets `OPENNOW_RENDERER=gl` before the texture is created;
anything else keeps the stock CPU path). With Verbose logs on, the renderer
logs `[d3drender] raster avg … ms/frame` once per second so the GPU half can
be blamed correctly instead of decode.

## The decoder half (for true zero-copy + the hardware-decode switch)

Decode is *not* the bottleneck (FFmpeg keeps up at 59 fps), but hardware
decode + GPU-resident frames removes the last CPU copy and gives Windows a
real hardware-decode switch. The contract is in place and the decoder is
implemented:

1. A custom libwebrtc build implements `RTCVideoFrame::NativeD3D11Handle()`
   (added to the ABI in `rtc_video_frame.h`), returning an
   `RtcD3D11TextureDescriptor` for frames decoded into a D3D11 NV12 texture.
2. `d3d11_video_decoder.cc` is now the real thing: a GStreamer
   `d3d11h264dec` (D3D11VA) pipeline that decodes each access unit, exports
   each decoded NV12 surface's texture to a legacy DXGI shared handle
   (`gst_d3d11_memory_get_resource_handle` + `IDXGIResource::GetSharedHandle`
   — note `gst_d3d11_memory_export` was removed in gst-plugins-bad 1.22's C++
   port and no longer exists) and wraps it in a `D3d11VideoBuffer` (kNative)
   that keeps the GStreamer buffer (and thus the texture) alive. Export only
   succeeds when the element allocates `D3D11_RESOURCE_MISC_SHARED` textures
   — stock `d3d11h264dec` does not, so on a stock runtime every frame takes
   the CPU NV12→I420 fallback (hardware decode still runs); a custom element
   with `MISC_SHARED` textures lights the zero-copy path up with no code
   change. Any failure (or `OPENNOW_DECODER=software`) delegates to the
   builtin FFmpeg decoder — the same structure as vaapi_patch.
3. The Windows renderer (compiled with `LIBWEBRTC_D3D11_CUSTOM`, defined by
   CMake when the `D3D11_CUSTOM.txt` marker sits next to the dll) opens the
   decoder's shared handle with `ID3D11Device::OpenSharedResource` and
   composites the NV12 planes through the shader — decode → composite with no
   CPU copy at all.

**Activation:** the decoder only runs in a *custom-built* libwebrtc that (a)
is built for Windows from this patch and (b) links a GStreamer runtime with
`d3d11h264dec` (gst-plugins-bad) that must ship with the app. Until then the
stock prebuilt dll keeps using the FFmpeg software decoder — that's the
fallback by design. **Zero-copy caveat:** the shared-handle export requires
the decoder element to allocate `D3D11_RESOURCE_MISC_SHARED` textures. Stock
`d3d11h264dec` does not (its pool uses `GST_D3D11_ALLOCATION_FLAG_TEXTURE_ARRAY`),
so with it the export fails and frames take the CPU NV12→I420 fallback — the
decoder still delivers D3D11VA hardware decode; only the final CPU copy
remains until an element with `MISC_SHARED` textures exists.

### Applying the patch to a libwebrtc wrapper checkout

```bash
./d3d11_patch/apply_patch.sh native/libwebrtc_build/src/libwebrtc \
                            packages/flutter_webrtc/third_party/libwebrtc
```

This copies the ABI header + `D3d11VideoBuffer` + the decoder factory hook into
the wrapper, patches `BUILD.gn` and `rtc_peerconnection_factory_impl.cc`, and
creates the `D3D11_CUSTOM.txt` marker. Then build for Windows (see
`vaapi_patch/README.md` for the wrapper build steps — same flow, `gn gen` +
`ninja` with a Windows toolchain) and vendor the artifacts:

```bash
cp out/win/libwebrtc.dll     packages/flutter_webrtc/third_party/libwebrtc/lib/
cp out/win/libwebrtc.dll.lib packages/flutter_webrtc/third_party/libwebrtc/lib/
rm -f packages/flutter_webrtc/third_party/downloads/libwebrtc-win-*.zip
```

CMake then skips the stock download and defines `LIBWEBRTC_D3D11_CUSTOM`.

### What the shipped decoder file is

`d3d11_video_decoder.cc` implements the GStreamer `d3d11h264dec` (D3D11VA)
decoder the `nvst_bridge` also uses on Windows (gst-plugins-bad,
`GST_CAPS_FEATURE_MEMORY_D3D11_MEMORY` buffers): it exports each decoded
surface's shared handle (`gst_d3d11_memory_get_resource_handle` +
`IDXGIResource::GetSharedHandle`; `gst_d3d11_memory_export` was removed in
the 1.22 C++ port) into a `libwebrtc::D3d11VideoBuffer` (kNative, holds a
GstBuffer ref so the texture outlives the frame), honors
`OPENNOW_DECODER=software` for A/B tests, and falls back to the builtin
FFmpeg decoder on any failure — exactly the vaapi_patch structure. Frames
that are not wrapped (CPU NV12→I420 fallback — always, with stock
`d3d11h264dec`, whose textures are not `MISC_SHARED`) stay on the I420
plane-upload path, so a partial implementation is safe. The H.264
AVCC→Annex-B + SPS/PPS re-injection converter lives in `h264_bitstream.h` (a
copy of vaapi_patch's, dependency-free; mirrored test in `test/`).

### Env-var switch

* `OPENNOW_RENDERER=gl` — GPU renderer (set from the Settings UI).
* `OPENNOW_DECODER=software` — force the FFmpeg fallback (A/B test the
  hardware decoder); anything else (or unset) prefers D3D11VA.
