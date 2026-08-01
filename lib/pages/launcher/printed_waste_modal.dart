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
  bool _pinging = false;
  String? _selectedZoneId;

  bool get _refreshing => _loading || _pinging;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
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
    setState(() => _pinging = true);
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
      _pinging = false;
    });
  }

  List<_ZoneView> get _eligible => _views.values.where((v) => !v.nuked).toList();

  /// Lowest queue position among eligible zones (the auto default).
  _ZoneView? get _lowestQueue {
    final eligible = _eligible;
    if (eligible.isEmpty) return null;
    eligible.sort((a, b) => (a.zone.queuePosition ?? 999)
        .compareTo(b.zone.queuePosition ?? 999));
    return eligible.first;
  }

  /// Lowest ping among eligible zones with a measured ping.
  _ZoneView? get _lowestPing {
    final withPing = _eligible.where((v) => v.pingMs != null).toList();
    if (withPing.isEmpty) return null;
    withPing.sort((a, b) => a.pingMs!.compareTo(b.pingMs!));
    return withPing.first;
  }

  String? get _autoZoneId => _lowestQueue?.zoneId;

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
          _ReloadButton(
            spinning: _refreshing,
            onPressed: _refreshing ? null : _load,
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

    final auto = _lowestQueue;
    final lowestPing = _lowestPing;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        if (auto != null) ...[
          Row(
            children: [
              Expanded(
                child: _RecommendCard(
                  icon: Icons.bolt,
                  title: 'Lowest Queue',
                  subtitle: 'Best ping + queue balance',
                  view: auto,
                  selected: _selectedZoneId == null ||
                      _selectedZoneId == auto.zoneId,
                  onTap: () => setState(() => _selectedZoneId = null),
                ),
              ),
              if (lowestPing != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _RecommendCard(
                    icon: Icons.speed,
                    title: 'Lowest Ping',
                    subtitle: 'Lowest latency to you',
                    view: lowestPing,
                    selected: _selectedZoneId == lowestPing.zoneId,
                    onTap: () => setState(
                        () => _selectedZoneId = lowestPing.zoneId),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
        ],
        for (final view in eligible) ...[
          _ZoneRow(
            view: view,
            isAuto: auto != null && view.zoneId == auto.zoneId,
            isLowestPing:
                lowestPing != null && view.zoneId == lowestPing.zoneId,
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
                onPressed: _refreshing ? null : _confirm,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecommendCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final _ZoneView view;
  final bool selected;
  final VoidCallback onTap;

  const _RecommendCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.view,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0x2200D9FF), Color(0x1400A8CC)],
                )
              : null,
          color: selected ? null : Neon.bgC,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Neon.accent : const Color(0x22FFFFFF),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Neon.accent, size: 16),
                const SizedBox(width: 6),
                Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    color: Neon.accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              view.zoneId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Neon.ink,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (view.pingMs != null)
                  NeonChip(
                    label: '${view.pingMs}ms',
                    tone: _pingTone(view.pingMs!),
                  ),
                NeonChip(
                  label: 'Q${view.zone.queuePosition ?? '--'}',
                  tone: _queueTone(view.zone.queuePosition ?? 999),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Neon.inkMuted, fontSize: 10.5),
            ),
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

/// Refresh icon that spins while the queue/ping data is being fetched.
class _ReloadButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final bool spinning;

  const _ReloadButton({this.onPressed, this.spinning = false});

  @override
  State<_ReloadButton> createState() => _ReloadButtonState();
}

class _ReloadButtonState extends State<_ReloadButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _ReloadButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spinning && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.spinning && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Reload queue data',
      icon: RotationTransition(
        turns: _controller,
        child: Icon(
          Icons.refresh,
          color: widget.spinning ? Neon.accent : Neon.inkMuted,
          size: 20,
        ),
      ),
      onPressed: widget.onPressed,
    );
  }
}

class _ZoneRow extends StatelessWidget {
  final _ZoneView view;
  final bool isAuto;
  final bool isLowestPing;
  final bool selected;
  final VoidCallback onTap;

  const _ZoneRow({
    required this.view,
    required this.isAuto,
    required this.isLowestPing,
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
                'QUEUE',
                style: TextStyle(
                  color: Neon.accent,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ],
            if (isLowestPing && !isAuto) ...[
              const SizedBox(width: 6),
              const Text(
                'PING',
                style: TextStyle(
                  color: Neon.violet,
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
