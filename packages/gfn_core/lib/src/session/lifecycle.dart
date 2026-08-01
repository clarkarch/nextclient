import '../cloudmatch/cloudmatch_service.dart';
import '../models/session.dart';

// Session lifecycle state machine (v0.01: no video/input).
// Mirrors the flow OpenNOW drives in the renderer:
//   requested -> queued -> allocated -> ready

enum SessionState { idle, requesting, queued, allocating, ready, error }

class SessionPhaseEvent {
  final SessionState from;
  final SessionState to;
  final String message;
  final DateTime timestamp;
  final Map<String, dynamic>? data;

  const SessionPhaseEvent({
    required this.from,
    required this.to,
    required this.message,
    required this.timestamp,
    this.data,
  });
}

typedef SessionLogFn = void Function(SessionPhaseEvent event);

class SessionLifecycle {
  final CloudMatchService cloudMatch;
  final void Function(SessionPhaseEvent event) onTransition;
  final Future<String> Function() getToken;

  SessionLifecycle({
    required this.cloudMatch,
    required this.onTransition,
    required this.getToken,
  });

  SessionState _state = SessionState.idle;
  SessionInfo? _session;
  String? _lastError;

  SessionState get state => _state;
  SessionInfo? get session => _session;
  String? get lastError => _lastError;

  void _transition(
    SessionState to,
    String message, {
    Map<String, dynamic>? data,
  }) {
    final from = _state;
    _state = to;
    onTransition(SessionPhaseEvent(
      from: from,
      to: to,
      message: message,
      timestamp: DateTime.now(),
      data: data,
    ));
  }

  /// Launch a game via CloudMatch createSession and poll to ready.
  Future<SessionInfo> launch(SessionCreateRequest request) async {
    if (_state == SessionState.requesting ||
        _state == SessionState.queued ||
        _state == SessionState.allocating) {
      throw StateError('A session launch is already in progress');
    }

    _lastError = null;
    _transition(SessionState.requesting, 'Requesting session');

    try {
      var info = await cloudMatch.createSession(request);
      _session = info;

      // Session status 1 = queuing/launching; 2/3 = ready.
      while (info.status == 1) {
        _transition(
          SessionState.queued,
          'Queued${info.queuePosition != null && info.queuePosition! > 1 ? ' (position ${info.queuePosition})' : ''}',
          data: {'queuePosition': info.queuePosition, 'seatSetupStep': info.seatSetupStep},
        );
        await Future<void>.delayed(const Duration(seconds: 1));

        final token = await getToken();
        info = await cloudMatch.pollSession(SessionPollRequest(
          token: token,
          streamingBaseUrl: request.streamingBaseUrl,
          serverIp: info.serverIp,
          zone: request.zone,
          sessionId: info.sessionId,
          clientId: info.clientId,
          deviceId: info.deviceId,
        ));
        _session = info;
      }

      if (info.status == 2 || info.status == 3) {
        _transition(SessionState.ready, 'Session ready', data: {
          'sessionId': info.sessionId,
          'signalingUrl': info.signalingUrl,
          'serverIp': info.serverIp,
        });
        return info;
      }

      _transition(
        SessionState.error,
        'Session ended with status ${info.status}',
        data: {'status': info.status},
      );
      throw StateError('Session ended with status ${info.status}');
    } catch (error) {
      _lastError = error.toString();
      _transition(SessionState.error, _lastError!);
      rethrow;
    }
  }

  /// Stop the current session.
  Future<void> stop() async {
    final session = _session;
    if (session == null) {
      _state = SessionState.idle;
      _session = null;
      return;
    }

    try {
      final token = await getToken();
      await cloudMatch.stopSession(SessionStopRequest(
        token: token,
        streamingBaseUrl: session.streamingBaseUrl,
        serverIp: session.serverIp,
        zone: session.zone,
        sessionId: session.sessionId,
        clientId: session.clientId,
        deviceId: session.deviceId,
      ));
    } finally {
      _session = null;
      _state = SessionState.idle;
    }
  }

  void reset() {
    _state = SessionState.idle;
    _session = null;
    _lastError = null;
  }
}