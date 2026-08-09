import 'package:flutter_test/flutter_test.dart';
import 'package:next_client/state/video_shader_settings.dart';

void main() {
  group('VideoShaderSettings defaults', () {
    test('match OpenNOW DEFAULT_VIDEO_SHADER_SETTINGS', () {
      const d = VideoShaderSettings.defaults;
      expect(d.enabled, isFalse);
      expect(d.sharpen, 40);
      expect(d.sharpenAdaptive, isTrue);
      expect(d.saturation, 100);
      expect(d.contrast, 100);
      expect(d.brightness, 100);
      expect(d.vibrance, 0);
      expect(d.filmGrain, 0);
    });

    test('defaults have no visible effect (disabled)', () {
      expect(VideoShaderSettings.defaults.hasVisibleEffect, isFalse);
    });
  });

  group('hasVisibleEffect', () {
    test('true when enabled and any control deviates', () {
      expect(
        const VideoShaderSettings(
          enabled: true,
          sharpen: 40,
        ).hasVisibleEffect,
        isTrue,
      );
      expect(
        const VideoShaderSettings(
          enabled: true,
          saturation: 120,
        ).hasVisibleEffect,
        isTrue,
      );
      expect(
        const VideoShaderSettings(
          enabled: true,
          sharpen: 0,
          saturation: 100,
          contrast: 100,
          brightness: 100,
          vibrance: 0,
          filmGrain: 0,
        ).hasVisibleEffect,
        isFalse, // enabled but every control neutral
      );
    });
  });

  group('persistence round-trip', () {
    test('toPersistedString / fromPersistedString', () {
      const settings = VideoShaderSettings(
        enabled: true,
        sharpen: 60,
        sharpenAdaptive: false,
        saturation: 140,
        contrast: 110,
        brightness: 95,
        vibrance: 25,
        filmGrain: 10,
      );
      final restored =
          VideoShaderSettings.fromPersistedString(settings.toPersistedString());
      expect(restored, settings);
      expect(restored.enabled, isTrue);
      expect(restored.sharpen, 60);
      expect(restored.sharpenAdaptive, isFalse);
      expect(restored.filmGrain, 10);
    });

    test('null/garbage input falls back to defaults', () {
      expect(
        VideoShaderSettings.fromPersistedString(null),
        VideoShaderSettings.defaults,
      );
      expect(
        VideoShaderSettings.fromPersistedString(''),
        VideoShaderSettings.defaults,
      );
      expect(
        VideoShaderSettings.fromPersistedString('not json'),
        VideoShaderSettings.defaults,
      );
      expect(VideoShaderSettings.fromJson(42), VideoShaderSettings.defaults);
    });

    test('out-of-range values are clamped to the UI ranges', () {
      final clamped = VideoShaderSettings.fromJson({
        'enabled': true,
        'sharpen': 500,
        'saturation': -50,
        'contrast': 10,
        'brightness': 999,
        'vibrance': 75,
        'filmGrain': -1,
      });
      expect(clamped.sharpen, 100);
      expect(clamped.saturation, 0);
      expect(clamped.contrast, 50);
      expect(clamped.brightness, 150);
      expect(clamped.vibrance, 75);
      expect(clamped.filmGrain, 0);
    });

    test('sharpenAdaptive defaults to adaptive (CAS) unless explicitly off', () {
      expect(
        VideoShaderSettings.fromJson({'sharpen': 50}).sharpenAdaptive,
        isTrue,
      );
      expect(
        VideoShaderSettings.fromJson({'sharpenAdaptive': false}).sharpenAdaptive,
        isFalse,
      );
      expect(
        VideoShaderSettings.fromJson({'sharpenAdaptive': true}).sharpenAdaptive,
        isTrue,
      );
    });
  });

  group('copyWith', () {
    test('updates only the given fields', () {
      const base = VideoShaderSettings.defaults;
      final updated = base.copyWith(enabled: true, vibrance: 30);
      expect(updated.enabled, isTrue);
      expect(updated.vibrance, 30);
      expect(updated.sharpen, base.sharpen);
      expect(updated.saturation, base.saturation);
    });

    test('equality ignores nothing', () {
      const a = VideoShaderSettings(enabled: true, sharpen: 55);
      const b = VideoShaderSettings(enabled: true, sharpen: 55);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.copyWith(sharpen: 56), isNot(a));
      expect(a.copyWith(sharpenAdaptive: false), isNot(a));
    });
  });
}
