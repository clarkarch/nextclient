// d3d11_video_decoder.h
//
// The Windows counterpart of vaapi_patch's vaapi_video_decoder.h. A factory
// that prefers D3D11VA hardware decoding for H.264 and falls back to the
// built-in FFmpeg software decoder whenever D3D11VA is unavailable,
// initialization fails, or OPENNOW_DECODER=software is set.
//
// The zero-CPU-copy contract is already in place: decoded NV12 surfaces are
// exported to a legacy DXGI shared handle
// (gst_d3d11_memory_get_resource_handle + IDXGIResource::GetSharedHandle;
// note gst_d3d11_memory_export was removed in gst-plugins-bad 1.22) and
// wrapped in a libwebrtc::D3d11VideoBuffer (d3d11_video_buffer.h) — a kNative
// VideoFrameBuffer carrying the texture's shared handle — so the Windows
// renderer (FlutterVideoRendererD3D, OPENNOW_RENDERER=gl) opens the texture
// on its own device and composites it with no CPU copy. Two export tiers:
// direct MISC_SHARED export when the element allocates shared textures, and a
// GPU-only shared copy (CopySubresourceRegion) for stock d3d11h264dec, whose
// textures are not shared — decoded pixels stay on the GPU in both cases.
// Only when neither works (no usable D3D11 device) do frames take the CPU
// NV12->I420 fallback, so a factory that only hardware-decodes *some* frames
// is safe.
//
// The decoder is backed by the same GStreamer d3d11h264dec element the app's
// native nvst_bridge uses on Windows (gst-plugins-bad,
// GST_CAPS_FEATURE_MEMORY_D3D11_MEMORY buffers). Requires a GStreamer runtime
// with the d3d11 plugin on the client machine and a custom libwebrtc Windows
// build that links it (see README.md + native/README.md for the wrapper build
// flow; the GStreamer Windows runtime must be bundled with the app).
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
