#!/usr/bin/env python3
"""Anchored, idempotent patch: wire the D3D11 decoder factory into the
wrapper's rtc_peerconnection_factory_impl.cc so every PeerConnectionFactory
built on Windows goes through CreateD3d11VideoDecoderFactory (D3D11VA-first +
FFmpeg fallback once implemented; the stub delegates to FFmpeg).

Usage: patch_factory.py <path-to-rtc_peerconnection_factory_impl.cc>
"""
import sys


def patch(path: str) -> bool:
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    # 1) Add the include (Windows only).
    include_anchor = '#include "api/video_codecs/builtin_video_encoder_factory.h"\n'
    include_add = (
        '#include "api/video_codecs/builtin_video_encoder_factory.h"\n'
        '#if defined(WEBRTC_WIN)\n'
        '#include "d3d11_video_decoder.h"\n'
        "#endif\n"
    )
    if '#include "d3d11_video_decoder.h"' in src:
        print("  [skip] include already present")
    elif include_anchor not in src:
        print("  [FAIL] include anchor not found")
        return False
    else:
        src = src.replace(include_anchor, include_add, 1)
        print("  [ok] added d3d11_video_decoder.h include")

    # 2) Swap the decoder factory in the #else branch (non-MSDK builds). Also
    # handles the vaapi-patched layout (#elif defined(WEBRTC_LINUX) ... #else).
    factory_old = (
        "#else\n"
        "        webrtc::CreateBuiltinVideoEncoderFactory(),\n"
        "        webrtc::CreateBuiltinVideoDecoderFactory(),\n"
        "#endif\n"
    )
    factory_new = (
        "#elif defined(WEBRTC_WIN)\n"
        "        webrtc::CreateBuiltinVideoEncoderFactory(),\n"
        "        CreateD3d11VideoDecoderFactory(\n"
        "            webrtc::CreateBuiltinVideoDecoderFactory()),\n"
        "#else\n"
        "        webrtc::CreateBuiltinVideoEncoderFactory(),\n"
        "        webrtc::CreateBuiltinVideoDecoderFactory(),\n"
        "#endif\n"
    )
    if "CreateD3d11VideoDecoderFactory(" in src:
        print("  [skip] factory wiring already present")
    elif factory_old not in src:
        print("  [FAIL] factory anchor not found")
        return False
    else:
        src = src.replace(factory_old, factory_new, 1)
        print("  [ok] wired CreateD3d11VideoDecoderFactory into #else branch")

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    return True


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: patch_factory.py <file>")
        sys.exit(2)
    sys.exit(0 if patch(sys.argv[1]) else 1)
