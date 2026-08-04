import 'package:flutter_test/flutter_test.dart';

/// Mirrors the gating logic in `webrtc_stream_session.dart` + `user_settings.dart`:
/// the experimental presets only apply when the master toggle is on.
StreamPriorityGate build({required bool enabled, required String selected}) {
  final priority = enabled ? selected : 'quality';
  final allowRes = priority == 'balanced' || priority == 'fps';
  final fpsFirst = priority == 'fps';
  final minRes = switch (priority) {
    'balanced' => 60,
    'fps' => 40,
    _ => 100,
  };
  return StreamPriorityGate(
    dynamicStreamingMode: allowRes ? 1 : 0,
    dfcEnabled: priority != 'quality',
    decodeFpsAdjPercent: fpsFirst ? 95 : 85,
    minResolutionPercent: minRes,
    cpmEnabled: allowRes ? 1 : 0,
  );
}

class StreamPriorityGate {
  final int dynamicStreamingMode;
  final bool dfcEnabled;
  final int decodeFpsAdjPercent;
  final int minResolutionPercent;
  final int cpmEnabled;

  const StreamPriorityGate({
    required this.dynamicStreamingMode,
    required this.dfcEnabled,
    required this.decodeFpsAdjPercent,
    required this.minResolutionPercent,
    required this.cpmEnabled,
  });
}

void main() {
  test('disabled toggle forces the safe quality profile regardless of choice',
      () {
    // Even if the user previously picked "fps", the toggle-off state must
    // produce the OpenNOW-matching defaults.
    for (final choice in ['quality', 'balanced', 'fps']) {
      final gate = build(enabled: false, selected: choice);
      expect(gate.dynamicStreamingMode, 0,
          reason: 'choice=$choice must not scale resolution');
      expect(gate.dfcEnabled, isFalse,
          reason: 'choice=$choice must not drop decode FPS');
      expect(gate.minResolutionPercent, 100);
      expect(gate.cpmEnabled, 0);
    }
  });

  test('enabled toggle applies the selected preset', () {
    expect(build(enabled: true, selected: 'quality').dfcEnabled, isFalse);
    expect(build(enabled: true, selected: 'balanced').dynamicStreamingMode, 1);
    expect(build(enabled: true, selected: 'balanced').minResolutionPercent, 60);
    expect(build(enabled: true, selected: 'fps').decodeFpsAdjPercent, 95);
    expect(build(enabled: true, selected: 'fps').minResolutionPercent, 40);
  });
}
