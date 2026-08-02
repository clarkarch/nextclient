import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/game_art.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_snackbar.dart';
import '../launcher/play_flow.dart';

/// Rich game detail screen: hero art, metadata, description, screenshots.
/// Falls back to the base [CatalogGame] data when the details query fails.
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
      // The `apps` query expects the CMS app id; fall back to the numeric
      // launch appId in case the panels id isn't a valid query key.
      final candidates = <String>{
        widget.game.id,
        if (widget.game.launchAppId != null) widget.game.launchAppId!,
      }.toList();

      GameDetails? details;
      String? lastError;
      for (final id in candidates) {
        try {
          details = await widget.services.catalog.fetchGameDetails(
            token: token,
            appId: id,
          );
          break;
        } catch (e) {
          debugPrint('[details] fetch failed for $id: $e');
          lastError = e.toString();
        }
      }

      if (!mounted) return;
      setState(() {
        _details = details;
        _loading = false;
        _error = details == null ? (lastError ?? 'No details available') : null;
      });
      widget.services.logSink.log(
        LogLevel.info,
        'details',
        'Game details loaded for ${widget.game.id} '
            '(${details?.title ?? 'unavailable'})',
      );
    } catch (e) {
      debugPrint('[details] unexpected failure for ${widget.game.id}: $e');
      widget.services.logSink.log(
        LogLevel.error,
        'details',
        'Unexpected failure for ${widget.game.id}: $e',
      );
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
            children: [_hero(), const SizedBox(height: 20), _meta()],
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
        Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(22)),
            boxShadow: Neon.softShadow(radius: 30),
          ),
          child: GameArt(
            imageUrl: heroUrl,
            label: widget.game.title,
            borderRadius: const BorderRadius.all(Radius.circular(22)),
          ),
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
                        shadows: [Shadow(color: Colors.black, blurRadius: 14)],
                      ),
                    ),
                    if (widget.game.publisherName != null)
                      Text(
                        widget.game.publisherName!,
                        style: const TextStyle(
                          color: Neon.inkSoft,
                          fontSize: 13,
                          shadows: [Shadow(color: Colors.black, blurRadius: 8)],
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
        NeonChip(label: game.playabilityState!, tone: NeonChipTone.success),
    ];

    String? description;
    if (details != null) {
      description = details.longDescription ?? details.shortDescription;
    }
    if (description == null || description.isEmpty) {
      description = game.title;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading && details == null) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: NeonSpinner(label: 'Loading details')),
          ),
        ],
        if (_error != null) ...[
          _InlineError(message: _error!, onRetry: _load),
          const SizedBox(height: 16),
        ],
        if (chips.isNotEmpty) Wrap(spacing: 8, runSpacing: 8, children: chips),
        if (details != null && details.screenshots.isNotEmpty) ...[
          const SizedBox(height: 24),
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
        const SizedBox(height: 24),
        Text(
          description,
          style: const TextStyle(
            color: Neon.inkSoft,
            fontSize: 14,
            height: 1.6,
          ),
        ),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _InlineError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Neon.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: Neon.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Neon.error, fontSize: 12),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
          IconButton(
            tooltip: 'Copy error',
            icon: const Icon(Icons.copy, size: 16, color: Neon.error),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message));
              showNeonSnackbar(
                context,
                'Error copied to clipboard',
                copyable: false,
              );
            },
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
