import '../catalog/game_images.dart' show pickLandscapeImage, pickPosterImage;
import 'catalog.dart' show AppVariant, VariantGfn;

/// Rich per-app metadata from the `appDataForAppId` GraphQL query.
class GameDetails {
  final String id;
  final String title;
  final String? publisherName;
  final String? developerName;
  final List<String> genres;
  final String? shortDescription;
  final String? longDescription;
  final int? maxLocalPlayers;
  final int? maxOnlinePlayers;
  final List<String> supportedControls;
  final List<String> contentRatingCategories;
  final Map<String, dynamic>? images;
  final List<AppVariant> variants;
  final String? playabilityState;
  final String? minimumMembershipTierLabel;
  final String? playType;

  const GameDetails({
    required this.id,
    required this.title,
    this.publisherName,
    this.developerName,
    this.genres = const [],
    this.shortDescription,
    this.longDescription,
    this.maxLocalPlayers,
    this.maxOnlinePlayers,
    this.supportedControls = const [],
    this.contentRatingCategories = const [],
    this.images,
    this.variants = const [],
    this.playabilityState,
    this.minimumMembershipTierLabel,
    this.playType,
  });

  factory GameDetails.fromJson(Map<String, dynamic> json) {
    final app = json['app'] as Map<String, dynamic>? ?? json;
    final gfn = app['gfn'] as Map<String, dynamic>?;
    final variants = (app['variants'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(AppVariant.fromJson)
        .toList();
    final ratings = app['contentRatings'] as List<dynamic>? ?? [];
    return GameDetails(
      id: app['id'] as String,
      title: app['title'] as String,
      publisherName: app['publisherName'] as String?,
      developerName: app['developerName'] as String?,
      genres: (app['genres'] as List<dynamic>? ?? []).cast<String>(),
      shortDescription: app['shortDescription'] as String?,
      longDescription: app['longDescription'] as String?,
      maxLocalPlayers: (app['maxLocalPlayers'] as num?)?.toInt(),
      maxOnlinePlayers: (app['maxOnlinePlayers'] as num?)?.toInt(),
      supportedControls: (app['supportedControls'] as List<dynamic>? ?? [])
          .cast<String>(),
      contentRatingCategories: ratings
          .whereType<Map<String, dynamic>>()
          .map((r) => r['categoryKey'] as String? ?? '')
          .where((c) => c.isNotEmpty)
          .toList(),
      images: app['images'] as Map<String, dynamic>?,
      variants: variants,
      playabilityState: gfn?['playabilityState'] as String?,
      minimumMembershipTierLabel:
          gfn?['minimumMembershipTierLabel'] as String?,
      playType: gfn?['playType'] as String?,
    );
  }

  /// Best 16:9 hero image for the details header.
  String? get heroImageUrl => pickLandscapeImage(images);

  /// Poster / box-art image.
  String? get posterImageUrl => pickPosterImage(images);

  /// Screenshots from the `SCREENSHOTS` image type.
  List<String> get screenshots {
    final urls = images?['SCREENSHOTS'];
    if (urls == null) return const [];
    final raw = urls is List ? urls.cast<Object?>() : [urls];
    final out = <String>[];
    for (final item in raw) {
      if (item is! String) continue;
      final trimmed = item.trim();
      if (trimmed.isEmpty || out.contains(trimmed)) continue;
      out.add(trimmed);
    }
    return out;
  }

  /// The preferred variant's GFN library state, if any.
  VariantGfn? get preferredVariantGfn {
    for (final v in variants) {
      if (v.gfn?.librarySelected == true) return v.gfn;
    }
    return null;
  }

  String? get launchAppId {
    for (final v in variants) {
      if (v.gfn?.librarySelected == true && _isNumericId(v.id)) return v.id;
    }
    for (final v in variants) {
      if (_isNumericId(v.id)) return v.id;
    }
    return _isNumericId(id) ? id : null;
  }

  static bool _isNumericId(String value) =>
      value.isNotEmpty && RegExp(r'^\d+$').hasMatch(value);
}
