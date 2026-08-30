enum GfnDeviceOs { windows, macOS, linux, android, iOS }

enum GfnDeviceType { desktop, console }

class GfnDeviceIdentity {
  final GfnDeviceOs deviceOs;
  final GfnDeviceType deviceType;
  final String deviceMake;
  final String deviceModel;
  final String clientPlatformName;

  const GfnDeviceIdentity({
    required this.deviceOs,
    required this.deviceType,
    required this.deviceMake,
    required this.deviceModel,
    required this.clientPlatformName,
  });

  Map<String, String> toNvHeaders() {
    return {
      'nv-device-os': _wireDeviceOs(),
      'nv-device-type': deviceType == GfnDeviceType.desktop ? 'DESKTOP' : 'CONSOLE',
      'nv-device-make': deviceMake,
      'nv-device-model': deviceModel,
    };
  }

  String _wireDeviceOs() {
    switch (deviceOs) {
      case GfnDeviceOs.windows:
        return 'WINDOWS';
      case GfnDeviceOs.macOS:
        return 'MACOS';
      case GfnDeviceOs.linux:
        return 'LINUX';
      case GfnDeviceOs.android:
        return 'ANDROID';
      case GfnDeviceOs.iOS:
        return 'IOS';
    }
  }
}