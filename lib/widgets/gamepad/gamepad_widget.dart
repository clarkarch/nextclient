import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/controller_theme.dart';
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
/// The overall look (palette, shape language, material) comes from the
/// active [ControllerTheme].
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
  final VoidCallback? onL3Pressed;
  final VoidCallback? onL3Released;
  final VoidCallback? onR3Pressed;
  final VoidCallback? onR3Released;

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
  /// Base inset (scaled) from screen edges for every anchor.
  final double edgePadding;

  /// 0..1 - shifts the d-pad / XYAB clusters downward within their band.
  final double verticalPosition;

  final bool showSticks;

  /// Whether the D-pad is shown.
  final bool showDpad;

  /// Whether the face buttons (A/B/X/Y) are shown.
  final bool showFaceButtons;

  /// Whether the menu buttons (Select/Start/Home) are shown.
  final bool showMenu;

  /// Active controller look (palette + shape + material).
  final ControllerTheme theme;

  /// Per-group component-size multipliers (0.6–1.5, 1.0 = follow the preset).
  final double stickScale;
  final double faceScale;
  final double dpadScale;

  /// Southpaw mode: swaps the left/right analog sticks' positions.
  final bool southpaw;

  /// Nintendo glyph layout on the face buttons (A/B and X/Y swapped).
  final bool nintendoLayout;

  /// Stick input dead zone as a fraction of full deflection (0.0–0.3).
  final double deadZone;

  /// Light haptic pulse when controls engage.
  final bool hapticFeedback;

  /// Master toggle for shadows/glows — off renders flat for max performance.
  final bool visualEffects;

  /// Whether press visuals animate (false = instant snap).
  final bool animationsEnabled;

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
    this.onL3Pressed,
    this.onL3Released,
    this.onR3Pressed,
    this.onR3Released,
    this.onLeftBumperPressed,
    this.onLeftBumperReleased,
    this.onRightBumperPressed,
    this.onRightBumperReleased,
    this.onLeftTriggerPressed,
    this.onLeftTriggerReleased,
    this.onRightTriggerPressed,
    this.onRightTriggerReleased,
    this.padding = const EdgeInsets.all(16.0),
    this.edgePadding = 12.0,
    this.verticalPosition = 0.0,
    this.scale = 1.0,
    this.spacing = 1.0,
    this.showShoulders = true,
    this.showSticks = true,
    this.showDpad = true,
    this.showFaceButtons = true,
    this.showMenu = true,
    this.theme = ControllerThemes.neon,
    this.stickScale = 1.0,
    this.faceScale = 1.0,
    this.dpadScale = 1.0,
    this.southpaw = false,
    this.nintendoLayout = false,
    this.deadZone = 0.0,
    this.hapticFeedback = false,
    this.visualEffects = true,
    this.animationsEnabled = true,
  });

  @override
  State<VirtualGamepad> createState() => _VirtualGamepadState();
}

class _VirtualGamepadState extends State<VirtualGamepad> {
  /// The active theme with the visual-effects toggle applied: effects off
  /// forces shadows/glows off regardless of the preset's own setting.
  ControllerTheme get _theme => widget.visualEffects
      ? widget.theme
      : widget.theme.copyWith(showShadows: false);

  /// Screen-adaptive base scale, normalized to a 400px reference. This sizes
  /// the LAYOUT (the base box the pad occupies). The user's component-size
  /// slider is applied separately as a transform (see [build]) so it never
  /// changes this box — i.e. never moves the pad's position on screen.
  double get _adaptiveScale {
    final screenSize = MediaQuery.of(context).size;
    final shortestSide = screenSize.width < screenSize.height
        ? screenSize.width
        : screenSize.height;
    var baseScale = shortestSide / 400;

    // Height fit: on landscape phones (e.g. 720x1560 -> ~360 logical px tall)
    // the base scale still overflows vertically and clips the topmost row
    // (LB/RB). Estimate the pad's natural column height at that scale —
    // shoulder row + gap + side containers + menu row — and shrink uniformly
    // so every control keeps its position, just smaller.
    // EdgeInsetsGeometry.vertical exposes the total top+bottom extent.
    final availHeight = screenSize.height - widget.padding.vertical;
    final naturalHeight =
        (44 +
            8 +
            36 + // trigger row, gap, bumper row
            12 + // gap below shoulders
            240 + // side containers (dpad/stick/face)
            16 +
            40 +
            16) * // menu row gaps + buttons
        baseScale;
    if (naturalHeight > availHeight && naturalHeight > 0) {
      baseScale *= availHeight / naturalHeight;
    }
    return baseScale.clamp(0.35, 1.5);
  }

  /// The theme's baked-in component-size multiplier.
  double get _density => widget.theme.density;

  double get _sideContainerSize => 240 * _adaptiveScale;
  double get _dpadSize =>
      160 * _adaptiveScale * _density * widget.dpadScale.clamp(0.6, 1.5);
  double get _analogStickSize =>
      100 * _adaptiveScale * _density * widget.stickScale.clamp(0.6, 1.5);
  double get _analogStickKnobSize =>
      42 * _adaptiveScale * _density * widget.stickScale.clamp(0.6, 1.5);
  double get _faceButtonSize =>
      48 * _adaptiveScale * _density * widget.faceScale.clamp(0.6, 1.5);
  double get _menuButtonSize => 40 * _adaptiveScale * _density;
  double get _shoulderButtonWidth => 90 * _adaptiveScale * _density;
  double get _shoulderButtonHeight => 36 * _adaptiveScale * _density;
  double get _triggerButtonWidth => 70 * _adaptiveScale * _density;
  double get _triggerButtonHeight => 44 * _adaptiveScale * _density;

  /// Inter-component gaps (offsets) scale with the screen AND the spacing
  /// slider, independently of the control sizes.
  double get _spacingScale => _adaptiveScale * widget.spacing;

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
    final s = _adaptiveScale;
    return LayoutBuilder(
      builder: (context, constraints) {
        final double bandH =
            (constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : MediaQuery.of(context).size.height) -
            widget.edgePadding * s;
        // Anchored Stack: shoulders pinned across the top, d-pad on the left
        // side, XYAB on the right, sticks anchored to the bottom corners
        // (lifted above the menu row), menu centered at the very bottom.
        // Every anchor uses [edgePadding] so the pad hugs the edges/corners
        // and the gameplay center stays clear.
        final double edge = widget.edgePadding * s;
        final double shoulderH = widget.showShoulders
            ? (_triggerButtonHeight +
                  8 * _spacingScale +
                  _shoulderButtonHeight +
                  10 * s)
            : 0.0;
        final double menuH = widget.showMenu
            ? (_menuButtonSize * widget.scale + 12 * s)
            : 0.0;
        final double stickLift = menuH + 14 * s;
        // Vertical position slider moves the d-pad / XYAB clusters within
        // the band between shoulders and the bottom controls.
        // verticalPosition: 0 = centered in the band, -1 = up at the
        // shoulders, +1 = down at the bottom controls.
        final double clusterTravel =
            ((bandH - shoulderH - menuH - _sideContainerSize) / 2).clamp(
              0.0,
              double.infinity,
            );
        final double clusterCenter = shoulderH + 6 * s + clusterTravel;
        final double clusterTop =
            clusterCenter -
            _sideContainerSize / 2 +
            widget.verticalPosition * clusterTravel;

        final Widget dpad = SizedBox(
          width: _sideContainerSize,
          height: _sideContainerSize,
          child: Center(
            child: _scaled(
              DPadWidget(
                size: _dpadSize,
                theme: _theme,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
                onDirectionPressed: widget.onDpadPressed,
                onDirectionReleased: widget.onDpadReleased,
              ),
            ),
          ),
        );

        final Widget faceCluster = SizedBox(
          width: _sideContainerSize,
          height: _sideContainerSize,
          child: Center(
            child: _scaled(
              FaceButtons(
                buttonSize: _faceButtonSize,
                theme: _theme,
                nintendoLayout: widget.nintendoLayout,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
                onButtonPressed: widget.onFaceButtonPressed,
                onButtonReleased: widget.onFaceButtonReleased,
              ),
            ),
          ),
        );

        final Widget leftStick = _scaled(
          AnalogStick(
            size: _analogStickSize,
            knobSize: _analogStickKnobSize,
            theme: _theme,
            deadZone: widget.deadZone,
            hapticsEnabled: widget.hapticFeedback,
            animationsEnabled: widget.animationsEnabled,
            accentColor: widget.southpaw ? _theme.secondary : _theme.primary,
            onDrag: widget.southpaw
                ? widget.onRightStickDrag
                : widget.onLeftStickDrag,
            onDragEnd: widget.southpaw
                ? widget.onRightStickDragEnd
                : widget.onLeftStickDragEnd,
          ),
        );

        final Widget rightStick = _scaled(
          AnalogStick(
            size: _analogStickSize,
            knobSize: _analogStickKnobSize,
            theme: _theme,
            deadZone: widget.deadZone,
            hapticsEnabled: widget.hapticFeedback,
            animationsEnabled: widget.animationsEnabled,
            accentColor: widget.southpaw ? _theme.primary : _theme.secondary,
            onDrag: widget.southpaw
                ? widget.onLeftStickDrag
                : widget.onRightStickDrag,
            onDragEnd: widget.southpaw
                ? widget.onLeftStickDragEnd
                : widget.onRightStickDragEnd,
          ),
        );

        final Widget menuRow = Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _scaled(
              _MenuButton(
                label: 'SELECT',
                size: _menuButtonSize,
                theme: _theme,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
                onPressed: widget.onSelectPressed,
                onReleased: widget.onSelectReleased,
              ),
            ),
            SizedBox(width: 16 * _spacingScale),
            _scaled(
              _MenuButton(
                label: 'START',
                size: _menuButtonSize,
                theme: _theme,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
                onPressed: widget.onStartPressed,
                onReleased: widget.onStartReleased,
              ),
            ),
            SizedBox(width: 16 * _spacingScale),
            _scaled(
              _MenuButton(
                icon: Icons.home_rounded,
                size: _menuButtonSize * 0.9,
                theme: _theme,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
                onPressed: widget.onHomePressed,
                onReleased: widget.onHomeReleased,
                isHome: true,
              ),
            ),
            SizedBox(width: 16 * _spacingScale),
            _scaled(
              _MenuButton(
                label: 'L3',
                size: _menuButtonSize * 0.9,
                theme: _theme,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
                onPressed: widget.onL3Pressed,
                onReleased: widget.onL3Released,
              ),
            ),
            SizedBox(width: 16 * _spacingScale),
            _scaled(
              _MenuButton(
                label: 'R3',
                size: _menuButtonSize * 0.9,
                theme: _theme,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
                onPressed: widget.onR3Pressed,
                onReleased: widget.onR3Released,
              ),
            ),
          ],
        );

        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (widget.showShoulders)
              Positioned(
                top: 0,
                left: edge,
                right: edge,
                child: _buildShoulderButtons(),
              ),
            if (widget.showDpad)
              Positioned(left: edge, top: clusterTop, child: dpad),
            if (widget.showFaceButtons)
              Positioned(right: edge, top: clusterTop, child: faceCluster),
            if (widget.showSticks) ...[
              Positioned(
                left: edge + 30 * s,
                bottom: stickLift,
                child: leftStick,
              ),
              Positioned(
                right: edge + 30 * s,
                bottom: stickLift,
                child: rightStick,
              ),
            ],
            if (widget.showMenu)
              Positioned(bottom: 0, left: 0, right: 0, child: menuRow),
          ],
        );
      },
    );
  }

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
                theme: _theme,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
                onPressed: widget.onLeftTriggerPressed,
                onReleased: widget.onLeftTriggerReleased,
              ),
            ),
            _scaled(
              _TriggerButton(
                width: _triggerButtonWidth,
                height: _triggerButtonHeight,
                theme: _theme,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
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
                theme: _theme,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
                onPressed: widget.onLeftBumperPressed,
                onReleased: widget.onLeftBumperReleased,
              ),
            ),
            _scaled(
              _ShoulderButton(
                label: 'RB',
                width: _shoulderButtonWidth,
                height: _shoulderButtonHeight,
                theme: _theme,
                hapticsEnabled: widget.hapticFeedback,
                animationsEnabled: widget.animationsEnabled,
                onPressed: widget.onRightBumperPressed,
                onReleased: widget.onRightBumperReleased,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Small menu button widget styled by the active [ControllerTheme].
class _MenuButton extends StatefulWidget {
  final String? label;
  final IconData? icon;
  final double size;
  final ControllerTheme theme;
  final bool hapticsEnabled;
  final bool animationsEnabled;
  final VoidCallback? onPressed;
  final VoidCallback? onReleased;
  final bool isHome;

  const _MenuButton({
    this.label,
    this.icon,
    required this.size,
    required this.theme,
    this.hapticsEnabled = false,
    this.animationsEnabled = true,
    this.onPressed,
    this.onReleased,
    this.isHome = false,
  });

  @override
  State<_MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<_MenuButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final accent = widget.isHome ? theme.primary : theme.secondary;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (_isPressed) return;
        setState(() => _isPressed = true);
        if (widget.hapticsEnabled) HapticFeedback.mediumImpact();
        widget.onPressed?.call();
      },
      onPointerUp: (_) {
        if (!_isPressed) return;
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      onPointerCancel: (_) {
        if (!_isPressed) return;
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      child: AnimatedScale(
        scale: _isPressed ? 0.90 : 1.0,
        duration: widget.animationsEnabled
            ? const Duration(milliseconds: 110)
            : Duration.zero,
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: widget.animationsEnabled
              ? const Duration(milliseconds: 120)
              : Duration.zero,
          width: widget.size,
          height: widget.size,
          decoration: theme.chromeDecoration(
            pressed: _isPressed,
            radius: theme.cornerFor(widget.size),
            accent: accent,
          ),
          child: Center(
            child: widget.icon != null
                ? Icon(
                    widget.icon,
                    size: widget.size * 0.5,
                    color: _isPressed
                        ? Colors.white
                        : widget.isHome
                        ? theme.primary
                        : theme.chromeInk(pressed: false),
                  )
                : Text(
                    widget.label ?? '',
                    style: TextStyle(
                      fontSize: widget.size * 0.22,
                      fontWeight: FontWeight.w600,
                      color: theme.chromeInk(pressed: _isPressed),
                      letterSpacing: 0.5,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Shoulder button widget (LB/RB) styled by the active [ControllerTheme].
class _ShoulderButton extends StatefulWidget {
  final String label;
  final double width;
  final double height;
  final ControllerTheme theme;
  final bool hapticsEnabled;
  final bool animationsEnabled;
  final VoidCallback? onPressed;
  final VoidCallback? onReleased;

  const _ShoulderButton({
    required this.label,
    required this.width,
    required this.height,
    required this.theme,
    this.hapticsEnabled = false,
    this.animationsEnabled = true,
    this.onPressed,
    this.onReleased,
  });

  @override
  State<_ShoulderButton> createState() => _ShoulderButtonState();
}

class _ShoulderButtonState extends State<_ShoulderButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (_isPressed) return;
        setState(() => _isPressed = true);
        if (widget.hapticsEnabled) HapticFeedback.mediumImpact();
        widget.onPressed?.call();
      },
      onPointerUp: (_) {
        if (!_isPressed) return;
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      onPointerCancel: (_) {
        if (!_isPressed) return;
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      child: AnimatedScale(
        scale: _isPressed ? 0.90 : 1.0,
        duration: widget.animationsEnabled
            ? const Duration(milliseconds: 110)
            : Duration.zero,
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: widget.animationsEnabled
              ? const Duration(milliseconds: 120)
              : Duration.zero,
          width: widget.width,
          height: widget.height,
          decoration: theme.chromeDecoration(
            pressed: _isPressed,
            radius: theme.cornerFor(widget.height),
            accent: theme.secondary,
          ),
          child: Center(
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 12 * (widget.height / 28),
                fontWeight: FontWeight.w600,
                color: theme.chromeInk(pressed: _isPressed),
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Trigger button widget (LT/RT) — taller and narrower than bumpers, with a
/// curved concave design typical of trigger buttons. Styled by the active
/// [ControllerTheme].
class _TriggerButton extends StatefulWidget {
  final double width;
  final double height;
  final ControllerTheme theme;
  final bool hapticsEnabled;
  final bool animationsEnabled;
  final VoidCallback? onPressed;
  final VoidCallback? onReleased;

  const _TriggerButton({
    required this.width,
    required this.height,
    required this.theme,
    this.hapticsEnabled = false,
    this.animationsEnabled = true,
    this.onPressed,
    this.onReleased,
  });

  @override
  State<_TriggerButton> createState() => _TriggerButtonState();
}

class _TriggerButtonState extends State<_TriggerButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (_isPressed) return;
        setState(() => _isPressed = true);
        if (widget.hapticsEnabled) HapticFeedback.mediumImpact();
        widget.onPressed?.call();
      },
      onPointerUp: (_) {
        if (!_isPressed) return;
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      onPointerCancel: (_) {
        if (!_isPressed) return;
        setState(() => _isPressed = false);
        widget.onReleased?.call();
      },
      child: AnimatedScale(
        scale: _isPressed ? 0.90 : 1.0,
        duration: widget.animationsEnabled
            ? const Duration(milliseconds: 110)
            : Duration.zero,
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: widget.animationsEnabled
              ? const Duration(milliseconds: 120)
              : Duration.zero,
          width: widget.width,
          height: widget.height,
          decoration: theme.chromeDecoration(
            pressed: _isPressed,
            radius: theme.cornerFor(widget.height) * 0.6,
          ),
          child: Center(
            child: Container(
              width: 32 * (widget.width / 56),
              height: 4 * (widget.height / 36),
              decoration: BoxDecoration(
                color: _isPressed
                    ? Colors.white.withValues(alpha: 0.9)
                    : theme.inkColor.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
