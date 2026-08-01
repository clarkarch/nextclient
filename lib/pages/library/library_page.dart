import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../widgets/catalog_game_card.dart';
import '../../widgets/guarded_sliver_grid.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/section_header.dart';
import '../game/game_details_page.dart';

/// User's owned/connected games, 16:9 grid.
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

  @override
  Widget build(BuildContext context) {
    final games = _games;
    return NeonPageScaffold(
      slivers: _slivers(games),
    );
  }

  List<Widget> _slivers(List<CatalogGame>? games) {
    final list = games ?? const <CatalogGame>[];
    return [
      SliverToBoxAdapter(
        child: SectionHeader(
          title: games == null ? 'Library' : 'My Library · ${games.length}',
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 14),
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
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: Center(
              child: Text(
                'Your library is empty.',
                style: TextStyle(color: Color(0xFF5C6B85), fontSize: 13),
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
