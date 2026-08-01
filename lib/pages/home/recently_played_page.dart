import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../widgets/catalog_game_card.dart';
import '../../widgets/guarded_sliver_grid.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../game/game_details_page.dart';

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
      slivers: games.isEmpty
          ? const [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(
                    child: Text(
                      'No recently played games yet.',
                      style: TextStyle(color: Color(0xFF5C6B85), fontSize: 13),
                    ),
                  ),
                ),
              ),
            ]
          : [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(0, 20, 0, 32),
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
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => GameDetailsPage(
                                services: services,
                                game: game,
                              ),
                            ),
                          );
                        },
                      );
                    },
                    childCount: games.length,
                  ),
                ),
              ),
            ],
    );
  }
}
