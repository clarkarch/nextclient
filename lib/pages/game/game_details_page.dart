import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/game_art.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../launcher/play_flow.dart';

/// Rich game detail screen: hero art, metadata, description, screenshots.
class GameDetailsPage extends StatefulWidget {
  final AppServices services;
  final CatalogGame game;

  const GameDetailsPage({
    super.key,
    required this.services,
    required this.game,
  });

  @override
  State<GameDetailsPage> createState() => _GameDetailsPageState();
}

class _GameDetailsPageState extends State<GameDetailsPage> {
  GameDetails? _details;
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
      // The `apps` query expects the CMS app id, not the numeric variant
      // (launch) appId.
      final details = await widget.services.catalog.fetchGameDetails(
        token: token,
        appId: widget.game.id,
      );
      if (!mounted) return;
      setState(() {
        _details = details;
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
    return NeonPageScaffold(
      showBack: true,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _hero(),
              const SizedBox(height: 20),
              if (_loading && _details == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: NeonSpinner(label: 'Loading details')),
                )
              else if (_error != null && _details == null)
                NeonErrorView(message: _error!, onRetry: _load)
              else
                _meta(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hero() {
    final details = _details;
    final heroUrl = details?.heroImageUrl ?? widget.game.imageUrl;
    return Stack(
      children: [
        GameArt(
          imageUrl: heroUrl,
          label: widget.game.title,
          borderRadius: const BorderRadius.all(Radius.circular(22)),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 16,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.game.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Neon.ink,
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3,
                        shadows: [
                          Shadow(color: Colors.black, blurRadius: 14),
                        ],
                      ),
                    ),
                    if (widget.game.publisherName != null)
                      Text(
                        widget.game.publisherName!,
                        style: const TextStyle(
                          color: Neon.inkSoft,
                          fontSize: 13,
                          shadows: [
                            Shadow(color: Colors.black, blurRadius: 8),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              NeonButton(
                label: 'Play',
                icon: Icons.play_arrow,
                onPressed: () => PlayFlow.launch(
                  context,
                  services: widget.services,
                  game: widget.game,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _meta() {
    final details = _details;
    final game = widget.game;

    final chips = <NeonChip>[
      if (game.minimumMembershipTierLabel != null)
        NeonChip(
          label: game.minimumMembershipTierLabel!,
          tone: game.minimumMembershipTierLabel == 'ULTIMATE'
              ? NeonChipTone.accent
              : NeonChipTone.violet,
        ),
      if (details?.genres.isNotEmpty ?? false)
        ...details!.genres.map((g) => NeonChip(label: g)),
      if (game.playabilityState != null)
        NeonChip(
          label: game.playabilityState!,
          tone: NeonChipTone.success,
        ),
    ];

    final description = details?.longDescription ??
        details?.shortDescription ??
        (details == null ? _error ?? '' : '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chips.isNotEmpty)
          Wrap(spacing: 8, runSpacing: 8, children: chips),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            description,
            style: const TextStyle(
              color: Neon.inkSoft,
              fontSize: 14,
              height: 1.6,
            ),
          ),
        ],
        if (details != null && details.screenshots.isNotEmpty) ...[
          const SizedBox(height: 28),
          const Text(
            'SCREENSHOTS',
            style: TextStyle(
              color: Neon.ink,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.2,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 170,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: details.screenshots.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) => SizedBox(
                width: 300,
                child: GameArt(
                  imageUrl: details.screenshots[i],
                  borderRadius: const BorderRadius.all(Radius.circular(14)),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
