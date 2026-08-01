import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../state/user_settings.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_dropdown.dart';
import '../../widgets/neon_option_chip.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';

/// Stream quality options sent to the NVIDIA server on launch.
class StreamQualityPage extends StatelessWidget {
  final AppServices services;

  const StreamQualityPage({super.key, required this.services});

  /// Resolution options grouped by aspect ratio, with membership tier tags.
  static const _resolutions = <String, List<_ResOption>>{
    '16:9': [
      _ResOption('1280x720', '720p', OptionTier.free),
      _ResOption('1920x1080', '1080p', OptionTier.free),
      _ResOption('2560x1440', '1440p', OptionTier.priority),
      _ResOption('3840x2160', '4K', OptionTier.ultimate),
    ],
    '16:10': [
      _ResOption('1680x1050', 'WSXGA', OptionTier.free),
      _ResOption('1920x1200', '1200p', OptionTier.free),
      _ResOption('2560x1600', '1600p', OptionTier.priority),
      _ResOption('3840x2400', '4K', OptionTier.ultimate),
    ],
    '21:9': [
      _ResOption('2560x1080', 'Ultrawide 1080p', OptionTier.free),
      _ResOption('3440x1440', 'Ultrawide 1440p', OptionTier.priority),
    ],
    '32:9': [
      _ResOption('5120x1440', 'Super Ultrawide', OptionTier.ultimate),
    ],
  };

  /// FPS values NVIDIA accepts, with membership tier tags.
  static const _fpsOptions = <(int, OptionTier)>[
    (30, OptionTier.free),
    (60, OptionTier.free),
    (90, OptionTier.priority),
    (120, OptionTier.ultimate),
    (144, OptionTier.ultimate),
    (165, OptionTier.ultimate),
    (240, OptionTier.ultimate),
    (360, OptionTier.ultimate),
  ];

  static const _bitrateMin = 10;
  static const _bitrateMax = 75;

  bool get _isFreeTier {
    final tier = services.auth.getSession()?.user.membershipTier;
    return tier == null || tier.toUpperCase() == 'FREE';
  }

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Stream Quality',
      showBack: true,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final s = services.settings;
          return NeonCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionLabel(label: 'Resolution'),
                const SizedBox(height: 10),
                _resolutionSelector(s),
                const SizedBox(height: 22),
                _SectionLabel(label: 'Frame rate'),
                const SizedBox(height: 10),
                _fpsSelector(s),
                const SizedBox(height: 22),
                _SectionLabel(label: 'Max bitrate'),
                const SizedBox(height: 10),
                _bitrateSlider(s),
                const SizedBox(height: 22),
                const _SectionLabel(label: 'Codec'),
                const SizedBox(height: 10),
                _codecDropdown(s),
                const SizedBox(height: 22),
                const _SectionLabel(label: 'Color quality'),
                const SizedBox(height: 10),
                _colorDropdown(s),
                const SizedBox(height: 22),
                _SectionLabel(label: 'Features'),
                const SizedBox(height: 6),
                _toggleRow(
                  icon: Icons.bolt,
                  title: 'L4S',
                  subtitle: 'Low-latency networking',
                  value: s.enableL4S,
                  onChanged: (v) => s.enableL4S = v,
                ),
                _toggleRow(
                  icon: Icons.monitor_heart_outlined,
                  title: 'Cloud G-SYNC',
                  subtitle: 'Reflex-compatible VRR',
                  value: s.enableCloudGsync,
                  onChanged: (v) => s.enableCloudGsync = v,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _resolutionSelector(UserSettings s) {
    // Detect the current aspect ratio from the saved resolution.
    var currentRatio = '16:9';
    for (final entry in _resolutions.entries) {
      if (entry.value.any((r) => r.resolution == s.resolution)) {
        currentRatio = entry.key;
        break;
      }
    }
    final options = _resolutions[currentRatio]!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final ratio in _resolutions.keys)
              NeonOptionChip(
                label: ratio,
                selected: ratio == currentRatio,
                onTap: () {
                  // Switch ratio; keep the current resolution if it belongs
                  // here, otherwise pick the highest option in the ratio.
                  final inRatio = _resolutions[ratio]!
                      .any((r) => r.resolution == s.resolution);
                  if (!inRatio) {
                    s.resolution = _resolutions[ratio]!.first.resolution;
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final opt in options)
              NeonOptionChip(
                label: opt.label,
                selected: opt.resolution == s.resolution,
                tier: opt.tier,
                enabled: !_isFreeTier || opt.tier == OptionTier.free,
                onTap: () => s.resolution = opt.resolution,
              ),
          ],
        ),
      ],
    );
  }

  Widget _fpsSelector(UserSettings s) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (fps, tier) in _fpsOptions)
          NeonOptionChip(
            label: '$fps fps',
            selected: s.fps == fps,
            tier: tier,
            enabled: !_isFreeTier || tier == OptionTier.free,
            onTap: () => s.fps = fps,
          ),
      ],
    );
  }

  Widget _bitrateSlider(UserSettings s) {
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: s.maxBitrateMbps.toDouble(),
            min: _bitrateMin.toDouble(),
            max: _bitrateMax.toDouble(),
            divisions: (_bitrateMax - _bitrateMin) ~/ 5,
            label: '${s.maxBitrateMbps} Mbps',
            onChanged: (v) => s.maxBitrateMbps = v.round(),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '${s.maxBitrateMbps} Mbps',
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Color(0xFF00D9FF),
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  Widget _codecDropdown(UserSettings s) {
    return NeonDropdown<VideoCodec>(
      value: s.codec,
      onChanged: (v) {
        if (v != null) s.codec = v;
      },
      items: VideoCodec.values
          .map((c) => NeonDropdownItem(c, c.name.toUpperCase()))
          .toList(),
    );
  }

  Widget _colorDropdown(UserSettings s) {
    return NeonDropdown<ColorQuality>(
      value: s.colorQuality,
      onChanged: (v) {
        if (v != null) s.colorQuality = v;
      },
      items: const [
        ColorQuality(bitDepth: 0, chromaFormat: 0),
        ColorQuality(bitDepth: 0, chromaFormat: 1),
        ColorQuality(bitDepth: 1, chromaFormat: 0),
        ColorQuality(bitDepth: 1, chromaFormat: 1),
      ]
          .map((c) => NeonDropdownItem(c, _colorLabel(c)))
          .toList(),
    );
  }

  Widget _toggleRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return NeonSettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }

  String _colorLabel(ColorQuality c) {
    final depth = c.bitDepth == 1 ? '10-bit' : '8-bit';
    final chroma = c.chromaFormat == 1 ? '4:4:4' : '4:2:0';
    return '$depth $chroma';
  }
}

class _ResOption {
  final String resolution;
  final String label;
  final OptionTier tier;

  const _ResOption(this.resolution, this.label, this.tier);
}

class _SectionLabel extends StatelessWidget {
  final String label;

  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: Color(0xFF00D9FF),
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 2,
      ),
    );
  }
}
