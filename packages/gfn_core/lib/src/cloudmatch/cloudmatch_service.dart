import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:math' show Random;

import 'package:http/http.dart' as http;

import '../http/client.dart'
    show
        GfnCloudMatchHeadersOptions,
        buildGfnCloudMatchClaimHeaders,
        buildGfnCloudMatchHeaders,
        isZoneHostname,
        normalizeCloudMatchBaseUrl;
import '../http/errors.dart' show SessionError;
import '../models/cloudmatch_types.dart';
import '../models/session.dart';
import 'session_parsing.dart' show toSessionInfo;
import 'session_request.dart'
    show buildClaimRequestBody, buildSessionRequestBody, createNetworkTestSession;
import 'signaling.dart'
    show isReadySessionStatus, resolveSignaling, streamingServerIp;
import 'transport.dart'
    show extractServerInfoRegionBases, fetchCloudMatch, resolveCreateSessionBase;

// Port of cloudmatch.ts (createSession, pollSession, claimSession,
// stopSession, getActiveSessions). GPU/device id + network test session are
// simplified but the wire request bodies match OpenNOW exactly.

class CloudMatchService {
  final http.Client client;
  final bool isMac;
  final String Function() stableDeviceId;

  CloudMatchService({
    required this.client,
    required this.isMac,
    required this.stableDeviceId,
  });

  /// Port of cloudmatch.ts createSession
  Future<SessionInfo> createSession(SessionCreateRequest input) async {
    final token = input.token;
    if (token == null || token.isEmpty) {
      throw StateError('Missing token for session creation');
    }
    if (!RegExp(r'^\d+$').hasMatch(input.appId)) {
      throw StateError('Invalid launch appId "${input.appId}" (must be numeric)');
    }

    final clientId = _uuidV4();
    final deviceId = stableDeviceId();

    final base = await resolveCreateSessionBase(
      client: client,
      base: _resolveStreamingBase(input.zone, input.streamingBaseUrl),
      token: token,
      clientId: clientId,
      deviceId: deviceId,
      isMac: isMac,
    );

    final networkTestSessionId = await createNetworkTestSession(
      client: client,
      base: base,
      token: token,
      clientId: clientId,
      deviceId: deviceId,
      settings: input.settings,
      isMac: isMac,
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );

    final body = buildSessionRequestBody(
      appId: input.appId,
      internalTitle: input.internalTitle,
      settings: input.settings,
      deviceHashId: deviceId,
      clientPlatformName: 'windows',
      networkTestSessionId: networkTestSessionId,
      accountLinked: input.accountLinked ?? true,
      enablePersistingInGameSettings: input.enablePersistingInGameSettings ?? false,
      supportsInGameSettingsPersistence:
          input.supportsInGameSettingsPersistence ?? false,
    );

    final query = Uri(queryParameters: {
      'keyboardLayout': _keyboardLayoutWire(input.settings.keyboardLayout),
      'languageCode': _languageCodeWire(input.settings.gameLanguage),
    }).query;

    final url = '$base/v2/session?$query';
    final response = await fetchCloudMatch(
      client: client,
      url: url,
      method: 'POST',
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
    );

    final text = _decodeBody(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SessionError.fromResponse(response.statusCode, text);
    }
    final payload = CloudMatchResponse.fromJson(
      _decodeObject(text),
    );

    return toSessionInfo(
      zone: input.zone,
      streamingBaseUrl: base,
      payload: payload,
      clientId: clientId,
      deviceId: deviceId,
      fallbackAppId: input.appId,
      fallbackAppLaunchMode: _appLaunchModeWire(input.settings.appLaunchMode),
    );
  }

  /// Port of cloudmatch.ts pollSession
  Future<SessionInfo> pollSession(SessionPollRequest input) async {
    final token = input.token;
    if (token == null || token.isEmpty) {
      throw StateError('Missing token for session polling');
    }
    final clientId = input.clientId ?? _uuidV4();
    final deviceId = input.deviceId ?? _uuidV4();

    final base = _resolvePollStopBase(input.zone, input.streamingBaseUrl, input.serverIp);
    final baseHost = Uri.parse(base).host;

    final url = '$base/v2/session/${input.sessionId}';
    final headers = buildGfnCloudMatchHeaders(
      GfnCloudMatchHeadersOptions(
        token: token,
        clientId: clientId,
        deviceId: deviceId,
        includeOrigin: false,
      ),
      isMac: isMac,
    );

    final response = await fetchCloudMatch(
      client: client,
      url: url,
      method: 'GET',
      headers: headers,
    );

    final text = _decodeBody(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SessionError.fromResponse(response.statusCode, text);
    }
    final payload = CloudMatchResponse.fromJson(_decodeObject(text));

    // Match Rust: if polled via zone LB and response has a real server IP,
    // re-poll directly via that IP.
    final realServerIp = streamingServerIp(payload);
    final polledViaZone = isZoneHostname(baseHost);
    final realIpDiffers = realServerIp != null &&
        realServerIp.isNotEmpty &&
        !isZoneHostname(realServerIp) &&
        realServerIp != input.serverIp;

    if (polledViaZone && realIpDiffers && isReadySessionStatus(payload.session.status)) {
      final directBase = 'https://$realServerIp';
      final directUrl = '$directBase/v2/session/${input.sessionId}';
      try {
        final directResponse = await fetchCloudMatch(
          client: client,
          url: directUrl,
          method: 'GET',
          headers: headers,
        );
        if (directResponse.statusCode >= 200 && directResponse.statusCode < 300) {
          final directPayload = CloudMatchResponse.fromJson(
            _decodeObject(_decodeBody(directResponse)),
          );
          if (directPayload.requestStatus.statusCode == 1) {
            return toSessionInfo(
              zone: input.zone,
              streamingBaseUrl: directBase,
              payload: directPayload,
              clientId: clientId,
              deviceId: deviceId,
            );
          }
        }
      } catch (_) {
        // Direct poll failed — fall through to zone LB response.
      }
    }

    return toSessionInfo(
      zone: input.zone,
      streamingBaseUrl: base,
      payload: payload,
      clientId: clientId,
      deviceId: deviceId,
    );
  }

  /// Port of cloudmatch.ts stopSession
  Future<void> stopSession(SessionStopRequest input) async {
    final token = input.token;
    if (token == null || token.isEmpty) {
      throw StateError('Missing token for session stop');
    }
    final clientId = input.clientId ?? _uuidV4();
    final deviceId = input.deviceId ?? _uuidV4();

    final base = _resolvePollStopBase(input.zone, input.streamingBaseUrl, input.serverIp);
    final url = '$base/v2/session/${input.sessionId}';

    final response = await fetchCloudMatch(
      client: client,
      url: url,
      method: 'DELETE',
      headers: buildGfnCloudMatchHeaders(
        GfnCloudMatchHeadersOptions(
          token: token,
          clientId: clientId,
          deviceId: deviceId,
          includeOrigin: false,
        ),
        isMac: isMac,
      ),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SessionError.fromResponse(
        response.statusCode,
        _decodeBody(response),
      );
    }
  }

  /// Port of cloudmatch.ts getActiveSessions
  Future<List<ActiveSessionInfo>> getActiveSessions({
    required String token,
    required String streamingBaseUrl,
  }) async {
    final base = normalizeCloudMatchBaseUrl(streamingBaseUrl);
    final headers = buildGfnCloudMatchHeaders(
      GfnCloudMatchHeadersOptions(
        token: token,
        deviceId: stableDeviceId(),
        includeOrigin: false,
      ),
      isMac: isMac,
    );

    final primary = await _fetchActiveSessionsFromBase(base, headers);
    if (primary != null) return primary;

    final fallbackBases = await _discoverFallbackBases(base, headers);
    for (final fallbackBase in fallbackBases) {
      if (fallbackBase == base) continue;
      final fallback = await _fetchActiveSessionsFromBase(fallbackBase, headers);
      if (fallback != null) return fallback;
    }

    return const [];
  }

  /// Port of cloudmatch.ts claimSession — claim/resume an existing session.
  Future<SessionInfo> claimSession(SessionClaimRequest input) async {
    final token = input.token;
    if (token == null || token.isEmpty) {
      throw StateError('Missing token for session claim');
    }
    final deviceId = input.deviceId ?? stableDeviceId();
    final clientId = input.clientId ?? _uuidV4();
    final appId = input.appId ?? '0';
    final settings = input.settings;

    var effectiveServerIp = input.serverIp;
    if (effectiveServerIp.isEmpty) {
      // The active-session listing may omit a direct server IP (no usage-14
      // connection info). Fall back to the host of the streaming base URL the
      // session was discovered on — a zone LB hostname, which the prefetch
      // below resolves to the real server IP.
      final fallbackBase = Uri.tryParse(input.streamingBaseUrl ?? '');
      if (fallbackBase != null && fallbackBase.host.isNotEmpty) {
        effectiveServerIp = fallbackBase.host;
      }
    }
    if (effectiveServerIp.isEmpty) {
      throw StateError(
        'Missing server IP / streaming base URL for session claim',
      );
    }
    if (isZoneHostname(effectiveServerIp)) {
      final zoneBase = 'https://$effectiveServerIp';
      final prefetchUrl = '$zoneBase/v2/session/${input.sessionId}';
      final prefetchHeaders = buildGfnCloudMatchHeaders(
        GfnCloudMatchHeadersOptions(
          token: token,
          clientId: clientId,
          deviceId: deviceId,
          includeOrigin: false,
        ),
        isMac: isMac,
      );
      try {
        final prefetchResp = await fetchCloudMatch(
          client: client,
          url: prefetchUrl,
          method: 'GET',
          headers: prefetchHeaders,
        );
        if (prefetchResp.statusCode >= 200 && prefetchResp.statusCode < 300) {
          final prefetchPayload = CloudMatchResponse.fromJson(
            _decodeObject(_decodeBody(prefetchResp)),
          );
          final realIp = streamingServerIp(prefetchPayload);
          if (realIp != null) effectiveServerIp = realIp;
        }
      } catch (_) {}
    }

    final query = Uri(queryParameters: {
      'keyboardLayout': _keyboardLayoutWire(settings?.keyboardLayout),
      'languageCode': _languageCodeWire(settings?.gameLanguage),
    }).query;
    final claimUrl =
        'https://$effectiveServerIp/v2/session/${input.sessionId}?$query';

    // Pre-claim validation.
    var preClaimStatus = 0;
    var shouldSendResumeClaim = true;
    try {
      final validationUrl = 'https://$effectiveServerIp/v2/session/${input.sessionId}';
      final validationHeaders = buildGfnCloudMatchHeaders(
        GfnCloudMatchHeadersOptions(
          token: token,
          clientId: clientId,
          deviceId: deviceId,
          includeOrigin: false,
        ),
        isMac: isMac,
      );
      final validationResp = await fetchCloudMatch(
        client: client,
        url: validationUrl,
        method: 'GET',
        headers: validationHeaders,
      );
      if (validationResp.statusCode >= 200 && validationResp.statusCode < 300) {
        final validationPayload = CloudMatchResponse.fromJson(
          _decodeObject(_decodeBody(validationResp)),
        );
        preClaimStatus = validationPayload.session.status;
        if (preClaimStatus == 1) {
          // Still launching — skip RESUME claim, poll directly.
        } else if (input.recoveryMode == true &&
            (preClaimStatus == 2 || preClaimStatus == 3)) {
          shouldSendResumeClaim = false;
        }
      }
    } catch (_) {}

    if (preClaimStatus != 1 && shouldSendResumeClaim) {
      final payload = buildClaimRequestBody(
        sessionId: input.sessionId,
        appId: appId,
        sessionAppLaunchMode: input.appLaunchMode,
        deviceHashId: deviceId,
        clientPlatformName: 'windows',
        enablePersistingInGameSettings:
            input.enablePersistingInGameSettings == true,
      );

      final claimHeaders = buildGfnCloudMatchClaimHeaders(
        GfnCloudMatchHeadersOptions(
          token: token,
          clientId: clientId,
          deviceId: deviceId,
        ),
        isMac: isMac,
      );

      final response = await fetchCloudMatch(
        client: client,
        url: claimUrl,
        method: 'PUT',
        headers: claimHeaders,
        body: jsonEncode(payload),
      );

      final text = _decodeBody(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SessionError.fromResponse(response.statusCode, text);
      }
      final apiResponse = CloudMatchResponse.fromJson(_decodeObject(text));
      if (apiResponse.requestStatus.statusCode != 1) {
        throw SessionError.fromResponse(200, text);
      }
    }

    // Poll until ready (status 2 or 3).
    final getUrl = 'https://$effectiveServerIp/v2/session/${input.sessionId}';
    const maxAttempts = 60;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (attempt > 1) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      final pollHeaders = buildGfnCloudMatchHeaders(
        GfnCloudMatchHeadersOptions(
          token: token,
          clientId: clientId,
          deviceId: deviceId,
          includeOrigin: false,
        ),
        isMac: isMac,
      );
      final pollResponse = await fetchCloudMatch(
        client: client,
        url: getUrl,
        method: 'GET',
        headers: pollHeaders,
      );
      if (pollResponse.statusCode < 200 || pollResponse.statusCode >= 300) {
        continue;
      }
      final pollApiResponse = CloudMatchResponse.fromJson(
        _decodeObject(_decodeBody(pollResponse)),
      );
      final sessionStatus = pollApiResponse.session.status;
      if (sessionStatus == 2 || sessionStatus == 3) {
        final signaling = resolveSignaling(pollApiResponse);
        return SessionInfo(
          sessionId: pollApiResponse.session.sessionId,
          appId: input.appId,
          status: sessionStatus,
          zone: '',
          streamingBaseUrl: 'https://$effectiveServerIp',
          serverIp: signaling.serverIp,
          signalingServer: signaling.signalingServer,
          signalingUrl: signaling.signalingUrl,
          gpuType: pollApiResponse.session.gpuType,
          appLaunchMode:
              input.appLaunchMode,
          rtspsEndpoints: signaling.rtspsEndpoints,
          iceServers: await _normalizeIceServersSimple(pollApiResponse),
          mediaConnectionInfo: signaling.mediaConnectionInfo,
          clientId: clientId,
          deviceId: deviceId,
        );
      }
      if (sessionStatus > 3 && sessionStatus != 6) break;
    }

    throw StateError('Session did not become ready after claiming');
  }

  Future<List<ActiveSessionInfo>?> _fetchActiveSessionsFromBase(
    String base,
    Map<String, String> headers,
  ) async {
    final url = '$base/v2/session';
    http.Response response;
    try {
      response = await fetchCloudMatch(
        client: client,
        url: url,
        method: 'GET',
        headers: headers,
        retries: 0,
      );
    } catch (_) {
      return null;
    }
    final text = _decodeBody(response);
    if (response.statusCode < 200 || response.statusCode >= 300) return null;

    Map<String, dynamic> decoded;
    try {
      decoded = _decodeObject(text);
    } catch (_) {
      return const [];
    }

    final status = decoded['requestStatus'];
    if (status is Map && (status['statusCode'] as num?)?.toInt() != 1) {
      return const [];
    }

    final sessions = decoded['sessions'];
    if (sessions is! List) return const [];

    final active = <ActiveSessionInfo>[];
    for (final s in sessions) {
      if (s is! Map<String, dynamic>) continue;
      final statusCode = (s['status'] as num?)?.toInt() ?? 0;
      if (statusCode != 1 && statusCode != 2 && statusCode != 3) continue;

      final requestData = s['sessionRequestData'];
      final rawAppId = requestData is Map ? requestData['appId'] : null;
      final appId = _asNumericAppId(rawAppId) ?? 0;
      final rawAppLaunchMode = requestData is Map ? requestData['appLaunchMode'] : null;
      final appLaunchMode =
          rawAppLaunchMode is num && rawAppLaunchMode.isFinite
              ? rawAppLaunchMode.truncate()
              : null;

      final connInfo = s['connectionInfo'];
      String? serverIp;
      String? signalingUrl;
      if (connInfo is List) {
        for (final conn in connInfo) {
          if (conn is! Map) continue;
          if ((conn['usage'] as num?)?.toInt() == 14 && conn['ip'] is String) {
            serverIp = conn['ip'] as String;
            break;
          }
        }
      }
      if (serverIp != null) {
        signalingUrl = 'wss://$serverIp:443/nvst/';
      }

      final monitorSettings = s['monitorSettings'];
      String? resolution;
      int? fps;
      if (monitorSettings is List && monitorSettings.isNotEmpty) {
        final monitor = monitorSettings.first;
        if (monitor is Map) {
          final width = (monitor['widthInPixels'] as num?)?.toInt() ?? 0;
          final height = (monitor['heightInPixels'] as num?)?.toInt() ?? 0;
          if (width > 0 && height > 0) resolution = '${width}x$height';
          fps = (monitor['framesPerSecond'] as num?)?.toInt();
        }
      }

      active.add(ActiveSessionInfo(
        sessionId: s['sessionId'] as String,
        appId: appId,
        appLaunchMode: appLaunchMode,
        gpuType: s['gpuType'] as String?,
        status: statusCode,
        queuePosition: (s['queuePosition'] as num?)?.toInt(),
        streamingBaseUrl: base,
        serverIp: serverIp,
        signalingUrl: signalingUrl,
        resolution: resolution,
        fps: fps,
      ));
    }
    return active;
  }

  Future<List<String>> _discoverFallbackBases(
    String base,
    Map<String, String> headers,
  ) async {
    try {
      final response = await fetchCloudMatch(
        client: client,
        url: '$base/v2/serverInfo',
        method: 'GET',
        headers: headers,
      );
      if (response.statusCode != 200) return const [];
      return extractServerInfoRegionBases(
        _decodeObject(_decodeBody(response)),
      );
    } catch (_) {
      return const [];
    }
  }

  String _resolveStreamingBase(String zone, String? provided) {
    if (provided != null && provided.trim().isNotEmpty) {
      var trimmed = provided.trim();
      if (trimmed.endsWith('/')) {
        trimmed = trimmed.substring(0, trimmed.length - 1);
      }
      return trimmed;
    }
    return 'https://$zone.cloudmatchbeta.nvidiagrid.net';
  }

  /// NVIDIA echoes appId as a number or a numeric string. Normalize both.
  int? _asNumericAppId(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
    return null;
  }

  String _resolvePollStopBase(String zone, String? provided, String? serverIp) {
    final base = _resolveStreamingBase(zone, provided);
    if (serverIp != null &&
        serverIp.isNotEmpty &&
        base.contains('cloudmatchbeta.nvidiagrid.net') &&
        !isZoneHostname(serverIp)) {
      return 'https://$serverIp';
    }
    return base;
  }

  String _keyboardLayoutWire(KeyboardLayout? layout) {
    if (layout == null) return 'en-US';
    const values = {
      KeyboardLayout.enUs: 'en-US',
      KeyboardLayout.enGb: 'en-GB',
      KeyboardLayout.trTr: 'tr-TR',
      KeyboardLayout.deDe: 'de-DE',
      KeyboardLayout.frFr: 'fr-FR',
      KeyboardLayout.esEs: 'es-ES',
      KeyboardLayout.esMx: 'es-MX',
      KeyboardLayout.itIt: 'it-IT',
      KeyboardLayout.ptPt: 'pt-PT',
      KeyboardLayout.ptBr: 'pt-BR',
      KeyboardLayout.plPl: 'pl-PL',
      KeyboardLayout.daDk: 'da-DK',
      KeyboardLayout.nbNo: 'nb-NO',
      KeyboardLayout.svSe: 'sv-SE',
      KeyboardLayout.fiFi: 'fi-FI',
      KeyboardLayout.ruRu: 'ru-RU',
      KeyboardLayout.jaJp: 'ja-JP',
      KeyboardLayout.koKr: 'ko-KR',
      KeyboardLayout.zhCn: 'zh-CN',
      KeyboardLayout.zhTw: 'zh-TW',
    };
    return values[layout] ?? 'en-US';
  }

  String _languageCodeWire(GameLanguage? language) {
    if (language == null) return 'en_US';
    const values = {
      GameLanguage.enUS: 'en_US',
      GameLanguage.enGB: 'en_GB',
      GameLanguage.deDE: 'de_DE',
      GameLanguage.frFR: 'fr_FR',
      GameLanguage.esES: 'es_ES',
      GameLanguage.esMX: 'es_MX',
      GameLanguage.itIT: 'it_IT',
      GameLanguage.ptPT: 'pt_PT',
      GameLanguage.ptBR: 'pt_BR',
      GameLanguage.ruRU: 'ru_RU',
      GameLanguage.plPL: 'pl_PL',
      GameLanguage.trTR: 'tr_TR',
      GameLanguage.jaJP: 'ja_JP',
      GameLanguage.koKR: 'ko_KR',
      GameLanguage.zhCN: 'zh_CN',
    };
    return values[language] ?? 'en_US';
  }

  int _appLaunchModeWire(AppLaunchMode? mode) {
    const values = <AppLaunchMode, int>{
      AppLaunchMode.default_: 1,
      AppLaunchMode.gamepadFriendly: 2,
      AppLaunchMode.touchFriendly: 3,
    };
    return values[mode ?? AppLaunchMode.default_] ?? 1;
  }

  Future<List<IceServer>> _normalizeIceServersSimple(
    CloudMatchResponse payload,
  ) async {
    final raw = payload.session.iceServers;
    final servers = <IceServer>[];
    for (final entry in raw) {
      if (entry.urls.isEmpty) continue;
      servers.add(IceServer(
        urls: entry.urls,
        username: entry.username,
        credential: entry.credential,
      ));
    }
    if (servers.isNotEmpty) return servers;
    return const [
      IceServer(urls: ['stun:stun.l.google.com:19302']),
      IceServer(urls: ['stun:stun1.l.google.com:19302']),
    ];
  }
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

String _decodeBody(http.Response response) {
  final body = response.body;
  if (body.isNotEmpty) return body;
  final bytes = response.bodyBytes;
  if (bytes.isEmpty) return '';
  return utf8.decode(bytes);
}

Map<String, dynamic> _decodeObject(String text) {
  final decoded = jsonDecode(text);
  if (decoded is Map<String, dynamic>) return decoded;
  throw FormatException('CloudMatch response was not a JSON object');
}