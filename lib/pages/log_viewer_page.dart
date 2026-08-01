import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../theme/neon.dart';
import '../widgets/neon_chip.dart';
import '../widgets/neon_page_scaffold.dart';

/// Live view over the in-memory [RingBufferLogSink].
class LogViewerPage extends StatefulWidget {
  final RingBufferLogSink logSink;

  const LogViewerPage({super.key, required this.logSink});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

enum _LogFilter { all, info, warn, error }

class _LogViewerPageState extends State<LogViewerPage> {
  final ScrollController _scroll = ScrollController();
  _LogFilter _filter = _LogFilter.all;
  Timer? _timer;
  List<LogEntry> _entries = const [];
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(milliseconds: 800), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _refresh() {
    final entries = widget.logSink.entries;
    if (identical(entries, _entries)) return;
    setState(() => _entries = entries);
    if (_stickToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  List<LogEntry> get _visible {
    return switch (_filter) {
      _LogFilter.all => _entries,
      _LogFilter.info => _entries.where((e) => e.level.index >= LogLevel.info.index).toList(),
      _LogFilter.warn => _entries.where((e) => e.level.index >= LogLevel.warn.index).toList(),
      _LogFilter.error => _entries.where((e) => e.level == LogLevel.error).toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Logs',
      showBack: true,
      actions: [
        IconButton(
          tooltip: 'Follow scroll',
          icon: Icon(
            _stickToBottom ? Icons.vertical_align_bottom : Icons.vertical_align_center,
            size: 18,
            color: _stickToBottom ? Neon.accent : Neon.inkMuted,
          ),
          onPressed: () => setState(() => _stickToBottom = !_stickToBottom),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in _LogFilter.values)
                  GestureDetector(
                    onTap: () => setState(() => _filter = f),
                    child: NeonChip(
                      label: switch (f) {
                        _LogFilter.all => 'All',
                        _LogFilter.info => 'Info+',
                        _LogFilter.warn => 'Warn+',
                        _LogFilter.error => 'Error',
                      },
                      tone: f == _filter
                          ? NeonChipTone.accent
                          : NeonChipTone.neutral,
                      filled: f == _filter,
                    ),
                  ),
              ],
            ),
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: true,
          child: Container(
            decoration: BoxDecoration(
              color: Neon.bgC,
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.all(12),
            child: _visible.isEmpty
                ? const Center(
                    child: Text(
                      'No log entries.',
                      style: TextStyle(color: Neon.inkMuted, fontSize: 12.5),
                    ),
                  )
                : Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: ListView.builder(
                      controller: _scroll,
                      itemCount: _visible.length,
                      itemBuilder: (context, i) {
                        final e = _visible[i];
                        return _LogLine(entry: e);
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _LogLine extends StatelessWidget {
  final LogEntry entry;

  const _LogLine({required this.entry});

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.level) {
      LogLevel.debug => Neon.inkMuted,
      LogLevel.info => Neon.inkSoft,
      LogLevel.warn => Neon.warning,
      LogLevel.error => Neon.error,
    };
    final t = entry.timestamp;
    final time = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              time,
              style: const TextStyle(
                color: Neon.inkMuted,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          SizedBox(
            width: 54,
            child: Text(
              entry.level.name.toUpperCase(),
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              entry.category,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Neon.inkMuted,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(color: color, fontSize: 11.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
