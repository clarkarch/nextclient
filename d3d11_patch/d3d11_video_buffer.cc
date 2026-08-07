#include "d3d11_video_buffer.h"

#if defined(_WIN32)
#include <d3d11.h>
#endif

namespace libwebrtc {

D3d11VideoBuffer::D3d11VideoBuffer(void* shared_handle, int width, int height,
                                   int stride_y, int stride_uv,
                                   GstBuffer* buffer,
                                   ID3D11Texture2D* owned_texture)
    : width_(width), height_(height), buffer_(buffer),
      owned_texture_(owned_texture) {
  if (buffer_ != nullptr) {
    // Keep the GStreamer buffer (and therefore the GstD3D11Memory + the D3D11
    // texture it wraps) alive for the whole lifetime of this frame buffer —
    // the legacy shared handle stays valid only while the resource lives.
    gst_buffer_ref(buffer_);
  }
  // owned_texture_ is transferred (no AddRef): the decoder hands over a ref it
  // no longer needs (ComPtr::Detach) and we Release() it in the destructor.
  // On non-Windows builds the member stays null (the decoder that sets it is
  // Windows-only), so the guarded Release() below is never reached.
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
#if defined(_WIN32)
  if (owned_texture_ != nullptr) {
    owned_texture_->Release();
  }
#endif
}

}  // namespace libwebrtc
