#!/usr/bin/env python3
"""Anchored, idempotent patch: add the D3D11 zero-copy sources to the
webrtc-sdk/libwebrtc wrapper's BUILD.gn (the rtc_shared_library("libwebrtc")
target).

Adds:
  - src/d3d11_video_buffer.cc/.h
  - src/d3d11_video_decoder.cc/.h
right after the vaapi sources if present (d3d11_patch can be layered on a
vaapi-patched checkout) or after rtc_logging.cc on a fresh one.

Usage: patch_build_gn.py <path-to-BUILD.gn>
"""
import sys


def patch(path: str) -> bool:
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    # Anchor on the vaapi decoder entry when this is a vaapi-patched checkout,
    # otherwise on rtc_logging.cc (the vaapi patch's own anchor).
    vaapi_anchor = '    "src/d3d11_video_decoder.cc",\n'
    if '"src/d3d11_video_decoder.cc"' in src:
        print("  [skip] d3d11 sources already present")
        return True

    anchor = None
    for candidate in ('    "src/vaapi_video_decoder.h",\n',
                      '    "src/rtc_logging.cc",\n'):
        if candidate in src:
            anchor = candidate
            break
    if anchor is None:
        print("  [FAIL] sources anchor not found "
              "(looked for vaapi_video_decoder.h / rtc_logging.cc)")
        return False

    add = (
        anchor +
        '    "src/d3d11_video_buffer.cc",\n'
        '    "src/d3d11_video_buffer.h",\n'
        '    "src/d3d11_video_decoder.cc",\n'
        '    "src/d3d11_video_decoder.h",\n'
    )
    src = src.replace(anchor, add, 1)
    print("  [ok] added d3d11_video_buffer + d3d11_video_decoder sources")

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    return True


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: patch_build_gn.py <BUILD.gn>")
        sys.exit(2)
    sys.exit(0 if patch(sys.argv[1]) else 1)
