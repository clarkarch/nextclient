import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';

class SessionPage extends StatefulWidget {
  final AppServices services;
  final CatalogGame? initialGame;

  const SessionPage({
    super.key,
    required this.services,
    this.initialGame,
  });

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  SessionLifecycle? _lifecycle;
  final List<SessionPhaseEvent> _events = [];
  late final TextEditingController _appIdController;
  List<StreamRegion>? _regions;
  String? _selectedRegionUrl;
  String? _regionsError;
  bool _loadingRegions = false;
  List<ActiveSessionInfo>? _activeSessions;
  bool _loadingActive = false;
  String? _activeError;

  @override
  void initState() {
    super.initState();
    _appIdController = TextEditingController(
      text: widget.initialGame?.launchAppId ?? '',
    );
    _loadRegions();
    _refreshActiveSessions();
  }

  Future<void> _loadRegions() async {
    setState(() {
      _loadingRegions = true;
      _regionsError = null;
    });
    try {
      final session = await widget.services.auth.ensureValidSession();
      final token = session?.tokens.idToken ?? session?.tokens.accessToken;
      final result = await widget.services.subscription.fetchDynamicRegions(
        token: token,
        streamingBaseUrl: session?.provider.streamingServiceUrl ?? '',
      );
      if (!mounted) return;
      setState(() {
        _regions = result.regions;
        _loadingRegions = false;
        // Default to first region if none selected.
        if (_selectedRegionUrl == null && result.regions.isNotEmpty) {
          _selectedRegionUrl = result.regions.first.url;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingRegions = false;
        _regionsError = 'Could not load regions: $e';
      });
    }
  }

  @override
  void dispose() {
    _appIdController.dispose();
    super.dispose();
  }

  SessionLifecycle _getLifecycle() {
    var lc = _lifecycle;
    if (lc != null) return lc;
    lc = SessionLifecycle(
      cloudMatch: widget.services.cloudMatch,
      getToken: () async {
        return widget.services.auth.resolveJwtToken();
      },
      onTransition: (event) {
        if (!mounted) return;
        setState(() => _events.add(event));
      },
    );
    _lifecycle = lc;
    return lc;
  }

  Future<void> _launch() async {
    final lifecycle = _getLifecycle();
    final appId = _appIdController.text.trim();
    if (appId.isEmpty) {
      _showError('Enter a numeric app ID (pick a game from Catalog, or use the '
          'appId shown there).');
      return;
    }
    final regionUrl = _selectedRegionUrl;
    if (regionUrl == null || regionUrl.isEmpty) {
      _showError('Select a region first (list loads automatically; if empty, '
          'check the log for the regions request).');
      return;
    }
    setState(() => _events.clear());

    final token = await widget.services.auth.resolveJwtToken();
    await lifecycle.launch(SessionCreateRequest(
      token: token,
      appId: appId,
      internalTitle: '',
      zone: 'prod',
      streamingBaseUrl: regionUrl,
      settings: _defaultSettings(),
    ));
  }

  StreamSettings _defaultSettings() {
    return StreamSettings(
      resolution: '1920x1080',
      fps: 60,
      maxBitrateMbps: 50,
      codec: VideoCodec.h264,
      colorQuality: const ColorQuality(bitDepth: 0, chromaFormat: 0),
      keyboardLayout: KeyboardLayout.enUs,
      gameLanguage: GameLanguage.enUS,
      enableL4S: false,
      enableCloudGsync: false,
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _refreshActiveSessions() async {
    final streamingBaseUrl = _selectedRegionUrl;
    if (streamingBaseUrl == null || streamingBaseUrl.isEmpty) return;
    setState(() {
      _loadingActive = true;
      _activeError = null;
    });
    try {
      final session = await widget.services.auth.ensureValidSession();
      final token = session?.tokens.idToken ?? session?.tokens.accessToken;
      final active = await widget.services.cloudMatch.getActiveSessions(
        token: token ?? '',
        streamingBaseUrl: streamingBaseUrl,
      );
      if (!mounted) return;
      setState(() {
        _activeSessions = active;
        _loadingActive = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingActive = false;
        _activeError = 'Could not list active sessions: $e';
      });
    }
  }

  Future<void> _stopActiveSession(ActiveSessionInfo info) async {
    final streamingBaseUrl = _selectedRegionUrl;
    if (streamingBaseUrl == null || streamingBaseUrl.isEmpty) {
      _showError('Select a region first.');
      return;
    }
    try {
      final session = await widget.services.auth.ensureValidSession();
      final token = session?.tokens.idToken ?? session?.tokens.accessToken;
      await widget.services.cloudMatch.stopSession(SessionStopRequest(
        sessionId: info.sessionId,
        token: token,
        streamingBaseUrl: streamingBaseUrl,
        zone: 'prod',
      ));
      _showError('Stopped session ${info.sessionId}');
      await _refreshActiveSessions();
    } catch (e) {
      _showError('Failed to stop session: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final lifecycle = _getLifecycle();
    final initial = widget.initialGame;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
          if (initial != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(initial.title,
                        style: Theme.of(context).textTheme.titleMedium),
                    Text('appId: ${initial.launchAppId ?? "n/a"}'),
                    Text('in library: ${initial.isInLibrary}'),
                  ],
                ),
              ),
            ),
          TextField(
            controller: _appIdController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'App ID (numeric)',
              helperText: 'Pick a game in Catalog and tap play, or enter its appId',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text('Region:'),
          if (_loadingRegions)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Loading regions...'),
                ],
              ),
            )
          else if (_regionsError != null)
            Row(
              children: [
                Expanded(
                  child: Text(_regionsError!,
                      style: const TextStyle(color: Colors.orange)),
                ),
                TextButton(onPressed: _loadRegions, child: const Text('Retry')),
              ],
            )
          else if (_regions == null || _regions!.isEmpty)
            const Text('No regions returned (check log for the serverInfo request)')
          else
            DropdownButtonFormField<String>(
              initialValue: _selectedRegionUrl,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: _regions!
                  .map((r) => DropdownMenuItem(
                        value: r.url,
                        child: Text('${r.name} · $r.url'),
                      ))
                  .toList(),
              onChanged: (v) => setState(() {
                _selectedRegionUrl = v;
                _activeSessions = null;
                _refreshActiveSessions();
              }),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Launch'),
                onPressed: _launch,
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
                onPressed: () => _getLifecycle().stop(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _StateCard(state: lifecycle.state),
          const SizedBox(height: 8),
          if (lifecycle.lastError != null)
            Card(
              color: Colors.red.withValues(alpha: 0.1),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  lifecycle.lastError!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text('Transitions (${_events.length})',
              style: Theme.of(context).textTheme.titleMedium),
          ..._events.map((event) => ListTile(
                dense: true,
                leading: Text(_stateLabel(event.from)),
                title: Text('${_stateLabel(event.from)} -> ${_stateLabel(event.to)}'),
                subtitle: Text(event.message),
              )),
          const SizedBox(height: 16),
          _ActiveSessionsCard(
            sessions: _activeSessions,
            loading: _loadingActive,
            error: _activeError,
            onRefresh: _refreshActiveSessions,
            onStop: _stopActiveSession,
          ),
      ],
    );
  }

  String _stateLabel(SessionState state) => switch (state) {
        SessionState.idle => 'idle',
        SessionState.requesting => 'requesting',
        SessionState.queued => 'queued',
        SessionState.allocating => 'allocating',
        SessionState.ready => 'ready',
        SessionState.error => 'error',
      };
}

class _StateCard extends StatelessWidget {
  final SessionState state;

  const _StateCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      SessionState.idle => Colors.blueGrey,
      SessionState.requesting => Colors.amber,
      SessionState.queued => Colors.orange,
      SessionState.allocating => Colors.deepPurple,
      SessionState.ready => Colors.green,
      SessionState.error => Colors.red,
    };
    return Card(
      color: color.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.circle, size: 12, color: color),
            const SizedBox(width: 8),
            Text(state.name.toUpperCase(),
                style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class _ActiveSessionsCard extends StatelessWidget {
  final List<ActiveSessionInfo>? sessions;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final Future<void> Function(ActiveSessionInfo) onStop;

  const _ActiveSessionsCard({
    required this.sessions,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Active sessions',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                TextButton(onPressed: onRefresh, child: const Text('Refresh')),
              ],
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.orange)),
            if (sessions == null && !loading && error == null)
              const Text('Select a region and hit Refresh to list sessions.'),
            if (sessions != null && sessions!.isEmpty)
              const Text('No active sessions.'),
            ...?sessions?.map((s) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.play_circle),
                  title: Text('appId ${s.appId}'),
                  subtitle: Text(
                    '${s.gpuType ?? "gpu?"} · status ${s.status} · '
                    '${s.sessionId}\n'
                    'queue ${s.queuePosition ?? "-"} · seat ${s.seatSetupStep ?? "-"}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.stop_circle_outlined),
                    tooltip: 'Stop session',
                    onPressed: () => onStop(s),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}