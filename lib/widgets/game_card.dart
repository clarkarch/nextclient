import 'package:flutter/material.dart';

import '../theme/neon.dart';
import 'game_art.dart';
import 'neon_chip.dart';

/// 16:9 game poster card with hover lift + glow. Tapping always routes to the
/// game details screen ([onTap]); launching happens there via Play.
class GameCard extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<String> genres;
  final String? imageUrl;
  final bool inLibrary;
  final VoidCallback? onTap;
  final Widget? cornerBadge;

  const GameCard({
    super.key,
    required this.title,
    this.subtitle,
    this.genres = const [],
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
  bool _pressed = false;

  String get _heroTag =>
      widget.imageUrl != null && widget.imageUrl!.isNotEmpty
          ? 'game-art:${widget.imageUrl}'
          : 'game-art:${widget.title}';

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : (_hover ? 1.02 : 1),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(0, _hover ? -6 : 0, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: Neon.cardShadow(hover: _hover),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Art with fancy border + sheen + hero
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _hover
                          ? Neon.accent.withValues(alpha: 0.55)
                          : Neon.outline.withValues(alpha: 0.9),
                      width: _hover ? 1.2 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(15),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Hero(
                            tag: _heroTag,
                            child: GameArt(
                              imageUrl: widget.imageUrl,
                              label: widget.title,
                              borderRadius: BorderRadius.zero,
                            ),
                          ),
                          // Top sheen — subtle glass highlight
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: Neon.cardSheen,
                              ),
                            ),
                          ),
                          // Hover shimmer sweep — the controller only runs
                          // while hovered so idle cards never tick.
                          AnimatedOpacity(
                            opacity: _hover ? 1 : 0,
                            duration: const Duration(milliseconds: 280),
                            child: _SheenSweep(active: _hover),
                          ),
                          // Bottom scrim for badge legibility
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0x00000000),
                                    Color(0x1A08080D),
                                  ],
                                  stops: [0.6, 1],
                                ),
                              ),
                            ),
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
                            Positioned(
                                top: 8, right: 8, child: widget.cornerBadge!),
                          // Hover play hint — fades in
                          AnimatedOpacity(
                            opacity: _hover ? 1 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: Center(
                              child: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.52),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color:
                                          Colors.white.withValues(alpha: 0.18)),
                                  boxShadow: Neon.glowShadow(
                                      radius: 14, alpha: 0.32),
                                ),
                                child: const Icon(Icons.play_arrow,
                                    color: Colors.white, size: 22),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 9, left: 2, right: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 160),
                        style: TextStyle(
                          color: _hover ? Colors.white : Neon.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.15,
                        ),
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (widget.subtitle != null)
                        Text(
                          widget.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _hover ? Neon.inkSoft : Neon.inkMuted,
                            fontSize: 11.5,
                            height: 1.2,
                          ),
                        ),
                      if (widget.genres.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          widget.genres.take(2).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _hover
                                ? Neon.inkSoft.withValues(alpha: 0.9)
                                : Neon.inkMuted.withValues(alpha: 0.85),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheenSweep extends StatefulWidget {
  final bool active;

  const _SheenSweep({this.active = false});

  @override
  State<_SheenSweep> createState() => _SheenSweepState();
}

class _SheenSweepState extends State<_SheenSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didUpdateWidget(covariant _SheenSweep oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Run only while hovered: an always-on controller in every grid card
    // costs a rebuild + repaint mark per card per frame, forever.
    if (widget.active != oldWidget.active) {
      if (widget.active) {
        _c.repeat();
      } else {
        _c.stop();
        _c.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1.2 + t * 2.4, -0.4),
              end: Alignment(0.2 + t * 2.4, 1.0),
              colors: [
                const Color(0x00000000),
                Colors.white.withValues(alpha: 0.10),
                const Color(0x00000000),
              ],
              stops: const [0.44, 0.5, 0.56],
            ),
          ),
        );
      },
    );
  }
}
