import 'package:flutter/material.dart';

import '../theme/neon.dart';
import 'neon_sidebar.dart';

/// Bottom navigation for portrait layouts (phones / narrow portrait windows),
/// mirroring the sidebar's neon styling so the two layouts feel identical.
///
/// A [Row] of [RailDestination]s is hard to reuse for a bottom bar (the rail
/// tiles are vertical stacks), so this renders its own compact tiles: icon on
/// top, label underneath, selected tile wrapped in an accent-tinted chip with
/// a top glow accent bar — the same accent language as the sidebar.
class NeonBottomNav extends StatelessWidget {
  final List<RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const NeonBottomNav({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Neon.bgB,
        border: const Border(top: BorderSide(color: Neon.outlineSoft)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            offset: const Offset(0, -6),
            blurRadius: 20,
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              for (var i = 0; i < destinations.length; i++)
                Expanded(
                  child: _BottomNavTile(
                    destination: destinations[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavTile extends StatelessWidget {
  final RailDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _BottomNavTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = selected;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Accent indicator bar for the selected tile (mirrors the sidebar's
          // left accent bar, rotated to the top).
          SizedBox(
            height: 3,
            width: 34,
            child: active
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: Neon.accentGradient,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 6),
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 40,
            height: 30,
            decoration: BoxDecoration(
              color: active
                  ? Neon.accent.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              boxShadow:
                  active ? Neon.glowShadow(radius: 12, alpha: 0.25) : null,
            ),
            child: Icon(
              active
                  ? destination.selectedIcon ?? destination.icon
                  : destination.icon,
              size: 22,
              color: active ? Neon.accent : Neon.inkMuted,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            destination.label,
            style: TextStyle(
              color: active ? Neon.accent : Neon.inkMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
