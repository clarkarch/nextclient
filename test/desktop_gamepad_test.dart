import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:next_client/state/desktop_gamepad.dart';
import 'package:next_client/state/gfn_input_protocol.dart';

void main() {
  group('applyRadialDeadzone', () {
    test('center and inside the 15% circle read zero', () {
      expect(applyRadialDeadzone(0, 0), (0, 0));
      expect(applyRadialDeadzone(0.1, 0), (0, 0));
      expect(applyRadialDeadzone(0.1, 0.1), (0, 0)); // magnitude ≈ 0.141
    });

    test('full deflection is preserved at the rim', () {
      expect(applyRadialDeadzone(1, 0), (1, 0));
      expect(applyRadialDeadzone(-1, 0), (-1, 0));
    });

    test('values outside the deadzone are rescaled', () {
      final (x, y) = applyRadialDeadzone(0.5, 0);
      expect(x, closeTo((0.5 - 0.15) / (1 - 0.15), 1e-9));
      expect(y, 0);
    });

    test('direction is preserved for diagonal pushes', () {
      final (x, y) = applyRadialDeadzone(0.3, 0.4);
      final magnitude = 0.5;
      final scale = (0.5 - 0.15) / (1 - 0.15);
      expect(x, closeTo(0.3 / magnitude * scale, 1e-9));
      expect(y, closeTo(0.4 / magnitude * scale, 1e-9));
    });
  });

  group('mapNormalizedGamepad', () {
    NormalizedGamepadState state() => NormalizedGamepadState();

    test('face buttons map to XInput flags', () {
      final s = state()
        ..buttons[GamepadButton.a] = true
        ..buttons[GamepadButton.b] = true
        ..buttons[GamepadButton.x] = true
        ..buttons[GamepadButton.y] = true
        ..buttons[GamepadButton.leftBumper] = true
        ..buttons[GamepadButton.rightBumper] = true
        ..buttons[GamepadButton.back] = true
        ..buttons[GamepadButton.start] = true
        ..buttons[GamepadButton.home] = true
        ..buttons[GamepadButton.leftStick] = true
        ..buttons[GamepadButton.rightStick] = true
        ..buttons[GamepadButton.dpadUp] = true
        ..buttons[GamepadButton.dpadDown] = true
        ..buttons[GamepadButton.dpadLeft] = true
        ..buttons[GamepadButton.dpadRight] = true;
      final g = mapNormalizedGamepad(s);
      expect(
        g.buttons,
        gamepadA |
            gamepadB |
            gamepadX |
            gamepadY |
            gamepadLb |
            gamepadRb |
            gamepadBack |
            gamepadStart |
            gamepadGuide |
            gamepadLs |
            gamepadRs |
            gamepadDpadUp |
            gamepadDpadDown |
            gamepadDpadLeft |
            gamepadDpadRight,
      );
    });

    test('an unpressed pad sends zero state', () {
      final g = mapNormalizedGamepad(state());
      expect(g.buttons, 0);
      expect(g.lx, 0);
      expect(g.ly, 0);
      expect(g.rx, 0);
      expect(g.ry, 0);
      expect(g.lt, 0);
      expect(g.rt, 0);
    });

    test('stick Y is negated to the up=-1 source convention', () {
      final up = mapNormalizedGamepad(state()..axes[GamepadAxis.leftStickY] = 1);
      expect(up.ly, closeTo(-1, 1e-9));
      final down = mapNormalizedGamepad(state()..axes[GamepadAxis.leftStickY] = -1);
      expect(down.ly, closeTo(1, 1e-9));
    });

    test('sticks get a radial deadzone applied', () {
      final g = mapNormalizedGamepad(
        state()
          ..axes[GamepadAxis.leftStickX] = 0.1
          ..axes[GamepadAxis.leftStickY] = 0.1, // magnitude ≈ 0.141
      );
      expect(g.lx, 0);
      expect(g.ly, 0);
    });

    test('analog triggers map 0..1 directly', () {
      final g = mapNormalizedGamepad(
        state()
          ..axes[GamepadAxis.leftTrigger] = 0.5
          ..axes[GamepadAxis.rightTrigger] = 1,
      );
      expect(g.lt, closeTo(0.5, 1e-9));
      expect(g.rt, closeTo(1, 1e-9));
    });

    test('digital trigger buttons fall back when no analog axis exists', () {
      final g = mapNormalizedGamepad(
        state()
          ..buttons[GamepadButton.leftTrigger] = true
          ..buttons[GamepadButton.rightTrigger] = true,
      );
      expect(g.lt, 1);
      expect(g.rt, 1);
    });
  });
}