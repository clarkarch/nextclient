import 'dart:convert' show jsonEncode;
import 'dart:io' show InternetAddress;

import '../models/cloudmatch_types.dart';
import '../models/session.dart';
import '../http/errors.dart' show SessionError;
import 'signaling.dart' show resolveSignaling;

// Port of cloudmatchSessionParsing.ts

int? toPositiveInt(Object? value) {
  if (value is num && value.isFinite) {
    final normalized = value.truncate();
    return normalized > 0 ? normalized : null;
  }
  if (value is String && value.trim().isNotEmpty) {
    final parsed = int.tryParse(value);
    return parsed != null && parsed > 0 ? parsed : null;
  }
  return null;
}

bool? toBoolean(Object? value) {
  if (value is bool) return value;
  if (value is num && value.isFinite) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
  }
  return null;
}

String? toOptionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isNotEmpty ? trimmed : null;
}

/// Port of extractQueuePosition — checks queuePosition, seatSetupInfo,
/// sessionProgress, progressInfo in that order.
int? extractQueuePosition(Map<String, dynamic>? session) {
  if (session == null) return null;

  final direct = toPositiveInt(session['queuePosition']);
  if (direct != null) return direct;

  final seatSetup = session['seatSetupInfo'];
  if (seatSetup is Map) {
    final nested = toPositiveInt(seatSetup['queuePosition']);
    if (nested != null) return nested;
  }

  final sessionProgress = session['sessionProgress'];
  if (sessionProgress is Map) {
    final nested = toPositiveInt(sessionProgress['queuePosition']);
    if (nested != null) return nested;
  }

  final progressInfo = session['progressInfo'];
  if (progressInfo is Map) {
    final nested = toPositiveInt(progressInfo['queuePosition']);
    if (nested != null) return nested;
  }

  return null;
}

int? extractSeatSetupStep(Map<String, dynamic>? session) {
  final seatSetup = session?['seatSetupInfo'];
  if (seatSetup is! Map) return null;
  final raw = seatSetup['seatSetupStep'];
  if (raw is num && raw.isFinite) return raw.truncate();
  return null;
}

/// Preferred ad media profile ordering (matches OpenNOW's
/// GFN_AD_MEDIA_PROFILE_ORDER): MP4, WebM, then HLS.
const List<String> _gfNAdMediaProfileOrder = const [
  'mp4deinterlaced720p',
  'webm',
  'hlsadaptive',
];

/// Port of cloudmatchSessionParsing.ts `normalizeSessionAdInfo`.
SessionAdInfo? normalizeSessionAdInfo(Map ad, int index) {
  String? optStr(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isNotEmpty ? t : null;
  }

  final adId = optStr(ad['adId']);

  final rawMediaFiles = ad['adMediaFiles'];
  final mediaFiles = <SessionAdMediaFile>[];
  if (rawMediaFiles is List) {
    for (final f in rawMediaFiles) {
      if (f is! Map) continue;
      final file = SessionAdMediaFile(
        mediaFileUrl: optStr(f['mediaFileUrl']),
        encodingProfile: optStr(f['encodingProfile']),
      );
      if (file.mediaFileUrl != null || file.encodingProfile != null) {
        mediaFiles.add(file);
      }
    }
    // Prefer encodingProfile: MP4 -> WebM -> HLS (unranked profiles sink last).
    mediaFiles.sort((a, b) {
      int rank(String? p) {
        if (p == null) return 1 << 30;
        final i = _gfNAdMediaProfileOrder.indexOf(p);
        return i >= 0 ? i : 1 << 30;
      }

      return rank(a.encodingProfile) - rank(b.encodingProfile);
    });
  }

  SessionAdMediaFile? preferred;
  for (final f in mediaFiles) {
    if (f.mediaFileUrl != null) {
      preferred = f;
      break;
    }
  }
  final mediaUrl = preferred?.mediaFileUrl ??
      optStr(ad['adUrl']) ??
      optStr(ad['mediaUrl']) ??
      optStr(ad['videoUrl']) ??
      optStr(ad['url']);

  final adUrl = optStr(ad['adUrl']);
  final clickThroughUrl = optStr(ad['clickThroughUrl']);
  final title = optStr(ad['title']);
  final description = optStr(ad['description']);

  final rawLength = ad['adLengthInSeconds'];
  final adLengthInSeconds = (rawLength is num && rawLength.isFinite && rawLength > 0)
      ? rawLength.toDouble()
      : null;

  // adLengthInSeconds is the confirmed live field (seconds -> ms). Fall back
  // to legacy durationMs / durationInMs which are already in ms.
  final durationMs = (adLengthInSeconds != null
          ? (adLengthInSeconds * 1000).round()
          : null) ??
      toPositiveInt(ad['durationMs']) ??
      toPositiveInt(ad['durationInMs']);

  final rawAdState = ad['adState'];
  final adState =
      (rawAdState is num && rawAdState.isFinite) ? rawAdState.truncate() : null;

  if (adId == null &&
      mediaUrl == null &&
      adUrl == null &&
      mediaFiles.isEmpty &&
      title == null &&
      description == null) {
    return null;
  }

  return SessionAdInfo(
    adId: adId ?? 'ad-${index + 1}',
    state: adState,
    adState: adState,
    adUrl: adUrl,
    mediaUrl: mediaUrl,
    adMediaFiles: mediaFiles,
    clickThroughUrl: clickThroughUrl,
    adLengthInSeconds: adLengthInSeconds,
    durationMs: durationMs,
    title: title,
    description: description,
  );
}

/// Port of extractAdState — surfaces queue ads from session fields.
SessionAdState? extractAdState(Map<String, dynamic>? session) {
  if (session == null) return null;

  bool? toBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    return null;
  }

  bool? nestedBool(String key, String sub) {
    final nested = session[key];
    if (nested is! Map) return null;
    return toBool(nested[sub]);
  }

  final sessionAdsRequired =
      toBool(session['sessionAdsRequired']) ??
      toBool(session['isAdsRequired']) ??
      nestedBool('sessionProgress', 'isAdsRequired') ??
      nestedBool('progressInfo', 'isAdsRequired');

  final ads = <SessionAdInfo>[];
  final rawAds = session['sessionAds'];
  if (rawAds is List) {
    for (var i = 0; i < rawAds.length; i++) {
      final ad = rawAds[i];
      if (ad is! Map) continue;
      final normalized = normalizeSessionAdInfo(ad, i);
      if (normalized != null) ads.add(normalized);
    }
  }

  final rawOpportunity = session['opportunity'];
  final opportunity = rawOpportunity is Map
      ? SessionOpportunityInfo(
          state: toOptionalString(rawOpportunity['state']),
          queuePaused: toBoolean(rawOpportunity['queuePaused']),
          gracePeriodSeconds: toPositiveInt(rawOpportunity['gracePeriodSeconds']),
          message: toOptionalString(rawOpportunity['message']),
          title: toOptionalString(rawOpportunity['title']),
          description: toOptionalString(rawOpportunity['description']),
        )
      : null;

  final queuePaused =
      opportunity?.queuePaused ??
      (opportunity?.state != null
          ? opportunity!.state!.toLowerCase() == 'graceperiodstart'
          : null);
  final gracePeriodSeconds = opportunity?.gracePeriodSeconds;
  final effectiveIsAdsRequired = sessionAdsRequired ?? ads.isNotEmpty;
  final message =
      opportunity?.message ??
      opportunity?.description ??
      (queuePaused == true
          ? 'Resume ads to stay in queue.'
          : effectiveIsAdsRequired == true
          ? 'Finish ads to stay in queue.'
          : null);

  if (effectiveIsAdsRequired != true &&
      ads.isEmpty &&
      queuePaused != true &&
      message == null) {
    return null;
  }

  return SessionAdState(
    isAdsRequired: effectiveIsAdsRequired,
    sessionAdsRequired: sessionAdsRequired,
    isQueuePaused: queuePaused,
    gracePeriodSeconds: gracePeriodSeconds,
    message: message,
    sessionAds: ads,
    ads: ads,
    opportunity: opportunity,
    // Mark whether the server sent sessionAds=null (transient gap) so the
    // renderer's mergeAdState can restore the previous ad list while NOT
    // restoring it after an explicit client-side clear.
    serverSentEmptyAds: session['sessionAds'] == null,
  );
}

/// Port of normalizeIceServers
Future<List<IceServer>> normalizeIceServers(CloudMatchResponse response) async {
  final raw = response.session.iceServers;
  final servers = <IceServer>[];
  for (final entry in raw) {
    if (entry.urls.isEmpty) continue;
    servers.add(
      IceServer(
        urls: entry.urls,
        username: entry.username,
        credential: entry.credential,
      ),
    );
  }

  if (servers.isNotEmpty) {
    final resolved = <IceServer>[];
    for (final s in servers) {
      final resolvedUrls = <String>[];
      for (final u in s.urls) {
        final m = RegExp(r'^([a-zA-Z0-9+.-]+):([^/]+)').firstMatch(u);
        if (m != null) {
          final scheme = m.group(1)!;
          final hostPort = m.group(2)!;
          final host = hostPort.split(':').first;
          final portPart = hostPort.contains(':')
              ? ':${hostPort.split(':').skip(1).join(':')}'
              : '';

          if (_isIpLiteral(host)) {
            resolvedUrls.add(u);
          } else {
            final ip = await _resolveHostnameWithFallback(host);
            final finalHost = ip ?? host;
            resolvedUrls.add('$scheme:${_bracketIfIpv6(finalHost)}$portPart');
          }
        } else {
          resolvedUrls.add(u);
        }
      }
      resolved.add(
        IceServer(
          urls: resolvedUrls,
          username: s.username,
          credential: s.credential,
        ),
      );
    }
    return resolved;
  }

  // Default fallbacks
  const defaults = [
    's1.stun.gamestream.nvidia.com:19308',
    'stun.l.google.com:19302',
    'stun1.l.google.com:19302',
  ];
  final out = <IceServer>[];
  for (final d in defaults) {
    final parts = d.split(':');
    final host = parts.first;
    final port = parts.length > 1 ? ':${parts.skip(1).join(':')}' : '';
    final ip = await _resolveHostnameWithFallback(host);
    final bracket = ip != null && ip.contains(':') && !ip.startsWith('[')
        ? '[$ip]'
        : (ip ?? host);
    out.add(IceServer(urls: ['stun:$bracket$port']));
  }
  return out;
}

bool _isIpLiteral(String host) {
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return true;
  if (RegExp(r'^\[[0-9a-fA-F:]+\]$').hasMatch(host)) return true;
  return false;
}

String _bracketIfIpv6(String host) {
  if (host.startsWith('[') && host.endsWith(']')) return host;
  if (host.contains(':') &&
      !RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
    return '[$host]';
  }
  return host;
}

Future<String?> _resolveHostnameWithFallback(String hostname) async {
  try {
    final addresses = await InternetAddress.lookup(hostname);
    if (addresses.isNotEmpty) return addresses.first.address;
  } catch (_) {}
  return null;
}

/// Port of toSessionInfo — the main CloudMatch response -> SessionInfo mapping.
Future<SessionInfo> toSessionInfo({
  required String zone,
  required String streamingBaseUrl,
  required CloudMatchResponse payload,
  String? clientId,
  String? deviceId,
  String? fallbackAppId,
  int? fallbackAppLaunchMode,
}) async {
  if (payload.requestStatus.statusCode != 1) {
    throw SessionError.fromResponse(200, jsonEncode(payload));
  }

  final signaling = resolveSignaling(payload);
  final sessionMap = _sessionMap(payload);
  final queuePosition = extractQueuePosition(sessionMap);
  final seatSetupStep = extractSeatSetupStep(sessionMap);
  final adState = extractAdState(sessionMap);
  final negotiatedProfile = _extractNegotiatedStreamProfile(payload);
  final appLaunchMode =
      _echoedSessionAppLaunchMode(payload) ?? fallbackAppLaunchMode;

  return SessionInfo(
    sessionId: payload.session.sessionId,
    appId: _asAppId(_sessionRequestData(payload)?['appId']) ?? fallbackAppId,
    status: payload.session.status,
    queuePosition: queuePosition,
    seatSetupStep: seatSetupStep,
    adState: adState,
    zone: zone,
    streamingBaseUrl: streamingBaseUrl,
    serverIp: signaling.serverIp,
    signalingServer: signaling.signalingServer,
    signalingUrl: signaling.signalingUrl,
    gpuType: payload.session.gpuType,
    appLaunchMode: appLaunchMode,
    rtspsEndpoints: signaling.rtspsEndpoints,
    iceServers: await normalizeIceServers(payload),
    mediaConnectionInfo: signaling.mediaConnectionInfo,
    negotiatedStreamProfile: negotiatedProfile,
    clientId: clientId,
    deviceId: deviceId,
  );
}

Map<String, dynamic>? _sessionMap(CloudMatchResponse payload) {
  // Prefer the raw response session so nested queue fields survive.
  return payload.session.rawJson ?? _asMap(payload.session.toJson());
}

Map<String, dynamic>? _sessionRequestData(CloudMatchResponse payload) {
  return _asMap(payload.session.sessionRequestData);
}

int? _echoedSessionAppLaunchMode(CloudMatchResponse payload) {
  final data = _sessionRequestData(payload);
  final raw = data?['appLaunchMode'];
  return raw is num && raw.isFinite ? raw.truncate() : null;
}

NegotiatedStreamProfile? _extractNegotiatedStreamProfile(
  CloudMatchResponse payload,
) {
  final data = _sessionRequestData(payload);
  final monitors = _asMap(data)?['clientRequestMonitorSettings'];
  final monitor = monitors is List && monitors.isNotEmpty
      ? _asMap(monitors.first)
      : null;

  final width = monitor?['widthInPixels'];
  final height = monitor?['heightInPixels'];
  final fps = monitor?['framesPerSecond'];

  final profile = <String, Object>{};
  if (width is num &&
      width.isFinite &&
      width > 0 &&
      height is num &&
      height.isFinite &&
      height > 0) {
    profile['resolution'] = '${width.truncate()}x${height.truncate()}';
  }
  if (fps is num && fps.isFinite && fps > 0) {
    profile['fps'] = fps.truncate();
  }

  if (profile.isEmpty) return null;
  return NegotiatedStreamProfile(
    resolution: profile['resolution'] as String?,
    fps: profile['fps'] as int?,
  );
}

Map<String, dynamic>? _asMap(Object? value) {
  return value is Map<String, dynamic> ? value : null;
}

/// NVIDIA echoes appId as either a number or a string depending on the
/// endpoint/state. Normalize both to a string (matching OpenNOW's loose
/// `appId?: string` typing, which is a number at runtime on some responses).
String? _asAppId(Object? value) {
  if (value is num) return value.toInt().toString();
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}
