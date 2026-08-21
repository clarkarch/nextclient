import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../state/title_bar_controller.dart';
import '../../theme/neon.dart';
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
class SettingsPage extends StatefulWidget {
  final AppServices services;
  final VoidCallback onSignOut;

  const SettingsPage({
    super.key,
    required this.services,
    required this.onSignOut,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  AppServices get services => widget.services;
  VoidCallback get onSignOut => widget.onSignOut;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
              _FadeIn(
                delay: const Duration(milliseconds: 40),
                child: SectionHeader(
                  title: 'Settings',
                  actionLabel: 'Reset',
                  onAction: () => _confirmReset(context),
                ),
              ),
              _FadeIn(
                delay: const Duration(milliseconds: 80),
                child: _searchField(),
              ),
              const SizedBox(height: 14),
              if (_query.trim().isNotEmpty) ...[
                _SettingsSearchResults(
                  page: this,
                  query: _query,
                  advancedUnlocked: advanced,
                ),
              ] else ...[
              _FadeIn(
                delay: const Duration(milliseconds: 110),
                child: _advancedToggleCard(),
              ),
              const SizedBox(height: 14),
              // Main settings are always visible; the Advanced Settings section
              // the toggle reveals holds the lower-level categories.
              _FadeIn(
                delay: const Duration(milliseconds: 170),
                child: _mainSettingsCard(context),
              ),
              if (advanced) ...[
                const SizedBox(height: 22),
                const _FadeIn(
                  delay: Duration(milliseconds: 220),
                  child: _GroupLabel('ADVANCED SETTINGS'),
                ),
                const SizedBox(height: 8),
                _FadeIn(
                  delay: const Duration(milliseconds: 260),
                  child: _advancedSettingsCard(context),
                ),
              ],
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _searchField() {
    return _FancyCard(
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _query = v),
        style: const TextStyle(color: Neon.ink, fontSize: 13.5),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search settings…',
          hintStyle: const TextStyle(color: Neon.inkMuted, fontSize: 13.5),
          prefixIcon: const Icon(Icons.search, size: 20, color: Neon.inkMuted),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18, color: Neon.inkMuted),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }

  Widget _advancedToggleCard() {
    return _FancyCard(
      glow: services.settings.advancedMode,
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
    return _FancyCard(
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
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Neon.bgB,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Neon.outline),
            boxShadow: Neon.glowShadow(radius: 22, alpha: 0.22),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Neon.error.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Neon.error.withValues(alpha: 0.35)),
                    ),
                    child:
                        const Icon(Icons.warning_amber, color: Neon.error, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Reset all settings?',
                    style: TextStyle(
                        color: Neon.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'This restores every setting to its default value. Your account '
                'stays signed in. This cannot be undone.',
                style: TextStyle(color: Neon.inkSoft, fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('Cancel',
                        style: TextStyle(color: Neon.inkSoft)),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      backgroundColor: Neon.error.withValues(alpha: 0.12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child:
                        const Text('Reset', style: TextStyle(color: Neon.error)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await services.settings.resetToDefaults();
    // Re-sync side effects that are applied outside the settings object:
    // verbose logging gates all sinks, and the title bar style touches the
    // native window.
    services.logSink.setEnabledForAll(services.settings.effectiveLogsEnabled);
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
    return _FancyCard(
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
            icon: Icons.bolt,
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
    final s = services.settings;
    return 'Background: ${s.backgroundStyle.label} · '
        'Scale: ${(s.uiScale * 100).round()}%';
  }

  String _perfSummary() {
    final s = services.settings;
    if (s.maxPerformanceMode) return 'Max performance · ENGAGED';
    return 'Verbose logs: ${s.logsEnabled ? 'on' : 'off'}';
  }
}

class _FancyCard extends StatelessWidget {
  final Widget child;
  final bool glow;
  const _FancyCard({required this.child, this.glow = false});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Neon.bgC.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(16),
        boxShadow: glow
            ? Neon.glowShadow(radius: 18, alpha: 0.24)
            : Neon.softShadow(radius: 18),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: child,
      ),
    );
  }
}

class _FadeIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  const _FadeIn({required this.child, this.delay = Duration.zero});
  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  late final Animation<double> _opacity =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.05),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
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


/// One searchable destination in settings.
class _SearchEntry {
  final String title;
  final String subtitle;
  final IconData icon;

  /// Extra match terms beyond [title]/[subtitle].
  final List<String> keywords;

  /// Only reachable when Advanced Settings is on.
  final bool advanced;

  final Widget Function(_SettingsPageState page) buildPage;

  const _SearchEntry({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.keywords = const [],
    this.advanced = false,
    required this.buildPage,
  });

  bool matches(String rawQuery) {
    final q = rawQuery.trim().toLowerCase();
    if (q.isEmpty) return false;
    final haystack = [title, subtitle, ...keywords].join(' ').toLowerCase();
    // Every whitespace-separated term must appear somewhere.
    return q.split(RegExp(r'\s+')).every(haystack.contains);
  }
}

/// The full settings index. Advanced-gated entries only surface once the
/// user has enabled Advanced Settings.
final List<_SearchEntry> _settingsSearchIndex = [
  _SearchEntry(
    title: 'Stream',
    subtitle: 'Resolution · FPS · bitrate · codec',
    icon: Icons.high_quality,
    keywords: [
      'resolution', 'fps', 'framerate', 'bitrate', 'bandwidth', 'codec',
      'h264', 'hevc', 'av1', 'hdr', 'color quality', '10bit', '422', '444',
      'quality', 'streaming',
    ],
    buildPage: (page) => StreamQualityPage(services: page.services),
  ),
  _SearchEntry(
    title: 'Region',
    subtitle: 'Streaming region',
    icon: Icons.public,
    keywords: ['server', 'location', 'ping', 'geo', 'datacenter'],
    buildPage: (page) => RegionPage(services: page.services),
  ),
  _SearchEntry(
    title: 'Language & Input',
    subtitle: 'Game language · keyboard layout',
    icon: Icons.language,
    keywords: ['language', 'locale', 'keyboard layout', 'input language'],
    buildPage: (page) => LanguagePage(services: page.services),
  ),
  _SearchEntry(
    title: 'Account',
    subtitle: 'Profile · sign out',
    icon: Icons.person_outline,
    keywords: ['profile', 'sign out', 'logout', 'login', 'user'],
    buildPage: (page) =>
        AccountPage(services: page.services, onSignOut: page.onSignOut),
  ),
  _SearchEntry(
    title: 'UI',
    subtitle: 'Background · scale · window',
    icon: Icons.palette_outlined,
    keywords: [
      'background', 'theme', 'glow', 'ui scale', 'text size', 'title bar',
      'frameless', 'window', 'appearance',
    ],
    buildPage: (page) => UiSettingsPage(services: page.services),
  ),
  _SearchEntry(
    title: 'Client',
    subtitle: 'Transport · renderer · input · shaders',
    icon: Icons.computer,
    advanced: true,
    keywords: [
      'transport', 'webrtc', 'libwebrtc', 'renderer', 'gpu shader', 'yuv',
      'ice', 'stun', 'turn', 'relay', 'bundle', 'rtcp mux', 'dscp', 'qos',
      'nack', 'fec', 'packet loss', 'ipv6', 'candidates', 'l4s', 'gsync',
      'vrr', 'reflex', 'mouse sensitivity', 'mouse acceleration',
      'mouse sampling', 'high-precision', 'cursor overlay', 'touch mode',
      'video shaders', 'sharpen', 'cas', 'saturation', 'contrast',
      'brightness', 'vibrance', 'film grain', 'shaders',
    ],
    buildPage: (page) => WebRtcSettingsPage(services: page.services),
  ),
  _SearchEntry(
    title: 'Performance',
    subtitle: 'Max performance · decoder · logs',
    icon: Icons.bolt,
    advanced: true,
    keywords: [
      'max performance', 'decoder', 'hardware acceleration', 'hw accel',
      'nvdec', 'vaapi', 'verbose logs', 'frame pacing',
    ],
    buildPage: (page) => PerformanceSettingsPage(services: page.services),
  ),
  _SearchEntry(
    title: 'Logs',
    subtitle: 'Debug log viewer',
    icon: Icons.terminal,
    advanced: true,
    keywords: ['log viewer', 'debug logs', 'diagnostics', 'export logs'],
    buildPage: (page) => LogViewerPage(
          logSink: page.services.logSink,
          logFilePath: page.services.logFilePath,
        ),
  ),
  _SearchEntry(
    title: 'Debug',
    subtitle: 'Cursor overlay diagnostics',
    icon: Icons.bug_report_outlined,
    advanced: true,
    keywords: ['cursor box', 'overlay diagnostics', 'debug'],
    buildPage: (page) => DebugSettingsPage(services: page.services),
  ),
];

/// Filtered results for the settings search field.
class _SettingsSearchResults extends StatelessWidget {
  final _SettingsPageState page;
  final String query;
  final bool advancedUnlocked;

  const _SettingsSearchResults({
    required this.page,
    required this.query,
    required this.advancedUnlocked,
  });

  @override
  Widget build(BuildContext context) {
    final hits = _settingsSearchIndex
        .where((e) => e.matches(query) && (!e.advanced || advancedUnlocked))
        .toList();

    if (hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Center(
          child: Text(
            'No settings match "$query"',
            style: const TextStyle(color: Neon.inkMuted, fontSize: 13),
          ),
        ),
      );
    }

    return _FancyCard(
      child: Column(
        children: [
          for (var i = 0; i < hits.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            NeonSettingTile(
              icon: hits[i].icon,
              title: hits[i].title,
              subtitle: hits[i].subtitle,
              onTap: () => page._open(context, hits[i].buildPage(page)),
              trailing:
                  const Icon(Icons.chevron_right, color: Neon.inkMuted),
            ),
          ],
        ],
      ),
    );
  }
}
