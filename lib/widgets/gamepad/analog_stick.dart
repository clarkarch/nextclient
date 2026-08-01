import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../theme/neon.dart';

/// Callback type for analog stick drag events.
/// Returns normalized offset where x and y range from -1.0 to 1.0.
typedef AnalogStickCallback = void Function(Offset normalizedOffset);

/// Draggable analog stick using [CustomPainter].
///
/// The stick can be dragged within a circular boundary and reports normalized
/// position values (-1.0 to 1.0) for both axes. Multi-touch safe: each stick
/// latches its own pointer id.
class AnalogStick extends StatefulWidget {
  /// Size of the analog stick base circle.
  final double size;

  /// Size of the movable stick knob.
  final double knobSize;

  /// Callback fired while the stick is dragged.
  final AnalogStickCallback? onDrag;

  /// Callback fired when the stick is released.
  final VoidCallback? onDragEnd;

  /// Color of the stick base.
  final Color baseColor;

  /// Color of the stick knob.
  final Color knobColor;

  /// Primary glow color for active state.
  final Color glowColor;

  const AnalogStick({
    super.key,
    this.size = 120.0,
    this.knobSize = 50.0,
    this.onDrag,
    this.onDragEnd,
    this.baseColor = const Color(0xFF14141F),
    this.knobColor = const Color(0xFF2A2A3E),
    this.glowColor = Neon.accent,
  });

  @override
  State<AnalogStick> createState() => _AnalogStickState();
}

class _AnalogStickState extends State<AnalogStick> {
  Offset _knobOffset = Offset.zero;
  bool _isDragging = false;

  // Multi-touch: track which pointer is using this stick.
  int? _activePointerId;

  double get _maxRadius => (widget.size - widget.knobSize) / 2;
  Offset get _center => Offset(widget.size / 2, widget.size / 2);

  void _handlePointerDown(PointerDownEvent event) {
    // Latch this pointer to this stick.
    if (_activePointerId != null) return;
    _activePointerId = event.pointer;
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

    setState(() {
      _knobOffset = clampedOffset;
      _isDragging = distance > (_maxRadius * 0.1); // 10% dead zone
    });

    final normalizedX = clampedOffset.dx / _maxRadius;
    final normalizedY = -clampedOffset.dy / _maxRadius; // Invert Y for game coords

    widget.onDrag?.call(Offset(normalizedX, normalizedY));
  }

  void _handleRelease() {
    setState(() {
      _knobOffset = Offset.zero;
      _isDragging = false;
    });
    // Immediately send (0,0) — no animation delay for logical output.
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
        child: CustomPaint(
          painter: _AnalogStickPainter(
            knobOffset: _knobOffset,
            maxRadius: _maxRadius,
            knobSize: widget.knobSize,
            isDragging: _isDragging,
            baseColor: widget.baseColor,
            knobColor: widget.knobColor,
            glowColor: widget.glowColor,
          ),
        ),
      ),
    );
  }
}

/// CustomPainter for rendering the analog stick with neumorphic shadows.
class _AnalogStickPainter extends CustomPainter {
  final Offset knobOffset;
  final double maxRadius;
  final double knobSize;
  final bool isDragging;
  final Color baseColor;
  final Color knobColor;
  final Color glowColor;

  _AnalogStickPainter({
    required this.knobOffset,
    required this.maxRadius,
    required this.knobSize,
    required this.isDragging,
    required this.baseColor,
    required this.knobColor,
    required this.glowColor,
  });

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
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);

    canvas.drawCircle(center + const Offset(0, 4), radius, shadowPaint);
  }

  void _drawBaseCircle(Canvas canvas, Offset center, double radius) {
    final basePaint = Paint()
      ..shader = RadialGradient(
        colors: [baseColor, baseColor.withValues(alpha: 0.8)],
        stops: const [0.3, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawCircle(center, radius, basePaint);

    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawCircle(center, radius - 1, borderPaint);
  }

  void _drawInnerDepression(Canvas canvas, Offset center, double radius) {
    final innerShadowPaint = Paint()
      ..shader = RadialGradient(
        colors: [Colors.black.withValues(alpha: 0.3), Colors.transparent],
        stops: const [0.7, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawCircle(center, radius, innerShadowPaint);
  }

  void _drawKnob(Canvas canvas, Offset center, double baseRadius) {
    final knobCenter = center + knobOffset;
    final knobRadius = knobSize / 2;

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: isDragging ? 0.6 : 0.4)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isDragging ? 8 : 4);

    canvas.drawCircle(knobCenter + const Offset(0, 2), knobRadius, shadowPaint);

    final knobPaint = Paint()
      ..shader = RadialGradient(
        colors: [knobColor, knobColor.withValues(alpha: 0.7)],
        center: const Alignment(-0.3, -0.3),
        radius: 1.2,
      ).createShader(Rect.fromCircle(center: knobCenter, radius: knobRadius));

    canvas.drawCircle(knobCenter, knobRadius, knobPaint);

    final highlightPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawArc(
      Rect.fromCircle(center: knobCenter, radius: knobRadius - 2),
      -math.pi * 0.8,
      math.pi * 0.6,
      false,
      highlightPaint,
    );

    if (isDragging) {
      final glowPaint = Paint()
        ..color = glowColor.withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);

      canvas.drawCircle(knobCenter, knobRadius + 4, glowPaint);
    }
  }

  void _drawDirectionIndicators(Canvas canvas, Offset center, double radius) {
    final indicatorRadius = 4.0;
    final indicatorDistance = radius * 0.65;

    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center + Offset(0, -indicatorDistance), indicatorRadius, paint);
    canvas.drawCircle(center + Offset(0, indicatorDistance), indicatorRadius, paint);
    canvas.drawCircle(center + Offset(-indicatorDistance, 0), indicatorRadius, paint);
    canvas.drawCircle(center + Offset(indicatorDistance, 0), indicatorRadius, paint);
  }

  @override
  bool shouldRepaint(covariant _AnalogStickPainter oldDelegate) {
    return oldDelegate.knobOffset != knobOffset ||
        oldDelegate.isDragging != isDragging;
  }
}
