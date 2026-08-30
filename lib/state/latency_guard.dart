import 'stream_stats.dart';

enum LatencyGuardState { ok, active, triggered }

/// One evaluation of the live stream by [LatencyGuard].
class LatencyGuardVerdict {
  final LatencyGuardState state;
  final String reason;
  final int backlogFrames;
  final double jitterBufferDelayMs;

  /// True while an episode (detected buildup until recovery) is ongoing.
  final bool episodeActive;

  const LatencyGuardVerdict({
    required this.state,
    this.reason = '',
    this.backlogFrames = 0,
    this.jitterBufferDelayMs = 0,
    this.episodeActive = false,
  });
}

/// Detects monotonic latency buildup during long sessions and reports when a
/// corrective action (keyframe resync) should fire.
///
/// Buildup mechanisms: sender/receiver clock drift (oscillators skew by
/// 20-100 ppm -> tens of ms per 10 minutes), adaptive jitter buffers that grow
/// quickly under network jitter but shrink very slowly, and stall residue
/// (frames buffered during a hiccup are played out late instead of dropped).
/// All of them show up the same way in getStats(): the `framesReceived -
/// framesDecoded` backlog and/or the average jitter-buffer delay creeping up
/// and staying up.
class LatencyGuard {
  LatencyGuard({this.enabled = true});

  /// Master switch ([UserSettings.latencyGuardEnabled]).
  bool enabled;

  /// Backlog above this many frames counts as "behind live".
  static const double backlogThreshold = 3;

  /// Consecutive hot polls before firing (~3 s at the 1 s poll rate).
  static const int triggerSamples = 3;

  /// Rolling window of jitter-buffer delay samples (~24 s of polls).
  static const int jbWindow = 24;

  /// Newest-half vs oldest-half growth ratio treated as buildup.
  static const double jbGrowthRatio = 1.4;

  /// Minimum absolute rise (ms) so tiny-value noise can't trip the ratio.
  static const double jbGrowthFloorMs = 4;

  /// Instantaneous per-frame jitter-buffer delay above this fires correction
  /// immediately (burst arrival / decoder stall) instead of waiting for the
  /// rolling-window growth check.
  static const double jbAbsoluteCapMs = 100;

  /// Cool polls required to close an episode after it opened.
  static const int recoverySamples = 6;

  final List<double> _jbHistory = [];
  int _backlogStrikes = 0;
  int _okStreak = 0;
  bool _episodeActive = false;

  void reset() {
    _jbHistory.clear();
    _backlogStrikes = 0;
    _okStreak = 0;
    _episodeActive = false;
  }

  /// Feeds one snapshot and returns the current verdict. [LatencyGuardState.
  /// triggered] fires exactly once per episode; use [callers] should send the
  /// correction then and treat [LatencyGuardState.active] as "still behind".
  LatencyGuardVerdict update(StreamStatsSnapshot s) {
    if (!enabled || !s.rendererHasVideo || s.receivedFps <= 0) {
      reset();
      return const LatencyGuardVerdict(state: LatencyGuardState.ok);
    }

    var reason = '';
    var hot = false;

    if (s.backlogFrames >= backlogThreshold) {
      _backlogStrikes++;
    } else {
      _backlogStrikes = 0;
    }
    if (_backlogStrikes >= triggerSamples) {
      hot = true;
      reason = 'decoder backlog ${s.backlogFrames}f';
    }

    _jbHistory.add(s.jitterBufferDelayMs);
    while (_jbHistory.length > jbWindow) {
      _jbHistory.removeAt(0);
    }
    if (!hot && s.jitterBufferDelayMs >= jbAbsoluteCapMs) {
      // Instantaneous spike (burst arrival / decoder stall): react on the
      // next poll rather than waiting for the slow rolling-window evidence.
      hot = true;
      reason =
          'jitter buffer spike ${s.jitterBufferDelayMs.toStringAsFixed(0)}ms';
    }
    if (!hot && _jbHistory.length == jbWindow) {
      final half = jbWindow ~/ 2;
      final oldMean = _avg(_jbHistory.sublist(0, half));
      final newMean = _avg(_jbHistory.sublist(half));
      if (newMean > oldMean * jbGrowthRatio &&
          newMean - oldMean >= jbGrowthFloorMs) {
        hot = true;
        reason =
            'jitter buffer ${oldMean.toStringAsFixed(0)}->'
            '${newMean.toStringAsFixed(0)}ms';
      }
    }

    if (hot) {
      _okStreak = 0;
      final fire = !_episodeActive;
      _episodeActive = true;
      return LatencyGuardVerdict(
        state: fire ? LatencyGuardState.triggered : LatencyGuardState.active,
        reason: reason,
        backlogFrames: s.backlogFrames,
        jitterBufferDelayMs: s.jitterBufferDelayMs,
        episodeActive: true,
      );
    }

    if (_episodeActive && ++_okStreak >= recoverySamples) {
      _episodeActive = false;
    }
    return LatencyGuardVerdict(
      state: LatencyGuardState.ok,
      backlogFrames: s.backlogFrames,
      jitterBufferDelayMs: s.jitterBufferDelayMs,
      episodeActive: _episodeActive,
    );
  }

  static double _avg(List<double> values) {
    if (values.isEmpty) return 0;
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }
}
