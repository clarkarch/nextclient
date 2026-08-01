import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// Native-style sidenav toggle. Sits at the bottom of the sidebar: shows an
/// open-panel icon when collapsed, a close-panel icon when expanded.
class NeonSidenavButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool expanded;

  const NeonSidenavButton({
    super.key,
    required this.onPressed,
    this.expanded = false,
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
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: Icon(
              expanded ? Icons.menu_open : Icons.menu,
              key: ValueKey(expanded),
              color: Neon.inkSoft,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}
