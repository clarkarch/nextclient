/// Mirrors OpenNOW's ColorQuality (bit depth + chroma subsampling).
class ColorQuality {
  final int bitDepth; // 0 = 8-bit, 1 = 10-bit
  final int chromaFormat; // 0 = 4:2:0, 1 = 4:4:4

  const ColorQuality({required this.bitDepth, required this.chromaFormat});

  String get wireValue => '${bitDepth == 1 ? "10bit" : "8bit"}_${chromaFormat == 1 ? "444" : "420"}';
}

class CloudGsyncResolution {
  final bool requested;
  final bool enabled;
  final bool reflexEnabled;
  final String reason;
  final CloudGsyncCapabilities capabilities;

  const CloudGsyncResolution({
    required this.requested,
    required this.enabled,
    required this.reflexEnabled,
    required this.reason,
    required this.capabilities,
  });

  factory CloudGsyncResolution.fromJson(Map<String, dynamic> json) {
    return CloudGsyncResolution(
      requested: json['requested'] as bool,
      enabled: json['enabled'] as bool,
      reflexEnabled: json['reflexEnabled'] as bool,
      reason: json['reason'] as String,
      capabilities: CloudGsyncCapabilities.fromJson(
          json['capabilities'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'requested': requested,
      'enabled': enabled,
      'reflexEnabled': reflexEnabled,
      'reason': reason,
      'capabilities': capabilities.toJson(),
    };
  }
}

class CloudGsyncCapabilities {
  final bool platformSupportsCloudGsync;
  final bool isVrrCapableDisplay;
  final bool isGsyncDisplay;
  final int minimumFpsForCloudGsync;
  final int minimumFpsForReflexWithoutVrr;
  final String detectionSource;
  final String? reason;

  const CloudGsyncCapabilities({
    required this.platformSupportsCloudGsync,
    required this.isVrrCapableDisplay,
    required this.isGsyncDisplay,
    required this.minimumFpsForCloudGsync,
    required this.minimumFpsForReflexWithoutVrr,
    required this.detectionSource,
    this.reason,
  });

  factory CloudGsyncCapabilities.fromJson(Map<String, dynamic> json) {
    return CloudGsyncCapabilities(
      platformSupportsCloudGsync: json['platformSupportsCloudGsync'] as bool,
      isVrrCapableDisplay: json['isVrrCapableDisplay'] as bool,
      isGsyncDisplay: json['isGsyncDisplay'] as bool,
      minimumFpsForCloudGsync: (json['minimumFpsForCloudGsync'] as num).toInt(),
      minimumFpsForReflexWithoutVrr:
          (json['minimumFpsForReflexWithoutVrr'] as num).toInt(),
      detectionSource: json['detectionSource'] as String,
      reason: json['reason'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'platformSupportsCloudGsync': platformSupportsCloudGsync,
      'isVrrCapableDisplay': isVrrCapableDisplay,
      'isGsyncDisplay': isGsyncDisplay,
      'minimumFpsForCloudGsync': minimumFpsForCloudGsync,
      'minimumFpsForReflexWithoutVrr': minimumFpsForReflexWithoutVrr,
      'detectionSource': detectionSource,
      'reason': reason,
    };
  }
}

enum StreamClientMode { web, native }

enum AppLaunchMode { default_, gamepadFriendly, touchFriendly }

enum StreamTransportMode { webrtc, nvst }

enum NativeStreamerFeatureMode { auto, fixed, adaptive, vrr }

enum NativeStreamerBackendPreference { auto, gstreamer }

enum VideoCodec { h264, h265, av1 }

enum GameLanguage { enUS, enGB, deDE, frFR, esES, esMX, itIT, ptPT, ptBR, ruRU, plPL, trTR, jaJP, koKR, zhCN }

enum KeyboardLayout { enUs, enGb, trTr, deDe, frFr, esEs, esMx, itIt, ptPt, ptBr, plPl, daDk, nbNo, svSe, fiFi, ruRu, jaJp, koKr, zhCn, zhTw }

class StreamSettings {
  final String resolution;
  final int fps;
  final int maxBitrateMbps;
  final VideoCodec codec;
  final ColorQuality colorQuality;
  final KeyboardLayout keyboardLayout;
  final GameLanguage gameLanguage;
  final bool enableL4S;
  final bool enableCloudGsync;
  final StreamClientMode clientMode;
  final NativeStreamerBackendPreference nativeStreamerBackend;
  final StreamTransportMode transportMode;
  final NativeStreamerFeatureMode nativeCloudGsyncMode;
  final bool requestedCloudGsync;
  final CloudGsyncResolution? cloudGsyncResolution;
  final AppLaunchMode appLaunchMode;

  const StreamSettings({
    required this.resolution,
    required this.fps,
    required this.maxBitrateMbps,
    required this.codec,
    required this.colorQuality,
    required this.keyboardLayout,
    required this.gameLanguage,
    required this.enableL4S,
    required this.enableCloudGsync,
    this.clientMode = StreamClientMode.web,
    this.nativeStreamerBackend = NativeStreamerBackendPreference.auto,
    this.transportMode = StreamTransportMode.webrtc,
    this.nativeCloudGsyncMode = NativeStreamerFeatureMode.auto,
    this.requestedCloudGsync = false,
    this.cloudGsyncResolution,
    this.appLaunchMode = AppLaunchMode.default_,
  });
}

class IceServer {
  final List<String> urls;
  final String? username;
  final String? credential;

  const IceServer({required this.urls, this.username, this.credential});
}

class MediaConnectionInfo {
  final String ip;
  final int port;
  final int? usage;

  const MediaConnectionInfo({required this.ip, required this.port, this.usage});
}

class SessionAdInfo {
  final String adId;
  final int? state;
  final String? adUrl;
  final String? mediaUrl;
  final String? clickThroughUrl;
  final int? durationMs;

  const SessionAdInfo({
    required this.adId,
    this.state,
    this.adUrl,
    this.mediaUrl,
    this.clickThroughUrl,
    this.durationMs,
  });
}

class SessionAdState {
  final bool isAdsRequired;
  final bool? sessionAdsRequired;
  final bool? isQueuePaused;
  final int? gracePeriodSeconds;
  final String? message;
  final List<SessionAdInfo> sessionAds;
  final List<SessionAdInfo> ads;

  const SessionAdState({
    required this.isAdsRequired,
    this.sessionAdsRequired,
    this.isQueuePaused,
    this.gracePeriodSeconds,
    this.message,
    required this.sessionAds,
    required this.ads,
  });
}

class NegotiatedStreamProfile {
  final String? resolution;
  final int? fps;
  final ColorQuality? colorQuality;
  final bool? enableL4S;
  final bool? enableCloudGsync;
  final bool? enableReflex;

  const NegotiatedStreamProfile({
    this.resolution,
    this.fps,
    this.colorQuality,
    this.enableL4S,
    this.enableCloudGsync,
    this.enableReflex,
  });
}

class StreamingFeatures {
  final bool? reflex;
  final int? bitDepth;
  final bool? cloudGsync;
  final int? chromaFormat;
  final bool? enabledL4S;
  final bool? trueHdr;

  const StreamingFeatures({
    this.reflex,
    this.bitDepth,
    this.cloudGsync,
    this.chromaFormat,
    this.enabledL4S,
    this.trueHdr,
  });
}

class SessionInfo {
  final String sessionId;
  final String? appId;
  final int status;
  final int? queuePosition;
  final int? seatSetupStep;
  final SessionAdState? adState;
  final String zone;
  final String? streamingBaseUrl;
  final String serverIp;
  final String signalingServer;
  final String signalingUrl;
  final String? gpuType;
  final int? appLaunchMode;
  final bool? enablePersistingInGameSettings;
  final List<String> rtspsEndpoints;
  final List<IceServer> iceServers;
  final MediaConnectionInfo? mediaConnectionInfo;
  final NegotiatedStreamProfile? negotiatedStreamProfile;
  final String? clientId;
  final String? deviceId;

  const SessionInfo({
    required this.sessionId,
    this.appId,
    required this.status,
    this.queuePosition,
    this.seatSetupStep,
    this.adState,
    required this.zone,
    this.streamingBaseUrl,
    required this.serverIp,
    required this.signalingServer,
    required this.signalingUrl,
    this.gpuType,
    this.appLaunchMode,
    this.enablePersistingInGameSettings,
    this.rtspsEndpoints = const [],
    required this.iceServers,
    this.mediaConnectionInfo,
    this.negotiatedStreamProfile,
    this.clientId,
    this.deviceId,
  });
}

class ActiveSessionInfo {
  final String sessionId;
  final int appId;
  final int? appLaunchMode;
  final bool? enablePersistingInGameSettings;
  final String? gpuType;
  final int status;
  final int? queuePosition;
  final int? seatSetupStep;
  final String? streamingBaseUrl;
  final String? serverIp;
  final String? signalingUrl;
  final String? resolution;
  final int? fps;

  const ActiveSessionInfo({
    required this.sessionId,
    required this.appId,
    this.appLaunchMode,
    this.enablePersistingInGameSettings,
    this.gpuType,
    required this.status,
    this.queuePosition,
    this.seatSetupStep,
    this.streamingBaseUrl,
    this.serverIp,
    this.signalingUrl,
    this.resolution,
    this.fps,
  });
}

class SessionCreateRequest {
  final String? token;
  final String? streamingBaseUrl;
  final String appId;
  final String internalTitle;
  final bool? accountLinked;
  final bool? enablePersistingInGameSettings;
  final bool? supportsInGameSettingsPersistence;
  final String zone;
  final StreamSettings settings;
  final String? proxyUrl;

  const SessionCreateRequest({
    this.token,
    this.streamingBaseUrl,
    required this.appId,
    required this.internalTitle,
    this.accountLinked,
    this.enablePersistingInGameSettings,
    this.supportsInGameSettingsPersistence,
    required this.zone,
    required this.settings,
    this.proxyUrl,
  });
}

class SessionPollRequest {
  final String? token;
  final String? streamingBaseUrl;
  final String? serverIp;
  final String zone;
  final String sessionId;
  final String? clientId;
  final String? deviceId;
  final String? proxyUrl;

  const SessionPollRequest({
    this.token,
    this.streamingBaseUrl,
    this.serverIp,
    required this.zone,
    required this.sessionId,
    this.clientId,
    this.deviceId,
    this.proxyUrl,
  });
}

class SessionStopRequest {
  final String? token;
  final String? streamingBaseUrl;
  final String? serverIp;
  final String zone;
  final String sessionId;
  final String? clientId;
  final String? deviceId;

  const SessionStopRequest({
    this.token,
    this.streamingBaseUrl,
    this.serverIp,
    required this.zone,
    required this.sessionId,
    this.clientId,
    this.deviceId,
  });
}

class SessionClaimRequest {
  final String? token;
  final String? streamingBaseUrl;
  final String sessionId;
  final String serverIp;
  final String? clientId;
  final String? deviceId;
  final String? appId;
  final int? appLaunchMode;
  final bool? enablePersistingInGameSettings;
  final StreamSettings? settings;
  final bool? recoveryMode;

  const SessionClaimRequest({
    this.token,
    this.streamingBaseUrl,
    required this.sessionId,
    required this.serverIp,
    this.clientId,
    this.deviceId,
    this.appId,
    this.appLaunchMode,
    this.enablePersistingInGameSettings,
    this.settings,
    this.recoveryMode,
  });
}

enum SessionConflictChoice { resume, new_, cancel }

enum ExistingSessionStrategy { autoResume, forceNew }

typedef SessionInfoFactory = SessionInfo Function(SessionInfo base);

/// Static helpers matching OpenNOW's shared/gfn/session.ts
class SessionHelpers {
  static bool isSessionReadyForConnectStatus(int status) {
    return status == 2 || status == 3;
  }
}