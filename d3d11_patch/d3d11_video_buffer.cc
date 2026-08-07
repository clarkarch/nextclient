// d3d11_video_buffer.cc
//
// See d3d11_video_buffer.h for the design.
#include "d3d11_video_buffer.h"

namespace libwebrtc {

D3d11VideoBuffer::D3d11VideoBuffer(void* shared_handle, int width, int height,
                                   int stride_y, int stride_uv,
                                   GstBuffer* buffer)
    : width_(width), height_(height), buffer_(buffer) {
  if (buffer_ != nullptr) {
    // Keep the GStreamer buffer (and therefore the GstD3D11Memory + the D3D11
    // texture it wraps) alive for the whole lifetime of this frame buffer —
    // the legacy shared handle stays valid only while the resource lives.
    gst_buffer_ref(buffer_);
  }
  desc_.handle = shared_handle;
  desc_.format = RtcD3D11TextureFormat::kNv12;
  desc_.width = width;
  desc_.height = height;
  desc_.stride_y = stride_y;
  desc_.stride_uv = stride_uv;
}

D3d11VideoBuffer::~D3d11VideoBuffer() {
  if (buffer_ != nullptr) {
    gst_buffer_unref(buffer_);
  }
}

}  // namespace libwebrtc
