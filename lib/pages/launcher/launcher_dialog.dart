import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/game_art.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_chip.dart';
import 'printed_waste_modal.dart';

/// Resolved launch target returned by [LauncherDialog].
class LaunchPlan {
  final String appId;
  final String streamingBaseUrl;

  const LaunchPlan({required this.appId, required this.streamingBaseUrl});
}

/// Popup launcher: pick which store variant (Steam / Epic / ...) to launch.
/// Returns a [LaunchPlan] via `Navigator.pop`; PlayFlow then opens streaming.
class LauncherDialog extends StatefulWidget {
  final AppServices services;
  final CatalogGame game;

  const LauncherDialog({
    super.key,
    required this.services,
    required this.game,
  });

  @override
  State<LauncherDialog> createState() => _LauncherDialogState();
}

class _LauncherDialogState extends State<LauncherDialog> {
  bool _launching = false;
  String? _selectedVariantId;

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
    for (final v in variants) {
      if (v.id == launch) return v.id;
    }
    return variants.first.id;
  }

  static bool _isNumericId(String value) =>
      value.isNotEmpty && RegExp(r'^\d+$').hasMatch(value);

  String get _defaultStreamingBaseUrl =>
      'https://prod.cloudmatchbeta.nvidiagrid.net/';

  bool get _isFreeTier {
    final tier = widget.services.auth.getSession()?.user.membershipTier;
    return tier == null || tier.toUpperCase() == 'FREE';
  }

  Future<void> _launch() async {
    final appId = _selectedVariantId ?? widget.game.launchAppId;
    if (appId == null || appId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This game has no launchable app id.')),
      );
      return;
    }

    setState(() => _launching = true);

    var baseUrl = widget.services.settings.selectedRegionUrl ??
        _defaultStreamingBaseUrl;

    // Free tier: pick a community-queue server (printedwaste) first.
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
          if (!mounted) return;
          // Cancelling the server picker aborts the launch.
          if (chosen == null) {
            setState(() => _launching = false);
            return;
          }
          baseUrl = chosen;
        }
      } catch (e) {
        debugPrint('PrintedWaste unavailable, using default routing: $e');
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop(LaunchPlan(
      appId: appId,
      streamingBaseUrl: baseUrl,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final variants = _launchableVariants;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: 20),
              if (variants.isNotEmpty) ...[
                const Text(
                  'CHOOSE STORE',
                  style: TextStyle(
                    color: Neon.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final v in variants)
                      _StoreChip(
                        label: _storeLabel(v),
                        selected: v.id == _selectedVariantId,
                        onTap: () =>
                            setState(() => _selectedVariantId = v.id),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 26),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _launching ? null : () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: Neon.inkSoft,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: const Text('CANCEL'),
                  ),
                  const SizedBox(width: 10),
                  NeonButton(
                    label: _isFreeTier ? 'Select Server' : 'Launch',
                    icon: _isFreeTier ? Icons.dns : Icons.rocket_launch,
                    busy: _launching,
                    onPressed: _launching ? null : _launch,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: GameArt(
            imageUrl: widget.game.imageUrl,
            label: widget.game.title,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.game.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Neon.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (widget.game.publisherName != null) ...[
                const SizedBox(height: 2),
                Text(
                  widget.game.publisherName!,
                  style: const TextStyle(color: Neon.inkMuted, fontSize: 12),
                ),
              ],
              const SizedBox(height: 8),
              if (widget.game.minimumMembershipTierLabel != null)
                NeonChip(
                  label: widget.game.minimumMembershipTierLabel!,
                  tone: NeonChipTone.violet,
                ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, color: Neon.inkMuted, size: 20),
          onPressed: _launching ? null : () => Navigator.of(context).pop(),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          gradient: selected ? Neon.accentGradient : null,
          color: selected ? null : Neon.bgC,
          borderRadius: BorderRadius.circular(13),
          boxShadow: selected ? Neon.glowShadow(radius: 15, alpha: 0.35) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.storefront,
              size: 15,
              color: selected ? Neon.bgA : Neon.inkSoft,
            ),
            const SizedBox(width: 7),
            Text(
              label.toUpperCase(),
              style: TextStyle(
                color: selected ? Neon.bgA : Neon.ink,
                fontSize: 11.5,
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
