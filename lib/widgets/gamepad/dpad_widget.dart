import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/controller_theme.dart';

/// Direction enum for D-pad inputs.
enum DPadDirection { up, down, left, right, none }

/// Callback type for D-pad direction events.
typedef DPadCallback = void Function(DPadDirection direction);

/// D-Pad widget using [CustomPainter].
///
/// Detects tap directions (up/down/left/right) and provides visual feedback
/// for pressed states. Multi-touch safe via pointer-id latching. Visuals come
/// from the active [ControllerTheme].
class DPadWidget extends StatefulWidget {
  /// Size of the D-pad.
  final double size;

  /// Callback when a direction is pressed.
  final DPadCallback? onDirectionPressed;

  /// Callback when a direction is released.
  final VoidCallback? onDirectionReleased;

  /// Active controller look.
  final ControllerTheme theme;

  /// Whether to fire a light haptic pulse when a direction engages.
  final bool hapticsEnabled;

  /// Whether press visuals animate (false = instant snap).
  final bool animationsEnabled;

  const DPadWidget({
    super.key,
    this.size = 140.0,
    this.onDirectionPressed,
    this.onDirectionReleased,
    this.theme = ControllerThemes.neon,
    this.hapticsEnabled = false,
    this.animationsEnabled = true,
  });

  @override
  State<DPadWidget> createState() => _DPadWidgetState();
}

class _DPadWidgetState extends State<DPadWidget>
    with SingleTickerProviderStateMixin {
  DPadDirection _pressedDirection = DPadDirection.none;

  /// The direction whose press visual is currently animating.
  DPadDirection _visualDirection = DPadDirection.none;
  int? _activePointerId;

  late final AnimationController _pressCtrl;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
      vsync: this,
      duration: widget.animationsEnabled
          ? const Duration(milliseconds: 110)
          : Duration.zero,
      value: 0,
    )..addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(DPadWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animationsEnabled != oldWidget.animationsEnabled) {
      _pressCtrl.duration = widget.animationsEnabled
          ? const Duration(milliseconds: 110)
          : Duration.zero;
    }
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

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
      if (widget.hapticsEnabled && direction != _pressedDirection) {
        HapticFeedback.lightImpact();
      }
      if (direction != _pressedDirection) {
        setState(() {
          _pressedDirection = direction;
          _visualDirection = direction;
        });
        _pressCtrl.forward(from: 0);
      } else {
        _pressedDirection = direction;
      }
      widget.onDirectionPressed?.call(direction);
    }
  }

  void _release() {
    if (_pressedDirection == DPadDirection.none) return;
    widget.onDirectionReleased?.call();
    setState(() => _pressedDirection = DPadDirection.none);
    // Input fired instantly above; the visual eases back out.
    _pressCtrl.reverse();
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointerId) return;
    _activePointerId = null;
    _release();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointerId) return;
    _activePointerId = null;
    _release();
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
            theme: widget.theme,
            pressedDirection: _pressedDirection,
            visualDirection: _visualDirection,
            pressProgress: _pressCtrl.value,
          ),
        ),
      ),
    );
  }
}

/// CustomPainter for rendering the D-pad in the active [ControllerTheme].
class _DPadPainter extends CustomPainter {
  final ControllerTheme theme;
  final DPadDirection pressedDirection;
  final DPadDirection visualDirection;
  final double pressProgress;

  _DPadPainter({
    required this.theme,
    required this.pressedDirection,
    required this.visualDirection,
    required this.pressProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final armWidth = size.width * 0.3;
    final buttonSize = armWidth;
    final armLength = armWidth * 1.25;

    _drawDirectionalButtons(canvas, center, armLength, armWidth, buttonSize);
  }

  void _drawDirectionalButtons(
    Canvas canvas,
    Offset center,
    double armLength,
    double armWidth,
    double buttonSize,
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
      final press =
          direction == visualDirection ? pressProgress.clamp(0.0, 1.0) : 0.0;

      _drawButton(
        canvas,
        buttonCenter,
        buttonSize,
        direction,
        isPressed,
        press,
      );
    }
  }

  void _drawButton(
    Canvas canvas,
    Offset center,
    double size,
    DPadDirection direction,
    bool isPressed,
    double press,
  ) {
    // Corner radius follows the theme's shape language on top of the classic
    // 15% base rounding.
    final corner = switch (theme.shape) {
      ControllerShape.rounded => size * 0.12,
      ControllerShape.square => size * 0.04,
      ControllerShape.block => 1.0,
      ControllerShape.pill => size * 0.24,
    };

    theme.paintControlRRect(
      canvas,
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: size, height: size),
        Radius.circular(corner),
      ),
      press: press,
    );

    _drawArrowIndicator(
      canvas,
      center,
      direction,
      isPressed,
      size,
      press,
    );
  }

  void _drawArrowIndicator(
    Canvas canvas,
    Offset center,
    DPadDirection direction,
    bool isPressed,
    double buttonSize,
    double press,
  ) {
    final arrowSize = 8.0 * (buttonSize / 48.0);

    // Arrow brightens from the dim secondary glow to full primary accent.
    final arrowPaint = Paint()
      ..color = Color.lerp(theme.dpadGlow, theme.primary, press)!
      ..style = PaintingStyle.fill;

    if (press < 1 && theme.showShadows) {
      final glowPaint = Paint()
        ..color = theme.dpadGlow.withValues(alpha: 0.15 * (1 - press))
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
    return oldDelegate.pressedDirection != pressedDirection ||
        oldDelegate.visualDirection != visualDirection ||
        oldDelegate.pressProgress != pressProgress ||
        oldDelegate.theme != theme;
  }
}
