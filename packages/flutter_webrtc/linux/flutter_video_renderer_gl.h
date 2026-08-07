// flutter_video_renderer_gl.h
//
// GPU-resident video renderer for the Linux embedder.
//
// The stock FlutterVideoRenderer converts every decoded frame to ARGB on the
// CPU (libyuv ConvertToARGB) and hands Flutter a CPU pixel buffer that the
// engine re-uploads with glTexSubImage2D. This renderer instead registers an
// FlTextureGL: a plugin-owned OpenGL texture that the engine composites
// directly (the Linux embedder samples it and shares it via EGLImage), so the
// only CPU→GPU traffic is the small Y/U/V plane upload (1.5 B/px) and the
// YUV→RGB chroma upsampling happens in a fragment shader — the same design as
// OpenNOW's yuvProgram/drawRgb on Android, wired into Flutter's Linux
// texture/engine path.
//
// Enabled per-session via the OPENNOW_RENDERER=gl environment variable (the
// A/B switch; anything else keeps the CPU ConvertToARGB path).
#ifndef FLUTTER_WEBRTC_RTC_VIDEO_RENDERER_GL_HXX
#define FLUTTER_WEBRTC_RTC_VIDEO_RENDERER_GL_HXX

#include <epoxy/gl.h>
#include <flutter_linux/flutter_linux.h>

#include <mutex>

#include "flutter_common.h"
#include "flutter_webrtc_base.h"

#include "rtc_video_frame.h"
#include "rtc_video_renderer.h"

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

// GObject subclass of FlTextureGL. The engine calls populate() on its raster
// thread with the Flutter GL context already current; we render the latest
// frame's Y/U/V planes through the YUV→RGB shader into an RGBA8 texture and
// hand that texture back to the engine for direct composition.
typedef struct _FlShaderTextureGL {
  FlTextureGL parent_instance;
  class FlutterVideoRendererGL* renderer;
} FlShaderTextureGL;

typedef struct _FlShaderTextureGLClass {
  FlTextureGLClass parent_class;
} FlShaderTextureGLClass;

GType fl_shader_texture_gl_get_type(void);

#define FL_SHADER_TEXTURE_GL(obj)                                        \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), fl_shader_texture_gl_get_type(),    \
                              FlShaderTextureGL))
#define FL_SHADER_TEXTURE_GL_CLASS(klass)                                \
  (G_TYPE_CHECK_CLASS_CAST((klass), fl_shader_texture_gl_get_type(),     \
                           FlShaderTextureGLClass))
#define FL_IS_SHADER_TEXTURE_GL(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_TYPE((obj), fl_shader_texture_gl_get_type()))

// Renders decoded video frames GPU-side. Mirrors FlutterVideoRenderer's track
// / event-channel contract (RTCVideoRenderer, SetVideoTrack, media_stream_id)
// so the existing Dart texture plumbing (RTCVideoView, Texture widget) works
// unchanged; only the pixel delivery differs (GL texture vs CPU pixel buffer).
class FlutterVideoRendererGL
    : public RTCVideoRenderer<scoped_refptr<RTCVideoFrame>>,
      public RefCountInterface {
 public:
  FlutterVideoRendererGL() = default;
  ~FlutterVideoRendererGL();

  void initialize(BinaryMessenger* messenger,
                  TaskRunner* task_runner,
                  FlTextureRegistrar* raw_registrar,
                  int64_t texture_id);

  // Takes a reference on the registered FlShaderTextureGL so OnFrame can mark
  // the texture dirty and dispose can unregister it without a registrar lookup
  // (fl_texture_registrar_lookup_texture is not in the public C API).
  void SetTextureHandle(FlShaderTextureGL* texture);

  // Unregisters the engine-side texture and releases our GObject reference.
  // Called from VideoRendererDispose before the renderer map entry is erased.
  // Takes the mutex so it can't race an in-flight OnFrame that is marking the
  // texture dirty.
  void UnregisterFromEngine(FlTextureRegistrar* raw_registrar);

  // Runs on the Flutter raster thread with the engine GL context current.
  // Renders the latest frame into an RGBA8 texture and returns its name.
  virtual const uint32_t* Populate(uint32_t* target,
                                   uint32_t* name,
                                   uint32_t* width,
                                   uint32_t* height);

  virtual void OnFrame(scoped_refptr<RTCVideoFrame> frame) override;

  void SetVideoTrack(scoped_refptr<RTCVideoTrack> track);

  int64_t texture_id() { return texture_id_; }

  bool CheckMediaStream(std::string mediaId);

  bool CheckVideoTrack(std::string mediaId);

  std::string media_stream_id;

  // Reads the OPENNOW_RENDERER env var: "gl" opts into the GPU renderer.
  static bool IsEnabled();

 private:
  struct FrameSize {
    size_t width;
    size_t height;
  };

  bool EnsureGlResources(int width, int height);
  bool CompileShaderProgram();
  bool CompileNv12ShaderProgram();
  void UploadAndRenderFrame(const uint8_t* y,
                            int y_stride,
                            const uint8_t* u,
                            int u_stride,
                            const uint8_t* v,
                            int v_stride,
                            int width,
                            int height);

  // Zero-copy dmabuf path: imports the two DRM prime fds (Y + interleaved UV,
  // NV12) as EGLImages and renders them through the NV12 shader into rgb_tex_.
  // Returns false when EGL dma-buf import is unavailable (GLX compositor, no
  // EGL_EXT_image_dma_buf_import, or a failed import) — Populate() then falls
  // back to the CPU UploadAndRenderFrame path. `desc` is owned by the frame and
  // stays valid for the whole call (the DmaBufVideoBuffer holds a GstBuffer ref
  // that keeps the VA surface alive while we sample it).
  bool ImportAndRenderDmaBuf(const RtcDmaBufDescriptor* desc,
                             int width,
                             int height);

  // Frame cache: the engine invokes populate() on every scene composite,
  // including repaints that carry no new video frame (stats-overlay tick,
  // session timer, chrome hover). When the same frame object is re-presented,
  // return the already-rendered RGB texture instead of re-running the
  // full-screen YUV->RGB pass AND the ~20-call GL state save/restore — on a
  // weak iGPU that redundant pass is real raster-thread time that directly
  // lowers UI fps. Only touched on the raster thread (populate()).
  scoped_refptr<RTCVideoFrame> last_rendered_frame_;
  int last_rendered_width_ = 0;
  int last_rendered_height_ = 0;
  bool rendered_once_ = false;

  // Raster-thread timing for populate(): how long the GPU pass really takes,
  // logged once per second. Splits "GPU can't composite" from "present/vsync
  // is the wall" so a laggy session can be blamed on the right half.
  uint64_t raster_frames_ = 0;
  double raster_total_ms_ = 0;
  double raster_max_ms_ = 0;
  uint64_t raster_cache_hits_ = 0;
  double raster_last_log_at_ = 0;  // steady_clock seconds

  // Logs avg/max populate() time once per second (raster thread only).
  void MaybeLogRasterStats();

  // Track / event state (mirrors FlutterVideoRenderer).
  FrameSize last_frame_size_ = {0, 0};
  bool first_frame_rendered = false;

  // One-shot diagnostics: logs which compositing path actually ran (dmabuf
  // EGL import vs YUV plane upload) so a laggy session can be blamed on the
  // right sub-path instead of on decode.
  bool path_reported_ = false;
  FlTextureRegistrar* raw_registrar_ = nullptr;
  FlShaderTextureGL* texture_ = nullptr;
  std::unique_ptr<EventChannelProxy> event_channel_;
  int64_t texture_id_ = -1;
  scoped_refptr<RTCVideoTrack> track_ = nullptr;
  scoped_refptr<RTCVideoFrame> frame_;
  std::mutex mutex_;
  RTCVideoFrame::VideoRotation rotation_ = RTCVideoFrame::kVideoRotation_0;

  // GL objects. The program + quad are process-wide statics (compiled once,
  // shared by every GL renderer); the textures/FBO are per-renderer and
  // reallocated in place on size change. All of them live for the process
  // lifetime — the engine context is only current on the raster thread during
  // populate(), so deleting them from the platform thread would be unsafe, and
  // the engine never calls populate() after unregister.
  GLuint y_tex_ = 0;
  GLuint u_tex_ = 0;
  GLuint v_tex_ = 0;
  GLuint uv_tex_ = 0;  // NV12 interleaved UV plane (dmabuf path)
  GLuint rgb_tex_ = 0;
  GLuint fbo_ = 0;
  int gl_width_ = 0;
  int gl_height_ = 0;
};

// Process-wide GL program + fullscreen quad, shared by all GL renderers.
// (Declared here so both the class above and the .cc can use them.)
struct GlQuad {
  // I420 (3-texture) program used by the CPU upload path.
  GLuint program = 0;
  GLuint vao = 0;
  GLuint vbo = 0;
  GLint uniform_y = -1;
  GLint uniform_u = -1;
  GLint uniform_v = -1;
  bool compiled = false;

  // NV12 (2-texture) program used by the zero-copy dmabuf EGLImage path.
  GLuint program_nv12 = 0;
  GLint uniform_y_nv12 = -1;
  GLint uniform_uv_nv12 = -1;
  bool nv12_compiled = false;
};

GlQuad* gl_quad();

// ---- GObject wiring --------------------------------------------------------

inline FlShaderTextureGL* fl_shader_texture_gl_new(
    FlutterVideoRendererGL* renderer) {
  FlShaderTextureGL* self = FL_SHADER_TEXTURE_GL(
      g_object_new(fl_shader_texture_gl_get_type(), nullptr));
  self->renderer = renderer;
  return self;
}

}  // namespace flutter_webrtc_plugin

// ---------------------------------------------------------------------------
// Renderer logging gate. The [glrender] diagnostics are funneled here so the
// Dart app can silence them from settings (the Verbose-logs toggle) the same
// way it silences the in-app LogSink. Default off — the per-frame raster stats
// and one-shot notices are debug-only noise in a release build.
// ---------------------------------------------------------------------------
namespace flutter_webrtc_plugin {
void set_renderer_logging_enabled(bool enabled);
bool renderer_logging_enabled();
}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_RTC_VIDEO_RENDERER_GL_HXX
