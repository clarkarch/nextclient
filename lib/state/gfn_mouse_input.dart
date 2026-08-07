import 'dart:math' show min, max, sqrt;

/// Mouse input shaping — port of OpenNOW's `webrtc/mouseInput.ts` plus the
/// sensitivity/acceleration curve from `domInputCaptureController.ts`.
///
/// Three layers, applied in order on the stream surface before a delta is
/// sent to the transport:
///  1. Sensitivity multiplier + optional software acceleration (user knobs).
///  2. Sub-pixel residual accumulation so micro-movements under 1 px are not
///     silently dropped by integer quantization.
///  3. Adaptive coalescing: deltas are batched on a timer whose interval
///     tightens toward ~2 ms under low SCTP pressure and relaxes toward
///     20 ms under backpressure — the exact policy OpenNOW uses to keep the
///     reliable input channel from flooding (a flood *is* input lag).

/// Applies the user's sensitivity multiplier, then optional software
/// acceleration (OpenNOW's gentle curve: low-speed precision, high-speed
/// turn boost, capped at +60% at 150%).
({double dx, double dy}) applyMouseTransform(
  double dx,
  double dy, {
  required double sensitivity,
  required int accelerationPercent,
}) {
  var adjustedDx = dx * sensitivity;
  var adjustedDy = dy * sensitivity;
  if (accelerationPercent > 1) {
    final speed = sqrt(adjustedDx * adjustedDx + adjustedDy * adjustedDy);
    final strength = (accelerationPercent - 1) / 149;
    final accelFactor = 1 + min(0.6 * strength, (speed / 50) * strength);
    adjustedDx *= accelFactor;
    adjustedDy *= accelFactor;
  }
  return (dx: adjustedDx, dy: adjustedDy);
}

/// Port of OpenNOW's `quantizeMouseDeltaWithResidual`: folds [delta] into the
/// carried [residual] and sends only the integer part, keeping the fraction
/// for the next event. A stream of 0.4 px moves eventually sends 1 px instead
/// of dropping every event (Dart rounds halves away from zero, matching JS).
({int send, double residual}) quantizeMouseDeltaWithResidual(
  double delta,
  double residual,
) {
  final accumulated = residual + delta;
  final send = accumulated.round();
  return (send: send, residual: accumulated - send);
}

/// Port of OpenNOW's `chooseAdaptiveMouseFlushInterval`.
///
/// - Partially-reliable mouse rides the PR channel and keeps a fixed base
///   interval (no backoff — the reliable keyboard channel's pressure doesn't
///   affect it).
/// - Reliable mouse: back off +2 ms under SCTP backpressure (buffered bytes
///   at/over half the threshold), tighten −1 ms under low pressure, otherwise
///   drift one step toward the base interval.
///
/// OpenNOW also passes a scheduling-delay term; Flutter has no equivalent
/// telemetry, so the pressure decision is buffered-bytes-only.
int chooseAdaptiveMouseFlushInterval({
  required int baseIntervalMs,
  required int currentIntervalMs,
  required int reliableBufferedAmount,
  required bool canUsePartiallyReliableMouse,
  required int backpressureThresholdBytes,
  required int minIntervalMs,
  required int maxIntervalMs,
}) {
  final boundedBase = min(max(baseIntervalMs, minIntervalMs), maxIntervalMs);
  final boundedCurrent =
      min(max(currentIntervalMs, minIntervalMs), maxIntervalMs);

  if (canUsePartiallyReliableMouse) return boundedBase;

  final highPressure = reliableBufferedAmount >= backpressureThresholdBytes ~/ 2;
  if (highPressure) {
    return max(boundedBase, min(maxIntervalMs, boundedCurrent + 2));
  }

  final lowPressure = reliableBufferedAmount <= 4096;
  if (lowPressure) {
    return max(minIntervalMs, boundedCurrent - 1);
  }

  if (boundedCurrent > boundedBase) {
    return max(boundedBase, boundedCurrent - 1);
  }
  if (boundedCurrent < boundedBase) {
    return min(boundedBase, boundedCurrent + 1);
  }
  return boundedCurrent;
}
