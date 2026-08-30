import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:next_client/state/gfn_sdp_munger.dart';

void main() {
  test('munge the real webrtcbin answer', () {
    final fixture = File('/tmp/gfn_diag/raw_answer.sdp');
    if (!fixture.existsSync()) {
      // Requires a live webrtcbin answer capture in /tmp/gfn_diag
      // (see native/gst_bridge/tools). Skip on machines without it.
      return;
    }
    final raw = fixture.readAsStringSync();
    var m = GfnSdpMunger.mungeAnswerSdp(raw, 75000);
    final gfn = GfnSdpMunger.mungeAnswerForGfn(m);
    File('/tmp/gfn_diag/final_answer.sdp').writeAsStringSync(gfn);
    print('=== FINAL ANSWER (sent to server) ===');
    for (final l in gfn.split('\n')) {
      if (l.startsWith('m=') || l.startsWith('a=recvonly') || l.startsWith('a=sendonly') || l.startsWith('a=inactive') || l.startsWith('a=group:BUNDLE') || l.startsWith('a=mid:') || l.startsWith('a=ice-ufrag:') || l.startsWith('a=fingerprint:')) print('  $l');
    }
    final creds = GfnSdpMunger.extractIceCredentials(gfn);
    print('CREDS ufrag=${creds.ufrag} pwd=${creds.pwd} fp=${creds.fingerprint}');
  });
}
