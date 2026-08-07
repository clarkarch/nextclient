import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:gfn_core/gfn_core.dart';

import 'gfn_cursor_overlay.dart' show GfnCursorOverlayUpdate;
import 'gfn_sdp_munger.dart';
import 'nvst_bridge_ffi.dart';
import 'stream_stats.dart';
import 'stream_transport.dart';
import 'user_settings.dart';
import 'webrtcbin_ffi_transport.dart';

/// Classic NVST UDP video transport (GStreamer hardware decode).
///
/// Video comes over the classic Mjolnir/NVST UDP path (RTSP SETUP/PLAY →
/// SRTP → NV_VIDEO_PACKET → Annex-B AUs → VAAPI/D3D11 decoder), a port of
/// OpenNOW's native streamer. Input (keyboard/mouse/gamepad) and the WebRTC
/// signaling handshake are delegated to the GStreamer `webrtcbin` FFI
/// transport — its SCTP data channels negotiate correctly even though the
/// server never sends it video RTP.
///
/// Select this transport on desktop where VAAPI/D3D11 hardware decode is
/// available; keep [flutterWebrtc] on Android (MediaCodec hardware decode).
class NvstVideoTransport implements StreamTransport {
  final SessionInfo session;
  final UserSettings settings;
  final LogSink log;
  final ValueChanged<String>? onStatus;

  /// Video frames from the NVST pipeline, rendered by [buildVideoView].
  final ValueNotifier<ui.Image?> frameImage = ValueNotifier(null);
  int? _videoWidth;
  int? _videoHeight;

  @override
  final ValueNotifier<StreamStatsSnapshot?> stats = ValueNotifier(null);

  /// The webrtcbin FFI transport owns signaling + SCTP input channels.
  late final WebRtcBinFfiTransport _input;

  NvstBridgeFfi? _bridge;
  bool _disposed = false;
  int _frameSeq = 0;
  int _lastShownSeq = -1;
  Timer? _statsTimer;
  bool _statsPollInFlight = false;
  int _lastFramesDecoded = 0;
  DateTime _lastStatsAt = DateTime.now();

  NvstVideoTransport({
    required this.session,
    required this.settings,
    required this.log,
    this.onStatus,
  }) : _input = WebRtcBinFfiTransport(
          session: session,
          settings: settings,
          log: log,
          onStatus: onStatus,
        );

  void _log(String message) {
    log.log(LogLevel.info, 'nvst', message);
    onStatus?.call(message);
  }

  @override
  int? get videoWidth => _videoWidth;
  @override
  int? get videoHeight => _videoHeight;
  @override
  bool get rendererHasVideo => frameImage.value != null;

  /// No WebRTC cursor_channel on the NVST path — cursor rendering stays
  /// server-side.
  @override
  ValueListenable<GfnCursorOverlayUpdate?>? get cursorOverlay => null;

  /// The NVST path has no SCTP buffered-amount telemetry; the adaptive mouse
  /// sampler sees no backpressure signal.
  @override
  int? get inputQueueBufferedBytes => null;

  @override
  Future<void> start() async {
    if (_disposed) return;

    // 1. Start the webrtcbin input transport (signaling + SCTP). It gets no
    //    video from the server, but its data channels work.
    await _input.start();

    // 2. NVST RTSP probe → SRTP/UDP video session.
    final bridge = NvstBridgeFfi.create(
      onLog: (msg) => log.log(LogLevel.debug, 'nvst', msg),
      onFrame: _onNativeFrame,
    );
    _bridge = bridge;

    try {
      final streamSettings = settings.buildStreamSettings();
      final dims = GfnSdpMunger.parseResolution(streamSettings.resolution);
      final codec = GfnSdpMunger.codecWireName(streamSettings.codec);
      final endpoint = session.rtspsEndpoints.isNotEmpty
          ? session.rtspsEndpoints.first
          : null;
      if (endpoint == null || endpoint.isEmpty) {
        throw StateError('No rtsps:// endpoints on the session');
      }

      _log('NVST probe: $endpoint');
      final video = bridge.probe(
        rtspsEndpoint: endpoint,
        sessionId: session.sessionId,
        width: dims.$1,
        height: dims.$2,
        fps: streamSettings.fps,
        codec: codec,
      );
      _log('NVST probe OK — peer ${video.videoPeerIp}:${video.videoPeerPort} '
          'clientPort ${video.clientUdpPort}');

      bridge.startVideo(video);
      _startStatsPolling();
    } catch (e) {
      // Tear down the input transport so a retry isn't blocked.
      await _input.dispose();
      bridge.dispose();
      _bridge = null;
      rethrow;
    }
  }

  // ---------------------------------------------------------------------
  // Video frames (NVST pipeline callback -> ui.Image)
  // ---------------------------------------------------------------------

  void _onNativeFrame(int width, int height, int stride,
      ffi.Pointer<ffi.Uint8> rgba, int rtpTimestamp) {
    final rowBytes = width * 4;
    final total = stride > 0 && height > 0 ? stride * height : 0;
    if (total <= 0) {
      _bridge?.freePtr(rgba.cast());
      return;
    }
    final copy = Uint8List(total);
    copy.setAll(0, rgba.asTypedList(total));
    _bridge?.freePtr(rgba.cast());

    Uint8List packed = copy;
    if (stride != rowBytes) {
      packed = Uint8List(rowBytes * height);
      for (var y = 0; y < height; y++) {
        packed.setRange(
          y * rowBytes,
          y * rowBytes + rowBytes,
          copy,
          y * stride,
        );
      }
    }
    _videoWidth = width;
    _videoHeight = height;
    final seq = ++_frameSeq;
    ui.decodeImageFromPixels(
      packed,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (img) {
        if (seq <= _lastShownSeq) return;
        _lastShownSeq = seq;
        frameImage.value = img;
      },
    );
  }

  // ---------------------------------------------------------------------
  // Stats polling (synthesized from the NVST bridge's counters)
  // ---------------------------------------------------------------------

  void _startStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_pollStats());
    });
  }

  Future<void> _pollStats() async {
    final bridge = _bridge;
    if (bridge == null || _disposed || _statsPollInFlight) return;
    _statsPollInFlight = true;
    try {
      final now = DateTime.now();
      final frames = bridge.framesDecoded();
      // Same minimum-window rule as StreamStatsSnapshot.fromStats: a
      // sub-100ms poll (timer jitter, back-to-back polls) makes the frame
      // delta meaningless — a 1-frame burst in 1ms reads as 1000 fps.
      final elapsedMs = now.difference(_lastStatsAt).inMilliseconds;
      final deltaSec =
          elapsedMs < 100 ? 0.0 : (elapsedMs / 1000).clamp(0.0, 5.0);
      final decodeFps = deltaSec > 0
          ? ((frames - _lastFramesDecoded) / deltaSec).clamp(0.0, 240.0)
          : 0.0;
      _lastFramesDecoded = frames;
      _lastStatsAt = now;

      stats.value = StreamStatsSnapshot(
        timestamp: now,
        connectionState: rendererHasVideo ? 'connected' : 'connecting',
        inputReady: _input.stats.value?.inputReady ?? false,
        reliableInputOpen: _input.stats.value?.reliableInputOpen ?? false,
        partiallyReliableInputOpen:
            _input.stats.value?.partiallyReliableInputOpen ?? false,
        rendererHasVideo: rendererHasVideo,
        framesReceived: frames,
        framesDecoded: frames,
        decodeFps: decodeFps.toDouble(),
        receivedFps: decodeFps.toDouble(),
        videoWidth: _videoWidth,
        videoHeight: _videoHeight,
        codecMime: null,
        decoderImplementation: 'GStreamerNvstVaapi',
      );
    } catch (e) {
      log.log(LogLevel.debug, 'nvst', 'stats poll failed: $e');
    } finally {
      _statsPollInFlight = false;
    }
  }

  // ---------------------------------------------------------------------
  // Input — delegated to the webrtcbin transport (SCTP data channels)
  // ---------------------------------------------------------------------

  @override
  void sendKeyEvent(KeyEvent event) => _input.sendKeyEvent(event);

  @override
  void sendText(String text) => _input.sendText(text);

  @override
  void sendMouseMove({required int dx, required int dy}) =>
      _input.sendMouseMove(dx: dx, dy: dy);

  @override
  void sendMouseAbsolute({
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    // No cursor overlay on the NVST path; cursor is server-rendered.
  }

  @override
  void sendMouseButton({required bool down, required int button}) =>
      _input.sendMouseButton(down: down, button: button);

  @override
  void sendMouseWheel({required int delta}) =>
      _input.sendMouseWheel(delta: delta);

  @override
  void sendGamepadState({
    int controllerId = 0,
    required int buttons,
    required double leftStickX,
    required double leftStickY,
    required double rightStickX,
    required double rightStickY,
    double leftTrigger = 0,
    double rightTrigger = 0,
  }) =>
      _input.sendGamepadState(
        controllerId: controllerId,
        buttons: buttons,
        leftStickX: leftStickX,
        leftStickY: leftStickY,
        rightStickX: rightStickX,
        rightStickY: rightStickY,
        leftTrigger: leftTrigger,
        rightTrigger: rightTrigger,
      );

  // ---------------------------------------------------------------------
  // Video surface
  // ---------------------------------------------------------------------

  @override
  Widget buildVideoView({required Widget placeholder}) {
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: frameImage,
      builder: (context, image, _) {
        if (image == null) return placeholder;
        return RawImage(
          image: image,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        );
      },
    );
  }

  // ---------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    stats.value = null;

    final bridge = _bridge;
    _bridge = null;
    bridge?.dispose();
    frameImage.value = null;

    await _input.dispose();
    _log('NVST transport torn down');
  }
}
