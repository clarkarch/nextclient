#ifndef LIB_WEBRTC_VIDEO_FRAME_IMPL_HXX
#define LIB_WEBRTC_VIDEO_FRAME_IMPL_HXX

#include "api/video/i420_buffer.h"
#include "api/video/video_frame_buffer.h"
#include "api/video/video_rotation.h"
#include "common_video/include/video_frame_buffer.h"
#include "rtc_video_frame.h"

#include <mutex>

namespace libwebrtc {

class VideoFrameBufferImpl : public RTCVideoFrame {
 public:
  VideoFrameBufferImpl(
      webrtc::scoped_refptr<webrtc::VideoFrameBuffer> frame_buffer);
  VideoFrameBufferImpl(webrtc::scoped_refptr<webrtc::I420Buffer> frame_buffer);

  virtual ~VideoFrameBufferImpl();

  scoped_refptr<RTCVideoFrame> Copy() override;

 public:
  int width() const override;

  int height() const override;

  const uint8_t* DataY() const override;

  const uint8_t* DataU() const override;

  const uint8_t* DataV() const override;

  int StrideY() const override;

  int StrideU() const override;

  int StrideV() const override;

  int ConvertToARGB(Type type, uint8_t* dst_argb, int dst_stride_argb,
                    int dest_width, int dest_height) override;

  const void* NativeDmaBufHandle() const override;

  const void* NativeD3D11Handle() const override;

  webrtc::scoped_refptr<webrtc::VideoFrameBuffer> buffer() { return buffer_; }

  // System monotonic clock, same timebase as webrtc::TimeMicros().
  int64_t timestamp_us() const { return timestamp_us_; }
  void set_timestamp_us(int64_t timestamp_us) { timestamp_us_ = timestamp_us; }

  virtual RTCVideoFrame::VideoRotation rotation() override;

  webrtc::VideoRotation rtc_rotation() const { return rotation_; }

  void set_rotation(webrtc::VideoRotation rotation) { rotation_ = rotation; }

  // Cached CPU view of a kNative buffer. DataY/U/V + Stride* must not call
  // ToI420() per accessor: for kNative that conversion allocates + converts
  // per call (6x per frame) and the returned pointer would dangle once the
  // temporary scoped_refptr is released. The cache converts at most once per
  // frame object (buffer_ never changes after construction). kNative D3D11
  // frames have no CPU view (ToI420() returns nullptr, cached once via the
  // flag) — use the GPU renderer with those.
  webrtc::scoped_refptr<webrtc::I420BufferInterface> GetCachedI420() const;

 private:
  webrtc::scoped_refptr<webrtc::VideoFrameBuffer> buffer_;
  int64_t timestamp_us_ = 0;
  webrtc::VideoRotation rotation_ = webrtc::kVideoRotation_0;
  mutable std::mutex i420_mu_;
  mutable webrtc::scoped_refptr<webrtc::I420BufferInterface> i420_cache_;
  mutable bool i420_ready_ = false;
};

}  // namespace libwebrtc

#endif  // LIB_WEBRTC_VIDEO_FRAME_IMPL_HXX
