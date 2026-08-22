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
          final maxPerf = services.settings.maxPerformanceMode;
          final logsEnabled = services.settings.effectiveLogsEnabled;
          final rawLogs = services.settings.logsEnabled;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NeonCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    NeonSettingTile(
                      icon: Icons.bolt,
                      title: 'Max performance mode',
                      subtitle: maxPerf
                          ? 'ENGAGED · hardware decode, GPU renderer, shader off, throttled stats, low overhead UI (Linux/Android)'
                          : 'Forces best path for streaming: hardware decode + GPU renderer, shader off, throttled telemetry, static background',
                      trailing: NeonSwitch(
                        value: maxPerf,
                        onChanged: (v) {
                          services.settings.maxPerformanceMode = v;
                          // Effective logs follow max-perf (forced off when engaged)
                          services.logSink.setEnabledForAll(
                            services.settings.effectiveLogsEnabled,
                          );
                          services.logSink.log(
                            LogLevel.info,
                            'perf',
                            'Max performance ${v ? 'ENGAGED' : 'disengaged'} '
                                '(hwAccel=${services.settings.effectiveHwAccel} '
                                'renderer=${services.settings.effectiveRendererBackend.name} '
                                'shader=${services.settings.effectiveVideoShader.enabled ? 'on' : 'off'} '
                                'poll=${services.settings.statsPollInterval.inMilliseconds}ms)',
                          );
                          if (v) {
                            // Push the forced-off shader immediately so the
                            // native EGL/D3D post-pass drops its FBO on next
                            // frame without waiting for a new session.
                            services.settings.addListener(
                              () {},
                            ); // ensure rebuild
                          }
                        },
                      ),
                    ),
                    if (maxPerf)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(14, 0, 14, 12),
                        child: Text(
                          'While engaged: shader filters are suppressed, telemetry '
                          'is throttled (1s vs 0.5s getStats), UI shadows/blurs are '
                          'reduced, animated background is forced to Subtle, and '
                          'Android requests sustained performance + keepScreenOn.',
                          style: TextStyle(color: Neon.warning, fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              NeonCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    NeonSettingTile(
                      icon: Icons.schedule,
                      title: 'Latency guard',
                      subtitle: maxPerf
                          ? 'Active (max performance keeps it on): keyframe '
                                'resync when the stream falls behind'
                          : 'Auto keyframe resync when the stream falls '
                                'behind over time. Off = best picture '
                                'consistency, manual recovery only.',
                      trailing: NeonSwitch(
                        value: maxPerf
                            ? true
                            : services.settings.latencyGuardEnabled,
                        onChanged: (v) {
                          if (!maxPerf) {
                            services.settings.latencyGuardEnabled = v;
                          }
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    NeonSettingTile(
                      icon: Icons.speed,
                      title: 'Zero playout delay',
                      subtitle:
                          'Render frames instantly instead of smoothing '
                          'arrival bursts. Lowest delay; may stutter on '
                          'unstable Wi-Fi. Applies after restart.',
                      trailing: NeonSwitch(
                        value: services.settings.zeroPlayoutDelayEnabled,
                        onChanged: (v) =>
                            services.settings.zeroPlayoutDelayEnabled = v,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              NeonCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    NeonSettingTile(
                      icon: Icons.terminal,
                      title: 'Verbose logs',
                      subtitle: maxPerf
                          ? 'Suppressed by max performance (forced off)'
                          : 'Record app activity into the log buffer',
                      trailing: Opacity(
                        opacity: maxPerf ? 0.45 : 1,
                        child: IgnorePointer(
                          ignoring: maxPerf,
                          child: NeonSwitch(
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
                      ),
                    ),
                    if (!maxPerf) ...[
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
                          style: const TextStyle(
                            color: Neon.inkMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ] else
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                        child: Text(
                          'Verbose logging is forced off in max-performance mode to '
                          'avoid formatting/scrubbing overhead per frame. Disable max '
                          'performance to re-enable it (currently ${rawLogs ? 'on' : 'off'} underneath).',
                          style: const TextStyle(
                            color: Neon.inkMuted,
                            fontSize: 12,
                          ),
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
}
