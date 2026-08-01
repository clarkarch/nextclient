import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// Network game art with a gradient placeholder and a graceful error state.
///
/// Designed for 16:9 card surfaces — always keep [AspectRatio] 16/9 in usage.
class GameArt extends StatefulWidget {
  final String? imageUrl;
  final double aspectRatio;
  final BorderRadius borderRadius;
  final Widget? overlay;
  final String? label;
  final int cacheWidth;

  const GameArt({
    super.key,
    this.imageUrl,
    this.aspectRatio = 16 / 9,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.overlay,
    this.label,
    this.cacheWidth = 800,
  });

  @override
  State<GameArt> createState() => _GameArtState();
}

class _GameArtState extends State<GameArt> {
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final url = widget.imageUrl;
    final showImage = url != null && url.isNotEmpty && !_failed;

    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: AspectRatio(
        aspectRatio: widget.aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildSurface(showImage, url),
            if (widget.overlay != null) widget.overlay!,
          ],
        ),
      ),
    );
  }

  Widget _buildSurface(bool showImage, String? url) {
    if (showImage) {
      return Image.network(
        url!,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        cacheWidth: widget.cacheWidth,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _placeholder();
        },
        errorBuilder: (context, error, stack) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_failed) setState(() => _failed = true);
          });
          return _placeholder();
        },
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1A2E), Color(0xFF0E0E18)],
        ),
        borderRadius: widget.borderRadius,
      ),
      child: Center(
        child: widget.label == null
            ? const Icon(Icons.videogame_asset_outlined, size: 30, color: Color(0x33FFFFFF))
            : Text(
                widget.label!,
                style: const TextStyle(color: Neon.inkMuted, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
      ),
    );
  }
}
