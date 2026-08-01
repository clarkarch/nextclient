import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// Glowing neon spinner with an optional label.
class NeonSpinner extends StatelessWidget {
  final String? label;
  final double size;

  const NeonSpinner({super.key, this.label, this.size = 34});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: const CircularProgressIndicator(
            strokeWidth: 3,
            color: Neon.accent,
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 14),
          Text(
            label!,
            style: const TextStyle(
              color: Neon.inkSoft,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ],
    );
  }
}

/// Full-area centered loader.
class NeonLoadingView extends StatelessWidget {
  final String? label;

  const NeonLoadingView({super.key, this.label});

  @override
  Widget build(BuildContext context) {
    return Center(child: NeonSpinner(label: label));
  }
}

/// Shimmer-style skeleton card for loading grids.
class SkeletonCard extends StatefulWidget {
  final double aspectRatio;

  const SkeletonCard({super.key, this.aspectRatio = 16 / 9});

  @override
  State<SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<SkeletonCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(const Color(0xFF14141E), const Color(0xFF1E1E2E), t)!,
                  Color.lerp(const Color(0xFF1A1A26), const Color(0xFF222234), t)!,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Responsive placeholder grid while games load.
class GameGridSkeleton extends StatelessWidget {
  final int columns;
  final int rows;

  const GameGridSkeleton({super.key, this.columns = 6, this.rows = 2});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var r = 0; r < rows; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: Row(
              children: [
                for (var c = 0; c < columns; c++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SkeletonCard(),
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            height: 10,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A1A26),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Reusable error panel with a retry action.
class NeonErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const NeonErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 34, color: Neon.error),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Neon.inkSoft, fontSize: 13),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('RETRY'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Neon.accent,
                side: const BorderSide(color: Neon.accent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
