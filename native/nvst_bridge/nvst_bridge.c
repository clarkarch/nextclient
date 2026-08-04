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
// Probe transport selection (OpenNOW parity + hardening): the `:322` RTSPS
// endpoint is NVIDIA-proprietary and sensitive — the exact upgrade form is
// under research upstream. We try, in order:
//   1. raw RTSPS  (RTSP/1.0 directly over TLS, no WebSocket)
//   2. WSS GET /  (Bifrost-shaped WebSocket upgrade, Poco header order)
//   3. WSS GET /v2/session/<id>  (CloudMatch-style upgrade path)
// Each WSS form also retries with an `x-nv-sessionid` header on HTTP 403.
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

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LOG_LINE_MAX 512
#define NV_VIDEO_PACKET_LEN 16
#define FLAG_EOF 0x02
#define FLAG_SOF 0x04
#define FLAG_CONTAINS_PIC_DATA 0x01

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

  while (!t->stop) {
    struct sockaddr_in from;
    socklen_t fromlen = sizeof(from);
    ssize_t n = recvfrom(t->socket_fd, buf, sizeof(buf), 0,
                         (struct sockaddr*)&from, &fromlen);
    if (n < 0) {
      if (errno == EINTR) continue;
      if (t->stop) break;
      nvst_log(t->bridge, "nvst: UDP recv error: %s", strerror(errno));
      if (errno == EBADF) break;
      continue;
    }
    if (!first_packet) {
      first_packet = TRUE;
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
  ssize_t sent = sendto(fd, ping, strlen(ping), 0, (struct sockaddr*)&peer,
                        sizeof(peer));
  nvst_log(b, "nvst: hole-punch sent (%zd B) to %s:%u from port %u",
           sent < 0 ? 0 : sent, session->video_peer_ip,
           session->video_peer_port, session->client_udp_port);

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

// WSS upgrade: TLS + Bifrost-shaped GET. Returns connected WsConn (raw=0).
static WsConn* wss_connect(const char* host, int port, const char* session_id,
                           const char* target_form, int with_session_header,
                           char* err, size_t err_cap) {
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
  static const char b64[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  char sec_key[25];
  int kb = 0;
  for (int i = 0; i < 16; i += 3) {
    uint32_t v = (uint32_t)key_bytes[i] << 16;
    if (i + 1 < 16) v |= (uint32_t)key_bytes[i + 1] << 8;
    if (i + 2 < 16) v |= key_bytes[i + 2];
    sec_key[kb++] = b64[(v >> 18) & 0x3f];
    sec_key[kb++] = b64[(v >> 12) & 0x3f];
    if (i + 1 < 16) {
      sec_key[kb++] = b64[(v >> 6) & 0x3f];
      sec_key[kb++] = (i + 2 < 16) ? b64[v & 0x3f] : '=';
    } else {
      sec_key[kb++] = '=';
      sec_key[kb++] = '=';
    }
  }
  sec_key[kb] = '\0';

  char req[1024];
  // OpenNOW's buildNvstWssUpgradeRequest: Poco/Bifrost header order,
  // Content-Length: 0. NVIDIA's WS servers additionally require the
  // `Sec-WebSocket-Protocol: x-nv-sessionid.<id>` subprotocol — the SAME one
  // the working NVST signaling WebSocket uses (signaling_client.dart). Without
  // it the server rejects the upgrade (HTTP 400/501). Origin/User-Agent mirror
  // the working signaling connection too.
  int n = snprintf(
      req, sizeof(req),
      "GET %s HTTP/1.1\r\n"
      "Host: %s:%d\r\n"
      "Connection: Upgrade\r\n"
      "Upgrade: websocket\r\n"
      "Sec-WebSocket-Version: 13\r\n"
      "Sec-WebSocket-Key: %s\r\n"
      "Sec-WebSocket-Protocol: x-nv-sessionid.%s\r\n"
      "Origin: https://play.geforcenow.com\r\n"
      "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 "
      "Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173\r\n"
      "Content-Length: 0\r\n",
      target_form, host, port, sec_key,
      (session_id && session_id[0]) ? session_id : "");
  if (with_session_header && session_id && session_id[0] && n > 0 &&
      n < (int)sizeof(req)) {
    n += snprintf(req + n, sizeof(req) - (size_t)n,
                  "x-nv-sessionid: %s\r\n", session_id);
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
    snprintf(err, err_cap, "WSS upgrade failed: HTTP %d", status);
    ws_close(c);
    return NULL;
  }
  return c;
}

// Send one RTSP request and read one response. Works for raw RTSPS and WSS.
static int rtsp_request(WsConn* c, const char* method, const char* uri,
                        const char* session, const char* extra_headers,
                        const char* body, char* resp, size_t resp_cap,
                        char* err, size_t err_cap) {
  static int cseq = 0;
  cseq++;
  char msg[4096];
  int n = snprintf(msg, sizeof(msg),
                   "%s %s RTSP/1.0\r\nCSeq: %d\r\nRequest-Id: %d\r\n"
                   "X-GS-Version: 14.2\r\n",
                   method, uri, cseq, cseq);
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

static void build_announce_sdp(int width, int height, int fps,
                               const char* key_hex, unsigned int key_id,
                               char* out, size_t out_cap) {
  char buf[8192];
  int n = snprintf(
      buf, sizeof(buf),
      "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=OpenNOW NVST Handshake\r\n"
      "t=0 0\r\n"
      "a=x-nv-video[0].clientViewportWd:%d\r\n"
      "a=x-nv-video[0].clientViewportHt:%d\r\n"
      "a=x-nv-video[0].maxFPS:%d\r\n"
      "a=x-nv-video[0].packetSize:1408\r\n"
      "a=x-nv-video[0].enableRtpNack:1\r\n"
      "a=x-nv-video[0].framePacing.mode:2\r\n"
      "a=x-nv-video[0].framePacing.pid.minTargetFrameTimeUs:%d\r\n"
      "a=x-nv-video[0].adaptiveQuantization.spatialAQSetting:7\r\n"
      "a=x-nv-video[0].adaptiveQuantization.temporalAQSetting:0\r\n"
      "a=x-nv-video[0].adaptiveQuantization.spatialAQStrength:12\r\n"
      "a=x-nv-video[0].adaptiveQuantization.qpThresholdAdjPercent:2\r\n"
      "a=x-nv-vqos[0].fec.enable:1\r\n"
      "a=x-nv-vqos[0].fec.repairPercent:20\r\n"
      "a=x-nv-vqos[0].fec.repairMinPercent:5\r\n"
      "a=x-nv-vqos[0].fec.repairMaxPercent:40\r\n"
      "a=x-nv-vqos[0].bw.maximumBitrateKbps:100000\r\n"
      "a=x-nv-vqos[0].bw.minimumBitrateKbps:1000\r\n"
      "a=x-nv-packetPacing.version:3\r\n"
      "a=x-nv-packetPacing.mode:1\r\n"
      "a=x-nv-packetPacing.numGroups:5\r\n"
      "a=x-nv-packetPacing.maxDelayUs:1000\r\n"
      "a=x-nv-packetPacing.minNumPacketsFrame:10\r\n"
      "a=x-nv-packetPacing.enableAccurateSleep:1\r\n"
      "a=x-nv-packetPacing.enableSmoothTransition:1\r\n"
      "a=x-nv-packetPacing.allowFpsBasedToggle:1\r\n"
      "a=x-nv-ri.partialReliableThresholdMs:300\r\n"
      "a=x-nv-ri.timestampsEnabled:1\r\n"
      "a=x-nv-ri.useMultipleGamepads:1\r\n"
      "a=x-nv-ri.usePartiallyReliableUdpChannel:0\r\n"
      "a=x-nv-ri.enablePartiallyReliableTransferGamepad:255\r\n"
      "a=x-nv-ri.enablePartiallyReliableTransferHid:-1\r\n"
      "a=x-nv-aqos.enableRedundancy:1\r\n"
      "a=x-nv-aqos.redundancyLevel:2\r\n"
      "a=x-nv-general.rtspWebSocketPerConnection:1\r\n"
      "a=x-nv-general.enetControlChannel.mtuSize:1191\r\n"
      "a=x-nv-general.pingIntervalBeforeConnectionMs:20\r\n"
      "a=x-nv-general.pingIntervalAfterConnectionMs:100\r\n"
      "a=x-nv-runtime.audioSrtp:0\r\n"
      "a=x-nv-runtime.micSrtp:0\r\n"
      "a=x-nv-runtime.videoSrtp:1\r\n"
      "a=x-nv-runtime.encryptionKey:%s\r\n"
      "a=x-nv-runtime.encryptionKeyId:%d\r\n"
      "a=x-nv-general.controlProtocol:udp_ag\r\n"
      "\r\n",
      width, height, fps, fps > 0 ? 1000000 / fps : 16666, key_hex,
      (int)key_id);
  if (n > 0 && n < (int)sizeof(buf)) {
    n = snprintf(out, out_cap, "%s", buf);
  }
  if (n < 0) out[0] = '\0';
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

// Run the full OPTIONS→DESCRIBE→SETUP→ANNOUNCE→PLAY handshake over an open
// connection (raw or WSS). Fills out on success. Returns 0 on success.
static int run_rtsp_handshake(WsConn* c, const char* rtsps_endpoint, int width,
                              int height, int fps, NvstProbeResult* out,
                              nvst_log_cb log_cb, void* userdata) {
  char resp[16384];
  char sess[128] = {0};
  int client_generated = 0;
  int client_port = 0;
  char err[256] = {0};

  if (rtsp_request(c, "OPTIONS", rtsps_endpoint, NULL, NULL, NULL, resp,
                   sizeof(resp), err, sizeof(err)) != 0 ||
      strncmp(resp, "RTSP/1.0 200", 12) != 0) {
    snprintf(out->error, sizeof(out->error), "OPTIONS failed: ");
    bounded_error(out->error + strlen(out->error), sizeof(out->error) - strlen(out->error), err[0] ? err : resp);
    return -1;
  }

  if (rtsp_request(c, "DESCRIBE", rtsps_endpoint, NULL,
                   "Accept: application/sdp", NULL, resp, sizeof(resp), err,
                   sizeof(err)) != 0) {
    snprintf(out->error, sizeof(out->error), "DESCRIBE failed: %s", err);
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

  char key_hex[65] = {0};
  unsigned int key_id = 0;
  if (extract_runtime_encryption_key(body, key_hex, sizeof(key_hex), &key_id) !=
      0) {
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
  close(udp_fd);

  char extra[256];
  snprintf(extra, sizeof(extra),
           "Transport: unicast;X-GS-ClientPort=%d-%d", client_port,
           client_port + 1);
  char setup_uri[512];
  snprintf(setup_uri, sizeof(setup_uri), "%s/streamid=video/0/0", rtsps_endpoint);
  if (rtsp_request(c, "SETUP", setup_uri, sess, extra, NULL, resp, sizeof(resp),
                   err, sizeof(err)) != 0 ||
      strncmp(resp, "RTSP/1.0 200", 12) != 0) {
    snprintf(out->error, sizeof(out->error), "SETUP failed: ");
    bounded_error(out->error + strlen(out->error), sizeof(out->error) - strlen(out->error), err[0] ? err : resp);
    return -1;
  }
  char peer_ip[64] = {0};
  unsigned int peer_port = 0;
  char* tp = strstr(resp, "X-GS-ServerPort=");
  if (tp) peer_port = (unsigned int)atoi(tp + strlen("X-GS-ServerPort="));
  tp = strstr(resp, "source=");
  if (tp) {
    tp += strlen("source=");
    int i = 0;
    while (*tp && *tp != ';' && *tp != ',' && *tp != ' ' && *tp != '\r' &&
           *tp != '\n' && i < (int)sizeof(peer_ip) - 1)
      peer_ip[i++] = *tp++;
    peer_ip[i] = '\0';
  }
  char ping[64] = {0};
  tp = strstr(resp, "x-nv-ping-payload:");
  if (!tp) tp = strstr(resp, "X-NV-PING-PAYLOAD:");
  if (tp) {
    tp = strchr(tp, ':') + 1;
    while (*tp == ' ') tp++;
    int i = 0;
    while (*tp && *tp != '\r' && *tp != '\n' && i < (int)sizeof(ping) - 1)
      ping[i++] = *tp++;
    ping[i] = '\0';
  }

  char announce[8192];
  build_announce_sdp(width, height, fps, key_hex, key_id, announce,
                     sizeof(announce));
  if (rtsp_request(c, "ANNOUNCE", rtsps_endpoint, sess,
                   "Content-Type: application/sdp", announce, resp, sizeof(resp),
                   err, sizeof(err)) != 0 ||
      strncmp(resp, "RTSP/1.0 200", 12) != 0) {
    snprintf(out->error, sizeof(out->error), "ANNOUNCE failed: ");
    bounded_error(out->error + strlen(out->error), sizeof(out->error) - strlen(out->error), err[0] ? err : resp);
    return -1;
  }

  if (rtsp_request(c, "PLAY", rtsps_endpoint, sess, "Range: npt=0.000-", NULL,
                   resp, sizeof(resp), err, sizeof(err)) != 0 ||
      strncmp(resp, "RTSP/1.0 200", 12) != 0) {
    snprintf(out->error, sizeof(out->error), "PLAY failed: ");
    bounded_error(out->error + strlen(out->error), sizeof(out->error) - strlen(out->error), err[0] ? err : resp);
    return -1;
  }

  if (!peer_ip[0] || peer_port == 0) {
    snprintf(out->error, sizeof(out->error),
             "SETUP did not return video peer (X-GS-ServerPort/source)");
    return -1;
  }

  out->ok = 1;
  snprintf(out->session, sizeof(out->session), "%s", sess);
  snprintf(out->video_peer_ip, sizeof(out->video_peer_ip), "%s", peer_ip);
  out->video_peer_port = (unsigned short)peer_port;
  out->client_udp_port = (unsigned short)client_port;
  snprintf(out->srtp_aes_key_hex, sizeof(out->srtp_aes_key_hex), "%s", key_hex);
  out->srtp_key_id = key_id;
  snprintf(out->ping_payload, sizeof(out->ping_payload), "%s", ping);
  if (log_cb) {
    char* m = g_strdup_printf(
        "nvst: handshake OK (session %s, clientPort %d, peer %s:%u, key%s)",
        sess[0] ? sess : "-", client_port, peer_ip, peer_port,
        client_generated ? " (client-generated)" : "");
    log_cb(userdata, m);
    g_free(m);
  }
  return 0;
}

int nvst_probe(const char* rtsps_endpoint, const char* session_id, int width,
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

  // Fallback chain (OpenNOW parity + hardening for the proprietary NVIDIA
  // server): raw RTSPS first, then WSS "/" and WSS "/v2/session/<id>", each
  // retrying with the x-nv-sessionid header on the second pass.
  //   attempt 0: raw RTSPS
  //   attempt 1: WSS "/"  (no sess header)
  //   attempt 2: WSS "/"  (x-nv-sessionid header)
  //   attempt 3: WSS /v2/session/<id>  (no sess header)
  //   attempt 4: WSS /v2/session/<id>  (x-nv-sessionid header)
  WsConn* c = NULL;
  for (int attempt = 0; attempt < 5 && !c; attempt++) {
    if (attempt == 0) {
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
        char* m = g_strdup_printf("nvst: trying raw RTSPS %s:%d", host, port);
        log_cb(userdata, m);
        g_free(m);
      }
    } else {
      const char* tform = (attempt <= 2) ? "/" : path_form;
      int with_sess = (attempt == 2 || attempt == 4);
      c = wss_connect(host, port, session_id, tform, with_sess, err,
                      sizeof(err));
      if (log_cb) {
        char* m = g_strdup_printf("nvst: trying WSS %s (sess=%d)", tform,
                                  with_sess);
        log_cb(userdata, m);
        g_free(m);
      }
    }
    if (!c) continue;
    if (run_rtsp_handshake(c, rtsps_endpoint, width, height, fps, out, log_cb,
                           userdata) != 0) {
      ws_close(c);
      c = NULL;
      continue;
    }
  }
  if (!c) {
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

  printf("ALL NVST SELF TESTS PASSED\n");
  return 0;
}
#endif  // NVST_SELF_TEST
