import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:next_client/state/gfn_sdp_munger.dart';

void main() {
  test('REAL offer: full pipeline + addMediaDirection changes the offer', () {
    final raw = File('/tmp/gfn_offer.sdp').readAsStringSync();
    expect(raw, contains('m=video'), reason: 'real offer loaded');

    var p = GfnSdpMunger.fixServerIp(raw, '80.250.97.40');
    p = GfnSdpMunger.duplicateSessionWebrtcAttributesToMedia(p);
    p = GfnSdpMunger.preferCodec(p, 'H264');
    p = GfnSdpMunger.alignVideoSdpFramerateForGstreamer(p, 60);
    p = GfnSdpMunger.sanitizeIcePwdForGstreamer(p);
    final before = p;
    final directed = GfnSdpMunger.addMediaDirection(p);

    expect(directed, isNot(equals(before)), reason: 'addMediaDirection must change the offer');
    expect(directed, contains('a=sendonly'));
    final videoSection = directed.split('m=').firstWhere((s) => s.startsWith('video'));
    expect(videoSection, contains('a=sendonly'));
    final appSection = directed.split('m=').firstWhere((s) => s.startsWith('application'));
    expect(appSection, isNot(contains('a=sendonly')));
    // no direction attr in the raw GFN offer -> webrtcbin would reject without this
    expect(raw.contains(RegExp(r'^a=(sendrecv|sendonly|recvonly|inactive)', multiLine: true)), isFalse);
    print('PIPELINE OK — direction fix applies to the real offer');
  });
}
