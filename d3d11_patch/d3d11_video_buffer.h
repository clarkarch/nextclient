// d3d11_video_buffer.h
//
// A webrtc::VideoFrameBuffer whose storage is a D3D11 NV12 texture shared
// with the renderer through a legacy DXGI shared handle (see
// RtcD3D11TextureDescriptor in rtc_video_frame.h). type() is kNative: there
// is no CPU pixel data. The Windows renderer reads the descriptor via
// RTCVideoFrame::NativeD3D11Handle(), opens the handle on its own D3D11
// device (ID3D11Device::OpenSharedResource), and composites the NV12 texture
// through a shader — decode → composite with zero CPU copies (the Windows
// analog of vaapi_patch's DmaBufVideoBuffer).
//
// The decoder exports the texture's legacy shared handle via
// gst_d3d11_memory_get_resource_handle + IDXGIResource::GetSharedHandle (the
// texture must have been created with D3D11_RESOURCE_MISC_SHARED for the
// export to succeed; stock d3d11h264dec textures are not shared, so the
// decoder CPU-falls-back) and keeps it alive for the whole lifetime of this
// buffer: the constructor takes an optional GstBuffer ref (the GStreamer
// buffer owns the GstD3D11Memory, which in turn keeps the D3D11 texture
// alive) that is released when the buffer is destroyed — so the shared handle
// stays valid exactly as long as the frame is referenced.
// ToI420() returns nullptr — GPU-resident frames have no trivial CPU view;
// consumers that need CPU pixels must use the stock I420 path (choose the
// OPENNOW_RENDERER=cpu renderer with the builtin FFmpeg decoder, or have the
// decoder keep a CPU-readable staging copy).
#ifndef LIBWEBRTC_SRC_D3D11_VIDEO_BUFFER_H_
#define LIBWEBRTC_SRC_D3D11_VIDEO_BUFFER_H_

#include <cstdint>

#include <gst/gst.h>

#include "api/video/video_frame_buffer.h"
#include "rtc_video_frame.h"

// Forward declaration only: this header compiles on every platform the
// wrapper builds for, so d3d11.h must not leak into non-Windows builds. The
// full type is only ever touched in d3d11_video_buffer.cc under _WIN32.
struct ID3D11Texture2D;

namespace libwebrtc {

// kNative D3D11 frame envelope (Windows zero-CPU-copy path). The decoder
// exports the decoded NV12 surface's legacy shared handle into the descriptor
// (either the decoder's own MISC_SHARED texture, or a MISC_SHARED GPU copy it
// blitted for stock elements); the renderer opens it on its own device and
// converts it GPU-side.
class D3d11VideoBuffer : public webrtc::VideoFrameBuffer {
 public:
  D3d11VideoBuffer(void* shared_handle, int width, int height, int stride_y,
                   int stride_uv, GstBuffer* buffer = nullptr,
                   ID3D11Texture2D* owned_texture = nullptr);

  ~D3d11VideoBuffer() override;

  webrtc::VideoFrameBuffer::Type type() const override {
    return webrtc::VideoFrameBuffer::Type::kNative;
  }

  int width() const override { return width_; }
  int height() const override { return height_; }

  // Native frame — no trivial I420 view.
  const webrtc::I420BufferInterface* GetI420() const override {
    return nullptr;
  }

  // CPU fallback: not available for GPU-resident frames (see header docs).
  webrtc::scoped_refptr<webrtc::I420BufferInterface> ToI420() override {
    return nullptr;
  }

  // Returns the ABI-stable descriptor the renderer opens.
  const RtcD3D11TextureDescriptor* d3d11_desc() const { return &desc_; }

 private:
  RtcD3D11TextureDescriptor desc_;
  int width_ = 0;
  int height_ = 0;
  // Ref'd GstBuffer (owns the GstD3D11Memory -> D3D11 texture). Keeps the
  // shared handle valid until the frame is released. Null for frames created
  // without a GStreamer buffer (e.g. tests) and for the GPU shared-copy path.
  GstBuffer* buffer_ = nullptr;
  // Owned D3D11 shared-copy texture (GPU-copy export): the decoder blits the
  // decode texture into a MISC_SHARED copy and transfers ownership here, so
  // the exported shared handle stays valid exactly as long as this frame
  // buffer. Null for the direct-export path (texture owned by the GstBuffer)
  // and tests.
  ID3D11Texture2D* owned_texture_ = nullptr;
};

}  // namespace libwebrtc

#endif  // LIBWEBRTC_SRC_D3D11_VIDEO_BUFFER_H_
