import 'package:flutter/material.dart';

import '../../main.dart';
import '../../state/user_settings.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_dropdown.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../../widgets/neon_switch.dart';
import '../../widgets/section_header.dart';
import '../log_viewer_page.dart';
import 'account_page.dart';
import 'language_page.dart';
import 'region_page.dart';
import 'stream_quality_page.dart';

/// Settings hub: categories open nested screens. Only NVIDIA-touching options.
///
/// With the Advanced Settings switch on, options are grouped under
/// SERVER SETTINGS (options sent to NVIDIA on launch) and CLIENT SETTINGS
/// (local client behavior, including WebRTC transport knobs) — inline labels,
/// no extra nesting.
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
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final advanced = services.settings.advancedMode;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(title: 'Settings'),
              _advancedToggleCard(),
              const SizedBox(height: 14),
              if (advanced) ...[
                const _GroupLabel('SERVER SETTINGS'),
                const SizedBox(height: 6),
                _serverCard(context),
                const SizedBox(height: 20),
                const _GroupLabel('CLIENT SETTINGS'),
                const SizedBox(height: 6),
                _clientCard(context),
              ] else
                _plainCard(context),
            ],
          );
        },
      ),
    );
  }

  Widget _advancedToggleCard() {
    return NeonCard(
      padding: EdgeInsets.zero,
      child: NeonSettingTile(
        icon: Icons.tune,
        title: 'Advanced Settings',
        subtitle: 'Group options into server & client settings',
        trailing: NeonSwitch(
          value: services.settings.advancedMode,
          onChanged: (v) => services.settings.advancedMode = v,
        ),
      ),
    );
  }

  /// Server-side options sent to the NVIDIA server on launch.
  Widget _serverCard(BuildContext context) {
    return NeonCard(
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
            onTap: () => _open(context, RegionPage(services: services)),
            trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
          ),
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.language,
            title: 'Language & Input',
            subtitle: 'Game language · keyboard layout',
            onTap: () => _open(context, LanguagePage(services: services)),
            trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
          ),
        ],
      ),
    );
  }

  /// Client-side options: WebRTC transport knobs + app-level settings.
  Widget _clientCard(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _WebRtcSettingsCard(services: services),
        const SizedBox(height: 12),
        NeonCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
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
              const Divider(height: 1),
              NeonSettingTile(
                icon: Icons.terminal,
                title: 'Logs',
                subtitle: 'Debug log viewer',
                onTap: () => _open(
                  context,
                  LogViewerPage(logSink: services.logSink),
                ),
                trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _plainCard(BuildContext context) {
    return NeonCard(
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
            onTap: () => _open(context, RegionPage(services: services)),
            trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
          ),
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.language,
            title: 'Language & Input',
            subtitle: 'Game language · keyboard layout',
            onTap: () => _open(context, LanguagePage(services: services)),
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
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.terminal,
            title: 'Logs',
            subtitle: 'Debug log viewer',
            onTap: () => _open(
              context,
              LogViewerPage(logSink: services.logSink),
            ),
            trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
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

/// Inline WebRTC client-side transport options (no nested screen).
class _WebRtcSettingsCard extends StatefulWidget {
  final AppServices services;

  const _WebRtcSettingsCard({required this.services});

  @override
  State<_WebRtcSettingsCard> createState() => _WebRtcSettingsCardState();
}

class _WebRtcSettingsCardState extends State<_WebRtcSettingsCard> {
  late final TextEditingController _stunController;

  AppServices get services => widget.services;

  @override
  void initState() {
    super.initState();
    _stunController = TextEditingController(text: services.settings.webrtcStunServer);
  }

  @override
  void dispose() {
    _stunController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = services.settings;
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'WEBRTC CLIENT',
                style: TextStyle(
                  color: Neon.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
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
                NeonDropdownItem(WebrtcIceTransportPolicy.all, 'All'),
                NeonDropdownItem(WebrtcIceTransportPolicy.relay, 'Relay'),
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
                NeonDropdownItem(WebrtcBundlePolicy.balanced, 'Balanced'),
                NeonDropdownItem(WebrtcBundlePolicy.maxCompat, 'Max compat'),
                NeonDropdownItem(WebrtcBundlePolicy.maxBundle, 'Max bundle'),
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
                NeonDropdownItem(WebrtcRtcpMuxPolicy.require, 'Require'),
                NeonDropdownItem(WebrtcRtcpMuxPolicy.negotiate, 'Negotiate'),
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
                  style: const TextStyle(color: Neon.ink, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'stun:stun.example.com:3478',
                    hintStyle:
                        const TextStyle(color: Neon.inkMuted, fontSize: 12),
                    isDense: true,
                    filled: true,
                    fillColor: Neon.bgC,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          const BorderSide(color: Neon.accent, width: 1.2),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String label;

  const _GroupLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 2),
      child: Text(
        label,
        style: const TextStyle(
          color: Neon.inkMuted,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 2,
        ),
      ),
    );
  }
}
