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
  final double processingDelayPerFrameMs; // avg since last poll (decode + queue)
  final int? videoWidth;
  final int? videoHeight;
  final String? codecMime;
  final String? decoderImplementation;
  final int packetsReceived;
  final int packetsLost;
  final double packetLossPercent;
  final int nackCount;
  final int pliCount; // keyframe requests sent to the server
  final int firCount;
  final int freezeCount;
  final double totalFreezesDurationMs; // cumulative

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
  final double lastDecodeTimeMs;
  final double lastProcessingDelayMs;

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
    this.processingDelayPerFrameMs = 0,
    this.videoWidth,
    this.videoHeight,
    this.codecMime,
    this.decoderImplementation,
    this.packetsReceived = 0,
    this.packetsLost = 0,
    this.packetLossPercent = 0,
    this.nackCount = 0,
    this.pliCount = 0,
    this.firCount = 0,
    this.freezeCount = 0,
    this.totalFreezesDurationMs = 0,
    this.audioBitrateKbps = 0,
    this.audioJitterMs = 0,
    this.audioPacketsLost = 0,
    this.rttMs = 0,
    this.availableIncomingBitrateKbps = 0,
    this.availableOutgoingBitrateKbps = 0,
    this.lastVideoBytes = 0,
    this.lastAudioBytes = 0,
    this.lastDecodeTimeMs = 0,
    this.lastProcessingDelayMs = 0,
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
    // A poll window shorter than this is dominated by scheduling noise (timer
    // jitter, getStats latency, back-to-back polls after an in-flight skip) —
    // the delta counters haven't advanced proportionally, so a tiny window can
    // fabricate impossible rates (a 1ms window with a 30-frame burst reads as
    // 30000 fps; a real session showed receive fps max 1095.7 on a 60 fps
    // stream). Treat such polls as "no window": keep the cumulative counters,
    // zero the rate fields.
    final elapsedMs = prevMs == null ? null : (nowMs - prevMs);
    final deltaSec = elapsedMs == null || elapsedMs < 100
        ? 0.0
        : (elapsedMs / 1000).clamp(0.0, 5.0);

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
    // NOTE on units: the flutter_webrtc fork reports totalDecodeTime in
    // MILLISECONDS (libwebrtc's internal VideoReceiveStats::total_decode_time
    // passes through unnormalized), not the spec's seconds. Treating it as
    // seconds inflated every decode/frame row by 1000× (a 27 s session showed
    // "7203 ms/frame" and ~80 minutes of decode total). totalProcessingDelay
    // and totalFreezesDuration follow the same ms convention.
    final vDecodeMs = (nv(video, 'totalDecodeTime') ?? 0).toDouble();
    final vProcessingMs = (nv(video, 'totalProcessingDelay') ?? 0).toDouble();
    final vFreezeMs = (nv(video, 'totalFreezesDuration') ?? 0).toDouble();
    final vPli = nv(video, 'pliCount')?.toInt() ?? 0;
    final vFir = nv(video, 'firCount')?.toInt() ?? 0;
    final vFreeze = nv(video, 'freezeCount')?.toInt() ?? 0;

    final byteDelta = vBytes - (prev?.lastVideoBytes ?? 0);
    final framesDecodedDelta = vFramesDecoded - (prev?.framesDecoded ?? 0);
    final framesReceivedDelta = vFramesReceived - (prev?.framesReceived ?? 0);
    final decodeMsDelta = vDecodeMs - (prev?.lastDecodeTimeMs ?? 0);
    final processingMsDelta = vProcessingMs - (prev?.lastProcessingDelayMs ?? 0);

    // Rate ceilings: a GFN session tops out at 240 fps; anything above is a
    // counter-reset artifact (negative deltas clamp to 0; absurd positives
    // clamp to the ceiling). Matches the FFI transports' 0-240 clamp.
    // Bitrate cap: 200000 kbps = 200 Mbps, a sanity ceiling far above any
    // GFN rate (max ~75-120 Mbps) so a byte-counter reset can't print a
    // 8 Gbps "bitrate" row.
    final bitrateKbps = deltaSec > 0 && byteDelta > 0
        ? ((byteDelta * 8) / 1000 / deltaSec).clamp(0.0, 200000.0)
        : 0.0;
    final decodeFps = deltaSec > 0 && framesDecodedDelta > 0
        ? (framesDecodedDelta / deltaSec).clamp(0.0, 240.0)
        : 0.0;
    final receivedFps = deltaSec > 0 && framesReceivedDelta > 0
        ? (framesReceivedDelta / deltaSec).clamp(0.0, 240.0)
        : 0.0;
    // Negative deltas mean the decoder was recreated mid-session (its
    // cumulative timers reset) — clamp so a restart can't poison averages.
    final decodeTimePerFrame = framesDecodedDelta > 0 && decodeMsDelta >= 0
        ? decodeMsDelta / framesDecodedDelta
        : 0.0;
    final processingDelayPerFrame =
        framesDecodedDelta > 0 && processingMsDelta >= 0
        ? processingMsDelta / framesDecodedDelta
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
    final audioBitrateKbps = deltaSec > 0 && aByteDelta > 0
        ? ((aByteDelta * 8) / 1000 / deltaSec).clamp(0.0, 200000.0)
        : 0.0;

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
      totalDecodeTimeMs: vDecodeMs,
      decodeTimePerFrameMs: decodeTimePerFrame,
      processingDelayPerFrameMs: processingDelayPerFrame,
      pliCount: vPli,
      firCount: vFir,
      freezeCount: vFreeze,
      totalFreezesDurationMs: vFreezeMs,
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
      lastDecodeTimeMs: vDecodeMs,
      lastProcessingDelayMs: vProcessingMs,
    );
  }
}

/// Rolling session-wide summary of stream health, aggregated from every stats
/// poll: decode/receive FPS and times, jitter, jitter-buffer delay, RTT, loss,
/// backlog, bitrates (video/audio/available), NACKs, plus the latest
/// client-side plumbing state (connection, input channels, renderer). The
/// stream page records [toReportString] into the logs when the user exits so a
/// laggy session (high decode ms, low FPS) can be reviewed after the stream is
/// gone.
class StreamStatsSummary {
  /// Total stats polls received.
  int samples = 0;

  /// Polls where frames were actually decoded. Idle polls (decodeFps == 0,
  /// e.g. loading screens) are skipped when averaging decode fps / decode time
  /// so the averages reflect real playback, not menus.
  int activeSamples = 0;
  double _decodeFpsSum = 0;
  double _decodeMsSum = 0;
  double decodeFpsMin = double.infinity;
  double decodeFpsMax = 0;
  double decodeMsMax = 0;

  /// Polls where frames were actually received (receivedFps > 0).
  int recvSamples = 0;
  double _receivedFpsSum = 0;
  double receivedFpsMin = double.infinity;
  double receivedFpsMax = 0;

  double _jitterSum = 0;
  double jitterMsMax = 0;
  double _jitterBufferDelaySum = 0;
  double jitterBufferDelayMax = 0;
  double _rttSum = 0;
  double rttMsMax = 0;
  double packetLossMax = 0;
  int backlogMax = 0;
  double _bitrateSum = 0;
  int nackMax = 0;

  /// Keyframe/decoder-recovery + freeze stats (WebRTC counters, cumulative —
  /// max is the session total).
  int pliMax = 0;
  int firMax = 0;
  int freezeMax = 0;

  /// Processing delay per frame (decode + queue wait) — the honest signal for
  /// "is the decoder keeping up": it tracks the backlog, so a session where
  /// decode fps < receive fps shows it climbing into the seconds.
  int processingSamples = 0;
  double _processingDelaySum = 0;
  double processingDelayMsMax = 0;

  double _audioBitrateSum = 0;
  double _audioJitterSum = 0;
  double audioJitterMsMax = 0;
  int audioPacketsLostMax = 0;

  double _inBitrateSum = 0;
  double inBitrateMax = 0;
  double _outBitrateSum = 0;
  double outBitrateMax = 0;

  /// Flutter-side (UI) frame rate as measured by the stats overlay's Ticker.
  /// Only populated while the stats overlay is enabled.
  int uiFpsSamples = 0;
  double _uiFpsSum = 0;
  double uiFpsMin = double.infinity;
  double uiFpsMax = 0;

  // Latest client-side plumbing state (connection/input/renderer).
  String? connectionState;
  bool inputReady = false;
  bool reliableInputOpen = false;
  bool partiallyReliableInputOpen = false;
  bool rendererHasVideo = false;

  // First-seen values (decoder/codec/resolution are stable over a session).
  String? codecMime;
  String? decoderImplementation;
  int? videoWidth;
  int? videoHeight;

  /// Most recent snapshot (carries the cumulative frame/packet counters).
  StreamStatsSnapshot? latest;

  /// First snapshot seen — together with [latest] gives the session duration.
  DateTime? _first;

  /// Wall-clock duration between the first and last stats poll.
  double? get durationSeconds {
    final l = latest;
    final f = _first;
    if (l == null || f == null) return null;
    return l.timestamp.difference(f).inMilliseconds / 1000;
  }

  double get avgDecodeFps => activeSamples > 0 ? _decodeFpsSum / activeSamples : 0;
  double get avgDecodeTimePerFrameMs =>
      activeSamples > 0 ? _decodeMsSum / activeSamples : 0;
  double get avgReceivedFps =>
      recvSamples > 0 ? _receivedFpsSum / recvSamples : 0;
  double get avgJitterMs => samples > 0 ? _jitterSum / samples : 0;
  double get avgJitterBufferDelayMs =>
      samples > 0 ? _jitterBufferDelaySum / samples : 0;
  double get avgRttMs => samples > 0 ? _rttSum / samples : 0;
  double get avgBitrateKbps => samples > 0 ? _bitrateSum / samples : 0;
  double get avgAudioBitrateKbps => samples > 0 ? _audioBitrateSum / samples : 0;
  double get avgAudioJitterMs => samples > 0 ? _audioJitterSum / samples : 0;
  double get avgInBitrateKbps => samples > 0 ? _inBitrateSum / samples : 0;
  double get avgOutBitrateKbps => samples > 0 ? _outBitrateSum / samples : 0;
  double get avgUiFps => uiFpsSamples > 0 ? _uiFpsSum / uiFpsSamples : 0;
  double get avgProcessingDelayMs =>
      processingSamples > 0 ? _processingDelaySum / processingSamples : 0;

  /// Merges one stats poll into the rollup. Idle polls (decodeFps == 0) only
  /// update the counters that are still meaningful (network, backlog, totals).
  void add(StreamStatsSnapshot s) {
    latest = s;
    _first ??= s.timestamp;
    samples++;
    connectionState = s.connectionState;
    inputReady = s.inputReady;
    reliableInputOpen = s.reliableInputOpen;
    partiallyReliableInputOpen = s.partiallyReliableInputOpen;
    rendererHasVideo = s.rendererHasVideo;
    _jitterSum += s.jitterMs;
    if (s.jitterMs > jitterMsMax) jitterMsMax = s.jitterMs;
    _jitterBufferDelaySum += s.jitterBufferDelayMs;
    if (s.jitterBufferDelayMs > jitterBufferDelayMax) {
      jitterBufferDelayMax = s.jitterBufferDelayMs;
    }
    _rttSum += s.rttMs;
    if (s.rttMs > rttMsMax) rttMsMax = s.rttMs;
    if (s.packetLossPercent > packetLossMax) {
      packetLossMax = s.packetLossPercent;
    }
    if (s.backlogFrames > backlogMax) backlogMax = s.backlogFrames;
    if (s.nackCount > nackMax) nackMax = s.nackCount;
    if (s.pliCount > pliMax) pliMax = s.pliCount;
    if (s.firCount > firMax) firMax = s.firCount;
    if (s.freezeCount > freezeMax) freezeMax = s.freezeCount;
    if (s.processingDelayPerFrameMs > 0) {
      processingSamples++;
      _processingDelaySum += s.processingDelayPerFrameMs;
      if (s.processingDelayPerFrameMs > processingDelayMsMax) {
        processingDelayMsMax = s.processingDelayPerFrameMs;
      }
    }
    // Bitrate intentionally averages every poll — idle polls (0 kbps) are real
    // network behavior, so they're kept, unlike decode FPS which skips them.
    _bitrateSum += s.videoBitrateKbps;
    _audioBitrateSum += s.audioBitrateKbps;
    _audioJitterSum += s.audioJitterMs;
    if (s.audioJitterMs > audioJitterMsMax) {
      audioJitterMsMax = s.audioJitterMs;
    }
    if (s.audioPacketsLost > audioPacketsLostMax) {
      audioPacketsLostMax = s.audioPacketsLost;
    }
    _inBitrateSum += s.availableIncomingBitrateKbps;
    if (s.availableIncomingBitrateKbps > inBitrateMax) {
      inBitrateMax = s.availableIncomingBitrateKbps;
    }
    _outBitrateSum += s.availableOutgoingBitrateKbps;
    if (s.availableOutgoingBitrateKbps > outBitrateMax) {
      outBitrateMax = s.availableOutgoingBitrateKbps;
    }
    codecMime ??= s.codecMime;
    decoderImplementation ??= s.decoderImplementation;
    videoWidth ??= s.videoWidth;
    videoHeight ??= s.videoHeight;
    if (s.receivedFps > 0) {
      recvSamples++;
      _receivedFpsSum += s.receivedFps;
      if (s.receivedFps < receivedFpsMin) receivedFpsMin = s.receivedFps;
      if (s.receivedFps > receivedFpsMax) receivedFpsMax = s.receivedFps;
    }
    if (s.decodeFps <= 0) return;
    activeSamples++;
    _decodeFpsSum += s.decodeFps;
    if (s.decodeFps < decodeFpsMin) decodeFpsMin = s.decodeFps;
    if (s.decodeFps > decodeFpsMax) decodeFpsMax = s.decodeFps;
    _decodeMsSum += s.decodeTimePerFrameMs;
    if (s.decodeTimePerFrameMs > decodeMsMax) decodeMsMax = s.decodeTimePerFrameMs;
  }

  /// Records a UI-fps sample from the stats overlay Ticker.
  void setUiFps(double fps) {
    if (fps <= 0) return;
    uiFpsSamples++;
    _uiFpsSum += fps;
    if (fps < uiFpsMin) uiFpsMin = fps;
    if (fps > uiFpsMax) uiFpsMax = fps;
  }

  /// Estimated playback lag from the decode backlog: frames received but not
  /// yet decoded, divided by the session's sustained receive rate. A growing
  /// backlog is the real "super laggy" signal — much more reliable than the
  /// per-frame decode time, which the custom VAAPI decoder inflates with
  /// pipeline queue time.
  String _lagLine() {
    final l = latest;
    final dur = durationSeconds;
    if (l == null || dur == null || dur <= 0 || l.framesReceived <= 0) {
      return '—';
    }
    // Prefer the instantaneous receive rate (last poll), then the best rate
    // seen — a session that idled on loading screens would otherwise
    // understate the rate and overstate the lag. Fall back to the sustained
    // session rate only if neither is available.
    final recvFps = l.receivedFps > 0
        ? l.receivedFps
        : receivedFpsMax > 0
        ? receivedFpsMax
        : l.framesReceived / dur;
    if (recvFps <= 0) return '—';
    final secs = l.backlogFrames / recvFps;
    return '~${secs.toStringAsFixed(1)}s buffered '
        '(${l.backlogFrames} frames @ ${recvFps.toStringAsFixed(1)} fps recv)';
  }

  /// Compact multi-line report for the end-of-stream log entry. Surfaces every
  /// field of [StreamSnapshot]: client plumbing (connection/input/renderer),
  /// video decode+receive, audio, and network — with min/avg/max where
  /// meaningful and latest for the cumulative counters.
  String toReportString() {
    final l = latest;
    final active = activeSamples > 0;
    final recv = recvSamples > 0;
    final dur = durationSeconds;
    String ms(double v) => '${v.toStringAsFixed(1)} ms';
    final b = StringBuffer('$samples stats polls\n');
    b.writeln(
        'duration     ${dur != null ? '${dur.toStringAsFixed(1)} s' : '—'}');
    if (l != null) {
      b.writeln('codec        ${l.codecMime ?? '—'}');
      b.writeln('decoder      ${l.decoderImplementation ?? '—'}');
      b.writeln('resolution   ${l.videoWidth ?? '?'}x${l.videoHeight ?? '?'}');
    }
    if (uiFpsSamples > 0) {
      b.writeln('ui fps       avg ${fmtFps(avgUiFps)}  '
          'min ${fmtFps(uiFpsMin)}  max ${fmtFps(uiFpsMax)}');
    }
    b.writeln('connection   ${connectionState ?? '—'}');
    b.writeln('input        ${inputReady ? 'ready' : 'idle'}');
    b.writeln('reliable ch  ${reliableInputOpen ? 'open' : 'closed'}');
    b.writeln('partial ch   ${partiallyReliableInputOpen ? 'open' : 'closed'}');
    if (l != null) {
      b.writeln(
          'renderer     ${l.videoWidth ?? '?'}x${l.videoHeight ?? '?'}'
          '${rendererHasVideo ? ' · active' : ' · waiting'}');
    } else {
      b.writeln('renderer     —');
    }
    b.writeln('decode fps   avg ${active ? fmtFps(avgDecodeFps) : '—'}  '
        'min ${active ? fmtFps(decodeFpsMin) : '—'}  '
        'max ${active ? fmtFps(decodeFpsMax) : '—'}  '
        'latest ${fmtFps(l?.decodeFps ?? 0)}');
    b.writeln('receive fps  avg ${recv ? fmtFps(avgReceivedFps) : '—'}  '
        'min ${recv ? fmtFps(receivedFpsMin) : '—'}  '
        'max ${recv ? fmtFps(receivedFpsMax) : '—'}  '
        'latest ${fmtFps(l?.receivedFps ?? 0)}');
    b.writeln('decode/frame avg ${active ? ms(avgDecodeTimePerFrameMs) : '—'}  '
        'max ${active ? ms(decodeMsMax) : '—'}  '
        'latest ${l != null ? ms(l.decodeTimePerFrameMs) : '—'}');
    b.writeln('decode total ${l != null ? ms(l.totalDecodeTimeMs) : '—'}');
    if (processingSamples > 0) {
      b.writeln('proc delay  avg ${ms(avgProcessingDelayMs)}  '
          'max ${ms(processingDelayMsMax)}');
    }
    b.writeln('video bitrate avg ${fmtKbps(avgBitrateKbps)}');
    b.writeln('jitter       avg ${ms(avgJitterMs)}  max ${ms(jitterMsMax)}');
    b.writeln(
        'jb delay     avg ${ms(avgJitterBufferDelayMs)}  '
        'max ${ms(jitterBufferDelayMax)}');
    b.writeln('rtt          avg ${ms(avgRttMs)}  max ${ms(rttMsMax)}');
    b.writeln('loss         max ${packetLossMax.toStringAsFixed(2)}%');
    b.writeln('backlog      max $backlogMax frames');
    b.writeln('lag          ${_lagLine()}');
    // Only claim queue inflation when frames are ACTUALLY backed up — an
    // instantaneous decode<receive on a healthy session (polling jitter,
    // backlog ~0) is normal and must not print a scary note.
    if (l != null && l.backlogFrames > 0 && l.receivedFps > 0 &&
        l.decodeFps < l.receivedFps) {
      b.writeln('queue note  decode ${fmtFps(l.decodeFps)} < receive '
          '${fmtFps(l.receivedFps)} fps with $backlogMax-frame backlog — '
          'decode/frame & proc delay include pipeline queue wait, not just '
          'GPU time');
    }
    if (l != null) {
      final pct = l.framesReceived > 0
          ? ' (${(l.framesDecoded / l.framesReceived * 100).toStringAsFixed(1)}% decoded)'
          : '';
      b.writeln('frames       ${l.framesDecoded} decoded / ${l.framesReceived} '
          'received / ${l.framesDropped} dropped (${l.keyFramesDecoded} key)'
          '$pct');
      b.writeln('packets      lost ${l.packetsLost}/${l.packetsReceived} '
          '(latest)  nack max $nackMax');
      b.writeln('pli/fir     max $pliMax / $firMax');
      b.writeln('freeze      max $freezeMax events'
          '${l.totalFreezesDurationMs > 0 ? ' · ${ms(l.totalFreezesDurationMs)} total' : ''}');
    }
    if (samples > 0) {
      b.writeln('audio        bitrate avg ${fmtKbps(avgAudioBitrateKbps)}  '
          'jitter avg ${ms(avgAudioJitterMs)}  max ${ms(audioJitterMsMax)}  '
          'lost max $audioPacketsLostMax');
      b.writeln('in avail     avg ${fmtKbps(avgInBitrateKbps)}  '
          'max ${fmtKbps(inBitrateMax)}');
      b.writeln('out avail    avg ${fmtKbps(avgOutBitrateKbps)}  '
          'max ${fmtKbps(outBitrateMax)}');
    }
    return b.toString();
  }
}

/// Human-readable formatting helpers for the stats overlay.
String fmtKbps(double kbps) {
  if (kbps >= 1000) return '${(kbps / 1000).toStringAsFixed(2)} Mbps';
  if (kbps >= 1) return '${kbps.toStringAsFixed(0)} kbps';
  return '${kbps.toStringAsFixed(1)} kbps';
}

String fmtFps(double fps) => '${fps.toStringAsFixed(1)} fps';
