import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// All-caps section label with an optional trailing action link.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.only(bottom: 14),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    color: Neon.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.6,
                    shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                  ),
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 3,
                      decoration: BoxDecoration(
                        gradient: Neon.accentGradient,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: [
                          BoxShadow(
                              color: Neon.accent.withValues(alpha: 0.45),
                              blurRadius: 8)
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 1,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Neon.accent.withValues(alpha: 0.18),
                              Colors.transparent
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (actionLabel != null)
            _ActionLink(label: actionLabel!, onTap: onAction),
        ],
      ),
    );
  }
}

class _ActionLink extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  const _ActionLink({required this.label, this.onTap});
  @override
  State<_ActionLink> createState() => _ActionLinkState();
}

class _ActionLinkState extends State<_ActionLink> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color:
                _hover ? Neon.accent.withValues(alpha: 0.10) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hover
                  ? Neon.accent.withValues(alpha: 0.32)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label.toUpperCase(),
                style: TextStyle(
                  color: _hover ? Colors.white : Neon.accent,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right,
                  size: 16, color: _hover ? Colors.white : Neon.accent),
            ],
          ),
        ),
      ),
    );
  }
}
