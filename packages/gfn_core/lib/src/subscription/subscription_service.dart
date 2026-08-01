import 'dart:convert' show jsonDecode;

import 'package:http/http.dart' as http;

import '../http/client.dart'
    show GfnLcarsHeadersOptions, buildGfnLcarsHeaders;
import '../models/catalog.dart' show StreamRegion;
import '../models/subscription.dart';

// Port of subscription.ts

const mesUrl = 'https://mes.geforcenow.com/v4/subscriptions';

class SubscriptionService {
  final http.Client client;
  final bool isMac;

  SubscriptionService({required this.client, required this.isMac});

  /// Port of fetchSubscription
  Future<SubscriptionInfo> fetchSubscription({
    required String token,
    required String userId,
    String vpcId = 'NP-AMS-08',
  }) async {
    final uri = Uri.parse(mesUrl).replace(queryParameters: {
      'serviceName': 'gfn_pc',
      'languageCode': 'en_US',
      'vpcId': vpcId,
      'userId': userId,
    });

    final response = await client.get(
      uri,
      headers: buildGfnLcarsHeaders(
        GfnLcarsHeadersOptions(
          token: token,
          clientType: 'NATIVE',
          clientStreamer: 'NVIDIA-CLASSIC',
        ),
        isMac: isMac,
      ),
    );

    if (response.statusCode != 200) {
      throw StateError(
        'Subscription API failed with status ${response.statusCode}: ${_snippet(response.body)}',
      );
    }

    final data = _decodeObject(response.body);
    return _parseSubscription(data, vpcId);
  }

  /// Port of fetchDynamicRegions
  Future<({List<StreamRegion> regions, String? vpcId})> fetchDynamicRegions({
    String? token,
    required String streamingBaseUrl,
  }) async {
    final base = streamingBaseUrl.endsWith('/')
        ? streamingBaseUrl
        : '$streamingBaseUrl/';
    final url = '$base' 'v2/serverInfo';

    final headers = buildGfnLcarsHeaders(
      GfnLcarsHeadersOptions(
        token: token,
        clientType: 'BROWSER',
        clientStreamer: 'WEBRTC',
      ),
      isMac: isMac,
    );

    http.Response response;
    try {
      response = await client.get(Uri.parse(url), headers: headers);
    } catch (_) {
      return (regions: <StreamRegion>[], vpcId: null);
    }

    if (response.statusCode != 200) {
      return (regions: <StreamRegion>[], vpcId: null);
    }

    final data = _decodeObject(response.body);
    final requestStatus = data['requestStatus'];
    final vpcId = requestStatus is Map ? requestStatus['serverId'] as String? : null;

    final metadata = data['metaData'];
    final regions = <StreamRegion>[];
    if (metadata is List) {
      for (final entry in metadata) {
        if (entry is! Map) continue;
        final value = entry['value'];
        final key = entry['key'];
        if (value is! String || !value.startsWith('https://')) continue;
        if (key == 'gfn-regions' || (key is String && key.startsWith('gfn-'))) continue;
        regions.add(StreamRegion(
          name: key as String,
          url: value.endsWith('/') ? value : '$value/',
        ));
      }
    }
    regions.sort((a, b) => a.name.compareTo(b.name));

    return (regions: regions, vpcId: vpcId);
  }

  SubscriptionInfo _parseSubscription(Map<String, dynamic> data, String vpcId) {
    final membershipTier = data['membershipTier'] as String? ?? 'FREE';

    final allottedMinutes = _parseMinutes(data['allottedTimeInMinutes']) ?? 0;
    final purchasedMinutes = _parseMinutes(data['purchasedTimeInMinutes']) ?? 0;
    final rolledOverMinutes = _parseMinutes(data['rolledOverTimeInMinutes']) ?? 0;
    final fallbackTotalMinutes =
        allottedMinutes + purchasedMinutes + rolledOverMinutes;
    final totalMinutes =
        _parseMinutes(data['totalTimeInMinutes']) ?? fallbackTotalMinutes;
    final remainingMinutes = _parseMinutes(data['remainingTimeInMinutes']) ?? 0;
    final usedMinutes = totalMinutes - remainingMinutes < 0
        ? 0
        : totalMinutes - remainingMinutes;

    final isUnlimited = data['subType'] == 'UNLIMITED';

    StorageAddon? storageAddon;
    final addons = data['addons'];
    if (addons is List) {
      for (final addon in addons) {
        if (addon is! Map) continue;
        if (addon['type'] != 'STORAGE' ||
            addon['subType'] != 'PERMANENT_STORAGE' ||
            addon['status'] != 'OK') {
          continue;
        }
        final attrs = addon['attributes'];
        String? attr(String key) {
          if (attrs is! List) return null;
          for (final attr in attrs) {
            if (attr is! Map) continue;
            if (attr['key'] == key) return attr['textValue'] as String?;
          }
          return null;
        }

        storageAddon = StorageAddon(
          type: 'PERMANENT_STORAGE',
          sizeGb: _parseNumberText(attr('TOTAL_STORAGE_SIZE_IN_GB')),
          usedGb: _parseNumberText(attr('USED_STORAGE_SIZE_IN_GB')),
          regionName: attr('STORAGE_METRO_REGION_NAME'),
          regionCode: attr('STORAGE_METRO_REGION'),
        );
        break;
      }
    }

    final entitledResolutions = <EntitledResolution>[];
    final features = data['features'];
    final resolutions =
        features is Map ? features['resolutions'] : null;
    if (resolutions is List) {
      for (final res in resolutions) {
        if (res is! Map) continue;
        if (res['isEntitled'] != true) continue;
        entitledResolutions.add(EntitledResolution(
          width: (res['widthInPixels'] as num).toInt(),
          height: (res['heightInPixels'] as num).toInt(),
          fps: (res['framesPerSecond'] as num).toInt(),
        ));
      }
      entitledResolutions.sort((a, b) {
        if (b.width != a.width) return b.width - a.width;
        if (b.height != a.height) return b.height - a.height;
        return b.fps - a.fps;
      });
    }

    final currentState = data['currentSubscriptionState'];
    return SubscriptionInfo(
      membershipTier: membershipTier,
      subscriptionType: data['type'] as String?,
      subscriptionSubType: data['subType'] as String?,
      allottedHours: allottedMinutes / 60,
      purchasedHours: purchasedMinutes / 60,
      rolledOverHours: rolledOverMinutes / 60,
      usedHours: usedMinutes / 60,
      remainingHours: remainingMinutes / 60,
      totalHours: totalMinutes / 60,
      firstEntitlementStartDateTime: data['firstEntitlementStartDateTime'] as String?,
      serverRegionId: vpcId,
      currentSpanStartDateTime: data['currentSpanStartDateTime'] as String?,
      currentSpanEndDateTime: data['currentSpanEndDateTime'] as String?,
      isUnlimited: isUnlimited,
      storageAddon: storageAddon,
      entitledResolutions: entitledResolutions,
      isGamePlayAllowed: currentState is Map
          ? currentState['isGamePlayAllowed'] as bool?
          : null,
    );
  }

  double? _parseMinutes(Object? value) {
    if (value is num && value.isFinite) return value.toDouble();
    if (value is String && value.trim().isNotEmpty) {
      return double.tryParse(value);
    }
    return null;
  }

  double? _parseNumberText(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return double.tryParse(value);
  }

  Map<String, dynamic> _decodeObject(String text) {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    throw FormatException('Subscription response was not a JSON object');
  }

  String _snippet(String text) {
    return text.length > 400 ? text.substring(0, 400) : text;
  }
}