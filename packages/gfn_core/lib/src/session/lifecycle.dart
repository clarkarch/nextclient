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
      // If force-new was requested, stop existing active sessions first
      // (mirrors OpenNOW's stopActiveSessionsForCreate).
      if (request.existingSessionStrategy == ExistingSessionStrategy.forceNew) {
        final token = request.token ?? await getToken();
        final base = request.streamingBaseUrl ?? 'https://prod.cloudmatchbeta.nvidiagrid.net';
        try {
          await stopActiveSessionsForCreate(
            token: token,
            streamingBaseUrl: base,
            zone: request.zone,
            appId: request.appId,
          );
        } catch (_) {}
      }
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
        final polled = await cloudMatch.pollSession(SessionPollRequest(
          token: token,
          streamingBaseUrl: request.streamingBaseUrl,
          serverIp: info.serverIp,
          zone: request.zone,
          sessionId: info.sessionId,
          clientId: info.clientId,
          deviceId: info.deviceId,
        ));
        // Poll responses may drop ad creatives (sessionAds=null after the
        // first poll). Merge so queue ads don't vanish — matches OpenNOW's
        // mergePolledSessionState. Merge with the local `info` — reading
        // `_session!` here races with a concurrent stop() nulling it.
        info = mergePolledSessionState(info, polled);
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

  /// Resume/claim an existing session (e.g. after the app restarted).
  Future<SessionInfo> resume(SessionClaimRequest request) async {
    if (_state == SessionState.requesting ||
        _state == SessionState.queued ||
        _state == SessionState.allocating) {
      throw StateError('A session launch is already in progress');
    }

    _lastError = null;
    _transition(SessionState.requesting, 'Resuming session');

    try {
      final info = await cloudMatch.claimSession(request);
      _session = info;
      if (info.status == 2 || info.status == 3) {
        _transition(SessionState.ready, 'Session resumed', data: {
          'sessionId': info.sessionId,
          'signalingUrl': info.signalingUrl,
          'serverIp': info.serverIp,
        });
      } else {
        _transition(
          SessionState.error,
          'Session resumed with status ${info.status}',
          data: {'status': info.status},
        );
        throw StateError('Session resumed with status ${info.status}');
      }
      return info;
    } catch (error) {
      _lastError = error.toString();
      _transition(SessionState.error, _lastError!);
      rethrow;
    }
  }

  /// Port of sessionLifecycle.ts stopActiveSessionsForCreate
  Future<void> stopActiveSessionsForCreate({
    required String token,
    required String streamingBaseUrl,
    required String zone,
    required String appId,
  }) async {
    final activeSessions = await cloudMatch.getActiveSessions(
      token: token,
      streamingBaseUrl: streamingBaseUrl,
    );
    final sessionsToStop = activeSessions.where(isActiveCreateSessionConflict).toList();
    if (sessionsToStop.isEmpty) return;
    for (final s in sessionsToStop) {
      final serverIp = s.serverIp;
      if (serverIp == null || serverIp.isEmpty) continue;
      try {
        await cloudMatch.stopSession(SessionStopRequest(
          token: token,
          streamingBaseUrl: streamingBaseUrl,
          serverIp: serverIp,
          zone: zone,
          sessionId: s.sessionId,
        ));
      } catch (_) {
        // best-effort — match OpenNOW which continues on single stop failure
      }
    }
  }

  void reset() {
    _state = SessionState.idle;
    _session = null;
    _lastError = null;
  }
}