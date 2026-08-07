// dmabuf_video_buffer.cc
//
// See dmabuf_video_buffer.h for the design.
#include "dmabuf_video_buffer.h"

#include <cstring>
#include <unistd.h>  // close()

namespace libwebrtc {

DmaBufVideoBuffer::DmaBufVideoBuffer(int y_fd, int uv_fd, int y_offset,
                                     int uv_offset, int y_pitch, int uv_pitch,
                                     int width, int height, uint32_t fourcc,
                                     uint64_t modifier, GstBuffer* buffer,
                                     const GstVideoInfo& info)
    : width_(width), height_(height), buffer_(gst_buffer_ref(buffer)),
      info_(info) {
  desc_.y_fd = y_fd;
  desc_.uv_fd = uv_fd;
  desc_.y_offset = y_offset;
  desc_.uv_offset = uv_offset;
  desc_.y_pitch = y_pitch;
  desc_.uv_pitch = uv_pitch;
  desc_.width = width;
  desc_.height = height;
  desc_.fourcc = fourcc;
  desc_.modifier = modifier;
}

DmaBufVideoBuffer::~DmaBufVideoBuffer() {
  // The EGL import dups the fds, so closing ours after the raster thread has
  // imported is safe. Two layers may share one object/fd on some drivers.
  if (desc_.y_fd >= 0 && desc_.y_fd != desc_.uv_fd) {
    close(desc_.y_fd);
  }
  if (desc_.uv_fd >= 0) {
    close(desc_.uv_fd);
  }
  gst_buffer_unref(buffer_);
}

webrtc::scoped_refptr<webrtc::I420BufferInterface> DmaBufVideoBuffer::ToI420() {
  if (buffer_ == nullptr) return nullptr;
  GstVideoFrame frame;
  if (!gst_video_frame_map(&frame, &info_, buffer_, GST_MAP_READ)) {
    return nullptr;
  }

  const int width = GST_VIDEO_INFO_WIDTH(&info_);
  const int height = GST_VIDEO_INFO_HEIGHT(&info_);
  const int y_stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
  const int uv_stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 1);
  const uint8_t* y = static_cast<const uint8_t*>(
      GST_VIDEO_FRAME_PLANE_DATA(&frame, 0));
  const uint8_t* uv = static_cast<const uint8_t*>(
      GST_VIDEO_FRAME_PLANE_DATA(&frame, 1));

  // NV12 -> I420 in a single pass, straight into the WebRTC I420Buffer (the
  // same conversion the decoder's CPU path used before the zero-copy path).
  const int uv_height = (height + 1) / 2;
  const int uv_width = (width + 1) / 2;
  webrtc::scoped_refptr<webrtc::I420Buffer> i420 =
      webrtc::I420Buffer::Create(width, height);
  for (int row = 0; row < height; ++row) {
    std::memcpy(i420->MutableDataY() + row * i420->StrideY(),
                y + row * y_stride, width);
  }
  for (int row = 0; row < uv_height; ++row) {
    const uint8_t* src = uv + row * uv_stride;
    uint8_t* out_u = i420->MutableDataU() + row * i420->StrideU();
    uint8_t* out_v = i420->MutableDataV() + row * i420->StrideV();
    for (int col = 0; col < uv_width; ++col) {
      out_u[col] = src[col * 2];
      out_v[col] = src[col * 2 + 1];
    }
  }
  gst_video_frame_unmap(&frame);
  return i420;
}

}  // namespace libwebrtc
