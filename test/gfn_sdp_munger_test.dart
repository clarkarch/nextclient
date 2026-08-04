import 'package:flutter_test/flutter_test.dart';
import 'package:next_client/state/gfn_sdp_munger.dart';

void main() {
  group('mungeAnswerForGfn', () {
    // Shape captured from the webrtc_neg_test harness on GStreamer 1.28.5:
    // video/audio sections echo the offer's (server's) transport attrs while
    // only the application section carries the client's real credentials, and
    // the BUNDLE group excludes video/audio.
    const rawAnswer = 'v=0\r\n'
        'o=- 4653287626563655709 2 IN IP4 0.0.0.0\r\n'
        's=-\r\n'
        't=0 0\r\n'
        'a=ice-options:trickle\r\n'
        'a=group:BUNDLE 2\r\n'
        'm=video 0 UDP/TLS/RTP/SAVPF 96\r\n'
        'c=IN IP4 0.0.0.0\r\n'
        'a=framerate:60\r\n'
        'a=mid:0\r\n'
        'a=rtcp-mux\r\n'
        'a=ice-ufrag:Y1eQ\r\n'
        'a=ice-pwd:Vb3mMzRsfVdHt6+9zQvVtqQ\r\n'
        'a=fingerprint:sha-256 8E:7A:32:0A:2B:4D:6F:91:1A:C5:D3:07:9E:21:44:66:88:AA\r\n'
        'a=setup:actpass\r\n'
        'a=rtpmap:96 H264/90000\r\n'
        'a=fmtp:96 profile-level-id=42e01f;packetization-mode=1\r\n'
        'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
        'c=IN IP4 0.0.0.0\r\n'
        'a=ice-ufrag:OkFB97e9M8vUfMQpBmdFNA9StTV5FinN\r\n'
        'a=ice-pwd:P7elaciiqyiWTTuLrU1cIjFRXDsiob9z\r\n'
        'a=mid:2\r\n'
        'a=setup:active\r\n'
        'a=sctp-port:5000\r\n'
        'a=fingerprint:sha-256 C2:8F:22:59:B2:80:41:C3:E1:F1:0A:8C:90:FC:66:AF\r\n';

    test('bundles every m-line and stamps client credentials on media', () {
      final out = GfnSdpMunger.mungeAnswerForGfn(rawAnswer);

      // Bundle group must include the video mid too, in m-line order.
      expect(out, contains('a=group:BUNDLE 0 2'));
      expect(out, isNot(contains('a=group:BUNDLE 2\r\n')));

      // The client's real creds (from the SCTP section) must appear in the
      // video section, and the echoed server creds must be gone.
      expect(out, contains('a=ice-ufrag:OkFB97e9M8vUfMQpBmdFNA9StTV5FinN'));
      expect(out, contains('a=ice-pwd:P7elaciiqyiWTTuLrU1cIjFRXDsiob9z'));
      expect(out, contains('a=fingerprint:sha-256 C2:8F:22:59:B2:80:41:C3:'));
      expect(out, contains('a=setup:active'));
      expect(out, isNot(contains('a=ice-ufrag:Y1eQ')));
      expect(out, isNot(contains('a=fingerprint:sha-256 8E:7A:')));
      expect(out, isNot(contains('a=setup:actpass')));

      // Codec lines must survive.
      expect(out, contains('a=rtpmap:96 H264/90000'));
      expect(out, contains('m=application 9 UDP/DTLS/SCTP webrtc-datachannel'));
      expect(out, contains('a=sctp-port:5000'));
    });

    test('returns input unchanged when no client SCTP transport exists', () {
      const noSctp = 'v=0\r\n'
          's=-\r\n'
          'a=group:BUNDLE 0\r\n'
          'm=video 0 UDP/TLS/RTP/SAVPF 96\r\n'
          'a=mid:0\r\n'
          'a=rtpmap:96 H264/90000\r\n';
      expect(GfnSdpMunger.mungeAnswerForGfn(noSctp), noSctp);
    });

    test('extractIceCredentials sees client creds after munging', () {
      final out = GfnSdpMunger.mungeAnswerForGfn(rawAnswer);
      final creds = GfnSdpMunger.extractIceCredentials(out);
      expect(creds.ufrag, 'OkFB97e9M8vUfMQpBmdFNA9StTV5FinN');
      expect(creds.pwd, 'P7elaciiqyiWTTuLrU1cIjFRXDsiob9z');
      expect(creds.fingerprint, 'C2:8F:22:59:B2:80:41:C3:E1:F1:0A:8C:90:FC:66:AF');
    });
  });

  group('addMediaDirection', () {
    // GFN offers carry no direction attributes; webrtcbin 1.28 rejects media
    // m-lines without one (answers m=video 0). Marking video/audio sendonly
    // makes webrtcbin answer recvonly. Shape mirrors a real munged offer.
    const offer = 'v=0\r\n'
        'o=- 4653287626563655709 2 IN IP4 127.0.0.1\r\n'
        's=-\r\n'
        't=0 0\r\n'
        'a=group:BUNDLE 0 1 2\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96 97 100\r\n'
        'c=IN IP4 0.0.0.0\r\n'
        'a=mid:0\r\n'
        'a=rtpmap:96 H264/90000\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111 63 103 104\r\n'
        'c=IN IP4 0.0.0.0\r\n'
        'a=mid:1\r\n'
        'a=rtpmap:111 opus/48000/2\r\n'
        'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
        'c=IN IP4 0.0.0.0\r\n'
        'a=mid:2\r\n'
        'a=sctp-port:5000\r\n';

    test('adds sendonly to video/audio, not application, keeps CRLF', () {
      final out = GfnSdpMunger.addMediaDirection(offer);
      expect(out, contains('m=video 9 UDP/TLS/RTP/SAVPF 96 97 100\r\n'
          'a=sendonly\r\n'));
      expect(out, contains('m=audio 9 UDP/TLS/RTP/SAVPF 111 63 103 104\r\n'
          'a=sendonly\r\n'));
      // The SCTP section must NOT get a direction attribute.
      expect(out, isNot(contains('webrtc-datachannel\r\n'
          'a=sendonly\r\n')));
      // Everything else survives untouched.
      expect(out, contains('a=rtpmap:96 H264/90000'));
      expect(out, contains('a=sctp-port:5000'));
      expect(out, contains('a=group:BUNDLE 0 1 2'));
    });

    test('does not duplicate an existing direction attribute', () {
      final withDir = offer.replaceFirst(
        'a=mid:0',
        'a=recvonly\r\na=mid:0',
      );
      final out = GfnSdpMunger.addMediaDirection(withDir);
      expect(out, contains('a=recvonly'));
      // Only one direction attribute for the video section.
      expect(RegExp('a=recvonly').allMatches(out).length, 1);
    });

    test('idempotent', () {
      final once = GfnSdpMunger.addMediaDirection(offer);
      final twice = GfnSdpMunger.addMediaDirection(once);
      expect(twice, once);
    });
  });

  group('original ICE credential capture vs sanitize', () {
    // Raw GFN offer shape: session-level transport attrs, ice-pwd is base64
    // with trailing '=' padding (GStreamer's parser rejects the '=', so it is
    // stripped before webrtcbin parses the offer — but the server's STUN
    // integrity uses the ORIGINAL padded value, which the bridge must restore
    // on the NICE streams).
    const rawOffer = 'v=0\r\n'
        'o=- 4373647202393833435 2 IN IP4 127.0.0.1\r\n'
        's=-\r\n'
        't=0 0\r\n'
        'a=group:BUNDLE 0 1 2\r\n'
        'a=ice-ufrag:Y1eQ\r\n'
        'a=ice-pwd:Vb3mMzRsfVdHt6+9zQvVtqQ=\r\n'
        'a=fingerprint:sha-256 8E:7A:32:0A:2B:4D:6F:91:1A:C5:D3:07:9E:21:44:66:88:AA\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'c=IN IP4 0.0.0.0\r\n'
        'a=mid:0\r\n'
        'a=rtpmap:96 H264/90000\r\n';

    test('extractIceCredentials on the RAW offer keeps the padded pwd', () {
      // This is what the transport captures BEFORE sanitization to hand the
      // bridge — it must see the original value with the '=' intact.
      final creds = GfnSdpMunger.extractIceCredentials(rawOffer);
      expect(creds.ufrag, 'Y1eQ');
      expect(creds.pwd, 'Vb3mMzRsfVdHt6+9zQvVtqQ=');
      expect(creds.fingerprint,
          '8E:7A:32:0A:2B:4D:6F:91:1A:C5:D3:07:9E:21:44:66:88:AA');
    });

    test('sanitizeIcePwdForGstreamer strips the padding (why restore exists)', () {
      final sanitized = GfnSdpMunger.sanitizeIcePwdForGstreamer(rawOffer);
      expect(sanitized, contains('a=ice-pwd:Vb3mMzRsfVdHt6+9zQvVtqQ\r\n'));
      expect(sanitized,
          isNot(contains('a=ice-pwd:Vb3mMzRsfVdHt6+9zQvVtqQ=\r\n')));
    });
  });

  group('restoreVideoRtx', () {
    // Offer shape captured from a real munged GFN offer: two H264 payloads
    // (96, 101), their rtx retransmission payloads (97 apt=96, 102 apt=101),
    // and flexfec-03 (98). The answer shape is what webrtcbin 1.28.5 actually
    // produced from it: it dropped BOTH rtx payloads and kept flexfec.
    const offer = 'v=0\r\n'
        'o=- 4373647202393833435 2 IN IP4 127.0.0.1\r\n'
        's=-\r\n'
        't=0 0\r\n'
        'a=group:BUNDLE 0 1 2\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96 101 97 102 98\r\n'
        'c=IN IP4 0.0.0.0\r\n'
        'a=mid:0\r\n'
        'a=rtpmap:96 H264/90000\r\n'
        'a=fmtp:96 profile-level-id=42001f;packetization-mode=1\r\n'
        'a=rtcp-fb:96 nack\r\n'
        'a=rtpmap:101 H264/90000\r\n'
        'a=fmtp:101 profile-level-id=42e01f;packetization-mode=1\r\n'
        'a=rtcp-fb:101 nack\r\n'
        'a=rtpmap:97 rtx/90000\r\n'
        'a=fmtp:97 apt=96\r\n'
        'a=rtcp-fb:97 nack\r\n'
        'a=rtpmap:102 rtx/90000\r\n'
        'a=fmtp:102 apt=101\r\n'
        'a=rtpmap:98 flexfec-03/90000\r\n';

    const answer = 'v=0\r\n'
        'o=- 4653287626563655709 2 IN IP4 0.0.0.0\r\n'
        's=-\r\n'
        't=0 0\r\n'
        'a=group:BUNDLE 0 1 2\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96 101 98\r\n'
        'c=IN IP4 0.0.0.0\r\n'
        'a=mid:0\r\n'
        'a=recvonly\r\n'
        'a=rtpmap:96 H264/90000\r\n'
        'a=rtpmap:101 H264/90000\r\n'
        'a=rtpmap:98 flexfec-03/90000\r\n'
        'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
        'a=mid:2\r\n';

    test('re-adds offer rtx payloads and drops flexfec from the answer', () {
      final out = GfnSdpMunger.restoreVideoRtx(answer, offer);

      // Video m-line: flexfec gone, rtx re-added after the negotiated H264s.
      expect(
        out,
        contains('m=video 9 UDP/TLS/RTP/SAVPF 96 101 97 102\r\n'),
      );
      expect(out, isNot(contains('rtpmap:98')));
      expect(out, isNot(contains(' 98\r\n')));

      // rtx rtpmap + apt fmtp + rtcp-fb restored from the offer.
      expect(out, contains('a=rtpmap:97 rtx/90000\r\n'));
      expect(out, contains('a=fmtp:97 apt=96\r\n'));
      expect(out, contains('a=rtcp-fb:97 nack\r\n'));
      expect(out, contains('a=rtpmap:102 rtx/90000\r\n'));
      expect(out, contains('a=fmtp:102 apt=101\r\n'));

      // Original H264 rtpmaps + section attrs survive.
      expect(out, contains('a=rtpmap:96 H264/90000\r\n'));
      expect(out, contains('a=rtpmap:101 H264/90000\r\n'));
      expect(out, contains('a=recvonly\r\n'));
      expect(out, contains('a=mid:0\r\n'));
      expect(out, contains('m=application 9 UDP/DTLS/SCTP webrtc-datachannel'));
    });

  group('mungeAnswerTransportExtras', () {
    // webrtcbin 1.28 answers drop the offer's transport-cc extmap, ICE
    // options, rtcp-rsize, and msid-semantic. OpenNOW's working webrtcbin
    // answer carries all four; the GFN video sender needs transport-cc.
    const answer = 'v=0\r\n'
        'o=- 1 2 IN IP4 0.0.0.0\r\n'
        's=-\r\n'
        't=0 0\r\n'
        'a=group:BUNDLE 0 1 2\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
        'a=mid:0\r\n'
        'a=rtpmap:111 OPUS/48000/2\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'a=mid:1\r\n'
        'a=rtpmap:96 H264/90000\r\n'
        'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
        'a=mid:2\r\n';
    const offer = 'v=0\r\n'
        'a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'a=mid:1\r\n';

    test('adds msid-semantic + extmap:3 + trickle + rtcp-rsize to media', () {
      final out = GfnSdpMunger.mungeAnswerTransportExtras(answer, offer);

      // v=0 must stay the first line (RFC 4566); msid-semantic goes in the
      // session block right before the first m= line.
      expect(out, startsWith('v=0\r\n'));
      expect(out, contains('t=0 0\r\n'
          'a=group:BUNDLE 0 1 2\r\n'
          'a=msid-semantic: WMS\r\n'
          'm=audio'));
      // Video + audio sections get the transport extras after their a=mid.
      expect(out, contains('a=mid:0\r\n'
          'a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n'
          'a=ice-options:trickle\r\n'
          'a=rtcp-rsize\r\n'));
      expect(out, contains('a=mid:1\r\n'
          'a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n'
          'a=ice-options:trickle\r\n'
          'a=rtcp-rsize\r\n'));
      // The application section is untouched.
      expect(out, contains('m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
          'a=mid:2\r\n'));
      // Codec lines survive.
      expect(out, contains('a=rtpmap:96 H264/90000'));
      expect(out, contains('a=rtpmap:111 OPUS/48000/2'));
    });

    test('does not duplicate msid-semantic when already present', () {
      final withSemantic = 'a=msid-semantic: WMS\r\n$answer';
      final out =
          GfnSdpMunger.mungeAnswerTransportExtras(withSemantic, offer);
      expect(RegExp('a=msid-semantic').allMatches(out).length, 1);
    });
  });

  group('preferCodec keeps flexfec (OpenNOW parity)', () {
    test('keeps FLEXFEC-03 payload when filtering to H264', () {
      const sdp = 'v=0\r\n'
          'm=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99\r\n'
          'a=rtpmap:96 H264/90000\r\n'
          'a=rtpmap:97 rtx/90000\r\n'
          'a=fmtp:97 apt=96\r\n'
          'a=rtpmap:98 flexfec-03/90000\r\n'
          'a=rtpmap:99 H265/90000\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';
      final out = GfnSdpMunger.preferCodec(sdp, 'H264');
      expect(out, contains('m=video 9 UDP/TLS/RTP/SAVPF 96 97 98'));
      expect(out, contains('a=rtpmap:98 flexfec-03/90000'));
      expect(out, isNot(contains('a=rtpmap:99')));
    });
  });

    test('returns answer unchanged when the offer has no rtx payloads', () {
      // Strip rtx from BOTH the m-line and its rtpmap/fmtp attrs — rtxApt is
      // built from rtpmap lines, so removing just the payload numbers would
      // still trigger the restore path.
      final noRtxOffer = offer
          .replaceAll('97 102 ', '')
          .replaceAll('a=rtpmap:97 rtx/90000\r\n', '')
          .replaceAll('a=fmtp:97 apt=96\r\n', '')
          .replaceAll('a=rtcp-fb:97 nack\r\n', '')
          .replaceAll('a=rtpmap:102 rtx/90000\r\n', '')
          .replaceAll('a=fmtp:102 apt=101\r\n', '');
      expect(GfnSdpMunger.restoreVideoRtx(answer, noRtxOffer), answer);
    });
  });
}
