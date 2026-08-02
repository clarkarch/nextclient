import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';

/// Streaming region selector (dynamic NVIDIA regions).
class RegionPage extends StatefulWidget {
  final AppServices services;

  const RegionPage({super.key, required this.services});

  @override
  State<RegionPage> createState() => _RegionPageState();
}

class _RegionPageState extends State<RegionPage> {
  List<StreamRegion>? _regions;
  String? _error;
  bool _loading = true;
  final Map<String, int> _pings = {};

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
      final session = await widget.services.auth.ensureValidSession();
      final token = session?.tokens.idToken ?? session?.tokens.accessToken;
      final result = await widget.services.subscription.fetchDynamicRegions(
        token: token,
        streamingBaseUrl: 'https://prod.cloudmatchbeta.nvidiagrid.net/',
      );
      if (!mounted) return;
      setState(() {
        _regions = result.regions;
        _loading = false;
      });
      widget.services.logSink.log(
        LogLevel.info,
        'region',
        'Loaded ${result.regions.length} regions',
      );
      await _ping(result.regions);
    } catch (e) {
      debugPrint('[region] load failed: $e');
      widget.services.logSink.log(LogLevel.error, 'region', 'Load failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _ping(List<StreamRegion> regions) async {
    if (regions.isEmpty) return;
    final results = await pingRegions(regions.take(12).toList());
    if (!mounted) return;
    setState(() {
      for (final r in results) {
        if (r.pingMs != null) _pings[r.url] = r.pingMs!;
      }
    });
  }

  Color _pingColor(int ms) {
    if (ms < 30) return Neon.success;
    if (ms < 80) return Neon.violet;
    if (ms < 150) return Neon.warning;
    return Neon.error;
  }

  @override
  Widget build(BuildContext context) {
    final regions = _regions;
    return NeonPageScaffold(
      title: 'Region',
      showBack: true,
      actions: [
        IconButton(
          tooltip: 'Re-measure latency',
          icon: const Icon(Icons.speed, size: 18, color: Neon.inkSoft),
          onPressed: _regions == null ? null : () => _load(),
        ),
      ],
      child: _loading && regions == null
          ? const NeonLoadingView(label: 'Loading regions')
          : _error != null && regions == null
              ? NeonErrorView(message: _error!, onRetry: _load)
              : NeonCard(
                  padding: EdgeInsets.zero,
                  child: regions == null || regions.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No regions available.',
                            style: TextStyle(color: Neon.inkMuted, fontSize: 13),
                          ),
                        )
                      : ListenableBuilder(
                          listenable: widget.services.settings,
                          builder: (context, _) {
                            final selected =
                                widget.services.settings.selectedRegionUrl;
                            return Column(
                              children: [
                                for (var i = 0; i < regions.length; i++) ...[
                                  if (i > 0) const Divider(height: 1),
                                  NeonSettingTile(
                                    icon: Icons.public,
                                    title: regions[i].name,
                                    subtitle: regions[i].url,
                                    onTap: () {
                                      widget.services.settings.selectedRegionUrl =
                                          regions[i].url;
                                    },
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_pings[regions[i].url] != null)
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(right: 10),
                                            child: Text(
                                              '${_pings[regions[i].url]}ms',
                                              style: TextStyle(
                                                color: _pingColor(
                                                    _pings[regions[i].url]!),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        regions[i].url == selected
                                            ? const Icon(
                                                Icons.check_circle,
                                                color: Neon.accent,
                                                size: 20,
                                              )
                                            : const Icon(
                                                Icons.circle_outlined,
                                                color: Neon.inkMuted,
                                                size: 20,
                                              ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                ),
    );
  }
}
