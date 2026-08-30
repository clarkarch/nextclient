import 'dart:convert' show jsonDecode, jsonEncode;

import '../models/auth.dart'
    show AuthSession, LoginProvider, SavedAccount;
import '../ports.dart' show TokenStorage;
import 'provider_discovery.dart' show normalizeProvider;

// Port of auth/persistedAccountState.ts — stores multiple sessions keyed by
// userId, an activeUserId, and a selectedProvider as a single JSON blob.

class PersistedAuthState {
  final Map<String, AuthSession> sessions;
  String? activeUserId;
  LoginProvider selectedProvider;

  PersistedAuthState({
    required this.sessions,
    this.activeUserId,
    required this.selectedProvider,
  });

  factory PersistedAuthState.empty() => PersistedAuthState(
        sessions: {},
        selectedProvider: _defaultProvider(),
      );

  AuthSession? getSession() {
    final id = activeUserId;
    if (id == null) return null;
    return sessions[id];
  }

  AuthSession? getSessionForUser(String userId) => sessions[userId];

  bool hasAccount(String userId) => sessions.containsKey(userId);

  String? firstUserId() => sessions.keys.isEmpty ? null : sessions.keys.first;

  String? getActiveUserId() => activeUserId;

  LoginProvider getPersistedSelectedProvider() => selectedProvider;

  LoginProvider getSelectedProvider() =>
      getSession()?.provider ?? selectedProvider;

  void setSelectedProvider(LoginProvider provider) {
    selectedProvider = normalizeProvider(provider);
  }

  AuthSession setSession(AuthSession session) {
    final normalized = _normalizeSession(session);
    sessions[normalized.user.userId] = normalized;
    activeUserId = normalized.user.userId;
    selectedProvider = normalized.provider;
    return normalized;
  }

  void updateSession(AuthSession session) {
    sessions[session.user.userId] = session;
  }

  void setActiveAccount(String? userId) {
    if (userId != null && sessions.containsKey(userId)) {
      activeUserId = userId;
    } else {
      activeUserId = null;
    }
    selectedProvider = getSession()?.provider ?? _defaultProvider();
  }

  bool removeAccount(String userId) {
    return sessions.remove(userId) != null;
  }

  List<SavedAccount> getSavedAccounts() {
    return sessions.values.map((session) {
      return SavedAccount(
        userId: session.user.userId,
        displayName: session.user.displayName,
        email: session.user.email,
        avatarUrl: session.user.avatarUrl,
        membershipTier: session.user.membershipTier,
        providerCode: session.provider.code,
      );
    }).toList();
  }

  void restore(Map<String, dynamic> parsed) {
    if (parsed['selectedProvider'] is Map<String, dynamic>) {
      selectedProvider = normalizeProvider(
        LoginProvider.fromJson(parsed['selectedProvider'] as Map<String, dynamic>),
      );
    }

    sessions.clear();
    final rawSessions = parsed['sessions'];
    if (rawSessions is List) {
      for (final entry in rawSessions) {
        if (entry is! Map<String, dynamic>) continue;
        final user = entry['user'];
        final userId = user is Map ? user['userId'] as String? : null;
        if (userId == null) continue;
        sessions[userId] = _normalizeSession(
          AuthSession.fromJson(entry),
        );
      }
    } else if (parsed['session'] is Map<String, dynamic>) {
      final entry = parsed['session'] as Map<String, dynamic>;
      final user = entry['user'];
      final userId = user is Map ? user['userId'] as String? : null;
      if (userId != null) {
        sessions[userId] = _normalizeSession(AuthSession.fromJson(entry));
      }
    }

    final active = parsed['activeUserId'];
    activeUserId = active is String && sessions.containsKey(active)
        ? active
        : firstUserId();
  }

  Map<String, dynamic> snapshot() {
    return {
      'sessions': sessions.values.map((s) => s.toJson()).toList(),
      'activeUserId': activeUserId,
      'selectedProvider': selectedProvider.toJson(),
    };
  }

  void reset() {
    sessions.clear();
    activeUserId = null;
    selectedProvider = _defaultProvider();
  }
}

AuthSession _normalizeSession(AuthSession session) {
  return AuthSession(
    provider: normalizeProvider(session.provider),
    tokens: session.tokens,
    user: session.user,
  );
}

LoginProvider _defaultProvider() {
  return const LoginProvider(
    idpId: 'PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg',
    code: 'NVIDIA',
    displayName: 'NVIDIA',
    streamingServiceUrl: 'https://prod.cloudmatchbeta.nvidiagrid.net/',
    priority: 0,
  );
}

/// Port of PersistedAccountState — handles load/save via the TokenStorage port.
class PersistedAccountState {
  final TokenStorage storage;
  PersistedAuthState? _current;

  PersistedAccountState({required this.storage});

  /// Load state from storage. Returns the active session if any.
  Future<AuthSession?> initialize() async {
    final tokens = await storage.readTokens();
    if (tokens == null) return null;

    final raw = tokens['gfn-account-state'];
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final state = PersistedAuthState.empty();
      state.restore(decoded);
      _current = state;
      return state.getSession();
    } catch (_) {
      return null;
    }
  }

  PersistedAuthState get state {
    final current = _current;
    if (current != null) return current;
    final restored = PersistedAuthState.empty();
    _current = restored;
    return restored;
  }

  PersistedAuthState get accounts => state;

  Future<void> persist() async {
    final raw = jsonEncode(state.snapshot());
    final existing = await storage.readTokens() ?? {};
    existing['gfn-account-state'] = raw;
    await storage.writeTokens(existing);
  }
}

typedef AuthSessionNull = AuthSession?;