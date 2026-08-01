import 'package:flutter/material.dart';

import '../../theme/neon.dart';

/// Direction enum for D-pad inputs.
enum DPadDirection { up, down, left, right, none }

/// Callback type for D-pad direction events.
typedef DPadCallback = void Function(DPadDirection direction);

/// D-Pad widget using [CustomPainter].
///
/// Detects tap directions (up/down/left/right) and provides visual feedback
/// for pressed states. Multi-touch safe via pointer-id latching.
class DPadWidget extends StatefulWidget {
  /// Size of the D-pad.
  final double size;

  /// Callback when a direction is pressed.
  final DPadCallback? onDirectionPressed;

  /// Callback when a direction is released.
  final VoidCallback? onDirectionReleased;

  /// Base color of the D-pad.
  final Color baseColor;

  /// Button color when pressed.
  final Color buttonColor;

  /// Glow color for pressed state.
  final Color glowColor;

  const DPadWidget({
    super.key,
    this.size = 140.0,
    this.onDirectionPressed,
    this.onDirectionReleased,
    this.baseColor = const Color(0xFF10101A),
    this.buttonColor = const Color(0xFF2A2A3E),
    this.glowColor = Neon.accent,
  });

  @override
  State<DPadWidget> createState() => _DPadWidgetState();
}

class _DPadWidgetState extends State<DPadWidget> {
  DPadDirection _pressedDirection = DPadDirection.none;
  int? _activePointerId;

  Offset get _center => Offset(widget.size / 2, widget.size / 2);

  DPadDirection _getDirectionFromPosition(Offset localPosition) {
    final diff = localPosition - _center;

    final deadZone = widget.size * 0.12;
    if (diff.distance < deadZone) return DPadDirection.none;

    if (diff.dy.abs() > diff.dx.abs()) {
      return diff.dy < 0 ? DPadDirection.up : DPadDirection.down;
    } else {
      return diff.dx < 0 ? DPadDirection.left : DPadDirection.right;
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_activePointerId != null) return;
    _activePointerId = event.pointer;

    final direction = _getDirectionFromPosition(event.localPosition);
    if (direction != DPadDirection.none) {
      setState(() => _pressedDirection = direction);
      widget.onDirectionPressed?.call(direction);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointerId) return;
    _activePointerId = null;

    if (_pressedDirection != DPadDirection.none) {
      widget.onDirectionReleased?.call();
      setState(() => _pressedDirection = DPadDirection.none);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointerId) return;
    _activePointerId = null;

    if (_pressedDirection != DPadDirection.none) {
      widget.onDirectionReleased?.call();
      setState(() => _pressedDirection = DPadDirection.none);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: CustomPaint(
          painter: _DPadPainter(
            pressedDirection: _pressedDirection,
            baseColor: widget.baseColor,
            buttonColor: widget.buttonColor,
            glowColor: widget.glowColor,
          ),
        ),
      ),
    );
  }
}

/// CustomPainter for rendering the D-pad with neumorphic shadows.
class _DPadPainter extends CustomPainter {
  final DPadDirection pressedDirection;
  final Color baseColor;
  final Color buttonColor;
  final Color glowColor;

  _DPadPainter({
    required this.pressedDirection,
    required this.baseColor,
    required this.buttonColor,
    required this.glowColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final armWidth = size.width * 0.3;
    final buttonSize = armWidth;
    final armLength = armWidth * 1.25;
    final cornerRadius = armWidth * 0.15;

    _drawDirectionalButtons(
      canvas,
      center,
      armLength,
      armWidth,
      buttonSize,
      cornerRadius,
    );
  }

  void _drawDirectionalButtons(
    Canvas canvas,
    Offset center,
    double armLength,
    double armWidth,
    double buttonSize,
    double cornerRadius,
  ) {
    final directions = [
      (DPadDirection.up, Offset(0, -armLength * 0.9)),
      (DPadDirection.down, Offset(0, armLength * 0.9)),
      (DPadDirection.left, Offset(-armLength * 0.9, 0)),
      (DPadDirection.right, Offset(armLength * 0.9, 0)),
    ];

    for (final (direction, offset) in directions) {
      final buttonCenter = center + offset;
      final isPressed = pressedDirection == direction;

      _drawButton(
        canvas,
        buttonCenter,
        buttonSize,
        cornerRadius * 0.8,
        direction,
        isPressed,
      );
    }
  }

  void _drawButton(
    Canvas canvas,
    Offset center,
    double size,
    double cornerRadius,
    DPadDirection direction,
    bool isPressed,
  ) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: size, height: size),
      Radius.circular(cornerRadius),
    );

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: isPressed ? 0.6 : 0.35)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isPressed ? 6 : 3);

    canvas.drawRRect(rect.shift(const Offset(0, 2)), shadowPaint);

    final buttonPaint = Paint()
      ..shader = LinearGradient(
        begin: const Alignment(-0.3, -0.3),
        end: const Alignment(0.3, 0.3),
        colors: isPressed
            ? [buttonColor.withValues(alpha: 0.9), buttonColor]
            : [buttonColor, buttonColor.withValues(alpha: 0.7)],
      ).createShader(rect.outerRect);

    canvas.drawRRect(rect, buttonPaint);

    if (!isPressed) {
      final highlightPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect.outerRect.deflate(1),
          Radius.circular(cornerRadius),
        ),
        highlightPaint,
      );
    }

    if (isPressed) {
      final glowPaint = Paint()
        ..color = glowColor.withValues(alpha: 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);

      canvas.drawRRect(rect, glowPaint);
    }

    _drawArrowIndicator(canvas, center, direction, isPressed, size);
  }

  void _drawArrowIndicator(
    Canvas canvas,
    Offset center,
    DPadDirection direction,
    bool isPressed,
    double buttonSize,
  ) {
    final arrowSize = 8.0 * (buttonSize / 48.0);

    final arrowPaint = Paint()
      ..color = isPressed ? glowColor : glowColor.withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;

    if (!isPressed) {
      final glowPaint = Paint()
        ..color = glowColor.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      _drawArrowPath(canvas, center, direction, arrowSize, glowPaint);
    }

    _drawArrowPath(canvas, center, direction, arrowSize, arrowPaint);
  }

  void _drawArrowPath(
    Canvas canvas,
    Offset center,
    DPadDirection direction,
    double arrowSize,
    Paint paint,
  ) {
    Path arrowPath;
    switch (direction) {
      case DPadDirection.up:
        arrowPath = Path()
          ..moveTo(center.dx, center.dy - arrowSize)
          ..lineTo(center.dx - arrowSize * 0.7, center.dy + arrowSize * 0.3)
          ..lineTo(center.dx + arrowSize * 0.7, center.dy + arrowSize * 0.3)
          ..close();
      case DPadDirection.down:
        arrowPath = Path()
          ..moveTo(center.dx, center.dy + arrowSize)
          ..lineTo(center.dx - arrowSize * 0.7, center.dy - arrowSize * 0.3)
          ..lineTo(center.dx + arrowSize * 0.7, center.dy - arrowSize * 0.3)
          ..close();
      case DPadDirection.left:
        arrowPath = Path()
          ..moveTo(center.dx - arrowSize, center.dy)
          ..lineTo(center.dx + arrowSize * 0.3, center.dy - arrowSize * 0.7)
          ..lineTo(center.dx + arrowSize * 0.3, center.dy + arrowSize * 0.7)
          ..close();
      case DPadDirection.right:
        arrowPath = Path()
          ..moveTo(center.dx + arrowSize, center.dy)
          ..lineTo(center.dx - arrowSize * 0.3, center.dy - arrowSize * 0.7)
          ..lineTo(center.dx - arrowSize * 0.3, center.dy + arrowSize * 0.7)
          ..close();
      case DPadDirection.none:
        return;
    }
    canvas.drawPath(arrowPath, paint);
  }

  @override
  bool shouldRepaint(covariant _DPadPainter oldDelegate) {
    return oldDelegate.pressedDirection != pressedDirection;
  }
}
