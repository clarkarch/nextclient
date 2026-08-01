import 'package:flutter/material.dart';

/// A [SliverGrid] that stays inert when the viewport cross-axis extent is
/// zero (e.g. during window minimize / resize). Prevents the
/// `crossAxisExtent > 0.0` assertion in sliver_grid.dart.
class GuardedSliverGrid extends StatelessWidget {
  final SliverGridDelegate gridDelegate;
  final SliverChildDelegate delegate;

  const GuardedSliverGrid({
    super.key,
    required this.gridDelegate,
    required this.delegate,
  });

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        if (constraints.crossAxisExtent <= 0) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        return SliverGrid(gridDelegate: gridDelegate, delegate: delegate);
      },
    );
  }
}
