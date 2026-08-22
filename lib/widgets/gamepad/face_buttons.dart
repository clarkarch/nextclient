import 'package:flutter/material.dart';

import 'haptics.dart';
import '../../theme/controller_theme.dart';

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
/// Visuals (colours, shape language, material, glyph style) come from the
/// active [ControllerTheme].
class FaceButtons extends StatefulWidget {
  /// Size of each button.
  final double buttonSize;

  /// Callback when a button is pressed.
  final FaceButtonCallback? onButtonPressed;

  /// Callback when a button is released.
  final FaceButtonCallback? onButtonReleased;

  /// Active controller look.
  final ControllerTheme theme;

  /// Nintendo glyph layout: A/B and X/Y swap positions (A right, B bottom,
  /// X top, Y left) like a Switch controller. Signals follow the glyphs.
  final bool nintendoLayout;

  /// Whether to fire a light haptic pulse when a button engages.
  final bool hapticsEnabled;

  /// Whether press visuals animate (false = instant snap).
  final bool animationsEnabled;

  const FaceButtons({
    super.key,
    this.buttonSize = 48.0,
    this.onButtonPressed,
    this.onButtonReleased,
    this.theme = ControllerThemes.neon,
    this.nintendoLayout = false,
    this.hapticsEnabled = false,
    this.animationsEnabled = true,
  });

  @override
  State<FaceButtons> createState() => _FaceButtonsState();
}

class _FaceButtonsState extends State<FaceButtons>
    with SingleTickerProviderStateMixin {
  FaceButtonLabel? _pressedButton;

  /// The button whose press visual is currently animating (kept during
  /// release so the ease-out is visible after input already fired).
  FaceButtonLabel? _visualButton;
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
    );
  }

  @override
  void didUpdateWidget(FaceButtons oldWidget) {
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

  /// Xbox diamond: Y top, B right, A bottom, X left. Nintendo layout swaps
  /// A/B and X/Y — the SAME map drives both the painted glyphs and the
  /// hit-test, so what you see is always what gets sent.
  Map<FaceButtonLabel, Offset> get _buttonPositions => widget.nintendoLayout
      ? const {
          FaceButtonLabel.x: Offset(0, -1), // Top
          FaceButtonLabel.a: Offset(1, 0), // Right
          FaceButtonLabel.b: Offset(0, 1), // Bottom
          FaceButtonLabel.y: Offset(-1, 0), // Left
        }
      : const {
          FaceButtonLabel.y: Offset(0, -1),
          FaceButtonLabel.b: Offset(1, 0),
          FaceButtonLabel.a: Offset(0, 1),
          FaceButtonLabel.x: Offset(-1, 0),
        };

  Offset get _center =>
      Offset(widget.buttonSize * 2.5, widget.buttonSize * 2.5);

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

    final direction = absY > absX
        ? (diff.dy < 0 ? const Offset(0, -1) : const Offset(0, 1))
        : (diff.dx > 0 ? const Offset(1, 0) : const Offset(-1, 0));
    for (final entry in _buttonPositions.entries) {
      if (entry.value == direction) return entry.key;
    }
    return null;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_activePointerId != null) return;
    _activePointerId = event.pointer;

    final button = _getButtonFromPosition(event.localPosition);
    if (button != null) {
      if (widget.hapticsEnabled && button != _pressedButton) {
        gamepadHaptic();
      }
      setState(() {
        _pressedButton = button;
        _visualButton = button;
      });
      _pressCtrl.forward();
      widget.onButtonPressed?.call(button);
    }
  }

  void _release() {
    if (_pressedButton == null) return;
    widget.onButtonReleased?.call(_pressedButton!);
    setState(() => _pressedButton = null);
    // Input fired instantly above; the visual eases back out.
    _pressCtrl.reverse();
    if (_pressCtrl.isDismissed) _visualButton = null;
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
    final totalSize = widget.buttonSize * 5;

    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      child: SizedBox(
        width: totalSize,
        height: totalSize,
        // Only the CustomPaint rebuilds per animation tick.
        child: AnimatedBuilder(
          animation: _pressCtrl,
          builder: (context, _) => CustomPaint(
            painter: _FaceButtonsPainter(
              theme: widget.theme,
              buttonSize: widget.buttonSize,
              spacingFactor: _spacingFactor,
              pressedButton: _pressedButton,
              visualButton: _visualButton,
              pressProgress: _pressCtrl.value,
              buttonPositions: _buttonPositions,
            ),
          ),
        ),
      ),
    );
  }
}

FaceGlyph _glyphOf(FaceButtonLabel label) => switch (label) {
  FaceButtonLabel.a => FaceGlyph.a,
  FaceButtonLabel.b => FaceGlyph.b,
  FaceButtonLabel.x => FaceGlyph.x,
  FaceButtonLabel.y => FaceGlyph.y,
};

/// CustomPainter for rendering face buttons in the active [ControllerTheme].
class _FaceButtonsPainter extends CustomPainter {
  final ControllerTheme theme;
  final double buttonSize;
  final double spacingFactor;
  final FaceButtonLabel? pressedButton;

  /// The button whose press animation is playing (input may have released).
  final FaceButtonLabel? visualButton;
  final double pressProgress;
  final Map<FaceButtonLabel, Offset> buttonPositions;

  _FaceButtonsPainter({
    required this.theme,
    required this.buttonSize,
    required this.spacingFactor,
    required this.pressedButton,
    required this.visualButton,
    required this.pressProgress,
    required this.buttonPositions,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final buttonRadius = buttonSize / 2;

    for (final entry in buttonPositions.entries) {
      final button = entry.key;
      final position = entry.value;
      final buttonCenter =
          center +
          Offset(
            position.dx * buttonSize * spacingFactor,
            position.dy * buttonSize * spacingFactor,
          );

      final isPressed = pressedButton == button;
      final accentColor = theme.faceColor(_glyphOf(button));
      final press = button == visualButton
          ? pressProgress.clamp(0.0, 1.0)
          : 0.0;

      _drawButton(
        canvas,
        buttonCenter,
        buttonRadius,
        button,
        accentColor,
        isPressed,
        press,
      );
    }
  }

  String _labelOf(FaceButtonLabel button) {
    return switch (button) {
      FaceButtonLabel.a => 'A',
      FaceButtonLabel.b => 'B',
      FaceButtonLabel.x => 'X',
      FaceButtonLabel.y => 'Y',
    };
  }

  void _drawButton(
    Canvas canvas,
    Offset center,
    double radius,
    FaceButtonLabel button,
    Color accentColor,
    bool isPressed,
    double press,
  ) {
    // Shape follows the theme's shape language: circles for rounded/pill,
    // squircles for square/block.
    switch (theme.shape) {
      case ControllerShape.rounded:
      case ControllerShape.pill:
        theme.paintControlCircle(
          canvas,
          center,
          radius,
          press: press,
          fill: accentColor,
        );
      case ControllerShape.square:
      case ControllerShape.block:
        theme.paintControlRRect(
          canvas,
          RRect.fromRectAndRadius(
            Rect.fromCircle(center: center, radius: radius),
            Radius.circular(theme.cornerFor(radius * 2)),
          ),
          press: press,
          fill: accentColor,
        );
    }

    if (theme.faceLabels == FaceLabelStyle.playstationSymbols) {
      _drawPsGlyph(canvas, center, button, accentColor, isPressed);
    } else {
      _drawLabel(canvas, center, _labelOf(button), accentColor, isPressed);
    }
  }

  /// Paints the PlayStation glyphs (△ ○ × □) as vectors so their size and
  /// stroke weight are identical across devices regardless of font coverage.
  void _drawPsGlyph(
    Canvas canvas,
    Offset center,
    FaceButtonLabel button,
    Color accentColor,
    bool isPressed,
  ) {
    final color = isPressed
        ? Colors.white
        : accentColor.withValues(alpha: 0.95);
    final r = buttonSize * 0.27; // glyph half-extent
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = buttonSize * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    switch (button) {
      case FaceButtonLabel.y: // △ top
        final h = r * 0.88;
        canvas.drawPath(
          Path()
            ..moveTo(center.dx, center.dy - h)
            ..lineTo(center.dx + h * 1.1, center.dy + h * 0.7)
            ..lineTo(center.dx - h * 1.1, center.dy + h * 0.7)
            ..close(),
          paint,
        );
      case FaceButtonLabel.b: // ○ right
        canvas.drawCircle(center, r * 0.82, paint);
      case FaceButtonLabel.a: // × bottom
        final d = r * 0.78;
        canvas.drawLine(center + Offset(-d, -d), center + Offset(d, d), paint);
        canvas.drawLine(center + Offset(-d, d), center + Offset(d, -d), paint);
      case FaceButtonLabel.x: // □ left
        canvas.drawRect(
          Rect.fromCenter(center: center, width: r * 1.45, height: r * 1.45),
          paint,
        );
    }
  }

  void _drawLabel(
    Canvas canvas,
    Offset center,
    String label,
    Color accentColor,
    bool isPressed,
  ) {
    final unpressedColor = switch (theme.faceLabels) {
      FaceLabelStyle.coloredLetters => accentColor.withValues(alpha: 0.9),
      FaceLabelStyle.whiteLetters => theme.inkColor.withValues(alpha: 0.9),
      FaceLabelStyle.playstationSymbols => accentColor.withValues(alpha: 0.95),
    };

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: isPressed ? Colors.white : unpressedColor,
          fontSize: buttonSize * 0.45,
          fontWeight: FontWeight.bold,
          shadows: theme.showShadows
              ? [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
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
    return oldDelegate.pressedButton != pressedButton ||
        oldDelegate.visualButton != visualButton ||
        oldDelegate.pressProgress != pressProgress ||
        oldDelegate.theme != theme;
  }
}
