import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:math' show Random;

import 'package:web_socket_channel/io.dart' show IOWebSocketChannel;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../http/client.dart' show gfnPlayOrigin, gfnUserAgentForPlatform;
import '../logging.dart' show LogLevel, LogSink;
import '../models/signaling_types.dart';

// Port of signaling.ts — NVIDIA's proprietary signaling WebSocket protocol.
// Message shapes must match OpenNOW exactly.

class GfnSignalingClient {
  final String signalingServer;
  final String sessionId;
  final String? signalingUrl;
  final bool isMac;
  final LogSink log;

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  int _peerId = 0;
  int _remotePeerId = 1;
  final String _peerName = 'peer-${Random().nextInt(1000000000)}';
  int _ackCounter = 0;
  int _connectionGeneration = 0;
  final List<void Function(MainToRendererSignalingEvent)> _listeners = [];

  GfnSignalingClient({
    required this.signalingServer,
    required this.sessionId,
    this.signalingUrl,
    this.isMac = false,
    required this.log,
  });

  void onEvent(void Function(MainToRendererSignalingEvent) listener) {
    _listeners.add(listener);
  }

  void _emit(MainToRendererSignalingEvent event) {
    for (final listener in _listeners) {
      listener(event);
    }
  }

  int _nextAckId() => ++_ackCounter;

  void _sendJson(Object payload) {
    final ws = _ws;
    if (ws == null) return;
    ws.sink.add(jsonEncode(payload));
  }

  String _buildSignInUrl() {
    final fallbackHost = signalingServer.contains(':')
        ? signalingServer
        : '$signalingServer:443';
    var baseUrl = (signalingUrl?.trim().isNotEmpty ?? false)
        ? signalingUrl!.trim()
        : 'wss://$fallbackHost/nvst/';

    // NVIDIA beta responses sometimes carry port 0 as a placeholder meaning
    // "use the default port". Port 0 is never connectable — normalize it.
    final parsed = Uri.tryParse(baseUrl);
    if (parsed != null && parsed.hasPort && parsed.port == 0) {
      baseUrl = parsed.replace(port: 443).toString();
    }

    final uri = Uri.parse(baseUrl);
    var path = uri.path;
    if (!path.endsWith('/')) path = '$path/';
    final url = uri.replace(
      scheme: 'wss',
      path: '$path' 'sign_in',
      queryParameters: {
        'peer_id': _peerName,
        'version': '2',
        'peer_role': '1',
        'pairing_id': sessionId,
      },
    );
    log.log(LogLevel.info, 'signaling', 'URL: $url (server: $signalingServer, signalingUrl: $signalingUrl)');
    return url.toString();
  }

  void _sendPeerInfo() {
    _sendJson({
      'ackid': _nextAckId(),
      'peer_info': {
        'browser': 'Chrome',
        'browserVersion': '131',
        'connected': true,
        'id': _peerId,
        'name': _peerName,
        'peerRole': 0,
        'resolution': '1920x1080',
        'version': 2,
      },
    });
  }

  Future<void> connect() async {
    final ws = _ws;
    if (ws != null) return;

    final url = _buildSignInUrl();
    final protocol = 'x-nv-sessionid.$sessionId';
    final generation = ++_connectionGeneration;

    log.log(LogLevel.info, 'signaling', 'Connecting to: $url');
    log.log(LogLevel.info, 'signaling', 'Session ID: $sessionId');
    log.log(LogLevel.info, 'signaling', 'Protocol: $protocol');

    final urlHost = url.replaceFirst(RegExp(r'^wss?://'), '').split('/').first;
    final channel = IOWebSocketChannel.connect(
      Uri.parse(url),
      // NVIDIA's NVST signaling endpoint requires the
      // `x-nv-sessionid.<sessionId>` subprotocol (Sec-WebSocket-Protocol);
      // without it the server rejects the upgrade with HTTP 400.
      protocols: [protocol],
      headers: {
        'Host': urlHost,
        'Origin': gfnPlayOrigin,
        'User-Agent': gfnUserAgentForPlatform(isMac: isMac),
      },
      pingInterval: null,
    );
    _ws = channel;

    final completer = Completer<void>();
    _subscription = channel.stream.listen(
      (raw) {
        if (!_isCurrentSocket(generation)) return;
        final text = raw is String ? raw : _decodeUtf8(raw);
        _handleMessage(text);
      },
      onError: (error) {
        if (!_isCurrentSocket(generation)) return;
        _emit(MainToRendererSignalingEvent(
          type: MainToRendererSignalingEventType.error,
          message: 'Signaling connect failed: $error',
        ));
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      onDone: () {
        _clearHeartbeat();
        if (!_isCurrentSocket(generation)) return;
        _ws = null;
        _emit(MainToRendererSignalingEvent(
          type: MainToRendererSignalingEventType.disconnected,
          reason: 'socket closed',
        ));
      },
    );

    // Wait for the underlying socket before declaring the channel connected.
    // Awaiting `ready` also gives a failed upgrade a listener, so its error is
    // delivered to [completer] instead of escaping as an unhandled async
    // exception (the stream's onError above reports it to the UI as well).
    try {
      await channel.ready;
    } catch (error) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
      return completer.future;
    }
    if (!_isCurrentSocket(generation)) {
      // Disconnected while the socket was coming up; don't leave the caller
      // awaiting a future that never completes.
      if (!completer.isCompleted) completer.complete();
      return completer.future;
    }

    _emit(MainToRendererSignalingEvent(
      type: MainToRendererSignalingEventType.connected,
    ));
    _sendPeerInfo();
    _setupHeartbeat();
    completer.complete();
    return completer.future;
  }

  bool _isCurrentSocket(int generation) {
    return _connectionGeneration == generation;
  }

  void _setupHeartbeat() {
    _clearHeartbeat();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _sendJson({'hb': 1});
    });
  }

  void _clearHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _handleMessage(String text) {
    Map<String, dynamic> parsed;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        parsed = decoded;
      } else {
        parsed = {};
      }
    } catch (_) {
      _emit(MainToRendererSignalingEvent(
        type: MainToRendererSignalingEventType.log,
        message: 'Ignoring non-JSON signaling packet: ${_snippet(text)}',
      ));
      return;
    }

    final peerInfo = parsed['peer_info'];
    if (peerInfo is Map) {
      final id = peerInfo['id'];
      if (id is num && peerInfo['name'] == _peerName) {
        _peerId = id.toInt();
        log.log(LogLevel.info, 'signaling', 'Local peer id assigned: $_peerId');
      }
    }

    final ackid = parsed['ackid'];
    if (ackid is num) {
      final shouldAck = peerInfo is! Map || (peerInfo['id'] as num?)?.toInt() != _peerId;
      if (shouldAck) {
        _sendJson({'ack': ackid.toInt()});
      }
    }

    if (parsed['hb'] is num) {
      _sendJson({'hb': 1});
      return;
    }

    if (parsed['error'] == 'peerRemoved') {
      log.log(LogLevel.info, 'signaling', 'Received peerRemoved signaling error');
      _emit(MainToRendererSignalingEvent(
        type: MainToRendererSignalingEventType.disconnected,
        reason: 'peerRemoved',
      ));
      return;
    }

    final peerMsg = parsed['peer_msg'];
    if (peerMsg is! Map) return;

    final from = peerMsg['from'];
    if (from is num) {
      _remotePeerId = from.toInt();
      log.log(LogLevel.info, 'signaling', 'Remote peer id: $_remotePeerId');
    }

    final peerMessage = (peerMsg['msg'] as String? ?? '').trim();
    if (peerMessage == 'BYE') {
      log.log(LogLevel.info, 'signaling', 'Received BYE peer message');
      _emit(MainToRendererSignalingEvent(
        type: MainToRendererSignalingEventType.disconnected,
        reason: 'BYE',
      ));
      return;
    }

    Map<String, dynamic> peerPayload;
    try {
      final decoded = jsonDecode(peerMessage);
      if (decoded is! Map<String, dynamic>) return;
      peerPayload = decoded;
    } catch (_) {
      _emit(MainToRendererSignalingEvent(
        type: MainToRendererSignalingEventType.log,
        message: 'Received non-JSON peer payload',
      ));
      return;
    }

    if (peerPayload['type'] == 'offer' && peerPayload['sdp'] is String) {
      final sdp = peerPayload['sdp'] as String;
      log.log(LogLevel.info, 'signaling', 'Received OFFER SDP (${sdp.length} chars)');
      _emit(MainToRendererSignalingEvent(
        type: MainToRendererSignalingEventType.offer,
        sdp: sdp,
      ));
      return;
    }

    if (peerPayload['candidate'] is String) {
      final candidate = peerPayload['candidate'] as String;
      final rawMLineIndex = peerPayload['sdpMLineIndex'];
      final sdpMLineIndex =
          rawMLineIndex is num ? rawMLineIndex.toInt() : 0;
      log.log(LogLevel.info, 'signaling', 'Received remote ICE candidate');
      _emit(MainToRendererSignalingEvent(
        type: MainToRendererSignalingEventType.remoteIce,
        candidate: IceCandidatePayload(
          candidate: candidate,
          sdpMid: peerPayload['sdpMid'] as String?,
          sdpMLineIndex: sdpMLineIndex,
          usernameFragment: peerPayload['usernameFragment'] as String?,
        ),
      ));
      return;
    }
  }

  Future<void> sendAnswer(SendAnswerRequest payload) async {
    final answer = {
      'type': 'answer',
      'sdp': payload.sdp,
      if (payload.nvstSdp != null) 'nvstSdp': payload.nvstSdp,
    };
    _sendJson({
      'peer_msg': {
        'from': _peerId,
        'to': _remotePeerId,
        'msg': jsonEncode(answer),
      },
      'ackid': _nextAckId(),
    });
  }

  Future<void> sendIceCandidate(IceCandidatePayload candidate) async {
    if (_isTcpIceCandidate(candidate.candidate)) {
      log.log(LogLevel.info, 'signaling', 'Dropping TCP local ICE candidate');
      return;
    }
    _sendJson({
      'peer_msg': {
        'from': _peerId,
        'to': _remotePeerId,
        'msg': jsonEncode({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'usernameFragment': candidate.usernameFragment,
        }),
      },
      'ackid': _nextAckId(),
    });
  }

  Future<void> requestKeyframe(KeyframeRequest payload) async {
    _sendJson({
      'peer_msg': {
        'from': _peerId,
        'to': _remotePeerId,
        'msg': jsonEncode({
          'type': 'request_keyframe',
          'reason': payload.reason,
          'backlogFrames': payload.backlogFrames,
          'attempt': payload.attempt,
        }),
      },
      'ackid': _nextAckId(),
    });
  }

  void disconnect() {
    _connectionGeneration++;
    _clearHeartbeat();
    _subscription?.cancel();
    _subscription = null;
    final ws = _ws;
    _ws = null;
    ws?.sink.close();
  }

  bool _isTcpIceCandidate(String candidate) {
    final parts = candidate.trim().split(RegExp(r'\s+'));
    return parts.length > 2 && parts[2].toLowerCase() == 'tcp';
  }

  String _decodeUtf8(dynamic raw) {
    if (raw is String) return raw;
    if (raw is List<int>) return utf8.decode(raw);
    return raw.toString();
  }

  String _snippet(String text) {
    return text.length > 120 ? text.substring(0, 120) : text;
  }
}