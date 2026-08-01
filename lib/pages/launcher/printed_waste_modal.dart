import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_chip.dart';

/// Free-tier queue-server picker powered by PrintedWaste community data.
///
/// Shows live queue positions + ETA per zone, ping, and flags nuked zones as
/// disabled. Returns the chosen zone's streaming base URL (or null to use
/// default routing) via `Navigator.pop`.
class PrintedWasteModal extends StatefulWidget {
  final AppServices services;
  final String gameTitle;
  final PrintedWasteQueueData initialQueue;

  const PrintedWasteModal({
    super.key,
    required this.services,
    required this.gameTitle,
    required this.initialQueue,
  });

  @override
  State<PrintedWasteModal> createState() => _PrintedWasteModalState();
}

class _ZoneView {
  final String zoneId;
  final PrintedWasteZoneData zone;
  final String routingUrl;
  final int? pingMs;
  final bool nuked;

  const _ZoneView({
    required this.zoneId,
    required this.zone,
    required this.routingUrl,
    this.pingMs,
    this.nuked = false,
  });
}

class _PrintedWasteModalState extends State<PrintedWasteModal> {
  Map<String, _ZoneView> _views = const {};
  String? _error;
  bool _loading = true;
  String? _selectedZoneId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final queue =
          await widget.services.printedWaste.fetchPrintedWasteQueue();
      var mapping = const PrintedWasteServerMapping(servers: {});
      try {
        mapping =
            await widget.services.printedWaste.fetchPrintedWasteServerMapping();
      } catch (_) {
        // Mapping is optional; without it nothing is nuked.
      }

      final views = <String, _ZoneView>{};
      for (final entry in queue.zones.entries) {
        if (!isStandardGfnZone(entry.key)) continue;
        final meta = mapping.servers[entry.key];
        views[entry.key] = _ZoneView(
          zoneId: entry.key,
          zone: entry.value,
          routingUrl: buildGfnZoneStreamingBaseUrl(entry.key),
          nuked: meta?.nuked == true,
        );
      }

      if (!mounted) return;
      setState(() {
        _views = views;
        _loading = false;
        _error = null;
      });

      await _ping();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load queue data: $e';
      });
    }
  }

  Future<void> _ping() async {
    final zones = _views.values.where((v) => !v.nuked).toList();
    if (zones.isEmpty) return;
    final regions = zones
        .map((v) => StreamRegion(name: v.zoneId, url: v.routingUrl))
        .toList();
    final results = await pingRegions(regions);
    if (!mounted) return;
    final byUrl = {for (final r in results) r.url: r.pingMs};
    setState(() {
      _views = {
        for (final e in _views.entries)
          e.key: _ZoneView(
            zoneId: e.value.zoneId,
            zone: e.value.zone,
            routingUrl: e.value.routingUrl,
            pingMs: byUrl[e.value.routingUrl],
            nuked: e.value.nuked,
          ),
      };
    });
  }

  String? get _autoZoneId {
    final eligible = _views.values.where((v) => !v.nuked).toList()
      ..sort((a, b) => (a.zone.queuePosition ?? 999)
          .compareTo(b.zone.queuePosition ?? 999));
    if (eligible.isEmpty) return null;
    return eligible.first.zoneId;
  }

  void _confirm() {
    final id = _selectedZoneId ?? _autoZoneId;
    final url = id == null ? null : _views[id]?.routingUrl;
    Navigator.of(context).pop(url);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            Flexible(
              child: _body(),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SELECT SERVER',
                  style: TextStyle(
                    color: Neon.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.gameTitle,
                  style: const TextStyle(
                    color: Neon.ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Free tier server queue',
                  style: TextStyle(color: Neon.inkMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Neon.inkMuted, size: 20),
            onPressed: () => Navigator.of(context).pop(null),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(
          child: CircularProgressIndicator(color: Neon.accent, strokeWidth: 2.5),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Neon.error, size: 30),
            const SizedBox(height: 10),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Neon.inkSoft, fontSize: 13),
            ),
            const SizedBox(height: 14),
            NeonOutlineButton(
              label: 'Retry',
              borderColor: Neon.accent,
              onPressed: _load,
            ),
          ],
        ),
      );
    }

    final eligible = _views.values.where((v) => !v.nuked).toList()
      ..sort((a, b) {
        final regionCompare = (a.zone.region ?? '')
            .compareTo(b.zone.region ?? '');
        if (regionCompare != 0) return regionCompare;
        return (a.zone.queuePosition ?? 999)
            .compareTo(b.zone.queuePosition ?? 999);
      });

    if (eligible.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Text(
            'No server data available.',
            style: TextStyle(color: Neon.inkMuted, fontSize: 13),
          ),
        ),
      );
    }

    final auto = _autoZoneId;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        if (auto != null) ...[
          _AutoCard(view: _views[auto]!, selected: _selectedZoneId == null),
          const SizedBox(height: 16),
        ],
        for (final view in eligible) ...[
          _ZoneRow(
            view: view,
            isAuto: view.zoneId == auto,
            selected: _selectedZoneId == view.zoneId,
            onTap: () => setState(() {
              _selectedZoneId =
                  _selectedZoneId == view.zoneId ? null : view.zoneId;
            }),
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(null),
            child: const Text(
              'Powered by PrintedWaste',
              style: TextStyle(color: Neon.inkMuted, fontSize: 11),
            ),
          ),
          Row(
            children: [
              NeonOutlineButton(
                label: 'Cancel',
                borderColor: Neon.inkMuted,
                onPressed: () => Navigator.of(context).pop(null),
              ),
              const SizedBox(width: 10),
              NeonButton(
                label: 'Launch',
                icon: Icons.rocket_launch,
                onPressed: _loading ? null : _confirm,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AutoCard extends StatelessWidget {
  final _ZoneView view;
  final bool selected;

  const _AutoCard({required this.view, required this.selected});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: null,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0x2200D9FF), Color(0x1A8B5CF6)],
                )
              : null,
          color: selected ? null : Neon.bgC,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Neon.accent : const Color(0x22FFFFFF),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.bolt, color: Neon.accent, size: 20),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AUTO SELECTED',
                    style: TextStyle(
                      color: Neon.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Best ping + queue balance',
                    style: TextStyle(color: Neon.inkMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            NeonChip(
              label: '${view.zone.queuePosition}',
              tone: _queueTone(view.zone.queuePosition ?? 999),
            ),
            if (view.pingMs != null) ...[
              const SizedBox(width: 8),
              NeonChip(
                label: '${view.pingMs}ms',
                tone: _pingTone(view.pingMs!),
              ),
            ],
          ],
        ),
      ),
    );
  }

  NeonChipTone _queueTone(int q) {
    if (q <= 5) return NeonChipTone.success;
    if (q <= 15) return NeonChipTone.violet;
    if (q <= 30) return NeonChipTone.warning;
    return NeonChipTone.error;
  }

  NeonChipTone _pingTone(int ms) {
    if (ms < 30) return NeonChipTone.success;
    if (ms < 80) return NeonChipTone.violet;
    if (ms < 150) return NeonChipTone.warning;
    return NeonChipTone.error;
  }
}

class _ZoneRow extends StatelessWidget {
  final _ZoneView view;
  final bool isAuto;
  final bool selected;
  final VoidCallback onTap;

  const _ZoneRow({
    required this.view,
    required this.isAuto,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final q = view.zone.queuePosition ?? 999;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0x1100D9FF) : Neon.bgC,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? Neon.accent : const Color(0x18FFFFFF),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? Neon.accent : Colors.transparent,
                border: Border.all(
                  color: selected ? Neon.accent : const Color(0x44FFFFFF),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              view.zoneId,
              style: const TextStyle(
                color: Neon.ink,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (isAuto) ...[
              const SizedBox(width: 6),
              const Text(
                'AUTO',
                style: TextStyle(
                  color: Neon.accent,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ],
            const Spacer(),
            if (view.pingMs != null)
              Text(
                '${view.pingMs}ms',
                style: TextStyle(
                  color: _pingColor(view.pingMs!),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            const SizedBox(width: 12),
            Text(
              'Q:$q',
              style: TextStyle(
                color: _queueColor(q),
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 44,
              child: Text(
                _formatWait(view.zone.etaMs),
                textAlign: TextAlign.right,
                style: const TextStyle(color: Neon.inkMuted, fontSize: 11.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _queueColor(int q) {
    if (q <= 5) return Neon.success;
    if (q <= 15) return Neon.violet;
    if (q <= 30) return Neon.warning;
    return Neon.error;
  }

  Color _pingColor(int ms) {
    if (ms < 30) return Neon.success;
    if (ms < 80) return Neon.violet;
    if (ms < 150) return Neon.warning;
    return Neon.error;
  }

  String _formatWait(int? etaMs) {
    if (etaMs == null) return '--';
    final mins = (etaMs / 60000).ceil();
    if (mins < 60) return '~${mins}m';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m > 0 ? '~${h}h ${m}m' : '~${h}h';
  }
}
