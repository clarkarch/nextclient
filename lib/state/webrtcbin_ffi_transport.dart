import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Directory, File;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart' show KeyEvent, KeyDownEvent, KeyUpEvent, KeyRepeatEvent;
import 'package:flutter/widgets.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;

import 'gfn_cursor_overlay.dart' show GfnCursorOverlayUpdate;
import 'gfn_input_protocol.dart';
import 'gfn_keyboard_mapping.dart';
import 'gfn_sdp_munger.dart';
import 'gst_bridge_ffi.dart';
import 'stream_stats.dart';
import 'stream_transport.dart';
import 'user_settings.dart';

/// GStreamer `webrtcbin` transport over dart:ffi.
///
/// Drives the exact same NVST signaling flow as [WebRtcStreamSession] — offer
/// SDP in -> (munged) -> `bridge_set_remote_offer` -> answer SDP out -> munged
/// -> nvstSdp built from the answer's ICE credentials -> ICE both ways -> input
/// data channels — but the WebRTC + video decode happens in GStreamer, where
/// `vah264dec` (VAAPI) / `d3d11h264dec` (Windows) hardware decode is
/// available without a custom libwebrtc build.
///
/// Video frames arrive as RGBA via the bridge's frame callback and are decoded
/// to [ui.Image] for a [RawImage]-backed surface (no texture registry needed).
class WebRtcBinFfiTransport implements StreamTransport {
  final SessionInfo session;
  final UserSettings settings;
  final LogSink log;

  /// Latest decoded frame, rendered by [buildVideoView]. Also drives
  /// [rendererHasVideo].
  final ValueNotifier<ui.Image?> frameImage = ValueNotifier(null);
  int? _videoWidth;
  int? _videoHeight;

  @override
  final ValueNotifier<StreamStatsSnapshot?> stats = ValueNotifier(null);

  GstBridgeFfi? _bridge;
  GfnSignalingClient? _signaling;
  bool _disposed = false;
  bool _answerSent = false;
  bool _answerOnWire = false;
  bool _established = false;
  String? _lastConnectionState;

  // NVST handshake state (mirrors the libwebrtc session).
  final List<IceCandidatePayload> _queuedLocalIce = [];
  final List<IceCandidatePayload> _queuedRemoteCandidates = [];
  RiInputCapabilities _inputCaps = const RiInputCapabilities();

  // Input transport state (same protocol as the libwebrtc path).
  final GfnInputEncoder _inputEncoder = GfnInputEncoder();
  bool _inputReady = false;
  bool _reliableInputOpen = false;
  bool _partiallyReliableInputOpen = false;
  Timer? _inputHeartbeatTimer;
  Timer? _statsTimer;
  bool _statsPollInFlight = false;
  int _lastFramesDecoded = 0;
  DateTime _lastStatsAt = DateTime.now();

  // Monotonic sequence for the async decode callback: [ui.decodeImageFromPixels]
  // completes out of order, and the newest completion must win — otherwise a
  // stale frame's decode could overwrite a newer frame already on screen.
  int _frameSeq = 0;
  int _lastShownSeq = -1;

  int _gamepadBitmap = 0x0000;
  bool _gamepadTouched = false;
  int _lastGamepadButtons = 0;
  double _lastLx = 0, _lastLy = 0, _lastRx = 0, _lastRy = 0;
  double _lastLt = 0, _lastRt = 0;

  final LockKeyState _lockKeys = LockKeyState();

  final ValueChanged<String>? onStatus;

  WebRtcBinFfiTransport({
    required this.session,
    required this.settings,
    required this.log,
    this.onStatus,
  });

  void _log(String message) {
    log.log(LogLevel.info, 'gstbridge', message);
    onStatus?.call(message);
  }

  @override
  int? get videoWidth => _videoWidth;

  @override
  int? get videoHeight => _videoHeight;

  @override
  bool get rendererHasVideo => frameImage.value != null;

  /// No WebRTC cursor_channel on the GStreamer bridge path — cursor rendering
  /// stays server-side.
  @override
  ValueListenable<GfnCursorOverlayUpdate?>? get cursorOverlay => null;

  /// The bridge exposes no SCTP buffered-amount telemetry to Dart, so the
  /// adaptive mouse sampler sees no backpressure signal on this transport.
  @override
  int? get inputQueueBufferedBytes => null;

  @override
  Future<void> start() async {
    if (_disposed) return;
    final bridge = GstBridgeFfi.create(
      onLog: (msg) => log.log(LogLevel.debug, 'gstbridge', msg),
      onIceCandidate: _onLocalIceCandidate,
      onFrame: _onNativeFrame,
      onChannel: _onChannelState,
      onMessage: _onChannelMessage,
    );
    _bridge = bridge;
    _log('GStreamer bridge created (webrtcbin)');

    _startStatsPolling();
    _log('Signaling: [SERVER HOST REDACTED]');
    final signaling = GfnSignalingClient(
      signalingServer: session.signalingServer,
      sessionId: session.sessionId,
      signalingUrl: session.signalingUrl,
      log: log,
    );
    signaling.onEvent(_onSignalingEvent);
    _signaling = signaling;
    if (_disposed) {
      signaling.disconnect();
      _signaling = null;
      return;
    }
    await signaling.connect();
  }

  // ---------------------------------------------------------------------
  // NVST signaling (mirrors WebRtcStreamSession._onSignalingEvent)
  // ---------------------------------------------------------------------

  Future<void> _onSignalingEvent(MainToRendererSignalingEvent event) async {
    switch (event.type) {
      case MainToRendererSignalingEventType.offer:
        await _handleOffer(event.sdp!);
      case MainToRendererSignalingEventType.remoteIce:
        final candidate = event.candidate;
        if (candidate == null) return;
        final bridge = _bridge;
        if (bridge == null) {
          _queuedRemoteCandidates.add(candidate);
          return;
        }
        // The offer must be set before candidates can be added; queue until
        // the answer flow has parsed it (mirrors libwebrtc's remote-description
        // ordering).
        if (!_answerSent) {
          _queuedRemoteCandidates.add(candidate);
          return;
        }
        _log('Remote ICE candidate (mid=${candidate.sdpMid}, '
            'mline=${candidate.sdpMLineIndex}): ${candidate.candidate}');
        bridge.addRemoteIce(candidate.candidate, candidate.sdpMid,
            candidate.sdpMLineIndex);
      case MainToRendererSignalingEventType.connected:
        _log('Signaling connected');
      case MainToRendererSignalingEventType.disconnected:
        final reason = (event.reason ?? '').trim().toLowerCase();
        final expected = _established ||
            reason == 'socket closed' ||
            reason == 'bye' ||
            reason == 'peerremoved' ||
            reason == 'peer removed';
        if (expected) {
          _log('Signaling socket closed after connection established (expected — streaming continues)');
        } else {
          _log('Signaling disconnected (${event.reason}) before connection established');
        }
      case MainToRendererSignalingEventType.error:
        _log('Signaling error: ${event.message}');
      case MainToRendererSignalingEventType.log:
        log.log(LogLevel.debug, 'gstbridge', event.message ?? '');
    }
  }

  Future<void> _handleOffer(String sdp) async {
    final bridge = _bridge;
    if (bridge == null || _answerSent || _disposed) return;
    _answerSent = true;

    try {
      _log('Received offer SDP — negotiating (GStreamer webrtcbin)');

      // 1. Parse the offer's ri.* input capabilities (echoed into nvstSdp) and
      //    create the input data channels before the answer is produced.
      _inputCaps = GfnSdpMunger.parseRiInputCapabilities(sdp);
      bridge.createInputChannels(_inputCaps.partialReliableThresholdMs);

      // 1b. Capture the ORIGINAL (unsanitized) remote ICE credentials from the
      //     raw offer. GFN ice-pwds are base64-padded ('=') which GStreamer's
      //     parser rejects, so the offer gets sanitized below — but the
      //     NVIDIA server signs its STUN with the REAL password. The bridge
      //     re-applies these originals to the NICE streams after negotiation
      //     or every connectivity check fails (OpenNOW parity).
      final originalCreds = GfnSdpMunger.extractIceCredentials(sdp);
      if (originalCreds.ufrag.isNotEmpty && originalCreds.pwd.isNotEmpty) {
        bridge.storeOriginalIceCredentials(
          originalCreds.ufrag,
          originalCreds.pwd,
        );
        _log('Captured original remote ICE credentials for NICE restore');
      }

      // 2. Offer sanitization — same order OpenNOW applies it. Raw GFN offers
      //    crash GStreamer's webrtcbin (session-level ICE attrs, unsanitized
      //    ice-pwd, unaligned framerate), so munge before handing it over.
      var processedOffer = sdp;
      final streamSettings = settings.buildStreamSettings();
      final codec = GfnSdpMunger.codecWireName(streamSettings.codec);

      final fixedIp = GfnSdpMunger.fixServerIp(processedOffer, session.serverIp);
      if (fixedIp != processedOffer) {
        _log('Fixed 0.0.0.0 addresses in SDP offer');
      }
      processedOffer = fixedIp;

      // Point ICE candidates at the CloudMatch media endpoint when present.
      final media = session.mediaConnectionInfo;
      if (media != null && (media.usage == 2 || media.usage == 17)) {
        final rewritten = GfnSdpMunger.rewriteIceCandidateEndpoints(
          processedOffer,
          media.ip,
          media.port,
        );
        if (rewritten != processedOffer) {
          _log('Rewrote ICE candidate endpoints to ${media.ip}:${media.port}');
        }
        processedOffer = rewritten;
      }

      final duplicated =
          GfnSdpMunger.duplicateSessionWebrtcAttributesToMedia(processedOffer);
      if (duplicated != processedOffer) {
        _log('Duplicated session ICE attrs into media sections');
      }
      processedOffer = duplicated;

      final filtered = GfnSdpMunger.preferCodec(processedOffer, codec);
      if (filtered != processedOffer) {
        _log('Filtered offer SDP to codec $codec');
      }
      processedOffer = filtered;

      final aligned = GfnSdpMunger.alignVideoSdpFramerateForGstreamer(
        processedOffer,
        streamSettings.fps,
      );
      if (aligned != processedOffer) {
        _log('Aligned offer SDP framerate to ${streamSettings.fps} fps');
      }
      processedOffer = aligned;

      final sanitized = GfnSdpMunger.sanitizeIcePwdForGstreamer(processedOffer);
      if (sanitized != processedOffer) {
        _log('Sanitized ice-pwd for GStreamer');
      }
      processedOffer = sanitized;

      // 2b. GFN offers carry NO direction attributes on their media m-lines
      //     (RFC 3264 default sendrecv), but webrtcbin 1.28 does not apply the
      //     default — it answers m=video 0 (rejected media) and the server
      //     never sends video. Mark video/audio a=sendonly so webrtcbin
      //     answers a=recvonly (verified against webrtcbin 1.28.5).
      final directed = GfnSdpMunger.addMediaDirection(processedOffer);
      if (directed != processedOffer) {
        _log('Marked media sections a=sendonly for webrtcbin');
      }
      processedOffer = directed;

      // 3. GStreamer answers the offer (set-remote-description -> create-answer
      //    -> set-local-description, all on the bridge's loop thread). ICE
      //    gathering starts as soon as the local description is set.
      _log('--- GStreamer offer (m-lines) ---');
      for (final line in processedOffer.split('\n')) {
        if (line.startsWith('m=') ||
            line.startsWith('a=sendonly') ||
            line.startsWith('a=recvonly') ||
            line.startsWith('a=sendrecv') ||
            line.startsWith('a=inactive')) {
          _log('  $line');
        }
      }
      // Diagnostics: persist full SDPs for offline inspection.
      try {
        final dir = await getTemporaryDirectory();
        final diag = Directory('${dir.path}/gfn_diag');
        await diag.create(recursive: true);
        File('${diag.path}/offer.sdp').writeAsStringSync(processedOffer);
      } catch (_) {}
      final answerSdp = bridge.setRemoteOffer(processedOffer);
      if (answerSdp == null) {
        throw Exception('GStreamer answer negotiation failed');
      }
      try {
        final dir = await getTemporaryDirectory();
        final diag = Directory('${dir.path}/gfn_diag');
        await diag.create(recursive: true);
        File('${diag.path}/raw_answer.sdp').writeAsStringSync(answerSdp);
      } catch (_) {}
      _log('--- GStreamer raw answer (m-lines) ---');
      for (final line in answerSdp.split('\n')) {
        if (line.startsWith('m=') ||
            line.startsWith('a=sendonly') ||
            line.startsWith('a=recvonly') ||
            line.startsWith('a=sendrecv') ||
            line.startsWith('a=inactive')) {
          _log('  $line');
        }
      }
      // Constant quality also lifts the SDP b=AS cap so the server isn't
      // limited to the slider ceiling on top of the disabled BWE.
      final answerCapKbps = settings.optConstantQuality
          ? 200000
          : streamSettings.maxBitrateMbps * 1000;
      final munged = GfnSdpMunger.mungeAnswerSdp(answerSdp, answerCapKbps);
      // webrtcbin's raw answer excludes video/audio from the BUNDLE group and
      // echoes the server's own ICE creds into media sections — reshape it
      // into a libwebrtc-shaped answer (one bundle, client creds everywhere).
      // Also fixes nvstSdp extraction: extractIceCredentials must see the
      // client's creds, not the server's echoed ones, or ICE validation fails.
      var gfnAnswer = GfnSdpMunger.mungeAnswerForGfn(munged);
      if (gfnAnswer == munged) {
        _log('Warning: answer has no SCTP transport — bundle/creds fix skipped');
      }
      // webrtcbin 1.28 does NOT echo the offer's transport-cc extmap, ICE
      // options, rtcp-rsize, or msid-semantic — OpenNOW's working answer has
      // all four, and the GFN video sender builds BWE on transport-cc, so
      // without extmap:3 in the answer video is withheld (audio has no such
      // requirement). Re-insert them echoing the offer's extmap:3 URI.
      final withExtras = GfnSdpMunger.mungeAnswerTransportExtras(
        gfnAnswer,
        processedOffer,
      );
      if (withExtras != gfnAnswer) {
        _log('Added transport extras to answer (extmap:3 transport-cc, '
            'ice-options:trickle, rtcp-rsize, msid-semantic — OpenNOW parity)');
        gfnAnswer = withExtras;
      }
      _log('--- raw answer video payloads ---');
      for (final line in answerSdp.split('\n')) {
        if (line.startsWith('m=video') || line.startsWith('a=rtpmap:')) {
          _log('  $line');
        }
      }
      // webrtcbin drops the offer's RTX payloads from its answer (verified on
      // 1.28.5: answers 96 101 [98] even when the offer lists 96 101 97 102
      // 98). NVIDIA's streamer builds its video sender around the FID group
      // and never sends video unless rtx is accepted, so re-add them from the
      // offer and drop flexfec-03 (which webrtcbin cannot consume).
      final withRtx = GfnSdpMunger.restoreVideoRtx(gfnAnswer, processedOffer);
      if (withRtx != gfnAnswer) {
        _log('Restored RTX payloads into answer video m-line '
            '(webrtcbin dropped them; NVIDIA needs FID/rtx to start video)');
        gfnAnswer = withRtx;
      } else {
        _log('Answer video m-line unchanged — no RTX payloads to restore');
      }
      _log('--- final answer video payloads ---');
      for (final line in gfnAnswer.split('\n')) {
        if (line.startsWith('m=video') || line.startsWith('a=rtpmap:')) {
          _log('  $line');
        }
      }
      _log('Answer created (${gfnAnswer.length} chars)');

      // 4. Build + send nvstSdp from the answer's ICE credentials.
      final credentials = GfnSdpMunger.extractIceCredentials(gfnAnswer);
      final dims = GfnSdpMunger.parseResolution(streamSettings.resolution);
      final nvstSdp = GfnSdpMunger.buildNvstSdp(
        width: dims.$1,
        height: dims.$2,
        fps: streamSettings.fps,
        maxBitrateKbps: streamSettings.maxBitrateMbps * 1000,
        codec: codec,
        colorQuality: streamSettings.colorQuality.wireValue,
        credentials: credentials,
        caps: _inputCaps,
        priority: settings.streamPriorityEnabled
            ? settings.streamPriority
            : StreamPriority.quality,
        // Experimental optimizations (all optional, default = safe profile).
        // Mirrors WebRtcStreamSession so both transports negotiate the same
        // server profile.
        lowLatencyMode: settings.optLowLatencyMode,
        recoveryProfile: settings.optRecoveryProfile,
        minBitrateKbps: settings.optMinBitrateKbps,
        enableNack: settings.optEnableNack,
        enableFec: settings.optEnableFec,
        constantQuality: settings.optConstantQuality,
      );
      _log('nvstSdp: codec=$codec ${dims.$1}x${dims.$2}@${streamSettings.fps}fps '
          'max=${streamSettings.maxBitrateMbps}Mbps ufrag=${credentials.ufrag} '
          'pwd=${credentials.pwd} fp=${credentials.fingerprint}');
      await _signaling?.sendAnswer(
        SendAnswerRequest(sdp: gfnAnswer, nvstSdp: nvstSdp),
      );
      _answerOnWire = true;
      _log('Answer sent with nvstSdp (${gfnAnswer.length} chars)');

      // 5. Flush remote candidates queued before the offer was applied.
      if (_queuedRemoteCandidates.isNotEmpty) {
        for (final c in _queuedRemoteCandidates) {
          bridge.addRemoteIce(c.candidate, c.sdpMid, c.sdpMLineIndex);
        }
        _queuedRemoteCandidates.clear();
      }
      // 6. Flush local ICE candidates gathered before the answer.
      if (_queuedLocalIce.isNotEmpty) {
        _log('Flushing ${_queuedLocalIce.length} queued local ICE candidates');
        for (final c in _queuedLocalIce) {
          await _signaling?.sendIceCandidate(c);
        }
        _queuedLocalIce.clear();
      }
    } catch (e) {
      _answerSent = false;
      _answerOnWire = false;
      _log('Answer negotiation failed: $e');
    }
  }

  void _onLocalIceCandidate(int mlineIndex, String candidate) {
    if (_disposed) return;
    log.log(
      LogLevel.debug,
      'gstbridge',
      'local ICE candidate mline=$mlineIndex: $candidate',
    );
    final payload = IceCandidatePayload(
      candidate: candidate,
      sdpMid: null,
      sdpMLineIndex: mlineIndex,
      usernameFragment: null,
    );
    if (!_answerOnWire) {
      _queuedLocalIce.add(payload);
      return;
    }
    _signaling?.sendIceCandidate(payload);
  }

  // ---------------------------------------------------------------------
  // Video frames (bridge callback -> ui.Image)
  // ---------------------------------------------------------------------

  void _onNativeFrame(int width, int height, int stride,
      ffi.Pointer<ffi.Uint8> rgba, int rtpTimestamp) {
    // The bridge handed us a malloc'd RGBA copy; copy it into a Dart-owned
    // buffer, free the C buffer, then decode.
    final rowBytes = width * 4;
    final total = stride > 0 && height > 0 ? stride * height : 0;
    if (total <= 0) {
      _bridge?.freePtr(rgba.cast());
      return;
    }
    final copy = Uint8List(total);
    copy.setAll(0, rgba.asTypedList(total));
    _bridge?.freePtr(rgba.cast());

    // RGBA is tightly packed here (stride may be padded to a GPU alignment) —
    // strip padding rows so decodeImageFromPixels gets rowBytes == width*4.
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
    _established = true;
    _videoWidth = width;
    _videoHeight = height;
    final seq = ++_frameSeq;
    ui.decodeImageFromPixels(
      packed,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (img) {
        // Only display the newest completed decode; older completions are
        // dropped (the image is GC-reclaimed).
        if (seq <= _lastShownSeq) return;
        _lastShownSeq = seq;
        frameImage.value = img;
      },
    );
  }

  // ---------------------------------------------------------------------
  // Input channels + handshake (mirrors the libwebrtc session)
  // ---------------------------------------------------------------------

  void _onChannelState(int channel, bool open) {
    if (channel == 1) {
      _reliableInputOpen = open;
      if (open) _log('Reliable input channel open');
    } else if (channel == 2) {
      _partiallyReliableInputOpen = open;
      if (open) {
        _log('Partially reliable input channel open');
      }
    }
  }

  void _onChannelMessage(int channel, Uint8List bytes) {
    if (bytes.length < 2 || channel != 1) return;
    if (_inputReady) return; // post-handshake messages: telemetry, ignore

    final view = ByteData.sublistView(bytes);
    final firstWord = view.getUint16(0, Endian.little);
    var version = 2;

    if (firstWord == 526) {
      version = bytes.length >= 4 ? view.getUint16(2, Endian.little) : 2;
    } else if (bytes[0] == 0x0e) {
      version = firstWord;
    } else {
      return; // Not a handshake.
    }

    _inputEncoder.clock.start();
    _inputReady = true;
    _inputEncoder.setProtocolVersion(version);
    _log('Input handshake complete (protocol v$version) — starting heartbeat');
    _startInputHeartbeat();
    if (_gamepadTouched) _sendLatchedGamepadState();
  }

  void _startInputHeartbeat() {
    _inputHeartbeatTimer?.cancel();
    _inputHeartbeatTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_inputReady) return;
      _bridge?.sendInput(_inputEncoder.encodeHeartbeat(), reliable: true);
    });
  }

  // --- Send helpers ---------------------------------------------------------

  void _sendReliable(Uint8List payload) {
    if (!_reliableInputOpen) return;
    _bridge?.sendInput(payload, reliable: true);
  }

  void _sendPartiallyReliable(Uint8List payload) {
    if (_partiallyReliableInputOpen) {
      _bridge?.sendInput(payload, reliable: false);
      return;
    }
    _sendReliable(payload);
  }

  @override
  void sendText(String text) {
    if (!_inputReady || text.isEmpty) return;
    for (final chunk in _inputEncoder.encodeTextInput(text)) {
      _sendReliable(chunk);
    }
  }

  bool _canUsePartiallyReliableGamepad(int controllerId) {
    final mask = 1 << (controllerId & 0x1f);
    return _partiallyReliableInputOpen &&
        (_inputCaps.enablePartiallyReliableTransferGamepad & mask) != 0;
  }

  bool _canUsePartiallyReliableInput(int inputType) {
    if (!_partiallyReliableInputOpen) return false;
    if (inputType != inputMouseRel && inputType != inputMouseAbs) return false;
    final hidMask = 1 << inputType;
    if (hidMask == 0 || (_inputCaps.hidDeviceMask & hidMask) == 0) return false;
    return (_inputCaps.enablePartiallyReliableTransferHid & hidMask) != 0;
  }

  // --- Input API (interface) ------------------------------------------------

  @override
  void sendKeyEvent(KeyEvent event) {
    if (!_inputReady) return;
    if (event is KeyRepeatEvent) return;

    final mapped = mapFlutterKeyEvent(event);
    if (mapped == null) {
      if (event is KeyDownEvent) {
        log.log(
          LogLevel.debug,
          'gstbridge',
          '[input] key not mapped (dropped): hid=0x'
              '${event.physicalKey.usbHidUsage.toRadixString(16)}',
        );
      }
      return;
    }

    final timestampUs = _inputEncoder.clock.captureTimestampUs();
    final modifiers = modifierFlagsForKeyEvent(event);

    if (event is KeyUpEvent) {
      _sendReliable(_inputEncoder.encodeKeyUp(
        keycode: mapped.keycode,
        scancode: mapped.scancode,
        modifiers: modifiers,
        timestampUs: timestampUs,
      ));
    } else if (event is KeyDownEvent) {
      _sendReliable(_inputEncoder.encodeKeyDown(
        keycode: mapped.keycode,
        scancode: mapped.scancode,
        modifiers: modifiers,
        timestampUs: timestampUs,
      ));
    }

    if (event is KeyDownEvent && isLockKeyEvent(event)) {
      if (_lockKeys.toggleFor(event)) {
        _sendReliable(_inputEncoder.encodeLockKeysSync(_lockKeys.protocolBits));
      }
    }
  }

  @override
  void sendMouseMove({required int dx, required int dy}) {
    if (!_inputReady) return;
    final payload = _inputEncoder.encodeMouseMove(
      dx: dx,
      dy: dy,
      timestampUs: _inputEncoder.clock.captureTimestampUs(),
    );
    if (_canUsePartiallyReliableInput(inputMouseRel)) {
      _sendPartiallyReliable(payload);
    } else {
      _sendReliable(payload);
    }
  }

  @override
  void sendMouseAbsolute({
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    // No cursor overlay on the webrtcbin-FFI bridge; cursor stays
    // server-rendered, so relative moves only.
  }

  @override
  void sendMouseButton({required bool down, required int button}) {
    if (!_inputReady) return;
    final ts = _inputEncoder.clock.captureTimestampUs();
    final payload = down
        ? _inputEncoder.encodeMouseButtonDown(button: button, timestampUs: ts)
        : _inputEncoder.encodeMouseButtonUp(button: button, timestampUs: ts);
    _sendReliable(payload);
  }

  @override
  void sendMouseWheel({required int delta}) {
    if (!_inputReady) return;
    _sendReliable(_inputEncoder.encodeMouseWheel(
      delta: delta,
      timestampUs: _inputEncoder.clock.captureTimestampUs(),
    ));
  }

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
  }) {
    _gamepadTouched = true;
    _lastGamepadButtons = buttons;
    _lastLx = leftStickX;
    _lastLy = leftStickY;
    _lastRx = rightStickX;
    _lastRy = rightStickY;
    _lastLt = leftTrigger;
    _lastRt = rightTrigger;
    _gamepadBitmap |= (1 << controllerId) | (1 << (controllerId + 8));
    if (!_inputReady) return;
    _sendLatchedGamepadState();
  }

  void _sendLatchedGamepadState() {
    final usePr = _canUsePartiallyReliableGamepad(0);
    final payload = _inputEncoder.encodeGamepadState(
      controllerId: 0,
      buttons: _lastGamepadButtons,
      leftTrigger: normalizeToUint8(_lastLt),
      rightTrigger: normalizeToUint8(_lastRt),
      leftStickX: normalizeToInt16(_lastLx),
      leftStickY: normalizeToInt16(_lastLy),
      rightStickX: normalizeToInt16(_lastRx),
      rightStickY: normalizeToInt16(_lastRy),
      bitmap: _gamepadBitmap,
      usePartiallyReliable: usePr,
    );
    if (usePr) {
      _sendPartiallyReliable(payload);
    } else {
      _sendReliable(payload);
    }
  }

  // ---------------------------------------------------------------------
  // Stats polling (synthesized from bridge counters)
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
        connectionState: _established ? 'connected' : _lastConnectionState,
        inputReady: _inputReady,
        reliableInputOpen: _reliableInputOpen,
        partiallyReliableInputOpen: _partiallyReliableInputOpen,
        rendererHasVideo: rendererHasVideo,
        framesReceived: frames,
        framesDecoded: frames,
        decodeFps: decodeFps.toDouble(),
        receivedFps: decodeFps.toDouble(),
        videoWidth: _videoWidth,
        videoHeight: _videoHeight,
        codecMime: null,
        decoderImplementation: 'GStreamerWebrtcBin',
      );
    } catch (e) {
      log.log(LogLevel.debug, 'gstbridge', 'stats poll failed: $e');
    } finally {
      _statsPollInFlight = false;
    }
  }

  // ---------------------------------------------------------------------
  // Video surface
  // ---------------------------------------------------------------------

  @override
  Widget buildVideoView({required Widget placeholder}) {
    return _GstVideoView(transport: this, placeholder: placeholder);
  }

  // ---------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _signaling?.disconnect();
    _signaling = null;

    _statsTimer?.cancel();
    _statsTimer = null;
    stats.value = null;

    _inputHeartbeatTimer?.cancel();
    _inputHeartbeatTimer = null;
    _inputReady = false;

    final bridge = _bridge;
    _bridge = null;
    bridge?.dispose();
    frameImage.value = null;
    _log('GStreamer bridge torn down');
  }
}

/// RawImage-backed video surface fed by the transport's decoded frames.
class _GstVideoView extends StatelessWidget {
  final WebRtcBinFfiTransport transport;
  final Widget placeholder;

  const _GstVideoView({required this.transport, required this.placeholder});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: transport.frameImage,
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
}


