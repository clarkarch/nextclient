import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../state/session_controller.dart';
import '../../theme/neon.dart';
import '../../widgets/game_art.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_loading.dart';

/// Full-screen streaming surface. Drives the [SessionController] lifecycle
/// (requesting → queued → allocating → ready) then shows the session-ready
/// state. No video render yet (gfn_core v0.01).
class StreamPage extends StatefulWidget {
  final AppServices services;
  final CatalogGame game;
  final SessionCreateRequest request;

  const StreamPage({
    super.key,
    required this.services,
    required this.game,
    required this.request,
  });

  @override
  State<StreamPage> createState() => _StreamPageState();
}

class _StreamPageState extends State<StreamPage> {
  bool _launchStarted = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (_launchStarted) return;
    _launchStarted = true;
    try {
      final token = await widget.services.auth.resolveJwtToken();
      final request = SessionCreateRequest(
        token: token,
        streamingBaseUrl: widget.request.streamingBaseUrl,
        appId: widget.request.appId,
        internalTitle: widget.request.internalTitle,
        accountLinked: widget.request.accountLinked,
        enablePersistingInGameSettings:
            widget.request.enablePersistingInGameSettings,
        supportsInGameSettingsPersistence:
            widget.request.supportsInGameSettingsPersistence,
        zone: widget.request.zone,
        settings: widget.request.settings,
        proxyUrl: widget.request.proxyUrl,
      );
      await widget.services.session.launch(request);
    } catch (e) {
      debugPrint('Launch failed: $e');
    }
  }

  Future<void> _stopAndExit() async {
    await widget.services.session.stop();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bgA,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.3,
            colors: [Color(0x1F00D9FF), Color(0x00000000)],
          ),
        ),
        child: SafeArea(
          child: ListenableBuilder(
            listenable: widget.services.session,
            builder: (context, _) {
              final controller = widget.services.session;
              return Column(
                children: [
                  _topBar(controller),
                  Expanded(
                    child: Center(
                      child: _surface(controller),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _topBar(SessionController controller) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Text(
            'NEXTCLIENT',
            style: const TextStyle(
              color: Neon.ink,
              fontSize: 14,
              fontWeight: FontWeight.w900,
              letterSpacing: 3,
            ),
          ),
          const Spacer(),
          NeonOutlineButton(
            label: 'Exit',
            icon: Icons.close,
            borderColor: Neon.inkMuted,
            onPressed: _stopAndExit,
          ),
        ],
      ),
    );
  }

  Widget _surface(SessionController controller) {
    final state = controller.state;
    if (state == SessionState.ready && controller.session != null) {
      return _ReadySurface(
        game: widget.game,
        session: controller.session!,
        onStop: _stopAndExit,
      );
    }
    if (state == SessionState.error) {
      return _ErrorSurface(
        message: controller.lastError ?? 'Unknown error',
        onRetry: () async {
          controller.reset();
          setState(() => _launchStarted = false);
          await _start();
        },
        onExit: _stopAndExit,
      );
    }
    return _ProgressSurface(
      game: widget.game,
      state: state,
      queuePosition: controller.session?.queuePosition,
    );
  }
}

class _ProgressSurface extends StatelessWidget {
  final CatalogGame game;
  final SessionState state;
  final int? queuePosition;

  const _ProgressSurface({
    required this.game,
    required this.state,
    this.queuePosition,
  });

  String get _statusText => switch (state) {
        SessionState.requesting => 'REQUESTING SESSION',
        SessionState.queued => queuePosition != null && queuePosition! > 1
            ? 'QUEUED · POSITION $queuePosition'
            : 'QUEUED',
        SessionState.allocating => 'ALLOCATING SERVER',
        SessionState.idle => 'PREPARING',
        _ => state.name.toUpperCase(),
      };

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 240,
            child: GameArt(
              imageUrl: game.imageUrl,
              label: game.title,
              borderRadius: const BorderRadius.all(Radius.circular(18)),
              overlay: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: Neon.scrim,
                  borderRadius: const BorderRadius.all(Radius.circular(18)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          const NeonSpinner(size: 40),
          const SizedBox(height: 20),
          Text(
            game.title,
            style: const TextStyle(
              color: Neon.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _statusText,
            style: const TextStyle(
              color: Neon.accent,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadySurface extends StatelessWidget {
  final CatalogGame game;
  final SessionInfo session;
  final VoidCallback onStop;

  const _ReadySurface({
    required this.game,
    required this.session,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 320,
            child: GameArt(
              imageUrl: game.imageUrl,
              label: game.title,
              borderRadius: const BorderRadius.all(Radius.circular(20)),
              overlay: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: Neon.scrim,
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const StatusDot(
            color: Neon.success,
            label: 'SESSION READY',
            pulse: true,
          ),
          const SizedBox(height: 16),
          Text(
            game.title,
            style: const TextStyle(
              color: Neon.ink,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              NeonChip(
                label: session.gpuType ?? 'GPU',
                tone: NeonChipTone.violet,
              ),
              NeonChip(label: session.serverIp),
              NeonChip(
                label: 'session ${_short(session.sessionId)}',
                tone: NeonChipTone.neutral,
              ),
              if (session.signalingUrl.isNotEmpty)
                NeonChip(label: 'signaling ready', tone: NeonChipTone.success),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Video rendering is not wired yet (gfn_core v0.01)',
            style: const TextStyle(color: Neon.inkMuted, fontSize: 12),
          ),
          const SizedBox(height: 28),
          NeonButton(
            label: 'Stop session',
            icon: Icons.stop,
            onPressed: onStop,
          ),
        ],
      ),
    );
  }

  String _short(String id) =>
      id.length > 8 ? '${id.substring(0, 8)}…' : id;
}

class _ErrorSurface extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onExit;

  const _ErrorSurface({
    required this.message,
    required this.onRetry,
    required this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 40, color: Neon.error),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Neon.inkSoft, fontSize: 13),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NeonOutlineButton(
              label: 'Exit',
              borderColor: Neon.inkMuted,
              onPressed: onExit,
            ),
            const SizedBox(width: 10),
            NeonButton(
              label: 'Retry',
              icon: Icons.refresh,
              onPressed: onRetry,
            ),
          ],
        ),
      ],
    );
  }
}
