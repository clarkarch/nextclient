import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// Native-style sidenav hamburger. Sits at the bottom of the rail and opens
/// the [Scaffold] drawer (wired via `Scaffold.of(context).openDrawer()`).
class NeonSidenavButton extends StatelessWidget {
  final VoidCallback onPressed;

  const NeonSidenavButton({
    super.key,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPressed,
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
}
