#!/usr/bin/env python3
"""Anchored patch: add GStreamer build support to the webrtc-sdk/libwebrtc
wrapper's BUILD.gn (the rtc_shared_library("libwebrtc") target).

Adds:
  1. A pkg_config("gstreamer") declaration next to pkg_config("gio").
  2. The vaapi decoder sources to the libwebrtc target.
  3. configs += [ ":gstreamer" ] on Linux so the target links gstreamer.

Usage: patch_build_gn.py <path-to-BUILD.gn>
"""
import sys


def patch(path: str) -> bool:
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    ok = True

    # 1) pkg_config("gstreamer") right after the gio pkg_config block.
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
    gst_block = (
        '\n'
        'if (is_linux) {\n'
        '  pkg_config("gstreamer") {\n'
        '    packages = [\n'
        '      "gstreamer-1.0",\n'
        '      "gstreamer-app-1.0",\n'
        '      "gstreamer-video-1.0",\n'
        '    ]\n'
        '  }\n'
        '}\n'
    )
    if 'pkg_config("gstreamer")' in src:
        print("  [skip] gstreamer pkg_config already present")
    elif gio_block not in src:
        print("  [FAIL] gio pkg_config anchor not found")
        ok = False
    else:
        src = src.replace(gio_block, gio_block + gst_block, 1)
        print("  [ok] added pkg_config(\"gstreamer\")")

    # 2) Sources for the vaapi decoder, appended near rtc_logging.cc.
    src_anchor = '    "src/rtc_logging.cc",\n'
    src_add = (
        '    "src/rtc_logging.cc",\n'
        '    "src/vaapi_video_decoder.cc",\n'
        '    "src/vaapi_video_decoder.h",\n'
    )
    if '"src/vaapi_video_decoder.cc"' in src:
        print("  [skip] vaapi sources already present")
    elif src_anchor not in src:
        print("  [FAIL] sources anchor (rtc_logging.cc) not found")
        ok = False
    else:
        src = src.replace(src_anchor, src_add, 1)
        print("  [ok] added vaapi_video_decoder sources")

    # 3) configs += [ ":gstreamer" ] on Linux, after the gio pkg_config usage
    #    guard pattern (desktop_capture block) — simplest robust anchor is the
    #    external_config public_configs line that precedes the sources list.
    cfg_anchor = "  public_configs = [ \":external_config\" ]\n"
    cfg_add = (
        "  public_configs = [ \":external_config\" ]\n"
        "\n"
        "  if (is_linux) {\n"
        '    configs += [ ":gstreamer" ]\n'
        "  }\n"
    )
    if 'configs += [ ":gstreamer" ]' in src:
        print("  [skip] gstreamer configs already present")
    elif cfg_anchor not in src:
        print("  [FAIL] configs anchor (external_config) not found")
        ok = False
    else:
        src = src.replace(cfg_anchor, cfg_add, 1)
        print('  [ok] added configs += [ ":gstreamer" ]')

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    return ok


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: patch_build_gn.py <BUILD.gn>")
        sys.exit(2)
    sys.exit(0 if patch(sys.argv[1]) else 1)
