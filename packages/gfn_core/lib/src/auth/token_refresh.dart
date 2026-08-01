import 'dart:convert' show JsonDecoder;

import 'package:http/http.dart' as http;

import '../models/auth.dart' show AuthTokens;
import 'constants.dart' show clientId, clientTokenEndpoint, tokenEndpoint;
import 'helpers.dart' show buildAuthHeadersForClient, toExpiresAt;
import 'oauth_flow.dart' show TokenResponse;

// Port of auth/tokenRefresh.ts

class ClientTokenResponse {
  final String clientToken;
  final int? expiresIn;

  const ClientTokenResponse({required this.clientToken, this.expiresIn});

  factory ClientTokenResponse.fromJson(Map<String, dynamic> json) {
    return ClientTokenResponse(
      clientToken: json['client_token'] as String,
      expiresIn: (json['expires_in'] as num?)?.toInt(),
    );
  }
}

/// Port of auth/tokenRefresh.ts refreshAuthTokens
Future<AuthTokens> refreshAuthTokens({
  required http.Client client,
  required String refreshToken,
  required bool isMac,
  String? authClientId,
}) async {
  final effectiveClientId = authClientId ?? clientId;
  final body = {
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
    'client_id': effectiveClientId,
  };

  final response = await client.post(
    Uri.parse(tokenEndpoint),
    headers: buildAuthHeadersForClient(
      effectiveClientId,
      contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
      isMac: isMac,
    ),
    body: body,
  );

  if (response.statusCode != 200) {
    throw StateError(
      'Token refresh failed (${response.statusCode}): ${_snippet(response.body)}',
    );
  }

  final payload = TokenResponse.fromJson(_decodeJson(response.body));
  return AuthTokens(
    accessToken: payload.accessToken,
    // Omit rather than set null so callers that spread onto prior tokens do
    // not wipe a still-valid id_token when the refresh response excludes it.
    refreshToken: payload.refreshToken ?? refreshToken,
    idToken: payload.idToken,
    expiresAt: toExpiresAt(payload.expiresIn),
    authClientId: effectiveClientId,
  );
}

/// Port of auth/tokenRefresh.ts requestClientToken
Future<({String token, int expiresAt, int lifetimeMs})> requestClientToken({
  required http.Client client,
  required String accessToken,
  required bool isMac,
  String? authClientId,
}) async {
  final effectiveClientId = authClientId ?? clientId;
  final response = await client.get(
    Uri.parse(clientTokenEndpoint),
    headers: buildAuthHeadersForClient(
      effectiveClientId,
      bearerToken: accessToken,
      isMac: isMac,
    ),
  );

  if (response.statusCode != 200) {
    throw StateError(
      'Client token request failed (${response.statusCode}): ${_snippet(response.body)}',
    );
  }

  final payload = ClientTokenResponse.fromJson(_decodeJson(response.body));
  final expiresAt = toExpiresAt(payload.expiresIn);
  return (
    token: payload.clientToken,
    expiresAt: expiresAt,
    lifetimeMs: (expiresAt - DateTime.now().millisecondsSinceEpoch) < 0
        ? 0
        : expiresAt - DateTime.now().millisecondsSinceEpoch,
  );
}

/// Port of auth/tokenRefresh.ts refreshWithClientToken
Future<TokenResponse> refreshWithClientToken({
  required http.Client client,
  required String clientToken,
  required String userId,
  required bool isMac,
  String? authClientId,
}) async {
  final effectiveClientId = authClientId ?? clientId;
  final body = {
    'grant_type': 'urn:ietf:params:oauth:grant-type:client_token',
    'client_token': clientToken,
    'client_id': effectiveClientId,
    'sub': userId,
  };

  final response = await client.post(
    Uri.parse(tokenEndpoint),
    headers: buildAuthHeadersForClient(
      effectiveClientId,
      contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
      isMac: isMac,
    ),
    body: body,
  );

  if (response.statusCode != 200) {
    throw StateError(
      'Client-token refresh failed (${response.statusCode}): ${_snippet(response.body)}',
    );
  }

  return TokenResponse.fromJson(_decodeJson(response.body));
}

/// Port of auth/tokenRefresh.ts mergeTokenSnapshot
AuthTokens mergeTokenSnapshot(AuthTokens base, TokenResponse refreshed) {
  final nextClientToken = refreshed.clientToken ?? base.clientToken;
  final clientTokenRotated = refreshed.clientToken != null &&
      refreshed.clientToken!.isNotEmpty &&
      refreshed.clientToken != base.clientToken;

  return AuthTokens(
    accessToken: refreshed.accessToken,
    refreshToken: refreshed.refreshToken ?? base.refreshToken,
    // Refresh responses often omit id_token; keep the prior JWT for LCARS callers.
    idToken: refreshed.idToken ?? base.idToken,
    expiresAt: toExpiresAt(refreshed.expiresIn),
    authClientId: base.authClientId ?? clientId,
    clientToken: nextClientToken,
    // Rotated client tokens must not inherit stale expiry metadata.
    clientTokenExpiresAt: clientTokenRotated ? null : base.clientTokenExpiresAt,
    clientTokenLifetimeMs: clientTokenRotated ? null : base.clientTokenLifetimeMs,
  );
}

Map<String, dynamic> _decodeJson(String text) {
  final value = const JsonDecoder().convert(text);
  if (value is Map<String, dynamic>) return value;
  throw FormatException('Response was not a JSON object');
}

String _snippet(String text) {
  return text.length > 400 ? text.substring(0, 400) : text;
}