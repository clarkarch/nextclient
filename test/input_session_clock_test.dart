import 'package:flutter_test/flutter_test.dart';
import 'package:next_client/state/gfn_input_protocol.dart';

void main() {
  group('InputSessionClock', () {
    test('is monotonic and starts near zero', () async {
      final clock = InputSessionClock();
      clock.start();
      // Stopwatch begins ticking immediately, so expect ~0 (well under 1ms).
      expect(clock.captureTimestampUs(), lessThan(1000));

      // Let some time pass; the clock must only move forward.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final a = clock.captureTimestampUs();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final b = clock.captureTimestampUs();
      expect(a, greaterThan(0));
      expect(b, greaterThanOrEqualTo(a));
    });

    test('reset starts a fresh timeline', () async {
      final clock = InputSessionClock();
      clock.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(clock.captureTimestampUs(), greaterThan(0));

      clock.start(); // handshake reset
      expect(clock.captureTimestampUs(), lessThan(1000));
    });

    test('does not go backwards', () {
      final clock = InputSessionClock();
      clock.start();
      final t1 = clock.captureTimestampUs();
      // Successive reads must never move backwards (a wall-clock jump like
      // an NTP sync can't affect the stopwatch).
      for (var i = 0; i < 10; i++) {
        final t2 = clock.captureTimestampUs();
        expect(t2, greaterThanOrEqualTo(t1));
      }
    });
  });
}
