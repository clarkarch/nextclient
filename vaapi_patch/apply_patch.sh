#!/usr/bin/env bash
# Applies the GStreamer VAAPI decoder patch to a webrtc-sdk/libwebrtc wrapper
# checkout (the repo cloned into the webrtc src tree per the README).
#
# Usage:
#   ./apply_patch.sh [path-to-wrapper]
#
# The wrapper is the directory that contains BUILD.gn, src/ and include/ from
# https://github.com/webrtc-sdk/libwebrtc. After following the README build
# steps this lives at:
#   native/libwebrtc_build/src/libwebrtc
# If no argument is given, we assume <project>/native/libwebrtc_build/src/libwebrtc.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${1:-$HERE/../native/libwebrtc_build/src/libwebrtc}"

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

echo "==> Copying decoder + zero-copy sources into $WRAPPER/src/"
cp "$HERE/vaapi_h264_bitstream.h"   "$WRAPPER/src/"
cp "$HERE/vaapi_video_decoder.h"    "$WRAPPER/src/"
cp "$HERE/vaapi_video_decoder.cc"   "$WRAPPER/src/"
cp "$HERE/dmabuf_video_buffer.h"    "$WRAPPER/src/"
cp "$HERE/dmabuf_video_buffer.cc"   "$WRAPPER/src/"
cp "$HERE/rtc_video_frame.h"        "$WRAPPER/include/"
cp "$HERE/rtc_video_frame_impl.h"   "$WRAPPER/src/"
cp "$HERE/rtc_video_frame_impl.cc"  "$WRAPPER/src/"

echo "==> Patching BUILD.gn"
python3 "$HERE/patch_build_gn.py" "$WRAPPER/BUILD.gn"

echo "==> Patching rtc_peerconnection_factory_impl.cc"
python3 "$HERE/patch_factory.py" "$WRAPPER/src/rtc_peerconnection_factory_impl.cc"

echo ""
echo "Done. Your wrapper now has GStreamer VAAPI decoding wired in."
echo "Remember: these source files are NOT committed to your git checkout."
