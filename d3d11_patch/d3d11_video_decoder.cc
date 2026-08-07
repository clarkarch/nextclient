// d3d11_video_decoder.cc
//
// NOTE: this is a DELEGATING STUB. It returns the builtin (FFmpeg) factory so
// the patched build compiles and runs end-to-end; hardware decode is then
// identical to stock (software). Implement the D3D11VA decoder behind this
// factory (see d3d11_video_decoder.h) — wrap decoded NV12 surfaces in
// libwebrtc::D3d11VideoBuffer so the Windows renderer's zero-copy path
// activates. The OPENNOW_DECODER=software env var (read here, like the VAAPI
// decoder on Linux) should force the software path for A/B testing.
#include "d3d11_video_decoder.h"

#include <cstdlib>
#include <cstring>

namespace libwebrtc {

std::unique_ptr<webrtc::VideoDecoderFactory> CreateD3d11VideoDecoderFactory(
    std::unique_ptr<webrtc::VideoDecoderFactory> fallback) {
  const char* value = std::getenv("OPENNOW_DECODER");
  if (value != nullptr && std::strcmp(value, "software") == 0) {
    // Force software decode for A/B testing (mirrors vaapi_video_decoder.cc).
    return fallback;
  }
  // TODO(d3d11): return a D3D11VA-first factory once implemented.
  return fallback;
}

}  // namespace libwebrtc
