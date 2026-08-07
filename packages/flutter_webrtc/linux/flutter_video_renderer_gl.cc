// flutter_video_renderer_gl.cc
//
// See flutter_video_renderer_gl.h for the design. The heavy lift here is
// running inside the engine's compositor: populate() is invoked on the raster
// thread with Flutter's GL context current, so every GL call below happens in
// the engine's context and we must restore the compositor's GL state when we
// leave.
#include "flutter_video_renderer_gl.h"

#include <epoxy/egl.h>
#include <epoxy/gl.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace flutter_webrtc_plugin {

// ---- Renderer logging gate (Dart toggles via setRendererLoggingEnabled) ----
namespace {
bool g_renderer_logging_enabled = false;
}  // namespace

void set_renderer_logging_enabled(bool enabled) {
  g_renderer_logging_enabled = enabled;
}

bool renderer_logging_enabled() { return g_renderer_logging_enabled; }

// ---------------------------------------------------------------------------
// Shaders (same GLSL dialect as the engine's fl_compositor_opengl shaders so
// they compile on both desktop GL and GLES contexts).
// ---------------------------------------------------------------------------

// Fullscreen triangle strip; the engine composites the RGBA8 result texture
// directly, so the vertex stage only needs clip-space + texcoords (OpenNOW's
// SHARPEN_VERTEX_SHADER).
//
// Orientation: image row 0 (v = 0) is drawn at clip y = -1 (the bottom of the
// FBO), which puts it at RGBA texture row 0. The engine samples external
// textures with texture row 0 = top of the widget (same convention as the CPU
// pixel-buffer path), so this keeps the frame upright.
static const char* kVertexShader =
    "attribute vec2 in_pos;\n"
    "attribute vec2 in_tc;\n"
    "varying vec2 tc;\n"
    "void main() {\n"
    "  gl_Position = vec4(in_pos, 0.0, 1.0);\n"
    "  tc = in_tc;\n"
    "}\n";

// OpenNOW's SHARPEN_YUV_FRAGMENT_SHADER core (no sharpen pass — plain
// YUV→RGB). Y plane is full-res, U/V are half-res; hardware bilinear
// filtering does the chroma upsampling, exactly like Android's drawYuv.
static const char* kFragmentShader =
    "#ifdef GL_ES\n"
    "precision mediump float;\n"
    "#endif\n"
    "uniform sampler2D y_tex;\n"
    "uniform sampler2D u_tex;\n"
    "uniform sampler2D v_tex;\n"
    "varying vec2 tc;\n"
    "void main() {\n"
    "  float y = texture2D(y_tex, tc).r;\n"
    "  float u = texture2D(u_tex, tc).r - 0.5;\n"
    "  float v = texture2D(v_tex, tc).r - 0.5;\n"
    "  gl_FragColor = vec4(\n"
    "    y + 1.403 * v,\n"
    "    y - 0.344 * u - 0.714 * v,\n"
    "    y + 1.770 * u,\n"
    "    1.0\n"
    "  );\n"
    "}\n";

// NV12 variant for the zero-copy dmabuf path: the interleaved UV plane lives
// in one GR88 texture (U in R, V in G) instead of two separate R8 planes.
static const char* kFragmentShaderNv12 =
    "#ifdef GL_ES\n"
    "precision mediump float;\n"
    "#endif\n"
    "uniform sampler2D y_tex;\n"
    "uniform sampler2D uv_tex;\n"
    "varying vec2 tc;\n"
    "void main() {\n"
    "  float y = texture2D(y_tex, tc).r;\n"
    "  float u = texture2D(uv_tex, tc).r - 0.5;\n"
    "  float v = texture2D(uv_tex, tc).g - 0.5;\n"
    "  gl_FragColor = vec4(\n"
    "    y + 1.403 * v,\n"
    "    y - 0.344 * u - 0.714 * v,\n"
    "    y + 1.770 * u,\n"
    "    1.0\n"
    "  );\n"
    "}\n";

// ---------------------------------------------------------------------------
// FlTextureGL GObject
// ---------------------------------------------------------------------------

G_DEFINE_TYPE(FlShaderTextureGL, fl_shader_texture_gl, fl_texture_gl_get_type())

static gboolean fl_shader_texture_gl_populate(FlTextureGL* texture,
                                              uint32_t* target,
                                              uint32_t* name,
                                              uint32_t* width,
                                              uint32_t* height,
                                              GError** error) {
  FlShaderTextureGL* self = FL_SHADER_TEXTURE_GL(texture);
  if (self->renderer == nullptr) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "renderer destroyed");
    return FALSE;
  }
  const uint32_t* tex = self->renderer->Populate(target, name, width, height);
  if (tex == nullptr) {
    // CRITICAL: the engine's gl_external_texture_frame_callback dereferences
    // error->message (g_warning("%s", error->message)) when populate returns
    // FALSE, so a NULL error here is a guaranteed SIGSEGV. The first composite
    // happens before any decoded frame arrives (frame_ == nullptr), so we must
    // always set the error on this path.
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "no frame available yet");
    return FALSE;
  }
  return TRUE;
}

static void fl_shader_texture_gl_class_init(FlShaderTextureGLClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = fl_shader_texture_gl_populate;
}

static void fl_shader_texture_gl_init(FlShaderTextureGL* self) {}

// ---------------------------------------------------------------------------
// Process-wide GL resources (program + fullscreen quad, shared by all GL
// renderers — compiled once, bounded memory, and never deleted because the
// engine GL context is only current on the raster thread during populate()).
// ---------------------------------------------------------------------------

namespace {

GlQuad g_quad;

}  // namespace

GlQuad* gl_quad() { return &g_quad; }

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

FlutterVideoRendererGL::~FlutterVideoRendererGL() {
  // Release our reference to the engine-side GObject. The engine drops its own
  // ref on unregister (before we're destroyed via gl_renderers_.erase), so the
  // GObject is freed after this — no GL work here, which is safe because the
  // engine's GL context may not be current on this thread.
  if (texture_ != nullptr) {
    g_object_unref(texture_);
    texture_ = nullptr;
  }
}

bool FlutterVideoRendererGL::IsEnabled() {
  const char* value = std::getenv("OPENNOW_RENDERER");
  return value != nullptr && std::strcmp(value, "gl") == 0;
}

void FlutterVideoRendererGL::initialize(BinaryMessenger* messenger,
                                        TaskRunner* task_runner,
                                        FlTextureRegistrar* raw_registrar,
                                        int64_t texture_id) {
  raw_registrar_ = raw_registrar;
  texture_id_ = texture_id;
  std::string channel_name =
      "FlutterWebRTC/Texture" + std::to_string(texture_id_);
  event_channel_ =
      EventChannelProxy::Create(messenger, task_runner, channel_name);
}

void FlutterVideoRendererGL::SetTextureHandle(FlShaderTextureGL* texture) {
  if (texture_ == texture) return;
  if (texture_ != nullptr) {
    g_object_unref(texture_);
  }
  texture_ = texture;
  if (texture_ != nullptr) {
    g_object_ref(texture_);
  }
}

void FlutterVideoRendererGL::UnregisterFromEngine(
    FlTextureRegistrar* raw_registrar) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (texture_ == nullptr) return;
  fl_texture_registrar_unregister_texture(raw_registrar,
                                          FL_TEXTURE(texture_));
  g_object_unref(texture_);
  texture_ = nullptr;
}

void FlutterVideoRendererGL::OnFrame(scoped_refptr<RTCVideoFrame> frame) {
  if (!first_frame_rendered) {
    EncodableMap params;
    params[EncodableValue("event")] = "didFirstFrameRendered";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    event_channel_->Success(EncodableValue(params));
    first_frame_rendered = true;
    if (renderer_logging_enabled()) {
      std::fprintf(stderr,
                   "[glrender] first frame received %dx%d (texture %lld)\n",
                   frame->width(), frame->height(),
                   static_cast<long long>(texture_id_));
    }
  }
  if (rotation_ != frame->rotation()) {
    EncodableMap params;
    params[EncodableValue("event")] = "didTextureChangeRotation";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    params[EncodableValue("rotation")] =
        EncodableValue((int32_t)frame->rotation());
    event_channel_->Success(EncodableValue(params));
    rotation_ = frame->rotation();
  }
  if (last_frame_size_.width != frame->width() ||
      last_frame_size_.height != frame->height()) {
    EncodableMap params;
    params[EncodableValue("event")] = "didTextureChangeVideoSize";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    params[EncodableValue("width")] = EncodableValue((int32_t)frame->width());
    params[EncodableValue("height")] = EncodableValue((int32_t)frame->height());
    event_channel_->Success(EncodableValue(params));
    last_frame_size_ = {(size_t)frame->width(), (size_t)frame->height()};
  }
  FlTextureRegistrar* raw = nullptr;
  FlShaderTextureGL* tex = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    frame_ = frame;
    // Snapshot the GObject under the lock, taking our own ref so an in-flight
    // frame can't race UnregisterFromEngine freeing it mid-call. The C API
    // call itself happens outside the lock.
    if (raw_registrar_ != nullptr && texture_ != nullptr) {
      raw = raw_registrar_;
      tex = texture_;
      g_object_ref(tex);
    }
  }
  if (raw != nullptr && tex != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(raw, FL_TEXTURE(tex));
    g_object_unref(tex);
  }
}

void FlutterVideoRendererGL::SetVideoTrack(scoped_refptr<RTCVideoTrack> track) {
  if (track_ != track) {
    if (track_)
      track_->RemoveRenderer(this);
    track_ = track;
    last_frame_size_ = {0, 0};
    first_frame_rendered = false;
    if (track_) {
      track_->AddRenderer(this);
      if (renderer_logging_enabled()) {
        std::fprintf(stderr, "[glrender] video track attached (id=%s)\n",
                     track_->id().std_string().c_str());
      }
    } else if (renderer_logging_enabled()) {
      std::fprintf(stderr, "[glrender] video track detached\n");
    }
  }
}

bool FlutterVideoRendererGL::CheckMediaStream(std::string mediaId) {
  if (0 == mediaId.size() || 0 == media_stream_id.size()) {
    return false;
  }
  return mediaId == media_stream_id;
}

bool FlutterVideoRendererGL::CheckVideoTrack(std::string mediaId) {
  if (0 == mediaId.size() || !track_) {
    return false;
  }
  return mediaId == track_->id().std_string();
}

const uint32_t* FlutterVideoRendererGL::Populate(uint32_t* target,
                                                 uint32_t* name,
                                                 uint32_t* width,
                                                 uint32_t* height) {
  // NOTE: runs on the Flutter raster thread with the engine GL context
  // current. We must not hold the mutex across GL work that could block
  // OnFrame; grab the frame ref, then render outside the lock.
  scoped_refptr<RTCVideoFrame> frame;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    frame = frame_;
  }
  if (!frame.get() || frame->width() <= 0 || frame->height() <= 0) {
    return nullptr;
  }
  const int w = frame->width();
  const int h = frame->height();

  // Frame cache: the engine re-composites the scene for UI repaints (stats
  // overlay tick, session timer, chrome hover) that carry the SAME decoded
  // frame. Re-running the full-screen YUV→RGB pass + ~20 GL state queries for
  // those costs real raster-thread time on a weak iGPU — return the
  // already-rendered texture untouched instead (the engine samples rgb_tex_
  // again as-is). The frame pointer is the identity key: every decoded frame
  // is a new RTCVideoFrame object, and OnFrame swaps frame_ per video frame.
  if (rendered_once_ && last_rendered_frame_ == frame &&
      last_rendered_width_ == w && last_rendered_height_ == h) {
    raster_cache_hits_++;
    *target = GL_TEXTURE_2D;
    *name = rgb_tex_;
    *width = w;
    *height = h;
    return name;
  }

  // Snapshot the compositor's GL state BEFORE we touch anything, and restore
  // it on every exit path. populate() runs mid-frame inside the engine's
  // compositor, which relies on its own bindings.
  GLint saved_unpack_row_length = 0;
  GLint saved_unpack_alignment = 4;
  glGetIntegerv(GL_UNPACK_ROW_LENGTH, &saved_unpack_row_length);
  glGetIntegerv(GL_UNPACK_ALIGNMENT, &saved_unpack_alignment);
  GLint saved_fbo = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved_fbo);
  GLint saved_viewport[4] = {0};
  glGetIntegerv(GL_VIEWPORT, saved_viewport);
  GLint saved_program = 0;
  glGetIntegerv(GL_CURRENT_PROGRAM, &saved_program);
  GLint saved_active_texture = 0;
  glGetIntegerv(GL_ACTIVE_TEXTURE, &saved_active_texture);
  GLint saved_texture_2d[3] = {0, 0, 0};
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &saved_texture_2d[0]);
  glActiveTexture(GL_TEXTURE1);
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &saved_texture_2d[1]);
  glActiveTexture(GL_TEXTURE2);
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &saved_texture_2d[2]);
  glActiveTexture(saved_active_texture);
  GLint saved_vao = 0;
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &saved_vao);
  GLboolean saved_blend = glIsEnabled(GL_BLEND);
  GLboolean saved_scissor = glIsEnabled(GL_SCISSOR_TEST);

  // Time the WHOLE raster-thread pass, including the state save above and the
  // restore below — on a weak APU the ~20 glGet*/glIsEnabled state queries can
  // be the actual CPU cost, so excluding them would report a misleadingly
  // small "raster" number and misattribute the wall to present/vsync.
  const auto t_render_start = std::chrono::steady_clock::now();
  const bool ok = EnsureGlResources(w, h);
  if (ok) {
    // Zero-copy path first: if the frame carries a dmabuf descriptor (VAAPI
    // kNative buffer), import the prime fds as EGLImages and composite with no
    // CPU copy. Falls back to the I420 upload when import is unavailable
    // (GLX compositor, no EGL dma-buf extension, driver import failure) or the
    // frame is plain I420 (FFmpeg path).
    const void* native = frame->NativeDmaBufHandle();
    bool rendered = false;
    if (native != nullptr) {
      const RtcDmaBufDescriptor* desc =
          static_cast<const RtcDmaBufDescriptor*>(native);
      rendered = ImportAndRenderDmaBuf(desc, w, h);
    }
    if (!rendered) {
      UploadAndRenderFrame(frame->DataY(), frame->StrideY(), frame->DataU(),
                           frame->StrideU(), frame->DataV(), frame->StrideV(), w,
                           h);
    }
    if (!path_reported_) {
      path_reported_ = true;
      if (renderer_logging_enabled()) {
        std::fprintf(stderr, "[glrender] compositing via %s\n",
                     rendered ? "zero-copy dmabuf EGL import"
                              : "YUV plane upload (CPU readback)");
      }
    }
    // Frame-cache bookkeeping (only on success; timing is taken over the whole
    // pass after the state restore below).
    last_rendered_frame_ = frame;
    last_rendered_width_ = w;
    last_rendered_height_ = h;
    rendered_once_ = true;
  }

  // Restore the engine's GL state.
  glPixelStorei(GL_UNPACK_ROW_LENGTH, saved_unpack_row_length);
  glPixelStorei(GL_UNPACK_ALIGNMENT, saved_unpack_alignment);
  glBindFramebuffer(GL_FRAMEBUFFER, saved_fbo);
  glViewport(saved_viewport[0], saved_viewport[1], saved_viewport[2],
             saved_viewport[3]);
  glUseProgram(saved_program);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, saved_texture_2d[0]);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, saved_texture_2d[1]);
  glActiveTexture(GL_TEXTURE2);
  glBindTexture(GL_TEXTURE_2D, saved_texture_2d[2]);
  glActiveTexture(saved_active_texture);
  glBindVertexArray(saved_vao);
  if (saved_blend) {
    glEnable(GL_BLEND);
  } else {
    glDisable(GL_BLEND);
  }
  if (saved_scissor) {
    glEnable(GL_SCISSOR_TEST);
  } else {
    glDisable(GL_SCISSOR_TEST);
  }

  // Full pass duration (state save → render → restore), fed into the per-second
  // [glrender] raster log.
  if (ok) {
    const auto t_render_end = std::chrono::steady_clock::now();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(
                                  t_render_end - t_render_start)
                                  .count();
    raster_frames_++;
    raster_total_ms_ += elapsed_ms;
    if (elapsed_ms > raster_max_ms_) raster_max_ms_ = elapsed_ms;
    MaybeLogRasterStats();
  }

  if (!ok) {
    return nullptr;
  }
  *target = GL_TEXTURE_2D;
  *name = rgb_tex_;
  *width = w;
  *height = h;
  return name;
}

bool FlutterVideoRendererGL::EnsureGlResources(int width, int height) {
  GlQuad* quad = gl_quad();
  if (!quad->compiled && !CompileShaderProgram()) {
    return false;
  }

  const bool size_changed = gl_width_ != width || gl_height_ != height;
  const int uv_w = (width + 1) / 2;
  const int uv_h = (height + 1) / 2;

  // Y/U/V plane textures. Created once; reallocated in place on size change.
  // uv_tex_ holds the interleaved NV12 UV plane on the dmabuf path (its
  // storage is redefined by glEGLImageTargetTexture2DOES each frame, so it only
  // needs creation + sampler params here).
  if (y_tex_ == 0) {
    glGenTextures(1, &y_tex_);
  }
  glBindTexture(GL_TEXTURE_2D, y_tex_);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  if (u_tex_ == 0) {
    glGenTextures(1, &u_tex_);
  }
  glBindTexture(GL_TEXTURE_2D, u_tex_);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  if (v_tex_ == 0) {
    glGenTextures(1, &v_tex_);
  }
  glBindTexture(GL_TEXTURE_2D, v_tex_);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  if (uv_tex_ == 0) {
    glGenTextures(1, &uv_tex_);
  }
  glBindTexture(GL_TEXTURE_2D, uv_tex_);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  // RGBA8 render target + FBO.
  if (rgb_tex_ == 0) {
    glGenTextures(1, &rgb_tex_);
    glBindTexture(GL_TEXTURE_2D, rgb_tex_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  }
  if (fbo_ == 0) {
    glGenFramebuffers(1, &fbo_);
  }

  if (size_changed) {
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glBindTexture(GL_TEXTURE_2D, y_tex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, width, height, 0, GL_RED,
                 GL_UNSIGNED_BYTE, nullptr);
    glBindTexture(GL_TEXTURE_2D, u_tex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, uv_w, uv_h, 0, GL_RED,
                 GL_UNSIGNED_BYTE, nullptr);
    glBindTexture(GL_TEXTURE_2D, v_tex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, uv_w, uv_h, 0, GL_RED,
                 GL_UNSIGNED_BYTE, nullptr);
    glBindTexture(GL_TEXTURE_2D, rgb_tex_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, nullptr);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           rgb_tex_, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
      std::fprintf(stderr,
                   "[flutter_webrtc] GL renderer: FBO incomplete after "
                   "resize (%#x)\n",
                   glCheckFramebufferStatus(GL_FRAMEBUFFER));
      return false;
    }
    gl_width_ = width;
    gl_height_ = height;
  }

  // Fullscreen quad VAO/VBO (GL 3.2 core profile needs a VAO bound). Shared
  // process-wide so it is created once, not per renderer.
  if (quad->vao == 0) {
    // v = 0 (image top) at the BOTTOM of the FBO so the RGBA texture ends up
    // row-0 = image-top, matching what the engine's texture sampling expects.
    const float vertices[] = {
        // x,    y,    u,    v
        -1.0f, -1.0f, 0.0f, 0.0f,  //
        1.0f,  -1.0f, 1.0f, 0.0f,  //
        -1.0f, 1.0f,  0.0f, 1.0f,  //
        1.0f,  1.0f,  1.0f, 1.0f,  //
    };
    glGenVertexArrays(1, &quad->vao);
    glGenBuffers(1, &quad->vbo);
    glBindVertexArray(quad->vao);
    glBindBuffer(GL_ARRAY_BUFFER, quad->vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    GLint pos = glGetAttribLocation(quad->program, "in_pos");
    GLint tc = glGetAttribLocation(quad->program, "in_tc");
    glEnableVertexAttribArray(pos);
    glVertexAttribPointer(pos, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          reinterpret_cast<void*>(0));
    glEnableVertexAttribArray(tc);
    glVertexAttribPointer(tc, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          reinterpret_cast<void*>(2 * sizeof(float)));
    glBindVertexArray(0);
  }

  return true;
}

bool FlutterVideoRendererGL::CompileShaderProgram() {
  GlQuad* quad = gl_quad();
  GLuint vs = glCreateShader(GL_VERTEX_SHADER);
  glShaderSource(vs, 1, &kVertexShader, nullptr);
  glCompileShader(vs);
  GLint ok = GL_FALSE;
  glGetShaderiv(vs, GL_COMPILE_STATUS, &ok);
  if (ok == GL_FALSE) {
    char log[1024] = {0};
    glGetShaderInfoLog(vs, sizeof(log), nullptr, log);
    std::fprintf(stderr, "[flutter_webrtc] GL vertex shader failed: %s\n", log);
    glDeleteShader(vs);
    return false;
  }

  GLuint fs = glCreateShader(GL_FRAGMENT_SHADER);
  glShaderSource(fs, 1, &kFragmentShader, nullptr);
  glCompileShader(fs);
  glGetShaderiv(fs, GL_COMPILE_STATUS, &ok);
  if (ok == GL_FALSE) {
    char log[1024] = {0};
    glGetShaderInfoLog(fs, sizeof(log), nullptr, log);
    std::fprintf(stderr, "[flutter_webrtc] GL fragment shader failed: %s\n",
                 log);
    glDeleteShader(vs);
    glDeleteShader(fs);
    return false;
  }

  quad->program = glCreateProgram();
  glAttachShader(quad->program, vs);
  glAttachShader(quad->program, fs);
  glLinkProgram(quad->program);
  glGetProgramiv(quad->program, GL_LINK_STATUS, &ok);
  if (ok == GL_FALSE) {
    char log[1024] = {0};
    glGetProgramInfoLog(quad->program, sizeof(log), nullptr, log);
    std::fprintf(stderr, "[flutter_webrtc] GL program link failed: %s\n", log);
    glDeleteShader(vs);
    glDeleteShader(fs);
    glDeleteProgram(quad->program);
    quad->program = 0;
    return false;
  }
  glDeleteShader(vs);
  glDeleteShader(fs);

  glUseProgram(quad->program);
  quad->uniform_y = glGetUniformLocation(quad->program, "y_tex");
  quad->uniform_u = glGetUniformLocation(quad->program, "u_tex");
  quad->uniform_v = glGetUniformLocation(quad->program, "v_tex");
  glUniform1i(quad->uniform_y, 0);
  glUniform1i(quad->uniform_u, 1);
  glUniform1i(quad->uniform_v, 2);
  quad->compiled = true;
  return true;
}

bool FlutterVideoRendererGL::CompileNv12ShaderProgram() {
  GlQuad* quad = gl_quad();
  GLuint vs = glCreateShader(GL_VERTEX_SHADER);
  glShaderSource(vs, 1, &kVertexShader, nullptr);
  glCompileShader(vs);
  GLint ok = GL_FALSE;
  glGetShaderiv(vs, GL_COMPILE_STATUS, &ok);
  if (ok == GL_FALSE) {
    char log[1024] = {0};
    glGetShaderInfoLog(vs, sizeof(log), nullptr, log);
    std::fprintf(stderr, "[flutter_webrtc] GL NV12 vertex shader failed: %s\n",
                 log);
    glDeleteShader(vs);
    return false;
  }

  GLuint fs = glCreateShader(GL_FRAGMENT_SHADER);
  glShaderSource(fs, 1, &kFragmentShaderNv12, nullptr);
  glCompileShader(fs);
  glGetShaderiv(fs, GL_COMPILE_STATUS, &ok);
  if (ok == GL_FALSE) {
    char log[1024] = {0};
    glGetShaderInfoLog(fs, sizeof(log), nullptr, log);
    std::fprintf(stderr,
                 "[flutter_webrtc] GL NV12 fragment shader failed: %s\n", log);
    glDeleteShader(vs);
    glDeleteShader(fs);
    return false;
  }

  quad->program_nv12 = glCreateProgram();
  glAttachShader(quad->program_nv12, vs);
  glAttachShader(quad->program_nv12, fs);
  glLinkProgram(quad->program_nv12);
  glGetProgramiv(quad->program_nv12, GL_LINK_STATUS, &ok);
  if (ok == GL_FALSE) {
    char log[1024] = {0};
    glGetProgramInfoLog(quad->program_nv12, sizeof(log), nullptr, log);
    std::fprintf(stderr, "[flutter_webrtc] GL NV12 program link failed: %s\n",
                 log);
    glDeleteShader(vs);
    glDeleteShader(fs);
    glDeleteProgram(quad->program_nv12);
    quad->program_nv12 = 0;
    return false;
  }
  glDeleteShader(vs);
  glDeleteShader(fs);

  glUseProgram(quad->program_nv12);
  quad->uniform_y_nv12 = glGetUniformLocation(quad->program_nv12, "y_tex");
  quad->uniform_uv_nv12 = glGetUniformLocation(quad->program_nv12, "uv_tex");
  glUniform1i(quad->uniform_y_nv12, 0);
  glUniform1i(quad->uniform_uv_nv12, 1);
  quad->nv12_compiled = true;
  return true;
}

void FlutterVideoRendererGL::MaybeLogRasterStats() {
  // The per-second raster log is debug noise; only emit it when the Dart app
  // turned renderer logging on (Verbose logs setting).
  if (!renderer_logging_enabled()) return;
  const auto now = std::chrono::steady_clock::now();
  const double now_s =
      std::chrono::duration<double>(now.time_since_epoch()).count();
  if (now_s - raster_last_log_at_ < 1.0) return;
  raster_last_log_at_ = now_s;
  const double avg =
      raster_frames_ > 0 ? raster_total_ms_ / raster_frames_ : 0.0;
  std::fprintf(stderr,
               "[glrender] raster avg %.2f ms/frame  max %.2f ms  "
               "n=%llu  cache hits=%llu\n",
               avg, raster_max_ms_,
               static_cast<unsigned long long>(raster_frames_),
               static_cast<unsigned long long>(raster_cache_hits_));
  raster_frames_ = 0;
  raster_total_ms_ = 0;
  raster_max_ms_ = 0;
  raster_cache_hits_ = 0;
}

void FlutterVideoRendererGL::UploadAndRenderFrame(const uint8_t* y,
                                                  int y_stride,
                                                  const uint8_t* u,
                                                  int u_stride,
                                                  const uint8_t* v,
                                                  int v_stride,
                                                  int width,
                                                  int height) {
  const int uv_w = (width + 1) / 2;
  const int uv_h = (height + 1) / 2;

  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glPixelStorei(GL_UNPACK_ROW_LENGTH, y_stride);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, y_tex_);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RED,
                  GL_UNSIGNED_BYTE, y);

  glPixelStorei(GL_UNPACK_ROW_LENGTH, u_stride);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, u_tex_);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, uv_w, uv_h, GL_RED,
                  GL_UNSIGNED_BYTE, u);

  glPixelStorei(GL_UNPACK_ROW_LENGTH, v_stride);
  glActiveTexture(GL_TEXTURE2);
  glBindTexture(GL_TEXTURE_2D, v_tex_);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, uv_w, uv_h, GL_RED,
                  GL_UNSIGNED_BYTE, v);

  // Render YUV→RGB into the FBO.
  GlQuad* quad = gl_quad();
  glDisable(GL_BLEND);
  glDisable(GL_SCISSOR_TEST);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glViewport(0, 0, width, height);
  glUseProgram(quad->program);
  glBindVertexArray(quad->vao);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glBindVertexArray(0);
}

bool FlutterVideoRendererGL::ImportAndRenderDmaBuf(const RtcDmaBufDescriptor* desc,
                                                   int width,
                                                   int height) {
  // Runs on the raster thread with the engine's GL context current. The
  // descriptor's fds are owned by the frame's DmaBufVideoBuffer (which holds a
  // GstBuffer ref keeping the VA surface alive), so they stay valid for the
  // whole call; eglCreateImageKHR internally dups them anyway.

  // The engine's compositor context must be EGL-backed for dmabuf imports
  // (GTK GL areas create EGL contexts; GLX contexts yield EGL_NO_DISPLAY and we
  // fall back to the CPU path).
  EGLDisplay display = eglGetCurrentDisplay();
  if (display == EGL_NO_DISPLAY) {
    std::fprintf(stderr,
                 "[flutter_webrtc] GL renderer: no EGL display for dmabuf "
                 "import — CPU fallback\n");
    return false;
  }

  // Resolve the KHR extension entry points once (they are not in the core
  // EGL dispatch table).
  static PFNEGLCREATEIMAGEKHRPROC create_image_khr = nullptr;
  static PFNEGLDESTROYIMAGEKHRPROC destroy_image_khr = nullptr;
  static void (*egl_image_target_texture_2d)(GLenum target, EGLImageKHR image) =
      nullptr;
  if (create_image_khr == nullptr) {
    create_image_khr = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
        eglGetProcAddress("eglCreateImageKHR"));
  }
  if (destroy_image_khr == nullptr) {
    destroy_image_khr = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
        eglGetProcAddress("eglDestroyImageKHR"));
  }
  if (egl_image_target_texture_2d == nullptr) {
    // glEGLImageTargetTexture2DOES — provided by GL_OES_EGL_image on desktop
    // GL (epoxy may not route it on core-profile contexts).
    egl_image_target_texture_2d = reinterpret_cast<void (*)(GLenum, EGLImageKHR)>(
        eglGetProcAddress("glEGLImageTargetTexture2DOES"));
  }
  if (create_image_khr == nullptr || destroy_image_khr == nullptr ||
      egl_image_target_texture_2d == nullptr) {
    std::fprintf(stderr,
                 "[flutter_webrtc] GL renderer: EGL image entry points "
                 "missing — CPU fallback\n");
    return false;
  }

  const char* exts = eglQueryString(display, EGL_EXTENSIONS);
  if (exts == nullptr ||
      std::strstr(exts, "EGL_EXT_image_dma_buf_import") == nullptr) {
    std::fprintf(stderr,
                 "[flutter_webrtc] GL renderer: no EGL_EXT_image_dma_buf_import "
                 "— CPU fallback\n");
    return false;
  }
  const bool has_modifiers =
      exts != nullptr &&
      std::strstr(exts, "EGL_EXT_image_dma_buf_import_modifiers") != nullptr;

  // NV12 = DRM_FORMAT_NV12. Plane fourccs: Y = R8, interleaved UV = GR88.
  // Hardcoded so the plugin needs no libdrm dependency.
  const EGLint kDrmFormatR8 = 0x20203852;    // fourcc('R','8',' ',' ')
  const EGLint kDrmFormatGr88 = 0x38385247;  // fourcc('G','R','8','8')

  const EGLint uv_w = (width + 1) / 2;
  const EGLint uv_h = (height + 1) / 2;

  auto build_attrs = [&](EGLint fourcc, EGLint img_w, EGLint img_h, int fd,
                         int offset, int pitch, std::vector<EGLint>* out) {
    out->push_back(EGL_LINUX_DRM_FOURCC_EXT);
    out->push_back(fourcc);
    out->push_back(EGL_WIDTH);
    out->push_back(img_w);
    out->push_back(EGL_HEIGHT);
    out->push_back(img_h);
    out->push_back(EGL_DMA_BUF_PLANE0_FD_EXT);
    out->push_back(fd);
    out->push_back(EGL_DMA_BUF_PLANE0_OFFSET_EXT);
    out->push_back(offset);
    out->push_back(EGL_DMA_BUF_PLANE0_PITCH_EXT);
    out->push_back(pitch);
    if (desc->modifier != 0 && has_modifiers) {
      out->push_back(EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT);
      out->push_back(static_cast<EGLint>(desc->modifier & 0xffffffffu));
      out->push_back(EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT);
      out->push_back(static_cast<EGLint>(desc->modifier >> 32));
    }
    out->push_back(EGL_NONE);
  };

  std::vector<EGLint> y_attrs;
  build_attrs(kDrmFormatR8, width, height, desc->y_fd, desc->y_offset,
              desc->y_pitch, &y_attrs);
  EGLImageKHR y_image = create_image_khr(display, EGL_NO_CONTEXT,
                                         EGL_LINUX_DMA_BUF_EXT, nullptr,
                                         y_attrs.data());
  if (y_image == EGL_NO_IMAGE_KHR) {
    std::fprintf(stderr,
                 "[flutter_webrtc] GL renderer: Y EGLImage import failed "
                 "(modifier %#llx) — CPU fallback\n",
                 static_cast<unsigned long long>(desc->modifier));
    return false;
  }

  std::vector<EGLint> uv_attrs;
  build_attrs(kDrmFormatGr88, uv_w, uv_h, desc->uv_fd, desc->uv_offset,
              desc->uv_pitch, &uv_attrs);
  EGLImageKHR uv_image = create_image_khr(display, EGL_NO_CONTEXT,
                                          EGL_LINUX_DMA_BUF_EXT, nullptr,
                                          uv_attrs.data());
  if (uv_image == EGL_NO_IMAGE_KHR) {
    destroy_image_khr(display, y_image);
    std::fprintf(stderr,
                 "[flutter_webrtc] GL renderer: UV EGLImage import failed — "
                 "CPU fallback\n");
    return false;
  }

  // Attach the images to the plane textures (redefines their storage), then
  // render NV12→RGB with the 2-texture shader into rgb_tex_/fbo_.
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, y_tex_);
  egl_image_target_texture_2d(GL_TEXTURE_2D, y_image);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, uv_tex_);
  egl_image_target_texture_2d(GL_TEXTURE_2D, uv_image);

  GlQuad* quad = gl_quad();
  if (!quad->nv12_compiled && !CompileNv12ShaderProgram()) {
    destroy_image_khr(display, y_image);
    destroy_image_khr(display, uv_image);
    return false;
  }

  glDisable(GL_BLEND);
  glDisable(GL_SCISSOR_TEST);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
  glViewport(0, 0, width, height);
  glUseProgram(quad->program_nv12);
  glUniform1i(quad->uniform_y_nv12, 0);
  glUniform1i(quad->uniform_uv_nv12, 1);
  glBindVertexArray(quad->vao);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glBindVertexArray(0);

  destroy_image_khr(display, y_image);
  destroy_image_khr(display, uv_image);
  return true;
}

}  // namespace flutter_webrtc_plugin
