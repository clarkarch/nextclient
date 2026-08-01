import 'package:flutter/material.dart';

import '../theme/neon.dart';
import 'game_art.dart';
import 'neon_chip.dart';

/// 16:9 game poster card with hover lift + glow. Tapping always routes to the
/// game details screen ([onTap]); launching happens there via Play.
class GameCard extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final bool inLibrary;
  final VoidCallback? onTap;
  final Widget? cornerBadge;

  const GameCard({
    super.key,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.inLibrary = false,
    this.onTap,
    this.cornerBadge,
  });

  @override
  State<GameCard> createState() => _GameCardState();
}

class _GameCardState extends State<GameCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          transform: Matrix4.translationValues(0, _hover ? -4 : 0, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: _hover
                ? Neon.glowShadow(radius: 26, alpha: 0.4)
                : Neon.softShadow(radius: 18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  GameArt(
                    imageUrl: widget.imageUrl,
                    label: widget.title,
                    borderRadius: const BorderRadius.all(Radius.circular(16)),
                  ),
                  if (widget.inLibrary)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: NeonChip(
                        label: 'Owned',
                        tone: NeonChipTone.success,
                        icon: Icons.check,
                      ),
                    ),
                  if (widget.cornerBadge != null)
                    Positioned(top: 8, right: 8, child: widget.cornerBadge!),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Neon.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (widget.subtitle != null)
                      Text(
                        widget.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Neon.inkMuted,
                          fontSize: 11.5,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
