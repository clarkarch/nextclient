import 'package:flutter/foundation.dart'
    show ValueChanged, ValueListenable, ValueNotifier;
import 'package:flutter/services.dart' show KeyEvent;
import 'package:flutter/widgets.dart' show Widget;
import 'package:gfn_core/gfn_core.dart';

import 'gfn_cursor_overlay.dart' show GfnCursorOverlayUpdate;
import 'nvst_video_transport.dart';
import 'stream_stats.dart';
import 'user_settings.dart';
import 'webrtc_stream_session.dart';
import 'webrtcbin_ffi_transport.dart';

/// Which transport renders + carries a GFN session.
///
/// [flutterWebrtc] is the default libwebrtc path (stock `flutter_webrtc`
/// plugin, `RTCVideoRenderer`). [webrtcbinFfi] routes through the native
/// GStreamer `webrtcbin` bridge (`native/gst_bridge/libgst_bridge.so`) which
/// decodes with VAAPI/FFmpeg hardware-accelerated elements — no custom
/// libwebrtc build required. [nvstGstreamer] receives video over the classic
/// NVST UDP path (`native/nvst_bridge/libnvst_bridge.so`) with GStreamer
/// hardware decode, keeping webrtcbin for SCTP input.
///
/// The transport is a setting (`UserSettings.streamTransport`) so switching is
/// a picker toggle, and the underlying libwebrtc `.so` swap from
/// `vaapi_patch/` can still be layered under [flutterWebrtc] independently.
enum StreamTransportKind {
  flutterWebrtc,
  webrtcbinFfi,
  nvstGstreamer,
}

/// Uniform surface over the GFN transports.
///
/// The stream page drives input through this interface (keyboard, mouse,
/// gamepad), subscribes to [stats], and renders the video via
/// [buildVideoView]. Implementations:
///  * [WebRtcStreamSession] — stock libwebrtc path.
///  * [WebRtcBinFfiTransport] — GStreamer webrtcbin over dart:ffi.
///  * [NvstVideoTransport] — classic NVST UDP video + GStreamer decode.
abstract class StreamTransport {
  /// Latest stream-health snapshot (mirrors `pc.getStats()`; the FFI transport
  /// synthesizes a comparable snapshot from the bridge's counters).
  ValueNotifier<StreamStatsSnapshot?> get stats;

  /// Latest decoded frame dimensions, for the stats overlay.
  int? get videoWidth;
  int? get videoHeight;

  /// True once remote video has actually been rendered.
  bool get rendererHasVideo;

  /// Connects signaling + the peer connection. Throws on unrecoverable
  /// failure (caller surfaces a friendly error).
  Future<void> start();

  /// Tears down the transport. Never throws.
  Future<void> dispose();

  /// Builds the video surface widget (placeholder is shown until frames
  /// arrive). The stream page wraps this in its input Listener layers.
  Widget buildVideoView({required Widget placeholder});

  /// Server cursor-overlay updates from the WebRTC `cursor_channel`
  /// (predefined styles + custom bitmaps). Null on transports without a
  /// cursor channel (NVST), where cursor rendering stays server-side.
  ValueListenable<GfnCursorOverlayUpdate?>? get cursorOverlay => null;

  /// Bytes currently queued in the transport's reliable input channel (SCTP
  /// backpressure). Null when the transport has no such telemetry; the
  /// adaptive mouse sampler uses it to back off its coalesce interval under
  /// pressure.
  int? get inputQueueBufferedBytes => null;

  // --- Input (mirrors the WebRtcStreamSession input API) --------------------

  void sendKeyEvent(KeyEvent event);

  /// Sends raw text (soft-keyboard / paste input) to the streamer.
  void sendText(String text);

  void sendMouseMove({required int dx, required int dy});

  void sendMouseButton({required bool down, required int button});

  void sendMouseWheel({required int delta});

  void sendGamepadState({
    int controllerId = 0,
    required int buttons,
    required double leftStickX,
    required double leftStickY,
    required double rightStickX,
    required double rightStickY,
    double leftTrigger = 0,
    double rightTrigger = 0,
  });
}

/// Builds the transport selected by [settings.streamTransport].
StreamTransport createStreamTransport({
  required StreamTransportKind kind,
  required SessionInfo session,
  required UserSettings settings,
  required LogSink log,
  ValueChanged<String>? onStatus,
}) {
  switch (kind) {
    case StreamTransportKind.flutterWebrtc:
      return WebRtcStreamSession(
        session: session,
        settings: settings,
        log: log,
        onStatus: onStatus,
      );
    case StreamTransportKind.webrtcbinFfi:
      return WebRtcBinFfiTransport(
        session: session,
        settings: settings,
        log: log,
        onStatus: onStatus,
      );
    case StreamTransportKind.nvstGstreamer:
      return NvstVideoTransport(
        session: session,
        settings: settings,
        log: log,
        onStatus: onStatus,
      );
  }
}
