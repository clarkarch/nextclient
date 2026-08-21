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
  final PageController _controller = PageController(viewportFraction: 0.88);
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
      _animateTo(next);
    });
  }

  void _goToPage(int index) {
    if (index == _index) {
      _startTimer();
      return;
    }
    _timer?.cancel();
    _animateTo(index);
  }

  void _animateTo(int index) {
    if (!mounted || !_controller.hasClients) return;
    _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 720),
      curve: Curves.easeInOutCubicEmphasized,
    );
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
        final height = (width * 9 / 16).clamp(250.0, 420.0);
        return Column(
          children: [
            SizedBox(
              height: height,
              child: PageView.builder(
                controller: _controller,
                padEnds: false,
                clipBehavior: Clip.none,
                itemCount: slides.length,
                onPageChanged: (i) {
                  setState(() => _index = i);
                  _startTimer();
                },
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: _ParallaxSlide(
                    controller: _controller,
                    index: i,
                    child: _Slide(
                      slide: slides[i],
                      isActive: i == _index,
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
            ),
            if (slides.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _PagerDots(
                  count: slides.length,
                  index: _index,
                  onTap: _goToPage,
                  autoAdvance: widget.autoAdvance,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ParallaxSlide extends StatelessWidget {
  final PageController controller;
  final int index;
  final Widget child;

  const _ParallaxSlide(
      {required this.controller, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    // The slide subtree is built ONCE and passed as [AnimatedBuilder.child] —
    // only the lightweight transform wrappers rebuild during a swipe.
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        double delta = 0;
        if (controller.hasClients && controller.position.hasContentDimensions) {
          final page = controller.page ?? controller.initialPage.toDouble();
          delta = (page - index).clamp(-1.0, 1.0).toDouble();
        }
        final absDelta = delta.abs();
        final scale = 1 - absDelta * 0.05;
        final opacity = (1 - absDelta * 0.12).clamp(0.78, 1.0);
        return Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                boxShadow: Neon.softShadow(radius: 18),
              ),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// Animated pager indicator: the active dot grows into a pill; solid colors
/// lerp smoothly so there's no teleporting. Includes a subtle auto-advance
/// progress shimmer on the active pill.
class _PagerDots extends StatelessWidget {
  final int count;
  final int index;
  final ValueChanged<int>? onTap;
  final Duration autoAdvance;

  const _PagerDots(
      {required this.count,
      required this.index,
      this.onTap,
      this.autoAdvance = const Duration(seconds: 6)});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          GestureDetector(
            onTap: onTap == null ? null : () => onTap!(i),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                width: i == index ? 22 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: i == index ? Neon.accent : const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
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
  final bool isActive;

  const _Slide(
      {required this.slide, this.onPlay, this.onSelect, this.isActive = true});

  @override
  Widget build(BuildContext context) {
    // No glow/border when inactive — clean, flat card. Keeps the design
    // calm per user request to remove glow/shining animations.
    return GestureDetector(
      onTap: onSelect,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _CoverImage(url: slide.imageUrl, label: slide.title),
            // Bottom scrim for legibility — no sheen/shimmer
            DecoratedBox(
              decoration: const BoxDecoration(gradient: Neon.scrim),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
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
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.25,
                          height: 1.1,
                          shadows: [
                            Shadow(color: Colors.black, blurRadius: 12),
                          ],
                        ),
                      ),
                      if (slide.subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          slide.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Neon.inkSoft,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 8),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (onPlay != null)
                        NeonButton(
                            label: 'Play',
                            icon: Icons.play_arrow,
                            onPressed: onPlay),
                    ],
                  ),
                ),
              ),
            ),
          ],
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
