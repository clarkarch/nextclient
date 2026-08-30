import 'dart:math' show max, min;

import 'package:gfn_core/gfn_core.dart';

import 'user_settings.dart' show StreamPriority, StreamRecoveryProfile;

/// Shared NVST SDP helpers used by every [StreamTransport] implementation.
///
/// These are ports of OpenNOW's `sdp/{ice,codec,answer,nvstOffer}.ts`. The
/// libwebrtc session and the GStreamer webrtcbin FFI transport both build the
/// offer-munging, answer-munging, and nvstSdp capability blob from this single
/// implementation so the negotiated profile never drifts between backends.
class GfnSdpMunger {
  // ---------------------------------------------------------------------
  // Codec / resolution helpers
  // ---------------------------------------------------------------------

  static String codecWireName(VideoCodec codec) => switch (codec) {
    VideoCodec.h264 => 'H264',
    VideoCodec.h265 => 'H265',
    VideoCodec.av1 => 'AV1',
  };

  static String normalizeCodec(String name) {
    final upper = name.toUpperCase();
    return upper == 'HEVC' ? 'H265' : upper;
  }

  static (int, int) parseResolution(String resolution) {
    final parts = resolution.split('x');
    final width = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
    final height = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
    if (width <= 0 || height <= 0) return (1920, 1080);
    return (width, height);
  }

  // ---------------------------------------------------------------------
  // ri.* input capability attributes (echoed into nvstSdp)
  // ---------------------------------------------------------------------

  static RiInputCapabilities parseRiInputCapabilities(String sdp) {
    int? threshold() {
      final match = RegExp(
        r'a=ri\.partialReliableThresholdMs:(\d+)',
        caseSensitive: false,
      ).firstMatch(sdp);
      if (match == null) return null;
      final parsed = int.tryParse(match.group(1) ?? '') ?? 0;
      if (parsed <= 0) return null;
      return max(1, min(5000, parsed));
    }

    int attr(String name, int fallback) {
      final match = RegExp(
        'a=${RegExp.escape(name)}:([^\\r\\n]+)',
        caseSensitive: false,
      ).firstMatch(sdp);
      final raw = match?.group(1)?.trim();
      if (raw == null) return fallback;
      final normalized = raw.toLowerCase();
      final parsed = normalized.startsWith('0x')
          ? int.tryParse(normalized.substring(2), radix: 16)
          : int.tryParse(normalized);
      return parsed ?? fallback;
    }

    return RiInputCapabilities(
      partialReliableThresholdMs: threshold() ??
          _defaultPartialReliableThresholdMs,
      hidDeviceMask: attr('ri.hidDeviceMask', _partiallyReliableHidMaskAll),
      enablePartiallyReliableTransferGamepad: attr(
        'ri.enablePartiallyReliableTransferGamepad',
        _partiallyReliableGamepadMaskAll,
      ),
      enablePartiallyReliableTransferHid: attr(
        'ri.enablePartiallyReliableTransferHid',
        _partiallyReliableHidMaskAll,
      ),
    );
  }

  static const int _defaultPartialReliableThresholdMs = 300;
  static const int _partiallyReliableGamepadMaskAll = (1 << 4) - 1;
  static const int _partiallyReliableHidMaskAll = 0xFFFFFFFF;

  // ---------------------------------------------------------------------
  // Server-IP + codec offer filtering
  // ---------------------------------------------------------------------

  /// Extract a server-IP hint from a dash-separated GFN hostname, e.g.
  /// "80-250-97-40.cloudmatchbeta.nvidiagrid.net" -> "80.250.97.40".
  static String? extractPublicIp(String hostOrIp) {
    if (hostOrIp.isEmpty) return null;
    if (RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(hostOrIp)) {
      return hostOrIp;
    }
    final firstLabel = hostOrIp.split('.').first;
    final parts = firstLabel.split('-');
    if (parts.length == 4 &&
        parts.every((p) => RegExp(r'^\d{1,3}$').hasMatch(p))) {
      return parts.join('.');
    }
    return null;
  }

  /// Rewrite 0.0.0.0 addresses (c= lines and ICE candidates) with the actual
  /// server IP. Port of OpenNOW's fix_server_ip() which fixes both the
  /// `c=IN IP4 0.0.0.0` line and any a=candidate endpoints.
  static String fixServerIp(String sdp, String serverIp) {
    final ip = extractPublicIp(serverIp);
    if (ip == null) return sdp;
    var result = sdp.replaceAll('c=IN IP4 0.0.0.0', 'c=IN IP4 $ip');
    final re = RegExp(
      r'(a=candidate:\S+\s+\d+\s+\w+\s+\d+\s+)0\.0\.0\.0(\s+)',
    );
    if (re.allMatches(result).isNotEmpty) {
      result = result.replaceAllMapped(
        re,
        (m) => '${m.group(1)}$ip${m.group(2)}',
      );
    }
    return result;
  }

  /// Rewrite every a=candidate endpoint to a fixed ip:port. Port of OpenNOW's
  /// rewrite_sdp_ice_candidate_endpoints() — used when CloudMatch hands us a
  /// media connection ip/port so webrtcbin dials the right media server.
  static String rewriteIceCandidateEndpoints(
    String sdp,
    String ip,
    int port,
  ) {
    final ip2 = ip.trim();
    if (ip2.isEmpty || port <= 0) return sdp;
    final lineEnding = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(RegExp(r'\r?\n'));
    final rewritten = lines.map((line) {
      if (!line.startsWith('a=candidate:')) return line;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 6) return line;
      if (parts[4] == ip2 && parts[5] == '$port') return line;
      parts[4] = ip2;
      parts[5] = '$port';
      return parts.join(' ');
    }).join(lineEnding);
    return rewritten;
  }

  /// GFN puts ice-ufrag/ice-pwd/fingerprint/setup at SESSION level; GStreamer's
  /// webrtcbin expects them per-media. Duplicate the session-level transport
  /// attributes into every media section. Port of OpenNOW's
  /// duplicate_session_webrtc_attributes_to_media().
  static String duplicateSessionWebrtcAttributesToMedia(String sdp) {
    final lineEnding = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(RegExp(r'\r?\n'));
    final firstMediaIndex = lines.indexWhere((l) => l.startsWith('m='));
    if (firstMediaIndex < 0) return sdp;

    bool isTransport(String l) =>
        l.startsWith('a=ice-ufrag:') ||
        l.startsWith('a=ice-pwd:') ||
        l.startsWith('a=ice-options:') ||
        l.startsWith('a=fingerprint:') ||
        l.startsWith('a=setup:');

    final sessionAttrs = lines
        .take(firstMediaIndex)
        .where(isTransport)
        .toList();
    if (sessionAttrs.isEmpty) return sdp;

    final output = <String>[
      ...lines.take(firstMediaIndex).where((l) => !isTransport(l)),
    ];

    var index = firstMediaIndex;
    while (index < lines.length) {
      final sectionStart = index;
      index += 1;
      while (index < lines.length && !lines[index].startsWith('m=')) {
        index += 1;
      }
      final section = lines.sublist(sectionStart, index);
      final insertIndex = section.indexWhere((l) => l.startsWith('a='));
      output.addAll(section.take(insertIndex < 0 ? section.length : insertIndex));
      for (final attr in sessionAttrs) {
        // split_once(':') semantics (matches OpenNOW's Rust port): the prefix
        // is everything up to the FIRST colon, e.g. "a=ice-ufrag:". Using
        // split(':').first would yield just "a:" and defeat the dedup check.
        final colon = attr.indexOf(':');
        final prefix = colon >= 0 ? attr.substring(0, colon + 1) : '$attr:';
        if (!section.any((l) => l.startsWith(prefix))) {
          output.add(attr);
        }
      }
      if (insertIndex >= 0) output.addAll(section.skip(insertIndex));
    }

    return output.join(lineEnding);
  }

  /// Strip characters GStreamer's SDP parser rejects from a=ice-pwd values
  /// (keeps [A-Za-z0-9+/]). Port of OpenNOW's sanitize_ice_pwd_for_gstreamer().
  static String sanitizeIcePwdForGstreamer(String sdp) {
    final lineEnding = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(RegExp(r'\r?\n'));
    final sanitized = lines.map((line) {
      if (!line.startsWith('a=ice-pwd:')) return line;
      final value = line.substring('a=ice-pwd:'.length);
      final cleaned = String.fromCharCodes(value.codeUnits.where((c) {
        final ch = String.fromCharCode(c);
        return RegExp(r'^[A-Za-z0-9+/]$').hasMatch(ch);
      }));
      return 'a=ice-pwd:$cleaned';
    }).join(lineEnding);
    return sanitized;
  }

  /// Ensure the video media advertises `a=framerate:<fps>` so webrtcbin
  /// negotiates the frame rate the app requested. Port of OpenNOW's
  /// align_video_sdp_framerate_for_gstreamer().
  static String alignVideoSdpFramerateForGstreamer(String sdp, int fps) {
    if (fps <= 0) return sdp;
    final lineEnding = sdp.contains('\r\n') ? '\r\n' : '\n';
    final hasTrailingEnding = sdp.endsWith(lineEnding);
    final lines = sdp
        .split(RegExp(r'\r?\n'))
        .where((l) => l.isNotEmpty || !hasTrailingEnding)
        .toList();
    final target = 'a=framerate:$fps';
    final output = <String>[];
    var inVideo = false;
    var videoHasFramerate = false;
    for (final line in lines) {
      if (line.startsWith('m=')) {
        if (inVideo && !videoHasFramerate) {
          output.add(target);
        }
        inVideo = line.startsWith('m=video');
        videoHasFramerate = false;
        output.add(line);
        continue;
      }
      if (inVideo && line.startsWith('a=framerate:')) {
        videoHasFramerate = true;
        output.add(line == target ? line : target);
        continue;
      }
      output.add(line);
    }
    if (inVideo && !videoHasFramerate) {
      output.add(target);
    }
    var result = output.join(lineEnding);
    if (hasTrailingEnding) result += lineEnding;
    return result;
  }

  /// Port of OpenNOW's preferCodec(). When [keepFallbacks] is true (web/
  /// flutter path) it reorders the video m-line so the preferred codec comes
  /// first but keeps every payload — avoiding the `m=video 0` reject that hangs
  /// on `Waiting for game video...` when the requested codec isn't decodable.
  /// Hard-filter (native/webrtcbin) strips to preferred + RTX (+ FLEXFEC).
  static String preferCodec(
    String sdp,
    String codec, {
    bool keepFallbacks = false,
    String? fallbackCodec,
    int? preferHevcProfileId,
  }) {
    final normalized = normalizeCodec(codec);
    final lineEnding = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(RegExp(r'\r?\n'));

    final payloadTypesByCodec = <String, List<String>>{};
    final codecByPayloadType = <String, String>{};
    final rtxAptByPayloadType = <String, String>{};

    var inVideo = false;
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        inVideo = true;
        continue;
      }
      if (line.startsWith('m=') && inVideo) inVideo = false;
      if (!inVideo || !line.startsWith('a=rtpmap:')) continue;

      final parts = line.substring('a=rtpmap:'.length).split(RegExp(r'\s+'));
      final pt = parts.isNotEmpty ? parts[0] : '';
      final codecName = normalizeCodec(
        (parts.length > 1 ? parts[1].split('/').first : '').trim(),
      );
      if (pt.isEmpty || codecName.isEmpty) continue;
      (payloadTypesByCodec[codecName] ??= []).add(pt);
      codecByPayloadType[pt] = codecName;
    }

    inVideo = false;
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        inVideo = true;
        continue;
      }
      if (line.startsWith('m=') && inVideo) inVideo = false;
      if (!inVideo || !line.startsWith('a=fmtp:')) continue;

      final parts = line.substring('a=fmtp:'.length).split(RegExp(r'\s+'));
      final pt = parts.isNotEmpty ? parts[0] : '';
      final params = parts.length > 1 ? parts[1] : '';
      if (pt.isEmpty || params.isEmpty) continue;
      final apt = RegExp(r'(?:^|;)\s*apt=(\d+)', caseSensitive: false)
          .firstMatch(params)
          ?.group(1);
      if (apt != null) rtxAptByPayloadType[pt] = apt;
    }

    // Need fmtp map for H265 profile ordering
    final fmtpByPayload = <String, String>{};
    inVideo = false;
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        inVideo = true;
        continue;
      }
      if (line.startsWith('m=') && inVideo) inVideo = false;
      if (!inVideo || !line.startsWith('a=fmtp:')) continue;
      final rest = line.substring('a=fmtp:'.length);
      final colonIdx = rest.indexOf(' ');
      if (colonIdx < 0) continue;
      final pt = rest.substring(0, colonIdx).trim();
      final params = rest.substring(colonIdx + 1);
      if (pt.isNotEmpty) fmtpByPayload[pt] = params;
    }

    final rawPreferred = payloadTypesByCodec[normalized] ?? [];
    if (rawPreferred.isEmpty) return sdp;

    // H265 profile ordering: prefer requested profile-id first
    List<String> orderedPreferred = rawPreferred;
    if (normalized == 'H265' && preferHevcProfileId != null) {
      int score(String pt) {
        final fmtp = fmtpByPayload[pt] ?? '';
        final m = RegExp(r'(?:^|;)\s*profile-id=(\d+)', caseSensitive: false).firstMatch(fmtp);
        final profile = m?.group(1);
        if (profile == preferHevcProfileId.toString()) return 0;
        if (profile == null || profile.isEmpty) return 1;
        return 2;
      }

      orderedPreferred = [...rawPreferred]..sort((a, b) => score(a) - score(b));
    }

    List<String> orderedFallback = [];
    if (keepFallbacks && fallbackCodec != null) {
      final fbNorm = normalizeCodec(fallbackCodec);
      if (fbNorm != normalized) {
        final fbRaw = payloadTypesByCodec[fbNorm] ?? [];
        if (fbNorm == 'H265' && preferHevcProfileId != null) {
          int score(String pt) {
            final fmtp = fmtpByPayload[pt] ?? '';
            final m = RegExp(r'(?:^|;)\s*profile-id=(\d+)', caseSensitive: false).firstMatch(fmtp);
            final profile = m?.group(1);
            if (profile == preferHevcProfileId.toString()) return 0;
            if (profile == null || profile.isEmpty) return 1;
            return 2;
          }

          orderedFallback = [...fbRaw]..sort((a, b) => score(a) - score(b));
        } else {
          orderedFallback = fbRaw;
        }
      }
    }

    final preferred = orderedPreferred.toSet();
    final allowed = <String>{...preferred};
    for (final entry in rtxAptByPayloadType.entries) {
      if (preferred.contains(entry.value) && codecByPayloadType[entry.key] == 'RTX') {
        allowed.add(entry.key);
      }
    }
    // Native sdp.rs (webrtcbin path): FLEXFEC-03 payloads are ALWAYS allowed —
    // hard filtering keeps preferred + apt-RTX + FLEXFEC, then reorders.
    if (!keepFallbacks) {
      for (final entry in codecByPayloadType.entries) {
        if (entry.value == 'FLEXFEC-03') {
          allowed.add(entry.key);
        }
      }
    } else {
      // Soft (web codec.ts) mode keeps EVERY payload — reorder only, so the
      // primary codecs stay in the m-line and the intersection can never
      // collapse to FEC-only.
      for (final pts in payloadTypesByCodec.values) {
        for (final pt in pts) {
          allowed.add(pt);
        }
      }
    }

    final filtered = <String>[];
    inVideo = false;
    for (final line in lines) {
      if (line.startsWith('m=video')) {
        inVideo = true;
        final parts = line.split(RegExp(r'\s+'));
        final header = parts.take(3).toList();
        final payloadsInLine = parts.skip(3).toList();
        final available = keepFallbacks
            ? payloadsInLine
            : payloadsInLine.where(allowed.contains).toList();
        final ordered = <String>[];
        for (final pt in orderedPreferred) {
          if (available.contains(pt)) ordered.add(pt);
        }
        for (final pt in orderedFallback) {
          if (!preferred.contains(pt) && available.contains(pt) && !ordered.contains(pt)) {
            ordered.add(pt);
          }
        }
        for (final pt in available) {
          if (!preferred.contains(pt) && !ordered.contains(pt)) ordered.add(pt);
        }
        filtered.add(ordered.isNotEmpty ? [...header, ...ordered].join(' ') : line);
        continue;
      }
      if (line.startsWith('m=') && inVideo) inVideo = false;
      if (inVideo &&
          (line.startsWith('a=rtpmap:') ||
              line.startsWith('a=fmtp:') ||
              line.startsWith('a=rtcp-fb:'))) {
        if (keepFallbacks) {
          filtered.add(line);
          continue;
        }
        final pt = line.split(':').elementAtOrNull(1)?.split(RegExp(r'\s+')).first ?? '';
        if (pt.isNotEmpty && !allowed.contains(pt)) continue;
      }
      filtered.add(line);
    }

    return filtered.join(lineEnding);
  }

  /// GStreamer webrtcbin 1.28 rejects media m-lines that carry NO direction
  /// attribute — it does NOT apply the RFC 3264 default of sendrecv, so an
  /// offer without `a=sendrecv`/`a=sendonly`/`a=recvonly` on video/audio gets
  /// answered with `m=video 0` (RFC 3264 "rejected media") and the server
  /// never sends video. Verified empirically against webrtcbin 1.28.5:
  ///   - no direction      -> answer m=video 0 (rejected)
  ///   - a=sendrecv        -> answer m=video 9
  ///   - a=sendonly        -> answer m=video 9 + a=recvonly  (correct)
  ///   - a=recvonly        -> answer m=video 9 + a=inactive   (server stays silent)
  ///
  /// We only receive media, so mark each video/audio m-line `a=sendonly` —
  /// webrtcbin then answers `a=recvonly`, exactly what the NVIDIA server
  /// expects from a receive-only client. The application (SCTP) section is
  /// left untouched.
  static String addMediaDirection(String sdp, {String direction = 'sendonly'}) {
    final lineEnding = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(RegExp(r'\r?\n'));
    final attr = 'a=$direction';
    final result = <String>[];

    var inMedia = false; // inside a video/audio section (needs a direction)
    var sectionHasDirection = false;
    var mlineIndex = -1; // index in `result` of the section's m= line

    void flushSection() {
      if (inMedia && !sectionHasDirection && mlineIndex >= 0) {
        result.insert(mlineIndex + 1, attr);
      }
    }

    for (final line in lines) {
      if (line.startsWith('m=')) {
        flushSection();
        inMedia = line.startsWith('m=video') || line.startsWith('m=audio');
        sectionHasDirection = false;
        mlineIndex = inMedia ? result.length : -1;
        result.add(line);
        continue;
      }
      if (inMedia &&
          (line.startsWith('a=sendrecv') ||
              line.startsWith('a=sendonly') ||
              line.startsWith('a=recvonly') ||
              line.startsWith('a=inactive'))) {
        sectionHasDirection = true;
      }
      result.add(line);
    }
    flushSection();

    return result.join(lineEnding);
  }

  // ---------------------------------------------------------------------
  // Answer munging
  // ---------------------------------------------------------------------

  /// Inject b=AS bitrate limits after each m= line and add stereo=1 to the
  /// opus fmtp line (port of OpenNOW's mungeAnswerSdp()).
  static String mungeAnswerSdp(String sdp, int maxBitrateKbps) {
    final lineEnding = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(RegExp(r'\r?\n'));
    final result = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      result.add(line);

      if (line.startsWith('m=video') || line.startsWith('m=audio')) {
        final bitrate = line.startsWith('m=video') ? maxBitrateKbps : 128;
        final next = i + 1 < lines.length ? lines[i + 1] : '';
        if (!next.startsWith('b=')) {
          result.add('b=AS:$bitrate');
        }
      }

      if (line.startsWith('a=fmtp:') &&
          line.contains('minptime=') &&
          !line.contains('stereo=1')) {
        result[result.length - 1] = '$line;stereo=1';
      }
    }

    return result.join(lineEnding);
  }

  /// Post-process a webrtcbin answer into a libwebrtc-shaped answer the
  /// NVIDIA server accepts:
  ///   - every media m-line joins the BUNDLE group. webrtcbin 1.28 only
  ///     bundles the SCTP m-line (the only transport it creates), leaving
  ///     video/audio out of `a=group:BUNDLE` — the server would then expect
  ///     separate transports with no reachable candidates.
  ///   - video/audio sections get the client's REAL ICE credentials (ufrag,
  ///     pwd, fingerprint, setup:active) taken from the SCTP section (the
  ///     only transport webrtcbin actually set up), replacing any transport
  ///     attrs echoed from the offer — which carry the SERVER's own
  ///     credentials and would make the server's ICE validation fail.
  ///
  /// Returns the input unchanged if no usable client transport is found.
  static String mungeAnswerForGfn(String sdp) {
    final lineEnding = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(RegExp(r'\r?\n'));

    final firstMedia = lines.indexWhere((l) => l.startsWith('m='));
    if (firstMedia < 0) return sdp;
    final session = lines.take(firstMedia).toList();
    final media = <List<String>>[];
    var index = firstMedia;
    while (index < lines.length) {
      final start = index;
      index += 1;
      while (index < lines.length && !lines[index].startsWith('m=')) {
        index += 1;
      }
      media.add(lines.sublist(start, index));
    }

    // Client transport attrs come from the SCTP (application) section — the
    // one transport webrtcbin actually created with its own credentials.
    String? clientUfrag;
    String? clientPwd;
    String? clientFingerprint;
    for (final s in media) {
      if (!s.first.startsWith('m=application')) continue;
      for (final l in s) {
        if (l.startsWith('a=ice-ufrag:')) {
          clientUfrag = l.substring('a=ice-ufrag:'.length);
        } else if (l.startsWith('a=ice-pwd:')) {
          clientPwd = l.substring('a=ice-pwd:'.length);
        } else if (l.startsWith('a=fingerprint:')) {
          clientFingerprint = l;
        }
      }
      break;
    }
    if (clientUfrag == null || clientPwd == null || clientFingerprint == null) {
      return sdp; // nothing sane to inject — leave untouched
    }

    bool isTransport(String l) =>
        l.startsWith('a=ice-ufrag:') ||
        l.startsWith('a=ice-pwd:') ||
        l.startsWith('a=fingerprint:') ||
        l.startsWith('a=setup:');

    // Fix the bundle group: every mid in m-line order.
    final mids = <String>[];
    for (final s in media) {
      for (final l in s) {
        if (l.startsWith('a=mid:')) {
          mids.add(l.substring('a=mid:'.length));
          break;
        }
      }
    }
    final bundle = mids.isEmpty ? null : 'a=group:BUNDLE ${mids.join(' ')}';

    final out = <String>[];
    for (final l in session) {
      if (l.startsWith('a=group:BUNDLE')) {
        if (bundle != null) out.add(bundle);
      } else {
        out.add(l);
      }
    }
    for (final s in media) {
      out.add(s.first); // m= line
      final isApp = s.first.startsWith('m=application');
      if (isApp) {
        out.addAll(s.skip(1)); // keep the SCTP section untouched
        continue;
      }
      final rest = s.skip(1).where((l) => !isTransport(l)).toList();
      // Keep any c=/b= header lines first, then the transport block — an
      // a= line before c= is legal SDP, but after c= is maximally compatible.
      final headerCount =
          rest.takeWhile((l) => l.startsWith('c=') || l.startsWith('b=')).length;
      out.addAll(rest.take(headerCount));
      out.addAll([
        'a=ice-ufrag:$clientUfrag',
        'a=ice-pwd:$clientPwd',
        clientFingerprint,
        'a=setup:active',
      ]);
      out.addAll(rest.skip(headerCount));
    }

    var result = out.join(lineEnding);
    if (sdp.endsWith(lineEnding)) result += lineEnding;
    return result;
  }

  /// GStreamer webrtcbin 1.28 answers do NOT echo the offer's RTP header
  /// extensions or ICE options: no `a=extmap:3` (transport-cc), no
  /// `a=ice-options:trickle`, no `a=rtcp-rsize`, and no `a=msid-semantic: WMS`.
  /// OpenNOW's working webrtcbin answer carries all four (verified against its
  /// native streamer logs + source). The GFN video sender builds its bandwidth
  /// estimation on transport-wide-cc feedback; without the extmap in the
  /// answer the extension is never negotiated and the server withholds video
  /// (audio has no such requirement — which is why audio arrives while video
  /// stays silent). Re-insert them, echoing the offer's extmap:3 URI so the
  /// negotiated extension matches what the server advertised.
  static String mungeAnswerTransportExtras(String answerSdp, String offerSdp) {
    final lineEnding = answerSdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = answerSdp.split(RegExp(r'\r?\n'));

    // Echo the offer's transport-wide-cc extmap URI (draft versions vary:
    // GFN serves -01). Fall back to the canonical -01 URI.
    String? offerExtmap3;
    for (final line in offerSdp.split(RegExp(r'\r?\n'))) {
      if (line.startsWith('a=extmap:3 ')) {
        offerExtmap3 = line.substring('a=extmap:3 '.length);
        break;
      }
    }
    final extmap3 = offerExtmap3 ??
        'http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01';

    // The libwebrtc answer echoes EVERY offer extmap (transport-cc 3,
    // video-timing 7, playout-delay 12 …). GFN's sender paces with them —
    // mirror the whole set, not just extmap 3.
    final offerExtmapLines = offerSdp
        .split(RegExp(r'\r?\n'))
        .where((l) => l.startsWith('a=extmap:'))
        .toList();

    // Idempotent: if any media section already advertises these, skip.
    final hasMsidSemantic = lines.any((l) => l.startsWith('a=msid-semantic:'));
    final hasTrickle = lines.any((l) => l.startsWith('a=ice-options:'));
    final hasRtcpRsize = lines.any((l) => l.startsWith('a=rtcp-rsize'));
    final hasExtmap3 = lines.any((l) => l.startsWith('a=extmap:3 '));

    final out = <String>[];

    var inAvMedia = false;
    var addedThisSection = false;
    final sectionExtmaps = <String>{};
    var msidSemanticInserted = hasMsidSemantic;
    for (final line in lines) {
      // RFC 4566: v=0 must be the first line, so msid-semantic goes in the
      // session block — right before the first m= line (after t=0 0).
      if (!msidSemanticInserted && line.startsWith('m=')) {
        out.add('a=msid-semantic: WMS');
        msidSemanticInserted = true;
      }
      if (line.startsWith('m=')) {
        inAvMedia = line.startsWith('m=video') || line.startsWith('m=audio');
        addedThisSection = false;
        sectionExtmaps.clear();
        out.add(line);
        continue;
      }
      out.add(line);
      if (inAvMedia &&
          !addedThisSection &&
          line.startsWith('a=mid:')) {
        // Echo every offer extmap per media section (webrtcbin answers with
        // none of them) — GFN's sender paces with transport-cc (3),
        // video-timing (7) and playout-delay (12). The libwebrtc answer
        // carries the full set in EVERY m-section.
        for (final ext in offerExtmapLines) {
          if (sectionExtmaps.add(ext)) {
            out.add(ext);
          }
        }
        final extmap3Line = 'a=extmap:3 $extmap3';
        if (!offerExtmapLines.any((l) => l.startsWith('a=extmap:3 ')) &&
            sectionExtmaps.add(extmap3Line)) {
          out.add(extmap3Line);
        }
        if (!hasTrickle) out.add('a=ice-options:trickle');
        if (!hasRtcpRsize) out.add('a=rtcp-rsize');
        addedThisSection = true;
      }
    }

    var result = out.join(lineEnding);
    if (answerSdp.endsWith(lineEnding)) result += lineEnding;
    return result;
  }

  /// webrtcbin 1.28 drops the offer's RTX payloads (97/102 in GFN offers) from
  /// its answer and instead keeps flexfec-03 — the inverse of what the working
  /// libwebrtc path sends. NVIDIA's streamer builds its video send pipeline
  /// around the FID (rtx) group, and without the rtx payload types in the
  /// answer it never starts sending video (audio has no such requirement, which
  /// is why audio arrives while video stays silent).
  ///
  /// Re-shape the webrtcbin answer to match a libwebrtc-shaped answer:
  ///   - drop any flexfec-03 payload from the video m-line (webrtcbin can't
  ///     consume it; keeping it just confuses the server's FEC-FR setup), and
  ///   - re-add the offer's rtx payloads (apt-linked to the negotiated H264
  ///     payloads) with their rtpmap/fmtp lines.
  static String restoreVideoRtx(String answerSdp, String offerSdp) {
    final lineEnding = answerSdp.contains('\r\n') ? '\r\n' : '\n';
    final ansLines = answerSdp.split(RegExp(r'\r?\n'));
    final offLines = offerSdp.split(RegExp(r'\r?\n'));

    // Offer video section: rtpmap + fmtp + rtcp-fb per payload type.
    final offRtpmap = <String, String>{};
    final offFmtp = <String, String>{};
    final offRtcpFb = <String, List<String>>{};
    var inOfferVideo = false;
    for (final line in offLines) {
      if (line.startsWith('m=video')) {
        inOfferVideo = true;
        continue;
      }
      if (inOfferVideo && line.startsWith('m=')) inOfferVideo = false;
      if (!inOfferVideo) continue;
      final rp = RegExp(r'^a=rtpmap:(\d+) (.+)$').firstMatch(line);
      if (rp != null) offRtpmap[rp.group(1)!] = rp.group(2)!;
      final fp = RegExp(r'^a=fmtp:(\d+) (.+)$').firstMatch(line);
      if (fp != null) offFmtp[fp.group(1)!] = fp.group(2)!;
      final fb = RegExp(r'^a=rtcp-fb:(\d+) (.+)$').firstMatch(line);
      if (fb != null) (offRtcpFb[fb.group(1)!] ??= []).add(fb.group(2)!);
    }

    // Which rtx payloads does the offer want, and which primary do they serve?
    final rtxApt = <String, String>{};
    for (final e in offRtpmap.entries) {
      final name = e.value.split('/').first.trim().toUpperCase();
      if (name != 'RTX') continue;
      final fmtp = offFmtp[e.key] ?? '';
      final apt = RegExp(r'(?:^|;)\s*apt=(\d+)').firstMatch(fmtp)?.group(1);
      if (apt != null) rtxApt[e.key] = apt;
    }
    if (rtxApt.isEmpty) return answerSdp;

    final out = <String>[];
    var inVideo = false;
    var videoDone = false;
    final videoPayloads = <String>[];
    final videoAttrLines = <String>[];

    for (final line in ansLines) {
      if (line.startsWith('m=video') && !videoDone) {
        inVideo = true;
        final parts = line.split(RegExp(r'\s+'));
        final header = parts.take(3).toList();
        videoPayloads.addAll(parts.skip(3));
        out.add(header.join(' ')); // m= line re-emitted below with rtx added
        continue;
      }
      if (inVideo && line.startsWith('m=')) {
        inVideo = false;
        videoDone = true;
      }
      if (inVideo) {
        // Collect every video-section line; payload-attr lines whose payload
        // is dropped (flexfec) are filtered after `kept` is computed below.
        videoAttrLines.add(line);
        continue;
      }
      out.add(line);
    }

    // Keep H264 (and any non-flexfec) payloads, then append offer rtx payloads
    // whose primary (apt) is among the kept payloads.
    final kept = videoPayloads.where((pt) {
      final name = offRtpmap[pt]?.split('/').first.trim().toUpperCase() ?? '';
      return name != 'FLEXFEC-03';
    }).toList();
    for (final e in rtxApt.entries) {
      if (kept.contains(e.value) && !kept.contains(e.key)) {
        kept.add(e.key);
      }
    }

    // Re-emit the m= line with the rebuilt payload list.
    final firstVideoIndex = out.indexWhere((l) => l.startsWith('m=video'));
    out[firstVideoIndex] = '${out[firstVideoIndex]} ${kept.join(' ')}';

    // Drop video attrs whose payload is no longer on the m-line (flexfec
    // rtpmap/fmtp/rtcp-fb). Computed AFTER `kept` so it stays correct even if
    // the offer scan lacks a flexfec rtpmap entry.
    final keptSet = kept.toSet();
    videoAttrLines.removeWhere((l) {
      final m = RegExp(r'^a=(?:rtpmap|fmtp|rtcp-fb):(\d+)').firstMatch(l);
      return m != null && !keptSet.contains(m.group(1));
    });

    // Inject the restored rtx payloads' rtpmap/fmtp/rtcp-fb from the offer.
    final injected = <String>[];
    for (final pt in kept) {
      if (offRtpmap[pt]?.split('/').first.trim().toUpperCase() != 'RTX') {
        continue;
      }
      if (videoAttrLines.any((l) => l.startsWith('a=rtpmap:$pt '))) {
        continue;
      }
      injected.add('a=rtpmap:$pt ${offRtpmap[pt]}');
      final fmtp = offFmtp[pt];
      if (fmtp != null) injected.add('a=fmtp:$pt $fmtp');
      for (final fb in offRtcpFb[pt] ?? const <String>[]) {
        injected.add('a=rtcp-fb:$pt $fb');
      }
    }

    // webrtcbin also drops rtcp-fb lines for the payloads it KEPT (nack /
    // nack pli / ccm fir / transport-cc) — NVIDIA's sender requires them for
    // loss retransmission and PLI keyframe requests. Re-add every offer
    // rtcp-fb for kept payloads that the answer lacks.
    for (final pt in kept) {
      final fbs = offRtcpFb[pt] ?? const <String>[];
      for (final fb in fbs) {
        final line = 'a=rtcp-fb:$pt $fb';
        if (!videoAttrLines.contains(line)) {
          injected.add(line);
        }
      }
    }

    // Re-insert video attrs + rtx lines right after the m= line (skipping any
    // c= line that lives at the head of videoAttrLines).
    var insertAt = firstVideoIndex + 1;
    while (insertAt < out.length && out[insertAt].startsWith('c=')) {
      insertAt++;
    }
    out.insertAll(insertAt, [...videoAttrLines, ...injected]);

    return out.join(lineEnding);
  }

  static IceCredentials extractIceCredentials(String sdp) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    String? valueOf(String prefix) {
      for (final line in lines) {
        if (line.startsWith(prefix)) {
          return line.substring(prefix.length).trim();
        }
      }
      return null;
    }

    return IceCredentials(
      ufrag: valueOf('a=ice-ufrag:') ?? '',
      pwd: valueOf('a=ice-pwd:') ?? '',
      fingerprint: valueOf('a=fingerprint:sha-256 ') ?? '',
    );
  }

  // ---------------------------------------------------------------------
  // nvstSdp capability blob
  // ---------------------------------------------------------------------

  static const int _officialMinBitrateKbps = 4000;
  static const int _highResolutionPixelCount = 2764800;
  static const int _highBitratePacingThresholdKbps = 42000;

  /// The fake-SDP capability blob NVIDIA's streamer requires in the answer so
  /// it knows the client's viewport, bitrate budget, encoder preferences, and
  /// input-channel capabilities.
  ///
  /// Port of OpenNOW's `sdp/nvstOffer.ts` — byte-for-byte aligned with the
  /// official `play.geforcenow.com` bundle when experimental knobs are off.
  /// When priority / low-latency / recovery / constantQuality differ from the
  /// safe defaults the same base is patched with the minimal overrides that
  /// actually change server behavior (preserving the official shape otherwise).
  static String buildNvstSdp({
    required int width,
    required int height,
    required int fps,
    required int maxBitrateKbps,
    required String codec,
    required String colorQuality,
    required IceCredentials credentials,
    required RiInputCapabilities caps,
    StreamPriority priority = StreamPriority.quality,
    bool lowLatencyMode = false,
    StreamRecoveryProfile recoveryProfile = StreamRecoveryProfile.smooth,
    int minBitrateKbps = 4000,
    bool enableNack = true,
    bool enableFec = true,
    bool constantQuality = false,
  }) {
    // -----------------------------------------------------------------
    // Official baseline — verbatim port of nvstOffer.ts (web transport)
    // -----------------------------------------------------------------
    final maxBitrate = max(_officialMinBitrateKbps, maxBitrateKbps.floor());
    final startupBitrate =
        max(_officialMinBitrateKbps, (maxBitrate / 4).round());
    final isHighFps = fps >= 90;
    final is90Fps = fps == 90;
    final is120Fps = fps == 120;
    final is240Fps = fps >= 240;
    final isAv1 = codec == 'AV1';
    final pixelCount = width * height;
    final useHighThroughputPacing = pixelCount >= _highResolutionPixelCount ||
        maxBitrate >= _highBitratePacingThresholdKbps;
    final supportsHighBitDepth = codec == 'H265' || codec == 'AV1';
    final bitDepth = supportsHighBitDepth && colorQuality.startsWith('10bit')
        ? 10
        : 8;
    final hidDeviceMask = caps.hidDeviceMask;
    final enablePartiallyReliableTransferGamepad =
        caps.enablePartiallyReliableTransferGamepad;
    final enablePartiallyReliableTransferHid =
        caps.enablePartiallyReliableTransferHid;

    // Official lines (mirrors nvstOffer.ts exactly)
    final lines = <String>[
      'v=0',
      'o=SdpTest test_id_13 14 IN IPv4 127.0.0.1',
      's=-',
      't=0 0',
      'a=general.icePassword:${credentials.pwd}',
      'a=general.iceUserNameFragment:${credentials.ufrag}',
      'a=general.dtlsFingerprint:${credentials.fingerprint}',
      'm=video 0 RTP/AVP',
      'a=msid:fbc-video-0',
      'a=vqos.fec.rateDropWindow:10',
      'a=vqos.fec.minRequiredFecPackets:2',
      'a=vqos.drc.minRequiredBitrateCheckEnabled:1',
      'a=vqos.fec.repairMinPercent:5',
      'a=vqos.fec.repairPercent:5',
      'a=vqos.fec.repairMaxPercent:35',
      'a=vqos.dynamicStreamingMode:3',
      'a=vqos.bllFec.enable:0',
    ];

    if (isHighFps) {
      lines.addAll([
        'a=vqos.drc.enable:0',
        'a=vqos.dfc.enable:1',
        'a=vqos.dfc.decodeFpsAdjPercent:85',
        'a=vqos.dfc.targetDownCooldownMs:250',
        'a=vqos.dfc.dfcAlgoVersion:${is120Fps || is240Fps ? 2 : 1}',
        'a=vqos.dfc.minTargetFps:${is90Fps ? 60 : 100}',
        'a=vqos.resControl.dfc.useClientFpsPerf:0',
        'a=vqos.dfc.adjustResAndFps:1',
      ]);
    } else {
      lines.add('a=vqos.drc.enable:1');
    }

    lines.addAll([
      'a=video.dx9EnableNv12:1',
      'a=video.dx9EnableHdr:1',
      'a=vqos.qpg.enable:1',
      'a=vqos.resControl.qp.qpg.featureSetting:7',
      'a=bwe.useOwdCongestionControl:1',
      'a=video.enableRtpNack:1',
      'a=vqos.bw.txRxLag.minFeedbackTxDeltaMs:200',
      'a=vqos.drc.bitrateIirFilterFactor:18',
      'a=video.packetSize:1140',
      'a=packetPacing.minNumPacketsPerGroup:15',
    ]);

    if (isHighFps) {
      lines.addAll([
        'a=bwe.iirFilterFactor:8',
        'a=video.encoderFeatureSetting:47',
        'a=video.encoderPreset:6',
        'a=vqos.resControl.cpmRtc.badNwSkipFramesCount:600',
        'a=vqos.resControl.cpmRtc.decodeTimeThresholdMs:${is90Fps ? 11 : 9}',
        'a=video.fbcDynamicFpsGrabTimeoutMs:${is90Fps ? 9 : is120Fps ? 6 : 18}',
        'a=vqos.resControl.cpmRtc.serverResolutionUpdateCoolDownCount:${is120Fps ? 6000 : 12000}',
        if (is120Fps || is240Fps) 'a=video.fakeEncodeFps:120',
      ]);
    }

    if (is240Fps) {
      lines.addAll([
        'a=video.enableNextCaptureMode:1',
        'a=vqos.maxStreamFpsEstimate:240',
        'a=video.videoSplitEncodeStripsPerFrame:63',
        'a=video.updateSplitEncodeStateDynamically:1',
      ]);
    }

    lines.addAll([
      'a=vqos.adjustStreamingFpsDuringOutOfFocus:1',
      'a=vqos.resControl.cpmRtc.ignoreOutOfFocusWindowState:1',
      'a=vqos.resControl.perfHistory.rtcIgnoreOutOfFocusWindowState:1',
      'a=vqos.resControl.cpmRtc.featureMask:3',
      'a=packetPacing.numGroups:${is120Fps ? 3 : 5}',
      'a=packetPacing.maxDelayUs:1000',
      'a=packetPacing.minNumPacketsFrame:10',
      'a=video.rtpNackQueueLength:1024',
      'a=video.rtpNackQueueMaxPackets:512',
      'a=video.rtpNackMaxPacketCount:25',
    ]);

    if (useHighThroughputPacing) {
      lines.add('a=vqos.drc.iirFilterFactor:100');
      if (!isAv1) {
        lines.addAll([
          'a=vqos.drc.qpMaxResThresholdAdj:4',
          'a=vqos.dfc.qpMaxResThresholdAdj:4',
          'a=vqos.grc.qpMaxResThresholdAdj:2',
        ]);
      }
    }

    if (isAv1) {
      final av1QpMaxResThresholdAdj = useHighThroughputPacing ? 20 : 0;
      lines.addAll([
        'a=vqos.drc.minQpHeadroom:20',
        'a=vqos.drc.lowerQpThreshold:100',
        'a=vqos.drc.upperQpThreshold:200',
        'a=vqos.drc.minAdaptiveQpThreshold:180',
        'a=vqos.drc.qpMaxResThresholdAdj:$av1QpMaxResThresholdAdj',
        'a=vqos.drc.qpCodecThresholdAdj:0',
        'a=vqos.dfc.minQpHeadroom:20',
        'a=vqos.dfc.qpLowerLimit:100',
        'a=vqos.dfc.qpMaxUpperLimit:200',
        'a=vqos.dfc.qpMinUpperLimit:180',
        'a=vqos.dfc.qpMaxResThresholdAdj:$av1QpMaxResThresholdAdj',
        'a=vqos.dfc.qpCodecThresholdAdj:0',
        'a=vqos.grc.minQpHeadroom:20',
        'a=vqos.grc.lowerQpThreshold:100',
        'a=vqos.grc.upperQpThreshold:200',
        'a=vqos.grc.minAdaptiveQpThreshold:180',
        'a=vqos.grc.qpMaxResThresholdAdj:$av1QpMaxResThresholdAdj',
        'a=vqos.grc.qpCodecThresholdAdj:0',
        'a=video.minQp:25',
        'a=video.enableAv1RcPrecisionFactor:1',
      ]);
    }

    // Tail before optional experimental patches
    lines.addAll([
      'a=video.clientViewportWd:$width',
      'a=video.clientViewportHt:$height',
      'a=video.maxFPS:$fps',
      'a=video.initialBitrateKbps:$startupBitrate',
      'a=video.initialPeakBitrateKbps:$startupBitrate',
      'a=vqos.bw.maximumBitrateKbps:$maxBitrate',
      'a=vqos.bw.minimumBitrateKbps:$_officialMinBitrateKbps',
      'a=video.maxNumReferenceFrames:4',
      'a=video.mapRtpTimestampsToFrames:1',
      'a=video.encoderCscMode:3',
      'a=video.encoderHdrCscMode:4',
      'a=video.dynamicRangeMode:${bitDepth == 10 ? 1 : 0}',
      'a=video.bitDepth:$bitDepth',
      if (codec == 'H265' && bitDepth == 10) 'a=video.minQp:14',
      'a=video.scalingFeature1:${isAv1 ? 1 : 0}',
      'a=video.prefilterParams.prefilterMode:0',
      'a=video.prefilterParams.prefilterModel:0',
      'a=video.prefilterParams.denoiseLevel:0',
      'a=video.prefilterParams.sharpnessLevel:0',
      'm=audio 0 RTP/AVP',
      'a=msid:audio',
      'm=mic 0 RTP/AVP',
      'a=msid:mic',
      'a=rtpmap:0 PCMU/8000',
      'm=application 0 RTP/AVP',
      'a=msid:input_1',
      'a=ri.partialReliableThresholdMs:${caps.partialReliableThresholdMs}',
      'a=ri.hidDeviceMask:$hidDeviceMask',
      'a=ri.enablePartiallyReliableTransferGamepad:$enablePartiallyReliableTransferGamepad',
      'a=ri.enablePartiallyReliableTransferHid:$enablePartiallyReliableTransferHid',
      '',
    ]);

    // -----------------------------------------------------------------
    // Experimental overrides — applied only when the caller diverges
    // from the official safe defaults. Keeps the happy path byte-identical
    // to play.geforcenow.com for BWE performance.
    // -----------------------------------------------------------------
    final hasExperimental = priority != StreamPriority.quality ||
        lowLatencyMode ||
        recoveryProfile != StreamRecoveryProfile.smooth ||
        minBitrateKbps != _officialMinBitrateKbps ||
        !enableNack ||
        !enableFec ||
        constantQuality;

    if (!hasExperimental) return lines.join('\n');

    // For experimental sessions, patch the official lines in-place rather than
    // rebuilding from scratch — keeps the diff minimal and auditable.
    return _applyExperimentalPatches(
      lines: lines,
      priority: priority,
      lowLatencyMode: lowLatencyMode,
      recoveryProfile: recoveryProfile,
      minBitrateKbps: minBitrateKbps,
      enableNack: enableNack,
      enableFec: enableFec,
      constantQuality: constantQuality,
      maxBitrate: maxBitrate,
      fps: fps,
      isHighFps: isHighFps,
      is120Fps: is120Fps,
      is240Fps: is240Fps,
    );
  }

  /// Patches an official nvstSdp with the minimal experimental overrides.
  static String _applyExperimentalPatches({
    required List<String> lines,
    required StreamPriority priority,
    required bool lowLatencyMode,
    required StreamRecoveryProfile recoveryProfile,
    required int minBitrateKbps,
    required bool enableNack,
    required bool enableFec,
    required bool constantQuality,
    required int maxBitrate,
    required int fps,
    required bool isHighFps,
    required bool is120Fps,
    required bool is240Fps,
  }) {
    final allowResolutionScaling =
        priority == StreamPriority.balanced || priority == StreamPriority.fps;
    final fpsFirst = priority == StreamPriority.fps;
    final minResolutionPercent = switch (priority) {
      StreamPriority.quality => 100,
      StreamPriority.balanced => 60,
      StreamPriority.fps => 40,
    };

    // Helpers to replace a line by prefix
    void replace(String prefix, String value) {
      final idx = lines.indexWhere((l) => l.startsWith(prefix));
      if (idx >= 0) lines[idx] = value;
    }

    void removePrefix(String prefix) {
      lines.removeWhere((l) => l.startsWith(prefix));
    }

    // Priority: dynamicStreamingMode 3 -> 1/0
    if (priority != StreamPriority.quality) {
      replace(
        'a=vqos.dynamicStreamingMode:',
        'a=vqos.dynamicStreamingMode:${allowResolutionScaling ? 1 : 0}',
      );
      // DRC/DFC: official for high-fps is fixed; for priority we enable
      // resolution-aware DFC even at 60 fps.
      if (!isHighFps) {
        // At 60 fps official has only drc.enable:1 — replace with DFC set.
        removePrefix('a=vqos.drc.enable:');
        final drcIdx = lines.indexWhere((l) => l.startsWith('a=vqos.dfc.enable:'));
        if (drcIdx < 0) {
          final insertAt = lines.indexWhere((l) => l.startsWith('a=video.dx9'));
          lines.insertAll(insertAt, [
            'a=vqos.dfc.enable:1',
            'a=vqos.dfc.decodeFpsAdjPercent:${fpsFirst ? 95 : 85}',
            'a=vqos.dfc.targetDownCooldownMs:250',
            'a=vqos.dfc.dfcAlgoVersion:1',
            'a=vqos.dfc.minTargetFps:60',
            'a=vqos.resControl.dfc.useClientFpsPerf:0',
            'a=vqos.dfc.adjustResAndFps:${allowResolutionScaling ? 1 : 0}',
          ]);
        }
      } else {
        replace(
          'a=vqos.dfc.decodeFpsAdjPercent:',
          'a=vqos.dfc.decodeFpsAdjPercent:${fpsFirst ? 95 : 85}',
        );
        replace(
          'a=vqos.dfc.adjustResAndFps:',
          'a=vqos.dfc.adjustResAndFps:${allowResolutionScaling ? 1 : 0}',
        );
      }
      // CPM resolution control: official featureMask:3 -> allow scaling
      replace(
        'a=vqos.resControl.cpmRtc.featureMask:',
        'a=vqos.resControl.cpmRtc.featureMask:${allowResolutionScaling ? 1 : 0}',
      );
      // Inject the extra CPM lines official does NOT send but priority expects
      final cpmIdx = lines.indexWhere(
        (l) => l.startsWith('a=vqos.resControl.cpmRtc.featureMask:'),
      );
      if (cpmIdx >= 0 &&
          !lines.any((l) => l.startsWith('a=vqos.resControl.cpmRtc.enable:'))) {
        lines.insertAll(cpmIdx + 1, [
          'a=vqos.resControl.cpmRtc.enable:${allowResolutionScaling ? 1 : 0}',
          'a=vqos.resControl.cpmRtc.minResolutionPercent:$minResolutionPercent',
          'a=vqos.resControl.cpmRtc.resolutionChangeHoldonMs:${allowResolutionScaling ? 5000 : 999999}',
          'a=vqos.calculateAvgVideoStreamingBitrate:1',
        ]);
      }
    }

    if (lowLatencyMode) {
      replace(
        'a=vqos.bw.txRxLag.minFeedbackTxDeltaMs:',
        'a=vqos.bw.txRxLag.minFeedbackTxDeltaMs:100',
      );
      replace('a=packetPacing.maxDelayUs:', 'a=packetPacing.maxDelayUs:500');
      // Tighten frame pacing if present; official has no framePacing line,
      // so insert one when low-latency is requested.
      final hasFraming = lines.any((l) => l.startsWith('a=video.framePacing'));
      if (!hasFraming) {
        final pacingIdx = lines.indexWhere(
          (l) => l.startsWith('a=packetPacing.minNumPacketsPerGroup:'),
        );
        final minFrameUs = max(
          1000,
          (1000000 * 60 ~/ (max(1, fps) * 100)),
        );
        lines.insertAll(pacingIdx, [
          'a=video.framePacing.mode:2',
          'a=video.framePacing.pid.minTargetFrameTimeUs:$minFrameUs',
        ]);
      }
    }

    if (recoveryProfile != StreamRecoveryProfile.smooth) {
      final (qlen, qmax, qcount) = switch (recoveryProfile) {
        StreamRecoveryProfile.smooth => (1024, 512, 25),
        StreamRecoveryProfile.balanced => (512, 256, 16),
        StreamRecoveryProfile.latency => (256, 128, 8),
      };
      replace('a=video.rtpNackQueueLength:', 'a=video.rtpNackQueueLength:$qlen');
      replace(
        'a=video.rtpNackQueueMaxPackets:',
        'a=video.rtpNackQueueMaxPackets:$qmax',
      );
      replace(
        'a=video.rtpNackMaxPacketCount:',
        'a=video.rtpNackMaxPacketCount:$qcount',
      );
      if (recoveryProfile == StreamRecoveryProfile.latency && !is240Fps) {
        // Insert preemptive IDR for latency recovery (skip 240fps pin)
        final nackIdx = lines.indexWhere(
          (l) => l.startsWith('a=video.rtpNackMaxPacketCount:'),
        );
        lines.insertAll(nackIdx + 1, [
          'a=vqos.rtcPreemptiveIdrSettings.minBurstNackSize:1',
          'a=vqos.rtcPreemptiveIdrSettings.minNackPacketCaptureAgeMs:1000',
        ]);
      }
    }

    if (minBitrateKbps != _officialMinBitrateKbps) {
      replace(
        'a=vqos.bw.minimumBitrateKbps:',
        'a=vqos.bw.minimumBitrateKbps:$minBitrateKbps',
      );
    }

    if (!enableNack) {
      replace('a=video.enableRtpNack:', 'a=video.enableRtpNack:0');
    }

    if (!enableFec) {
      removePrefix('a=vqos.fec.');
      removePrefix('a=vqos.bllFec.enable:');
      removePrefix('a=vqos.drc.minRequiredBitrateCheckEnabled:');
    }

    if (constantQuality) {
      final startup = maxBitrate;
      replace(
        'a=video.initialBitrateKbps:',
        'a=video.initialBitrateKbps:$startup',
      );
      replace(
        'a=video.initialPeakBitrateKbps:',
        'a=video.initialPeakBitrateKbps:$startup',
      );
      // Inject BWE disable lines after maximumBitrateKbps
      final maxIdx = lines.indexWhere(
        (l) => l.startsWith('a=vqos.bw.maximumBitrateKbps:'),
      );
      if (maxIdx >= 0 &&
          !lines.any((l) => l.startsWith('a=vqos.bw.enableBandwidthEstimation:'))) {
        lines.insertAll(maxIdx + 2, [
          'a=vqos.bw.peakBitrateKbps:$maxBitrate',
          'a=vqos.bw.serverPeakBitrateKbps:$maxBitrate',
          'a=vqos.bw.enableBandwidthEstimation:0',
          'a=vqos.bw.disableBitrateLimit:1',
          'a=vqos.grc.maximumBitrateKbps:$maxBitrate',
          'a=vqos.grc.enable:0',
        ]);
      }
    }

    return lines.join('\n');
  }
}

/// ICE credentials extracted from a session's own answer SDP.
class IceCredentials {
  final String ufrag;
  final String pwd;
  final String fingerprint;

  const IceCredentials({
    required this.ufrag,
    required this.pwd,
    required this.fingerprint,
  });
}

/// Input-channel capabilities parsed from the offer's `ri.*` attributes.
class RiInputCapabilities {
  final int partialReliableThresholdMs;
  final int hidDeviceMask;
  final int enablePartiallyReliableTransferGamepad;
  final int enablePartiallyReliableTransferHid;

  const RiInputCapabilities({
    this.partialReliableThresholdMs = 300,
    this.hidDeviceMask = 0xFFFFFFFF,
    this.enablePartiallyReliableTransferGamepad = 15,
    this.enablePartiallyReliableTransferHid = 0xFFFFFFFF,
  });
}
