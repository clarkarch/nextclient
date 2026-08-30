// nvst_bridge.c — Classic NVST UDP video for GFN (GO-with-Moonlight port).
//
// Layered like OpenNOW's native streamer:
//   RTSP-over-(raw-TLS|WSS) probe → NvstVideoSession → UDP/SRTP receive thread
//   → Annex-B AU assembly → GStreamer appsrc → h264parse/h265parse →
//   hardware decoder (vah264dec / d3d11h264dec / vtdec_hw) → videoconvert →
//   RGBA appsink → Dart frame callback.
//
// The GStreamer pipeline and its GLib main loop live on one background thread
// (mirrors gst_bridge.c). The UDP receive thread feeds appsrc. All public
// entry points are safe to call from Dart's main isolate.
//
// Probe transport selection (OpenNOW connectNvstWss parity + hardening):
// the `:322` RTSPS endpoint goes through a Bifrost-shaped raw-TLS WebSocket
// upgrade (GET / primary, GET /v2/session/<id> fallback, each retried with an
// `x-nv-sessionid` header as a last resort). The upgrade carries NO
// Sec-WebSocket-Protocol / Origin / User-Agent — bare headers route the
// connection to the RTSP-over-WSS handler; the RTSP handshake
// (OPTIONS → DESCRIBE → SETUP video/0/0 → ANNOUNCE → PLAY) then runs over
// WebSocket text frames.
#include "nvst_bridge.h"

#include <arpa/inet.h>
#include <glib.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>
#include <netdb.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <pthread.h>
#include <srtp2/srtp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#define LOG_LINE_MAX 512
#define NV_VIDEO_PACKET_LEN 16
#define FLAG_EOF 0x02
#define FLAG_SOF 0x04
#define FLAG_CONTAINS_PIC_DATA 0x01

// Case-insensitive strstr (OpenNOW headers are lower-cased; NVST RTSP
// headers vary by server — X-GS-ServerPort vs x-gs-serverport).
static const char* find_header_ci(const char* haystack, const char* needle) {
  if (!haystack || !needle || !*needle) return NULL;
  size_t nlen = strlen(needle);
  for (const char* p = haystack; *p; p++) {
    if (strncasecmp(p, needle, nlen) == 0) return p;
  }
  return NULL;
}

// Authenticated STUN hole punch (defined with the SDP helpers below).
static size_t build_stun_binding_request(const char* local_ufrag,
                                         const char* remote_ufrag,
                                         const char* remote_pwd, uint8_t* msg,
                                         size_t msg_cap);
static size_t build_stun_binding_success(const char* local_pwd,
                                         const uint8_t* txid,
                                         const char* mapped_ip,
                                         unsigned short mapped_port,
                                         uint8_t* msg, size_t msg_cap);
static void hole_punch_volley(int fd, const char* peer_ip,
                              unsigned short peer_port, const char* local_ufrag,
                              const char* remote_ufrag, const char* remote_pwd);

struct NvstBridge {
  GMainLoop* loop;
  GMainContext* context;
  GThread* loop_thread;
  GstElement* pipeline;
  GstElement* appsrc;
  GstElement* appsink;
  nvst_log_cb log_cb;
  nvst_frame_cb frame_cb;
  void* userdata;
  int frames_decoded;
  GMutex stats_mutex;
  gboolean destroyed;
};

static void nvst_log(NvstBridge* b, const char* fmt, ...) {
  char buf[LOG_LINE_MAX];
  va_list ap;
  va_start(ap, fmt);
  g_vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (b && b->log_cb) {
    b->log_cb(b->userdata, g_strdup(buf));
  }
}

// ---------------------------------------------------------------------------
// SRTP / NV_VIDEO_PACKET / frame assembly (pure, unit-testable helpers)
// ---------------------------------------------------------------------------

void nvst_pack_master_key_salt(const unsigned char aes_key[32], uint32_t key_id,
                               unsigned char out[44]) {
  memset(out, 0, 44);
  memcpy(out, aes_key, 32);
  out[40] = (unsigned char)((key_id >> 24) & 0xff);
  out[41] = (unsigned char)((key_id >> 16) & 0xff);
  out[42] = (unsigned char)((key_id >> 8) & 0xff);
  out[43] = (unsigned char)(key_id & 0xff);
}

int nvst_parse_aes_key_hex(const char* hex, unsigned char out[32]) {
  if (!hex || strlen(hex) != 64) return -1;
  for (int i = 0; i < 32; i++) {
    unsigned int byte = 0;
    if (sscanf(hex + i * 2, "%2x", &byte) != 1) return -1;
    out[i] = (unsigned char)byte;
  }
  return 0;
}

typedef struct {
  uint32_t stream_packet_index;
  uint32_t frame_index;
  uint8_t flags;
  uint8_t extra_flags;
  uint8_t multi_fec_flags;
  uint8_t multi_fec_blocks;
  uint32_t fec_info;
} NvVideoPacket;

static int nv_video_packet_parse(const uint8_t* bytes, size_t len,
                                 NvVideoPacket* out) {
  if (len < NV_VIDEO_PACKET_LEN) return -1;
  out->stream_packet_index = (uint32_t)(bytes[0] | (bytes[1] << 8) |
                                        (bytes[2] << 16) | (bytes[3] << 24));
  out->frame_index = (uint32_t)(bytes[4] | (bytes[5] << 8) |
                                (bytes[6] << 16) | (bytes[7] << 24));
  out->flags = bytes[8];
  out->extra_flags = bytes[9];
  out->multi_fec_flags = bytes[10];
  out->multi_fec_blocks = bytes[11];
  out->fec_info = (uint32_t)(bytes[12] | (bytes[13] << 8) |
                             (bytes[14] << 16) | (bytes[15] << 24));
  return 0;
}

static const uint8_t* nvst_strip_rtp_header(const uint8_t* packet, size_t len,
                                            size_t* out_len) {
  if (len < 12) return NULL;
  uint8_t first = packet[0];
  if ((first >> 6) != 2) return NULL;
  int has_padding = (first & 0x20) != 0;
  int has_extension = (first & 0x10) != 0;
  size_t csrc = first & 0x0f;
  size_t offset = 12 + csrc * 4;
  if (len < offset) return NULL;
  if (has_extension) {
    offset += 4;
    if (len < offset) return NULL;
  }
  const uint8_t* payload = packet + offset;
  size_t payload_len = len - offset;
  if (has_padding) {
    if (payload_len == 0) return NULL;
    size_t pad_len = payload[payload_len - 1];
    if (pad_len == 0 || pad_len > payload_len) return NULL;
    payload_len -= pad_len;
  }
  *out_len = payload_len;
  return payload;
}

typedef struct {
  int have_frame;
  uint32_t current_frame;
  GByteArray* buffer;
} NvstFrameAssembler;

static void nvst_assembler_init(NvstFrameAssembler* a) {
  a->have_frame = 0;
  a->current_frame = 0;
  a->buffer = g_byte_array_new();
}

static void nvst_assembler_clear(NvstFrameAssembler* a) {
  if (a->buffer) g_byte_array_free(a->buffer, TRUE);
  a->buffer = NULL;
}

static gboolean nvst_assembler_push(NvstFrameAssembler* a,
                                    const NvVideoPacket* hdr,
                                    const uint8_t* payload, size_t len,
                                    GByteArray** au) {
  if (hdr->flags == 0) return FALSE;  // FEC / empty
  if (a->have_frame && a->current_frame != hdr->frame_index) {
    g_byte_array_set_size(a->buffer, 0);
  }
  a->have_frame = 1;
  a->current_frame = hdr->frame_index;
  g_byte_array_append(a->buffer, payload, len);
  if (hdr->flags & FLAG_EOF) {
    if (a->buffer->len == 0) return FALSE;
    *au = a->buffer;
    a->buffer = g_byte_array_new();
    a->have_frame = 0;
    return TRUE;
  }
  return FALSE;
}

// ---------------------------------------------------------------------------
// GStreamer decode pipeline
// ---------------------------------------------------------------------------

static GstFlowReturn on_new_sample(GstElement* sink, gpointer user_data) {
  NvstBridge* b = (NvstBridge*)user_data;
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
  GstMapInfo map;
  if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    gst_sample_unref(sample);
    return GST_FLOW_OK;
  }
  if (b->frame_cb && map.data && map.size > 0) {
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
  gst_buffer_unmap(buffer, &map);
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

static gpointer nvst_loop_thread_main(gpointer user_data) {
  NvstBridge* b = (NvstBridge*)user_data;
  g_main_loop_run(b->loop);
  return NULL;
}

// Property availability varies across GStreamer versions / plugin variants
// (vah264dec vs vaapih264dec vs avdec_h264) — set defensively.
static gboolean has_prop(GstElement* el, const char* name) {
  return g_object_class_find_property(G_OBJECT_GET_CLASS(el), name) != NULL;
}

static NvstBridge* nvst_pipeline_create(const char* codec, nvst_log_cb log_cb,
                                        nvst_frame_cb frame_cb,
                                        void* userdata) {
  NvstBridge* b = g_new0(NvstBridge, 1);
  b->log_cb = log_cb;
  b->frame_cb = frame_cb;
  b->userdata = userdata;
  g_mutex_init(&b->stats_mutex);

  int is_h265 = codec && g_ascii_strcasecmp(codec, "H265") == 0;
  const char* parser = is_h265 ? "h265parse" : "h264parse";
#if defined(__linux__)
  const char* decoder = is_h265 ? "vah265dec" : "vah264dec";
#elif defined(_WIN32)
  const char* decoder = is_h265 ? "d3d11h265dec" : "d3d11h264dec";
#else
  const char* decoder = is_h265 ? "avdec_h265" : "avdec_h264";
#endif

  b->pipeline = gst_pipeline_new("nvst-video-pipeline");
  b->appsrc = gst_element_factory_make("appsrc", "nvst-annexb");
  GstElement* parse = gst_element_factory_make(parser, "parser");
  GstElement* dec = gst_element_factory_make(decoder, "decoder");
  GstElement* convert = gst_element_factory_make("videoconvert", "videoconvert");
  b->appsink = gst_element_factory_make("appsink", "video-appsink");
  if (!b->pipeline || !b->appsrc || !parse || !dec || !convert || !b->appsink) {
    nvst_log(b, "nvst: failed to create pipeline elements (plugin missing?)");
    if (b->pipeline) gst_object_unref(b->pipeline);
    g_mutex_clear(&b->stats_mutex);
    g_free(b);
    return NULL;
  }

  GstCaps* src_caps = gst_caps_new_simple(
      is_h265 ? "video/x-h265" : "video/x-h264", "stream-format",
      G_TYPE_STRING, "byte-stream", "alignment", G_TYPE_STRING, "au", NULL);
  g_object_set(G_OBJECT(b->appsrc), "caps", src_caps, "is-live", TRUE, "format",
               GST_FORMAT_TIME, "block", FALSE, "max-bytes", 0, "stream-type",
               0, NULL);  // stream-type 0 = GST_APP_STREAM_TYPE_STREAM
  gst_caps_unref(src_caps);

  // OpenNOW decoder-chain robustness props (gstreamer_pipeline.rs:2491-2508):
  // re-send codec data with every IDR, resync on corrupted input, rate-limit
  // decoder-side key-unit requests, and keep QoS throttling off.
  g_object_set(G_OBJECT(parse), "disable-passthrough", TRUE, "config-interval",
               -1, NULL);
  if (has_prop(dec, "automatic-request-sync-points")) {
    g_object_set(G_OBJECT(dec), "automatic-request-sync-points", TRUE, NULL);
  }
  if (has_prop(dec, "discard-corrupted-frames")) {
    g_object_set(G_OBJECT(dec), "discard-corrupted-frames", TRUE, NULL);
  }
  if (has_prop(dec, "min-force-key-unit-interval")) {
    g_object_set(G_OBJECT(dec), "min-force-key-unit-interval",
                 (guint64)100000000, NULL);
  }
  if (has_prop(dec, "qos")) {
    g_object_set(G_OBJECT(dec), "qos", FALSE, NULL);
  }

  GstCaps* out_caps = gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING,
                                          "RGBA", NULL);
  g_object_set(G_OBJECT(b->appsink), "caps", out_caps, "sync", FALSE, "drop",
               TRUE, "max-buffers", 2, "emit-signals", TRUE, NULL);
  gst_caps_unref(out_caps);
  g_signal_connect(b->appsink, "new-sample", G_CALLBACK(on_new_sample), b);

  gst_bin_add_many(GST_BIN(b->pipeline), b->appsrc, parse, dec, convert,
                   b->appsink, NULL);
  if (!gst_element_link_many(b->appsrc, parse, dec, convert, b->appsink, NULL)) {
    nvst_log(b, "nvst: pipeline link failed");
    gst_object_unref(b->pipeline);
    g_mutex_clear(&b->stats_mutex);
    g_free(b);
    return NULL;
  }

  b->loop = g_main_loop_new(NULL, FALSE);
  b->context = g_main_loop_get_context(b->loop);
  b->loop_thread = g_thread_new("nvst-video-loop", nvst_loop_thread_main, b);

  if (gst_element_set_state(b->pipeline, GST_STATE_PLAYING) ==
      GST_STATE_CHANGE_FAILURE) {
    nvst_log(b, "nvst: failed to start pipeline");
    g_main_loop_quit(b->loop);
    g_thread_join(b->loop_thread);
    gst_object_unref(b->pipeline);
    g_mutex_clear(&b->stats_mutex);
    g_free(b);
    return NULL;
  }
  return b;
}

static void nvst_push_au(NvstBridge* b, const uint8_t* au, size_t len) {
  if (!b || !b->appsrc || len == 0) return;
  GstBuffer* buffer = gst_buffer_new_allocate(NULL, len, NULL);
  GstMapInfo map;
  if (gst_buffer_map(buffer, &map, GST_MAP_WRITE)) {
    memcpy(map.data, au, len);
    gst_buffer_unmap(buffer, &map);
  }
  GstFlowReturn ret;
  g_signal_emit_by_name(b->appsrc, "push-buffer", buffer, &ret);
  gst_buffer_unref(buffer);
}

// ---------------------------------------------------------------------------
// UDP receive + SRTP thread
// ---------------------------------------------------------------------------

typedef struct {
  NvstBridge* bridge;
  NvstVideoSession session;
  int socket_fd;
  srtp_t srtp_ctx;
  volatile gboolean stop;
} NvstUdpThread;

static void* nvst_udp_thread_main(void* user_data) {
  NvstUdpThread* t = (NvstUdpThread*)user_data;
  uint8_t buf[2048];
  NvstFrameAssembler asm_;
  nvst_assembler_init(&asm_);
  gboolean first_packet = FALSE;
  gboolean cleartext_notice = FALSE;

  // Authenticated hole punch (ping version 6): volley ICE Binding Requests
  // every 20 ms until the first media packet arrives, and answer inbound
  // server Binding Requests / legacy PING datagrams at any time (they can
  // arrive on the media socket for the whole session).
  const gboolean punch_v6 = t->session.ping_version >= 6 &&
                            t->session.remote_ice_ufrag[0] &&
                            t->session.remote_ice_pwd[0] &&
                            t->session.local_ice_ufrag[0] &&
                            t->session.local_ice_pwd[0];
  struct sockaddr_in peer;
  memset(&peer, 0, sizeof(peer));
  peer.sin_family = AF_INET;
  peer.sin_port = htons(t->session.video_peer_port);
  inet_pton(AF_INET, t->session.video_peer_ip, &peer.sin_addr);
  struct timeval tv = {0, punch_v6 ? 20000 : 250000};
  setsockopt(t->socket_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  if (punch_v6) {
    nvst_log(t->bridge,
             "nvst: authenticated hole punch active (ufrag %s → %s:%u)",
             t->session.local_ice_ufrag, t->session.video_peer_ip,
             t->session.video_peer_port);
  }

  while (!t->stop) {
    struct sockaddr_in from;
    socklen_t fromlen = sizeof(from);
    ssize_t n = recvfrom(t->socket_fd, buf, sizeof(buf), 0,
                         (struct sockaddr*)&from, &fromlen);
    if (n < 0) {
      if (errno == EINTR) continue;
      if (t->stop) break;
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        if (!first_packet) {
          if (punch_v6) {
            hole_punch_volley(t->socket_fd, t->session.video_peer_ip,
                              t->session.video_peer_port,
                              t->session.local_ice_ufrag,
                              t->session.remote_ice_ufrag,
                              t->session.remote_ice_pwd);
          } else {
            sendto(t->socket_fd, "PING", 4, 0, (struct sockaddr*)&peer,
                   sizeof(peer));
          }
        }
        continue;
      }
      nvst_log(t->bridge, "nvst: UDP recv error: %s", strerror(errno));
      if (errno == EBADF) break;
      continue;
    }
    // Control datagrams share the media socket — answer and keep reading.
    if (n == 4 && memcmp(buf, "PING", 4) == 0) {
      sendto(t->socket_fd, "PONG", 4, 0, (struct sockaddr*)&from, fromlen);
      continue;
    }
    if (punch_v6 && n >= 20 && buf[0] == 0x00 && buf[1] == 0x01) {
      // STUN Binding Request from the server — reply with authenticated
      // Binding Success (ping version 6 handshake).
      uint8_t reply[64];
      char ip[INET_ADDRSTRLEN] = {0};
      inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
      size_t rlen = build_stun_binding_success(
          t->session.local_ice_pwd, buf + 8, ip, ntohs(from.sin_port), reply,
          sizeof(reply));
      if (rlen > 0) {
        sendto(t->socket_fd, reply, rlen, 0, (struct sockaddr*)&from, fromlen);
      }
      continue;
    }
    if (!first_packet) {
      first_packet = TRUE;
      if (punch_v6) {
        // Media flows — back off the punch to the idle recv timeout.
        struct timeval idle = {0, 250000};
        setsockopt(t->socket_fd, SOL_SOCKET, SO_RCVTIMEO, &idle, sizeof(idle));
      }
      nvst_log(t->bridge, "nvst: UDP received first packet (%zd B)", n);
    }
    if (!cleartext_notice) {
      cleartext_notice = TRUE;
      nvst_log(t->bridge,
               "nvst: attempting SRTP unprotect then cleartext-RTP fallback");
    }

    uint8_t pkt[2048];
    size_t pkt_len = (size_t)n;
    memcpy(pkt, buf, pkt_len);

    if (t->srtp_ctx) {
      int in_len = (int)pkt_len;
      srtp_err_status_t st = srtp_unprotect(t->srtp_ctx, pkt, &in_len);
      if (st == srtp_err_status_ok) pkt_len = (size_t)in_len;
    }

    size_t payload_len = 0;
    const uint8_t* payload = nvst_strip_rtp_header(pkt, pkt_len, &payload_len);
    if (!payload || payload_len < NV_VIDEO_PACKET_LEN) continue;
    NvVideoPacket hdr;
    if (nv_video_packet_parse(payload, payload_len, &hdr) != 0) continue;
    const uint8_t* media = payload + NV_VIDEO_PACKET_LEN;
    size_t media_len = payload_len - NV_VIDEO_PACKET_LEN;

    GByteArray* au = NULL;
    if (nvst_assembler_push(&asm_, &hdr, media, media_len, &au)) {
      nvst_push_au(t->bridge, au->data, au->len);
      g_byte_array_free(au, TRUE);
    }
  }
  nvst_assembler_clear(&asm_);
  return NULL;
}

NvstBridge* nvst_video_start(const NvstVideoSession* session, nvst_log_cb log_cb,
                             nvst_frame_cb frame_cb, void* userdata) {
  gst_init(NULL, NULL);
  srtp_init();
  if (!session) return NULL;

  NvstBridge* b = nvst_pipeline_create(session->codec, log_cb, frame_cb, userdata);
  if (!b) return NULL;

  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) {
    nvst_log(b, "nvst: socket() failed");
    nvst_video_stop(b);
    return NULL;
  }
  struct sockaddr_in bind_addr;
  memset(&bind_addr, 0, sizeof(bind_addr));
  bind_addr.sin_family = AF_INET;
  bind_addr.sin_addr.s_addr = htonl(INADDR_ANY);
  bind_addr.sin_port = htons(session->client_udp_port);
  if (bind(fd, (struct sockaddr*)&bind_addr, sizeof(bind_addr)) < 0) {
    nvst_log(b, "nvst: UDP bind %u failed: %s", session->client_udp_port,
             strerror(errno));
    close(fd);
    nvst_video_stop(b);
    return NULL;
  }
  struct timeval tv = {0, 250000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

  const char* ping = session->ping_payload[0] ? session->ping_payload : "PING";
  struct sockaddr_in peer;
  memset(&peer, 0, sizeof(peer));
  peer.sin_family = AF_INET;
  peer.sin_port = htons(session->video_peer_port);
  if (inet_pton(AF_INET, session->video_peer_ip, &peer.sin_addr) != 1) {
    nvst_log(b, "nvst: invalid video peer IP %s", session->video_peer_ip);
    close(fd);
    nvst_video_stop(b);
    return NULL;
  }
  if (session->ping_version >= 6 && session->remote_ice_ufrag[0] &&
      session->remote_ice_pwd[0] && session->local_ice_ufrag[0] &&
      session->local_ice_pwd[0]) {
    // Ping version 6: authenticated ICE/STUN punch (the receive thread keeps
    // it running every 20 ms until media flows).
    hole_punch_volley(fd, session->video_peer_ip, session->video_peer_port,
                      session->local_ice_ufrag, session->remote_ice_ufrag,
                      session->remote_ice_pwd);
    nvst_log(b, "nvst: STUN hole-punch volley sent to %s:%u from port %u",
             session->video_peer_ip, session->video_peer_port,
             session->client_udp_port);
  } else {
    ssize_t sent = sendto(fd, ping, strlen(ping), 0, (struct sockaddr*)&peer,
                          sizeof(peer));
    nvst_log(b, "nvst: hole-punch sent (%zd B) to %s:%u from port %u",
             sent < 0 ? 0 : sent, session->video_peer_ip,
             session->video_peer_port, session->client_udp_port);
  }

  NvstUdpThread* t = g_new0(NvstUdpThread, 1);
  t->bridge = b;
  t->session = *session;
  t->socket_fd = fd;
  t->stop = FALSE;
  unsigned char aes_key[32];
  if (nvst_parse_aes_key_hex(session->srtp_aes_key_hex, aes_key) == 0) {
    unsigned char master[44];
    nvst_pack_master_key_salt(aes_key, session->srtp_key_id, master);
    srtp_policy_t policy;
    memset(&policy, 0, sizeof(policy));
    srtp_crypto_policy_set_aes_gcm_256_8_auth(&policy.rtp);
    srtp_crypto_policy_set_aes_gcm_256_8_auth(&policy.rtcp);
    policy.ssrc.type = ssrc_any_inbound;
    policy.ssrc.value = 0;
    policy.key = master;
    policy.window_size = 1024;
    if (srtp_create(&t->srtp_ctx, &policy) == srtp_err_status_ok) {
      nvst_log(b, "nvst: SRTP session created (AEAD_AES_256_GCM, keyId %u)",
               session->srtp_key_id);
    } else {
      t->srtp_ctx = NULL;
      nvst_log(b, "nvst: SRTP create failed — falling back to cleartext RTP");
    }
  } else {
    t->srtp_ctx = NULL;
    nvst_log(b, "nvst: no valid AES key — cleartext RTP fallback");
  }

  pthread_t th;
  if (pthread_create(&th, NULL, nvst_udp_thread_main, t) != 0) {
    nvst_log(b, "nvst: UDP thread create failed");
    if (t->srtp_ctx) srtp_dealloc(t->srtp_ctx);
    close(fd);
    g_free(t);
    nvst_video_stop(b);
    return NULL;
  }
  pthread_detach(th);
  return b;
}

void nvst_video_stop(NvstBridge* bridge) {
  if (!bridge) return;
  bridge->destroyed = TRUE;
  if (bridge->loop && bridge->loop_thread) {
    g_main_loop_quit(bridge->loop);
    g_thread_join(bridge->loop_thread);
  }
  if (bridge->pipeline) {
    gst_element_set_state(bridge->pipeline, GST_STATE_NULL);
    gst_object_unref(bridge->pipeline);
  }
  g_mutex_clear(&bridge->stats_mutex);
  g_free(bridge);
}

int nvst_frames_decoded(NvstBridge* bridge) {
  if (!bridge) return 0;
  g_mutex_lock(&bridge->stats_mutex);
  int n = bridge->frames_decoded;
  g_mutex_unlock(&bridge->stats_mutex);
  return n;
}

void nvst_free_string(char* s) { g_free(s); }
void nvst_free_ptr(void* p) { free(p); }

// ---------------------------------------------------------------------------
// RTSPS probe (raw RTSPS + WebSocket fallbacks, OpenNOW parity)
// ---------------------------------------------------------------------------

typedef struct {
  SSL* ssl;
  int fd;
  int raw;  // 1 = raw RTSPS (RTSP directly over TLS), 0 = WSS
} WsConn;

// Raw TLS connect to host:port (shared by raw-RTSPS and WSS paths).
static int tls_connect(const char* host, int port, SSL** out_ssl, int* out_fd,
                       char* err, size_t err_cap) {
  SSL_CTX* ctx = SSL_CTX_new(TLS_client_method());
  if (!ctx) {
    snprintf(err, err_cap, "SSL_CTX_new failed");
    return -1;
  }
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  // OpenNOW uses rejectUnauthorized:true (system trust roots). Mirror that:
  // the GFN RTSPS endpoint presents a real cert and may reject clients that
  // skip verification at the TLS layer (HTTP 501 at the app layer is often a
  // symptom of a failed ClientHello-level handshake artifact). Load system
  // roots; if none are available, fall back to no-verify so the probe still
  // attempts the upgrade.
  if (SSL_CTX_set_default_verify_paths(ctx) != 1) {
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
  } else {
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
  }

  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    snprintf(err, err_cap, "socket() failed");
    SSL_CTX_free(ctx);
    return -1;
  }
  struct hostent* he = gethostbyname(host);
  if (!he) {
    snprintf(err, err_cap, "gethostbyname failed: %s", host);
    close(fd);
    SSL_CTX_free(ctx);
    return -1;
  }
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);
  if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
    snprintf(err, err_cap, "connect failed: %s", strerror(errno));
    close(fd);
    SSL_CTX_free(ctx);
    return -1;
  }

  SSL* ssl = SSL_new(ctx);
  SSL_CTX_free(ctx);  // ctx no longer needed after SSL_new
  if (!ssl) {
    snprintf(err, err_cap, "SSL_new failed");
    close(fd);
    return -1;
  }
  if (SSL_set_fd(ssl, fd) != 1) {
    snprintf(err, err_cap, "SSL_set_fd failed");
    SSL_free(ssl);
    close(fd);
    return -1;
  }
  SSL_set_tlsext_host_name(ssl, host);
  if (SSL_connect(ssl) != 1) {
    snprintf(err, err_cap, "TLS connect failed");
    SSL_free(ssl);
    close(fd);
    return -1;
  }
  *out_ssl = ssl;
  *out_fd = fd;
  return 0;
}

static void ws_close(WsConn* c) {
  if (!c) return;
  if (c->ssl) SSL_free(c->ssl);
  if (c->fd >= 0) close(c->fd);
  free(c);
}

// Read exactly n bytes (retry on WANT_READ/WANT_WRITE).
static int ssl_read_full(SSL* ssl, void* buf, size_t n) {
  size_t got = 0;
  unsigned char* p = (unsigned char*)buf;
  while (got < n) {
    int r = SSL_read(ssl, p + got, (int)(n - got));
    if (r <= 0) {
      int e = SSL_get_error(ssl, r);
      if (e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE) continue;
      return -1;
    }
    got += (size_t)r;
  }
  return 0;
}

// Read an RTSP response over raw TLS: headers until CRLFCRLF, then body per
// Content-Length. Returns 0 on success.
static int raw_read_response(WsConn* c, char* resp, size_t resp_cap, char* err,
                             size_t err_cap) {
  size_t total = 0;
  while (total < resp_cap - 1) {
    char ch;
    if (ssl_read_full(c->ssl, &ch, 1) != 0) {
      snprintf(err, err_cap, "RTSP read failed");
      return -1;
    }
    resp[total++] = ch;
    if (total >= 4 && memcmp(resp + total - 4, "\r\n\r\n", 4) == 0) break;
  }
  resp[total] = '\0';
  char* body_start = strstr(resp, "\r\n\r\n");
  if (!body_start) {
    snprintf(err, err_cap, "RTSP response missing header terminator");
    return -1;
  }
  size_t hdr_end_off = (size_t)(body_start - resp) + 4;
  const char* cl = strstr(resp, "Content-Length:");
  long clen = 0;
  if (cl) clen = atol(cl + strlen("Content-Length:"));
  if (clen > 0) {
    size_t have = total - hdr_end_off;
    if (have < (size_t)clen) {
      size_t need = (size_t)clen - have;
      if (hdr_end_off + (size_t)clen >= resp_cap) {
        snprintf(err, err_cap, "RTSP response too large");
        return -1;
      }
      if (ssl_read_full(c->ssl, resp + total, need) != 0) {
        snprintf(err, err_cap, "RTSP body read failed");
        return -1;
      }
      total += need;
      resp[total] = '\0';
    }
  }
  return 0;
}

// Read one WebSocket frame payload. Handles ping/pong (0x9/0xA) by skipping
// and looping; returns text (0x1) payload. Returns 0 on success.
static int ws_read_frame_payload(WsConn* c, char** out, size_t* out_len) {
  for (;;) {
    uint8_t hdr[2];
    if (ssl_read_full(c->ssl, hdr, 2) != 0) return -1;
    int opcode = hdr[0] & 0x0f;
    int masked = (hdr[1] & 0x80) != 0;
    uint64_t len = hdr[1] & 0x7f;
    if (len == 126) {
      uint8_t ext[2];
      if (ssl_read_full(c->ssl, ext, 2) != 0) return -1;
      len = (ext[0] << 8) | ext[1];
    } else if (len == 127) {
      uint8_t ext[8];
      if (ssl_read_full(c->ssl, ext, 8) != 0) return -1;
      len = 0;
      for (int i = 0; i < 8; i++) len = (len << 8) | ext[i];
    }
    if (len > 1 << 20) return -1;
    uint8_t mask[4] = {0, 0, 0, 0};
    if (masked) {
      if (ssl_read_full(c->ssl, mask, 4) != 0) return -1;
    }
    char* buf = (char*)malloc((size_t)len + 1);
    if (!buf) return -1;
    if (ssl_read_full(c->ssl, buf, (size_t)len) != 0) {
      free(buf);
      return -1;
    }
    if (masked) {
      for (uint64_t i = 0; i < len; i++) buf[i] ^= mask[i % 4];
    }
    if (opcode == 0x9 || opcode == 0xA) {
      free(buf);  // ping/pong: skip
      continue;
    }
    if (opcode != 0x1) {
      free(buf);
      return -1;
    }
    buf[len] = '\0';
    *out = buf;
    *out_len = (size_t)len;
    return 0;
  }
}

// Send a masked WebSocket text frame (opcode 0x1).
static int ws_send_text(WsConn* c, const char* msg, size_t len) {
  uint8_t hdr[14];
  size_t hlen = 0;
  hdr[0] = 0x81;  // FIN + text
  if (len < 126) {
    hdr[1] = 0x80 | (uint8_t)len;
    hlen = 2;
  } else if (len < 65536) {
    hdr[1] = 0x80 | 126;
    hdr[2] = (uint8_t)(len >> 8);
    hdr[3] = (uint8_t)(len & 0xff);
    hlen = 4;
  } else {
    hdr[1] = 0x80 | 127;
    for (int i = 0; i < 8; i++) hdr[2 + i] = (uint8_t)((len >> (8 * (7 - i))) & 0xff);
    hlen = 10;
  }
  uint8_t mask[4] = {0x12, 0x34, 0x56, 0x78};
  memcpy(hdr + hlen, mask, 4);
  hlen += 4;
  if (SSL_write(c->ssl, hdr, (int)hlen) != (int)hlen) return -1;
  uint8_t* masked = (uint8_t*)malloc(len ? len : 1);
  for (size_t i = 0; i < len; i++) masked[i] = (uint8_t)msg[i] ^ mask[i % 4];
  int r = SSL_write(c->ssl, masked, (int)len);
  free(masked);
  return r == (int)len ? 0 : -1;
}

int nvst_bridge_abi_version(void) { return NVST_BRIDGE_ABI_VERSION; }

// Base64-encode (standard alphabet, padded). out needs 4*ceil(len/3)+1 bytes.
static void b64_encode(const uint8_t* in, size_t len, char* out) {
  static const char b64[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  size_t o = 0;
  for (size_t i = 0; i < len; i += 3) {
    uint32_t v = (uint32_t)in[i] << 16;
    if (i + 1 < len) v |= (uint32_t)in[i + 1] << 8;
    if (i + 2 < len) v |= in[i + 2];
    out[o++] = b64[(v >> 18) & 0x3f];
    out[o++] = b64[(v >> 12) & 0x3f];
    out[o++] = (i + 1 < len) ? b64[(v >> 6) & 0x3f] : '=';
    out[o++] = (i + 2 < len) ? b64[v & 0x3f] : '=';
  }
  out[o] = '\0';
}

// WSS upgrade: TLS + Bifrost-shaped GET (OpenNOW buildNvstWssUpgradeRequest:
// Poco header order, Content-Length: 0). `use_subprotocol` selects the
// CloudMatch signaling-style upgrade (Sec-WebSocket-Protocol:
// x-nv-sessionid.<id>) used by per-session gateways. `x-nv-sessionid` is
// attached per the with_session_header flag.
// Returns 0 on success.
static WsConn* wss_connect(const char* host, int port, const char* session_id,
                           const char* target_form, int with_session_header,
                           int use_subprotocol, const char* extra_headers,
                           int omit_content_length, char* err,
                           size_t err_cap) {
  SSL* ssl = NULL;
  int fd = -1;
  if (tls_connect(host, port, &ssl, &fd, err, err_cap) != 0) return NULL;
  WsConn* c = (WsConn*)malloc(sizeof(WsConn));
  if (!c) {
    SSL_free(ssl);
    close(fd);
    return NULL;
  }
  c->ssl = ssl;
  c->fd = fd;
  c->raw = 0;

  uint8_t key_bytes[16];
  RAND_bytes(key_bytes, sizeof(key_bytes));
  char sec_key[25];
  b64_encode(key_bytes, sizeof(key_bytes), sec_key);

  char req[4096];
  // Two accepted upgrade shapes, both seen working in the field:
  //  - official Bifrost (:322): bare `GET /rtsp` + `x-nv-sessionid` header
  //    (OpenNOW clientHeaders.ts: "that upgrade is GET /rtsp + x-nv-sessionid
  //    only")
  //  - CloudMatch signaling front (/nvst/): the Dart signaling client's exact
  //    shape — subprotocol, NO Content-Length, NO sid header.
  //  - Host omits default ports (443/322) like the Dart/JS clients do.
  int n;
  char host_hdr[300];
  if (port == 443 || port == 322) {
    snprintf(host_hdr, sizeof(host_hdr), "Host: %s\r\n", host);
  } else {
    snprintf(host_hdr, sizeof(host_hdr), "Host: %s:%d\r\n", host, port);
  }
  const char* cl_line = omit_content_length ? "" : "Content-Length: 0\r\n";
  if (use_subprotocol) {
    n = snprintf(
        req, sizeof(req),
        "GET %s HTTP/1.1\r\n"
        "%s"
        "Connection: Upgrade\r\n"
        "Upgrade: websocket\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "Sec-WebSocket-Protocol: x-nv-sessionid.%s\r\n"
        "%s",
        target_form, host_hdr, sec_key,
        (session_id && session_id[0]) ? session_id : "", cl_line);
  } else {
    n = snprintf(
        req, sizeof(req),
        "GET %s HTTP/1.1\r\n"
        "%s"
        "Connection: Upgrade\r\n"
        "Upgrade: websocket\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Sec-WebSocket-Key: %s\r\n"
        "%s",
        target_form, host_hdr, sec_key, cl_line);
  }
  if (with_session_header && session_id && session_id[0] && n > 0 &&
      n < (int)sizeof(req)) {
    n += snprintf(req + n, sizeof(req) - (size_t)n,
                  "x-nv-sessionid: %s\r\n", session_id);
  }
  if (extra_headers && extra_headers[0] && n > 0 && n < (int)sizeof(req)) {
    n += snprintf(req + n, sizeof(req) - (size_t)n, "%s", extra_headers);
  }
  if (n > 0 && n < (int)sizeof(req)) {
    n += snprintf(req + n, sizeof(req) - (size_t)n, "\r\n");
  }
  if (n <= 0 || n >= (int)sizeof(req)) {
    snprintf(err, err_cap, "WSS upgrade request too large");
    ws_close(c);
    return NULL;
  }
  if (SSL_write(ssl, req, n) != n) {
    snprintf(err, err_cap, "WSS upgrade write failed");
    ws_close(c);
    return NULL;
  }

  // Read the HTTP 101 response headers.
  char hdrs[4096];
  size_t total = 0;
  while (total < sizeof(hdrs) - 1) {
    char ch;
    if (ssl_read_full(ssl, &ch, 1) != 0) {
      snprintf(err, err_cap, "WSS upgrade read failed");
      ws_close(c);
      return NULL;
    }
    hdrs[total++] = ch;
    if (total >= 4 && memcmp(hdrs + total - 4, "\r\n\r\n", 4) == 0) break;
  }
  hdrs[total] = '\0';
  int status = 0;
  sscanf(hdrs, "HTTP/%*d.%*d %d", &status);
  if (status != 101) {
    // Include the status line + first body line — Bifrost's error body says
    // what it rejected (unknown route / session / upgrade target).
    char first_line[128] = {0};
    for (size_t i = 0; i < total && i < sizeof(first_line) - 1; i++) {
      if (hdrs[i] == '\r' || hdrs[i] == '\n') break;
      first_line[i] = hdrs[i];
    }
    const char* body_start = strstr(hdrs, "\r\n\r\n");
    char body_line[128] = {0};
    if (body_start) {
      body_start += 4;
      size_t j = 0;
      while (body_start[j] && body_start[j] != '\r' && body_start[j] != '\n' &&
             j < sizeof(body_line) - 1) {
        body_line[j] = body_start[j];
        j++;
      }
    }
    snprintf(err, err_cap, "WSS upgrade failed: HTTP %d (%s | %s) [%s]",
             status, first_line, body_line, target_form);
    ws_close(c);
    return NULL;
  }
  // Validate Sec-WebSocket-Accept = base64(SHA1(key + RFC6455 GUID)) —
  // OpenNOW does the same to catch misrouted/hand-rolled upgrades.
  {
    char guid[64];
    snprintf(guid, sizeof(guid), "%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
             sec_key);
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int md_len = 0;
    if (EVP_Digest(guid, strlen(guid), md, &md_len, EVP_sha1(), NULL) != 1) {
      snprintf(err, err_cap, "WSS upgrade: SHA1 failed");
      ws_close(c);
      return NULL;
    }
    char expect[64];
    b64_encode(md, md_len, expect);
    const char* got = find_header_ci(hdrs, "Sec-WebSocket-Accept:");
    if (got) {
      got += strlen("Sec-WebSocket-Accept:");
      while (*got == ' ' || *got == '\t') got++;
      if (strncmp(got, expect, strlen(expect)) != 0) {
        snprintf(err, err_cap, "WSS upgrade: invalid Sec-WebSocket-Accept");
        ws_close(c);
        return NULL;
      }
    }
  }
  return c;
}

// Send one RTSP request and read one response (WSS). Every request carries
// the common Bifrost identity headers (OpenNOW commonHeaders): CSeq,
// Request-Id, X-GS-Version: 14.2, Host, x-nv-sessionid.
static int rtsp_request(WsConn* c, const char* method, const char* uri,
                        const char* host_header, const char* nv_session,
                        const char* session, const char* extra_headers,
                        const char* body, char* resp, size_t resp_cap,
                        char* err, size_t err_cap) {
  static int cseq = 0;
  cseq++;
  char msg[8192];
  int n = snprintf(msg, sizeof(msg),
                   "%s %s RTSP/1.0\r\nCSeq: %d\r\nRequest-Id: %d\r\n"
                   "X-GS-Version: 14.2\r\n",
                   method, uri, cseq, cseq);
  if (host_header && host_header[0] && n > 0 && n < (int)sizeof(msg)) {
    n += snprintf(msg + n, sizeof(msg) - (size_t)n, "Host: %s\r\n",
                  host_header);
  }
  if (nv_session && nv_session[0] && n > 0 && n < (int)sizeof(msg)) {
    n += snprintf(msg + n, sizeof(msg) - (size_t)n, "x-nv-sessionid: %s\r\n",
                  nv_session);
  }
  if (session && session[0] && n > 0 && n < (int)sizeof(msg)) {
    n += snprintf(msg + n, sizeof(msg) - (size_t)n, "Session: %s\r\n", session);
  }
  if (extra_headers && extra_headers[0] && n > 0 && n < (int)sizeof(msg)) {
    n += snprintf(msg + n, sizeof(msg) - (size_t)n, "%s\r\n", extra_headers);
  }
  if (body && body[0]) {
    n += snprintf(msg + n, sizeof(msg) - (size_t)n, "Content-Length: %zu\r\n",
                  strlen(body));
  }
  if (n > 0 && n < (int)sizeof(msg)) {
    n += snprintf(msg + n, sizeof(msg) - (size_t)n, "\r\n");
  }
  if (body && body[0] && n > 0 && n < (int)sizeof(msg)) {
    n += snprintf(msg + n, sizeof(msg) - (size_t)n, "%s", body);
  }
  if (n <= 0 || n >= (int)sizeof(msg)) {
    snprintf(err, err_cap, "RTSP request too large");
    return -1;
  }

  if (c->raw) {
    if (SSL_write(c->ssl, msg, n) != n) {
      snprintf(err, err_cap, "RTSP send failed");
      return -1;
    }
    if (raw_read_response(c, resp, resp_cap, err, err_cap) != 0) return -1;
    return 0;
  }
  if (ws_send_text(c, msg, (size_t)n) != 0) {
    snprintf(err, err_cap, "RTSP send failed");
    return -1;
  }
  char* frame = NULL;
  size_t frame_len = 0;
  if (ws_read_frame_payload(c, &frame, &frame_len) != 0) {
    snprintf(err, err_cap, "RTSP read failed");
    return -1;
  }
  if (frame_len >= resp_cap) frame_len = resp_cap - 1;
  memcpy(resp, frame, frame_len);
  resp[frame_len] = '\0';
  free(frame);
  return 0;
}

// --- SDP helpers -------------------------------------------------------------

static int extract_runtime_encryption_key(const char* sdp, char* key_hex,
                                          size_t key_cap, unsigned int* key_id) {
  *key_hex = '\0';
  const char* km = strstr(sdp, "a=x-nv-runtime.encryptionKey:");
  const char* im = strstr(sdp, "a=x-nv-runtime.encryptionKeyId:");
  if (!km || !im) return -1;
  km += strlen("a=x-nv-runtime.encryptionKey:");
  size_t i = 0;
  while (km[i] && km[i] != '\r' && km[i] != '\n' && i < key_cap - 1) {
    key_hex[i] = km[i];
    i++;
  }
  key_hex[i] = '\0';
  im += strlen("a=x-nv-runtime.encryptionKeyId:");
  long id = strtol(im, NULL, 10);
  if (id < 0) id += 0x100000000L;
  *key_id = (unsigned int)(id & 0xffffffffu);
  return strlen(key_hex) == 64 ? 0 : -1;
}

// OpenNOW extractNvstSdpAttribute: matches `a=<name>:` or `a=x-nv-<name>:`
// (the x-nv prefix covers namespaced forms like `x-nv-general.foo`).
static int sdp_attr(const char* sdp, const char* name, char* out,
                    size_t out_cap) {
  char with_nv[128];
  snprintf(with_nv, sizeof(with_nv), "a=x-nv-%s:", name);
  char plain[128];
  snprintf(plain, sizeof(plain), "a=%s:", name);
  const char* patterns[2] = {with_nv, plain};
  for (int i = 0; i < 2; i++) {
    const char* p = strstr(sdp, patterns[i]);
    if (!p) continue;
    p += strlen(patterns[i]);
    size_t j = 0;
    while (p[j] && p[j] != '\r' && p[j] != '\n' && j < out_cap - 1) {
      out[j] = p[j];
      j++;
    }
    while (j > 0 && (out[j - 1] == ' ' || out[j - 1] == '\t')) j--;
    out[j] = '\0';
    return j > 0 ? 0 : -1;
  }
  return -1;
}

// OpenNOW extractMediaControl: the `a=control:` line inside the m=<type>
// section.
static int extract_media_control(const char* sdp, const char* media_type,
                                 char* out, size_t out_cap) {
  const char* p = sdp;
  char current[32] = {0};
  while (p && *p) {
    const char* eol = strstr(p, "\r\n");
    size_t len = eol ? (size_t)(eol - p) : strlen(p);
    if (len > 2 && strncmp(p, "m=", 2) == 0) {
      size_t n = 0;
      while (n < len - 2 && p[2 + n] && p[2 + n] != ' ' && p[2 + n] != '\t' &&
             n < sizeof(current) - 1) {
        current[n] = (char)g_ascii_tolower(p[2 + n]);
        n++;
      }
      current[n] = '\0';
    } else if (len > 10 && current[0] &&
               g_ascii_strcasecmp(current, media_type) == 0 &&
               strncmp(p, "a=control:", 10) == 0) {
      const char* v = p + 10;
      size_t n = 0;
      while (v[n] && v[n] != '\r' && v[n] != '\n' && n < out_cap - 1) {
        out[n] = v[n];
        n++;
      }
      out[n] = '\0';
      if (out[0] && g_strcmp0(out, "*") != 0) return 0;
    }
    if (!eol) break;
    p = eol + 2;
  }
  return -1;
}

// OpenNOW extractNvstIceCredentials: V2 attrs first, then legacy.
static int extract_ice_credentials(const char* sdp, char* ufrag,
                                   size_t ufrag_cap, char* pwd,
                                   size_t pwd_cap) {
  ufrag[0] = pwd[0] = '\0';
  const char* pats_u[] = {"a=x-nv-general.iceUserNameFragmentV2:",
                          "a=x-nv-general.iceUsernameFragment:", "a=ice-ufrag:"};
  const char* pats_p[] = {"a=x-nv-general.icePasswordV2:",
                          "a=x-nv-general.iceUsernamePwd:", "a=ice-pwd:"};
  for (int i = 0; i < 3 && !ufrag[0]; i++) {
    const char* p = strstr(sdp, pats_u[i]);
    if (!p) continue;
    p += strlen(pats_u[i]);
    size_t j = 0;
    while (p[j] && p[j] != '\r' && p[j] != '\n' && j < ufrag_cap - 1) {
      ufrag[j] = p[j];
      j++;
    }
    while (j > 0 && (ufrag[j - 1] == ' ' || ufrag[j - 1] == '\t')) j--;
    ufrag[j] = '\0';
  }
  for (int i = 0; i < 3 && !pwd[0]; i++) {
    const char* p = strstr(sdp, pats_p[i]);
    if (!p) continue;
    p += strlen(pats_p[i]);
    size_t j = 0;
    while (p[j] && p[j] != '\r' && p[j] != '\n' && j < pwd_cap - 1) {
      pwd[j] = p[j];
      j++;
    }
    while (j > 0 && (pwd[j - 1] == ' ' || pwd[j - 1] == '\t')) j--;
    pwd[j] = '\0';
  }
  return (ufrag[0] && pwd[0]) ? 0 : -1;
}

// OpenNOW generateNvstIceCredentials: 4-char ufrag + 22-char pwd from the
// base64 alphabet.
static void generate_ice_credentials(char* ufrag, size_t ufrag_cap, char* pwd,
                                     size_t pwd_cap) {
  static const char alphabet[] =
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/";
  uint8_t rnd[26];
  RAND_bytes(rnd, sizeof(rnd));
  size_t i = 0;
  for (; i < 4 && i < ufrag_cap - 1; i++) ufrag[i] = alphabet[rnd[i] & 0x3f];
  ufrag[i] = '\0';
  for (i = 0; i < 22 && i < pwd_cap - 1; i++) {
    pwd[i] = alphabet[rnd[4 + i] & 0x3f];
  }
  pwd[i] = '\0';
}

// --- Authenticated STUN hole punch (OpenNOW buildNvstStunBindingRequest /
// buildNvstStunBindingSuccess) -----------------------------------------------

static uint32_t crc32_ieee(const uint8_t* data, size_t len) {
  static uint32_t table[256];
  static gboolean table_ready = FALSE;
  if (!table_ready) {
    for (uint32_t v = 0; v < 256; v++) {
      uint32_t crc = v;
      for (int bit = 0; bit < 8; bit++) {
        crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320u : 0);
      }
      table[v] = crc;
    }
    table_ready = TRUE;
  }
  uint32_t crc = 0xffffffffu;
  for (size_t i = 0; i < len; i++) {
    crc = (crc >> 8) ^ table[(crc ^ data[i]) & 0xff];
  }
  return crc ^ 0xffffffffu;
}

static int hmac_sha1(const char* key, const uint8_t* data, size_t len,
                     uint8_t out[20]) {
  EVP_PKEY* pkey =
      EVP_PKEY_new_raw_private_key(EVP_PKEY_HMAC, NULL, (const uint8_t*)key,
                                   strlen(key));
  if (!pkey) return -1;
  EVP_MD_CTX* ctx = EVP_MD_CTX_new();
  int ok = -1;
  size_t out_len = 20;
  if (ctx && EVP_DigestSignInit(ctx, NULL, EVP_sha1(), NULL, pkey) == 1 &&
      EVP_DigestSign(ctx, out, &out_len, data, len) == 1 && out_len == 20) {
    ok = 0;
  }
  EVP_MD_CTX_free(ctx);
  EVP_PKEY_free(pkey);
  return ok;
}

static size_t stun_append_attr(uint8_t* msg, size_t pos, uint16_t type,
                               const uint8_t* value, size_t vlen) {
  msg[pos++] = (uint8_t)(type >> 8);
  msg[pos++] = (uint8_t)(type & 0xff);
  msg[pos++] = (uint8_t)(vlen >> 8);
  msg[pos++] = (uint8_t)(vlen & 0xff);
  memcpy(msg + pos, value, vlen);
  pos += vlen;
  size_t padding = (4 - (vlen % 4)) % 4;
  memset(msg + pos, 0, padding);
  return pos + padding;
}

// RFC 5389 Binding Request: USERNAME(remote:local) + MESSAGE-INTEGRITY +
// FINGERPRINT.
static size_t build_stun_binding_request(const char* local_ufrag,
                                         const char* remote_ufrag,
                                         const char* remote_pwd, uint8_t* msg,
                                         size_t msg_cap) {
  char username[160];
  snprintf(username, sizeof(username), "%s:%s", remote_ufrag, local_ufrag);
  size_t ulen = strlen(username);
  size_t body = 4 + ulen + ((4 - (ulen % 4)) % 4);
  size_t total = 20 + body + 24 + 8;
  if (total > msg_cap) return 0;
  memset(msg, 0, total);
  msg[0] = 0x00;
  msg[1] = 0x01;  // Binding Request
  msg[3] = (uint8_t)(body + 24 + 8);
  msg[4] = 0x21;
  msg[5] = 0x12;
  msg[6] = 0xA4;
  msg[7] = 0x42;  // magic cookie
  RAND_bytes(msg + 8, 12);
  size_t pos = stun_append_attr(msg, 20, 0x0006, (const uint8_t*)username,
                                ulen);
  msg[3] = (uint8_t)(body + 24);
  uint8_t mac[20];
  if (hmac_sha1(remote_pwd, msg, pos, mac) != 0) return 0;
  msg[3] = (uint8_t)(body + 24 + 8);
  pos = stun_append_attr(msg, pos, 0x0008, mac, 20);
  msg[3] = (uint8_t)(body + 24 + 8);
  uint32_t crc = crc32_ieee(msg, pos) ^ 0x5354554eu;
  uint8_t fp[4] = {(uint8_t)(crc >> 24), (uint8_t)(crc >> 16),
                   (uint8_t)(crc >> 8), (uint8_t)crc};
  return stun_append_attr(msg, pos, 0x8028, fp, 4);
}

// RFC 5389 Binding Success for an inbound server request (ping version 6):
// XOR-MAPPED-ADDRESS(from) + MESSAGE-INTEGRITY(local pwd) + FINGERPRINT.
static size_t build_stun_binding_success(const char* local_pwd,
                                         const uint8_t* txid /*12*/,
                                         const char* mapped_ip,
                                         unsigned short mapped_port,
                                         uint8_t* msg, size_t msg_cap) {
  struct in_addr addr;
  if (inet_pton(AF_INET, mapped_ip, &addr) != 1) return 0;
  size_t total = 20 + 12 + 24 + 8;
  if (total > msg_cap) return 0;
  memset(msg, 0, total);
  msg[0] = 0x01;
  msg[1] = 0x01;  // Binding Success
  msg[3] = (uint8_t)(12 + 24 + 8);
  msg[4] = 0x21;
  msg[5] = 0x12;
  msg[6] = 0xA4;
  msg[7] = 0x42;
  memcpy(msg + 8, txid, 12);
  uint8_t xma[8] = {0, 0x01, (uint8_t)((mapped_port >> 8) ^ 0x21),
                    (uint8_t)((mapped_port & 0xff) ^ 0x12), 0, 0, 0, 0};
  const uint8_t* ip = (const uint8_t*)&addr.s_addr;
  static const uint8_t magic[4] = {0x21, 0x12, 0xA4, 0x42};
  for (int i = 0; i < 4; i++) xma[4 + i] = ip[i] ^ magic[i];
  size_t pos = stun_append_attr(msg, 20, 0x0020, xma, 8);
  msg[3] = (uint8_t)(12 + 24);
  uint8_t mac[20];
  if (hmac_sha1(local_pwd, msg, pos, mac) != 0) return 0;
  msg[3] = (uint8_t)(12 + 24 + 8);
  pos = stun_append_attr(msg, pos, 0x0008, mac, 20);
  msg[3] = (uint8_t)(12 + 24 + 8);
  uint32_t crc = crc32_ieee(msg, pos) ^ 0x5354554eu;
  uint8_t fp[4] = {(uint8_t)(crc >> 24), (uint8_t)(crc >> 16),
                   (uint8_t)(crc >> 8), (uint8_t)crc};
  return stun_append_attr(msg, pos, 0x8028, fp, 4);
}

// Send one hole-punch volley: 3x ICE Binding Requests (local ufrag ↔ remote
// ufrag, authenticated with the server's DESCRIBE password) + 1 NATT binding
// with the literal "PING" username (OpenNOW sendPing).
static void hole_punch_volley(int fd, const char* peer_ip,
                              unsigned short peer_port, const char* local_ufrag,
                              const char* remote_ufrag, const char* remote_pwd) {
  struct sockaddr_in to;
  memset(&to, 0, sizeof(to));
  to.sin_family = AF_INET;
  to.sin_port = htons(peer_port);
  if (inet_pton(AF_INET, peer_ip, &to.sin_addr) != 1) return;
  uint8_t pkt[256];
  for (int i = 0; i < 3; i++) {
    size_t n = build_stun_binding_request(local_ufrag, remote_ufrag, remote_pwd,
                                          pkt, sizeof(pkt));
    if (n > 0) sendto(fd, pkt, n, 0, (struct sockaddr*)&to, sizeof(to));
  }
  size_t n =
      build_stun_binding_request(local_ufrag, "PING", remote_pwd, pkt,
                                 sizeof(pkt));
  if (n > 0) sendto(fd, pkt, n, 0, (struct sockaddr*)&to, sizeof(to));
}

// Drain inbound datagrams, answering STUN Binding Requests with an
// authenticated Binding Success and legacy "PING" with "PONG".
static void hole_punch_drain(int fd, const char* local_pwd) {
  for (;;) {
    uint8_t buf[2048];
    struct sockaddr_in from;
    socklen_t flen = sizeof(from);
    ssize_t n = recvfrom(fd, buf, sizeof(buf), MSG_DONTWAIT,
                         (struct sockaddr*)&from, &flen);
    if (n <= 0) return;
    if (n == 4 && memcmp(buf, "PING", 4) == 0) {
      sendto(fd, "PONG", 4, 0, (struct sockaddr*)&from, flen);
      continue;
    }
    if (n >= 20 && buf[0] == 0x00 && buf[1] == 0x01) {  // Binding Request
      uint8_t reply[64];
      char ip[INET_ADDRSTRLEN] = {0};
      inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
      size_t rlen =
          build_stun_binding_success(local_pwd, buf + 8, ip,
                                     ntohs(from.sin_port), reply,
                                     sizeof(reply));
      if (rlen > 0) {
        sendto(fd, reply, rlen, 0, (struct sockaddr*)&from, flen);
      }
    }
  }
}

// Mature ANNOUNCE SDP (OpenNOW buildAnnounceSdp, legacy non-cloud path):
// Bifrost allowlist + runtime encryption key + ICE credentials +
// clientTransport. GFN keys video SRTP on this key even with DTLS present.
static void build_announce_sdp(int width, int height, int fps,
                               const char* codec, const char* key_hex,
                               unsigned int key_id, const char* local_ufrag,
                               const char* local_pwd, const char* local_ipv4,
                               unsigned short client_port,
                               unsigned short video_port, char* out,
                               size_t out_cap) {
  // bitStreamFormat: AV1=2, H265=1, H264=0.
  const char* bit_stream_format = "0";
  const char* client_support_hevc = "0";
  if (codec && g_ascii_strcasecmp(codec, "AV1") == 0) {
    bit_stream_format = "2";
  } else if (codec && (g_ascii_strcasecmp(codec, "H265") == 0 ||
                       g_ascii_strcasecmp(codec, "HEVC") == 0)) {
    bit_stream_format = "1";
    client_support_hevc = "1";
  }
  const unsigned int max_bitrate_kbps = 100000;
  const unsigned int initial_bitrate_kbps = max_bitrate_kbps;
  // Spread high-refresh frames across <half the frame interval (OpenNOW:
  // dense 120 fps UDP bursts on Wi-Fi otherwise).
  const int max_delay_us = fps >= 100 ? 4000 : 2000;

  GString* s = g_string_sized_new(8192);
#define APPEND(...) g_string_append_printf(s, __VA_ARGS__)
  APPEND("v=0\r\n");
  APPEND("o=unknown 0 14 IN IPv4 127.0.0.1\r\n");
  APPEND("s=NVIDIA Streaming Client\r\n");
  APPEND("a=x-nv-video[0].clientViewportWd:%d\r\n", width);
  APPEND("a=x-nv-video[0].clientViewportHt:%d\r\n", height);
  APPEND("a=x-nv-video[0].videoSplitEncodeStripsPerFrame:64\r\n");
  APPEND("a=x-nv-video[0].updateSplitEncodeStateDynamically:1\r\n");
  APPEND("a=x-nv-video[0].packetSize:1280\r\n");
  APPEND("a=x-nv-video[0].enableRtpNack:1\r\n");
  APPEND("a=x-nv-video[0].rtpNackQueueLength:2048\r\n");
  APPEND("a=x-nv-video[0].rtpNackQueueMaxPackets:1024\r\n");
  APPEND("a=x-nv-video[0].rtpNackMaxPacketCount:64\r\n");
  APPEND("a=x-nv-video[0].framePacing.mode:1\r\n");
  APPEND("a=x-nv-video[0].framePacing.feedbackMode:1\r\n");
  APPEND("a=x-nv-video[0].framePacing.pid.minTargetFrameTimeUs:7936\r\n");
  APPEND("a=x-nv-video[0].adaptiveQuantization.spatialAQSetting:7\r\n");
  APPEND("a=x-nv-video[0].adaptiveQuantization.temporalAQSetting:0\r\n");
  APPEND("a=x-nv-video[0].adaptiveQuantization.spatialAQStrength:12\r\n");
  APPEND("a=x-nv-video[0].adaptiveQuantization.qpThresholdAdjPercent:2\r\n");
  APPEND(
      "a=x-nv-video[0].adaptiveQuantization.saqAdaptMinQpThresholdPercent:40"
      "\r\n");
  APPEND(
      "a=x-nv-video[0].adaptiveQuantization.saqAdaptMaxQpThresholdPercent:100"
      "\r\n");
  APPEND(
      "a=x-nv-video[0].adaptiveQuantization.saqAdaptDecayStrengthX100:250"
      "\r\n");
  APPEND("a=x-nv-video[0].adaptiveQuantization.perfAdjEnablement:1\r\n");
  APPEND("a=x-nv-video[0].enableAv1RcPrecisionFactor:1\r\n");
  // CloudMatch provisions the profile, but NVST still needs the client
  // frame-rate ceiling — the server defaults to 60 FPS without it.
  APPEND("a=x-nv-video[0].maxFPS:%d\r\n", fps);
  APPEND("a=x-nv-video[0].initialBitrateKbps:%u\r\n", initial_bitrate_kbps);
  APPEND("a=x-nv-video[0].initialPeakBitrateKbps:%u\r\n",
         initial_bitrate_kbps);
  APPEND("a=x-nv-vqos[0].bitStreamFormat:%s\r\n", bit_stream_format);
  APPEND("a=x-nv-vqos[0].fec.enable:1\r\n");
  APPEND("a=x-nv-vqos[0].fec.rateDropWindow:10\r\n");
  APPEND("a=x-nv-vqos[0].fec.minRequiredFecPackets:2\r\n");
  APPEND("a=x-nv-vqos[0].fec.repairPercent:20\r\n");
  APPEND("a=x-nv-vqos[0].fec.repairMinPercent:20\r\n");
  APPEND("a=x-nv-vqos[0].fec.repairMaxPercent:35\r\n");
  APPEND("a=x-nv-vqos[0].bllFec.enable:0\r\n");
  APPEND("a=x-nv-vqos[0].grc.enable:7\r\n");
  APPEND("a=x-nv-vqos[0].drc.enable:0\r\n");
  APPEND("a=x-nv-vqos[0].dfc.adjustResAndFps:0\r\n");
  APPEND("a=x-nv-vqos[0].calculateAvgVideoStreamingBitrate:1\r\n");
  if (g_strcmp0(bit_stream_format, "2") != 0) {
    APPEND("a=x-nv-clientSupportHevc:%s\r\n", client_support_hevc);
  }
  APPEND("a=x-nv-vqos[0].bw.maximumBitrateKbps:%u\r\n", max_bitrate_kbps);
  APPEND("a=x-nv-vqos[0].bw.minimumBitrateKbps:1000\r\n");
  APPEND("a=x-nv-vqos[0].drc.bitrateIirFilterFactor:128\r\n");
  APPEND("a=x-nv-vqos[0].resControl.bitrateIirFilterFactor:128\r\n");
  APPEND("a=x-nv-vqos[0].dynamicStreamingMode:0\r\n");
  APPEND("a=x-nv-packetPacing.version:3\r\n");
  APPEND("a=x-nv-packetPacing.mode:1\r\n");
  APPEND("a=x-nv-packetPacing.numGroups:5\r\n");
  APPEND("a=x-nv-packetPacing.maxDelayUs:%d\r\n", max_delay_us);
  APPEND("a=x-nv-packetPacing.minNumPacketsFrame:10\r\n");
  APPEND("a=x-nv-packetPacing.minNumPacketsPerGroup:15\r\n");
  APPEND("a=x-nv-packetPacing.enableAccurateSleep:1\r\n");
  APPEND("a=x-nv-packetPacing.enableSmoothTransition:1\r\n");
  APPEND("a=x-nv-packetPacing.allowFpsBasedToggle:1\r\n");
  APPEND("a=x-nv-ri.partialReliableThresholdMs:300\r\n");
  APPEND("a=x-nv-ri.timestampsEnabled:1\r\n");
  APPEND("a=x-nv-ri.useMultipleGamepads:1\r\n");
  APPEND("a=x-nv-ri.usePartiallyReliableUdpChannel:0\r\n");
  APPEND("a=x-nv-ri.enablePartiallyReliableTransferGamepad:255\r\n");
  APPEND("a=x-nv-ri.enablePartiallyReliableTransferHid:-1\r\n");
  APPEND("a=x-nv-aqos.enableRedundancy:0\r\n");
  APPEND("a=x-nv-aqos.redundancyLevel:0\r\n");
  APPEND("a=x-nv-bwe.useOwdCongestionControl:1\r\n");
  APPEND("a=x-nv-general.rtspWebSocketPerConnection:1\r\n");
  APPEND("a=x-nv-general.enetControlChannel.mtuSize:1191\r\n");
  APPEND("a=x-nv-general.pingIntervalBeforeConnectionMs:20\r\n");
  APPEND("a=x-nv-general.pingIntervalAfterConnectionMs:100\r\n");
  APPEND("a=x-nv-runtime.audioSrtp:0\r\n");
  APPEND("a=x-nv-runtime.micSrtp:0\r\n");
  APPEND("a=x-nv-runtime.mouseCursorCapture:3\r\n");
  APPEND("a=x-nv-runtime.mimicRemoteCursor:0\r\n");
  APPEND("a=x-nv-runtime.videoSrtp:1\r\n");
  APPEND("a=x-nv-runtime.encryptionKey:%s\r\n", key_hex);
  APPEND("a=x-nv-runtime.encryptionKeyId:%u\r\n", key_id);
  APPEND("a=x-nv-general.iceUsernameFragment:%s\r\n", local_ufrag);
  APPEND("a=x-nv-general.iceUsernamePwd:%s\r\n", local_pwd);
  APPEND("a=x-nv-general.iceUserNameFragmentV2:%s\r\n", local_ufrag);
  APPEND("a=x-nv-general.icePasswordV2:%s\r\n", local_pwd);
  APPEND("a=x-nv-general.clientTransport:%s:%u\r\n",
         local_ipv4 ? local_ipv4 : "127.0.0.1", (unsigned int)client_port);
  APPEND("a=ice-options:trickle\r\n");
  APPEND("a=ice-ufrag:%s\r\n", local_ufrag);
  APPEND("a=ice-pwd:%s\r\n", local_pwd);
  APPEND("t=0 0\r\n");
  // Live-capture ANNOUNCE uses the server video port, not SDP "port 0".
  APPEND("m=video %u\r\n", (unsigned int)video_port);
  APPEND("c=IN IP4 0.0.0.0\r\n");
  APPEND("i=DeviceString, DeviceName\r\n");
#undef APPEND
  snprintf(out, out_cap, "%s", s->str);
  g_string_free(s, TRUE);
}

static void bounded_error(char* out, size_t cap, const char* src) {
  if (!src || !*src) {
    snprintf(out, cap, "(no detail)");
    return;
  }
  size_t n = 0;
  while (src[n] && src[n] != '\r' && src[n] != '\n' && n < cap - 1) n++;
  memcpy(out, src, n);
  out[n] = '\0';
}

// Run the full OPTIONS → DESCRIBE → SETUP → STUN punch → ANNOUNCE (→ PLAY)
// handshake over an open WSS connection. Fills out on success. Returns 0 on
// success. Mirrors OpenNOW negotiateNvstRtspSession (legacy non-cloud path).
static int run_rtsp_handshake(WsConn* c, const char* rtsps_endpoint,
                              const char* host_header,
                              const char* rtsp_host_header,
                              const char* session_id,
                              int width, int height, int fps, const char* codec,
                              NvstProbeResult* out, nvst_log_cb log_cb,
                              void* userdata) {
  char resp[16384];
  char sess[128] = {0};
  int client_generated = 0;
  int client_port = 0;
  char err[256] = {0};
  char ping_version_s[16] = {0};
  char disable_play[16] = {0};
  char video_control[256] = {0};
  char server_ufrag[64] = {0};
  char server_pwd[128] = {0};
  char local_ufrag[8] = {0};
  char local_pwd[32] = {0};

  const int have_session_id = session_id && session_id[0];

  if (rtsp_request(c, "OPTIONS", rtsps_endpoint, host_header,
                   have_session_id ? session_id : NULL, NULL, NULL, NULL, resp,
                   sizeof(resp), err, sizeof(err)) != 0 ||
      strncmp(resp, "RTSP/1.0 200", 12) != 0) {
    snprintf(out->error, sizeof(out->error), "OPTIONS failed: ");
    bounded_error(out->error + strlen(out->error),
                  sizeof(out->error) - strlen(out->error),
                  err[0] ? err : resp);
    return -1;
  }

  if (rtsp_request(c, "DESCRIBE", rtsps_endpoint, host_header,
                   have_session_id ? session_id : NULL, NULL,
                   "Accept: application/sdp\r\nx-nv-abtesting: 2", NULL, resp,
                   sizeof(resp), err, sizeof(err)) != 0 ||
      strncmp(resp, "RTSP/1.0 200", 12) != 0) {
    snprintf(out->error, sizeof(out->error), "DESCRIBE failed: ");
    bounded_error(out->error + strlen(out->error),
                  sizeof(out->error) - strlen(out->error),
                  err[0] ? err : resp);
    return -1;
  }
  char* hdr_end = strstr(resp, "\r\n\r\n");
  const char* body = hdr_end ? hdr_end + 4 : "";
  char* sess_p = strstr(resp, "Session:");
  if (sess_p) {
    sess_p += strlen("Session:");
    while (*sess_p == ' ') sess_p++;
    int i = 0;
    while (*sess_p && *sess_p != ';' && *sess_p != '\r' && *sess_p != '\n' &&
           i < (int)sizeof(sess) - 1)
      sess[i++] = *sess_p++;
    sess[i] = '\0';
  }
  if (!sess[0]) {
    snprintf(out->error, sizeof(out->error),
             "DESCRIBE response missing Session header");
    return -1;
  }
  sdp_attr(body, "general.pingVersion", ping_version_s,
           sizeof(ping_version_s));
  sdp_attr(body, "general.disablePlay", disable_play, sizeof(disable_play));
  int ping_version =
      ping_version_s[0] ? atoi(ping_version_s) : 6;
  int disable_play_flag = disable_play[0] ? atoi(disable_play) : 0;
  if (extract_media_control(body, "video", video_control,
                            sizeof(video_control)) != 0) {
    // Legacy servers don't advertise controls — fall back to the canonical
    // video stream id.
    snprintf(video_control, sizeof(video_control), "streamid=video/0/0");
  }
  extract_ice_credentials(body, server_ufrag, sizeof(server_ufrag), server_pwd,
                          sizeof(server_pwd));

  char key_hex[65] = {0};
  unsigned int key_id = 0;
  if (extract_runtime_encryption_key(body, key_hex, sizeof(key_hex), &key_id) !=
      0) {
    // Official Bifrost ALWAYS client-generates runtime.encryptionKey and
    // sends it in ANNOUNCE — without it the server never keys video for us.
    uint8_t rnd[32];
    RAND_bytes(rnd, sizeof(rnd));
    static const char hexd[] = "0123456789ABCDEF";
    for (int i = 0; i < 32; i++) {
      key_hex[i * 2] = hexd[rnd[i] >> 4];
      key_hex[i * 2 + 1] = hexd[rnd[i] & 0x0f];
    }
    key_hex[64] = '\0';
    RAND_bytes(rnd, 4);
    key_id = ((uint32_t)rnd[0] << 24) | ((uint32_t)rnd[1] << 16) |
             ((uint32_t)rnd[2] << 8) | rnd[3];
    client_generated = 1;
  }

  // Bind the client UDP port once and keep it for the whole handshake —
  // SETUP advertises it and the STUN punch runs through ANNOUNCE.
  int udp_fd = socket(AF_INET, SOCK_DGRAM, 0);
  struct sockaddr_in bind_addr;
  memset(&bind_addr, 0, sizeof(bind_addr));
  bind_addr.sin_family = AF_INET;
  bind_addr.sin_addr.s_addr = htonl(INADDR_ANY);
  bind_addr.sin_port = 0;
  if (udp_fd < 0 || bind(udp_fd, (struct sockaddr*)&bind_addr, sizeof(bind_addr)) < 0) {
    snprintf(out->error, sizeof(out->error), "UDP bind failed");
    if (udp_fd >= 0) close(udp_fd);
    return -1;
  }
  struct sockaddr_in got;
  socklen_t glen = sizeof(got);
  getsockname(udp_fd, (struct sockaddr*)&got, &glen);
  client_port = ntohs(got.sin_port);

  // Resolve the video control URI and normalize to the official SETUP form
  // (streamid=video/N → streamid=video/N/0).
  char setup_uri[512];
  if (strncmp(video_control, "rtsps://", 8) == 0 ||
      strncmp(video_control, "rtsp://", 7) == 0) {
    snprintf(setup_uri, sizeof(setup_uri), "%s", video_control);
  } else if (video_control[0] == '/') {
    snprintf(setup_uri, sizeof(setup_uri), "rtsps://%s%s", rtsp_host_header,
             video_control);
  } else {
    snprintf(setup_uri, sizeof(setup_uri), "%s/%s", rtsps_endpoint,
             video_control);
  }
  size_t uri_len = strlen(setup_uri);
  if (uri_len > 0 && setup_uri[uri_len - 1] != '/' &&
      strstr(setup_uri, "streamid=") != NULL) {
    const char* sid = strstr(setup_uri, "streamid=video/");
    if (sid && strchr(sid + 15, '/') == NULL) {
      snprintf(setup_uri + uri_len, sizeof(setup_uri) - uri_len, "/0");
    }
  }

  char extra[512];
  char ping_echo[32] = "6";
  if (ping_version_s[0]) {
    snprintf(ping_echo, sizeof(ping_echo), "%d", ping_version);
  }
  snprintf(extra, sizeof(extra),
           "Transport: unicast;X-GS-ClientPort=%d-%d\r\nx-nv-ping: %s",
           client_port, client_port + 1, ping_echo);
  if (rtsp_request(c, "SETUP", setup_uri, host_header,
                   have_session_id ? session_id : NULL, sess, extra, NULL, resp,
                   sizeof(resp), err, sizeof(err)) != 0 ||
      strncmp(resp, "RTSP/1.0 200", 12) != 0) {
    snprintf(out->error, sizeof(out->error), "SETUP failed: ");
    bounded_error(out->error + strlen(out->error),
                  sizeof(out->error) - strlen(out->error),
                  err[0] ? err : resp);
    close(udp_fd);
    return -1;
  }
  sess_p = strstr(resp, "Session:");
  if (sess_p) {
    sess_p += strlen("Session:");
    while (*sess_p == ' ') sess_p++;
    char updated[128] = {0};
    int i = 0;
    while (*sess_p && *sess_p != ';' && *sess_p != '\r' && *sess_p != '\n' &&
           i < (int)sizeof(updated) - 1)
      updated[i++] = *sess_p++;
    if (updated[0]) snprintf(sess, sizeof(sess), "%s", updated);
  }
  char peer_ip[64] = {0};
  unsigned int peer_port = 0;
  const char* tp = find_header_ci(resp, "X-GS-ServerPort=");
  if (tp) peer_port = (unsigned int)atoi(tp + strlen("X-GS-ServerPort="));
  tp = find_header_ci(resp, "source=");
  if (tp) {
    tp += strlen("source=");
    int i = 0;
    while (*tp && *tp != ';' && *tp != ',' && *tp != ' ' && *tp != '\r' &&
           *tp != '\n' && i < (int)sizeof(peer_ip) - 1)
      peer_ip[i++] = *tp++;
    peer_ip[i] = '\0';
  }
  char ping[64] = {0};
  tp = find_header_ci(resp, "x-nv-ping-payload:");
  if (tp) {
    tp = strchr(tp, ':') + 1;
    while (*tp == ' ') tp++;
    int i = 0;
    while (*tp && *tp != '\r' && *tp != '\n' && i < (int)sizeof(ping) - 1)
      ping[i++] = *tp++;
    ping[i] = '\0';
  }
  tp = find_header_ci(resp, "x-nv-ping:");
  if (tp && strchr(tp, ':') != NULL) {
    int v = atoi(strchr(tp, ':') + 1);
    if (v > 0) ping_version = v;
  }

  if (!peer_ip[0] || peer_port == 0) {
    snprintf(out->error, sizeof(out->error),
             "SETUP did not return video peer (X-GS-ServerPort/source)");
    close(udp_fd);
    return -1;
  }

  // Authenticated hole punch (ping version 6 + ICE credentials available).
  // Official first burst is three ICE Binding Requests, then the NATT
  // "PING"-username binding; keep it running through ANNOUNCE.
  int punching = 0;
  if (ping_version == 6 && server_ufrag[0] && server_pwd[0]) {
    generate_ice_credentials(local_ufrag, sizeof(local_ufrag), local_pwd,
                             sizeof(local_pwd));
    // Remote ufrag: hex SETUP ping → ping+1; literal PING → itself
    // (OpenNOW resolveNvstIceRemoteUfrag).
    char remote_ufrag[64] = {0};
    if (ping[0]) {
      int hexy = 1;
      for (const char* q = ping; *q; q++) {
        if (!((*q >= '0' && *q <= '9') || (*q >= 'a' && *q <= 'f') ||
              (*q >= 'A' && *q <= 'F'))) {
          hexy = 0;
          break;
        }
      }
      if (hexy && g_ascii_strcasecmp(ping, "PING") != 0) {
        unsigned long long v = strtoull(ping, NULL, 16);
        snprintf(remote_ufrag, sizeof(remote_ufrag), "%llx", v + 1);
      } else {
        snprintf(remote_ufrag, sizeof(remote_ufrag), "%s", ping);
      }
    } else {
      snprintf(remote_ufrag, sizeof(remote_ufrag), "%s", server_ufrag);
    }
    for (int burst = 0; burst < 5; burst++) {
      hole_punch_volley(udp_fd, peer_ip, (unsigned short)peer_port, local_ufrag,
                        remote_ufrag, server_pwd);
      hole_punch_drain(udp_fd, local_pwd);
      struct timespec ts = {0, 20 * 1000 * 1000};
      nanosleep(&ts, NULL);
    }
    punching = 1;
    snprintf(out->remote_ice_ufrag, sizeof(out->remote_ice_ufrag), "%s",
             remote_ufrag);
    snprintf(out->remote_ice_pwd, sizeof(out->remote_ice_pwd), "%s",
             server_pwd);
    snprintf(out->local_ice_ufrag, sizeof(out->local_ice_ufrag), "%s",
             local_ufrag);
    snprintf(out->local_ice_pwd, sizeof(out->local_ice_pwd), "%s", local_pwd);
  }
  out->ping_version = (unsigned int)ping_version;

  char announce[12288];
  build_announce_sdp(width, height, fps, codec, key_hex, key_id,
                     punching ? local_ufrag : "", punching ? local_pwd : "",
                     NULL, (unsigned short)client_port,
                     (unsigned short)peer_port, announce, sizeof(announce));
  // Legacy path announces against "/" (OpenNOW: officialCloudPath ? target :
  // "/").
  if (rtsp_request(c, "ANNOUNCE", "/", host_header,
                   have_session_id ? session_id : NULL, sess,
                   "Content-Type: application/sdp", announce, resp,
                   sizeof(resp), err, sizeof(err)) != 0 ||
      strncmp(resp, "RTSP/1.0 200", 12) != 0) {
    snprintf(out->error, sizeof(out->error), "ANNOUNCE failed: ");
    bounded_error(out->error + strlen(out->error),
                  sizeof(out->error) - strlen(out->error),
                  err[0] ? err : resp);
    close(udp_fd);
    return -1;
  }

  // GFN disables PLAY; only send it when the server didn't opt out.
  if (!disable_play_flag) {
    if (rtsp_request(c, "PLAY", rtsps_endpoint, host_header,
                     have_session_id ? session_id : NULL, sess,
                     "Range: npt=0.000-", NULL, resp, sizeof(resp), err,
                     sizeof(err)) != 0 ||
        strncmp(resp, "RTSP/1.0 200", 12) != 0) {
      snprintf(out->error, sizeof(out->error), "PLAY failed: ");
      bounded_error(out->error + strlen(out->error),
                    sizeof(out->error) - strlen(out->error),
                    err[0] ? err : resp);
      close(udp_fd);
      return -1;
    }
  }

  close(udp_fd);

  out->ok = 1;
  out->error[0] = '\0';  // an earlier cascade attempt's error is obsolete
  snprintf(out->session, sizeof(out->session), "%s", sess);
  snprintf(out->video_peer_ip, sizeof(out->video_peer_ip), "%s", peer_ip);
  out->video_peer_port = (unsigned short)peer_port;
  out->client_udp_port = (unsigned short)client_port;
  snprintf(out->srtp_aes_key_hex, sizeof(out->srtp_aes_key_hex), "%s", key_hex);
  out->srtp_key_id = key_id;
  snprintf(out->ping_payload, sizeof(out->ping_payload), "%s", ping);
  snprintf(out->codec, sizeof(out->codec), "%s",
           codec && codec[0] ? codec : "H264");
  if (log_cb) {
    char* m = g_strdup_printf(
        "nvst: handshake OK (session %s, clientPort %d, peer %s:%u, ping v%u, "
        "ice %s, key%s)",
        sess[0] ? sess : "-", client_port, peer_ip, peer_port, ping_version,
        punching ? "authenticated" : "legacy", client_generated ? " (client-generated)" : "");
    log_cb(userdata, m);

  }
  return 0;
}

// Debug: fire a matrix of request shapes at the gateway and log each status
// line — used only when every probe attempt failed, so a single run maps what
// the live-session gateway accepts.
static void probe_debug_matrix(const char* host, int port,
                               const char* session_id, nvst_log_cb log_cb,
                               void* userdata) {
  char ep[288];
  snprintf(ep, sizeof(ep), "rtsps://%s:%d", host, port);
  char host_hdr[288];
  snprintf(host_hdr, sizeof(host_hdr), "Host: %s:%d\r\n", host, port);
  char sid_hdr[512];
  snprintf(sid_hdr, sizeof(sid_hdr), "x-nv-sessionid: %s\r\n",
           session_id ? session_id : "");
  char v2_target[320];
  snprintf(v2_target, sizeof(v2_target), "/v2/session/%s",
           session_id ? session_id : "");
  const char* origin_ua =
      "Origin: https://play.geforcenow.com\r\n"
      "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 "
      "Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.87.131\r\n";

  enum { kWs, kHttpGet, kRawOptions };
  struct {
    const char* name;
    const char* target;
    const char* extra;
    int kind;
  } cases[] = {
      {"ws /rtsp origin+ua+sid", "/rtsp", origin_ua, kWs},
      {"ws /rtsp subproto=rtsp", "/rtsp",
       "Sec-WebSocket-Protocol: rtsp\r\n", kWs},
      {"ws /rtsp origin+ua (no sid)", "/rtsp", origin_ua, kWs},
      {"ws /session + sid", "/session", sid_hdr, kWs},
      {"ws /v2/session/<id> + sid", v2_target, sid_hdr, kWs},
      {"ws / keepalive+upgrade", "/", NULL, kWs},
      {"http get /rtsp + sid", "/rtsp", sid_hdr, kHttpGet},
      {"raw options x-gs-clientversion", NULL, NULL, kRawOptions},
  };
  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
    uint8_t rnd[16];
    RAND_bytes(rnd, sizeof(rnd));
    char key[25];
    b64_encode(rnd, 16, key);
    char req[2048];
    const char* target = cases[i].target ? cases[i].target : ep;
    if (cases[i].kind == kWs) {
      snprintf(req, sizeof(req),
               "GET %s HTTP/1.1\r\n"
               "%s"
               "Connection: Upgrade\r\n"
               "Upgrade: websocket\r\n"
               "Sec-WebSocket-Version: 13\r\n"
               "%s"
               "Sec-WebSocket-Key: %s\r\n"
               "Content-Length: 0\r\n"
               "\r\n",
               target, host_hdr, cases[i].extra ? cases[i].extra : "", key);
    } else if (cases[i].kind == kHttpGet) {
      snprintf(req, sizeof(req),
               "GET %s HTTP/1.1\r\n%s%sConnection: close\r\n\r\n", target,
               host_hdr, cases[i].extra ? cases[i].extra : "");
    } else {
      snprintf(req, sizeof(req),
               "OPTIONS %s RTSP/1.0\r\nCSeq: 1\r\nRequest-Id: 1\r\n"
               "X-GS-ClientVersion: 14\r\n%s\r\n",
               ep, host_hdr);
    }

    SSL* ssl = NULL;
    int fd = -1;
    char err[128] = {0};
    if (tls_connect(host, port, &ssl, &fd, err, sizeof(err)) != 0) {
      char* m0 = g_strdup_printf("nvst: matrix %s -> tls fail: %s",
                                 cases[i].name, err);
      log_cb(userdata, m0);
      continue;
    }
    SSL_write(ssl, req, (int)strlen(req));
    char resp[512] = {0};
    size_t total = 0;
    while (total < sizeof(resp) - 1) {
      char ch;
      if (ssl_read_full(ssl, &ch, 1) != 0) break;
      resp[total++] = ch;
      if (total >= 4 && memcmp(resp + total - 4, "\r\n\r\n", 4) == 0) break;
    }
    SSL_shutdown(ssl);
    SSL_free(ssl);
    close(fd);
    char first[96] = {0};
    for (size_t j = 0; j < total && j < sizeof(first) - 1; j++) {
      if (resp[j] == '\r' || resp[j] == '\n') break;
      first[j] = resp[j];
    }
    char* m = g_strdup_printf("nvst: matrix %s -> %s", cases[i].name,
                              first[0] ? first : "(no response)");
    log_cb(userdata, m);
  }
}

int nvst_probe(const char* rtsps_endpoint, const char* fallback_ws_url,
               const char* auth_token, const char* session_id, int width,
               int height, int fps, const char* codec, NvstProbeResult* out,
               nvst_log_cb log_cb, void* userdata) {
  memset(out, 0, sizeof(*out));
  snprintf(out->codec, sizeof(out->codec), "%s",
           codec && codec[0] ? codec : "H264");
  if (!rtsps_endpoint || !rtsps_endpoint[0]) {
    snprintf(out->error, sizeof(out->error), "No rtsps:// endpoints available");
    return -1;
  }

  // Parse rtsps://host:port
  const char* p = rtsps_endpoint;
  if (strncmp(p, "rtsps://", 8) == 0) p += 8;
  else if (strncmp(p, "rtsp://", 7) == 0) p += 7;
  char host[256] = {0};
  int port = 322;
  const char* slash = strchr(p, '/');
  const char* colon = strchr(p, ':');
  if (colon && (!slash || colon < slash)) {
    size_t hlen = (size_t)(colon - p);
    if (hlen >= sizeof(host)) hlen = sizeof(host) - 1;
    memcpy(host, p, hlen);
    port = atoi(colon + 1);
    if (port <= 0) port = 322;
  } else {
    size_t hlen = slash ? (size_t)(slash - p) : strlen(p);
    if (hlen >= sizeof(host)) hlen = sizeof(host) - 1;
    memcpy(host, p, hlen);
  }
  if (!host[0]) {
    snprintf(out->error, sizeof(out->error), "Bad rtsps endpoint: %s",
             rtsps_endpoint);
    return -1;
  }

  char err[256] = {0};
  char path_form[256] = "/";
  if (session_id && session_id[0]) {
    snprintf(path_form, sizeof(path_form), "/v2/session/%s", session_id);
  }
  // Host header form (host:port) used by every RTSP request.
  char host_header[288];
  if (port == 322) {
    snprintf(host_header, sizeof(host_header), "%s", host);
  } else {
    snprintf(host_header, sizeof(host_header), "%s:%d", host, port);
  }
  if (log_cb) {
    char* m = g_strdup_printf("nvst: probe endpoint %s (connect %s:%d)",
                              rtsps_endpoint, host, port);
    log_cb(userdata, m);

  }

  // Attempt shapes. Field evidence (live :48322 per-session gateways):
  //  - raw RTSPS (RTSP/1.0 directly over TLS) is the natural transport for a
  //    per-session ephemeral port — with the full header set (Host +
  //    x-nv-sessionid + X-GS-Version) that earlier runs lacked;
  //  - WebSocket upgrades answer 501 (with headers) / 404 (bare) there;
  //  - the official :322 Bifrost front takes the WSS `GET /rtsp` + header form
  //    (OpenNOW clientHeaders.ts). Raw first, then every WSS shape.
  WsConn* c = NULL;
  struct {
    int raw;
    const char* target;
    int with_sess;
    int subproto;
  } attempts[] = {
      {1, NULL, 0, 0},   {0, "/rtsp", 1, 0},  {0, "/rtsp", 1, 1},
      {0, "/", 1, 1},    {0, path_form, 0, 1}, {0, "/rtsp", 0, 0},
      {0, path_form, 0, 0},
  };
  const int attempt_count = (int)(sizeof(attempts) / sizeof(attempts[0]));
  for (int attempt = 0; attempt < attempt_count && !c; attempt++) {
    if (attempts[attempt].raw) {
      SSL* ssl = NULL;
      int fd = -1;
      if (tls_connect(host, port, &ssl, &fd, err, sizeof(err)) == 0) {
        c = (WsConn*)malloc(sizeof(WsConn));
        if (c) {
          c->ssl = ssl;
          c->fd = fd;
          c->raw = 1;
        } else {
          SSL_free(ssl);
          close(fd);
        }
      }
      if (log_cb) {
        char* m = g_strdup_printf("nvst: raw RTSPS %s:%d %s", host, port,
                                  c ? "connected" : (err[0] ? err : "failed"));
        log_cb(userdata, m);  // callback owns + frees the message
      }
    } else {
      const char* tform = attempts[attempt].target;
      c = wss_connect(host, port, session_id, tform,
                      attempts[attempt].with_sess, attempts[attempt].subproto,
                      NULL, 0, err, sizeof(err));
      if (log_cb) {
        char* m = g_strdup_printf("nvst: WSS %s (sess=%d sub=%d) %s", tform,
                                  attempts[attempt].with_sess,
                                  attempts[attempt].subproto,
                                  c ? "connected" : (err[0] ? err : "failed"));
        log_cb(userdata, m);  // callback owns + frees the message
      }
    }
    if (!c) continue;
    if (run_rtsp_handshake(c, rtsps_endpoint, host_header, host_header,
                           session_id, width, height, fps, codec, out, log_cb,
                           userdata) != 0) {
      ws_close(c);
      c = NULL;
      continue;
    }
  }

  // Last battery: the signaling WebSocket shape — wss://host:443/nvst/ with
  // `Sec-WebSocket-Protocol: x-nv-sessionid.<id>` — is the only connection
  // the live gateways demonstrably accept (buildSignalingUrl maps rtsps://
  // endpoints to exactly this URL, and rtspWebSocketPerConnection:1 in the
  // ANNOUNCE covers the same flow). Try the session's signaling URL first,
  // then /nvst/ and /rtsp on the rtsps host at :443, each with the RTSP
  // handshake layered over the established socket.
  // NOTE: the full battery + diagnostic matrix cost ~50 s per probe against
  // dead ends — they only run with NVST_EXPERIMENTAL=1 in the environment.
  if (!c && getenv("NVST_EXPERIMENTAL")) {
    char fb_host[256] = {0};
    int fb_port = 443;
    char fb_path[256] = "/nvst/";
    int have_fb = 0;
    if (fallback_ws_url && (strncmp(fallback_ws_url, "wss://", 6) == 0 ||
                            strncmp(fallback_ws_url, "ws://", 5) == 0)) {
      const char* q = fallback_ws_url + (fallback_ws_url[0] == 'w' &&
                                                 fallback_ws_url[1] == 's'
                                             ? 6
                                             : 5);
      const char* slash = strchr(q, '/');
      const char* colon = strchr(q, ':');
      size_t hlen = colon ? (size_t)(colon - q)
                          : (slash ? (size_t)(slash - q) : strlen(q));
      if (hlen >= sizeof(fb_host)) hlen = sizeof(fb_host) - 1;
      memcpy(fb_host, q, hlen);
      if (colon && (!slash || colon < slash)) {
        fb_port = atoi(colon + 1);
        if (fb_port <= 0) fb_port = 443;
      }
      if (slash) snprintf(fb_path, sizeof(fb_path), "%s", slash);
      have_fb = fb_host[0] != '\0';
    }
    char origin_ua_hdr[320] =
        "Origin: https://play.geforcenow.com\r\n"
        "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 "
        "Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.87.131\r\n";
    char jwt_hdr[1200] = {0};
    char jwt_origin_hdr[1400] = {0};
    if (auth_token && auth_token[0]) {
      snprintf(jwt_hdr, sizeof(jwt_hdr), "Authorization: GFNJWT %s\r\n",
               auth_token);
      snprintf(jwt_origin_hdr, sizeof(jwt_origin_hdr),
               "Authorization: GFNJWT %s\r\n" "Origin: "
               "https://play.geforcenow.com\r\n",
               auth_token);
    }
    struct {
      const char* host;
      int port;
      const char* path;
      int with_sess;
      int subproto;
      const char* extra;
      int omit_cl;
      const char* label;
    } fb_attempts[] = {
        // Exact mirror of the WORKING Dart signaling client upgrade:
        // subprotocol, no sid header, no Content-Length.
        {fb_host, fb_port, fb_path, 0, 1, NULL, 1, "signaling url dart-mirror"},
        {fb_host, fb_port, fb_path, 1, 1, NULL, 0, "signaling url + subproto"},
        {fb_host, fb_port, fb_path, 1, 0, NULL, 0, "signaling url"},
        {host, 443, "/nvst/", 0, 1, NULL, 1, "443/nvst/ dart-mirror"},
        {host, 443, "/nvst/", 1, 1, NULL, 0, "443/nvst/ + subproto"},
        {host, 443, "/nvst/", 1, 0, NULL, 0, "443/nvst/"},
        // :443/rtsp returned 403 (route exists, auth failed) on a live
        // session — exhaust the auth shapes: Origin/UA, query-string sid,
        // JWT, and the OpenNOW bare→403→sid retry semantics.
        {host, 443, "/rtsp", 1, 1, origin_ua_hdr, 0, "443/rtsp origin+ua"},
        {host, 443, "/rtsp?sessionId=", 1, 1, origin_ua_hdr, 0,
         "443/rtsp?sessionId origin+ua"},
        {host, 443, "/rtsp", 0, 1, origin_ua_hdr, 0,
         "443/rtsp origin+ua no-sid"},
        {host, 443, "/rtsp", 1, 1, jwt_hdr, 0, "443/rtsp jwt"},
        {host, 443, "/rtsp", 1, 1, jwt_origin_hdr, 0, "443/rtsp jwt+origin"},
        {host, 48322, "/rtsp", 1, 1, origin_ua_hdr, 0, "48322/rtsp origin+ua"},
        {host, 48322, "/rtsp?sessionId=", 1, 1, origin_ua_hdr, 0,
         "48322/rtsp?sessionId origin+ua"},
        {host, 443, "/session", 1, 1, origin_ua_hdr, 0, "443/session origin+ua"},
        {host, 48322, "/nvst/", 1, 1, NULL, 0,
         "rtsps-host:48322/nvst/ + subproto"},
    };
    const int fb_count = (int)(sizeof(fb_attempts) / sizeof(fb_attempts[0]));
    for (int i = 0; i < fb_count && !c; i++) {
      if (i < 3 && !have_fb) continue;  // no signaling URL provided
      if (!fb_attempts[i].host[0]) continue;
      char target[512];
      if (strstr(fb_attempts[i].path, "?sessionId=")) {
        snprintf(target, sizeof(target), "%s%s", fb_attempts[i].path,
                 session_id ? session_id : "");
      } else {
        snprintf(target, sizeof(target), "%s", fb_attempts[i].path);
      }
      c = wss_connect(fb_attempts[i].host, fb_attempts[i].port, session_id,
                      target, fb_attempts[i].with_sess, fb_attempts[i].subproto,
                      fb_attempts[i].extra, fb_attempts[i].omit_cl, err,
                      sizeof(err));
      if (log_cb) {
        char* m = g_strdup_printf("nvst: WSS %s:%d%s (sess=%d sub=%d) %s",
                                  fb_attempts[i].host, fb_attempts[i].port,
                                  target, fb_attempts[i].with_sess,
                                  fb_attempts[i].subproto,
                                  c ? "connected" : (err[0] ? err : "failed"));
        log_cb(userdata, m);  // callback owns + frees the message
      }
      if (!c) continue;
      // HTTP Host: dialed host (omit default ports); RTSP URI base stays on
      // the rtsps endpoint namespace.
      char dial_host_header[288];
      if (fb_attempts[i].port == 443 || fb_attempts[i].port == 322) {
        snprintf(dial_host_header, sizeof(dial_host_header), "%s",
                 fb_attempts[i].host);
      } else {
        snprintf(dial_host_header, sizeof(dial_host_header), "%s:%d",
                 fb_attempts[i].host, fb_attempts[i].port);
      }
      if (run_rtsp_handshake(c, rtsps_endpoint, dial_host_header, host_header,
                             session_id, width, height, fps, codec, out,
                             log_cb, userdata) != 0) {
        ws_close(c);
        c = NULL;
        continue;
      }
    }
  }
  if (!c) {
    // Every transport shape failed — dump the diagnostic matrix only under
    // NVST_EXPERIMENTAL (it costs 8 extra TLS connections).
    if (log_cb && getenv("NVST_EXPERIMENTAL")) {
      probe_debug_matrix(host, port, session_id, log_cb, userdata);
    }
    if (!out->error[0]) {
      snprintf(out->error, sizeof(out->error), "RTSP probe failed: %s",
               err[0] ? err : "all transports rejected");
    }
    return -1;
  }
  ws_close(c);
  return 0;
}

// ---------------------------------------------------------------------------
// Self-test (NVST_SELF_TEST)
// ---------------------------------------------------------------------------
#ifdef NVST_SELF_TEST
#include <assert.h>
#include <stdio.h>

int main(void) {
  unsigned char key[32];
  assert(nvst_parse_aes_key_hex(
             "ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB",
             key) == 0);
  for (int i = 0; i < 32; i++) assert(key[i] == 0xAB);

  unsigned char master[44];
  nvst_pack_master_key_salt(key, 2664076126u, master);
  for (int i = 0; i < 32; i++) assert(master[i] == 0xAB);
  assert(master[32] == 0 && master[39] == 0);
  assert(master[40] == 0x9E && master[41] == 0xCA && master[42] == 0x93 &&
         master[43] == 0x5E);

  uint8_t pkt[16] = {0x44, 0x33, 0x22, 0x11, 7, 0, 0, 0,
                     FLAG_SOF | FLAG_EOF | FLAG_CONTAINS_PIC_DATA, 0x10, 0x20,
                     0x30, 0xDD, 0xCC, 0xBB, 0xAA};
  NvVideoPacket h;
  assert(nv_video_packet_parse(pkt, 16, &h) == 0);
  assert(h.stream_packet_index == 0x11223344);
  assert(h.frame_index == 7);
  assert(h.flags & FLAG_EOF);
  assert(h.extra_flags == 0x10);
  assert(h.fec_info == 0xAABBCCDD);

  uint8_t rtp[12 + 16 + 4];
  memset(rtp, 0, sizeof(rtp));
  rtp[0] = 0x80;
  rtp[1] = 96;
  memcpy(rtp + 12, pkt, 16);
  rtp[28] = 0xDE;
  rtp[29] = 0xAD;
  size_t plen = 0;
  const uint8_t* payload = nvst_strip_rtp_header(rtp, sizeof(rtp), &plen);
  assert(payload != NULL);
  assert(plen == 20);
  assert(payload[0] == 0x44);

  NvstFrameAssembler asm_;
  nvst_assembler_init(&asm_);
  NvVideoPacket sof = {1, 3, FLAG_SOF | FLAG_CONTAINS_PIC_DATA, 0, 0, 0, 0};
  NvVideoPacket eof = {2, 3, FLAG_EOF | FLAG_CONTAINS_PIC_DATA, 0, 0, 0, 0};
  GByteArray* au = NULL;
  assert(!nvst_assembler_push(&asm_, &sof, (const uint8_t*)"AA", 2, &au));
  assert(nvst_assembler_push(&asm_, &eof, (const uint8_t*)"BB", 2, &au));
  assert(au != NULL && au->len == 4);
  assert(memcmp(au->data, "AABB", 4) == 0);
  g_byte_array_free(au, TRUE);
  nvst_assembler_clear(&asm_);

  nvst_assembler_init(&asm_);
  NvVideoPacket fec = {3, 3, 0, 0, 0, 0, 0};
  assert(!nvst_assembler_push(&asm_, &fec, (const uint8_t*)"X", 1, &au));
  nvst_assembler_clear(&asm_);

  // STUN Binding Request structure: type 0x0001, magic cookie, length field
  // covering USERNAME(7 chars "PING:ab" → body 12) + MI(24) + FP(8) = 44.
  uint8_t stun[128];
  size_t slen = build_stun_binding_request("ab", "PING", "password", stun,
                                           sizeof(stun));
  assert(slen == 20 + 12 + 24 + 8);
  assert(stun[0] == 0x00 && stun[1] == 0x01);
  assert(stun[4] == 0x21 && stun[5] == 0x12 && stun[6] == 0xA4 &&
         stun[7] == 0x42);
  assert(stun[2] == 0x00 && stun[3] == (12 + 24 + 8));
  // USERNAME attribute (0x0006, len 7) right after the 20-byte header.
  assert(stun[20] == 0x00 && stun[21] == 0x06 && stun[22] == 0x00 &&
         stun[23] == 0x07);
  assert(memcmp(stun + 24, "PING:ab", 7) == 0);

  // Binding Success for a loopback request: verify the FINGERPRINT covers the
  // whole message (CRC32 over msg minus the 8-byte FP attr, XOR 0x5354554e).
  // Layout: 20 header + 12 XOR-MAPPED-ADDRESS + 24 MESSAGE-INTEGRITY + 8 FP.
  uint8_t txid[12] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
  uint8_t ok_pkt[64];
  size_t olen = build_stun_binding_success("localpwd", txid, "127.0.0.1", 5004,
                                           ok_pkt, sizeof(ok_pkt));
  assert(olen == 64);
  assert(ok_pkt[0] == 0x01 && ok_pkt[1] == 0x01);
  assert(memcmp(ok_pkt + 8, txid, 12) == 0);
  assert(ok_pkt[56] == 0x80 && ok_pkt[57] == 0x28 && ok_pkt[58] == 0x00 &&
         ok_pkt[59] == 0x04);
  uint32_t fp_wire = ((uint32_t)ok_pkt[60] << 24) | ((uint32_t)ok_pkt[61] << 16) |
                     ((uint32_t)ok_pkt[62] << 8) | ok_pkt[63];
  // Recompute: crc32 over the first 56 bytes, XOR 0x5354554e.
  uint32_t recomputed = crc32_ieee(ok_pkt, 56) ^ 0x5354554eu;
  assert(fp_wire == recomputed);

  printf("ALL NVST SELF TESTS PASSED\n");
  return 0;
}
#endif  // NVST_SELF_TEST
