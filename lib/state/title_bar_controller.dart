import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../state/user_settings.dart';

/// Applies the "Hide title bar" UI setting to the native window.
///
/// Only effective on desktop platforms the window_manager plugin supports
/// (Linux, macOS, Windows); everywhere else this is a no-op.
class TitleBarController {
  TitleBarController._();

  /// Whether this platform can hide the OS title bar.
  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  /// Applies [settings.hideTitleBar] to the current window.
  static Future<void> apply(UserSettings settings) async {
    if (!isSupported) return;
    await windowManager.setTitleBarStyle(
      settings.hideTitleBar
          ? TitleBarStyle.hidden
          : TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
  }

  /// Hides or shows the OS title bar immediately.
  static Future<void> setHidden(bool hidden) async {
    if (!isSupported) return;
    await windowManager.setTitleBarStyle(
      hidden ? TitleBarStyle.hidden : TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
  }
}
