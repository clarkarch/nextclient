import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/neon.dart';
import 'game_art.dart';
import 'neon_button.dart';
import 'neon_chip.dart';

/// Auto-advancing 16:9 featured-game carousel with title overlay + Play.
class FeaturedCarousel extends StatefulWidget {
  final List<FeaturedSlide> slides;
  final void Function(FeaturedSlide slide)? onPlay;
  final void Function(FeaturedSlide slide)? onSelect;
  final Duration autoAdvance;

  const FeaturedCarousel({
    super.key,
    required this.slides,
    this.onPlay,
    this.onSelect,
    this.autoAdvance = const Duration(seconds: 6),
  });

  @override
  State<FeaturedCarousel> createState() => _FeaturedCarouselState();
}

class FeaturedSlide {
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final List<NeonChip>? chips;
  final Object? data;

  const FeaturedSlide({
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.chips,
    this.data,
  });
}

class _FeaturedCarouselState extends State<FeaturedCarousel> {
  final PageController _controller = PageController(viewportFraction: 0.92);
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    if (widget.slides.length < 2) return;
    _timer = Timer.periodic(widget.autoAdvance, (_) {
      if (!mounted || !_controller.hasClients) return;
      final next = (_index + 1) % widget.slides.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final slides = widget.slides;
    if (slides.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: PageView.builder(
            controller: _controller,
            itemCount: slides.length,
            onPageChanged: (i) {
              setState(() => _index = i);
              _startTimer();
            },
            itemBuilder: (context, i) => _Slide(
              slide: slides[i],
              onPlay: widget.onPlay == null
                  ? null
                  : () => widget.onPlay!(slides[i]),
              onSelect: widget.onSelect == null
                  ? null
                  : () => widget.onSelect!(slides[i]),
            ),
          ),
        ),
        if (slides.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < slides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: i == _index ? 18 : 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      gradient: i == _index ? Neon.accentGradient : null,
                      color: i == _index ? null : const Color(0x44FFFFFF),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Slide extends StatelessWidget {
  final FeaturedSlide slide;
  final VoidCallback? onPlay;
  final VoidCallback? onSelect;

  const _Slide({required this.slide, this.onPlay, this.onSelect});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onSelect,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GameArt(
            imageUrl: slide.imageUrl,
            label: slide.title,
            borderRadius: const BorderRadius.all(Radius.circular(20)),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: Neon.scrim,
              borderRadius: const BorderRadius.all(Radius.circular(20)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (slide.chips != null && slide.chips!.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: slide.chips!,
                    ),
                  const SizedBox(height: 10),
                  Text(
                    slide.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Neon.ink,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.3,
                      shadows: [
                        Shadow(color: Colors.black, blurRadius: 12),
                      ],
                    ),
                  ),
                  if (slide.subtitle != null)
                    Text(
                      slide.subtitle!,
                      style: const TextStyle(
                        color: Neon.inkSoft,
                        fontSize: 13,
                        shadows: [
                          Shadow(color: Colors.black, blurRadius: 8),
                        ],
                      ),
                    ),
                  const SizedBox(height: 14),
                  if (onPlay != null) NeonButton(label: 'Play', onPressed: onPlay),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
