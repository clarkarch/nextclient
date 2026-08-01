import 'dart:convert' show JsonEncoder;

import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';

class QueuePage extends StatefulWidget {
  final AppServices services;

  const QueuePage({super.key, required this.services});

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  PrintedWasteQueueData? _queue;
  PrintedWasteServerMapping? _mapping;
  String? _error;
  bool _loading = false;
  bool _showRaw = false;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.services.printedWaste.fetchPrintedWasteQueue(),
        widget.services.printedWaste.fetchPrintedWasteServerMapping(),
      ]);
      if (!mounted) return;
      setState(() {
        _queue = results[0] as PrintedWasteQueueData;
        _mapping = results[1] as PrintedWasteServerMapping;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Fetch PrintedWaste'),
              onPressed: _loading ? null : _load,
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _showRaw = !_showRaw),
              child: Text(_showRaw ? 'Show parsed' : 'Show raw JSON'),
            ),
          ],
        ),
        if (_loading) const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        if (_showRaw && _queue != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert({
                'queue': _queue!.zones.map((k, v) => MapEntry(k, {
                      'QueuePosition': v.queuePosition,
                      'Last Updated': v.lastUpdated,
                      'Region': v.region,
                      'eta': v.etaMs,
                    })),
                'mapping': _mapping?.servers.map((k, v) => MapEntry(k, {
                      'key': v.key,
                      'value': v.value,
                      'displayName': v.displayName,
                      'is4080Server': v.is4080Server,
                      'is5080Server': v.is5080Server,
                      'nuked': v.nuked,
                    })),
              }),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        if (!_showRaw) ...[
          if (_queue != null)
            ..._queue!.zones.entries.map((entry) => ListTile(
                  leading: const Icon(Icons.schedule),
                  title: Text(entry.key),
                  subtitle: Text(
                    'Queue: ${entry.value.queuePosition ?? "n/a"} | '
                    'Region: ${entry.value.region ?? "n/a"} | '
                    'ETA: ${entry.value.etaMs != null ? "${(entry.value.etaMs! / 1000).floor()}s" : "n/a"}',
                  ),
                )),
          if (_mapping != null)
            ..._mapping!.servers.entries.take(50).map((entry) => ListTile(
                  leading: Icon(
                    Icons.dns,
                    color: entry.value.nuked == true ? Colors.red : null,
                  ),
                  title: Text(entry.key),
                  subtitle: Text(
                    '${entry.value.displayName ?? entry.value.value ?? ""}'
                    '${entry.value.is4080Server == true ? " [RTX 4080]" : ""}'
                    '${entry.value.is5080Server == true ? " [RTX 5080]" : ""}'
                    '${entry.value.nuked == true ? " [NUKED]" : ""}',
                  ),
                )),
        ],
      ],
    );
  }
}