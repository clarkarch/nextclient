#!/usr/bin/env python3
"""Anchored, idempotent patch: add the D3D11 zero-copy decoder + GStreamer
build support to the webrtc-sdk/libwebrtc wrapper's BUILD.gn (the
rtc_shared_library("libwebrtc") target).

Adds:
  1. The d3d11 decoder + buffer sources (d3d11_video_buffer.cc/.h,
     d3d11_video_decoder.cc/.h, h264_bitstream.h) right after the vaapi
     sources if present (d3d11_patch can be layered on a vaapi-patched
     checkout) or after rtc_logging.cc on a fresh one.
  2. A Windows-only pkg_config("gstreamer_d3d11") declaration (gstreamer-1.0
     / app / video + the gst-plugins-bad d3d11 helper library, which ships
     gstreamer-d3d11-1.0.pc and the <gst/d3d11/*.h> headers in the GStreamer
     MSVC runtime). This is a SEPARATE target from vaapi_patch's
     pkg_config("gstreamer") (Linux) so both patches compose on one checkout:
     gstreamer_d3d11 is referenced only under is_win, so on Linux it is never
     evaluated and the d3d11 packages cannot break the vaapi build.
  3. configs += [ ":gstreamer_d3d11" ] on Windows so the libwebrtc target
     links GStreamer.

Every step is independently idempotent: re-running on an already-patched
BUILD.gn skips what is present and adds only what is missing.

Usage: patch_build_gn.py <path-to-BUILD.gn>
"""
import sys


def patch(path: str) -> bool:
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    ok = True

    # 1) Decoder + buffer sources. Anchor on the vaapi decoder entry when this
    #    is a vaapi-patched checkout, otherwise on rtc_logging.cc (the vaapi
    #    patch's own anchor).
    if '"src/d3d11_video_decoder.cc"' in src:
        print("  [skip] d3d11 sources already present")
    else:
        anchor = None
        for candidate in ('    "src/vaapi_video_decoder.h",\n',
                          '    "src/rtc_logging.cc",\n'):
            if candidate in src:
                anchor = candidate
                break
        if anchor is None:
            print("  [FAIL] sources anchor not found "
                  "(looked for vaapi_video_decoder.h / rtc_logging.cc)")
            ok = False
        else:
            add = (
                anchor +
                '    "src/d3d11_video_buffer.cc",\n'
                '    "src/d3d11_video_buffer.h",\n'
                '    "src/d3d11_video_decoder.cc",\n'
                '    "src/d3d11_video_decoder.h",\n'
                '    "src/h264_bitstream.h",\n'
            )
            src = src.replace(anchor, add, 1)
            print("  [ok] added d3d11_video_buffer + d3d11_video_decoder "
                  "+ h264_bitstream sources")

    # 2) Windows-only GStreamer pkg_config, anchored after the gio block (the
    #    same anchor vaapi_patch uses for its pkg_config("gstreamer")).
    gio_block = (
        'if (is_linux) {\n'
        '  pkg_config("gio") {\n'
        '    packages = [\n'
        '      "gio-2.0",\n'
        '      "gio-unix-2.0",\n'
        '    ]\n'
        '  }\n'
        '}\n'
    )
    d3d11_pkg_block = (
        '\n'
        'if (is_win) {\n'
        '  pkg_config("gstreamer_d3d11") {\n'
        '    packages = [\n'
        '      "gstreamer-1.0",\n'
        '      "gstreamer-app-1.0",\n'
        '      "gstreamer-video-1.0",\n'
        '      "gstreamer-d3d11-1.0",\n'
        '    ]\n'
        '  }\n'
        '}\n'
    )
    if 'pkg_config("gstreamer_d3d11")' in src:
        print("  [skip] gstreamer_d3d11 pkg_config already present")
    elif gio_block not in src:
        print("  [FAIL] gio pkg_config anchor not found (for gstreamer_d3d11)")
        ok = False
    else:
        src = src.replace(gio_block, gio_block + d3d11_pkg_block, 1)
        print('  [ok] added pkg_config("gstreamer_d3d11")')

    # 3) configs += [ ":gstreamer_d3d11" ] on Windows, after the
    #    external_config public_configs line (the vaapi patch's anchor).
    cfg_anchor = ':external_config" ]\n'
    cfg_add = (
        ':external_config" ]\n'
        '\n'
        '  if (is_win) {\n'
        '    configs += [ ":gstreamer_d3d11" ]\n'
        '  }\n'
    )
    if 'configs += [ ":gstreamer_d3d11" ]' in src:
        print("  [skip] gstreamer_d3d11 configs already present")
    elif cfg_anchor not in src:
        print("  [FAIL] configs anchor (external_config) not found "
              "(for gstreamer_d3d11)")
        ok = False
    else:
        src = src.replace(cfg_anchor, cfg_add, 1)
        print('  [ok] added configs += [ ":gstreamer_d3d11" ]')

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    return ok


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: patch_build_gn.py <BUILD.gn>")
        sys.exit(2)
    sys.exit(0 if patch(sys.argv[1]) else 1)
