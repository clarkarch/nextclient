import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../theme/neon.dart';
import 'neon_button.dart';
import 'neon_dropdown.dart';

/// Modern neon filter + sort bar. Exposes a sort dropdown and a Filters
/// button (with active-count badge) that opens an anchored popover with
/// multi-select filter groups. Selections are reported back via callbacks.
class FilterSortBar extends StatefulWidget {
  final List<CatalogFilterGroup> groups;
  final List<CatalogSortOption> sortOptions;
  final String? sortId;
  final Set<String> filterIds;
  final ValueChanged<String?> onSortChanged;
  final ValueChanged<Set<String>> onFiltersChanged;

  const FilterSortBar({
    super.key,
    required this.groups,
    required this.sortOptions,
    this.sortId,
    this.filterIds = const {},
    required this.onSortChanged,
    required this.onFiltersChanged,
  });

  @override
  State<FilterSortBar> createState() => _FilterSortBarState();
}

class _FilterSortBarState extends State<FilterSortBar> {
  int get _activeCount => widget.filterIds.length;

  void _openFilters(BuildContext anchor) {
    final overlay =
        Overlay.of(anchor).context.findRenderObject() as RenderBox?;
    final box = anchor.findRenderObject() as RenderBox?;
    if (overlay == null || box == null) return;
    final offset =
        box.localToGlobal(Offset(0, box.size.height), ancestor: overlay);

    showDialog<void>(
      context: anchor,
      barrierColor: Colors.black54,
      barrierDismissible: true,
      builder: (_) => Stack(
        children: [
          Positioned(
            left: offset.dx.clamp(
              12,
              overlay.size.width > 360 ? overlay.size.width - 320 : 12,
            ),
            top: offset.dy + 8,
            child: _FilterPanel(
              groups: widget.groups,
              initial: widget.filterIds,
              onApply: widget.onFiltersChanged,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Neon.bgC,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Builder(
            builder: (buttonContext) => _FilterButton(
              count: _activeCount,
              onTap: () => _openFilters(buttonContext),
            ),
          ),
          const Spacer(),
          if (widget.sortOptions.isNotEmpty)
            Row(
              children: [
                const Text(
                  'SORT',
                  style: TextStyle(
                    color: Neon.inkMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(width: 8),
                NeonDropdown<String>(
                  value: widget.sortId,
                  onChanged: widget.onSortChanged,
                  items: widget.sortOptions
                      .map((s) => NeonDropdownItem(s.id, s.label))
                      .toList(),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _FilterButton({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: count > 0 ? Neon.accent.withValues(alpha: 0.14) : null,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: count > 0 ? Neon.accent : const Color(0x22FFFFFF),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_alt_outlined,
              size: 16,
              color: count > 0 ? Neon.accent : Neon.inkSoft,
            ),
            const SizedBox(width: 6),
            Text(
              'FILTERS',
              style: TextStyle(
                color: count > 0 ? Neon.accent : Neon.inkSoft,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  gradient: Neon.accentGradient,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Neon.bgA,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterPanel extends StatefulWidget {
  final List<CatalogFilterGroup> groups;
  final Set<String> initial;
  final ValueChanged<Set<String>> onApply;

  const _FilterPanel({
    required this.groups,
    required this.initial,
    required this.onApply,
  });

  @override
  State<_FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<_FilterPanel> {
  late final Set<String> _selected = {...widget.initial};

  void _toggle(String id) {
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Neon.bgC,
      elevation: 14,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300, maxHeight: 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'FILTERS',
                style: TextStyle(
                  color: Neon.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 12),
              for (final group in widget.groups) ...[
                Text(
                  group.label.toUpperCase(),
                  style: const TextStyle(
                    color: Neon.inkMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in group.options)
                      _ToggleChip(
                        label: option.label,
                        selected: _selected.contains(option.id),
                        onTap: () => _toggle(option.id),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              const Divider(),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() => _selected.clear());
                    },
                    style: TextButton.styleFrom(foregroundColor: Neon.inkSoft),
                    child: const Text('CLEAR'),
                  ),
                  const Spacer(),
                  NeonButton(
                    label: 'Apply',
                    onPressed: () {
                      Navigator.of(context).pop();
                      widget.onApply({..._selected});
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ToggleChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          gradient: selected ? Neon.accentGradient : null,
          color: selected ? null : const Color(0x0FFFFFFF),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? Neon.accent : const Color(0x22FFFFFF),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              const Icon(Icons.check, size: 12, color: Neon.bgA),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? Neon.bgA : Neon.ink,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
