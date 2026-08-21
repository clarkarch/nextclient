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
        border: const Border(
            right: BorderSide(color: Color(0x1F252C3F), width: 1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            offset: const Offset(6, 0),
            blurRadius: 22,
          ),
          BoxShadow(
            color: Neon.accent.withValues(alpha: 0.04),
            offset: const Offset(1, 0),
            blurRadius: 0,
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

class _SidebarTile extends StatefulWidget {
  final RailDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final color = selected
        ? Neon.accent
        : (_hover ? Neon.ink : Neon.inkSoft);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          color: selected
              ? Neon.accent.withValues(alpha: 0.10)
              : (_hover
                  ? Colors.white.withValues(alpha: 0.04)
                  : Colors.transparent),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 3,
                height: selected ? 20 : (_hover ? 14 : 0),
                margin: EdgeInsets.only(right: selected ? 14 : 14),
                decoration: BoxDecoration(
                  gradient: Neon.accentGradient,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                              color: Neon.accent.withValues(alpha: 0.45),
                              blurRadius: 8)
                        ]
                      : null,
                ),
              ),
              Icon(
                selected
                    ? widget.destination.selectedIcon ?? widget.destination.icon
                    : widget.destination.icon,
                size: 20,
                color: color,
              ),
              const SizedBox(width: 12),
              Text(
                widget.destination.label,
                style: TextStyle(
                  color: selected ? Neon.accent : Neon.ink,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                ),
              ),
            ],
          ),
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
