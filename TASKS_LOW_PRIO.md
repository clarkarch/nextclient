# Backlog — Low Priority

> Nice-to-have, non-blocking tasks. Ordered roughly by impact. Each entry is
> self-contained and can be picked up independently.

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