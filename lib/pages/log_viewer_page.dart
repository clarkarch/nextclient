import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gfn_core/gfn_core.dart';

import '../theme/neon.dart';
import '../widgets/neon_chip.dart';
import '../widgets/neon_page_scaffold.dart';
import '../widgets/neon_snackbar.dart';

/// Live view over the in-memory [RingBufferLogSink] inside a
/// [CompositeLogSink] (which also fans logs out to the terminal and a file).
class LogViewerPage extends StatefulWidget {
  final CompositeLogSink logSink;
  final String? logFilePath;

  const LogViewerPage({super.key, required this.logSink, this.logFilePath});

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
    _timer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => _refresh(),
    );
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
      _LogFilter.info =>
        _entries.where((e) => e.level.index >= LogLevel.info.index).toList(),
      _LogFilter.warn =>
        _entries.where((e) => e.level.index >= LogLevel.warn.index).toList(),
      _LogFilter.error =>
        _entries.where((e) => e.level == LogLevel.error).toList(),
    };
  }

  static String _format(LogEntry e) {
    final t = e.timestamp;
    final time =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    return '[$time] [${e.level.name.toUpperCase()}] [${e.category}] ${e.message}';
  }

  void _copyVisible() {
    final visible = _visible;
    if (visible.isEmpty) return;
    final text = visible.map(_format).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    showNeonSnackbar(
      context,
      'Copied ${visible.length} log line${visible.length == 1 ? '' : 's'}',
      copyable: false,
    );
  }

  void _copyPath() {
    final path = widget.logFilePath;
    if (path == null) return;
    Clipboard.setData(ClipboardData(text: path));
    showNeonSnackbar(
      context,
      'Log file path copied',
      copyable: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Logs',
      showBack: true,
      actions: [
        IconButton(
          tooltip: 'Copy visible logs',
          icon: const Icon(Icons.copy_all, size: 18, color: Neon.inkSoft),
          onPressed: _copyVisible,
        ),
        IconButton(
          tooltip: 'Follow scroll',
          icon: Icon(
            _stickToBottom
                ? Icons.vertical_align_bottom
                : Icons.vertical_align_center,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.logFilePath != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x0FFFFFFF),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x22FFFFFF)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.description_outlined,
                            size: 15, color: Neon.inkSoft),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.logFilePath!,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Neon.inkSoft,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () => _copyPath(),
                          child: const Icon(Icons.copy,
                              size: 14, color: Neon.inkMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                if (!widget.logSink.enabled) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Neon.warning.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Neon.warning.withValues(alpha: 0.35),
                      ),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.warning_amber,
                            size: 15, color: Neon.warning),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Verbose logging is off — enable it in Settings → '
                            'Performance before reproducing an issue.',
                            style: TextStyle(
                              color: Neon.warning,
                              fontSize: 11.5,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Wrap(
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
              boxShadow: Neon.softShadow(radius: 14),
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

class _LogLine extends StatefulWidget {
  final LogEntry entry;

  const _LogLine({required this.entry});

  @override
  State<_LogLine> createState() => _LogLineState();
}

class _LogLineState extends State<_LogLine> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final color = switch (entry.level) {
      LogLevel.debug => Neon.inkMuted,
      LogLevel.info => Neon.inkSoft,
      LogLevel.warn => Neon.warning,
      LogLevel.error => Neon.error,
    };
    final t = entry.timestamp;
    final time =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
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
            SizedBox(
              width: 20,
              child: _hover
                  ? InkWell(
                      onTap: () {
                        Clipboard.setData(
                          ClipboardData(
                            text: _LogViewerPageState._format(entry),
                          ),
                        );
                        showNeonSnackbar(
                          context,
                          'Log line copied',
                          copyable: false,
                        );
                      },
                      child: const Icon(
                        Icons.copy,
                        size: 13,
                        color: Neon.inkMuted,
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
