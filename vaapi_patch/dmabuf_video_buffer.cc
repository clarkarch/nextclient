// dmabuf_video_buffer.cc
//
// See dmabuf_video_buffer.h for the design.
#include "dmabuf_video_buffer.h"

#include <unistd.h>  // close()

#include "libyuv/convert.h"

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

  // NV12 -> I420 via libyuv (SIMD). Slow path only: sinks that cannot handle
  // kNative (stock CPU renderer, recording).
  webrtc::scoped_refptr<webrtc::I420Buffer> i420 =
      webrtc::I420Buffer::Create(width, height);
  const int ret = libyuv::NV12ToI420(
      y, y_stride, uv, uv_stride, i420->MutableDataY(), i420->StrideY(),
      i420->MutableDataU(), i420->StrideU(), i420->MutableDataV(),
      i420->StrideV(), width, height);
  gst_video_frame_unmap(&frame);
  if (ret != 0) return nullptr;
  return i420;
}

}  // namespace libwebrtc
