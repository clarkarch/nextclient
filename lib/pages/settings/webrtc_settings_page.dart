import 'package:flutter/material.dart';

import '../../main.dart';
import '../../state/user_settings.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_dropdown.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../../widgets/neon_switch.dart';

/// WebRTC client-side transport options (local client behavior, not sent to
/// the NVIDIA server) plus the input-pipeline knobs (mouse shaping + cursor
/// overlay) that ride on the WebRTC input data channels.
class WebRtcSettingsPage extends StatefulWidget {
  final AppServices services;

  const WebRtcSettingsPage({super.key, required this.services});

  @override
  State<WebRtcSettingsPage> createState() => _WebRtcSettingsPageState();
}

class _WebRtcSettingsPageState extends State<WebRtcSettingsPage> {
  late final TextEditingController _stunController;

  static const _samplingOptions = [
    (-1, 'Immediate'),
    (0, 'Adaptive'),
    (4, '4 ms'),
    (8, '8 ms'),
    (16, '16 ms'),
  ];

  AppServices get services => widget.services;

  @override
  void initState() {
    super.initState();
    _stunController =
        TextEditingController(text: services.settings.webrtcStunServer);
  }

  @override
  void dispose() {
    _stunController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = services.settings;
    return NeonPageScaffold(
      title: 'WebRTC',
      showBack: true,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NeonCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  NeonSettingTile(
                    icon: Icons.route,
                    title: 'ICE transport policy',
                    subtitle: 'relay forces TURN relay only',
                    trailing: NeonDropdown<WebrtcIceTransportPolicy>(
                      value: s.webrtcIceTransport,
                      width: 132,
                      onChanged: (v) {
                        if (v != null) s.webrtcIceTransport = v;
                      },
                      items: const [
                        NeonDropdownItem(
                          WebrtcIceTransportPolicy.all,
                          'All',
                        ),
                        NeonDropdownItem(
                          WebrtcIceTransportPolicy.relay,
                          'Relay',
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  NeonSettingTile(
                    icon: Icons.hourglass_bottom,
                    title: 'ICE candidate pool',
                    subtitle: 'Pre-gathered candidates before offer',
                    trailing: NeonDropdown<int>(
                      value: s.webrtcIcePoolSize,
                      width: 92,
                      onChanged: (v) {
                        if (v != null) s.webrtcIcePoolSize = v;
                      },
                      items: [
                        for (var i = 0; i <= 6; i++)
                          NeonDropdownItem<int>(i, '$i'),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  NeonSettingTile(
                    icon: Icons.merge,
                    title: 'Bundle policy',
                    subtitle: 'Transports bundled into one',
                    trailing: NeonDropdown<WebrtcBundlePolicy>(
                      value: s.webrtcBundle,
                      width: 132,
                      onChanged: (v) {
                        if (v != null) s.webrtcBundle = v;
                      },
                      items: const [
                        NeonDropdownItem(
                          WebrtcBundlePolicy.balanced,
                          'Balanced',
                        ),
                        NeonDropdownItem(
                          WebrtcBundlePolicy.maxCompat,
                          'Max compat',
                        ),
                        NeonDropdownItem(
                          WebrtcBundlePolicy.maxBundle,
                          'Max bundle',
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  NeonSettingTile(
                    icon: Icons.call_merge,
                    title: 'RTCP mux policy',
                    subtitle: 'RTP + RTCP on one socket',
                    trailing: NeonDropdown<WebrtcRtcpMuxPolicy>(
                      value: s.webrtcRtcpMux,
                      width: 132,
                      onChanged: (v) {
                        if (v != null) s.webrtcRtcpMux = v;
                      },
                      items: const [
                        NeonDropdownItem(
                          WebrtcRtcpMuxPolicy.require,
                          'Require',
                        ),
                        NeonDropdownItem(
                          WebrtcRtcpMuxPolicy.negotiate,
                          'Negotiate',
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  NeonSettingTile(
                    icon: Icons.memory,
                    title: 'Hardware acceleration',
                    subtitle: 'GPU video decode when available',
                    trailing: NeonSwitch(
                      value: s.webrtcHwAccel,
                      onChanged: (v) => s.webrtcHwAccel = v,
                    ),
                  ),
                  const Divider(height: 1),
                  NeonSettingTile(
                    icon: Icons.network_check,
                    title: 'DSCP marking (QoS)',
                    subtitle: 'Mark RTP packets for network prioritization',
                    trailing: NeonSwitch(
                      value: s.webrtcEnableDscp,
                      onChanged: (v) => s.webrtcEnableDscp = v,
                    ),
                  ),
                  const Divider(height: 1),
                  NeonSettingTile(
                    icon: Icons.dns_outlined,
                    title: 'Max IPv6 networks',
                    subtitle: 'Limit IPv6 candidate networks gathered',
                    trailing: NeonDropdown<int>(
                      value: s.webrtcMaxIpv6Networks,
                      width: 92,
                      onChanged: (v) {
                        if (v != null) s.webrtcMaxIpv6Networks = v;
                      },
                      items: const [
                        NeonDropdownItem<int>(8, '8'),
                        NeonDropdownItem<int>(16, '16'),
                        NeonDropdownItem<int>(32, '32'),
                        NeonDropdownItem<int>(64, '64'),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'EXTRA STUN / TURN SERVERS',
                          style: TextStyle(
                            color: Neon.inkMuted,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.6,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _stunController,
                          onChanged: (v) => s.webrtcStunServer = v,
                          style: const TextStyle(
                            color: Neon.ink,
                            fontSize: 13,
                          ),
                          decoration: InputDecoration(
                            hintText: 'stun:stun.example.com:3478',
                            hintStyle: const TextStyle(
                              color: Neon.inkMuted,
                              fontSize: 12,
                            ),
                            isDense: true,
                            filled: true,
                            fillColor: Neon.bgC,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                color: Neon.accent,
                                width: 1.2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _inputCard(s),
          ],
        ),
      ),
    );
  }

  /// Input-pipeline knobs that ride the WebRTC input data channels (ported
  /// from OpenNOW's settings): mouse shaping + in-game cursor overlay.
  Widget _inputCard(UserSettings s) {
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          const NeonSettingSection(label: 'Input'),
          NeonSettingTile(
            icon: Icons.speed,
            title: 'Mouse sensitivity',
            subtitle:
                '${s.inputMouseSensitivity.toStringAsFixed(2)}× · 1.00× = default',
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: s.inputMouseSensitivity,
                min: 0.25,
                max: 4.0,
                divisions: 15,
                label: '${s.inputMouseSensitivity.toStringAsFixed(2)}×',
                onChanged: (v) => s.inputMouseSensitivity = v,
              ),
            ),
          ),
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.rocket_launch_outlined,
            title: 'Mouse acceleration',
            subtitle:
                '${s.inputMouseAcceleration} · 1 = off (OpenNOW curve)',
            trailing: SizedBox(
              width: 150,
              child: Slider(
                value: s.inputMouseAcceleration.toDouble(),
                min: 1,
                max: 150,
                divisions: 149,
                label: '${s.inputMouseAcceleration}',
                onChanged: (v) => s.inputMouseAcceleration = v.round(),
              ),
            ),
          ),
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.auto_fix_high,
            title: 'High-precision mouse',
            subtitle: 'Keep sub-pixel movement — micro-deltas accumulate '
                'instead of being dropped',
            trailing: NeonSwitch(
              value: s.inputMousePrecision,
              onChanged: (v) => s.inputMousePrecision = v,
            ),
          ),
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.timer_outlined,
            title: 'Mouse sampling',
            subtitle: _samplingSubtitle(s.inputMouseSamplingMs),
            trailing: NeonDropdown<int>(
              value: s.inputMouseSamplingMs,
              width: 120,
              onChanged: (v) {
                if (v != null) s.inputMouseSamplingMs = v;
              },
              items: [
                for (final o in _samplingOptions)
                  NeonDropdownItem<int>(o.$1, o.$2),
              ],
            ),
          ),
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.mouse,
            title: 'In-game cursor overlay',
            subtitle: "Render the game's cursor client-side via "
                'cursor_channel (predefined styles + custom bitmaps)',
            trailing: NeonSwitch(
              value: s.inputCursorOverlay,
              onChanged: (v) => s.inputCursorOverlay = v,
            ),
          ),
        ],
      ),
    );
  }

  String _samplingSubtitle(int ms) => switch (ms) {
        < 0 => 'Every event sent as-is — minimal latency, most packets',
        0 => 'Auto: 2–20 ms tuned from SCTP backpressure',
        _ => 'Fixed $ms ms batch — fewer packets, up to +$ms ms',
      };
}
