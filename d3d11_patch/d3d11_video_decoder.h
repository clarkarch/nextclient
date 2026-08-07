// d3d11_video_decoder.h
//
// The Windows counterpart of vaapi_patch's vaapi_video_decoder.h. A factory
// that prefers D3D11VA hardware decoding for H.264 and falls back to the
// built-in FFmpeg software decoder whenever D3D11VA is unavailable,
// initialization fails, or OPENNOW_DECODER=software is set.
//
// The zero-copy contract is already in place: decoded NV12 surfaces must be
// wrapped in a libwebrtc::D3d11VideoBuffer (d3d11_video_buffer.h) — a kNative
// VideoFrameBuffer carrying the texture's legacy DXGI shared handle — so the
// Windows renderer (FlutterVideoRendererD3D, OPENNOW_RENDERER=gl) opens the
// texture on its own device and composites it with no CPU copy. Frames that
// are NOT wrapped stay on the I420 plane-upload path, so a factory that only
// hardware-decodes *some* frames is safe.
//
// The shipped d3d11_video_decoder.cc is a delegating stub (returns `fallback`,
// the builtin FFmpeg factory) so the patch builds end-to-end before the real
// decoder lands. Recommended implementation: reuse the same GStreamer
// d3d11h264dec element the app's native nvst_bridge already uses on Windows
// (gst-plugins-bad, GST_CAPS_FEATURE_MEMORY_D3D11_MEMORY buffers) and export
// each decoded surface's ID3D11Texture2D as a legacy shared handle
// (IDXGIResource::GetSharedHandle) into the D3d11VideoBuffer.
#ifndef LIBWEBRTC_SRC_D3D11_VIDEO_DECODER_H_
#define LIBWEBRTC_SRC_D3D11_VIDEO_DECODER_H_

#include <memory>

#include "api/video_codecs/video_decoder_factory.h"

namespace libwebrtc {

// Creates a factory that tries the D3D11VA H.264 decoder first and delegates
// everything else (and D3D11VA failures) to `fallback`, which should be
// webrtc::CreateBuiltinVideoDecoderFactory() (the FFmpeg software decoder).
std::unique_ptr<webrtc::VideoDecoderFactory> CreateD3d11VideoDecoderFactory(
    std::unique_ptr<webrtc::VideoDecoderFactory> fallback);

}  // namespace libwebrtc

#endif  // LIBWEBRTC_SRC_D3D11_VIDEO_DECODER_H_
