import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/game_art.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../stream/stream_page.dart';
import 'printed_waste_modal.dart';

/// Launcher options: pick which store variant (Steam / Epic / ...) to launch,
/// then Launch → (printedwaste picker for free tier) → queue → streaming.
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
  bool _launching = false;
  String? _selectedVariantId;

  /// Variants that can actually be launched (numeric app ids).
  List<AppVariant> get _launchableVariants =>
      widget.game.variants.where((v) => _isNumericId(v.id)).toList();

  @override
  void initState() {
    super.initState();
    _selectedVariantId = _defaultVariantId();
  }

  String? _defaultVariantId() {
    final launch = widget.game.launchAppId;
    final variants = _launchableVariants;
    if (variants.isEmpty) return launch;
    // Prefer the variant that matches the resolved launch app id.
    for (final v in variants) {
      if (v.id == launch) return v.id;
    }
    return variants.first.id;
  }

  String get _defaultStreamingBaseUrl =>
      'https://prod.cloudmatchbeta.nvidiagrid.net/';

  bool get _isFreeTier {
    final tier = widget.services.auth.getSession()?.user.membershipTier;
    return tier == null || tier.toUpperCase() == 'FREE';
  }

  static bool _isNumericId(String value) =>
      value.isNotEmpty && RegExp(r'^\d+$').hasMatch(value);

  Future<void> _launch() async {
    final appId = _selectedVariantId ?? widget.game.launchAppId;
    if (appId == null || appId.isEmpty) {
      _toast('This game has no launchable app id.');
      return;
    }
    final streamingBaseUrl =
        widget.services.settings.selectedRegionUrl ?? _defaultStreamingBaseUrl;

    setState(() => _launching = true);

    var effectiveBaseUrl = streamingBaseUrl;

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
            effectiveBaseUrl = chosen;
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
            streamingBaseUrl: effectiveBaseUrl,
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
              if (_launchableVariants.isNotEmpty) ...[
                const SizedBox(height: 28),
                _storeSection(),
              ],
              const SizedBox(height: 32),
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

  Widget _storeSection() {
    final variants = _launchableVariants;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'CHOOSE STORE',
          style: TextStyle(
            color: Neon.accent,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final v in variants)
              _StoreChip(
                label: _storeLabel(v),
                selected: v.id == _selectedVariantId,
                onTap: () => setState(() => _selectedVariantId = v.id),
              ),
          ],
        ),
      ],
    );
  }

  String _storeLabel(AppVariant v) {
    final store = v.appStore ?? v.shortName;
    if (store == null || store.isEmpty) return 'Variant ${v.id}';
    const names = {
      'Steam': 'Steam',
      'Epic Games Store': 'Epic Games',
      'GOG': 'GOG',
      'Ubisoft Connect': 'Ubisoft',
      'Ubisoft': 'Ubisoft',
      'Xbox Game Pass': 'Xbox Game Pass',
      'Microsoft Store': 'Microsoft Store',
      'EA App': 'EA App',
      'Battle.net': 'Battle.net',
    };
    return names[store] ?? store;
  }
}

class _StoreChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _StoreChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          gradient: selected ? Neon.accentGradient : null,
          color: selected ? null : Neon.bgC,
          borderRadius: BorderRadius.circular(14),
          boxShadow: selected ? Neon.glowShadow(radius: 16, alpha: 0.35) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.storefront,
              size: 16,
              color: selected ? Neon.bgA : Neon.inkSoft,
            ),
            const SizedBox(width: 8),
            Text(
              label.toUpperCase(),
              style: TextStyle(
                color: selected ? Neon.bgA : Neon.ink,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
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
