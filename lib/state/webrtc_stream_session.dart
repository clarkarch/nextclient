import 'dart:math' show max, min;

import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gfn_core/gfn_core.dart';

import 'user_settings.dart';

/// Bridges NVIDIA's NVST signaling WebSocket to a local [RTCPeerConnection]
/// and renders the incoming media into an [RTCVideoRenderer].
///
/// Lifecycle: [start] connects signaling + creates the peer connection, then
/// the NVST `offer`/`remoteIce` events drive the SDP/ICE exchange. The remote
/// video track is attached to [videoRenderer]. Call [dispose] to tear down.
///
/// The SDP/ICE exchange mirrors OpenNOW's `handleOffer()`: the offer is
/// rewritten (server-IP fix + codec filtering), input data channels are
/// negotiated, the answer is bitrate-munged, and the server-required
/// `nvstSdp` capability blob (built from the local ICE credentials) is sent
/// alongside the answer. Local ICE candidates are queued until the answer is
/// on the wire, then flushed (OpenNOW's trickle order).
class WebRtcStreamSession {
  final SessionInfo session;
  final UserSettings settings;
  final RingBufferLogSink log;

  final RTCVideoRenderer videoRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  GfnSignalingClient? _signaling;
  MediaStream? _remoteStream;
  bool _disposed = false;
  bool _answerSent = false;
  bool _rendererInitialized = false;

  /// True once the SDP handshake has completed and remote media is attached.
  /// Mirrors OpenNOW's `hasConfirmedRemoteIce` + ICE-state tracking: a
  /// signaling socket close after this point is expected, not an error.
  bool _established = false;

  // --- NVST handshake state (mirrors OpenNOW's handleOffer) ---
  bool _answerOnWire = false;
  final List<IceCandidatePayload> _queuedLocalIce = [];
  final List<IceCandidatePayload> _queuedRemoteCandidates = [];
  RTCDataChannel? _reliableInputChannel;
  RTCDataChannel? _partiallyReliableInputChannel;
  _RiInputCapabilities _inputCaps = const _RiInputCapabilities();

  static const int _defaultPartialReliableThresholdMs = 300;
  static const int _partiallyReliableGamepadMaskAll = (1 << 4) - 1;
  static const int _partiallyReliableHidDeviceMaskAll = 0xFFFFFFFF;
  static const int _officialMinBitrateKbps = 4000;
  static const int _highResolutionPixelCount = 2764800;
  static const int _highBitratePacingThresholdKbps = 42000;

  /// Fires with human-readable connection milestones (for the session panel).
  final ValueChanged<String>? onStatus;

  WebRtcStreamSession({
    required this.session,
    required this.settings,
    required this.log,
    this.onStatus,
  });

  void _log(String message) {
    log.log(LogLevel.info, 'webrtc', message);
    onStatus?.call(message);
  }

  Future<void> start() async {
    if (_disposed) return;
    await videoRenderer.initialize();
    _rendererInitialized = true;
    if (_disposed) return;

    final pc = await createPeerConnection(_buildConfiguration());
    if (_disposed) {
      await pc.close();
      return;
    }
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      final raw = candidate.candidate;
      if (raw == null || raw.isEmpty) return; // ICE gathering complete
      final payload = IceCandidatePayload(
        candidate: raw,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
        usernameFragment: null,
      );
      if (!_answerOnWire) {
        // The server only accepts trickle candidates after the answer —
        // queue them until the answer is sent (OpenNOW).
        _queuedLocalIce.add(payload);
        return;
      }
      _signaling?.sendIceCandidate(payload);
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        videoRenderer.srcObject = _remoteStream;
        _established = true;
        _log('Remote video track attached');
      }
    };

    pc.onConnectionState = (state) {
      _log('ICE connection state: ${state.name}');
    };

    _log('Signaling: ${session.signalingServer}');
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

  Future<void> _onSignalingEvent(MainToRendererSignalingEvent event) async {
    switch (event.type) {
      case MainToRendererSignalingEventType.offer:
        await _handleOffer(event.sdp!);
      case MainToRendererSignalingEventType.remoteIce:
        final candidate = event.candidate;
        if (candidate == null) return;
        final remoteDescription = await _pc?.getRemoteDescription();
        if (remoteDescription == null) {
          _queuedRemoteCandidates.add(candidate);
          return;
        }
        await _addRemoteCandidate(candidate);
      case MainToRendererSignalingEventType.connected:
        _log('Signaling connected');
      case MainToRendererSignalingEventType.disconnected:
        // NVIDIA closes the NVST signaling socket once the SDP/ICE handshake
        // completes (OpenNOW: `isExpectedNativeSessionClose` /
        // `ignore-active-ice`). Media keeps flowing over the established
        // WebRTC peer connection, so only treat a pre-handshake disconnect as
        // a real failure.
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
        log.log(LogLevel.debug, 'webrtc', event.message ?? '');
    }
  }

  Future<void> _handleOffer(String sdp) async {
    final pc = _pc;
    if (pc == null || _answerSent || _disposed) return;
    _answerSent = true;

    try {
      _log('Received offer SDP — negotiating');

      // Parse the offer's ri.* input-capability attributes so the data
      // channel + nvstSdp values match what the server advertised.
      _inputCaps = _parseRiInputCapabilities(sdp);

      // Negotiate the input data channels into the answer before the SDP
      // exchange (OpenNOW's createDataChannels).
      await _createDataChannels(pc);

      // 1. Point server ICE candidates at the WebRTC media endpoint from
      //    CloudMatch when one is present (usage 2 = WebRTC, 17 = WebRTC
      //    fallback), fixing any 0.0.0.0 placeholders in the offer.
      var processedOffer = sdp;
      final media = session.mediaConnectionInfo;
      if (media != null && (media.usage == 2 || media.usage == 17)) {
        final fixed = _fixServerIp(processedOffer, media.ip);
        if (fixed != processedOffer) {
          _log('Fixed server IP in SDP offer: ${media.ip}');
        }
        processedOffer = fixed;
      }

      // 2. Filter the offer to the requested codec so the negotiated codec
      //    matches what we advertise in nvstSdp.
      final streamSettings = settings.buildStreamSettings();
      final codec = _codecWireName(streamSettings.codec);
      final filtered = _preferCodec(processedOffer, codec);
      if (filtered != processedOffer) {
        _log('Filtered offer SDP to codec $codec');
      }
      processedOffer = filtered;

      await pc.setRemoteDescription(
        RTCSessionDescription(processedOffer, 'offer'),
      );
      _log('Remote description set');

      // Flush any remote candidates that raced ahead of the offer.
      if (_queuedRemoteCandidates.isNotEmpty) {
        for (final c in _queuedRemoteCandidates) {
          await _addRemoteCandidate(c);
        }
        _queuedRemoteCandidates.clear();
      }

      // 3. Create the answer, munge it (b=AS bitrate + stereo=1 opus), and
      //    set it locally. We send before ICE gathering completes and let
      //    trickle handle the rest, exactly like OpenNOW.
      var answer = await pc.createAnswer();
      final munged = _mungeAnswerSdp(
        answer.sdp ?? '',
        streamSettings.maxBitrateMbps * 1000,
      );
      answer = RTCSessionDescription(munged, 'answer');
      await pc.setLocalDescription(answer);

      final localDescription = await pc.getLocalDescription();
      final finalSdp = localDescription?.sdp ?? munged;
      if (finalSdp.isEmpty) {
        throw Exception('Missing local SDP after setLocalDescription');
      }
      _log('Answer created (${finalSdp.length} chars)');

      // 4. The server requires the nvstSdp capability blob, built from the
      //    ICE credentials in our own answer SDP.
      final credentials = _extractIceCredentials(finalSdp);
      final dims = _parseResolution(streamSettings.resolution);
      final nvstSdp = _buildNvstSdp(
        width: dims.$1,
        height: dims.$2,
        fps: streamSettings.fps,
        maxBitrateKbps: streamSettings.maxBitrateMbps * 1000,
        codec: codec,
        colorQuality: streamSettings.colorQuality.wireValue,
        credentials: credentials,
        caps: _inputCaps,
      );

      await _signaling?.sendAnswer(
        SendAnswerRequest(sdp: finalSdp, nvstSdp: nvstSdp),
      );
      _answerOnWire = true;
      _log('Answer sent with nvstSdp');

      // 5. Flush local ICE candidates that fired before the answer.
      if (_queuedLocalIce.isNotEmpty) {
        _log('Flushing ${_queuedLocalIce.length} queued local ICE candidates');
        for (final c in _queuedLocalIce) {
          await _signaling?.sendIceCandidate(c);
        }
        _queuedLocalIce.clear();
      }
    } catch (e) {
      // Allow a retransmitted offer to be answered on the next attempt.
      _answerSent = false;
      _answerOnWire = false;
      _log('Answer negotiation failed: $e');
    }
  }

  Future<void> _addRemoteCandidate(IceCandidatePayload candidate) async {
    try {
      await _pc?.addCandidate(RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      ));
    } catch (e) {
      _log('addCandidate failed: $e');
    }
  }

  Future<void> _createDataChannels(RTCPeerConnection pc) async {
    // If a previous negotiation attempt failed, close any channels created
    // then so a retransmitted offer doesn't leak them (OpenNOW re-creates
    // from scratch each handleOffer).
    try {
      _reliableInputChannel?.close();
      _partiallyReliableInputChannel?.close();
    } catch (_) {}
    _reliableInputChannel = null;
    _partiallyReliableInputChannel = null;

    try {
      final reliable = await pc.createDataChannel(
        'input_channel_v1',
        RTCDataChannelInit()..ordered = true,
      );
      reliable.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _log('Reliable input channel open');
        } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
          _log('Reliable input channel closed');
        }
      };
      reliable.onMessage = (event) {
        _log('Input channel message received (${event.isBinary ? 'binary' : 'text'})');
      };
      _reliableInputChannel = reliable;

      final pr = await pc.createDataChannel(
        'input_channel_partially_reliable',
        RTCDataChannelInit()
          ..ordered = false
          ..maxRetransmitTime = _inputCaps.partialReliableThresholdMs,
      );
      pr.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _log(
            'Partially reliable input channel open (maxPacketLifeTime=${_inputCaps.partialReliableThresholdMs} ms)',
          );
        } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
          _log('Partially reliable input channel closed');
        }
      };
      _partiallyReliableInputChannel = pr;
    } catch (e) {
      // Data channels are advisory for media; don't fail the handshake over
      // them, but surface it in the log.
      _log('Data channel setup failed (continuing): $e');
    }
  }

  /// Builds the RTCConfiguration map for flutter_webrtc, starting from the
  /// ICE servers NVIDIA handed us and overlaying the client-side WebRTC knobs
  /// exposed in advanced settings.
  Map<String, dynamic> _buildConfiguration() {
    final servers = <Map<String, dynamic>>[
      for (final s in session.iceServers)
        {
          'urls': s.urls,
          if (s.username != null) 'username': s.username,
          if (s.credential != null) 'credential': s.credential,
        },
    ];

    final custom = settings.webrtcStunServer.trim();
    if (custom.isNotEmpty) {
      servers.add({
        'urls': custom.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      });
    }
    if (servers.isEmpty) {
      servers.add({
        'urls': ['stun:stun.l.google.com:19302'],
      });
    }

    return {
      'iceServers': servers,
      'iceTransportPolicy':
          settings.webrtcIceTransport == WebrtcIceTransportPolicy.relay
          ? 'relay'
          : 'all',
      'iceCandidatePoolSize': settings.webrtcIcePoolSize,
      'bundlePolicy': switch (settings.webrtcBundle) {
        WebrtcBundlePolicy.balanced => 'balanced',
        WebrtcBundlePolicy.maxCompat => 'max-compat',
        WebrtcBundlePolicy.maxBundle => 'max-bundle',
      },
      'rtcpMuxPolicy': switch (settings.webrtcRtcpMux) {
        WebrtcRtcpMuxPolicy.require => 'require',
        WebrtcRtcpMuxPolicy.negotiate => 'negotiate',
      },
      'enableHardwareAcceleration': settings.webrtcHwAccel,
      'sdpSemantics': 'unified-plan',
    };
  }

  // ---------------------------------------------------------------------
  // NVST SDP helpers — ports of OpenNOW's sdp/{ice,codec,answer,nvstOffer}.ts
  // ---------------------------------------------------------------------

  String _codecWireName(VideoCodec codec) => switch (codec) {
        VideoCodec.h264 => 'H264',
        VideoCodec.h265 => 'H265',
        VideoCodec.av1 => 'AV1',
      };

  String _normalizeCodec(String name) {
    final upper = name.toUpperCase();
    return upper == 'HEVC' ? 'H265' : upper;
  }

  (int, int) _parseResolution(String resolution) {
    final parts = resolution.split('x');
    final width = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
    final height = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
    if (width <= 0 || height <= 0) return (1920, 1080);
    return (width, height);
  }

  _RiInputCapabilities _parseRiInputCapabilities(String sdp) {
    int? threshold() {
      final match = RegExp(
        r'a=ri\.partialReliableThresholdMs:(\d+)',
        caseSensitive: false,
      ).firstMatch(sdp);
      if (match == null) return null;
      final parsed = int.tryParse(match.group(1) ?? '') ?? 0;
      if (parsed <= 0) return null;
      return max(1, min(5000, parsed));
    }

    int attr(String name, int fallback) {
      final match = RegExp(
        'a=${RegExp.escape(name)}:([^\\r\\n]+)',
        caseSensitive: false,
      ).firstMatch(sdp);
      final raw = match?.group(1)?.trim();
      if (raw == null) return fallback;
      final normalized = raw.toLowerCase();
      final parsed = normalized.startsWith('0x')
          ? int.tryParse(normalized.substring(2), radix: 16)
          : int.tryParse(normalized);
      return parsed ?? fallback;
    }

    return _RiInputCapabilities(
      partialReliableThresholdMs: threshold() ??
          _defaultPartialReliableThresholdMs,
      hidDeviceMask: attr(
        'ri.hidDeviceMask',
        _partiallyReliableHidDeviceMaskAll,
      ),
      enablePartiallyReliableTransferGamepad: attr(
        'ri.enablePartiallyReliableTransferGamepad',
        _partiallyReliableGamepadMaskAll,
      ),
      enablePartiallyReliableTransferHid: attr(
        'ri.enablePartiallyReliableTransferHid',
        _partiallyReliableHidDeviceMaskAll,
      ),
    );
  }

  /// Extract a server-IP hint from a dash-separated GFN hostname, e.g.
  /// "80-250-97-40.cloudmatchbeta.nvidiagrid.net" -> "80.250.97.40".
  String? _extractPublicIp(String hostOrIp) {
    if (hostOrIp.isEmpty) return null;
    if (RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(hostOrIp)) {
      return hostOrIp;
    }
    final firstLabel = hostOrIp.split('.').first;
    final parts = firstLabel.split('-');
    if (parts.length == 4 && parts.every((p) => RegExp(r'^\d{1,3}$').hasMatch(p))) {
      return parts.join('.');
    }
    return null;
  }

  /// Rewrite 0.0.0.0 ICE candidate addresses with the actual server IP.
  String _fixServerIp(String sdp, String serverIp) {
    final ip = _extractPublicIp(serverIp);
    if (ip == null) return sdp;
    final re = RegExp(
      r'(a=candidate:\S+\s+\d+\s+\w+\s+\d+\s+)0\.0\.0\.0(\s+)',
    );
    final count = re.allMatches(sdp).length;
    if (count == 0) return sdp;
    return sdp.replaceAllMapped(
      re,
      (m) => '${m.group(1)}$ip${m.group(2)}',
    );
  }

  /// Port of OpenNOW's preferCodec(): hard-filter the offer SDP down to the
  /// requested video codec so the negotiated answer matches nvstSdp.
  String _preferCodec(String sdp, String codec) {
    final normalized = _normalizeCodec(codec);
    final lineEnding = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(RegExp(r'\r?\n'));

    final payloadTypesByCodec = <String, List<String>>{};
    final codecByPayloadType = <String, String>{};
    final rtxAptByPayloadType = <String, String>{};

    var inVideo = false;
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        inVideo = true;
        continue;
      }
      if (line.startsWith('m=') && inVideo) inVideo = false;
      if (!inVideo || !line.startsWith('a=rtpmap:')) continue;

      final parts = line.substring('a=rtpmap:'.length).split(RegExp(r'\s+'));
      final pt = parts.isNotEmpty ? parts[0] : '';
      final codecName = _normalizeCodec(
        (parts.length > 1 ? parts[1].split('/').first : '').trim(),
      );
      if (pt.isEmpty || codecName.isEmpty) continue;
      (payloadTypesByCodec[codecName] ??= []).add(pt);
      codecByPayloadType[pt] = codecName;
    }

    inVideo = false;
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        inVideo = true;
        continue;
      }
      if (line.startsWith('m=') && inVideo) inVideo = false;
      if (!inVideo || !line.startsWith('a=fmtp:')) continue;

      final parts = line.substring('a=fmtp:'.length).split(RegExp(r'\s+'));
      final pt = parts.isNotEmpty ? parts[0] : '';
      final params = parts.length > 1 ? parts[1] : '';
      if (pt.isEmpty || params.isEmpty) continue;
      final apt = RegExp(r'(?:^|;)\s*apt=(\d+)', caseSensitive: false)
          .firstMatch(params)
          ?.group(1);
      if (apt != null) rtxAptByPayloadType[pt] = apt;
    }

    final preferredPayloads = payloadTypesByCodec[normalized] ?? [];
    if (preferredPayloads.isEmpty) return sdp;

    final preferred = preferredPayloads.toSet();
    final allowed = <String>{...preferred};
    // Keep RTX payloads linked to preferred payloads (apt mapping).
    for (final entry in rtxAptByPayloadType.entries) {
      if (preferred.contains(entry.value) &&
          codecByPayloadType[entry.key] == 'RTX') {
        allowed.add(entry.key);
      }
    }

    final filtered = <String>[];
    inVideo = false;
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        inVideo = true;
        final parts = line.split(RegExp(r'\s+'));
        final header = parts.take(3).toList();
        final available = parts.skip(3).where(allowed.contains).toList();
        final ordered = <String>[
          ...preferredPayloads.where(available.contains),
          ...available.where((pt) => !preferred.contains(pt)),
        ];
        filtered.add(ordered.isNotEmpty ? [...header, ...ordered].join(' ') : line);
        continue;
      }
      if (line.startsWith('m=') && inVideo) inVideo = false;
      if (inVideo &&
          (line.startsWith('a=rtpmap:') ||
              line.startsWith('a=fmtp:') ||
              line.startsWith('a=rtcp-fb:'))) {
        final pt = line.split(':').elementAtOrNull(1)?.split(RegExp(r'\s+')).first ?? '';
        if (pt.isNotEmpty && !allowed.contains(pt)) continue;
      }
      filtered.add(line);
    }

    return filtered.join(lineEnding);
  }

  /// Port of OpenNOW's mungeAnswerSdp(): inject b=AS bitrate limits after
  /// each m= line and add stereo=1 to the opus fmtp line.
  String _mungeAnswerSdp(String sdp, int maxBitrateKbps) {
    final lineEnding = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(RegExp(r'\r?\n'));
    final result = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      result.add(line);

      if (line.startsWith('m=video') || line.startsWith('m=audio')) {
        final bitrate = line.startsWith('m=video') ? maxBitrateKbps : 128;
        final next = i + 1 < lines.length ? lines[i + 1] : '';
        if (!next.startsWith('b=')) {
          result.add('b=AS:$bitrate');
        }
      }

      if (line.startsWith('a=fmtp:') &&
          line.contains('minptime=') &&
          !line.contains('stereo=1')) {
        result[result.length - 1] = '$line;stereo=1';
      }
    }

    return result.join(lineEnding);
  }

  _IceCredentials _extractIceCredentials(String sdp) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    String? valueOf(String prefix) {
      for (final line in lines) {
        if (line.startsWith(prefix)) {
          return line.substring(prefix.length).trim();
        }
      }
      return null;
    }

    return _IceCredentials(
      ufrag: valueOf('a=ice-ufrag:') ?? '',
      pwd: valueOf('a=ice-pwd:') ?? '',
      fingerprint: valueOf('a=fingerprint:sha-256 ') ?? '',
    );
  }

  /// Port of OpenNOW's buildNvstSdp(): the fake-SDP capability blob NVIDIA's
  /// streamer requires in the answer so it knows the client's viewport,
  /// bitrate budget, encoder preferences, and input-channel capabilities.
  String _buildNvstSdp({
    required int width,
    required int height,
    required int fps,
    required int maxBitrateKbps,
    required String codec,
    required String colorQuality,
    required _IceCredentials credentials,
    required _RiInputCapabilities caps,
  }) {
    final maxBitrate = max(_officialMinBitrateKbps, maxBitrateKbps.floor());
    final startupBitrate = max(
      _officialMinBitrateKbps,
      (maxBitrate / 4).round(),
    );
    final isHighFps = fps >= 90;
    final is90Fps = fps == 90;
    final is120Fps = fps == 120;
    final is240Fps = fps >= 240;
    final isAv1 = codec == 'AV1';
    final pixelCount = width * height;
    final useHighThroughputPacing = pixelCount >= _highResolutionPixelCount ||
        maxBitrate >= _highBitratePacingThresholdKbps;
    final supportsHighBitDepth = codec == 'H265' || codec == 'AV1';
    final bitDepth =
        supportsHighBitDepth && colorQuality.startsWith('10bit') ? 10 : 8;
    final minTargetFrameTimeUs = max(
      1000,
      (1000000 * 95 ~/ (max(1, fps) * 100)),
    );
    final hidDeviceMask = caps.hidDeviceMask;
    final enablePartiallyReliableTransferGamepad =
        caps.enablePartiallyReliableTransferGamepad;
    final enablePartiallyReliableTransferHid =
        caps.enablePartiallyReliableTransferHid;

    final lines = <String>[
      'v=0',
      'o=SdpTest test_id_13 14 IN IPv4 127.0.0.1',
      's=-',
      't=0 0',
      'a=general.icePassword:${credentials.pwd}',
      'a=general.iceUserNameFragment:${credentials.ufrag}',
      'a=general.dtlsFingerprint:${credentials.fingerprint}',
      'm=video 0 RTP/AVP',
      'a=msid:fbc-video-0',
      // Match the stable Android-native recovery profile. Large FEC/NACK
      // bursts amplify congestion after packet loss instead of letting BWE
      // recover.
      'a=vqos.fec.rateDropWindow:10',
      'a=vqos.fec.minRequiredFecPackets:2',
      'a=vqos.drc.minRequiredBitrateCheckEnabled:1',
      'a=vqos.fec.repairMinPercent:5',
      'a=vqos.fec.repairPercent:5',
      'a=vqos.fec.repairMaxPercent:35',
      // Official dynamicStreamingMode=0 path disables server resolution/FPS
      // switching.
      'a=vqos.dynamicStreamingMode:0',
      'a=vqos.drc.enable:0',
      'a=vqos.calculateAvgVideoStreamingBitrate:1',
    ];

    if (isHighFps) {
      lines.addAll([
        'a=vqos.dfc.enable:1',
        'a=vqos.dfc.decodeFpsAdjPercent:85',
        'a=vqos.dfc.targetDownCooldownMs:250',
        'a=vqos.dfc.dfcAlgoVersion:${is120Fps || is240Fps ? 2 : 1}',
        'a=vqos.dfc.minTargetFps:${is120Fps || is240Fps ? 100 : 60}',
        'a=vqos.resControl.dfc.useClientFpsPerf:0',
        'a=vqos.dfc.adjustResAndFps:0',
      ]);
    } else {
      lines.addAll([
        'a=vqos.dfc.enable:0',
        'a=vqos.dfc.adjustResAndFps:0',
      ]);
    }

    lines.addAll([
      'a=video.dx9EnableNv12:1',
      'a=video.dx9EnableHdr:1',
      'a=vqos.qpg.enable:1',
      'a=vqos.resControl.qp.qpg.featureSetting:7',
      'a=video.adaptiveQuantization.spatialAQSetting:7',
      'a=video.adaptiveQuantization.temporalAQSetting:0',
      'a=video.adaptiveQuantization.spatialAQStrength:12',
      'a=video.adaptiveQuantization.qpThresholdAdjPercent:2',
      'a=video.adaptiveQuantization.saqAdaptMinQpThresholdPercent:40',
      'a=video.adaptiveQuantization.saqAdaptMaxQpThresholdPercent:100',
      'a=video.adaptiveQuantization.saqAdaptDecayStrengthX100:250',
      'a=video.adaptiveQuantization.perfAdjEnablement:1',
      'a=video.framePacing.mode:2',
      'a=video.framePacing.pid.minTargetFrameTimeUs:$minTargetFrameTimeUs',
      'a=bwe.useOwdCongestionControl:1',
      'a=video.enableRtpNack:1',
      'a=vqos.bw.txRxLag.minFeedbackTxDeltaMs:200',
      'a=vqos.drc.bitrateIirFilterFactor:18',
      'a=video.packetSize:1140',
      // Official packet pacing profile (Nvsc dumps + DESCRIBE enableAccurateSleep).
      'a=packetPacing.version:3',
      'a=packetPacing.mode:1',
      'a=packetPacing.minNumPacketsPerGroup:15',
      'a=packetPacing.enableAccurateSleep:1',
      'a=packetPacing.enableSmoothTransition:1',
      'a=packetPacing.allowFpsBasedToggle:1',
      'a=vqos.relaxMaxBitrate.overrideAvgBitrateThresholdPercent:4',
      'a=vqos.relaxMaxBitrate.customAvgBitrateThresholdPercent:65',
      'a=vqos.relaxMaxBitrate.overrideAvgQpThresholdPercent:7',
      'a=vqos.relaxMaxBitrate.customAvgQpThresholdPercent:51',
      'a=vqos.relaxMaxBitrate.iirFilterFactor:120',
      'a=vqos.qpDelta.qpDeltaMaxPercent:10',
      'a=vqos.qpDelta.qpDeltaSurfaceAdjustmentStrengthPercent:70',
      'a=vqos.qpDelta.qpDeltaVbvUsageFactorPercentH264:100',
      'a=vqos.qpDelta.qpDeltaVbvUsageFactorPercentH265:100',
      'a=vqos.qpDelta.qpDeltaVbvUsageFactorPercentAv1:100',
      'a=vqos.qpDelta.qpDeltaMinPercent:60',
      'a=vqos.qpDelta.qpDeltaIirFactor:60',
      'a=vqos.qpDelta.qpDeltaThrottlePercent:100',
    ]);

    if (isHighFps) {
      lines.addAll([
        'a=bwe.iirFilterFactor:8',
        'a=video.encoderFeatureSetting:47',
        'a=video.encoderPreset:6',
        'a=vqos.resControl.cpmRtc.badNwSkipFramesCount:600',
        'a=vqos.resControl.cpmRtc.decodeTimeThresholdMs:${is90Fps ? 11 : 9}',
        'a=video.fbcDynamicFpsGrabTimeoutMs:${is90Fps ? 9 : is120Fps ? 6 : 18}',
        'a=vqos.resControl.cpmRtc.serverResolutionUpdateCoolDownCount:${is120Fps ? 6000 : 12000}',
      ]);
    }

    if (is240Fps) {
      lines.addAll([
        'a=video.enableNextCaptureMode:1',
        'a=vqos.maxStreamFpsEstimate:240',
        // Official 240 FPS DESCRIBE uses 63 strips (not the older web-client
        // value of 3).
        'a=video.videoSplitEncodeStripsPerFrame:63',
        'a=video.updateSplitEncodeStateDynamically:1',
        'a=vqos.rtcPreemptiveIdrSettings.minBurstNackSize:65535',
        'a=vqos.rtcPreemptiveIdrSettings.minNackPacketCaptureAgeMs:65535',
      ]);
    }

    lines.addAll([
      'a=vqos.adjustStreamingFpsDuringOutOfFocus:1',
      'a=vqos.resControl.cpmRtc.ignoreOutOfFocusWindowState:1',
      'a=vqos.resControl.perfHistory.rtcIgnoreOutOfFocusWindowState:1',
      // Disable CPM-based resolution changes (prevents SSRC switches).
      'a=vqos.resControl.cpmRtc.featureMask:0',
      'a=vqos.resControl.cpmRtc.enable:0',
      // Never scale down resolution.
      'a=vqos.resControl.cpmRtc.minResolutionPercent:100',
      // Infinite cooldown to prevent resolution changes.
      'a=vqos.resControl.cpmRtc.resolutionChangeHoldonMs:999999',
    ]);

    lines.addAll([
      'a=packetPacing.numGroups:${is120Fps ? 3 : 5}',
      'a=packetPacing.maxDelayUs:1000',
      'a=packetPacing.minNumPacketsFrame:10',
      'a=video.rtpNackQueueLength:1024',
      'a=video.rtpNackQueueMaxPackets:512',
      'a=video.rtpNackMaxPacketCount:25',
    ]);

    if (useHighThroughputPacing) {
      lines.add('a=vqos.drc.iirFilterFactor:100');
      if (!isAv1) {
        lines.addAll([
          'a=vqos.drc.qpMaxResThresholdAdj:4',
          'a=vqos.dfc.qpMaxResThresholdAdj:4',
          'a=vqos.grc.qpMaxResThresholdAdj:2',
        ]);
      }
    }

    if (isAv1) {
      final av1QpMaxResThresholdAdj = useHighThroughputPacing ? 20 : 0;
      lines.addAll([
        'a=vqos.drc.minQpHeadroom:20',
        'a=vqos.drc.lowerQpThreshold:100',
        'a=vqos.drc.upperQpThreshold:200',
        'a=vqos.drc.minAdaptiveQpThreshold:180',
        'a=vqos.drc.qpMaxResThresholdAdj:$av1QpMaxResThresholdAdj',
        'a=vqos.drc.qpCodecThresholdAdj:0',
        'a=vqos.dfc.minQpHeadroom:20',
        'a=vqos.dfc.qpLowerLimit:100',
        'a=vqos.dfc.qpMaxUpperLimit:200',
        'a=vqos.dfc.qpMinUpperLimit:180',
        'a=vqos.dfc.qpMaxResThresholdAdj:$av1QpMaxResThresholdAdj',
        'a=vqos.dfc.qpCodecThresholdAdj:0',
        'a=vqos.grc.minQpHeadroom:20',
        'a=vqos.grc.lowerQpThreshold:100',
        'a=vqos.grc.upperQpThreshold:200',
        'a=vqos.grc.minAdaptiveQpThreshold:180',
        'a=vqos.grc.qpMaxResThresholdAdj:$av1QpMaxResThresholdAdj',
        'a=vqos.grc.qpCodecThresholdAdj:0',
        'a=video.minQp:25',
        'a=video.enableAv1RcPrecisionFactor:1',
      ]);
    }

    lines.addAll([
      'a=video.clientViewportWd:$width',
      'a=video.clientViewportHt:$height',
      'a=video.maxFPS:$fps',
      'a=video.initialBitrateKbps:$startupBitrate',
      'a=video.initialPeakBitrateKbps:$startupBitrate',
      'a=vqos.bw.maximumBitrateKbps:$maxBitrate',
      'a=vqos.bw.minimumBitrateKbps:$_officialMinBitrateKbps',
      'a=vqos.bw.peakBitrateKbps:$maxBitrate',
      'a=vqos.bw.serverPeakBitrateKbps:$maxBitrate',
      'a=vqos.bw.enableBandwidthEstimation:1',
      'a=vqos.bw.disableBitrateLimit:0',
      'a=vqos.grc.maximumBitrateKbps:$maxBitrate',
      'a=vqos.grc.enable:0',
      'a=video.maxNumReferenceFrames:4',
      'a=video.mapRtpTimestampsToFrames:1',
      'a=video.encoderCscMode:3',
      'a=video.dynamicRangeMode:0',
      'a=video.bitDepth:$bitDepth',
      'a=video.scalingFeature1:${isAv1 ? 1 : 0}',
      'a=video.prefilterParams.prefilterModel:0',
      // Audio track (receive-only from server).
      'm=audio 0 RTP/AVP',
      'a=msid:audio',
      'a=aqos.enableRedundancy:1',
      'a=aqos.redundancyLevel:2',
      'a=aqos.enableRedundancyForMic:1',
      'a=aqos.redundancyLevelForMic:3',
      'a=audio.enableDynamicAudioConfig:1',
      'a=audio.enableTimestampAudioBuffer:1',
      // Mic track (send to server).
      'm=mic 0 RTP/AVP',
      'a=msid:mic',
      'a=rtpmap:0 PCMU/8000',
      // Input/application track.
      'm=application 0 RTP/AVP',
      'a=msid:input_1',
      'a=ri.partialReliableThresholdMs:${caps.partialReliableThresholdMs}',
      'a=ri.hidDeviceMask:$hidDeviceMask',
      'a=ri.enablePartiallyReliableTransferGamepad:$enablePartiallyReliableTransferGamepad',
      'a=ri.enablePartiallyReliableTransferHid:$enablePartiallyReliableTransferHid',
      'a=ri.timestampsEnabled:1',
      'a=ri.useMultipleGamepads:1',
      '',
    ]);

    return lines.join('\n');
  }

  /// Tears down signaling, the peer connection, and the renderer. Never
  /// throws: on desktop the native side releases remote streams when the peer
  /// connection closes, so a second `MediaStream.dispose()` throws
  /// `MediaStreamDisposeFailed` — that is caught and treated as done.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _signaling?.disconnect();
    _signaling = null;

    try {
      _reliableInputChannel?.close();
      _partiallyReliableInputChannel?.close();
    } catch (_) {}
    _reliableInputChannel = null;
    _partiallyReliableInputChannel = null;

    // Detach the renderer before the media graph is torn down.
    try {
      videoRenderer.srcObject = null;
    } catch (_) {}

    final stream = _remoteStream;
    _remoteStream = null;
    if (stream != null) {
      try {
        await stream.dispose();
      } catch (e) {
        // Already released by the platform — nothing left to do.
        log.log(LogLevel.debug, 'webrtc', 'Remote stream dispose skipped: $e');
      }
    }

    final pc = _pc;
    _pc = null;
    if (pc != null) {
      try {
        await pc.close();
      } catch (e) {
        log.log(LogLevel.debug, 'webrtc', 'Peer connection close failed: $e');
      }
    }

    if (_rendererInitialized) {
      try {
        await videoRenderer.dispose();
      } catch (e) {
        log.log(LogLevel.debug, 'webrtc', 'Renderer dispose failed: $e');
      }
      _rendererInitialized = false;
    }
  }
}

class _IceCredentials {
  final String ufrag;
  final String pwd;
  final String fingerprint;

  const _IceCredentials({
    required this.ufrag,
    required this.pwd,
    required this.fingerprint,
  });
}

/// Input-channel capabilities parsed from the offer's `ri.*` attributes
/// (port of OpenNOW's `RiInputCapabilities`). These are echoed back into the
/// `nvstSdp` so the streamer negotiates the same channels we created.
class _RiInputCapabilities {
  final int partialReliableThresholdMs;
  final int hidDeviceMask;
  final int enablePartiallyReliableTransferGamepad;
  final int enablePartiallyReliableTransferHid;

  const _RiInputCapabilities({
    this.partialReliableThresholdMs = 300,
    this.hidDeviceMask = 0xFFFFFFFF,
    this.enablePartiallyReliableTransferGamepad = 15,
    this.enablePartiallyReliableTransferHid = 0xFFFFFFFF,
  });
}
