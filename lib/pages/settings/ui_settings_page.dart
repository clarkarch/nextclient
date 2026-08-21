import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../state/title_bar_controller.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../../widgets/neon_switch.dart';

/// UI category: app-wide look. Background style plus a "hide title bar" toggle
/// (desktop only). The selection is persisted via [UserSettings]; the
/// background pushes to [BackgroundGlow] so every [NeonPageScaffold] restyles
/// live.
class UiSettingsPage extends StatelessWidget {
  final AppServices services;

  const UiSettingsPage({super.key, required this.services});

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'UI',
      showBack: true,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final selected = services.settings.backgroundStyle;
          final scalePercent = (services.settings.uiScale * 100)
              .round()
              .toDouble();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (TitleBarController.isSupported) ...[
                NeonCard(
                  padding: EdgeInsets.zero,
                  child: NeonSettingTile(
                    icon: Icons.web_asset,
                    title: 'Hide title bar',
                    subtitle: 'Frameless window (desktop only)',
                    trailing: NeonSwitch(
                      value: services.settings.hideTitleBar,
                      onChanged: (v) {
                        services.settings.hideTitleBar = v;
                        unawaited(TitleBarController.setHidden(v));
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              NeonCard(
                padding: EdgeInsets.zero,
                child: NeonSettingTile(
                  icon: Icons.animation,
                  title: 'Animations',
                  subtitle:
                      'Entrance fades, staggered cards, moving backgrounds',
                  trailing: NeonSwitch(
                    value: services.settings.uiAnimations,
                    onChanged: (v) => services.settings.uiAnimations = v,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              NeonCard(
                padding: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.format_size,
                            size: 20,
                            color: Neon.inkSoft,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'UI SCALE',
                              style: TextStyle(
                                color: Neon.ink,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Overall app text size. Scales dialogs, labels '
                              'and the stream chrome together; 100% is default.',
                              style: TextStyle(
                                color: Neon.inkMuted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '${(scalePercent).round()}%',
                            style: const TextStyle(
                              color: Neon.accent,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: scalePercent,
                        min: 75,
                        max: 150,
                        divisions: 15,
                        label: '${scalePercent.round()}%',
                        onChanged: (v) => services.settings.uiScale = v / 100,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _sizeProbe(0.8, 'A'),
                          _sizeProbe(1.0, 'A'),
                          _sizeProbe(1.5, 'A'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              NeonCard(
                padding: EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(14, 14, 14, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'BACKGROUND',
                          style: TextStyle(
                            color: Neon.inkMuted,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.6,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Same electric-blue glow, different paint algorithms.',
                            style: TextStyle(
                              color: Neon.inkSoft,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final option in BackgroundStyle.values)
                                _StyleOption(
                                  option: option,
                                  selected: option == selected,
                                  onTap: () =>
                                      services.settings.backgroundStyle =
                                          option,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Small preview glyph scaled by [size] so the slider's effect is visible
  /// without leaving the page.
  Widget _sizeProbe(double size, String label) {
    return SizedBox(
      width: 26,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Neon.inkMuted,
          fontSize: 14 * size,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Tappable live preview swatch for a background style.
class _StyleOption extends StatelessWidget {
  final BackgroundStyle option;
  final bool selected;
  final VoidCallback onTap;

  const _StyleOption({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 104,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Neon.bgB,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? Neon.accent : Neon.outline,
            width: selected ? 1.6 : 1,
          ),
          boxShadow: selected ? Neon.glowShadow(radius: 12, alpha: 0.3) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 46,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NeonBackground(style: option),
                    if (option.animated)
                      const Align(
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.play_circle_outline,
                          size: 16,
                          color: Neon.inkSoft,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    option.label,
                    style: TextStyle(
                      color: selected ? Neon.accent : Neon.inkSoft,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (selected)
                  const Icon(Icons.check_circle, size: 14, color: Neon.accent),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
