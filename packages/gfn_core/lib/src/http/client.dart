import 'dart:convert' show jsonDecode, utf8;
import 'dart:math' show Random;

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;

import '../models/device.dart';
import 'errors.dart';

// Port of OpenNOW clientHeaders.ts + deviceIdentity.ts + deviceId.ts.
// These constants are reverse-engineered from NVIDIA's proprietary API.
// DO NOT change any value.

const gfnWindowsUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 '
    'NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173';

const gfnMacosUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/537.36 GFN-PC/2.0.80.173';

const gfnClientVersion = '2.0.80.173';
const lcarsClientId = 'ec7e38d4-03af-4b58-b131-cfb0495903ab';

const gfnPlayOrigin = 'https://play.geforcenow.com';
const gfnPlayReferer = 'https://play.geforcenow.com/';
const nvidiaFileOrigin = 'https://nvfile';
const nvidiaFileReferer = 'https://nvfile/';

const gfnCloudmatchBetaHostSuffix = 'cloudmatchbeta.nvidiagrid.net';

const defaultStreamingBaseUrl = 'https://prod.cloudmatchbeta.nvidiagrid.net/';

String gfnUserAgentForPlatform({required bool isMac}) =>
    isMac ? gfnMacosUserAgent : gfnWindowsUserAgent;

String gfnJwtAuthorization(String token) => 'GFNJWT $token';

String bearerAuthorization(String token) => 'Bearer $token';

/// Port of deviceIdentity.ts DESKTOP_IDENTITY_BY_PLATFORM — desktop always
/// uses clientPlatformName "windows" even on Linux/macOS (matching OpenNOW),
/// but nv-device-os must match the host OS (WINDOWS/MACOS/LINUX).
class DeviceIdentityResolver {
  // ignore: unused_field - kept for completeness (Windows target)
  static const _windows = GfnDeviceIdentity(
    deviceOs: GfnDeviceOs.windows,
    deviceType: GfnDeviceType.desktop,
    deviceMake: 'UNKNOWN',
    deviceModel: 'UNKNOWN',
    clientPlatformName: 'windows',
  );

  static const _macos = GfnDeviceIdentity(
    deviceOs: GfnDeviceOs.macOS,
    deviceType: GfnDeviceType.desktop,
    deviceMake: 'UNKNOWN',
    deviceModel: 'UNKNOWN',
    clientPlatformName: 'windows',
  );

  static const _linux = GfnDeviceIdentity(
    deviceOs: GfnDeviceOs.linux,
    deviceType: GfnDeviceType.desktop,
    deviceMake: 'UNKNOWN',
    deviceModel: 'UNKNOWN',
    clientPlatformName: 'windows',
  );

  static const steamDeckIdentity = GfnDeviceIdentity(
    deviceOs: GfnDeviceOs.windows,
    deviceType: GfnDeviceType.desktop,
    deviceMake: 'VALVE',
    deviceModel: 'STEAMDECK',
    clientPlatformName: 'SteamOS',
  );

  GfnDeviceIdentity resolve({
    bool identifyAsSteamDeck = false,
    bool isMac = false,
    bool isLinux = false,
  }) {
    if (identifyAsSteamDeck) return steamDeckIdentity;
    if (isMac) return _macos;
    if (isLinux) return _linux;
    // Default to linux identity when platform is unknown — matches next_client
    // target (Linux/Android). Keep WINDOWS available via explicit flag if needed.
    // Use caller-supplied isMac/isLinux; unknown falls through to _linux.
    return _linux;
  }
}

/// Port of auth/helpers.ts generateDeviceId — sha256(host:user:opennow-stable)
String generateDeviceId({required String hostname, required String username}) {
  final digest = sha256.convert('$hostname:$username:opennow-stable'.codeUnits);
  return digest.toString();
}

/// Port of deviceId.ts — stable device id persisted on disk. Uses TokenStorage
/// port keyed 'gfn-device-id'.
String stableDeviceId({
  required String Function() hostname,
  required String Function() username,
  Map<String, String>? tokens,
}) {
  final persisted = tokens?['gfn-device-id'];
  if (persisted != null && persisted.isNotEmpty) return persisted;
  return generateDeviceId(hostname: hostname(), username: username());
}

class NvidiaAuthHeadersOptions {
  final String? bearerToken;
  final String? accept;
  final String? contentType;
  final bool includeReferer;

  const NvidiaAuthHeadersOptions({
    this.bearerToken,
    this.accept,
    this.contentType,
    this.includeReferer = false,
  });
}

/// Port of buildNvidiaAuthHeaders
Map<String, String> buildNvidiaAuthHeaders(
  NvidiaAuthHeadersOptions options, {
  required bool isMac,
}) {
  final headers = <String, String>{};
  final token = options.bearerToken;
  if (token != null) {
    headers['Authorization'] = bearerAuthorization(token);
  }
  final contentType = options.contentType;
  if (contentType != null) {
    headers['Content-Type'] = contentType;
  }
  headers['Origin'] = nvidiaFileOrigin;
  if (options.includeReferer) {
    headers['Referer'] = nvidiaFileReferer;
  }
  headers['Accept'] = options.accept ?? 'application/json, text/plain, */*';
  headers['User-Agent'] = gfnUserAgentForPlatform(isMac: isMac);
  return headers;
}

class GfnLcarsHeadersOptions {
  final String? token;
  final String? clientId;
  final String clientType;
  final String clientStreamer;
  final String? accept;
  final bool includeUserAgent;
  final bool includeEmptyTokenAuthorization;

  const GfnLcarsHeadersOptions({
    this.token,
    this.clientId,
    this.clientType = 'NATIVE',
    this.clientStreamer = 'NVIDIA-CLASSIC',
    this.accept,
    this.includeUserAgent = false,
    this.includeEmptyTokenAuthorization = false,
  });
}

/// Port of buildGfnLcarsHeaders
Map<String, String> buildGfnLcarsHeaders(
  GfnLcarsHeadersOptions options, {
  required bool isMac,
  bool identifyAsSteamDeck = false,
}) {
  final identity = DeviceIdentityResolver().resolve(
    identifyAsSteamDeck: identifyAsSteamDeck,
    isMac: isMac,
  );
  final headers = <String, String>{
    'Accept': options.accept ?? 'application/json',
  };

  final token = options.token;
  if (token != null && token.isNotEmpty ||
      (options.includeEmptyTokenAuthorization && token != null)) {
    headers['Authorization'] = gfnJwtAuthorization(token);
  }

  headers['nv-client-id'] = options.clientId ?? lcarsClientId;
  headers['nv-client-type'] = options.clientType;
  headers['nv-client-version'] = gfnClientVersion;
  headers['nv-client-streamer'] = options.clientStreamer;
  headers.addAll(identity.toNvHeaders());

  if (options.includeUserAgent) {
    headers['User-Agent'] = gfnUserAgentForPlatform(isMac: isMac);
  }

  return headers;
}

/// Port of buildGfnGraphQlHeaders
Map<String, String> buildGfnGraphQlHeaders(
  String? token, {
  required bool isMac,
  bool identifyAsSteamDeck = false,
}) {
  final identity = DeviceIdentityResolver().resolve(
    identifyAsSteamDeck: identifyAsSteamDeck,
    isMac: isMac,
  );
  final headers = <String, String>{
    'Accept': 'application/json, text/plain, */*',
    'Content-Type': 'application/json',
    'Origin': gfnPlayOrigin,
    'Referer': gfnPlayReferer,
    if (token != null) 'Authorization': gfnJwtAuthorization(token),
    'nv-client-id': lcarsClientId,
    'nv-client-type': 'NATIVE',
    'nv-client-version': gfnClientVersion,
    'nv-client-streamer': 'NVIDIA-CLASSIC',
    'nv-browser-type': 'CHROME',
    'User-Agent': gfnUserAgentForPlatform(isMac: isMac),
  };
  headers.addAll(identity.toNvHeaders());
  return headers;
}

class GfnCloudMatchHeadersOptions {
  final String token;
  final String? clientId;
  final String? deviceId;
  final bool includeOrigin;
  final bool identifyAsSteamDeck;

  const GfnCloudMatchHeadersOptions({
    required this.token,
    this.clientId,
    this.deviceId,
    this.includeOrigin = true,
    this.identifyAsSteamDeck = false,
  });
}

String randomUuid() => _uuidV4();

/// Minimal RFC 4122 v4 UUID generator (no external dep).
String _uuidV4() {
  final random = _cryptoRandom();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Random _cryptoRandom() => Random.secure();

/// Port of buildGfnCloudMatchHeaders
Map<String, String> buildGfnCloudMatchHeaders(
  GfnCloudMatchHeadersOptions options, {
  required bool isMac,
}) {
  final identity = DeviceIdentityResolver().resolve(
    identifyAsSteamDeck: options.identifyAsSteamDeck,
    isMac: isMac,
  );
  final headers = <String, String>{
    'User-Agent': gfnUserAgentForPlatform(isMac: isMac),
    'Authorization': gfnJwtAuthorization(options.token),
    'Content-Type': 'application/json',
    'nv-browser-type': 'CHROME',
    'nv-client-id': options.clientId ?? _uuidV4(),
    'nv-client-streamer': 'NVIDIA-CLASSIC',
    'nv-client-type': 'NATIVE',
    'nv-client-version': gfnClientVersion,
    'x-device-id': options.deviceId ?? _uuidV4(),
  };
  headers.addAll(identity.toNvHeaders());
  if (options.includeOrigin) {
    headers['Origin'] = gfnPlayOrigin;
    headers['Referer'] = gfnPlayReferer;
  }
  return headers;
}

/// Port of buildGfnCloudMatchClaimHeaders
Map<String, String> buildGfnCloudMatchClaimHeaders(
  GfnCloudMatchHeadersOptions options, {
  required bool isMac,
}) {
  final identity = DeviceIdentityResolver().resolve(
    identifyAsSteamDeck: options.identifyAsSteamDeck,
    isMac: isMac,
  );
  final headers = <String, String>{
    'User-Agent': gfnUserAgentForPlatform(isMac: isMac),
    'Authorization': gfnJwtAuthorization(options.token),
    'Content-Type': 'application/json',
    'Origin': gfnPlayOrigin,
    'Referer': gfnPlayReferer,
    'nv-client-id': options.clientId ?? _uuidV4(),
    'nv-client-streamer': 'NVIDIA-CLASSIC',
    'nv-client-type': 'NATIVE',
    'nv-client-version': gfnClientVersion,
    'x-device-id': options.deviceId ?? _uuidV4(),
  };
  headers.addAll(identity.toNvHeaders());
  return headers;
}

/// Port of endpoints.ts buildGfnZoneStreamingBaseUrl
String buildGfnZoneStreamingBaseUrl(String zoneId) {
  return 'https://${zoneId.toLowerCase()}.$gfnCloudmatchBetaHostSuffix/';
}

/// Port of endpoints.ts isStandardGfnZone
bool isStandardGfnZone(String zoneId) {
  return zoneId.startsWith('NP-') && !zoneId.startsWith('NPA-');
}

class CloudMatchHttpClient {
  final http.Client _client;
  final bool isMac;

  CloudMatchHttpClient({http.Client? client, this.isMac = false})
      : _client = client ?? http.Client();

  http.Client get client => _client;

  /// Port of request.ts readCloudMatchJson
  Future<({String text, T payload})> readCloudMatchJson<T>(
    http.Response response, {
    void Function(String text)? onText,
    void Function(String text)? onErrorText,
  }) async {
    final text = _decodeBody(response);
    onText?.call(text);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      onErrorText?.call(text);
      throw SessionError.fromResponse(response.statusCode, text);
    }
    return (text: text, payload: jsonDecode(text) as T);
  }

  /// Port of request.ts throwIfCloudMatchResponseError
  Future<void> throwIfCloudMatchResponseError(http.Response response) async {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    final text = _decodeBody(response);
    throw SessionError.fromResponse(response.statusCode, text);
  }

  String _decodeBody(http.Response response) {
    final body = response.body;
    if (body.isEmpty) {
      final encoding = response.bodyBytes.isNotEmpty
          ? utf8.decode(response.bodyBytes)
          : '';
      return encoding;
    }
    return body;
  }
}

/// Port of cloudmatchTransport.ts normalizeCloudMatchBaseUrl
String normalizeCloudMatchBaseUrl(String url) {
  var trimmed = url.trim();
  final hasProtocol = RegExp(r'^https?://', caseSensitive: false).hasMatch(trimmed);
  if (!hasProtocol) trimmed = 'https://$trimmed';
  if (trimmed.endsWith('/')) trimmed = trimmed.substring(0, trimmed.length - 1);
  return trimmed;
}

/// Port of cloudmatchTransport.ts cloudmatchUrl
String cloudmatchUrl(String zone) {
  return 'https://$zone.cloudmatchbeta.nvidiagrid.net';
}

/// Port of cloudmatchTransport.ts resolveStreamingBaseUrl
String resolveStreamingBaseUrl(String zone, String? provided) {
  if (provided != null && provided.trim().isNotEmpty) {
    var trimmed = provided.trim();
    if (trimmed.endsWith('/')) trimmed = trimmed.substring(0, trimmed.length - 1);
    return trimmed;
  }
  return cloudmatchUrl(zone);
}

/// Port of cloudmatchTransport.ts shouldUseServerIp
bool shouldUseServerIp(String baseUrl) {
  return baseUrl.contains('cloudmatchbeta.nvidiagrid.net');
}

/// Port of cloudmatchTransport.ts isZoneHostname
bool isZoneHostname(String ip) {
  var hostname = ip.trim().toLowerCase();
  if (hostname.endsWith('.')) {
    hostname = hostname.substring(0, hostname.length - 1);
  }
  const domains = ['cloudmatchbeta.nvidiagrid.net', 'cloudmatch.nvidiagrid.net'];
  for (final domain in domains) {
    if (hostname == domain || hostname.endsWith('.$domain')) return true;
  }
  return false;
}

/// Port of cloudmatchTransport.ts resolvePollStopBase
String resolvePollStopBase(String zone, String? provided, String? serverIp) {
  final base = resolveStreamingBaseUrl(zone, provided);
  if (serverIp != null &&
      serverIp.isNotEmpty &&
      shouldUseServerIp(base) &&
      !isZoneHostname(serverIp)) {
    return 'https://$serverIp';
  }
  return base;
}

/// Port of cloudmatchTransport.ts formatErrorForLog
String formatErrorForLog(Object error) {
  if (error is SessionError) {
    return '${error.title}: ${error.description}';
  }
  return error.toString();
}