import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:gamepads/gamepads.dart';

import 'gfn_input_protocol.dart';

/// A full gamepad snapshot in the shared XInput shape used by the stream.
///
/// [ly]/[ry] use the source convention the stream page expects (up = -1,
/// matching the Android [PhysicalGamepad] bridge); sticks carry a radial
/// deadzone; triggers are 0..1.
typedef GamepadState = ({
  int buttons,
  double lx,
  double ly,
  double rx,
  double ry,
  double lt,
  double rt,
});

/// Callback shape shared by the Android [PhysicalGamepad] and the Linux
/// [DesktopGamepad].
typedef GamepadStateCallback =
    void Function(
        int buttons,
        double lx,
        double ly,
        double rx,
        double ry,
        double lt,
        double rt);

/// Linux desktop physical gamepad (USB / Bluetooth) bridge — the counterpart of
/// [PhysicalGamepad] on Android.
///
/// Backed by the `gamepads` plugin, which on Linux reads the kernel joystick
/// devices and normalizes buttons/axes to the standard Xbox/gamepad layout via
/// the bundled SDL GameController DB keyed by vendor/product id — the same
/// standard-mapped source OpenNOW (Electron Gamepad API) uses. This avoids
/// hand-rolling evdev key-code mapping, which is hardware/kernel-ABI dependent.
///
/// A single process-wide instance fans state out over [stateStream] (with a
/// 100 ms keepalive, mirroring OpenNOW's controller-presence latching) and
/// reports connect/disconnect via [onConnectionChanged] so the UI can surface
/// it (e.g. a snackbar). Ref-counted via [start]/[stop] so the shell and the
/// stream page can share it without double-reading devices.
class DesktopGamepad {
  DesktopGamepad._();

  static DesktopGamepad? _instance;
  static DesktopGamepad get instance => _instance ??= DesktopGamepad._();

  /// Set by the app shell to surface controller connect/disconnect.
  void Function(bool connected, String name)? onConnectionChanged;

  final StreamController<GamepadState> _stateController =
      StreamController<GamepadState>.broadcast();

  /// Full gamepad state on every change and every keepalive tick.
  Stream<GamepadState> get stateStream => _stateController.stream;

  int _refs = 0;
  bool _running = false;
  StreamSubscription<NormalizedGamepadEvent>? _eventSub;
  Timer? _pollTimer;
  Timer? _keepaliveTimer;
  final Map<String, NormalizedGamepadState> _states = {};
  final Map<String, String> _names = {};

  bool get isRunning => _running;

  /// Begin tracking gamepads. Safe to call from both the shell and the stream
  /// page; the underlying listener lives until the last [stop].
  void start() {
    if (defaultTargetPlatform != TargetPlatform.linux) return;
    _refs++;
    if (_running) return;
    _running = true;
    // Single-subscription stream: subscribe once for the process lifetime and
    // gate on _running — re-subscribing after a teardown would throw.
    _eventSub ??= Gamepads.normalizedEvents.listen(_onNormalizedEvent);
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkConnections(),
    );
    _keepaliveTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _sendKeepalive(),
    );
    _checkConnections();
  }

  /// Release a reference; tears the timers down at the last [stop].
  void stop() {
    if (_refs > 0) _refs--;
    if (_refs > 0 || !_running) return;
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _states.clear();
    _names.clear();
  }

  void _onNormalizedEvent(NormalizedGamepadEvent event) {
    if (!_running) return;
    final state = _states.putIfAbsent(
      event.gamepadId,
      NormalizedGamepadState.new,
    );
    state.update(event);
    _stateController.add(mapNormalizedGamepad(state));
  }

  /// Resend the last-known state so the server keeps the controller "present"
  /// (games detect an active device by receiving packets; a silent controller
  /// gets dropped back to keyboard/mouse prompts — OpenNOW does the same).
  void _sendKeepalive() {
    for (final state in _states.values) {
      _stateController.add(mapNormalizedGamepad(state));
    }
  }

  Future<void> _checkConnections() async {
    try {
      final pads = await Gamepads.list();
      final present = {for (final p in pads) p.id: p.name};

      for (final id in [..._names.keys]) {
        if (present.containsKey(id)) continue;
        final name = _names.remove(id)!;
        _states.remove(id);
        onConnectionChanged?.call(false, name);
      }
      for (final entry in present.entries) {
        if (_names.containsKey(entry.key)) continue;
        _names[entry.key] = entry.value;
        onConnectionChanged?.call(true, entry.value);
      }
    } catch (_) {
      // Plugin not ready (no listeners yet) — retried on the next poll tick.
    }
  }
}

/// Radial stick deadzone with rescale — port of OpenNOW's `applyDeadzone`.
/// Inside the 15% circle both axes read 0; outside, the magnitude is rescaled
/// so full deflection is still reachable at the rim.
(double, double) applyRadialDeadzone(
  double x,
  double y, {
  double deadzone = gamepadDeadzone,
}) {
  final magnitude = math.sqrt(x * x + y * y);
  if (magnitude < deadzone) return (0, 0);
  final scale = ((magnitude - deadzone) / (1 - deadzone)).clamp(0.0, 1.0);
  return (x / magnitude * scale, y / magnitude * scale);
}

/// Maps a normalized (standard-layout) gamepad state onto the shared XInput
/// shape, mirroring OpenNOW's `mapGamepadButtons` + `readGamepadAxes`.
GamepadState mapNormalizedGamepad(NormalizedGamepadState s) {
  var buttons = 0;
  if (s.isPressed(GamepadButton.a)) buttons |= gamepadA;
  if (s.isPressed(GamepadButton.b)) buttons |= gamepadB;
  if (s.isPressed(GamepadButton.x)) buttons |= gamepadX;
  if (s.isPressed(GamepadButton.y)) buttons |= gamepadY;
  if (s.isPressed(GamepadButton.leftBumper)) buttons |= gamepadLb;
  if (s.isPressed(GamepadButton.rightBumper)) buttons |= gamepadRb;
  if (s.isPressed(GamepadButton.back)) buttons |= gamepadBack;
  if (s.isPressed(GamepadButton.start)) buttons |= gamepadStart;
  if (s.isPressed(GamepadButton.home)) buttons |= gamepadGuide;
  if (s.isPressed(GamepadButton.leftStick)) buttons |= gamepadLs;
  if (s.isPressed(GamepadButton.rightStick)) buttons |= gamepadRs;
  if (s.isPressed(GamepadButton.dpadUp)) buttons |= gamepadDpadUp;
  if (s.isPressed(GamepadButton.dpadDown)) buttons |= gamepadDpadDown;
  if (s.isPressed(GamepadButton.dpadLeft)) buttons |= gamepadDpadLeft;
  if (s.isPressed(GamepadButton.dpadRight)) buttons |= gamepadDpadRight;

  // Triggers: prefer the analog axis, fall back to the digital button (some
  // controllers only expose one).
  var lt = s.axisValue(GamepadAxis.leftTrigger);
  var rt = s.axisValue(GamepadAxis.rightTrigger);
  if (s.isPressed(GamepadButton.leftTrigger) && lt <= 0) lt = 1;
  if (s.isPressed(GamepadButton.rightTrigger) && rt <= 0) rt = 1;

  // Sticks: radial deadzone, then Y negated to the "up = -1" source convention
  // the stream page's _onPhysicalGamepadState expects (gamepads reports up = +1).
  final (lx, ly) = applyRadialDeadzone(
    s.axisValue(GamepadAxis.leftStickX),
    s.axisValue(GamepadAxis.leftStickY),
  );
  final (rx, ry) = applyRadialDeadzone(
    s.axisValue(GamepadAxis.rightStickX),
    s.axisValue(GamepadAxis.rightStickY),
  );

  return (
    buttons: buttons,
    lx: lx,
    ly: -ly,
    rx: rx,
    ry: -ry,
    lt: lt,
    rt: rt,
  );
}