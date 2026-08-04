// vaapi_video_decoder.h
//
// A VideoDecoderFactory for libwebrtc that prefers GStreamer VAAPI hardware
// decoding (vah264dec on GStreamer >= 1.20, vaapih264dec on older distros) for
// H.264 and falls back to the built-in FFmpeg software decoder whenever VAAPI
// is unavailable, initialization fails, or the OPENNOW_DECODER=software
// environment variable is set.
//
// This gives the "switch": run with the env var to force software, or without
// it to get hardware decode with automatic software fallback.
#ifndef LIBWEBRTC_SRC_VAAPI_VIDEO_DECODER_H_
#define LIBWEBRTC_SRC_VAAPI_VIDEO_DECODER_H_

#include <memory>

#include "api/video_codecs/video_decoder_factory.h"

namespace libwebrtc {

// Creates a factory that tries the GStreamer VAAPI H.264 decoder first and
// delegates everything else (and VAAPI failures) to `fallback`, which should
// be webrtc::CreateBuiltinVideoDecoderFactory() (the FFmpeg software decoder).
std::unique_ptr<webrtc::VideoDecoderFactory> CreateVaapiVideoDecoderFactory(
    std::unique_ptr<webrtc::VideoDecoderFactory> fallback);

}  // namespace libwebrtc

#endif  // LIBWEBRTC_SRC_VAAPI_VIDEO_DECODER_H_
