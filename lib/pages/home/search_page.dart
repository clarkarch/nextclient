import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/catalog_game_card.dart';
import '../../widgets/guarded_sliver_grid.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../game/game_details_page.dart';

/// Search over the full catalog. Fetches all games once, then filters
/// client-side as the user types.
class SearchPage extends StatefulWidget {
  final AppServices services;

  const SearchPage({super.key, required this.services});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  List<CatalogGame>? _all;
  String? _error;
  final TextEditingController _query = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
    });
    try {
      final token = await widget.services.auth.resolveJwtToken();
      final games = await widget.services.catalog.fetchMainGamesUncached(
        token: token,
      );
      if (!mounted) return;
      setState(() => _all = games);
    } catch (e) {
      debugPrint('[search] load failed: $e');
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  List<CatalogGame> get _results {
    final all = _all ?? const <CatalogGame>[];
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((g) =>
            g.title.toLowerCase().contains(q) ||
            (g.publisherName?.toLowerCase().contains(q) ?? false))
        .toList();
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
    final all = _all;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 20),
          child: TextField(
            controller: _query,
            autofocus: true,
            onChanged: (v) => setState(() => _filter = v),
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
      if (_error != null && all == null)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 280,
            child: NeonErrorView(message: _error!, onRetry: _load),
          ),
        )
      else if (all == null)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(child: NeonSpinner(label: 'Loading catalog')),
          ),
        )
      else if (_results.isEmpty)
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
      else
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
                final game = _results[i];
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
              childCount: _results.length,
            ),
          ),
        ),
    ];
  }
}
