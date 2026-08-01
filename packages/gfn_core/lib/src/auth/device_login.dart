import 'dart:convert' show JsonDecoder;

import 'package:http/http.dart' as http;

import '../models/auth.dart' show AuthDeviceLoginChallenge, AuthTokens, LoginProvider;
import 'constants.dart' show deviceAuthorizeEndpoint, scopes, steamDeckClientId, tokenEndpoint;
import 'helpers.dart'
    show buildAuthHeadersForClient, generateAuthDeviceId, toExpiresAt;
import 'oauth_flow.dart' show TokenResponse;

class DeviceAuthorizationResponse {
  final String? deviceCode;
  final String? userCode;
  final String? verificationUri;
  final String? verificationUriComplete;
  final int? expiresIn;
  final int? interval;

  const DeviceAuthorizationResponse({
    this.deviceCode,
    this.userCode,
    this.verificationUri,
    this.verificationUriComplete,
    this.expiresIn,
    this.interval,
  });

  factory DeviceAuthorizationResponse.fromJson(Map<String, dynamic> json) {
    return DeviceAuthorizationResponse(
      deviceCode: json['device_code'] as String?,
      userCode: json['user_code'] as String?,
      verificationUri: json['verification_uri'] as String?,
      verificationUriComplete: json['verification_uri_complete'] as String?,
      expiresIn: (json['expires_in'] as num?)?.toInt(),
      interval: (json['interval'] as num?)?.toInt(),
    );
  }
}

class DeviceTokenErrorResponse {
  final String? error;
  final String? errorDescription;

  const DeviceTokenErrorResponse({this.error, this.errorDescription});
}

/// Port of auth/deviceLogin.ts requestDeviceAuthorization
Future<AuthDeviceLoginChallenge> requestDeviceAuthorization({
  required http.Client client,
  required LoginProvider provider,
  required String hostname,
  required String username,
  required String attemptId,
  required bool isMac,
}) async {
  final deviceId = generateAuthDeviceId(hostname: hostname, username: username);
  final body = {
    'client_id': steamDeckClientId,
    'scope': scopes,
    'device_id': deviceId,
    'display_name': 'OpenNOW',
    'idp_id': provider.idpId,
  };

  final response = await client.post(
    Uri.parse(deviceAuthorizeEndpoint),
    headers: {
      ...buildAuthHeadersForClient(
        steamDeckClientId,
        contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
        isMac: isMac,
      ),
      'x-device-id': deviceId,
      'nv-client-id': steamDeckClientId,
      'nv-client-streamer': 'WEBRTC',
      'nv-client-type': 'BROWSER',
      'nv-client-platform-name': 'browser',
      'nv-browser-type': 'CHROME',
      'nv-device-os': 'STEAMOS',
      'nv-device-type': 'CONSOLE',
      'nv-device-model': 'STEAMDECK',
      'nv-device-make': 'VALVE',
    },
    body: body,
  );

  if (response.statusCode != 200) {
    throw StateError(
      'Device authorization failed (${response.statusCode}): ${_snippet(response.body)}',
    );
  }

  final payload = DeviceAuthorizationResponse.fromJson(_decodeJson(response.body));
  final deviceCode = payload.deviceCode;
  final userCode = payload.userCode;
  final verificationUri = payload.verificationUri;
  final verificationUriComplete = payload.verificationUriComplete;
  if (deviceCode == null ||
      userCode == null ||
      verificationUri == null ||
      verificationUriComplete == null) {
    throw StateError('Device authorization response did not include QR login data');
  }

  return AuthDeviceLoginChallenge(
    attemptId: attemptId,
    deviceCode: deviceCode,
    userCode: userCode,
    verificationUri: verificationUri,
    verificationUriComplete: verificationUriComplete,
    expiresAt: toExpiresAt(payload.expiresIn, defaultSeconds: 600),
    intervalSeconds: (payload.interval ?? 5) < 1 ? 1 : payload.interval ?? 5,
  );
}

/// Port of auth/deviceLogin.ts exchangeDeviceCode
Future<Object> exchangeDeviceCode({
  required http.Client client,
  required String deviceCode,
  required bool isMac,
}) async {
  final body = {
    'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
    'device_code': deviceCode,
    'client_id': steamDeckClientId,
  };

  final response = await client.post(
    Uri.parse(tokenEndpoint),
    headers: buildAuthHeadersForClient(
      steamDeckClientId,
      contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
      isMac: isMac,
    ),
    body: body,
  );

  Map<String, dynamic>? decoded;
  try {
    decoded = _decodeJson(response.body);
  } catch (_) {
    decoded = null;
  }

  if (response.statusCode != 200) {
    return decoded == null
        ? DeviceTokenErrorResponse(
            error: 'device_token_exchange_failed',
            errorDescription: 'Device token exchange failed (${response.statusCode})',
          )
        : DeviceTokenErrorResponse(
            error: decoded['error'] as String?,
            errorDescription: decoded['error_description'] as String?,
          );
  }

  final payload = decoded == null ? null : TokenResponse.fromJson(decoded);
  if (payload == null || payload.accessToken.isEmpty) {
    return const DeviceTokenErrorResponse(
      error: 'invalid_token_response',
      errorDescription: 'Device token response did not include access_token',
    );
  }

  return AuthTokens(
    accessToken: payload.accessToken,
    refreshToken: payload.refreshToken,
    idToken: payload.idToken,
    expiresAt: toExpiresAt(payload.expiresIn),
    authClientId: steamDeckClientId,
    clientToken: payload.clientToken,
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