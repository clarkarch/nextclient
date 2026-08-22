import 'package:flutter/services.dart';

/// Gamepad haptics via the Android Vibrator service directly.
///
/// Flutter's `HapticFeedback.*` goes through
/// `View.performHapticFeedback()`, which silently no-ops when the system's
/// touch-feedback setting is off — users with "touch feedback: off" got no
/// buzz at all. A one-shot on the Vibrator ignores that setting.
const MethodChannel _perfChannel = MethodChannel('next_client/perf');

void gamepadHaptic() {
  try {
    _perfChannel.invokeMethod('haptic');
  } catch (_) {
    // Channel missing (non-Android) — silent.
  }
}
