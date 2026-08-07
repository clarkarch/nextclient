import 'package:flutter_test/flutter_test.dart';
import 'package:next_client/state/gfn_mouse_input.dart';

void main() {
  group('applyMouseTransform', () {
    test('identity at 1.0 sensitivity and acceleration off (1)', () {
      final r = applyMouseTransform(
        10,
        -4,
        sensitivity: 1.0,
        accelerationPercent: 1,
      );
      expect(r.dx, closeTo(10, 1e-9));
      expect(r.dy, closeTo(-4, 1e-9));
    });

    test('sensitivity scales linearly', () {
      final r = applyMouseTransform(
        10,
        5,
        sensitivity: 2.0,
        accelerationPercent: 1,
      );
      expect(r.dx, closeTo(20, 1e-9));
      expect(r.dy, closeTo(10, 1e-9));
    });

    test('acceleration boosts fast deltas more than slow ones (capped +60%)',
        () {
      final slow = applyMouseTransform(
        2,
        0,
        sensitivity: 1.0,
        accelerationPercent: 150,
      );
      final fast = applyMouseTransform(
        50,
        0,
        sensitivity: 1.0,
        accelerationPercent: 150,
      );
      expect(fast.dx / 50, greaterThan(slow.dx / 2));

      final capped = applyMouseTransform(
        500,
        0,
        sensitivity: 1.0,
        accelerationPercent: 150,
      );
      expect(capped.dx / 500, closeTo(1.6, 0.001));
    });
  });

  group('quantizeMouseDeltaWithResidual', () {
    test('sub-pixel deltas accumulate into a sent pixel', () {
      var residual = 0.0;
      var sent = 0;
      for (var i = 0; i < 3; i++) {
        final q = quantizeMouseDeltaWithResidual(0.4, residual);
        sent += q.send;
        residual = q.residual;
      }
      expect(sent, 1);
      expect(residual, closeTo(0.2, 1e-9));
    });

    test('rounds halves away from zero and carries the fraction', () {
      final q = quantizeMouseDeltaWithResidual(1.5, 0);
      expect(q.send, 2);
      expect(q.residual, closeTo(-0.5, 1e-9));
    });

    test('negative deltas accumulate symmetrically', () {
      var residual = 0.0;
      var sent = 0;
      for (var i = 0; i < 3; i++) {
        final q = quantizeMouseDeltaWithResidual(-0.4, residual);
        sent += q.send;
        residual = q.residual;
      }
      expect(sent, -1);
      expect(residual, closeTo(-0.2, 1e-9));
    });
  });

  group('chooseAdaptiveMouseFlushInterval', () {
    test('keeps the base interval when partially-reliable mouse is active', () {
      final interval = chooseAdaptiveMouseFlushInterval(
        baseIntervalMs: 8,
        currentIntervalMs: 20,
        reliableBufferedAmount: 48 * 1024,
        canUsePartiallyReliableMouse: true,
        backpressureThresholdBytes: 64 * 1024,
        minIntervalMs: 2,
        maxIntervalMs: 20,
      );
      expect(interval, 8);
    });

    test('tightens under low pressure and relaxes under pressure on reliable',
        () {
      final lowPressure = chooseAdaptiveMouseFlushInterval(
        baseIntervalMs: 8,
        currentIntervalMs: 8,
        reliableBufferedAmount: 1024,
        canUsePartiallyReliableMouse: false,
        backpressureThresholdBytes: 64 * 1024,
        minIntervalMs: 2,
        maxIntervalMs: 20,
      );
      expect(lowPressure, 7);

      final highPressure = chooseAdaptiveMouseFlushInterval(
        baseIntervalMs: 8,
        currentIntervalMs: 7,
        reliableBufferedAmount: 48 * 1024,
        canUsePartiallyReliableMouse: false,
        backpressureThresholdBytes: 64 * 1024,
        minIntervalMs: 2,
        maxIntervalMs: 20,
      );
      expect(highPressure, 9);
    });

    test('bounds to the min/max window', () {
      final tight = chooseAdaptiveMouseFlushInterval(
        baseIntervalMs: 2,
        currentIntervalMs: 3,
        reliableBufferedAmount: 0,
        canUsePartiallyReliableMouse: false,
        backpressureThresholdBytes: 64 * 1024,
        minIntervalMs: 2,
        maxIntervalMs: 20,
      );
      expect(tight, 2);

      final loose = chooseAdaptiveMouseFlushInterval(
        baseIntervalMs: 20,
        currentIntervalMs: 19,
        reliableBufferedAmount: 64 * 1024,
        canUsePartiallyReliableMouse: false,
        backpressureThresholdBytes: 64 * 1024,
        minIntervalMs: 2,
        maxIntervalMs: 20,
      );
      expect(loose, 20);
    });
  });
}
