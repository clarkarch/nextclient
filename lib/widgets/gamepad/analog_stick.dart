import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/controller_theme.dart';

/// Callback type for analog stick drag events.
/// Returns normalized offset where x and y range from -1.0 to 1.0.
typedef AnalogStickCallback = void Function(Offset normalizedOffset);

/// Draggable analog stick using [CustomPainter].
///
/// The stick can be dragged within a circular boundary and reports normalized
/// position values (-1.0 to 1.0) for both axes. Multi-touch safe: each stick
/// latches its own pointer id. Visuals come from the active [ControllerTheme].
class AnalogStick extends StatefulWidget {
  /// Size of the analog stick base circle.
  final double size;

  /// Size of the movable stick knob.
  final double knobSize;

  /// Callback fired while the stick is dragged.
  final AnalogStickCallback? onDrag;

  /// Callback fired when the stick is released.
  final VoidCallback? onDragEnd;

  /// Active controller look.
  final ControllerTheme theme;

  /// Input dead zone as a fraction of full deflection (0.0–0.3). Movement
  /// inside the zone reports (0,0); beyond it, output is rescaled so full
  /// deflection still reaches exactly 1.0.
  final double deadZone;

  /// Whether to fire a light haptic pulse when the stick is grabbed.
  final bool hapticsEnabled;

  /// Whether grab visuals animate (false = instant snap).
  final bool animationsEnabled;

  /// Press/glow accent for this stick. Left and right sticks use different
  /// theme accents so southpaw's swap is visible.
  final Color? accentColor;

  const AnalogStick({
    super.key,
    this.size = 120.0,
    this.knobSize = 50.0,
    this.onDrag,
    this.onDragEnd,
    this.theme = ControllerThemes.neon,
    this.deadZone = 0.0,
    this.hapticsEnabled = false,
    this.animationsEnabled = true,
    this.accentColor,
  });

  @override
  State<AnalogStick> createState() => _AnalogStickState();
}

class _AnalogStickState extends State<AnalogStick>
    with SingleTickerProviderStateMixin {
  Offset _knobOffset = Offset.zero;

  // Multi-touch: track which pointer is using this stick.
  int? _activePointerId;

  late final AnimationController _grabCtrl;

  @override
  void initState() {
    super.initState();
    _grabCtrl = AnimationController(
      vsync: this,
      duration: widget.animationsEnabled
          ? const Duration(milliseconds: 110)
          : Duration.zero,
      value: 0,
    );
  }

  @override
  void didUpdateWidget(AnalogStick oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animationsEnabled != oldWidget.animationsEnabled) {
      _grabCtrl.duration = widget.animationsEnabled
          ? const Duration(milliseconds: 110)
          : Duration.zero;
    }
  }

  @override
  void dispose() {
    _grabCtrl.dispose();
    super.dispose();
  }

  double get _maxRadius => (widget.size - widget.knobSize) / 2;
  Offset get _center => Offset(widget.size / 2, widget.size / 2);

  void _handlePointerDown(PointerDownEvent event) {
    // Latch this pointer to this stick.
    if (_activePointerId != null) return;
    _activePointerId = event.pointer;
    if (widget.hapticsEnabled) HapticFeedback.lightImpact();
    _grabCtrl.forward();
    _handleTouch(event.localPosition);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointerId) return;
    _handleTouch(event.localPosition);
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointerId) return;
    _activePointerId = null;
    _handleRelease();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointerId) return;
    _activePointerId = null;
    _handleRelease();
  }

  void _handleTouch(Offset localPosition) {
    final rawOffset = localPosition - _center;
    final distance = rawOffset.distance;

    final clampedOffset = distance > _maxRadius
        ? rawOffset / distance * _maxRadius
        : rawOffset;

    // Normalized output with dead-zone rescaling: inside the zone the stick
    // reports (0,0); beyond it, values are stretched so full deflection
    // still reaches exactly 1.0.
    final magnitude = clampedOffset.distance / _maxRadius;
    final dz = widget.deadZone.clamp(0.0, 0.9);
    var normalizedX = 0.0;
    var normalizedY = 0.0;
    if (magnitude > dz) {
      final rescaled = (magnitude - dz) / (1 - dz);
      normalizedX = clampedOffset.dx / _maxRadius / magnitude * rescaled;
      normalizedY = -clampedOffset.dy / _maxRadius / magnitude * rescaled;
    }

    setState(() {
      _knobOffset = clampedOffset;
    });

    widget.onDrag?.call(Offset(normalizedX, normalizedY));
  }

  void _handleRelease() {
    setState(() {
      _knobOffset = Offset.zero;
    });
    // Input snaps home instantly above; the knob visual eases back.
    _grabCtrl.reverse();
    widget.onDrag?.call(Offset.zero);
    widget.onDragEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        // Only the CustomPaint rebuilds per animation tick — the grab
        // controller no longer setState()s the whole control.
        child: AnimatedBuilder(
          animation: _grabCtrl,
          builder: (context, _) => CustomPaint(
            painter: _AnalogStickPainter(
              theme: widget.theme,
              knobOffset: _knobOffset,
              maxRadius: _maxRadius,
              knobSize: widget.knobSize,
              grabProgress: _grabCtrl.value,
              accentColor: widget.accentColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// CustomPainter for rendering the analog stick in the active [ControllerTheme].
class _AnalogStickPainter extends CustomPainter {
  final ControllerTheme theme;
  final Offset knobOffset;
  final double maxRadius;
  final double knobSize;

  /// Animated grab amount (0..1) driving knob scale/glow.
  final double grabProgress;

  /// Per-stick accent (falls back to the theme primary).
  final Color? accentColor;

  _AnalogStickPainter({
    required this.theme,
    required this.knobOffset,
    required this.maxRadius,
    required this.knobSize,
    required this.grabProgress,
    this.accentColor,
  });

  Color get _accent => accentColor ?? theme.primary;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.width / 2;

    _drawOuterRingShadow(canvas, center, baseRadius);
    _drawBaseCircle(canvas, center, baseRadius);
    _drawInnerDepression(canvas, center, baseRadius * 0.85);
    _drawKnob(canvas, center, baseRadius);
    _drawDirectionIndicators(canvas, center, baseRadius);
  }

  void _drawOuterRingShadow(Canvas canvas, Offset center, double radius) {
    if (!theme.showShadows || theme.material == ControllerMaterial.pixel) {
      return;
    }
    canvas.drawCircle(
      center + const Offset(0, 4),
      radius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
  }

  void _drawBaseCircle(Canvas canvas, Offset center, double radius) {
    theme.paintControlCircle(canvas, center, radius);

    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _drawInnerDepression(Canvas canvas, Offset center, double radius) {
    // Concave well only makes sense on dimensional materials.
    if (!theme.showShadows ||
        (theme.material != ControllerMaterial.neumorphic &&
            theme.material != ControllerMaterial.metal)) {
      return;
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.black.withValues(alpha: 0.3), Colors.transparent],
          stops: const [0.7, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  void _drawKnob(Canvas canvas, Offset center, double baseRadius) {
    final knobCenter = center + knobOffset;
    final knobRadius = knobSize / 2;

    theme.paintControlCircle(
      canvas,
      knobCenter,
      knobRadius,
      press: grabProgress.clamp(0.0, 1.0),
      fill: _accent,
    );

    // Specular highlight arc on dimensional knobs.
    if (theme.material == ControllerMaterial.neumorphic ||
        theme.material == ControllerMaterial.metal) {
      canvas.drawArc(
        Rect.fromCircle(center: knobCenter, radius: knobRadius - 2),
        -math.pi * 0.8,
        math.pi * 0.6,
        false,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.15)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    final grab = grabProgress.clamp(0.0, 1.0);
    if (grab > 0 && theme.showShadows) {
      canvas.drawCircle(
        knobCenter,
        knobRadius + 4,
        Paint()
          ..color = _accent.withValues(alpha: 0.3 * grab)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    }
  }

  void _drawDirectionIndicators(Canvas canvas, Offset center, double radius) {
    // Ghost/pixel looks stay clean without direction dots.
    if (!theme.showShadows ||
        theme.material == ControllerMaterial.ghost ||
        theme.material == ControllerMaterial.pixel) {
      return;
    }

    const indicatorRadius = 4.0;
    final indicatorDistance = radius * 0.65;

    final paint = Paint()
      ..color = theme.inkColor.withValues(alpha: 0.22)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center + Offset(0, -indicatorDistance), indicatorRadius, paint);
    canvas.drawCircle(center + Offset(0, indicatorDistance), indicatorRadius, paint);
    canvas.drawCircle(center + Offset(-indicatorDistance, 0), indicatorRadius, paint);
    canvas.drawCircle(center + Offset(indicatorDistance, 0), indicatorRadius, paint);
  }

  @override
  bool shouldRepaint(covariant _AnalogStickPainter oldDelegate) {
    return oldDelegate.knobOffset != knobOffset ||
        oldDelegate.grabProgress != grabProgress ||
        oldDelegate.theme != theme;
  }
}
