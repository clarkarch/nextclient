import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import 'game_card.dart';
import 'neon_chip.dart';

/// Convenience wrapper building a [GameCard] from a [CatalogGame] domain
/// object. Keeps grid builders across Home / Library / Recently Played free
/// of card construction details.
class CatalogGameCard extends StatelessWidget {
  final CatalogGame game;
  final VoidCallback? onTap;
  final bool showOwnedBadge;

  const CatalogGameCard({
    super.key,
    required this.game,
    this.onTap,
    this.showOwnedBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    return GameCard(
      title: game.title,
      subtitle: game.publisherName ?? game.shortName,
      genres: game.genres,
      imageUrl: game.imageUrl,
      inLibrary: showOwnedBadge && game.isInLibrary,
      onTap: onTap,
      cornerBadge: _tierBadge(),
    );
  }

  Widget? _tierBadge() {
    final tier = game.minimumMembershipTierLabel;
    if (tier == null) return null;
    final tone = switch (tier.toUpperCase()) {
      'FREE' => NeonChipTone.neutral,
      'PRIORITY' => NeonChipTone.violet,
      'ULTIMATE' => NeonChipTone.accent,
      _ => NeonChipTone.neutral,
    };
    return NeonChip(label: tier, tone: tone);
  }
}
