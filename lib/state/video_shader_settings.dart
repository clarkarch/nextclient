import 'dart:convert' show jsonDecode, jsonEncode;

/// Client-side GPU post-processing applied to the decoded stream (GPU
/// renderer path only — the CPU renderer composites outside a shader, so the
/// filter cannot apply there).
///
/// All values use UI-facing ranges; the native renderer normalizes them for
/// the shader.
class VideoShaderSettings {
  /// Master toggle for the post-processing pipeline.
  final bool enabled;

  /// Sharpening strength, 0-100 (0 = off). When [sharpenAdaptive] is true the
  /// shader uses contrast-adaptive (CAS) sharpening; otherwise it applies a
  /// uniform unsharp mask across the whole frame.
  final int sharpen;

  /// True = contrast-adaptive (CAS) sharpening that concentrates on edges and
  /// leaves flat areas alone. False = uniform sharpening everywhere, which
  /// makes the effect much easier to see.
  final bool sharpenAdaptive;

  /// Color saturation percentage, 0-200 (100 = neutral).
  final int saturation;

  /// Contrast percentage, 50-150 (100 = neutral).
  final int contrast;

  /// Brightness percentage, 50-150 (100 = neutral).
  final int brightness;

  /// Vibrance boost for muted colors, 0-100 (0 = off).
  final int vibrance;

  /// Animated film grain amount, 0-100 (0 = off).
  final int filmGrain;

  const VideoShaderSettings({
    this.enabled = true,
    this.sharpen = 40,
    this.sharpenAdaptive = true,
    this.saturation = 100,
    this.contrast = 100,
    this.brightness = 100,
    this.vibrance = 0,
    this.filmGrain = 0,
  });

  /// Default video shader settings.
  static const VideoShaderSettings defaults = VideoShaderSettings();

  /// The neutral value a control snaps back to on double-click (the value
  /// that leaves the image unchanged).
  static int neutralFor(String key) => switch (key) {
    'sharpen' => 0,
    'saturation' => 100,
    'contrast' => 100,
    'brightness' => 100,
    'vibrance' => 0,
    'filmGrain' => 0,
    _ => 100,
  };

  /// True when the shader pipeline would visibly change the image. The native
  /// renderer skips the extra post-processing pass entirely when this is
  /// false.
  bool get hasVisibleEffect =>
      enabled &&
      (sharpen > 0 ||
          saturation != 100 ||
          contrast != 100 ||
          brightness != 100 ||
          vibrance > 0 ||
          filmGrain > 0);

  VideoShaderSettings copyWith({
    bool? enabled,
    int? sharpen,
    bool? sharpenAdaptive,
    int? saturation,
    int? contrast,
    int? brightness,
    int? vibrance,
    int? filmGrain,
  }) {
    return VideoShaderSettings(
      enabled: enabled ?? this.enabled,
      sharpen: sharpen ?? this.sharpen,
      sharpenAdaptive: sharpenAdaptive ?? this.sharpenAdaptive,
      saturation: saturation ?? this.saturation,
      contrast: contrast ?? this.contrast,
      brightness: brightness ?? this.brightness,
      vibrance: vibrance ?? this.vibrance,
      filmGrain: filmGrain ?? this.filmGrain,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'sharpen': sharpen,
    'sharpenAdaptive': sharpenAdaptive,
    'saturation': saturation,
    'contrast': contrast,
    'brightness': brightness,
    'vibrance': vibrance,
    'filmGrain': filmGrain,
  };

  /// Normalizes persisted/user-provided settings into safe UI ranges.
  /// Anything that isn't a plain map falls back to the defaults; out-of-range
  /// values are clamped.
  static VideoShaderSettings fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    int clamp(Object? value, int min, int max, int fallback) {
      final parsed = value is num ? value.toInt() : int.tryParse('$value');
      if (parsed == null) return fallback;
      return parsed.clamp(min, max);
    }

    return VideoShaderSettings(
      enabled: raw['enabled'] == true,
      sharpen: clamp(raw['sharpen'], 0, 100, defaults.sharpen),
      // Adaptive (CAS) is the default; only an explicit false opts out.
      sharpenAdaptive: raw['sharpenAdaptive'] != false,
      saturation: clamp(raw['saturation'], 0, 200, defaults.saturation),
      contrast: clamp(raw['contrast'], 50, 150, defaults.contrast),
      brightness: clamp(raw['brightness'], 50, 150, defaults.brightness),
      vibrance: clamp(raw['vibrance'], 0, 100, defaults.vibrance),
      filmGrain: clamp(raw['filmGrain'], 0, 100, defaults.filmGrain),
    );
  }

  static VideoShaderSettings fromPersistedString(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      return fromJson(jsonDecode(raw));
    } catch (_) {
      return defaults;
    }
  }

  String toPersistedString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is VideoShaderSettings &&
      other.enabled == enabled &&
      other.sharpen == sharpen &&
      other.sharpenAdaptive == sharpenAdaptive &&
      other.saturation == saturation &&
      other.contrast == contrast &&
      other.brightness == brightness &&
      other.vibrance == vibrance &&
      other.filmGrain == filmGrain;

  @override
  int get hashCode => Object.hash(
    enabled,
    sharpen,
    sharpenAdaptive,
    saturation,
    contrast,
    brightness,
    vibrance,
    filmGrain,
  );
}
