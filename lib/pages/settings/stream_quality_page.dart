import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_dropdown.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';

/// Stream quality options sent to the NVIDIA server on launch.
class StreamQualityPage extends StatelessWidget {
  final AppServices services;

  const StreamQualityPage({super.key, required this.services});

  static const resolutions = [
    '1280x720',
    '1920x1080',
    '2560x1440',
    '3840x2160',
  ];

  static const bitrates = [10, 20, 30, 40, 50, 60, 75];

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
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _row(
                  icon: Icons.aspect_ratio,
                  title: 'Resolution',
                  trailing: NeonDropdown<String>(
                    value: s.resolution,
                    onChanged: (v) {
                      if (v != null) s.resolution = v;
                    },
                    items: resolutions
                        .map((r) => NeonDropdownItem(r, r))
                        .toList(),
                  ),
                ),
                const Divider(height: 1),
                _row(
                  icon: Icons.speed,
                  title: 'Frame rate',
                  trailing: NeonDropdown<int>(
                    value: s.fps,
                    onChanged: (v) {
                      if (v != null) s.fps = v;
                    },
                    items: [60, 120]
                        .map((f) => NeonDropdownItem(f, '$f fps'))
                        .toList(),
                  ),
                ),
                const Divider(height: 1),
                _row(
                  icon: Icons.network_ping,
                  title: 'Max bitrate',
                  trailing: NeonDropdown<int>(
                    value: s.maxBitrateMbps,
                    onChanged: (v) {
                      if (v != null) s.maxBitrateMbps = v;
                    },
                    items: bitrates
                        .map((b) => NeonDropdownItem(b, '$b Mbps'))
                        .toList(),
                  ),
                ),
                const Divider(height: 1),
                _row(
                  icon: Icons.memory,
                  title: 'Codec',
                  trailing: NeonDropdown<VideoCodec>(
                    value: s.codec,
                    onChanged: (v) {
                      if (v != null) s.codec = v;
                    },
                    items: VideoCodec.values
                        .map((c) => NeonDropdownItem(c, c.name.toUpperCase()))
                        .toList(),
                  ),
                ),
                const Divider(height: 1),
                _row(
                  icon: Icons.palette_outlined,
                  title: 'Color quality',
                  trailing: NeonDropdown<ColorQuality>(
                    value: s.colorQuality,
                    onChanged: (v) {
                      if (v != null) s.colorQuality = v;
                    },
                    items: [
                      const ColorQuality(bitDepth: 0, chromaFormat: 0),
                      const ColorQuality(bitDepth: 0, chromaFormat: 1),
                      const ColorQuality(bitDepth: 1, chromaFormat: 0),
                      const ColorQuality(bitDepth: 1, chromaFormat: 1),
                    ]
                        .map((c) => NeonDropdownItem(c, _colorLabel(c)))
                        .toList(),
                  ),
                ),
                const Divider(height: 1),
                _row(
                  icon: Icons.bolt,
                  title: 'L4S',
                  subtitle: 'Low-latency networking',
                  trailing: Switch(
                    value: s.enableL4S,
                    onChanged: (v) => s.enableL4S = v,
                  ),
                ),
                const Divider(height: 1),
                _row(
                  icon: Icons.monitor_heart_outlined,
                  title: 'Cloud G-SYNC',
                  subtitle: 'Reflex-compatible VRR',
                  trailing: Switch(
                    value: s.enableCloudGsync,
                    onChanged: (v) => s.enableCloudGsync = v,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget trailing,
  }) {
    return NeonSettingTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
    );
  }

  String _colorLabel(ColorQuality c) {
    final depth = c.bitDepth == 1 ? '10-bit' : '8-bit';
    final chroma = c.chromaFormat == 1 ? '4:4:4' : '4:2:0';
    return '$depth $chroma';
  }
}
