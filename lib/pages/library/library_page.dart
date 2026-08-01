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
    CatalogSortOption(id: 'publisher', label: 'Publisher', orderBy: 'publisher'),
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
      final games = await widget.services.catalog
          .fetchLibraryGamesUncached(token: token);
      if (!mounted) return;
      setState(() {
        _games = games;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[library] load failed: $e');
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
            storeIds.isEmpty || storeIds.any((id) => stores.contains(id.substring(6)));
        final tierMatch =
            tierIds.isEmpty || tierIds.any((id) => tier == id.substring(5));
        return storeMatch && tierMatch;
      }).toList();
    }
    switch (_sortId) {
      case 'title':
        list = [...list]
          ..sort((a, b) =>
              a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case 'publisher':
        list = [...list]
          ..sort((a, b) => (a.publisherName ?? '')
              .toLowerCase()
              .compareTo((b.publisherName ?? '').toLowerCase()));
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final games = _games;
    return NeonPageScaffold(
      slivers: _slivers(games),
    );
  }

  List<Widget> _slivers(List<CatalogGame>? games) {
    final list = _visible;
    final groups = _filterGroups;
    return [
      SliverToBoxAdapter(
        child: SectionHeader(
          title: games == null ? 'Library' : 'My Library · ${games.length}',
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 14),
        ),
      ),
      if (games != null && groups.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 20),
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
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Refresh library',
                  icon: const Icon(Icons.refresh, size: 18, color: Neon.inkSoft),
                  onPressed: _load,
                ),
              ],
            ),
          ),
        ),
      if (_loading && games == null)
        const SliverToBoxAdapter(child: GameGridSkeleton())
      else if (_error != null && games == null)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 320,
            child: NeonErrorView(message: _error!, onRetry: _load),
          ),
        )
      else if (list.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: Text(
                _filterIds.isNotEmpty
                    ? 'No games match your filters.'
                    : 'Your library is empty.',
                style: const TextStyle(color: Color(0xFF5C6B85), fontSize: 13),
              ),
            ),
          ),
        )
      else
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
                final game = list[i];
                return CatalogGameCard(
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
                );
              },
              childCount: list.length,
            ),
          ),
        ),
    ];
  }
}
