import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/catalog_game_card.dart';
import '../../widgets/filter_sort_bar.dart';
import '../../widgets/guarded_sliver_grid.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/section_header.dart';
import '../game/game_details_page.dart';

/// User's owned/connected games, 16:9 grid with client-side filter/sort.
class LibraryPage extends StatefulWidget {
  final AppServices services;

  const LibraryPage({super.key, required this.services});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<CatalogGame>? _games;
  String? _error;
  bool _loading = false;
  String? _sortId;
  final Set<String> _filterIds = {};

  static const _sortOptions = [
    CatalogSortOption(id: 'title', label: 'Title', orderBy: 'title'),
    CatalogSortOption(
      id: 'publisher',
      label: 'Publisher',
      orderBy: 'publisher',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _sortId = _sortOptions.first.id;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await widget.services.auth.resolveJwtToken();
      final games = await widget.services.catalog.fetchLibraryGamesUncached(
        token: token,
      );
      widget.services.logSink.log(
        LogLevel.info,
        'library',
        'Library loaded: ${games.length} games',
      );
      if (!mounted) return;
      setState(() {
        _games = games;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[library] load failed: $e');
      widget.services.logSink.log(LogLevel.error, 'library', 'Load failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Synthesized client-side filter groups from the loaded library.
  List<CatalogFilterGroup> get _filterGroups {
    final games = _games ?? const <CatalogGame>[];
    final stores = <String>{};
    final tiers = <String>{};
    for (final g in games) {
      for (final v in g.variants) {
        if (v.appStore != null && v.appStore!.isNotEmpty) {
          stores.add(v.appStore!);
        }
      }
      if (g.minimumMembershipTierLabel != null) {
        tiers.add(g.minimumMembershipTierLabel!);
      }
    }
    final storeOptions = stores.toList()..sort();
    final tierOptions = tiers.toList()..sort();
    return [
      if (storeOptions.isNotEmpty)
        CatalogFilterGroup(
          id: 'store',
          label: 'Store',
          options: storeOptions
              .map((s) => CatalogFilterOption(id: 'store:$s', label: s))
              .toList(),
        ),
      if (tierOptions.isNotEmpty)
        CatalogFilterGroup(
          id: 'tier',
          label: 'Membership',
          options: tierOptions
              .map((t) => CatalogFilterOption(id: 'tier:$t', label: t))
              .toList(),
        ),
    ];
  }

  List<CatalogGame> get _visible {
    final games = _games ?? const <CatalogGame>[];
    var list = games;
    if (_filterIds.isNotEmpty) {
      final storeIds = _filterIds.where((id) => id.startsWith('store:'));
      final tierIds = _filterIds.where((id) => id.startsWith('tier:'));
      list = list.where((g) {
        final stores = g.variants
            .map((v) => v.appStore)
            .whereType<String>()
            .toSet();
        final tier = g.minimumMembershipTierLabel;
        final storeMatch =
            storeIds.isEmpty ||
            storeIds.any((id) => stores.contains(id.substring(6)));
        final tierMatch =
            tierIds.isEmpty || tierIds.any((id) => tier == id.substring(5));
        return storeMatch && tierMatch;
      }).toList();
    }
    switch (_sortId) {
      case 'title':
        list = [...list]
          ..sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
        break;
      case 'publisher':
        list = [...list]
          ..sort(
            (a, b) => (a.publisherName ?? '').toLowerCase().compareTo(
              (b.publisherName ?? '').toLowerCase(),
            ),
          );
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final games = _games;
    return NeonPageScaffold(onRefresh: _load, slivers: _slivers(games));
  }

  List<Widget> _slivers(List<CatalogGame>? games) {
    final list = _visible;
    final groups = _filterGroups;
    return [
      SliverToBoxAdapter(
        child: _FadeIn(
          delay: const Duration(milliseconds: 60),
          child: SectionHeader(
            title: games == null ? 'Library' : 'My Library · ${games.length}',
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 14),
          ),
        ),
      ),
      if (games != null && groups.isNotEmpty)
        SliverToBoxAdapter(
          child: _FadeIn(
            delay: const Duration(milliseconds: 120),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: Row(
                children: [
                  Expanded(
                    child: FilterSortBar(
                      groups: groups,
                      sortOptions: _sortOptions,
                      sortId: _sortId,
                      filterIds: _filterIds,
                      onSortChanged: (id) => setState(() => _sortId = id),
                      onFiltersChanged: (ids) {
                        setState(() {
                          _filterIds
                            ..clear()
                            ..addAll(ids);
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      if (_loading && games == null)
        const SliverToBoxAdapter(child: GameGridSkeleton())
      else if (_error != null && games == null)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 340,
            child: NeonErrorView(message: _error!, onRetry: _load),
          ),
        )
      else if (list.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(36),
            child: _EmptyLibrary(
              filtered: _filterIds.isNotEmpty,
              onClear: _filterIds.isNotEmpty
                  ? () => setState(() => _filterIds.clear())
                  : null,
            ),
          ),
        )
      else
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
              final game = list[i];
              return _StaggeredCard(
                index: i,
                child: CatalogGameCard(
                  game: game,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => GameDetailsPage(
                          services: widget.services,
                          game: game,
                        ),
                      ),
                    );
                  },
                ),
              );
            }, childCount: list.length),
          ),
        ),
    ];
  }
}

class _FadeIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  const _FadeIn({required this.child, this.delay = Duration.zero});
  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.05),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  @override
  void initState() {
    super.initState();
    if (!UiMotion.enabled.value) return;
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
    if (!UiMotion.enabled.value) return widget.child;
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
    duration: const Duration(milliseconds: 460),
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.07),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  @override
  void initState() {
    super.initState();
    if (!UiMotion.enabled.value) return;
    Future.delayed(Duration(milliseconds: (widget.index % 14) * 38), () {
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
    if (!UiMotion.enabled.value) return widget.child;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  final bool filtered;
  final VoidCallback? onClear;
  const _EmptyLibrary({required this.filtered, this.onClear});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 26),
        decoration: BoxDecoration(
          color: Neon.bgC.withValues(alpha: 0.74),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Neon.outlineSoft),
          boxShadow: Neon.softShadow(radius: 18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                gradient: filtered ? Neon.violetGradient : Neon.accentGradient,
                shape: BoxShape.circle,
                boxShadow: Neon.glowShadow(radius: 14, alpha: 0.28),
              ),
              child: Icon(
                filtered ? Icons.filter_alt_off : Icons.library_add_outlined,
                color: Neon.bgA,
                size: 26,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              filtered ? 'No matches' : 'Your library is empty',
              style: const TextStyle(
                color: Neon.ink,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              filtered
                  ? 'Try clearing filters to see all your games.'
                  : 'Connect a store account to see your owned games here.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Neon.inkMuted, fontSize: 12.5),
            ),
            if (filtered && onClear != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: onClear,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Neon.accent,
                  side: const BorderSide(color: Neon.accent),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('CLEAR FILTERS'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
