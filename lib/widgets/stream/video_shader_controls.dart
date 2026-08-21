import 'package:flutter/material.dart';
import 'dart:io' show Platform;

import '../../state/stream_transport.dart' show StreamTransportKind;
import '../../state/user_settings.dart';
import '../../state/video_shader_settings.dart';
import '../../theme/neon.dart';
import '../neon_switch.dart';

/// One shader control row.
class _ShaderControl {
  final String key;
  final String label;
  final int min;
  final int max;
  final String? hint;

  /// Shows an "Adaptive" toggle next to this control (used by Sharpen to
  /// switch between contrast-adaptive CAS and uniform sharpening).
  final bool adaptiveToggle;

  const _ShaderControl({
    required this.key,
    required this.label,
    required this.min,
    required this.max,
    this.hint,
    this.adaptiveToggle = false,
  });
}

const List<_ShaderControl> _controls = [
  _ShaderControl(
    key: 'sharpen',
    label: 'Sharpen',
    min: 0,
    max: 100,
    adaptiveToggle: true,
  ),
  _ShaderControl(key: 'saturation', label: 'Saturation', min: 0, max: 200),
  _ShaderControl(key: 'contrast', label: 'Contrast', min: 50, max: 150),
  _ShaderControl(key: 'brightness', label: 'Brightness', min: 50, max: 150),
  _ShaderControl(
    key: 'vibrance',
    label: 'Vibrance',
    min: 0,
    max: 100,
    hint: 'Boosts muted colors without oversaturating.',
  ),
  _ShaderControl(key: 'filmGrain', label: 'Film Grain', min: 0, max: 100),
];

/// GPU post-processing filters for the stream (CAS sharpening,
/// saturation/contrast/brightness, vibrance, animated film grain). The filter
/// only applies on the GPU renderer path (RendererBackend.gl — GL on Linux,
/// D3D11 on Windows), so the controls show an explanatory hint when that path
/// isn't selected.
class VideoShaderControls extends StatelessWidget {
  final UserSettings settings;

  const VideoShaderControls({super.key, required this.settings});

  /// Whether the native GPU renderer (the only path the shader pipeline runs
  /// on) is selected for the next session. On Android the shader filter is
  /// always available via the ShaderFilterDrawer wrapper.
  bool get _available =>
      (Platform.isAndroid ||
          settings.rendererBackend == RendererBackend.gl) &&
      settings.streamTransport == StreamTransportKind.flutterWebrtc;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final shader = settings.videoShader;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Video shaders',
                    style: TextStyle(color: Neon.ink, fontSize: 13),
                  ),
                ),
                NeonSwitch(
                  value: shader.enabled,
                  onChanged: (v) =>
                      settings.videoShader = shader.copyWith(enabled: v),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _available
                  ? 'GPU post-processing applied to the stream. '
                      'Warning: may reduce stream FPS on slower GPUs.'
                  : 'Requires the GPU renderer (Renderer → GPU shader '
                      'YUV→RGB) on the LIBWEBRTC transport.',
              style: const TextStyle(color: Neon.inkMuted, fontSize: 11.5),
            ),
            if (shader.enabled) ...[
              const SizedBox(height: 4),
              VideoShaderFilterSliders(settings: settings),
            ],
          ],
        );
      },
    );
  }
}

/// Headerless shader hint + sliders + reset — embedded in the stream
/// sidebar's VIDEO EFFECTS section (whose header switch owns enable/disable).
/// Keeps the same availability warning as the full [VideoShaderControls].
class VideoShaderFilterSliders extends StatelessWidget {
  final UserSettings settings;

  const VideoShaderFilterSliders({super.key, required this.settings});

  /// Same availability rule as [VideoShaderControls]: the shader pipeline
  /// only runs on the GPU renderer path.
  bool get _available =>
      (Platform.isAndroid ||
          settings.rendererBackend == RendererBackend.gl) &&
      settings.streamTransport == StreamTransportKind.flutterWebrtc;

  @override
  Widget build(BuildContext context) {
    final shader = settings.videoShader;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _available
              ? 'GPU post-processing applied to the stream. '
                  'Warning: may reduce stream FPS on slower GPUs.'
              : 'Requires the GPU renderer (Renderer → GPU shader '
                  'YUV→RGB) on the LIBWEBRTC transport.',
          style: const TextStyle(color: Neon.inkMuted, fontSize: 11.5),
        ),
        const SizedBox(height: 4),
        for (final control in _controls) ...[
          const SizedBox(height: 10),
          _ShaderSlider(
            control: control,
            value: shader,
            onChanged: (next) => settings.videoShader = next,
          ),
        ],
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: () => settings.videoShader =
                VideoShaderSettings.defaults.copyWith(enabled: true),
            style: OutlinedButton.styleFrom(
              foregroundColor: Neon.inkSoft,
              side: const BorderSide(color: Neon.outline),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
            child: const Text('RESET FILTERS'),
          ),
        ),
      ],
    );
  }
}

class _ShaderSlider extends StatelessWidget {
  final _ShaderControl control;
  final VideoShaderSettings value;
  final ValueChanged<VideoShaderSettings> onChanged;

  const _ShaderSlider({
    required this.control,
    required this.value,
    required this.onChanged,
  });

  int get _current => switch (control.key) {
    'sharpen' => value.sharpen,
    'saturation' => value.saturation,
    'contrast' => value.contrast,
    'brightness' => value.brightness,
    'vibrance' => value.vibrance,
    'filmGrain' => value.filmGrain,
    _ => 100,
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                control.label,
                style: const TextStyle(color: Neon.ink, fontSize: 13),
              ),
            ),
            Text(
              '$_current%',
              style: const TextStyle(color: Neon.inkSoft, fontSize: 12),
            ),
          ],
        ),
        // Double-tap the slider track to snap the control back to neutral.
        GestureDetector(
          onDoubleTap: () => onChanged(
            value._with(control.key, VideoShaderSettings.neutralFor(control.key)),
          ),
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Neon.accent,
              inactiveTrackColor: Neon.outlineSoft,
              thumbColor: Neon.accent,
              overlayColor: Neon.accent.withValues(alpha: 0.15),
              trackHeight: 3,
            ),
            child: Slider(
              value: _current.toDouble().clamp(
                control.min.toDouble(),
                control.max.toDouble(),
              ),
              min: control.min.toDouble(),
              max: control.max.toDouble(),
              divisions: control.max - control.min,
              label: '$_current%',
              onChanged: (v) => onChanged(
                value._with(control.key, v.round()),
              ),
            ),
          ),
        ),
        if (control.adaptiveToggle) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Adaptive',
                  style: TextStyle(color: Neon.ink, fontSize: 12),
                ),
              ),
              NeonSwitch(
                value: value.sharpenAdaptive,
                onChanged: (v) =>
                    onChanged(value.copyWith(sharpenAdaptive: v)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            value.sharpenAdaptive
                ? 'Edge-aware (CAS): strengthens edges, leaves flat areas '
                    'untouched.'
                : 'Uniform: applies to the whole frame — easiest way to see '
                    'the effect.',
            style: const TextStyle(color: Neon.inkMuted, fontSize: 11),
          ),
        ],
        if (!control.adaptiveToggle && control.hint != null)
          Text(
            control.hint!,
            style: const TextStyle(color: Neon.inkMuted, fontSize: 11),
          ),
      ],
    );
  }
}

extension on VideoShaderSettings {
  VideoShaderSettings _with(String key, int v) => switch (key) {
    'sharpen' => copyWith(sharpen: v),
    'saturation' => copyWith(saturation: v),
    'contrast' => copyWith(contrast: v),
    'brightness' => copyWith(brightness: v),
    'vibrance' => copyWith(vibrance: v),
    'filmGrain' => copyWith(filmGrain: v),
    _ => this,
  };
}
