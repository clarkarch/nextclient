import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// A single destination in the [NeonRail].
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

/// Left icon rail (gaming-launcher style). Reusable: pass any list of
/// [RailDestination], the selected index, and an optional [footer].
class NeonRail extends StatelessWidget {
  final String brand;
  final List<RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final Widget? footer;

  const NeonRail({
    super.key,
    required this.brand,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      decoration: BoxDecoration(
        color: Neon.bgB,
        border: const Border(right: BorderSide(color: Color(0x1FFFFFFF))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            offset: const Offset(6, 0),
            blurRadius: 20,
          ),
        ],
      ),
      child: Column(
        children: [
          _BrandMark(label: brand),
          const SizedBox(height: 24),
          for (var i = 0; i < destinations.length; i++)
            _RailItem(
              destination: destinations[i],
              selected: i == selectedIndex,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          if (footer != null) ...[footer!, const SizedBox(height: 12)],
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  final String label;

  const _BrandMark({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          gradient: Neon.accentGradient,
          borderRadius: BorderRadius.circular(12),
          boxShadow: Neon.glowShadow(radius: 16, alpha: 0.45),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: Neon.bgA,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  final RailDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _RailItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
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
                      : _hover
                          ? const Color(0x0FFFFFFF)
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: active
                        ? Neon.accent.withValues(alpha: 0.5)
                        : Colors.transparent,
                  ),
                  boxShadow: active ? Neon.glowShadow(radius: 14, alpha: 0.3) : null,
                ),
                child: Icon(
                  active
                      ? widget.destination.selectedIcon ?? widget.destination.icon
                      : widget.destination.icon,
                  size: 22,
                  color: active ? Neon.accent : Neon.inkMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
