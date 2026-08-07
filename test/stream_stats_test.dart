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
  double totalDecodeTime = 800,
  int pliCount = 2,
  int firCount = 0,
  int freezeCount = 1,
  double totalFreezesDuration = 150,
  double totalProcessingDelay = 600,
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
        'totalProcessingDelay': totalProcessingDelay,
        'pliCount': pliCount,
        'firCount': firCount,
        'freezeCount': freezeCount,
        'totalFreezesDuration': totalFreezesDuration,
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
          totalDecodeTime: 500,
          totalProcessingDelay: 300,
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
          totalDecodeTime: 800,
          totalProcessingDelay: 600,
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
      // totalDecodeTime grew 300 ms over 30 decoded frames → 10ms/frame
      // (the raw stat is ms, NOT seconds — treating it as seconds would
      // report 10000ms/frame here).
      expect(snap.decodeTimePerFrameMs, closeTo(10, 0.1));
      // Processing delay (decode + queue wait) follows the same ms units.
      expect(snap.processingDelayPerFrameMs, closeTo(10, 0.1));
      expect(snap.totalDecodeTimeMs, closeTo(800, 0.1));
      expect(snap.pliCount, 2);
      expect(snap.firCount, 0);
      expect(snap.freezeCount, 1);
      expect(snap.totalFreezesDurationMs, closeTo(150, 0.1));
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

    test('zeroes rates for sub-100ms poll windows (impossible fps guard)', () {
      // Two polls 1ms apart with a 30-frame burst used to fabricate
      // ~30000 fps (a real session showed receive fps max 1095.7 on a
      // 60 fps stream). Sub-100ms windows must yield 0 rates while still
      // carrying the cumulative counters.
      final t0 = DateTime(2026, 1, 1);
      final t1 = t0.add(const Duration(milliseconds: 1));

      final prev = StreamStatsSnapshot.fromStats(
        _sampleReports(
          bytesReceived: 1_000_000,
          framesReceived: 100,
          framesDecoded: 90,
          framesDropped: 2,
          packetsLost: 3,
          packetsReceived: 1000,
        ),
        prev: null,
        timestamp: t0,
      );
      final snap = StreamStatsSnapshot.fromStats(
        _sampleReports(
          bytesReceived: 1_500_000,
          framesReceived: 130,
          framesDecoded: 120,
          framesDropped: 5,
          packetsLost: 5,
          packetsReceived: 2000,
        ),
        prev: prev,
        timestamp: t1,
      );

      expect(snap.decodeFps, 0);
      expect(snap.receivedFps, 0);
      expect(snap.videoBitrateKbps, 0);
      expect(snap.audioBitrateKbps, 0);
      // Cumulative counters still advance for the report.
      expect(snap.framesDecoded, 120);
      expect(snap.framesReceived, 130);
    });

    test('caps rates at 240 fps / 200 Mbps (counter-reset artifact)', () {
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
      // A counter that jumped forward (e.g. a mid-session decoder recreation
      // summed into the poll) must be clamped, not reported raw.
      final snap = StreamStatsSnapshot.fromStats(
        _sampleReports(
          bytesReceived: 500_000_000, // huge byte jump
          framesReceived: 50_000,
          framesDecoded: 50_000,
          framesDropped: 0,
          packetsLost: 0,
          packetsReceived: 50_000,
          audioBytesReceived: 20_000_000,
        ),
        prev: prev,
        timestamp: t1,
      );

      expect(snap.decodeFps, 240);
      expect(snap.receivedFps, 240);
      expect(snap.videoBitrateKbps, 200_000);
      expect(snap.audioBitrateKbps, 200_000);
    });
  });

  group('formatters', () {
    test('fmtKbps and fmtFps', () {
      expect(fmtKbps(500), '500 kbps');
      expect(fmtKbps(50_000), '50.00 Mbps');
      expect(fmtFps(59.94), '59.9 fps');
    });
  });

  group('StreamStatsSummary', () {
    StreamStatsSnapshot makeSnap({
      DateTime? timestamp,
      double decodeFps = 30,
      double receivedFps = 60,
      double decodeTimePerFrameMs = 5,
      double totalDecodeTimeMs = 5000,
      double jitterMs = 8,
      double jitterBufferDelayMs = 12,
      double rttMs = 12,
      double packetLossPercent = 0.5,
      int framesReceived = 1300,
      double videoBitrateKbps = 40_000,
      int framesDecoded = 1200,
      int framesDropped = 10,
      int keyFramesDecoded = 40,
      int packetsLost = 4,
      int packetsReceived = 2000,
      int nackCount = 3,
      int pliCount = 0,
      int firCount = 0,
      int freezeCount = 0,
      double totalFreezesDurationMs = 0,
      double processingDelayPerFrameMs = 0,
      double audioBitrateKbps = 160,
      double audioJitterMs = 4,
      int audioPacketsLost = 1,
      double availableIncomingBitrateKbps = 60_000,
      double availableOutgoingBitrateKbps = 5000,
      String? connectionState,
      bool inputReady = false,
      bool reliableInputOpen = false,
      bool partiallyReliableInputOpen = false,
      bool rendererHasVideo = false,
    }) {
      return StreamStatsSnapshot(
        timestamp: timestamp ?? DateTime(2026, 1, 1),
        connectionState: connectionState,
        inputReady: inputReady,
        reliableInputOpen: reliableInputOpen,
        partiallyReliableInputOpen: partiallyReliableInputOpen,
        rendererHasVideo: rendererHasVideo,
        decodeFps: decodeFps,
        receivedFps: receivedFps,
        decodeTimePerFrameMs: decodeTimePerFrameMs,
        totalDecodeTimeMs: totalDecodeTimeMs,
        jitterMs: jitterMs,
        jitterBufferDelayMs: jitterBufferDelayMs,
        rttMs: rttMs,
        packetLossPercent: packetLossPercent,
        videoBitrateKbps: videoBitrateKbps,
        framesDecoded: framesDecoded,
        framesReceived: framesReceived,
        framesDropped: framesDropped,
        keyFramesDecoded: keyFramesDecoded,
        packetsLost: packetsLost,
        packetsReceived: packetsReceived,
        nackCount: nackCount,
        pliCount: pliCount,
        firCount: firCount,
        freezeCount: freezeCount,
        totalFreezesDurationMs: totalFreezesDurationMs,
        processingDelayPerFrameMs: processingDelayPerFrameMs,
        audioBitrateKbps: audioBitrateKbps,
        audioJitterMs: audioJitterMs,
        audioPacketsLost: audioPacketsLost,
        availableIncomingBitrateKbps: availableIncomingBitrateKbps,
        availableOutgoingBitrateKbps: availableOutgoingBitrateKbps,
        codecMime: 'video/H264',
        decoderImplementation: 'FFmpegVideoDecoder',
        videoWidth: 1920,
        videoHeight: 1080,
      );
    }

    test('averages decode fps over active polls, skipping idle ones', () {
      final summary = StreamStatsSummary()
        ..add(makeSnap(decodeFps: 30))
        ..add(makeSnap(decodeFps: 0)) // idle poll — must not skew the average
        ..add(makeSnap(decodeFps: 60));

      expect(summary.samples, 3);
      expect(summary.activeSamples, 2);
      expect(summary.avgDecodeFps, closeTo(45, 0.001));
      expect(summary.decodeFpsMin, closeTo(30, 0.001));
      expect(summary.decodeFpsMax, closeTo(60, 0.001));
      // avg bitrate still counts every poll.
      expect(summary.avgBitrateKbps, closeTo(40_000, 1));
    });

    test('tracks decode time, jitter, rtt, loss and backlog extremes', () {
      final summary = StreamStatsSummary()
        ..add(makeSnap(decodeTimePerFrameMs: 5, jitterMs: 8, rttMs: 12,
            packetLossPercent: 0.5, framesReceived: 103, framesDecoded: 100))
        ..add(makeSnap(decodeTimePerFrameMs: 5000, jitterMs: 21, rttMs: 48,
            packetLossPercent: 2.1, framesReceived: 114, framesDecoded: 100));

      expect(summary.avgDecodeTimePerFrameMs, closeTo(2502.5, 0.001));
      expect(summary.decodeMsMax, closeTo(5000, 0.001));
      expect(summary.avgJitterMs, closeTo(14.5, 0.001));
      expect(summary.jitterMsMax, closeTo(21, 0.001));
      expect(summary.avgRttMs, closeTo(30, 0.001));
      expect(summary.rttMsMax, closeTo(48, 0.001));
      expect(summary.packetLossMax, closeTo(2.1, 0.001));
      expect(summary.backlogMax, 14);
    });

    test('keeps first-seen codec/decoder/resolution and latest snapshot', () {
      final summary = StreamStatsSummary()
        ..add(makeSnap())
        ..add(makeSnap(videoBitrateKbps: 50_000, framesDecoded: 2400));

      expect(summary.codecMime, 'video/H264');
      expect(summary.decoderImplementation, 'FFmpegVideoDecoder');
      expect(summary.videoWidth, 1920);
      expect(summary.videoHeight, 1080);
      expect(summary.latest?.framesDecoded, 2400);
    });

    test('ui fps rollup ignores non-positive samples', () {
      final summary = StreamStatsSummary()
        ..setUiFps(0)
        ..setUiFps(12)
        ..setUiFps(20);

      expect(summary.uiFpsSamples, 2);
      expect(summary.avgUiFps, closeTo(16, 0.001));
      expect(summary.uiFpsMin, closeTo(12, 0.001));
      expect(summary.uiFpsMax, closeTo(20, 0.001));
    });

    test('report string carries the key health fields', () {
      final summary = StreamStatsSummary()
        ..add(makeSnap())
        ..setUiFps(15);
      final report = summary.toReportString();

      expect(report, contains('1 stats polls'));
      expect(report, contains('codec        video/H264'));
      expect(report, contains('ui fps'));
      expect(report, contains('decode fps'));
      expect(report, contains('decode/frame'));
      expect(report, contains('backlog'));
      expect(report, contains('1200 decoded'));
      // The report must survive the log-sink redaction pass untouched.
      expect(report, isNot(contains('[IP REDACTED]')));
      expect(report, isNot(contains('[UUID REDACTED]')));
    });

    test('report includes every stream health section', () {
      final summary = StreamStatsSummary()
        ..add(makeSnap(
          connectionState: 'connected',
          inputReady: true,
          reliableInputOpen: true,
          partiallyReliableInputOpen: true,
          rendererHasVideo: true,
        ))
        ..setUiFps(15);
      final report = summary.toReportString();

      expect(report, contains('connection   connected'));
      expect(report, contains('input        ready'));
      expect(report, contains('reliable ch  open'));
      expect(report, contains('partial ch   open'));
      expect(report, contains('1920x1080 · active'));
      expect(report, contains('receive fps'));
      expect(report, contains('decode total 5000.0 ms'));
      expect(report, contains('jb delay'));
      expect(report, contains('packets      lost 4/2000'));
      expect(report, contains('nack max 3'));
      expect(report, contains('audio'));
      expect(report, contains('in avail'));
      expect(report, contains('out avail'));
    });

    test('reports duration and lag from the live receive rate', () {
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      final summary = StreamStatsSummary()
        ..add(makeSnap(timestamp: t0, framesReceived: 100, framesDecoded: 20))
        ..add(makeSnap(
          timestamp: t0.add(const Duration(seconds: 10)),
          framesReceived: 700,
          framesDecoded: 24, // backlog 676; latest receivedFps = 60 fps
        ));
      final report = summary.toReportString();
      expect(report, contains('duration     10.0 s'));
      expect(report, contains('lag          ~11.3s')); // 676 / 60
    });

    test('lag falls back to the max receive rate when the last poll stalled', () {
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      final summary = StreamStatsSummary()
        ..add(makeSnap(
          timestamp: t0,
          receivedFps: 30,
          framesReceived: 100,
          framesDecoded: 20,
        ))
        ..add(makeSnap(
          timestamp: t0.add(const Duration(seconds: 10)),
          receivedFps: 0, // stalled at exit — the laggy case
          framesReceived: 700,
          framesDecoded: 24, // backlog 676; best rate seen was 30 fps
        ));
      final report = summary.toReportString();
      expect(report, contains('lag          ~22.5s')); // 676 / 30
    });

    test('tracks recovery + freeze stats and annotates decode behind', () {
      final summary = StreamStatsSummary()
        ..add(makeSnap(
          pliCount: 4,
          firCount: 1,
          freezeCount: 2,
          totalFreezesDurationMs: 240,
          processingDelayPerFrameMs: 40,
          decodeFps: 30,
          receivedFps: 60,
        ))
        ..add(makeSnap(
          pliCount: 4,
          firCount: 1,
          freezeCount: 2,
          totalFreezesDurationMs: 240,
          processingDelayPerFrameMs: 60,
          decodeFps: 35,
          receivedFps: 62,
        ));
      final report = summary.toReportString();

      expect(report, contains('pli/fir     max 4 / 1'));
      expect(report, contains('freeze      max 2 events · 240.0 ms total'));
      expect(report, contains('proc delay  avg 50.0 ms  max 60.0 ms'));
      // Decode 35 fps < receive 62 fps + 100-frame backlog → the report must
      // call out that the decode/frame row is queue-inflated, not GPU time.
      expect(report, contains('queue note'));
    });

    test('no queue note when the backlog is empty (healthy jitter)', () {
      // decode briefly below receive with zero backlog is normal polling
      // jitter — it must not print a scary queue-wait note.
      final summary = StreamStatsSummary()
        ..add(makeSnap(
          decodeFps: 58,
          receivedFps: 61,
          framesReceived: 1200,
          framesDecoded: 1200, // backlog 0
        ));
      expect(summary.toReportString(), isNot(contains('queue note')));
    });

    test('empty summary reports zero polls and no crash', () {
      final report = StreamStatsSummary().toReportString();
      expect(report, contains('0 stats polls'));
      expect(report, contains('—'));
    });
  });
}
