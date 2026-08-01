import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/catalog_game_card.dart';
import '../../widgets/game_grid.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../game/game_details_page.dart';
import '../launcher/play_flow.dart';

/// "See All" grid for the recently played row.
class RecentlyPlayedPage extends StatelessWidget {
  final AppServices services;
  final List<CatalogGame> games;

  const RecentlyPlayedPage({
    super.key,
    required this.services,
    required this.games,
  });

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Recently Played',
      showBack: true,
      child: games.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: Text(
                  'No recently played games yet.',
                  style: TextStyle(color: Neon.inkMuted, fontSize: 13),
                ),
              ),
            )
          : GameGrid(
              itemCount: games.length,
              itemBuilder: (context, i) {
                final game = games[i];
                return CatalogGameCard(
                  game: game,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            GameDetailsPage(services: services, game: game),
                      ),
                    );
                  },
                  onPlay: () => PlayFlow.launch(context,
                      services: services, game: game),
                );
              },
            ),
    );
  }
}
