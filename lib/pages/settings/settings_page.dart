import 'package:flutter/material.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../../widgets/section_header.dart';
import 'account_page.dart';
import 'language_page.dart';
import 'region_page.dart';
import 'stream_quality_page.dart';

/// Settings hub: categories open nested screens. Only NVIDIA-touching options.
class SettingsPage extends StatelessWidget {
  final AppServices services;
  final VoidCallback onSignOut;

  const SettingsPage({
    super.key,
    required this.services,
    required this.onSignOut,
  });

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Settings'),
          NeonCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                NeonSettingTile(
                  icon: Icons.high_quality,
                  title: 'Stream Quality',
                  subtitle: _qualitySummary(),
                  onTap: () => _open(
                    context,
                    StreamQualityPage(services: services),
                  ),
                  trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
                ),
                const Divider(height: 1),
                NeonSettingTile(
                  icon: Icons.public,
                  title: 'Region',
                  subtitle: 'Streaming region',
                  onTap: () =>
                      _open(context, RegionPage(services: services)),
                  trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
                ),
                const Divider(height: 1),
                NeonSettingTile(
                  icon: Icons.language,
                  title: 'Language & Input',
                  subtitle: 'Game language · keyboard layout',
                  onTap: () =>
                      _open(context, LanguagePage(services: services)),
                  trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
                ),
                const Divider(height: 1),
                NeonSettingTile(
                  icon: Icons.person_outline,
                  title: 'Account',
                  subtitle: 'Profile · sign out',
                  onTap: () => _open(
                    context,
                    AccountPage(services: services, onSignOut: onSignOut),
                  ),
                  trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _qualitySummary() {
    final s = services.settings;
    return '${s.resolution} · ${s.fps}fps · ${s.maxBitrateMbps} Mbps · '
        '${s.codec.name.toUpperCase()}';
  }
}
