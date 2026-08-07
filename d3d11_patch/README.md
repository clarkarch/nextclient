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

## The decoder half (optional, for true zero-copy)

Decode is *not* the bottleneck (FFmpeg keeps up at 59 fps), but hardware
decode + GPU-resident frames removes the last CPU copy. The contract is ready:

1. A custom libwebrtc build implements `RTCVideoFrame::NativeD3D11Handle()`
   (added to the ABI in `rtc_video_frame.h`), returning an
   `RtcD3D11TextureDescriptor` for frames decoded into a D3D11 NV12 texture.
2. The Windows renderer (compiled with `LIBWEBRTC_D3D11_CUSTOM`, defined by
   CMake when the `D3D11_CUSTOM.txt` marker sits next to the dll) opens the
   decoder's shared handle with `ID3D11Device::OpenSharedResource` and
   composites the NV12 planes through the shader — decode → composite with no
   CPU copy at all.

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

`d3d11_video_decoder.cc` is a **delegating stub** (returns the builtin FFmpeg
factory) so the patched build compiles and runs end-to-end before the real
decoder lands. The recommended implementation is the same GStreamer
`d3d11h264dec` element the app's native `nvst_bridge` already uses on Windows
(gst-plugins-bad, `GST_CAPS_FEATURE_MEMORY_D3D11_MEMORY` buffers): export each
decoded surface's `ID3D11Texture2D` as a legacy shared handle
(`IDXGIResource::GetSharedHandle`, texture created with
`D3D11_RESOURCE_MISC_SHARED`) into a `libwebrtc::D3d11VideoBuffer` (kNative),
honor `OPENNOW_DECODER=software` for A/B tests, and fall back to the builtin
decoder on any failure — exactly the vaapi_patch structure. Frames that are
not wrapped stay on the I420 plane-upload path, so a partial implementation is
safe.

### Env-var switch

* `OPENNOW_RENDERER=gl` — GPU renderer (set from the Settings UI).
* `OPENNOW_DECODER=software` — force the FFmpeg fallback (A/B test the
  hardware decoder); anything else (or unset) prefers D3D11VA.
