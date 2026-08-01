class LoginProvider {
  final String idpId;
  final String code;
  final String displayName;
  final String streamingServiceUrl;
  final int priority;

  const LoginProvider({
    required this.idpId,
    required this.code,
    required this.displayName,
    required this.streamingServiceUrl,
    required this.priority,
  });

  factory LoginProvider.fromJson(Map<String, dynamic> json) {
    return LoginProvider(
      idpId: json['idpId'] as String,
      code: json['code'] as String,
      displayName: json['displayName'] as String,
      streamingServiceUrl: json['streamingServiceUrl'] as String,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'idpId': idpId,
      'code': code,
      'displayName': displayName,
      'streamingServiceUrl': streamingServiceUrl,
      'priority': priority,
    };
  }

  LoginProvider normalize() {
    if (streamingServiceUrl.endsWith('/')) return this;
    return LoginProvider(
      idpId: idpId,
      code: code,
      displayName: displayName,
      streamingServiceUrl: '$streamingServiceUrl/',
      priority: priority,
    );
  }
}

class AuthTokens {
  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final int expiresAt;
  final String? authClientId;
  final String? clientToken;
  final int? clientTokenExpiresAt;
  final int? clientTokenLifetimeMs;

  const AuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.idToken,
    required this.expiresAt,
    this.authClientId,
    this.clientToken,
    this.clientTokenExpiresAt,
    this.clientTokenLifetimeMs,
  });

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String?,
      idToken: json['idToken'] as String?,
      expiresAt: (json['expiresAt'] as num).toInt(),
      authClientId: json['authClientId'] as String?,
      clientToken: json['clientToken'] as String?,
      clientTokenExpiresAt: (json['clientTokenExpiresAt'] as num?)?.toInt(),
      clientTokenLifetimeMs: (json['clientTokenLifetimeMs'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'idToken': idToken,
      'expiresAt': expiresAt,
      'authClientId': authClientId,
      'clientToken': clientToken,
      'clientTokenExpiresAt': clientTokenExpiresAt,
      'clientTokenLifetimeMs': clientTokenLifetimeMs,
    };
  }

  AuthTokens copyWith({
    String? accessToken,
    String? refreshToken,
    String? idToken,
    int? expiresAt,
    String? authClientId,
    String? clientToken,
    int? clientTokenExpiresAt,
    int? clientTokenLifetimeMs,
  }) {
    return AuthTokens(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      idToken: idToken ?? this.idToken,
      expiresAt: expiresAt ?? this.expiresAt,
      authClientId: authClientId ?? this.authClientId,
      clientToken: clientToken ?? this.clientToken,
      clientTokenExpiresAt: clientTokenExpiresAt ?? this.clientTokenExpiresAt,
      clientTokenLifetimeMs: clientTokenLifetimeMs ?? this.clientTokenLifetimeMs,
    );
  }
}

class AuthUser {
  final String userId;
  final String displayName;
  final String? email;
  final String? avatarUrl;
  final String membershipTier;

  const AuthUser({
    required this.userId,
    required this.displayName,
    this.email,
    this.avatarUrl,
    required this.membershipTier,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      userId: json['userId'] as String,
      displayName: json['displayName'] as String,
      email: json['email'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      membershipTier: json['membershipTier'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'displayName': displayName,
      'email': email,
      'avatarUrl': avatarUrl,
      'membershipTier': membershipTier,
    };
  }
}

class AuthSession {
  final LoginProvider provider;
  final AuthTokens tokens;
  final AuthUser user;

  const AuthSession({
    required this.provider,
    required this.tokens,
    required this.user,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      provider: LoginProvider.fromJson(json['provider'] as Map<String, dynamic>).normalize(),
      tokens: AuthTokens.fromJson(json['tokens'] as Map<String, dynamic>),
      user: AuthUser.fromJson(json['user'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'provider': provider.toJson(),
      'tokens': tokens.toJson(),
      'user': user.toJson(),
    };
  }
}

class SavedAccount {
  final String userId;
  final String displayName;
  final String? email;
  final String? avatarUrl;
  final String membershipTier;
  final String providerCode;

  const SavedAccount({
    required this.userId,
    required this.displayName,
    this.email,
    this.avatarUrl,
    required this.membershipTier,
    required this.providerCode,
  });

  factory SavedAccount.fromJson(Map<String, dynamic> json) {
    return SavedAccount(
      userId: json['userId'] as String,
      displayName: json['displayName'] as String,
      email: json['email'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      membershipTier: json['membershipTier'] as String,
      providerCode: json['providerCode'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'displayName': displayName,
      'email': email,
      'avatarUrl': avatarUrl,
      'membershipTier': membershipTier,
      'providerCode': providerCode,
    };
  }
}

class AuthDeviceLoginChallenge {
  final String attemptId;
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String verificationUriComplete;
  final int expiresAt;
  final int intervalSeconds;

  const AuthDeviceLoginChallenge({
    required this.attemptId,
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresAt,
    required this.intervalSeconds,
  });
}

enum AuthDeviceLoginPollStatus {
  pending,
  slowDown,
  expired,
  accessDenied,
  authorized,
  error;

  static AuthDeviceLoginPollStatus fromWire(String? value) {
    switch (value) {
      case 'authorization_pending':
        return AuthDeviceLoginPollStatus.pending;
      case 'slow_down':
        return AuthDeviceLoginPollStatus.slowDown;
      case 'expired_token':
        return AuthDeviceLoginPollStatus.expired;
      case 'access_denied':
        return AuthDeviceLoginPollStatus.accessDenied;
      default:
        return AuthDeviceLoginPollStatus.error;
    }
  }
}

class AuthDeviceLoginPollResult {
  final AuthDeviceLoginPollStatus status;
  final AuthSession? session;
  final String? error;
  final int? intervalSeconds;

  const AuthDeviceLoginPollResult({
    required this.status,
    this.session,
    this.error,
    this.intervalSeconds,
  });
}

enum AuthRefreshOutcome {
  notAttempted,
  refreshed,
  failed,
  missingRefreshToken;
}

class AuthRefreshStatus {
  final bool attempted;
  final bool forced;
  final AuthRefreshOutcome outcome;
  final String message;
  final String? error;

  const AuthRefreshStatus({
    required this.attempted,
    required this.forced,
    required this.outcome,
    required this.message,
    this.error,
  });
}

class AuthSessionResult {
  final AuthSession? session;
  final AuthRefreshStatus refresh;

  const AuthSessionResult({
    required this.session,
    required this.refresh,
  });
}