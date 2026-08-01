import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// Neon-styled dropdown for settings options.
class NeonDropdown<T> extends StatelessWidget {
  final T? value;
  final ValueChanged<T?> onChanged;
  final List<NeonDropdownItem<T>> items;
  final double? width;

  const NeonDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    required this.items,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x0FFFFFFF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          dropdownColor: Neon.bgC,
          icon: const Icon(Icons.expand_more, color: Neon.accent, size: 18),
          style: const TextStyle(color: Neon.ink, fontSize: 13),
          items: items
              .map((i) => DropdownMenuItem(
                    value: i.value,
                    child: Text(
                      i.label,
                      style: const TextStyle(
                        color: Neon.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class NeonDropdownItem<T> {
  final T value;
  final String label;

  const NeonDropdownItem(this.value, this.label);
}

/// Reusable option selector row for single-choice settings.
class NeonChoiceRow<T> extends StatelessWidget {
  final String title;
  final T value;
  final ValueChanged<T> onChanged;
  final List<NeonDropdownItem<T>> options;

  const NeonChoiceRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    required this.options,
  });

  @override
  Widget build(BuildContext context) {
    return NeonDropdown<T>(
      value: value,
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      items: options,
    );
  }
}
