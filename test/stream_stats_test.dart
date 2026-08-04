import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:next_client/state/stream_stats.dart';

StatsReport _report(String id, String type, Map<String, dynamic> values) {
  return StatsReport(
    id,
    type,
    0,
    {
      'id': id,
      'type': type,
      'timestamp': 0,
      ...values,
    },
  );
}

List<StatsReport> _sampleReports({
  required int bytesReceived,
  required int framesReceived,
  required int framesDecoded,
  required int framesDropped,
  required int packetsLost,
  required int packetsReceived,
  double jitter = 0.008,
  double jitterBufferDelay = 0.4,
  int jitterBufferEmittedCount = 40,
  double totalDecodeTime = 0.8,
  double rtt = 0.012,
  double availableIncomingBitrate = 60_000_000,
  String? codecId = 'codec1',
  int audioBytesReceived = 100_000,
}) {
  return [
    _report('codec1', 'codec', {'mimeType': 'video/H264'}),
    _report(
      'video-in',
      'inbound-rtp',
      {
        'kind': 'video',
        'mediaType': 'video',
        'framesReceived': framesReceived,
        'framesDecoded': framesDecoded,
        'framesDropped': framesDropped,
        'keyFramesDecoded': 2,
        'bytesReceived': bytesReceived,
        'packetsReceived': packetsReceived,
        'packetsLost': packetsLost,
        'jitter': jitter,
        'jitterBufferDelay': jitterBufferDelay,
        'jitterBufferEmittedCount': jitterBufferEmittedCount,
        'totalDecodeTime': totalDecodeTime,
        'frameWidth': 1920,
        'frameHeight': 1080,
        'codecId': codecId,
        'decoderImplementation': 'FFmpegVideoDecoder',
      },
    ),
    _report(
      'audio-in',
      'inbound-rtp',
      {
        'kind': 'audio',
        'mediaType': 'audio',
        'bytesReceived': audioBytesReceived,
        'packetsLost': 1,
        'jitter': 0.004,
      },
    ),
    _report(
      'pair',
      'candidate-pair',
      {
        'state': 'succeeded',
        'nominated': true,
        'currentRoundTripTime': rtt,
        'availableIncomingBitrate': availableIncomingBitrate,
        'availableOutgoingBitrate': 5_000_000,
      },
    ),
  ];
}

void main() {
  group('StreamStatsSnapshot.fromStats', () {
    test('parses absolute counters and per-poll deltas', () {
      final t0 = DateTime(2026, 1, 1);
      final t1 = t0.add(const Duration(milliseconds: 500));

      final prev = StreamStatsSnapshot.fromStats(
        _sampleReports(
          bytesReceived: 1_000_000,
          framesReceived: 100,
          framesDecoded: 90,
          framesDropped: 2,
          packetsLost: 3,
          packetsReceived: 1000,
          totalDecodeTime: 0.5,
          audioBytesReceived: 50_000,
        ),
        prev: null,
        timestamp: t0,
      );

      // Second poll: +5 MB in 500ms → 80 Mbps; +30 decoded frames → 60 fps.
      final snap = StreamStatsSnapshot.fromStats(
        _sampleReports(
          bytesReceived: 6_000_000,
          framesReceived: 130,
          framesDecoded: 120,
          framesDropped: 5,
          packetsLost: 5,
          packetsReceived: 2000,
          totalDecodeTime: 0.8,
          audioBytesReceived: 100_000,
        ),
        prev: prev,
        timestamp: t1,
        connectionState: 'connected',
        inputReady: true,
        reliableInputOpen: true,
      );

      expect(snap.videoBitrateKbps, closeTo(80_000, 1));
      expect(snap.decodeFps, closeTo(60, 0.1));
      expect(snap.receivedFps, closeTo(60, 0.1));
      expect(snap.framesDecoded, 120);
      expect(snap.backlogFrames, 10);
      expect(snap.jitterMs, closeTo(8, 0.1));
      expect(snap.jitterBufferDelayMs, closeTo(10, 0.1)); // 0.4s/40
      // totalDecodeTime grew 0.3s over 30 decoded frames → 10ms/frame.
      expect(snap.decodeTimePerFrameMs, closeTo(10, 0.1));
      // Audio: 50KB delta over 500ms → 800 kbps.
      expect(snap.audioBitrateKbps, closeTo(800, 1));
      expect(snap.videoWidth, 1920);
      expect(snap.videoHeight, 1080);
      expect(snap.codecMime, 'video/H264');
      expect(snap.decoderImplementation, 'FFmpegVideoDecoder');
      expect(snap.rttMs, closeTo(12, 0.1));
      expect(snap.availableIncomingBitrateKbps, closeTo(60_000, 1));
      expect(snap.connectionState, 'connected');
      expect(snap.inputReady, isTrue);
      expect(snap.reliableInputOpen, isTrue);
      expect(snap.packetLossPercent, closeTo(5 / 2005 * 100, 0.01));
    });

    test('audio deltas and formats', () {
      final t0 = DateTime(2026, 1, 1);
      final t1 = t0.add(const Duration(milliseconds: 500));
      final prev = StreamStatsSnapshot.fromStats(
        _sampleReports(
          bytesReceived: 0,
          framesReceived: 0,
          framesDecoded: 0,
          framesDropped: 0,
          packetsLost: 0,
          packetsReceived: 0,
          audioBytesReceived: 0,
        ),
        prev: null,
        timestamp: t0,
      );
      final snap = StreamStatsSnapshot.fromStats(
        _sampleReports(
          bytesReceived: 0,
          framesReceived: 0,
          framesDecoded: 0,
          framesDropped: 0,
          packetsLost: 0,
          packetsReceived: 0,
          audioBytesReceived: 100_000,
        ),
        prev: prev,
        timestamp: t1,
      );
      // Audio: 100KB delta over 500ms → 1.6 Mbps.
      expect(snap.audioBitrateKbps, closeTo(1600, 1));
      expect(snap.audioJitterMs, closeTo(4, 0.1));
      expect(snap.audioPacketsLost, 1);
    });

    test('handles empty reports without crashing', () {
      final snap = StreamStatsSnapshot.fromStats(
        [],
        prev: null,
        timestamp: DateTime(2026, 1, 1),
      );
      expect(snap.framesDecoded, 0);
      expect(snap.videoBitrateKbps, 0);
      expect(snap.backlogFrames, 0);
      expect(snap.rttMs, 0);
    });
  });

  group('formatters', () {
    test('fmtKbps and fmtFps', () {
      expect(fmtKbps(500), '500 kbps');
      expect(fmtKbps(50_000), '50.00 Mbps');
      expect(fmtFps(59.94), '59.9 fps');
    });
  });
}
