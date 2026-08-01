import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../state/user_settings.dart';
import '../../theme/neon.dart';
import '../../widgets/game_art.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';
import '../settings/stream_quality_page.dart';
import '../stream/stream_page.dart';
import 'printed_waste_modal.dart';

/// Pre-launch options: region + stream quality summary, then Launch →
/// (printedwaste picker for free tier) → streaming.
class LauncherPage extends StatefulWidget {
  final AppServices services;
  final CatalogGame game;

  const LauncherPage({
    super.key,
    required this.services,
    required this.game,
  });

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> {
  List<StreamRegion>? _regions;
  bool _loadingRegions = false;
  String? _regionsError;
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    _loadRegions();
  }

  Future<void> _loadRegions() async {
    setState(() {
      _loadingRegions = true;
      _regionsError = null;
    });
    try {
      final session = await widget.services.auth.ensureValidSession();
      final token = session?.tokens.idToken ?? session?.tokens.accessToken;
      final result = await widget.services.subscription.fetchDynamicRegions(
        token: token,
        streamingBaseUrl: _defaultStreamingBaseUrl,
      );
      if (!mounted) return;
      setState(() {
        _regions = result.regions;
        _loadingRegions = false;
        if (_regions != null && _regions!.isNotEmpty) {
          final saved = widget.services.settings.selectedRegionUrl;
          final match =
              _regions!.any((r) => r.url == saved);
          if (widget.services.settings.selectedRegionUrl == null || !match) {
            widget.services.settings.selectedRegionUrl = _regions!.first.url;
          }
        }
      });
    } catch (e) {
      debugPrint('[launcher] regions load failed: $e');
      if (!mounted) return;
      setState(() {
        _loadingRegions = false;
        _regionsError = 'Could not load regions: $e';
      });
    }
  }

  String get _defaultStreamingBaseUrl =>
      'https://prod.cloudmatchbeta.nvidiagrid.net/';

  String get _qualitySummary {
    final s = widget.services.settings;
    return '${s.resolution} · ${s.fps}fps · ${s.maxBitrateMbps} Mbps · '
        '${s.codec.name.toUpperCase()}'
        '${s.enableL4S ? ' · L4S' : ''}'
        '${s.enableCloudGsync ? ' · G-SYNC' : ''}';
  }

  bool get _isFreeTier {
    final tier = widget.services.auth.getSession()?.user.membershipTier;
    return tier == null || tier.toUpperCase() == 'FREE';
  }

  Future<void> _launch() async {
    final appId = widget.game.launchAppId;
    if (appId == null || appId.isEmpty) {
      _toast('This game has no launchable app id.');
      return;
    }
    final regionUrl = widget.services.settings.selectedRegionUrl ??
        _defaultStreamingBaseUrl;

    setState(() => _launching = true);

    String? streamingBaseUrl = regionUrl;

    // Free tier: let the user pick a community-queue server (printedwaste).
    if (_isFreeTier) {
      try {
        final queue =
            await widget.services.printedWaste.fetchPrintedWasteQueue();
        var mapping = const PrintedWasteServerMapping(servers: {});
        try {
          mapping = await widget.services.printedWaste
              .fetchPrintedWasteServerMapping();
        } catch (_) {}
        if (hasAnyEligiblePrintedWasteZone(queue, mapping)) {
          if (!mounted) return;
          final chosen = await showDialog<String>(
            context: context,
            builder: (_) => PrintedWasteModal(
              services: widget.services,
              gameTitle: widget.game.title,
              initialQueue: queue,
            ),
          );
          if (chosen != null) {
            streamingBaseUrl = chosen;
          }
        }
      } catch (e) {
        debugPrint('PrintedWaste unavailable, using default routing: $e');
      }
    }

    if (!mounted) return;
    setState(() => _launching = false);

    // Open the streaming surface (it listens to the session controller) then
    // drive the lifecycle.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => StreamPage(
          services: widget.services,
          game: widget.game,
          request: SessionCreateRequest(
            token: null,
            streamingBaseUrl: streamingBaseUrl,
            appId: appId,
            internalTitle: widget.game.title,
            zone: 'prod',
            settings: widget.services.settings.buildStreamSettings(),
          ),
        ),
      ),
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.services.settings;
    return NeonPageScaffold(
      title: 'Launch',
      showBack: true,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _GameHeader(game: widget.game),
              const SizedBox(height: 24),
              NeonCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    NeonSettingTile(
                      icon: Icons.public,
                      title: 'Region',
                      subtitle: _regionSubtitle(),
                      onTap: null,
                      trailing: _regionDropdown(settings),
                    ),
                    const Divider(height: 1),
                    NeonSettingTile(
                      icon: Icons.high_quality,
                      title: 'Stream Quality',
                      subtitle: _qualitySummary,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => StreamQualityPage(
                              services: widget.services,
                            ),
                          ),
                        );
                      },
                      trailing: const Icon(
                        Icons.chevron_right,
                        color: Neon.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Center(
                child: NeonButton(
                  label: 'Launch',
                  icon: Icons.rocket_launch,
                  wide: true,
                  busy: _launching,
                  onPressed: _launching ? null : _launch,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _regionDropdown(UserSettings settings) {
    if (_loadingRegions) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Neon.accent,
        ),
      );
    }
    if (_regionsError != null) {
      return TextButton(onPressed: _loadRegions, child: const Text('Retry'));
    }
    final regions = _regions ?? const <StreamRegion>[];
    if (regions.isEmpty) {
      return const Text(
        'No regions',
        style: TextStyle(color: Neon.inkMuted, fontSize: 12),
      );
    }
    return DropdownButton<String>(
      value: settings.selectedRegionUrl,
      dropdownColor: Neon.bgC,
      underline: const SizedBox.shrink(),
      icon: const Icon(Icons.expand_more, color: Neon.accent, size: 18),
      style: const TextStyle(color: Neon.ink, fontSize: 13),
      items: regions
          .map((r) => DropdownMenuItem(
                value: r.url,
                child: Text(
                  r.name,
                  style: const TextStyle(
                    color: Neon.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ))
          .toList(),
      onChanged: (v) {
        if (v != null) settings.selectedRegionUrl = v;
      },
    );
  }

  String _regionSubtitle() {
    final url = widget.services.settings.selectedRegionUrl;
    if (url == null) return 'Loading regions…';
    final region = _regions?.where((r) => r.url == url).firstOrNull;
    return region?.url ?? url;
  }
}

class _GameHeader extends StatelessWidget {
  final CatalogGame game;

  const _GameHeader({required this.game});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: GameArt(
            imageUrl: game.imageUrl,
            label: game.title,
            borderRadius: const BorderRadius.all(Radius.circular(16)),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                game.title,
                style: const TextStyle(
                  color: Neon.ink,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (game.publisherName != null) ...[
                const SizedBox(height: 4),
                Text(
                  game.publisherName!,
                  style: const TextStyle(color: Neon.inkMuted, fontSize: 13),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (game.launchAppId != null)
                    NeonChip(label: 'appId ${game.launchAppId}'),
                  if (game.minimumMembershipTierLabel != null)
                    NeonChip(
                      label: game.minimumMembershipTierLabel!,
                      tone: NeonChipTone.violet,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
