import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:gfn_core/gfn_core.dart';

class LogViewerPage extends StatefulWidget {
  final RingBufferLogSink logSink;

  const LogViewerPage({super.key, required this.logSink});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  LogLevel? _filter;

  @override
  Widget build(BuildContext context) {
    final entries = widget.logSink.entries
        .where((e) => _filter == null || e.level.index >= _filter!.index)
        .toList()
        .reversed
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Log Viewer'),
        actions: [
          PopupMenuButton<LogLevel?>(
            initialValue: _filter,
            onSelected: (v) => setState(() => _filter = v),
            itemBuilder: (_) => [
              const PopupMenuItem<LogLevel?>(value: null, child: Text('All')),
              PopupMenuItem<LogLevel?>(
                value: LogLevel.debug,
                child: Text('Debug+ (${_levelLabel(LogLevel.debug)})'),
              ),
              PopupMenuItem<LogLevel?>(
                value: LogLevel.info,
                child: Text('Info+ (${_levelLabel(LogLevel.info)})'),
              ),
              PopupMenuItem<LogLevel?>(
                value: LogLevel.warn,
                child: Text('Warn+ (${_levelLabel(LogLevel.warn)})'),
              ),
              PopupMenuItem<LogLevel?>(
                value: LogLevel.error,
                child: Text('Error (${_levelLabel(LogLevel.error)})'),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy all',
            onPressed: _copyAll,
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(child: Text('No log entries'))
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final entry = entries[i];
                return ListTile(
                  dense: true,
                  leading: _LevelBadge(level: entry.level),
                  title: Text(
                    entry.message,
                    style: const TextStyle(fontSize: 12),
                  ),
                  subtitle: Text(
                    '${_formatTime(entry.timestamp)} [${entry.category}]',
                    style: const TextStyle(fontSize: 11),
                  ),
                );
              },
            ),
    );
  }

  void _copyAll() {
    final text = widget.logSink.entries
        .map((e) =>
            '${_formatTime(e.timestamp)} ${_levelLabel(e.level)} [${e.category}] ${e.message}')
        .join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Log copied to clipboard')),
    );
  }

  String _levelLabel(LogLevel level) => level.name.toUpperCase();

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}

class _LevelBadge extends StatelessWidget {
  final LogLevel level;

  const _LevelBadge({required this.level});

  @override
  Widget build(BuildContext context) {
    final color = switch (level) {
      LogLevel.debug => Colors.blueGrey,
      LogLevel.info => Colors.lightBlue,
      LogLevel.warn => Colors.orange,
      LogLevel.error => Colors.red,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        level.name.toUpperCase(),
        style: TextStyle(fontSize: 9, color: color),
      ),
    );
  }
}