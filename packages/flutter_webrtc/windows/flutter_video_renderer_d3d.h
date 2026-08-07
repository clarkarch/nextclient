// flutter_video_renderer_d3d.h
//
// GPU-resident video renderer for the Windows embedder.
//
// The stock FlutterVideoRenderer converts every decoded frame to ARGB on the
// CPU (libyuv ConvertToARGB, 4 B/px) and hands Flutter a CPU pixel buffer that
// the engine re-uploads with glTexSubImage2D (another 4 B/px over PCIe). That
// full-screen CPU convert + upload is what capped the stream at 28–33 UI fps
// while decode kept up at 59 (issue #1). This renderer instead registers a
// flutter::GpuSurfaceTexture (kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle):
// a plugin-owned D3D11 shared texture that the engine's ANGLE compositor binds
// with EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE and composites directly — zero
// CPU readback. The Y/U/V planes are uploaded once (1.5 B/px) and the YUV→RGB
// chroma upsampling runs in an HLSL pixel shader on our D3D11 device, exactly
// the Linux GL renderer's design (the same A/B switch, OPENNOW_RENDERER=gl).
//
// Enabled per-session via the OPENNOW_RENDERER=gl environment variable (the
// A/B switch; anything else keeps the CPU ConvertToARGB path). The D3D11
// device, shaders and RGBA output texture are per-process statics (the device
// context is only touched on the raster thread inside ObtainDescriptor, so a
// shared context is safe).
#ifndef FLUTTER_WEBRTC_RTC_VIDEO_RENDERER_D3D_HXX
#define FLUTTER_WEBRTC_RTC_VIDEO_RENDERER_D3D_HXX

#include <wrl/client.h>  // Microsoft::WRL::ComPtr

// windows.h MUST come before d3d11.h: the D3D headers use HANDLE/HRESULT/UINT
// but do not include windows.h themselves, and this header is pulled into the
// platform-neutral common TUs (flutter_video_renderer.cc) whose include chain
// does not otherwise guarantee it.
#include <windows.h>

#include <d3d11.h>
#include <dxgi.h>

#include <mutex>
#include <string>

#include "flutter_common.h"
#include "flutter_webrtc_base.h"

#include "rtc_video_frame.h"
#include "rtc_video_renderer.h"

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

// Renders decoded video frames GPU-side. Mirrors FlutterVideoRenderer's track
// / event-channel contract (RTCVideoRenderer, SetVideoTrack, media_stream_id)
// so the existing Dart texture plumbing (RTCVideoView, Texture widget) works
// unchanged; only the pixel delivery differs (D3D11 shared texture vs CPU
// pixel buffer).
class FlutterVideoRendererD3D
    : public RTCVideoRenderer<scoped_refptr<RTCVideoFrame>>,
      public RefCountInterface {
 public:
  FlutterVideoRendererD3D() = default;
  ~FlutterVideoRendererD3D();

  void initialize(TextureRegistrar* registrar,
                  BinaryMessenger* messenger,
                  TaskRunner* task_runner,
                  std::unique_ptr<flutter::TextureVariant> texture,
                  int64_t texture_id);

  // Runs on the Flutter raster thread on every composite. Converts the latest
  // frame YUV→RGB into the shared D3D11 texture and returns its descriptor;
  // the engine binds it via EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE and draws it
  // with no CPU readback. Returns nullptr before the first decoded frame
  // (the engine skips that composite).
  const FlutterDesktopGpuSurfaceDescriptor* ObtainDescriptor(size_t width,
                                                             size_t height);

  virtual void OnFrame(scoped_refptr<RTCVideoFrame> frame) override;

  void SetVideoTrack(scoped_refptr<RTCVideoTrack> track);

  int64_t texture_id() { return texture_id_; }

  bool CheckMediaStream(std::string mediaId);

  bool CheckVideoTrack(std::string mediaId);

  std::string media_stream_id;

  // The currently attached video track, so the Dart renderer watchdog can
  // re-attach it to the CPU renderer after a D3D11 -> CPU texture swap
  // (VideoRendererSwitchToCpu). Null until SetVideoTrack is called.
  scoped_refptr<RTCVideoTrack> video_track() const { return track_; }

  // Reads the OPENNOW_RENDERER env var: "gl" opts into the GPU renderer.
  static bool IsEnabled();

 private:
  struct FrameSize {
    size_t width;
    size_t height;
  };

  // (Re)creates the plane textures + shared RGBA render target for the given
  // size on the process-wide D3D11 device. Raster thread only.
  bool EnsureResources(int width, int height);

  // Uploads the I420 planes and runs the YUV→RGB shader into rgba_tex_.
  bool RenderI420Frame(const uint8_t* y,
                       int y_stride,
                       const uint8_t* u,
                       int u_stride,
                       const uint8_t* v,
                       int v_stride,
                       int width,
                       int height);

#if defined(LIBWEBRTC_D3D11_CUSTOM)
  // Zero-copy path for a custom libwebrtc build (see d3d11_patch/): opens the
  // decoder's NV12 shared texture on our device and composites it through the
  // NV12 shader — decode → composite with no CPU copy at all.
  bool RenderNativeFrame(const RtcD3D11TextureDescriptor* desc,
                         int width,
                         int height);
#endif

  // Fills descriptor_ with the current shared texture + frame size.
  void FillDescriptor(int width, int height);

  // Raster-thread timing for ObtainDescriptor(): how long the GPU pass really
  // takes, logged once per second when renderer logging is enabled.
  void MaybeLogRasterStats();
  void LogPath(const char* path);

  // Frame cache: the engine re-composites the scene for UI repaints (stats
  // overlay tick, session timer, chrome hover) that carry the SAME decoded
  // frame. Re-running the full-screen YUV→RGB pass for those wastes raster
  // time — return the already-rendered texture instead. Only touched on the
  // raster thread.
  scoped_refptr<RTCVideoFrame> last_rendered_frame_;
  int last_rendered_width_ = 0;
  int last_rendered_height_ = 0;
  bool rendered_once_ = false;

  uint64_t raster_frames_ = 0;
  double raster_total_ms_ = 0;
  double raster_max_ms_ = 0;
  uint64_t raster_cache_hits_ = 0;
  double raster_last_log_at_ = 0;  // steady_clock seconds

  // One-shot diagnostics: logs which compositing path actually ran (D3D11
  // shared texture vs YUV plane upload) so a laggy session can be blamed on
  // the right sub-path instead of on decode.
  bool path_reported_ = false;

  // Track / event state (mirrors FlutterVideoRenderer).
  FrameSize last_frame_size_ = {0, 0};
  bool first_frame_rendered = false;

  TextureRegistrar* registrar_ = nullptr;
  std::unique_ptr<EventChannelProxy> event_channel_;
  int64_t texture_id_ = -1;
  scoped_refptr<RTCVideoTrack> track_ = nullptr;
  scoped_refptr<RTCVideoFrame> frame_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  std::mutex mutex_;
  RTCVideoFrame::VideoRotation rotation_ = RTCVideoFrame::kVideoRotation_0;

  // D3D11 objects. Touched only on the raster thread inside ObtainDescriptor
  // (single-threaded device context). The textures are reallocated in place on
  // size change and live until the renderer is disposed; the engine never
  // calls ObtainDescriptor after unregister, so deleting them from the
  // destructor (which can run on any thread) is safe — by then the engine has
  // released the shared texture.
  Microsoft::WRL::ComPtr<ID3D11Texture2D> y_tex_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> u_tex_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> v_tex_;
  Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> y_srv_;
  Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> u_srv_;
  Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> v_srv_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> rgba_tex_;
  Microsoft::WRL::ComPtr<ID3D11RenderTargetView> rgba_rtv_;
  HANDLE shared_handle_ = nullptr;  // owned by rgba_tex_ (never CloseHandle)
  int d3d_width_ = 0;
  int d3d_height_ = 0;

#if defined(LIBWEBRTC_D3D11_CUSTOM)
  Microsoft::WRL::ComPtr<ID3D11Texture2D> native_tex_;
  Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> nv12_y_srv_;
  Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> nv12_uv_srv_;
#endif

  // One pre-filled descriptor handed to the engine each composite. Only the
  // raster thread writes it; the decode thread never touches it.
  FlutterDesktopGpuSurfaceDescriptor descriptor_ = {};
};

// Process-wide D3D11 device + shaders, shared by every D3D renderer (created
// once, never deleted — like the Linux GL renderer's GlQuad). All use happens
// on the raster thread inside ObtainDescriptor.
struct D3d11Quad {
  Microsoft::WRL::ComPtr<ID3D11Device> device;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx;
  Microsoft::WRL::ComPtr<ID3D11VertexShader> vs;
  Microsoft::WRL::ComPtr<ID3D11PixelShader> ps_i420;
  Microsoft::WRL::ComPtr<ID3D11PixelShader> ps_nv12;
  Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler;
  bool compiled = false;
  // Which D3D_DRIVER_TYPE actually created the device (hardware or WARP), so
  // the self-test can open the shared handle on a matching second device.
  D3D_DRIVER_TYPE driver_type = D3D_DRIVER_TYPE_HARDWARE;
  char compile_error[512] = {0};
};

D3d11Quad* d3d11_quad();

// Verifies the D3D11 GPU renderer can actually produce a compositable shared
// texture BEFORE the renderer is chosen at texture creation: creates the
// device + compiles the shaders, makes a small shared RGBA texture, and opens
// the shared handle on a second device of the same driver type (hardware or
// WARP). On failure the caller falls back to the CPU pixel-buffer renderer so
// the stream stays visible instead of going black, and the reason is recorded
// via renderer_status_set_error() for the Dart watchdog's getRendererStatus.
//
// Threading: runs on the platform thread at texture creation, which is
// serialized with the raster thread's first ObtainDescriptor (texture creation
// happens before any frame flows), so it is safe to (re)initialize the shared
// D3d11Quad device/context here. Do not call it from the raster thread or
// while a stream is actively compositing.
bool D3d11RendererSelfTest();

// --- Renderer health status (read by the Dart renderer watchdog) ------------
// The backend reflects what CreateVideoRendererTexture actually created; the
// composited counter proves frames are being PRESENTED (not just decoded — a
// D3D11 renderer can decode fine while the engine composites nothing, which
// is the black-screen case).
void renderer_status_set_backend(const char* backend);  // "d3d11" | "cpu"
void renderer_status_set_error(const char* error);      // null clears
void renderer_status_mark_composited();
const char* renderer_status_backend();
uint64_t renderer_status_composited();
std::string renderer_status_error();

}  // namespace flutter_webrtc_plugin

// ---------------------------------------------------------------------------
// Renderer logging gate. The [d3drender] diagnostics are funneled here so the
// Dart app can silence them from settings (the Verbose-logs toggle) the same
// way it silences the in-app LogSink and the Linux GL renderer's [glrender]
// logs. Default off — the per-frame raster stats and one-shot notices are
// debug-only noise in a release build.
// ---------------------------------------------------------------------------
namespace flutter_webrtc_plugin {
void set_renderer_logging_enabled(bool enabled);
bool renderer_logging_enabled();
}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_RTC_VIDEO_RENDERER_D3D_HXX
