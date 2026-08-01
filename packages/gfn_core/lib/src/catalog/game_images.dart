// Port of OpenNOW gameAppMapper.ts image helpers.
//
// The catalog GraphQL responses carry `images` as a map of image-type key ->
// URL (or list of URLs). These helpers resolve the preferred 16:9 / poster
// art and apply NVIDIA's CDN optimization suffix.

const landscapeImageKeys = [
  'MARQUEE_HERO_IMAGE',
  'HERO_IMAGE',
  'TV_BANNER',
  'FEATURE_IMAGE',
  'KEY_IMAGE',
  'KEY_ART',
];

const posterImageKeys = [
  'GAME_BOX_ART',
  'KEY_IMAGE',
  'KEY_ART',
];

/// Optimize an `img.nvidiagrid.net` URL by appending the webp + width suffix.
String optimizeImageUrl(String url, {int width = 1200}) {
  if (url.contains('img.nvidiagrid.net')) {
    return '$url;f=webp;w=$width';
  }
  return url;
}

/// Normalize an image value (string or list) into a deduped URL list.
List<String> normalizeImageValues(Object? value, {int width = 1200}) {
  final raw = value is List ? value.cast<Object?>() : [value];
  final urls = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    final trimmed = item.trim();
    if (trimmed.isEmpty) continue;
    final optimized = optimizeImageUrl(trimmed, width: width);
    if (!urls.contains(optimized)) urls.add(optimized);
  }
  return urls;
}

/// Return every image URL known for the game, keyed by image type.
Map<String, List<String>> imageUrlsByType(Map<String, dynamic>? images) {
  if (images == null) return const {};
  final result = <String, List<String>>{};
  for (final entry in images.entries) {
    if (entry.value == null) continue;
    final urls = normalizeImageValues(entry.value);
    if (urls.isNotEmpty) result[entry.key] = urls;
  }
  return result;
}

/// First available 16:9 landscape image (hero / banner / key art).
String? pickLandscapeImage(
  Map<String, dynamic>? images, {
  int width = 1200,
}) {
  if (images == null) return null;
  for (final key in landscapeImageKeys) {
    final value = normalizeImageValues(images[key], width: width);
    if (value.isNotEmpty) return value.first;
  }
  return null;
}

/// First available poster / box-art image.
String? pickPosterImage(
  Map<String, dynamic>? images, {
  int width = 1200,
}) {
  if (images == null) return null;
  for (final key in posterImageKeys) {
    final value = normalizeImageValues(images[key], width: width);
    if (value.isNotEmpty) return value.first;
  }
  return null;
}
