// dmabuf_video_buffer.h
//
// A webrtc::VideoFrameBuffer whose storage is a set of DRM prime fds exported
// from a VAAPI NV12 surface (see vaapi_video_decoder.cc OnSample). type() is
// kNative: there is no CPU pixel data until ToI420() is called. The GL
// renderer reads the fd/stride/modifier descriptor via
// RTCVideoFrame::NativeDmaBufHandle() and imports the fds as EGLImages —
// decode → composite with zero CPU copies.
//
// The buffer holds a GstBuffer ref (gst_buffer_ref) so the VA surface is not
// recycled while the raster thread still samples it. GetI420() returns nullptr
// (it is native; there is no trivial I420 view). ToI420() is the CPU fallback
// (map + NV12→I420) used by sinks that cannot handle kNative, e.g. the stock
// CPU FlutterVideoRenderer or recording.
#ifndef LIBWEBRTC_SRC_DMABUF_VIDEO_BUFFER_H_
#define LIBWEBRTC_SRC_DMABUF_VIDEO_BUFFER_H_

#include <gst/gst.h>
#include <gst/video/video-frame.h>
#include <gst/video/video-info.h>

#include <cstdint>

#include "api/scoped_refptr.h"
#include "api/video/i420_buffer.h"
#include "api/video/video_frame_buffer.h"
#include "rtc_video_frame.h"

namespace libwebrtc {

// kNative dmabuf frame envelope (VAAPI zero-copy path). The fds are owned by
// this object and closed on destruction (the EGL import dups them, so closing
// after the raster thread imported is safe). The GstBuffer ref keeps the VA
// surface alive for the whole lifetime of the frame.
class DmaBufVideoBuffer : public webrtc::VideoFrameBuffer {
 public:
  DmaBufVideoBuffer(int y_fd, int uv_fd, int y_offset, int uv_offset,
                    int y_pitch, int uv_pitch, int width, int height,
                    uint32_t fourcc, uint64_t modifier, GstBuffer* buffer,
                    const GstVideoInfo& info);

  ~DmaBufVideoBuffer() override;

  webrtc::VideoFrameBuffer::Type type() const override {
    return webrtc::VideoFrameBuffer::Type::kNative;
  }

  int width() const override { return width_; }
  int height() const override { return height_; }

  // Native frame — no trivial I420 view. Consumers that need CPU pixels must
  // call ToI420() (slow path).
  const webrtc::I420BufferInterface* GetI420() const override { return nullptr; }

  // CPU fallback: maps the held GstBuffer (GST_MAP_READ) and converts
  // NV12 → I420 in a single pass. Used by sinks that cannot handle kNative.
  webrtc::scoped_refptr<webrtc::I420BufferInterface> ToI420() override;

  // Returns the ABI-stable descriptor the GL renderer imports.
  const RtcDmaBufDescriptor* dma_buf() const { return &desc_; }

 private:
  RtcDmaBufDescriptor desc_;
  int width_ = 0;
  int height_ = 0;
  GstBuffer* buffer_;  // owned ref; keeps the VA surface alive
  GstVideoInfo info_;
};

}  // namespace libwebrtc

#endif  // LIBWEBRTC_SRC_DMABUF_VIDEO_BUFFER_H_
