# Tasks / Backlog

> Self-contained tasks, ordered roughly by impact. Not all are low-priority —
> each entry carries its own priority tag. Can be picked up independently.

## Windows/macOS hardware video decode — MEDIUM

**Goal:** Get GPU-accelerated H.264 decode on Windows and macOS. Today the
libwebrtc path on those platforms decodes with CPU (FFmpeg software) and uses
the CPU renderer — only Linux has hardware decode (VAAPI).

**Status:** Linux has VAAPI via the custom libwebrtc build (Decoder=VAAPI,
Renderer=GL). Windows/macOS currently ship the stock CPU path only; the UI now
hides Decoder/Renderer options on non-Linux platforms (they're Linux-only).

**Approach (sketch):**
- Prefer building the existing native **GStreamer** transport
  (`WEBRTCBIN`/`NVST` bridges are Linux `.so` today) for Windows/macOS and let
  GStreamer pick its platform hardware decoder:
  - Windows: `d3d11h264dec` (D3D11 Media Foundation), or NVDEC on NVIDIA GPUs.
  - macOS: `avfoundation` / `vth264dec` (VideoToolbox, Metal-backed).
  This reuses the decode/render pipeline already proven on Linux instead of
  porting VAAPI (which doesn't exist outside Linux/Mesa).
- Alternative (libwebrtc-only): add a platform `VideoDecoderFactory` per OS
  (Windows DX11/MFT, macOS VideoToolbox) into the vendored libwebrtc build,
  mirroring how `OPENNOW_DECODER` selects the factory on Linux.
- Render path on Win/mac: keep CPU pixel-buffer (stock) or add a D3D11/Metal
  texture upload for zero-copy.

**Verify:** Decoder stats overlay should read a hardware decoder name (e.g.
`D3D11H264` / `VideoToolboxH264`) instead of `FFmpegVideoDecoder` on each
platform, with a meaningful decode-fps gain over software.

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