// vaapi_video_decoder.cc
//
// GStreamer-backed VAAPI H.264 hardware decoder for libwebrtc (m144 API),
// plus a VideoDecoderFactory that prefers it and falls back to the built-in
// FFmpeg software decoder.
//
// Pipeline:
//   appsrc -> h264parse -> vah264dec/vaapih264dec -> appsink (NV12)
//
// The decoder element is resolved at runtime: "vah264dec" on GStreamer >= 1.20
// (built into gst-plugins-bad), "vaapih264dec" on older distros with the
// separate gstreamer-vaapi package.
//
// WebRTC hands us AVCC (length-prefixed) access units; we convert them to
// Annex-B (start codes) and re-inject SPS/PPS ahead of IDR keyframes, then
// push each complete access unit into appsrc. Decoded NV12 frames are pulled
// from appsink, converted to I420 in a single pass, and delivered via
// DecodedImageCallback.
//
// Switch: setting OPENNOW_DECODER=software forces the software fallback.
#include "vaapi_video_decoder.h"

#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/gst.h>
#include <gst/va/gstvaallocator.h>
#include <gst/va/gstvadisplay.h>
#include <gst/video/video-frame.h>
#include <gst/video/video-info.h>
#include <va/va.h>
#include <va/va_drmcommon.h>

#include <glib.h>

#include <unistd.h>  // close() / dup()

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "api/scoped_refptr.h"
#include "api/video/encoded_image.h"
#include "api/video/i420_buffer.h"
#include "api/video/video_frame.h"
#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_decoder.h"
#include "modules/video_coding/include/video_error_codes.h"
#include "api/make_ref_counted.h"
#include "dmabuf_video_buffer.h"
#include "rtc_base/logging.h"
#include "vaapi_h264_bitstream.h"

namespace libwebrtc {
namespace {

constexpr char kDecoderImplementation[] = "GStreamerVaapiH264";

// DRM_FORMAT_NV12 (fourcc 'NV12'). The whole-surface fourcc of the exported
// NV12 frame; the GL renderer imports the two planes as R8 (Y) + GR88 (UV).
// Hardcoded to avoid a libdrm dependency in the wrapper build.
constexpr uint32_t kDrmFormatNv12 = 0x3231564e;

bool ForceSoftwareDecoder() {
  const char* value = getenv("OPENNOW_DECODER");
  return value != nullptr && std::strcmp(value, "software") == 0;
}

// --- Decode-path diagnostics (black-screen debugging) -----------------------

// Hex dump of the first `count` bytes of an access unit, for framing
// detection (AVCC starts with a 4-byte length, Annex-B with 00 00 01 /
// 00 00 00 01).
std::string HexPrefix(const uint8_t* data, size_t size, size_t count = 8) {
  std::string s;
  char buf[8];
  for (size_t i = 0; i < std::min<size_t>(size, count); ++i) {
    std::snprintf(buf, sizeof(buf), "%02x ", data[i]);
    s += buf;
  }
  return s;
}

// Comma-separated H.264 NAL unit types found in an access unit by scanning
// for Annex-B start codes. Used to prove whether SPS (7) / PPS (8) ever
// reach the decoder in-band.
std::string ScanNalTypes(const uint8_t* data, size_t size) {
  std::string types;
  size_t i = 0;
  while (i + 3 < size) {
    if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 &&
        data[i + 3] == 1) {
      if (i + 4 < size) {
        types += std::to_string(data[i + 4] & 0x1f);
        types += ",";
      }
      i += 4;
    } else if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
      if (i + 3 < size) {
        types += std::to_string(data[i + 3] & 0x1f);
        types += ",";
      }
      i += 3;
    } else {
      ++i;
    }
  }
  return types;
}

// --- File logging ----------------------------------------------------------
//
// RTC_LOG goes to the process stderr; Dart app logs go through the LogSink
// into next_client.log. To keep the decoder diagnostics in the SAME log the
// app/stream uses, DecoderLog appends to next_client.log (the same file the
// Dart FileLogSink writes) so a frozen/black stream can be diagnosed there.
void DecoderLog(const char* fmt, ...) {
  static std::mutex log_mu;
  const char* home = getenv("HOME");
  char path[512];
  std::snprintf(path, sizeof(path),
                "%s/.local/share/com.example.next_client/next_client.log",
                home != nullptr ? home : "/tmp");
  std::lock_guard<std::mutex> lock(log_mu);
  FILE* f = fopen(path, "a");
  if (f == nullptr) return;
  const auto now = std::chrono::system_clock::now();
  const auto secs =
      std::chrono::duration_cast<std::chrono::seconds>(now.time_since_epoch());
  const auto millis =
      std::chrono::duration_cast<std::chrono::milliseconds>(
          now.time_since_epoch()) %
      1000;
  std::fprintf(f, "[%lld.%03lld] ", static_cast<long long>(secs.count()),
               static_cast<long long>(millis.count()));
  va_list ap;
  va_start(ap, fmt);
  std::vfprintf(f, fmt, ap);
  va_end(ap);
  std::fprintf(f, "\n");
  std::fclose(f);
}

// Resolves the VAAPI H.264 decoder element: "vah264dec" on GStreamer >= 1.20
// (gst-plugins-bad), "vaapih264dec" on older distros with the separate
// gstreamer-vaapi package. Returns nullptr if neither is installed.
const char* VaapiDecoderElement() {
  static const char* element = []() -> const char* {
    gst_init(nullptr, nullptr);
    for (const char* name : {"vah264dec", "vaapih264dec"}) {
      GstElementFactory* factory = gst_element_factory_find(name);
      if (factory != nullptr) {
        gst_object_unref(factory);
        return name;
      }
    }
    return nullptr;
  }();
  return element;
}

bool VaapiElementAvailable() {
  return VaapiDecoderElement() != nullptr;
}

// Whether the decoder element's src pad template offers the VAMemory caps
// feature (VA surface-backed buffers). vah264dec advertises
// video/x-raw(memory:VAMemory) alongside plain system-memory NV12; requesting
// the feature in the caps filter makes appsink receive VA-backed buffers so
// TryExportDmaBuf can export prime fds and the GL renderer takes the zero-copy
// EGL-import path. Without it, negotiation settles on plain NV12, every
// buffer has no VA surface, and every frame falls back to the CPU
// NV12→I420+readback path (the "compositing via YUV plane upload" log line).
// The check is a template caps intersection so drivers that do NOT offer the
// feature keep the previous plain-NV12 pipeline instead of failing
// negotiation.
bool VaapiElementOffersVaMemory(const char* element_name) {
  GstElementFactory* factory = gst_element_factory_find(element_name);
  if (factory == nullptr) return false;
  bool offers = false;
  // vah264dec registers its src template statically (gst-inspect shows
  // "video/x-raw(memory:VAMemory)" + plain "video/x-raw"), so the factory's
  // static pad template list is available BEFORE the element type is
  // instantiated — gst_element_factory_get_element_type() is G_TYPE_INVALID
  // until then, so the class-based lookup would always miss.
  const GList* templates =
      gst_element_factory_get_static_pad_templates(factory);
  for (const GList* it = templates; it != nullptr; it = it->next) {
    const GstStaticPadTemplate* tmpl =
        static_cast<const GstStaticPadTemplate*>(it->data);
    if (tmpl == nullptr || tmpl->direction != GST_PAD_SRC) continue;
    // GstStaticCaps is reference-counted like GstCaps; intersect its caps
    // with the VAMemory feature caps to see if the src pad offers it. The
    // getter takes non-const (it only reads — refcounts the static caps).
    GstCaps* templ_caps = gst_static_caps_get(
        const_cast<GstStaticCaps*>(&tmpl->static_caps));
    GstCaps* va_caps = gst_caps_from_string("video/x-raw(memory:VAMemory)");
    GstCaps* intersection = gst_caps_intersect(templ_caps, va_caps);
    if (!gst_caps_is_empty(intersection)) offers = true;
    gst_caps_unref(intersection);
    gst_caps_unref(va_caps);
    gst_caps_unref(templ_caps);
    if (offers) break;
  }
  gst_object_unref(factory);
  return offers;
}

class GstVaapiVideoDecoder : public webrtc::VideoDecoder {
 public:
  GstVaapiVideoDecoder() = default;
  ~GstVaapiVideoDecoder() override { Release(); }

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
    // Whether the current AU is a keyframe; also carried by held AUs so the
    // overflow path only requests a fresh keyframe when it drops one.
    bool is_keyframe = false;

    // Serialize the whole decode path (diagnostics, converter_, pending_ and
    // the appsrc push) against Release(), which tears the pipeline down under
    // the same mutex_. The pipeline_ null guard also catches late frames that
    // arrive after teardown.
    std::lock_guard<std::mutex> lock(mutex_);
    if (pipeline_ == nullptr) {
      return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
    }

    // Diagnostics for the first few AUs of a session: framing (hex prefix),
    // NAL types present, and whether SPS/PPS have been captured yet. This
    // distinguishes "stream has no in-band SPS/PPS" (types lack 7/8) from
    // "converter corrupts them" (7/8 present but pipeline still fails). Runs
    // under mutex_ so converter_ state is fully serialized with Release().
    static std::atomic<int> diag_seen{0};
    const int diag_n = diag_seen.fetch_add(1);
    if (diag_n < 60) {
      DecoderLog("decode #%d in=%zu hasParam=%d nals=%s", diag_n,
                 input_image.size(), converter_.HasParameterSets(),
                 ScanNalTypes(data, input_image.size()).c_str());
      if (diag_n < 8) {
        RTC_LOG(LS_INFO) << "GstVAAPI decode#" << diag_n
                         << " in=" << input_image.size()
                         << " hex=" << HexPrefix(data, input_image.size())
                         << " nals=" << ScanNalTypes(data, input_image.size())
                         << " pts=" << pts_ns
                         << " hasParam=" << converter_.HasParameterSets();
      }
    }

    // Warm path: SPS/PPS already captured — convert and push immediately.
    if (converter_.HasParameterSets()) {
      std::vector<uint8_t> annexb;
      if (!converter_.Convert(data, input_image.size(), &annexb,
                              &is_keyframe)) {
        RTC_LOG(LS_ERROR) << "Malformed H.264 access unit";
        DecoderLog("decode #%d WARM CONVERT-FAIL", diag_n);
        return WEBRTC_VIDEO_CODEC_ERROR;
      }
      if (annexb.empty()) return WEBRTC_VIDEO_CODEC_OK;  // param-set-only AU
      const int32_t push_ret =
          PushLocked(annexb.data(), annexb.size(), pts_ns);
      DecoderLog("decode #%d WARM push=%d key=%d", diag_n, push_ret,
                 is_keyframe);
      return push_ret;
    }

    // Cold path: no parameter sets yet. Converting this AU may capture them
    // (the converter caches in-band SPS/PPS from any AU, not just keyframes).
    std::vector<uint8_t> annexb;
    if (!converter_.Convert(data, input_image.size(), &annexb, &is_keyframe)) {
      RTC_LOG(LS_ERROR) << "Malformed H.264 access unit";
      DecoderLog("decode #%d COLD CONVERT-FAIL", diag_n);
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
    if (converter_.HasParameterSets()) {
      // Cache just warmed — flush the AUs held so far (re-converting them with
      // a warm cache prepends SPS/PPS ahead of any held keyframes), then push
      // this one.
      DecoderLog("decode #%d COLD-WARMED key=%d held=%zu", diag_n,
                 is_keyframe, pending_.size());
      FlushPendingLocked();
      if (annexb.empty()) return WEBRTC_VIDEO_CODEC_OK;
      const int32_t push_ret =
          PushLocked(annexb.data(), annexb.size(), pts_ns);
      DecoderLog("decode #%d WARM push=%d key=%d", diag_n, push_ret,
                 is_keyframe);
      return push_ret;
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
    DecoderLog("decode #%d HOLD key=%d pending=%zu bytes=%zu", diag_n,
               is_keyframe, pending_.size(), pending_bytes_);
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
          << "GstVAAPI: holding for SPS/PPS; dropping oldest AU (pending="
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
    // parameter-set cache so a reused decoder starts clean for a new stream
    // (stale SPS/PPS would otherwise be prepended to the new keyframes).
    pending_.clear();
    pending_bytes_ = 0;
    push_failures_ = 0;
    converter_.Reset();
    {
      std::lock_guard<std::mutex> rtlock(render_time_mu_);
      render_times_.clear();
    }
    DecoderLog("release complete");
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
    const char* decoder_element = VaapiDecoderElement();
    if (decoder_element == nullptr) {
      RTC_LOG(LS_ERROR) << "No VAAPI H.264 decoder element found "
                           "(vah264dec / vaapih264dec)";
      return false;
    }
    GError* error = nullptr;
    char pipeline_desc[256];
    // VAAPI H.264 decoders natively output NV12, so there is no videoconvert:
    // the decoder's buffers flow straight to appsink. Converting NV12 -> I420
    // happens once, in OnSample, directly into the WebRTC I420Buffer — one CPU
    // pass instead of a videoconvert copy plus a second I420 memcpy.
    //
    // Zero-copy: when the element offers VAMemory, request it in the caps
    // filter so appsink receives VA surface-backed NV12. TryExportDmaBuf then
    // exports the surface to prime fds and the GL renderer imports them as
    // EGLImages — the decoded frame never touches the CPU (the whole point of
    // the zero-copy path). Falling back to plain NV12 (no VAMemory feature)
    // forces every frame through the CPU path, which is what capped the
    // stream at ~20 fps with "YUV plane upload (CPU readback)" in the logs.
    const bool va_memory = VaapiElementOffersVaMemory(decoder_element);
    std::snprintf(pipeline_desc, sizeof(pipeline_desc),
                  "appsrc name=src ! h264parse ! %s ! "
                  "video/x-raw%s,format=NV12 ! appsink name=sink",
                  decoder_element, va_memory ? "(memory:VAMemory)" : "");
    RTC_LOG(LS_INFO) << "GStreamer VAAPI pipeline: "
                     << (va_memory ? "zero-copy (memory:VAMemory)"
                                   : "CPU fallback (plain NV12)");
    DecoderLog("configure: decoder=%s va_memory=%d", decoder_element,
               va_memory ? 1 : 0);
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
    // is-live=FALSE is the black-screen fix: a *live* appsrc can't complete
    // the PAUSED -> PLAYING preroll until it has both a buffer AND a running
    // live clock, so the decode lags far behind the arriving RTP. WebRTC then
    // classifies every late decoded frame as "backed up in the decoder" and
    // drops it -> framesDecoded stays 0 -> black screen. Non-live (we feed
    // complete AUs ourselves and appsink runs sync=FALSE, so latency is
    // unaffected) completes the state change deterministically and decodes
    // promptly once the first AU is pushed.
    g_object_set(G_OBJECT(appsrc_), "is-live", FALSE, "do-timestamp", FALSE,
                 "max-bytes", 2 * 1024 * 1024, "block", FALSE, nullptr);

    // appsink: never sync to a clock (deliver ASAP), drop stale frames to
    // bound latency, emit a signal per sample.
    g_object_set(G_OBJECT(appsink_), "sync", FALSE, "drop", TRUE,
                 "max-buffers", 2, "emit-signals", TRUE, nullptr);
    g_signal_connect(appsink_, "new-sample", G_CALLBACK(&OnSampleThunk), this);

    // --- GLib context thread: REQUIRED for live pipelines -----------------
    //
    // A live appsrc pipeline's async state change (PAUSED -> PLAYING) never
    // completes without a running GLib main loop to dispatch the async-done
    // and clock messages on the bus. Without it, set_state() returns ASYNC,
    // the pipeline stays stuck in PAUSED, h264parse never runs, and every
    // decoded frame count stays at 0 — the root cause of the "black screen".
    //
    // We spawn a dedicated background thread that iterates OUR OWN
    // GMainContext (g_main_context_new), NOT the process-global default
    // context — in a Flutter Linux app the GTK main thread owns the default
    // context for its whole lifetime, so g_main_loop_run() there would block
    // in g_main_context_acquire() forever and the bus would never be
    // serviced. The bus watch is attached to our context, so errors are
    // logged and the async state change completes. Shutdown uses an atomic
    // flag + g_main_context_wakeup (race-free), joined in Release().
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
                RTC_LOG(LS_ERROR) << "GStreamer VAAPI decoder error: "
                                  << (err ? err->message : "unknown")
                                  << " | " << (debug ? debug : "");
                DecoderLog("bus ERROR: %s | %s",
                           err ? err->message : "unknown",
                           debug ? debug : "");
                if (err) g_error_free(err);
                g_free(debug);
                break;
              }
              case GST_MESSAGE_WARNING: {
                GError* err = nullptr;
                gchar* debug = nullptr;
                gst_message_parse_warning(msg, &err, &debug);
                RTC_LOG(LS_WARNING) << "GStreamer VAAPI decoder warning: "
                                    << (err ? err->message : "unknown")
                                    << " | " << (debug ? debug : "");
                DecoderLog("bus WARNING: %s | %s",
                           err ? err->message : "unknown",
                           debug ? debug : "");
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
        // Attach failed (source already attached/destroyed — a programming
        // error); drop our ref so it is finalized.
        g_source_destroy(bus_watch_source_);
        g_source_unref(bus_watch_source_);
        bus_watch_source_ = nullptr;
      }
    }

    stop_.store(false);
    main_loop_thread_ = new std::thread([this]() {
      // Guard against a null context: iterating a null context silently falls
      // back to the process-global default context, which the GTK main thread
      // owns — exactly the deadlock this dedicated-context design avoids.
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
    // in PAUSED. A live appsrc may still be waiting for the first buffer to
    // preroll, but the main loop is running so the async state dispatch will
    // complete — this wait just confirms the path is viable.
    GstState state, pending;
    const GstStateChangeReturn sync = gst_element_get_state(
        pipeline_, &state, &pending, 2 * GST_SECOND);
    DecoderLog("configure: decoder=%s state=%s sync=%s pending=%s",
               decoder_element, gst_element_state_get_name(state),
               gst_element_state_change_return_get_name(sync),
               gst_element_state_get_name(pending));
    if (sync != GST_STATE_CHANGE_SUCCESS) {
      RTC_LOG(LS_WARNING) << "GStreamer pipeline state after 2s: "
                          << gst_element_state_get_name(state) << " ("
                          << gst_element_state_change_return_get_name(sync)
                          << "), pending="
                          << gst_element_state_get_name(pending);
    }
    return true;
  }

  // Exports the decoded VA surface backing `buffer` to two DRM prime fds (Y
  // plane + interleaved UV plane, NV12) and wraps them in a kNative
  // DmaBufVideoBuffer that keeps the GstBuffer (and therefore the VA surface)
  // alive until the raster thread has imported the frame as EGLImages.
  //
  // vah264dec (GStreamer >= 1.20) only advertises video/x-raw(memory:VAMemory)
  // / plain NV12 on this machine — it will not negotiate DMABuf caps — so the
  // zero-copy fds come from vaExportSurfaceHandle(DRM_PRIME_2, SEPARATE_LAYERS)
  // instead of gst_dmabuf_memory_get_fd(). Returns nullptr when the buffer has
  // no VA memory or the driver cannot export; OnSample() then uses the CPU
  // NV12→I420 fallback.
  webrtc::scoped_refptr<webrtc::VideoFrameBuffer> TryExportDmaBuf(
      GstBuffer* buffer, const GstVideoInfo* info) {
    const VASurfaceID surface = gst_va_buffer_get_surface(buffer);
    if (surface == VA_INVALID_ID) return nullptr;
    GstVaDisplay* va_display = gst_va_buffer_peek_display(buffer);
    if (va_display == nullptr) return nullptr;
    gst_object_ref(va_display);
    VADisplay dpy =
        static_cast<VADisplay>(gst_va_display_get_va_dpy(va_display));

    VADRMPRIMESurfaceDescriptor desc;
    std::memset(&desc, 0, sizeof(desc));
    const VAStatus st = vaExportSurfaceHandle(
        dpy, surface, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
        VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS,
        &desc);
    gst_object_unref(va_display);
    if (st != VA_STATUS_SUCCESS) return nullptr;

    // SEPARATE_LAYERS + NV12 => two single-plane layers: R8 (Y) then GR88 (UV).
    if (desc.num_layers < 2 || desc.layers[0].num_planes < 1 ||
        desc.layers[1].num_planes < 1) {
      for (uint32_t i = 0; i < desc.num_objects; ++i) close(desc.objects[i].fd);
      return nullptr;
    }
    const auto& y_layer = desc.layers[0];
    const auto& uv_layer = desc.layers[1];
    const uint32_t y_obj = y_layer.object_index[0];
    const uint32_t uv_obj = uv_layer.object_index[0];
    if (y_obj >= desc.num_objects || uv_obj >= desc.num_objects) {
      for (uint32_t i = 0; i < desc.num_objects; ++i) close(desc.objects[i].fd);
      return nullptr;
    }
    // A driver may back both layers with one object/fd; give each plane its
    // own fd so DmaBufVideoBuffer's per-plane close() is unambiguous.
    const int y_fd = desc.objects[y_obj].fd;
    int uv_fd = desc.objects[uv_obj].fd;
    if (y_fd < 0 || uv_fd < 0) {
      if (y_fd >= 0) close(y_fd);
      if (uv_fd >= 0 && uv_fd != y_fd) close(uv_fd);
      return nullptr;
    }
    if (uv_fd == y_fd) {
      uv_fd = dup(uv_fd);
      if (uv_fd < 0) {
        close(y_fd);
        return nullptr;
      }
    }

    const int width = GST_VIDEO_INFO_WIDTH(info);
    const int height = GST_VIDEO_INFO_HEIGHT(info);
    return webrtc::make_ref_counted<DmaBufVideoBuffer>(
        y_fd, uv_fd, static_cast<int>(y_layer.offset[0]),
        static_cast<int>(uv_layer.offset[0]),
        static_cast<int>(y_layer.pitch[0]),
        static_cast<int>(uv_layer.pitch[0]), width, height, kDrmFormatNv12,
        desc.objects[y_obj].drm_format_modifier, buffer, *info);
  }

  static GstFlowReturn OnSampleThunk(GstElement* sink, gpointer user_data) {
    return static_cast<GstVaapiVideoDecoder*>(user_data)->OnSample(sink);
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
    static std::atomic<int> sample_seen{0};
    const int sample_n = sample_seen.fetch_add(1);
    if (sample_n < 120) {
      DecoderLog("sample #%d pts=%llu w=%d h=%d", sample_n,
                 static_cast<unsigned long long>(GST_BUFFER_PTS(buffer)),
                 width, height);
    }

    // --- Zero-copy path: export the VA surface to DRM prime fds -----------
    //
    // vah264dec (GStreamer >= 1.20) does not negotiate video/x-raw(memory:DMABuf)
    // on this machine (it only offers VAMemory / plain NV12), so the dmabuf fds
    // come from vaExportSurfaceHandle(DRM_PRIME_2) instead. The exported fds are
    // wrapped in a kNative DmaBufVideoBuffer; the GL renderer imports them as
    // EGLImages and the decoded frame never touches the CPU. The GstBuffer ref
    // held by DmaBufVideoBuffer keeps the VA surface alive until the raster
    // thread has sampled it (backpressure = one frame).
    webrtc::scoped_refptr<webrtc::VideoFrameBuffer> frame_buffer =
        TryExportDmaBuf(buffer, &info);

    if (frame_buffer == nullptr) {
      // --- CPU fallback: NV12 -> I420 in a single pass ---------------------
      //
      // Only hit when the surface cannot be exported (no VA memory, driver
      // without PRIME_2 export, or a non-NV12 layout). Keep this path exactly
      // as before so the FFmpeg renderer-backend and any non-VAAPI session
      // still work.
      GstVideoFrame frame;
      if (!gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ)) {
        gst_sample_unref(sample);
        return GST_FLOW_OK;
      }
      const int y_stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
      const int uv_stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 1);
      const uint8_t* y = static_cast<const uint8_t*>(
          GST_VIDEO_FRAME_PLANE_DATA(&frame, 0));
      const uint8_t* uv = static_cast<const uint8_t*>(
          GST_VIDEO_FRAME_PLANE_DATA(&frame, 1));

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
    // (e.g. 1516 -> pts 16844444 -> 1515) finds no entry and silently drops
    // EVERY frame before it reaches the renderer (black screen despite a
    // healthy decoder).
    const uint32_t rtp_timestamp = static_cast<uint32_t>(
        (GST_BUFFER_PTS(buffer) * 90000 + 500000000ULL) / 1000000000ULL);
    // Recover the render_time_ms WebRTC passed to Decode() for this RTP
    // timestamp. The VideoFrame MUST carry it or VCMDecodedFrameCallback
    // can't match the decoded frame to its frame_info_ entry and silently
    // drops it (black screen). Fall back to a wall-clock estimate if the
    // entry was evicted (bounded map) so rendering never fully stalls.
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
    // "deliver" vs "delivered" brackets the Decoded() call so the log can
    // distinguish a streaming thread stuck INSIDE the WebRTC callback
    // (deliver logged, delivered not) from one that never reached it.
    if (sample_n < 120) {
      DecoderLog("deliver #%d rtp=%u", sample_n, rtp_timestamp);
    }
    if (callback != nullptr) {
      callback->Decoded(video_frame);
    }
    if (sample_n < 120) {
      DecoderLog("delivered #%d", sample_n);
    }
    gst_sample_unref(sample);
    return GST_FLOW_OK;
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
    DecoderLog("push in=%zu pts=%llu ret=%s", size,
               static_cast<unsigned long long>(pts_ns),
               gst_flow_get_name(ret));
    if (ret != GST_FLOW_OK) {
      // Push only takes ownership of `buffer` on success — free it here.
      // A non-OK return means the queue is full or flushing; drop the frame
      // and let WebRTC request a keyframe rather than failing the stream.
      gst_buffer_unref(buffer);
      ++push_failures_;
      RTC_LOG(LS_WARNING) << "appsrc push dropped frame: "
                          << gst_flow_get_name(ret);
      if (push_failures_ >= 15) {
        // Backpressure for a while: the pipeline is not consuming. A live
        // pipeline that missed its async-done can stay prerolled at PAUSED
        // with exactly one frame delivered — re-issuing PLAYING self-heals
        // that. Log state so the log pinpoints it.
        push_failures_ = 0;
        GstState state, pending;
        gst_element_get_state(pipeline_, &state, &pending, 0);
        const GstStateChangeReturn ret2 =
            gst_element_set_state(pipeline_, GST_STATE_PLAYING);
        DecoderLog(
            "push backpressure: state=%s pending=%s — re-issuing PLAYING "
            "ret=%s",
            gst_element_state_get_name(state),
            gst_element_state_get_name(pending),
            gst_element_state_change_return_get_name(ret2));
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
      RTC_LOG(LS_INFO) << "GstVAAPI: SPS/PPS captured; flushed " << flushed
                       << " held AU(s)";
      DecoderLog("flush %zu held AU(s)", flushed);
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
  static constexpr size_t kMaxPendingFrames = 120;  // ~2 s at 60 fps
  static constexpr size_t kMaxPendingBytes = 8 * 1024 * 1024;

  AvccToAnnexB converter_;
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

class VaapiVideoDecoderFactory : public webrtc::VideoDecoderFactory {
 public:
  explicit VaapiVideoDecoderFactory(
      std::unique_ptr<webrtc::VideoDecoderFactory> fallback)
      : fallback_(std::move(fallback)) {}

  std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override {
    if (fallback_ != nullptr) return fallback_->GetSupportedFormats();
    return {webrtc::SdpVideoFormat("H264")};
  }

  webrtc::VideoDecoderFactory::CodecSupport QueryCodecSupport(
      const webrtc::SdpVideoFormat& format, bool reference_scaling) const override {
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
        VaapiElementAvailable()) {
      RTC_LOG(LS_INFO) << "Using GStreamer VAAPI decoder for " << format.name;
      return std::make_unique<GstVaapiVideoDecoder>();
    }
    RTC_LOG(LS_INFO) << "VAAPI unavailable; falling back for " << format.name;
    if (fallback_ != nullptr) return fallback_->Create(env, format);
    return nullptr;
  }

 private:
  std::unique_ptr<webrtc::VideoDecoderFactory> fallback_;
};

}  // namespace

std::unique_ptr<webrtc::VideoDecoderFactory> CreateVaapiVideoDecoderFactory(
    std::unique_ptr<webrtc::VideoDecoderFactory> fallback) {
  return std::make_unique<VaapiVideoDecoderFactory>(std::move(fallback));
}

}  // namespace libwebrtc
