import 'dart:convert' show jsonDecode, jsonEncode, utf8;

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;

import '../http/client.dart' show buildGfnGraphQlHeaders;

// Port of lcarsGraphql.ts. The GraphQL query strings below are NVIDIA's
// proprietary catalog queries reverse-engineered by OpenNOW. They must be
// preserved character-for-character — NVIDIA rejects malformed GraphQL.

const lcarsGraphqlUrl = 'https://apps.gxn.nvidia.com/graphql';
const lcarsCdnGraphqlUrl = 'https://games.geforce.com/graphql';

const _gameSectionQuery = '''
query GetGameSection(\$vpcId: String!, \$locale: String!, \$panelNames: [String]!) {
  panels(vpcId: \$vpcId, language: \$locale, names: \$panelNames) {
    id
    name
    sections {
      id
      title
      renderDirectives
      seeMoreInfo {
        filterTileId
        title
        filterIds
        minTiles
        sortOrderId
      }
      items {
        __typename
        ...filterFields
        ...minimalGameFields
        ...marketingFields
      }
    }
  }
}

fragment filterFields on FilterItem {
  id
  title
  image
  filterIds
  sortOrderId
}

fragment minimalGameFields on GameItem {
  app {
    id
    images {
      TV_BANNER
      HERO_IMAGE
    }
    title
    itemMetadata {
      campaignIds
    }
    variants {
      id
      shortName
      appStore
      supportedControls
      minimumSizeInBytes
      gfn {
        library {
          status
          selected
          playStatus
          installed
          subscription
        }
        status
        stateDetails {
          ... on VariantGfnAutoPatchingMetadata {
            subType
            endTime
          }
          ... on VariantGfnManualPatchingMetadata {
            subType
            endTime
          }
          ... on VariantGfnMaintenanceMetadata {
            subType
          }
        }
      }
    }
    gfn {
      playabilityState
      minimumMembershipTierLabel
      catalogSkuStrings {
        SKU_BASED_TAG
      }
      playType
    }
  }
}

fragment marketingFields on MarketingItem {
  id
  title
  subTitle
  body
  images {
    MARQUEE_HERO_IMAGE
    HERO_IMAGE
  }
  action {
    uri
    label
    infoText
  }
  schedule {
    startTime
    endTime
  }
}''';

const _marqueeQuery = '''
query GetMarquee(\$vpcId: String!, \$locale: String!, \$panelNames: [String]!) {
  panels(vpcId: \$vpcId, language: \$locale, names: \$panelNames) {
    id
    name
    sections {
      id
      title
      items {
        __typename
        ...marketingFields
        ...marqueeGameFields
      }
    }
  }
}

fragment marketingFields on MarketingItem {
  id
  title
  images {
    MARQUEE_HERO_IMAGE
    HERO_IMAGE
  }
  body
  action {
    uri
    label
    infoText
  }
  schedule {
    startTime
    endTime
  }
}

fragment marqueeGameFields on GameItem {
  app {
    id
    title
    publisherName
    contentRatings {
      categoryKey
      contentDescriptorKeys
      interactiveElementKeys
      type
    }
    marqueeScrimPrimaryRGB {
      r
      g
      b
    }
    images {
      GAME_LOGO
      MARQUEE_HERO_IMAGE
      HERO_IMAGE
    }
    itemMetadata {
      campaignIds
    }
    variants {
      id
      appStore
      supportedControls
    }
  }
}''';

const _librarySectionWithTimeQuery = '''
query GetGameSection(\$vpcId: String!, \$locale: String!, \$panelNames: [String]!) {
  panels(vpcId: \$vpcId, language: \$locale, names: \$panelNames) {
    id
    name
    sections {
      id
      title
      renderDirectives
      seeMoreInfo {
        filterTileId
        title
        filterIds
        minTiles
        sortOrderId
      }
      items {
        __typename
        ...filterFields
        ...minimalGameFields
      }
    }
  }
}

fragment filterFields on FilterItem {
  id
  title
  image
  filterIds
  sortOrderId
}

fragment minimalGameFields on GameItem {
  app {
    id
    images {
      TV_BANNER
      HERO_IMAGE
      KEY_ART
    }
    title
    itemMetadata {
      campaignIds
    }
    variants {
      id
      shortName
      appStore
      publisherName
      supportedControls
      gfn {
        library {
          status
          selected
          playStatus
          lastPlayedDate
          subscription
        }
        status
        stateDetails {
          ... on VariantGfnAutoPatchingMetadata {
            subType
            endTime
          }
          ... on VariantGfnManualPatchingMetadata {
            subType
            endTime
          }
          ... on VariantGfnMaintenanceMetadata {
            subType
          }
        }
      }
      contentRatings {
        categoryKey
        type
      }
    }
    gfn {
      playabilityState
      minimumMembershipTierLabel
      catalogSkuStrings {
        SKU_BASED_TAG
      }
    }
  }
}''';

const _filterGroupAndSortQuery = '''
query GetFilterGroupAndSortOrderDefinitions(\$locale: String!) {
  filterGroupDefinitions(language: \$locale) {
    id
    label
    filters {
      id
      label
      filters
    }
  }
  sortOrderDefinitions(language: \$locale) {
    id
    label
    orderBy
  }
}''';

const _appDataForAppIdQuery = '''
query GetAppDataQueryForAppId(\$vpcId: String!, \$locale: String!, \$appIds: [String]!) {
  apps(vpcId: \$vpcId, language: \$locale, appIds: \$appIds) {
    items {
      contentRatings {
        categoryKey
        contentDescriptorKeys
        interactiveElementKeys
        type
      }
      developerName
      id
      genres
      images {
        GAME_BOX_ART
        GAME_LOGO
        HERO_IMAGE
        SCREENSHOTS
        TV_BANNER
        KEY_ART
      }
      nvidiaTech {
        PHOTO_MODE
        FREESTYLE
        HIGHLIGHTS
      }
      title
      longDescription
      shortDescription
      maxLocalPlayers
      maxOnlinePlayers
      supportedControls
      publisherName
      itemMetadata {
        campaignIds
      }
      variants {
        appStore
        id
        shortName
        supportedControls
        storeUrl
        publisherName
        developerName
        subscriptions
        minimumSizeInBytes
        cloudSaveSupported
        gfn {
          library {
            installed
            status
            selected
            playStatus
            subscription
            lastPlayedDate
          }
          status
          features {
            ...feature
          }
        }
      }
      gfn {
        playabilityState
        minimumMembershipTierLabel
        catalogSkuStrings {
          SKU_BASED_TAG
          SKU_BASED_PLAYABILITY_TEXT
          SKU_BASED_UNPLAYABLE_DIALOG_HEADER
          SKU_BASED_UNPLAYABLE_DIALOG_BODY_UPGRADE
          SKU_BASED_UNPLAYABLE_DIALOG_BODY_UPGRADE_ECOMM_RESTRICTED
        }
        playType
      }
    }
  }
}

fragment feature on GfnSubscriptionFeature {
  __typename
  ... on GfnSubscriptionFeatureValue {
    key
    value
  }
  ... on GfnSubscriptionFeatureValueList {
    key
    values
  }
}''';

const _addOwnedVariantMutation = '''
mutation AddOwnedVariant(\$cmsId: String!, \$locale: String!) {
  addOwnedVariant(language: \$locale, variantId: \$cmsId) {
    app {
      id
    }
  }
}''';

class LcarsQueryDefinition {
  final String? requestType;
  final String? sha256Hash;
  final String? query;

  const LcarsQueryDefinition({this.requestType, this.sha256Hash, this.query});
}

enum LcarsQueryName {
  marquee,
  main,
  librarySection,
  librarySectionWithTime,
  filterGroupAndSortOrderDefinitions,
  appsWithSearch,
  appsWithoutSearch,
  appDataForAppId,
  addOwnedVariant,
}

/// Port of LCARS_QUERY_DEFINITIONS — the persisted-query hashes are NVIDIA's
/// reverse-engineered values and MUST match exactly.
const lcarsQueryDefinitions = <LcarsQueryName, LcarsQueryDefinition>{
  LcarsQueryName.marquee: LcarsQueryDefinition(
    requestType: 'panels/Marquee',
    sha256Hash: 'dd4bddfdef4707dfe340cc2040d6bb9c4c45f706976fca15b2ef33221c385d7f',
    query: _marqueeQuery,
  ),
  LcarsQueryName.main: LcarsQueryDefinition(
    requestType: 'panels/MainV2',
    sha256Hash: '46ec15f267a056e7d5e46e629efa929529e5e7542a4850faece90b9f8fa5f810',
    query: _gameSectionQuery,
  ),
  LcarsQueryName.librarySection: LcarsQueryDefinition(
    requestType: 'panels/Library',
    sha256Hash: '46ec15f267a056e7d5e46e629efa929529e5e7542a4850faece90b9f8fa5f810',
    query: _gameSectionQuery,
  ),
  LcarsQueryName.librarySectionWithTime: LcarsQueryDefinition(
    requestType: 'panels/Library',
    sha256Hash: '7f54d6bbbf3b1c09d0e5264dfa36f0f4aaf5e2678f2089f0cbf0d4dda18c3af9',
    query: _librarySectionWithTimeQuery,
  ),
  LcarsQueryName.filterGroupAndSortOrderDefinitions: LcarsQueryDefinition(
    requestType: 'filterGroupAndSortOrderDefinitions',
    sha256Hash: 'ef725de5e93b093de1ac7418fed0ffb4f6ae2b9c14f743ab274a791521488eb9',
    query: _filterGroupAndSortQuery,
  ),
  LcarsQueryName.appsWithSearch: LcarsQueryDefinition(
    requestType: 'apps',
    sha256Hash: 'ea1b5e417c95ceb5c7d6a65aa4613a417ed80b1a8d6a8c26b6953846da1fc513',
  ),
  LcarsQueryName.appsWithoutSearch: LcarsQueryDefinition(
    requestType: 'apps',
    sha256Hash: '5ae1cfe2e04debdcd81279b5559313abab7d9cfa3ac9d9c048e969b3d445dcb9',
  ),
  LcarsQueryName.appDataForAppId: LcarsQueryDefinition(
    requestType: 'appMetaData',
    sha256Hash: 'cf8b620dfd03617017ba7c858cee65197e1ace5180e41be194b39227227ced63',
    query: _appDataForAppIdQuery,
  ),
  LcarsQueryName.addOwnedVariant: LcarsQueryDefinition(
    sha256Hash: '02b373dd20366da6a7184c16a8a84505cc3d15e9f35788c0104c4d16456bcfaf',
    query: _addOwnedVariantMutation,
  ),
};

/// Port of fetchLcarsGraphQl — persisted-query GET with fallback to full query.
Future<Map<String, dynamic>> fetchLcarsGraphQl({
  required http.Client client,
  required LcarsQueryName queryName,
  required Map<String, dynamic> variables,
  String? token,
  required bool isMac,
  String? endpoint,
  String? context,
  String? fallbackQuery,
}) async {
  final definition = lcarsQueryDefinitions[queryName]!;
  final effectiveQuery = fallbackQuery ?? definition.query;
  // NVIDIA's registry hashes are stale relative to the query text shipped
  // here (APQ_HASH_MISMATCH). Compute the hash from the query text so the
  // server executes and registers our query; fall back to the stored hash
  // for definitions without an inline query.
  final sha256Hash = effectiveQuery != null
      ? sha256.convert(utf8.encode(effectiveQuery)).toString()
      : definition.sha256Hash;
  if (sha256Hash == null) {
    throw StateError('LCARS query $queryName does not define a persisted-query hash');
  }

  final effectiveEndpoint = endpoint ?? lcarsCdnGraphqlUrl;
  final effectiveContext = context ?? 'GFN GraphQL failed';
  final huId = _randomHuId();

  Map<String, String> buildParams({bool withQuery = false}) {
    final params = <String, String>{
      'extensions': jsonEncode({
        'persistedQuery': {'sha256Hash': sha256Hash},
      }),
      'huId': huId,
      'variables': jsonEncode(variables),
    };
    if (definition.requestType != null) {
      params['requestType'] = definition.requestType!;
    }
    if (withQuery && effectiveQuery != null) {
      params['query'] = effectiveQuery;
    }
    return params;
  }

  final headers = {
    ...buildGfnGraphQlHeaders(token, isMac: isMac),
    'Content-Type': 'application/graphql',
  };

  final uri = Uri.parse(effectiveEndpoint)
      .replace(queryParameters: buildParams());
  var response = await client.get(uri, headers: headers);

  if (response.statusCode == 400 && effectiveQuery != null) {
    final retryUri = Uri.parse(effectiveEndpoint)
        .replace(queryParameters: buildParams(withQuery: true));
    response = await client.get(retryUri, headers: headers);
  }

  if (response.statusCode != 200) {
    throw StateError(
      '$effectiveContext (${response.statusCode}): ${_snippet(response.body)}',
    );
  }

  return _decodeObject(response.body);
}

/// Port of postLcarsGraphQl — POST full query (used for mutations).
Future<Map<String, dynamic>> postLcarsGraphQl({
  required http.Client client,
  required String query,
  required Map<String, dynamic> variables,
  required String token,
  required bool isMac,
}) async {
  final response = await client.post(
    Uri.parse(lcarsGraphqlUrl),
    headers: buildGfnGraphQlHeaders(token, isMac: isMac),
    body: jsonEncode({'query': query, 'variables': variables}),
  );

  if (response.statusCode != 200) {
    throw StateError(
      'GFN library mutation failed (${response.statusCode}): ${_snippet(response.body)}',
    );
  }

  final payload = _decodeObject(response.body);
  throwGraphQlErrors(payload['errors'], 'GFN library mutation failed');
  return payload;
}

/// Port of throwGraphQlErrors
void throwGraphQlErrors(List<dynamic>? errors, String context) {
  if (errors == null || errors.isEmpty) return;
  final messages = errors.map((e) {
    if (e is Map && e['message'] is String) return e['message'] as String;
    return 'Unknown error';
  }).join(', ');
  throw StateError('$context: $messages');
}

String _randomHuId() {
  final now = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
  final rand = DateTime.now().microsecond.toRadixString(16);
  return '$now$rand';
}

Map<String, dynamic> _decodeObject(String text) {
  final decoded = jsonDecode(text);
  if (decoded is Map<String, dynamic>) return decoded;
  throw FormatException('GraphQL response was not a JSON object');
}

String _snippet(String text) {
  return text.length > 400 ? text.substring(0, 400) : text;
}