import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../pages/stream/stream_page.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../../widgets/neon_switch.dart';
import 'ads_tester_page.dart';

/// Debug diagnostics: client-side toggles for inspecting the in-game cursor
/// overlay without trial-and-error run→edit→rebuild loops.
class DebugSettingsPage extends StatelessWidget {
  final AppServices services;

  const DebugSettingsPage({super.key, required this.services});

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Debug',
      showBack: true,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          return NeonCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                NeonSettingTile(
                  icon: Icons.play_circle_outline,
                  title: 'Streaming UI demo',
                  subtitle:
                      'Open the stream surface on a fake session (no queue, no server)',
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Neon.inkMuted,
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => StreamPage(
                          services: services,
                          game: const CatalogGame(
                            id: 'demo',
                            title: 'Streaming UI Demo',
                          ),
                          demoMode: true,
                        ),
                      ),
                    );
                  },
                ),
                const Divider(height: 1),
                NeonSettingTile(
                  icon: Icons.movie_outlined,
                  title: 'Ads tester',
                  subtitle: 'Play an ad media URL via fvp (no session needed)',
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Neon.inkMuted,
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AdsTesterPage()),
                    );
                  },
                ),
                const Divider(height: 1),
                NeonSettingTile(
                  icon: Icons.track_changes,
                  title: 'Cursor overlay box',
                  subtitle: 'Show a filled box at the rendered cursor',
                  trailing: NeonSwitch(
                    value: services.settings.debugCursorOverlayBox,
                    onChanged: (v) {
                      services.settings.debugCursorOverlayBox = v;
                    },
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: Text(
                    'Cursor overlay box puts a translucent box at the rendered '
                    'cursor to inspect its bounding box and tracking. '
                    'Native cursor toggle now lives in Client settings.',
                    style: const TextStyle(color: Neon.inkMuted, fontSize: 12),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
