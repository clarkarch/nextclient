import 'package:flutter_test/flutter_test.dart';

String build({required int fps, required String priority}) {
  final lines = <String>[];
  final isHighFps = fps >= 90;
  final allowRes = priority == 'balanced' || priority == 'fps';
  final fpsFirst = priority == 'fps';
  final minRes = switch (priority) {
    'balanced' => 60,
    'fps' => 40,
    _ => 100,
  };
  final dfc = isHighFps || priority != 'quality';

  lines.add('a=vqos.dynamicStreamingMode:${allowRes ? 1 : 0}');
  if (dfc) {
    lines.add('a=vqos.dfc.enable:1');
    lines.add('a=vqos.dfc.decodeFpsAdjPercent:${fpsFirst ? 95 : 85}');
    lines.add('a=vqos.dfc.adjustResAndFps:${allowRes ? 1 : 0}');
  } else {
    lines.add('a=vqos.dfc.enable:0');
  }
  lines.add('a=vqos.resControl.cpmRtc.featureMask:${allowRes ? 1 : 0}');
  lines.add('a=vqos.resControl.cpmRtc.enable:${allowRes ? 1 : 0}');
  lines.add('a=vqos.resControl.cpmRtc.minResolutionPercent:$minRes');
  lines.add(
      'a=vqos.resControl.cpmRtc.resolutionChangeHoldonMs:${allowRes ? 5000 : 999999}');
  return lines.join('\n');
}

void main() {
  test('quality preserves the original no-adaptation profile', () {
    final sdp = build(fps: 60, priority: 'quality');
    expect(sdp, contains('a=vqos.dynamicStreamingMode:0'));
    expect(sdp, contains('a=vqos.dfc.enable:0'));
    expect(sdp, contains('a=vqos.resControl.cpmRtc.featureMask:0'));
    expect(sdp, contains('a=vqos.resControl.cpmRtc.minResolutionPercent:100'));
    expect(sdp, contains('a=vqos.resControl.cpmRtc.resolutionChangeHoldonMs:999999'));
  });

  test('balanced enables resolution scaling with mid floor', () {
    final sdp = build(fps: 60, priority: 'balanced');
    expect(sdp, contains('a=vqos.dynamicStreamingMode:1'));
    expect(sdp, contains('a=vqos.dfc.enable:1'));
    expect(sdp, contains('a=vqos.dfc.adjustResAndFps:1'));
    expect(sdp, contains('a=vqos.resControl.cpmRtc.minResolutionPercent:60'));
  });

  test('fps holds frame rate and scales resolution down first', () {
    final sdp = build(fps: 60, priority: 'fps');
    expect(sdp, contains('a=vqos.dynamicStreamingMode:1'));
    expect(sdp, contains('a=vqos.dfc.decodeFpsAdjPercent:95'));
    expect(sdp, contains('a=vqos.resControl.cpmRtc.minResolutionPercent:40'));
  });
}
