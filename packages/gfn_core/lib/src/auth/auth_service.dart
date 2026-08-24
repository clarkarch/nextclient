import 'dart:io' show InternetAddress, ServerSocket;

import 'package:http/http.dart' as http;

import '../models/auth.dart'
    show
        AuthDeviceLoginChallenge,
        AuthDeviceLoginPollResult,
        AuthDeviceLoginPollStatus,
        AuthRefreshOutcome,
        AuthRefreshStatus,
        AuthSession,
        AuthSessionResult,
        AuthTokens,
        AuthUser,
        LoginProvider,
        SavedAccount;
import '../ports.dart' show BrowserLauncher, Clock, RandomSource, TokenStorage;
import 'constants.dart' show clientTokenRefreshWindowMs, tokenRefreshWindowMs;
import 'device_login.dart'
    show DeviceTokenErrorResponse, exchangeDeviceCode, requestDeviceAuthorization;
import 'oauth_flow.dart'
    show
        OAuthBindException,
        buildAuthUrl,
        buildOAuthLoginContext,
        exchangeAuthorizationCode,
        findAvailablePorts,
        openAuthorizationUrlAndWaitForCode;
import 'persisted_state.dart' show PersistedAccountState;
import 'provider_discovery.dart' show ProviderDiscovery, normalizeProvider;
import 'token_refresh.dart'
    show
        mergeTokenSnapshot,
        refreshAuthTokens,
        refreshWithClientToken,
        requestClientToken;
import 'user_info.dart' show fetchUserInfo;

// Port of auth.ts (AuthService) + auth/sessionValidity.ts +
// auth/accountManager.ts. Platform-specific bits (shell.openExternal, the local
// callback server, hostname/username) come in through ports.

class AuthServiceDeps {
  final http.Client httpClient;
  final TokenStorage tokenStorage;
  final BrowserLauncher browserLauncher;
  final Clock clock;
  final RandomSource random;
  final String hostname;
  final String username;
  final bool isMac;

  /// Mobile platforms freeze backgrounded processes (Cached Apps Freezer),
  /// which stalls the OAuth callback listener while the browser does the
  /// login. Mobile therefore gets a much wider callback window.
  final bool isMobile;

  const AuthServiceDeps({
    required this.httpClient,
    required this.tokenStorage,
    required this.browserLauncher,
    required this.clock,
    required this.random,
    required this.hostname,
    required this.username,
    required this.isMac,
    this.isMobile = false,
  });
}

class AuthService {
  final AuthServiceDeps deps;
  final PersistedAccountState _state;
  final ProviderDiscovery _providerDiscovery;
  final Map<String, _DeviceLoginAttempt> _deviceLoginAttempts = {};
  final Map<String, AuthSession> _pendingDeviceLoginSessions = {};

  AuthService({required this.deps})
      : _state = PersistedAccountState(storage: deps.tokenStorage),
        _providerDiscovery = ProviderDiscovery(
          client: deps.httpClient,
          isMac: deps.isMac,
          clock: deps.clock,
        );

  AuthSession? _cachedSession;  Future<void> initialize() async {
    final restored = await _state.initialize();
    if (restored != null) {
      _cachedSession = restored;
    }
  }

  Future<List<LoginProvider>> getProviders() {
    return _providerDiscovery.getProviders();
  }

  AuthSession? getSession() => _cachedSession;

  List<SavedAccount> getSavedAccounts() => _state.accounts.getSavedAccounts();

  LoginProvider getSelectedProvider() => _state.accounts.getSelectedProvider();

  void setSession(AuthSession? session) {
    _cachedSession = session;
    if (session == null) {
      _state.accounts.reset();
    } else {
      _state.accounts.setSession(session);
    }
  }

  /// OAuth browser flow. Returns the fully-built session.
  Future<AuthSession> login({String? providerIdpId}) async {
    final provider =
        await _selectLoginProvider(providerIdpId);
    final context = buildOAuthLoginContext(
      random: deps.random,
      hostname: deps.hostname,
      username: deps.username,
      port: 0, // resolved below
    );

    // Probe every configured callback port up front, then race the real bind
    // across candidates: another process can steal a probed port between the
    // availability check and the actual bind, so fall through to the next port
    // instead of surfacing a raw socket error.
    final candidatePorts = await findAvailablePorts(
      tryBind: (p) => _tryBind(p),
    );
    if (candidatePorts.isEmpty) {
      throw StateError('No available OAuth callback ports');
    }

    var code = '';
    var port = -1;
    Object? lastBindFailure;
    // Mobile: the app is background-frozen while Chrome handles the NVIDIA
    // login, so give the callback a wide window to survive late unfreezes.
    final callbackTimeout = deps.isMobile
        ? const Duration(minutes: 10)
        : const Duration(minutes: 2);
    for (final candidate in candidatePorts) {
      try {
        code = await openAuthorizationUrlAndWaitForCode(
          authUrl: buildAuthUrl(
            provider: provider,
            challenge: context.challenge,
            port: candidate,
            deviceId: context.deviceId,
            nonce: context.nonce,
          ),
          port: candidate,
          timeout: callbackTimeout,
          openExternal: deps.browserLauncher.openUrl,
        );
        port = candidate;
        break;
      } on OAuthBindException catch (error) {
        // Bind failed before the browser was opened — safe to retry.
        lastBindFailure = error;
      }
    }
    if (port < 0) {
      throw StateError(
        lastBindFailure?.toString() ?? 'No available OAuth callback ports',
      );
    }

    final initialTokens = await exchangeAuthorizationCode(
      client: deps.httpClient,
      code: code,
      verifier: context.verifier,
      port: port,
      isMac: deps.isMac,
    );

    final session = await _buildLoginSession(initialTokens, provider);
    return _saveLoginSession(session);
  }

  /// Start a device-code login. Returns a challenge that includes the QR URI.
  Future<AuthDeviceLoginChallenge> startDeviceLogin({
    String? providerIdpId,
  }) async {
    final provider = await _selectLoginProvider(providerIdpId);
    final attemptId = _randomHex(16);
    final challenge = await requestDeviceAuthorization(
      client: deps.httpClient,
      provider: provider,
      hostname: deps.hostname,
      username: deps.username,
      attemptId: attemptId,
      isMac: deps.isMac,
    );
    _deviceLoginAttempts[attemptId] = _DeviceLoginAttempt(
      provider: provider,
      deviceCode: challenge.deviceCode,
      expiresAt: challenge.expiresAt,
    );
    return challenge;
  }

  /// Poll a device-code login. Returns authorized only when the code was
  /// approved and the token exchange succeeded.
  Future<AuthDeviceLoginPollResult> pollDeviceLogin({
    required String attemptId,
    required String deviceCode,
  }) async {
    final attempt = _deviceLoginAttempts[attemptId];
    if (attempt == null || attempt.deviceCode != deviceCode) {
      return const AuthDeviceLoginPollResult(
        status: AuthDeviceLoginPollStatus.expired,
        error: 'QR login was cancelled or expired',
      );
    }
    if (deps.clock.nowMillis() >= attempt.expiresAt) {
      _cancelDeviceLogin(attemptId);
      return const AuthDeviceLoginPollResult(
        status: AuthDeviceLoginPollStatus.expired,
        error: 'QR login expired',
      );
    }

    final result = await exchangeDeviceCode(
      client: deps.httpClient,
      deviceCode: deviceCode,
      isMac: deps.isMac,
    );

    if (!_deviceLoginAttempts.containsKey(attemptId)) {
      return const AuthDeviceLoginPollResult(
        status: AuthDeviceLoginPollStatus.expired,
        error: 'QR login was cancelled',
      );
    }

    if (result is AuthTokens) {
      final session = await _buildLoginSession(result, attempt.provider);
      if (!_deviceLoginAttempts.containsKey(attemptId)) {
        return const AuthDeviceLoginPollResult(
          status: AuthDeviceLoginPollStatus.expired,
          error: 'QR login was cancelled',
        );
      }
      _pendingDeviceLoginSessions[attemptId] = session;
      return const AuthDeviceLoginPollResult(
        status: AuthDeviceLoginPollStatus.authorized,
      );
    }

    final errorResponse = result as DeviceTokenErrorResponse;
    switch (errorResponse.error) {
      case 'authorization_pending':
        return AuthDeviceLoginPollResult(
          status: AuthDeviceLoginPollStatus.pending,
          error: errorResponse.errorDescription,
        );
      case 'slow_down':
        return AuthDeviceLoginPollResult(
          status: AuthDeviceLoginPollStatus.slowDown,
          error: errorResponse.errorDescription,
        );
      case 'expired_token':
        _cancelDeviceLogin(attemptId);
        return AuthDeviceLoginPollResult(
          status: AuthDeviceLoginPollStatus.expired,
          error: errorResponse.errorDescription ?? 'QR login expired',
        );
      case 'access_denied':
        _cancelDeviceLogin(attemptId);
        return AuthDeviceLoginPollResult(
          status: AuthDeviceLoginPollStatus.accessDenied,
          error: errorResponse.errorDescription ?? 'QR login was denied',
        );
      default:
        _cancelDeviceLogin(attemptId);
        return AuthDeviceLoginPollResult(
          status: AuthDeviceLoginPollStatus.error,
          error: errorResponse.errorDescription ??
              errorResponse.error ??
              'QR login failed',
        );
    }
  }

  /// Complete a device-code login after it was authorized.
  Future<AuthSession> completeDeviceLogin({required String attemptId}) async {
    final session = _pendingDeviceLoginSessions[attemptId];
    if (session == null || !_deviceLoginAttempts.containsKey(attemptId)) {
      throw StateError('QR login is no longer active');
    }
    _cancelDeviceLogin(attemptId);
    return _saveLoginSession(session);
  }

  void cancelDeviceLogin({required String attemptId}) {
    _cancelDeviceLogin(attemptId);
  }

  /// Ensure the current session is valid, refreshing tokens if near expiry.
  Future<AuthSessionResult> ensureValidSessionWithStatus({
    bool forceRefresh = false,
    String? expectedUserId,
  }) async {
    final session = _state.accounts.getSession();
    if (session == null) {
      return AuthSessionResult(
        session: null,
        refresh: AuthRefreshStatus(
          attempted: false,
          forced: forceRefresh,
          outcome: AuthRefreshOutcome.notAttempted,
          message: 'No saved session found.',
        ),
      );
    }

    final userId = session.user.userId;
    var tokens = session.tokens;

    if (tokens.clientToken == null && !_isExpired(tokens.expiresAt)) {
      try {
        final withClientToken = await _ensureClientToken(tokens);
        if (withClientToken.clientToken != null &&
            withClientToken.clientToken != tokens.clientToken) {
          _state.accounts.updateSession(
            AuthSession(provider: session.provider, tokens: withClientToken, user: session.user),
          );
          tokens = withClientToken;
          await _state.persist();
        }
      } catch (_) {
        // Unable to bootstrap client token from saved session.
      }
    }

    if (!forceRefresh && !_shouldRefreshSession(tokens)) {
      return AuthSessionResult(
        session: _state.accounts.getSession(),
        refresh: AuthRefreshStatus(
          attempted: false,
          forced: forceRefresh,
          outcome: AuthRefreshOutcome.notAttempted,
          message: 'Session token is still valid.',
        ),
      );
    }

    Future<AuthSessionResult> applyRefreshedTokens(
      AuthTokens refreshedTokens,
      String source,
    ) async {
      final latestSession = _state.accounts.getSession() ?? session;
      final baseSession =
          latestSession.user.userId == userId ? latestSession : session;
      final expectedRefreshUserId = expectedUserId ?? userId;

      AuthUser? refreshedUser;
      try {
        refreshedUser = await fetchUserInfo(
          client: deps.httpClient,
          tokens: refreshedTokens,
          isMac: deps.isMac,
        );
      } catch (_) {
        // Token refresh succeeded but user info refresh failed. Keep cached user.
      }

      final resolvedUser = refreshedUser ?? baseSession.user;
      if (resolvedUser.userId != expectedRefreshUserId) {
        return AuthSessionResult(
          session: baseSession,
          refresh: AuthRefreshStatus(
            attempted: true,
            forced: forceRefresh,
            outcome: AuthRefreshOutcome.failed,
            message: 'Token refresh returned a different account than expected.',
            error: 'expected_user_id:$expectedRefreshUserId actual_user_id:${resolvedUser.userId}',
          ),
        );
      }

      _state.accounts.updateSession(
        AuthSession(
          provider: baseSession.provider,
          tokens: refreshedTokens,
          user: resolvedUser,
        ),
      );
      await _state.persist();
      return AuthSessionResult(
        session: _state.accounts.getSession(),
        refresh: AuthRefreshStatus(
          attempted: true,
          forced: forceRefresh,
          outcome: AuthRefreshOutcome.refreshed,
          message: forceRefresh
              ? 'Saved session token refreshed via $source.'
              : 'Session token refreshed via $source because it was near expiry.',
        ),
      );
    }

    final refreshErrors = <String>[];
    if (tokens.clientToken != null) {
      try {
        final refreshedFromClientToken = await refreshWithClientToken(
          client: deps.httpClient,
          clientToken: tokens.clientToken!,
          userId: userId,
          isMac: deps.isMac,
          authClientId: tokens.authClientId,
        );
        var refreshedTokens = mergeTokenSnapshot(tokens, refreshedFromClientToken);
        refreshedTokens = await _ensureClientToken(refreshedTokens);
        return await applyRefreshedTokens(refreshedTokens, 'client token');
      } catch (error) {
        refreshErrors.add('client_token: $error');
      }
    }

    if (tokens.refreshToken != null) {
      try {
        final refreshedOAuth = await refreshAuthTokens(
          client: deps.httpClient,
          refreshToken: tokens.refreshToken!,
          isMac: deps.isMac,
          authClientId: tokens.authClientId,
        );
        var refreshedTokens = AuthTokens(
          accessToken: refreshedOAuth.accessToken,
          refreshToken: refreshedOAuth.refreshToken ?? tokens.refreshToken,
          idToken: refreshedOAuth.idToken ?? tokens.idToken,
          expiresAt: refreshedOAuth.expiresAt,
          authClientId: refreshedOAuth.authClientId ?? tokens.authClientId,
          clientToken: tokens.clientToken,
          clientTokenExpiresAt: tokens.clientTokenExpiresAt,
          clientTokenLifetimeMs: tokens.clientTokenLifetimeMs,
        );
        refreshedTokens = await _ensureClientToken(refreshedTokens);
        return await applyRefreshedTokens(refreshedTokens, 'refresh token');
      } catch (error) {
        refreshErrors.add('refresh_token: $error');
      }
    }

    final errorText = refreshErrors.isEmpty ? null : refreshErrors.join(' | ');
    final expired = _isExpired(tokens.expiresAt);
    if (tokens.clientToken == null && tokens.refreshToken == null) {
      if (expired) {
        await _logout();
        return AuthSessionResult(
          session: null,
          refresh: AuthRefreshStatus(
            attempted: true,
            forced: forceRefresh,
            outcome: AuthRefreshOutcome.missingRefreshToken,
            message: 'Saved session expired and has no refresh mechanism. Please log in again.',
          ),
        );
      }
      return AuthSessionResult(
        session: _state.accounts.getSession(),
        refresh: AuthRefreshStatus(
          attempted: true,
          forced: forceRefresh,
          outcome: AuthRefreshOutcome.missingRefreshToken,
          message: 'No refresh token available. Using saved session token.',
        ),
      );
    }

    if (expired) {
      await _logout();
      return AuthSessionResult(
        session: null,
        refresh: AuthRefreshStatus(
          attempted: true,
          forced: forceRefresh,
          outcome: AuthRefreshOutcome.failed,
          message: 'Token refresh failed and the saved session expired. Please log in again.',
          error: errorText,
        ),
      );
    }

    return AuthSessionResult(
      session: _state.accounts.getSession(),
      refresh: AuthRefreshStatus(
        attempted: true,
        forced: forceRefresh,
        outcome: AuthRefreshOutcome.failed,
        message: 'Token refresh failed. Using saved session token.',
        error: errorText,
      ),
    );
  }

  Future<AuthSession?> ensureValidSession() async {
    final result = await ensureValidSessionWithStatus();
    return result.session;
  }

  Future<String> resolveJwtToken({String? explicitToken}) async {
    if (getSession() != null) {
      final session = await ensureValidSession();
      if (session == null) {
        throw StateError('No authenticated session available');
      }
      return session.tokens.idToken ?? session.tokens.accessToken;
    }
    if (explicitToken != null && explicitToken.trim().isNotEmpty) {
      return explicitToken.trim();
    }
    final session = await ensureValidSession();
    if (session == null) {
      throw StateError('No authenticated session available');
    }
    return session.tokens.idToken ?? session.tokens.accessToken;
  }

  Future<AuthSession> switchAccount({
    required String userId,
  }) async {
    final target = _state.accounts.getSessionForUser(userId);
    if (target == null) {
      throw StateError('Saved account not found');
    }
    _state.accounts.setActiveAccount(userId);
    _cachedSession = _state.accounts.getSession();

    final result = await ensureValidSessionWithStatus(
      forceRefresh: true,
      expectedUserId: userId,
    );
    if (result.session == null || result.session!.user.userId != userId) {
      _state.accounts.setActiveAccount(null);
      _cachedSession = _state.accounts.getSession();
      throw StateError(result.refresh.message);
    }
    _cachedSession = result.session;
    return result.session!;
  }

  Future<void> removeAccount({required String userId}) async {
    final removed = _state.accounts.removeAccount(userId);
    if (!removed) return;
    if (_state.accounts.getActiveUserId() == userId) {
      _state.accounts.setActiveAccount(_state.accounts.firstUserId());
    }
    _cachedSession = _state.accounts.getSession();
    await _state.persist();
  }

  Future<void> logout() async {
    await _logout();
  }

  Future<void> logoutAll() async {
    _state.accounts.reset();
    _cachedSession = null;
    await _state.persist();
  }

  Future<AuthTokens> _ensureClientToken(AuthTokens tokens) async {
    final hasUsableClientToken = tokens.clientToken != null &&
        !_isNearExpiry(tokens.clientTokenExpiresAt, clientTokenRefreshWindowMs);
    if (hasUsableClientToken || _isExpired(tokens.expiresAt)) {
      return tokens;
    }
    final clientToken = await requestClientToken(
      client: deps.httpClient,
      accessToken: tokens.accessToken,
      isMac: deps.isMac,
      authClientId: tokens.authClientId,
    );
    return AuthTokens(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      idToken: tokens.idToken,
      expiresAt: tokens.expiresAt,
      authClientId: tokens.authClientId,
      clientToken: clientToken.token,
      clientTokenExpiresAt: clientToken.expiresAt,
      clientTokenLifetimeMs: clientToken.lifetimeMs,
    );
  }

  Future<LoginProvider> _selectLoginProvider(String? providerIdpId) async {
    final selected = await _providerDiscovery.selectProvider(
      selectedProvider: _state.accounts.getPersistedSelectedProvider(),
      providerIdpId: providerIdpId,
    );
    _state.accounts.setSelectedProvider(selected);
    return _state.accounts.getPersistedSelectedProvider();
  }

  Future<AuthSession> _buildLoginSession(
    AuthTokens initialTokens,
    LoginProvider provider,
  ) async {
    final user = await fetchUserInfo(
      client: deps.httpClient,
      tokens: initialTokens,
      isMac: deps.isMac,
    );
    var tokens = initialTokens;
    try {
      tokens = await _ensureClientToken(initialTokens);
    } catch (_) {
      // Fall back to OAuth token only.
    }
    return AuthSession(
      provider: normalizeProvider(provider),
      tokens: tokens,
      user: user,
    );
  }

  Future<AuthSession> _saveLoginSession(AuthSession session) async {
    final normalized = _state.accounts.setSession(session);
    _cachedSession = normalized;
    await _state.persist();
    return normalized;
  }

  Future<void> _logout() async {
    final activeUserId = _state.accounts.getActiveUserId();
    if (activeUserId == null) return;
    _state.accounts.removeAccount(activeUserId);
    _state.accounts.setActiveAccount(_state.accounts.firstUserId());
    _cachedSession = _state.accounts.getSession();
    await _state.persist();
  }

  bool _shouldRefreshSession(AuthTokens tokens) {
    return _isNearExpiry(tokens.expiresAt, tokenRefreshWindowMs);
  }

  bool _isExpired(int? expiresAt) {
    if (expiresAt == null) return true;
    return expiresAt <= deps.clock.nowMillis();
  }

  bool _isNearExpiry(int? expiresAt, int windowMs) {
    if (expiresAt == null) return true;
    return expiresAt - deps.clock.nowMillis() < windowMs;
  }

  String _randomHex(int byteCount) {
    return deps.random
        .nextBytes(byteCount)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<int> _tryBind(int port) async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await server.close();
      return port;
    } catch (_) {
      return -1;
    }
  }

  void _cancelDeviceLogin(String attemptId) {
    _deviceLoginAttempts.remove(attemptId);
    _pendingDeviceLoginSessions.remove(attemptId);
  }
}

class _DeviceLoginAttempt {
  final LoginProvider provider;
  final String deviceCode;
  final int expiresAt;

  const _DeviceLoginAttempt({
    required this.provider,
    required this.deviceCode,
    required this.expiresAt,
  });
}