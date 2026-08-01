import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// Elevated rounded panel with layered soft shadows.
class NeonCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? color;
  final bool glow;
  final double radius;
  final VoidCallback? onTap;

  const NeonCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.color,
    this.glow = false,
    this.radius = 16,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: color ?? Neon.bgC,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: glow ? Neon.glowShadow() : Neon.softShadow(),
      ),
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(radius),
                child: Padding(padding: padding, child: child),
              ),
            ),
    );
  }
}
