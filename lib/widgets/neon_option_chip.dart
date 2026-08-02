import 'package:flutter/material.dart';

import '../theme/neon.dart';
import 'neon_chip.dart';

enum OptionTier { free, priority, ultimate }

/// Selectable pill option with an optional membership-tier badge.
class NeonOptionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final OptionTier? tier;
  final VoidCallback? onTap;
  final bool enabled;

  const NeonOptionChip({
    super.key,
    required this.label,
    required this.selected,
    this.tier,
    this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final isPremium = tier != null && tier != OptionTier.free;
    final interactive = enabled && onTap != null;
    return Opacity(
      opacity: interactive ? 1 : 0.45,
      child: GestureDetector(
        onTap: interactive ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            gradient: selected && interactive ? Neon.accentGradient : null,
            color: selected && interactive ? null : Neon.bgC,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected && interactive
                  ? Neon.accent
                  : Neon.outline,
            ),
            boxShadow: selected && interactive
                ? Neon.glowShadow(radius: 14, alpha: 0.3)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!interactive && isPremium) ...[
                const Icon(Icons.lock, size: 12, color: Neon.inkMuted),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  color: selected && interactive ? Neon.bgA : Neon.ink,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
              if (isPremium) ...[
                const SizedBox(width: 6),
                NeonChip(
                  label: _tierLabel(tier!),
                  tone: _tierTone(tier!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _tierLabel(OptionTier t) => switch (t) {
        OptionTier.free => 'FREE',
        OptionTier.priority => 'PRIORITY',
        OptionTier.ultimate => 'ULTIMATE',
      };

  NeonChipTone _tierTone(OptionTier t) => switch (t) {
        OptionTier.free => NeonChipTone.neutral,
        OptionTier.priority => NeonChipTone.violet,
        OptionTier.ultimate => NeonChipTone.accent,
      };
}
