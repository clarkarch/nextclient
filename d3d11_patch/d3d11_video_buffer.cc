// d3d11_video_buffer.cc
//
// See d3d11_video_buffer.h for the design.
#include "d3d11_video_buffer.h"

namespace libwebrtc {

D3d11VideoBuffer::D3d11VideoBuffer(void* shared_handle, int width, int height,
                                   int stride_y, int stride_uv)
    : width_(width), height_(height) {
  desc_.handle = shared_handle;
  desc_.format = RtcD3D11TextureFormat::kNv12;
  desc_.width = width;
  desc_.height = height;
  desc_.stride_y = stride_y;
  desc_.stride_uv = stride_uv;
}

}  // namespace libwebrtc
