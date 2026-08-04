import 'package:flutter_webrtc/flutter_webrtc.dart';

/// One parsed snapshot of the live WebRTC stream, collected every ~500ms from
/// `pc.getStats()`. Mirrors OpenNOW's `collectStats()` + `streamDiagnostics`
/// shape: it carries both the server-side (inbound) video/audio health and the
/// client-side plumbing state (input channels, connection state, renderer).
class StreamStatsSnapshot {
  final DateTime timestamp;

  // --- Client-side state -----------------------------------------------------
  final String? connectionState;
  final bool inputReady;
  final bool reliableInputOpen;
  final bool partiallyReliableInputOpen;
  final bool rendererHasVideo; // renderer.value.renderVideo

  // --- Video inbound-rtp (stream side) ---------------------------------------
  final int framesReceived;
  final int framesDecoded;
  final int framesDropped;
  final int keyFramesDecoded;
  final double decodeFps; // deltas/sec since last poll
  final double receivedFps;
  final double videoBitrateKbps; // deltas/sec since last poll
  final double jitterMs;
  final double jitterBufferDelayMs; // avg per emitted frame
  final double totalDecodeTimeMs; // cumulative
  final double decodeTimePerFrameMs; // avg since last poll
  final int? videoWidth;
  final int? videoHeight;
  final String? codecMime;
  final String? decoderImplementation;
  final int packetsReceived;
  final int packetsLost;
  final double packetLossPercent;
  final int nackCount;

  // --- Audio inbound-rtp (stream side) ---------------------------------------
  final double audioBitrateKbps;
  final double audioJitterMs;
  final int audioPacketsLost;

  // --- Candidate pair / network ----------------------------------------------
  final double rttMs;
  final double availableIncomingBitrateKbps;
  final double availableOutgoingBitrateKbps;

  /// Backlog = frames buffered ahead of the decoder (received - decoded). A
  /// persistently large backlog means the jitter buffer is holding latency.
  int get backlogFrames =>
      framesReceived >= 0 && framesDecoded >= 0
          ? framesReceived - framesDecoded
          : 0;

  // Cumulative counters carried forward so the next poll can compute deltas.
  final int lastVideoBytes;
  final int lastAudioBytes;
  final double lastDecodeTimeSec;

  const StreamStatsSnapshot({
    required this.timestamp,
    this.connectionState,
    this.inputReady = false,
    this.reliableInputOpen = false,
    this.partiallyReliableInputOpen = false,
    this.rendererHasVideo = false,
    this.framesReceived = 0,
    this.framesDecoded = 0,
    this.framesDropped = 0,
    this.keyFramesDecoded = 0,
    this.decodeFps = 0,
    this.receivedFps = 0,
    this.videoBitrateKbps = 0,
    this.jitterMs = 0,
    this.jitterBufferDelayMs = 0,
    this.totalDecodeTimeMs = 0,
    this.decodeTimePerFrameMs = 0,
    this.videoWidth,
    this.videoHeight,
    this.codecMime,
    this.decoderImplementation,
    this.packetsReceived = 0,
    this.packetsLost = 0,
    this.packetLossPercent = 0,
    this.nackCount = 0,
    this.audioBitrateKbps = 0,
    this.audioJitterMs = 0,
    this.audioPacketsLost = 0,
    this.rttMs = 0,
    this.availableIncomingBitrateKbps = 0,
    this.availableOutgoingBitrateKbps = 0,
    this.lastVideoBytes = 0,
    this.lastAudioBytes = 0,
    this.lastDecodeTimeSec = 0,
  });

  /// Parses a raw getStats() report list into a snapshot, using [prev] to
  /// compute deltas (fps/bitrate) across the polling interval.
  factory StreamStatsSnapshot.fromStats(
    List<StatsReport> reports, {
    StreamStatsSnapshot? prev,
    required DateTime timestamp,
    String? connectionState,
    bool inputReady = false,
    bool reliableInputOpen = false,
    bool partiallyReliableInputOpen = false,
    bool rendererHasVideo = false,
  }) {
    Map<dynamic, dynamic>? video;
    Map<dynamic, dynamic>? audio;
    Map<dynamic, dynamic>? activePair;
    final codecs = <String, Map<dynamic, dynamic>>{};

    for (final report in reports) {
      final values = report.values;
      switch (report.type) {
        case 'inbound-rtp':
          final kind = values['kind'] ?? values['mediaType'];
          if (kind == 'video') {
            video = values;
          } else if (kind == 'audio') {
            audio = values;
          }
        case 'candidate-pair':
          if (values['state'] == 'succeeded' && values['nominated'] == true) {
            activePair = values;
          }
        case 'codec':
          codecs[report.id] = values;
      }
    }

    final nowMs = timestamp.millisecondsSinceEpoch;
    final prevMs = prev?.timestamp.millisecondsSinceEpoch;
    final deltaSec =
        (prevMs == null ? 0 : (nowMs - prevMs) / 1000).clamp(0.0, 5.0);

    num? nv(Map<dynamic, dynamic>? m, String key) {
      final raw = m?[key];
      if (raw is num) return raw;
      if (raw is String) return num.tryParse(raw);
      return null;
    }

    // --- Video ---
    final vFramesReceived = nv(video, 'framesReceived')?.toInt() ?? 0;
    final vFramesDecoded = nv(video, 'framesDecoded')?.toInt() ?? 0;
    final vFramesDropped = nv(video, 'framesDropped')?.toInt() ?? 0;
    final vKeyDecoded = nv(video, 'keyFramesDecoded')?.toInt() ?? 0;
    final vBytes = nv(video, 'bytesReceived')?.toInt() ?? 0;
    final vPacketsRecv = nv(video, 'packetsReceived')?.toInt() ?? 0;
    final vPacketsLost = nv(video, 'packetsLost')?.toInt() ?? 0;
    final vJitterMs = (nv(video, 'jitter') ?? 0).toDouble() * 1000;
    final vJbDelaySec = (nv(video, 'jitterBufferDelay') ?? 0).toDouble();
    final vJbEmitted = nv(video, 'jitterBufferEmittedCount')?.toInt() ?? 0;
    final vDecodeSec = (nv(video, 'totalDecodeTime') ?? 0).toDouble();

    final byteDelta = vBytes - (prev?.lastVideoBytes ?? 0);
    final framesDecodedDelta = vFramesDecoded - (prev?.framesDecoded ?? 0);
    final framesReceivedDelta = vFramesReceived - (prev?.framesReceived ?? 0);
    final decodeSecDelta = vDecodeSec - (prev?.lastDecodeTimeSec ?? 0);

    final bitrateKbps =
        deltaSec > 0 ? (byteDelta * 8) / 1000 / deltaSec : 0.0;
    final decodeFps = deltaSec > 0 ? framesDecodedDelta / deltaSec : 0.0;
    final receivedFps = deltaSec > 0 ? framesReceivedDelta / deltaSec : 0.0;
    final decodeTimePerFrame = framesDecodedDelta > 0
        ? (decodeSecDelta * 1000) / framesDecodedDelta
        : 0.0;
    final jitterBufferDelayMs =
        vJbEmitted > 0 ? (vJbDelaySec * 1000) / vJbEmitted : 0.0;

    // codecId is a string reference to a 'codec' report id, NOT a numeric
    // stat — read it raw instead of through the num-coercing nv() helper.
    // codecId and decoderImplementation are string stats (report id reference
    // and decoder name) — read them raw, NOT through the num-coercing nv().
    final rawCodecId = video?['codecId'];
    final codecId = rawCodecId?.toString();
    final codecMime =
        codecId == null ? null : codecs[codecId]?['mimeType'] as String?;
    final rawDecoder = video?['decoderImplementation'];

    // --- Audio ---
    final aBytes = nv(audio, 'bytesReceived')?.toInt() ?? 0;
    final aJitterMs = (nv(audio, 'jitter') ?? 0).toDouble() * 1000;
    final aPacketsLost = nv(audio, 'packetsLost')?.toInt() ?? 0;
    final aByteDelta = aBytes - (prev?.lastAudioBytes ?? 0);
    final audioBitrateKbps =
        deltaSec > 0 ? (aByteDelta * 8) / 1000 / deltaSec : 0.0;

    // --- Candidate pair / RTT ---
    final rttMs = (nv(activePair, 'currentRoundTripTime') ?? 0).toDouble() * 1000;
    final inBps = (nv(activePair, 'availableIncomingBitrate') ?? 0).toDouble();
    final outBps = (nv(activePair, 'availableOutgoingBitrate') ?? 0).toDouble();

    final totalPackets = vPacketsRecv + vPacketsLost;
    final lossPercent =
        totalPackets > 0 ? (vPacketsLost / totalPackets) * 100 : 0.0;

    return StreamStatsSnapshot(
      timestamp: timestamp,
      connectionState: connectionState,
      inputReady: inputReady,
      reliableInputOpen: reliableInputOpen,
      partiallyReliableInputOpen: partiallyReliableInputOpen,
      rendererHasVideo: rendererHasVideo,
      framesReceived: vFramesReceived,
      framesDecoded: vFramesDecoded,
      framesDropped: vFramesDropped,
      keyFramesDecoded: vKeyDecoded,
      decodeFps: decodeFps,
      receivedFps: receivedFps,
      videoBitrateKbps: bitrateKbps,
      jitterMs: vJitterMs,
      jitterBufferDelayMs: jitterBufferDelayMs,
      totalDecodeTimeMs: vDecodeSec * 1000,
      decodeTimePerFrameMs: decodeTimePerFrame,
      videoWidth:
          nv(video, 'frameWidth')?.toInt() ?? nv(video, 'width')?.toInt(),
      videoHeight:
          nv(video, 'frameHeight')?.toInt() ?? nv(video, 'height')?.toInt(),
      codecMime: codecMime,
      decoderImplementation: rawDecoder?.toString(),
      packetsReceived: vPacketsRecv,
      packetsLost: vPacketsLost,
      packetLossPercent: lossPercent,
      nackCount: nv(video, 'nackCount')?.toInt() ?? 0,
      audioBitrateKbps: audioBitrateKbps,
      audioJitterMs: aJitterMs,
      audioPacketsLost: aPacketsLost,
      rttMs: rttMs,
      availableIncomingBitrateKbps: inBps / 1000,
      availableOutgoingBitrateKbps: outBps / 1000,
      lastVideoBytes: vBytes,
      lastAudioBytes: aBytes,
      lastDecodeTimeSec: vDecodeSec,
    );
  }
}

/// Human-readable formatting helpers for the stats overlay.
String fmtKbps(double kbps) {
  if (kbps >= 1000) return '${(kbps / 1000).toStringAsFixed(2)} Mbps';
  if (kbps >= 1) return '${kbps.toStringAsFixed(0)} kbps';
  return '${kbps.toStringAsFixed(1)} kbps';
}

String fmtFps(double fps) => '${fps.toStringAsFixed(1)} fps';
