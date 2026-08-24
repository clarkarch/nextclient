import 'dart:async' show Completer;
import 'dart:convert' show JsonDecoder;
import 'dart:io'
    show HttpServer, HttpRequest, HttpStatus, InternetAddress;

import 'package:http/http.dart' as http;

import '../models/auth.dart' show AuthTokens, LoginProvider;
import '../ports.dart' show RandomSource;
import 'constants.dart'
    show authEndpoint, clientId, redirectPorts, scopes, tokenEndpoint;
import 'helpers.dart'
    show
        buildAuthHeadersForClient,
        generateAuthDeviceId,
        generatePkce,
        randomHex,
        toExpiresAt;

class TokenResponse {
  final String accessToken;
  final String? refreshToken;
  final String? idToken;
  final String? clientToken;
  final int? expiresIn;

  const TokenResponse({
    required this.accessToken,
    this.refreshToken,
    this.idToken,
    this.clientToken,
    this.expiresIn,
  });

  factory TokenResponse.fromJson(Map<String, dynamic> json) {
    return TokenResponse(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      idToken: json['id_token'] as String?,
      clientToken: json['client_token'] as String?,
      expiresIn: (json['expires_in'] as num?)?.toInt(),
    );
  }
}

/// Port of auth/oauthFlow.ts buildAuthUrl
String buildAuthUrl({
  required LoginProvider provider,
  required String challenge,
  required int port,
  required String deviceId,
  required String nonce,
}) {
  final redirectUri = 'http://localhost:$port';
  final params = <String, String>{
    'response_type': 'code',
    'device_id': deviceId,
    'scope': scopes,
    'client_id': clientId,
    'redirect_uri': redirectUri,
    'ui_locales': 'en_US',
    'nonce': nonce,
    'prompt': 'select_account',
    'code_challenge': challenge,
    'code_challenge_method': 'S256',
    'idp_id': provider.idpId,
  };
  final query = params.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return '$authEndpoint?$query';
}

/// Abort signal for a pending OAuth callback wait — mirrors the AbortController
/// wiring in auth/oauthFlow.ts openAuthorizationUrlAndWaitForCode.
class OAuthCancelToken {
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get whenCancelled => _cancelled.future;

  bool get isCancelled => _cancelled.isCompleted;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Thrown when the local OAuth callback server cannot be bound, so callers can
/// fall back to the next redirect port.
class OAuthBindException implements Exception {
  final int port;
  final Object cause;

  const OAuthBindException({required this.port, required this.cause});

  @override
  String toString() => 'Could not bind OAuth callback port $port: $cause';
}

/// Port of auth/oauthFlow.ts findAvailablePort — returns every configured
/// redirect port that can currently be bound, in preference order.
Future<List<int>> findAvailablePorts({
  required Future<int> Function(int port) tryBind,
}) async {
  final available = <int>[];
  for (final port in redirectPorts) {
    if (await tryBind(port) == port) available.add(port);
  }
  return available;
}

/// Port of auth/oauthFlow.ts waitForAuthorizationCode — starts a local HTTP
/// server on 127.0.0.1:port, waits for the OAuth redirect, extracts the code.
/// The server is always torn down: on success, on a bad callback, on timeout,
/// and when [cancelToken] fires.
Future<String> waitForAuthorizationCode(
  int port, {
  required Duration timeout,
  OAuthCancelToken? cancelToken,
}) async {
  final HttpServer server;
  try {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  } catch (cause) {
    throw OAuthBindException(port: port, cause: cause);
  }

  try {
    final request = await _firstRequest(server, timeout, cancelToken);
    final uri = request.uri;
    final code = uri.queryParameters['code'];
    final error = uri.queryParameters['error'];

    const html = '<!doctype html><html><body style="font-family:Segoe UI,Arial,'
        'sans-serif;background:#0b1220;color:#dbe7ff;display:flex;'
        'justify-content:center;align-items:center;height:100vh">'
        '<div style="background:#111a2c;padding:24px 28px;border:1px solid '
        '#30425f;border-radius:12px;max-width:460px">'
        '<h2 style="margin-top:0">Login</h2>'
        '<p>Login complete. You can close this window and return to the app.</p>'
        '</div></body></html>';

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set('Content-Type', 'text/html; charset=utf-8');
    request.response.write(html);
    await request.response.close();

    if (code != null) return code;
    throw StateError(error ?? 'Authorization failed');
  } finally {
    await server.close(force: true);
  }
}

Future<HttpRequest> _firstRequest(
  HttpServer server,
  Duration timeout,
  OAuthCancelToken? cancelToken,
) {
  final requestFuture = server.first.timeout(timeout, onTimeout: () {
    throw StateError('Timed out waiting for OAuth callback');
  });
  if (cancelToken == null) return requestFuture;
  return Future.any([
    requestFuture,
    cancelToken.whenCancelled.then((_) {
      throw StateError('OAuth login was cancelled.');
    }),
  ]);
}

/// Port of auth/oauthFlow.ts openAuthorizationUrlAndWaitForCode — opens the
/// browser and awaits the OAuth redirect. If the browser cannot be opened, the
/// callback wait is aborted immediately so the port is freed and no unhandled
/// async error escapes.
Future<String> openAuthorizationUrlAndWaitForCode({
  required String authUrl,
  required int port,
  required Duration timeout,
  required Future<void> Function(String url) openExternal,
}) async {
  final cancelToken = OAuthCancelToken();
  final codeFuture = waitForAuthorizationCode(
    port,
    timeout: timeout,
    cancelToken: cancelToken,
  );
  try {
    await openExternal(authUrl);
  } catch (_) {
    cancelToken.cancel();
    try {
      await codeFuture;
    } catch (_) {
      // Expected: the wait was just cancelled.
    }
    rethrow;
  }
  return codeFuture;
}

/// Port of auth/oauthFlow.ts exchangeAuthorizationCode
Future<AuthTokens> exchangeAuthorizationCode({
  required http.Client client,
  required String code,
  required String verifier,
  required int port,
  required bool isMac,
  String? authClientId,
}) async {
  final body = {
    'grant_type': 'authorization_code',
    'code': code,
    'redirect_uri': 'http://localhost:$port',
    'code_verifier': verifier,
  };

  final response = await client.post(
    Uri.parse(tokenEndpoint),
    headers: buildAuthHeadersForClient(
      authClientId ?? clientId,
      contentType: 'application/x-www-form-urlencoded; charset=UTF-8',
      includeReferer: true,
      isMac: isMac,
    ),
    body: body,
  );

  if (response.statusCode != 200) {
    throw StateError(
      'Token exchange failed (${response.statusCode}): ${_snippet(response.body)}',
    );
  }

  final payload = TokenResponse.fromJson(
    _decodeJson(response.body),
  );
  return AuthTokens(
    accessToken: payload.accessToken,
    refreshToken: payload.refreshToken,
    idToken: payload.idToken,
    expiresAt: toExpiresAt(payload.expiresIn),
    authClientId: authClientId ?? clientId,
  );
}

/// Build an OAuth login context given the pieces needed.
class OAuthLoginContext {
  final String verifier;
  final String challenge;
  final String deviceId;
  final String nonce;
  final int port;

  const OAuthLoginContext({
    required this.verifier,
    required this.challenge,
    required this.deviceId,
    required this.nonce,
    required this.port,
  });
}

/// Helper to assemble the full OAuth flow inputs.
OAuthLoginContext buildOAuthLoginContext({
  required RandomSource random,
  required String hostname,
  required String username,
  required int port,
}) {
  final (verifier: verifier, challenge: challenge) = generatePkce(random);
  return OAuthLoginContext(
    verifier: verifier,
    challenge: challenge,
    deviceId: generateAuthDeviceId(hostname: hostname, username: username),
    nonce: randomHex(16, random),
    port: port,
  );
}

Map<String, dynamic> _decodeJson(String body) {
  final decoded = Uri.decodeQueryComponent(body);
  // token endpoint returns JSON; body is already JSON text from package:http.
  final value = _tryDecodeJson(body) ?? _tryDecodeJson(decoded);
  if (value is Map<String, dynamic>) return value;
  throw FormatException('Token response was not a JSON object');
}

dynamic _tryDecodeJson(String text) {
  try {
    return const JsonDecoder().convert(text);
  } catch (_) {
    return null;
  }
}

String _snippet(String text) {
  return text.length > 400 ? text.substring(0, 400) : text;
}