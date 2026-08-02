import 'package:flutter/foundation.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/neon.dart';

/// Launch preferences that are sent to the NVIDIA server in the
/// `SessionCreateRequest`. Persisted locally so launches reuse the last choice.
class UserSettings extends ChangeNotifier {
  final SharedPreferences _prefs;

  static const _keyResolution = 'settings.resolution';
  static const _keyFps = 'settings.fps';
  static const _keyBitrate = 'settings.bitrate';
  static const _keyCodec = 'settings.codec';
  static const _keyColorQuality = 'settings.colorQuality';
  static const _keyKeyboardLayout = 'settings.keyboardLayout';
  static const _keyGameLanguage = 'settings.gameLanguage';
  static const _keyL4S = 'settings.l4s';
  static const _keyCloudGsync = 'settings.cloudGsync';
  static const _keyAppLaunchMode = 'settings.appLaunchMode';
  static const _keyNativeCloudGsyncMode = 'settings.nativeCloudGsyncMode';
  static const _keyRegionUrl = 'settings.regionUrl';
  static const _keyAdvancedMode = 'settings.advancedMode';
  static const _keyStreamGamepad = 'settings.stream.gamepad';
  static const _keyStreamGamepadScale = 'settings.stream.gamepadScale';
  static const _keyStreamShowFps = 'settings.stream.showFps';
  static const _keyWebrtcIceTransport = 'settings.webrtc.iceTransport';
  static const _keyWebrtcIcePoolSize = 'settings.webrtc.icePoolSize';
  static const _keyWebrtcBundle = 'settings.webrtc.bundle';
  static const _keyWebrtcRtcpMux = 'settings.webrtc.rtcpMux';
  static const _keyWebrtcHwAccel = 'settings.webrtc.hwAccel';
  static const _keyWebrtcStun = 'settings.webrtc.stun';
  static const _keyWebrtcDscp = 'settings.webrtc.dscp';
  static const _keyWebrtcMaxIpv6Networks = 'settings.webrtc.maxIpv6Networks';
  static const _keyStreamPriority = 'settings.experimental.streamPriority';
  static const _keyBackgroundStyle = 'settings.ui.backgroundStyle';
  static const _keyLogsEnabled = 'settings.perf.logsEnabled';
  static const _keyHideTitleBar = 'settings.ui.hideTitleBar';

  String _resolution = '1920x1080';
  int _fps = 60;
  int _maxBitrateMbps = 50;
  VideoCodec _codec = VideoCodec.h264;
  ColorQuality _colorQuality = const ColorQuality(bitDepth: 0, chromaFormat: 0);
  KeyboardLayout _keyboardLayout = KeyboardLayout.enUs;
  GameLanguage _gameLanguage = GameLanguage.enUS;
  bool _enableL4S = false;
  bool _enableCloudGsync = false;
  AppLaunchMode _appLaunchMode = AppLaunchMode.default_;
  NativeStreamerFeatureMode _nativeCloudGsyncMode =
      NativeStreamerFeatureMode.auto;
  String? _selectedRegionUrl;
  bool _advancedMode = false;
  bool _streamGamepad = false;
  double _streamGamepadScale = 1.0;
  bool _streamShowFps = false;
  WebrtcIceTransportPolicy _webrtcIceTransport = WebrtcIceTransportPolicy.all;
  int _webrtcIcePoolSize = 0;
  WebrtcBundlePolicy _webrtcBundle = WebrtcBundlePolicy.balanced;
  WebrtcRtcpMuxPolicy _webrtcRtcpMux = WebrtcRtcpMuxPolicy.require;
  bool _webrtcHwAccel = true;
  String _webrtcStunServer = '';
  bool _webrtcEnableDscp = false;
  int _webrtcMaxIpv6Networks = 64;
  StreamPriority _streamPriority = StreamPriority.quality;
  BackgroundStyle _backgroundStyle = BackgroundStyle.beams;
  bool _logsEnabled = true;
  bool _hideTitleBar = false;

  UserSettings(this._prefs) {
    _load();
  }

  String get resolution => _resolution;
  int get fps => _fps;
  int get maxBitrateMbps => _maxBitrateMbps;
  VideoCodec get codec => _codec;
  ColorQuality get colorQuality => _colorQuality;
  KeyboardLayout get keyboardLayout => _keyboardLayout;
  GameLanguage get gameLanguage => _gameLanguage;
  bool get enableL4S => _enableL4S;
  bool get enableCloudGsync => _enableCloudGsync;
  AppLaunchMode get appLaunchMode => _appLaunchMode;
  NativeStreamerFeatureMode get nativeCloudGsyncMode => _nativeCloudGsyncMode;
  String? get selectedRegionUrl => _selectedRegionUrl;
  bool get advancedMode => _advancedMode;
  bool get streamGamepad => _streamGamepad;
  double get streamGamepadScale => _streamGamepadScale;
  bool get streamShowFps => _streamShowFps;
  WebrtcIceTransportPolicy get webrtcIceTransport => _webrtcIceTransport;
  int get webrtcIcePoolSize => _webrtcIcePoolSize;
  WebrtcBundlePolicy get webrtcBundle => _webrtcBundle;
  WebrtcRtcpMuxPolicy get webrtcRtcpMux => _webrtcRtcpMux;
  bool get webrtcHwAccel => _webrtcHwAccel;
  String get webrtcStunServer => _webrtcStunServer;
  bool get webrtcEnableDscp => _webrtcEnableDscp;
  int get webrtcMaxIpv6Networks => _webrtcMaxIpv6Networks;
  StreamPriority get streamPriority => _streamPriority;
  BackgroundStyle get backgroundStyle => _backgroundStyle;
  bool get logsEnabled => _logsEnabled;
  bool get hideTitleBar => _hideTitleBar;

  set resolution(String v) {
    if (_resolution == v) return;
    _resolution = v;
    _save(_keyResolution, v);
    notifyListeners();
  }

  set fps(int v) {
    if (_fps == v) return;
    _fps = v;
    _save(_keyFps, v);
    notifyListeners();
  }

  set maxBitrateMbps(int v) {
    if (_maxBitrateMbps == v) return;
    _maxBitrateMbps = v;
    _save(_keyBitrate, v);
    notifyListeners();
  }

  set codec(VideoCodec v) {
    if (_codec == v) return;
    _codec = v;
    _save(_keyCodec, v.name);
    notifyListeners();
  }

  set colorQuality(ColorQuality v) {
    if (_colorQuality.bitDepth == v.bitDepth &&
        _colorQuality.chromaFormat == v.chromaFormat) {
      return;
    }
    _colorQuality = v;
    _save(_keyColorQuality, v.wireValue);
    notifyListeners();
  }

  set keyboardLayout(KeyboardLayout v) {
    if (_keyboardLayout == v) return;
    _keyboardLayout = v;
    _save(_keyKeyboardLayout, v.name);
    notifyListeners();
  }

  set gameLanguage(GameLanguage v) {
    if (_gameLanguage == v) return;
    _gameLanguage = v;
    _save(_keyGameLanguage, v.name);
    notifyListeners();
  }

  set enableL4S(bool v) {
    if (_enableL4S == v) return;
    _enableL4S = v;
    _save(_keyL4S, v);
    notifyListeners();
  }

  set enableCloudGsync(bool v) {
    if (_enableCloudGsync == v) return;
    _enableCloudGsync = v;
    _save(_keyCloudGsync, v);
    notifyListeners();
  }

  set appLaunchMode(AppLaunchMode v) {
    if (_appLaunchMode == v) return;
    _appLaunchMode = v;
    _save(_keyAppLaunchMode, v.name);
    notifyListeners();
  }

  set nativeCloudGsyncMode(NativeStreamerFeatureMode v) {
    if (_nativeCloudGsyncMode == v) return;
    _nativeCloudGsyncMode = v;
    _save(_keyNativeCloudGsyncMode, v.name);
    notifyListeners();
  }

  set selectedRegionUrl(String? v) {
    if (_selectedRegionUrl == v) return;
    _selectedRegionUrl = v;
    if (v == null) {
      _prefs.remove(_keyRegionUrl);
    } else {
      _prefs.setString(_keyRegionUrl, v);
    }
    notifyListeners();
  }

  set advancedMode(bool v) {
    if (_advancedMode == v) return;
    _advancedMode = v;
    _save(_keyAdvancedMode, v);
    notifyListeners();
  }

  set streamGamepad(bool v) {
    if (_streamGamepad == v) return;
    _streamGamepad = v;
    _save(_keyStreamGamepad, v);
    notifyListeners();
  }

  set streamGamepadScale(double v) {
    final clamped = v.clamp(0.6, 1.4);
    if (_streamGamepadScale == clamped) return;
    _streamGamepadScale = clamped;
    _prefs.setDouble(_keyStreamGamepadScale, clamped);
    notifyListeners();
  }

  set streamShowFps(bool v) {
    if (_streamShowFps == v) return;
    _streamShowFps = v;
    _save(_keyStreamShowFps, v);
    notifyListeners();
  }

  set webrtcIceTransport(WebrtcIceTransportPolicy v) {
    if (_webrtcIceTransport == v) return;
    _webrtcIceTransport = v;
    _save(_keyWebrtcIceTransport, v.name);
    notifyListeners();
  }

  set webrtcIcePoolSize(int v) {
    if (_webrtcIcePoolSize == v) return;
    _webrtcIcePoolSize = v;
    _save(_keyWebrtcIcePoolSize, v);
    notifyListeners();
  }

  set webrtcBundle(WebrtcBundlePolicy v) {
    if (_webrtcBundle == v) return;
    _webrtcBundle = v;
    _save(_keyWebrtcBundle, v.name);
    notifyListeners();
  }

  set webrtcRtcpMux(WebrtcRtcpMuxPolicy v) {
    if (_webrtcRtcpMux == v) return;
    _webrtcRtcpMux = v;
    _save(_keyWebrtcRtcpMux, v.name);
    notifyListeners();
  }

  set webrtcHwAccel(bool v) {
    if (_webrtcHwAccel == v) return;
    _webrtcHwAccel = v;
    _save(_keyWebrtcHwAccel, v);
    notifyListeners();
  }

  set webrtcStunServer(String v) {
    if (_webrtcStunServer == v) return;
    _webrtcStunServer = v;
    _save(_keyWebrtcStun, v);
    notifyListeners();
  }

  set webrtcEnableDscp(bool v) {
    if (_webrtcEnableDscp == v) return;
    _webrtcEnableDscp = v;
    _save(_keyWebrtcDscp, v);
    notifyListeners();
  }

  set webrtcMaxIpv6Networks(int v) {
    if (_webrtcMaxIpv6Networks == v) return;
    _webrtcMaxIpv6Networks = v;
    _save(_keyWebrtcMaxIpv6Networks, v);
    notifyListeners();
  }

  set streamPriority(StreamPriority v) {
    if (_streamPriority == v) return;
    _streamPriority = v;
    _save(_keyStreamPriority, v.name);
    notifyListeners();
  }

  set backgroundStyle(BackgroundStyle v) {
    if (_backgroundStyle == v) return;
    _backgroundStyle = v;
    _save(_keyBackgroundStyle, v.name);
    BackgroundGlow.current.value = v;
    notifyListeners();
  }

  set logsEnabled(bool v) {
    if (_logsEnabled == v) return;
    _logsEnabled = v;
    _save(_keyLogsEnabled, v);
    notifyListeners();
  }

  set hideTitleBar(bool v) {
    if (_hideTitleBar == v) return;
    _hideTitleBar = v;
    _save(_keyHideTitleBar, v);
    notifyListeners();
  }

  StreamSettings buildStreamSettings() {
    return StreamSettings(
      resolution: _resolution,
      fps: _fps,
      maxBitrateMbps: _maxBitrateMbps,
      codec: _codec,
      colorQuality: _colorQuality,
      keyboardLayout: _keyboardLayout,
      gameLanguage: _gameLanguage,
      enableL4S: _enableL4S,
      enableCloudGsync: _enableCloudGsync,
      appLaunchMode: _appLaunchMode,
      nativeCloudGsyncMode: _nativeCloudGsyncMode,
    );
  }

  void _load() {
    _resolution = _prefs.getString(_keyResolution) ?? _resolution;
    _fps = _prefs.getInt(_keyFps) ?? _fps;
    _maxBitrateMbps = _prefs.getInt(_keyBitrate) ?? _maxBitrateMbps;
    _codec = VideoCodec.values.asNameMap()[_prefs.getString(_keyCodec)] ?? _codec;
    _colorQuality = _parseColorQuality(_prefs.getString(_keyColorQuality)) ?? _colorQuality;
    _keyboardLayout =
        KeyboardLayout.values.asNameMap()[_prefs.getString(_keyKeyboardLayout)] ??
            _keyboardLayout;
    _gameLanguage =
        GameLanguage.values.asNameMap()[_prefs.getString(_keyGameLanguage)] ??
            _gameLanguage;
    _enableL4S = _prefs.getBool(_keyL4S) ?? _enableL4S;
    _enableCloudGsync = _prefs.getBool(_keyCloudGsync) ?? _enableCloudGsync;
    _appLaunchMode =
        AppLaunchMode.values.asNameMap()[_prefs.getString(_keyAppLaunchMode)] ??
            _appLaunchMode;
    _nativeCloudGsyncMode = NativeStreamerFeatureMode.values
            .asNameMap()[_prefs.getString(_keyNativeCloudGsyncMode)] ??
        _nativeCloudGsyncMode;
    _selectedRegionUrl = _prefs.getString(_keyRegionUrl);
    _advancedMode = _prefs.getBool(_keyAdvancedMode) ?? _advancedMode;
    _streamGamepad = _prefs.getBool(_keyStreamGamepad) ?? _streamGamepad;
    _streamGamepadScale =
        _prefs.getDouble(_keyStreamGamepadScale) ?? _streamGamepadScale;
    _streamShowFps = _prefs.getBool(_keyStreamShowFps) ?? _streamShowFps;
    _webrtcIceTransport = WebrtcIceTransportPolicy
            .values.asNameMap()[_prefs.getString(_keyWebrtcIceTransport)] ??
        _webrtcIceTransport;
    _webrtcIcePoolSize =
        _prefs.getInt(_keyWebrtcIcePoolSize) ?? _webrtcIcePoolSize;
    _webrtcBundle = WebrtcBundlePolicy.values
            .asNameMap()[_prefs.getString(_keyWebrtcBundle)] ??
        _webrtcBundle;
    _webrtcRtcpMux = WebrtcRtcpMuxPolicy.values
            .asNameMap()[_prefs.getString(_keyWebrtcRtcpMux)] ??
        _webrtcRtcpMux;
    _webrtcHwAccel = _prefs.getBool(_keyWebrtcHwAccel) ?? _webrtcHwAccel;
    _webrtcStunServer = _prefs.getString(_keyWebrtcStun) ?? _webrtcStunServer;
    _webrtcEnableDscp =
        _prefs.getBool(_keyWebrtcDscp) ?? _webrtcEnableDscp;
    _webrtcMaxIpv6Networks =
        _prefs.getInt(_keyWebrtcMaxIpv6Networks) ?? _webrtcMaxIpv6Networks;
    _streamPriority = StreamPriority.values.asNameMap()[
            _prefs.getString(_keyStreamPriority)] ??
        _streamPriority;
    _backgroundStyle = BackgroundStyle.values.asNameMap()[
            _prefs.getString(_keyBackgroundStyle)] ??
        _backgroundStyle;
    _logsEnabled = _prefs.getBool(_keyLogsEnabled) ?? _logsEnabled;
    _hideTitleBar = _prefs.getBool(_keyHideTitleBar) ?? _hideTitleBar;
    BackgroundGlow.current.value = _backgroundStyle;
  }

  void _save(String key, Object value) {
    if (value is String) {
      _prefs.setString(key, value);
    } else if (value is int) {
      _prefs.setInt(key, value);
    } else if (value is bool) {
      _prefs.setBool(key, value);
    }
  }

  ColorQuality? _parseColorQuality(String? raw) {
    if (raw == null) return null;
    final bitDepth = raw.startsWith('10bit') ? 1 : 0;
    final chroma = raw.endsWith('444') ? 1 : 0;
    return ColorQuality(bitDepth: bitDepth, chromaFormat: chroma);
  }

  /// Resets every setting back to its factory default and clears the persisted
  /// values. Leaves the saved auth session intact (account stays signed in).
  Future<void> resetToDefaults() async {
    for (final key in _allKeys) {
      await _prefs.remove(key);
    }
    _resolution = '1920x1080';
    _fps = 60;
    _maxBitrateMbps = 50;
    _codec = VideoCodec.h264;
    _colorQuality = const ColorQuality(bitDepth: 0, chromaFormat: 0);
    _keyboardLayout = KeyboardLayout.enUs;
    _gameLanguage = GameLanguage.enUS;
    _enableL4S = false;
    _enableCloudGsync = false;
    _appLaunchMode = AppLaunchMode.default_;
    _nativeCloudGsyncMode = NativeStreamerFeatureMode.auto;
    _selectedRegionUrl = null;
    _advancedMode = false;
    _streamGamepad = false;
    _streamGamepadScale = 1.0;
    _streamShowFps = false;
    _webrtcIceTransport = WebrtcIceTransportPolicy.all;
    _webrtcIcePoolSize = 0;
    _webrtcBundle = WebrtcBundlePolicy.balanced;
    _webrtcRtcpMux = WebrtcRtcpMuxPolicy.require;
    _webrtcHwAccel = true;
    _webrtcStunServer = '';
    _webrtcEnableDscp = false;
    _webrtcMaxIpv6Networks = 64;
    _streamPriority = StreamPriority.quality;
    _backgroundStyle = BackgroundStyle.beams;
    _logsEnabled = true;
    _hideTitleBar = false;
    BackgroundGlow.current.value = _backgroundStyle;
    notifyListeners();
  }

  static final List<String> _allKeys = [
    _keyResolution,
    _keyFps,
    _keyBitrate,
    _keyCodec,
    _keyColorQuality,
    _keyKeyboardLayout,
    _keyGameLanguage,
    _keyL4S,
    _keyCloudGsync,
    _keyAppLaunchMode,
    _keyNativeCloudGsyncMode,
    _keyRegionUrl,
    _keyAdvancedMode,
    _keyStreamGamepad,
    _keyStreamGamepadScale,
    _keyStreamShowFps,
    _keyWebrtcIceTransport,
    _keyWebrtcIcePoolSize,
    _keyWebrtcBundle,
    _keyWebrtcRtcpMux,
    _keyWebrtcHwAccel,
    _keyWebrtcStun,
    _keyWebrtcDscp,
    _keyWebrtcMaxIpv6Networks,
    _keyStreamPriority,
    _keyBackgroundStyle,
    _keyLogsEnabled,
    _keyHideTitleBar,
  ];
}

/// WebRTC client-side ICE transport policy (RTCConfiguration).
enum WebrtcIceTransportPolicy { all, relay }

/// WebRTC bundle policy (RTCConfiguration).
enum WebrtcBundlePolicy { balanced, maxCompat, maxBundle }

/// WebRTC rtcp-mux policy (RTCConfiguration).
enum WebrtcRtcpMuxPolicy { require, negotiate }

/// Experimental: how the NVIDIA server should adapt resolution/FPS under load,
/// expressed via the nvstSdp vqos policy lines. Unverified against the live
/// server — may be ignored, and changing it only affects new sessions.
enum StreamPriority {
  /// Prefer full resolution and bitrate; allow the server to drop decode FPS
  /// under load before touching resolution.
  quality,

  /// Balance resolution and FPS.
  balanced,

  /// Prefer holding frame rate; allow resolution to scale down first.
  fps,
}
