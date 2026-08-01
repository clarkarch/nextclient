import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../state/session_controller.dart';
import '../../state/user_settings.dart';
import '../../state/webrtc_stream_session.dart';
import '../../theme/neon.dart';
import '../../utils/friendly_error.dart';
import '../../widgets/game_art.dart';
import '../../widgets/gamepad/dpad_widget.dart';
import '../../widgets/gamepad/face_buttons.dart';
import '../../widgets/gamepad/gamepad_widget.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_loading.dart';
import '../../widgets/neon_snackbar.dart';
import '../../widgets/stream/session_timer.dart';

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
  WebRtcStreamSession? _webrtc;
  String? _webrtcStatus;
  bool _stopInFlight = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    final webrtc = _webrtc;
    _webrtc = null;
    // Fire-and-forget local teardown; dispose() never throws.
    if (webrtc != null) {
      webrtc.dispose();
    }
    // Safety net: if the route was popped without going through
    // _stopAndExit (e.g. window closed / navigator reset), still ask the
    // server to release the session so it doesn't keep running.
    if (!_stopInFlight) {
      unawaited(_stopServerSession());
    }
    super.dispose();
  }

  /// Once CloudMatch reports the session ready, spin up the WebRTC
  /// connection and attach the incoming video to a renderer.
  Future<void> _connectStream(SessionInfo session) async {
    if (_webrtc != null) return;
    final webrtc = WebRtcStreamSession(
      session: session,
      settings: widget.services.settings,
      log: widget.services.logSink,
      onStatus: (msg) {
        if (mounted) setState(() => _webrtcStatus = msg);
      },
    );
    _webrtc = webrtc;
    try {
      await webrtc.start();
    } catch (e) {
      debugPrint('[stream] webrtc start failed: $e');
      if (!mounted) return;
      // Tear down so a later retry isn't blocked by the non-null guard.
      await webrtc.dispose();
      if (!mounted) return;
      setState(() {
        _webrtc = null;
        _webrtcStatus = 'Stream connection failed: $e';
      });
    }
  }

  Future<void> _start() async {
    if (_launchStarted) return;
    _launchStarted = true;
    try {
      final token = await widget.services.auth.resolveJwtToken();
      final resume = widget.resumeClaim;
      if (resume != null) {
        await widget.services.session.resume(
          SessionClaimRequest(
            token: token,
            streamingBaseUrl: resume.streamingBaseUrl,
            sessionId: resume.sessionId,
            serverIp: resume.serverIp,
            appId: resume.appId,
            appLaunchMode: resume.appLaunchMode,
            enablePersistingInGameSettings:
                resume.enablePersistingInGameSettings,
            settings:
                resume.settings ??
                widget.services.settings.buildStreamSettings(),
          ),
        );
        final resumed = widget.services.session.session;
        if (resumed != null && mounted) await _connectStream(resumed);
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
        enablePersistingInGameSettings: request.enablePersistingInGameSettings,
        supportsInGameSettingsPersistence:
            request.supportsInGameSettingsPersistence,
        zone: request.zone,
        settings: request.settings,
        proxyUrl: request.proxyUrl,
      );
      await widget.services.session.launch(built);
      final launched = widget.services.session.session;
      if (launched != null && mounted) await _connectStream(launched);
    } catch (e) {
      debugPrint('Launch failed: $e');
    }
  }

  Future<void> _stopAndExit() async {
    if (_stopInFlight) return;
    _stopInFlight = true;
    // Local teardown first, but never let a local failure prevent the
    // server-side session stop (DELETE /v2/session).
    try {
      await _webrtc?.dispose();
    } catch (e) {
      debugPrint('[stream] webrtc teardown failed (continuing): $e');
    } finally {
      _webrtc = null;
    }
    await _stopServerSession();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Stops the CloudMatch session (server-side DELETE) and resets the
  /// lifecycle state. Swallows errors so callers always pop.
  Future<void> _stopServerSession() async {
    try {
      await widget.services.session.stop();
    } catch (e) {
      debugPrint('[stream] session stop failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Intercept system back / Esc so the server session is always stopped
    // instead of silently abandoning the running cloud instance.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _stopAndExit();
      },
      child: Scaffold(
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
              final ready =
                  controller.state == SessionState.ready &&
                  controller.session != null;
              if (ready) {
                // Full-bleed immersive streaming surface.
                return _ReadySurface(
                  game: widget.game,
                  session: controller.session!,
                  webrtc: _webrtc,
                  webrtcStatus: _webrtcStatus,
                  settings: widget.services.settings,
                  onStop: _stopAndExit,
                );
              }
              return Column(
                children: [
                  _topBar(controller),
                  Expanded(child: Center(child: _surface(controller))),
                ],
              );
            },
          ),
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
            Container(
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.all(Radius.circular(18)),
                boxShadow: Neon.softShadow(radius: 22),
              ),
              child: SizedBox(
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
            if (widget.state == SessionState.queued &&
                s?.queuePosition != null) ...[
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
                (s!.adState!.isAdsRequired ||
                    s.adState!.isQueuePaused == true)) ...[
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
                    const Icon(
                      Icons.play_circle_outline,
                      size: 14,
                      color: Neon.inkMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ad.adId,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Neon.inkMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (ad.durationMs != null)
                      Text(
                        _fmtDuration(ad.durationMs!),
                        style: const TextStyle(
                          color: Neon.inkMuted,
                          fontSize: 11.5,
                        ),
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
          boxShadow: Neon.softShadow(radius: 10),
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
              child: const Icon(
                Icons.expand_more,
                size: 16,
                color: Neon.inkSoft,
              ),
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
                  _InfoRow(
                    label: 'Queue position',
                    value: '#${s.queuePosition}',
                  ),
                ],
                if (s.seatSetupStep != null) ...[
                  const Divider(height: 12),
                  _InfoRow(
                    label: 'Seat setup step',
                    value: '${s.seatSetupStep}',
                  ),
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
        Text(label, style: const TextStyle(color: Neon.inkMuted, fontSize: 12)),
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

/// Full-bleed streaming surface: video fills the screen, with gradient chrome
/// overlays (session timer + exit, bottom control bar) and an optional virtual
/// gamepad overlay. Esc or tapping the video toggles the chrome. Layout
/// borrows from open_next's stream screen, themed with Neon.
class _ReadySurface extends StatefulWidget {
  final CatalogGame game;
  final SessionInfo session;
  final WebRtcStreamSession? webrtc;
  final String? webrtcStatus;
  final UserSettings settings;
  final VoidCallback onStop;

  const _ReadySurface({
    required this.game,
    required this.session,
    this.webrtc,
    this.webrtcStatus,
    required this.settings,
    required this.onStop,
  });

  @override
  State<_ReadySurface> createState() => _ReadySurfaceState();
}

class _ReadySurfaceState extends State<_ReadySurface> {
  bool _chromeVisible = true;

  // Gamepad bitmask + stick state. The input-channel encoder isn't ported
  // yet, so these just accumulate here ready to be handed to it.
  int _gamepadButtons = 0;
  int _leftStickX = 0;
  int _leftStickY = 0;
  int _rightStickX = 0;
  int _rightStickY = 0;

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  void _sendGamepadState() {
    // TODO(input): encode + send over input_channel_v1 once ported.
    debugPrint(
      '[gamepad] buttons=0x${_gamepadButtons.toRadixString(16)} '
      'l=($_leftStickX,$_leftStickY) r=($_rightStickX,$_rightStickY)',
    );
  }

  void _onLeftStickDrag(Offset offset) {
    _leftStickX = (offset.dx * 127).round().clamp(-127, 127);
    _leftStickY = (offset.dy * 127).round().clamp(-127, 127);
    _sendGamepadState();
  }

  void _onRightStickDrag(Offset offset) {
    _rightStickX = (offset.dx * 127).round().clamp(-127, 127);
    _rightStickY = (offset.dy * 127).round().clamp(-127, 127);
    _sendGamepadState();
  }

  void _onFaceButtonPressed(FaceButtonLabel button) {
    _gamepadButtons |= switch (button) {
      FaceButtonLabel.a => 0x0001,
      FaceButtonLabel.b => 0x0002,
      FaceButtonLabel.x => 0x0004,
      FaceButtonLabel.y => 0x0008,
    };
    _sendGamepadState();
  }

  void _onFaceButtonReleased(FaceButtonLabel button) {
    _gamepadButtons &= ~switch (button) {
      FaceButtonLabel.a => 0x0001,
      FaceButtonLabel.b => 0x0002,
      FaceButtonLabel.x => 0x0004,
      FaceButtonLabel.y => 0x0008,
    };
    _sendGamepadState();
  }

  void _onDpadPressed(DPadDirection direction) {
    _gamepadButtons |= switch (direction) {
      DPadDirection.up => 0x1000,
      DPadDirection.down => 0x2000,
      DPadDirection.left => 0x4000,
      DPadDirection.right => 0x8000,
      DPadDirection.none => 0,
    };
    _sendGamepadState();
  }

  void _onDpadReleased() {
    _gamepadButtons &= ~(0x1000 | 0x2000 | 0x4000 | 0x8000);
    _sendGamepadState();
  }

  @override
  Widget build(BuildContext context) {
    final renderer = widget.webrtc?.videoRenderer;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _toggleChrome();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      // Rebuild when stream settings change (gamepad/stats toggles in the
      // bottom chrome mutate UserSettings, a ChangeNotifier).
      child: ListenableBuilder(
        listenable: widget.settings,
        builder: (context, _) => Stack(
          fit: StackFit.expand,
          children: [
          // Video fills the screen. Tap toggles the chrome — but only this
          // layer owns the tap, so touching the gamepad below never flips it.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleChrome,
              child: Container(
                color: Colors.black,
                child: renderer != null
                    ? RTCVideoView(
                        renderer,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                        placeholderBuilder: (_) => _backdropArt(),
                      )
                    : _backdropArt(),
              ),
            ),
          ),

            // Top chrome: timer + title/status + exit.
            if (_chromeVisible)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _TopChrome(
                  game: widget.game,
                  session: widget.session,
                  webrtcStatus: widget.webrtcStatus,
                  onStop: widget.onStop,
                ),
              ),

            // Stats overlay (right side under the chrome).
            if (_chromeVisible && widget.settings.streamShowFps)
              Positioned(
                top: 96,
                right: 16,
                child: _FpsOverlay(
                  webrtcStatus: widget.webrtcStatus,
                ),
              ),

            // Bottom chrome: control bar.
            if (_chromeVisible)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _BottomChrome(
                  settings: widget.settings,
                  onStop: widget.onStop,
                ),
              ),

            // Virtual gamepad overlay (independent of chrome visibility). The
            // no-op tap on the wrapper swallows taps so using the gamepad
            // never toggles the chrome (raw Listeners don't join the arena).
            if (widget.settings.streamGamepad)
              Positioned(
                left: 0,
                right: 0,
                // Keep the gamepad clear of the bottom chrome so its
                // Gamepad/Stats/Exit buttons stay reachable. Chrome is
                // ~89px tall plus the safe-area inset.
                bottom: _chromeVisible
                    ? 96.0 + MediaQuery.of(context).padding.bottom
                    : 0.0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 8,
                        right: 8,
                        bottom: 8,
                      ),
                      child: VirtualGamepad(
                      scale: widget.settings.streamGamepadScale,
                      onLeftStickDrag: _onLeftStickDrag,
                      onLeftStickDragEnd: () {
                        _leftStickX = 0;
                        _leftStickY = 0;
                        _sendGamepadState();
                      },
                      onRightStickDrag: _onRightStickDrag,
                      onRightStickDragEnd: () {
                        _rightStickX = 0;
                        _rightStickY = 0;
                        _sendGamepadState();
                      },
                      onDpadPressed: _onDpadPressed,
                      onDpadReleased: _onDpadReleased,
                      onFaceButtonPressed: _onFaceButtonPressed,
                      onFaceButtonReleased: _onFaceButtonReleased,
                    ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _backdropArt() {
    final url = widget.game.imageUrl;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1A1A2E), Color(0xFF0E0E18)],
            ),
          ),
        ),
        if (url != null && url.isNotEmpty)
          Image.network(
            url,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : const SizedBox.shrink(),
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(gradient: Neon.scrim),
        ),
      ],
    );
  }
}

/// Top gradient chrome with the session timer, game title, and exit button.
class _TopChrome extends StatelessWidget {
  final CatalogGame game;
  final SessionInfo session;
  final String? webrtcStatus;
  final VoidCallback onStop;

  const _TopChrome({
    required this.game,
    required this.session,
    this.webrtcStatus,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 16,
        right: 16,
        bottom: 24,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.72),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        children: [
          const SessionTimer(),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  game.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Neon.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    shadows: [Shadow(color: Colors.black, blurRadius: 10)],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  webrtcStatus ??
                      '${session.gpuType ?? 'GPU'} · ${session.serverIp}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Neon.inkSoft,
                    fontSize: 11.5,
                    shadows: [Shadow(color: Colors.black, blurRadius: 8)],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          NeonOutlineButton(
            label: 'Exit',
            icon: Icons.close,
            borderColor: Neon.error,
            onPressed: onStop,
          ),
        ],
      ),
    );
  }
}

/// Bottom gradient chrome: gamepad / stats toggles + exit.
class _BottomChrome extends StatelessWidget {
  final UserSettings settings;
  final VoidCallback onStop;

  const _BottomChrome({
    required this.settings,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: 28,
        left: 24,
        right: 24,
        bottom: MediaQuery.of(context).padding.bottom + 14,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.72),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ChromeButton(
            icon: settings.streamGamepad
                ? Icons.gamepad
                : Icons.gamepad_outlined,
            label: 'Gamepad',
            active: settings.streamGamepad,
            onTap: () =>
                settings.streamGamepad = !settings.streamGamepad,
          ),
          const SizedBox(width: 40),
          _ChromeButton(
            icon: Icons.speed,
            label: 'Stats',
            active: settings.streamShowFps,
            onTap: () => settings.streamShowFps = !settings.streamShowFps,
          ),
          const SizedBox(width: 40),
          _ChromeButton(
            icon: Icons.close,
            label: 'Exit',
            onTap: onStop,
          ),
        ],
      ),
    );
  }
}

class _ChromeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  const _ChromeButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? Neon.accent : Neon.ink;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: active ? Neon.accent : Neon.inkSoft,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Minimal stats chip showing the live webrtc status (real stream stats via
/// getStats can slot in here later).
class _FpsOverlay extends StatelessWidget {
  final String? webrtcStatus;

  const _FpsOverlay({this.webrtcStatus});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.speed, size: 14, color: Neon.accent),
          const SizedBox(width: 6),
          Text(
            webrtcStatus ?? 'connecting…',
            style: const TextStyle(color: Neon.ink, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
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
            NeonButton(label: 'Retry', icon: Icons.refresh, onPressed: onRetry),
          ],
        ),
      ],
    );
  }
}
