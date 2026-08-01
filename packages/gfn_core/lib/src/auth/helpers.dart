import 'dart:convert' show base64Url;

import 'package:crypto/crypto.dart' show sha256;

import '../http/client.dart' show generateDeviceId;
import '../ports.dart' show RandomSource;
import 'constants.dart' show steamDeckClientId, steamDeckUserAgent;

// Port of auth/helpers.ts

int toExpiresAt(int? expiresInSeconds, {int defaultSeconds = 86400}) {
  return DateTime.now().millisecondsSinceEpoch + (expiresInSeconds ?? defaultSeconds) * 1000;
}

bool isExpired(int? expiresAt, {required int nowMillis}) {
  if (expiresAt == null) return true;
  return expiresAt <= nowMillis;
}

bool isNearExpiry(int? expiresAt, int windowMs, {required int nowMillis}) {
  if (expiresAt == null) return true;
  return expiresAt - nowMillis < windowMs;
}

/// Port of auth/helpers.ts generateDeviceId — sha256(host:user:opennow-stable)
String generateAuthDeviceId({
  required String hostname,
  required String username,
}) {
  return generateDeviceId(hostname: hostname, username: username);
}

/// Port of auth/oauthFlow.ts generatePkce — RFC 7636
({String verifier, String challenge}) generatePkce(RandomSource random) {
  final bytes = random.nextBytes(64);
  final verifier = base64Url
      .encode(bytes)
      .replaceAll('=', '')
      .substring(0, 86);
  final challenge = base64Url
      .encode(sha256.convert(verifier.codeUnits).bytes)
      .replaceAll('=', '');
  return (verifier: verifier, challenge: challenge);
}

/// Port of auth/oauthFlow.ts random hex nonce (16 bytes)
String randomHex(int byteCount, RandomSource random) {
  return random.nextBytes(byteCount).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Port of auth/helpers.ts toExpiresAt with default
int toExpiresAtDefault(int? expiresInSeconds) => toExpiresAt(expiresInSeconds);

/// Port of auth/helpers.ts buildAuthHeadersForClient — the Steam Deck variant
/// uses the Steam Deck UA + play origin, otherwise the generic nvidia headers.
Map<String, String> buildAuthHeadersForClient(
  String authClientId, {
  String? bearerToken,
  String? accept,
  String? contentType,
  bool includeReferer = false,
  required bool isMac,
}) {
  if (authClientId != steamDeckClientId) {
    return _buildNvidiaAuthHeaders(
      bearerToken: bearerToken,
      accept: accept,
      contentType: contentType,
      includeReferer: includeReferer,
      isMac: isMac,
    );
  }

  return {
    'Accept': accept ?? 'application/json, text/plain, */*',
    'Origin': 'https://play.geforcenow.com',
    'Referer': 'https://play.geforcenow.com/',
    'User-Agent': steamDeckUserAgent,
    'Authorization': ?(bearerToken == null ? null : 'Bearer $bearerToken'),
    'Content-Type': ?contentType,
  };
}

Map<String, String> _buildNvidiaAuthHeaders({
  String? bearerToken,
  String? accept,
  String? contentType,
  bool includeReferer = false,
  required bool isMac,
}) {
  return {
    'Authorization': ?(bearerToken == null ? null : 'Bearer $bearerToken'),
    'Content-Type': ?contentType,
    'Origin': 'https://nvfile',
    if (includeReferer) 'Referer': 'https://nvfile/',
    'Accept': accept ?? 'application/json, text/plain, */*',
    'User-Agent': _userAgent(isMac),
  };
}

String _userAgent(bool isMac) {
  return isMac
      ? 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 GFN-PC/2.0.80.173'
      : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 '
          'NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173';
}