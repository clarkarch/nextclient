import 'package:flutter/material.dart';

import '../../theme/neon.dart';

/// Button label enum.
enum FaceButtonLabel { a, b, x, y }

/// Callback type for face button events.
typedef FaceButtonCallback = void Function(FaceButtonLabel button);

/// Face buttons widget (A, B, X, Y) using [CustomPainter].
///
/// Arranged in standard Xbox-style diamond layout:
/// ```
///   Y
/// X   B
///   A
/// ```
class FaceButtons extends StatefulWidget {
  /// Size of each button.
  final double buttonSize;

  /// Callback when a button is pressed.
  final FaceButtonCallback? onButtonPressed;

  /// Callback when a button is released.
  final FaceButtonCallback? onButtonReleased;

  /// Base color for buttons.
  final Color buttonColor;

  /// Glow color for active state.
  final Color glowColor;

  const FaceButtons({
    super.key,
    this.buttonSize = 48.0,
    this.onButtonPressed,
    this.onButtonReleased,
    this.buttonColor = const Color(0xFF2A2A3E),
    this.glowColor = Neon.accent,
  });

  @override
  State<FaceButtons> createState() => _FaceButtonsState();
}

class _FaceButtonsState extends State<FaceButtons> {
  FaceButtonLabel? _pressedButton;
  int? _activePointerId;

  static const _buttonPositions = {
    FaceButtonLabel.y: Offset(0, -1), // Top
    FaceButtonLabel.b: Offset(1, 0), // Right
    FaceButtonLabel.a: Offset(0, 1), // Bottom
    FaceButtonLabel.x: Offset(-1, 0), // Left
  };

  static const _buttonLabels = {
    FaceButtonLabel.a: 'A',
    FaceButtonLabel.b: 'B',
    FaceButtonLabel.x: 'X',
    FaceButtonLabel.y: 'Y',
  };

  static const _buttonColors = {
    FaceButtonLabel.a: Neon.success, // Green
    FaceButtonLabel.b: Neon.error, // Red
    FaceButtonLabel.x: Neon.accent, // Cyan
    FaceButtonLabel.y: Neon.violet, // Purple
  };

  Offset get _center => Offset(
        widget.buttonSize * 2.5,
        widget.buttonSize * 2.5,
      );

  // Center distance = buttonSize * spacingFactor (1.125 ≈ 6px gap at 48px).
  double get _spacingFactor => 1.125;

  FaceButtonLabel? _getButtonFromPosition(Offset localPosition) {
    final diff = localPosition - _center;
    final distance = diff.distance;
    final buttonRadius = widget.buttonSize * 0.6;

    if (distance > buttonRadius * 3.5) return null;

    final absX = diff.dx.abs();
    final absY = diff.dy.abs();

    // Dead zone in center.
    if (absX < widget.buttonSize * 0.3 && absY < widget.buttonSize * 0.3) {
      return null;
    }

    if (absY > absX) {
      return diff.dy < 0 ? FaceButtonLabel.y : FaceButtonLabel.a;
    } else {
      return diff.dx > 0 ? FaceButtonLabel.b : FaceButtonLabel.x;
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_activePointerId != null) return;
    _activePointerId = event.pointer;

    final button = _getButtonFromPosition(event.localPosition);
    if (button != null) {
      setState(() => _pressedButton = button);
      widget.onButtonPressed?.call(button);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointerId) return;
    _activePointerId = null;

    if (_pressedButton != null) {
      widget.onButtonReleased?.call(_pressedButton!);
      setState(() => _pressedButton = null);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointerId) return;
    _activePointerId = null;

    if (_pressedButton != null) {
      widget.onButtonReleased?.call(_pressedButton!);
      setState(() => _pressedButton = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalSize = widget.buttonSize * 5;

    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: SizedBox(
        width: totalSize,
        height: totalSize,
        child: CustomPaint(
          painter: _FaceButtonsPainter(
            buttonSize: widget.buttonSize,
            spacingFactor: _spacingFactor,
            pressedButton: _pressedButton,
            buttonColor: widget.buttonColor,
            glowColor: widget.glowColor,
            buttonColors: _buttonColors,
            buttonLabels: _buttonLabels,
            buttonPositions: _buttonPositions,
          ),
        ),
      ),
    );
  }
}

/// CustomPainter for rendering face buttons with neumorphic shadows.
class _FaceButtonsPainter extends CustomPainter {
  final double buttonSize;
  final double spacingFactor;
  final FaceButtonLabel? pressedButton;
  final Color buttonColor;
  final Color glowColor;
  final Map<FaceButtonLabel, Color> buttonColors;
  final Map<FaceButtonLabel, String> buttonLabels;
  final Map<FaceButtonLabel, Offset> buttonPositions;

  _FaceButtonsPainter({
    required this.buttonSize,
    required this.spacingFactor,
    required this.pressedButton,
    required this.buttonColor,
    required this.glowColor,
    required this.buttonColors,
    required this.buttonLabels,
    required this.buttonPositions,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final buttonRadius = buttonSize / 2;

    for (final entry in buttonPositions.entries) {
      final button = entry.key;
      final position = entry.value;
      final buttonCenter = center + Offset(
            position.dx * buttonSize * spacingFactor,
            position.dy * buttonSize * spacingFactor,
          );

      final isPressed = pressedButton == button;
      final buttonColorValue = buttonColors[button] ?? glowColor;

      _drawButton(
        canvas,
        buttonCenter,
        buttonRadius,
        buttonLabels[button]!,
        buttonColorValue,
        isPressed,
      );
    }
  }

  void _drawButton(
    Canvas canvas,
    Offset center,
    double radius,
    String label,
    Color accentColor,
    bool isPressed,
  ) {
    if (isPressed) {
      final glowPaint = Paint()
        ..color = accentColor.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);

      canvas.drawCircle(center, radius + 4, glowPaint);
    }

    final shadowOffset = isPressed ? const Offset(0, 1) : const Offset(0, 3);
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: isPressed ? 0.5 : 0.35)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isPressed ? 4 : 6);

    canvas.drawCircle(center + shadowOffset, radius, shadowPaint);

    final buttonPaint = Paint()
      ..shader = RadialGradient(
        colors: isPressed
            ? [accentColor.withValues(alpha: 0.9), accentColor.withValues(alpha: 0.7)]
            : [buttonColor, buttonColor.withValues(alpha: 0.7)],
        center: const Alignment(-0.3, -0.3),
        radius: 1.2,
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawCircle(center, radius, buttonPaint);

    final borderPaint = Paint()
      ..color = isPressed
          ? accentColor.withValues(alpha: 0.8)
          : Colors.white.withValues(alpha: 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isPressed ? 2 : 1.5;

    canvas.drawCircle(center, radius - 0.5, borderPaint);

    _drawLabel(canvas, center, label, accentColor, isPressed);
  }

  void _drawLabel(
    Canvas canvas,
    Offset center,
    String label,
    Color accentColor,
    bool isPressed,
  ) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: isPressed ? Colors.white : accentColor.withValues(alpha: 0.9),
          fontSize: buttonSize * 0.45,
          fontWeight: FontWeight.bold,
          shadows: [
            Shadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();
    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _FaceButtonsPainter oldDelegate) {
    return oldDelegate.pressedButton != pressedButton;
  }
}
