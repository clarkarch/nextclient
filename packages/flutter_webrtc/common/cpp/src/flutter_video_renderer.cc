#include "flutter_video_renderer.h"

#if defined(__linux__)
#include "flutter_video_renderer_gl.h"
#include "flutter/texture_registrar_impl.h"
#endif
#if defined(_WIN32)
#include "flutter_video_renderer_d3d.h"
#endif

namespace flutter_webrtc_plugin {

FlutterVideoRenderer::~FlutterVideoRenderer() {}

void FlutterVideoRenderer::initialize(
    TextureRegistrar* registrar,
    BinaryMessenger* messenger,
    TaskRunner* task_runner,
    std::unique_ptr<flutter::TextureVariant> texture,
    int64_t trxture_id) {
  registrar_ = registrar;
  texture_ = std::move(texture);
  texture_id_ = trxture_id;
  std::string channel_name =
      "FlutterWebRTC/Texture" + std::to_string(texture_id_);
  event_channel_ = EventChannelProxy::Create(messenger, task_runner, channel_name);
}

const FlutterDesktopPixelBuffer* FlutterVideoRenderer::CopyPixelBuffer(
    size_t width,
    size_t height) const {
  mutex_.lock();
  if (pixel_buffer_.get() && frame_.get()) {
    if (pixel_buffer_->width != frame_->width() ||
        pixel_buffer_->height != frame_->height()) {
      size_t buffer_size =
          (size_t(frame_->width()) * size_t(frame_->height())) * (32 >> 3);
      rgb_buffer_.reset(new uint8_t[buffer_size]);
      pixel_buffer_->width = frame_->width();
      pixel_buffer_->height = frame_->height();
    }

    frame_->ConvertToARGB(RTCVideoFrame::Type::kABGR, rgb_buffer_.get(), 0,
                          static_cast<int>(pixel_buffer_->width),
                          static_cast<int>(pixel_buffer_->height));

    pixel_buffer_->buffer = rgb_buffer_.get();
    mutex_.unlock();
#if defined(_WIN32)
    // Count a successfully delivered pixel buffer as a composite so the
    // renderer watchdog (getRendererStatus) can tell a working CPU path from
    // a D3D11 path that decodes but never presents.
    renderer_status_mark_composited();
#endif
    return pixel_buffer_.get();
  }
  mutex_.unlock();
  return nullptr;
}

void FlutterVideoRenderer::OnFrame(scoped_refptr<RTCVideoFrame> frame) {
  if (!first_frame_rendered) {
    EncodableMap params;
    params[EncodableValue("event")] = "didFirstFrameRendered";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    event_channel_->Success(EncodableValue(params));
    pixel_buffer_.reset(new FlutterDesktopPixelBuffer());
    pixel_buffer_->width = 0;
    pixel_buffer_->height = 0;
    first_frame_rendered = true;
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
  mutex_.lock();
  frame_ = frame;
  mutex_.unlock();
  registrar_->MarkTextureFrameAvailable(texture_id_);
}

void FlutterVideoRenderer::SetVideoTrack(scoped_refptr<RTCVideoTrack> track) {
  if (track_ != track) {
    if (track_)
      track_->RemoveRenderer(this);
    track_ = track;
    last_frame_size_ = {0, 0};
    first_frame_rendered = false;
    if (track_)
      track_->AddRenderer(this);
  }
}

bool FlutterVideoRenderer::CheckMediaStream(std::string mediaId) {
  if (0 == mediaId.size() || 0 == media_stream_id.size()) {
    return false;
  }
  return mediaId == media_stream_id;
}

bool FlutterVideoRenderer::CheckVideoTrack(std::string mediaId) {
  if (0 == mediaId.size() || !track_) {
    return false;
  }
  return mediaId == track_->id().std_string();
}

FlutterVideoRendererManager::FlutterVideoRendererManager(
    FlutterWebRTCBase* base)
    : base_(base) {}

FlutterVideoRendererManager::~FlutterVideoRendererManager() = default;

void FlutterVideoRendererManager::CreateVideoRendererTexture(
    std::unique_ptr<MethodResultProxy> result) {
#if defined(__linux__)
  if (FlutterVideoRendererGL::IsEnabled()) {
    auto texture = new RefCountedObject<FlutterVideoRendererGL>();
    // The GL renderer bypasses the client-wrapper TextureVariant and registers
    // an FlTextureGL directly through the engine C API so Flutter composites
    // our GPU texture without a CPU readback.
    FlTextureRegistrar* raw = static_cast<flutter::TextureRegistrarImpl*>(
                                  base_->textures_)
                                  ->raw_texture_registrar();
    FlShaderTextureGL* gl_texture = fl_shader_texture_gl_new(texture);
    if (!fl_texture_registrar_register_texture(raw,
                                               FL_TEXTURE(gl_texture))) {
      g_object_unref(gl_texture);
      result->Error("CreateVideoRendererTextureFailed",
                    "FlTextureGL registration failed");
      return;
    }
    int64_t texture_id = fl_texture_get_id(FL_TEXTURE(gl_texture));
    // Hand the renderer its own ref so OnFrame can mark the texture dirty
    // without a registrar lookup on the decode thread.
    texture->SetTextureHandle(gl_texture);
    // Drop the manager's GObject ref; the renderer + registrar keep the
    // texture alive until unregister/dispose.
    g_object_unref(gl_texture);
    texture->initialize(base_->messenger_, base_->task_runner_, raw,
                        texture_id);
    gl_renderers_[texture_id] = texture;
    EncodableMap params;
    params[EncodableValue("textureId")] = EncodableValue(texture_id);
    result->Success(EncodableValue(params));
    return;
  }
#endif
#if defined(_WIN32)
  if (FlutterVideoRendererD3D::IsEnabled() && D3d11RendererSelfTest()) {
    // GPU renderer: register a GpuSurfaceTexture (DXGI shared handle). The
    // engine binds the shared D3D11 texture via
    // EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE and composites it with no CPU
    // readback; ObtainDescriptor (raster thread) runs the YUV→RGB shader.
    // D3d11RendererSelfTest() verifies device+shaders+shared-handle BEFORE
    // committing to the path; on failure we fall through to the CPU renderer
    // below instead of streaming a silent black texture.
    renderer_status_set_backend("d3d11");
    auto texture = new RefCountedObject<FlutterVideoRendererD3D>();
    auto textureVariant = std::make_unique<flutter::TextureVariant>(
        flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
            [texture](size_t width,
                      size_t height) -> const FlutterDesktopGpuSurfaceDescriptor* {
              return texture->ObtainDescriptor(width, height);
            }));
    auto texture_id = base_->textures_->RegisterTexture(textureVariant.get());
    texture->initialize(base_->textures_, base_->messenger_,
                        base_->task_runner_, std::move(textureVariant),
                        texture_id);
    d3d_renderers_[texture_id] = texture;
    EncodableMap params;
    params[EncodableValue("textureId")] = EncodableValue(texture_id);
    result->Success(EncodableValue(params));
    return;
  }
#endif
#if defined(_WIN32)
  // CPU renderer (either GL was not requested, or the D3D11 self-test failed
  // — the stream stays visible on the CPU path and getRendererStatus reports
  // the reason via the error string).
  renderer_status_set_backend("cpu");
#endif
  auto texture = new RefCountedObject<FlutterVideoRenderer>();
  auto textureVariant =
      std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
          [texture](size_t width,
                    size_t height) -> const FlutterDesktopPixelBuffer* {
            return texture->CopyPixelBuffer(width, height);
          }));

  auto texture_id = base_->textures_->RegisterTexture(textureVariant.get());
  texture->initialize(base_->textures_, base_->messenger_, base_->task_runner_,
                      std::move(textureVariant), texture_id);
  renderers_[texture_id] = texture;
  EncodableMap params;
  params[EncodableValue("textureId")] = EncodableValue(texture_id);
  result->Success(EncodableValue(params));
}

void FlutterVideoRendererManager::VideoRendererSetSrcObject(
    int64_t texture_id,
    const std::string& stream_id,
    const std::string& owner_tag,
    const std::string& track_id) {
  scoped_refptr<RTCMediaStream> stream =
      base_->MediaStreamForId(stream_id, owner_tag);

  auto it = renderers_.find(texture_id);
  if (it != renderers_.end()) {
    FlutterVideoRenderer* renderer = it->second.get();
    if (stream.get()) {
      auto video_tracks = stream->video_tracks();
      if (video_tracks.size() > 0) {
        if (track_id == std::string()) {
          renderer->SetVideoTrack(video_tracks[0]);
        } else {
          for (auto track : video_tracks.std_vector()) {
            if (track->id().std_string() == track_id) {
              renderer->SetVideoTrack(track);
              break;
            }
          }
        }
        renderer->media_stream_id = stream_id;
      }
    } else {
      renderer->SetVideoTrack(nullptr);
    }
    return;
  }
#if defined(__linux__)
  auto glit = gl_renderers_.find(texture_id);
  if (glit != gl_renderers_.end()) {
    FlutterVideoRendererGL* renderer = glit->second.get();
    if (stream.get()) {
      auto video_tracks = stream->video_tracks();
      if (video_tracks.size() > 0) {
        if (track_id == std::string()) {
          renderer->SetVideoTrack(video_tracks[0]);
        } else {
          for (auto track : video_tracks.std_vector()) {
            if (track->id().std_string() == track_id) {
              renderer->SetVideoTrack(track);
              break;
            }
          }
        }
        renderer->media_stream_id = stream_id;
      }
    } else {
      renderer->SetVideoTrack(nullptr);
    }
  }
#endif
#if defined(_WIN32)
  auto dit = d3d_renderers_.find(texture_id);
  if (dit != d3d_renderers_.end()) {
    FlutterVideoRendererD3D* renderer = dit->second.get();
    if (stream.get()) {
      auto video_tracks = stream->video_tracks();
      if (video_tracks.size() > 0) {
        if (track_id == std::string()) {
          renderer->SetVideoTrack(video_tracks[0]);
        } else {
          for (auto track : video_tracks.std_vector()) {
            if (track->id().std_string() == track_id) {
              renderer->SetVideoTrack(track);
              break;
            }
          }
        }
        renderer->media_stream_id = stream_id;
      }
    } else {
      renderer->SetVideoTrack(nullptr);
    }
  }
#endif
}

void FlutterVideoRendererManager::VideoRendererDispose(
    int64_t texture_id,
    std::unique_ptr<MethodResultProxy> result) {
  auto it = renderers_.find(texture_id);
  if (it != renderers_.end()) {
    it->second->SetVideoTrack(nullptr);
#if defined(_WIN32)
    // Async unregister: the engine releases its reference (and stops touching
    // the texture) before the callback runs, so erasing here can't race an
    // in-flight composite on the raster thread.
    base_->textures_->UnregisterTexture(texture_id,
                                        [&, it] { renderers_.erase(it); });
#else
    base_->textures_->UnregisterTexture(texture_id);
    renderers_.erase(it);
#endif
    result->Success();
    return;
  }
#if defined(_WIN32)
  auto dit = d3d_renderers_.find(texture_id);
  if (dit != d3d_renderers_.end()) {
    dit->second->SetVideoTrack(nullptr);
    // Async unregister: the engine releases its reference to the shared D3D11
    // texture before the callback runs, so erasing here can't race an
    // in-flight composite on the raster thread.
    base_->textures_->UnregisterTexture(texture_id, [&, dit] {
      d3d_renderers_.erase(dit);
    });
    result->Success();
    return;
  }
#endif
#if defined(__linux__)
  auto glit = gl_renderers_.find(texture_id);
  if (glit != gl_renderers_.end()) {
    glit->second->SetVideoTrack(nullptr);
    FlTextureRegistrar* raw = static_cast<flutter::TextureRegistrarImpl*>(
                                  base_->textures_)
                                  ->raw_texture_registrar();
    glit->second->UnregisterFromEngine(raw);
    gl_renderers_.erase(glit);
    result->Success();
    return;
  }
#endif
  result->Error("VideoRendererDisposeFailed",
                "VideoRendererDispose() texture not found!");
}

void FlutterVideoRendererManager::VideoRendererSwitchToCpu(
    int64_t texture_id, std::unique_ptr<MethodResultProxy> result) {
#if defined(_WIN32)
  auto dit = d3d_renderers_.find(texture_id);
  if (dit == d3d_renderers_.end()) {
    // Not a D3D renderer (CPU path already active) — nothing to switch.
    result->Success(EncodableValue(EncodableMap{}));
    return;
  }
  FlutterVideoRendererD3D* d3d = dit->second.get();
  scoped_refptr<RTCVideoTrack> track = d3d->video_track();
  d3d->SetVideoTrack(nullptr);
  // Async unregister: the engine releases its reference (and stops touching
  // the texture) before the callback runs, so erasing here can't race an
  // in-flight composite on the raster thread.
  base_->textures_->UnregisterTexture(texture_id,
                                      [&, dit] { d3d_renderers_.erase(dit); });

  // Create a CPU pixel-buffer renderer under a fresh texture id and re-attach
  // the track, so streaming continues on the guaranteed-visible CPU path.
  auto texture = new RefCountedObject<FlutterVideoRenderer>();
  auto textureVariant =
      std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
          [texture](size_t width,
                    size_t height) -> const FlutterDesktopPixelBuffer* {
            return texture->CopyPixelBuffer(width, height);
          }));
  const int64_t new_id =
      base_->textures_->RegisterTexture(textureVariant.get());
  texture->initialize(base_->textures_, base_->messenger_,
                      base_->task_runner_, std::move(textureVariant), new_id);
  renderers_[new_id] = texture;
  if (track.get()) {
    texture->SetVideoTrack(track);
    texture->media_stream_id = d3d->media_stream_id;
  }
  renderer_status_set_backend("cpu");
  renderer_status_set_error(nullptr);
  EncodableMap params;
  params[EncodableValue("textureId")] = EncodableValue(new_id);
  result->Success(EncodableValue(params));
#else
  result->Error("videoRendererSwitchToCpu", "Windows only");
#endif
}

}  // namespace flutter_webrtc_plugin
