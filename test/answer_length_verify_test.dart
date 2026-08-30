import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:next_client/state/gfn_sdp_munger.dart';

void main() {
  test('post-munge lengths: no-direction vs sendonly', () {
    final fixture = File('/tmp/gfn_munged2.sdp');
    final harness = File('/tmp/webrtc_neg_test');
    if (!fixture.existsSync() || !harness.existsSync()) {
      // Requires a live capture + the webrtc_neg_test harness in /tmp
      // (see native/gst_bridge/tools). Skip on machines without them.
      return;
    }
    final noDir = fixture.readAsStringSync();
    // Regenerate answers via subprocess: harness writes /tmp/answer.sdp
    // no-direction offer first
    Process.runSync('/tmp/webrtc_neg_test', ['/tmp/gfn_munged2.sdp']);
    final rawNoDir = File('/tmp/answer.sdp').readAsStringSync();
    // sendonly offer
    Process.runSync('/tmp/webrtc_neg_test', ['/tmp/test_sendonly.sdp']);
    final rawSendonly = File('/tmp/answer.sdp').readAsStringSync();

    String munge(String raw) {
      var m = GfnSdpMunger.mungeAnswerSdp(raw, 75000);
      return GfnSdpMunger.mungeAnswerForGfn(m);
    }

    final noDirMunged = munge(rawNoDir);
    final sendonlyMunged = munge(rawSendonly);
    print('raw no-dir: ${rawNoDir.length}  munged: ${noDirMunged.length}');
    print('raw sendonly: ${rawSendonly.length}  munged: ${sendonlyMunged.length}');
    print('--- no-dir m-lines ---');
    for (final l in noDirMunged.split('\n')) { if (l.startsWith('m=') || l.startsWith('a=group:BUNDLE')) print(l); }
    print('--- sendonly m-lines ---');
    for (final l in sendonlyMunged.split('\n')) { if (l.startsWith('m=') || l.startsWith('a=group:BUNDLE') || l.startsWith('a=recvonly')) print(l); }
    // The live app logged 2080 chars. Which one matches?
    expect(noDirMunged.length, inInclusiveRange(2075, 2085));
    expect(sendonlyMunged.length, lessThan(1800));
  });
}
