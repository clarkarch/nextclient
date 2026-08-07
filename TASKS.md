# Tasks / Backlog

> Self-contained tasks, ordered roughly by impact. Not all are low-priority —
> each entry carries its own priority tag. Can be picked up independently.

## Windows/macOS hardware video decode — MEDIUM

**Goal:** Get GPU-accelerated H.264 decode and zero-copy presentation on
Windows and macOS. Only Linux has the full hardware path today (VAAPI decode +
zero-copy dmabuf render).

**Status (Windows):**
- ✅ **Renderer half landed** (`flutter_video_renderer_d3d.{h,cc}`): the
  libwebrtc path can now present with a GPU shader — Y/U/V planes uploaded as
  D3D11 textures (1.5 B/px), YUV→RGB in an HLSL pixel shader, composited by
  the engine via a DXGI shared-handle `GpuSurfaceTexture`
  (`EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE`) with no CPU readback. This fixes
  the 28–33 UI fps CPU-render bottleneck (issue #1 log) using the **stock**
  prebuilt libwebrtc — no custom build needed. Enabled via Settings → Client
  → Renderer → GPU (shader YUV→RGB) (`OPENNOW_RENDERER=gl`).
- ✅ **Decoder half implemented** (`d3d11_patch/`): the zero-copy ABI hook
  (`RTCVideoFrame::NativeD3D11Handle` + `D3d11VideoBuffer`), the decoder
  factory wiring, the CMake vendoring marker (`D3D11_CUSTOM.txt` →
  `LIBWEBRTC_D3D11_CUSTOM`) and the real D3D11VA decoder (GStreamer
  `d3d11h264dec`, `OPENNOW_DECODER=software` A/B switch, FFmpeg fallback) are
  in place. **Activation still requires** a Windows custom libwebrtc build
  that links a GStreamer runtime with the d3d11 plugin (bundled with the
  app); until then the stock prebuilt dll uses FFmpeg, which is the fallback
  by design. Zero-copy caveat: the shared-handle export needs the decoder
  element to allocate `MISC_SHARED` textures; stock `d3d11h264dec` doesn't,
  so the decoder exports via `gst_d3d11_memory_get_resource_handle` +
  `IDXGIResource::GetSharedHandle` and CPU-falls-back (hardware decode still
  runs) until a shared-texture element exists. Decode is not the bottleneck
  (FFmpeg keeps up at 59 fps), so this is an optimization, not a blocker.

**Remaining:** macOS Metal renderer (analogous `flutter_video_renderer_metal`,
`CVPixelBuffer`/Metal texture via the engine's macOS texture path) + macOS
hardware decoder (VideoToolbox).

**Verify (Windows):** Decoder stats overlay should read a hardware decoder
name (e.g. `D3D11H264`) instead of `FFmpegVideoDecoder` once the decoder lands,
and the `[d3drender] compositing via zero-copy D3D11 texture` log line means
frames never touch the CPU. With the stock build, `[d3drender] compositing via
YUV plane upload + GPU shader` + UI fps at display rate is the win.

## Native custom-bitmap OS cursor (GTK plugin) — LOW

**Goal:** Get the window manager to render GFN **custom** cursor bitmaps (not
just the predefined styles) as the real OS cursor, so compositor effects like
speed-stretch apply to them too.

**Status:** Predefined cursor styles are already mapped to native OS cursors via
`UserSettings.inputCursorNative` (Debug → Native cursor). The remaining gap is
**custom bitmap cursors** (`image/png`, ids like 232/233), which Flutter cannot
set as the OS cursor — `MouseRegion.cursor` only supports named system cursors,
no arbitrary image API.

**Problem this solves:** The client-drawn overlay never goes through the
compositor, so WM cursor effects don't apply to custom bitmaps. OpenNOW gets
them because the browser hands the cursor bitmap to the OS
(`video.style.cursor` with a data-URL).

**Approach (sketch):**
- Add a small desktop platform plugin (mirror `packages/pointer_lock`
  structure) exposing e.g. `setCursorPng(bytes, hotspotX, hotspotY)` and
  `clearCursor()`.
- Linux/GTK impl: decode RGBA → `GdkPixbuf` → `gdk_cursor_new_from_pixbuf`
  (with hotspot) → `gdk_window_set_cursor`; on SVG/other mime, fall back to a
  decoded `ui.Image` (overlay). Update the cursor whenever the server streams a
  new bitmap id.
- Windows: `SetCursor` with a `CreateIconIndirect` from the hotspot + scale.
  macOS: `NSCursor` from an `NSImage`.
- Cache per `cursorId` (the session already does this: `_cursorImageCache`).

**Constraints:**
- Only meaningful when the pointer is NOT hard-locked (during a grab the OS
  cursor is hidden/captured, so WM effects can't draw). Scope the native path
  to unlocked hover.
- Respect `inputCursorOverlay` (whole overlay off) and `inputCursorNative`.
- Async PNG decode must not block the UI thread.

**Verify:** With a WM that has cursor effects (e.g. a speed-stretch compositor),
hover a game that streams a custom cursor and confirm it stretches like the
predefined styles now do. Add a widget/`flutter_webrtc`-level test once the
platform glue is stubbed.