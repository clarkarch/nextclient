import 'package:flutter/material.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../../widgets/neon_switch.dart';

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
                    'Puts a translucent box at the client-rendered cursor '
                    'position so you can inspect the overlay\'s bounding box '
                    '(size, hotspot offset, and tracking) without relying on '
                    'the cursor bitmap alone. Off by default.',
                    style:
                        const TextStyle(color: Neon.inkMuted, fontSize: 12),
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