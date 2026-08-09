// flutter_video_renderer_d3d.cc
//
// See flutter_video_renderer_d3d.h for the design. The heavy lift here is
// running inside the engine's compositor: ObtainDescriptor() is invoked on the
// raster thread right before the engine draws the texture, so every D3D11 call
// below happens on our own device context (never on the engine's GL context —
// the shared surface is the only thing that crosses the boundary, opened by
// the engine via EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE).
#include "flutter_video_renderer_d3d.h"

#include <d3dcompiler.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

namespace flutter_webrtc_plugin {

// ---- Renderer logging gate (Dart toggles via setRendererLoggingEnabled) ----
namespace {
bool g_renderer_logging_enabled = false;
}  // namespace

// ---- Video shader filter settings (port of OpenNOW's videoShader.ts) ------
namespace {
std::mutex g_shader_settings_mu;
VideoShaderSettingsState g_shader_settings;
uint64_t g_shader_version = 0;
const auto g_start_time = std::chrono::steady_clock::now();
}  // namespace

void set_video_shader_settings(const VideoShaderSettingsState& settings) {
  std::lock_guard<std::mutex> lock(g_shader_settings_mu);
  g_shader_settings = settings;
  g_shader_settings.version = ++g_shader_version;
}

VideoShaderSettingsState video_shader_settings_snapshot() {
  std::lock_guard<std::mutex> lock(g_shader_settings_mu);
  return g_shader_settings;
}

// ---------------------------------------------------------------------------
// Renderer health status (read by the Dart renderer watchdog)
// ---------------------------------------------------------------------------
namespace {
std::atomic<const char*> g_status_backend{"cpu"};
std::atomic<uint64_t> g_status_composited{0};
std::mutex g_status_error_mu;
std::string g_status_error;
}  // namespace

void renderer_status_set_backend(const char* backend) {
  g_status_backend.store(backend != nullptr ? backend : "cpu");
}

void renderer_status_set_error(const char* error) {
  std::lock_guard<std::mutex> lock(g_status_error_mu);
  if (error == nullptr) {
    g_status_error.clear();
  } else {
    g_status_error = error;
  }
}

void renderer_status_mark_composited() {
  g_status_composited.fetch_add(1, std::memory_order_relaxed);
}

const char* renderer_status_backend() { return g_status_backend.load(); }

uint64_t renderer_status_composited() {
  return g_status_composited.load(std::memory_order_relaxed);
}

std::string renderer_status_error() {
  std::lock_guard<std::mutex> lock(g_status_error_mu);
  return g_status_error;
}

namespace {
// Defined below (after the shader/device helpers); the self-test needs it.
bool EnsureQuadCompiled(D3d11Quad* quad);
}  // namespace

// Runs on the plugin thread at texture creation. Catches the D3D11 failures
// that otherwise manifest as a silent black screen: device/shader init, shared
// texture creation, and — the closest in-process proxy for the engine's ANGLE
// import (EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE) — opening the shared handle
// on a second device of the same driver type (hardware or WARP).
bool D3d11RendererSelfTest() {
  D3d11Quad* quad = d3d11_quad();
  if (!EnsureQuadCompiled(quad)) {
    renderer_status_set_error(quad->compile_error);
    return false;
  }

  D3D11_TEXTURE2D_DESC td = {};
  td.Width = 2;
  td.Height = 2;
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  td.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> tex;
  if (FAILED(quad->device->CreateTexture2D(&td, nullptr, &tex))) {
    renderer_status_set_error("D3D11 self-test: CreateTexture2D failed");
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIResource> dxgi;
  HANDLE handle = nullptr;
  if (FAILED(tex.As(&dxgi)) || FAILED(dxgi->GetSharedHandle(&handle)) ||
      handle == nullptr) {
    renderer_status_set_error(
        "D3D11 self-test: legacy shared handle unavailable");
    return false;
  }

  // Open the handle on a second device of the SAME driver type the renderer
  // settled on (hardware or WARP) — what the engine's ANGLE compositor does
  // per composite. A cross-device open failure here means the same will fail
  // for ANGLE on this adapter/driver combo.
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                      D3D_FEATURE_LEVEL_11_0,
                                      D3D_FEATURE_LEVEL_10_1,
                                      D3D_FEATURE_LEVEL_10_0};
  Microsoft::WRL::ComPtr<ID3D11Device> dev2;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx2;
  HRESULT hr = D3D11CreateDevice(
      nullptr, quad->driver_type, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
      levels, sizeof(levels) / sizeof(levels[0]), D3D11_SDK_VERSION, &dev2,
      nullptr, &ctx2);
  if (FAILED(hr)) {
    renderer_status_set_error("D3D11 self-test: second device failed");
    return false;
  }
  Microsoft::WRL::ComPtr<ID3D11Texture2D> opened;
  hr = dev2->OpenSharedResource(handle, __uuidof(ID3D11Texture2D),
                                reinterpret_cast<void**>(
                                    opened.ReleaseAndGetAddressOf()));
  if (FAILED(hr) || opened == nullptr) {
    renderer_status_set_error(
        "D3D11 self-test: OpenSharedResource failed (adapter mismatch?)");
    return false;
  }

  renderer_status_set_error(nullptr);  // clear any stale error
  return true;
}

void set_renderer_logging_enabled(bool enabled) {
  g_renderer_logging_enabled = enabled;
}

bool renderer_logging_enabled() { return g_renderer_logging_enabled; }

// ---------------------------------------------------------------------------
// Shaders (HLSL 4.0 — works on every D3D11 feature level, down to FL 10.0).
// ---------------------------------------------------------------------------

// Fullscreen triangle generated from SV_VertexID — no vertex buffer / input
// layout needed. The V flip puts image row 0 (Y row 0) at the top of the
// render target: D3D11 clip y = +1 is the RT top, and uv.y = 0 samples Y row
// 0, so uv.y = 1 - pos.y maps image top → RT top. The engine samples external
// textures with row 0 = top of the widget (same convention as the CPU
// pixel-buffer path), which keeps the frame upright.
static const char* kVertexShader = R"(
struct VSOut {
  float4 pos : SV_POSITION;
  float2 uv : TEXCOORD0;
};
VSOut vs_main(uint id : SV_VertexID) {
  VSOut o;
  float2 pos = float2((id << 1) & 2, id & 2);
  o.pos = float4(pos * 2.0 - 1.0, 0.0, 1.0);
  o.uv = float2(pos.x, 1.0 - pos.y);
  return o;
}
)";

// I420 (3-plane) YUV→RGB, same coefficients as the Linux GL renderer. Y is
// full-res, U/V are half-res; bilinear filtering does the chroma upsampling.
static const char* kFragmentShaderI420 = R"(
Texture2D y_tex : register(t0);
Texture2D u_tex : register(t1);
Texture2D v_tex : register(t2);
SamplerState samp : register(s0);
struct VSOut {
  float4 pos : SV_POSITION;
  float2 uv : TEXCOORD0;
};
float4 ps_i420(VSOut i) : SV_TARGET {
  float y = y_tex.Sample(samp, i.uv).r;
  float u = u_tex.Sample(samp, i.uv).r - 0.5;
  float v = v_tex.Sample(samp, i.uv).r - 0.5;
  return float4(
    y + 1.403 * v,
    y - 0.344 * u - 0.714 * v,
    y + 1.770 * u,
    1.0
  );
}
)";

// NV12 (2-plane) variant for the zero-copy path: the interleaved UV plane is
// sampled as a single R8G8 texture (U in R, V in G) instead of two R8 planes.
static const char* kFragmentShaderNv12 = R"(
Texture2D y_tex : register(t0);
Texture2D uv_tex : register(t1);
SamplerState samp : register(s0);
struct VSOut {
  float4 pos : SV_POSITION;
  float2 uv : TEXCOORD0;
};
float4 ps_nv12(VSOut i) : SV_TARGET {
  float y = y_tex.Sample(samp, i.uv).r;
  float2 uv = uv_tex.Sample(samp, i.uv).rg;
  float u = uv.x - 0.5;
  float v = uv.y - 0.5;
  return float4(
    y + 1.403 * v,
    y - 0.344 * u - 0.714 * v,
    y + 1.770 * u,
    1.0
  );
}
)";

// Post-processing pixel shader in HLSL 4.0: CAS-style contrast-adaptive
// sharpening (or a uniform unsharp mask when sharpen_adaptive is off),
// brightness/contrast/saturation/vibrance color grading, and animated film
// grain. Samples the intermediate RGBA (YUV→RGB) texture with texel offsets;
// the uniforms arrive via a per-frame constant buffer (register b0).
static const char* kPostPixelShader = R"(
Texture2D rgba_tex : register(t0);
SamplerState samp : register(s0);
cbuffer PostParams : register(b0) {
  float2 texel_size;
  float sharpen;
  float saturation;
  float contrast;
  float brightness;
  float vibrance;
  float grain;
  float time;
  float sharpen_adaptive;
};
struct VSOut {
  float4 pos : SV_POSITION;
  float2 uv : TEXCOORD0;
};
float luma(float3 c) {
  return dot(c, float3(0.2126, 0.7152, 0.0722));
}
float hash(float2 p) {
  float3 p3 = frac(float3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return frac((p3.x + p3.y) * p3.z);
}
float3 cas_sharpen(float2 uv, float3 center, float amount) {
  float3 n = rgba_tex.Sample(samp, uv + float2(0.0, -texel_size.y)).rgb;
  float3 s = rgba_tex.Sample(samp, uv + float2(0.0,  texel_size.y)).rgb;
  float3 w = rgba_tex.Sample(samp, uv + float2(-texel_size.x, 0.0)).rgb;
  float3 e = rgba_tex.Sample(samp, uv + float2( texel_size.x, 0.0)).rgb;
  float3 mn = min(center, min(min(n, s), min(w, e)));
  float3 mx = max(center, max(max(n, s), max(w, e)));
  float3 amp = clamp(min(mn, 1.0 - mx) / max(mx, 1e-5), 0.0, 1.0);
  amp = sqrt(amp);
  float peak = lerp(-0.125, -0.2, amount);
  float3 weight = amp * peak;
  float3 result = (center + (n + s + w + e) * weight) / (1.0 + 4.0 * weight);
  return clamp(result, mn, mx);
}
float3 sharpen_uniform(float2 uv, float3 center, float amount) {
  float3 n = rgba_tex.Sample(samp, uv + float2(0.0, -texel_size.y)).rgb;
  float3 s = rgba_tex.Sample(samp, uv + float2(0.0,  texel_size.y)).rgb;
  float3 w = rgba_tex.Sample(samp, uv + float2(-texel_size.x, 0.0)).rgb;
  float3 e = rgba_tex.Sample(samp, uv + float2( texel_size.x, 0.0)).rgb;
  float3 blur = (n + s + w + e) * 0.25;
  // Plain unsharp mask: same strength everywhere. k matches the CAS edge
  // response (1x..4x of the center-minus-blur delta) so the two modes feel
  // comparable at the same slider value, minus the edge gating.
  float k = 1.0 + 3.0 * amount;
  return saturate(center + (center - blur) * k);
}
float4 ps_post(VSOut i) : SV_TARGET {
  float3 color = rgba_tex.Sample(samp, i.uv).rgb;
  if (sharpen > 0.001) {
    if (sharpen_adaptive > 0.5) {
      color = cas_sharpen(i.uv, color, sharpen);
    } else {
      color = sharpen_uniform(i.uv, color, sharpen);
    }
  }
  color *= brightness;
  color = (color - 0.5) * contrast + 0.5;
  float l = luma(color);
  color = lerp(float3(l, l, l), color, saturation);
  if (vibrance > 0.001) {
    float maxC = max(color.r, max(color.g, color.b));
    float minC = min(color.r, min(color.g, color.b));
    float sat = maxC - minC;
    float boost = vibrance * (1.0 - sat);
    color = lerp(float3(luma(color), luma(color), luma(color)), color,
                 1.0 + boost);
  }
  if (grain > 0.001) {
    float g = hash(i.pos.xy + frac(time) * 1024.0) - 0.5;
    color += g * grain * 0.12 * (0.3 + 0.7 * luma(color));
  }
  return float4(saturate(color), 1.0);
}
)";

namespace {

D3d11Quad g_quad;

bool CompileShader(const char* name,
                   const char* source,
                   const char* entry,
                   const char* target,
                   ID3DBlob** blob,
                   char* error,
                   size_t error_len) {
  ID3DBlob* error_blob = nullptr;
  const HRESULT hr =
      D3DCompile(source, strlen(source), name, nullptr, nullptr, entry, target,
                 D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, blob, &error_blob);
  if (FAILED(hr)) {
    if (error_blob != nullptr && error_blob->GetBufferSize() > 0) {
      const size_t n = error_blob->GetBufferSize() < error_len
                           ? error_blob->GetBufferSize()
                           : error_len - 1;
      std::memcpy(error, error_blob->GetBufferPointer(), n);
      error[n] = '\0';
    } else {
      std::snprintf(error, error_len, "D3DCompile failed (hr=%#lx)",
                    static_cast<unsigned long>(hr));
    }
    if (error_blob != nullptr) error_blob->Release();
    return false;
  }
  return true;
}

bool CompileProgram(D3d11Quad* quad) {
  ID3DBlob* vs_blob = nullptr;
  if (!CompileShader("flutter_webrtc_vs", kVertexShader, "vs_main", "vs_4_0",
                     &vs_blob, quad->compile_error,
                     sizeof(quad->compile_error))) {
    return false;
  }
  HRESULT hr = quad->device->CreateVertexShader(vs_blob->GetBufferPointer(),
                                                vs_blob->GetBufferSize(),
                                                nullptr, &quad->vs);
  vs_blob->Release();
  if (FAILED(hr)) {
    std::snprintf(quad->compile_error, sizeof(quad->compile_error),
                  "CreateVertexShader failed (hr=%#lx)",
                  static_cast<unsigned long>(hr));
    return false;
  }

  ID3DBlob* ps_blob = nullptr;
  if (!CompileShader("flutter_webrtc_ps_i420", kFragmentShaderI420,
                     "ps_i420", "ps_4_0", &ps_blob, quad->compile_error,
                     sizeof(quad->compile_error))) {
    return false;
  }
  hr = quad->device->CreatePixelShader(ps_blob->GetBufferPointer(),
                                       ps_blob->GetBufferSize(), nullptr,
                                       &quad->ps_i420);
  ps_blob->Release();
  if (FAILED(hr)) {
    std::snprintf(quad->compile_error, sizeof(quad->compile_error),
                  "CreatePixelShader(I420) failed (hr=%#lx)",
                  static_cast<unsigned long>(hr));
    return false;
  }

  ID3DBlob* ps_nv12_blob = nullptr;
  if (!CompileShader("flutter_webrtc_ps_nv12", kFragmentShaderNv12,
                     "ps_nv12", "ps_4_0", &ps_nv12_blob, quad->compile_error,
                     sizeof(quad->compile_error))) {
    return false;
  }
  hr = quad->device->CreatePixelShader(ps_nv12_blob->GetBufferPointer(),
                                       ps_nv12_blob->GetBufferSize(), nullptr,
                                       &quad->ps_nv12);
  ps_nv12_blob->Release();
  if (FAILED(hr)) {
    std::snprintf(quad->compile_error, sizeof(quad->compile_error),
                  "CreatePixelShader(NV12) failed (hr=%#lx)",
                  static_cast<unsigned long>(hr));
    return false;
  }

  // Post-processing (video shader filter) pixel shader + constant buffer.
  // Compiled unconditionally (cheap, once per process) so a later filter
  // enable never has to re-init mid-stream; the self-test validates it too.
  ID3DBlob* ps_post_blob = nullptr;
  if (!CompileShader("flutter_webrtc_ps_post", kPostPixelShader, "ps_post",
                     "ps_4_0", &ps_post_blob, quad->compile_error,
                     sizeof(quad->compile_error))) {
    return false;
  }
  hr = quad->device->CreatePixelShader(ps_post_blob->GetBufferPointer(),
                                       ps_post_blob->GetBufferSize(), nullptr,
                                       &quad->ps_post);
  ps_post_blob->Release();
  if (FAILED(hr)) {
    std::snprintf(quad->compile_error, sizeof(quad->compile_error),
                  "CreatePixelShader(post) failed (hr=%#lx)",
                  static_cast<unsigned long>(hr));
    return false;
  }
  D3D11_BUFFER_DESC cbd = {};
  cbd.ByteWidth = sizeof(PostShaderParams);
  cbd.Usage = D3D11_USAGE_DEFAULT;
  cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  hr = quad->device->CreateBuffer(&cbd, nullptr, &quad->post_cb);
  if (FAILED(hr)) {
    std::snprintf(quad->compile_error, sizeof(quad->compile_error),
                  "CreateBuffer(post cb) failed (hr=%#lx)",
                  static_cast<unsigned long>(hr));
    return false;
  }

  D3D11_SAMPLER_DESC sd = {};
  sd.Filter = D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;
  sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
  sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
  sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sd.MaxLOD = D3D11_FLOAT32_MAX;
  hr = quad->device->CreateSamplerState(&sd, &quad->sampler);
  if (FAILED(hr)) {
    std::snprintf(quad->compile_error, sizeof(quad->compile_error),
                  "CreateSamplerState failed (hr=%#lx)",
                  static_cast<unsigned long>(hr));
    return false;
  }

  quad->compiled = true;
  return true;
}

bool EnsureQuadCompiled(D3d11Quad* quad) {
  if (quad->compiled) return true;
  D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                D3D_FEATURE_LEVEL_11_0,
                                D3D_FEATURE_LEVEL_10_1,
                                D3D_FEATURE_LEVEL_10_0};
  D3D_FEATURE_LEVEL feature_level = D3D_FEATURE_LEVEL_11_0;
  const UINT create_flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  auto create_device = [&](D3D_DRIVER_TYPE type) {
    quad->device.Reset();
    quad->ctx.Reset();
    return D3D11CreateDevice(nullptr, type, nullptr, create_flags, levels,
                             sizeof(levels) / sizeof(levels[0]),
                             D3D11_SDK_VERSION, &quad->device, &feature_level,
                             &quad->ctx);
  };
  HRESULT hr = create_device(D3D_DRIVER_TYPE_HARDWARE);
  if (FAILED(hr)) {
    // VMs / remote-desktop / basic-display adapters can lack a hardware D3D11
    // driver. WARP (software rasterizer) still gives us the shared-texture
    // path — slower, but the GPU renderer works instead of going black.
    hr = create_device(D3D_DRIVER_TYPE_WARP);
    if (SUCCEEDED(hr)) quad->driver_type = D3D_DRIVER_TYPE_WARP;
  } else {
    quad->driver_type = D3D_DRIVER_TYPE_HARDWARE;
  }
  if (FAILED(hr) || quad->device == nullptr || quad->ctx == nullptr) {
    std::snprintf(quad->compile_error, sizeof(quad->compile_error),
                  "D3D11CreateDevice failed (hr=%#lx)",
                  static_cast<unsigned long>(hr));
    return false;
  }
  return CompileProgram(quad);
}

}  // namespace

D3d11Quad* d3d11_quad() { return &g_quad; }

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

FlutterVideoRendererD3D::~FlutterVideoRendererD3D() {
  // The engine releases the shared texture on unregister before we are
  // destroyed (the map entry is erased after the async unregister completes),
  // so the ComPtrs clean up on a thread that never touches the device context.
}

bool FlutterVideoRendererD3D::IsEnabled() {
#if defined(_WIN32)
  // MSVC deprecates std::getenv (C4996) and the Flutter Windows build treats
  // warnings as errors (/WX), so use the safe _dupenv_s variant here. (The
  // Linux GL renderer can keep std::getenv — GCC/Clang don't emit C4996.)
  char* value = nullptr;
  size_t len = 0;
  if (_dupenv_s(&value, &len, "OPENNOW_RENDERER") != 0 || value == nullptr) {
    return false;
  }
  const bool enabled = std::strcmp(value, "gl") == 0;
  std::free(value);
  return enabled;
#else
  const char* value = std::getenv("OPENNOW_RENDERER");
  return value != nullptr && std::strcmp(value, "gl") == 0;
#endif
}

void FlutterVideoRendererD3D::initialize(TextureRegistrar* registrar,
                                         BinaryMessenger* messenger,
                                         TaskRunner* task_runner,
                                         std::unique_ptr<flutter::TextureVariant> texture,
                                         int64_t trxture_id) {
  registrar_ = registrar;
  texture_ = std::move(texture);
  texture_id_ = trxture_id;
  std::string channel_name =
      "FlutterWebRTC/Texture" + std::to_string(texture_id_);
  event_channel_ =
      EventChannelProxy::Create(messenger, task_runner, channel_name);
}

void FlutterVideoRendererD3D::OnFrame(scoped_refptr<RTCVideoFrame> frame) {
  if (!first_frame_rendered) {
    EncodableMap params;
    params[EncodableValue("event")] = "didFirstFrameRendered";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    event_channel_->Success(EncodableValue(params));
    first_frame_rendered = true;
    if (renderer_logging_enabled()) {
      std::fprintf(stderr,
                   "[d3drender] first frame received %dx%d (texture %lld)\n",
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
  {
    std::lock_guard<std::mutex> lock(mutex_);
    frame_ = frame;
  }
  registrar_->MarkTextureFrameAvailable(texture_id_);
}

void FlutterVideoRendererD3D::SetVideoTrack(scoped_refptr<RTCVideoTrack> track) {
  if (track_ != track) {
    if (track_)
      track_->RemoveRenderer(this);
    track_ = track;
    last_frame_size_ = {0, 0};
    first_frame_rendered = false;
    if (track_) {
      track_->AddRenderer(this);
      if (renderer_logging_enabled()) {
        std::fprintf(stderr, "[d3drender] video track attached (id=%s)\n",
                     track_->id().std_string().c_str());
      }
    } else if (renderer_logging_enabled()) {
      std::fprintf(stderr, "[d3drender] video track detached\n");
    }
  }
}

bool FlutterVideoRendererD3D::CheckMediaStream(std::string mediaId) {
  if (0 == mediaId.size() || 0 == media_stream_id.size()) {
    return false;
  }
  return mediaId == media_stream_id;
}

bool FlutterVideoRendererD3D::CheckVideoTrack(std::string mediaId) {
  if (0 == mediaId.size() || !track_) {
    return false;
  }
  return mediaId == track_->id().std_string();
}

void FlutterVideoRendererD3D::FillDescriptor(int width, int height) {
  descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  descriptor_.handle = static_cast<void*>(shared_handle_);
  descriptor_.width = static_cast<size_t>(d3d_width_);
  descriptor_.height = static_cast<size_t>(d3d_height_);
  descriptor_.visible_width = static_cast<size_t>(width);
  descriptor_.visible_height = static_cast<size_t>(height);
  descriptor_.format = kFlutterDesktopPixelFormatRGBA8888;
  descriptor_.release_callback = nullptr;
  descriptor_.release_context = nullptr;
}

const FlutterDesktopGpuSurfaceDescriptor* FlutterVideoRendererD3D::ObtainDescriptor(
    size_t width,
    size_t height) {
  // NOTE: runs on the Flutter raster thread. We must not hold the mutex across
  // D3D11 work that could block OnFrame; grab the frame ref, then render.
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

  // Snapshot the shader filter settings for this composite. The post pass
  // (and which texture the engine samples) depends on it; the version joins
  // the frame-cache key so a live slider change re-renders immediately.
  const VideoShaderSettingsState shader = video_shader_settings_snapshot();
  const bool post_active = shader.active();

  // Frame cache: the engine re-composites the scene for UI repaints (stats
  // overlay tick, session timer, chrome hover) that carry the SAME decoded
  // frame. Re-running the full-screen YUV→RGB pass for those costs real
  // raster-thread time on a weak iGPU — return the already-rendered texture
  // untouched instead (the engine samples the shared surface again as-is).
  if (rendered_once_ && last_rendered_frame_ == frame &&
      last_rendered_width_ == w && last_rendered_height_ == h &&
      last_rendered_shader_version_ == shader.version &&
      last_rendered_post_active_ == post_active) {
    raster_cache_hits_++;
    FillDescriptor(w, h);
    renderer_status_mark_composited();
    return &descriptor_;
  }

  const auto t_render_start = std::chrono::steady_clock::now();
  const bool ok = EnsureResources(w, h);
  bool rendered = false;
  const void* native = nullptr;
  if (ok) {
#if defined(LIBWEBRTC_D3D11_CUSTOM)
    // Zero-copy path first: if the frame carries a D3D11 texture descriptor
    // (custom libwebrtc kNative buffer), open the decoder's shared texture and
    // composite it with no CPU copy at all. Falls back to the I420 plane
    // upload for plain I420 frames (stock FFmpeg path).
    native = frame->NativeD3D11Handle();
    if (native != nullptr) {
      const RtcD3D11TextureDescriptor* desc =
          static_cast<const RtcD3D11TextureDescriptor*>(native);
      rendered = RenderNativeFrame(desc, w, h, post_active);
    }
#endif
    // kNative frames have no CPU I420 view — never feed their (null) planes
    // to the upload path when the zero-copy import fails; skip the composite
    // instead (the engine keeps the last good frame, and a fresh keyframe
    // retries). Plain I420 frames take the upload path as before.
    if (!rendered && native == nullptr) {
      rendered = RenderI420Frame(frame->DataY(), frame->StrideY(),
                                 frame->DataU(), frame->StrideU(),
                                 frame->DataV(), frame->StrideV(), w, h,
                                 post_active);
    }
    if (rendered) {
      last_rendered_frame_ = frame;
      last_rendered_width_ = w;
      last_rendered_height_ = h;
      last_rendered_shader_version_ = shader.version;
      last_rendered_post_active_ = post_active;
      rendered_once_ = true;
    }
    if (!path_reported_) {
      path_reported_ = true;
      LogPath(rendered ? "zero-copy D3D11 texture (no CPU copy)"
                       : "YUV plane upload + GPU shader");
    }
  }

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

  if (!rendered) {
    // Record WHY the D3D11 path failed so the Dart watchdog's getRendererStatus
    // can log it (and knows the path never produced a compositable frame).
    if (!ok) {
      D3d11Quad* quad = d3d11_quad();
      renderer_status_set_error(
          quad->compile_error[0] ? quad->compile_error
                                 : "D3D11 resources unavailable");
    } else if (native != nullptr) {
      renderer_status_set_error(
          "D3D11 zero-copy import failed (adapter mismatch?)");
    } else {
      renderer_status_set_error("D3D11 render pass failed");
    }
    return nullptr;
  }
  FillDescriptor(w, h);
  renderer_status_mark_composited();
  return &descriptor_;
}

void FlutterVideoRendererD3D::LogPath(const char* path) {
  if (!renderer_logging_enabled()) return;
  std::fprintf(stderr, "[d3drender] compositing via %s\n", path);
}

bool FlutterVideoRendererD3D::EnsureResources(int width, int height) {
  D3d11Quad* quad = d3d11_quad();
  if (!quad->compiled && !EnsureQuadCompiled(quad)) {
    if (renderer_logging_enabled()) {
      std::fprintf(stderr, "[d3drender] D3D11 init failed: %s\n",
                   quad->compile_error);
    }
    return false;
  }

  const bool size_changed = d3d_width_ != width || d3d_height_ != height;
  const int uv_w = (width + 1) / 2;
  const int uv_h = (height + 1) / 2;

  if (size_changed || y_tex_ == nullptr) {
    // Y/U/V R8 plane textures (DEFAULT usage; updated via UpdateSubresource).
    auto create_plane = [&](ID3D11Texture2D** tex, ID3D11ShaderResourceView** srv,
                            int w, int h) -> bool {
      D3D11_TEXTURE2D_DESC td = {};
      td.Width = static_cast<UINT>(w);
      td.Height = static_cast<UINT>(h);
      td.MipLevels = 1;
      td.ArraySize = 1;
      td.Format = DXGI_FORMAT_R8_UNORM;
      td.SampleDesc.Count = 1;
      td.Usage = D3D11_USAGE_DEFAULT;
      td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
      if (FAILED(quad->device->CreateTexture2D(&td, nullptr, tex))) {
        return false;
      }
      D3D11_SHADER_RESOURCE_VIEW_DESC sd = {};
      sd.Format = DXGI_FORMAT_R8_UNORM;
      sd.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
      sd.Texture2D.MipLevels = 1;
      return SUCCEEDED(quad->device->CreateShaderResourceView(*tex, &sd, srv));
    };
    y_tex_.Reset();
    u_tex_.Reset();
    v_tex_.Reset();
    y_srv_.Reset();
    u_srv_.Reset();
    v_srv_.Reset();
    if (!create_plane(y_tex_.GetAddressOf(), y_srv_.GetAddressOf(), width,
                      height) ||
        !create_plane(u_tex_.GetAddressOf(), u_srv_.GetAddressOf(), uv_w,
                      uv_h) ||
        !create_plane(v_tex_.GetAddressOf(), v_srv_.GetAddressOf(), uv_w,
                      uv_h)) {
      return false;
    }

    // Intermediate RGBA target for the YUV→RGB pass (non-shared — the engine
    // never sees it). Carries an SRV so the post pass can sample it.
    rgba_tex_.Reset();
    rgba_rtv_.Reset();
    rgba_srv_.Reset();
    D3D11_TEXTURE2D_DESC rt = {};
    rt.Width = static_cast<UINT>(width);
    rt.Height = static_cast<UINT>(height);
    rt.MipLevels = 1;
    rt.ArraySize = 1;
    rt.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    rt.SampleDesc.Count = 1;
    rt.Usage = D3D11_USAGE_DEFAULT;
    rt.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    if (FAILED(quad->device->CreateTexture2D(&rt, nullptr, &rgba_tex_))) {
      return false;
    }
    if (FAILED(quad->device->CreateRenderTargetView(
            rgba_tex_.Get(), nullptr, &rgba_rtv_))) {
      return false;
    }
    if (FAILED(quad->device->CreateShaderResourceView(
            rgba_tex_.Get(), nullptr, &rgba_srv_))) {
      return false;
    }

    // Final RGBA shared render target handed to the engine. The legacy SHARED
    // misc flag is required so ANGLE can open the handle with
    // EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE on its own device.
    final_tex_.Reset();
    final_rtv_.Reset();
    D3D11_TEXTURE2D_DESC ft = {};
    ft.Width = static_cast<UINT>(width);
    ft.Height = static_cast<UINT>(height);
    ft.MipLevels = 1;
    ft.ArraySize = 1;
    ft.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    ft.SampleDesc.Count = 1;
    ft.Usage = D3D11_USAGE_DEFAULT;
    ft.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ft.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    if (FAILED(quad->device->CreateTexture2D(&ft, nullptr, &final_tex_))) {
      return false;
    }
    if (FAILED(quad->device->CreateRenderTargetView(
            final_tex_.Get(), nullptr, &final_rtv_))) {
      return false;
    }
    Microsoft::WRL::ComPtr<IDXGIResource> dxgi;
    if (FAILED(final_tex_.As(&dxgi)) ||
        FAILED(dxgi->GetSharedHandle(&shared_handle_))) {
      return false;
    }

    d3d_width_ = width;
    d3d_height_ = height;
  }
  return true;
}

bool FlutterVideoRendererD3D::RenderI420Frame(const uint8_t* y,
                                              int y_stride,
                                              const uint8_t* u,
                                              int u_stride,
                                              const uint8_t* v,
                                              int v_stride,
                                              int width,
                                              int height,
                                              bool post_active) {
  D3d11Quad* quad = d3d11_quad();

  // 1.5 B/px CPU→GPU upload of the three planes (vs 4 B/px for the CPU path's
  // ARGB convert + upload). Row pitch = the frame's stride; UpdateSubresource
  // copies row by row into the tightly-packed R8 textures.
  quad->ctx->UpdateSubresource(y_tex_.Get(), 0, nullptr, y,
                               static_cast<UINT>(y_stride), 0);
  quad->ctx->UpdateSubresource(u_tex_.Get(), 0, nullptr, u,
                               static_cast<UINT>(u_stride), 0);
  quad->ctx->UpdateSubresource(v_tex_.Get(), 0, nullptr, v,
                               static_cast<UINT>(v_stride), 0);

  // Filter off: draw YUV→RGB straight into the shared texture the engine
  // composites. Filter on: draw into the intermediate so the post pass can
  // sample it, then run the post pass into the shared texture.
  ID3D11ShaderResourceView* srvs[] = {y_srv_.Get(), u_srv_.Get(), v_srv_.Get()};
  quad->ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  quad->ctx->VSSetShader(quad->vs.Get(), nullptr, 0);
  quad->ctx->PSSetShader(quad->ps_i420.Get(), nullptr, 0);
  quad->ctx->PSSetShaderResources(0, 3, srvs);
  quad->ctx->PSSetSamplers(0, 1, quad->sampler.GetAddressOf());
  ID3D11RenderTargetView* rtvs[] = {
      post_active ? rgba_rtv_.Get() : final_rtv_.Get()};
  quad->ctx->OMSetRenderTargets(1, rtvs, nullptr);
  D3D11_VIEWPORT vp = {0.0f, 0.0f, static_cast<float>(width),
                       static_cast<float>(height), 0.0f, 1.0f};
  quad->ctx->RSSetViewports(1, &vp);
  quad->ctx->Draw(3, 0);
  if (post_active) {
    if (!RenderPostPass(width, height)) return false;
  }
  // Submit the draw before the engine samples the surface on its own device.
  quad->ctx->Flush();
  return true;
}

bool FlutterVideoRendererD3D::RenderPostPass(int width, int height) {
  D3d11Quad* quad = d3d11_quad();
  if (!quad->ps_post.Get() || !quad->post_cb.Get()) {
    return false;
  }
  const VideoShaderSettingsState s = video_shader_settings_snapshot();
  const double elapsed_s = std::chrono::duration<double>(
                               std::chrono::steady_clock::now() - g_start_time)
                               .count();
  PostShaderParams params = {};
  params.texel_x = 1.0f / width;
  params.texel_y = 1.0f / height;
  params.sharpen = s.sharpen / 100.0f;
  params.sharpen_adaptive = s.sharpenAdaptive ? 1.0f : 0.0f;
  params.saturation = s.saturation / 100.0f;
  params.contrast = s.contrast / 100.0f;
  params.brightness = s.brightness / 100.0f;
  params.vibrance = s.vibrance / 100.0f;
  params.grain = s.grain / 100.0f;
  params.time = static_cast<float>(elapsed_s);
  quad->ctx->UpdateSubresource(quad->post_cb.Get(), 0, nullptr, &params, 0, 0);

  ID3D11ShaderResourceView* srvs[] = {rgba_srv_.Get()};
  quad->ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  quad->ctx->VSSetShader(quad->vs.Get(), nullptr, 0);
  quad->ctx->PSSetShader(quad->ps_post.Get(), nullptr, 0);
  quad->ctx->PSSetConstantBuffers(0, 1, quad->post_cb.GetAddressOf());
  quad->ctx->PSSetShaderResources(0, 1, srvs);
  quad->ctx->PSSetSamplers(0, 1, quad->sampler.GetAddressOf());
  ID3D11RenderTargetView* rtvs[] = {final_rtv_.Get()};
  quad->ctx->OMSetRenderTargets(1, rtvs, nullptr);
  D3D11_VIEWPORT vp = {0.0f, 0.0f, static_cast<float>(width),
                       static_cast<float>(height), 0.0f, 1.0f};
  quad->ctx->RSSetViewports(1, &vp);
  quad->ctx->Draw(3, 0);
  return true;
}

#if defined(LIBWEBRTC_D3D11_CUSTOM)
bool FlutterVideoRendererD3D::RenderNativeFrame(
    const RtcD3D11TextureDescriptor* desc,
    int width,
    int height,
    bool post_active) {
  if (desc == nullptr || desc->handle == nullptr ||
      desc->format != RtcD3D11TextureFormat::kNv12) {
    return false;
  }
  D3d11Quad* quad = d3d11_quad();

  // Open the decoder's shared NV12 texture (created with
  // D3D11_RESOURCE_MISC_SHARED on the same GPU) on our device.
  Microsoft::WRL::ComPtr<ID3D11Texture2D> tex;
  const HRESULT hr = quad->device->OpenSharedResource(
      desc->handle, __uuidof(ID3D11Texture2D),
      reinterpret_cast<void**>(tex.ReleaseAndGetAddressOf()));
  if (FAILED(hr) || tex == nullptr) {
    return false;
  }

  if (tex != native_tex_) {
    native_tex_ = tex;
    nv12_y_srv_.Reset();
    nv12_uv_srv_.Reset();

    // NV12 plane 0 (Y) as R8.
    D3D11_SHADER_RESOURCE_VIEW_DESC yd = {};
    yd.Format = DXGI_FORMAT_R8_UNORM;
    yd.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    yd.Texture2D.MipLevels = 1;
    if (FAILED(quad->device->CreateShaderResourceView(
            tex.Get(), &yd, &nv12_y_srv_))) {
      return false;
    }
    // NV12 plane 1 (interleaved UV) as R8G8.
    D3D11_SHADER_RESOURCE_VIEW_DESC uv = {};
    uv.Format = DXGI_FORMAT_R8G8_UNORM;
    uv.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    uv.Texture2D.MipLevels = 1;
    if (FAILED(quad->device->CreateShaderResourceView(
            tex.Get(), &uv, &nv12_uv_srv_))) {
      return false;
    }
  }

  ID3D11ShaderResourceView* srvs[] = {nv12_y_srv_.Get(), nv12_uv_srv_.Get()};
  quad->ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  quad->ctx->VSSetShader(quad->vs.Get(), nullptr, 0);
  quad->ctx->PSSetShader(quad->ps_nv12.Get(), nullptr, 0);
  quad->ctx->PSSetShaderResources(0, 2, srvs);
  quad->ctx->PSSetSamplers(0, 1, quad->sampler.GetAddressOf());
  // Same target split as RenderI420Frame: intermediate when the post pass
  // runs, shared final texture when the filter is off.
  ID3D11RenderTargetView* rtvs[] = {
      post_active ? rgba_rtv_.Get() : final_rtv_.Get()};
  quad->ctx->OMSetRenderTargets(1, rtvs, nullptr);
  D3D11_VIEWPORT vp = {0.0f, 0.0f, static_cast<float>(width),
                       static_cast<float>(height), 0.0f, 1.0f};
  quad->ctx->RSSetViewports(1, &vp);
  quad->ctx->Draw(3, 0);
  if (post_active) {
    if (!RenderPostPass(width, height)) return false;
  }
  quad->ctx->Flush();
  return true;
}
#endif  // LIBWEBRTC_D3D11_CUSTOM

void FlutterVideoRendererD3D::MaybeLogRasterStats() {
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
               "[d3drender] raster avg %.2f ms/frame  max %.2f ms  "
               "n=%llu  cache hits=%llu\n",
               avg, raster_max_ms_,
               static_cast<unsigned long long>(raster_frames_),
               static_cast<unsigned long long>(raster_cache_hits_));
  raster_frames_ = 0;
  raster_total_ms_ = 0;
  raster_max_ms_ = 0;
  raster_cache_hits_ = 0;
}

}  // namespace flutter_webrtc_plugin
