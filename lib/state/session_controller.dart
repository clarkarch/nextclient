import 'package:flutter/foundation.dart';
import 'package:gfn_core/gfn_core.dart';

/// ChangeNotifier bridge over [SessionLifecycle] so the UI can react to
/// launch progress (requesting → queued → allocating → ready → error).
class SessionController extends ChangeNotifier {
  final CloudMatchService cloudMatch;
  final Future<String> Function() getToken;
  SessionLifecycle? _lifecycle;
  final List<SessionPhaseEvent> _events = [];

  SessionController({
    required this.cloudMatch,
    required this.getToken,
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
          notifyListeners();
        },
      );
      _lifecycle = lc;
    }
    return lc;
  }

  Future<SessionInfo> launch(SessionCreateRequest request) {
    final lifecycle = _ensure();
    notifyListeners();
    return lifecycle.launch(request);
  }

  Future<SessionInfo> resume(SessionClaimRequest request) {
    final lifecycle = _ensure();
    notifyListeners();
    return lifecycle.resume(request);
  }

  Future<void> stop() async {
    final lc = _lifecycle;
    if (lc == null) return;
    await lc.stop();
    notifyListeners();
  }

  void reset() {
    _lifecycle?.reset();
    _lifecycle = null;
    _events.clear();
    notifyListeners();
  }
}
