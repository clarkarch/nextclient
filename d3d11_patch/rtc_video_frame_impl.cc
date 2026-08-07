#include "rtc_video_frame_impl.h"

#include "api/video/i420_buffer.h"
#include "libyuv/convert_argb.h"
#include "libyuv/convert_from.h"
#include "rtc_base/checks.h"
#include "rtc_base/logging.h"

#if defined(WEBRTC_LINUX)
#include "dmabuf_video_buffer.h"
#endif
#if defined(WEBRTC_WIN)
#include "d3d11_video_buffer.h"
#endif

namespace libwebrtc {

VideoFrameBufferImpl::VideoFrameBufferImpl(
    webrtc::scoped_refptr<webrtc::VideoFrameBuffer> frame_buffer)
    : buffer_(frame_buffer) {}

VideoFrameBufferImpl::VideoFrameBufferImpl(
    webrtc::scoped_refptr<webrtc::I420Buffer> frame_buffer)
    : buffer_(frame_buffer) {}

VideoFrameBufferImpl::~VideoFrameBufferImpl() {}

scoped_refptr<RTCVideoFrame> VideoFrameBufferImpl::Copy() {
  scoped_refptr<VideoFrameBufferImpl> frame =
      scoped_refptr<VideoFrameBufferImpl>(
          new RefCountedObject<VideoFrameBufferImpl>(buffer_));
  return frame;
}

int VideoFrameBufferImpl::width() const { return buffer_->width(); }

int VideoFrameBufferImpl::height() const { return buffer_->height(); }

// NOTE: plane accessors must go through ToI420(), not GetI420(). GetI420()
// returns nullptr for kNative frames (zero-copy paths) and would null-deref
// here; ToI420() is the conversion fallback and is free for I420 buffers
// (I420BufferInterface::ToI420() returns itself). For kNative D3D11 frames
// ToI420() returns nullptr (no CPU view) — use the GPU renderer with those.
const uint8_t* VideoFrameBufferImpl::DataY() const {
  auto i420 = buffer_->ToI420();
  return i420 ? i420->DataY() : nullptr;
}

const uint8_t* VideoFrameBufferImpl::DataU() const {
  auto i420 = buffer_->ToI420();
  return i420 ? i420->DataU() : nullptr;
}

const uint8_t* VideoFrameBufferImpl::DataV() const {
  auto i420 = buffer_->ToI420();
  return i420 ? i420->DataV() : nullptr;
}

int VideoFrameBufferImpl::StrideY() const {
  auto i420 = buffer_->ToI420();
  return i420 ? i420->StrideY() : 0;
}

int VideoFrameBufferImpl::StrideU() const {
  auto i420 = buffer_->ToI420();
  return i420 ? i420->StrideU() : 0;
}

int VideoFrameBufferImpl::StrideV() const {
  auto i420 = buffer_->ToI420();
  return i420 ? i420->StrideV() : 0;
}

const void* VideoFrameBufferImpl::NativeDmaBufHandle() const {
#if defined(WEBRTC_LINUX)
  if (buffer_ &&
      buffer_->type() == webrtc::VideoFrameBuffer::Type::kNative) {
    const DmaBufVideoBuffer* dmabuf =
        static_cast<const DmaBufVideoBuffer*>(buffer_.get());
    return dmabuf->dma_buf();
  }
#else
  (void)buffer_;
#endif
  return nullptr;
}

const void* VideoFrameBufferImpl::NativeD3D11Handle() const {
#if defined(WEBRTC_WIN)
  if (buffer_ &&
      buffer_->type() == webrtc::VideoFrameBuffer::Type::kNative) {
    const D3d11VideoBuffer* d3d =
        static_cast<const D3d11VideoBuffer*>(buffer_.get());
    return d3d->d3d11_desc();
  }
#else
  (void)buffer_;
#endif
  return nullptr;
}

int VideoFrameBufferImpl::ConvertToARGB(Type type, uint8_t* dst_buffer,
                                        int dst_stride, int dest_width,
                                        int dest_height) {
  // Use ToI420() so kNative frames are converted (CPU fallback) instead
  // of crashing in I420Buffer::Rotate(const VideoFrameBuffer&) which calls
  // GetI420() internally. Free for I420 buffers. (kNative D3D11 frames have
  // no I420 view — ToI420() returns nullptr and this returns 0.)
  webrtc::scoped_refptr<webrtc::I420BufferInterface> i420 = buffer_->ToI420();
  if (!i420) return 0;

  webrtc::scoped_refptr<webrtc::I420Buffer> rotated =
      webrtc::I420Buffer::Rotate(*i420, rotation_);

  webrtc::scoped_refptr<webrtc::I420Buffer> dest =
      webrtc::I420Buffer::Create(dest_width, dest_height);

  dest->ScaleFrom(*rotated.get());
  int buf_size = dest->width() * dest->height() * (32 >> 3);
  switch (type) {
    case libwebrtc::RTCVideoFrame::Type::kARGB:
      libyuv::I420ToARGB(dest->DataY(), dest->StrideY(), dest->DataU(),
                         dest->StrideU(), dest->DataV(), dest->StrideV(),
                         dst_buffer, dest->width() * 32 / 8, dest->width(),
                         dest->height());
      break;
    case libwebrtc::RTCVideoFrame::Type::kBGRA:
      libyuv::I420ToBGRA(dest->DataY(), dest->StrideY(), dest->DataU(),
                         dest->StrideU(), dest->DataV(), dest->StrideV(),
                         dst_buffer, dest->width() * 32 / 8, dest->width(),
                         dest->height());
      break;
    case libwebrtc::RTCVideoFrame::Type::kABGR:
      libyuv::I420ToABGR(dest->DataY(), dest->StrideY(), dest->DataU(),
                         dest->StrideU(), dest->DataV(), dest->StrideV(),
                         dst_buffer, dest->width() * 32 / 8, dest->width(),
                         dest->height());
      break;
    case libwebrtc::RTCVideoFrame::Type::kRGBA:
      libyuv::I420ToRGBA(dest->DataY(), dest->StrideY(), dest->DataU(),
                         dest->StrideU(), dest->DataV(), dest->StrideV(),
                         dst_buffer, dest->width() * 32 / 8, dest->width(),
                         dest->height());
      break;
    default:
      break;
  }
  return buf_size;
}

libwebrtc::RTCVideoFrame::VideoRotation VideoFrameBufferImpl::rotation() {
  switch (rotation_) {
    case webrtc::kVideoRotation_0:
      return RTCVideoFrame::kVideoRotation_0;
    case webrtc::kVideoRotation_90:
      return RTCVideoFrame::kVideoRotation_90;
    case webrtc::kVideoRotation_180:
      return RTCVideoFrame::kVideoRotation_180;
    case webrtc::kVideoRotation_270:
      return RTCVideoFrame::kVideoRotation_270;
    default:
      break;
  }
  return RTCVideoFrame::kVideoRotation_0;
}

scoped_refptr<RTCVideoFrame> RTCVideoFrame::Create(int width, int height,
                                                   const uint8_t* buffer,
                                                   int length) {
  int stride_y = width;
  int stride_uv = (width + 1) / 2;

  int size_y = stride_y * height;
  int size_u = stride_uv * height / 2;
  // int size_v = size_u;

  RTC_DCHECK(length == (width * height * 3) / 2);

  const uint8_t* data_y = buffer;
  const uint8_t* data_u = buffer + size_y;
  const uint8_t* data_v = buffer + size_y + size_u;

  webrtc::scoped_refptr<webrtc::I420Buffer> i420_buffer = webrtc::I420Buffer::Copy(
      width, height, data_y, stride_y, data_u, stride_uv, data_v, stride_uv);

  scoped_refptr<VideoFrameBufferImpl> frame =
      scoped_refptr<VideoFrameBufferImpl>(
          new RefCountedObject<VideoFrameBufferImpl>(i420_buffer));
  return frame;
}

scoped_refptr<RTCVideoFrame> RTCVideoFrame::Create(
    int width, int height, const uint8_t* data_y, int stride_y,
    const uint8_t* data_u, int stride_u, const uint8_t* data_v, int stride_v) {
  webrtc::scoped_refptr<webrtc::I420Buffer> i420_buffer = webrtc::I420Buffer::Copy(
      width, height, data_y, stride_y, data_u, stride_u, data_v, stride_v);

  scoped_refptr<VideoFrameBufferImpl> frame =
      scoped_refptr<VideoFrameBufferImpl>(
          new RefCountedObject<VideoFrameBufferImpl>(i420_buffer));
  return frame;
}

}  // namespace libwebrtc
