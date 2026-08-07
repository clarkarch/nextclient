#ifndef LIB_WEBRTC_RTC_VIDEO_FRAME_HXX
#define LIB_WEBRTC_RTC_VIDEO_FRAME_HXX

#include <cstdint>

#include "rtc_types.h"

namespace libwebrtc {

// ABI-stable descriptor for the Linux zero-copy VAAPI path. The decoder
// exports the decoded VA surface to two DRM prime fds (Y plane + interleaved
// UV plane, NV12) and the GL renderer imports them as EGLImages, so frames
// travel decode → composite with no CPU copy. Opaque to the RTCVideoFrame ABI;
// the Linux GL renderer casts NativeDmaBufHandle() to this struct. Both sides
// compile against this same header, so the layout is guaranteed to match.
struct RtcDmaBufDescriptor {
  int y_fd = -1;        // DRM prime fd for the Y plane (DRM_FORMAT_R8)
  int uv_fd = -1;       // DRM prime fd for the interleaved UV plane (GR88)
  int y_offset = 0;     // byte offset of the Y plane within y_fd
  int uv_offset = 0;    // byte offset of the UV plane within uv_fd
  int y_pitch = 0;      // bytes per row, Y plane
  int uv_pitch = 0;     // bytes per row, UV plane
  int width = 0;
  int height = 0;
  uint32_t fourcc = 0;    // DRM_FORMAT_NV12
  uint64_t modifier = 0;  // DRM_FORMAT_MOD_LINEAR (0) or driver modifier
};

class RTCVideoFrame : public RefCountInterface {
 public:
  enum class Type { kARGB, kBGRA, kABGR, kRGBA };

  enum VideoRotation {
    kVideoRotation_0 = 0,
    kVideoRotation_90 = 90,
    kVideoRotation_180 = 180,
    kVideoRotation_270 = 270
  };

 public:
  LIB_WEBRTC_API static scoped_refptr<RTCVideoFrame> Create(
      int width, int height, const uint8_t* buffer, int length);

  LIB_WEBRTC_API static scoped_refptr<RTCVideoFrame> Create(
      int width, int height, const uint8_t* data_y, int stride_y,
      const uint8_t* data_u, int stride_u, const uint8_t* data_v, int stride_v);

  virtual scoped_refptr<RTCVideoFrame> Copy() = 0;

  // The resolution of the frame in pixels. For formats where some planes are
  // subsampled, this is the highest-resolution plane.
  virtual int width() const = 0;
  virtual int height() const = 0;

  virtual VideoRotation rotation() = 0;

  // Returns pointer to the pixel data for a given plane. The memory is owned by
  // the VideoFrameBuffer object and must not be freed by the caller.
  virtual const uint8_t* DataY() const = 0;
  virtual const uint8_t* DataU() const = 0;
  virtual const uint8_t* DataV() const = 0;

  // Returns the number of bytes between successive rows for a given plane.
  virtual int StrideY() const = 0;
  virtual int StrideU() const = 0;
  virtual int StrideV() const = 0;

  virtual int ConvertToARGB(Type type, uint8_t* dst_argb, int dst_stride_argb,
                            int dest_width, int dest_height) = 0;

  // Non-null only when the underlying buffer is a kNative dmabuf buffer
  // (VAAPI zero-copy path). Opaque to this ABI; the Linux GL renderer casts it
  // to RtcDmaBufDescriptor. Returns nullptr for I420 frames (FFmpeg path).
  virtual const void* NativeDmaBufHandle() const = 0;

 protected:
  virtual ~RTCVideoFrame() {}
};

}  // namespace libwebrtc

#endif  // LIB_WEBRTC_RTC_VIDEO_FRAME_HXX
