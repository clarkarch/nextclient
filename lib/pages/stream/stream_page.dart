import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../state/session_controller.dart';
import '../../theme/neon.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/game_art.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_snackbar.dart';

/// Full-screen streaming surface. Drives the [SessionController] lifecycle
/// (requesting → queued → allocating → ready) then shows the session-ready
/// state. No video render yet (gfn_core v0.01). With [resumeClaim], an
/// existing session is claimed/resumed instead of creating a new one.
class StreamPage extends StatefulWidget {
  final AppServices services;
  final CatalogGame game;
  final SessionCreateRequest? request;
  final SessionClaimRequest? resumeClaim;

  const StreamPage({
    super.key,
    required this.services,
    required this.game,
    this.request,
    this.resumeClaim,
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
      final resume = widget.resumeClaim;
      if (resume != null) {
        await widget.services.session.resume(SessionClaimRequest(
          token: token,
          streamingBaseUrl: resume.streamingBaseUrl,
          sessionId: resume.sessionId,
          serverIp: resume.serverIp,
          appId: resume.appId,
          appLaunchMode: resume.appLaunchMode,
          enablePersistingInGameSettings:
              resume.enablePersistingInGameSettings,
          settings: resume.settings ??
              widget.services.settings.buildStreamSettings(),
        ));
        return;
      }
      final request = widget.request;
      if (request == null) return;
      final built = SessionCreateRequest(
        token: token,
        streamingBaseUrl: request.streamingBaseUrl,
        appId: request.appId,
        internalTitle: request.internalTitle,
        accountLinked: request.accountLinked,
        enablePersistingInGameSettings:
            request.enablePersistingInGameSettings,
        supportsInGameSettingsPersistence:
            request.supportsInGameSettingsPersistence,
        zone: request.zone,
        settings: request.settings,
        proxyUrl: request.proxyUrl,
      );
      await widget.services.session.launch(built);
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
        message: friendlyError(controller.lastError ?? 'Unknown error'),
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
      session: controller.session,
      events: controller.events,
    );
  }
}

class _ProgressSurface extends StatefulWidget {
  final CatalogGame game;
  final SessionState state;
  final SessionInfo? session;
  final List<SessionPhaseEvent> events;

  const _ProgressSurface({
    super.key,
    required this.game,
    required this.state,
    this.session,
    this.events = const [],
  });

  @override
  State<_ProgressSurface> createState() => _ProgressSurfaceState();
}

class _ProgressSurfaceState extends State<_ProgressSurface> {
  bool _showLogs = false;

  String get _statusText => switch (widget.state) {
        SessionState.requesting => 'REQUESTING SESSION',
        SessionState.queued => 'QUEUED',
        SessionState.allocating => 'ALLOCATING SERVER',
        SessionState.idle => 'PREPARING',
        _ => widget.state.name.toUpperCase(),
      };

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 200,
              child: GameArt(
                imageUrl: widget.game.imageUrl,
                label: widget.game.title,
                borderRadius: const BorderRadius.all(Radius.circular(18)),
                overlay: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: Neon.scrim,
                    borderRadius: const BorderRadius.all(Radius.circular(18)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            const NeonSpinner(size: 34),
            const SizedBox(height: 16),
            Text(
              widget.game.title,
              style: const TextStyle(
                color: Neon.ink,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            NeonChip(
              label: _statusText,
              tone: widget.state == SessionState.queued
                  ? NeonChipTone.warning
                  : widget.state == SessionState.allocating
                      ? NeonChipTone.violet
                      : NeonChipTone.accent,
            ),
            if (widget.state == SessionState.queued && s?.queuePosition != null) ...[
              const SizedBox(height: 24),
              const Text(
                'QUEUE POSITION',
                style: TextStyle(
                  color: Neon.inkMuted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '#${s!.queuePosition}',
                style: const TextStyle(
                  color: Neon.accent,
                  fontSize: 44,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  shadows: [Shadow(color: Neon.accent, blurRadius: 24)],
                ),
              ),
              if (s.seatSetupStep != null) ...[
                const SizedBox(height: 6),
                Text(
                  'seat setup step ${s.seatSetupStep}',
                  style: const TextStyle(color: Neon.inkMuted, fontSize: 12),
                ),
              ],
            ],
            if (s?.adState != null &&
                (s!.adState!.isAdsRequired || s.adState!.isQueuePaused == true)) ...[
              const SizedBox(height: 20),
              _QueueAdCard(adState: s.adState!),
            ],
            const SizedBox(height: 24),
            _LogsToggle(
              open: _showLogs,
              onTap: () => setState(() => _showLogs = !_showLogs),
            ),
            if (_showLogs) ...[
              const SizedBox(height: 12),
              _LogsPanel(session: s, events: widget.events),
            ],
          ],
        ),
      ),
    );
  }
}

class _QueueAdCard extends StatelessWidget {
  final SessionAdState adState;

  const _QueueAdCard({required this.adState});

  @override
  Widget build(BuildContext context) {
    final paused = adState.isQueuePaused == true;
    return NeonCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                paused ? Icons.pause_circle : Icons.live_tv,
                color: paused ? Neon.warning : Neon.accent,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      paused ? 'QUEUE PAUSED' : 'QUEUE AD',
                      style: TextStyle(
                        color: paused ? Neon.warning : Neon.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                      ),
                    ),
                    Text(
                      adState.message ??
                          (paused
                              ? 'Resume ads to stay in queue.'
                              : 'Finish ads to stay in queue.'),
                      style: const TextStyle(
                        color: Neon.inkSoft,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (adState.ads.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final ad in adState.ads)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    const Icon(Icons.play_circle_outline,
                        size: 14, color: Neon.inkMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ad.adId,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Neon.inkMuted, fontSize: 12),
                      ),
                    ),
                    if (ad.durationMs != null)
                      Text(
                        _fmtDuration(ad.durationMs!),
                        style: const TextStyle(
                            color: Neon.inkMuted, fontSize: 11.5),
                      ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _fmtDuration(int ms) {
    final s = (ms / 1000).ceil();
    if (s < 60) return '${s}s';
    return '${s ~/ 60}m ${s % 60}s';
  }
}

class _LogsToggle extends StatelessWidget {
  final bool open;
  final VoidCallback onTap;

  const _LogsToggle({required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0x0FFFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x22FFFFFF)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              open ? Icons.terminal : Icons.terminal_outlined,
              size: 16,
              color: Neon.inkSoft,
            ),
            const SizedBox(width: 8),
            const Text(
              'SESSION INFO',
              style: TextStyle(
                color: Neon.inkSoft,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.expand_more, size: 16, color: Neon.inkSoft),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogsPanel extends StatelessWidget {
  final SessionInfo? session;
  final List<SessionPhaseEvent> events;

  const _LogsPanel({this.session, this.events = const []});

  @override
  Widget build(BuildContext context) {
    final s = session;
    return Column(
      children: [
        NeonCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _InfoRow(label: 'State', value: _sessionLabel(s)),
              if (s != null) ...[
                const Divider(height: 12),
                _InfoRow(label: 'Status code', value: '${s.status}'),
                if (s.queuePosition != null) ...[
                  const Divider(height: 12),
                  _InfoRow(label: 'Queue position', value: '#${s.queuePosition}'),
                ],
                if (s.seatSetupStep != null) ...[
                  const Divider(height: 12),
                  _InfoRow(label: 'Seat setup step', value: '${s.seatSetupStep}'),
                ],
                const Divider(height: 12),
                _InfoRow(label: 'Zone', value: s.zone),
                if (s.sessionId.isNotEmpty) ...[
                  const Divider(height: 12),
                  _InfoRow(label: 'Session ID', value: _short(s.sessionId)),
                ],
                if (s.gpuType != null) ...[
                  const Divider(height: 12),
                  _InfoRow(label: 'GPU', value: s.gpuType!),
                ],
              ],
            ],
          ),
        ),
        if (events.isNotEmpty) ...[
          const SizedBox(height: 12),
          NeonCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'TRANSITIONS',
                  style: TextStyle(
                    color: Neon.inkMuted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 10),
                for (final e in events.reversed.take(8))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${_stateLabel(e.from)} → ${_stateLabel(e.to)}',
                            style: const TextStyle(
                              color: Neon.inkSoft,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        Text(
                          _time(e.timestamp),
                          style: const TextStyle(
                            color: Neon.inkMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String _short(String id) =>
      id.length > 8 ? '${id.substring(0, 8)}…' : id;

  static String _sessionLabel(SessionInfo? s) {
    if (s == null) return '—';
    return s.status == 2 || s.status == 3 ? 'ready' : 'active';
  }

  static String _stateLabel(SessionState s) => switch (s) {
        SessionState.idle => 'idle',
        SessionState.requesting => 'requesting',
        SessionState.queued => 'queued',
        SessionState.allocating => 'allocating',
        SessionState.ready => 'ready',
        SessionState.error => 'error',
      };

  static String _time(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(color: Neon.inkMuted, fontSize: 12),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            color: Neon.ink,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
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
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: message));
            showNeonSnackbar(
              context,
              'Error copied to clipboard',
              copyable: false,
            );
          },
          icon: const Icon(Icons.copy, size: 14, color: Neon.inkSoft),
          label: const Text('COPY ERROR'),
          style: TextButton.styleFrom(
            foregroundColor: Neon.inkSoft,
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(height: 8),
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
