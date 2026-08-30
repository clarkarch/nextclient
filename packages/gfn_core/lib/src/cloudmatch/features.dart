import '../models/session.dart';

// Port of cloudmatchFeatures.ts

const appLaunchModeWireValues = <AppLaunchMode, int>{
  AppLaunchMode.default_: 1,
  AppLaunchMode.gamepadFriendly: 2,
  AppLaunchMode.touchFriendly: 3,
};

int appLaunchModeWireValue(AppLaunchMode? mode) =>
    appLaunchModeWireValues[mode ?? AppLaunchMode.default_]!;

int codecWireValue(VideoCodec codec) {
  switch (codec) {
    case VideoCodec.h264:
      return 1;
    case VideoCodec.h265:
      return 2;
    case VideoCodec.av1:
      return 3;
  }
}

const _officialCodecLadders = <int, List<int>>{
  0: [0],
  1: [1],
  2: [2, 1],
  3: [3, 2, 1],
};

int resolveRequestedCodecWireValue(
  int preferenceWireValue,
  List<int> supportedCodecWireValues,
) {
  final ladder = _officialCodecLadders[preferenceWireValue] ??
      [preferenceWireValue];
  if (supportedCodecWireValues.isEmpty) {
    return ladder.first;
  }
  final supported = Set<int>.from(supportedCodecWireValues);
  for (final v in ladder) {
    if (supported.contains(v)) return v;
  }
  return ladder.first;
}

/// Port of buildRequestedStreamingFeatures
Map<String, dynamic> buildRequestedStreamingFeatures({
  required StreamSettings settings,
  required int bitDepth,
  required int chromaFormat,
  required bool hdrEnabled,
  List<VideoCodec>? supportedCodecs,
}) {
  final cloudGsync = settings.enableCloudGsync;
  return {
    'reflex': shouldRequestReflex(settings),
    'bitDepth': bitDepth,
    'cloudGsync': cloudGsync,
    'enabledL4S': settings.enableL4S,
    'supportedHidDevices': 0,
    'profile': 0,
    'fallbackToLogicalResolution': false,
    'chromaFormat': chromaFormat,
    'prefilterMode': 0,
    'prefilterSharpness': 0,
    'prefilterNoiseReduction': 0,
    'hudStreamingMode': 0,
    'maxBitrateKbps': (settings.maxBitrateMbps * 1000).round(),
    'codec': resolveRequestedCodecWireValue(
      codecWireValue(settings.codec),
      (supportedCodecs ?? const <VideoCodec>[]).map(codecWireValue).toList(),
    ),
    'vsync': false,
    'dynamicStreamingMode': 3,
    'audioChannelCount': 2,
  };
}

/// Port of shouldRequestReflex
bool shouldRequestReflex(StreamSettings settings) {
  final resolution = settings.cloudGsyncResolution;
  if (resolution != null && resolution.reflexEnabled) return true;

  final reflexMinimum =
      resolution?.capabilities.minimumFpsForReflexWithoutVrr ?? 120;
  return settings.enableCloudGsync || settings.fps >= reflexMinimum;
}

/// Port of shouldEnableInGameSettingsPersistence
bool shouldEnableInGameSettingsPersistence({
  required bool? enablePersistingInGameSettings,
  required bool? supportsInGameSettingsPersistence,
}) {
  return enablePersistingInGameSettings == true &&
      supportsInGameSettingsPersistence == true;
}

/// Port of cloudmatchSessionRequest.ts parseResolution
({int width, int height}) parseResolution(String input) {
  final parts = input.split('x');
  final width = int.tryParse(parts.isNotEmpty ? parts.first : '') ?? -1;
  final height = parts.length > 1 ? int.tryParse(parts[1]) ?? -1 : -1;
  if (width <= 0 || height <= 0) return (width: 1920, height: 1080);
  return (width: width, height: height);
}

/// Port of cloudmatchSessionRequest.ts timezoneOffsetMs
int timezoneOffsetMs() {
  return DateTime.now().timeZoneOffset.inMilliseconds;
}