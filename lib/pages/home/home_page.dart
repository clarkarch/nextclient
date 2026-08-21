import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/catalog_game_card.dart';
import '../../widgets/featured_carousel.dart';
import '../../widgets/guarded_sliver_grid.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/section_header.dart';
import '../game/game_details_page.dart';
import '../launcher/play_flow.dart';
import '../settings/account_page.dart';
import 'recently_played_page.dart';
import 'search_page.dart';

/// Home: featured carousel + recently played row (See All) + all games grid.
class HomePage extends StatefulWidget {
  final AppServices services;
  final VoidCallback onSignOut;
  final bool showBrand;

  const HomePage({
    super.key,
    required this.services,
    required this.onSignOut,
    this.showBrand = true,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<CatalogGame>? _featured;
  List<CatalogGame>? _recent;
  List<CatalogGame>? _all;
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

      // Load each section independently so one failing panel doesn't blank
      // the whole home page.
      final featuredFuture = widget.services.catalog.fetchFeaturedGames(
        token: token,
      );
      final recentFuture = widget.services.catalog.fetchRecentlyPlayed(
        token: token,
      );
      final allFuture = widget.services.catalog.fetchMainGamesUncached(
        token: token,
      );

      final featured = await _guard(featuredFuture);
      final recent = await _guard(recentFuture);
      final all = await _guard(allFuture);

      if (!mounted) return;
      setState(() {
        _featured = featured;
        _recent = recent;
        _all = all;
        _loading = false;
        if (featured == null && recent == null && all == null) {
          _error = 'Could not load the catalog. Check your connection.';
        }
      });
      widget.services.logSink.log(
        LogLevel.info,
        'home',
        'Catalog loaded: featured=${featured?.length ?? 0}, '
            'recent=${recent?.length ?? 0}, all=${all?.length ?? 0}',
      );
    } catch (e) {
      debugPrint('[home] load failed: $e');
      widget.services.logSink.log(LogLevel.error, 'home', 'Load failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<List<CatalogGame>?> _guard(Future<List<CatalogGame>> future) async {
    try {
      return await future;
    } catch (e) {
      debugPrint('[home] section load failed: $e');
      widget.services.logSink.log(
        LogLevel.warn,
        'home',
        'Section load failed: $e',
      );
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    return NeonPageScaffold(
      onRefresh: _load,
      header: _HomeTopBar(
        services: widget.services,
        onSignOut: widget.onSignOut,
        showBrand: widget.showBrand,
        onRefresh: _load,
      ),
      slivers: _buildSlivers(all),
    );
  }

  List<Widget> _buildSlivers(List<CatalogGame>? all) {
    final featured = _featured ?? const <CatalogGame>[];
    final recent = _recent ?? const <CatalogGame>[];
    final games = all ?? const <CatalogGame>[];

    if (_loading && all == null) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 20),
            child: GameGridSkeleton(),
          ),
        ),
      ];
    }
    if (_error != null && featured.isEmpty && recent.isEmpty && games.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 40),
            child: SizedBox(
              height: 340,
              child: NeonErrorView(message: _error!, onRetry: _load),
            ),
          ),
        ),
      ];
    }

    return [
      if (featured.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
        SliverToBoxAdapter(
          child: _FadeIn(
            delay: const Duration(milliseconds: 60),
            child: FeaturedCarousel(
              slides: featured
                  .map(
                    (g) => FeaturedSlide(
                      title: g.title,
                      subtitle: g.publisherName,
                      imageUrl: g.marqueeImageUrl,
                      chips: _slideChips(g),
                      data: g,
                    ),
                  )
                  .toList(),
              onPlay: (s) => _play(s.data as CatalogGame),
              onSelect: (s) => _openDetails(s.data as CatalogGame),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 34)),
      ],
      if (recent.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: _FadeIn(
            delay: const Duration(milliseconds: 140),
            child: SectionHeader(
              title: 'Recently Played',
              actionLabel: 'See All',
              onAction: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RecentlyPlayedPage(
                      services: widget.services,
                      games: recent,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _FadeIn(
            delay: const Duration(milliseconds: 180),
            child: SizedBox(
              height: 175,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                itemCount: recent.length,
                separatorBuilder: (_, _) => const SizedBox(width: 16),
                itemBuilder: (context, i) => SizedBox(
                  width: 224,
                  child: _StaggeredCard(
                    index: i,
                    child: CatalogGameCard(
                      game: recent[i],
                      onTap: () => _openDetails(recent[i]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 34)),
      ],
      SliverToBoxAdapter(
        child: _FadeIn(
          delay: const Duration(milliseconds: 220),
          child: const SectionHeader(title: 'All Games'),
        ),
      ),
      if (games.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 32),
          sliver: GuardedSliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 210,
              mainAxisExtent: 184,
              mainAxisSpacing: 22,
              crossAxisSpacing: 16,
            ),
            delegate: SliverChildBuilderDelegate((context, i) {
              final game = games[i];
              return _StaggeredCard(
                index: i,
                child: CatalogGameCard(
                  game: game,
                  onTap: () => _openDetails(game),
                ),
              );
            }, childCount: games.length),
          ),
        ),
      if (games.isEmpty && !_loading)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: _EmptyIllustration(
              icon: Icons.videogame_asset_outlined,
              title: 'No games yet',
              subtitle: 'Pull to refresh or check your connection.',
            ),
          ),
        ),
    ];
  }

  List<NeonChip>? _slideChips(CatalogGame game) {
    final chips = <NeonChip>[];
    final tier = game.minimumMembershipTierLabel;
    if (tier != null) {
      chips.add(
        NeonChip(
          label: tier,
          tone: tier == 'ULTIMATE'
              ? NeonChipTone.accent
              : tier == 'PRIORITY'
              ? NeonChipTone.violet
              : NeonChipTone.neutral,
        ),
      );
    }
    return chips.isEmpty ? null : chips;
  }

  void _openDetails(CatalogGame game) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GameDetailsPage(services: widget.services, game: game),
      ),
    );
  }

  void _play(CatalogGame game) {
    PlayFlow.launch(context, services: widget.services, game: game);
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

class _StaggeredCard extends StatefulWidget {
  final int index;
  final Widget child;
  const _StaggeredCard({required this.index, required this.child});
  @override
  State<_StaggeredCard> createState() => _StaggeredCardState();
}

class _StaggeredCardState extends State<_StaggeredCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  late final Animation<double> _opacity =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.08),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    final delay = Duration(milliseconds: (widget.index % 12) * 45);
    Future.delayed(delay, () {
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

class _EmptyIllustration extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyIllustration(
      {required this.icon, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
        decoration: BoxDecoration(
          color: Neon.bgC.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Neon.outlineSoft),
          boxShadow: Neon.softShadow(radius: 20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                gradient: Neon.accentGradient,
                shape: BoxShape.circle,
                boxShadow: Neon.glowShadow(radius: 16, alpha: 0.28),
              ),
              child: Icon(icon, color: Neon.bgA, size: 28),
            ),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(
                    color: Neon.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: Neon.inkMuted, fontSize: 12.5)),
          ],
        ),
      ),
    );
  }
}

/// Home top bar: NEXTCLIENT brand on the left; refresh + search + profile.
class _HomeTopBar extends StatelessWidget {
  final AppServices services;
  final VoidCallback onSignOut;
  final bool showBrand;
  final VoidCallback onRefresh;

  const _HomeTopBar({
    required this.services,
    required this.onSignOut,
    required this.showBrand,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final user = services.auth.getSession()?.user;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          if (showBrand)
            ShaderMask(
              shaderCallback: (bounds) =>
                  Neon.accentGradient.createShader(bounds),
              child: const Text(
                'NEXTCLIENT',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
            ),
          const Spacer(),
          _TopIconButton(
            icon: Icons.refresh,
            tooltip: 'Refresh catalog',
            onTap: onRefresh,
          ),
          const SizedBox(width: 8),
          _TopIconButton(
            icon: Icons.search,
            tooltip: 'Search games',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SearchPage(services: services),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          if (user != null)
            GestureDetector(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        AccountPage(services: services, onSignOut: onSignOut),
                  ),
                );
              },
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: Neon.accentGradient,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Neon.accent.withValues(alpha: 0.5)),
                  boxShadow: Neon.glowShadow(radius: 12, alpha: 0.3),
                ),
                child: Center(
                  child: Text(
                    user.displayName.isNotEmpty
                        ? user.displayName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: Neon.bgA,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TopIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _TopIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_TopIconButton> createState() => _TopIconButtonState();
}

class _TopIconButtonState extends State<_TopIconButton> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _pressed ? 0.94 : (_hover ? 1.06 : 1),
            duration: const Duration(milliseconds: 140),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _hover
                    ? Neon.accent.withValues(alpha: 0.12)
                    : const Color(0x0FFFFFFF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _hover
                      ? Neon.accent.withValues(alpha: 0.42)
                      : Neon.outline,
                ),
                boxShadow: _hover
                    ? [
                        BoxShadow(
                            color: Neon.accent.withValues(alpha: 0.18),
                            blurRadius: 14)
                      ]
                    : null,
              ),
              child: Icon(widget.icon,
                  size: 20,
                  color: _hover ? Neon.accent : Neon.inkSoft),
            ),
          ),
        ),
      ),
    );
  }
}
