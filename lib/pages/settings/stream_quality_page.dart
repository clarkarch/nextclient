import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../main.dart';
import '../../state/user_settings.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_dropdown.dart';
import '../../widgets/neon_experimental_tag.dart';
import '../../widgets/neon_option_chip.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../../widgets/neon_switch.dart';

/// Stream options sent to the NVIDIA server on launch. Options are gated by
/// the account's entitled resolutions when the subscription is known.
class StreamQualityPage extends StatefulWidget {
  final AppServices services;

  const StreamQualityPage({super.key, required this.services});

  @override
  State<StreamQualityPage> createState() => _StreamQualityPageState();
}

class _StreamQualityPageState extends State<StreamQualityPage> {
  SubscriptionInfo? _subscription;

  /// Resolution options grouped by aspect ratio, with membership tier tags.
  static const _resolutions = <String, List<_ResOption>>{
    '16:9': [
      _ResOption('1280x720', '720p', OptionTier.free, 1280, 720),
      _ResOption('1920x1080', '1080p', OptionTier.free, 1920, 1080),
      _ResOption('2560x1440', '1440p', OptionTier.priority, 2560, 1440),
      _ResOption('3840x2160', '4K', OptionTier.ultimate, 3840, 2160),
      _ResOption('5120x2880', '5K', OptionTier.ultimate, 5120, 2880),
    ],
    '16:10': [
      _ResOption('1680x1050', 'WSXGA', OptionTier.free, 1680, 1050),
      _ResOption('1920x1200', '1200p', OptionTier.free, 1920, 1200),
      _ResOption('2560x1600', '1600p', OptionTier.priority, 2560, 1600),
      _ResOption('3840x2400', '4K', OptionTier.ultimate, 3840, 2400),
    ],
    '21:9': [
      _ResOption('2560x1080', 'Ultrawide 1080p', OptionTier.free, 2560, 1080),
      _ResOption(
        '3440x1440',
        'Ultrawide 1440p',
        OptionTier.priority,
        3440,
        1440,
      ),
    ],
    '32:9': [
      _ResOption(
        '5120x1440',
        'Super Ultrawide',
        OptionTier.ultimate,
        5120,
        1440,
      ),
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
  static const _bitrateMax = 200;

  bool get _isFreeTier {
    final tier = widget.services.auth.getSession()?.user.membershipTier;
    return tier == null || tier.toUpperCase() == 'FREE';
  }

  @override
  void initState() {
    super.initState();
    widget.services.loadSubscription().then((info) {
      if (mounted) setState(() => _subscription = info);
    });
  }

  /// Whether an option is usable. Prefers the account's entitled
  /// resolutions; falls back to membership-tier rules when unknown.
  bool _canUse(OptionTier tier, {int? width, int? height, int? fps}) {
    final subscription = _subscription;
    if (subscription != null) {
      final entitled = subscription.entitledResolutions;
      if (entitled.isNotEmpty) {
        if (width != null && height != null) {
          return entitled.any((r) => r.width == width && r.height == height);
        }
        if (fps != null) {
          return entitled.any((r) => r.fps == fps);
        }
        return true;
      }
    }
    return !_isFreeTier || tier == OptionTier.free;
  }

  /// Resolution options derived from the account's entitled resolutions,
  /// grouped by aspect ratio. When the subscription is known this is the
  /// authoritative list — it can contain more (or fewer) options than the
  /// hardcoded defaults, so we only ever offer server-approved combinations.
  Map<String, List<_ResOption>> get _resolutionGroups {
    final entitled = _subscription?.entitledResolutions ?? const [];
    if (entitled.isEmpty) return _resolutions;

    final groups = <String, List<_ResOption>>{};
    final seen = <String>{};
    for (final r in entitled) {
      final key = '${r.width}x${r.height}';
      if (!seen.add(key)) continue;
      final ratio = _aspectRatio(r.width, r.height);
      (groups[ratio] ??= []).add(
        _ResOption(
          key,
          _resolutionLabel(r.width, r.height),
          OptionTier.free,
          r.width,
          r.height,
        ),
      );
    }
    return groups;
  }

  /// FPS options derived from the account's entitled resolutions, gated to the
  /// currently-selected resolution when the subscription is known (entitlement
  /// is per resolution+fps combo, so offering a global fps list could let a
  /// user pick a combo the server rejects). Sorted ascending. Falls back to the
  /// hardcoded list when the subscription is unknown.
  List<int> _entitledFpsOptions(UserSettings s) {
    final entitled = _subscription?.entitledResolutions ?? const [];
    if (entitled.isEmpty) return _fpsOptions.map((e) => e.$1).toList();

    final parts = s.resolution.split('x');
    final width = int.tryParse(parts.isNotEmpty ? parts.first : '');
    final height = int.tryParse(parts.length > 1 ? parts[1] : '');
    final fpsSet = <int>{
      for (final r in entitled)
        if (r.width == width && r.height == height) r.fps,
    };
    if (fpsSet.isEmpty) {
      // Selected resolution isn't in the entitled list (e.g. stale saved
      // value) — fall back to any entitled fps so the user can still proceed.
      fpsSet.addAll({for (final r in entitled) r.fps});
    }
    return fpsSet.toList()..sort();
  }

  static String _aspectRatio(int width, int height) {
    // Label by the conventional ratio (16:9, 16:10, 21:9, 32:9) — a pure GCD
    // fraction would render 1920x1200 as "8:5" which is inconsistent with the
    // rest of the app's grouping.
    const canonical = [
      (w: 16, h: 9),
      (w: 16, h: 10),
      (w: 21, h: 9),
      (w: 32, h: 9),
      (w: 4, h: 3),
      (w: 5, h: 4),
      (w: 3, h: 2),
    ];
    final ratio = width / height;
    for (final c in canonical) {
      if ((c.w / c.h - ratio).abs() < 0.08) return '${c.w}:${c.h}';
    }
    // Fall back to a reduced fraction.
    var a = width;
    var b = height;
    while (b != 0) {
      final t = a % b;
      a = b;
      b = t;
    }
    return '${width ~/ a}:${height ~/ a}';
  }

  static String _resolutionLabel(int width, int height) {
    const common = {
      '1280x720': '720p',
      '1920x1080': '1080p',
      '2560x1440': '1440p',
      '3840x2160': '4K',
      '1680x1050': 'WSXGA',
      '1920x1200': '1200p',
      '2560x1600': '1600p',
      '3840x2400': '4K',
      '2560x1080': 'Ultrawide 1080p',
      '3440x1440': 'Ultrawide 1440p',
      '5120x1440': 'Super Ultrawide',
    };
    return common['${width}x$height'] ?? '${width}x$height';
  }

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Stream',
      showBack: true,
      child: ListenableBuilder(
        listenable: widget.services.settings,
        builder: (context, _) {
          final s = widget.services.settings;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NeonCard(
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
                    const SizedBox(height: 6),
                    _toggleRow(
                      icon: Icons.auto_awesome_motion,
                      title: 'Constant quality',
                      subtitle:
                          'Holds full bitrate during complex scenes by '
                          'disabling the server\'s adaptive rate control. '
                          'Best on stable connections — pair with a higher '
                          'Max bitrate.',
                      value: s.optConstantQuality,
                      onChanged: (v) => s.optConstantQuality = v,
                    ),
                    const SizedBox(height: 22),
                    const _SectionLabel(label: 'Codec'),
                    const SizedBox(height: 10),
                    _codecDropdown(s),
                    const SizedBox(height: 22),
                    const _SectionLabel(label: 'Color quality'),
                    const SizedBox(height: 10),
                    _colorDropdown(s),
                    const SizedBox(height: 22),
                    _SectionLabel(label: 'Launch mode'),
                    const SizedBox(height: 10),
                    _appLaunchModeDropdown(s),
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
                    Padding(
                      padding: const EdgeInsets.only(left: 4, top: 8),
                      child: _SectionLabel(label: 'Native Cloud G-SYNC mode'),
                    ),
                    const SizedBox(height: 8),
                    _nativeCloudGsyncDropdown(s),
                  ],
                ),
              ),
              if (_isFreeTier) ...[
                const SizedBox(height: 14),
                _buildFreeTierUpgradeCard(),
              ],
              const SizedBox(height: 14),
              _experimentalServerCard(s),
            ],
          );
        },
      ),
    );
  }

  /// Server-side adaptation knobs sent via nvstSdp (the server may ignore
  /// them). Kept as stable settings but flagged EXPERIMENTAL.
  Widget _experimentalServerCard(UserSettings s) {
    return NeonCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'SERVER ADAPTATION',
                  style: TextStyle(
                    color: Neon.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ),
              const NeonExperimentalTag(),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Unverified options baked into nvstSdp at session start — they only '
            'affect new sessions and the server may ignore them.',
            style: TextStyle(color: Neon.inkMuted, fontSize: 12),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'STREAM PRIORITY PRESETS',
                  style: TextStyle(
                    color: Neon.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ),
              NeonSwitch(
                value: s.streamPriorityEnabled,
                onChanged: (v) => s.streamPriorityEnabled = v,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            s.streamPriorityEnabled
                ? 'Active — the preset below is sent via nvstSdp. OFF is the '
                      'safe default (matches the original OpenNOW profile).'
                : 'Off (default) — the stream uses the safe quality profile, '
                      'matching original OpenNOW behavior. Enable to experiment.',
            style: const TextStyle(color: Neon.inkMuted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
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
          const SizedBox(height: 14),
          _toggleRow(
            icon: Icons.bolt_outlined,
            title: 'Low-latency mode',
            subtitle: 'Tightens server frame pacing, packet delay budget and '
                'RTCP feedback cadence. Lower input latency, less jitter '
                'tolerance.',
            value: s.optLowLatencyMode,
            onChanged: (v) => s.optLowLatencyMode = v,
          ),
          const SizedBox(height: 14),
          const Text(
            'RECOVERY',
            style: TextStyle(
              color: Neon.accent,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'How the server repairs packet loss. Smooth keeps a deep NACK '
            'window (resilient, but grows latency under loss); latency uses a '
            'shallow window + fresh keyframes.',
            style: TextStyle(color: Neon.inkMuted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in StreamRecoveryProfile.values)
                NeonOptionChip(
                  label: p.name.toUpperCase(),
                  selected: p == s.optRecoveryProfile,
                  onTap: () => s.optRecoveryProfile = p,
                ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            'MIN BITRATE FLOOR',
            style: TextStyle(
              color: Neon.accent,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Lower bound the server targets even when bandwidth estimation '
            'drops. Higher = stable quality; lower = faster BWE shed.',
            style: TextStyle(color: Neon.inkMuted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: (s.optMinBitrateKbps / 1000).clamp(1, 30),
                  min: 1,
                  max: 30,
                  divisions: 29,
                  activeColor: Neon.accent,
                  inactiveColor: Neon.bgC,
                  label: '${s.optMinBitrateKbps ~/ 1000} Mbps',
                  onChanged: (v) =>
                      s.optMinBitrateKbps = (v * 1000).round(),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${s.optMinBitrateKbps ~/ 1000} Mbps',
                style: const TextStyle(
                  color: Neon.inkSoft,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _toggleRow(
            icon: Icons.refresh,
            title: 'Enable NACK retransmission',
            subtitle: 'Request re-sends of lost RTP packets.',
            value: s.optEnableNack,
            onChanged: (v) => s.optEnableNack = v,
          ),
          _toggleRow(
            icon: Icons.dehaze,
            title: 'Enable FEC forward error correction',
            subtitle: 'Recover loss with redundant packets.',
            value: s.optEnableFec,
            onChanged: (v) => s.optEnableFec = v,
          ),
          const SizedBox(height: 6),
          const Text(
            'Both negotiate recovery with the server. Disabling both maximizes '
            'bandwidth headroom for video but makes loss bursts more visible.',
            style: TextStyle(color: Neon.inkMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// Upgrade CTA shown to free-tier accounts: some options here are locked by
  /// membership tier, so point users at NVIDIA's premium memberships page.
  static const _upgradeUrl =
      'https://www.nvidia.com/en-us/geforce-now/premium-memberships/';

  Widget _buildFreeTierUpgradeCard() {
    return NeonCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.workspace_premium, size: 20, color: Neon.accent),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'UNLOCK MORE',
                  style: TextStyle(
                    color: Neon.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Some resolutions, frame rates, and features require a '
            'GeForce NOW premium membership.',
            style: TextStyle(color: Neon.inkSoft, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 14),
          NeonButton(
            label: 'View premium memberships',
            icon: Icons.open_in_new,
            onPressed: () => launchUrl(
              Uri.parse(_upgradeUrl),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ],
      ),
    );
  }

  Widget _resolutionSelector(UserSettings s) {
    final groups = _resolutionGroups;
    var currentRatio = groups.keys.first;
    for (final entry in groups.entries) {
      if (entry.value.any((r) => r.resolution == s.resolution)) {
        currentRatio = entry.key;
        break;
      }
    }
    final options = groups[currentRatio] ?? const <_ResOption>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final ratio in groups.keys)
              NeonOptionChip(
                label: ratio,
                selected: ratio == currentRatio,
                onTap: () {
                  final inRatio = groups[ratio]!.any(
                    (r) => r.resolution == s.resolution,
                  );
                  if (!inRatio) {
                    s.resolution = groups[ratio]!.first.resolution;
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
                enabled: _canUse(
                  opt.tier,
                  width: opt.width,
                  height: opt.height,
                ),
                onTap: () => s.resolution = opt.resolution,
              ),
          ],
        ),
      ],
    );
  }

  Widget _fpsSelector(UserSettings s) {
    final hasSubscription =
        (_subscription?.entitledResolutions.isNotEmpty ?? false);
    if (hasSubscription) {
      final fpsOptions = _entitledFpsOptions(s);
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final fps in fpsOptions)
            NeonOptionChip(
              label: '$fps fps',
              selected: s.fps == fps,
              onTap: () => s.fps = fps,
            ),
        ],
      );
    }
    // Subscription unknown: show the hardcoded tier-gated list.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (fps, tier) in _fpsOptions)
          NeonOptionChip(
            label: '$fps fps',
            selected: s.fps == fps,
            tier: tier,
            enabled: _canUse(tier, fps: fps),
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
            divisions: _bitrateMax - _bitrateMin,
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
              color: Neon.accent,
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
      ].map((c) => NeonDropdownItem(c, _colorLabel(c))).toList(),
    );
  }

  Widget _appLaunchModeDropdown(UserSettings s) {
    return NeonDropdown<AppLaunchMode>(
      value: s.appLaunchMode,
      onChanged: (v) {
        if (v != null) s.appLaunchMode = v;
      },
      items: [
        for (final m in AppLaunchMode.values)
          NeonDropdownItem(m, switch (m) {
            AppLaunchMode.default_ => 'Default',
            AppLaunchMode.gamepadFriendly => 'Gamepad friendly',
            AppLaunchMode.touchFriendly => 'Touch friendly',
          }),
      ],
    );
  }

  Widget _nativeCloudGsyncDropdown(UserSettings s) {
    return NeonDropdown<NativeStreamerFeatureMode>(
      value: s.nativeCloudGsyncMode,
      onChanged: (v) {
        if (v != null) s.nativeCloudGsyncMode = v;
      },
      items: [
        for (final m in NativeStreamerFeatureMode.values)
          NeonDropdownItem(m, m.name.toUpperCase()),
      ],
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
      trailing: NeonSwitch(value: value, onChanged: onChanged),
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
  final int width;
  final int height;

  const _ResOption(
    this.resolution,
    this.label,
    this.tier,
    this.width,
    this.height,
  );
}

class _SectionLabel extends StatelessWidget {
  final String label;

  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: Neon.accent,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 2,
      ),
    );
  }
}
