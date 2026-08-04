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

void bridge_free_string(char* s);
// Frees a frame buffer handed to the frame callback.
void bridge_free_ptr(void* p);

#ifdef __cplusplus
}
#endif
#endif  // GST_BRIDGE_H
