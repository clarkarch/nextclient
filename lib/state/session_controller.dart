import 'package:flutter/foundation.dart';
import 'package:gfn_core/gfn_core.dart';

/// ChangeNotifier bridge over [SessionLifecycle] so the UI can react to
/// launch progress (requesting → queued → allocating → ready → error).
class SessionController extends ChangeNotifier {
  final CloudMatchService cloudMatch;
  final Future<String> Function() getToken;
  final LogSink log;
  SessionLifecycle? _lifecycle;
  final List<SessionPhaseEvent> _events = [];

  SessionController({
    required this.cloudMatch,
    required this.getToken,
    required this.log,
  });

  SessionState get state =>
      _lifecycle?.state ?? SessionState.idle;
  SessionInfo? get session => _lifecycle?.session;
  String? get lastError => _lifecycle?.lastError;
  List<SessionPhaseEvent> get events => _events;

  SessionLifecycle _ensure() {
    var lc = _lifecycle;
    if (lc == null) {
      lc = SessionLifecycle(
        cloudMatch: cloudMatch,
        getToken: getToken,
        onTransition: (event) {
          _events.add(event);
          log.log(
            LogLevel.info,
            'session',
            '${event.from.name} → ${event.to.name}: ${event.message}',
          );
          notifyListeners();
        },
      );
      _lifecycle = lc;
    }
    return lc;
  }

  Future<SessionInfo> launch(SessionCreateRequest request) {
    log.log(
      LogLevel.info,
      'session',
      'Launching ${request.appId} '
          '(${request.settings.resolution} @ ${request.settings.fps}fps)',
    );
    final lifecycle = _ensure();
    notifyListeners();
    return lifecycle.launch(request);
  }

  Future<SessionInfo> resume(SessionClaimRequest request) {
    log.log(
      LogLevel.info,
      'session',
      'Resuming session [SESSION ID REDACTED] (${request.appId})',
    );
    final lifecycle = _ensure();
    notifyListeners();
    return lifecycle.resume(request);
  }

  Future<void> stop() async {
    final lc = _lifecycle;
    if (lc == null) {
      log.log(LogLevel.info, 'session', 'Stop requested but no active session');
      return;
    }
    log.log(LogLevel.info, 'session', 'Stopping session [SESSION ID REDACTED]');
    await lc.stop();
    log.log(LogLevel.info, 'session', 'Session stopped');
    notifyListeners();
  }

  void reset() {
    log.log(LogLevel.info, 'session', 'Session lifecycle reset');
    _lifecycle?.reset();
    _lifecycle = null;
    _events.clear();
    notifyListeners();
  }
}
