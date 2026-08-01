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
  Map<String, int?>? _pings;
  String? _error;
  bool _loading = false;
  bool _isPinging = false;
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
      await _pingZones();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pingZones() async {
    final queue = _queue;
    if (queue == null || _isPinging) return;
    setState(() => _isPinging = true);

    final zones = queue.zones.entries
        .where((e) => isStandardGfnZone(e.key))
        .where((e) => !_isNuked(e.key))
        .map((e) => StreamRegion(name: e.key, url: buildGfnZoneStreamingBaseUrl(e.key)))
        .toList();

    try {
      final results = await pingRegions(zones);
      if (!mounted) return;
      setState(() {
        _pings = {
          for (final r in results) r.url: r.pingMs,
        };
      });
    } catch (_) {
      // Ping failures are non-fatal.
    } finally {
      if (mounted) setState(() => _isPinging = false);
    }
  }

  bool _isNuked(String zoneId) {
    return _mapping?.servers[zoneId]?.nuked == true;
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Fetch queue + ping'),
              onPressed: _loading || _isPinging ? null : _load,
            ),
            const Spacer(),
            if (_isPinging)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
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
        if (_showRaw && queue != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert({
                'queue': queue.zones.map((k, v) => MapEntry(k, {
                      'QueuePosition': v.queuePosition,
                      'Last Updated': v.lastUpdated,
                      'Region': v.region,
                      'eta': v.etaMs,
                    })),
                'mapping': _mapping?.servers.map((k, v) => MapEntry(k, {
                      'title': v.displayName,
                      'value': v.value,
                      'is4080Server': v.is4080Server,
                      'is5080Server': v.is5080Server,
                      'nuked': v.nuked,
                    })),
              }),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        if (!_showRaw)
          ..._buildZoneCards(queue),
      ],
    );
  }

  List<Widget> _buildZoneCards(PrintedWasteQueueData? queue) {
    if (queue == null) return const [];
    final zones = queue.zones.entries
        .where((e) => isStandardGfnZone(e.key))
        .toList()
      ..sort((a, b) => (a.value.queuePosition ?? 9999).compareTo(b.value.queuePosition ?? 9999));

    final cards = <Widget>[];
    for (final entry in zones) {
      final zone = entry.value;
      final nuked = _isNuked(entry.key);
      if (nuked) continue;
      final routingUrl = buildGfnZoneStreamingBaseUrl(entry.key);
      final pingMs = _pings?[routingUrl];
      cards.add(Card(
        child: ListTile(
          leading: Icon(
            Icons.schedule,
            color: _queueColor(zone.queuePosition),
          ),
          title: Row(
            children: [
              Text(entry.key),
              const SizedBox(width: 8),
              Text(_regionFlag(zone.region)),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Queue: ${zone.queuePosition ?? "n/a"}'
                  ' · Region: ${zone.region ?? "n/a"}'),
              if (zone.etaMs != null)
                Text('ETA: ${_formatWait(zone.etaMs!)}'),
            ],
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                pingMs == null ? '-' : '$pingMs ms',
                style: TextStyle(
                  color: _pingColor(pingMs),
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text('ping', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ));
    }
    if (cards.isEmpty) {
      return const [Padding(
        padding: EdgeInsets.all(16),
        child: Text('No standard (NP-*) zones in queue data.'),
      )];
    }
    return cards;
  }

  String _formatWait(int etaMs) {
    final mins = (etaMs / 60000).ceil();
    if (mins < 60) return '~${mins}m';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m > 0 ? '~${h}h ${m}m' : '~${h}h';
  }

  String _regionFlag(String? region) {
    const flags = {
      'US': '🇺🇸',
      'EU': '🇪🇺',
      'JP': '🇯🇵',
      'KR': '🇰🇷',
      'CA': '🇨🇦',
      'THAI': '🇹🇭',
      'MY': '🇲🇾',
    };
    return flags[region] ?? region ?? '';
  }

  Color _pingColor(int? ms) {
    if (ms == null) return Colors.grey;
    if (ms < 30) return Colors.green;
    if (ms < 80) return Colors.lightGreen;
    if (ms < 150) return Colors.amber;
    return Colors.red;
  }

  Color _queueColor(int? q) {
    if (q == null) return Colors.grey;
    if (q <= 5) return Colors.green;
    if (q <= 15) return Colors.lightGreen;
    if (q <= 30) return Colors.amber;
    return Colors.red;
  }
}