import 'package:flutter/foundation.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/controller_theme.dart';
import '../theme/neon.dart';
import 'stream_transport.dart' show StreamTransportKind;
import 'video_shader_settings.dart';

/// Layout style of the on-stream stats overlay.
enum StatsOverlayStyle { compact, detailed }

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
  static const _keyStreamGamepadSpacing = 'settings.stream.gamepadSpacing';
  static const _keyStreamGamepadPosition = 'settings.stream.gamepadPosition';
  static const _keyStreamGamepadEdgePad = 'settings.stream.gamepadEdgePad';
  static const _keyStreamStickClickMode = 'settings.stream.stickClickMode';
  static const _keyStreamPadVisible = 'settings.stream.padVisible';
  static const _keyStreamGamepadOpacity = 'settings.stream.gamepadOpacity';
  static const _keyStreamGamepadShowShoulders =
      'settings.stream.gamepadShowShoulders';
  static const _keyStreamGamepadShowSticks =
      'settings.stream.gamepadShowSticks';
  static const _keyStreamGamepadShowDpad = 'settings.stream.gamepadShowDpad';
  static const _keyStreamGamepadShowFaceButtons =
      'settings.stream.gamepadShowFaceButtons';
  static const _keyStreamGamepadShowMenu = 'settings.stream.gamepadShowMenu';
  static const _keyStreamGamepadTheme = 'settings.stream.gamepadTheme';
  static const _keyStreamGamepadStickScale =
      'settings.stream.gamepadStickScale';
  static const _keyStreamGamepadFaceScale = 'settings.stream.gamepadFaceScale';
  static const _keyStreamGamepadDpadScale = 'settings.stream.gamepadDpadScale';
  static const _keyStreamGamepadSouthpaw = 'settings.stream.gamepadSouthpaw';
  static const _keyStreamGamepadNintendoLayout =
      'settings.stream.gamepadNintendoLayout';
  static const _keyStreamGamepadDeadzone = 'settings.stream.gamepadDeadzone';
  static const _keyStreamGamepadHaptics = 'settings.stream.gamepadHaptics';
  static const _keyStreamGamepadEffects = 'settings.stream.gamepadEffects';
  static const _keyStreamGamepadAnimations =
      'settings.stream.gamepadAnimations';
  static const _keyStreamStatsStyle = 'settings.stream.statsStyle';
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
  static const _keyStreamPriorityEnabled =
      'settings.experimental.streamPriorityEnabled';
  static const _keyStreamTransport = 'settings.experimental.streamTransport';
  static const _keyDecoderBackend = 'settings.experimental.decoderBackend';
  static const _keyRendererBackend = 'settings.experimental.rendererBackend';
  static const _keyVideoShader = 'settings.videoShader';
  static const _keyBackgroundStyle = 'settings.ui.backgroundStyle';
  static const _keyUiScale = 'settings.ui.scale';
  static const _keyUiScaleTouched = 'settings.ui.scaleTouched';
  static const _keyUiAnimations = 'settings.ui.animations';
  static const _keyLogsEnabled = 'settings.perf.logsEnabled';
  static const _keyLatencyGuard = 'settings.perf.latencyGuard';
  static const _keyZeroPlayoutDelay = zeroPlayoutDelayPrefKey;
  static const _keyHideTitleBar = 'settings.ui.hideTitleBar';
  static const _keyMaxPerformanceMode = 'settings.perf.maxPerformance';
  // --- Experimental stream optimizations --------------------------------
  static const _keyOptLowLatency = 'settings.experimental.opt.lowLatency';
  static const _keyOptRecovery = 'settings.experimental.opt.recoveryProfile';
  static const _keyOptMinBitrate = 'settings.experimental.opt.minBitrate';
  static const _keyOptNack = 'settings.experimental.opt.enableNack';
  static const _keyOptFec = 'settings.experimental.opt.enableFec';
  static const _keyOptConstantQuality =
      'settings.experimental.opt.constantQuality';
  // --- Input (client-side, applied on the stream surface) ----------------
  static const _keyInputSensitivity = 'settings.input.mouseSensitivity';
  static const _keyInputAcceleration = 'settings.input.mouseAcceleration';
  static const _keyInputPrecision = 'settings.input.mousePrecision';
  static const _keyInputSamplingMs = 'settings.input.mouseSamplingMs';
  static const _keyInputCursorOverlay = 'settings.input.cursorOverlay';
  static const _keyInputCursorNative = 'settings.input.cursorNative';
  static const _keyInputTouchMode = 'settings.input.touchMode';
  static const _keyInputTouchEnabled = 'settings.input.touchEnabled';
  static const _keyKeyboardTapToDismiss = 'settings.input.keyboardTapToDismiss';
  // --- Debug diagnostics (advanced) --------------------------------------
  static const _keyDebugCursorOverlayBox = 'settings.debug.cursorOverlayBox';

  /// One-shot migration flag for the sampling default flip (adaptive ->
  /// immediate): only the pre-existing stored 0 from the old default is
  /// rewritten; a later explicit choice of adaptive (also 0) is left alone.
  static const _keyInputSamplingMigrated = 'settings.input.samplingMigrated';

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
  double _streamGamepadSpacing = 1.0;
  double _streamGamepadPosition = 0.0;
  double _streamGamepadEdgePad = 12.0;
  StickClickMode _streamStickClickMode = StickClickMode.direct;
  bool _streamPadVisible = true;
  double _streamGamepadOpacity = 1.0;
  bool _streamGamepadShowShoulders = true;
  bool _streamGamepadShowSticks = true;
  bool _streamGamepadShowDpad = true;
  bool _streamGamepadShowFaceButtons = true;
  bool _streamGamepadShowMenu = true;
  ControllerTheme _streamGamepadTheme = ControllerThemes.neon;
  double _streamGamepadStickScale = 1.0;
  double _streamGamepadFaceScale = 1.0;
  double _streamGamepadDpadScale = 1.0;
  bool _streamGamepadSouthpaw = false;
  bool _streamGamepadNintendoLayout = false;
  double _streamGamepadDeadzone = 0.0;
  bool _streamGamepadHaptics = true;
  bool _streamGamepadEffects = true;
  bool _streamGamepadAnimations = true;
  StatsOverlayStyle _streamStatsStyle = StatsOverlayStyle.detailed;
  bool _streamShowFps = false;
  WebrtcIceTransportPolicy _webrtcIceTransport = WebrtcIceTransportPolicy.all;
  int _webrtcIcePoolSize = 4;
  WebrtcBundlePolicy _webrtcBundle = WebrtcBundlePolicy.maxBundle;
  WebrtcRtcpMuxPolicy _webrtcRtcpMux = WebrtcRtcpMuxPolicy.require;
  bool _webrtcHwAccel = true;
  String _webrtcStunServer = '';
  bool _webrtcEnableDscp = false;
  int _webrtcMaxIpv6Networks = 64;
  StreamPriority _streamPriority = StreamPriority.quality;
  bool _streamPriorityEnabled = false;
  StreamTransportKind _streamTransport = StreamTransportKind.flutterWebrtc;
  DecoderBackend _decoderBackend = DecoderBackend.vaapi;
  RendererBackend _rendererBackend = RendererBackend.gl;
  VideoShaderSettings _videoShader = VideoShaderSettings.defaults;
  BackgroundStyle _backgroundStyle = BackgroundStyle.circuit;
  double _uiScale = 1.0;
  bool _uiScaleTouched = false;
  bool _uiAnimations = true;
  bool _logsEnabled = false;
  bool _latencyGuardEnabled = false;
  bool _zeroPlayoutDelayEnabled = false;
  bool _hideTitleBar = false;
  bool _maxPerformanceMode = false;
  // --- Experimental stream optimizations (all default to the safe profile) --
  bool _optLowLatencyMode = false;
  StreamRecoveryProfile _optRecoveryProfile = StreamRecoveryProfile.latency;
  int _optMinBitrateKbps = 4000;
  bool _optEnableNack = true;
  bool _optEnableFec = true;
  bool _optConstantQuality = false;
  // --- Input (client-side, applied on the stream surface) ----------------
  double _inputMouseSensitivity = 1.0;
  int _inputMouseAcceleration = 1;
  bool _inputMousePrecision = true;
  int _inputMouseSamplingMs = -1; // -1 = immediate (proven path; adaptive = 0)
  bool _inputCursorOverlay = true;
  bool _inputCursorNative = true;
  TouchInputMode _inputTouchMode = TouchInputMode.relative;
  bool _inputTouchEnabled = false;
  bool _keyboardTapToDismiss = false;
  bool _debugCursorOverlayBox = false;

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

  /// Gamepad component spacing (0.5–2.0, 1.0 = default): multiplies the gaps
  /// between the control rows (shoulders ↔ sticks/D-pad/face ↔ menu) so the
  /// components offset relative to each other without resizing. Independent of
  /// [streamGamepadScale] (sizes) and [streamGamepadPosition] (vertical lift).
  double get streamGamepadSpacing => _streamGamepadSpacing;

  /// Gamepad vertical position (0.0–1.0, 0.0 = sitting at the bottom edge):
  /// lifts the whole pad up from the bottom of the screen without resizing it.
  /// Independent of [streamGamepadScale], which sizes the components.
  double get streamGamepadPosition => _streamGamepadPosition;

  /// Base inset (logical px) between the pad's anchors and the screen edges.
  double get streamGamepadEdgePad => _streamGamepadEdgePad;

  /// What a physical L3/R3 (stick click) does during a stream:
  /// [StickClickMode.direct] forwards it to the game as a real stick click,
  /// [StickClickMode.togglePad] toggles the virtual gamepad overlay instead.
  StickClickMode get streamStickClickMode => _streamStickClickMode;

  /// Virtual gamepad overlay visibility (toggled by L3/R3 in toggle mode).
  /// Lives on [UserSettings] — the same notify/rebuild path as the other
  /// show/hide element toggles, so hiding is guaranteed to stick.
  bool get streamPadVisible => _streamPadVisible;

  /// Whether the shoulder/trigger row (LT/RT/LB/RB) is shown on the gamepad.
  bool get streamGamepadShowShoulders => _streamGamepadShowShoulders;

  /// Whether the analog sticks are shown on the gamepad.
  bool get streamGamepadShowSticks => _streamGamepadShowSticks;

  /// Whether the D-pad is shown on the gamepad.
  bool get streamGamepadShowDpad => _streamGamepadShowDpad;

  /// Whether the face buttons (A/B/X/Y) are shown on the gamepad.
  bool get streamGamepadShowFaceButtons => _streamGamepadShowFaceButtons;

  /// Whether the menu buttons (Select/Start/Home) are shown on the gamepad.
  bool get streamGamepadShowMenu => _streamGamepadShowMenu;

  /// Active controller look (palette + shape language + material preset).
  ControllerTheme get streamGamepadTheme => _streamGamepadTheme;

  /// Per-group component-size multipliers (0.6–1.5, 1.0 = follow preset).
  double get streamGamepadStickScale => _streamGamepadStickScale;
  double get streamGamepadFaceScale => _streamGamepadFaceScale;
  double get streamGamepadDpadScale => _streamGamepadDpadScale;

  /// Southpaw mode: left/right analog sticks swap positions.
  bool get streamGamepadSouthpaw => _streamGamepadSouthpaw;

  /// Nintendo glyph layout: A/B and X/Y swap positions on the face cluster.
  bool get streamGamepadNintendoLayout => _streamGamepadNintendoLayout;

  /// Stick input dead zone as a fraction of full deflection (0.0–0.3).
  double get streamGamepadDeadzone => _streamGamepadDeadzone;

  /// Light haptic pulse when controls engage.
  bool get streamGamepadHaptics => _streamGamepadHaptics;

  /// Master toggle for shadows/glows (off = flat rendering).
  bool get streamGamepadEffects => _streamGamepadEffects;

  /// Whether press visuals animate (false = instant snap for max snappiness).
  bool get streamGamepadAnimations => _streamGamepadAnimations;

  /// Stats overlay layout (compact pill vs detailed panel).
  StatsOverlayStyle get streamStatsStyle => _streamStatsStyle;

  /// Gamepad overlay opacity (0.2–1.0, 1.0 = fully opaque). Tweaked live
  /// from the stream settings sidebar so the pad can sit semi-transparent
  /// over the video.
  double get streamGamepadOpacity => _streamGamepadOpacity;
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
  bool get streamPriorityEnabled => _streamPriorityEnabled;
  StreamTransportKind get streamTransport => _streamTransport;
  DecoderBackend get decoderBackend => _decoderBackend;
  RendererBackend get rendererBackend => _rendererBackend;

  /// Client-side GPU post-processing applied to the stream (port of OpenNOW's
  /// video shader filters: CAS sharpening, color grade, vibrance, film
  /// grain). Applies on the GPU renderer path only (RendererBackend.gl).
  VideoShaderSettings get videoShader => _videoShader;
  BackgroundStyle get backgroundStyle => _backgroundStyle;

  /// App-wide UI/text scale (0.75–1.5, 1.0 = default). Applied globally as a
  /// [TextScaler] multiplier over the OS font scale, so dialogs, labels and
  /// the stream chrome all grow/shrink together regardless of hardcoded sizes.
  double get uiScale => _uiScale;

  /// Master switch for decorative UI motion (entrance fades, staggered
  /// cards, animated backgrounds, carousel auto-advance).
  bool get uiAnimations => _uiAnimations;

  bool get logsEnabled => _logsEnabled;

  /// Watches the live stream for monotonic latency buildup (decoder backlog,
  /// jitter-buffer growth) and requests a keyframe resync when it detects the
  /// client falling behind over time.
  bool get latencyGuardEnabled => _latencyGuardEnabled;

  /// Renders decoded frames the moment they arrive when the server advertises
  /// the playout-delay RTP extension (WebRTC-ZeroPlayoutDelay field trial).
  /// Lowest render delay; may stutter under bursty jitter. Requires a restart
  /// to apply (the field trial binds at PeerConnectionFactory init).
  static const zeroPlayoutDelayPrefKey = 'settings.perf.zeroPlayoutDelay';
  bool get zeroPlayoutDelayEnabled => _zeroPlayoutDelayEnabled;

  /// Effective UI scale: 80% by default on Android (small screens), 100%
  /// elsewhere — until the user explicitly moves the slider, after which
  /// their value wins everywhere.
  double effectiveUiScale() {
    if (_uiScaleTouched) return _uiScale;
    return defaultTargetPlatform == TargetPlatform.android ? 0.8 : 1.0;
  }

  bool get hideTitleBar => _hideTitleBar;

  /// When true the stream stack aggressively maximizes render performance:
  /// disables expensive post-processing, forces hardware decode, prefers the
  /// GPU renderer, throttles telemetry, disables animated backgrounds and
  /// verbose logging. Applied on both Linux and Android.
  bool get maxPerformanceMode => _maxPerformanceMode;

  /// Effective values when max-performance is on: callers that affect the
  /// streaming pipeline should read these instead of the raw persisted values
  /// so the boost is reversible without losing the user's saved preferences.
  bool get effectiveLogsEnabled => _maxPerformanceMode ? false : _logsEnabled;
  VideoShaderSettings get effectiveVideoShader => _maxPerformanceMode
      ? const VideoShaderSettings(enabled: false)
      : _videoShader;
  RendererBackend get effectiveRendererBackend =>
      _maxPerformanceMode ? RendererBackend.gl : _rendererBackend;
  DecoderBackend get effectiveDecoderBackend =>
      _maxPerformanceMode ? DecoderBackend.vaapi : _decoderBackend;
  bool get effectiveHwAccel => _maxPerformanceMode ? true : _webrtcHwAccel;
  BackgroundStyle get effectiveBackgroundStyle =>
      _maxPerformanceMode ? BackgroundStyle.subtle : _backgroundStyle;
  bool get effectiveUiAnimations => _maxPerformanceMode ? false : _uiAnimations;
  Duration get statsPollInterval => _maxPerformanceMode
      ? const Duration(milliseconds: 1000)
      : const Duration(milliseconds: 500);
  bool get performanceShadowsEnabled => !_maxPerformanceMode;

  bool get optLowLatencyMode => _optLowLatencyMode;
  StreamRecoveryProfile get optRecoveryProfile => _optRecoveryProfile;
  int get optMinBitrateKbps => _optMinBitrateKbps;
  bool get optEnableNack => _optEnableNack;
  bool get optEnableFec => _optEnableFec;

  /// When on, tells the server to disable its adaptive bandwidth estimation
  /// and bitrate limiting so the encode bitrate stays at the max even during
  /// complex scenes. Holds quality through high-motion/particle moments, but
  /// gives up the graceful quality shed that protects a shaky link.
  bool get optConstantQuality => _optConstantQuality;

  /// Mouse sensitivity multiplier applied to every streamed delta
  /// (0.25–4.0, 1.0 = default). Port of OpenNOW's mouseSensitivity.
  double get inputMouseSensitivity => _inputMouseSensitivity;

  /// Software mouse acceleration strength (1–150, 1 = off). The curve boosts
  /// large fast deltas for turn speed while keeping small slow deltas precise.
  /// Port of OpenNOW's mouseAcceleration (OpenNOW defaults to 1 = linear).
  int get inputMouseAcceleration => _inputMouseAcceleration;

  /// Sub-pixel mouse precision: fractional deltas accumulate into a residual
  /// so micro-movements under 1 px are eventually sent instead of dropped.
  bool get inputMousePrecision => _inputMousePrecision;

  /// Mouse delta coalescing interval in ms. `<0` sends every event
  /// immediately (minimal latency, highest packet rate), `0` adapts between
  /// 2–20 ms from SCTP backpressure (OpenNOW's default), `>0` is a fixed
  /// 4/8/16 ms batch.
  int get inputMouseSamplingMs => _inputMouseSamplingMs;

  /// Renders the game's actual cursor client-side via the WebRTC
  /// `cursor_channel` (predefined styles map to OS cursors, custom bitmaps
  /// are drawn over the video). Off = server-side cursor rendering only.
  bool get inputCursorOverlay => _inputCursorOverlay;

  /// When on, predefined cursor styles (arrow/text/wait/crosshair/resize/move)
  /// are presented as the real OS cursor so the window manager applies its own
  /// cursor effects (speed-stretch etc.). Custom bitmap cursors always use the
  /// client-drawn overlay (Flutter can't set an arbitrary image as the OS
  /// cursor). Off = always draw the overlay bitmap.
  bool get inputCursorNative => _inputCursorNative;

  /// Debug bounding box behind the client-rendered cursor overlay, so its
  /// placement/size can be inspected while the actual bitmap decode is being
  /// tuned. Off by default (pure diagnostics).
  bool get debugCursorOverlayBox => _debugCursorOverlayBox;

  /// How a touch/finger on the surface maps to the game cursor:
  /// [TouchInputMode.absolute] pins the pointer to the exact touched spot
  /// (direct touch), [TouchInputMode.relative] streams deltas like a laptop
  /// trackpad.
  TouchInputMode get inputTouchMode => _inputTouchMode;

  /// Master switch for touch input on the stream surface. Off ignores touches
  /// entirely (they still enter the game, but never click or move the cursor),
  /// useful when playing with an external mouse/keyboard on a touch screen.
  bool get inputTouchEnabled => _inputTouchEnabled;

  /// When on, tapping the stream surface while the soft keyboard is up closes
  /// the keyboard (and consumes the tap) instead of keeping the IME open and
  /// forwarding the tap to the game. Off keeps the keyboard up so the in-game
  /// text field stays interactive — close it with the system back button.
  bool get keyboardTapToDismiss => _keyboardTapToDismiss;

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

  set streamGamepadSpacing(double v) {
    final clamped = v.clamp(0.5, 2.0);
    if (_streamGamepadSpacing == clamped) return;
    _streamGamepadSpacing = clamped;
    _prefs.setDouble(_keyStreamGamepadSpacing, clamped);
    notifyListeners();
  }

  set streamGamepadPosition(double v) {
    final clamped = v.clamp(-1.0, 1.0);
    if (_streamGamepadPosition == clamped) return;
    _streamGamepadPosition = clamped;
    _prefs.setDouble(_keyStreamGamepadPosition, clamped);
    notifyListeners();
  }

  set streamGamepadEdgePad(double v) {
    final clamped = v.clamp(0.0, 40.0);
    if (_streamGamepadEdgePad == clamped) return;
    _streamGamepadEdgePad = clamped;
    _prefs.setDouble(_keyStreamGamepadEdgePad, clamped);
    notifyListeners();
  }

  set streamStickClickMode(StickClickMode v) {
    if (_streamStickClickMode == v) return;
    _streamStickClickMode = v;
    _prefs.setString(_keyStreamStickClickMode, v.name);
    notifyListeners();
  }

  set streamPadVisible(bool v) {
    if (_streamPadVisible == v) return;
    _streamPadVisible = v;
    _prefs.setBool(_keyStreamPadVisible, v);
    notifyListeners();
  }

  set streamGamepadShowShoulders(bool v) {
    if (_streamGamepadShowShoulders == v) return;
    _streamGamepadShowShoulders = v;
    _save(_keyStreamGamepadShowShoulders, v);
    notifyListeners();
  }

  set streamGamepadShowSticks(bool v) {
    if (_streamGamepadShowSticks == v) return;
    _streamGamepadShowSticks = v;
    _save(_keyStreamGamepadShowSticks, v);
    notifyListeners();
  }

  set streamGamepadShowDpad(bool v) {
    if (_streamGamepadShowDpad == v) return;
    _streamGamepadShowDpad = v;
    _save(_keyStreamGamepadShowDpad, v);
    notifyListeners();
  }

  set streamGamepadShowFaceButtons(bool v) {
    if (_streamGamepadShowFaceButtons == v) return;
    _streamGamepadShowFaceButtons = v;
    _save(_keyStreamGamepadShowFaceButtons, v);
    notifyListeners();
  }

  set streamGamepadShowMenu(bool v) {
    if (_streamGamepadShowMenu == v) return;
    _streamGamepadShowMenu = v;
    _save(_keyStreamGamepadShowMenu, v);
    notifyListeners();
  }

  set streamGamepadTheme(ControllerTheme v) {
    if (_streamGamepadTheme == v) return;
    _streamGamepadTheme = v;
    _save(_keyStreamGamepadTheme, v.id);
    notifyListeners();
  }

  set streamGamepadStickScale(double v) {
    final clamped = v.clamp(0.6, 1.5);
    if (_streamGamepadStickScale == clamped) return;
    _streamGamepadStickScale = clamped;
    _prefs.setDouble(_keyStreamGamepadStickScale, clamped);
    notifyListeners();
  }

  set streamGamepadFaceScale(double v) {
    final clamped = v.clamp(0.6, 1.5);
    if (_streamGamepadFaceScale == clamped) return;
    _streamGamepadFaceScale = clamped;
    _prefs.setDouble(_keyStreamGamepadFaceScale, clamped);
    notifyListeners();
  }

  set streamGamepadDpadScale(double v) {
    final clamped = v.clamp(0.6, 1.5);
    if (_streamGamepadDpadScale == clamped) return;
    _streamGamepadDpadScale = clamped;
    _prefs.setDouble(_keyStreamGamepadDpadScale, clamped);
    notifyListeners();
  }

  set streamGamepadSouthpaw(bool v) {
    if (_streamGamepadSouthpaw == v) return;
    _streamGamepadSouthpaw = v;
    _save(_keyStreamGamepadSouthpaw, v);
    notifyListeners();
  }

  set streamGamepadNintendoLayout(bool v) {
    if (_streamGamepadNintendoLayout == v) return;
    _streamGamepadNintendoLayout = v;
    _save(_keyStreamGamepadNintendoLayout, v);
    notifyListeners();
  }

  set streamGamepadDeadzone(double v) {
    final clamped = v.clamp(0.0, 0.3);
    if (_streamGamepadDeadzone == clamped) return;
    _streamGamepadDeadzone = clamped;
    _prefs.setDouble(_keyStreamGamepadDeadzone, clamped);
    notifyListeners();
  }

  set streamGamepadHaptics(bool v) {
    if (_streamGamepadHaptics == v) return;
    _streamGamepadHaptics = v;
    _save(_keyStreamGamepadHaptics, v);
    notifyListeners();
  }

  set streamGamepadEffects(bool v) {
    if (_streamGamepadEffects == v) return;
    _streamGamepadEffects = v;
    _save(_keyStreamGamepadEffects, v);
    notifyListeners();
  }

  set streamGamepadAnimations(bool v) {
    if (_streamGamepadAnimations == v) return;
    _streamGamepadAnimations = v;
    _save(_keyStreamGamepadAnimations, v);
    notifyListeners();
  }

  set streamStatsStyle(StatsOverlayStyle v) {
    if (_streamStatsStyle == v) return;
    _streamStatsStyle = v;
    _save(_keyStreamStatsStyle, v.name);
    notifyListeners();
  }

  set streamGamepadOpacity(double v) {
    final clamped = v.clamp(0.2, 1.0);
    if (_streamGamepadOpacity == clamped) return;
    _streamGamepadOpacity = clamped;
    _prefs.setDouble(_keyStreamGamepadOpacity, clamped);
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

  /// Master switch for the experimental server-adaptation presets. When off,
  /// the stream always uses the OpenNOW-matching `quality` profile regardless
  /// of [streamPriority] (the server-adaptation lines stay at their safe
  /// defaults).
  set streamPriorityEnabled(bool v) {
    if (_streamPriorityEnabled == v) return;
    _streamPriorityEnabled = v;
    _save(_keyStreamPriorityEnabled, v);
    notifyListeners();
  }

  /// Which transport renders + carries the stream. Defaults to the stock
  /// libwebrtc path; the GStreamer webrtcbin FFI bridge is the experimental
  /// hardware-decode option.
  set streamTransport(StreamTransportKind v) {
    if (_streamTransport == v) return;
    _streamTransport = v;
    _save(_keyStreamTransport, v.name);
    notifyListeners();
  }

  /// Which decode backend the custom libwebrtc uses for the next session:
  /// [DecoderBackend.vaapi] (GStreamer VAAPI-first on Linux, D3D11VA-first on
  /// Windows, both with FFmpeg fallback) or [DecoderBackend.ffmpeg] (forced
  /// software). Applied just before the peer connection is created by setting
  /// the `OPENNOW_DECODER` env var that the libwebrtc decoder factory reads at
  /// decoder instantiation.
  set decoderBackend(DecoderBackend v) {
    if (_decoderBackend == v) return;
    _decoderBackend = v;
    _save(_keyDecoderBackend, v.name);
    notifyListeners();
  }

  /// How the libwebrtc renderer delivers decoded frames to Flutter:
  /// [RendererBackend.cpu] (stock libyuv ConvertToARGB into a pixel buffer)
  /// or [RendererBackend.gl] (Y/U/V planes uploaded as GPU textures, YUV→RGB
  /// in a shader — GL on Linux, D3D11 shared-handle on Windows — composited
  /// by the engine with no CPU readback). Applied via the `OPENNOW_RENDERER`
  /// env var read by the plugin when the video texture is created. Defaults
  /// to [RendererBackend.gl] — the GPU path falls back to CPU when the shader
  /// renderer isn't available, so the default stays compatible.
  set rendererBackend(RendererBackend v) {
    if (_rendererBackend == v) return;
    _rendererBackend = v;
    _save(_keyRendererBackend, v.name);
    notifyListeners();
  }

  /// Replaces the whole shader filter config (enabled + all six controls) and
  /// persists it. The stream surface pushes the change to the native GPU
  /// renderer, which re-applies it on the next composite.
  set videoShader(VideoShaderSettings v) {
    if (_videoShader == v) return;
    _videoShader = v;
    _prefs.setString(_keyVideoShader, v.toPersistedString());
    notifyListeners();
  }

  set backgroundStyle(BackgroundStyle v) {
    if (_backgroundStyle == v) return;
    _backgroundStyle = v;
    _save(_keyBackgroundStyle, v.name);
    BackgroundGlow.current.value = v;
    notifyListeners();
  }

  set uiScale(double v) {
    final clamped = v.clamp(0.75, 1.5);
    if (_uiScale == clamped && _uiScaleTouched) return;
    _uiScale = clamped;
    _uiScaleTouched = true;
    _prefs.setDouble(_keyUiScale, clamped);
    _prefs.setBool(_keyUiScaleTouched, true);
    notifyListeners();
  }

  set uiAnimations(bool v) {
    if (_uiAnimations == v) return;
    _uiAnimations = v;
    _save(_keyUiAnimations, v);
    UiMotion.enabled.value = effectiveUiAnimations;
    notifyListeners();
  }

  set logsEnabled(bool v) {
    if (_logsEnabled == v) return;
    _logsEnabled = v;
    _save(_keyLogsEnabled, v);
    notifyListeners();
  }

  set latencyGuardEnabled(bool v) {
    if (_latencyGuardEnabled == v) return;
    _latencyGuardEnabled = v;
    _save(_keyLatencyGuard, v);
    notifyListeners();
  }

  set zeroPlayoutDelayEnabled(bool v) {
    if (_zeroPlayoutDelayEnabled == v) return;
    _zeroPlayoutDelayEnabled = v;
    _save(_keyZeroPlayoutDelay, v);
    notifyListeners();
  }

  set hideTitleBar(bool v) {
    if (_hideTitleBar == v) return;
    _hideTitleBar = v;
    _save(_keyHideTitleBar, v);
    notifyListeners();
  }

  set maxPerformanceMode(bool v) {
    if (_maxPerformanceMode == v) return;
    _maxPerformanceMode = v;
    _save(_keyMaxPerformanceMode, v);
    // When going to max perf, immediately reflect the effective background
    // and notify so the whole UI (Neon glow, shader, renderer prefs)
    // re-evaluates via effective getters without overwriting persisted prefs.
    if (v) {
      BackgroundGlow.current.value = effectiveBackgroundStyle;
    } else {
      BackgroundGlow.current.value = _backgroundStyle;
    }
    UiMotion.enabled.value = effectiveUiAnimations;
    notifyListeners();
  }

  set optLowLatencyMode(bool v) {
    if (_optLowLatencyMode == v) return;
    _optLowLatencyMode = v;
    _save(_keyOptLowLatency, v);
    notifyListeners();
  }

  set optRecoveryProfile(StreamRecoveryProfile v) {
    if (_optRecoveryProfile == v) return;
    _optRecoveryProfile = v;
    _save(_keyOptRecovery, v.name);
    notifyListeners();
  }

  set optMinBitrateKbps(int v) {
    final clamped = v.clamp(1000, 100000).toInt();
    if (_optMinBitrateKbps == clamped) return;
    _optMinBitrateKbps = clamped;
    _save(_keyOptMinBitrate, clamped);
    notifyListeners();
  }

  set optEnableNack(bool v) {
    if (_optEnableNack == v) return;
    _optEnableNack = v;
    _save(_keyOptNack, v);
    notifyListeners();
  }

  set optEnableFec(bool v) {
    if (_optEnableFec == v) return;
    _optEnableFec = v;
    _save(_keyOptFec, v);
    notifyListeners();
  }

  set optConstantQuality(bool v) {
    if (_optConstantQuality == v) return;
    _optConstantQuality = v;
    _save(_keyOptConstantQuality, v);
    notifyListeners();
  }

  set inputMouseSensitivity(double v) {
    final clamped = v.clamp(0.25, 4.0);
    if (_inputMouseSensitivity == clamped) return;
    _inputMouseSensitivity = clamped;
    _prefs.setDouble(_keyInputSensitivity, clamped);
    notifyListeners();
  }

  set inputMouseAcceleration(int v) {
    final clamped = v.clamp(1, 150).toInt();
    if (_inputMouseAcceleration == clamped) return;
    _inputMouseAcceleration = clamped;
    _save(_keyInputAcceleration, clamped);
    notifyListeners();
  }

  set inputMousePrecision(bool v) {
    if (_inputMousePrecision == v) return;
    _inputMousePrecision = v;
    _save(_keyInputPrecision, v);
    notifyListeners();
  }

  set inputMouseSamplingMs(int v) {
    if (_inputMouseSamplingMs == v) return;
    _inputMouseSamplingMs = v;
    _save(_keyInputSamplingMs, v);
    notifyListeners();
  }

  set inputCursorOverlay(bool v) {
    if (_inputCursorOverlay == v) return;
    _inputCursorOverlay = v;
    _save(_keyInputCursorOverlay, v);
    notifyListeners();
  }

  set inputCursorNative(bool v) {
    if (_inputCursorNative == v) return;
    _inputCursorNative = v;
    _save(_keyInputCursorNative, v);
    notifyListeners();
  }

  set debugCursorOverlayBox(bool v) {
    if (_debugCursorOverlayBox == v) return;
    _debugCursorOverlayBox = v;
    _save(_keyDebugCursorOverlayBox, v);
    notifyListeners();
  }

  set inputTouchMode(TouchInputMode v) {
    if (_inputTouchMode == v) return;
    _inputTouchMode = v;
    _save(_keyInputTouchMode, v.name);
    notifyListeners();
  }

  set inputTouchEnabled(bool v) {
    if (_inputTouchEnabled == v) return;
    _inputTouchEnabled = v;
    _save(_keyInputTouchEnabled, v);
    notifyListeners();
  }

  set keyboardTapToDismiss(bool v) {
    if (_keyboardTapToDismiss == v) return;
    _keyboardTapToDismiss = v;
    _save(_keyKeyboardTapToDismiss, v);
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
    _codec =
        VideoCodec.values.asNameMap()[_prefs.getString(_keyCodec)] ?? _codec;
    _colorQuality =
        _parseColorQuality(_prefs.getString(_keyColorQuality)) ?? _colorQuality;
    _keyboardLayout =
        KeyboardLayout.values.asNameMap()[_prefs.getString(
          _keyKeyboardLayout,
        )] ??
        _keyboardLayout;
    _gameLanguage =
        GameLanguage.values.asNameMap()[_prefs.getString(_keyGameLanguage)] ??
        _gameLanguage;
    _enableL4S = _prefs.getBool(_keyL4S) ?? _enableL4S;
    _enableCloudGsync = _prefs.getBool(_keyCloudGsync) ?? _enableCloudGsync;
    _appLaunchMode =
        AppLaunchMode.values.asNameMap()[_prefs.getString(_keyAppLaunchMode)] ??
        _appLaunchMode;
    _nativeCloudGsyncMode =
        NativeStreamerFeatureMode.values.asNameMap()[_prefs.getString(
          _keyNativeCloudGsyncMode,
        )] ??
        _nativeCloudGsyncMode;
    _selectedRegionUrl = _prefs.getString(_keyRegionUrl);
    _advancedMode = _prefs.getBool(_keyAdvancedMode) ?? _advancedMode;
    _streamGamepad = _prefs.getBool(_keyStreamGamepad) ?? _streamGamepad;
    _streamGamepadScale =
        _prefs.getDouble(_keyStreamGamepadScale) ?? _streamGamepadScale;
    _streamGamepadSpacing =
        _prefs.getDouble(_keyStreamGamepadSpacing) ?? _streamGamepadSpacing;
    _streamGamepadPosition =
        _prefs.getDouble(_keyStreamGamepadPosition) ?? _streamGamepadPosition;
    _streamGamepadEdgePad =
        _prefs.getDouble(_keyStreamGamepadEdgePad) ?? _streamGamepadEdgePad;
    final stickMode = _prefs.getString(_keyStreamStickClickMode);
    if (stickMode != null) {
      _streamStickClickMode =
          StickClickMode.values.asNameMap()[stickMode] ?? _streamStickClickMode;
    }
    _streamGamepadOpacity =
        _prefs.getDouble(_keyStreamGamepadOpacity) ?? _streamGamepadOpacity;
    _streamGamepadShowShoulders =
        _prefs.getBool(_keyStreamGamepadShowShoulders) ??
        _streamGamepadShowShoulders;
    _streamGamepadShowSticks =
        _prefs.getBool(_keyStreamGamepadShowSticks) ?? _streamGamepadShowSticks;
    _streamGamepadShowDpad =
        _prefs.getBool(_keyStreamGamepadShowDpad) ?? _streamGamepadShowDpad;
    _streamGamepadShowFaceButtons =
        _prefs.getBool(_keyStreamGamepadShowFaceButtons) ??
        _streamGamepadShowFaceButtons;
    _streamGamepadShowMenu =
        _prefs.getBool(_keyStreamGamepadShowMenu) ?? _streamGamepadShowMenu;
    _streamGamepadTheme = ControllerThemes.byId(
      _prefs.getString(_keyStreamGamepadTheme),
    );
    _streamGamepadStickScale =
        _prefs.getDouble(_keyStreamGamepadStickScale) ??
        _streamGamepadStickScale;
    _streamGamepadFaceScale =
        _prefs.getDouble(_keyStreamGamepadFaceScale) ?? _streamGamepadFaceScale;
    _streamGamepadDpadScale =
        _prefs.getDouble(_keyStreamGamepadDpadScale) ?? _streamGamepadDpadScale;
    _streamGamepadSouthpaw =
        _prefs.getBool(_keyStreamGamepadSouthpaw) ?? _streamGamepadSouthpaw;
    _streamGamepadNintendoLayout =
        _prefs.getBool(_keyStreamGamepadNintendoLayout) ??
        _streamGamepadNintendoLayout;
    _streamGamepadDeadzone =
        _prefs.getDouble(_keyStreamGamepadDeadzone) ?? _streamGamepadDeadzone;
    _streamGamepadHaptics =
        _prefs.getBool(_keyStreamGamepadHaptics) ?? _streamGamepadHaptics;
    _streamGamepadEffects =
        _prefs.getBool(_keyStreamGamepadEffects) ?? _streamGamepadEffects;
    _streamGamepadAnimations =
        _prefs.getBool(_keyStreamGamepadAnimations) ?? _streamGamepadAnimations;
    _streamStatsStyle =
        StatsOverlayStyle.values.asNameMap()[_prefs.getString(
          _keyStreamStatsStyle,
        )] ??
        _streamStatsStyle;
    _streamShowFps = _prefs.getBool(_keyStreamShowFps) ?? _streamShowFps;
    _webrtcIceTransport =
        WebrtcIceTransportPolicy.values.asNameMap()[_prefs.getString(
          _keyWebrtcIceTransport,
        )] ??
        _webrtcIceTransport;
    _webrtcIcePoolSize =
        _prefs.getInt(_keyWebrtcIcePoolSize) ?? _webrtcIcePoolSize;
    _webrtcBundle =
        WebrtcBundlePolicy.values.asNameMap()[_prefs.getString(
          _keyWebrtcBundle,
        )] ??
        _webrtcBundle;
    _webrtcRtcpMux =
        WebrtcRtcpMuxPolicy.values.asNameMap()[_prefs.getString(
          _keyWebrtcRtcpMux,
        )] ??
        _webrtcRtcpMux;
    _webrtcHwAccel = _prefs.getBool(_keyWebrtcHwAccel) ?? _webrtcHwAccel;
    _webrtcStunServer = _prefs.getString(_keyWebrtcStun) ?? _webrtcStunServer;
    _webrtcEnableDscp = _prefs.getBool(_keyWebrtcDscp) ?? _webrtcEnableDscp;
    _webrtcMaxIpv6Networks =
        _prefs.getInt(_keyWebrtcMaxIpv6Networks) ?? _webrtcMaxIpv6Networks;
    _streamPriority =
        StreamPriority.values.asNameMap()[_prefs.getString(
          _keyStreamPriority,
        )] ??
        _streamPriority;
    _streamPriorityEnabled =
        _prefs.getBool(_keyStreamPriorityEnabled) ?? _streamPriorityEnabled;
    _streamTransport =
        StreamTransportKind.values.asNameMap()[_prefs.getString(
          _keyStreamTransport,
        )] ??
        _streamTransport;
    _decoderBackend =
        DecoderBackend.values.asNameMap()[_prefs.getString(
          _keyDecoderBackend,
        )] ??
        _decoderBackend;
    _rendererBackend =
        RendererBackend.values.asNameMap()[_prefs.getString(
          _keyRendererBackend,
        )] ??
        _rendererBackend;
    _videoShader = VideoShaderSettings.fromPersistedString(
      _prefs.getString(_keyVideoShader),
    );
    _backgroundStyle =
        BackgroundStyle.values.asNameMap()[_prefs.getString(
          _keyBackgroundStyle,
        )] ??
        _backgroundStyle;
    _uiScale = _prefs.getDouble(_keyUiScale) ?? _uiScale;
    _uiScaleTouched = _prefs.getBool(_keyUiScaleTouched) ?? _uiScaleTouched;
    _uiAnimations = _prefs.getBool(_keyUiAnimations) ?? _uiAnimations;
    _logsEnabled = _prefs.getBool(_keyLogsEnabled) ?? _logsEnabled;
    _latencyGuardEnabled =
        _prefs.getBool(_keyLatencyGuard) ?? _latencyGuardEnabled;
    _zeroPlayoutDelayEnabled =
        _prefs.getBool(_keyZeroPlayoutDelay) ?? _zeroPlayoutDelayEnabled;
    _hideTitleBar = _prefs.getBool(_keyHideTitleBar) ?? _hideTitleBar;
    _maxPerformanceMode =
        _prefs.getBool(_keyMaxPerformanceMode) ?? _maxPerformanceMode;
    _optLowLatencyMode =
        _prefs.getBool(_keyOptLowLatency) ?? _optLowLatencyMode;
    _optRecoveryProfile =
        StreamRecoveryProfile.values.asNameMap()[_prefs.getString(
          _keyOptRecovery,
        )] ??
        _optRecoveryProfile;
    _optMinBitrateKbps = _prefs.getInt(_keyOptMinBitrate) ?? _optMinBitrateKbps;
    _optEnableNack = _prefs.getBool(_keyOptNack) ?? _optEnableNack;
    _optEnableFec = _prefs.getBool(_keyOptFec) ?? _optEnableFec;
    _optConstantQuality =
        _prefs.getBool(_keyOptConstantQuality) ?? _optConstantQuality;
    _inputMouseSensitivity =
        _prefs.getDouble(_keyInputSensitivity) ?? _inputMouseSensitivity;
    _inputMouseAcceleration =
        _prefs.getInt(_keyInputAcceleration) ?? _inputMouseAcceleration;
    _inputMousePrecision =
        _prefs.getBool(_keyInputPrecision) ?? _inputMousePrecision;
    // The input-sampling feature shipped with adaptive (0) as the default;
    // that added latency and was implicated in the dead-mouse reports, so a
    // stored 0 from the old default is migrated to immediate (-1) — but only
    // once, so a later explicit choice of adaptive isn't reset every launch.
    if (!(_prefs.getBool(_keyInputSamplingMigrated) ?? false)) {
      final storedSamplingMs = _prefs.getInt(_keyInputSamplingMs);
      if (storedSamplingMs == 0) {
        _inputMouseSamplingMs = -1;
        _prefs.remove(_keyInputSamplingMs);
      }
      _prefs.setBool(_keyInputSamplingMigrated, true);
    }
    _inputMouseSamplingMs =
        _prefs.getInt(_keyInputSamplingMs) ?? _inputMouseSamplingMs;
    _inputCursorOverlay =
        _prefs.getBool(_keyInputCursorOverlay) ?? _inputCursorOverlay;
    _inputCursorNative =
        _prefs.getBool(_keyInputCursorNative) ?? _inputCursorNative;
    _inputTouchMode =
        TouchInputMode.values.asNameMap()[_prefs.getString(
          _keyInputTouchMode,
        )] ??
        _inputTouchMode;
    _inputTouchEnabled =
        _prefs.getBool(_keyInputTouchEnabled) ?? _inputTouchEnabled;
    _keyboardTapToDismiss =
        _prefs.getBool(_keyKeyboardTapToDismiss) ?? _keyboardTapToDismiss;
    _debugCursorOverlayBox =
        _prefs.getBool(_keyDebugCursorOverlayBox) ?? _debugCursorOverlayBox;
    BackgroundGlow.current.value = effectiveBackgroundStyle;
    UiMotion.enabled.value = effectiveUiAnimations;
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
    _streamGamepadSpacing = 1.0;
    _streamGamepadPosition = 0.0;
    _streamGamepadEdgePad = 12.0;
    _streamGamepadOpacity = 1.0;
    _streamGamepadShowShoulders = true;
    _streamGamepadShowSticks = true;
    _streamGamepadShowDpad = true;
    _streamGamepadShowFaceButtons = true;
    _streamGamepadShowMenu = true;
    _streamGamepadTheme = ControllerThemes.neon;
    _streamGamepadStickScale = 1.0;
    _streamGamepadFaceScale = 1.0;
    _streamGamepadDpadScale = 1.0;
    _streamGamepadSouthpaw = false;
    _streamGamepadNintendoLayout = false;
    _streamGamepadDeadzone = 0.0;
    _streamGamepadHaptics = true;
    _streamGamepadEffects = true;
    _streamGamepadAnimations = true;
    _streamStatsStyle = StatsOverlayStyle.detailed;
    _streamShowFps = false;
    _webrtcIceTransport = WebrtcIceTransportPolicy.all;
    _webrtcIcePoolSize = 4;
    _webrtcBundle = WebrtcBundlePolicy.maxBundle;
    _webrtcRtcpMux = WebrtcRtcpMuxPolicy.require;
    _webrtcHwAccel = true;
    _webrtcStunServer = '';
    _webrtcEnableDscp = false;
    _webrtcMaxIpv6Networks = 64;
    _streamPriority = StreamPriority.quality;
    _streamPriorityEnabled = false;
    _streamTransport = StreamTransportKind.flutterWebrtc;
    _decoderBackend = DecoderBackend.vaapi;
    _rendererBackend = RendererBackend.gl;
    _videoShader = VideoShaderSettings.defaults;
    _backgroundStyle = BackgroundStyle.circuit;
    _uiScale = 1.0;
    _uiScaleTouched = false;
    _uiAnimations = true;
    _logsEnabled = false;
    _latencyGuardEnabled = false;
    _zeroPlayoutDelayEnabled = false;
    _hideTitleBar = false;
    _maxPerformanceMode = false;
    _optLowLatencyMode = false;
    _optRecoveryProfile = StreamRecoveryProfile.latency;
    _optMinBitrateKbps = 4000;
    _optEnableNack = true;
    _optEnableFec = true;
    _optConstantQuality = false;
    _inputMouseSensitivity = 1.0;
    _inputMouseAcceleration = 1;
    _inputMousePrecision = true;
    _inputMouseSamplingMs = -1;
    _inputCursorOverlay = true;
    _inputCursorNative = true;
    _inputTouchMode = TouchInputMode.relative;
    _inputTouchEnabled = false;
    _keyboardTapToDismiss = false;
    _debugCursorOverlayBox = false;
    BackgroundGlow.current.value = _backgroundStyle;
    UiMotion.enabled.value = effectiveUiAnimations;
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
    _keyStreamGamepadSpacing,
    _keyStreamGamepadPosition,
    _keyStreamGamepadEdgePad,
    _keyStreamStickClickMode,
    _keyStreamPadVisible,
    _keyStreamGamepadOpacity,
    _keyStreamGamepadShowShoulders,
    _keyStreamGamepadShowSticks,
    _keyStreamGamepadShowDpad,
    _keyStreamGamepadShowFaceButtons,
    _keyStreamGamepadShowMenu,
    _keyStreamGamepadTheme,
    _keyStreamGamepadStickScale,
    _keyStreamGamepadFaceScale,
    _keyStreamGamepadDpadScale,
    _keyStreamGamepadSouthpaw,
    _keyStreamGamepadNintendoLayout,
    _keyStreamGamepadDeadzone,
    _keyStreamGamepadHaptics,
    _keyStreamGamepadEffects,
    _keyStreamGamepadAnimations,
    _keyStreamStatsStyle,
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
    _keyStreamPriorityEnabled,
    _keyStreamTransport,
    _keyDecoderBackend,
    _keyRendererBackend,
    _keyVideoShader,
    _keyBackgroundStyle,
    _keyUiScale,
    _keyUiScaleTouched,
    _keyUiAnimations,
    _keyLogsEnabled,
    _keyLatencyGuard,
    _keyZeroPlayoutDelay,
    _keyHideTitleBar,
    _keyMaxPerformanceMode,
    _keyOptLowLatency,
    _keyOptRecovery,
    _keyOptMinBitrate,
    _keyOptNack,
    _keyOptFec,
    _keyOptConstantQuality,
    _keyInputSensitivity,
    _keyInputAcceleration,
    _keyInputPrecision,
    _keyInputSamplingMs,
    _keyInputCursorOverlay,
    _keyInputCursorNative,
    _keyInputTouchMode,
    _keyInputTouchEnabled,
    _keyKeyboardTapToDismiss,
    _keyDebugCursorOverlayBox,
  ];
}

/// Actual decode backend the custom libwebrtc uses for the next session.
enum DecoderBackend {
  /// Hardware decode first with automatic FFmpeg fallback: GStreamer VAAPI
  /// (vah264dec) on Linux, GStreamer D3D11VA (d3d11h264dec) on Windows. This
  /// is the default custom-build behavior; the same enum value selects the
  /// platform-appropriate hardware element.
  vaapi,

  /// Force the built-in FFmpeg software decoder (the stock flutter_webrtc
  /// path) irrespective of hardware-decode availability.
  ffmpeg,
}

/// How decoded frames are pushed to the Flutter texture/engine on the
/// libwebrtc transport. A/B switch while the GPU shader renderers are landed.
enum RendererBackend {
  /// Stock path: libyuv ConvertToARGB on the CPU, upload the ARGB pixel
  /// buffer to a Flutter texture. Works everywhere.
  cpu,

  /// GPU path: upload Y/U/V planes as GPU textures and run the YUV→RGB chroma
  /// upsampling in a shader (OpenNOW-style — GL on Linux, D3D11 on Windows).
  /// The engine composites the resulting texture directly — no CPU conversion
  /// or readback.
  gl,
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

/// How aggressively the client asks the server to recover from packet loss.
/// A direct tradeoff between keeping input latency low and riding out loss.
enum StreamRecoveryProfile {
  /// Deep NACK + FEC retransmission: most resilient to loss bursts, but
  /// retransmits add jitter-buffer latency (the "input feels delayed" case).
  smooth,

  /// Middle ground between latency and resilience.
  balanced,

  /// Shallow NACK window + prefer fresh keyframes over deep retransmit:
  /// lowest latency, but more visible artifacts under sustained loss.
  latency,
}

/// Touch input mapping used on the stream surface (mobile / touchscreens).
enum TouchInputMode {
  /// Direct touch: the cursor jumps to the exact spot under the finger
  /// (absolute coordinates) and taps are clicks.
  absolute,

  /// Trackpad-style: drags move the cursor by relative deltas from the last
  /// position (like a laptop touchpad).
  relative,
}

/// Behavior of physical L3/R3 (analog-stick click) during a stream.
enum StickClickMode {
  /// Forwarded to the game as a real stick click.
  direct,

  /// Intercepted client-side: toggles the virtual gamepad overlay.
  togglePad,
}
