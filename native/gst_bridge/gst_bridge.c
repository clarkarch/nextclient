// gst_bridge.c — GStreamer webrtcbin bridge for GFN streaming.
//
// Pipeline (built lazily as pads appear):
//   webrtcbin (video RTP pad)
//     -> decodebin           // auto: rtph264depay + vah264dec/avdec_h264
//                            // (vah264dec = VAAPI in gst-plugins-bad >=1.20;
//                            //  ranked above avdec_h264 so hardware wins)
//     -> videoconvert
//     -> video/x-raw,format=RGBA
//     -> appsink             // new-sample -> bridge_frame_cb
//   webrtcbin (audio RTP pad)
//     -> decodebin           // auto: rtpopusdepay + opusdec
//     -> audioconvert -> audioresample -> autoaudiosink (sync=false)
//                            // (OpenNOW parity: local audio playback)
//
// Threading: a dedicated GLib main loop runs on a background thread; every
// action (set-remote-description, create-answer, set-local-description,
// add-ice-candidate, create-data-channel, send) is marshalled onto that loop
// with g_main_context_invoke so webrtcbin's internal negotiation machinery
// resolves correctly. Callbacks fire from GStreamer threads — keep them cheap.
#include "gst_bridge.h"

#include <glib.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/sdp/gstsdpmessage.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drmcommon.h>
#include <drm_fourcc.h>
#include <gst/va/gstva.h>
#include <gst/video/video.h>
#include <gst/webrtc/datachannel.h>
#include <gst/webrtc/webrtc.h>

#include <pthread.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#define LOG_LINE_MAX 512

// Dmabuf frame slot helpers (defined below the sample handler).
void bridge_close_dmabuf_fds(BridgeDmaBufFrame* f);
int bridge_frame_slot_mode(GstBridge* bridge);
int bridge_acquire_latest_dmabuf(GstBridge* bridge, BridgeDmaBufFrame* out);

struct GstBridge {
  GMainLoop* loop;
  GMainContext* context;
  GThread* loop_thread;

  GstElement* pipeline;
  GstElement* webrtcbin;
  GstWebRTCDataChannel* reliable_channel;
  GstWebRTCDataChannel* partial_channel;

  // Video decode chain (created once when the video pad appears).
  GstElement* decodebin;
  GstElement* convert;
  GstElement* vapostproc;  // GPU zero-copy mode: VA postproc (VAMemory RGBA)
  GstElement* appsink;
  gboolean video_attached;
  guint video_ssrc;        // remote video SSRC (from RTP caps) for PLI/FIR
  guint keyframe_retry_id; // GLib timeout source id
  GstPad* video_rtp_pad;   // webrtcbin video src pad (ref'd) — keyframe events
  guint rtp_probe_id;      // pad probe id (RTP delivery counter)
  int rtp_frames_window;   // RTP buffers seen in the current 5s window
  int rtp_fps_last;        // last logged RTP buffers/s

  // Audio decode chain (created once when the audio pad appears):
  // decodebin -> queue -> audioconvert -> audioresample -> autoaudiosink
  // (OpenNOW parity: audio always decoded via decodebin + autoaudiosink).
  GstElement* audio_queue;
  GstElement* audio_convert;
  GstElement* audio_resample;
  GstElement* audio_sink;
  gboolean audio_attached;

  bridge_log_cb log_cb;
  bridge_ice_cb ice_cb;
  bridge_frame_cb frame_cb;
  bridge_channel_cb channel_cb;
  bridge_message_cb message_cb;
  void* userdata;

  GMutex state_mutex;  // guards channels + answer result
  GCond answer_cond;
  char* answer_text;

  GMutex stats_mutex;
  int frames_decoded;
  gboolean destroyed;

  // GPU-texture frame slot (swap-on-acquire double buffer, see
  // bridge_enable_frame_slot). The producer ONLY ever writes slot_scratch;
  // the consumer's buffer is handed over at acquire and stays untouched by
  // the producer until the consumer releases it at the NEXT acquire.
  GMutex slot_mutex;
  uint8_t* slot_consumer;  // consumer-owned between acquire calls
  size_t slot_consumer_cap;
  int32_t slot_width;
  int32_t slot_height;
  int32_t slot_stride;
  uint8_t* slot_scratch;   // producer-only until the next acquire swaps it in
  size_t slot_scratch_cap;
  int32_t slot_pending_width;
  int32_t slot_pending_height;
  int32_t slot_pending_stride;
  uint32_t slot_seq;
  gboolean slot_pending;
  gboolean slot_has_frame;
  gboolean slot_enabled;
  // GPU zero-copy mode: frames exported as dmabuf fds instead of pixels.
  gboolean slot_is_dmabuf;
  BridgeDmaBufFrame slot_dmabuf_pending;
  BridgeDmaBufFrame slot_dmabuf_consumer;
  bridge_slot_notify_cb slot_notify;
  void* slot_notify_userdata;

  // M-line index of the SCTP (application) section — the only transport
  // webrtcbin actually creates and gathers candidates for. Remote candidates
  // are fed there as well as at their reported m-line.
  guint app_mline_index;

  // Original (unsanitized) remote ICE credentials from the raw GFN offer
  // (passed from Dart before the offer is sanitized). GFN ice-pwds are
  // base64-padded — GStreamer's parser rejects the trailing '=', so the offer
  // is sanitized for parsing, but the NVIDIA server signs its STUN with the
  // REAL password. These originals are re-applied to the NICE streams after
  // negotiation; without that every connectivity check fails (HMAC mismatch)
  // and ICE never connects (OpenNOW parity).
  //
  // Written by bridge_set_original_ice_credentials on the Dart thread BEFORE
  // bridge_set_remote_offer is invoked; read here only on the loop thread
  // after set-remote-description — the g_main_context_invoke hand-off between
  // those two calls provides the happens-before edge.
  gchar* orig_ufrag;
  gchar* orig_pwd;
};

static void bridge_log(GstBridge* b, const char* fmt, ...) {
  char buf[LOG_LINE_MAX];
  va_list ap;
  va_start(ap, fmt);
  g_vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (b && b->log_cb) {
    // Heap-handoff: the Dart listener callback is async (runs after we
    // return), so a stack buffer would be dead memory by the time Dart reads
    // it. g_strdup'd; Dart MUST free with bridge_free_string.
    b->log_cb(b->userdata, g_strdup(buf));
  }
}

// ---------------------------------------------------------------------------
// Frame delivery (appsink new-sample)
// ---------------------------------------------------------------------------

static GstFlowReturn on_new_sample(GstElement* sink, gpointer user_data) {
  GstBridge* b = (GstBridge*)user_data;
  GstSample* sample = NULL;
  g_signal_emit_by_name(sink, "pull-sample", &sample);
  if (!sample) return GST_FLOW_OK;

  GstBuffer* buffer = gst_sample_get_buffer(sample);
  GstCaps* caps = gst_sample_get_caps(sample);
  GstVideoInfo info;
  if (!buffer || !caps || !gst_video_info_from_caps(&info, caps)) {
    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  // GPU zero-copy mode: export the VA surface as dmabuf fds — the CPU never
  // maps or copies a pixel.
  if (b->slot_is_dmabuf) {
    g_mutex_lock(&b->stats_mutex);
    b->frames_decoded++;
    g_mutex_unlock(&b->stats_mutex);

    VASurfaceID surface = gst_va_buffer_get_surface(buffer);
    GstVaDisplay* va_display = gst_va_buffer_peek_display(buffer);
    if (surface == VA_INVALID_ID || !va_display) {
      gst_sample_unref(sample);
      return GST_FLOW_OK;
    }
    VADisplay dpy = (VADisplay)gst_va_display_get_va_dpy(va_display);
    if (!dpy) {
      gst_sample_unref(sample);
      return GST_FLOW_OK;
    }
    vaSyncSurface(dpy, surface);

    BridgeDmaBufFrame f;
    memset(&f, 0, sizeof(f));
    f.width = GST_VIDEO_INFO_WIDTH(&info);
    f.height = GST_VIDEO_INFO_HEIGHT(&info);
    f.seq = (uint32_t)g_atomic_int_add(&b->slot_seq, 1) + 1;
    // GStreamer RGBA VAMemory surfaces: VA_FOURCC_RGBA == DRM_FORMAT_ABGR8888
    f.fourcc = DRM_FORMAT_ABGR8888;
    f.nfd = 1;
    f.fds[0] = -1;

    VADRMPRIMESurfaceDescriptor h;
    memset(&h, 0, sizeof(h));
    VAStatus st = vaExportSurfaceHandle(dpy, surface,
                                        VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                        VA_EXPORT_SURFACE_READ_ONLY |
                                            VA_EXPORT_SURFACE_COMPOSED_LAYERS,
                                        &h);
    if (st != VA_STATUS_SUCCESS) {
      static gboolean warned = FALSE;
      if (!warned) {
        bridge_log(b, "webrtcbin: vaExportSurfaceHandle failed (%d) — "
                      "zero-copy frames unavailable", (int)st);
        warned = TRUE;
      }
      gst_sample_unref(sample);
      return GST_FLOW_OK;
    }
    f.nfd = h.num_objects;
    for (uint32_t i = 0; i < h.num_objects && i < 4; i++) {
      f.fds[i] = h.objects[i].fd;
      f.modifiers[i] = h.objects[i].drm_format_modifier;
    }
    f.fourcc = h.fourcc;
    if (h.num_layers > 0) {
      // Single composed layer: 1 plane for RGBA.
      f.strides[0] = (int32_t)h.layers[0].pitch[0];
      f.offsets[0] = (int32_t)h.layers[0].offset[0];
    }

    g_mutex_lock(&b->slot_mutex);
    // Producer-side lifecycle: close the previous unconsumed pending export.
    bridge_close_dmabuf_fds(&b->slot_dmabuf_pending);
    b->slot_dmabuf_pending = f;
    b->slot_pending = TRUE;
    b->slot_has_frame = TRUE;
    bridge_slot_notify_cb notify = b->slot_notify;
    void* notify_ud = b->slot_notify_userdata;
    g_mutex_unlock(&b->slot_mutex);
    if (notify) notify(notify_ud);

    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  GstMapInfo map;
  if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }

  if (b->frame_cb && map.data && map.size > 0) {
    // Copy out of the GStreamer buffer so the callback can own a malloc'd
    // region (Dart frees it via bridge_free_ptr).
    gsize bytes = map.size;
    uint8_t* copy = (uint8_t*)malloc(bytes);
    if (copy) {
      memcpy(copy, map.data, bytes);
      b->frame_cb(b->userdata, GST_VIDEO_INFO_WIDTH(&info),
                  GST_VIDEO_INFO_HEIGHT(&info),
                  GST_VIDEO_INFO_PLANE_STRIDE(&info, 0), copy,
                  (uint32_t)GST_BUFFER_PTS(buffer));
    }
    g_mutex_lock(&b->stats_mutex);
    b->frames_decoded++;
    g_mutex_unlock(&b->stats_mutex);
  }

  // GPU-texture slot: store the newest frame (producer copies outside the
  // lock into scratch, then swaps pointers under the lock).
  if (b->slot_enabled && map.data && map.size > 0) {
    size_t need = (size_t)map.size;
    if (b->slot_scratch_cap < need) {
      g_mutex_lock(&b->slot_mutex);
      uint8_t* grown = (uint8_t*)realloc(b->slot_scratch, need);
      if (grown) {
        b->slot_scratch = grown;
        b->slot_scratch_cap = need;
      }
      g_mutex_unlock(&b->slot_mutex);
    }
    if (b->slot_scratch && b->slot_scratch_cap >= need) {
      memcpy(b->slot_scratch, map.data, need);
      g_mutex_lock(&b->slot_mutex);
      b->slot_pending_width = GST_VIDEO_INFO_WIDTH(&info);
      b->slot_pending_height = GST_VIDEO_INFO_HEIGHT(&info);
      b->slot_pending_stride = GST_VIDEO_INFO_PLANE_STRIDE(&info, 0);
      b->slot_seq++;
      b->slot_pending = TRUE;
      b->slot_has_frame = TRUE;
      bridge_slot_notify_cb notify = b->slot_notify;
      void* notify_ud = b->slot_notify_userdata;
      g_mutex_unlock(&b->slot_mutex);
      // Flutter only re-invokes populate() after
      // fl_texture_registrar_mark_texture_frame_available() — the plugin
      // hooks this to mark the texture dirty per frame. Thread-safe: the
      // registrar posts to the platform thread internally.
      if (notify) notify(notify_ud);
    }
  }
  gst_buffer_unmap(buffer, &map);
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

// ---------------------------------------------------------------------------
// Decodebin dynamic pad -> videoconvert
// ---------------------------------------------------------------------------

static void on_decodebin_pad_added(GstElement* element, GstPad* pad,
                                   gpointer user_data) {
  GstBridge* b = (GstBridge*)user_data;
  (void)element;
  if (b->vapostproc) {
    // GPU zero-copy mode: decodebin's raw video pad -> vapostproc sink.
    GstCaps* caps = gst_pad_get_current_caps(pad);
    const gchar* name =
        caps ? gst_structure_get_name(gst_caps_get_structure(caps, 0)) : NULL;
    gboolean is_raw = name && g_str_has_prefix(name, "video/x-raw");
    if (caps) gst_caps_unref(caps);
    if (!is_raw) return;
    GstPad* sinkpad = gst_element_get_static_pad(b->vapostproc, "sink");
    if (sinkpad) {
      if (gst_pad_link(pad, sinkpad) != GST_PAD_LINK_OK) {
        bridge_log(b, "webrtcbin: decodebin->vapostproc link failed");
      }
      gst_object_unref(sinkpad);
    }
    return;
  }
  if (!b->convert) return;
  // decodebin can emit audio + video src pads; only the video one belongs on
  // the videoconvert->appsink chain. (The RTP pad feed is video-only in
  // practice, but filter defensively so an audio pad can't break the link.)
  GstCaps* caps = gst_pad_get_current_caps(pad);
  const gchar* name =
      caps ? gst_structure_get_name(gst_caps_get_structure(caps, 0)) : NULL;
  gboolean is_video = name && g_str_has_prefix(name, "video/");
  if (caps) gst_caps_unref(caps);
  if (!is_video) {
    bridge_log(b, "webrtcbin: decodebin produced non-video pad (%s) — "
                  "skipping",
               name ? name : "?");
    return;
  }
  GstPad* sinkpad = gst_element_get_static_pad(b->convert, "sink");
  if (sinkpad) {
    if (gst_pad_link(pad, sinkpad) != GST_PAD_LINK_OK) {
      bridge_log(b, "webrtcbin: decodebin->videoconvert link failed");
    }
    gst_object_unref(sinkpad);
  }
  gst_element_sync_state_with_parent(b->convert);
  gst_element_sync_state_with_parent(b->appsink);
}

// ---------------------------------------------------------------------------
// Audio decode chain (webrtcbin audio RTP pad -> decodebin -> autoaudiosink)
// ---------------------------------------------------------------------------

static void on_audio_decodebin_pad_added(GstElement* element, GstPad* pad,
                                         gpointer user_data) {
  GstBridge* b = (GstBridge*)user_data;
  (void)element;
  // The dynamic raw-audio pad links to the QUEUE's sink — audioconvert's
  // sink is already consumed by the static queue->convert chain.
  if (!b->audio_queue) return;
  GstCaps* caps = gst_pad_get_current_caps(pad);
  const gchar* name =
      caps ? gst_structure_get_name(gst_caps_get_structure(caps, 0)) : NULL;
  gboolean is_audio_raw = name && g_str_has_prefix(name, "audio/x-raw");
  if (caps) gst_caps_unref(caps);
  if (!is_audio_raw) return;
  GstPad* sinkpad = gst_element_get_static_pad(b->audio_queue, "sink");
  if (sinkpad) {
    if (gst_pad_link(pad, sinkpad) != GST_PAD_LINK_OK) {
      bridge_log(b, "webrtcbin: decodebin->queue link failed");
    }
    gst_object_unref(sinkpad);
  }
  gst_element_sync_state_with_parent(b->audio_convert);
  gst_element_sync_state_with_parent(b->audio_resample);
  gst_element_sync_state_with_parent(b->audio_sink);
}

// OpenNOW parity (gstreamer_pipeline.rs:2866-2880): audio is always decoded
// through a decodebin into `queue -> audioconvert -> audioresample ->
// autoaudiosink` with low-latency sink config (sync=false). decodebin has a
// single sink pad, so the audio media gets its own decodebin.
static void attach_audio_chain(GstBridge* b, GstPad* pad) {
  if (b->audio_attached) return;

  GstElement* decodebin = gst_element_factory_make("decodebin", "decodebin-audio");
  GstElement* queue = gst_element_factory_make("queue", "audio-queue");
  GstElement* convert =
      gst_element_factory_make("audioconvert", "audioconvert");
  GstElement* resample =
      gst_element_factory_make("audioresample", "audioresample");
  GstElement* sink = gst_element_factory_make("autoaudiosink", "audio-sink");
  if (!decodebin || !queue || !convert || !resample || !sink) {
    bridge_log(b, "webrtcbin: failed to create audio decode chain elements");
    return;
  }

  // OpenNOW AUDIO_QUEUE_MAX_BUFFERS=2; sink low-latency config (sync=false)
  // matches their configure_sink call. (GstAutoAudioSink is a bin — it has
  // `sync` but neither `async` nor `qos`; setting those logs a CRITICAL.)
  g_object_set(G_OBJECT(queue), "max-size-buffers", 2, "max-size-bytes", 0,
               "max-size-time", 0, NULL);
  g_object_set(G_OBJECT(sink), "sync", FALSE, NULL);

  gst_bin_add_many(GST_BIN(b->pipeline), decodebin, queue, convert, resample,
                   sink, NULL);
  if (!gst_element_link_many(queue, convert, resample, sink, NULL)) {
    bridge_log(b, "webrtcbin: audio chain link failed");
    return;
  }
  g_signal_connect(decodebin, "pad-added",
                   G_CALLBACK(on_audio_decodebin_pad_added), b);
  b->audio_queue = queue;
  b->audio_convert = convert;
  b->audio_resample = resample;
  b->audio_sink = sink;

  GstPad* sinkpad = gst_element_get_static_pad(decodebin, "sink");
  if (sinkpad) {
    if (gst_pad_link(pad, sinkpad) != GST_PAD_LINK_OK) {
      bridge_log(b, "webrtcbin: failed to link audio pad to decodebin");
    }
    gst_object_unref(sinkpad);
  }
  gst_element_sync_state_with_parent(decodebin);
  gst_element_sync_state_with_parent(queue);
  b->audio_attached = TRUE;
  bridge_log(b, "webrtcbin: audio RTP pad attached (decodebin->autoaudiosink)");
}

// RTP delivery counter: distinguishes "server sends ~14fps" from "the decode
// pipeline drops to ~14fps".
static GstPadProbeReturn rtp_buffer_probe(GstPad* pad,
                                          GstPadProbeInfo* info,
                                          gpointer user_data) {
  (void)pad;
  (void)info;
  GstBridge* b = (GstBridge*)user_data;
  g_mutex_lock(&b->stats_mutex);
  b->rtp_frames_window++;
  g_mutex_unlock(&b->stats_mutex);
  return GST_PAD_PROBE_OK;
}

// RTP delivery rate: distinguishes "the server sends ~14 fps" from "our
// pipeline drops to ~14 fps". Logged every 5 s on the GLib loop thread.
static gboolean rtp_fps_log_tick(gpointer user_data) {
  GstBridge* b = (GstBridge*)user_data;
  if (!b || b->destroyed) return G_SOURCE_REMOVE;
  g_mutex_lock(&b->stats_mutex);
  int n = b->rtp_frames_window;
  b->rtp_frames_window = 0;
  g_mutex_unlock(&b->stats_mutex);
  bridge_log(b, "webrtcbin: rtp delivery %d fps (5s window)", n / 5);
  return G_SOURCE_CONTINUE;
}

// Log which decoder decodebin actually plugged (avdec = software).
static gboolean log_decodebin_children(gpointer user_data) {
  GstBridge* b = (GstBridge*)user_data;
  if (!b || b->destroyed || !b->decodebin) return G_SOURCE_REMOVE;
  GList* children = GST_BIN_CHILDREN(b->decodebin);
  for (GList* it = children; it; it = it->next) {
    GstElement* el = GST_ELEMENT(it->data);
    GstElementFactory* f = gst_element_get_factory(el);
    if (f) {
      bridge_log(b, "webrtcbin: decodebin plugged: %s (%s)",
                 GST_OBJECT_NAME(f),
                 gst_element_factory_get_klass(f));
    }
  }
  return G_SOURCE_REMOVE;
}

// ---------------------------------------------------------------------------
// Keyframe requests (Moonlight parity: ControlStream.c requestIdrFrameFunc —
// request an IDR at stream start so the client never displays a mid-GOP
// blocky frame). WebRTC equivalent: RTCP FIR, PLI as fallback.
// ---------------------------------------------------------------------------

// Fire a keyframe request now and twice more at ~500ms intervals. The timer
// runs on the GLib loop thread (all webrtcbin actions resolve there).
static void schedule_initial_keyframe_requests(GstBridge* b);

struct KeyframeCtx {
  GstBridge* bridge;
  int ticks;
};

static gboolean keyframe_retry_tick(gpointer user_data) {
  struct KeyframeCtx* ctx = (struct KeyframeCtx*)user_data;
  GstBridge* b = ctx->bridge;
  if (!b || b->destroyed) {
    b->keyframe_retry_id = 0;
    g_free(ctx);
    return G_SOURCE_REMOVE;
  }
  if (b->video_rtp_pad) {
    // Upstream GstVideoForceKeyUnit on the RTP pad — webrtcbin converts it
    // to a RTCP PLI/FIR to the sender. (webrtcbin 1.28 has no send-rtcp-fir
    // / send-rtcp-pli action signals — those emitted GLib-CRITICALs.)
    GstEvent* ev = gst_video_event_new_upstream_force_key_unit(
        GST_CLOCK_TIME_NONE, TRUE, 0);
    gst_pad_send_event(b->video_rtp_pad, ev);
    bridge_log(b, "webrtcbin: keyframe requested (force-key-unit, tick %d)",
               ctx->ticks + 1);
  }
  ctx->ticks++;
  if (ctx->ticks >= 3) {
    b->keyframe_retry_id = 0;
    g_free(ctx);
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

static void schedule_initial_keyframe_requests(GstBridge* b) {
  if (b->keyframe_retry_id != 0) {
    g_source_remove(b->keyframe_retry_id);
    b->keyframe_retry_id = 0;
  }
  struct KeyframeCtx* ctx = g_new0(struct KeyframeCtx, 1);
  ctx->bridge = b;
  ctx->ticks = 0;
  b->keyframe_retry_id = g_timeout_add(500, keyframe_retry_tick, ctx);
}

// ---------------------------------------------------------------------------
// Video pad handling (webrtcbin -> decodebin)
// ---------------------------------------------------------------------------

static void on_pad_added(GstElement* element, GstPad* pad, gpointer user_data) {
  GstBridge* b = (GstBridge*)user_data;
  (void)element;
  if (b->video_attached) return;

  GstCaps* caps = gst_pad_get_current_caps(pad);
  const GstStructure* s = caps ? gst_caps_get_structure(caps, 0) : NULL;
  const char* media = s ? gst_structure_get_string(s, "media") : NULL;
  const gchar* name = s ? gst_structure_get_name(s) : NULL;
  gchar* caps_str = caps ? gst_caps_to_string(caps) : g_strdup("(none)");
  // webrtcbin 1.28 can hand over template caps (no `media` field) or NO caps
  // at pad-added time — the full caps arrive later via a CAPS event, and
  // decodebin waits for them. webrtcbin only ever emits pad-added for RTP
  // pads (SCTP arrives via on-data-channel), so any pad here is an RTP pad.
  // Only reject pads we can POSITIVELY identify as audio; GFN's m-line order
  // puts video(0) first, so the first RTP pad is the video pad.
  gboolean is_audio = media && g_strcmp0(media, "audio") == 0;
  // Sanity check when caps are present: pad-added on webrtcbin only carries
  // RTP pads (SCTP arrives via on-data-channel, never here). NULL caps are
  // accepted — webrtcbin 1.28 can fire pad-added before setting caps, and the
  // full caps arrive later via a CAPS event that decodebin waits for.
  gboolean is_rtp =
      !caps || g_str_has_prefix(name ? name : "", "application/x-rtp");
  bridge_log(b, "webrtcbin: pad added (%s) media=%s caps=%s",
             name ? name : "?", media ? media : "(none)", caps_str);
  g_free(caps_str);
  // Remote video SSRC from the RTP caps — needed for RTCP FIR/PLI. Must be
  // read BEFORE the caps are unref'd below.
  if (media && g_strcmp0(media, "video") == 0 && caps) {
    gst_structure_get_uint(gst_caps_get_structure(caps, 0), "ssrc",
                           &b->video_ssrc);
  }
  if (caps) gst_caps_unref(caps);
  if (!is_rtp) {
    bridge_log(b, "webrtcbin: ignoring non-RTP pad");
    return;
  }
  if (is_audio) {
    // Audio media: decode + play locally (OpenNOW parity). The video chain
    // below stays untouched; each media gets its own decodebin.
    attach_audio_chain(b, pad);
    return;
  }

  bridge_log(b, "webrtcbin: video RTP pad appeared — attaching decode chain");
  b->decodebin = gst_element_factory_make("decodebin", "decodebin");
  b->convert = gst_element_factory_make("videoconvert", "videoconvert");
  b->appsink = gst_element_factory_make("appsink", "video-appsink");
  if (!b->decodebin || !b->convert || !b->appsink) {
    bridge_log(b, "webrtcbin: failed to create decode chain elements");
    return;
  }

  // GPU zero-copy chain (preferred): decodebin -> vapostproc (converts to
  // RGBA in VAMemory on the GPU video processor) -> appsink(VAMemory). The
  // CPU never sees a pixel; each VA surface is exported as a dmabuf fd and
  // imported as an EGLImage on the raster thread.
  GstElement* vapostproc = gst_element_factory_make("vapostproc", "vapostproc");
  if (vapostproc) {
    GstCaps* va_caps = gst_caps_from_string(
        "video/x-raw(memory:VAMemory),format=RGBA");
    GstCaps* app_va_caps = gst_caps_from_string(
        "video/x-raw(memory:VAMemory),format=RGBA");
    g_object_set(G_OBJECT(b->appsink), "caps", app_va_caps, "sync", FALSE,
                 "drop", TRUE, "max-buffers", 2, "emit-signals", TRUE, NULL);
    gst_caps_unref(app_va_caps);
    g_signal_connect(b->appsink, "new-sample", G_CALLBACK(on_new_sample), b);
    g_signal_connect(b->decodebin, "pad-added",
                     G_CALLBACK(on_decodebin_pad_added), b);
    b->convert = NULL;
    b->vapostproc = vapostproc;
    gst_bin_add_many(GST_BIN(b->pipeline), b->decodebin, vapostproc,
                     b->appsink, NULL);
    gboolean linked = gst_element_link_pads_filtered(
        vapostproc, "src", b->appsink, "sink", va_caps);
    bridge_log(b, "webrtcbin: vapostproc->appsink(VAMemory RGBA) link: %s",
               linked ? "ok" : "FAILED");
    gst_caps_unref(va_caps);
    gst_element_sync_state_with_parent(vapostproc);
    gst_element_sync_state_with_parent(b->appsink);
    b->slot_is_dmabuf = TRUE;
    bridge_log(b, "webrtcbin: GPU zero-copy chain armed (VAMemory RGBA)");
    // Link the RTP pad into decodebin now (raw video out is routed to
    // vapostproc by on_decodebin_pad_added).
    GstPad* sinkpad = gst_element_get_static_pad(b->decodebin, "sink");
    if (sinkpad) {
      if (gst_pad_link(pad, sinkpad) != GST_PAD_LINK_OK) {
        bridge_log(b, "webrtcbin: failed to link video pad to decodebin");
      }
      gst_object_unref(sinkpad);
    }
    gst_element_sync_state_with_parent(b->decodebin);
    b->video_attached = TRUE;
    schedule_initial_keyframe_requests(b);
    g_timeout_add(1000, log_decodebin_children, b);
    g_timeout_add(5000, rtp_fps_log_tick, b);
    return;
  }
  // CPU fallback (original chain) — also handles platforms without va.

  GstCaps* out_caps = gst_caps_new_simple("video/x-raw", "format",
                                          G_TYPE_STRING, "RGBA", NULL);
  g_object_set(G_OBJECT(b->appsink), "caps", out_caps, "sync", FALSE, "drop",
               TRUE, "max-buffers", 2, "emit-signals", TRUE, NULL);
  gst_caps_unref(out_caps);
  g_signal_connect(b->appsink, "new-sample", G_CALLBACK(on_new_sample), b);
  g_signal_connect(b->decodebin, "pad-added",
                   G_CALLBACK(on_decodebin_pad_added), b);

  gst_bin_add_many(GST_BIN(b->pipeline), b->decodebin, b->convert, b->appsink,
                   NULL);
  // decodebin's src pads are dynamic — they link to videoconvert in
  // on_decodebin_pad_added. Get the chain into PLAYING first.
  if (gst_element_link(b->convert, b->appsink)) {
    gst_element_sync_state_with_parent(b->convert);
    gst_element_sync_state_with_parent(b->appsink);
  }

  // Keep the RTP pad for upstream force-key-unit events + delivery stats.
  if (!b->video_rtp_pad) {
    b->video_rtp_pad = gst_object_ref(pad);
    b->rtp_probe_id = gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BUFFER,
                                        rtp_buffer_probe, b, NULL);
  }
  // Link the webrtcbin video RTP pad into decodebin's sink.
  GstPad* sinkpad = gst_element_get_static_pad(b->decodebin, "sink");
  if (sinkpad) {
    if (gst_pad_link(pad, sinkpad) != GST_PAD_LINK_OK) {
      bridge_log(b, "webrtcbin: failed to link video pad to decodebin");
    }
    gst_object_unref(sinkpad);
  }
  gst_element_sync_state_with_parent(b->decodebin);
  b->video_attached = TRUE;
  // Moonlight parity: request a clean IDR right away instead of joining
  // mid-GOP with blocky references.
  schedule_initial_keyframe_requests(b);
  g_timeout_add(1000, log_decodebin_children, b);
  g_timeout_add(5000, rtp_fps_log_tick, b);
}

// ---------------------------------------------------------------------------
// ICE + data channels
// ---------------------------------------------------------------------------

static void on_ice_candidate(GstElement* element, guint mline_index,
                             const gchar* candidate, gpointer user_data) {
  GstBridge* b = (GstBridge*)user_data;
  (void)element;
  if (!candidate || candidate[0] == '\0') return;  // end-of-candidates
  if (b->ice_cb) {
    // Heap-handoff (async Dart listener; see bridge_log). Dart MUST free with
    // bridge_free_string.
    b->ice_cb(b->userdata, mline_index, g_strdup(candidate));
  }
}

static void on_data_channel(GstElement* element, GstWebRTCDataChannel* channel,
                            gpointer user_data) {
  GstBridge* b = (GstBridge*)user_data;
  (void)element;
  gchar* label = NULL;
  g_object_get(channel, "label", &label, NULL);
  gboolean reliable = g_strcmp0(label, "input_channel_v1") == 0;
  bridge_log(b, "webrtcbin: data channel '%s' (%s)",
             label ? label : "?", reliable ? "reliable" : "partial");
  if (reliable) {
    g_object_ref(channel);
    g_mutex_lock(&b->state_mutex);
    b->reliable_channel = channel;
    g_mutex_unlock(&b->state_mutex);
    if (b->channel_cb) b->channel_cb(b->userdata, 1, 1);
  } else if (g_strcmp0(label, "input_channel_partially_reliable") == 0) {
    g_object_ref(channel);
    g_mutex_lock(&b->state_mutex);
    b->partial_channel = channel;
    g_mutex_unlock(&b->state_mutex);
    if (b->channel_cb) b->channel_cb(b->userdata, 2, 1);
  }
  g_free(label);
}

// ---------------------------------------------------------------------------
// Inbound data-channel messages (server -> client input handshake)
// ---------------------------------------------------------------------------

// GstWebRTCDataChannelMessage is not exposed in the public headers; the layout
// is stable since GStreamer 1.16 ({ GBytes* data; gboolean binary; }).
typedef struct {
  GBytes* data;
  gboolean binary;
} DataChannelMessageCompat;

static void on_channel_message(GstWebRTCDataChannel* channel,
                               DataChannelMessageCompat* msg,
                               gpointer user_data) {
  GstBridge* b = (GstBridge*)user_data;
  if (!b->message_cb || !msg || !msg->data) return;
  gsize len = 0;
  gconstpointer bytes = g_bytes_get_data(msg->data, &len);
  if (!bytes || len == 0) return;

  int which = 0;
  g_mutex_lock(&b->state_mutex);
  if (channel == (GstWebRTCDataChannel*)b->reliable_channel) which = 1;
  else if (channel == (GstWebRTCDataChannel*)b->partial_channel) which = 2;
  g_mutex_unlock(&b->state_mutex);
  if (which != 0) {
    // Heap-handoff (async Dart listener). malloc'd so it pairs with
    // bridge_free_ptr (free); Dart MUST free it.
    uint8_t* copy = (uint8_t*)malloc(len);
    if (copy) {
      memcpy(copy, bytes, len);
      b->message_cb(b->userdata, which, copy, len);
    }
  }
}

static void connect_channel_signals(GstBridge* b, GstWebRTCDataChannel* ch) {
  if (!ch) return;
  if (g_signal_lookup("on-message", G_TYPE_FROM_INSTANCE(ch)) != 0) {
    g_signal_connect(ch, "on-message", G_CALLBACK(on_channel_message), b);
  }
}

// ---------------------------------------------------------------------------
// Remote ICE credential restoration
// ---------------------------------------------------------------------------

// GstWebRTCNiceTransport is a private webrtcbin subclass; its layout is
// { GstWebRTCICETransport parent; GstWebRTCICEStream *stream; gpointer _priv; }
// (mirrored from OpenNOW's GstWebRTCNiceTransportCompat). We only read the
// `stream` member through this compat view — the actual object is a valid
// GstWebRTCICETransport instance, so the cast is layout-compatible.
typedef struct {
  GstWebRTCICETransport parent;
  GstWebRTCICEStream* stream;
  gpointer _priv;
} GstWebRTCNiceTransportCompat;

// Re-point the negotiated NICE streams at the ORIGINAL (unsanitized) remote
// ICE credentials. GFN ice-pwds are base64 with trailing '=' padding which
// GStreamer's SDP parser rejects — the Dart side sanitizes them before
// webrtcbin parses the offer. But the server's STUN MESSAGE-INTEGRITY is
// computed with the real password, so webrtcbin's NICE agent must validate
// against it or every connectivity check fails. Dig the actual
// GstWebRTCICEStream out of each transceiver's transport and re-set the
// originals (OpenNOW parity: try_restore_original_remote_ice_credentials).
//
// Verified against the installed GStreamer 1.28.5: g_object_get and the
// get-transceiver signal both return FULL references (refcount probe), so
// every object obtained here is unref'd before returning.
static void restore_original_remote_ice_credentials(GstBridge* b,
                                                    const char* stage) {
  if (!b->orig_ufrag || !b->orig_pwd) return;

  GstWebRTCICE* agent = NULL;
  g_object_get(b->webrtcbin, "ice-agent", &agent, NULL);
  if (!agent) {
    bridge_log(b, "webrtcbin: no ice-agent for credential restore (%s)",
               stage);
    return;
  }

  guint restored = 0;
  for (guint i = 0; i < 8; i++) {
    GstWebRTCRTPTransceiver* transceiver = NULL;
    g_signal_emit_by_name(b->webrtcbin, "get-transceiver", i, &transceiver);
    if (!transceiver) continue;

    GstWebRTCRTPReceiver* receiver = NULL;
    g_object_get(transceiver, "receiver", &receiver, NULL);
    gst_object_unref(transceiver);
    if (!receiver) continue;

    GstWebRTCDTLSTransport* dtls = NULL;
    g_object_get(receiver, "transport", &dtls, NULL);
    gst_object_unref(receiver);
    if (!dtls) continue;

    GstWebRTCICETransport* ice = NULL;
    g_object_get(dtls, "transport", &ice, NULL);
    gst_object_unref(dtls);
    if (!ice) continue;

    if (g_strcmp0(G_OBJECT_TYPE_NAME(ice), "GstWebRTCNiceTransport") == 0) {
      GstWebRTCNiceTransportCompat* compat =
          (GstWebRTCNiceTransportCompat*)ice;
      if (compat->stream) {
        if (gst_webrtc_ice_set_remote_credentials(
                agent, compat->stream, b->orig_ufrag, b->orig_pwd)) {
          restored++;
        } else {
          bridge_log(b,
                     "webrtcbin: NICE stream rejected original ICE "
                     "credentials (transceiver %u)",
                     i);
        }
      }
    }
    gst_object_unref(ice);
  }
  gst_object_unref(agent);

  if (restored == 0) {
    bridge_log(b,
               "webrtcbin: no NICE stream yet to restore ICE credentials "
               "(%s) — deferred",
               stage);
  } else {
    bridge_log(b, "webrtcbin: restored original ICE credentials on %u NICE "
                  "stream(s) (%s)",
               restored, stage);
  }
}

// ---------------------------------------------------------------------------
// Promise replies (run on the loop thread)
// ---------------------------------------------------------------------------

typedef struct {
  GstBridge* bridge;
} RemoteCtx;

typedef struct {
  GstBridge* bridge;
} AnswerCtx;

static void answer_replied(GstPromise* promise, gpointer user_data);

// Reply handler for set-remote-description. webrtcbin 1.28 verifies the offer
// (fingerprints, etc.) asynchronously and delivers the result here. On error
// we STOP — creating an answer after a failed set-remote-description corrupts
// webrtcbin's internal state (garbage-size gst_structure_copy abort).
static void remote_desc_replied(GstPromise* promise, gpointer user_data) {
  RemoteCtx* ctx = (RemoteCtx*)user_data;
  GstBridge* b = ctx->bridge;
  const GstStructure* reply = gst_promise_get_reply(promise);
  const gchar* err = reply ? gst_structure_get_string(reply, "error") : NULL;
  if (err && *err) {
    bridge_log(b, "webrtcbin: set-remote-description failed: %s", err);
    g_mutex_lock(&b->state_mutex);
    g_free(b->answer_text);
    b->answer_text = g_strdup("");
    g_cond_broadcast(&b->answer_cond);
    g_mutex_unlock(&b->state_mutex);
    gst_promise_unref(promise);
    g_free(ctx);
    return;
  }
  bridge_log(b, "webrtcbin: set-remote-description OK — creating answer");
  // NICE streams exist once the remote description is applied — re-point them
  // at the ORIGINAL (unsanitized) credentials before answering, or the
  // server's STUN integrity checks fail. OpenNOW restores at this same stage.
  restore_original_remote_ice_credentials(b, "after remote description");
  AnswerCtx* actx = g_new0(AnswerCtx, 1);
  actx->bridge = b;
  GstPromise* apromise =
      gst_promise_new_with_change_func(answer_replied, actx, NULL);
  // Correct invocation (gst-inspect-1.0 webrtcbin):
  //   "create-answer" -> void (GstStructure *arg0, GstPromise *arg1)
  // CRITICAL: arg0 must be a real GstStructure, NOT NULL — this glib's
  // generic signal marshaller copies it via gst_structure_copy(), and a NULL
  // makes that copy read garbage sizes from near-NULL memory (g_malloc0 of
  // ~100GB -> GLib fatal abort before the handler even runs). Verified in
  // native/gst_bridge/tools/webrtc_neg_test.c.
  GstStructure* options = gst_structure_new_empty("answer-options");
  g_signal_emit_by_name(b->webrtcbin, "create-answer", options, apromise);
  gst_structure_free(options);
  gst_promise_unref(promise);
  g_free(ctx);
}

static void answer_replied(GstPromise* promise, gpointer user_data) {
  AnswerCtx* ctx = (AnswerCtx*)user_data;
  GstBridge* b = ctx->bridge;
  const GstStructure* reply = gst_promise_get_reply(promise);
  GstWebRTCSessionDescription* answer = NULL;
  if (reply &&
      gst_structure_get(reply, "answer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION,
                        &answer, NULL) &&
      answer) {
    // Adopt the answer as the local description so ICE gathering starts.
    g_signal_emit_by_name(b->webrtcbin, "set-local-description", answer, NULL);
    // set-local-description can (re)create transports — re-apply the original
    // remote credentials once more (OpenNOW parity).
    restore_original_remote_ice_credentials(b, "after local description");
    gchar* text = gst_sdp_message_as_text(answer->sdp);
    g_mutex_lock(&b->state_mutex);
    g_free(b->answer_text);
    b->answer_text = g_strdup(text ? text : "");
    g_cond_broadcast(&b->answer_cond);
    g_mutex_unlock(&b->state_mutex);
    g_free(text);
    gst_webrtc_session_description_free(answer);
  } else {
    bridge_log(b, "webrtcbin: create-answer failed (no answer in reply)");
    g_mutex_lock(&b->state_mutex);
    g_free(b->answer_text);
    b->answer_text = g_strdup("");
    g_cond_broadcast(&b->answer_cond);
    g_mutex_unlock(&b->state_mutex);
  }
  gst_promise_unref(promise);
  g_free(ctx);
}

// ---------------------------------------------------------------------------
// Action marshalling (invoked on the loop thread via g_main_context_invoke)
// ---------------------------------------------------------------------------

typedef struct {
  GstBridge* bridge;
  gchar* offer_sdp;
} OfferArgs;

static gboolean invoke_set_remote_offer(gpointer data) {
  OfferArgs* a = (OfferArgs*)data;
  GstBridge* b = a->bridge;

  GstSDPMessage* sdp = NULL;
  if (gst_sdp_message_new_from_text(a->offer_sdp, &sdp) != GST_SDP_OK) {
    bridge_log(b, "webrtcbin: failed to parse remote offer SDP");
    g_mutex_lock(&b->state_mutex);
    g_free(b->answer_text);
    b->answer_text = g_strdup("");
    g_cond_broadcast(&b->answer_cond);
    g_mutex_unlock(&b->state_mutex);
    g_free(a->offer_sdp);
    g_free(a);
    return G_SOURCE_REMOVE;
  }
  // Record the SCTP m-line index (the only transport webrtcbin creates).
  {
    b->app_mline_index = 0;
    const guint n = gst_sdp_message_medias_len(sdp);
    for (guint i = 0; i < n; i++) {
      GstSDPMedia* m = gst_sdp_message_get_media(sdp, i);
      if (g_strcmp0(gst_sdp_media_get_media(m), "application") == 0) {
        b->app_mline_index = i;
        break;
      }
    }
  }
  GstWebRTCSessionDescription* remote =
      gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_OFFER, sdp);
  // Wait for set-remote-description to be applied (and verified) before
  // creating an answer; its reply handler kicks off create-answer on success.
  RemoteCtx* rctx = g_new0(RemoteCtx, 1);
  rctx->bridge = b;
  GstPromise* rpromise =
      gst_promise_new_with_change_func(remote_desc_replied, rctx, NULL);
  g_signal_emit_by_name(b->webrtcbin, "set-remote-description", remote,
                        rpromise);
  gst_webrtc_session_description_free(remote);
  g_free(a->offer_sdp);
  g_free(a);
  return G_SOURCE_REMOVE;
}

typedef struct {
  GstBridge* bridge;
  gchar* candidate;
  gchar* mid;
  guint mline_index;
} IceArgs;

static gboolean invoke_add_ice(gpointer data) {
  IceArgs* a = (IceArgs*)data;
  GstBridge* b = a->bridge;
  // Installed signature (gst-inspect-1.0 webrtcbin):
  //   "add-ice-candidate" -> void (guint mline_index, const gchar *candidate)
  // There is NO mid-taking variant on 1.28.5. Passing 3 args (mid, index,
  // candidate) made glib bind the gchar* mid as the guint and the int index
  // as the gchar* — feeding webrtcbin a garbage m-line and candidate, so the
  // server's ICE candidate never reached its agent (no connectivity checks,
  // no DTLS, no media). BUNDLE means one transport, so the mid is redundant.
  // Feeding a candidate only helps if the streams validate STUN with the
  // right password — re-apply the originals first (OpenNOW restores here too).
  restore_original_remote_ice_credentials(b, "before remote ICE candidate");
  g_signal_emit_by_name(b->webrtcbin, "add-ice-candidate", a->mline_index,
                        a->candidate);
  bridge_log(b, "webrtcbin: fed remote ICE candidate (m-line %u)",
             a->mline_index);
  // Also feed the SCTP transport's m-line: it is the only transport webrtcbin
  // actually gathered local candidates for, and webrtcbin DEFERS candidates
  // for unregistered m-lines until their transport registers (seen in
  // gstwebrtcbin.c:5564 "Unknown mline N, deferring"). Feeding the server's
  // candidate there too lets its ICE agent form pairs and start checks.
  if (b->app_mline_index != a->mline_index) {
    g_signal_emit_by_name(b->webrtcbin, "add-ice-candidate",
                          b->app_mline_index, a->candidate);
    bridge_log(b, "webrtcbin: fed remote ICE candidate (m-line %u, SCTP)",
               b->app_mline_index);
  }
  g_free(a->candidate);
  g_free(a->mid);
  g_free(a);
  return G_SOURCE_REMOVE;
}

typedef struct {
  GstBridge* bridge;
  gchar* label;
  gboolean partial;
} ChannelArgs;

static gboolean invoke_create_data_channel(gpointer data) {
  ChannelArgs* a = (ChannelArgs*)data;
  GstWebRTCDataChannel* channel = NULL;
  g_signal_emit_by_name(a->bridge->webrtcbin, "create-data-channel", a->label,
                        NULL, &channel);
  if (channel) {
    // webrtcbin owns a reference for the lifetime of the session (the action
    // signal returns a borrowed pointer — do NOT unref, matching the canonical
    // gst-webrtc sendrecv example).
    g_mutex_lock(&a->bridge->state_mutex);
    if (a->partial) {
      a->bridge->partial_channel = channel;
    } else {
      a->bridge->reliable_channel = channel;
    }
    g_mutex_unlock(&a->bridge->state_mutex);
    connect_channel_signals(a->bridge, channel);
    if (a->bridge->channel_cb) {
      a->bridge->channel_cb(a->bridge->userdata, a->partial ? 2 : 1, 1);
    }
  }
  g_free(a->label);
  g_free(a);
  return G_SOURCE_REMOVE;
}

typedef struct {
  GstBridge* bridge;
  uint8_t* data;
  size_t len;
  int reliable;
} SendArgs;

static gboolean invoke_send_input(gpointer data) {
  SendArgs* a = (SendArgs*)data;
  GstBridge* b = a->bridge;
  GstWebRTCDataChannel* ch = NULL;
  g_mutex_lock(&b->state_mutex);
  ch = a->reliable ? b->reliable_channel : b->partial_channel;
  g_mutex_unlock(&b->state_mutex);
  if (!ch) {
    g_free(a->data);
    g_free(a);
    return G_SOURCE_REMOVE;
  }
  GBytes* bytes = g_bytes_new(a->data, a->len);
  GError* err = NULL;
  if (!gst_webrtc_data_channel_send_data_full(ch, bytes, &err)) {
    bridge_log(b, "webrtcbin: data channel send failed: %s",
               err && err->message ? err->message : "unknown");
    if (err) g_error_free(err);
  }
  g_bytes_unref(bytes);
  g_free(a->data);
  g_free(a);
  return G_SOURCE_REMOVE;
}

// ---------------------------------------------------------------------------
// Main loop thread
// ---------------------------------------------------------------------------

static gpointer loop_thread_main(gpointer user_data) {
  GstBridge* b = (GstBridge*)user_data;
  g_main_loop_run(b->loop);
  return NULL;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

GstBridge* bridge_create(bridge_log_cb log_cb, bridge_ice_cb ice_cb,
                         bridge_frame_cb frame_cb,
                         bridge_channel_cb channel_cb,
                         bridge_message_cb message_cb, void* userdata) {
  gst_init(NULL, NULL);
  GstBridge* b = g_new0(GstBridge, 1);
  b->log_cb = log_cb;
  b->ice_cb = ice_cb;
  b->frame_cb = frame_cb;
  b->channel_cb = channel_cb;
  b->message_cb = message_cb;
  b->userdata = userdata;
  g_mutex_init(&b->state_mutex);
  g_cond_init(&b->answer_cond);
  g_mutex_init(&b->stats_mutex);
  g_mutex_init(&b->slot_mutex);

  b->pipeline = gst_pipeline_new("gfn-webrtc-pipeline");
  b->webrtcbin = gst_element_factory_make("webrtcbin", "webrtcbin");
  if (!b->pipeline || !b->webrtcbin) {
    bridge_log(b, "webrtcbin: failed to create pipeline (plugin missing?)");
    if (b->pipeline) gst_object_unref(b->pipeline);
    if (b->webrtcbin) gst_object_unref(b->webrtcbin);
    g_mutex_clear(&b->state_mutex);
    g_cond_clear(&b->answer_cond);
    g_mutex_clear(&b->stats_mutex);
    g_free(b);
    return NULL;
  }
  gst_bin_add(GST_BIN(b->pipeline), b->webrtcbin);

  // Prefer hardware H264/H265 decode in decodebin — without this, decodebin
  // can rank avdec_h264 (software) above the VA decoders on some installs
  // and the whole pipeline drops to ~14 fps at 1080p.
  {
    static const char* hw_decoders[] = {"vah264dec", "vaapih264dec",
                                        "vah265dec", "vaapih265dec", NULL};
    for (int i = 0; hw_decoders[i]; i++) {
      GstElementFactory* f = gst_element_factory_find(hw_decoders[i]);
      if (f) {
        gst_plugin_feature_set_rank(GST_PLUGIN_FEATURE(f),
                                    GST_RANK_PRIMARY * 2);
        gst_object_unref(f);
      }
    }
  }

  // Match the reference client (OpenNOW): bundle every m-line into one ICE
  // transport and gather server-reflexive candidates via STUN so the GFN
  // media server can reach us behind NAT.
  g_object_set(b->webrtcbin, "bundle-policy",
               GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE, NULL);
  g_object_set(b->webrtcbin, "stun-server",
               "stun://stun2.l.google.com:19302", NULL);
  // OpenNOW-aligned anti-buildup: cap the internal jitterbuffer at 2 ms so
  // received latency cannot ratchet upward over a long session (clock drift,
  // jitter-buffer growth). Frames are released to the decode chain ~immediately.
  g_object_set(b->webrtcbin, "latency", 2, NULL);

  g_signal_connect(b->webrtcbin, "on-ice-candidate",
                   G_CALLBACK(on_ice_candidate), b);
  g_signal_connect(b->webrtcbin, "on-data-channel",
                   G_CALLBACK(on_data_channel), b);
  g_signal_connect(b->webrtcbin, "pad-added", G_CALLBACK(on_pad_added), b);

  // The loop must be running before any action is marshalled; webrtcbin's
  // negotiation and ICE use it. Start the loop thread first, then PLAYING.
  b->loop = g_main_loop_new(NULL, FALSE);
  b->context = g_main_loop_get_context(b->loop);
  b->loop_thread = g_thread_new("gst-bridge-loop", loop_thread_main, b);

  if (gst_element_set_state(b->pipeline, GST_STATE_PLAYING) ==
      GST_STATE_CHANGE_FAILURE) {
    bridge_log(b, "webrtcbin: failed to start pipeline");
    g_main_loop_quit(b->loop);
    g_thread_join(b->loop_thread);
    gst_object_unref(b->pipeline);
    g_mutex_clear(&b->state_mutex);
    g_cond_clear(&b->answer_cond);
    g_mutex_clear(&b->stats_mutex);
    g_free(b);
    return NULL;
  }
  bridge_log(b, "webrtcbin: bridge created (GStreamer %s)",
             gst_version_string());
  return b;
}

void bridge_destroy(GstBridge* bridge) {
  if (!bridge) return;
  bridge->destroyed = TRUE;
  g_mutex_lock(&bridge->state_mutex);
  g_free(bridge->answer_text);
  bridge->answer_text = NULL;
  g_free(bridge->orig_ufrag);
  g_free(bridge->orig_pwd);
  bridge->orig_ufrag = NULL;
  bridge->orig_pwd = NULL;
  g_cond_broadcast(&bridge->answer_cond);
  g_mutex_unlock(&bridge->state_mutex);

  if (bridge->loop && bridge->loop_thread) {
    g_main_loop_quit(bridge->loop);
    g_thread_join(bridge->loop_thread);
  }
  if (bridge->pipeline) {
    gst_element_set_state(bridge->pipeline, GST_STATE_NULL);
    gst_object_unref(bridge->pipeline);
  }
  g_mutex_clear(&bridge->state_mutex);
  g_cond_clear(&bridge->answer_cond);
  g_mutex_clear(&bridge->stats_mutex);
  g_mutex_lock(&bridge->slot_mutex);
  g_free(bridge->slot_consumer);
  g_free(bridge->slot_scratch);
  bridge->slot_consumer = NULL;
  bridge->slot_scratch = NULL;
  bridge->slot_has_frame = FALSE;
  g_mutex_unlock(&bridge->slot_mutex);
  g_mutex_clear(&bridge->slot_mutex);
  g_free(bridge);
}

char* bridge_set_remote_offer(GstBridge* bridge, const char* offer_sdp) {
  if (!bridge || !offer_sdp) return NULL;
  g_mutex_lock(&bridge->state_mutex);
  g_free(bridge->answer_text);
  bridge->answer_text = NULL;
  g_mutex_unlock(&bridge->state_mutex);

  OfferArgs* a = g_new0(OfferArgs, 1);
  a->bridge = bridge;
  a->offer_sdp = g_strdup(offer_sdp);
  g_main_context_invoke(bridge->context, invoke_set_remote_offer, a);

  // Wait for the promise reply (delivered on the loop thread).
  g_mutex_lock(&bridge->state_mutex);
  while (!bridge->answer_text && !bridge->destroyed) {
    g_cond_wait(&bridge->answer_cond, &bridge->state_mutex);
  }
  char* result = g_strdup(bridge->answer_text ? bridge->answer_text : "");
  g_mutex_unlock(&bridge->state_mutex);
  return result[0] == '\0' ? (g_free(result), (char*)NULL) : result;
}

int bridge_set_original_ice_credentials(GstBridge* bridge, const char* ufrag,
                                        const char* pwd) {
  if (!bridge || !ufrag || !pwd) return 0;
  g_free(bridge->orig_ufrag);
  g_free(bridge->orig_pwd);
  bridge->orig_ufrag = g_strdup(ufrag);
  bridge->orig_pwd = g_strdup(pwd);
  return 1;
}

int bridge_add_remote_ice(GstBridge* bridge, const char* candidate,
                          const char* sdp_mid, unsigned int sdp_mline_index) {
  if (!bridge || !candidate) return 0;
  IceArgs* a = g_new0(IceArgs, 1);
  a->bridge = bridge;
  a->candidate = g_strdup(candidate);
  a->mid = g_strdup(sdp_mid ? sdp_mid : "");
  a->mline_index = sdp_mline_index;
  g_main_context_invoke(bridge->context, invoke_add_ice, a);
  return 1;
}

int bridge_create_input_channels(GstBridge* bridge, int partial_reliable_ms) {
  if (!bridge) return 0;
  ChannelArgs* a = g_new0(ChannelArgs, 1);
  a->bridge = bridge;
  a->label = g_strdup("input_channel_v1");
  a->partial = FALSE;
  g_main_context_invoke(bridge->context, invoke_create_data_channel, a);

  if (partial_reliable_ms > 0) {
    ChannelArgs* p = g_new0(ChannelArgs, 1);
    p->bridge = bridge;
    p->label = g_strdup("input_channel_partially_reliable");
    p->partial = TRUE;
    g_main_context_invoke(bridge->context, invoke_create_data_channel, p);
  }
  return 1;
}

int bridge_send_input(GstBridge* bridge, const uint8_t* data, size_t len,
                      int reliable) {
  if (!bridge || !data || len == 0) return 0;
  SendArgs* a = g_new0(SendArgs, 1);
  a->bridge = bridge;
  a->data = g_memdup2(data, len);
  a->len = len;
  a->reliable = reliable;
  g_main_context_invoke(bridge->context, invoke_send_input, a);
  return 1;
}

int bridge_frames_decoded(GstBridge* bridge) {
  if (!bridge) return 0;
  g_mutex_lock(&bridge->stats_mutex);
  int n = bridge->frames_decoded;
  g_mutex_unlock(&bridge->stats_mutex);
  return n;
}

void bridge_enable_frame_slot(GstBridge* bridge) {
  if (!bridge) return;
  g_mutex_lock(&bridge->slot_mutex);
  bridge->slot_enabled = TRUE;
  g_mutex_unlock(&bridge->slot_mutex);
  bridge_log(bridge, "webrtcbin: GPU frame slot enabled");
}

void bridge_set_frame_slot_notify(GstBridge* bridge,
                                  bridge_slot_notify_cb notify,
                                  void* userdata) {
  if (!bridge) return;
  g_mutex_lock(&bridge->slot_mutex);
  bridge->slot_notify = notify;
  bridge->slot_notify_userdata = userdata;
  g_mutex_unlock(&bridge->slot_mutex);
}

int bridge_frame_slot_mode(GstBridge* bridge) {
  if (!bridge) return 0;
  g_mutex_lock(&bridge->slot_mutex);
  int mode = bridge->slot_is_dmabuf ? 1 : 0;
  g_mutex_unlock(&bridge->slot_mutex);
  return mode;
}

void bridge_close_dmabuf_fds(BridgeDmaBufFrame* f) {
  for (int i = 0; i < f->nfd && i < 4; i++) {
    if (f->fds[i] >= 0) close(f->fds[i]);
    f->fds[i] = -1;
  }
  f->nfd = 0;
}

int bridge_acquire_latest_dmabuf(GstBridge* bridge, BridgeDmaBufFrame* out) {
  if (!bridge || !out) return 0;
  g_mutex_lock(&bridge->slot_mutex);
  if (bridge->slot_pending && bridge->slot_dmabuf_pending.nfd > 0) {
    // Close the consumer's previous fds, then hand over the pending export.
    bridge_close_dmabuf_fds(&bridge->slot_dmabuf_consumer);
    bridge->slot_dmabuf_consumer = bridge->slot_dmabuf_pending;
    bridge->slot_dmabuf_pending.nfd = 0;
    for (int i = 0; i < 4; i++) bridge->slot_dmabuf_pending.fds[i] = -1;
    bridge->slot_width = bridge->slot_dmabuf_consumer.width;
    bridge->slot_height = bridge->slot_dmabuf_consumer.height;
    bridge->slot_stride = bridge->slot_dmabuf_consumer.strides[0];
    bridge->slot_seq = bridge->slot_dmabuf_consumer.seq;
  }
  if (!bridge->slot_has_frame || bridge->slot_dmabuf_consumer.nfd <= 0) {
    g_mutex_unlock(&bridge->slot_mutex);
    return 0;
  }
  *out = bridge->slot_dmabuf_consumer;
  g_mutex_unlock(&bridge->slot_mutex);
  return 1;
}

int bridge_frame_slot_enabled(GstBridge* bridge) {
  if (!bridge) return 0;
  g_mutex_lock(&bridge->slot_mutex);
  int enabled = bridge->slot_enabled ? 1 : 0;
  g_mutex_unlock(&bridge->slot_mutex);
  return enabled;
}

// Consumer owns the returned buffer until the next call. The producer only
// writes into its scratch buffer (pointer-swapped under the lock), so the
// consumer's view is never torn mid-upload.
int bridge_acquire_latest_frame(GstBridge* bridge, const uint8_t** out_data,
                                int32_t* out_width, int32_t* out_height,
                                int32_t* out_stride, uint32_t* out_seq) {
  if (!bridge || !out_data || !out_width || !out_height || !out_stride) {
    return 0;
  }
  g_mutex_lock(&bridge->slot_mutex);
  if (bridge->slot_pending && bridge->slot_scratch) {
    // Hand the freshly written scratch buffer to the consumer; the buffer
    // the consumer was reading becomes the new scratch (producer-only), so
    // an in-flight GL upload can never race the producer.
    uint8_t* tmp_buf = bridge->slot_consumer;
    size_t tmp_cap = bridge->slot_consumer_cap;
    bridge->slot_consumer = bridge->slot_scratch;
    bridge->slot_consumer_cap = bridge->slot_scratch_cap;
    bridge->slot_scratch = tmp_buf;
    bridge->slot_scratch_cap = tmp_cap;
    bridge->slot_width = bridge->slot_pending_width;
    bridge->slot_height = bridge->slot_pending_height;
    bridge->slot_stride = bridge->slot_pending_stride;
    bridge->slot_pending = FALSE;
  }
  if (!bridge->slot_has_frame || !bridge->slot_consumer) {
    g_mutex_unlock(&bridge->slot_mutex);
    return 0;
  }
  *out_data = bridge->slot_consumer;
  *out_width = bridge->slot_width;
  *out_height = bridge->slot_height;
  *out_stride = bridge->slot_stride;
  if (out_seq) *out_seq = bridge->slot_seq;
  g_mutex_unlock(&bridge->slot_mutex);
  return 1;
}

void bridge_free_string(char* s) { g_free(s); }

// Frees a frame buffer returned by the frame callback (malloc'd in C).
void bridge_free_ptr(void* p) { free(p); }
