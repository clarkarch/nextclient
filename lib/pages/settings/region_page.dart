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
    final regions = _regions;
    return NeonPageScaffold(
      title: 'Region',
      showBack: true,
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
                                    trailing: regions[i].url == selected
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
