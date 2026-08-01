import 'package:flutter/foundation.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
