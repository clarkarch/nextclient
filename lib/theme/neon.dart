import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// App background styles selectable from the UI settings. All keep the
/// electric-blue accent (the original layered glow) — they differ in the
/// *algorithm* used to paint it: how strong the glow is, where it sits, and
/// whether it animates. [NeonBackground] renders each style.
enum BackgroundStyle {
  none('None', animated: false),
  classic('Classic', animated: false),
  subtle('Subtle', animated: false),
  glow('Glow', animated: false),
  beams('Beams', animated: false),
  horizon('Horizon', animated: false),
  spotlight('Spotlight', animated: false),
  veil('Veil', animated: false),
  pulse('Pulse', animated: true),
  aurora('Aurora', animated: true),
  tide('Tide', animated: true),
  starfield('Starfield', animated: false),
  nebula('Nebula', animated: false),
  circuit('Circuit', animated: false),
  hexgrid('Hexgrid', animated: false),
  contours('Contours', animated: false),
  prism('Prism', animated: false);

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
  static final ValueNotifier<BackgroundStyle> current = ValueNotifier(
    BackgroundStyle.beams,
  );
}

/// Global master switch for decorative UI motion (entrance fades, staggered
/// cards, animated backgrounds, carousel auto-advance). Synced from
/// [UserSettings.uiAnimations]; widgets read the notifier so the toggle
/// applies live without rebuilding the whole app.
class UiMotion {
  UiMotion._();

  static final ValueNotifier<bool> enabled = ValueNotifier(true);
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
  bool _animating = false;
  ui.Image? _snapshot;
  Size _snapshotSize = Size.zero;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    UiMotion.enabled.addListener(_syncAnimation);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(NeonBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style) {
      _invalidateSnapshot();
    }
    _syncAnimation();
    _refreshSnapshot();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshSnapshot();
  }

  @override
  void dispose() {
    UiMotion.enabled.removeListener(_syncAnimation);
    _controller.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    final shouldAnimate = widget.style.animated && UiMotion.enabled.value;
    if (shouldAnimate == _animating) return;
    _animating = shouldAnimate;
    if (shouldAnimate) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
    _refreshSnapshot();
  }

  void _invalidateSnapshot() {
    _generation++;
    _snapshot?.dispose();
    _snapshot = null;
    _snapshotSize = Size.zero;
  }

  /// Rasterizes the background once into a plain GPU texture. A texture is
  /// composited every frame by the engine with no scene-graph work at all —
  /// immune to raster-cache heuristics, repaint-region walks, and driver
  /// quirks. This is the cheapest thing a background can possibly be.
  void _refreshSnapshot() {
    if (_animating || !mounted) return;
    final mq = MediaQuery.of(context);
    final dpr = math.min(mq.devicePixelRatio, 2.0);
    final px = Size(
      (mq.size.width * dpr).roundToDouble(),
      (mq.size.height * dpr).roundToDouble(),
    );
    if (_snapshot != null && px == _snapshotSize) return;
    _renderSnapshot(px, dpr);
  }

  Future<void> _renderSnapshot(Size px, double dpr) async {
    final gen = ++_generation;
    final style = widget.style;
    final image = await _paintBackground(px, dpr, style);
    if (!mounted || gen != _generation) {
      image.dispose();
      return;
    }
    setState(() {
      _snapshot?.dispose();
      _snapshot = image;
      _snapshotSize = px;
    });
  }

  Future<ui.Image> _paintBackground(
    Size px,
    double dpr,
    BackgroundStyle style,
  ) async {
    final rect = Offset.zero & px;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, rect);
    canvas.drawRect(rect, Paint()..color = Neon.bgA);
    canvas.drawRect(rect, Paint()..shader = _gradient(0).createShader(rect));
    if (style != BackgroundStyle.classic &&
        style != BackgroundStyle.subtle &&
        style != BackgroundStyle.none) {
      canvas.drawRect(
        rect,
        Paint()..shader = _depthGradient(0).createShader(rect),
      );
    }
    if (style == BackgroundStyle.beams ||
        style == BackgroundStyle.pulse ||
        style == BackgroundStyle.aurora ||
        style == BackgroundStyle.tide) {
      const offset = -0.3; // shimmer position at t = 0
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment(-1.0 + offset * 2, -0.6),
            end: Alignment(0.2 + offset * 2, 1.0),
            colors: [
              _glowTransparent,
              _electricBlue.withValues(
                alpha: style == BackgroundStyle.aurora ? 0.06 : 0.04,
              ),
              _glowTransparent,
            ],
            stops: const [0.42, 0.5, 0.58],
          ).createShader(rect),
      );
    }
    _paintStyleDecoration(canvas, px, dpr, style);
    if (style != BackgroundStyle.classic) {
      final gridPaint = Paint()
        ..color = const Color(0x0AFFFFFF)
        ..strokeWidth = 0.6 * dpr
        ..style = ui.PaintingStyle.stroke;
      final step = 28.0 * dpr;
      for (double x = 0; x <= px.width; x += step) {
        canvas.drawLine(Offset(x, 0), Offset(x, px.height), gridPaint);
      }
      for (double y = 0; y <= px.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(px.width, y), gridPaint);
      }
      final glowLine = Paint()
        ..strokeWidth = dpr
        ..shader = LinearGradient(
          colors: [
            _electricBlue.withValues(alpha: 0.0),
            _electricBlue.withValues(alpha: 0.08),
            _glowTransparent,
          ],
        ).createShader(Rect.fromLTWH(0, 0, px.width, dpr));
      canvas.drawLine(
        Offset(0, px.height * 0.08),
        Offset(px.width, px.height * 0.08),
        glowLine,
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(px.width.round(), px.height.round());
    picture.dispose();
    return image;
  }

  void _paintStyleDecoration(
    Canvas canvas,
    Size px,
    double dpr,
    BackgroundStyle style,
  ) {
    switch (style) {
      case BackgroundStyle.starfield:
        _paintStarfield(canvas, px, dpr);
      case BackgroundStyle.nebula:
        _paintNebula(canvas, px, dpr);
      case BackgroundStyle.circuit:
        _paintCircuit(canvas, px, dpr);
      case BackgroundStyle.hexgrid:
        _paintHexgrid(canvas, px, dpr);
      case BackgroundStyle.contours:
        _paintContours(canvas, px, dpr);
      case BackgroundStyle.prism:
        _paintPrism(canvas, px, dpr);
      default:
        break;
    }
  }

  void _paintStarfield(Canvas canvas, Size px, double dpr) {
    final rng = math.Random(1337);
    for (final c in const [Offset(0.22, 0.3), Offset(0.78, 0.72)]) {
      final center = Offset(px.width * c.dx, px.height * c.dy);
      final radius = math.min(px.width, px.height) * 0.45;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [_electricBlue.withValues(alpha: 0.07), _glowTransparent],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    final count = (px.width * px.height / (9000 * dpr * dpr)).round().clamp(
      120,
      320,
    );
    for (var i = 0; i < count; i++) {
      final x = rng.nextDouble() * px.width;
      final y = rng.nextDouble() * px.height;
      final r = (0.5 + rng.nextDouble() * 1.4) * dpr;
      final isAccent = rng.nextDouble() < 0.12;
      final alpha = 0.12 + rng.nextDouble() * 0.55;
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()
          ..color = isAccent
              ? _electricBlue.withValues(alpha: alpha)
              : Colors.white.withValues(alpha: alpha),
      );
    }
  }

  void _paintNebula(Canvas canvas, Size px, double dpr) {
    final rng = math.Random(4242);
    final paint = Paint()..blendMode = ui.BlendMode.plus;
    for (var i = 0; i < 9; i++) {
      final center = Offset(
        rng.nextDouble() * px.width,
        rng.nextDouble() * px.height,
      );
      final radius =
          math.min(px.width, px.height) * (0.18 + rng.nextDouble() * 0.30);
      paint.shader = RadialGradient(
        colors: [
          _electricBlue.withValues(alpha: 0.05 + rng.nextDouble() * 0.07),
          _glowTransparent,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }
  }

  void _paintCircuit(Canvas canvas, Size px, double dpr) {
    final rng = math.Random(9001);
    final step = 28.0 * dpr;
    final tracePaint = Paint()
      ..color = _electricBlue.withValues(alpha: 0.16)
      ..strokeWidth = 1.2 * dpr
      ..style = ui.PaintingStyle.stroke;
    final nodePaint = Paint()..color = _electricBlue.withValues(alpha: 0.38);
    final cols = px.width ~/ step;
    final rows = px.height ~/ step;
    for (var t = 0; t < 16; t++) {
      var x = rng.nextInt(cols + 1) * step;
      var y = rng.nextInt(rows + 1) * step;
      final path = ui.Path()..moveTo(x, y);
      final segments = 2 + rng.nextInt(4);
      for (var s = 0; s < segments; s++) {
        final horizontal = rng.nextBool();
        final dir = rng.nextBool() ? 1 : -1;
        final len = step * (1 + rng.nextInt(3));
        if (horizontal) {
          x = (x + dir * len).clamp(0.0, px.width).toDouble();
        } else {
          y = (y + dir * len).clamp(0.0, px.height).toDouble();
        }
        path.lineTo(x, y);
      }
      canvas.drawPath(path, tracePaint);
      canvas.drawCircle(Offset(x, y), 2.6 * dpr, nodePaint);
    }
  }

  void _paintHexgrid(Canvas canvas, Size px, double dpr) {
    final r = 30.0 * dpr;
    final h = r * math.sqrt(3) / 2;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 0.8 * dpr
      ..style = ui.PaintingStyle.stroke;
    Offset vertex(Offset center, int i) {
      final angle = math.pi / 3 * i;
      return center + Offset(r * math.cos(angle), r * math.sin(angle));
    }

    for (var row = 0; row * h * 2 < px.height + r * 2; row++) {
      for (var col = 0; col * r * 3 < px.width + r * 2; col++) {
        final cx = col * r * 3 + (row.isOdd ? r * 1.5 : 0.0);
        final center = Offset(cx, row * h * 2);
        final path = ui.Path();
        for (var i = 0; i <= 6; i++) {
          final v = vertex(center, i % 6);
          if (i == 0) {
            path.moveTo(v.dx, v.dy);
          } else {
            path.lineTo(v.dx, v.dy);
          }
        }
        canvas.drawPath(path, paint);
      }
    }
  }

  void _paintContours(Canvas canvas, Size px, double dpr) {
    final paint = Paint()
      ..color = _electricBlue.withValues(alpha: 0.10)
      ..strokeWidth = 1.0 * dpr
      ..style = ui.PaintingStyle.stroke;
    final centers = [
      Offset(px.width * 0.25, px.height * 0.3),
      Offset(px.width * 0.75, px.height * 0.75),
    ];
    for (final center in centers) {
      for (var ring = 1; ring <= 11; ring++) {
        final baseR = ring * 34.0 * dpr;
        final path = ui.Path();
        const segs = 72;
        for (var s = 0; s <= segs; s++) {
          final ang = s / segs * 2 * math.pi;
          final wob =
              1.0 +
              0.10 * math.sin(ang * 3 + ring * 0.9) +
              0.06 * math.sin(ang * 5 - ring * 0.5);
          final r = baseR * wob;
          final p = Offset(
            center.dx + r * math.cos(ang),
            center.dy + r * math.sin(ang) * 0.85,
          );
          if (s == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        canvas.drawPath(path, paint);
      }
    }
  }

  void _paintPrism(Canvas canvas, Size px, double dpr) {
    final rect = Offset.zero & px;
    final origin = Offset.zero;
    final reach = math.max(px.width, px.height) * 1.6;
    final edgePaint = Paint()
      ..color = _electricBlue.withValues(alpha: 0.25)
      ..strokeWidth = 1.0 * dpr;
    final rng = math.Random(777);
    var angle = 0.55;
    for (var b = 0; b < 8; b++) {
      final a1 = angle + rng.nextDouble() * 0.02;
      final a2 = a1 + 0.035 + rng.nextDouble() * 0.05;
      angle = a2;
      final p1 = origin + Offset(math.cos(a1), math.sin(a1)) * reach;
      final p2 = origin + Offset(math.cos(a2), math.sin(a2)) * reach;
      final path = ui.Path()
        ..moveTo(origin.dx, origin.dy)
        ..lineTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              _electricBlue.withValues(alpha: 0.10 - b * 0.008),
              _glowTransparent,
            ],
          ).createShader(rect),
      );
      canvas.drawLine(origin, p1, edgePaint);
    }
  }

  @override
  Widget build(BuildContext context) {
    // None: zero background work — the scaffold's opaque base color shows
    // through.
    if (widget.style == BackgroundStyle.none) {
      return const SizedBox.expand();
    }
    if (_animating) {
      return RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: _gradient(_controller.value),
                ),
              ),
              if (widget.style != BackgroundStyle.subtle)
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: _depthGradient(_controller.value),
                  ),
                ),
              if (widget.style == BackgroundStyle.pulse ||
                  widget.style == BackgroundStyle.aurora ||
                  widget.style == BackgroundStyle.tide)
                _ShimmerSweep(t: _controller.value, style: widget.style),
            ],
          ),
        ),
      );
    }
    final snapshot = _snapshot;
    if (snapshot != null) {
      return RepaintBoundary(
        child: SizedBox.expand(
          child: RawImage(image: snapshot, fit: BoxFit.fill),
        ),
      );
    }
    // First frames before the texture is ready: flat obsidian.
    return const SizedBox.expand();
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
      BackgroundStyle.none => const RadialGradient(
        colors: [_glowTransparent, _glowTransparent],
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
        center: Alignment(
          -0.85 + 0.35 * _drift(t),
          -0.9 + 0.28 * _drift(t + 0.5),
        ),
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
      BackgroundStyle.starfield ||
      BackgroundStyle.hexgrid => const RadialGradient(
        center: Alignment.topLeft,
        radius: 1.6,
        colors: [Color(0x1400D9FF), _glowTransparent],
        stops: [0, 0.55],
      ),
      BackgroundStyle.nebula => RadialGradient(
        center: const Alignment(-0.6, -0.4),
        radius: 1.35,
        colors: [
          _electricBlue.withValues(alpha: 0.24),
          _electricBlue.withValues(alpha: 0.10),
          _glowTransparent,
        ],
        stops: const [0, 0.38, 0.75],
      ),
      BackgroundStyle.circuit => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          _electricBlue.withValues(alpha: 0.16),
          _glowTransparent,
          _electricBlue.withValues(alpha: 0.07),
        ],
        stops: const [0, 0.45, 1],
      ),
      BackgroundStyle.contours => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          _electricBlue.withValues(alpha: 0.18),
          _glowTransparent,
          _electricBlue.withValues(alpha: 0.05),
        ],
        stops: const [0, 0.4, 1],
      ),
      BackgroundStyle.prism => RadialGradient(
        center: const Alignment(-0.9, -0.9),
        radius: 1.5,
        colors: [
          _electricBlue.withValues(alpha: 0.26),
          _electricBlue.withValues(alpha: 0.08),
          _glowTransparent,
        ],
        stops: const [0, 0.4, 0.85],
      ),
    };
  }

  Gradient _depthGradient(double t) {
    return switch (widget.style) {
      BackgroundStyle.glow => RadialGradient(
        center: const Alignment(0.9, 0.85),
        radius: 1.2,
        colors: [_electricBlue.withValues(alpha: 0.07), _glowTransparent],
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
        colors: [_electricBlue.withValues(alpha: 0.06), _glowTransparent],
        stops: const [0, 1],
      ),
      BackgroundStyle.spotlight => RadialGradient(
        center: const Alignment(0.85, 0.85),
        radius: 1.0,
        colors: [_electricBlue.withValues(alpha: 0.05), _glowTransparent],
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
              _electricBlue.withValues(
                alpha: style == BackgroundStyle.aurora ? 0.06 : 0.04,
              ),
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

  /// Bumped from #5C6B85 for WCAG AA contrast (~5.5:1) on obsidian.
  static const inkMuted = Color(0xFF6E80A0);

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
  static List<BoxShadow> glowShadow({double radius = 18, double alpha = 0.35}) {
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
      boxShadow: glow
          ? glowShadow(radius: 20, alpha: 0.32)
          : softShadow(radius: 20),
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
    splashColor: Neon.accent.withValues(alpha: 0.12),
    highlightColor: Neon.accent.withValues(alpha: 0.06),
    hoverColor: Neon.accent.withValues(alpha: 0.04),
    textTheme: base.textTheme
        .apply(bodyColor: Neon.ink, displayColor: Neon.ink)
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
          bodySmall: const TextStyle(color: Neon.inkMuted, fontSize: 12),
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
        (states) =>
            states.contains(WidgetState.selected) ? Neon.bgA : Neon.inkMuted,
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
      trackColor: WidgetStateProperty.resolveWith((_) => Colors.transparent),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(5),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Neon.accent,
      linearTrackColor: Color(0x22FFFFFF),
    ),
  );
}
