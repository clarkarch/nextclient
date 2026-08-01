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

  const HomePage({
    super.key,
    required this.services,
    required this.onSignOut,
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
      final featuredFuture =
          widget.services.catalog.fetchFeaturedGames(token: token);
      final recentFuture =
          widget.services.catalog.fetchRecentlyPlayed(token: token);
      final allFuture =
          widget.services.catalog.fetchMainGamesUncached(token: token);

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
    } catch (e) {
      debugPrint('[home] load failed: $e');
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
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    return NeonPageScaffold(
      header: _HomeTopBar(
        services: widget.services,
        onSignOut: widget.onSignOut,
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
        SliverToBoxAdapter(child: Padding(
          padding: EdgeInsets.only(top: 20),
          child: GameGridSkeleton(),
        )),
      ];
    }
    if (_error != null &&
        featured.isEmpty &&
        recent.isEmpty &&
        games.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 40),
            child: SizedBox(
              height: 320,
              child: NeonErrorView(message: _error!, onRetry: _load),
            ),
          ),
        ),
      ];
    }

    return [
      if (featured.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
        SliverToBoxAdapter(
          child: FeaturedCarousel(
            slides: featured
                .map((g) => FeaturedSlide(
                      title: g.title,
                      subtitle: g.publisherName,
                      imageUrl: g.marqueeImageUrl,
                      chips: _slideChips(g),
                      data: g,
                    ))
                .toList(),
            onPlay: (s) => _play(s.data as CatalogGame),
            onSelect: (s) => _openDetails(s.data as CatalogGame),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 36)),
      ],
      if (recent.isNotEmpty) ...[
        SliverToBoxAdapter(
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
        SliverToBoxAdapter(
          child: SizedBox(
            height: 165,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: recent.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, i) => SizedBox(
                width: 220,
                child: CatalogGameCard(
                  game: recent[i],
                  onTap: () => _openDetails(recent[i]),
                ),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 36)),
      ],
      const SliverToBoxAdapter(child: SectionHeader(title: 'All Games')),
      if (games.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 32),
          sliver: GuardedSliverGrid(
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 210,
              mainAxisExtent: 210 / 1.3,
              mainAxisSpacing: 26,
              crossAxisSpacing: 16,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final game = games[i];
                return CatalogGameCard(
                  game: game,
                  onTap: () => _openDetails(game),
                );
              },
              childCount: games.length,
            ),
          ),
        ),
      if (games.isEmpty && !_loading)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: Center(
              child: Text(
                'No games available.',
                style: TextStyle(color: Color(0xFF5C6B85), fontSize: 13),
              ),
            ),
          ),
        ),
    ];
  }

  List<NeonChip>? _slideChips(CatalogGame game) {
    final chips = <NeonChip>[];
    final tier = game.minimumMembershipTierLabel;
    if (tier != null) {
      chips.add(NeonChip(
        label: tier,
        tone: tier == 'ULTIMATE'
            ? NeonChipTone.accent
            : tier == 'PRIORITY'
                ? NeonChipTone.violet
                : NeonChipTone.neutral,
      ));
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

/// Home top bar: NEXTCLIENT brand on the left; search + profile on the right.
class _HomeTopBar extends StatelessWidget {
  final AppServices services;
  final VoidCallback onSignOut;

  const _HomeTopBar({required this.services, required this.onSignOut});

  @override
  Widget build(BuildContext context) {
    final user = services.auth.getSession()?.user;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x12FFFFFF))),
      ),
      child: Row(
        children: [
          ShaderMask(
            shaderCallback: (bounds) => Neon.accentGradient.createShader(bounds),
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
                    builder: (_) => AccountPage(
                      services: services,
                      onSignOut: onSignOut,
                    ),
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

class _TopIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _TopIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0x0FFFFFFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0x22FFFFFF)),
          ),
          child: Icon(icon, size: 20, color: Neon.inkSoft),
        ),
      ),
    );
  }
}
