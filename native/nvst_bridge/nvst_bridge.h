// nvst_bridge.h — Classic NVST UDP video for GFN (Mjolnir/GO-with-Moonlight).
//
// Port of OpenNOW's native/opennow-streamer/src/nvst_video.rs + the
// nvstRtsp probe (probe.ts / rtspClient.ts / websocketTransport.ts / sdp.ts).
//
// Flow:
//   1. RTSP-over-WSS probe (OPTIONS → DESCRIBE → SETUP video/0/0 →
//      ANNOUNCE → PLAY) against the session's rtsps:// endpoint. Extracts or
//      generates the SRTP encryption key + video peer ip:port + a client UDP
//      port to bind.
//   2. UDP receive thread binds that port, hole-punches with the server's
//      ping payload, then decrypts SRTP (libsrtp) and parses the RTP payload
//      as Moonlight-hypothesis NV_VIDEO_PACKETs, assembling Annex-B access
//      units on FLAG_EOF.
//   3. Assembled AUs are pushed into a GStreamer appsrc →
//      h264parse/h265parse → VAAPI/D3D11 hardware decoder → videoconvert →
//      RGBA appsink. Frames are handed to Dart via the frame callback.
//
// Threading: one GLib main loop thread owns the GStreamer pipeline (mirrors
// gst_bridge.c). A separate UDP receive thread feeds appsrc. The RTSP probe
// runs synchronously in the calling thread.
//
// This is a port of a scaffold OpenNOW labels "GO-with-Moonlight-hypothesis":
// the NV_VIDEO_PACKET layout and SRTP profile are documented but the SRTP
// decrypt path was unconfirmed upstream (libsrtp not linked there). This
// bridge links libsrtp and prefers AEAD_AES_256_GCM, with cleartext-RTP
// fallback so the receive/assemble path can still be exercised.
#ifndef NVST_BRIDGE_H
#define NVST_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NvstBridge NvstBridge;

// Log line (g_strdup'd; free with nvst_free_string).
typedef void (*nvst_log_cb)(void* userdata, const char* message);
// Decoded video frame, RGBA, malloc'd by the bridge — free with
// nvst_free_ptr.
typedef void (*nvst_frame_cb)(void* userdata, int width, int height,
                              int stride, const uint8_t* rgba,
                              uint32_t rtp_timestamp);

// Params for starting a classic-NVST UDP video session. Mirrors
// OpenNOW's NvstVideoSession.
typedef struct NvstVideoSession {
  // Bind port for the UDP receive socket (clientUdpPort from SETUP).
  unsigned short client_udp_port;
  char video_peer_ip[64];
  unsigned short video_peer_port;
  // 64-hex AES-256 key (runtime.encryptionKey), used to pack the libsrtp
  // master key||salt.
  char srtp_aes_key_hex[65];
  // keyId for salt packing (`%024x`).
  unsigned int srtp_key_id;
  // Server-provided hole-punch ping payload (may be empty → "PING").
  char ping_payload[64];
  // "H264" or "H265".
  char codec[8];
} NvstVideoSession;

// Result of the RTSP probe. On ok==1, video_session is populated and
// `session` holds the RTSP session id (caller may need it for nothing
// further — the UDP video is already live via nvst_video_start).
typedef struct NvstProbeResult {
  int ok;
  char error[256];
  char session[128];
  char video_peer_ip[64];
  unsigned short video_peer_port;
  unsigned short client_udp_port;
  char srtp_aes_key_hex[65];
  unsigned int srtp_key_id;
  char ping_payload[64];
  char codec[8];
} NvstProbeResult;

// Runs the RTSP-over-WSS handshake against `rtsps_endpoint` for `session_id`
// and fills `out` with the negotiated video session. `width`/`height`/`fps`
// are the client viewport (used for the ANNOUNCE SDP). Returns 0 on success,
// non-zero on failure (error string in out->error). The probe's UDP socket is
// closed on return so nvst_video_start can rebind the same port.
int nvst_probe(const char* rtsps_endpoint, const char* session_id, int width,
               int height, int fps, const char* codec, NvstProbeResult* out,
               nvst_log_cb log_cb, void* userdata);

// Starts the UDP receive + GStreamer decode pipeline for a session returned
// by nvst_probe. Returns NULL on failure (log callback has details).
NvstBridge* nvst_video_start(const NvstVideoSession* session,
                             nvst_log_cb log_cb, nvst_frame_cb frame_cb,
                             void* userdata);

// Stops the receive thread + pipeline and frees the bridge. Never crashes on
// a NULL bridge.
void nvst_video_stop(NvstBridge* bridge);

// Polled from Dart for the stats overlay.
int nvst_frames_decoded(NvstBridge* bridge);

void nvst_free_string(char* s);
void nvst_free_ptr(void* p);

#ifdef __cplusplus
}
#endif
#endif  // NVST_BRIDGE_H
