// gst_texture_plugin.cc — in-tree Linux plugin exposing the gst_bridge frame
// slot as a Flutter GL texture. The webrtcbin transport decodes into an
// appsink; instead of shipping every RGBA frame through Dart
// (decodeImageFromPixels -> RawImage, CPU-bound at ~9-14 fps @1080p), the
// embedder's FlTextureGL::populate() pulls the newest frame straight from the
// bridge's double-buffered slot on the raster thread and uploads it with
// glTexSubImage2D. Dart renders a Texture widget — no main-isolate work.
#include "gst_texture_plugin.h"

#include <dlfcn.h>
#include <drm_fourcc.h>
#include <epoxy/egl.h>
#include <epoxy/gl.h>

#include <cstring>

#include "flutter_linux/flutter_linux.h"

// gst_bridge.h lives in native/gst_bridge (C ABI); declare the three symbols
// we need directly to keep the runner independent of that include path.
extern "C" {
typedef struct GstBridge GstBridge;
typedef void (*fn_bridge_enable_frame_slot)(GstBridge*);
typedef int (*fn_bridge_acquire_latest_frame)(GstBridge*, const uint8_t**,
                                              int32_t*, int32_t*, int32_t*,
                                              uint32_t*);
typedef void (*fn_bridge_set_frame_slot_notify)(GstBridge*,
                                                void (*)(void*), void*);
typedef struct BridgeDmaBufFrame {
  int fds[4];
  int nfd;
  uint32_t fourcc;
  int32_t width;
  int32_t height;
  int32_t strides[4];
  int32_t offsets[4];
  uint64_t modifiers[4];
  uint32_t seq;
} BridgeDmaBufFrame;
typedef int (*fn_bridge_frame_slot_mode)(GstBridge*);
typedef int (*fn_bridge_acquire_latest_dmabuf)(GstBridge*, BridgeDmaBufFrame*);
typedef void (*fn_bridge_close_dmabuf_fds)(BridgeDmaBufFrame*);
}

namespace {

constexpr char kChannelName[] = "next_client/gst_texture";

struct _GstTextureGL;
static gboolean gst_texture_gl_emit_placeholder(struct _GstTextureGL* self,
                                                uint32_t* target,
                                                uint32_t* name,
                                                uint32_t* width,
                                                uint32_t* height);

// Typedefs resolved from the already-loaded libgst_bridge.so.
struct BridgeApi {
  fn_bridge_enable_frame_slot enable = nullptr;
  fn_bridge_acquire_latest_frame acquire = nullptr;
  fn_bridge_frame_slot_mode mode = nullptr;
  fn_bridge_acquire_latest_dmabuf acquire_dmabuf = nullptr;
  fn_bridge_close_dmabuf_fds close_dmabuf = nullptr;
};

GstBridge* AsBridge(int64_t ptr) { return reinterpret_cast<GstBridge*>(ptr); }


// --- FlTextureGL subclass ---------------------------------------------------

#define GST_TYPE_TEXTURE_GL (gst_texture_gl_get_type())
#define GST_TEXTURE_GL(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), GST_TYPE_TEXTURE_GL, GstTextureGL))

typedef struct _GstTextureGL GstTextureGL;

struct _GstTextureGL {
  FlTextureGL parent_instance;

  GLuint gl_name;
  uint32_t last_seq;
  int32_t last_width;
  int32_t last_height;
  GstBridge* bridge;
  BridgeApi* api;
  FlTextureRegistrar* registrar;  // not owned; for mark-frame-available
  // GPU zero-copy mode state.
  int is_dmabuf;
  EGLImageKHR egl_image;
  BridgeDmaBufFrame held_dmabuf;
};

typedef struct _GstTextureGLClass {
  FlTextureGLClass parent_class;
} GstTextureGLClass;

G_DEFINE_TYPE(GstTextureGL, gst_texture_gl, fl_texture_gl_get_type())

static void gst_texture_gl_finalize(GObject* object) {
  GstTextureGL* self = GST_TEXTURE_GL(object);
  if (self->egl_image != EGL_NO_IMAGE_KHR) {
    eglDestroyImageKHR(eglGetCurrentDisplay(), self->egl_image);
    self->egl_image = EGL_NO_IMAGE_KHR;
  }
  if (self->gl_name != 0) {
    glDeleteTextures(1, &self->gl_name);
    self->gl_name = 0;
  }
  G_OBJECT_CLASS(gst_texture_gl_parent_class)->finalize(object);
}

static gboolean gst_texture_gl_populate(FlTextureGL* texture, uint32_t* target,
                                        uint32_t* name, uint32_t* width,
                                        uint32_t* height, GError** error) {
  GstTextureGL* self = GST_TEXTURE_GL(texture);
  (void)error;
  if (!self->bridge || !self->api || !self->api->acquire) {
    // Bridge not attached — keep returning a valid texture so Flutter keeps
    // compositing the widget (returning FALSE here can permanently drop it).
    return gst_texture_gl_emit_placeholder(self, target, name, width, height);
  }

  // ---- GPU zero-copy: import the newest VA surface dmabuf as EGLImage ----
  if (self->is_dmabuf && self->api->acquire_dmabuf) {
    BridgeDmaBufFrame f;
    memset(&f, 0, sizeof(f));
    if (!self->api->acquire_dmabuf(self->bridge, &f) || f.nfd <= 0) {
      // No new frame yet — keep the current texture.
      if (self->gl_name == 0) {
        return gst_texture_gl_emit_placeholder(self, target, name, width,
                                               height);
      }
      *target = GL_TEXTURE_2D;
      *name = self->gl_name;
      *width = static_cast<uint32_t>(self->last_width);
      *height = static_cast<uint32_t>(self->last_height);
      return TRUE;
    }
    if (self->gl_name == 0) {
      glGenTextures(1, &self->gl_name);
    }
    glBindTexture(GL_TEXTURE_2D, self->gl_name);

    EGLDisplay dpy = eglGetCurrentDisplay();
    // DRM_FORMAT_MOD_INVALID (0x00ffffffffffffff) means "implicit layout" —
    // it must NOT be passed as an explicit modifier attribute, or the import
    // fails. Only real modifiers go into the attr list.
    const uint64_t kInvalidMod = 0x00ffffffffffffffULL;
    const bool has_modifiers = f.nfd > 0 &&
        f.modifiers[0] != kInvalidMod && f.modifiers[0] != 0;
    EGLint attrs[8 * 4 + 1];
    int i = 0;
    attrs[i++] = EGL_WIDTH;
    attrs[i++] = f.width;
    attrs[i++] = EGL_HEIGHT;
    attrs[i++] = f.height;
    attrs[i++] = EGL_LINUX_DRM_FOURCC_EXT;
    attrs[i++] = static_cast<EGLint>(f.fourcc);
    for (int p = 0; p < f.nfd && p < 4; p++) {
      attrs[i++] = EGL_DMA_BUF_PLANE0_FD_EXT + p * 3;
      attrs[i++] = f.fds[p];
      attrs[i++] = EGL_DMA_BUF_PLANE0_OFFSET_EXT + p * 3;
      attrs[i++] = f.offsets[p];
      attrs[i++] = EGL_DMA_BUF_PLANE0_PITCH_EXT + p * 3;
      attrs[i++] = f.strides[p];
      if (has_modifiers) {
        attrs[i++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT + p * 3;
        attrs[i++] = static_cast<EGLint>(f.modifiers[p] & 0xffffffff);
        attrs[i++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT + p * 3;
        attrs[i++] = static_cast<EGLint>(f.modifiers[p] >> 32);
      }
    }
    attrs[i++] = EGL_NONE;
    EGLImageKHR img = eglCreateImageKHR(dpy, EGL_NO_CONTEXT,
                                        EGL_LINUX_DMA_BUF_EXT,
                                        (EGLClientBuffer)attrs, nullptr);
    // The image holds its own dmabuf reference — close the fds now.
    for (int p = 0; p < f.nfd && p < 4; p++) {
      if (f.fds[p] >= 0) close(f.fds[p]);
      f.fds[p] = -1;
    }
    if (img == EGL_NO_IMAGE_KHR) {
      if (!self->last_width) {
        g_print("[gsttexture] dmabuf import FAILED: egl 0x%x fourcc %08x "
                "mod %llx w %d\n",
                static_cast<unsigned>(eglGetError()), f.fourcc,
                (unsigned long long)f.modifiers[0], f.width);
      }
      // Fallback: keep the last good texture visible.
      if (self->gl_name != 0 && self->last_width > 0) {
        *target = GL_TEXTURE_2D;
        *name = self->gl_name;
        *width = static_cast<uint32_t>(self->last_width);
        *height = static_cast<uint32_t>(self->last_height);
        return TRUE;
      }
      return gst_texture_gl_emit_placeholder(self, target, name, width,
                                             height);
    }
    if (self->last_width == 0) {
      g_print("[gsttexture] dmabuf import OK: %dx%d fourcc %08x mod %llx\n",
              f.width, f.height, f.fourcc,
              (unsigned long long)f.modifiers[0]);
    }
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, img);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (self->egl_image != EGL_NO_IMAGE_KHR) {
      eglDestroyImageKHR(dpy, self->egl_image);
    }
    self->egl_image = img;
    self->last_seq = f.seq;
    self->last_width = f.width;
    self->last_height = f.height;
    *target = GL_TEXTURE_2D;
    *name = self->gl_name;
    *width = static_cast<uint32_t>(f.width);
    *height = static_cast<uint32_t>(f.height);
    return TRUE;
  }

  const uint8_t* data = nullptr;
  int32_t w = 0;
  int32_t h = 0;
  int32_t stride = 0;
  uint32_t seq = 0;
  if (!self->api->acquire(self->bridge, &data, &w, &h, &stride, &seq) ||
      data == nullptr || w <= 0 || h <= 0) {
    // No frame yet — placeholder instead of an error (same reason).
    return gst_texture_gl_emit_placeholder(self, target, name, width, height);
  }

  if (self->gl_name == 0) {
    glGenTextures(1, &self->gl_name);
    g_print("[gsttexture] first populate: %dx%d stride %d seq %u\n", w, h,
            stride, seq);
  }
  gboolean dim_changed = self->last_width != w || self->last_height != h;
  glBindTexture(GL_TEXTURE_2D, self->gl_name);
  if (dim_changed) {
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, nullptr);
    self->last_width = w;
    self->last_height = h;
    g_print("[gsttexture] upload %dx%d\n", w, h);
  }
  glPixelStorei(GL_UNPACK_ROW_LENGTH, stride / 4);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE,
                  data);
  glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  // Diagnostics: per-frame log with GL error state — a frozen picture with
  // fresh seqs here means uploads are failing after the first.
  while (glGetError() != GL_NO_ERROR) {
  }
  g_print("[gsttexture] frame seq %u %dx%d\n", seq, w, h);

  self->last_seq = seq;
  *target = GL_TEXTURE_2D;
  *name = self->gl_name;
  *width = static_cast<uint32_t>(w);
  *height = static_cast<uint32_t>(h);
  return TRUE;
}

static void gst_texture_gl_class_init(GstTextureGLClass* klass) {
  G_OBJECT_CLASS(klass)->finalize = gst_texture_gl_finalize;
  FL_TEXTURE_GL_CLASS(klass)->populate = gst_texture_gl_populate;
}

static void gst_texture_gl_init(GstTextureGL* self) {
  self->gl_name = 0;
  self->last_seq = 0;
  self->last_width = 0;
  self->last_height = 0;
  self->bridge = nullptr;
  self->api = nullptr;
  self->is_dmabuf = 0;
  self->egl_image = EGL_NO_IMAGE_KHR;
  memset(&self->held_dmabuf, 0, sizeof(self->held_dmabuf));
}

// A 1x1 black texture so populate always returns something compositable —
// erroring from populate can make Flutter permanently drop the texture.
static gboolean gst_texture_gl_emit_placeholder(GstTextureGL* self,
                                                uint32_t* target,
                                                uint32_t* name,
                                                uint32_t* width,
                                                uint32_t* height) {
  if (self->gl_name == 0) {
    glGenTextures(1, &self->gl_name);
    glBindTexture(GL_TEXTURE_2D, self->gl_name);
    static const uint8_t black[4] = {0, 0, 0, 255};
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, black);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  } else {
    glBindTexture(GL_TEXTURE_2D, self->gl_name);
  }
  *target = GL_TEXTURE_2D;
  *name = self->gl_name;
  *width = 1;
  *height = 1;
  return TRUE;
}

// --- Plugin state + method channel ------------------------------------------

struct GstTexturePlugin {
  FlTextureRegistrar* texture_registrar;
  GstTextureGL* texture;
  BridgeApi api;
  void* bridge_lib;
  int64_t attached_bridge;
  fn_bridge_set_frame_slot_notify set_notify = nullptr;
};

// Runs on the GStreamer streaming thread per produced frame: marks the
// texture dirty so the engine re-invokes populate() on the raster thread.
// The registrar posts to the platform thread internally (fvp and the
// flutter_webrtc GL renderer call this from decode threads the same way).
static void gst_texture_slot_notify(void* userdata) {
  GstTexturePlugin* plugin = reinterpret_cast<GstTexturePlugin*>(userdata);
  if (plugin && plugin->texture && plugin->texture_registrar) {
    fl_texture_registrar_mark_texture_frame_available(
        plugin->texture_registrar, FL_TEXTURE(plugin->texture));
  }
}

GstTexturePlugin* g_plugin = nullptr;

void gst_texture_plugin_detach() {
  if (!g_plugin) return;
  if (g_plugin->set_notify && g_plugin->attached_bridge) {
    g_plugin->set_notify(reinterpret_cast<GstBridge*>(g_plugin->attached_bridge),
                         nullptr, nullptr);
  }
  if (g_plugin->texture) {
    fl_texture_registrar_unregister_texture(g_plugin->texture_registrar,
                                            FL_TEXTURE(g_plugin->texture));
    g_object_unref(g_plugin->texture);
    g_plugin->texture = nullptr;
  }
  // Deliberately NOT dlclose'ing the bridge library — the Dart FFI holds
  // function pointers into it for the process lifetime.
  g_plugin->attached_bridge = 0;
}

void gst_texture_plugin_handle_attach(GstTexturePlugin* plugin,
                                      FlMethodCall* call) {
  g_autoptr(FlValue) result = nullptr;
  do {
    if (plugin->texture) {
      result = fl_value_new_int(0);  // already attached
      break;
    }
    FlValue* args = fl_method_call_get_args(call);
    int64_t bridge_ptr =
        fl_value_get_int(fl_value_lookup_string(args, "bridge"));
    const char* lib_path =
        fl_value_get_string(fl_value_lookup_string(args, "libPath"));
    if (bridge_ptr == 0 || lib_path == nullptr) {
      fl_method_call_respond_error(call, "bad-args",
                                   "bridge pointer or lib path missing",
                                   nullptr, nullptr);
      return;
    }
    // Same-file dlopen returns the already-loaded handle (refcount++), so we
    // share globals with the Dart FFI bridge.
    void* lib = dlopen(lib_path, RTLD_NOW | RTLD_NOLOAD);
    if (!lib) lib = dlopen(lib_path, RTLD_NOW);
    if (!lib) {
      fl_method_call_respond_error(call, "dlopen-failed", dlerror(), nullptr,
                                   nullptr);
      return;
    }
    plugin->bridge_lib = lib;
    plugin->api.enable = reinterpret_cast<fn_bridge_enable_frame_slot>(
        dlsym(lib, "bridge_enable_frame_slot"));
    plugin->api.acquire =
        reinterpret_cast<fn_bridge_acquire_latest_frame>(
            dlsym(lib, "bridge_acquire_latest_frame"));
    plugin->set_notify = reinterpret_cast<fn_bridge_set_frame_slot_notify>(
        dlsym(lib, "bridge_set_frame_slot_notify"));
    plugin->api.mode = reinterpret_cast<fn_bridge_frame_slot_mode>(
        dlsym(lib, "bridge_frame_slot_mode"));
    plugin->api.acquire_dmabuf =
        reinterpret_cast<fn_bridge_acquire_latest_dmabuf>(
            dlsym(lib, "bridge_acquire_latest_dmabuf"));
    plugin->api.close_dmabuf = reinterpret_cast<fn_bridge_close_dmabuf_fds>(
        dlsym(lib, "bridge_close_dmabuf_fds"));
    if (!plugin->api.enable || !plugin->api.acquire) {
      fl_method_call_respond_error(call, "symbols-missing",
                                   "bridge_enable_frame_slot/"
                                   "bridge_acquire_latest_frame not found",
                                   nullptr, nullptr);
      return;
    }
    plugin->api.enable(AsBridge(bridge_ptr));

    plugin->texture = GST_TEXTURE_GL(
        g_object_new(gst_texture_gl_get_type(), nullptr));
    plugin->texture->bridge = AsBridge(bridge_ptr);
    plugin->texture->api = &plugin->api;
    if (plugin->api.mode) {
      plugin->texture->is_dmabuf =
          plugin->api.mode(AsBridge(bridge_ptr)) == 1 ? 1 : 0;
    }
    g_object_ref(plugin->texture);
    if (!fl_texture_registrar_register_texture(plugin->texture_registrar,
                                               FL_TEXTURE(plugin->texture))) {
      g_object_unref(plugin->texture);
      plugin->texture = nullptr;
      fl_method_call_respond_error(call, "register-failed",
                                   "texture registration failed", nullptr,
                                   nullptr);
      return;
    }
    int64_t id = reinterpret_cast<int64_t>(fl_texture_get_id(
        FL_TEXTURE(plugin->texture)));
    plugin->texture->registrar = plugin->texture_registrar;
    if (plugin->set_notify) {
      plugin->set_notify(AsBridge(bridge_ptr), gst_texture_slot_notify,
                         plugin);
    }
    plugin->attached_bridge = bridge_ptr;
    result = fl_value_new_int(id);
  } while (false);
  fl_method_call_respond_success(call, result, nullptr);
}

void gst_texture_plugin_method_call(FlMethodChannel* channel,
                                    FlMethodCall* call, gpointer user_data) {
  (void)channel;
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "attach") == 0) {
    gst_texture_plugin_handle_attach(g_plugin, call);
  } else if (g_strcmp0(method, "detach") == 0) {
    gst_texture_plugin_detach();
    fl_method_call_respond_success(call, fl_value_new_bool(TRUE), nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

}  // namespace

extern "C" void gst_texture_plugin_register_with_registrar(
    FlPluginRegistry* registry) {
  if (g_plugin) return;
  FlPluginRegistrar* registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "gst_texture");
  g_plugin = g_new0(GstTexturePlugin, 1);
  g_plugin->texture_registrar = fl_plugin_registrar_get_texture_registrar(
      registrar);
  g_object_ref(g_plugin->texture_registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), kChannelName,
      FL_METHOD_CODEC(codec));
  // NOTE: `registrar` is owned by the registry for the process lifetime (the
  // generated registrant never unrefs it either) — do NOT unref it here; the
  // messenger read above must stay valid.
  fl_method_channel_set_method_call_handler(channel, gst_texture_plugin_method_call,
                                            g_plugin, nullptr);
  g_object_unref(channel);
}
