import 'dart:convert' show base64Decode, jsonDecode, utf8;

import 'package:crypto/crypto.dart' show md5;
import 'package:http/http.dart' as http;

import '../models/auth.dart' show AuthTokens, AuthUser;
import 'constants.dart' show clientId, userinfoEndpoint;
import 'helpers.dart' show buildAuthHeadersForClient;

// Port of auth/userInfo.ts

String _decodeBase64Url(String value) {
  final normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  final padding = normalized.length % 4;
  final padded =
      padding == 0 ? normalized : '$normalized${'=' * (4 - padding)}';
  return utf8.decode(base64Decode(padded));
}

Map<String, dynamic>? _parseJwtPayload(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = _decodeBase64Url(parts[1]);
    final decoded = jsonDecode(payload);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

String gravatarUrl(String email, {int size = 80}) {
  final normalized = email.trim().toLowerCase();
  final hash = md5.convert(normalized.codeUnits).toString();
  return 'https://www.gravatar.com/avatar/$hash?s=$size&d=identicon';
}

/// Port of auth/userInfo.ts fetchUserInfo — prefers parsing the JWT; falls
/// back to the userinfo endpoint.
Future<AuthUser> fetchUserInfo({
  required http.Client client,
  required AuthTokens tokens,
  required bool isMac,
}) async {
  final jwtToken = tokens.idToken ?? tokens.accessToken;
  final parsed = _parseJwtPayload(jwtToken);
  final sub = parsed?['sub'] as String?;
  if (sub != null) {
    final emailFromToken = parsed!['email'] as String?;
    final pictureFromToken = parsed['picture'] as String?;
    if (emailFromToken != null || pictureFromToken != null) {
      final avatar = pictureFromToken ??
          (emailFromToken != null ? gravatarUrl(emailFromToken) : null);
      return AuthUser(
        userId: sub,
        displayName:
            (parsed['preferred_username'] as String?) ??
                emailFromToken?.split('@').first ??
                'User',
        email: emailFromToken,
        avatarUrl: avatar,
        membershipTier: (parsed['gfn_tier'] as String?) ?? 'FREE',
      );
    }
  }

  final response = await client.get(
    Uri.parse(userinfoEndpoint),
    headers: buildAuthHeadersForClient(
      tokens.authClientId ?? clientId,
      bearerToken: tokens.accessToken,
      accept: 'application/json',
      isMac: isMac,
    ),
  );

  if (response.statusCode != 200) {
    throw StateError('User info failed (${response.statusCode})');
  }

  final payload = _decodeObject(response.body);
  final email = payload['email'] as String?;
  final avatar = payload['picture'] as String? ??
      (email != null ? gravatarUrl(email) : null);

  return AuthUser(
    userId: payload['sub'] as String,
    displayName: (payload['preferred_username'] as String?) ??
        email?.split('@').first ??
        'User',
    email: email,
    avatarUrl: avatar,
    membershipTier: 'FREE',
  );
}

Map<String, dynamic> _decodeObject(String text) {
  final decoded = jsonDecode(text);
  if (decoded is Map<String, dynamic>) return decoded;
  throw FormatException('User info response was not a JSON object');
}