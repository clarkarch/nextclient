import 'package:flutter/material.dart';

import '../theme/neon.dart';
import 'neon_card.dart';
import 'neon_rail.dart';

/// Native-style sidenav hamburger. Sits at the bottom of the rail and opens a
/// GNOME-style popover menu listing the navigation destinations.
class NeonSidenavButton extends StatelessWidget {
  final List<RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const NeonSidenavButton({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _openMenu(context),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0x0FFFFFFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x22FFFFFF)),
            boxShadow: Neon.softShadow(radius: 10),
          ),
          child: const Icon(Icons.menu, color: Neon.inkSoft, size: 22),
        ),
      ),
    );
  }

  void _openMenu(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      barrierDismissible: true,
      builder: (_) => Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(96, 0, 12, 12),
          child: NeonCard(
            glow: true,
            radius: 18,
            padding: EdgeInsets.zero,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Text(
                      'NAVIGATE',
                      style: TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      ),
                    ),
                  ),
                  for (var i = 0; i < destinations.length; i++)
                    _MenuTile(
                      destination: destinations[i],
                      selected: i == selectedIndex,
                      onTap: () {
                        Navigator.of(context).pop();
                        onSelect(i);
                      },
                    ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final RailDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _MenuTile({
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: selected ? Neon.accent.withValues(alpha: 0.1) : Colors.transparent,
        child: Row(
          children: [
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
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (selected) ...[
              const Spacer(),
              const Icon(Icons.check, size: 16, color: Neon.accent),
            ],
          ],
        ),
      ),
    );
  }
}
