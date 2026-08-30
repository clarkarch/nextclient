// gst_bridge.h
//
// Minimal C ABI around GStreamer's webrtcbin element, exposed to Dart via
// dart:ffi. Covers the exact GFN flow the Dart WebRtcStreamSession does:
//   offer SDP in -> (munged in Dart) -> set-remote-description
//   -> create-answer -> answer SDP out (munged in Dart) -> nvstSdp built in Dart
//   -> ICE candidates both ways, input data channels (reliable + partial),
//   decoded frames out via callback (RGBA, malloc'd; Dart frees).
//
// Threading: all GStreamer actions are marshalled onto a dedicated GLib main
// loop thread so promise-based SDP negotiation resolves correctly. Callbacks
// fire from GStreamer threads — keep them cheap.
#ifndef GST_BRIDGE_H
#define GST_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GstBridge GstBridge;

// The Dart listener callbacks are asynchronous, so every pointer payload is
// heap-allocated by the bridge and ownership is handed to the callee, which
// MUST free it (bridge_free_string for g_strdup'd strings, bridge_free_ptr
// for malloc'd buffers).

// Log line (g_strdup'd; free with bridge_free_string).
typedef void (*bridge_log_cb)(void* userdata, const char* message);
// Local ICE candidate gathered by webrtcbin (full a=candidate: line,
// g_strdup'd; free with bridge_free_string).
typedef void (*bridge_ice_cb)(void* userdata, unsigned int mline_index,
                              const char* candidate);
// Decoded video frame, RGBA, malloc'd by the bridge — free with
// bridge_free_ptr.
typedef void (*bridge_frame_cb)(void* userdata, int width, int height,
                                int stride, const uint8_t* rgba,
                                uint32_t rtp_timestamp);
// Input channel state changes (1 = reliable open, 2 = partial open).
typedef void (*bridge_channel_cb)(void* userdata, int channel, int open);
// Inbound data-channel message (channel 1 = reliable, 2 = partial).
// malloc'd; free with bridge_free_ptr.
typedef void (*bridge_message_cb)(void* userdata, int channel,
                                  const uint8_t* data, size_t len);

GstBridge* bridge_create(bridge_log_cb log_cb, bridge_ice_cb ice_cb,
                         bridge_frame_cb frame_cb,
                         bridge_channel_cb channel_cb,
                         bridge_message_cb message_cb, void* userdata);
void bridge_destroy(GstBridge* bridge);

// Sets the remote offer and creates the local answer. Returns a malloc'd
// answer SDP string (free with bridge_free_string), or NULL on failure.
char* bridge_set_remote_offer(GstBridge* bridge, const char* offer_sdp);

// Stores the ORIGINAL (unsanitized) remote ICE credentials from the raw GFN
// offer. GFN ice-pwds are base64-padded ('='), which GStreamer's SDP parser
// rejects — the offer is sanitized for parsing, but the server signs its STUN
// with the real password, so these originals are re-applied to the NICE
// streams after negotiation. Call before bridge_set_remote_offer.
int bridge_set_original_ice_credentials(GstBridge* bridge, const char* ufrag,
                                        const char* pwd);

// Adds a remote ICE candidate (mid may be NULL).
int bridge_add_remote_ice(GstBridge* bridge, const char* candidate,
                          const char* sdp_mid, unsigned int sdp_mline_index);

// Creates the input data channels before the answer is negotiated.
// partial_reliable_ms <= 0 disables the partially-reliable channel.
int bridge_create_input_channels(GstBridge* bridge, int partial_reliable_ms);

// Sends an input packet (reliable=1 -> input_channel_v1, else partial).
int bridge_send_input(GstBridge* bridge, const uint8_t* data, size_t len,
                      int reliable);

// Polled every ~500 ms from Dart for the stats overlay.
int bridge_frames_decoded(GstBridge* bridge);
int bridge_frames_dropped(GstBridge* bridge);

// GPU-texture path: a double-buffered "latest frame" slot. The embedder's
// FlTextureGL::populate() calls bridge_acquire_latest_frame() on the raster
// thread; the returned buffer stays valid until the NEXT acquire. Enable
// with bridge_enable_frame_slot() before streaming starts (the appsink then
// also stores frames into the slot; the Dart frame callback still fires).
void bridge_enable_frame_slot(GstBridge* bridge);

int bridge_frame_slot_enabled(GstBridge* bridge);

// Returns the newest frame. The buffer stays valid until the next call.
int bridge_acquire_latest_frame(GstBridge* bridge, const uint8_t** out_data,
                                int32_t* out_width, int32_t* out_height,
                                int32_t* out_stride, uint32_t* out_seq);

// Called once per produced frame (from the GStreamer streaming thread) so the
// embedder can mark the texture dirty — Flutter only re-invokes populate()
// after fl_texture_registrar_mark_texture_frame_available().
typedef void (*bridge_slot_notify_cb)(void* userdata);
void bridge_set_frame_slot_notify(GstBridge* bridge,
                                  bridge_slot_notify_cb notify, void* userdata);

// GPU zero-copy mode: the appsink negotiates VAMemory (RGBA via vapostproc),
// frames are exported as dmabuf fds (vaExportSurfaceHandle) and the embedder
// imports them as EGLImages on the raster thread. 0 = pixel slot (CPU RGBA),
// 1 = dmabuf slot.
int bridge_frame_slot_mode(GstBridge* bridge);

typedef struct BridgeDmaBufFrame {
  int fds[4];
  int nfd;
  uint32_t fourcc;  // DRM fourcc (ABGR8888 for RGBA surfaces)
  int32_t width;
  int32_t height;
  int32_t strides[4];
  int32_t offsets[4];
  uint64_t modifiers[4];  // DRM format modifiers (per object)
  uint32_t seq;
} BridgeDmaBufFrame;

// Consumer owns the fds until the next call; close them after EGLImage
// import (the image holds its own dmabuf reference).
int bridge_acquire_latest_dmabuf(GstBridge* bridge, BridgeDmaBufFrame* out);

void bridge_free_string(char* s);
// Frees a frame buffer handed to the frame callback.
void bridge_free_ptr(void* p);

#ifdef __cplusplus
}
#endif
#endif  // GST_BRIDGE_H
