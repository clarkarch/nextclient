import 'dart:convert' show jsonDecode;

import '../catalog/game_images.dart'
    show landscapeImageKeys, normalizeImageValues;

class AppVariant {
  final String id;
  final String? shortName;
  final String? appStore;
  final List<String> supportedControls;
  final int? minimumSizeInBytes;
  final VariantGfn? gfn;

  const AppVariant({
    required this.id,
    this.shortName,
    this.appStore,
    this.supportedControls = const [],
    this.minimumSizeInBytes,
    this.gfn,
  });

  factory AppVariant.fromJson(Map<String, dynamic> json) {
    final controls = json['supportedControls'];
    return AppVariant(
      id: json['id'] as String,
      shortName: json['shortName'] as String?,
      appStore: json['appStore'] as String?,
      supportedControls: controls is List
          ? controls.whereType<String>().toList()
          : const <String>[],
      minimumSizeInBytes: (json['minimumSizeInBytes'] as num?)?.toInt(),
      gfn: json['gfn'] is Map<String, dynamic>
          ? VariantGfn.fromJson(json['gfn'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'shortName': shortName,
      'appStore': appStore,
      'supportedControls': supportedControls,
      'minimumSizeInBytes': minimumSizeInBytes,
      if (gfn != null) 'gfn': gfn!.toJson(),
    };
  }
}

class VariantGfn {
  final String? status;
  final String? libraryStatus;
  final bool? librarySelected;
  final String? playStatus;
  final bool? installed;
  final String? lastPlayedDate;

  const VariantGfn({
    this.status,
    this.libraryStatus,
    this.librarySelected,
    this.playStatus,
    this.installed,
    this.lastPlayedDate,
  });

  factory VariantGfn.fromJson(Map<String, dynamic> json) {
    final libraryValue = json['library'];
    final library = libraryValue is Map<String, dynamic>
        ? libraryValue
        : const <String, dynamic>{};
    return VariantGfn(
      status: json['status'] as String?,
      libraryStatus: library['status'] as String?,
      librarySelected: library['selected'] as bool?,
      playStatus: library['playStatus'] as String?,
      installed: library['installed'] as bool?,
      lastPlayedDate: library['lastPlayedDate'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'status': status,
      'library': {
        'status': libraryStatus,
        'selected': librarySelected,
        'playStatus': playStatus,
        'installed': installed,
        'lastPlayedDate': lastPlayedDate,
      },
    };
  }
}

class CatalogGame {
  final String id;
  final String title;
  final String? shortName;
  final String? publisherName;
  final List<AppVariant> variants;
  final Map<String, dynamic>? images;
  final String? playabilityState;
  final String? minimumMembershipTierLabel;
  final String? playType;
  final String? launchAppId;
  final bool isInLibrary;

  const CatalogGame({
    required this.id,
    required this.title,
    this.shortName,
    this.publisherName,
    this.variants = const [],
    this.images,
    this.playabilityState,
    this.minimumMembershipTierLabel,
    this.playType,
    this.launchAppId,
    this.isInLibrary = false,
  });

  /// Best 16:9 landscape art (hero/banner/key art) for cards.
  String? get imageUrl {
    for (final key in landscapeImageKeys) {
      final value = normalizeImageValues(images?[key]);
      if (value.isNotEmpty) return value.first;
    }
    return null;
  }

  /// Marquee hero (highest-fidelity landscape) for the featured carousel.
  String? get marqueeImageUrl {
    final value = normalizeImageValues(images?['MARQUEE_HERO_IMAGE']);
    if (value.isNotEmpty) return value.first;
    return imageUrl;
  }

  /// Most recent play date across variants, if any.
  DateTime? get lastPlayedDate {
    DateTime? latest;
    for (final v in variants) {
      final raw = v.gfn?.lastPlayedDate;
      if (raw == null || raw.isEmpty) continue;
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) continue;
      if (latest == null || parsed.isAfter(latest)) latest = parsed;
    }
    return latest;
  }

  factory CatalogGame.fromJson(Map<String, dynamic> json) {
    final app = json['app'] as Map<String, dynamic>? ?? json;
    final variants = (app['variants'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((v) => AppVariant.fromJson(v))
        .toList();
    return CatalogGame(
      id: app['id'] as String,
      title: app['title'] as String,
      shortName: app['shortName'] as String?,
      publisherName: app['publisherName'] as String?,
      variants: variants,
      images: app['images'] as Map<String, dynamic>?,
      playabilityState: (app['gfn'] as Map<String, dynamic>?)?['playabilityState'] as String?,
      minimumMembershipTierLabel:
          (app['gfn'] as Map<String, dynamic>?)?['minimumMembershipTierLabel'] as String?,
      playType: (app['gfn'] as Map<String, dynamic>?)?['playType'] as String?,
      launchAppId: _resolveLaunchAppId(variants, app['id'] as String),
      isInLibrary: variants.any((v) => isOwnedLibraryStatus(v.gfn?.libraryStatus)),
    );
  }

  /// Port of gameAppMapper.ts resolveAppData.numericAppId — the preferred
  /// numeric variant id (selected variant first), falling back to the app id
  /// if it is itself numeric.
  static String? _resolveLaunchAppId(List<AppVariant> variants, String appId) {
    for (final v in variants) {
      if (v.gfn?.librarySelected == true && _isNumericId(v.id)) return v.id;
    }
    for (final v in variants) {
      if (_isNumericId(v.id)) return v.id;
    }
    return _isNumericId(appId) ? appId : null;
  }

  static bool _isNumericId(String value) =>
      value.isNotEmpty && RegExp(r'^\d+$').hasMatch(value);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'shortName': shortName,
      'publisherName': publisherName,
      'variants': variants.map((v) => v.toJson()).toList(),
      'images': images,
      'playabilityState': playabilityState,
      'minimumMembershipTierLabel': minimumMembershipTierLabel,
      'playType': playType,
      'launchAppId': launchAppId,
      'isInLibrary': isInLibrary,
    };
  }
}

class CatalogSection {
  final String id;
  final String title;
  final List<CatalogGame> games;

  const CatalogSection({required this.id, required this.title, required this.games});

  factory CatalogSection.fromJson(Map<String, dynamic> json) {
    return CatalogSection(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      games: (json['items'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .where((item) => item['__typename'] == 'GameItem')
          .map((item) => CatalogGame.fromJson(item))
          .toList(),
    );
  }
}

class CatalogPanel {
  final String id;
  final String name;
  final List<CatalogSection> sections;

  const CatalogPanel({required this.id, required this.name, required this.sections});

  factory CatalogPanel.fromJson(Map<String, dynamic> json) {
    return CatalogPanel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String,
      sections: (json['sections'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((s) => CatalogSection.fromJson(s))
          .toList(),
    );
  }
}

class CatalogBrowseResult {
  final List<CatalogGame> games;
  final bool hasNextPage;
  final String? endCursor;
  final int numberReturned;
  final int numberSupported;
  final int totalCount;

  const CatalogBrowseResult({
    required this.games,
    this.hasNextPage = false,
    this.endCursor,
    this.numberReturned = 0,
    this.numberSupported = 0,
    this.totalCount = 0,
  });
}

/// A single filterable option inside a [CatalogFilterGroup].
class CatalogFilterOption {
  final String id;
  final String label;
  final String groupId;
  final String groupLabel;

  /// Parsed `AppFilterFields` payload sent to the server when selected.
  final Map<String, dynamic> payload;

  const CatalogFilterOption({
    required this.id,
    required this.label,
    this.groupId = '',
    this.groupLabel = '',
    this.payload = const {},
  });

  factory CatalogFilterOption.fromJson(
    Map<String, dynamic> json, {
    required String groupId,
    required String groupLabel,
  }) {
    return CatalogFilterOption(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      groupId: groupId,
      groupLabel: groupLabel,
      payload: _parsePayload(json['filters']),
    );
  }

  static Map<String, dynamic> _parsePayload(Object? value) {
    if (value is! List || value.isEmpty) return const {};
    final raw = value.first;
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    } else if (raw is Map<String, dynamic>) {
      return raw;
    }
    return const {};
  }
}

class CatalogFilterGroup {
  final String id;
  final String label;
  final List<CatalogFilterOption> options;

  const CatalogFilterGroup({
    required this.id,
    required this.label,
    this.options = const [],
  });

  factory CatalogFilterGroup.fromJson(Map<String, dynamic> json) {
    final raw = json['filters'];
    final options = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map((f) => CatalogFilterOption.fromJson(
                  f,
                  groupId: json['id'] as String? ?? '',
                  groupLabel: json['label'] as String? ?? '',
                ))
            .where((o) => o.id.isNotEmpty && o.label.isNotEmpty)
            .toList()
        : const <CatalogFilterOption>[];
    return CatalogFilterGroup(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      options: options,
    );
  }
}

class CatalogSortOption {
  final String id;
  final String label;
  final String orderBy;

  const CatalogSortOption({
    required this.id,
    required this.label,
    required this.orderBy,
  });

  factory CatalogSortOption.fromJson(Map<String, dynamic> json) {
    return CatalogSortOption(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      orderBy: json['orderBy'] as String? ?? '',
    );
  }
}

/// Filter groups + sort orders + per-filter payload lookup from the
/// `filterGroupAndSortOrderDefinitions` query.
class CatalogDefinitions {
  final List<CatalogFilterGroup> groups;
  final List<CatalogSortOption> sortOptions;
  final Map<String, Map<String, dynamic>> filterPayloadById;

  const CatalogDefinitions({
    this.groups = const [],
    this.sortOptions = const [],
    this.filterPayloadById = const {},
  });

  /// Merge the AppFilterFields payloads for the given filter ids.
  Map<String, dynamic> mergeFilterPayloads(List<String> filterIds) {
    final merged = <String, dynamic>{};
    for (final id in filterIds) {
      final payload = filterPayloadById[id];
      if (payload != null) merged.addAll(payload);
    }
    return merged;
  }
}

class StreamRegion {
  final String name;
  final String url;
  final int? pingMs;

  const StreamRegion({required this.name, required this.url, this.pingMs});

  factory StreamRegion.fromJson(Map<String, dynamic> json) {
    return StreamRegion(
      name: json['name'] as String,
      url: json['url'] as String,
      pingMs: (json['pingMs'] as num?)?.toInt(),
    );
  }
}

const ownedLibraryStatuses = ['MANUAL', 'PLATFORM_SYNC', 'IN_LIBRARY'];

bool isOwnedLibraryStatus(String? status) {
  return status != null && ownedLibraryStatuses.contains(status);
}