// webrtc_neg_test.c — standalone repro + fix-verification for the webrtcbin
// negotiation crash.
//
// Negotiation flow (matches OpenNOW's promise-based flow):
//   1. set-remote-description with a promise; wait for the reply; if the
//      reply carries an error, STOP (never create-answer).
//   2. create-answer: on GStreamer 1.28 the promise is an IN-param:
//        g_signal_emit_by_name (webrtc, "create-answer", NULL, promise)
//      verified via gst-inspect-1.0 webrtcbin:
//        "create-answer" -> void (GstStructure *arg0, GstPromise *arg1)
//      We pre-create the promise with a change callback; the reply lands
//      there. (Passing &promise — the old out-param style — makes webrtcbin
//      call gst_promise_reply() on a stack address, treating stack memory
//      as a GstPromise -> pointer-as-size corruption -> GLib fatal abort.)
//   3. set-local-description with the answer + a promise.
//
// Usage: webrtc_neg_test <offer.sdp>
// Exit 0 = negotiation succeeded; 1 = clean negotiation failure; 134 = crash.
#include <glib.h>
#include <gst/gst.h>
#include <gst/sdp/gstsdpmessage.h>
#include <gst/webrtc/webrtc.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static GMainLoop* loop;
static int step = 0;  // 1 = waiting remote-desc, 2 = waiting answer
static char* g_answer = NULL;  // captured answer SDP from create-answer

static void on_ice_candidate_probe(GstElement* element, guint mline_index,
                                   const gchar* candidate, gpointer user_data) {
  (void)element;
  (void)user_data;
  fprintf(stderr, "[test] LOCAL candidate mline=%u: %s\n", mline_index,
          candidate);
}

static void on_remote_desc_replied(GstPromise* promise, gpointer user_data) {
  const GstStructure* reply = gst_promise_get_reply(promise);
  gboolean has_error = reply && gst_structure_has_field(reply, "error");
  fprintf(stderr, "[test] set-remote-description -> %s\n",
          has_error ? "ERROR" : "OK");
  if (reply) {
    gchar* dump = gst_structure_to_string(reply);
    fprintf(stderr, "[test]   reply-dump: %s\n", dump ? dump : "(null)");
    g_free(dump);
  } else {
    fprintf(stderr, "[test]   reply: (null)\n");
  }
  step = 2;
  g_main_loop_quit(loop);
}

static void on_answer_created(GstPromise* promise, gpointer user_data) {
  const GstStructure* reply = gst_promise_get_reply(promise);
  if (reply && gst_structure_has_field(reply, "error")) {
    const gchar* err = gst_structure_get_string(reply, "error");
    fprintf(stderr, "[test] create-answer ERROR: %s\n", err ? err : "?");
  }
  GstWebRTCSessionDescription* answer = NULL;
  if (reply &&
      gst_structure_get(reply, "answer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION,
                        &answer, NULL) &&
      answer) {
    gchar* text = gst_sdp_message_as_text(answer->sdp);
    fprintf(stderr, "[test] create-answer OK (%zu chars)\n", strlen(text)); FILE* fw=fopen("/tmp/answer.sdp","w"); if(fw){fwrite(text,1,strlen(text),fw); fclose(fw);}
    g_free(g_answer);
    g_answer = g_strdup(text);
    g_free(text);
    gst_webrtc_session_description_free(answer);
  } else {
    fprintf(stderr, "[test] create-answer FAILED (no answer in reply)\n");
  }
  step = 3;
  g_main_loop_quit(loop);
}

static void on_local_desc_replied(GstPromise* promise, gpointer user_data) {
  const GstStructure* reply = gst_promise_get_reply(promise);
  const gchar* err = reply ? gst_structure_get_string(reply, "error") : NULL;
  fprintf(stderr, "[test] set-local-description -> %s%s\n",
          err && *err ? "ERROR: " : "OK", err && *err ? err : "");
  g_main_loop_quit(loop);
}

static void on_candidate_replied(GstPromise* promise, gpointer user_data) {
  const GstStructure* reply = gst_promise_get_reply(promise);
  const gchar* err = reply ? gst_structure_get_string(reply, "error") : NULL;
  fprintf(stderr, "[test] add-ice-candidate (m-line %ld) -> %s%s\n",
          (long)user_data, err && *err ? "ERROR: " : "OK",
          err && *err ? err : "");
  gst_promise_unref(promise);
  g_main_loop_quit(loop);
}

static gboolean on_watchdog(gpointer user_data) {
  fprintf(stderr, "[test] WATCHDOG TIMEOUT at step %d\n", step);
  g_main_loop_quit(loop);
  return G_SOURCE_REMOVE;
}

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <offer.sdp>\n", argv[0]);
    return 2;
  }
  FILE* f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "cannot open %s\n", argv[1]);
    return 2;
  }
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  char* text = malloc(len + 1);
  if (fread(text, 1, len, f) != (size_t)len) {
    fprintf(stderr, "short read\n");
    return 2;
  }
  text[len] = '\0';
  fclose(f);

  gst_init(NULL, NULL);
  loop = g_main_loop_new(NULL, FALSE);
  g_timeout_add_seconds(15, on_watchdog, NULL);
  GstElement* pipeline = gst_pipeline_new("test-pipeline");
  GstElement* webrtcbin = gst_element_factory_make("webrtcbin", "webrtcbin");
  // Match OpenNOW's webrtcbin configuration (bundle-policy + stun-server).
  g_object_set(webrtcbin, "bundle-policy", GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE,
               NULL);
  g_object_set(webrtcbin, "stun-server", "stun://stun2.l.google.com:19302",
               NULL);
  g_signal_connect(webrtcbin, "on-ice-candidate",
                   G_CALLBACK(on_ice_candidate_probe), NULL);
  gst_bin_add(GST_BIN(pipeline), webrtcbin);
  gst_element_set_state(pipeline, GST_STATE_PLAYING);
  GstState state;
  if (gst_element_get_state(pipeline, &state, NULL, 10 * GST_SECOND) ==
          GST_STATE_CHANGE_FAILURE ||
      state != GST_STATE_PLAYING) {
    fprintf(stderr, "[test] pipeline failed to reach PLAYING\n");
    return 1;
  }

  GstSDPMessage* sdp = NULL;
  if (gst_sdp_message_new_from_text(text, &sdp) != GST_SDP_OK) {
    fprintf(stderr, "[test] SDP parse failed\n");
    return 1;
  }
  fprintf(stderr, "[test] SDP parsed OK (%ld bytes)\n", len);

  // Step 1: set-remote-description with a promise; wait for the reply.
  GstWebRTCSessionDescription* remote =
      gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_OFFER, sdp);
  GstPromise* dpromise =
      gst_promise_new_with_change_func(on_remote_desc_replied, NULL, NULL);
  step = 1;
  g_signal_emit_by_name(webrtcbin, "set-remote-description", remote, dpromise);
  g_main_loop_run(loop);
  gst_promise_unref(dpromise);
  gst_webrtc_session_description_free(remote);
  if (step != 2) {
    fprintf(stderr, "[test] set-remote-description never replied\n");
    return 1;
  }

  // Step 2: create-answer — promise is an IN-param; pre-create with a
  // change callback so the reply is delivered to on_answer_created.
  // CRITICAL: the options arg (GstStructure*) must NOT be NULL — this glib's
  // generic signal marshaller copies it via gst_structure_copy(), and passing
  // NULL makes that copy read garbage sizes from near-NULL memory
  // (g_malloc0 of ~100GB -> GLib fatal abort, before the handler even runs).
  GstPromise* apromise =
      gst_promise_new_with_change_func(on_answer_created, NULL, NULL);
  GstStructure* options = gst_structure_new_empty("answer-options");
  g_signal_emit_by_name(webrtcbin, "create-answer", options, apromise);
  gst_structure_free(options);
  g_main_loop_run(loop);
  gst_promise_unref(apromise);

  // Step 3: adopt the answer as the local description (ICE gathering starts),
  // then probe remote-candidate feeding on every m-line. add-ice-candidate-full
  // reports acceptance/errors through its promise reply — this pinpoints which
  // m-line index webrtcbin will actually accept a remote candidate on.
  if (g_answer) {
    GstSDPMessage* asdp = NULL;
    if (gst_sdp_message_new_from_text(g_answer, &asdp) == GST_SDP_OK) {
      GstWebRTCSessionDescription* local =
          gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, asdp);
      GstPromise* lp =
          gst_promise_new_with_change_func(on_local_desc_replied, NULL, NULL);
      g_signal_emit_by_name(webrtcbin, "set-local-description", local, lp);
      g_main_loop_run(loop);
      gst_promise_unref(lp);
      gst_webrtc_session_description_free(local);
    }
    for (guint ml = 0; ml < 3; ml++) {
      GstPromise* cp = gst_promise_new_with_change_func(
          on_candidate_replied, (gpointer)(long)ml, NULL);
      g_signal_emit_by_name(webrtcbin, "add-ice-candidate-full", ml,
                            "candidate:1 1 UDP 2130706431 127.0.0.1 5000 typ host",
                            cp);
      g_main_loop_run(loop);
    }
  }

  gst_element_set_state(pipeline, GST_STATE_NULL);
  gst_object_unref(pipeline);
  g_main_loop_unref(loop);
  free(text);
  fprintf(stderr, "[test] DONE (no crash)\n");
  return step == 3 ? 0 : 1;
}
