#!/usr/bin/env bash
# Applies the D3D11 zero-copy patch to a webrtc-sdk/libwebrtc wrapper checkout
# (the repo cloned into the webrtc src tree per the vaapi_patch README), and
# marks the app's third_party/libwebrtc as a custom build so the Windows
# flutter_webrtc plugin compiles its zero-copy renderer path.
#
# Usage:
#   ./apply_patch.sh [path-to-wrapper] [path-to-app-third_party-libwebrtc]
#
# The wrapper is the directory that contains BUILD.gn, src/ and include/ from
# https://github.com/webrtc-sdk/libwebrtc, e.g.
#   native/libwebrtc_build/src/libwebrtc
# The second argument is the app's third_party/libwebrtc directory (where the
# custom libwebrtc.dll will be dropped), e.g.
#   packages/flutter_webrtc/third_party/libwebrtc
# Both default to the standard next_client layout.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${1:-$HERE/../native/libwebrtc_build/src/libwebrtc}"
LIBWEBRTC_APP_DIR="${2:-$HERE/../packages/flutter_webrtc/third_party/libwebrtc}"

if [[ ! -d "$WRAPPER" ]]; then
  echo "ERROR: wrapper dir not found: $WRAPPER" >&2
  echo "Pass the path to the libwebrtc wrapper checkout, e.g." >&2
  echo "  $0 native/libwebrtc_build/src/libwebrtc" >&2
  exit 1
fi
if [[ ! -f "$WRAPPER/BUILD.gn" || ! -d "$WRAPPER/src" ]]; then
  echo "ERROR: $WRAPPER does not look like the libwebrtc wrapper" >&2
  exit 1
fi

echo "==> Copying D3D11 zero-copy sources into $WRAPPER/src/ + include/"
cp "$HERE/rtc_video_frame.h"        "$WRAPPER/include/"
cp "$HERE/rtc_video_frame_impl.h"   "$WRAPPER/src/"
cp "$HERE/rtc_video_frame_impl.cc"  "$WRAPPER/src/"
cp "$HERE/d3d11_video_buffer.h"     "$WRAPPER/src/"
cp "$HERE/d3d11_video_buffer.cc"    "$WRAPPER/src/"
cp "$HERE/d3d11_video_decoder.h"    "$WRAPPER/src/"
cp "$HERE/d3d11_video_decoder.cc"   "$WRAPPER/src/"
cp "$HERE/h264_bitstream.h"         "$WRAPPER/src/"

echo "==> Patching BUILD.gn"
# Windows runners often lack a `python3` on PATH (only `python`); pick
# whichever interpreter exists so the patch applies identically in CI.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
else
  PY=python
fi
"$PY" "$HERE/patch_build_gn.py" "$WRAPPER/BUILD.gn"

echo "==> Patching rtc_peerconnection_factory_impl.cc"
"$PY" "$HERE/patch_factory.py" "$WRAPPER/src/rtc_peerconnection_factory_impl.cc"

echo "==> Marking the app's third_party/libwebrtc as a custom build"
if [[ -d "$LIBWEBRTC_APP_DIR/lib" ]]; then
  touch "$LIBWEBRTC_APP_DIR/lib/D3D11_CUSTOM.txt"
  echo "  [ok] wrote $LIBWEBRTC_APP_DIR/lib/D3D11_CUSTOM.txt"
else
  echo "  [warn] $LIBWEBRTC_APP_DIR/lib not found — create it (with the built"
  echo "         libwebrtc.dll + .lib) and touch D3D11_CUSTOM.txt yourself."
fi

echo ""
echo "Done. Next steps:"
echo "  1. Build libwebrtc for Windows (see the wrapper's README / vaapi_patch"
echo "     build steps):"
echo "       cd <webrtc src>/webrtc && gn gen out/win --args=... && ninja -C out/win"
echo "  2. Copy the artifacts into the app so the plugin links your custom dll:"
echo "       cp out/win/libwebrtc.dll     $LIBWEBRTC_APP_DIR/lib/"
echo "       cp out/win/libwebrtc.dll.lib $LIBWEBRTC_APP_DIR/lib/"
echo "       rm -f $LIBWEBRTC_APP_DIR/../downloads/libwebrtc-win-*.zip"
echo "     (the D3D11_CUSTOM.txt marker already tells CMake to use your build)"
echo "  3. Run the app with the GPU renderer: Settings > Client > Renderer"
echo "     > GPU (shader YUV->RGB), then stream. Watch for [d3drender] logs"
echo "     with Verbose logs enabled (compositing via zero-copy D3D11 texture"
echo "     means the decoder wraps frames in D3d11VideoBuffer)."
echo ""
echo "Remember: these source files are NOT committed to your git checkout."
