import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/neon.dart';

/// Session timer showing elapsed streaming time.
///
/// [startedAt] pins the start so the elapsed time survives rebuilds and
/// remounts (e.g. the stream chrome toggling the widget out of the tree; a
/// fresh `initState` would otherwise reset the clock every time the UI was
/// shown). Defaults to mount time when not supplied.
class SessionTimer extends StatefulWidget {
  final DateTime? startedAt;

  const SessionTimer({super.key, this.startedAt});

  @override
  State<SessionTimer> createState() => _SessionTimerState();
}

class _SessionTimerState extends State<SessionTimer> {
  Timer? _timer;
  late final DateTime _startedAt;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _startedAt = widget.startedAt ?? DateTime.now();
    // Compute immediately so the first frame shows the real elapsed time
    // instead of flashing 00:00:00 until the first tick.
    _elapsed = DateTime.now().difference(_startedAt);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsed = DateTime.now().difference(_startedAt);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Neon.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timer_outlined, size: 16, color: Neon.accent),
          const SizedBox(width: 6),
          Text(
            _formatDuration(_elapsed),
            style: const TextStyle(
              color: Neon.ink,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
