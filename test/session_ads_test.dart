import 'package:flutter_test/flutter_test.dart';
import 'package:gfn_core/gfn_core.dart';

void main() {
  group('reportSessionAd wire codes', () {
    test('maps actions to OpenNOW AD_ACTION_CODES', () {
      expect(adActionWireCode(SessionAdAction.start), 1);
      expect(adActionWireCode(SessionAdAction.pause), 2);
      expect(adActionWireCode(SessionAdAction.resume), 3);
      expect(adActionWireCode(SessionAdAction.finish), 4);
      expect(adActionWireCode(SessionAdAction.cancel), 5);
    });
  });

  group('extractAdState', () {
    test('parses adMediaFiles, prefers MP4, converts adLengthInSeconds->ms',
        () {
      final state = extractAdState({
        'sessionAdsRequired': true,
        'sessionAds': [
          {
            'adId': 'creative-1',
            'title': 'Fancy Ad',
            'description': 'A description',
            'adLengthInSeconds': 15,
            'adMediaFiles': [
              {'encodingProfile': 'hlsadaptive', 'mediaFileUrl': 'https://h'},
              {
                'encodingProfile': 'mp4deinterlaced720p',
                'mediaFileUrl': 'https://mp4',
              },
              {'encodingProfile': 'webm', 'mediaFileUrl': 'https://webm'},
            ],
          },
        ],
      });

      expect(state, isNotNull);
      expect(state!.isAdsRequired, isTrue);
      expect(state.serverSentEmptyAds, isFalse);
      expect(state.sessionAds, hasLength(1));
      final ad = state.sessionAds.first;
      // MP4 outranks HLS, so mediaUrl must be the mp4 source.
      expect(ad.mediaUrl, 'https://mp4');
      // adLengthInSeconds is the confirmed live field (seconds -> ms).
      expect(ad.durationMs, 15000);
      expect(ad.adLengthInSeconds, 15);
      expect(ad.title, 'Fancy Ad');
      expect(ad.description, 'A description');
      expect(ad.adMediaFiles, hasLength(3));
    });

    test('prefers adLengthInSeconds over legacy durationMs', () {
      final state = extractAdState({
        'sessionAdsRequired': true,
        'sessionAds': [
          {
            'adId': 'creative-2',
            'adUrl': 'https://a',
            'durationMs': 5000,
            'adLengthInSeconds': 20,
          },
        ],
      });
      expect(state!.sessionAds.single.durationMs, 20000);
    });

    test('marks serverSentEmptyAds when sessionAds is null', () {
      final state = extractAdState({
        'sessionAdsRequired': true,
        'sessionAds': null,
      });
      expect(state, isNotNull);
      expect(state!.isAdsRequired, isTrue);
      expect(state.sessionAds, isEmpty);
      expect(state.serverSentEmptyAds, isTrue);
    });

    test('drops ads with no usable content', () {
      final state = extractAdState({
        'sessionAdsRequired': true,
        'sessionAds': [
          {'adLengthInSeconds': 10}, // no id, url, media, title, description
          {'adId': 'ok', 'adUrl': 'https://ok'},
        ],
      });
      expect(state!.sessionAds, hasLength(1));
      expect(state.sessionAds.single.adId, 'ok');
    });

    test('returns null when no ads required and nothing present', () {
      expect(extractAdState({'status': 1}), isNull);
    });
  });

  group('mergeAdState', () {
    SessionAdState stateWith(String id) => SessionAdState(
          isAdsRequired: true,
          sessionAdsRequired: true,
          sessionAds: [SessionAdInfo(adId: id)],
          ads: [SessionAdInfo(adId: id)],
        );

    test('restores previous ads on a transient null sessionAds gap', () {
      final previous = stateWith('creative-1');
      final next = SessionAdState(
        isAdsRequired: true,
        sessionAdsRequired: true,
        sessionAds: const [],
        ads: const [],
        serverSentEmptyAds: true,
      );
      final merged = mergeAdState(previous, next);
      expect(merged!.sessionAds.single.adId, 'creative-1');
    });

    test('does NOT restore when serverSentEmptyAds is false', () {
      final previous = stateWith('creative-1');
      final next = SessionAdState(
        isAdsRequired: true,
        sessionAdsRequired: true,
        sessionAds: const [],
        ads: const [],
        serverSentEmptyAds: false,
      );
      expect(mergeAdState(previous, next)!.sessionAds, isEmpty);
    });

    test('returns next when next has its own ads', () {
      final previous = stateWith('creative-1');
      final next = stateWith('creative-2');
      expect(mergeAdState(previous, next)!.sessionAds.single.adId, 'creative-2');
    });
  });

  group('mergePolledSessionState', () {
    SessionInfo base() => const SessionInfo(
          sessionId: 's1',
          appId: '123',
          status: 1,
          zone: 'dc',
          serverIp: '1.2.3.4',
          signalingServer: 's',
          signalingUrl: 'u',
          iceServers: [],
        );

    test('preserves adState across polls while queued', () {
      final previous = base().copyWith(
        adState: SessionAdState(
          isAdsRequired: true,
          sessionAdsRequired: true,
          sessionAds: [const SessionAdInfo(adId: 'ad-1')],
          ads: [const SessionAdInfo(adId: 'ad-1')],
        ),
      );
      final next = base().copyWith(
        status: 1,
        adState: const SessionAdState(
          isAdsRequired: true,
          sessionAdsRequired: true,
          sessionAds: [],
          ads: [],
          serverSentEmptyAds: true,
        ),
      );
      final merged = mergePolledSessionState(previous, next);
      expect(merged.adState!.sessionAds.single.adId, 'ad-1');
    });

    test('keeps previous appLaunchMode when next omits it', () {
      final previous = base().copyWith(appLaunchMode: 2);
      final merged = mergePolledSessionState(previous, base());
      expect(merged.appLaunchMode, 2);
    });
  });
}
