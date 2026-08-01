import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/neon.dart';
import 'neon_button.dart';
import 'neon_chip.dart';

/// Auto-advancing featured-game banner carousel. Uses a responsive banner
/// height (never a full-width 16:9 block) so it doesn't hog the viewport.
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
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final slides = widget.slides;
    if (slides.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Banner height: 16:9 ratio capped so it never dominates the screen.
        final height = (width * 9 / 16).clamp(260.0, 460.0);
        return Column(
          children: [
            SizedBox(
              height: height,
              child: PageView.builder(
                controller: _controller,
                itemCount: slides.length,
                onPageChanged: (i) {
                  setState(() => _index = i);
                  _startTimer();
                },
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _Slide(
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
            ),
            if (slides.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: _PagerDots(count: slides.length, index: _index),
              ),
          ],
        );
      },
    );
  }
}

/// Animated pager indicator: the active dot grows into a pill; solid colors
/// lerp smoothly so there's no teleporting.
class _PagerDots extends StatelessWidget {
  final int count;
  final int index;

  const _PagerDots({required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            width: i == index ? 24 : 6,
            height: 6,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: i == index ? Neon.accent : const Color(0x33FFFFFF),
              borderRadius: BorderRadius.circular(3),
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
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: Neon.softShadow(radius: 26),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _CoverImage(url: slide.imageUrl, label: slide.title),
              DecoratedBox(
                decoration: BoxDecoration(gradient: Neon.scrim),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (slide.chips != null && slide.chips!.isNotEmpty)
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: slide.chips!,
                            ),
                          const SizedBox(height: 8),
                          Text(
                            slide.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Neon.ink,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.3,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 12),
                              ],
                            ),
                          ),
                          if (slide.subtitle != null) ...[
                            const SizedBox(height: 2),
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
                          ],
                          const SizedBox(height: 12),
                          if (onPlay != null)
                            NeonButton(label: 'Play', onPressed: onPlay),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoverImage extends StatelessWidget {
  final String? url;
  final String label;

  const _CoverImage({required this.url, required this.label});

  @override
  Widget build(BuildContext context) {
    final value = url;
    if (value == null || value.isEmpty) return _placeholder();
    return Image.network(
      value,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      cacheWidth: 1600,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return _placeholder();
      },
      errorBuilder: (context, error, stack) => _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1A2E), Color(0xFF0E0E18)],
        ),
      ),
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Neon.inkMuted, fontSize: 14),
        ),
      ),
    );
  }
}
