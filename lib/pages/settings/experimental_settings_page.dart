import 'package:flutter/material.dart';

import '../../main.dart';
import '../../state/user_settings.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_option_chip.dart';
import '../../widgets/neon_page_scaffold.dart';

/// Experimental settings: unverified options that tweak how the NVIDIA server
/// adapts the stream. They are baked into the nvstSdp at session start, so they
/// only affect new sessions, and the server may ignore them.
class ExperimentalSettingsPage extends StatelessWidget {
  final AppServices services;

  const ExperimentalSettingsPage({super.key, required this.services});

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Experimental',
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
                const Text(
                  'STREAM PRIORITY',
                  style: TextStyle(
                    color: Neon.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'How the server should adapt resolution/FPS under load. '
                  'Sent via nvstSdp at session start — affects new sessions '
                  'only, and NVIDIA may ignore these hints.',
                  style: TextStyle(color: Neon.inkMuted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in StreamPriority.values)
                      NeonOptionChip(
                        label: p.name.toUpperCase(),
                        selected: p == s.streamPriority,
                        onTap: () => s.streamPriority = p,
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  switch (s.streamPriority) {
                    StreamPriority.quality =>
                      'Full resolution & bitrate; drops decode FPS under load.',
                    StreamPriority.balanced =>
                      'Balances resolution and FPS (allows downscaling).',
                    StreamPriority.fps =>
                      'Holds frame rate; scales resolution down first.',
                  },
                  style: const TextStyle(color: Neon.inkSoft, fontSize: 12.5),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
