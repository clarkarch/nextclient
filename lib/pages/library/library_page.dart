import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/catalog_game_card.dart';
import '../../widgets/game_grid.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/section_header.dart';
import '../game/game_details_page.dart';
import '../launcher/play_flow.dart';

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: games == null ? 'Library' : 'My Library · ${games.length}',
          ),
          if (_loading && games == null)
            const GameGridSkeleton()
          else if (_error != null && games == null)
            SizedBox(
              height: 320,
              child: NeonErrorView(message: _error!, onRetry: _load),
            )
          else if (games != null && games.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: Text(
                  'Your library is empty.',
                  style: TextStyle(color: Neon.inkMuted, fontSize: 13),
                ),
              ),
            )
          else if (games != null)
            GameGrid(
              itemCount: games.length,
              itemBuilder: (context, i) {
                final game = games[i];
                return CatalogGameCard(
                  game: game,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            GameDetailsPage(services: widget.services, game: game),
                      ),
                    );
                  },
                  onPlay: () => PlayFlow.launch(context,
                      services: widget.services, game: game),
                );
              },
            ),
        ],
      ),
    );
  }
}
