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

  String? _cachedVpcId;
  final Map<String, ({DateTime at, List<CatalogGame> games})> _cache = {};

  static const _cacheTtl = Duration(minutes: 5);

  CatalogService({required this.client, required this.isMac});

  List<CatalogGame>? _cached(String key) {
    final hit = _cache[key];
    if (hit == null) return null;
    if (DateTime.now().difference(hit.at) > _cacheTtl) {
      _cache.remove(key);
      return null;
    }
    return hit.games;
  }

  void _store(String key, List<CatalogGame> games) {
    _cache[key] = (at: DateTime.now(), games: games);
  }

  /// Port of gameAppMapper.ts getVpcId — resolves the server's VPC ID.
  /// Cached for the lifetime of the service.
  Future<String> getVpcId({
    String? token,
    String? providerStreamingBaseUrl,
  }) async {
    final cached = _cachedVpcId;
    if (cached != null) return cached;
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

    if (response.statusCode != 200) {
      _cachedVpcId = 'GFN-PC';
      return _cachedVpcId!;
    }

    final decoded = jsonDecode(response.body);
    final requestStatus =
        decoded is Map ? decoded['requestStatus'] : null;
    final serverId = requestStatus is Map ? requestStatus['serverId'] : null;
    _cachedVpcId = serverId is String && serverId.isNotEmpty
        ? serverId
        : 'GFN-PC';
    return _cachedVpcId!;
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
    final cached = _cached('main');
    if (cached != null) return cached;
    final payload = await fetchPanels(
      token: token,
      panelNames: ['MAIN'],
      providerStreamingBaseUrl: providerStreamingBaseUrl,
    );
    final games = flattenPanels(payload);
    _store('main', games);
    return games;
  }

  /// Port of catalogBrowse.ts featuredGamesFromPanels + fetchFeaturedGames
  Future<List<CatalogGame>> fetchFeaturedGames({
    required String token,
    String? providerStreamingBaseUrl,
  }) async {
    final cached = _cached('featured');
    if (cached != null) return cached;
    final payload = await fetchPanels(
      token: token,
      panelNames: ['MARQUEE'],
      providerStreamingBaseUrl: providerStreamingBaseUrl,
    );
    final games = flattenPanels(payload).take(6).toList();
    _store('featured', games);
    return games;
  }

  /// Port of catalogBrowse.ts fetchPanels with LIBRARY panels — the user's
  /// actual library (owned/connected games).
  Future<List<CatalogGame>> fetchLibraryGamesUncached({
    required String token,
    String? providerStreamingBaseUrl,
  }) async {
    final cached = _cached('library');
    if (cached != null) return cached;
    final payload = await fetchPanels(
      token: token,
      panelNames: ['LIBRARY'],
      providerStreamingBaseUrl: providerStreamingBaseUrl,
    );
    final games = flattenPanels(payload);
    _store('library', games);
    return games;
  }

  /// Library games that have a recorded play date, newest first. Port of
  /// OpenNOW's recently-played derivation using the `librarySectionWithTime`
  /// persisted query (`lastPlayedDate`).
  Future<List<CatalogGame>> fetchRecentlyPlayed({
    required String token,
    String? providerStreamingBaseUrl,
  }) async {
    final cached = _cached('recent');
    if (cached != null) return cached;
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
    _store('recent', games);
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

  /// Filter groups + sort orders from `filterGroupAndSortOrderDefinitions`.
  Future<CatalogDefinitions> fetchFilterSortDefinitions({
    required String token,
  }) async {
    final payload = await fetchLcarsGraphQl(
      client: client,
      queryName: LcarsQueryName.filterGroupAndSortOrderDefinitions,
      variables: {'locale': defaultLocale},
      token: token,
      isMac: isMac,
      context: 'GFN filter definitions failed',
    );

    final errors = payload['errors'];
    if (errors is List && errors.isNotEmpty) {
      throwGraphQlErrors(errors, 'GFN filter definitions failed');
    }

    final data = payload['data'] as Map<String, dynamic>? ?? const {};
    final groups = (data['filterGroupDefinitions'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(CatalogFilterGroup.fromJson)
        .where((g) => g.id.isNotEmpty && g.options.isNotEmpty)
        .toList();
    final sortOptions = (data['sortOrderDefinitions'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(CatalogSortOption.fromJson)
        .where((s) => s.id.isNotEmpty && s.orderBy.isNotEmpty)
        .toList();

    final filterPayloadById = <String, Map<String, dynamic>>{};
    for (final group in groups) {
      for (final option in group.options) {
        filterPayloadById[option.id] = option.payload;
      }
    }

    return CatalogDefinitions(
      groups: groups,
      sortOptions: sortOptions,
      filterPayloadById: filterPayloadById,
    );
  }

  /// Server-side catalog browse with search, sort and filters. Port of
  /// catalogBrowse.ts browseCatalogUncached using the `apps` persisted
  /// queries (`appsWithSearch` / `appsWithoutSearch`), paginated.
  Future<CatalogBrowseResult> browseCatalog({
    required String token,
    String? searchQuery,
    String? sortId,
    List<String> filterIds = const [],
    int fetchCount = 60,
    String? providerStreamingBaseUrl,
  }) async {
    final vpcId = await getVpcId(
      token: token,
      providerStreamingBaseUrl: providerStreamingBaseUrl,
    );
    final definitions = await fetchFilterSortDefinitions(token: token);

    final query = searchQuery?.trim() ?? '';
    final normalized = filterIds
        .where(definitions.filterPayloadById.containsKey)
        .toList();
    final selectedSort = definitions.sortOptions
            .where((o) => o.id == sortId)
            .firstOrNull ??
        definitions.sortOptions.firstOrNull ??
        const CatalogSortOption(
          id: 'relevance',
          label: 'Relevance',
          orderBy: 'itemMetadata.relevance:DESC,sortName:ASC',
        );
    final filters = definitions.mergeFilterPayloads(normalized);

    final games = <CatalogGame>[];
    var cursor = '';
    var hasNextPage = true;
    var endCursor = '';
    var numberReturned = 0;
    var numberSupported = 0;
    var totalCount = 0;

    for (var page = 0; page < maxCatalogPages && hasNextPage; page++) {
      final variables = <String, Object>{
        'vpcId': vpcId,
        'locale': defaultLocale,
        'sortString': selectedSort.orderBy,
        'fetchCount': fetchCount,
        'cursor': cursor,
        if (query.isNotEmpty) 'searchString': query,
        'filters': filters,
      };
      final payload = await fetchLcarsGraphQl(
        client: client,
        queryName: query.isNotEmpty
            ? LcarsQueryName.appsWithSearch
            : LcarsQueryName.appsWithoutSearch,
        variables: variables,
        token: token,
        isMac: isMac,
        context: 'GFN catalog query failed',
        fallbackQuery:
            query.isNotEmpty ? _searchBrowseQuery : _filterBrowseQuery,
      );

      final errors = payload['errors'];
      if (errors is List && errors.isNotEmpty) {
        throwGraphQlErrors(errors, 'GFN catalog query failed');
      }

      final apps = (payload['data'] as Map<String, dynamic>?)?['apps'];
      if (apps is! Map<String, dynamic>) break;

      final items = apps['items'];
      if (items is List) {
        for (final item in items) {
          if (item is Map<String, dynamic>) {
            games.add(CatalogGame.fromJson(item));
          }
        }
      }
      numberReturned = (apps['numberReturned'] as num?)?.toInt() ?? numberReturned;
      numberSupported = (apps['numberSupported'] as num?)?.toInt() ?? numberSupported;
      totalCount = (apps['totalCount'] as num?)?.toInt() ?? totalCount;

      final pageInfo = apps['pageInfo'];
      if (pageInfo is Map<String, dynamic>) {
        hasNextPage = (pageInfo['hasNextPage'] as bool?) ?? false;
        endCursor = (pageInfo['endCursor'] as String?) ?? '';
      }
      cursor = endCursor;
    }

    return CatalogBrowseResult(
      games: dedupeGames(games),
      hasNextPage: hasNextPage,
      endCursor: endCursor,
      numberReturned: numberReturned,
      numberSupported: numberSupported,
      totalCount: totalCount,
    );
  }
}

/// Fields requested from the `apps` browse query. A trimmed superset of what
/// [CatalogGame.fromJson] reads.
const _browseFields = '''
  numberReturned
  numberSupported
  pageInfo { hasNextPage endCursor totalCount }
  items {
    id
    title
    images { KEY_ART KEY_IMAGE GAME_BOX_ART TV_BANNER HERO_IMAGE MARQUEE_HERO_IMAGE FEATURE_IMAGE GAME_LOGO }
    variants {
      id
      shortName
      appStore
      supportedControls
      gfn {
        status
        library { status selected }
      }
    }
    gfn {
      playabilityState
      minimumMembershipTierLabel
    }
  }
''';

const _filterBrowseQuery = '''
query GetFilterBrowseResults(
  \$vpcId: String!,
  \$locale: String!,
  \$sortString: String!,
  \$fetchCount: Int!,
  \$cursor: String!,
  \$filters: AppFilterFields!
) {
  apps(
    vpcId: \$vpcId,
    language: \$locale,
    orderBy: \$sortString,
    first: \$fetchCount,
    after: \$cursor,
    filters: \$filters
  ) {
$_browseFields
  }
}''';

const _searchBrowseQuery = '''
query GetSearchFilterResults(
  \$vpcId: String!,
  \$locale: String!,
  \$sortString: String!,
  \$fetchCount: Int!,
  \$cursor: String!,
  \$searchString: String!,
  \$filters: AppFilterFields!
) {
  apps(
    vpcId: \$vpcId,
    language: \$locale,
    orderBy: \$sortString,
    first: \$fetchCount,
    after: \$cursor,
    searchQuery: \$searchString,
    filters: \$filters
  ) {
$_browseFields
  }
}''';

/// Port of gameAppMapper.ts dedupeGames — dedupe by id.
List<CatalogGame> dedupeGames(List<CatalogGame> games) {
  final byId = <String, CatalogGame>{};
  for (final game in games) {
    byId.putIfAbsent(game.id, () => game);
  }
  return byId.values.toList();
}