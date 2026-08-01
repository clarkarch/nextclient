import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' show Random;

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;

import '../http/client.dart'
    show GfnCloudMatchHeadersOptions, buildGfnCloudMatchHeaders;
import '../models/session.dart';
import 'features.dart'
    show
        appLaunchModeWireValue,
        buildRequestedStreamingFeatures,
        parseResolution,
        shouldEnableInGameSettingsPersistence,
        timezoneOffsetMs;

// Port of cloudmatchSessionRequest.ts. The request body shapes below are the
// exact NVIDIA CloudMatch API format reverse-engineered by OpenNOW. Do not
// add/remove/rename fields.

const networkTestSessionTimeoutMs = 8000;
const networkTestSessionCacheTtlMs = 30 * 60 * 1000;

class NetworkTestSessionCache {
  final Map<String, ({String sessionId, int expiresAt})> _cache = {};

  String _cacheKey({
    required String base,
    required StreamSettings settings,
    required String token,
    required int nowMillis,
  }) {
    final resolution = parseResolution(settings.resolution);
    final identityHash = sha256Hex(
      '$token\u0000',
    );
    return '$base\u0000${resolution.width}x${resolution.height}@${settings.fps}\u0000$identityHash';
  }

  String? getCached({
    required String base,
    required StreamSettings settings,
    required String token,
    required int nowMillis,
  }) {
    final key = _cacheKey(base: base, settings: settings, token: token, nowMillis: nowMillis);
    final cached = _cache[key];
    if (cached == null) return null;
    if (cached.expiresAt <= nowMillis) {
      _cache.remove(key);
      return null;
    }
    return cached.sessionId;
  }

  void cache({
    required String base,
    required StreamSettings settings,
    required String token,
    required int nowMillis,
    required String sessionId,
  }) {
    final key = _cacheKey(base: base, settings: settings, token: token, nowMillis: nowMillis);
    _cache[key] = (sessionId: sessionId, expiresAt: nowMillis + networkTestSessionCacheTtlMs);
  }
}

String sha256Hex(String input) {
  return sha256.convert(input.codeUnits).toString().substring(0, 16);
}

/// Port of cloudmatchSessionRequest.ts createNetworkTestSession
Future<String?> createNetworkTestSession({
  required http.Client client,
  required String base,
  required String token,
  required String clientId,
  required String deviceId,
  required StreamSettings settings,
  required bool isMac,
  required int nowMillis,
  NetworkTestSessionCache? cache,
}) async {
  final effectiveCache = cache ?? NetworkTestSessionCache();
  final cached = effectiveCache.getCached(
    base: base,
    settings: settings,
    token: token,
    nowMillis: nowMillis,
  );
  if (cached != null) return cached;

  final resolution = parseResolution(settings.resolution);
  final body = {
    'netTestRequestData': {
      'clientPlatformName': 'windows',
      'netTestProfile': {
        'widthInPixels': resolution.width,
        'heightInPixels': resolution.height,
        'framesPerSecond': settings.fps,
      },
    },
  };

  try {
    final response = await client
        .post(
          Uri.parse('$base/v2/nettestsession'),
          headers: buildGfnCloudMatchHeaders(
            GfnCloudMatchHeadersOptions(
              token: token,
              clientId: clientId,
              deviceId: deviceId,
              includeOrigin: true,
            ),
            isMac: isMac,
          ),
          body: jsonEncode(body),
        )
        .timeout(const Duration(milliseconds: networkTestSessionTimeoutMs));

    if (response.statusCode != 200) {
      return null;
    }

    final decoded = jsonDecode(response.body);
    final requestStatus = decoded is Map ? decoded['requestStatus'] : null;
    if (requestStatus is Map && (requestStatus['statusCode'] as num?)?.toInt() != 1) {
      return null;
    }

    final netTestSession = decoded is Map ? decoded['netTestSession'] : null;
    final sessionId =
        netTestSession is Map ? netTestSession['sessionId'] as String? : null;
    if (sessionId == null || sessionId.trim().isEmpty) return null;

    effectiveCache.cache(
      base: base,
      settings: settings,
      token: token,
      nowMillis: nowMillis,
      sessionId: sessionId.trim(),
    );
    return sessionId.trim();
  } catch (_) {
    return null;
  }
}

/// Port of webRtcSessionMetadata
List<Map<String, String>> webRtcSessionMetadata(int width, int height) {
  return [
    {'key': 'SubSessionId', 'value': _uuidV4()},
    {'key': 'wssignaling', 'value': '1'},
    {'key': 'GSStreamerType', 'value': 'WebRTC'},
    {'key': 'networkType', 'value': 'Unknown'},
    {'key': 'ClientImeSupport', 'value': '0'},
    {
      'key': 'clientPhysicalResolution',
      'value': '{"horizontalPixels":$width,"verticalPixels":$height}',
    },
    {'key': 'surroundAudioInfo', 'value': '2'},
  ];
}

/// Port of buildSessionRequestBody
Map<String, dynamic> buildSessionRequestBody({
  required String appId,
  required String? internalTitle,
  required StreamSettings settings,
  required String deviceHashId,
  required String clientPlatformName,
  String? networkTestSessionId,
  bool accountLinked = true,
  bool enablePersistingInGameSettings = false,
  bool supportsInGameSettingsPersistence = false,
}) {
  final resolution = parseResolution(settings.resolution);
  final cq = settings.colorQuality;
  // hdrEnabled is a SEPARATE toggle from color quality (see OpenNOW comment).
  // 10-bit color depth does NOT mean HDR. Conflating them caused the server to
  // set up an HDR pipeline that downscaled resolution to ~540p.
  final hdrEnabled = false;
  final bitDepth = cq.bitDepth;
  final chromaFormat = cq.chromaFormat;

  return {
    'sessionRequestData': {
      'appId': appId,
      'internalTitle': internalTitle,
      'availableSupportedControllers': <Object>[],
      'networkTestSessionId': networkTestSessionId,
      'parentSessionId': null,
      'clientIdentification': 'GFN-PC',
      'deviceHashId': deviceHashId,
      'clientVersion': '30.0',
      'sdkVersion': '1.0',
      'streamerVersion': 1,
      'clientPlatformName': clientPlatformName,
      'clientRequestMonitorSettings': [
        {
          'monitorId': 0,
          'positionX': 0,
          'positionY': 0,
          'widthInPixels': resolution.width,
          'heightInPixels': resolution.height,
          'framesPerSecond': settings.fps,
          'sdrHdrMode': 0,
          'displayData': <String, dynamic>{},
          'hdr10PlusGamingData': null,
          'dpi': 0,
        },
      ],
      'useOps': true,
      'audioMode': 2,
      'metaData': webRtcSessionMetadata(resolution.width, resolution.height),
      'sdrHdrMode': 0,
      'clientDisplayHdrCapabilities': null,
      'surroundAudioInfo': 0,
      'remoteControllersBitmap': 0,
      'clientTimezoneOffset': timezoneOffsetMs(),
      'enhancedStreamMode': 1,
      'appLaunchMode': appLaunchModeWireValue(settings.appLaunchMode),
      'secureRTSPSupported': false,
      'partnerCustomData': '',
      'accountLinked': accountLinked,
      'enablePersistingInGameSettings': shouldEnableInGameSettingsPersistence(
        enablePersistingInGameSettings: enablePersistingInGameSettings,
        supportsInGameSettingsPersistence: supportsInGameSettingsPersistence,
      ),
      'userAge': 26,
      'requestedStreamingFeatures': buildRequestedStreamingFeatures(
        settings: settings,
        bitDepth: bitDepth,
        chromaFormat: chromaFormat,
        hdrEnabled: hdrEnabled,
      ),
    },
  };
}

/// Port of buildClaimRequestBody — minimal fields for RESUME (NO streaming
/// parameter renegotiation; sending fps/resolution/codec causes HTTP 400).
Map<String, dynamic> buildClaimRequestBody({
  required String sessionId,
  required String appId,
  required int? sessionAppLaunchMode,
  required String deviceHashId,
  required String clientPlatformName,
  bool enablePersistingInGameSettings = false,
}) {
  final subSessionId = _uuidV4();
  final timezoneMs = timezoneOffsetMs();
  final appLaunchMode = sessionAppLaunchMode ?? 1;

  return {
    'action': 2,
    'data': 'RESUME',
    'sessionRequestData': {
      'audioMode': 2,
      'remoteControllersBitmap': 0,
      'sdrHdrMode': 0,
      'networkTestSessionId': null,
      'availableSupportedControllers': <Object>[],
      'clientVersion': '30.0',
      'deviceHashId': deviceHashId,
      'internalTitle': null,
      'clientPlatformName': clientPlatformName,
      'metaData': [
        {'key': 'SubSessionId', 'value': subSessionId},
        {'key': 'wssignaling', 'value': '1'},
        {'key': 'GSStreamerType', 'value': 'WebRTC'},
        {'key': 'networkType', 'value': 'Unknown'},
        {'key': 'ClientImeSupport', 'value': '0'},
        {'key': 'surroundAudioInfo', 'value': '2'},
      ],
      'surroundAudioInfo': 0,
      'clientTimezoneOffset': timezoneMs,
      'clientIdentification': 'GFN-PC',
      'parentSessionId': null,
      'appId': int.tryParse(appId) ?? 0,
      'streamerVersion': 1,
      'appLaunchMode': appLaunchMode,
      'sdkVersion': '1.0',
      'enhancedStreamMode': 1,
      'useOps': true,
      'clientDisplayHdrCapabilities': null,
      'accountLinked': true,
      'partnerCustomData': '',
      'enablePersistingInGameSettings': enablePersistingInGameSettings,
      'secureRTSPSupported': false,
      'userAge': 26,
    },
    'metaData': <Object>[],
  };
}

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}