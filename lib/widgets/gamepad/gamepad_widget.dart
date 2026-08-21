import 'package:flutter/material.dart';

import '../../theme/controller_theme.dart';
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

  /// Callback when start/select/home is released (held buttons stay down until
  /// the finger lifts — Start/Select typically act on the edge, bumpers/triggers
  /// stream their full axis while held).
  final VoidCallback? onStartReleased;
  final VoidCallback? onSelectReleased;
  final VoidCallback? onHomeReleased;

  /// Callback for left bumper (LB).
  final VoidCallback? onLeftBumperPressed;

  /// Callback when the left bumper is released.
  final VoidCallback? onLeftBumperReleased;

  /// Callback for right bumper (RB).
  final VoidCallback? onRightBumperPressed;

  /// Callback when the right bumper is released.
  final VoidCallback? onRightBumperReleased;

  /// Callback for left trigger (LT).
  final VoidCallback? onLeftTriggerPressed;

  /// Callback when the left trigger is released.
  final VoidCallback? onLeftTriggerReleased;

  /// Callback for right trigger (RT).
  final VoidCallback? onRightTriggerPressed;

  /// Callback when the right trigger is released.
  final VoidCallback? onRightTriggerReleased;

  /// Padding around the gamepad.
  final EdgeInsets padding;

  /// Visual scale factor for the gamepad (1.0 = default, 0.7 = small,
  /// 1.3 = large). Applied as a transform around the base layout, so changing
  /// it resizes the controls WITHOUT moving the pad's position on screen —
  /// position is controlled separately by the parent's placement.
  final double scale;

  /// Scale factor for the gaps between the control rows (0.5–2.0, 1.0 =
  /// default). Offsets the components relative to each other (shoulders ↔
  /// sticks/D-pad/face ↔ menu) without resizing them.
  final double spacing;

  /// Whether the shoulder/trigger row (LT/RT/LB/RB) is shown.
  final bool showShoulders;

  /// Whether the analog sticks are shown.
  final bool showSticks;

  /// Whether the D-pad is shown.
  final bool showDpad;

  /// Whether the face buttons (A/B/X/Y) are shown.
  final bool showFaceButtons;

  /// Whether the menu buttons (Select/Start/Home) are shown.
  final bool showMenu;

  /// Visual theme — changes overall look (shape, density, shadows) not just tint.
  final ControllerTheme theme;

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
    this.onStartReleased,
    this.onSelectReleased,
    this.onHomeReleased,
    this.onLeftBumperPressed,
    this.onLeftBumperReleased,
    this.onRightBumperPressed,
    this.onRightBumperReleased,
    this.onLeftTriggerPressed,
    this.onLeftTriggerReleased,
    this.onRightTriggerPressed,
    this.onRightTriggerReleased,
    this.padding = const EdgeInsets.all(16.0),
    this.scale = 1.0,
    this.spacing = 1.0,
    this.showShoulders = true,
    this.showSticks = true,
    this.showDpad = true,
    this.showFaceButtons = true,
    this.showMenu = true,
    this.theme = ControllerTheme.neon,
  });

  @override
  State<VirtualGamepad> createState() => _VirtualGamepadState();
}

class _VirtualGamepadState extends State<VirtualGamepad> {
  /// Screen-adaptive base scale, normalized to a 400px reference. This sizes
  /// the LAYOUT (the base box the pad occupies). The user's component-size
  /// slider is applied separately as a transform (see [build]) so it never
  /// changes this box — i.e. never moves the pad's position on screen.
  /// Theme density tweaks the overall feel (compact vs arcade).
  double get _adaptiveScale {
    final screenSize = MediaQuery.of(context).size;
    final shortestSide = screenSize.width < screenSize.height
        ? screenSize.width
        : screenSize.height;
    final baseScale = shortestSide / 400;
    final themed = baseScale * widget.theme.density;
    return themed.clamp(0.45, 1.6);
  }

  double get _sideContainerSize => 240 * _adaptiveScale;
  double get _dpadSize => 160 * _adaptiveScale;
  double get _analogStickSize => 100 * _adaptiveScale;
  double get _analogStickKnobSize => 42 * _adaptiveScale;
  double get _faceButtonSize => 48 * _adaptiveScale;
  double get _menuButtonSize => 40 * _adaptiveScale;
  double get _shoulderButtonWidth => 90 * _adaptiveScale;
  double get _shoulderButtonHeight => 36 * _adaptiveScale;
  double get _triggerButtonWidth => 70 * _adaptiveScale;
  double get _triggerButtonHeight => 44 * _adaptiveScale;

  /// Inter-component gaps (offsets) scale with the screen AND the spacing
  /// slider, independently of the control sizes.
  double get _spacingScale => _adaptiveScale * widget.spacing;
  double get _centerSpacing => 80 * _spacingScale;

  /// Scales a single control around its own center. The base layout keeps the
  /// control's position; only its visual size changes.
  Widget _scaled(Widget child) {
    return Transform.scale(
      scale: widget.scale,
      alignment: Alignment.center,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    // The component-size slider scales EACH control around its own center via
    // [_scaled] — the base layout (and every control's position) stays exactly
    // where it is, so resizing only changes the size of the controls, never
    // their position. Transform also transforms hit tests, so a scaled-up
    // control stays tappable over its whole visual area.
    return Padding(
      padding: widget.padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showShoulders) ...[
            _buildShoulderButtons(),
            SizedBox(height: 12 * _spacingScale),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLeftSide(),
              if (widget.showDpad ||
                  widget.showSticks ||
                  widget.showFaceButtons)
                SizedBox(width: _centerSpacing),
              _buildRightSide(),
            ],
          ),
          if (widget.showMenu) ...[
            SizedBox(height: 16 * _spacingScale),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _scaled(
                  _MenuButton(
                    label: 'SELECT',
                    size: _menuButtonSize,
                    glowColor: widget.theme.secondary,
                    onPressed: widget.onSelectPressed,
                    onReleased: widget.onSelectReleased,
                  ),
                ),
                SizedBox(width: 16 * _spacingScale),
                _scaled(
                  _MenuButton(
                    label: 'START',
                    size: _menuButtonSize,
                    glowColor: widget.theme.secondary,
                    onPressed: widget.onStartPressed,
                    onReleased: widget.onStartReleased,
                  ),
                ),
                SizedBox(width: 16 * _spacingScale),
                _scaled(
                  _MenuButton(
                    icon: Icons.home_rounded,
                    size: _menuButtonSize * 0.9,
                    glowColor: widget.theme.primary,
                    onPressed: widget.onHomePressed,
                    onReleased: widget.onHomeReleased,
                    isHome: true,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  bool get _isSquare =>
      widget.theme.shape == ControllerShape.square ||
      widget.theme.shape == ControllerShape.block;

  Widget _buildShoulderButtons() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _scaled(
              _TriggerButton(
                width: _triggerButtonWidth,
                height: _triggerButtonHeight,
                glowColor: widget.theme.primary,
                onPressed: widget.onLeftTriggerPressed,
                onReleased: widget.onLeftTriggerReleased,
              ),
            ),
            _scaled(
              _TriggerButton(
                width: _triggerButtonWidth,
                height: _triggerButtonHeight,
                glowColor: widget.theme.primary,
                onPressed: widget.onRightTriggerPressed,
                onReleased: widget.onRightTriggerReleased,
              ),
            ),
          ],
        ),
        SizedBox(height: 8 * _spacingScale),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _scaled(
              _ShoulderButton(
                label: 'LB',
                width: _shoulderButtonWidth,
                height: _shoulderButtonHeight,
                glowColor: widget.theme.secondary,
                square: _isSquare,
                onPressed: widget.onLeftBumperPressed,
                onReleased: widget.onLeftBumperReleased,
              ),
            ),
            _scaled(
              _ShoulderButton(
                label: 'RB',
                width: _shoulderButtonWidth,
                height: _shoulderButtonHeight,
                glowColor: widget.theme.secondary,
                square: _isSquare,
                onPressed: widget.onRightBumperPressed,
                onReleased: widget.onRightBumperReleased,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLeftSide() {
    if (!widget.showDpad && !widget.showSticks) return const SizedBox.shrink();
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showDpad)
            SizedBox(
              width: _sideContainerSize,
              height: _sideContainerSize,
              child: Center(
                child: _scaled(
                  DPadWidget(
                    size: _dpadSize,
                    glowColor: widget.theme.secondary,
                    baseColor: widget.theme.baseBg == const Color(0x00000000)
                        ? const Color(0xFF14141F)
                        : widget.theme.baseBg,
                    onDirectionPressed: widget.onDpadPressed,
                    onDirectionReleased: widget.onDpadReleased,
                  ),
                ),
              ),
            ),
          if (widget.showDpad && widget.showSticks)
            SizedBox(height: 16 * _spacingScale),
          if (widget.showSticks)
            _scaled(
              AnalogStick(
                size: _analogStickSize,
                knobSize: _analogStickKnobSize,
                glowColor: widget.theme.primary,
                baseColor: widget.theme.baseBg == const Color(0x00000000)
                    ? const Color(0xFF14141F)
                    : widget.theme.baseBg,
                onDrag: widget.onLeftStickDrag,
                onDragEnd: widget.onLeftStickDragEnd,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRightSide() {
    if (!widget.showFaceButtons && !widget.showSticks) {
      return const SizedBox.shrink();
    }
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (widget.showFaceButtons)
            SizedBox(
              width: _sideContainerSize,
              height: _sideContainerSize,
              child: Center(
                child: _scaled(
                  FaceButtons(
                    buttonSize: _faceButtonSize,
                    glowColor: widget.theme.primary,
                    onButtonPressed: widget.onFaceButtonPressed,
                    onButtonReleased: widget.onFaceButtonReleased,
                  ),
                ),
              ),
            ),
          if (widget.showFaceButtons && widget.showSticks)
            SizedBox(height: 16 * _spacingScale),
          if (widget.showSticks)
            _scaled(
              AnalogStick(
                size: _analogStickSize,
                knobSize: _analogStickKnobSize,
                glowColor: widget.theme.secondary,
                baseColor: widget.theme.baseBg == const Color(0x00000000)
                    ? const Color(0xFF14141F)
                    : widget.theme.baseBg,
                onDrag: widget.onRightStickDrag,
                onDragEnd: widget.onRightStickDragEnd,
              ),
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
  final VoidCallback? onReleased;
  final bool isHome;
  final Color glowColor;

  const _MenuButton({
    this.label,
    this.icon,
    required this.size,
    this.onPressed,
    this.onReleased,
    this.isHome = false,
    this.glowColor = Neon.accent,
  });

  @override
  State<_MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<_MenuButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _isPressed = true);
        widget.onPressed?.call();
      },
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      onTapCancel: () {
        if (!_isPressed) return;
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: _isPressed ? Neon.cardHover : Neon.bgC,
          borderRadius: BorderRadius.circular(widget.isHome ? widget.size / 3 : widget.size / 4),
          border: Border.all(
            color: widget.isHome
                ? widget.glowColor.withValues(alpha: 0.38)
                : Neon.outline,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _isPressed ? 0.3 : 0.4),
              blurRadius: _isPressed ? 4 : 6,
              offset: Offset(0, _isPressed ? 1 : 3),
            ),
            if (_isPressed)
              BoxShadow(
                color: widget.glowColor.withValues(alpha: 0.38),
                blurRadius: 8,
              ),
          ],
        ),
        child: Center(
          child: widget.icon != null
              ? Icon(
                  widget.icon,
                  size: widget.size * 0.5,
                  color: widget.isHome ? widget.glowColor : Neon.inkMuted,
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
  final VoidCallback? onReleased;
  final Color glowColor;
  final bool square;

  const _ShoulderButton({
    required this.label,
    required this.width,
    required this.height,
    this.onPressed,
    this.onReleased,
    this.glowColor = Neon.violet,
    this.square = false,
  });

  @override
  State<_ShoulderButton> createState() => _ShoulderButtonState();
}

class _ShoulderButtonState extends State<_ShoulderButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _isPressed = true);
        widget.onPressed?.call();
      },
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      onTapCancel: () {
        if (!_isPressed) return;
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: _isPressed
              ? (widget.square ? widget.glowColor.withValues(alpha: 0.22) : Neon.cardHover)
              : Neon.bgC,
          borderRadius: BorderRadius.circular(widget.square ? 4 : 6),
          border: Border.all(
            color: _isPressed ? widget.glowColor : Neon.outline,
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _isPressed ? 0.2 : 0.35),
              blurRadius: _isPressed ? 3 : 5,
              offset: Offset(0, _isPressed ? 1 : 2),
            ),
            if (_isPressed)
              BoxShadow(
                color: widget.glowColor.withValues(alpha: 0.38),
                blurRadius: 8,
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
  final VoidCallback? onReleased;
  final Color glowColor;

  const _TriggerButton({
    required this.width,
    required this.height,
    this.onPressed,
    this.onReleased,
    this.glowColor = Neon.accent,
  });

  @override
  State<_TriggerButton> createState() => _TriggerButtonState();
}

class _TriggerButtonState extends State<_TriggerButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        setState(() => _isPressed = true);
        widget.onPressed?.call();
      },
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      onTapCancel: () {
        if (!_isPressed) return;
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
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
          border: Border.all(
            color: _isPressed ? widget.glowColor : Neon.outline,
            width: 1,
          ),
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
            if (_isPressed)
              BoxShadow(
                color: widget.glowColor.withValues(alpha: 0.42),
                blurRadius: 8,
              ),
          ],
        ),
        child: Center(
          child: Container(
            width: 32 * (widget.width / 56),
            height: 4 * (widget.height / 36),
            decoration: BoxDecoration(
              color: _isPressed
                  ? widget.glowColor.withValues(alpha: 0.6)
                  : Neon.inkMuted.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}
