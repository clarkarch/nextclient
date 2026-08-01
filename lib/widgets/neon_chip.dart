import 'package:flutter/material.dart';

import '../theme/neon.dart';

enum NeonChipTone { accent, violet, success, warning, error, neutral }

/// Small pill used for badges and tags.
class NeonChip extends StatelessWidget {
  final String label;
  final NeonChipTone tone;
  final IconData? icon;
  final bool filled;

  const NeonChip({
    super.key,
    required this.label,
    this.tone = NeonChipTone.neutral,
    this.icon,
    this.filled = false,
  });

  Color get _color => switch (tone) {
        NeonChipTone.accent => Neon.accent,
        NeonChipTone.violet => Neon.violet,
        NeonChipTone.success => Neon.success,
        NeonChipTone.warning => Neon.warning,
        NeonChipTone.error => Neon.error,
        NeonChipTone.neutral => Neon.inkSoft,
      };

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: filled ? color : color.withValues(alpha: 0.45),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 13,
              color: filled ? Neon.bgA : color,
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: filled ? Neon.bgA : color,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

/// Dot + label used to indicate a live/active state.
class StatusDot extends StatelessWidget {
  final Color color;
  final String label;
  final bool pulse;

  const StatusDot({
    super.key,
    required this.color,
    required this.label,
    this.pulse = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PulseDot(color: color, pulse: pulse),
        const SizedBox(width: 7),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  final bool pulse;

  const _PulseDot({required this.color, required this.pulse});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.pulse) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      );
    }
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_controller),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: widget.color.withValues(alpha: 0.6), blurRadius: 8),
          ],
        ),
      ),
    );
  }
}
