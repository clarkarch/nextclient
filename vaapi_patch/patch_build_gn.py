#!/usr/bin/env python3
"""Anchored, idempotent patch: add GStreamer VAAPI + zero-copy dmabuf build
support to the webrtc-sdk/libwebrtc wrapper's BUILD.gn (the
rtc_shared_library("libwebrtc") target).

Adds:
  1. A pkg_config("gstreamer") declaration next to pkg_config("gio")
     (gstreamer-1.0 / app / video / va + libva).
  2. The vaapi decoder + dmabuf buffer sources to the libwebrtc target.
  3. configs += [ ":gstreamer" ] on Linux so the target links gstreamer/libva.

Every step is independently idempotent: re-running on an already-patched
BUILD.gn (e.g. after apply_patch.sh adds new sources) skips what is present and
adds only what is missing.

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

    # 1b) gstreamer-va-1.0 + libva inside the gstreamer pkg_config packages
    # list (vaExportSurfaceHandle + gst/va surface access). Independent anchor:
    # the gstreamer-video-1.0 entry from step 1.
    gst_pkg_anchor = '      "gstreamer-video-1.0",\n'
    gst_pkg_add = (
        '      "gstreamer-video-1.0",\n'
        '      "gstreamer-va-1.0",\n'
        '      "libva",\n'
    )
    if '"gstreamer-va-1.0"' in src:
        print("  [skip] gstreamer-va-1.0/libva packages already present")
    elif gst_pkg_anchor not in src:
        print("  [FAIL] gstreamer-video-1.0 pkg anchor not found")
        ok = False
    else:
        src = src.replace(gst_pkg_anchor, gst_pkg_add, 1)
        print("  [ok] added gstreamer-va-1.0/libva packages")

    # 2) Decoder + dmabuf sources. Anchor: the vaapi_video_decoder entry that
    # a previous patch run (or this one, below) inserted after rtc_logging.cc.
    src_anchor = '    "src/vaapi_video_decoder.h",\n'
    src_add = (
        '    "src/vaapi_video_decoder.h",\n'
        '    "src/dmabuf_video_buffer.cc",\n'
        '    "src/dmabuf_video_buffer.h",\n'
    )
    if '"src/vaapi_video_decoder.cc"' not in src:
        # Fresh BUILD.gn: insert vaapi sources after rtc_logging.cc first.
        log_anchor = '    "src/rtc_logging.cc",\n'
        log_add = (
            '    "src/rtc_logging.cc",\n'
            '    "src/vaapi_video_decoder.cc",\n'
            '    "src/vaapi_video_decoder.h",\n'
        )
        if log_anchor not in src:
            print("  [FAIL] sources anchor (rtc_logging.cc) not found")
            ok = False
        else:
            src = src.replace(log_anchor, log_add, 1)
            print("  [ok] added vaapi_video_decoder sources")
            # Now that vaapi_video_decoder.h exists, apply the dmabuf add.
            if '"src/dmabuf_video_buffer.cc"' not in src:
                src = src.replace(src_anchor, src_add, 1)
                print("  [ok] added dmabuf_video_buffer sources")
    elif '"src/dmabuf_video_buffer.cc"' not in src:
        if src_anchor not in src:
            print("  [FAIL] dmabuf sources anchor (vaapi_video_decoder.h) not found")
            ok = False
        else:
            src = src.replace(src_anchor, src_add, 1)
            print("  [ok] added dmabuf_video_buffer sources")
    else:
        print("  [skip] vaapi + dmabuf sources already present")

    # 3) configs += [ ":gstreamer" ] on Linux, after the external_config
    #    public_configs line that precedes the sources list.
    cfg_anchor = ':external_config" ]\n'
    cfg_add = (
        ':external_config" ]\n'
        '\n'
        '  if (is_linux) {\n'
        '    configs += [ ":gstreamer" ]\n'
        '  }\n'
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
