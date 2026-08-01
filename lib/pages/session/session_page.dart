import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';

class SessionPage extends StatefulWidget {
  final AppServices services;

  const SessionPage({super.key, required this.services});

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  SessionLifecycle? _lifecycle;
  final List<SessionPhaseEvent> _events = [];
  final _appIdController = TextEditingController(text: '2460648703');
  final _regionController = TextEditingController(text: 'NP-AMS-08');

  @override
  void dispose() {
    _appIdController.dispose();
    _regionController.dispose();
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
    if (appId.isEmpty) return;
    setState(() => _events.clear());

    final token = await widget.services.auth.resolveJwtToken();
    await lifecycle.launch(SessionCreateRequest(
      token: token,
      appId: appId,
      internalTitle: '',
      zone: _regionController.text.trim(),
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

  @override
  Widget build(BuildContext context) {
    final lifecycle = _getLifecycle();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _appIdController,
          decoration: const InputDecoration(
            labelText: 'App ID (numeric)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _regionController,
          decoration: const InputDecoration(
            labelText: 'Zone (e.g. NP-AMS-08)',
            border: OutlineInputBorder(),
          ),
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