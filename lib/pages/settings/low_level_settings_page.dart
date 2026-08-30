import 'package:flutter/material.dart';

import '../../main.dart';
import '../../state/user_settings.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_option_chip.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../../widgets/neon_switch.dart';

/// Low-level stream tuning: raw nvstSdp knobs that control the NVIDIA server's
/// encoder, pacing, and recovery. All map 1:1 to `GfnSdpMunger.buildNvstSdp`.
/// When everything is at the official defaults the outgoing SDP is byte-identical
/// to `play.geforcenow.com` (verified against the vendor bundle), so the happy
/// path is server-proven. The toggles here only add overrides when you diverge.
///
/// Lives in the advanced Settings hub so power tinkerers can find it without
/// cluttering the main Stream page.
class LowLevelSettingsPage extends StatelessWidget {
  final AppServices services;

  const LowLevelSettingsPage({super.key, required this.services});

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Low level',
      showBack: true,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final s = services.settings;
          final isOfficial = !s.streamPriorityEnabled &&
              !s.optLowLatencyMode &&
              s.optRecoveryProfile == StreamRecoveryProfile.smooth &&
              s.optMinBitrateKbps == 4000 &&
              s.optEnableNack &&
              s.optEnableFec &&
              !s.optConstantQuality;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NeonCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: isOfficial ? Neon.success.withValues(alpha: 0.14) : Neon.warning.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: isOfficial ? Neon.success.withValues(alpha: 0.3) : Neon.warning.withValues(alpha: 0.3)),
                          ),
                          child: Text(
                            isOfficial ? 'OFFICIAL PROFILE' : 'CUSTOM OVERRIDES ACTIVE',
                            style: TextStyle(
                              color: isOfficial ? Neon.success : Neon.warning,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: isOfficial
                              ? null
                              : () {
                                  s.streamPriorityEnabled = false;
                                  s.streamPriority = StreamPriority.quality;
                                  s.optLowLatencyMode = false;
                                  s.optRecoveryProfile = StreamRecoveryProfile.smooth;
                                  s.optMinBitrateKbps = 4000;
                                  s.optEnableNack = true;
                                  s.optEnableFec = true;
                                  s.optConstantQuality = false;
                                },
                          child: const Text('Reset to official'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isOfficial
                          ? 'Matches play.geforcenow.com exactly (dynamicStreamingMode:3, featureMask:3, NACK 1024). Best BWE ramp and proven stability.'
                          : 'One or more overrides are active. The server may ignore unknown caps. Test on a short session before a ranked run.',
                      style: const TextStyle(color: Neon.inkMuted, fontSize: 12, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _priorityCard(s),
              const SizedBox(height: 14),
              _latencyCard(s),
              const SizedBox(height: 14),
              _recoveryCard(s),
              const SizedBox(height: 14),
              _bitrateCard(s),
              const SizedBox(height: 14),
              _reliabilityCard(s),
              const SizedBox(height: 14),
              _constantQualityCard(s),
            ],
          );
        },
      ),
    );
  }

  Widget _priorityCard(UserSettings s) {
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NeonSettingSection(label: 'Stream priority'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              s.streamPriorityEnabled
                  ? 'When on, the preset below is baked into nvstSdp at session start.'
                  : 'Off = official quality profile (no resolution scaling, pinned 100%). Enable to let the server trade resolution for fps under load.',
              style: const TextStyle(color: Neon.inkMuted, fontSize: 12),
            ),
          ),
          NeonSettingTile(
            icon: Icons.tune,
            title: 'Enable priority presets',
            subtitle: s.streamPriorityEnabled ? 'Overrides active' : 'Official profile',
            trailing: NeonSwitch(
              value: s.streamPriorityEnabled,
              onChanged: (v) => s.streamPriorityEnabled = v,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in StreamPriority.values)
                  NeonOptionChip(
                    label: p.name.toUpperCase(),
                    selected: p == s.streamPriority,
                    enabled: s.streamPriorityEnabled,
                    onTap: () => s.streamPriority = p,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Text(
              switch (s.streamPriority) {
                StreamPriority.quality => 'quality: 100% min resolution, no scaling. Best sharpness.',
                StreamPriority.balanced => 'balanced: 60% floor, resolution + fps adapt together.',
                StreamPriority.fps => 'fps: 40% floor, drops resolution first to hold frame rate.',
              },
              style: const TextStyle(color: Neon.inkSoft, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _latencyCard(UserSettings s) {
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NeonSettingSection(label: 'Latency'),
          NeonSettingTile(
            icon: Icons.bolt_outlined,
            title: 'Low-latency mode',
            subtitle: 'Tightens frame pacing (60% target), packet delay 500µs, RTCP feedback 100ms. Lower input lag, less jitter tolerance.',
            trailing: NeonSwitch(
              value: s.optLowLatencyMode,
              onChanged: (v) => s.optLowLatencyMode = v,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Text(
              s.optLowLatencyMode
                  ? 'Active: encoder holds less buffered video. May stutter on unstable Wi-Fi.'
                  : 'Off: official 200ms feedback, 1000µs pacing (stable default).',
              style: const TextStyle(color: Neon.inkMuted, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recoveryCard(UserSettings s) {
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NeonSettingSection(label: 'Recovery'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              'How the server repairs packet loss. Deep NACK window is resilient but adds latency under loss; shallow + preemptive IDR recovers faster with a fresh keyframe.',
              style: TextStyle(color: Neon.inkMuted, fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in StreamRecoveryProfile.values)
                  NeonOptionChip(
                    label: switch (p) {
                      StreamRecoveryProfile.smooth => 'SMOOTH (1024)',
                      StreamRecoveryProfile.balanced => 'BALANCED (512)',
                      StreamRecoveryProfile.latency => 'LATENCY (256)',
                    },
                    selected: p == s.optRecoveryProfile,
                    onTap: () => s.optRecoveryProfile = p,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
            child: Text(
              switch (s.optRecoveryProfile) {
                StreamRecoveryProfile.smooth => 'smooth: NACK 1024/512/25 — official size, best for lossy links.',
                StreamRecoveryProfile.balanced => 'balanced: 512/256/16 — middle ground.',
                StreamRecoveryProfile.latency => 'latency: 256/128/8 + preemptive IDR after burst loss. Lowest tail latency.',
              },
              style: const TextStyle(color: Neon.inkSoft, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bitrateCard(UserSettings s) {
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NeonSettingSection(label: 'Bitrate floor'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              'Minimum the server targets even when BWE drops. Higher = stable quality, slower shed. Official floor is 4000 kbps.',
              style: TextStyle(color: Neon.inkMuted, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Expanded(
                  child:                   Slider(
                    value: (s.optMinBitrateKbps / 1000).clamp(1, 30),
                    min: 1,
                    max: 30,
                    divisions: 29,
                    label: '${s.optMinBitrateKbps ~/ 1000} Mbps',
                    onChanged: (v) => s.optMinBitrateKbps = (v * 1000).round(),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${s.optMinBitrateKbps ~/ 1000} Mbps',
                    style: const TextStyle(color: Neon.inkSoft, fontSize: 13, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Text('Baked into a=vqos.bw.minimumBitrateKbps at session start.',
                style: const TextStyle(color: Neon.inkMuted, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _reliabilityCard(UserSettings s) {
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NeonSettingSection(label: 'Reliability'),
          NeonSettingTile(
            icon: Icons.refresh,
            title: 'Enable NACK',
            subtitle: 'Request retransmission of lost RTP packets (video.enableRtpNack).',
            trailing: NeonSwitch(value: s.optEnableNack, onChanged: (v) => s.optEnableNack = v),
          ),
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.dehaze,
            title: 'Enable FEC',
            subtitle: 'Redundant packets for forward correction (vqos.fec.*). Disabling frees bandwidth but hurts loss resilience.',
            trailing: NeonSwitch(value: s.optEnableFec, onChanged: (v) => s.optEnableFec = v),
          ),
        ],
      ),
    );
  }

  Widget _constantQualityCard(UserSettings s) {
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NeonSettingSection(label: 'Constant quality'),
          NeonSettingTile(
            icon: Icons.auto_awesome_motion,
            title: 'Constant quality',
            subtitle: 'Disable server BWE and start at max bitrate (vqos.bw.enableBandwidthEstimation:0). Holds quality in complex scenes, no graceful shed on bad Wi-Fi.',
            trailing: NeonSwitch(value: s.optConstantQuality, onChanged: (v) => s.optConstantQuality = v),
          ),
          if (s.optConstantQuality)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Text('Requires stable link. Pair with a higher Max bitrate on the Stream page.',
                  style: TextStyle(color: Neon.warning, fontSize: 11)),
            ),
        ],
      ),
    );
  }

}
