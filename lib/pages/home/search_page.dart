import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/catalog_game_card.dart';
import '../../widgets/filter_sort_bar.dart';
import '../../widgets/guarded_sliver_grid.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../game/game_details_page.dart';

/// Server-side catalog search with sort + filters.
class SearchPage extends StatefulWidget {
  final AppServices services;

  const SearchPage({super.key, required this.services});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _query = TextEditingController();
  CatalogDefinitions? _definitions;
  String? _sortId;
  final Set<String> _filterIds = {};
  List<CatalogGame> _games = const [];
  int _totalCount = 0;
  String? _error;
  bool _loading = true;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _query.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final token = await widget.services.auth.resolveJwtToken();
      final definitions =
          await widget.services.catalog.fetchFilterSortDefinitions(token: token);
      if (!mounted) return;
      setState(() {
        _definitions = definitions;
        _sortId = definitions.sortOptions.firstOrNull?.id;
      });
    } catch (e) {
      debugPrint('[search] definitions failed: $e');
    }
    await _browse();
  }

  Future<void> _browse() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await widget.services.auth.resolveJwtToken();
      final result = await widget.services.catalog.browseCatalog(
        token: token,
        searchQuery: _query.text,
        sortId: _sortId,
        filterIds: _filterIds.toList(),
      );
      if (!mounted) return;
      setState(() {
        _games = result.games;
        _totalCount = result.totalCount;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[search] browse failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _browse();
    });
  }

  void _onSortChanged(String? sortId) {
    setState(() => _sortId = sortId);
    _browse();
  }

  void _onFiltersChanged(Set<String> ids) {
    setState(() {
      _filterIds
        ..clear()
        ..addAll(ids);
    });
    _browse();
  }

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Search',
      showBack: true,
      slivers: _slivers(),
    );
  }

  List<Widget> _slivers() {
    final definitions = _definitions;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 14),
          child: TextField(
            controller: _query,
            autofocus: true,
            onChanged: _onQueryChanged,
            style: const TextStyle(color: Neon.ink, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search games…',
              hintStyle: const TextStyle(color: Neon.inkMuted, fontSize: 13),
              prefixIcon: const Icon(Icons.search, color: Neon.inkMuted),
              filled: true,
              fillColor: Neon.bgC,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Neon.accent, width: 1.4),
              ),
            ),
          ),
        ),
      ),
      if (definitions != null && definitions.groups.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: FilterSortBar(
              groups: definitions.groups,
              sortOptions: definitions.sortOptions,
              sortId: _sortId,
              filterIds: _filterIds,
              onSortChanged: _onSortChanged,
              onFiltersChanged: _onFiltersChanged,
            ),
          ),
        ),
      if (_error != null && _games.isEmpty)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 280,
            child: NeonErrorView(message: _error!, onRetry: _browse),
          ),
        )
      else if (_loading && _games.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(child: NeonSpinner(label: 'Searching catalog')),
          ),
        )
      else if (_games.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: Center(
              child: Text(
                'No games match your search.',
                style: TextStyle(color: Color(0xFF5C6B85), fontSize: 13),
              ),
            ),
          ),
        )
      else ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              '${_games.length} results'
              '${_totalCount > _games.length ? ' of $_totalCount' : ''}',
              style: const TextStyle(color: Neon.inkMuted, fontSize: 12),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 32),
          sliver: GuardedSliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 210,
              mainAxisExtent: 210 / 1.3,
              mainAxisSpacing: 26,
              crossAxisSpacing: 16,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final game = _games[i];
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
              childCount: _games.length,
            ),
          ),
        ),
      ],
    ];
  }
}
