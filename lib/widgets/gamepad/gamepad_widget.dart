import 'package:flutter/material.dart';

import '../../theme/neon.dart';
import 'analog_stick.dart';
import 'dpad_widget.dart';
import 'face_buttons.dart';

/// Main virtual gamepad widget combining all controller elements.
///
/// Provides a complete gamepad interface with:
/// - Left side: Analog stick + D-pad
/// - Right side: Analog stick + Face buttons (A, B, X, Y) + Menu buttons
///
/// Size is calculated dynamically based on screen size and user preference.
class VirtualGamepad extends StatefulWidget {
  /// Callback for left analog stick movement.
  final void Function(Offset normalizedOffset)? onLeftStickDrag;

  /// Callback when left stick is released.
  final VoidCallback? onLeftStickDragEnd;

  /// Callback for right analog stick movement.
  final void Function(Offset normalizedOffset)? onRightStickDrag;

  /// Callback when right stick is released.
  final VoidCallback? onRightStickDragEnd;

  /// Callback for D-pad direction.
  final void Function(DPadDirection direction)? onDpadPressed;

  /// Callback when D-pad is released.
  final VoidCallback? onDpadReleased;

  /// Callback for face button press.
  final void Function(FaceButtonLabel button)? onFaceButtonPressed;

  /// Callback when face button is released.
  final void Function(FaceButtonLabel button)? onFaceButtonReleased;

  /// Callback for start button.
  final VoidCallback? onStartPressed;

  /// Callback for select button.
  final VoidCallback? onSelectPressed;

  /// Callback for home button.
  final VoidCallback? onHomePressed;

  /// Callback for left bumper (LB).
  final VoidCallback? onLeftBumperPressed;

  /// Callback for right bumper (RB).
  final VoidCallback? onRightBumperPressed;

  /// Callback for left trigger (LT).
  final VoidCallback? onLeftTriggerPressed;

  /// Callback for right trigger (RT).
  final VoidCallback? onRightTriggerPressed;

  /// Background color for the gamepad area.
  final Color backgroundColor;

  /// Padding around the gamepad.
  final EdgeInsets padding;

  /// Scale factor for gamepad size (1.0 = default, 0.7 = small, 1.3 = large).
  final double scale;

  const VirtualGamepad({
    super.key,
    this.onLeftStickDrag,
    this.onLeftStickDragEnd,
    this.onRightStickDrag,
    this.onRightStickDragEnd,
    this.onDpadPressed,
    this.onDpadReleased,
    this.onFaceButtonPressed,
    this.onFaceButtonReleased,
    this.onStartPressed,
    this.onSelectPressed,
    this.onHomePressed,
    this.onLeftBumperPressed,
    this.onRightBumperPressed,
    this.onLeftTriggerPressed,
    this.onRightTriggerPressed,
    this.backgroundColor = Colors.transparent,
    this.padding = const EdgeInsets.all(16.0),
    this.scale = 1.0,
  });

  @override
  State<VirtualGamepad> createState() => _VirtualGamepadState();
}

class _VirtualGamepadState extends State<VirtualGamepad> {
  /// Calculate adaptive scale based on screen size.
  double get _adaptiveScale {
    final screenSize = MediaQuery.of(context).size;
    final shortestSide =
        screenSize.width < screenSize.height ? screenSize.width : screenSize.height;
    // Base scale on shortest side, normalized to 400px reference.
    final baseScale = shortestSide / 400;
    return (baseScale.clamp(0.5, 1.5) * widget.scale).clamp(0.4, 2.0);
  }

  double get _sideContainerSize => 240 * _adaptiveScale;
  double get _dpadSize => 160 * _adaptiveScale;
  double get _analogStickSize => 100 * _adaptiveScale;
  double get _analogStickKnobSize => 42 * _adaptiveScale;
  double get _faceButtonSize => 48 * _adaptiveScale;
  double get _centerSpacing => 80 * _adaptiveScale;
  double get _menuButtonSize => 40 * _adaptiveScale;
  double get _shoulderButtonWidth => 90 * _adaptiveScale;
  double get _shoulderButtonHeight => 36 * _adaptiveScale;
  double get _triggerButtonWidth => 70 * _adaptiveScale;
  double get _triggerButtonHeight => 44 * _adaptiveScale;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        color: widget.backgroundColor,
        border: Border.all(color: Neon.outlineSoft),
      ),
      child: Padding(
        padding: widget.padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildShoulderButtons(),
            SizedBox(height: 12 * _adaptiveScale),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLeftSide(),
                SizedBox(width: _centerSpacing),
                _buildRightSide(),
              ],
            ),
            SizedBox(height: 16 * _adaptiveScale),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MenuButton(
                  label: 'SELECT',
                  size: _menuButtonSize,
                  onPressed: widget.onSelectPressed,
                ),
                SizedBox(width: 16 * _adaptiveScale),
                _MenuButton(
                  label: 'START',
                  size: _menuButtonSize,
                  onPressed: widget.onStartPressed,
                ),
                SizedBox(width: 16 * _adaptiveScale),
                _MenuButton(
                  icon: Icons.home_rounded,
                  size: _menuButtonSize * 0.9,
                  onPressed: widget.onHomePressed,
                  isHome: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShoulderButtons() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _TriggerButton(
              width: _triggerButtonWidth,
              height: _triggerButtonHeight,
              onPressed: widget.onLeftTriggerPressed,
            ),
            _TriggerButton(
              width: _triggerButtonWidth,
              height: _triggerButtonHeight,
              onPressed: widget.onRightTriggerPressed,
            ),
          ],
        ),
        SizedBox(height: 8 * _adaptiveScale),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _ShoulderButton(
              label: 'LB',
              width: _shoulderButtonWidth,
              height: _shoulderButtonHeight,
              onPressed: widget.onLeftBumperPressed,
            ),
            _ShoulderButton(
              label: 'RB',
              width: _shoulderButtonWidth,
              height: _shoulderButtonHeight,
              onPressed: widget.onRightBumperPressed,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLeftSide() {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _sideContainerSize,
            height: _sideContainerSize,
            child: Center(
              child: DPadWidget(
                size: _dpadSize,
                glowColor: Neon.violet,
                onDirectionPressed: widget.onDpadPressed,
                onDirectionReleased: widget.onDpadReleased,
              ),
            ),
          ),
          SizedBox(height: 16 * _adaptiveScale),
          AnalogStick(
            size: _analogStickSize,
            knobSize: _analogStickKnobSize,
            glowColor: Neon.accent,
            onDrag: widget.onLeftStickDrag,
            onDragEnd: widget.onLeftStickDragEnd,
          ),
        ],
      ),
    );
  }

  Widget _buildRightSide() {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: _sideContainerSize,
            height: _sideContainerSize,
            child: Center(
              child: FaceButtons(
                buttonSize: _faceButtonSize,
                onButtonPressed: widget.onFaceButtonPressed,
                onButtonReleased: widget.onFaceButtonReleased,
              ),
            ),
          ),
          SizedBox(height: 16 * _adaptiveScale),
          AnalogStick(
            size: _analogStickSize,
            knobSize: _analogStickKnobSize,
            glowColor: Neon.violet,
            onDrag: widget.onRightStickDrag,
            onDragEnd: widget.onRightStickDragEnd,
          ),
        ],
      ),
    );
  }
}

/// Small menu button widget with neumorphic styling.
class _MenuButton extends StatefulWidget {
  final String? label;
  final IconData? icon;
  final double size;
  final VoidCallback? onPressed;
  final bool isHome;

  const _MenuButton({
    this.label,
    this.icon,
    required this.size,
    this.onPressed,
    this.isHome = false,
  });

  @override
  State<_MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<_MenuButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onPressed?.call();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: _isPressed ? Neon.cardHover : Neon.bgC,
          borderRadius: BorderRadius.circular(widget.size / 3),
          border: Border.all(
            color: widget.isHome
                ? Neon.accent.withValues(alpha: 0.3)
                : Neon.outline,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _isPressed ? 0.3 : 0.4),
              blurRadius: _isPressed ? 4 : 6,
              offset: Offset(0, _isPressed ? 1 : 3),
            ),
            if (widget.isHome && _isPressed)
              BoxShadow(
                color: Neon.accent.withValues(alpha: 0.3),
                blurRadius: 8,
              ),
          ],
        ),
        child: Center(
          child: widget.icon != null
              ? Icon(
                  widget.icon,
                  size: widget.size * 0.5,
                  color: widget.isHome ? Neon.accent : Neon.inkMuted,
                )
              : Text(
                  widget.label ?? '',
                  style: TextStyle(
                    fontSize: widget.size * 0.22,
                    fontWeight: FontWeight.w600,
                    color: Neon.inkMuted,
                    letterSpacing: 0.5,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Shoulder button widget (LB/RB).
class _ShoulderButton extends StatefulWidget {
  final String label;
  final double width;
  final double height;
  final VoidCallback? onPressed;

  const _ShoulderButton({
    required this.label,
    required this.width,
    required this.height,
    this.onPressed,
  });

  @override
  State<_ShoulderButton> createState() => _ShoulderButtonState();
}

class _ShoulderButtonState extends State<_ShoulderButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onPressed?.call();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: _isPressed ? Neon.cardHover : Neon.bgC,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Neon.outline, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _isPressed ? 0.2 : 0.35),
              blurRadius: _isPressed ? 3 : 5,
              offset: Offset(0, _isPressed ? 1 : 2),
            ),
          ],
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 12 * (widget.height / 28),
              fontWeight: FontWeight.w600,
              color: Neon.inkMuted,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// Trigger button widget (LT/RT) — taller and narrower than bumpers, with a
/// curved concave design typical of trigger buttons.
class _TriggerButton extends StatefulWidget {
  final double width;
  final double height;
  final VoidCallback? onPressed;

  const _TriggerButton({
    required this.width,
    required this.height,
    this.onPressed,
  });

  @override
  State<_TriggerButton> createState() => _TriggerButtonState();
}

class _TriggerButtonState extends State<_TriggerButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onPressed?.call();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: _isPressed
                ? [Neon.cardHover.withValues(alpha: 0.9), Neon.bgC]
                : [Neon.bgC, Neon.bgC.withValues(alpha: 0.8)],
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(8),
            topRight: Radius.circular(8),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(4),
          ),
          border: Border.all(color: Neon.outline, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _isPressed ? 0.2 : 0.35),
              blurRadius: _isPressed ? 3 : 5,
              offset: Offset(0, _isPressed ? 1 : 2),
            ),
            // Inner shadow for concave effect.
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 2,
              offset: const Offset(0, 2),
              spreadRadius: -1,
            ),
          ],
        ),
        child: Center(
          child: Container(
            width: 32 * (widget.width / 56),
            height: 4 * (widget.height / 36),
            decoration: BoxDecoration(
              color: _isPressed
                  ? Neon.accent.withValues(alpha: 0.6)
                  : Neon.inkMuted.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}
