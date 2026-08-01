import 'package:flutter/material.dart';

/// Neon Night palette — electric blue accent on layered obsidian.
class Neon {
  Neon._();

  static const bgA = Color(0xFF08080D);
  static const bgB = Color(0xFF0D0D14);
  static const bgC = Color(0xFF12121C);
  static const card = Color(0xFF12121C);
  static const cardHover = Color(0xFF181826);
  static const surfaceGlass = Color(0x66FFFFFF);

  static const ink = Color(0xFFF2F7FF);
  static const inkSoft = Color(0xFF9FB0C9);
  static const inkMuted = Color(0xFF5C6B85);

  static const accent = Color(0xFF00D9FF);
  static const accentDim = Color(0xFF0A8FA8);
  static const violet = Color(0xFF8B5CF6);
  static const success = Color(0xFF34D399);
  static const warning = Color(0xFFFBBF24);
  static const error = Color(0xFFF87171);

  static const accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF00E5FF), Color(0xFF00A8CC)],
  );

  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF00C4F0), Color(0xFF0079A3)],
  );

  static const scrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xF008080D), Color(0x0008080D)],
  );

  /// Layered soft shadow used by cards/panels.
  static List<BoxShadow> softShadow({double radius = 24, Color? color}) {
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.45),
        offset: const Offset(0, 10),
        blurRadius: radius,
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.25),
        offset: const Offset(0, 3),
        blurRadius: 8,
      ),
    ];
  }

  /// Electric blue glow shadow for interactive/active elements.
  static List<BoxShadow> glowShadow({
    double radius = 18,
    double alpha = 0.35,
  }) {
    return [
      ...softShadow(),
      BoxShadow(
        color: accent.withValues(alpha: alpha),
        offset: const Offset(0, 0),
        blurRadius: radius,
        spreadRadius: 1,
      ),
    ];
  }
}

ThemeData buildNeonTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Neon.accent,
    onPrimary: Neon.bgA,
    secondary: Neon.violet,
    onSecondary: Colors.white,
    error: Neon.error,
    onError: Neon.bgA,
    surface: Neon.bgB,
    onSurface: Neon.ink,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: Neon.bgA,
  );

  const label = TextStyle(
    color: Neon.ink,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
  );

  return base.copyWith(
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    textTheme: base.textTheme
        .apply(
          bodyColor: Neon.ink,
          displayColor: Neon.ink,
        )
        .copyWith(
          headlineLarge: const TextStyle(
            color: Neon.ink,
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
          headlineMedium: const TextStyle(
            color: Neon.ink,
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
          titleLarge: const TextStyle(
            color: Neon.ink,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
          titleMedium: const TextStyle(
            color: Neon.ink,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
          bodyMedium: const TextStyle(
            color: Neon.inkSoft,
            fontSize: 13.5,
            height: 1.45,
          ),
          bodySmall: const TextStyle(
            color: Neon.inkMuted,
            fontSize: 12,
          ),
          labelLarge: label,
          labelMedium: const TextStyle(
            color: Neon.inkSoft,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
    cardTheme: const CardThemeData(
      color: Neon.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Neon.bgB,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Neon.bgC,
      contentTextStyle: TextStyle(color: Neon.ink, fontSize: 13.5),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0x22FFFFFF),
      thickness: 1,
      space: 1,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: Neon.accent,
      inactiveTrackColor: const Color(0x33FFFFFF),
      thumbColor: Neon.accent,
      overlayColor: Neon.accent.withValues(alpha: 0.12),
      trackHeight: 4,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Neon.bgA
            : Neon.inkMuted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Neon.accent
            : const Color(0x33FFFFFF),
      ),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: Neon.bgC,
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(color: Neon.ink, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (_) => Neon.accent.withValues(alpha: 0.4),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (_) => Colors.transparent,
      ),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(5),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Neon.accent,
      linearTrackColor: Color(0x22FFFFFF),
    ),
  );
}
