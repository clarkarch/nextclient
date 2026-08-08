import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../state/title_bar_controller.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../../widgets/neon_snackbar.dart';
import '../../widgets/neon_switch.dart';
import '../../widgets/section_header.dart';
import '../log_viewer_page.dart';
import 'account_page.dart';
import 'debug_settings_page.dart';
import 'language_page.dart';
import 'performance_settings_page.dart';
import 'region_page.dart';
import 'stream_quality_page.dart';
import 'ui_settings_page.dart';
import 'webrtc_settings_page.dart';

/// Settings hub: server-side options sent to NVIDIA on launch (plus account
/// and Logs, which are always reachable), and client-side categories (WebRTC,
/// UI, Performance) revealed by the Advanced Settings toggle. Server settings
/// are always visible; the toggle only exposes the client categories below.
class SettingsPage extends StatelessWidget {
  final AppServices services;
  final VoidCallback onSignOut;

  const SettingsPage({
    super.key,
    required this.services,
    required this.onSignOut,
  });

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
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
              SectionHeader(
                title: 'Settings',
                actionLabel: 'Reset',
                onAction: () => _confirmReset(context),
              ),
              _advancedToggleCard(),
              const SizedBox(height: 14),
              // Main settings are always visible; the Advanced Settings section
              // the toggle reveals holds the lower-level categories.
              _mainSettingsCard(context),
              if (advanced) ...[
                const SizedBox(height: 20),
                const _GroupLabel('ADVANCED SETTINGS'),
                const SizedBox(height: 6),
                _advancedSettingsCard(context),
              ],
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
        subtitle: 'Show advanced categories',
        trailing: NeonSwitch(
          value: services.settings.advancedMode,
          onChanged: (v) => services.settings.advancedMode = v,
        ),
      ),
    );
  }

  /// Always-visible settings: the stream server options, account, and the
  /// UI category (kept on the main view since it's a day-to-day preference).
  Widget _mainSettingsCard(BuildContext context) {
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          NeonSettingTile(
            icon: Icons.high_quality,
            title: 'Stream',
            subtitle: _qualitySummary(),
            onTap: () => _open(context, StreamQualityPage(services: services)),
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
            icon: Icons.palette_outlined,
            title: 'UI',
            subtitle: _uiSummary(),
            onTap: () => _open(context, UiSettingsPage(services: services)),
            trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Neon.bgB,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Reset all settings?',
          style: TextStyle(color: Neon.ink, fontSize: 16),
        ),
        content: const Text(
          'This restores every setting to its default value. Your account '
          'stays signed in. This cannot be undone.',
          style: TextStyle(color: Neon.inkSoft, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Neon.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset', style: TextStyle(color: Neon.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await services.settings.resetToDefaults();
    // Re-sync side effects that are applied outside the settings object:
    // verbose logging gates all sinks, and the title bar style touches the
    // native window.
    services.logSink.setEnabledForAll(services.settings.logsEnabled);
    await TitleBarController.apply(services.settings);
    services.logSink.log(
      LogLevel.info,
      'settings',
      'Settings reset to defaults',
    );
    if (context.mounted) {
      showNeonSnackbar(context, 'Settings reset to defaults', copyable: false);
    }
  }

  /// Lower-level categories only relevant to tinkerers, hidden behind the
  /// Advanced Settings toggle (client transport, logging, Performance,
  /// Debug). Experimental options now live inside their own pages, marked with
  /// an EXPERIMENTAL tag instead of a separate category.
  Widget _advancedSettingsCard(BuildContext context) {
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          NeonSettingTile(
            icon: Icons.computer,
            title: 'Client',
            subtitle: 'Transport · renderer · input · cursor overlay',
            onTap: () => _open(context, WebRtcSettingsPage(services: services)),
            trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
          ),
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.terminal,
            title: 'Logs',
            subtitle: 'Debug log viewer',
            onTap: () => _open(
              context,
              LogViewerPage(
                logSink: services.logSink,
                logFilePath: services.logFilePath,
              ),
            ),
            trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
          ),
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.speed,
            title: 'Performance',
            subtitle: _perfSummary(),
            onTap: () =>
                _open(context, PerformanceSettingsPage(services: services)),
            trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
          ),
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.bug_report_outlined,
            title: 'Debug',
            subtitle: 'Cursor overlay diagnostics',
            onTap: () => _open(context, DebugSettingsPage(services: services)),
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

  String _uiSummary() {
    return 'Background: ${services.settings.backgroundStyle.label}';
  }

  String _perfSummary() {
    return 'Verbose logs: ${services.settings.logsEnabled ? 'on' : 'off'}';
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
