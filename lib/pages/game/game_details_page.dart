import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/game_art.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_snackbar.dart';
import '../launcher/play_flow.dart';

/// Rich game detail screen: hero art, metadata, description, screenshots.
/// Falls back to the base [CatalogGame] data when the details query fails.
class GameDetailsPage extends StatefulWidget {
  final AppServices services;
  final CatalogGame game;

  const GameDetailsPage({
    super.key,
    required this.services,
    required this.game,
  });

  @override
  State<GameDetailsPage> createState() => _GameDetailsPageState();
}

class _GameDetailsPageState extends State<GameDetailsPage> {
  GameDetails? _details;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await widget.services.auth.resolveJwtToken();
      // The `apps` query expects the CMS app id; fall back to the numeric
      // launch appId in case the panels id isn't a valid query key.
      final candidates = <String>{
        widget.game.id,
        if (widget.game.launchAppId != null) widget.game.launchAppId!,
      }.toList();

      GameDetails? details;
      String? lastError;
      for (final id in candidates) {
        try {
          details = await widget.services.catalog.fetchGameDetails(
            token: token,
            appId: id,
          );
          break;
        } catch (e) {
          debugPrint('[details] fetch failed for $id: $e');
          lastError = e.toString();
        }
      }

      if (!mounted) return;
      setState(() {
        _details = details;
        _loading = false;
        _error = details == null ? (lastError ?? 'No details available') : null;
      });
      widget.services.logSink.log(
        LogLevel.info,
        'details',
        'Game details loaded for ${widget.game.id} '
            '(${details?.title ?? 'unavailable'})',
      );
    } catch (e) {
      debugPrint('[details] unexpected failure for ${widget.game.id}: $e');
      widget.services.logSink.log(
        LogLevel.error,
        'details',
        'Unexpected failure for ${widget.game.id}: $e',
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      showBack: true,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [_hero(), const SizedBox(height: 20), _meta()],
          ),
        ),
      ),
    );
  }

  Widget _hero() {
    final details = _details;
    final heroUrl = details?.heroImageUrl ?? widget.game.imageUrl;
    final heroTag = widget.game.imageUrl != null && widget.game.imageUrl!.isNotEmpty
        ? 'game-art:${widget.game.imageUrl}'
        : 'game-art:${widget.game.title}';
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Neon.outline.withValues(alpha: 0.55)),
        boxShadow: Neon.softShadow(radius: 24),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(23),
        child: Stack(
          children: [
            Hero(
              tag: heroTag,
              child: GameArt(
                imageUrl: heroUrl,
                label: widget.game.title,
                borderRadius: BorderRadius.zero,
              ),
            ),
            // Bottom scrim for title legibility
            Positioned.fill(
              child: DecoratedBox(
                decoration: const BoxDecoration(gradient: Neon.scrim),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.game.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.3,
                            height: 1.05,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 14),
                            ],
                          ),
                        ),
                        if (widget.game.publisherName != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            widget.game.publisherName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Neon.inkSoft,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 8)
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  NeonButton(
                    label: 'Play',
                    icon: Icons.play_arrow,
                    onPressed: () => PlayFlow.launch(
                      context,
                      services: widget.services,
                      game: widget.game,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _meta() {
    final details = _details;
    final game = widget.game;

    final chips = <NeonChip>[
      if (game.minimumMembershipTierLabel != null)
        NeonChip(
          label: game.minimumMembershipTierLabel!,
          tone: game.minimumMembershipTierLabel == 'ULTIMATE'
              ? NeonChipTone.accent
              : NeonChipTone.violet,
        ),
      if (details?.genres.isNotEmpty ?? false)
        ...details!.genres.map((g) => NeonChip(label: g)),
      if (game.playabilityState != null)
        NeonChip(label: game.playabilityState!, tone: NeonChipTone.success),
    ];

    String? description;
    if (details != null) {
      description = details.longDescription ?? details.shortDescription;
    }
    if (description == null || description.isEmpty) {
      description = game.title;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading && details == null) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: NeonSpinner(label: 'Loading details')),
          ),
        ],
        if (_error != null) ...[
          _InlineError(message: _error!, onRetry: _load),
          const SizedBox(height: 16),
        ],
        if (chips.isNotEmpty)
          _FadeIn(
            delay: const Duration(milliseconds: 140),
            child: Wrap(spacing: 8, runSpacing: 8, children: chips),
          ),
        if (details != null && details.screenshots.isNotEmpty) ...[
          const SizedBox(height: 26),
          _FadeIn(
            delay: const Duration(milliseconds: 200),
            child: Row(
              children: [
                const Text(
                  'SCREENSHOTS',
                  style: TextStyle(
                    color: Neon.ink,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.4,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Neon.accent.withValues(alpha: 0.35),
                          Colors.transparent
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _FadeIn(
            delay: const Duration(milliseconds: 260),
            child: SizedBox(
              height: 176,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                itemCount: details.screenshots.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (context, i) => _ScreenshotCard(
                  url: details.screenshots[i],
                  index: i,
                  onTap: () => _openScreenshot(
                      context, details.screenshots, i),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 26),
        _FadeIn(
          delay: const Duration(milliseconds: 320),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Neon.bgC.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Neon.outlineSoft),
              boxShadow: Neon.softShadow(radius: 16),
            ),
            child: Text(
              description,
              style: const TextStyle(
                color: Neon.inkSoft,
                fontSize: 14,
                height: 1.65,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openScreenshot(
      BuildContext context, List<String> urls, int initial) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      builder: (_) => _ScreenshotLightbox(urls: urls, initial: initial),
    );
  }
}

class _FadeIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  const _FadeIn({required this.child, this.delay = Duration.zero});
  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final Animation<double> _opacity =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

class _ScreenshotCard extends StatefulWidget {
  final String url;
  final int index;
  final VoidCallback onTap;
  const _ScreenshotCard(
      {required this.url, required this.index, required this.onTap});
  @override
  State<_ScreenshotCard> createState() => _ScreenshotCardState();
}

class _ScreenshotCardState extends State<_ScreenshotCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.03 : 1,
          duration: const Duration(milliseconds: 180),
          child: Container(
            width: 300,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _hover
                    ? Neon.accent.withValues(alpha: 0.45)
                    : Neon.outline.withValues(alpha: 0.6),
              ),
              boxShadow: _hover
                  ? Neon.glowShadow(radius: 18, alpha: 0.28)
                  : Neon.softShadow(radius: 14),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GameArt(
                    imageUrl: widget.url,
                    borderRadius: BorderRadius.zero,
                    cacheWidth: 900,
                  ),
                  if (_hover)
                    Container(
                      color: Colors.black.withValues(alpha: 0.22),
                      child: const Center(
                        child: Icon(Icons.zoom_in,
                            color: Colors.white, size: 28),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScreenshotLightbox extends StatefulWidget {
  final List<String> urls;
  final int initial;
  const _ScreenshotLightbox({required this.urls, required this.initial});
  @override
  State<_ScreenshotLightbox> createState() => _ScreenshotLightboxState();
}

class _ScreenshotLightboxState extends State<_ScreenshotLightbox> {
  late final PageController _c = PageController(initialPage: widget.initial);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Stack(
        children: [
          PageView.builder(
            controller: _c,
            itemCount: widget.urls.length,
            itemBuilder: (context, i) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(
                    widget.urls[i],
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 20,
            right: 20,
            child: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _InlineError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Neon.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: Neon.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Neon.error, fontSize: 12),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
          IconButton(
            tooltip: 'Copy error',
            icon: const Icon(Icons.copy, size: 16, color: Neon.error),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message));
              showNeonSnackbar(
                context,
                'Error copied to clipboard',
                copyable: false,
              );
            },
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
