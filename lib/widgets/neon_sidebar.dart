import 'package:flutter/material.dart';

import '../theme/neon.dart';
import 'neon_sidenav_button.dart';

/// A single destination in the [NeonSidebar].
class RailDestination {
  final String label;
  final IconData icon;
  final IconData? selectedIcon;

  const RailDestination({
    required this.label,
    required this.icon,
    this.selectedIcon,
  });
}

/// External, always-in-layout side navigation. Expands to a labeled sidebar
/// (NEXTCLIENT brand + nav tiles) or collapses to a narrow icon rail. The
/// burger at the bottom toggles between the two; content is pushed, never
/// overlayed by a sliding drawer.
class NeonSidebar extends StatelessWidget {
  final List<RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool expanded;
  final VoidCallback onToggle;

  const NeonSidebar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: expanded ? 250 : 84,
      decoration: BoxDecoration(
        color: Neon.bgB,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            offset: const Offset(6, 0),
            blurRadius: 20,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (expanded) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 24, 22, 14),
              child: ShaderMask(
                shaderCallback: _gradientShader,
                child: Text(
                  'NEXTCLIENT',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ] else
            const SizedBox(height: 20),
          for (var i = 0; i < destinations.length; i++)
            if (expanded)
              _SidebarTile(
                destination: destinations[i],
                selected: i == selectedIndex,
                onTap: () => onSelect(i),
              )
            else
              _RailItem(
                destination: destinations[i],
                selected: i == selectedIndex,
                onTap: () => onSelect(i),
              ),
          const Spacer(),
          Align(
            alignment: expanded ? Alignment.centerLeft : Alignment.center,
            child: Padding(
              padding: EdgeInsets.only(
                left: expanded ? 22 : 0,
                bottom: 12,
              ),
              child: NeonSidenavButton(onPressed: onToggle, expanded: expanded),
            ),
          ),
        ],
      ),
    );
  }

  static Shader _gradientShader(Rect bounds) =>
      Neon.accentGradient.createShader(bounds);
}

class _SidebarTile extends StatelessWidget {
  final RailDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? Neon.accent : Neon.inkSoft;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? Neon.accent.withValues(alpha: 0.1) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        child: Row(
          children: [
            if (selected)
              Container(
                width: 3,
                height: 20,
                margin: const EdgeInsets.only(right: 14),
                decoration: BoxDecoration(
                  gradient: Neon.accentGradient,
                  borderRadius: BorderRadius.circular(2),
                ),
              )
            else
              const SizedBox(width: 17),
            Icon(
              selected
                  ? destination.selectedIcon ?? destination.icon
                  : destination.icon,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 12),
            Text(
              destination.label,
              style: TextStyle(
                color: selected ? Neon.accent : Neon.ink,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final RailDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _RailItem({
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
      child: SizedBox(
        height: 64,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (active)
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 3,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: Neon.accentGradient,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: active
                    ? Neon.accent.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: active
                      ? Neon.accent.withValues(alpha: 0.5)
                      : Colors.transparent,
                ),
                boxShadow: active
                    ? Neon.glowShadow(radius: 14, alpha: 0.3)
                    : null,
              ),
              child: Icon(
                active
                    ? destination.selectedIcon ?? destination.icon
                    : destination.icon,
                size: 22,
                color: active ? Neon.accent : Neon.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
