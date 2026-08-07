# Native builds — custom libwebrtc wrapper

The stream uses a **custom-built libwebrtc** that adds GStreamer VAAPI hardware
decoding plus a zero-copy dmabuf render path. It is *not* the stock
flutter_webrtc binary: a local fork of `webrtc-sdk/libwebrtc` is patched,
compiled with `ninja`, and the resulting `libwebrtc.so` is vendored into the
flutter_webrtc plugin checkout.

This README covers the **daily rebuild workflow** (change a `.cc` → get it into
the app). For the full one-time checkout/build-from-scratch steps see
[`../vaapi_patch/README.md`](../vaapi_patch/README.md).

## Directory layout

```
native/
  libwebrtc-vaapi/          # webrtc-sdk/libwebrtc wrapper fork (source of truth)
    build/libwebrtc_linux_build.sh   # upstream build script (downloads + builds)
  libwebrtc_build/          # the actual WebRTC src checkout + build dirs
    src/
      libwebrtc/            # wrapper checkout that gets PATCHED
        src/vaapi_video_decoder.cc    # ← the file you edit
        src/dmabuf_video_buffer.cc
        include/rtc_video_frame.h
      out-debug/Linux-x64/  # is_debug=true   build (NOT what the app ships)
      out-release/Linux-x64/# is_debug=false build ← THE ONE THAT MATTERS
  depot_tools/              # gclient (Chromium tooling)
  gst_bridge/ nvst_bridge/  # FFI bridges (separate Makefile builds)
vaapi_patch/                # patch sources: apply_patch.sh copies them into the wrapper (Linux)
d3d11_patch/                # Windows counterpart: D3D11 zero-copy ABI + decoder factory hook
d3d11_patch/rtc_video_frame.h  # adds NativeD3D11Handle() to the RTCVideoFrame ABI
packages/flutter_webrtc/third_party/libwebrtc/lib/libwebrtc.so   # vendored .so the plugin links
```

**Windows note:** the Windows plugin links a **stock** prebuilt
`libwebrtc.dll` (downloaded by `third_party/CMakeLists.txt`) — no custom build
is required for the GPU renderer (D3D11 shared-handle presentation,
`OPENNOW_RENDERER=gl`, lands in `flutter_video_renderer_d3d.cc`). A custom
D3D11 build (hardware decode + frames that never touch the CPU) is optional:
apply `d3d11_patch/apply_patch.sh` to a Windows wrapper checkout, vendor the
dll into `third_party/libwebrtc/lib/` alongside a `D3D11_CUSTOM.txt` marker
(CMake then skips the download and defines `LIBWEBRTC_D3D11_CUSTOM`). See
[`../d3d11_patch/README.md`](../d3d11_patch/README.md).

The flow is: edit `vaapi_patch/*.cc` → `apply_patch.sh` copies it into
`native/libwebrtc_build/src/libwebrtc/src/` → `ninja` recompiles → copy the new
`.so` into the plugin → rebuild the Flutter app.

## Daily rebuild (incremental — the common case)

You changed `vaapi_patch/vaapi_video_decoder.cc` (or any wrapper source). Ninja
builds are incremental: only the edited file recompiles, then the `.so`
relinks. **Use the release build dir — `out-release`, not `out-debug`.** The app
ships the release `.so`; rebuilding debug does nothing for a release app.

```bash
# 1. Stage the patch into the wrapper checkout (idempotent; safe to re-run)
bash vaapi_patch/apply_patch.sh

# 2. Incremental build (only changed sources + relink; minutes, not hours)
ninja -C native/libwebrtc_build/src/out-release/Linux-x64 libwebrtc
#   [1/2] CXX obj/libwebrtc/libwebrtc/vaapi_video_decoder.o
#   [2/2] SOLINK ./libwebrtc.so

# 3. Swap the .so into the plugin. The plugin's CMakeLists.txt has a guard:
#    a vendored libwebrtc.so is used as-is and NEVER re-downloaded, so you
#    must copy it yourself.
cp native/libwebrtc_build/src/out-release/Linux-x64/libwebrtc.so \
   packages/flutter_webrtc/third_party/libwebrtc/lib/libwebrtc.so

# 4. Rebuild the app
flutter pub get          # NOTE: usually preserves the vendored .so — verify below
flutter build linux --release
```

**Always verify the build actually contains your change** — a stale `.so` is the
#1 cause of "I fixed it but nothing changed":

```bash
# Your change's string must appear in the vendored .so:
grep -c 'memory:VAMemory' packages/flutter_webrtc/third_party/libwebrtc/lib/libwebrtc.so
#  → 3 (or whatever your string's count is); 0 = stale binary

# And in the final app bundle:
grep -c 'memory:VAMemory' build/linux/x64/release/bundle/lib/libwebrtc.so
```

## Why out-release and not out-debug

Two build dirs exist with different GN args:

| dir | args.gn | used by |
|---|---|---|
| `out-debug/Linux-x64` | `is_debug=true` | old workflow, NOT shipped |
| `out-release/Linux-x64` | `is_debug=false symbol_level=0 use_custom_libcxx=true` | **the app ships this** |

Debugging: if a change doesn't show up in the app, check which dir you built,
and confirm the vendored `.so` mtime is newer than the app bundle's.

## Zero-copy decoder background (why the .so matters)

The wrapper's decoder (`vaapi_video_decoder.cc`) builds
`appsrc → h264parse → vah264dec → appsink`. The caps filter requests
`memory:VAMemory` when the element offers it, so appsink receives VA
surface-backed NV12. `TryExportDmaBuf()` then exports prime fds wrapped in a
`DmaBufVideoBuffer` (kNative), and the GL renderer imports them as EGLImages —
zero CPU copies. Without the VAMemory request the pipeline negotiates plain
system-memory NV12 and every frame falls back to the CPU
NV12→I420+readback path (the log line `[glrender] compositing via YUV plane
upload (CPU readback)`), which caps decode at ~20-45 fps and tanks UI fps.

Session log tells you which path ran (first frame only):

```
[glrender] compositing via zero-copy dmabuf EGL import   ← good
[glrender] compositing via YUV plane upload (CPU readback) ← CPU fallback
```

If you see the CPU line AND one of the renderer's EGL-import failure messages
(`no EGL display for dmabuf import`, `no EGL_EXT_image_dma_buf_import`,
`Y EGLImage import failed`), the decoder exported the dmabuf but the engine
compositor can't import it (GLX vs EGL) — the fight moves to the renderer, not
the decoder.

## Full rebuild from scratch

Only needed after a checkout change or a fresh machine — see
[`vaapi_patch/README.md`](../vaapi_patch/README.md) for the complete steps
(gclient sync of `m144_release`, `gn gen`, `ninja -j2 libwebrtc`, OOM notes).
The short version:

```bash
cd native/libwebrtc_build/src
gn gen out-release/Linux-x64 \
  --args='target_os="linux" target_cpu="x64" is_debug=false rtc_include_tests=false rtc_use_h264=true ffmpeg_branding="Chrome" is_component_build=false use_rtti=true use_custom_libcxx=true rtc_enable_protobuf=false use_sysroot=false symbol_level=0'
ninja -C out-release/Linux-x64 -j2 libwebrtc    # 1-3 h on 2 cores; OOM → -j1 + swap
```

## Gotchas

- **`flutter pub get` can re-extract the plugin** (path dependency) and reset
  the vendored `.so`. Always re-verify with `grep` after `pub get`.
- **Never let the plugin download its own libwebrtc** — the CMakeLists guard
  only kicks in when a vendored `.so` exists at
  `packages/flutter_webrtc/third_party/libwebrtc/lib/libwebrtc.so`.
- **7 GB RAM is tight** for the giant `.so` link — add swap before a full
  build (`fallocate -l 8G /swapfile && mkswap && swapon`).
- **`OPENNOW_DECODER=software`** forces the FFmpeg fallback at runtime
  (A/B testing without a rebuild); the stats overlay's Decoder row shows
  `GStreamerVaapiH264` (VAAPI live) vs `FFmpegVideoDecoder` (software).
- **Editing `.cc` files does NOT require the full Flutter toolchain** — a
  standalone compile check against just GStreamer headers can validate
  GStreamer API usage before committing to the (slow) ninja build.
