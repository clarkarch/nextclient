// d3d11_video_decoder.cc
//
// GStreamer-backed D3D11VA H.264 hardware decoder for libwebrtc (m144 API),
// plus a VideoDecoderFactory that prefers it and falls back to the built-in
// FFmpeg software decoder. The Windows counterpart of vaapi_patch's
// vaapi_video_decoder.cc (same structure, d3d11h264dec instead of vah264dec).
//
// Pipeline:
//   appsrc -> h264parse -> d3d11h264dec -> appsink (NV12)
//
// d3d11h264dec (gst-plugins-bad) decodes on the GPU via D3D11VA. When the
// element offers video/x-raw(memory:D3D11Memory) on its src pad we request it
// in the caps filter, so appsink receives D3D11-memory-backed NV12 buffers,
// and each decoded surface is exported as a legacy DXGI shared handle into a
// libwebrtc::D3d11VideoBuffer (kNative) so the Windows renderer
// (FlutterVideoRendererD3D, OPENNOW_RENDERER=gl) opens the texture on its own
// device and composites it with ZERO CPU involvement:
//   Tier 1 — direct export: the element allocated MISC_SHARED textures
//            (dormant with stock d3d11h264dec, which does not).
//   Tier 2 — GPU shared copy: blit the texture slice into a MISC_SHARED copy
//            with CopySubresourceRegion on the element's device and export
//            the copy's handle. GPU-only; never touches CPU pixels. This is
//            the path stock d3d11h264dec takes.
//   Tier 3 — CPU fallback: NV12 -> I420 readback (only when neither export
//            works, e.g. no usable D3D11 device).
//
// WebRTC hands us AVCC (length-prefixed) access units; we convert them to
// Annex-B (start codes) and re-inject SPS/PPS ahead of IDR keyframes, then
// push each complete access unit into appsrc (see h264_bitstream.h).
//
// Switch: setting OPENNOW_DECODER=software forces the software fallback.
//
// This file is Windows-only: it includes Windows/D3D11 and gst-plugins-bad's
// gstd3d11memory.h, none of which exist on Linux/macOS. The whole body is
// guarded so the d3d11_patch can be layered onto the same libwebrtc wrapper
// that vaapi_patch already patches (the wrapper is built for several OSes from
// one tree; on non-Windows the source compiles to nothing).
#include "d3d11_video_decoder.h"

#if defined(WEBRTC_WIN)

#include <d3d11.h>
#include <dxgi.h>
#include <windows.h>
#include <wrl/client.h>  // Microsoft::WRL::ComPtr

#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/d3d11/gstd3d11device.h>
#include <gst/d3d11/gstd3d11memory.h>
#include <gst/gst.h>
#include <gst/video/video-frame.h>
#include <gst/video/video-info.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "api/make_ref_counted.h"
#include "api/scoped_refptr.h"
#include "api/video/encoded_image.h"
#include "api/video/i420_buffer.h"
#include "api/video/video_frame.h"
#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_decoder.h"
#include "d3d11_video_buffer.h"
#include "h264_bitstream.h"
#include "modules/video_coding/include/video_error_codes.h"
#include "rtc_base/logging.h"

namespace libwebrtc {
namespace {

constexpr char kDecoderImplementation[] = "GStreamerD3d11H264";

bool ForceSoftwareDecoder() {
#if defined(_WIN32)
  // MSVC deprecates std::getenv (C4996) and the wrapper build treats warnings
  // as errors; use the safe _dupenv_s variant (same fix as the D3D renderer's
  // IsEnabled()).
  char* value = nullptr;
  size_t len = 0;
  if (_dupenv_s(&value, &len, "OPENNOW_DECODER") != 0 || value == nullptr) {
    return false;
  }
  const bool force = std::strcmp(value, "software") == 0;
  std::free(value);
  return force;
#else
  const char* value = getenv("OPENNOW_DECODER");
  return value != nullptr && std::strcmp(value, "software") == 0;
#endif
}

// Resolves the D3D11 H.264 decoder element. d3d11h264dec lives in
// gst-plugins-bad; a GStreamer runtime with the d3d11 plugin is required on
// the client machine. Returns nullptr if it is not installed.
const char* D3d11DecoderElement() {
  static const char* element = []() -> const char* {
    gst_init(nullptr, nullptr);
    GstElementFactory* factory = gst_element_factory_find("d3d11h264dec");
    if (factory != nullptr) {
      gst_object_unref(factory);
      return "d3d11h264dec";
    }
    return nullptr;
  }();
  return element;
}

bool D3d11ElementAvailable() { return D3d11DecoderElement() != nullptr; }

// Whether the decoder element's src pad template offers the D3D11Memory caps
// feature (D3D11 texture-backed buffers). d3d11h264dec advertises
// video/x-raw(memory:D3D11Memory) alongside plain system-memory NV12;
// requesting the feature in the caps filter makes appsink receive D3D11
// buffers so OnSample can export the texture's shared handle and the renderer
// takes the zero-copy path. The check is a template caps intersection so
// builds that do NOT offer the feature keep the plain-NV12 CPU pipeline
// instead of failing negotiation.
bool D3d11ElementOffersD3d11Memory(const char* element_name) {
  GstElementFactory* factory = gst_element_factory_find(element_name);
  if (factory == nullptr) return false;
  bool offers = false;
  const GList* templates =
      gst_element_factory_get_static_pad_templates(factory);
  for (const GList* it = templates; it != nullptr; it = it->next) {
    const GstStaticPadTemplate* tmpl =
        static_cast<const GstStaticPadTemplate*>(it->data);
    if (tmpl == nullptr || tmpl->direction != GST_PAD_SRC) continue;
    GstCaps* templ_caps =
        gst_static_caps_get(const_cast<GstStaticCaps*>(&tmpl->static_caps));
    GstCaps* d3d11_caps =
        gst_caps_from_string("video/x-raw(memory:D3D11Memory)");
    GstCaps* intersection = gst_caps_intersect(templ_caps, d3d11_caps);
    if (!gst_caps_is_empty(intersection)) offers = true;
    gst_caps_unref(intersection);
    gst_caps_unref(d3d11_caps);
    gst_caps_unref(templ_caps);
    if (offers) break;
  }
  gst_object_unref(factory);
  return offers;
}

class GstD3d11VideoDecoder : public webrtc::VideoDecoder {
 public:
  GstD3d11VideoDecoder() = default;
  ~GstD3d11VideoDecoder() override { Release(); }

  bool Configure(const Settings& settings) override {
    (void)settings;
    std::lock_guard<std::mutex> lock(mutex_);
    if (pipeline_ != nullptr) return true;
    return CreatePipelineLocked();
  }

  int32_t Decode(const webrtc::EncodedImage& input_image, bool missing_frames,
                 int64_t render_time_ms) override {
    if (missing_frames) {
      return WEBRTC_VIDEO_CODEC_OK_REQUEST_KEYFRAME;
    }
    const uint8_t* data = input_image.data();
    if (data == nullptr || input_image.size() == 0) {
      return WEBRTC_VIDEO_CODEC_OK_REQUEST_KEYFRAME;
    }
    // RTP timestamps are 90 kHz; convert to nanoseconds for GStreamer PTS.
    const uint32_t rtp_ts = input_image.RtpTimestamp();
    const uint64_t pts_ns =
        static_cast<guint64>(rtp_ts) * 1000000000ULL / 90000;
    // Record the render_time_ms WebRTC passed us for this RTP timestamp so
    // OnSample() can stamp it back onto the decoded VideoFrame. WebRTC's
    // VCMDecodedFrameCallback matches decoded frames against frame_infos_ by
    // RTP timestamp AND render_time_ms; omitting render_time_ms (default 0)
    // makes every match fail and the frame is silently dropped before the
    // renderer — black screen despite a healthy decoder. Bounded + cleared
    // on Release() to avoid unbounded growth across long sessions.
    {
      std::lock_guard<std::mutex> rtlock(render_time_mu_);
      render_times_[rtp_ts] = render_time_ms;
      if (render_times_.size() > kMaxRenderTimeEntries) {
        render_times_.erase(render_times_.begin());
      }
    }
    bool is_keyframe = false;

    // Serialize the whole decode path (converter_, pending_ and the appsrc
    // push) against Release(), which tears the pipeline down under the same
    // mutex_. The pipeline_ null guard also catches late frames that arrive
    // after teardown.
    std::lock_guard<std::mutex> lock(mutex_);
    if (pipeline_ == nullptr) {
      return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
    }

    // Warm path: SPS/PPS already captured — convert and push immediately.
    if (converter_.HasParameterSets()) {
      std::vector<uint8_t> annexb;
      if (!converter_.Convert(data, input_image.size(), &annexb,
                              &is_keyframe)) {
        RTC_LOG(LS_ERROR) << "Malformed H.264 access unit";
        return WEBRTC_VIDEO_CODEC_ERROR;
      }
      if (annexb.empty()) return WEBRTC_VIDEO_CODEC_OK;  // param-set-only AU
      return PushLocked(annexb.data(), annexb.size(), pts_ns);
    }

    // Cold path: no parameter sets yet. Converting this AU may capture them
    // (the converter caches in-band SPS/PPS from any AU, not just keyframes).
    std::vector<uint8_t> annexb;
    if (!converter_.Convert(data, input_image.size(), &annexb, &is_keyframe)) {
      RTC_LOG(LS_ERROR) << "Malformed H.264 access unit";
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
    if (converter_.HasParameterSets()) {
      // Cache just warmed — flush the AUs held so far (re-converting them with
      // a warm cache prepends SPS/PPS ahead of any held keyframes), then push
      // this one.
      FlushPendingLocked();
      if (annexb.empty()) return WEBRTC_VIDEO_CODEC_OK;
      return PushLocked(annexb.data(), annexb.size(), pts_ns);
    }

    // Still no SPS/PPS: hold the RAW AU until they appear. Pushing a keyframe
    // without SPS/PPS makes h264parse fail the first push with
    // not-negotiated, which poisons the whole pipeline (stuck PAUSED, zero
    // frames). Holding keeps the pipeline healthy and ready for the first
    // parameter-set frame; keyframes get SPS/PPS re-injected at flush time.
    pending_.push_back(PendingAu{
        std::vector<uint8_t>(data, data + input_image.size()), pts_ns,
        is_keyframe});
    pending_bytes_ += input_image.size();
    if (pending_.size() > kMaxPendingFrames ||
        pending_bytes_ > kMaxPendingBytes) {
      const size_t dropped = pending_.front().raw.size();
      const bool dropped_keyframe = pending_.front().keyframe;
      pending_.pop_front();
      pending_bytes_ -= dropped;
      // Does the queue still hold a keyframe? If not, none is in flight —
      // request a fresh IDR so the server resends SPS/PPS. No PLI spam: the
      // request fires only when a keyframe was dropped OR none is held.
      bool has_keyframe = false;
      for (const auto& au : pending_) {
        if (au.keyframe) {
          has_keyframe = true;
          break;
        }
      }
      RTC_LOG(LS_WARNING)
          << "GstD3D11: holding for SPS/PPS; dropping oldest AU (pending="
          << pending_.size() << ", " << pending_bytes_ << " bytes)";
      return (dropped_keyframe || !has_keyframe)
                 ? WEBRTC_VIDEO_CODEC_OK_REQUEST_KEYFRAME
                 : WEBRTC_VIDEO_CODEC_OK;
    }
    return WEBRTC_VIDEO_CODEC_OK;
  }

  int32_t RegisterDecodeCompleteCallback(
      webrtc::DecodedImageCallback* callback) override {
    std::lock_guard<std::mutex> lock(callback_mutex_);
    decoded_callback_ = callback;
    return WEBRTC_VIDEO_CODEC_OK;
  }

  int32_t Release() override {
    // Note: Release() deliberately uses mutex_ (not callback_mutex_) so it
    // never blocks on the GStreamer streaming thread, which takes
    // callback_mutex_ in OnSample(). set_state(NULL) below can wait for that
    // thread to drain; holding only mutex_ here avoids a teardown deadlock.
    std::lock_guard<std::mutex> lock(mutex_);
    if (pipeline_ != nullptr) {
      // Signal the GLib context thread to stop and join it before tearing
      // down the pipeline. stop_/wakeup is race-free: g_main_loop_quit()
      // called before the loop thread started would have been lost.
      stop_.store(true);
      if (main_context_ != nullptr) {
        g_main_context_wakeup(main_context_);
      }
      if (main_loop_thread_ != nullptr && main_loop_thread_->joinable()) {
        main_loop_thread_->join();
      }
      delete main_loop_thread_;
      main_loop_thread_ = nullptr;

      // The context thread has exited, so no bus handler can race with us.
      if (bus_watch_source_ != nullptr) {
        g_source_destroy(bus_watch_source_);
        g_source_unref(bus_watch_source_);
        bus_watch_source_ = nullptr;
      }
      if (bus_ != nullptr) {
        gst_object_unref(bus_);
        bus_ = nullptr;
      }

      gst_element_set_state(pipeline_, GST_STATE_NULL);

      if (main_context_ != nullptr) {
        g_main_context_unref(main_context_);
        main_context_ = nullptr;
      }

      // gst_bin_get_by_name() returned new refs we must release; the bin
      // unref alone does not free the elements we hold references to.
      if (appsrc_ != nullptr) gst_object_unref(appsrc_);
      if (appsink_ != nullptr) gst_object_unref(appsink_);
      gst_object_unref(pipeline_);
      pipeline_ = nullptr;
      appsrc_ = nullptr;
      appsink_ = nullptr;
    }
    // Drop AUs held while waiting for SPS/PPS and clear the converter's
    // parameter-set cache so a reused decoder starts clean for a new stream.
    pending_.clear();
    pending_bytes_ = 0;
    push_failures_ = 0;
    converter_.Reset();
    {
      std::lock_guard<std::mutex> rtlock(render_time_mu_);
      render_times_.clear();
    }
    return WEBRTC_VIDEO_CODEC_OK;
  }

  webrtc::VideoDecoder::DecoderInfo GetDecoderInfo() const override {
    webrtc::VideoDecoder::DecoderInfo info;
    info.implementation_name = kDecoderImplementation;
    info.is_hardware_accelerated = true;
    return info;
  }

  const char* ImplementationName() const override {
    return kDecoderImplementation;
  }

 private:
  bool CreatePipelineLocked() {
    gst_init(nullptr, nullptr);
    const char* decoder_element = D3d11DecoderElement();
    if (decoder_element == nullptr) {
      RTC_LOG(LS_ERROR)
          << "No D3D11 H.264 decoder element found (d3d11h264dec — is the "
             "GStreamer d3d11 plugin installed?)";
      return false;
    }
    GError* error = nullptr;
    char pipeline_desc[256];
    // d3d11h264dec natively outputs NV12; when it offers D3D11Memory we
    // request the feature in the caps filter so appsink receives D3D11
    // texture-backed buffers (zero-copy export in OnSample). Without it, the
    // pipeline settles on plain NV12 and every frame takes the CPU path.
    const bool d3d11_memory = D3d11ElementOffersD3d11Memory(decoder_element);
    std::snprintf(pipeline_desc, sizeof(pipeline_desc),
                  "appsrc name=src ! h264parse ! %s ! "
                  "video/x-raw%s,format=NV12 ! appsink name=sink",
                  decoder_element, d3d11_memory ? "(memory:D3D11Memory)" : "");
    RTC_LOG(LS_INFO) << "GStreamer D3D11 pipeline: "
                     << (d3d11_memory ? "zero-copy (memory:D3D11Memory)"
                                      : "CPU fallback (plain NV12)");
    pipeline_ = gst_parse_launch(pipeline_desc, &error);
    if (pipeline_ == nullptr) {
      RTC_LOG(LS_ERROR) << "gst_parse_launch failed: "
                        << (error != nullptr ? error->message : "unknown");
      if (error != nullptr) g_error_free(error);
      return false;
    }
    appsrc_ = gst_bin_get_by_name(GST_BIN(pipeline_), "src");
    appsink_ = gst_bin_get_by_name(GST_BIN(pipeline_), "sink");
    if (appsrc_ == nullptr || appsink_ == nullptr) {
      if (appsrc_ != nullptr) gst_object_unref(appsrc_);
      if (appsink_ != nullptr) gst_object_unref(appsink_);
      gst_object_unref(pipeline_);
      pipeline_ = nullptr;
      appsrc_ = nullptr;
      appsink_ = nullptr;
      return false;
    }

    // appsrc: complete Annex-B access units, stream source, bounded queue so a
    // stalled pipeline applies backpressure instead of buffering unboundedly.
    GstCaps* h264_caps = gst_caps_new_simple(
        "video/x-h264", "stream-format", G_TYPE_STRING, "byte-stream",
        "alignment", G_TYPE_STRING, "au", nullptr);
    gst_app_src_set_caps(GST_APP_SRC(appsrc_), h264_caps);
    gst_caps_unref(h264_caps);  // set_caps refs internally; drop our ref
    gst_app_src_set_stream_type(GST_APP_SRC(appsrc_),
                                GST_APP_STREAM_TYPE_STREAM);
    g_object_set(G_OBJECT(appsrc_), "format", GST_FORMAT_TIME, nullptr);
    // do-timestamp=FALSE: we set PTS ourselves (derived from the RTP
    // timestamp); do-timestamp=TRUE would overwrite it with pipeline running
    // time and corrupt the timestamp round-trip in OnSample().
    //
    // is-live=FALSE is the black-screen fix (same as vaapi_patch): a *live*
    // appsrc can't complete the PAUSED -> PLAYING preroll until it has both a
    // buffer AND a running live clock, so the decode lags far behind the
    // arriving RTP. WebRTC then classifies every late decoded frame as "backed
    // up in the decoder" and drops it -> framesDecoded stays 0 -> black
    // screen. Non-live (we feed complete AUs ourselves and appsink runs
    // sync=FALSE, so latency is unaffected) completes the state change
    // deterministically and decodes promptly once the first AU is pushed.
    g_object_set(G_OBJECT(appsrc_), "is-live", FALSE, "do-timestamp", FALSE,
                 "max-bytes", 2 * 1024 * 1024, "block", FALSE, nullptr);

    // appsink: never sync to a clock (deliver ASAP), drop stale frames to
    // bound latency, emit a signal per sample.
    g_object_set(G_OBJECT(appsink_), "sync", FALSE, "drop", TRUE,
                 "max-buffers", 2, "emit-signals", TRUE, nullptr);
    g_signal_connect(appsink_, "new-sample", G_CALLBACK(&OnSampleThunk), this);

    // --- GLib context thread: REQUIRED for live pipelines -----------------
    //
    // An async state change (PAUSED -> PLAYING) never completes without a
    // running GLib main loop to dispatch the async-done and clock messages on
    // the bus. Without it, set_state() returns ASYNC, the pipeline stays stuck
    // in PAUSED, h264parse never runs, and every decoded frame count stays at
    // 0 — the root cause of the "black screen". We spawn a dedicated
    // background thread that iterates OUR OWN GMainContext (never the
    // process-global default context, which the app's own thread may own).
    bus_ = gst_element_get_bus(pipeline_);
    main_context_ = g_main_context_new();
    if (bus_ != nullptr && main_context_ != nullptr) {
      bus_watch_source_ = gst_bus_create_watch(bus_);
      g_source_set_callback(
          bus_watch_source_,
          reinterpret_cast<GSourceFunc>(+[](GstBus* /*bus*/, GstMessage* msg,
                                            gpointer /*ud*/) -> gboolean {
            switch (GST_MESSAGE_TYPE(msg)) {
              case GST_MESSAGE_ERROR: {
                GError* err = nullptr;
                gchar* debug = nullptr;
                gst_message_parse_error(msg, &err, &debug);
                RTC_LOG(LS_ERROR) << "GStreamer D3D11 decoder error: "
                                  << (err ? err->message : "unknown")
                                  << " | " << (debug ? debug : "");
                if (err) g_error_free(err);
                g_free(debug);
                break;
              }
              case GST_MESSAGE_WARNING: {
                GError* err = nullptr;
                gchar* debug = nullptr;
                gst_message_parse_warning(msg, &err, &debug);
                RTC_LOG(LS_WARNING) << "GStreamer D3D11 decoder warning: "
                                    << (err ? err->message : "unknown")
                                    << " | " << (debug ? debug : "");
                if (err) g_error_free(err);
                g_free(debug);
                break;
              }
              default:
                break;
            }
            return G_SOURCE_CONTINUE;
          }),
          nullptr, nullptr);
      if (g_source_attach(bus_watch_source_, main_context_) == 0) {
        g_source_destroy(bus_watch_source_);
        g_source_unref(bus_watch_source_);
        bus_watch_source_ = nullptr;
      }
    }

    stop_.store(false);
    main_loop_thread_ = new std::thread([this]() {
      if (main_context_ == nullptr) return;
      g_main_context_push_thread_default(main_context_);
      while (!stop_.load()) {
        g_main_context_iteration(main_context_, TRUE);
      }
      g_main_context_pop_thread_default(main_context_);
    });

    if (gst_element_set_state(pipeline_, GST_STATE_PLAYING) ==
        GST_STATE_CHANGE_FAILURE) {
      RTC_LOG(LS_ERROR) << "Failed to start GStreamer pipeline";
      stop_.store(true);
      if (main_context_ != nullptr) g_main_context_wakeup(main_context_);
      if (main_loop_thread_ != nullptr && main_loop_thread_->joinable()) {
        main_loop_thread_->join();
      }
      delete main_loop_thread_;
      main_loop_thread_ = nullptr;
      if (bus_watch_source_ != nullptr) {
        g_source_destroy(bus_watch_source_);
        g_source_unref(bus_watch_source_);
        bus_watch_source_ = nullptr;
      }
      if (bus_ != nullptr) {
        gst_object_unref(bus_);
        bus_ = nullptr;
      }
      if (main_context_ != nullptr) {
        g_main_context_unref(main_context_);
        main_context_ = nullptr;
      }
      if (appsrc_ != nullptr) gst_object_unref(appsrc_);
      if (appsink_ != nullptr) gst_object_unref(appsink_);
      gst_object_unref(pipeline_);
      pipeline_ = nullptr;
      appsrc_ = nullptr;
      appsink_ = nullptr;
      return false;
    }

    // Block until the pipeline actually reaches PLAYING (or 2 seconds elapse)
    // so Configure() doesn't return true while the pipeline is still PARTIALLY
    // in PAUSED. The main loop is running so the async state dispatch will
    // complete — this wait just confirms the path is viable.
    GstState state, pending;
    const GstStateChangeReturn sync = gst_element_get_state(
        pipeline_, &state, &pending, 2 * GST_SECOND);
    if (sync != GST_STATE_CHANGE_SUCCESS) {
      RTC_LOG(LS_WARNING) << "GStreamer pipeline state after 2s: "
                          << gst_element_state_get_name(state) << " ("
                          << gst_element_state_change_return_get_name(sync)
                          << "), pending="
                          << gst_element_state_get_name(pending);
    }
    return true;
  }

  static GstFlowReturn OnSampleThunk(GstElement* sink, gpointer user_data) {
    return static_cast<GstD3d11VideoDecoder*>(user_data)->OnSample(sink);
  }

  GstFlowReturn OnSample(GstElement* sink) {
    GstSample* sample = gst_app_sink_pull_sample(GST_APP_SINK(sink));
    if (sample == nullptr) return GST_FLOW_OK;
    GstBuffer* buffer = gst_sample_get_buffer(sample);
    GstCaps* caps = gst_sample_get_caps(sample);

    GstVideoInfo info;
    if (caps == nullptr || !gst_video_info_from_caps(&info, caps)) {
      gst_sample_unref(sample);
      return GST_FLOW_OK;
    }

    const int width = GST_VIDEO_INFO_WIDTH(&info);
    const int height = GST_VIDEO_INFO_HEIGHT(&info);

    // --- Zero-CPU-copy path: export the D3D11 texture's shared handle ------
    //
    // When the pipeline negotiated (memory:D3D11Memory), the buffer's first
    // memory is a GstD3D11Memory wrapping a decoder-owned D3D11 texture. We
    // hand the renderer a legacy DXGI shared handle so it can open the
    // texture on its own D3D11 device — decode → composite with no CPU
    // involvement. Two export tiers (see ExportSharedCopy for tier 2):
    //
    // NOTE on the API: gst_d3d11_memory_export (the 1.20-era name for this)
    // was removed in the gst-plugins-bad 1.22 C++ port and never returned, so
    // we use the stable public API present in every 1.22+ release: pull the
    // texture via gst_d3d11_memory_get_resource_handle() and ask DXGI for its
    // legacy shared handle. GetSharedHandle succeeds ONLY when the texture
    // was created with D3D11_RESOURCE_MISC_SHARED — stock d3d11h264dec does
    // NOT (its pool allocates with GST_D3D11_ALLOCATION_FLAG_TEXTURE_ARRAY,
    // no shared flag), so tier 1 is dormant on stock and tier 2 (the GPU
    // shared copy) carries the load instead. Both keep every decoded pixel on
    // the GPU; only tier 3 (below) reads frames back to the CPU.
    webrtc::scoped_refptr<webrtc::VideoFrameBuffer> frame_buffer = nullptr;
    GstMemory* mem = gst_buffer_peek_memory(buffer, 0);
    // The descriptor hardcodes kNv12, so only wrap NV12 D3D11 buffers (the
    // caps filter already constrains the pipeline to format=NV12; this guard
    // keeps a hypothetical non-NV12 D3D11 buffer from being mislabeled).
    if (gst_is_d3d11_memory(mem) &&
        GST_VIDEO_INFO_FORMAT(&info) == GST_VIDEO_FORMAT_NV12) {
      GstD3D11Memory* d3d11_mem = GST_D3D11_MEMORY_CAST(mem);
      // Tier 1 — direct export: the element allocated MISC_SHARED textures,
      // so hand the renderer the decoder's own shared handle (zero GPU work,
      // zero CPU). Dormant with stock d3d11h264dec.
      HANDLE handle = nullptr;
      ID3D11Resource* resource =
          gst_d3d11_memory_get_resource_handle(d3d11_mem);
      if (resource != nullptr) {
        Microsoft::WRL::ComPtr<IDXGIResource> dxgi_resource;
        if (SUCCEEDED(resource->QueryInterface(IID_PPV_ARGS(&dxgi_resource)))) {
          if (SUCCEEDED(dxgi_resource->GetSharedHandle(&handle)) &&
              handle != nullptr) {
            if (!export_direct_logged_) {
              export_direct_logged_ = true;
              RTC_LOG(LS_INFO) << "GstD3D11: direct MISC_SHARED export (zero "
                                  "copy, no GPU blit)";
            }
            // NOTE: the caps-negotiated strides may be 0/aligned for D3D11
            // memory (the real pitch lives in the texture desc); they are
            // informational only — the renderer creates whole-texture SRVs
            // and ignores them.
            frame_buffer = webrtc::make_ref_counted<D3d11VideoBuffer>(
                handle, width, height, GST_VIDEO_INFO_PLANE_STRIDE(&info, 0),
                GST_VIDEO_INFO_PLANE_STRIDE(&info, 1), buffer);
          }
        }
      }
      // Tier 2 — GPU shared copy: stock d3d11h264dec textures are not
      // shared, so blit this frame's texture slice into a MISC_SHARED copy on
      // the element's device and export the copy's handle. GPU-only; the
      // buffer OWNS the copy texture so the handle stays valid for the frame.
      if (frame_buffer == nullptr) {
        frame_buffer = ExportSharedCopy(d3d11_mem, width, height);
      }
      if (frame_buffer == nullptr) {
        RTC_LOG(LS_WARNING)
            << "GstD3D11: export/copy failed — CPU NV12->I420 fallback";
      }
    }

    if (frame_buffer == nullptr) {
      // --- CPU fallback: NV12 -> I420 in a single pass ---------------------
      //
      // Tier 3: only hit when the element doesn't offer D3D11Memory, neither
      // export tier worked (no usable D3D11 device), or the surface is not
      // NV12. Keep this path so the FFmpeg renderer-backend and any non-D3D11
      // session still work.
      GstVideoFrame frame;
      if (!gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ)) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
      }
      const int y_stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
      const int uv_stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 1);
      const uint8_t* y =
          static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0));
      const uint8_t* uv =
          static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 1));

      const int uv_height = (height + 1) / 2;
      const int uv_width = (width + 1) / 2;
      webrtc::scoped_refptr<webrtc::I420Buffer> i420 =
          webrtc::I420Buffer::Create(width, height);
      for (int row = 0; row < height; ++row) {
        std::memcpy(i420->MutableDataY() + row * i420->StrideY(),
                    y + row * y_stride, width);
      }
      for (int row = 0; row < uv_height; ++row) {
        const uint8_t* src = uv + row * uv_stride;
        uint8_t* out_u = i420->MutableDataU() + row * i420->StrideU();
        uint8_t* out_v = i420->MutableDataV() + row * i420->StrideV();
        for (int col = 0; col < uv_width; ++col) {
          out_u[col] = src[col * 2];
          out_v[col] = src[col * 2 + 1];
        }
      }
      gst_video_frame_unmap(&frame);
      frame_buffer = i420;
    }

    // Round-trip the PTS back to an RTP timestamp (90 kHz). The forward
    // conversion (Decode: rtp * 1e9 / 90000) truncates by < 1 ns, so rounding
    // the inverse recovers the EXACT original RTP timestamp. WebRTC's
    // VCMDecodedFrameCallback::FindFrameInfo matches decoded frames to the
    // encode-side frame_infos_ by exact RTP timestamp — a truncated inverse
    // finds no entry and silently drops EVERY frame (black screen despite a
    // healthy decoder).
    const uint32_t rtp_timestamp = static_cast<uint32_t>(
        (GST_BUFFER_PTS(buffer) * 90000 + 500000000ULL) / 1000000000ULL);
    // Recover the render_time_ms WebRTC passed to Decode() for this RTP
    // timestamp. The VideoFrame MUST carry it or VCMDecodedFrameCallback
    // can't match the decoded frame to its frame_info_ entry and silently
    // drops it. Fall back to a wall-clock estimate if the entry was evicted
    // (bounded map) so rendering never fully stalls.
    int64_t render_time_ms = 0;
    {
      std::lock_guard<std::mutex> rtlock(render_time_mu_);
      auto it = render_times_.find(rtp_timestamp);
      if (it != render_times_.end()) {
        render_time_ms = it->second;
        render_times_.erase(it);
      } else {
        render_time_ms =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch())
                .count();
      }
    }
    webrtc::VideoFrame video_frame = webrtc::VideoFrame::Builder()
        .set_video_frame_buffer(frame_buffer)
        .set_timestamp_rtp(rtp_timestamp)
        .set_timestamp_ms(render_time_ms)
        .set_rotation(webrtc::kVideoRotation_0)
        .build();

    // Snapshot the callback under its own mutex, then invoke outside —
    // Decoded() is a synchronous callback into WebRTC and must not run while
    // we hold the pipeline mutex (Release()/Decode() contend on it).
    webrtc::DecodedImageCallback* callback = nullptr;
    {
      std::lock_guard<std::mutex> lock(callback_mutex_);
      callback = decoded_callback_;
    }
    if (callback != nullptr) {
      callback->Decoded(video_frame);
    }
    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  // Tier-2 export: copies the D3D11 memory's texture slice into a MISC_SHARED
  // texture on the element's device and returns a D3d11VideoBuffer that OWNS
  // the copy (the renderer opens the copy's legacy shared handle — zero CPU
  // pixels involved). The decoder element runs on the streaming thread and we
  // are called from that same thread (appsink new-sample), so this context use
  // cannot race the decoder's own; the device lock is still taken to match
  // gst-plugins-bad's own readback convention (gstd3d11videosink emits its
  // readback signal with the lock held). Returns nullptr on any failure and
  // the caller takes the CPU fallback.
  webrtc::scoped_refptr<webrtc::VideoFrameBuffer> ExportSharedCopy(
      GstD3D11Memory* mem, int width, int height) {
    // Guard BEFORE calling the device getters (they g_return_val_if_fail on
    // null, but we should not rely on that path).
    if (mem == nullptr || mem->device == nullptr) {
      RTC_LOG(LS_WARNING) << "GstD3D11: no D3D11 device on memory";
      return nullptr;
    }
    GstD3D11Device* device = mem->device;
    ID3D11Device* dev = gst_d3d11_device_get_device_handle(device);
    ID3D11DeviceContext* ctx =
        gst_d3d11_device_get_device_context_handle(device);
    ID3D11Resource* src = gst_d3d11_memory_get_resource_handle(mem);
    if (dev == nullptr || ctx == nullptr || src == nullptr) {
      RTC_LOG(LS_WARNING)
          << "GstD3D11: device/context/resource unavailable";
      return nullptr;
    }
    D3D11_TEXTURE2D_DESC src_desc = {};
    if (!gst_d3d11_memory_get_texture_desc(mem, &src_desc)) {
      RTC_LOG(LS_WARNING) << "GstD3D11: get_texture_desc failed";
      return nullptr;
    }
    // The decoder's pool allocates one texture ARRAY (dpb depth); each memory
    // is a single slice, so copy just that subresource into a 1-slice copy.
    const UINT src_subresource = gst_d3d11_memory_get_subresource_index(mem);

    D3D11_TEXTURE2D_DESC copy_desc = {};
    copy_desc.Width = src_desc.Width;
    copy_desc.Height = src_desc.Height;
    copy_desc.MipLevels = 1;
    copy_desc.ArraySize = 1;
    copy_desc.Format = src_desc.Format;
    copy_desc.SampleDesc.Count =
        src_desc.SampleDesc.Count > 0 ? src_desc.SampleDesc.Count : 1;
    copy_desc.SampleDesc.Quality = 0;
    copy_desc.Usage = D3D11_USAGE_DEFAULT;
    copy_desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    copy_desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

    Microsoft::WRL::ComPtr<ID3D11Texture2D> copy;
    if (FAILED(dev->CreateTexture2D(&copy_desc, nullptr, &copy)) ||
        copy == nullptr) {
      RTC_LOG(LS_WARNING) << "GstD3D11: CreateTexture2D(shared copy) failed";
      return nullptr;
    }
    gst_d3d11_device_lock(device);
    ctx->CopySubresourceRegion(copy.Get(), 0, 0, 0, 0, src, src_subresource,
                               nullptr);
    // Flush submits the copy to the GPU. The renderer opens the handle on its
    // OWN device later (raster thread, milliseconds after this frame's
    // decode) — D3D11 gives no cross-device ordering guarantee, so this
    // relies on that temporal separation, exactly like the direct-export
    // path. An ID3D11Fence handoff would make it airtight; not needed at the
    // current frame timing.
    ctx->Flush();
    gst_d3d11_device_unlock(device);

    Microsoft::WRL::ComPtr<IDXGIResource> dxgi;
    HANDLE handle = nullptr;
    if (FAILED(copy.As(&dxgi)) || FAILED(dxgi->GetSharedHandle(&handle)) ||
        handle == nullptr) {
      RTC_LOG(LS_WARNING) << "GstD3D11: shared-copy export failed";
      return nullptr;
    }
    if (!export_gpu_logged_) {
      export_gpu_logged_ = true;
      RTC_LOG(LS_INFO) << "GstD3D11: GPU shared copy "
                          "(CopySubresourceRegion) export — no CPU pixels";
    }
    // Transfer ownership of the copy texture (Detach passes our ref; the
    // buffer releases it when the frame is done). Strides are informational
    // only (the renderer uses whole-texture SRVs).
    return webrtc::make_ref_counted<D3d11VideoBuffer>(
        handle, width, height, 0, 0, nullptr, copy.Detach());
  }

  // Pushes one already-converted Annex-B AU into appsrc. Caller holds mutex_.
  int32_t PushLocked(const uint8_t* data, size_t size, uint64_t pts_ns) {
    GstBuffer* buffer = gst_buffer_new_allocate(nullptr, size, nullptr);
    if (buffer == nullptr) return WEBRTC_VIDEO_CODEC_ERROR;
    GstMapInfo map;
    if (!gst_buffer_map(buffer, &map, GST_MAP_WRITE)) {
      gst_buffer_unref(buffer);
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
    std::memcpy(map.data, data, size);
    gst_buffer_unmap(buffer, &map);
    GST_BUFFER_PTS(buffer) = pts_ns;
    const GstFlowReturn ret =
        gst_app_src_push_buffer(GST_APP_SRC(appsrc_), buffer);
    if (ret != GST_FLOW_OK) {
      // Push only takes ownership of `buffer` on success — free it here.
      gst_buffer_unref(buffer);
      ++push_failures_;
      RTC_LOG(LS_WARNING) << "appsrc push dropped frame: "
                          << gst_flow_get_name(ret);
      if (push_failures_ >= 15) {
        // Backpressure for a while: the pipeline is not consuming. Re-issue
        // PLAYING to self-heal a pipeline that missed its async-done.
        push_failures_ = 0;
        GstState state, pending;
        gst_element_get_state(pipeline_, &state, &pending, 0);
        const GstStateChangeReturn ret2 =
            gst_element_set_state(pipeline_, GST_STATE_PLAYING);
        RTC_LOG(LS_WARNING) << "push backpressure: state="
                            << gst_element_state_get_name(state)
                            << " pending="
                            << gst_element_state_get_name(pending)
                            << " — re-issuing PLAYING ret="
                            << gst_element_state_change_return_get_name(ret2);
      }
      return WEBRTC_VIDEO_CODEC_OK_REQUEST_KEYFRAME;
    }
    push_failures_ = 0;
    return WEBRTC_VIDEO_CODEC_OK;
  }

  // Pushes every held AU (re-converting with a now-warm SPS/PPS cache so
  // keyframes carry the parameter sets). Caller holds mutex_.
  void FlushPendingLocked() {
    size_t flushed = 0;
    while (!pending_.empty()) {
      PendingAu au = std::move(pending_.front());
      pending_.pop_front();
      pending_bytes_ -= au.raw.size();
      std::vector<uint8_t> out;
      bool is_keyframe = false;
      if (!converter_.Convert(au.raw.data(), au.raw.size(), &out,
                              &is_keyframe)) {
        continue;  // Malformed held AU — drop it.
      }
      if (out.empty()) continue;  // Param-set-only AU.
      PushLocked(out.data(), out.size(), au.pts_ns);
      ++flushed;
    }
    if (flushed > 0) {
      RTC_LOG(LS_INFO) << "GstD3D11: SPS/PPS captured; flushed " << flushed
                       << " held AU(s)";
    }
  }

  // AUs received before the first SPS/PPS pair. Stored raw (not converted) so
  // they can be re-converted at flush time with a warm parameter-set cache.
  struct PendingAu {
    std::vector<uint8_t> raw;
    uint64_t pts_ns;
    bool keyframe;
  };
  std::deque<PendingAu> pending_;
  size_t pending_bytes_ = 0;
  int push_failures_ = 0;  // consecutive non-OK appsrc pushes (backpressure)
  // Log-once flags for the export tier actually used (info logs).
  bool export_direct_logged_ = false;
  bool export_gpu_logged_ = false;
  static constexpr size_t kMaxPendingFrames = 120;  // ~2 s at 60 fps
  static constexpr size_t kMaxPendingBytes = 8 * 1024 * 1024;

  D3d11AvccToAnnexB converter_;
  std::mutex mutex_;            // pipeline lifecycle (Configure/Decode/Release)
  std::mutex callback_mutex_;   // decoded_callback_ (Register/OnSample only)
  // Maps the RTP timestamp WebRTC handed to Decode() -> the render_time_ms it
  // expects back on the decoded VideoFrame. Looked up + erased in OnSample().
  std::mutex render_time_mu_;
  std::map<uint32_t, int64_t> render_times_;
  static constexpr size_t kMaxRenderTimeEntries = 512;  // ~8 s at 60 fps
  webrtc::DecodedImageCallback* decoded_callback_ = nullptr;
  GstElement* pipeline_ = nullptr;
  GstElement* appsrc_ = nullptr;
  GstElement* appsink_ = nullptr;
  GMainContext* main_context_ = nullptr;
  GSource* bus_watch_source_ = nullptr;
  std::thread* main_loop_thread_ = nullptr;
  std::atomic<bool> stop_{false};
  GstBus* bus_ = nullptr;
};

class D3d11VideoDecoderFactory : public webrtc::VideoDecoderFactory {
 public:
  explicit D3d11VideoDecoderFactory(
      std::unique_ptr<webrtc::VideoDecoderFactory> fallback)
      : fallback_(std::move(fallback)) {}

  std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override {
    if (fallback_ != nullptr) return fallback_->GetSupportedFormats();
    return {webrtc::SdpVideoFormat("H264")};
  }

  webrtc::VideoDecoderFactory::CodecSupport QueryCodecSupport(
      const webrtc::SdpVideoFormat& format,
      bool reference_scaling) const override {
    if (format.name == "H264") {
      return {true, !ForceSoftwareDecoder()};
    }
    if (fallback_ != nullptr) {
      return fallback_->QueryCodecSupport(format, reference_scaling);
    }
    return {false, false};
  }

  std::unique_ptr<webrtc::VideoDecoder> Create(
      const webrtc::Environment& env,
      const webrtc::SdpVideoFormat& format) override {
    if (!ForceSoftwareDecoder() && format.name == "H264" &&
        D3d11ElementAvailable()) {
      RTC_LOG(LS_INFO) << "Using GStreamer D3D11VA decoder for " << format.name;
      return std::make_unique<GstD3d11VideoDecoder>();
    }
    RTC_LOG(LS_INFO) << "D3D11VA unavailable; falling back for " << format.name;
    if (fallback_ != nullptr) return fallback_->Create(env, format);
    return nullptr;
  }

 private:
  std::unique_ptr<webrtc::VideoDecoderFactory> fallback_;
};

}  // namespace

std::unique_ptr<webrtc::VideoDecoderFactory> CreateD3d11VideoDecoderFactory(
    std::unique_ptr<webrtc::VideoDecoderFactory> fallback) {
  return std::make_unique<D3d11VideoDecoderFactory>(std::move(fallback));
}

}  // namespace libwebrtc

#endif  // defined(WEBRTC_WIN)
