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

/// Ad lifecycle action reported to the server (matches OpenNOW's
/// `SessionAdAction`). Wire codes come from `adActionWireCode`.
enum SessionAdAction { start, pause, resume, finish, cancel }

/// Wire codes for [SessionAdAction] (matches OpenNOW's AD_ACTION_CODES:
/// start=1, pause=2, resume=3, finish=4, cancel=5).
int adActionWireCode(SessionAdAction action) {
  switch (action) {
    case SessionAdAction.start:
      return 1;
    case SessionAdAction.pause:
      return 2;
    case SessionAdAction.resume:
      return 3;
    case SessionAdAction.finish:
      return 4;
    case SessionAdAction.cancel:
      return 5;
  }
}

/// A multi-format media source entry for an ad (port of SessionAdMediaFile).
class SessionAdMediaFile {
  final String? mediaFileUrl;
  final String? encodingProfile;

  const SessionAdMediaFile({this.mediaFileUrl, this.encodingProfile});
}

/// Normalized `opportunity` object from a session response (port of
/// SessionOpportunityInfo).
class SessionOpportunityInfo {
  final String? state;
  final bool? queuePaused;
  final int? gracePeriodSeconds;
  final String? message;
  final String? title;
  final String? description;

  const SessionOpportunityInfo({
    this.state,
    this.queuePaused,
    this.gracePeriodSeconds,
    this.message,
    this.title,
    this.description,
  });
}

class SessionAdInfo {
  final String adId;
  final int? state;
  final int? adState;
  final String? adUrl;
  final String? mediaUrl;
  final List<SessionAdMediaFile> adMediaFiles;
  final String? clickThroughUrl;
  final double? adLengthInSeconds;
  final int? durationMs;
  final String? title;
  final String? description;

  const SessionAdInfo({
    required this.adId,
    this.state,
    this.adState,
    this.adUrl,
    this.mediaUrl,
    this.adMediaFiles = const [],
    this.clickThroughUrl,
    this.adLengthInSeconds,
    this.durationMs,
    this.title,
    this.description,
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
  final SessionOpportunityInfo? opportunity;

  /// True when the server explicitly returned sessionAds=null (a transient gap
  /// between polls). Used by [mergeAdState] to decide whether to restore the
  /// previous ad list — see OpenNOW's serverSentEmptyAds.
  final bool? serverSentEmptyAds;

  const SessionAdState({
    required this.isAdsRequired,
    this.sessionAdsRequired,
    this.isQueuePaused,
    this.gracePeriodSeconds,
    this.message,
    required this.sessionAds,
    required this.ads,
    this.opportunity,
    this.serverSentEmptyAds,
  });

  SessionAdState copyWith({
    bool? isAdsRequired,
    bool? sessionAdsRequired,
    bool? isQueuePaused,
    int? gracePeriodSeconds,
    String? message,
    List<SessionAdInfo>? sessionAds,
    List<SessionAdInfo>? ads,
    SessionOpportunityInfo? opportunity,
    bool? serverSentEmptyAds,
  }) {
    return SessionAdState(
      isAdsRequired: isAdsRequired ?? this.isAdsRequired,
      sessionAdsRequired: sessionAdsRequired ?? this.sessionAdsRequired,
      isQueuePaused: isQueuePaused ?? this.isQueuePaused,
      gracePeriodSeconds: gracePeriodSeconds ?? this.gracePeriodSeconds,
      message: message ?? this.message,
      sessionAds: sessionAds ?? this.sessionAds,
      ads: ads ?? this.ads,
      opportunity: opportunity ?? this.opportunity,
      serverSentEmptyAds: serverSentEmptyAds ?? this.serverSentEmptyAds,
    );
  }
}

/// Request to report an ad lifecycle event (port of SessionAdReportRequest).
class SessionAdReportRequest {
  final String? token;
  final String? streamingBaseUrl;
  final String? serverIp;
  final String zone;
  final String sessionId;
  final String? clientId;
  final String? deviceId;
  final String adId;
  final SessionAdAction action;
  final int? clientTimestamp;
  final int? watchedTimeInMs;
  final int? pausedTimeInMs;
  final String? cancelReason;

  const SessionAdReportRequest({
    this.token,
    this.streamingBaseUrl,
    this.serverIp,
    required this.zone,
    required this.sessionId,
    this.clientId,
    this.deviceId,
    required this.adId,
    required this.action,
    this.clientTimestamp,
    this.watchedTimeInMs,
    this.pausedTimeInMs,
    this.cancelReason,
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

  /// Sentinel for nullable copyWith fields that need to be null-able.
  static const Object _unset = Object();

  SessionInfo copyWith({
    String? sessionId,
    String? appId,
    int? status,
    int? queuePosition,
    int? seatSetupStep,
    Object? adState = _unset,
    String? zone,
    String? streamingBaseUrl,
    String? serverIp,
    String? signalingServer,
    String? signalingUrl,
    String? gpuType,
    int? appLaunchMode,
    bool? enablePersistingInGameSettings,
    List<String>? rtspsEndpoints,
    List<IceServer>? iceServers,
    Object? mediaConnectionInfo = _unset,
    NegotiatedStreamProfile? negotiatedStreamProfile,
    String? clientId,
    String? deviceId,
  }) {
    return SessionInfo(
      sessionId: sessionId ?? this.sessionId,
      appId: appId ?? this.appId,
      status: status ?? this.status,
      queuePosition: queuePosition ?? this.queuePosition,
      seatSetupStep: seatSetupStep ?? this.seatSetupStep,
      adState: identical(adState, _unset)
          ? this.adState
          : adState as SessionAdState?,
      zone: zone ?? this.zone,
      streamingBaseUrl: streamingBaseUrl ?? this.streamingBaseUrl,
      serverIp: serverIp ?? this.serverIp,
      signalingServer: signalingServer ?? this.signalingServer,
      signalingUrl: signalingUrl ?? this.signalingUrl,
      gpuType: gpuType ?? this.gpuType,
      appLaunchMode: appLaunchMode ?? this.appLaunchMode,
      enablePersistingInGameSettings:
          enablePersistingInGameSettings ?? this.enablePersistingInGameSettings,
      rtspsEndpoints: rtspsEndpoints ?? this.rtspsEndpoints,
      iceServers: iceServers ?? this.iceServers,
      mediaConnectionInfo: identical(mediaConnectionInfo, _unset)
          ? this.mediaConnectionInfo
          : mediaConnectionInfo as MediaConnectionInfo?,
      negotiatedStreamProfile:
          negotiatedStreamProfile ?? this.negotiatedStreamProfile,
      clientId: clientId ?? this.clientId,
      deviceId: deviceId ?? this.deviceId,
    );
  }
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
  final List<VideoCodec>? supportedCodecs;
  final ExistingSessionStrategy? existingSessionStrategy;
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
    this.supportedCodecs,
    this.existingSessionStrategy,
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

// Port of sessionSelection.ts
bool isAutoResumeReadySession(ActiveSessionInfo entry) {
  return entry.serverIp != null && (entry.status == 2 || entry.status == 3);
}

bool isActiveCreateSessionConflict(ActiveSessionInfo entry) {
  return entry.status == 1 || entry.status == 2 || entry.status == 3;
}

ActiveSessionInfo? selectReadySessionToClaim(
  List<ActiveSessionInfo> activeSessions,
  int numericAppId,
) {
  for (final s in activeSessions) {
    if (isAutoResumeReadySession(s) && s.appId == numericAppId) return s;
  }
  for (final s in activeSessions) {
    if (isAutoResumeReadySession(s)) return s;
  }
  return null;
}

ActiveSessionInfo? selectLaunchingSession(
  List<ActiveSessionInfo> activeSessions,
  int numericAppId,
) {
  for (final s in activeSessions) {
    if (s.serverIp != null && s.appId == numericAppId && s.status == 1) return s;
  }
  for (final s in activeSessions) {
    if (s.serverIp != null && s.status == 1) return s;
  }
  return null;
}

/// Port of OpenNOW's getSessionAdItems (sessionAds preferred, then ads).
List<SessionAdInfo> getSessionAdItems(SessionAdState? adState) =>
    adState?.sessionAds ?? adState?.ads ?? const [];

/// Port of OpenNOW's isSessionAdsRequired.
bool isSessionAdsRequired(SessionAdState? adState) =>
    adState?.sessionAdsRequired ?? adState?.isAdsRequired ?? false;

/// Port of OpenNOW's getSessionAdOpportunity.
SessionOpportunityInfo? getSessionAdOpportunity(SessionAdState? adState) =>
    adState?.opportunity;

/// Port of OpenNOW's isSessionQueuePaused.
bool isSessionQueuePaused(SessionAdState? adState) =>
    getSessionAdOpportunity(adState)?.queuePaused ??
    adState?.isQueuePaused ??
    false;

/// Port of OpenNOW's getSessionAdGracePeriodSeconds.
int? getSessionAdGracePeriodSeconds(SessionAdState? adState) =>
    getSessionAdOpportunity(adState)?.gracePeriodSeconds ??
    adState?.gracePeriodSeconds;

/// Port of OpenNOW's queueAds.mergeAdState.
///
/// The server only populates `sessionAds` in the first poll after session
/// creation. Later polls return sessionAdsRequired=true but sessionAds=null
/// (serverSentEmptyAds=true), which would otherwise produce an empty ad list.
/// Preserve the ad list from the most recent poll that had URLs so the ad
/// player can continue. Do NOT restore when serverSentEmptyAds is false —
/// that signals an explicit client-side clear after a rejected finish action.
SessionAdState? mergeAdState(SessionAdState? previous, SessionAdState? next) {
  if (next == null) return previous;
  if (isSessionAdsRequired(next) &&
      next.serverSentEmptyAds == true &&
      getSessionAdItems(next).isEmpty &&
      (previous != null && previous.sessionAds.isNotEmpty)) {
    return next.copyWith(sessionAds: previous.sessionAds, ads: previous.ads);
  }
  return next;
}

/// Port of OpenNOW's queueAds.mergePolledSessionState.
SessionInfo mergePolledSessionState(SessionInfo previous, SessionInfo next) {
  final appLaunchMode = next.appLaunchMode ?? previous.appLaunchMode;
  final appId = next.appId ?? previous.appId;
  if (SessionHelpers.isSessionReadyForConnectStatus(next.status)) {
    return next.copyWith(appId: appId, appLaunchMode: appLaunchMode);
  }
  return next.copyWith(
    appId: appId,
    appLaunchMode: appLaunchMode,
    adState: mergeAdState(previous.adState, next.adState),
    mediaConnectionInfo:
        next.mediaConnectionInfo ?? previous.mediaConnectionInfo,
  );
}