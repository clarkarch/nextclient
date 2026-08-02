import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../../widgets/neon_switch.dart';

/// Performance category: local client-behavior knobs. Currently a verbose-log
/// toggle that gates recording into the in-memory log buffer (also surfaced in
/// the Logs viewer). Applies immediately via [AppServices.logSink].
class PerformanceSettingsPage extends StatelessWidget {
  final AppServices services;

  const PerformanceSettingsPage({super.key, required this.services});

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Performance',
      showBack: true,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final logsEnabled = services.settings.logsEnabled;
          return NeonCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                NeonSettingTile(
                  icon: Icons.terminal,
                  title: 'Verbose logs',
                  subtitle: 'Record app activity into the log buffer',
                  trailing: NeonSwitch(
                    value: logsEnabled,
                    onChanged: (v) {
                      // Log the transition before flipping the sink so the
                      // toggle event itself is always captured.
                      services.logSink.log(
                        LogLevel.info,
                        'perf',
                        'Verbose logging ${v ? 'enabled' : 'disabled'}',
                      );
                      services.settings.logsEnabled = v;
                      services.logSink.setEnabledForAll(v);
                    },
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: Text(
                    'Every log line is formatted, scrubbed for sensitive '
                    'values, and stored in the in-memory buffer. Turning logs '
                    'off skips that work, which can improve performance and '
                    'reduce memory on slower hardware — especially during '
                    'session setup and teardown.\n\n'
                    'When off, nothing new is recorded (existing entries are '
                    'kept). Turn it on before reproducing an issue so the Logs '
                    'viewer captures what happens.',
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
