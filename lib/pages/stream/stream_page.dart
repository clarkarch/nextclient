import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:pointer_lock/pointer_lock.dart';

import '../../main.dart';
import '../../state/gfn_input_protocol.dart';
import '../../state/session_controller.dart';
import '../../state/stream_stats.dart';
import '../../state/stream_transport.dart';
import '../../state/user_settings.dart';
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
  StreamTransport? _transport;
  String? _webrtcStatus;
  bool _stopInFlight = false;

  /// Lets the outer PopScope ask the live stream surface how to handle the
  /// Android system back button (show chrome / close keyboard / exit).
  final GlobalKey<_ReadySurfaceState> _readyKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    final transport = _transport;
    _transport = null;
    // Fire-and-forget local teardown; dispose() never throws.
    if (transport != null) {
      transport.dispose();
    }
    // Safety net: if the route was popped without going through
    // _stopAndExit (e.g. window closed / navigator reset), still ask the
    // server to release the session so it doesn't keep running.
    if (!_stopInFlight) {
      unawaited(_stopServerSession());
    }
    super.dispose();
  }

  /// Once CloudMatch reports the session ready, spin up the selected
  /// transport (libwebrtc or GStreamer webrtcbin) and attach the incoming
  /// video to its surface.
  Future<void> _connectStream(SessionInfo session) async {
    if (_transport != null) return;
    final transport = createStreamTransport(
      kind: widget.services.settings.streamTransport,
      session: session,
      settings: widget.services.settings,
      log: widget.services.logSink,
      onStatus: (msg) {
        if (mounted) setState(() => _webrtcStatus = msg);
      },
    );
    _transport = transport;
    widget.services.logSink.log(
      LogLevel.info,
      'stream',
      'Starting stream session [SESSION ID REDACTED] '
          '(${widget.services.settings.streamTransport.name})',
    );
    try {
      await transport.start();
      widget.services.logSink.log(
        LogLevel.info,
        'stream',
        'Stream session started',
      );
    } catch (e) {
      debugPrint('[stream] transport start failed: $e');
      widget.services.logSink.log(
        LogLevel.error,
        'stream',
        'Transport start failed: $e',
      );
      if (!mounted) return;
      // Drop the transport reference (unsubscribing the stats overlay from its
      // ValueNotifier) BEFORE disposing, so no widget is still listening when
      // the notifier is torn down — same ordering as _stopAndExit.
      setState(() {
        _transport = null;
        _webrtcStatus = 'Stream connection failed: $e';
      });
      // Tear down so a later retry isn't blocked by the non-null guard.
      await transport.dispose();
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
        if (resumed != null && mounted) {
          widget.services.logSink.log(
            LogLevel.info,
            'stream',
            'Session resumed [SESSION ID REDACTED]',
          );
          await _connectStream(resumed);
        }
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
      widget.services.logSink.log(
        LogLevel.info,
        'stream',
        'Session launched [SESSION ID REDACTED]',
      );
      if (launched != null && mounted) await _connectStream(launched);
    } catch (e) {
      widget.services.logSink.log(
        LogLevel.error,
        'stream',
        'Launch failed: $e',
      );
      debugPrint('Launch failed: $e');
    }
  }

  Future<void> _stopAndExit() async {
    if (_stopInFlight) return;
    _stopInFlight = true;
    final transport = _transport;
    // Drop the video surface out of the widget tree first so the transport's
    // native texture is no longer being painted when we dispose it. Tearing
    // down a still-mounted RTCVideoView's texture crashes the engine on Linux
    // (SIGSEGV), and a route pop keeps the outgoing subtree alive during its
    // exit transition.
    if (mounted) {
      setState(() => _transport = null);
    } else {
      _transport = null;
    }
    if (mounted) Navigator.of(context).pop();
    // Local teardown after the video surface is off-screen. Never let a local
    // failure prevent the server-side session stop (DELETE /v2/session).
    try {
      await transport?.dispose();
      widget.services.logSink.log(LogLevel.info, 'stream', 'Stream torn down');
    } catch (e) {
      debugPrint('[stream] transport teardown failed (continuing): $e');
      widget.services.logSink.log(
        LogLevel.warn,
        'stream',
        'Stream teardown failed (continuing): $e',
      );
    }
    await _stopServerSession();
    widget.services.logSink.log(LogLevel.info, 'stream', 'Stream page closed');
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
        // When the stream surface is live, the Android back button shows the
        // stream UI (chrome) or dismisses the soft keyboard first; it only
        // exits once the chrome is already visible.
        final ready = _readyKey.currentState;
        if (ready != null && ready.handleSystemBack()) return;
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
                  key: _readyKey,
                  game: widget.game,
                  session: controller.session!,
                  transport: _transport,
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
          border: Border.all(color: Neon.outline),
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
/// gamepad overlay. A single Esc is forwarded to the game; a quick double-Esc
/// shows the chrome; tapping the video locks the mouse. Layout borrows from
/// open_next's stream screen, themed with Neon.
class _ReadySurface extends StatefulWidget {
  final CatalogGame game;
  final SessionInfo session;
  final StreamTransport? transport;
  final String? webrtcStatus;
  final UserSettings settings;
  final VoidCallback onStop;

  const _ReadySurface({
    super.key,
    required this.game,
    required this.session,
    this.transport,
    this.webrtcStatus,
    required this.settings,
    required this.onStop,
  });

  @override
  State<_ReadySurface> createState() => _ReadySurfaceState();
}

class _ReadySurfaceState extends State<_ReadySurface> {
  bool _chromeVisible = true;

  /// True while the OS pointer is locked: cursor hidden, raw movement deltas
  /// stream straight to the game so FPS-style look works without the cursor
  /// hitting the window edge. The capture click is consumed; a double-Esc
  /// shows the chrome and releases it (a single Esc goes to the game).
  bool _mouseLocked = false;
  StreamSubscription<PointerLockMoveEvent>? _pointerLockSub;

  /// In-flight unlock so a re-lock can't race it. Cancelling a Wayland lock
  /// session is asynchronous (the native `event_stream_cancel` → unlock round
  /// trip happens on the plugin's own event stream); starting a new session
  /// before that finishes would let the stale unlock tear down the fresh lock.
  Future<void>? _pendingUnlock;

  /// Double-Esc detection: a single Esc is always forwarded to the game; a
  /// second Esc arriving within [_escDoubleWindow] shows the stream UI
  /// instead (that second press is consumed — the game already saw the first).
  static const Duration _escDoubleWindow = Duration(milliseconds: 400);
  Timer? _escTimer;
  bool _escArmed = false;
  bool _escDownForwarded = false;

  /// Soft-keyboard overlay state. When enabled a bottom text bar autofocuses a
  /// hidden [TextField] so the OS keyboard shows; typed text is forwarded to
  /// the stream as INPUT_TEXT (backspace/enter become key events).
  bool _keyboardOpen = false;
  final TextEditingController _keyboardController = TextEditingController();
  final FocusNode _keyboardFocus = FocusNode();
  String _lastKeyboardText = '';

  /// Bitmask of mouse buttons currently pressed on the video surface, used to
  /// detect which button a down/up event refers to (GFN protocol is 1-based
  /// single-button events).
  int _pressedMouseButtons = 0;

  /// True while a click lands with chrome hidden and the mouse unlocked. That
  /// click is consumed as the "capture click" that enters mouse lock via the
  /// tap handler (never streamed to the game), matching cloud-gaming
  /// click-to-capture conventions.
  bool _consumingClickForLock = false;

  // Gamepad bitmask + stick state (normalized -1..1), streamed over the
  // input data channel once the NVST handshake completes.
  int _gamepadButtons = 0;
  double _leftStickX = 0;
  double _leftStickY = 0;
  double _rightStickX = 0;
  double _rightStickY = 0;

  /// Routes Escape keys: a single press is read by the game; a quick second
  /// press shows the stream UI instead. The second press (and its release)
  /// never reaches the game; key-up is only echoed for a down the game saw.
  void _handleEscKey(KeyEvent event) {
    if (event is KeyRepeatEvent) return;
    if (event is KeyUpEvent) {
      if (_escDownForwarded) widget.transport?.sendKeyEvent(event);
      _escDownForwarded = false;
      return;
    }
    if (event is! KeyDownEvent) return;
    if (_escArmed) {
      // Second Esc within the window: show the stream UI. The game already
      // received the first press, so this one is consumed entirely.
      _escArmed = false;
      _escTimer?.cancel();
      _escTimer = null;
      if (_mouseLocked) _exitMouseLock();
      // Double-Esc always shows the stream UI (never hides it).
      if (!_chromeVisible) setState(() => _chromeVisible = true);
      return;
    }
    // First Esc: forward to the game and arm the double-press window.
    _escArmed = true;
    _escDownForwarded = true;
    widget.transport?.sendKeyEvent(event);
    _escTimer?.cancel();
    _escTimer = Timer(_escDoubleWindow, () {
      _escArmed = false;
      _escTimer = null;
    });
  }

  /// True once the native pointer-lock session has actually delivered a delta.
  /// The plugin's Linux implementation uses the deprecated `gdk_pointer_grab`,
  /// which fails on Wayland (and swallows the error inside an async onListen,
  /// so we can't learn about it from an error callback). Instead we optimistically
  /// attempt the grab and let it take over only once it proves alive: until the
  /// first plugin delta arrives, Flutter pointer deltas keep flowing (soft lock).
  bool _nativeGrabLive = false;

  /// Enters in-game mode: hides the chrome and locks the pointer.
  ///
  /// The soft lock always engages first (chrome hidden, cursor hidden via
  /// MouseRegion, deltas streamed from Flutter pointer events), so input works
  /// even where no OS grab exists — that's the path on native Wayland. On
  /// X11/Windows/macOS/web we additionally request a real grab for unbounded
  /// deltas; it only starts driving input after its first event.
  Future<void> _enterMouseLock() async {
    if (_mouseLocked) return;
    // Wait for any pending unlock to land before creating a new session, so
    // its native unlock doesn't tear down the lock we're about to acquire.
    final pending = _pendingUnlock;
    _pendingUnlock = null;
    if (pending != null) await pending;
    if (!mounted) return;
    if (_mouseLocked) return;
    setState(() {
      _mouseLocked = true;
      _chromeVisible = false;
      // Entering in-game mode dismisses the soft keyboard (its focus would
      // otherwise fight the pointer-lock tap).
      if (_keyboardOpen) {
        _keyboardOpen = false;
        _keyboardFocus.unfocus();
      }
    });
    if (_pointerLockSub != null) return;
    try {
      final stream = pointerLock.createSession(
        cursor: PointerLockCursor.hidden,
      );
      _pointerLockSub = stream.listen(
        (event) {
          _nativeGrabLive = true;
          _sendMouseDelta(event.delta);
        },
        onDone: _onPointerLockReleased,
        onError: (Object error) {
          debugPrint('[stream] pointer lock error: $error');
          _onPointerLockReleased();
        },
      );
    } catch (e) {
      // Grab unavailable (e.g. native Wayland) — the soft lock is already
      // active, keep going.
      debugPrint('[stream] pointer lock unavailable (soft lock active): $e');
    }
  }

  void _exitMouseLock() {
    final sub = _pointerLockSub;
    _pointerLockSub = null;
    _nativeGrabLive = false;
    _mouseLocked = false;
    if (sub != null) _pendingUnlock = sub.cancel();
  }

  /// Fired when the platform releases the pointer on its own (e.g. the
  /// browser exits pointer lock on Esc during web builds).
  void _onPointerLockReleased() {
    _pendingUnlock = null;
    if (!mounted) return;
    setState(() {
      _pointerLockSub = null;
      _nativeGrabLive = false;
      _mouseLocked = false;
      _chromeVisible = true;
    });
  }

  @override
  void dispose() {
    _pointerLockSub?.cancel();
    _pendingUnlock = null;
    _escTimer?.cancel();
    _keyboardController.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  // --- Mouse → stream (only when the chrome is hidden, i.e. in-game) -------

  int? _gfnButtonForBit(int bit) => switch (bit) {
        kPrimaryMouseButton => mouseLeft,
        kSecondaryMouseButton => mouseRight,
        kMiddleMouseButton => mouseMiddle,
        kBackMouseButton => mouseBack,
        kForwardMouseButton => mouseForward,
        _ => null,
      };

  void _sendMouseDelta(Offset delta) {
    final dx = delta.dx.round().clamp(-32767, 32767);
    final dy = delta.dy.round().clamp(-32767, 32767);
    if (dx == 0 && dy == 0) return;
    widget.transport?.sendMouseMove(dx: dx, dy: dy);
  }

  void _onVideoPointerDown(PointerDownEvent event) {
    if (_chromeVisible) return; // chrome consumes; tap will hide it
    // Touch: a finger is the primary mouse button. No capture-click for
    // touch — every tap while in-game is a real click.
    if (event.kind == PointerDeviceKind.touch) {
      _pressedMouseButtons |= kPrimaryMouseButton;
      widget.transport?.sendMouseButton(down: true, button: mouseLeft);
      return;
    }
    if (!_mouseLocked) {
      // First click after hiding the UI is the capture click: consume it and
      // let the tap below enter mouse lock (consistent with the chrome-visible
      // path, where the click is consumed too).
      _consumingClickForLock = true;
      return;
    }
    final newly = event.buttons & ~_pressedMouseButtons;
    _pressedMouseButtons = event.buttons;
    for (var bit = 1; bit <= kForwardMouseButton; bit <<= 1) {
      if ((newly & bit) == 0) continue;
      final button = _gfnButtonForBit(bit);
      if (button != null) {
        widget.transport?.sendMouseButton(down: true, button: button);
      }
    }
  }

  void _onVideoPointerUp(PointerUpEvent event) {
    if (_chromeVisible) return;
    if (event.kind == PointerDeviceKind.touch) {
      _pressedMouseButtons &= ~kPrimaryMouseButton;
      widget.transport?.sendMouseButton(down: false, button: mouseLeft);
      return;
    }
    if (_consumingClickForLock) {
      _consumingClickForLock = false;
      return;
    }
    final released = _pressedMouseButtons & ~event.buttons;
    _pressedMouseButtons = event.buttons;
    for (var bit = 1; bit <= kForwardMouseButton; bit <<= 1) {
      if ((released & bit) == 0) continue;
      final button = _gfnButtonForBit(bit);
      if (button != null) {
        widget.transport?.sendMouseButton(down: false, button: button);
      }
    }
  }

  // Deltas stream straight from Flutter pointer events whenever the chrome is
  // hidden (in-game). A native grab session only takes over once it has proven
  // alive (_nativeGrabLive) — until then Flutter deltas keep flowing, which is
  // what keeps the mouse working on native Wayland where the grab can't exist.
  void _onVideoPointerMove(PointerEvent event) {
    if (_pointerLockSub != null && _nativeGrabLive) return;
    if (!_chromeVisible && event is PointerMoveEvent) {
      _sendMouseDelta(event.delta);
    }
  }

  void _onVideoPointerHover(PointerHoverEvent event) {
    if (_pointerLockSub != null && _nativeGrabLive) return;
    if (!_chromeVisible) _sendMouseDelta(event.delta);
  }

  void _onVideoPointerCancel(PointerCancelEvent event) {
    if (_chromeVisible) return;
    _consumingClickForLock = false;
    // Pointer lock can inject cancel/add pairs (Windows capture, gdk grab);
    // release only the buttons we think are held so the game never sees a
    // stuck button — and no spurious ups for buttons that were never down.
    final wasDown = _pressedMouseButtons;
    _pressedMouseButtons = 0;
    for (var bit = 1; bit <= kForwardMouseButton; bit <<= 1) {
      if ((wasDown & bit) == 0) continue;
      final button = _gfnButtonForBit(bit);
      if (button != null) {
        widget.transport?.sendMouseButton(down: false, button: button);
      }
    }
  }

  void _onVideoPointerSignal(PointerSignalEvent event) {
    if (_chromeVisible || event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy.round();
    if (dy != 0) widget.transport?.sendMouseWheel(delta: dy);
  }

  void _sendGamepadState() {
    widget.transport?.sendGamepadState(
      buttons: _gamepadButtons,
      leftStickX: _leftStickX,
      leftStickY: _leftStickY,
      rightStickX: _rightStickX,
      rightStickY: _rightStickY,
    );
  }

  void _onLeftStickDrag(Offset offset) {
    _leftStickX = offset.dx;
    _leftStickY = offset.dy;
    _sendGamepadState();
  }

  void _onRightStickDrag(Offset offset) {
    _rightStickX = offset.dx;
    _rightStickY = offset.dy;
    _sendGamepadState();
  }

  // XInput button flags — must match the protocol constants in
  // gfn_input_protocol.dart (A=0x1000…, DPAD_UP=0x0001…).
  void _onFaceButtonPressed(FaceButtonLabel button) {
    _gamepadButtons |= switch (button) {
      FaceButtonLabel.a => 0x1000,
      FaceButtonLabel.b => 0x2000,
      FaceButtonLabel.x => 0x4000,
      FaceButtonLabel.y => 0x8000,
    };
    _sendGamepadState();
  }

  void _onFaceButtonReleased(FaceButtonLabel button) {
    _gamepadButtons &= ~switch (button) {
      FaceButtonLabel.a => 0x1000,
      FaceButtonLabel.b => 0x2000,
      FaceButtonLabel.x => 0x4000,
      FaceButtonLabel.y => 0x8000,
    };
    _sendGamepadState();
  }

  void _onDpadPressed(DPadDirection direction) {
    _gamepadButtons |= switch (direction) {
      DPadDirection.up => 0x0001,
      DPadDirection.down => 0x0002,
      DPadDirection.left => 0x0004,
      DPadDirection.right => 0x0008,
      DPadDirection.none => 0,
    };
    _sendGamepadState();
  }

  void _onDpadReleased() {
    _gamepadButtons &= ~(0x0001 | 0x0002 | 0x0004 | 0x0008);
    _sendGamepadState();
  }

  // --- Soft keyboard (mobile touch input) -----------------------------------

  void _toggleKeyboard() {
    setState(() {
      _keyboardOpen = !_keyboardOpen;
      if (_keyboardOpen) {
        _lastKeyboardText = '';
        _keyboardController.clear();
      } else {
        _keyboardFocus.unfocus();
      }
    });
    if (_keyboardOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _keyboardFocus.requestFocus();
      });
    }
  }

  void _onKeyboardChanged(String text) {
    final previous = _lastKeyboardText;
    _lastKeyboardText = text;
    final transport = widget.transport;
    if (transport == null) return;

    // Backspace for every character removed from the tail.
    var removed = 0;
    while (removed < previous.length &&
        (removed >= text.length ||
            previous.codeUnitAt(previous.length - 1 - removed) !=
                text.codeUnitAt(text.length - 1 - removed))) {
      removed++;
    }
    for (var i = 0; i < removed; i++) {
      _sendSyntheticKey(LogicalKeyboardKey.backspace,
          PhysicalKeyboardKey.backspace);
    }

    // Forward the newly typed characters as text input.
    final added = text.length > previous.length
        ? text.substring(previous.length)
        : '';
    if (added.isNotEmpty) transport.sendText(added);
  }

  void _onKeyboardSubmitted(String text) {
    if (text.isNotEmpty) {
      widget.transport?.sendText(text);
      _lastKeyboardText = '';
      _keyboardController.clear();
    }
    _sendSyntheticKey(LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter);
  }

  void _sendSyntheticKey(
      LogicalKeyboardKey logical, PhysicalKeyboardKey physical) {
    final now = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);
    widget.transport?.sendKeyEvent(KeyDownEvent(
      physicalKey: physical,
      logicalKey: logical,
      timeStamp: now,
      synthesized: true,
    ));
    widget.transport?.sendKeyEvent(KeyUpEvent(
      physicalKey: physical,
      logicalKey: logical,
      timeStamp: now,
      synthesized: true,
    ));
  }

  /// Android system back: if the soft keyboard is open, close it; otherwise
  /// show the stream UI (chrome). Returns true when consumed.
  bool handleSystemBack() {
    if (_keyboardOpen) {
      _toggleKeyboard();
      return true;
    }
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final transport = widget.transport;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        // Escape: a single press is read by the game; a quick second press
        // within the double-press window shows the stream UI instead.
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          _handleEscKey(event);
          return KeyEventResult.handled;
        }
          // Everything else goes to the stream over the input channel.
          widget.transport?.sendKeyEvent(event);
          return KeyEventResult.handled;
        },
        // Rebuild when stream settings change (gamepad/stats toggles in the
        // bottom chrome mutate UserSettings, a ChangeNotifier).
        child: ListenableBuilder(
          listenable: widget.settings,
          builder: (context, _) => Stack(
            fit: StackFit.expand,
            children: [
          // Video fills the screen. When the chrome is visible, tapping hides
          // it (UI mode). When hidden (in-game), all mouse input — deltas,
          // buttons, wheel — streams to the game. Raw Listeners below the
          // chrome/gamepad overlays mean those still win hit-testing.
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onVideoPointerDown,
              onPointerUp: _onVideoPointerUp,
              onPointerMove: _onVideoPointerMove,
              onPointerHover: _onVideoPointerHover,
              onPointerSignal: _onVideoPointerSignal,
              onPointerCancel: _onVideoPointerCancel,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  // Tapping the stream surface captures the pointer: the first
                  // click (chrome visible, or unlocked-but-hidden) is consumed
                  // by _onVideoPointerDown/_Up and enters mouse lock; further
                  // clicks play. Double-Esc releases.
                  if (_chromeVisible || !_mouseLocked) {
                    _enterMouseLock();
                  }
                },
                child: MouseRegion(
                  // Soft lock: hide the OS cursor while in-game. This is what
                  // actually hides it on Linux/Wayland, where no native grab
                  // exists.
                  cursor: _mouseLocked
                      ? SystemMouseCursors.none
                      : SystemMouseCursors.basic,
                  child: Container(
                    color: Colors.black,
                    child: transport != null
                        ? transport.buildVideoView(
                            placeholder: _backdropArt(),
                          )
                        : _backdropArt(),
                  ),
                ),
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

            // Stats overlay (right side under the chrome). Stays visible when
            // the stream UI hides so stats remain readable in-game.
            if (widget.settings.streamShowFps)
              Positioned(
                top: 96,
                right: 16,
                child: _StatsOverlay(transport: widget.transport),
              ),

            // Hint pill: mouse-lock + double-Esc gestures.
            if (_chromeVisible)
              Positioned(
                top: 88,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: _HintPill(),
                  ),
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
                  keyboardOpen: _keyboardOpen,
                  onKeyboard: _toggleKeyboard,
                  onFullscreen: _enterMouseLock,
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

            // Soft keyboard overlay (touch devices). The focused text field
            // summons the OS keyboard; typed text goes to the game, and the
            // close button (or the Android back button) dismisses it.
            if (_keyboardOpen)
              Positioned(
                left: 0,
                right: 0,
                bottom: MediaQuery.of(context).viewInsets.bottom,
                child: SafeArea(
                  top: false,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Neon.bgC.withValues(alpha: 0.92),
                        border: const Border(
                          top: BorderSide(color: Neon.outlineSoft),
                        ),
                        boxShadow: Neon.softShadow(radius: 12),
                      ),
                      child: Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Icon(
                              Icons.keyboard,
                              size: 18,
                              color: Neon.inkMuted,
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _keyboardController,
                              focusNode: _keyboardFocus,
                              onChanged: _onKeyboardChanged,
                              onSubmitted: _onKeyboardSubmitted,
                              textInputAction: TextInputAction.go,
                              keyboardType: TextInputType.text,
                              autocorrect: false,
                              enableSuggestions: false,
                              style: const TextStyle(
                                color: Neon.ink,
                                fontSize: 14,
                              ),
                              cursorColor: Neon.accent,
                              decoration: InputDecoration(
                                hintText: 'Type to the game…',
                                hintStyle: const TextStyle(
                                  color: Neon.inkMuted,
                                  fontSize: 14,
                                ),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                filled: true,
                                fillColor: Neon.bgB,
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: const BorderSide(
                                    color: Neon.outlineSoft,
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: const BorderSide(
                                    color: Neon.accent,
                                    width: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: _toggleKeyboard,
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: Neon.bgB,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Neon.outline),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.close,
                                    size: 16,
                                    color: Neon.inkMuted,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    'Done',
                                    style: TextStyle(
                                      color: Neon.ink,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
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

/// Bottom gradient chrome: gamepad / stats toggles + keyboard + fullscreen.
class _BottomChrome extends StatelessWidget {
  final UserSettings settings;
  final bool keyboardOpen;
  final VoidCallback onKeyboard;
  final VoidCallback onFullscreen;

  const _BottomChrome({
    required this.settings,
    required this.keyboardOpen,
    required this.onKeyboard,
    required this.onFullscreen,
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
            icon: Icons.keyboard,
            label: 'Keyboard',
            active: keyboardOpen,
            onTap: onKeyboard,
          ),
          const SizedBox(width: 40),
          _ChromeButton(
            icon: Icons.fullscreen,
            label: 'Fullscreen',
            onTap: onFullscreen,
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

/// Subtle hint pill explaining the gestures (single Esc reaches the game,
/// double-Esc opens the UI, click locks the mouse).
class _HintPill extends StatelessWidget {
  const _HintPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.keyboard, size: 13, color: Neon.inkSoft),
          SizedBox(width: 7),
          Text(
            'click to lock mouse · Esc goes to the game · Esc Esc opens UI',
            style: TextStyle(color: Neon.inkSoft, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Verbose live stats overlay: real getStats() data (bitrate, FPS, jitter,
/// RTT, loss, decode time, backlog) plus client-side plumbing (UI FPS via a
/// Ticker, connection/ICE state, input channels, renderer). Ports the spirit
/// of OpenNOW's stream diagnostics panel.
class _StatsOverlay extends StatefulWidget {
  final StreamTransport? transport;

  const _StatsOverlay({this.transport});

  @override
  State<_StatsOverlay> createState() => _StatsOverlayState();
}

class _StatsOverlayState extends State<_StatsOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _uiFrames = 0;
  double _uiFps = 0;
  Duration _windowStart = Duration.zero;

  @override
  void initState() {
    super.initState();
    // Measure the Flutter UI's own frame rate (client-side render health),
    // independent of the stream's decode FPS.
    _ticker = createTicker((elapsed) {
      _uiFrames++;
      final windowMs = elapsed - _windowStart;
      if (windowMs.inMilliseconds >= 500 && windowMs.inMilliseconds > 0) {
        setState(() {
          _uiFps = _uiFrames * 1000 / windowMs.inMilliseconds;
          _uiFrames = 0;
          _windowStart = elapsed;
        });
      }
    });
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transport = widget.transport;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340, maxHeight: 560),
      child: Container(
        width: 340,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          boxShadow: Neon.softShadow(radius: 14),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _StatsHeader(),
              if (transport == null) ...[
                const SizedBox(height: 8),
                const Text(
                  'transport not started',
                  style: TextStyle(color: Neon.inkMuted, fontSize: 11),
                ),
              ] else
                ValueListenableBuilder<StreamStatsSnapshot?>(
                  valueListenable: transport.stats,
                  builder: (context, snap, _) {
                    if (snap == null) {
                      return const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Text(
                          'collecting stats…',
                          style: TextStyle(color: Neon.inkMuted, fontSize: 11),
                        ),
                      );
                    }
                    return _StatsBody(
                      snap: snap,
                      uiFps: _uiFps,
                      transport: transport,
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatsHeader extends StatelessWidget {
  const _StatsHeader();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Icon(Icons.speed, size: 14, color: Neon.accent),
        SizedBox(width: 6),
        Text(
          'LIVE STATS',
          style: TextStyle(
            color: Neon.ink,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
          ),
        ),
      ],
    );
  }
}

class _StatsBody extends StatelessWidget {
  final StreamStatsSnapshot snap;
  final double uiFps;
  final StreamTransport transport;

  const _StatsBody({
    required this.snap,
    required this.uiFps,
    required this.transport,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        _section('CLIENT'),
        _row('UI FPS', uiFps.toStringAsFixed(1)),
        _row('Connection', snap.connectionState ?? '—'),
        _row('Input', snap.inputReady ? 'ready' : 'idle'),
        _row('Reliable ch', snap.reliableInputOpen ? 'open' : 'closed'),
        _row('Partial ch', snap.partiallyReliableInputOpen ? 'open' : 'closed'),
        _row(
          'Renderer',
          '${transport.videoWidth ?? '?'}x${transport.videoHeight ?? '?'}'
              '${snap.rendererHasVideo ? ' · active' : ' · waiting'}',
        ),
        const SizedBox(height: 6),
        _section('STREAM · VIDEO'),
        _row('Codec', snap.codecMime?.replaceFirst('video/', '') ?? '—'),
        _row('Decoder', snap.decoderImplementation ?? '—'),
        _row('Resolution',
            '${snap.videoWidth ?? '?'}x${snap.videoHeight ?? '?'}'),
        _row('Bitrate', fmtKbps(snap.videoBitrateKbps)),
        _row('Decode FPS', fmtFps(snap.decodeFps)),
        _row('Receive FPS', fmtFps(snap.receivedFps)),
        _row('Backlog', '${snap.backlogFrames} frames'),
        _row('Frames',
            '${snap.framesDecoded} dec / ${snap.framesReceived} recv'),
        _row('Dropped', '${snap.framesDropped} (${snap.keyFramesDecoded} key)'),
        _row('Jitter', '${snap.jitterMs.toStringAsFixed(1)} ms'),
        _row('JB delay', '${snap.jitterBufferDelayMs.toStringAsFixed(1)} ms'),
        _row('Decode/frame', '${snap.decodeTimePerFrameMs.toStringAsFixed(2)} ms'),
        const SizedBox(height: 6),
        _section('STREAM · AUDIO'),
        _row('Bitrate', fmtKbps(snap.audioBitrateKbps)),
        _row('Jitter', '${snap.audioJitterMs.toStringAsFixed(1)} ms'),
        _row('Packets lost', '${snap.audioPacketsLost}'),
        const SizedBox(height: 6),
        _section('NETWORK'),
        _row('RTT', '${snap.rttMs.toStringAsFixed(1)} ms'),
        _row(
          'Loss',
          '${snap.packetLossPercent.toStringAsFixed(2)}% '
              '(${snap.packetsLost}/${snap.packetsReceived})',
        ),
        _row('NACK', '${snap.nackCount}'),
        _row('In avail', fmtKbps(snap.availableIncomingBitrateKbps)),
        _row('Out avail', fmtKbps(snap.availableOutgoingBitrateKbps)),
      ],
    );
  }

  Widget _section(String label) {
    return Text(
      label,
      style: const TextStyle(
        color: Neon.accent,
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(color: Neon.inkMuted, fontSize: 10.5),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              color: Neon.ink,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
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
