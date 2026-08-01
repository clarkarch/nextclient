import 'dart:convert' show jsonDecode;

import 'package:http/http.dart' as http;

import '../http/client.dart'
    show GfnLcarsHeadersOptions, buildGfnLcarsHeaders;
import '../models/catalog.dart';
import '../models/game_details.dart';
import 'graphql.dart'
    show LcarsQueryName, fetchLcarsGraphQl, throwGraphQlErrors;

// Port of gameAppMapper.ts getVpcId + catalogBrowse.ts
const defaultLocale = 'en_US';
const defaultCloudmatchBaseUrl = 'https://prod.cloudmatchbeta.nvidiagrid.net/';
const maxCatalogPages = 3;

class CatalogService {
  final http.Client client;
  final bool isMac;

  CatalogService({required this.client, required this.isMac});

  /// Port of gameAppMapper.ts getVpcId — resolves the server's VPC ID.
  Future<String> getVpcId({
    String? token,
    String? providerStreamingBaseUrl,
  }) async {
    Uri validatedBaseUrl;
    try {
      final candidate =
          Uri.parse(providerStreamingBaseUrl?.trim() ?? defaultCloudmatchBaseUrl);
      final hostname = candidate.host.toLowerCase();
      if (candidate.scheme != 'https' ||
          (hostname != 'prod.cloudmatchbeta.nvidiagrid.net' &&
              hostname != 'img.nvidiagrid.net' &&
              !hostname.endsWith('.geforcenow.nvidiagrid.net'))) {
        validatedBaseUrl = Uri.parse(defaultCloudmatchBaseUrl);
      } else {
        validatedBaseUrl = candidate;
      }
    } catch (_) {
      validatedBaseUrl = Uri.parse(defaultCloudmatchBaseUrl);
    }

    final serverInfoUrl = validatedBaseUrl.resolve('v2/serverInfo');
    final response = await client.get(
      serverInfoUrl,
      headers: buildGfnLcarsHeaders(
        GfnLcarsHeadersOptions(
          token: token,
          clientType: 'NATIVE',
          clientStreamer: 'NVIDIA-CLASSIC',
          includeUserAgent: true,
          includeEmptyTokenAuthorization: true,
        ),
        isMac: isMac,
      ),
    );

    if (response.statusCode != 200) return 'GFN-PC';

    final decoded = jsonDecode(response.body);
    final requestStatus =
        decoded is Map ? decoded['requestStatus'] : null;
    final serverId = requestStatus is Map ? requestStatus['serverId'] : null;
    return serverId is String && serverId.isNotEmpty ? serverId : 'GFN-PC';
  }

  /// Port of catalogBrowse.ts fetchPanels — fetch home/library/marquee panels.
  Future<Map<String, dynamic>> fetchPanels({
    required String token,
    required List<String> panelNames,
    String? providerStreamingBaseUrl,
    bool withLibraryTime = false,
  }) async {
    final vpcId = await getVpcId(
      token: token,
      providerStreamingBaseUrl: providerStreamingBaseUrl,
    );

    final LcarsQueryName queryName;
    if (panelNames.contains('MARQUEE')) {
      queryName = LcarsQueryName.marquee;
    } else if (panelNames.contains('LIBRARY')) {
      queryName = withLibraryTime
          ? LcarsQueryName.librarySectionWithTime
          : LcarsQueryName.librarySection;
    } else {
      queryName = LcarsQueryName.main;
    }

    return fetchLcarsGraphQl(
      client: client,
      queryName: queryName,
      variables: {
        'vpcId': vpcId,
        'locale': defaultLocale,
        'panelNames': panelNames,
      },
      token: token,
      isMac: isMac,
      context: 'Games GraphQL failed',
    );
  }

  /// Port of catalogBrowse.ts flattenPanels
  List<CatalogGame> flattenPanels(Map<String, dynamic> payload) {
    final errors = payload['errors'];
    if (errors is List && errors.isNotEmpty) {
      throwGraphQlErrors(errors, 'Games GraphQL failed');
    }

    final games = <CatalogGame>[];
    final panels = (payload['data'] as Map<String, dynamic>?)?['panels'];
    if (panels is List) {
      for (final panel in panels) {
        if (panel is! Map<String, dynamic>) continue;
        final sections = panel['sections'];
        if (sections is List) {
          for (final section in sections) {
            if (section is! Map<String, dynamic>) continue;
            final items = section['items'];
            if (items is List) {
              for (final item in items) {
                if (item is! Map<String, dynamic>) continue;
                if (item['__typename'] != 'GameItem') continue;
                final app = item['app'];
                if (app is! Map<String, dynamic>) continue;
                games.add(CatalogGame.fromJson(item));
              }
            }
          }
        }
      }
    }

    return dedupeGames(games);
  }

  /// Port of catalogBrowse.ts fetchMainGamesUncached
  Future<List<CatalogGame>> fetchMainGamesUncached({
    required String token,
    String? providerStreamingBaseUrl,
  }) async {
    final payload = await fetchPanels(
      token: token,
      panelNames: ['MAIN'],
      providerStreamingBaseUrl: providerStreamingBaseUrl,
    );
    return flattenPanels(payload);
  }

  /// Port of catalogBrowse.ts featuredGamesFromPanels + fetchFeaturedGames
  Future<List<CatalogGame>> fetchFeaturedGames({
    required String token,
    String? providerStreamingBaseUrl,
  }) async {
    final payload = await fetchPanels(
      token: token,
      panelNames: ['MARQUEE'],
      providerStreamingBaseUrl: providerStreamingBaseUrl,
    );
    final games = flattenPanels(payload);
    return games.take(6).toList();
  }

  /// Port of catalogBrowse.ts fetchPanels with LIBRARY panels — the user's
  /// actual library (owned/connected games).
  Future<List<CatalogGame>> fetchLibraryGamesUncached({
    required String token,
    String? providerStreamingBaseUrl,
  }) async {
    final payload = await fetchPanels(
      token: token,
      panelNames: ['LIBRARY'],
      providerStreamingBaseUrl: providerStreamingBaseUrl,
    );
    return flattenPanels(payload);
  }

  /// Library games that have a recorded play date, newest first. Port of
  /// OpenNOW's recently-played derivation using the `librarySectionWithTime`
  /// persisted query (`lastPlayedDate`).
  Future<List<CatalogGame>> fetchRecentlyPlayed({
    required String token,
    String? providerStreamingBaseUrl,
  }) async {
    final payload = await fetchPanels(
      token: token,
      panelNames: ['LIBRARY'],
      providerStreamingBaseUrl: providerStreamingBaseUrl,
      withLibraryTime: true,
    );
    final games = flattenPanels(payload)
        .where((g) => g.lastPlayedDate != null)
        .toList()
      ..sort((a, b) => b.lastPlayedDate!.compareTo(a.lastPlayedDate!));
    return games;
  }

  /// Rich metadata for a single app from the `appDataForAppId` persisted query.
  Future<GameDetails> fetchGameDetails({
    required String token,
    required String appId,
    String? providerStreamingBaseUrl,
  }) async {
    final vpcId = await getVpcId(
      token: token,
      providerStreamingBaseUrl: providerStreamingBaseUrl,
    );
    final payload = await fetchLcarsGraphQl(
      client: client,
      queryName: LcarsQueryName.appDataForAppId,
      variables: {
        'vpcId': vpcId,
        'locale': defaultLocale,
        'appIds': [appId],
      },
      token: token,
      isMac: isMac,
      context: 'Game details GraphQL failed',
    );

    final errors = payload['errors'];
    if (errors is List && errors.isNotEmpty) {
      throwGraphQlErrors(errors, 'Game details GraphQL failed');
    }

    final items = (payload['data'] as Map<String, dynamic>?)?['apps'] is Map
        ? ((payload['data'] as Map<String, dynamic>)['apps']
                as Map<String, dynamic>)['items']
        : null;
    if (items is! List || items.isEmpty || items.first is! Map<String, dynamic>) {
      throw StateError('Game details returned no app for appId $appId');
    }
    return GameDetails.fromJson(items.first as Map<String, dynamic>);
  }
}

/// Port of gameAppMapper.ts dedupeGames — dedupe by id.
List<CatalogGame> dedupeGames(List<CatalogGame> games) {
  final byId = <String, CatalogGame>{};
  for (final game in games) {
    byId.putIfAbsent(game.id, () => game);
  }
  return byId.values.toList();
}