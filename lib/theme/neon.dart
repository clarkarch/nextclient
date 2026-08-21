import 'dart:math' as math;

import 'package:flutter/material.dart';

/// App background styles selectable from the UI settings. All keep the
/// electric-blue accent (the original layered glow) — they differ in the
/// *algorithm* used to paint it: how strong the glow is, where it sits, and
/// whether it animates. [NeonBackground] renders each style.
enum BackgroundStyle {
  classic('Classic', animated: false),
  subtle('Subtle', animated: false),
  glow('Glow', animated: false),
  beams('Beams', animated: false),
  horizon('Horizon', animated: false),
  spotlight('Spotlight', animated: false),
  veil('Veil', animated: false),
  pulse('Pulse', animated: true),
  aurora('Aurora', animated: true),
  tide('Tide', animated: true);

  const BackgroundStyle(this.label, {required this.animated});

  final String label;

  /// Whether the style breathes/drifts over time.
  final bool animated;
}

/// Global holder for the user-selected background style. Pages read it via
/// [NeonPageScaffold] so a change in settings applies everywhere without
/// threading the style through every page's constructor.
class BackgroundGlow {
  BackgroundGlow._();

  /// The currently selected background style.
  static final ValueNotifier<BackgroundStyle> current =
      ValueNotifier(BackgroundStyle.beams);
}

/// The electric-blue accent used by every background style. The hue never
/// changes; only how the glow is painted does — all variants stay in the
/// blue/cyan family per request (no violet/pink).
const _electricBlue = Color(0xFF00D9FF);
const _glowTransparent = Color(0x00000000);

/// Paints the app's background layer for a [BackgroundStyle]. Static styles are
/// a single painted gradient; animated styles breathe/drift on an internal
/// repeating controller (paused when off-screen styles swap in).
class NeonBackground extends StatefulWidget {
  final BackgroundStyle style;

  const NeonBackground({super.key, required this.style});

  @override
  State<NeonBackground> createState() => _NeonBackgroundState();
}

class _NeonBackgroundState extends State<NeonBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late bool _wasAnimated;

  @override
  void initState() {
    super.initState();
    _wasAnimated = widget.style.animated;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    if (_wasAnimated) _controller.repeat();
  }

  @override
  void didUpdateWidget(NeonBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.style.animated != _wasAnimated) {
      _wasAnimated = widget.style.animated;
      if (_wasAnimated) {
        _controller.repeat();
      } else {
        _controller.stop();
        _controller.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isClassic => widget.style == BackgroundStyle.classic;

  @override
  Widget build(BuildContext context) {
    // Classic: plain single gradient, no grid/shimmer/depth — exactly the
    // original theme before the fancy pass.
    if (_isClassic) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Neon.bgA),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topLeft,
                radius: 1.4,
                colors: [Color(0x0F00D9FF), _glowTransparent],
                stops: [0, 0.5],
              ),
            ),
          ),
        ],
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Stack(
        fit: StackFit.expand,
        children: [
          // Base obsidian
          const ColoredBox(color: Neon.bgA),
          // Primary style layer
          DecoratedBox(
            decoration: BoxDecoration(gradient: _gradient(_controller.value)),
          ),
          // Fancy secondary depth layer — subtle violet/blue orbs that add
          // depth without changing hue. Only visible on richer styles.
          if (widget.style != BackgroundStyle.subtle)
            DecoratedBox(
              decoration: BoxDecoration(gradient: _depthGradient(_controller.value)),
            ),
          // Fine grid overlay — faint 24px lattice for tech texture
          const _GridOverlay(),
          // Soft vignette to frame content — keeps edges grounded
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.2,
                colors: [_glowTransparent, Color(0x6608080D)],
                stops: [0.6, 1.0],
              ),
            ),
          ),
          // Animated shimmer sweep for beams/pulse/aurora/tide — diagonal specular
          if (widget.style == BackgroundStyle.beams ||
              widget.style == BackgroundStyle.pulse ||
              widget.style == BackgroundStyle.aurora ||
              widget.style == BackgroundStyle.tide)
            _ShimmerSweep(t: _controller.value, style: widget.style),
        ],
      ),
    );
  }

  /// Builds the gradient for the given style. [t] is 0..1 and only animates
  /// the pulsing/drifting styles; static styles ignore it. Every style stays
  /// strictly electric-blue (no violet/pink) per user request.
  Gradient _gradient(double t) {
    return switch (widget.style) {
      BackgroundStyle.classic => const RadialGradient(
          center: Alignment.topLeft,
          radius: 1.4,
          colors: [Color(0x0F00D9FF), _glowTransparent],
          stops: [0, 0.5],
        ),
      BackgroundStyle.subtle => const RadialGradient(
          center: Alignment.topLeft,
          radius: 1.6,
          colors: [Color(0x1400D9FF), _glowTransparent],
          stops: [0, 0.55],
        ),
      BackgroundStyle.glow => RadialGradient(
          center: const Alignment(-0.75, -0.55),
          radius: 1.35,
          colors: [
            _electricBlue.withValues(alpha: 0.28),
            _electricBlue.withValues(alpha: 0.10),
            _glowTransparent,
          ],
          stops: const [0, 0.35, 0.72],
        ),
      BackgroundStyle.beams => LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _electricBlue.withValues(alpha: 0.18),
            _glowTransparent,
            _electricBlue.withValues(alpha: 0.09),
            _glowTransparent,
            _electricBlue.withValues(alpha: 0.07),
          ],
          stops: const [0, 0.28, 0.52, 0.76, 1],
        ),
      BackgroundStyle.horizon => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _electricBlue.withValues(alpha: 0.22),
            _electricBlue.withValues(alpha: 0.06),
            _glowTransparent,
            _electricBlue.withValues(alpha: 0.05),
          ],
          stops: const [0, 0.14, 0.32, 1],
        ),
      BackgroundStyle.spotlight => RadialGradient(
          center: const Alignment(0, -0.9),
          radius: 1.25,
          colors: [
            _electricBlue.withValues(alpha: 0.26),
            _electricBlue.withValues(alpha: 0.11),
            _glowTransparent,
          ],
          stops: const [0, 0.38, 0.78],
        ),
      BackgroundStyle.veil => LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _electricBlue.withValues(alpha: 0.10),
            _glowTransparent,
            _electricBlue.withValues(alpha: 0.04),
            _glowTransparent,
          ],
          stops: const [0, 0.38, 0.62, 1],
        ),
      BackgroundStyle.pulse => RadialGradient(
          center: const Alignment(-0.7, -0.6),
          radius: 1.35,
          colors: [
            _electricBlue.withValues(alpha: 0.14 + 0.14 * _wave(t)),
            _electricBlue.withValues(alpha: 0.06 + 0.05 * _wave(t + 0.25)),
            _glowTransparent,
          ],
          stops: const [0, 0.42, 0.75],
        ),
      BackgroundStyle.aurora => RadialGradient(
          center: Alignment(-0.85 + 0.35 * _drift(t), -0.9 + 0.28 * _drift(t + 0.5)),
          radius: 1.75,
          colors: [
            _electricBlue.withValues(alpha: 0.20),
            _electricBlue.withValues(alpha: 0.07),
            _glowTransparent,
          ],
          stops: const [0, 0.45, 1],
        ),
      BackgroundStyle.tide => RadialGradient(
          center: Alignment(-0.2 + 0.45 * _drift(t), 0.95),
          radius: 1.55,
          colors: [
            _electricBlue.withValues(alpha: 0.16 + 0.07 * _wave(t)),
            _electricBlue.withValues(alpha: 0.05),
            _glowTransparent,
          ],
          stops: const [0, 0.48, 1],
        ),
    };
  }

  Gradient _depthGradient(double t) {
    return switch (widget.style) {
      BackgroundStyle.glow => RadialGradient(
          center: const Alignment(0.9, 0.85),
          radius: 1.2,
          colors: [
            _electricBlue.withValues(alpha: 0.07),
            _glowTransparent,
          ],
          stops: const [0, 1],
        ),
      BackgroundStyle.beams => LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [
            _glowTransparent,
            _electricBlue.withValues(alpha: 0.05),
            _glowTransparent,
          ],
          stops: const [0, 0.5, 1],
        ),
      BackgroundStyle.horizon => RadialGradient(
          center: const Alignment(0, 1.05),
          radius: 1.1,
          colors: [
            _electricBlue.withValues(alpha: 0.06),
            _glowTransparent,
          ],
          stops: const [0, 1],
        ),
      BackgroundStyle.spotlight => RadialGradient(
          center: const Alignment(0.85, 0.85),
          radius: 1.0,
          colors: [
            _electricBlue.withValues(alpha: 0.05),
            _glowTransparent,
          ],
          stops: const [0, 1],
        ),
      BackgroundStyle.veil => LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [
            _glowTransparent,
            _electricBlue.withValues(alpha: 0.04),
            _glowTransparent,
          ],
          stops: const [0, 0.55, 1],
        ),
      BackgroundStyle.pulse => RadialGradient(
          center: Alignment(0.8, 0.9),
          radius: 1.1,
          colors: [
            _electricBlue.withValues(alpha: 0.06 + 0.04 * _wave(t)),
            _glowTransparent,
          ],
          stops: const [0, 1],
        ),
      BackgroundStyle.aurora => RadialGradient(
          center: Alignment(0.85 + 0.15 * _drift(t + 0.3), 0.75),
          radius: 1.4,
          colors: [
            _electricBlue.withValues(alpha: 0.07),
            _electricBlue.withValues(alpha: 0.04),
            _glowTransparent,
          ],
          stops: const [0, 0.6, 1],
        ),
      BackgroundStyle.tide => RadialGradient(
          center: Alignment(0.2 + 0.3 * _drift(t + 0.2), -0.3),
          radius: 1.3,
          colors: [
            _electricBlue.withValues(alpha: 0.05 + 0.03 * _wave(t)),
            _glowTransparent,
          ],
          stops: const [0, 1],
        ),
      _ => const RadialGradient(colors: [_glowTransparent, _glowTransparent]),
    };
  }

  /// Slow breathing wave (0..1), two cycles over the animation period.
  double _wave(double t) => 0.5 + 0.5 * math.sin(t * 2 * math.pi * 2);

  /// Slow sinusoidal drift (-1..1) for the aurora style.
  double _drift(double t) => math.sin(t * 2 * math.pi);
}

class _GridOverlay extends StatelessWidget {
  const _GridOverlay();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GridPainter(),
      size: Size.infinite,
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x0AFFFFFF)
      ..strokeWidth = 0.6
      ..style = PaintingStyle.stroke;
    const step = 28.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    // Faint horizontal glow line near top
    final glow = Paint()
      ..shader = LinearGradient(
        colors: [_electricBlue.withValues(alpha: 0.0), _electricBlue.withValues(alpha: 0.08), _glowTransparent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, 1))
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height * 0.08), Offset(size.width, size.height * 0.08), glow);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ShimmerSweep extends StatelessWidget {
  final double t;
  final BackgroundStyle style;

  const _ShimmerSweep({required this.t, required this.style});

  @override
  Widget build(BuildContext context) {
    // Slow diagonal sweep - only visible as faint specular highlight
    final offset = (t * 1.6) % 1.6 - 0.3;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(-1.0 + offset * 2, -0.6),
            end: Alignment(0.2 + offset * 2, 1.0),
            colors: [
              _glowTransparent,
              _electricBlue.withValues(alpha: style == BackgroundStyle.aurora ? 0.06 : 0.04),
              _glowTransparent,
            ],
            stops: const [0.42, 0.5, 0.58],
          ),
        ),
      ),
    );
  }
}

/// Neon Night palette — electric blue accent on layered obsidian.
class Neon {
  Neon._();

  static const bgA = Color(0xFF08080D);
  static const bgB = Color(0xFF0D0D14);
  static const bgC = Color(0xFF12121C);
  static const card = Color(0xFF12121C);
  static const cardHover = Color(0xFF181826);
  static const surfaceGlass = Color(0x0FFFFFFF);

  /// Subtle dark outline for cards, chips, and controls — a slate-blue hairline
  /// that sits naturally on the obsidian surfaces instead of a washed-out
  /// white-alpha border.
  static const outline = Color(0xFF252C3F);

  /// Fainter outline for hairline separators (dividers, bars, panel edges).
  static const outlineSoft = Color(0xFF1A2131);

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

  static const violetGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8B5CF6), Color(0xFF5B21B6)],
  );

  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF00C4F0), Color(0xFF0079A3)],
  );

  static const cardSheen = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x14FFFFFF), Color(0x00000000), Color(0x0A00D9FF)],
    stops: [0, 0.55, 1],
  );

  static const scrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xF008080D), Color(0x0008080D)],
  );

  static const scrimStrong = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xFF08080D), Color(0xCC08080D), Color(0x0008080D)],
    stops: [0, 0.45, 1],
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

  static List<BoxShadow> cardShadow({bool hover = false}) {
    if (hover) return glowShadow(radius: 26, alpha: 0.38);
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.5),
        offset: const Offset(0, 12),
        blurRadius: 28,
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.28),
        offset: const Offset(0, 4),
        blurRadius: 10,
      ),
      BoxShadow(
        color: accent.withValues(alpha: 0.06),
        offset: const Offset(0, 0),
        blurRadius: 18,
      ),
    ];
  }

  static BoxDecoration glassCard({double radius = 16, bool glow = false}) {
    return BoxDecoration(
      color: const Color(0xFF12121C).withValues(alpha: 0.84),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: const Color(0xFF252C3F).withValues(alpha: 0.9)),
      boxShadow: glow ? glowShadow(radius: 20, alpha: 0.32) : softShadow(radius: 20),
    );
  }
}

/// Fade-through-style page transition: outgoing page fades, incoming page
/// fades in while rising ~3% of its height. Applied app-wide via
/// [pageTransitionsTheme].
class _FadeRiseTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeRiseTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.03),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
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
    splashFactory: InkSparkle.splashFactory,
    // Every MaterialPageRoute gets a soft fade + tiny rise instead of the
    // platform-default horizontal slide — reads calmer on the dark theme.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _FadeRiseTransitionsBuilder(),
        TargetPlatform.iOS: _FadeRiseTransitionsBuilder(),
        TargetPlatform.linux: _FadeRiseTransitionsBuilder(),
        TargetPlatform.macOS: _FadeRiseTransitionsBuilder(),
        TargetPlatform.windows: _FadeRiseTransitionsBuilder(),
      },
    ),
    splashColor: Neon.accent.withValues(alpha: 0.12),
    highlightColor: Neon.accent.withValues(alpha: 0.06),
    hoverColor: Neon.accent.withValues(alpha: 0.04),
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
      color: Neon.outlineSoft,
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
