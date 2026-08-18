import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show kIsWeb, kProfileMode, kReleaseMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:pointer_lock/pointer_lock.dart';
import 'package:window_manager/window_manager.dart';

import '../../main.dart';
import '../../state/gfn_cursor_overlay.dart';
import '../../state/gfn_input_protocol.dart';
import '../../state/gfn_mouse_input.dart';
import '../../state/physical_gamepad.dart';
import '../../state/session_controller.dart';
import '../../state/stream_stats.dart';
import '../../state/stream_transport.dart';
import '../../state/user_settings.dart';
import '../../state/video_shader_settings.dart';
import '../../state/webrtc_stream_session.dart'
    show pushVideoShaderSettings;
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
import '../../widgets/neon_switch.dart';
import '../../widgets/stream/queue_ad_player.dart';
import '../../widgets/stream/session_timer.dart';
import '../../widgets/stream/video_shader_controls.dart';

/// Full-screen streaming surface. Drives the [SessionController] lifecycle
/// (requesting → queued → allocating → ready) then shows the session-ready
/// state. No video render yet (gfn_core v0.01). With [resumeClaim], an
/// existing session is claimed/resumed instead of creating a new one.
class StreamPage extends StatefulWidget {
  final AppServices services;
  final CatalogGame game;
  final SessionCreateRequest? request;
  final SessionClaimRequest? resumeClaim;

  /// Debug mode: renders the live streaming surface (chrome, timer, gamepad,
  /// stats overlay, gestures) against a fake session with no server, so the
  /// stream UI can be exercised without queuing for a real session.
  final bool demoMode;

  const StreamPage({
    super.key,
    required this.services,
    required this.game,
    this.request,
    this.resumeClaim,
    this.demoMode = false,
  });

  @override
  State<StreamPage> createState() => _StreamPageState();

  /// Fake ready session for [demoMode]. The surface never calls the server in
  /// demo mode (transport is null), so only the fields the chrome reads matter.
  static SessionInfo get demoSession => const SessionInfo(
    sessionId: 'demo',
    status: 0,
    zone: 'demo',
    serverIp: 'demo.local',
    signalingServer: 'demo.local',
    signalingUrl: 'demo.local',
    iceServers: [],
  );
}

class _StreamPageState extends State<StreamPage> {
  bool _launchStarted = false;
  StreamTransport? _transport;
  String? _webrtcStatus;
  bool _stopInFlight = false;

  /// Session-wide stats rollup, recorded to the logs on exit so a laggy
  /// session (high decode ms, low FPS) can be reviewed after the stream ends.
  StreamStatsSummary? _statsSummary;
  bool _statsLogged = false;

  /// UI-fps measurement: a post-frame callback counts frames that are actually
  /// produced. Unlike a Ticker it never schedules frames, so it can't worsen
  /// the very lag it measures — and it runs even when the stats overlay is off,
  /// so the on-exit report always carries the UI-fps numbers.
  bool _uiFpsActive = false;
  int _uiFrames = 0;
  Duration? _uiWindowStart;

  /// Lets the outer PopScope ask the live stream surface how to handle the
  /// Android system back button (show chrome / close keyboard / exit).
  final GlobalKey<_ReadySurfaceState> _readyKey = GlobalKey();

  /// Ownership token for the window-close hook in main.dart. Only the page
  /// that installed [appCloseHook] clears it, so popping an older page can't
  /// wipe a newer page's hook.
  late final Object _closeHookToken = Object();

  void _onStats() {
    final snap = _transport?.stats.value;
    if (snap != null) _statsSummary?.add(snap);
  }

  void _startUiFpsTracking() {
    if (_uiFpsActive) return;
    _uiFpsActive = true;
    _uiFrames = 0;
    _uiWindowStart = null;
    WidgetsBinding.instance.addPostFrameCallback(_onUiFrame);
  }

  void _onUiFrame(Duration elapsed) {
    if (!_uiFpsActive) return;
    _uiFrames++;
    final start = _uiWindowStart;
    if (start == null) {
      // First frame only opens the window — re-register so the chain keeps
      // running. Without this the callback never reschedules and the report
      // never gets any ui-fps samples (the ui fps row silently vanishes).
      _uiWindowStart = elapsed;
      WidgetsBinding.instance.addPostFrameCallback(_onUiFrame);
      return;
    }
    final windowMs = elapsed - start;
    if (windowMs.inMilliseconds >= 500 && windowMs.inMilliseconds > 0) {
      _statsSummary?.setUiFps(_uiFrames * 1000 / windowMs.inMilliseconds);
      _uiFrames = 0;
      _uiWindowStart = elapsed;
    }
    WidgetsBinding.instance.addPostFrameCallback(_onUiFrame);
  }

  /// debug / profile / release, from the compile-time [kDebugMode] etc. flags.
  String get _buildMode =>
      kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug');

  /// Human label for the mouse sampling interval setting (for the on-exit
  /// report): <0 immediate, 0 adaptive, >0 fixed ms.
  String _samplingLabel(int ms) => switch (ms) {
    < 0 => 'immediate',
    0 => 'adaptive',
    _ => '${ms}ms',
  };

  /// Compact block describing the build mode and the settings the session ran
  /// under, logged with the on-exit stats so lag/decode numbers can be
  /// correlated with the exact configuration they were reproduced with.
  String _sessionContextReport() {
    final s = widget.services.settings;
    String line(String label, String value) => '${label.padRight(12)}$value';
    return [
      line('build', _buildMode),
      line(
        'requested',
        '${s.resolution} @ ${s.fps} fps ${s.codec.name} · '
            '${s.maxBitrateMbps} Mbps',
      ),
      line('transport', s.streamTransport.name),
      line('decoder', s.decoderBackend.name),
      line('renderer', s.rendererBackend.name),
      line(
        'shader',
        s.videoShader.hasVisibleEffect
            ? 'on sharpen=${s.videoShader.sharpen}% '
                '${s.videoShader.sharpenAdaptive ? 'adaptive' : 'uniform'} '
                'sat=${s.videoShader.saturation}% '
                'contrast=${s.videoShader.contrast}% '
                'brightness=${s.videoShader.brightness}% '
                'vibrance=${s.videoShader.vibrance}% '
                'grain=${s.videoShader.filmGrain}%'
            : 'off',
      ),
      line(
        'priority',
        '${s.streamPriority.name}'
            '${s.streamPriorityEnabled ? '' : ' (off)'}',
      ),
      line(
        'gamepad',
        s.streamGamepad
            ? 'on ${s.streamGamepadScale.toStringAsFixed(1)}x '
                'off=${s.streamGamepadSpacing.toStringAsFixed(1)}x '
                'vpos=${s.streamGamepadPosition.toStringAsFixed(1)}'
            : 'off',
      ),
      line(
        'input',
        'sens=${s.inputMouseSensitivity.toStringAsFixed(2)}x '
            'accel=${s.inputMouseAcceleration} '
            'sample=${_samplingLabel(s.inputMouseSamplingMs)} '
            'precision=${s.inputMousePrecision} '
            'cursor=${s.inputCursorOverlay}',
      ),
      line('stats', s.streamShowFps ? 'on' : 'off'),
      line(
        'webrtc',
        'hwAccel=${s.webrtcHwAccel} ice=${s.webrtcIceTransport.name} '
            'bundle=${s.webrtcBundle.name} rtcpMux=${s.webrtcRtcpMux.name}',
      ),
      line(
        'recovery',
        '${s.optRecoveryProfile.name} minBitrate=${s.optMinBitrateKbps}kbps '
            'nack=${s.optEnableNack} fec=${s.optEnableFec} '
            'lowLatency=${s.optLowLatencyMode} '
            'constantQuality=${s.optConstantQuality}',
      ),
    ].join('\n');
  }

  /// Logs the end-of-stream stats report exactly once, then unsubscribes.
  /// Called from both [dispose] (safety-net teardown) and [_stopAndExit].
  void _logStreamStats(StreamTransport? transport) {
    if (_statsLogged) return;
    _statsLogged = true;
    _uiFpsActive = false; // stop the frame callback from rescheduling
    transport?.stats.removeListener(_onStats);
    final summary = _statsSummary;
    _statsSummary = null;
    if (summary == null || summary.samples == 0) return;
    widget.services.logSink.log(
      LogLevel.info,
      'stream',
      'Stream stats on exit:\n'
          '${_sessionContextReport()}\n'
          '${summary.toReportString()}',
    );
  }

  @override
  void initState() {
    super.initState();
    // Window-close hook (Alt+F4 / WM close): main.dart intercepts the native
    // close and runs this first so the stream is torn down while the engine
    // is still alive (see main.dart's installWindowCloseHandler). Closing the
    // window mid-stream would destroy the engine under the live native video
    // stack and crash on Linux.
    appCloseHook = _stopAndExit;
    appCloseOwner = _closeHookToken;
    if (widget.demoMode) return; // no server session to launch
    _start();
  }

  @override
  void dispose() {
    // Clear the close hook only if this page still owns it (see
    // [_closeHookToken]). The close handler then no-ops — and the window
    // closes immediately — when no stream page is live.
    if (identical(appCloseOwner, _closeHookToken)) {
      appCloseOwner = null;
      appCloseHook = null;
    }
    final transport = _transport;
    _transport = null;
    // Fire-and-forget local teardown; dispose() never throws.
    if (transport != null) {
      _logStreamStats(transport);
      transport.dispose();
    }
    // Safety net: if the route was popped without going through
    // _stopAndExit (e.g. window closed / navigator reset), still ask the
    // server to release the session so it doesn't keep running.
    if (!_stopInFlight) {
      unawaited(_stopServerSession());
    }
    // Safety net for the frame callback chain when no transport was ever
    // connected (nothing else stops it).
    _uiFpsActive = false;
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
    // Start the session stats rollup for the on-exit report.
    _statsSummary = StreamStatsSummary();
    transport.stats.addListener(_onStats);
    _startUiFpsTracking();
    widget.services.logSink.log(
      LogLevel.info,
      'stream',
      'Starting stream session [SESSION ID REDACTED] '
          '(${widget.services.settings.streamTransport.name} · $_buildMode)',
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
      // Tear down so a later retry isn't blocked by the non-null guard. The
      // rollup is abandoned (nothing was streamed); drop the listener so the
      // disposed notifier can't notify this state again.
      transport.stats.removeListener(_onStats);
      _uiFpsActive = false;
      _statsSummary = null;
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

  /// Reports an ad lifecycle action to the backend for the current session.
  Future<void> _reportAdAction(
    SessionAdAction action,
    String adId, {
    int? watchedMs,
  }) async {
    final session = widget.services.session.session;
    if (session == null) return;
    try {
      final token = await widget.services.auth.resolveJwtToken();
      await widget.services.cloudMatch.reportSessionAd(
        SessionAdReportRequest(
          token: token,
          streamingBaseUrl: session.streamingBaseUrl,
          serverIp: session.serverIp,
          zone: session.zone,
          sessionId: session.sessionId,
          clientId: session.clientId,
          deviceId: session.deviceId,
          adId: adId,
          action: action,
          watchedTimeInMs: watchedMs,
        ),
      );
    } catch (e) {
      widget.services.logSink.log(
        LogLevel.warn,
        'queue-ad',
        'report $action (ad $adId) failed: $e',
      );
    }
  }

  Future<void> _stopAndExit() async {
    if (_stopInFlight) return;
    if (widget.demoMode) {
      // No transport or server session to tear down in demo mode.
      _exitDemo();
      return;
    }
    _stopInFlight = true;
    final transport = _transport;
    // Release in-game mode (pointer lock + OS fullscreen) explicitly BEFORE
    // the route teardown: on the window-close path the engine may die right
    // after this returns, so the native pointer grab must already be down.
    _readyKey.currentState?.releaseInGameMode();
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
    // Record the end-of-stream stats report before the transport is torn down
    // (the stats notifier stops updating once disposed).
    _logStreamStats(transport);
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

  /// Pops the demo surface without touching the server. Guards dispose's
  /// safety-net server stop from firing on the fake session.
  void _exitDemo() {
    _stopInFlight = true;
    if (mounted) Navigator.of(context).pop();
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
    // Debug demo mode: skip the CloudMatch lifecycle entirely and show the
    // live surface against a fake session (no transport, no server). The
    // chrome/timer/gamepad/stats gestures all work the same so UI-only changes
    // can be iterated on without queueing for a seat.
    if (widget.demoMode) {
      return PopScope(
        canPop: true,
        child: Scaffold(
          backgroundColor: Neon.bgA,
          body: _ReadySurface(
            key: _readyKey,
            game: widget.game,
            session: StreamPage.demoSession,
            transport: null,
            webrtcStatus: 'Demo session · no server',
            settings: widget.services.settings,
            onStop: _exitDemo,
          ),
        ),
      );
    }

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
      reportAd: _reportAdAction,
    );
  }
}

class _ProgressSurface extends StatefulWidget {
  final CatalogGame game;
  final SessionState state;
  final SessionInfo? session;
  final List<SessionPhaseEvent> events;
  final Future<void> Function(
    SessionAdAction action,
    String adId, {
    int? watchedMs,
  })
  reportAd;

  const _ProgressSurface({
    required this.game,
    required this.state,
    this.session,
    this.events = const [],
    required this.reportAd,
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
              _QueueAdCard(adState: s.adState!, reportAd: widget.reportAd),
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
  final Future<void> Function(
    SessionAdAction action,
    String adId, {
    int? watchedMs,
  })
  reportAd;

  const _QueueAdCard({required this.adState, required this.reportAd});

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
            // Play the first ad that has a media source; remaining ads are
            // listed as metadata.
            for (final ad in adState.ads)
              if (QueueAdPlayer.resolveMediaUrl(ad) != null) ...[
                QueueAdPlayer(
                  ad: ad,
                  onReport: (action, {int? watchedMs}) =>
                      reportAd(action, ad.adId, watchedMs: watchedMs),
                ),
                const SizedBox(height: 12),
              ],
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (ad.title ?? ad.adId).isNotEmpty
                                ? ad.title ?? ad.adId
                                : ad.adId,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Neon.ink,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (ad.description != null &&
                              ad.description!.isNotEmpty)
                            Text(
                              ad.description!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Neon.inkMuted,
                                fontSize: 11.5,
                              ),
                            ),
                        ],
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
/// — or parking the cursor at the top edge — shows the chrome; tapping the
/// video locks the mouse. Layout borrows from open_next's stream screen,
/// themed with Neon.
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

class _ReadySurfaceState extends State<_ReadySurface>
    with WidgetsBindingObserver {
  bool _chromeVisible = true;

  /// When the live session started. Owned here (this state lives for the whole
  /// stream) rather than inside the timer widget so the clock survives the
  /// chrome toggling the timer out of the tree when the stream UI is hidden.
  late final DateTime _sessionStartedAt = DateTime.now();

  /// True while the OS pointer is locked: cursor hidden, raw movement deltas
  /// stream straight to the game so FPS-style look works without the cursor
  /// hitting the window edge. The capture click is consumed; a double-Esc
  /// shows the chrome and releases it (a single Esc goes to the game).
  bool _mouseLocked = false;

  /// True while the window is in real OS fullscreen. Entering fullscreen lets
  /// the compositor (KWin) unredirect the window to direct scanout — one fewer
  /// full-screen GPU pass per frame, which is the difference between 31 and
  /// 60 fps UI on a weak iGPU (OpenNOW runs its games fullscreen for the same
  /// reason). Only used on desktop; the in-app Fullscreen button and the
  /// capture-click both route through [_enterMouseLock].
  bool _osFullscreen = false;

  /// Height of the top-edge escape zone (logical px). While in-game, parking
  /// the cursor here shows the stream UI — the reliable, mouse-only way out.
  /// Double-Esc needs the keyboard, which some Wayland compositors stop
  /// delivering to the app during OS fullscreen; the edge never does.
  static const double _edgeZoneHeight = 28;
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

  /// The keyboard only ever closes on a deliberate action: the Android system
  /// back button, or the user touching the non-keyboard stream UI (video tap /
  /// Hide UI rides [_enterGameMode] which already drops it). It must NEVER
  /// close on its own while the user is typing.
  ///
  /// Dismissals that never route through this widget (the OS back button /
  /// swipe-down / tap outside while the IME is open) are detected through
  /// [_keyboardFocus]: EditableText's `connectionClosed` unfocuses its node
  /// the moment the platform stops the IME.
  ///
  /// Two guards keep typing from tripping that signal:
  /// 1. The hidden field is keyed in the surface [Stack], so when the
  ///    server-driven cursor overlay is inserted in front of it (the game
  ///    shows a text caret the moment a character is typed into a chat/login
  ///    field), index-based reconciliation does NOT recreate the field's
  ///    element and detach its focus node.
  /// 2. Focus loss alone never closes immediately: it is debounced and gated
  ///    on the IME inset having actually collapsed, so a transient drop from a
  ///    predictive IME (which resets the input connection on each committed
  ///    character) is treated as the keyboard still being up.
  Timer? _keyboardCloseDebounce;
  static const Duration _keyboardCloseDelay = Duration(milliseconds: 350);

  /// True while a tap that dismissed the soft keyboard (the
  /// [UserSettings.keyboardTapToDismiss] toggle) is in flight, so the
  /// corresponding pointer-up does not forward a stray click to the game —
  /// the tap was spent closing the IME, not clicking the stream.
  bool _keyboardDismissTap = false;

  /// When the Android back button is delivered as a key event, it lands on the
  /// surface's [Focus.onKeyEvent] AND may also arrive as a system pop through
  /// the navigator. `handleSystemBack` records the last handling time so the
  /// second delivery of the same physical press is deduplicated instead of
  /// toggling the chrome twice (show-then-hide, which looks like "back does
  /// nothing").
  DateTime? _lastBackHandledAt;
  static const Duration _backDedupeWindow = Duration(milliseconds: 250);

  /// Live stream-settings sidebar (gamepad scale/opacity, stats, sensitivity).
  bool _streamSettingsOpen = false;

  /// Surface focus owner so a physical/hardware keyboard keeps routing keys to
  /// the stream from any Android input source (e.g. scrcpy --otg), and the
  /// focus is reclaimed after the soft keyboard closes.
  final FocusNode _gameFocus = FocusNode();

  /// Physical Android gamepad (USB/Bluetooth) bridge — automatic, no UI.
  PhysicalGamepad? _physicalGamepad;

  /// Bitmask of mouse buttons currently pressed on the video surface, used to
  /// detect which button a down/up event refers to (GFN protocol is 1-based
  /// single-button events).
  int _pressedMouseButtons = 0;

  /// True while a click lands with chrome hidden and the mouse unlocked. That
  /// click is consumed as the "capture click" that enters mouse lock via the
  /// tap handler (never streamed to the game), matching cloud-gaming
  /// click-to-capture conventions.
  bool _consumingClickForLock = false;

  // --- In-game cursor overlay (WebRTC cursor_channel) -----------------------

  /// Decoded custom cursor bitmap bytes (PNG), when the current cursor is a
  /// custom image rather than a predefined style.
  Uint8List? _cursorImageBytes;
  int _cursorHotspotX = 0;
  int _cursorHotspotY = 0;
  double _cursorScale = 1;

  /// Custom cursor bitmaps keyed by server cursor id (OpenNOW's cursorCache).
  /// The server streams the image once per id and later updates reference the
  /// id without re-sending the bytes — without this cache those updates would
  /// render nothing. The full shape (hotspot + scale) is cached too so an
  /// id-only update doesn't reset the hotspot to 0 and misplace the cursor.
  final Map<int, ({Uint8List bytes, int hotspotX, int hotspotY, double scale})>
  _cursorImageCache = {};

  /// Decoded RGBA bitmaps for predefined cursor ids (OpenNOW renders the
  /// built-in PREDEFINED_CURSORS client-side too — it never swaps the OS
  /// cursor, which would freeze the mouse on the soft-lock path). Keyed by
  /// server id, decoded once from the ported 1-bit ICO table.
  final Map<int, ({int width, int height, Uint8List rgba})>
  _predefinedBitmapCache = {};

  /// Decoded [ui.Image] of the current predefined cursor, rendered via
  /// [RawImage] (predefined bitmaps are raw RGBA from the ICO decoder, which
  /// `Image.memory` can't decode). Null while a custom cursor is active.
  ui.Image? _cursorPredefinedImage;

  /// Server id of the cursor [_cursorPredefinedImage] was decoded from, so
  /// id-only re-streams of the same style skip the (re)decode.
  int? _cursorPredefinedId;

  /// Generation guard so a slow [ui.decodeImageFromPixels] callback from an
  /// older cursor can't clobber the current one.
  int _predefinedImageGen = 0;

  /// Decoded [ui.Image] of the current *custom* cursor (PNG from the
  /// cursor_channel), rendered via [RawImage] exactly like the predefined
  /// path. `Image.memory` proved unreliable for these GFN cursor PNGs (silent
  /// no-op paint), so custom bitmaps take the same decoded-image route.
  ui.Image? _cursorCustomImage;

  /// Generation guard for the async [ui.instantiateImageCodec] custom decode,
  /// so a slow decode of a stale cursor can't clobber the current one.
  int _customImageGen = 0;

  /// Pixel dimensions of the *currently rendered* cursor bitmap (custom PNG
  /// via [pngPixelSize], or the decoded predefined ICO), so the overlay can
  /// render at native resolution on any display scale.
  int _cursorBitmapW = 32;
  int _cursorBitmapH = 32;

  /// True once the server has told us the game cursor is active.
  bool _cursorVisible = false;

  /// Predefined cursor *style* label from the server (e.g. "crosshair"), used
  /// to map to a native OS cursor when [UserSettings.inputCursorNative] is on
  /// and the pointer isn't locked. 'custom' means a bitmap (no native equiv).
  String _cursorOsStyle = 'default';

  /// True once the tracked position is meaningful (server position applied on
  /// the hidden→visible transition, or deltas have moved it).
  bool _cursorPositionKnown = false;

  /// Tracked cursor position in normalized 0..65535 space (server units), so
  /// window resizes don't break placement.
  double _cursorNormX = 0;
  double _cursorNormY = 0;

  /// Fired whenever the tracked cursor position changes while in-game, so the
  /// overlay repaints on the same cadence as the mouse moves (like OpenNOW's
  /// transform-updated canvas). Scoped to the cursor subtree via
  /// [ValueListenableBuilder] so repainting a cursor frame never rebuilt the
  /// whole stream surface.
  final ValueNotifier<Offset> _cursorPos = ValueNotifier<Offset>(Offset.zero);

  /// Last shader filter settings pushed to the native renderer, so the
  /// settings listener only fires the method channel on actual changes.
  late VideoShaderSettings _lastPushedShader;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _keyboardFocus.addListener(_onKeyboardFocusChanged);
    _attachCursorOverlay(widget.transport);
    _physicalGamepad = PhysicalGamepad(_onPhysicalGamepadState);
    // Push the video shader filter settings to the native GPU renderer and
    // keep it in sync while this surface is live, so sidebar slider changes
    // apply to the running stream without re-connecting (the GL/D3D post pass
    // reads the process-wide state on every composite).
    _lastPushedShader = widget.settings.videoShader;
    widget.settings.addListener(_onShaderSettingsChanged);
    unawaited(pushVideoShaderSettings(widget.settings.videoShader));
  }

  /// Forwards shader filter changes to the native renderer (deduped on the
  /// settings object — unrelated settings changes skip the method call).
  void _onShaderSettingsChanged() {
    final shader = widget.settings.videoShader;
    if (shader == _lastPushedShader) return;
    _lastPushedShader = shader;
    unawaited(pushVideoShaderSettings(shader));
  }

  /// Fired on every focus change of the hidden keyboard [TextField].
  ///
  /// When the platform stops the IME for a focused text field (Android system
  /// back, swipe-down, tap outside), EditableText's `connectionClosed` calls
  /// `unfocus` on its node — focus leaving while the keyboard is flagged open
  /// is the "the OS dismissed it behind our back" case. But focus loss is NOT
  /// instant proof: predictive IMEs transiently reset the input connection
  /// (and with it focus) while committing characters, so the dismissal is only
  /// committed once the loss persists AND the IME inset has collapsed (a live
  /// IME always occupies screen space). Any keystroke ([_onKeyboardChanged])
  /// or recovered focus cancels the pending close. The explicit close paths
  /// set `_keyboardOpen = false` before unfocusing, so this just no-ops there.
  void _onKeyboardFocusChanged() {
    if (!mounted || !_keyboardOpen) return;
    if (_keyboardFocus.hasFocus) {
      // Focus came back from a transient IME drop — abort the pending close.
      _keyboardCloseDebounce?.cancel();
      _keyboardCloseDebounce = null;
      return;
    }
    _scheduleKeyboardAutoClose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Some Android builds hide the IME on back/swipe-down without closing the
    // input connection, so the focus listener above never fires and the open
    // flag (and the stale connection) keeps the OS swallowing subsequent back
    // presses. Watch the inset directly: a collapse while the keyboard is
    // flagged open is a real dismissal and cleans the stale state up.
    _scheduleKeyboardAutoClose();
  }

  /// Debounces the keyboard auto-close. Triggered by a dropped focus on the
  /// hidden field or by the IME inset collapsing; closes only when the inset
  /// stays gone (a live IME always occupies space). Typing
  /// ([_onKeyboardChanged]) and recovered focus cancel it. It only clears the
  /// keyboard state — revealing the chrome is [handleSystemBack]'s job, so a
  /// stray auto-close never flashes the UI mid-edit.
  void _scheduleKeyboardAutoClose() {
    if (!mounted || !_keyboardOpen) return;
    if (View.of(context).viewInsets.bottom > 0) {
      _keyboardCloseDebounce?.cancel();
      _keyboardCloseDebounce = null;
      return;
    }
    _keyboardCloseDebounce ??= Timer(_keyboardCloseDelay, () {
      _keyboardCloseDebounce = null;
      if (!mounted || !_keyboardOpen) return;
      if (View.of(context).viewInsets.bottom > 0) return;
      setState(() {
        _keyboardOpen = false;
      });
      // Tear down the (possibly stale) input connection so the OS no longer
      // treats a keyboard as active and swallows back presses.
      _keyboardFocus.unfocus();
      // Hand the hardware-keyboard focus back to the stream surface so
      // physical keys keep reaching the game after the IME is dismissed.
      _gameFocus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant _ReadySurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transport != widget.transport) {
      _detachCursorOverlay(oldWidget.transport);
      _attachCursorOverlay(widget.transport);
    }
  }

  void _attachCursorOverlay(StreamTransport? transport) {
    transport?.cursorOverlay?.addListener(_onCursorOverlay);
  }

  void _detachCursorOverlay(StreamTransport? transport) {
    transport?.cursorOverlay?.removeListener(_onCursorOverlay);
  }

  void _onCursorOverlay() {
    final update = widget.transport?.cursorOverlay?.value;
    if (update == null) return;
    final wasVisible = _cursorVisible;
    if (update.custom) {
      // Custom bitmap: cache + render via a decoded ui.Image (RawImage). Any
      // stale predefined image is dropped (disposed, not just unreferenced —
      // ui.Image is a native resource).
      if (_cursorPredefinedImage != null) {
        _predefinedImageGen++; // invalidate any in-flight predefined decode
        _cursorPredefinedImage!.dispose();
        _cursorPredefinedImage = null;
      }
      // A custom cursor is always renderable once the server references one.
      // (OpenNOW drives visibility from `style !== "none"`; custom cursors
      // are never "none".)
      _cursorVisible = true;
      if (update.imageBytes != null) {
        // Full bitmap update: cache the complete shape under its id so later
        // id-only updates reuse it, and adopt THIS message's shape. Id-only
        // re-streams send stale 0/0.0 hotspot/scale placeholders that must NOT
        // overwrite the cached values, so they are only lowered here alongside
        // the real bitmap.
        _cursorImageCache[update.cursorId] = (
          bytes: update.imageBytes!,
          hotspotX: update.hotspotX ?? 0,
          hotspotY: update.hotspotY ?? 0,
          scale: update.scale ?? 1,
        );
        _cursorImageBytes = update.imageBytes;
        _cursorHotspotX = update.hotspotX ?? 0;
        _cursorHotspotY = update.hotspotY ?? 0;
        _cursorScale = update.scale ?? 1;
        final size = pngPixelSize(update.imageBytes!);
        if (size != null) {
          _cursorBitmapW = size.$1;
          _cursorBitmapH = size.$2;
        }
        _decodeCustomImage(update.imageBytes!);
      } else {
        // Id-only re-stream: reuse the cached shape exactly (image + hotspot
        // + scale). Without this the cursor would jump to the top-left corner
        // of the bitmap; trusting the message's 0/0.0 hotspot+scale would make
        // it draw at zero size / the wrong offset.
        final cached = _cursorImageCache[update.cursorId];
        if (cached == null) return; // nothing renderable yet
        _cursorImageBytes = cached.bytes;
        _cursorHotspotX = cached.hotspotX;
        _cursorHotspotY = cached.hotspotY;
        _cursorScale = cached.scale;
      }
    } else {
      // Predefined style: render the built-in cursor bitmap client-side
      // (like OpenNOW) instead of swapping the OS cursor. The OS cursor stays
      // hidden in-game (_videoCursor) — showing it freezes the mouse on the
      // soft-lock path. id 0 (style 'none') renders as a hidden cursor.
      _cursorImageBytes = null;
      if (_cursorCustomImage != null) {
        _customImageGen++; // invalidate any in-flight custom decode
        _cursorCustomImage!.dispose();
        _cursorCustomImage = null;
      }
      final predefined = predefinedCursorFor(update.cursorId);
      if (predefined.style == 'none') {
        _cursorVisible = false;
        _cursorOsStyle = 'none';
      } else {
        _cursorOsStyle = predefined.style;
        final bitmap =
            _predefinedBitmapCache[update.cursorId] ??
            decodeIcoCursor(base64Decode(predefined.imageBase64));
        if (bitmap == null) return; // malformed table entry — skip
        _predefinedBitmapCache[update.cursorId] = bitmap;
        _cursorBitmapW = bitmap.width;
        _cursorBitmapH = bitmap.height;
        _cursorHotspotX = predefined.hotspotX;
        _cursorHotspotY = predefined.hotspotY;
        _cursorScale = 1;
        _cursorVisible = true;
        _cursorOsStyle = 'custom'; // bitmap — no native OS cursor equivalent
        // Skip the async decode when this id is already the displayed cursor
        // (id-only updates re-stream the same style every frame); the image
        // only needs (re)building when the cursor actually changes.
        if (_cursorPredefinedId != update.cursorId) {
          _cursorPredefinedId = update.cursorId;
          _decodePredefinedImage(
            bitmap.rgba,
            bitmap.width,
            bitmap.height,
            update.cursorId,
          );
        }
      }
    }
    // The server's absolute position only lands on the hidden→visible
    // transition (OpenNOW's shouldApplyCursorChannelPosition).
    if (!wasVisible && update.positionX != null && update.positionY != null) {
      _cursorNormX = update.positionX!.toDouble();
      _cursorNormY = update.positionY!.toDouble();
      _cursorPositionKnown = true;
    }
    setState(() {});
    // A freshly-shown cursor: immediately pin the server cursor to the overlay
    // position so the game cursor and the client overlay never start apart.
    if (_cursorVisible &&
        _cursorPositionKnown &&
        !_chromeVisible &&
        widget.settings.inputCursorOverlay) {
      widget.transport?.sendMouseAbsolute(
        x: _cursorNormX.round(),
        y: _cursorNormY.round(),
        width: 65535,
        height: 65535,
      );
    }
  }

  /// Converts the decoded ICO RGBA buffer into a [ui.Image] for [RawImage].
  /// Async, so guarded by [_predefinedImageGen] against out-of-order callbacks
  /// (a slow decode from a previous cursor must not overwrite the current one).
  void _decodePredefinedImage(
    Uint8List rgba,
    int width,
    int height,
    int cursorId,
  ) {
    final gen = ++_predefinedImageGen;
    ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, (
      image,
    ) {
      if (!mounted || gen != _predefinedImageGen) {
        image.dispose();
        return;
      }
      setState(() {
        _cursorPredefinedImage?.dispose();
        _cursorPredefinedImage = image;
      });
    });
  }

  /// Decodes a custom cursor PNG into a [ui.Image] for [RawImage], the same
  /// robust path the predefined cursors take. `Image.memory` proved to paint
  /// nothing for these GFN cursor bitmaps, so the custom cursors use a decoded
  /// [ui.Image] too. Async and guarded by [_customImageGen] so a slow decode
  /// of a stale cursor can't clobber the current one.
  void _decodeCustomImage(Uint8List bytes) {
    final gen = ++_customImageGen;
    ui
        .instantiateImageCodec(
          bytes,
          targetWidth: _cursorBitmapW,
          targetHeight: _cursorBitmapH,
        )
        .then((codec) => codec.getNextFrame())
        .then<void>((frame) {
          if (!mounted || gen != _customImageGen) {
            frame.image.dispose();
            return;
          }
          setState(() {
            _cursorCustomImage?.dispose();
            _cursorCustomImage = frame.image;
          });
        })
        .catchError((Object _) {
          // Unreadable bitmap: keep the previous cursor; the debug overlay
          // box (when enabled) still shows the tracked position.
        });
  }

  /// Moves the tracked cursor by the *adjusted* deltas (sensitivity + accel
  /// already applied) — OpenNOW's `moveBy`. Runs under both soft lock and a
  /// native grab: under a grab the OS cursor is captured/hidden so the game
  /// cursor must still be drawn client-side at the tracked position.
  void _trackCursorPosition(double dx, double dy) {
    if (!widget.settings.inputCursorOverlay) return;
    if (!mounted) return;
    final size = MediaQuery.sizeOf(context);
    if (size.width <= 0 || size.height <= 0) return;
    // First delta without a server-anchored position: start at the viewport
    // center (OpenNOW's `positionInitialized` centering) so the cursor doesn't
    // appear from a corner. Deltas are relative, so this only matters once.
    if (!_cursorPositionKnown) {
      _cursorNormX = 32768;
      _cursorNormY = 32768;
      _cursorPositionKnown = true;
    }
    _cursorNormX = (_cursorNormX + dx / size.width * 65535).clamp(0.0, 65535.0);
    _cursorNormY = (_cursorNormY + dy / size.height * 65535).clamp(
      0.0,
      65535.0,
    );
    // Repaint only the cursor overlay on this delta (not the whole surface),
    // mirroring OpenNOW's canvas transform update so the cursor tracks the
    // mouse input smoothly instead of waiting for the next server position.
    if (_cursorVisible && _cursorPositionKnown && !_chromeVisible) {
      _cursorPos.value = Offset(_cursorNormX, _cursorNormY);
    }
  }

  /// OS cursor shown over the video surface. In-game (mouse locked) the OS
  /// cursor is ALWAYS hidden — never swapped to a real predefined cursor. On
  /// the soft-lock path (no native grab) the OS cursor is the one the user
  /// physically moves, so showing it means it hits the window edge and the
  /// pointer deltas stop; the game cursor is drawn client-side instead.
  ///
  /// When NOT locked (chrome / game menus), a native-cursor mapping can be
  /// used so the window manager renders the game's predefined cursor style
  /// (arrow/text/wait/crosshair/resize) — including its own compositor effects
  /// like speed-stretch. Custom bitmap cursors always fall back to the overlay.
  SystemMouseCursor get _videoCursor {
    if (_mouseLocked) return SystemMouseCursors.none;
    if (widget.settings.inputCursorNative && _cursorVisible) {
      final native = _nativeCursorForStyle(_cursorOsStyle);
      if (native != null) return native;
    }
    return SystemMouseCursors.basic;
  }

  /// Maps a predefined cursor style to the corresponding OS cursor so the WM
  /// renders it natively. Returns null for custom bitmaps/unknown styles,
  /// leaving the caller to use the basic arrow.
  SystemMouseCursor? _nativeCursorForStyle(String style) {
    return switch (style) {
      'text' => SystemMouseCursors.text,
      'wait' => SystemMouseCursors.wait,
      'progress' => SystemMouseCursors.progress,
      'crosshair' => SystemMouseCursors.precise,
      'move' => SystemMouseCursors.move,
      'help' => SystemMouseCursors.help,
      'pointer' => SystemMouseCursors.click,
      'ns-resize' => SystemMouseCursors.resizeUpDown,
      'ew-resize' => SystemMouseCursors.resizeLeftRight,
      'nwse-resize' => SystemMouseCursors.resizeUpLeftDownRight,
      'nesw-resize' => SystemMouseCursors.resizeUpRightDownLeft,
      _ => null,
    };
  }

  // Gamepad bitmask + stick state (normalized -1..1), streamed over the
  // input data channel once the NVST handshake completes.
  int _gamepadButtons = 0;
  double _leftStickX = 0;
  double _leftStickY = 0;
  double _rightStickX = 0;
  double _rightStickY = 0;
  double _leftTrigger = 0;
  double _rightTrigger = 0;

  /// Stick drags are coalesced onto a one-shot flush timer instead of sending
  /// per pointer-move event. Touch pointers deliver moves at hundreds of Hz;
  /// the mouse pipeline already batches on a timer (see the mouse section),
  /// and sending one state packet per event floods the SCTP input channel and
  /// steals UI-thread frames from the video decode. A real controller samples
  /// at ~60Hz, so coalescing to 16ms loses nothing perceptible.
  Timer? _gamepadFlushTimer;
  static const Duration _gamepadFlushInterval = Duration(milliseconds: 16);

  void _onLeftStickDrag(Offset offset) {
    _leftStickX = offset.dx;
    _leftStickY = offset.dy;
    _scheduleGamepadFlush();
  }

  void _onRightStickDrag(Offset offset) {
    _rightStickX = offset.dx;
    _rightStickY = offset.dy;
    _scheduleGamepadFlush();
  }

  /// Latch-and-flush: the latest stick values go out on a fixed 16ms cadence
  /// as long as moves keep coming. Discrete events (buttons, D-pad, release)
  /// still go out immediately via [_sendGamepadState].
  void _scheduleGamepadFlush() {
    if (_gamepadFlushTimer != null) return;
    _gamepadFlushTimer = Timer(_gamepadFlushInterval, () {
      _gamepadFlushTimer = null;
      _sendGamepadState();
    });
  }

  /// Routes Escape keys. While the stream UI (chrome) is showing, a single
  /// Esc hides it (back into the game); otherwise a single press is read by
  /// the game and a quick second press shows the stream UI.
  void _handleEscKey(KeyEvent event) {
    if (event is KeyRepeatEvent) return;
    if (event is KeyUpEvent) {
      if (_escDownForwarded) widget.transport?.sendKeyEvent(event);
      _escDownForwarded = false;
      return;
    }
    if (event is! KeyDownEvent) return;
    // Stream UI visible: Esc hides it and enters in-game mode.
    if (_chromeVisible) {
      _escArmed = false;
      _escDownForwarded = false;
      _escTimer?.cancel();
      _escTimer = null;
      setState(() {
        _chromeVisible = false;
        _streamSettingsOpen = false;
      });
      return;
    }
    if (_escArmed) {
      // Second Esc within the window: show the stream UI. The game already
      // received the first press, so this one is consumed entirely.
      _escArmed = false;
      _escTimer?.cancel();
      _escTimer = null;
      if (!_chromeVisible) {
        // Release just the pointer grab so the cursor is clickable, but do
        // NOT leave OS fullscreen (that flashes/minimizes the window on
        // Wayland). Fullscreen exits via the Fullscreen button / top edge.
        final sub = _pointerLockSub;
        _pointerLockSub = null;
        _nativeGrabLive = false;
        _mouseLocked = false;
        if (sub != null) _pendingUnlock = sub.cancel();
        setState(() => _chromeVisible = true);
      }
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
  /// Enters in-game mode (chromatically + system bars) synchronously and
  /// idempotently. The synchronous half is what touch/screen taps rely on so
  /// hiding the UI is immediate and reliable — no awaits, no pointer-grab.
  void _enterGameMode() {
    if (mounted) {
      setState(() {
        _mouseLocked = true;
        _chromeVisible = false;
        _streamSettingsOpen = false;
        // Entering in-game mode (touching non-keyboard stream UI) dismisses
        // the soft keyboard — its focus would otherwise fight the
        // pointer-lock tap. The flag is cleared BEFORE the unfocus so the
        // focus listener sees the close as already handled.
        if (_keyboardOpen) {
          _keyboardOpen = false;
          _keyboardCloseDebounce?.cancel();
          _keyboardCloseDebounce = null;
          _keyboardFocus.unfocus();
        }
      });
    }
    _applyMobileSystemUi(true);
  }

  void _toggleChromeFromKey() {
    if (_chromeVisible) {
      // Hide: back into the game (mouse deltas reach the game again).
      setState(() {
        _chromeVisible = false;
        _mouseLocked = true;
        _streamSettingsOpen = false;
      });
      return;
    }
    // Show: cancel just the pointer grab so the cursor is clickable — but DO
    // NOT call _exitMouseLock()/leave OS fullscreen (that flashes/minimizes
    // the window on Wayland). Fullscreen exits only via the Fullscreen button
    // or the top-edge escape zone.
    final sub = _pointerLockSub;
    _pointerLockSub = null;
    _nativeGrabLive = false;
    _mouseLocked = false;
    if (sub != null) _pendingUnlock = sub.cancel();
    setState(() => _chromeVisible = true);
  }

  /// Fullscreen button: entering enters in-game mode (pointer lock + OS
  /// fullscreen); while already in OS fullscreen it exits back to the window.
  void _toggleFullscreen() {
    if (_osFullscreen) {
      setState(() {
        _chromeVisible = true;
        _streamSettingsOpen = false;
      });
      _exitMouseLock();
      return;
    }
    _enterMouseLock();
  }

  /// Same as [_enterGameMode] but for the soft-keyboard button: the chrome
  /// hides so the stream is immersive while the OS keyboard stays up. Switches
  /// the system to immersive would dismiss the IME on some Android builds, so
  /// the system bars are left alone here — the keyboard takes the screen.
  void _hideChromeKeepKeyboard() {
    if (mounted) {
      setState(() {
        _mouseLocked = true;
        _chromeVisible = false;
        _streamSettingsOpen = false;
      });
    }
  }

  /// True when in-game and a pointer grab is already active (or the platform
  /// has no grab at all — mobile, where in-game mode IS the soft lock), so
  /// [_enterMouseLock] would be a no-op. Re-entry is allowed while the UI is
  /// showing, and also when the chrome is hidden but no grab session exists
  /// (the Hide-UI button / Esc-hide path sets [_mouseLocked] without ever
  /// starting the grab) — in that state the next surface click must engage
  /// the real grab instead of silently staying soft-locked.
  bool get _grabAlreadyEngaged =>
      _mouseLocked &&
      !_chromeVisible &&
      (_pointerLockSub != null ||
          !(kIsWeb ||
              Platform.isLinux ||
              Platform.isMacOS ||
              Platform.isWindows));

  Future<void> _enterMouseLock() async {
    // Allow re-entry whenever the UI is showing (the "fullscreen once" bug:
    // leaving game via the back button leaves _mouseLocked stale, which would
    // otherwise make the next Fullscreen press a no-op).
    if (_grabAlreadyEngaged) return;
    // Wait for any pending unlock to land before creating a new session, so
    // its native unlock doesn't tear down the lock we're about to acquire.
    final pending = _pendingUnlock;
    _pendingUnlock = null;
    if (pending != null) await pending;
    if (!mounted) return;
    if (_grabAlreadyEngaged) return;
    // Real OS fullscreen alongside the in-game mode: the compositor stops
    // re-compositing the windowed surface (direct scanout), which is a
    // full-screen pass saved per frame on iGPUs. No-op on mobile/web and when
    // the platform plugin has no implementation. The flag is set BEFORE the
    // await so a dispose during the in-flight transition (user exits the
    // stream) still runs _leaveOsFullscreen and restores the window.
    if (!kIsWeb &&
        (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      _osFullscreen = true;
      try {
        await windowManager.setFullScreen(true);
      } catch (_) {
        _osFullscreen = false;
      }
      // Best-effort: some Wayland compositors drop keyboard focus during the
      // fullscreen transition; re-grab it so Esc keeps reaching the app.
      // Deliberately outside the state transition — a failure here must not
      // mark the window as non-fullscreen.
      if (_osFullscreen) {
        try {
          await windowManager.focus();
        } catch (_) {}
      }
    }
    if (!mounted) return;
    if (_grabAlreadyEngaged) return;
    _enterGameMode();
    // Mobile (Android/iOS) has no native pointer grab — the soft-lock state
    // IS the game mode; taps stream to the game directly. Only desktop/web
    // attempt the real grab.
    final canGrab =
        kIsWeb || Platform.isLinux || Platform.isMacOS || Platform.isWindows;
    if (!canGrab) return;
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
    _leaveOsFullscreen();
    _applyMobileSystemUi(false);
    if (sub != null) _pendingUnlock = sub.cancel();
  }

  /// Shows the stream UI when the cursor reaches the top edge while in-game.
  /// Releases the pointer lock and OS fullscreen so the user is never trapped,
  /// even when keyboard input is unavailable (Wayland fullscreen focus loss).
  void _showChromeFromEdge() {
    if (!mounted) return;
    if (_chromeVisible) return;
    // _exitMouseLock is safe unconditionally: _leaveOsFullscreen and the
    // pointer-lock cancel both no-op when nothing is active.
    _exitMouseLock();
    setState(() => _chromeVisible = true);
  }

  /// Releases in-game mode (pointer lock + OS fullscreen) without popping.
  /// Called by the stream page before route teardown so the native pointer
  /// grab is down before the engine can die (window-close path).
  void releaseInGameMode() {
    _exitMouseLock();
  }

  /// Restores the window from OS fullscreen when leaving in-game mode. Fired
  /// on double-Esc, pointer-lock release, and dispose. No-op on non-desktop.
  void _leaveOsFullscreen() {
    if (!_osFullscreen) return;
    _osFullscreen = false;
    if (kIsWeb ||
        !(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return;
    }
    unawaited(windowManager.setFullScreen(false).catchError((_) => false));
  }

  /// Hides or restores the Android/iOS system bars. `hide=true` (in-game /
  /// fullscreen) goes fully immersive so nothing overlays the stream; `false`
  /// restores the solid bars the app boots with. No-op on desktop/web.
  void _applyMobileSystemUi(bool hide) {
    if (kIsWeb) return;
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      SystemChrome.setEnabledSystemUIMode(
        hide ? SystemUiMode.immersiveSticky : SystemUiMode.manual,
        overlays: hide ? const [] : SystemUiOverlay.values,
      );
    } catch (_) {
      // Best-effort: a platform that can't switch modes must not break the
      // stream session.
    }
  }

  /// Fired when the platform releases the pointer on its own (e.g. the
  /// browser exits pointer lock on Esc during web builds).
  void _onPointerLockReleased() {
    _pendingUnlock = null;
    _leaveOsFullscreen();
    _applyMobileSystemUi(false);
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
    _mouseFlushTimer?.cancel();
    _mouseFlushTimer = null;
    _gamepadFlushTimer?.cancel();
    _gamepadFlushTimer = null;
    // Flush any deltas left in the coalescing buffer before the surface dies.
    _flushMouse();
    _detachCursorOverlay(widget.transport);
    _predefinedImageGen++; // invalidate any in-flight decode callback
    _cursorPredefinedImage?.dispose();
    _cursorPredefinedImage = null;
    _customImageGen++; // invalidate any in-flight custom decode
    _cursorCustomImage?.dispose();
    _cursorCustomImage = null;
    _cursorPos.dispose();
    _keyboardCloseDebounce?.cancel();
    _keyboardCloseDebounce = null;
    _keyboardFocus.removeListener(_onKeyboardFocusChanged);
    _keyboardController.dispose();
    _keyboardFocus.dispose();
    _physicalGamepad?.dispose();
    _gameFocus.dispose();
    widget.settings.removeListener(_onShaderSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _leaveOsFullscreen();
    _applyMobileSystemUi(false);
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

  // --- Mouse shaping pipeline (port of OpenNOW's mouseInput.ts) ------------

  /// Accumulated (post-transform) deltas awaiting the coalescing flush.
  double _pendingMouseDx = 0;
  double _pendingMouseDy = 0;

  /// Sub-pixel remainders carried across flushes so micro-movements are not
  /// lost to integer quantization.
  double _mouseResidualX = 0;
  double _mouseResidualY = 0;

  Timer? _mouseFlushTimer;
  int _mouseFlushIntervalMs = 0;

  /// Accumulated nominal flush time across ticks, used to re-evaluate the
  /// adaptive interval on a ~0.5 s window (OpenNOW recomputes on its 500 ms
  /// stats poll).
  int _mouseFlushWindowMs = 0;

  /// Absolute-direct-touch: touch maps the pointer to the exact touched spot
  /// instead of streaming relative trackpad-style deltas.
  bool get _touchAbsolute =>
      widget.settings.inputTouchMode == TouchInputMode.absolute;

  /// Relative-touch tap vs drag tracking: a click is only emitted on finger-up
  /// if the finger didn't stray past [_touchSlop] (sending a down on touch and
  /// an up on release otherwise double-clicks in the game).
  Offset? _touchDownPos;
  bool _touchPointerDragged = false;
  static const double _touchSlop = 6.0;

  /// Pins the server cursor to the absolute position of a touch, in normalized
  /// 0..65535 server space (GFN input type 5). Direct-touch taps still send the
  /// primary button via the normal down/up path.
  /// Pins the server cursor to the absolute pointer position, in normalized
  /// 0..65535 server space (GFN input type 5). Used for direct-touch and to
  /// align a click to the exact spot a pointer (e.g. OTG mouse) points at,
  /// when no OS grab is active.
  void _sendAbsoluteAt(Offset localPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = _videoContentRect(box.size);
    if (rect.width <= 0 || rect.height <= 0) return;
    final x = ((localPosition.dx - rect.left) / rect.width * 65535)
        .round()
        .clamp(0, 65535);
    final y = ((localPosition.dy - rect.top) / rect.height * 65535)
        .round()
        .clamp(0, 65535);
    // Keep the client-drawn cursor overlay parked under the finger so the
    // server cursor and overlay stay aligned in absolute mode.
    if (widget.settings.inputCursorOverlay) {
      _cursorNormX = x.toDouble();
      _cursorNormY = y.toDouble();
      _cursorPositionKnown = true;
      if (_cursorVisible && !_chromeVisible) {
        _cursorPos.value = Offset(_cursorNormX, _cursorNormY);
      }
    }
    widget.transport?.sendMouseAbsolute(
      x: x,
      y: y,
      width: 65535,
      height: 65535,
    );
  }

  /// The "contain"-fitted rectangle the streamed video actually occupies
  /// within [surface], so absolute pointers map onto the game viewport (not
  /// the whole window with its letterbox bars). Aspect is taken from the
  /// transport's video dimensions when known, else assumed 16:9.
  Rect _videoContentRect(Size surface) {
    if (surface.width <= 0 || surface.height <= 0) {
      return Offset.zero & surface;
    }
    var aspect = 16 / 9;
    final snap = widget.transport?.stats.value;
    final vw = snap?.videoWidth;
    final vh = snap?.videoHeight;
    if (vw != null && vh != null && vw > 0 && vh > 0) {
      aspect = vw / vh;
    }
    final w = surface.width;
    final h = surface.height;
    final fittedW = h * aspect;
    if (fittedW <= w) {
      return Rect.fromLTWH((w - fittedW) / 2, 0, fittedW, h);
    }
    final fittedH = w / aspect;
    return Rect.fromLTWH(0, (h - fittedH) / 2, w, fittedH);
  }

  void _sendMouseDelta(Offset delta) {
    final s = widget.settings;
    final transformed = applyMouseTransform(
      delta.dx,
      delta.dy,
      sensitivity: s.inputMouseSensitivity,
      accelerationPercent: s.inputMouseAcceleration,
    );
    _trackCursorPosition(transformed.dx, transformed.dy);
    _pendingMouseDx += transformed.dx;
    _pendingMouseDy += transformed.dy;
    if (s.inputMouseSamplingMs < 0) {
      // Immediate: every event (still keeps the sub-pixel residual).
      _flushMouse();
    } else {
      _ensureMouseFlushTimer();
    }
  }

  /// Sends the accumulated deltas. With precision on, the integer part of
  /// each axis goes out and the fraction stays in [_mouseResidualX/Y]; with
  /// precision off, each flush rounds to whole pixels.
  void _flushMouse() {
    // When the game cursor is being drawn client-side (overlay visible), pin
    // the server cursor to the SAME absolute position (input type 5) instead
    // of sending relative deltas. Relative deltas for a visible cursor drift
    // from the overlay across aspect/DPR, so clicks land off-target.
    if (widget.settings.inputCursorOverlay &&
        _cursorVisible &&
        _cursorPositionKnown &&
        !_chromeVisible) {
      widget.transport?.sendMouseAbsolute(
        x: _cursorNormX.round(),
        y: _cursorNormY.round(),
        width: 65535,
        height: 65535,
      );
      // The accumulated deltas already drove _cursorNorm; don't double-send
      // them as relative moves on top of the absolute pin.
      _pendingMouseDx = 0;
      _pendingMouseDy = 0;
      _mouseResidualX = 0;
      _mouseResidualY = 0;
      return;
    }

    final precision = widget.settings.inputMousePrecision;
    var dx = _pendingMouseDx;
    var dy = _pendingMouseDy;
    _pendingMouseDx = 0;
    _pendingMouseDy = 0;
    if (precision) {
      final qx = quantizeMouseDeltaWithResidual(dx, _mouseResidualX);
      final qy = quantizeMouseDeltaWithResidual(dy, _mouseResidualY);
      _mouseResidualX = qx.residual;
      _mouseResidualY = qy.residual;
      dx = qx.send.toDouble();
      dy = qy.send.toDouble();
    } else {
      dx = dx.roundToDouble();
      dy = dy.roundToDouble();
    }
    if (dx == 0 && dy == 0) return;
    widget.transport?.sendMouseMove(
      dx: dx.clamp(-32767, 32767).round(),
      dy: dy.clamp(-32767, 32767).round(),
    );
  }

  void _ensureMouseFlushTimer() {
    if (_mouseFlushTimer != null) return;
    if (_pendingMouseDx == 0 && _pendingMouseDy == 0) return;
    _mouseFlushTimer = Timer(
      Duration(milliseconds: _currentMouseFlushIntervalMs()),
      _onMouseFlushTick,
    );
  }

  /// Coalesce interval: a fixed 4/8/16 ms when the user picked one, otherwise
  /// OpenNOW's adaptive policy — base 4 ms on raw pointer-lock deltas, 8 ms
  /// otherwise, backing off toward 20 ms under SCTP backpressure and
  /// tightening toward 2 ms when the reliable queue is empty.
  int _currentMouseFlushIntervalMs() {
    final fixed = widget.settings.inputMouseSamplingMs;
    if (fixed > 0) return fixed;
    final base = _nativeGrabLive ? 4 : 8;
    return chooseAdaptiveMouseFlushInterval(
      baseIntervalMs: base,
      currentIntervalMs: _mouseFlushIntervalMs == 0
          ? base
          : _mouseFlushIntervalMs,
      reliableBufferedAmount: widget.transport?.inputQueueBufferedBytes ?? 0,
      canUsePartiallyReliableMouse: false,
      backpressureThresholdBytes: 64 * 1024,
      minIntervalMs: 2,
      maxIntervalMs: 20,
    );
  }

  void _onMouseFlushTick() {
    _mouseFlushTimer = null;
    // Accumulate the nominal flush time across ticks; once a ~0.5 s window
    // has elapsed, re-evaluate the adaptive interval from the current SCTP
    // pressure (OpenNOW recomputes on its 500 ms stats poll).
    _mouseFlushWindowMs += _currentMouseFlushIntervalMs();
    if (widget.settings.inputMouseSamplingMs == 0 &&
        _mouseFlushWindowMs >= 500) {
      _mouseFlushWindowMs = 0;
      _mouseFlushIntervalMs = _currentMouseFlushIntervalMs();
    }
    _flushMouse();
    if (_pendingMouseDx != 0 || _pendingMouseDy != 0) {
      _ensureMouseFlushTimer();
    }
  }

  void _onVideoPointerDown(PointerDownEvent event) {
    // When the soft keyboard is up, the hidden TextField owns focus. Any
    // _gameFocus.requestFocus() or _enterGameMode() here would yank the IME
    // away mid-typing — that's the "typing into the game's login field closes
    // the keyboard" bug. While the keyboard is open, a tap is forwarded to the
    // game as-is (so the in-game field being typed into can be focused/tapped)
    // and the focus is left alone.
    final keyboardOpen = _keyboardOpen;
    if (keyboardOpen && widget.settings.keyboardTapToDismiss) {
      // Tap-to-dismiss is on: touching the stream surface closes the soft
      // keyboard. The tap is consumed — it dismissed the IME, it did not click
      // the game (the matching pointer-up is suppressed via [_keyboardDismissTap]).
      _keyboardDismissTap = true;
      _dismissKeyboard();
      return;
    }
    if (!keyboardOpen) {
      // Any interaction with the surface reasserts that the stream owns the
      // hardware-keyboard focus (physical keys keep reaching the game).
      _gameFocus.requestFocus();
    }
    // Touch: leaving the UI is immediate and synchronous on the first touch.
    // Absolute mode clicks on touch (direct touch). Relative mode defers the
    // click to release and only fires it for a real tap (no drag) — sending a
    // down immediately AND an up on release produced a double-click.
    if (event.kind == PointerDeviceKind.touch) {
      if (keyboardOpen) {
        // Keep the IME up and stream the tap so interacting with the game's
        // text field doesn't dismiss the keyboard.
        if (!widget.settings.inputTouchEnabled) return;
        _touchDownPos = event.position;
        _touchPointerDragged = false;
        if (_touchAbsolute) {
          _sendAbsoluteAt(event.localPosition);
          _pressedMouseButtons |= kPrimaryMouseButton;
          widget.transport?.sendMouseButton(down: true, button: mouseLeft);
        }
        return;
      }
      if (_chromeVisible || !_mouseLocked) {
        _enterGameMode();
        return;
      }
      if (!widget.settings.inputTouchEnabled) return;
      _touchDownPos = event.position;
      _touchPointerDragged = false;
      if (_touchAbsolute) {
        _sendAbsoluteAt(event.localPosition);
        _pressedMouseButtons |= kPrimaryMouseButton;
        widget.transport?.sendMouseButton(down: true, button: mouseLeft);
      }
      return;
    }
    if (_chromeVisible) return; // chrome consumes; tap will hide it
    // A click on the video while the UI is visible (mouse path) hides it
    // immediately too — no need to wait for the tap recognizer.
    if (!keyboardOpen && !_mouseLocked) {
      _enterGameMode();
      return;
    }
    final newly = event.buttons & ~_pressedMouseButtons;
    _pressedMouseButtons = event.buttons;
    // Without an active OS grab (soft lock, OTG/absolute mouse, touchscreens),
    // a click must land on the cursor the user is aiming with. Only align an
    // absolute position when the game is actually SHOWING a cursor (menus /
    // chat): in look mode the cursor is hidden and a type-5 pin yanks the
    // camera to wherever the physical pointer happens to be (which drifts
    // from the tracked position at window edges / sensitivity != 1). And when
    // the cursor is visible, pin the TRACKED position the overlay/flush
    // already uses — never the raw physical pointer, or the visible game
    // cursor teleports on click.
    if (newly & kPrimaryMouseButton != 0 &&
        !(_pointerLockSub != null && _nativeGrabLive) &&
        _cursorVisible) {
      if (_cursorPositionKnown) {
        widget.transport?.sendMouseAbsolute(
          x: _cursorNormX.round(),
          y: _cursorNormY.round(),
          width: 65535,
          height: 65535,
        );
      } else {
        // No tracked position (overlay off / never server-anchored): align
        // the click to the physical pointer as a last resort.
        _sendAbsoluteAt(event.localPosition);
      }
    }
    for (var bit = 1; bit <= kForwardMouseButton; bit <<= 1) {
      if ((newly & bit) == 0) continue;
      final button = _gfnButtonForBit(bit);
      if (button != null) {
        widget.transport?.sendMouseButton(down: true, button: button);
      }
    }
  }

  void _onVideoPointerUp(PointerUpEvent event) {
    if (_keyboardDismissTap) {
      // This tap closed the soft keyboard — do not forward a click to the
      // game for it.
      _keyboardDismissTap = false;
      return;
    }
    if (event.kind == PointerDeviceKind.touch) {
      final absolute = _touchAbsolute;
      final wasDragged = _touchPointerDragged;
      _touchDownPos = null;
      _touchPointerDragged = false;
      if (absolute) {
        // Down was already sent on touch; release it here.
        if (_pressedMouseButtons & kPrimaryMouseButton != 0) {
          _pressedMouseButtons &= ~kPrimaryMouseButton;
          widget.transport?.sendMouseButton(down: false, button: mouseLeft);
        }
        return;
      }
      // Relative: a pure tap (finger never dragged) is one click, sent on
      // release; a drag already streamed movement deltas and must NOT also
      // fire a click (that was the double-click-on-release).
      if (wasDragged) {
        _pressedMouseButtons &= ~kPrimaryMouseButton;
        return;
      }
      if (!widget.settings.inputTouchEnabled) return;
      _pressedMouseButtons |= kPrimaryMouseButton;
      widget.transport?.sendMouseButton(down: true, button: mouseLeft);
      _pressedMouseButtons &= ~kPrimaryMouseButton;
      widget.transport?.sendMouseButton(down: false, button: mouseLeft);
      return;
    }
    if (_chromeVisible) return;
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
      if (event.kind == PointerDeviceKind.touch) {
        if (!widget.settings.inputTouchEnabled) return;
        if (_touchAbsolute) {
          _sendAbsoluteAt(event.localPosition);
          return;
        }
        // Relative: past the slop threshold this is a drag, not a tap — the
        // release must not emit a click.
        final start = _touchDownPos;
        if (start != null && (event.position - start).distance > _touchSlop) {
          _touchPointerDragged = true;
        }
      }
      _sendMouseDelta(event.delta);
    }
  }

  void _onVideoPointerHover(PointerHoverEvent event) {
    if (_pointerLockSub != null && _nativeGrabLive) return;
    if (!_chromeVisible) _sendMouseDelta(event.delta);
  }

  void _onVideoPointerCancel(PointerCancelEvent event) {
    if (_chromeVisible) return;
    _touchDownPos = null;
    _touchPointerDragged = false;
    _consumingClickForLock = false;
    _keyboardDismissTap = false;
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
    // GFN expects the NEGATED raw deltaY (the official client sends
    // -wheelEvent.deltaY unquantized; OpenNOW's onWheel does the same).
    // Flutter's scrollDelta.dy matches the browser's sign (positive =
    // scroll down), so negate here or scrolling is backwards. Also clamp to
    // int16 — fast scrolling can exceed it and the encoder's setInt16 throws
    // outside that range.
    final dy =
        (-event.scrollDelta.dy).round().clamp(-32768, 32767).toInt();
    if (dy != 0) widget.transport?.sendMouseWheel(delta: dy);
  }

  /// Physical Android gamepad state → the stream. Y axes are inverted like the
  /// on-screen stick (up = -1); buttons are the shared XInput bitmap.
  void _onPhysicalGamepadState(
    int buttons,
    double lx,
    double ly,
    double rx,
    double ry,
    double lt,
    double rt,
  ) {
    if (!mounted) return;
    _gamepadButtons = buttons;
    _leftStickX = lx;
    _leftStickY = -ly;
    _rightStickX = rx;
    _rightStickY = -ry;
    _leftTrigger = lt;
    _rightTrigger = rt;
    // Drop the virtual-pad latch timer: a physical controller already samples
    // at its own rate, so stream its latest state as it arrives.
    _gamepadFlushTimer?.cancel();
    _gamepadFlushTimer = null;
    _sendGamepadState();
  }

  void _sendGamepadState() {
    widget.transport?.sendGamepadState(
      buttons: _gamepadButtons,
      leftStickX: _leftStickX,
      leftStickY: _leftStickY,
      rightStickX: _rightStickX,
      rightStickY: _rightStickY,
      leftTrigger: _leftTrigger,
      rightTrigger: _rightTrigger,
    );
  }

  /// Sets a digital XInput gamepad bit (d-pad / start/select / home / LB / RB)
  /// and streams the new state immediately.
  void _setGamepadBit(int bit, bool down) {
    if (down) {
      _gamepadButtons |= bit;
    } else {
      _gamepadButtons &= ~bit;
    }
    _sendGamepadState();
  }

  /// Sets a trigger axis (0 = left, 1 = right) to [value] (0..1) and streams.
  void _setTrigger(int which, double value) {
    if (which == 0) {
      _leftTrigger = value;
    } else {
      _rightTrigger = value;
    }
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

  /// Closes the soft keyboard and hands the hardware-keyboard focus back to
  /// the stream surface. Always resets the open flag and any pending
  /// auto-close; used by the tap-to-dismiss path and the back button.
  void _dismissKeyboard() {
    if (!_keyboardOpen) return;
    setState(() {
      _keyboardOpen = false;
    });
    _keyboardCloseDebounce?.cancel();
    _keyboardCloseDebounce = null;
    _keyboardFocus.unfocus();
    _gameFocus.requestFocus();
  }

  void _toggleKeyboard() {
    // A manual toggle always overrides any pending auto-close.
    _keyboardCloseDebounce?.cancel();
    _keyboardCloseDebounce = null;
    setState(() {
      _keyboardOpen = !_keyboardOpen;
      if (_keyboardOpen) {
        _lastKeyboardText = '';
        _keyboardController.clear();
      } else {
        _keyboardFocus.unfocus();
        _gameFocus.requestFocus();
      }
    });
    if (_keyboardOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _keyboardFocus.requestFocus();
      });
    }
  }

  void _onKeyboardChanged(String text) {
    // Any committed character proves the IME is still up and being typed into
    // — cancel a pending auto-close from a transient focus drop.
    _keyboardCloseDebounce?.cancel();
    _keyboardCloseDebounce = null;
    final previous = _lastKeyboardText;
    _lastKeyboardText = text;
    final transport = widget.transport;
    if (transport == null) return;

    // Diff against the last committed text via the common PREFIX: the shared
    // leading run is unchanged, everything after it was either deleted (back
    // space for each) or newly typed (forwarded as text). A tail-based diff
    // breaks on plain appends — it read the just-typed char as a replacement
    // and emitted a spurious backspace on every keystroke.
    var common = 0;
    while (common < previous.length &&
        common < text.length &&
        previous.codeUnitAt(common) == text.codeUnitAt(common)) {
      common++;
    }
    final removed = previous.length - common;
    for (var i = 0; i < removed; i++) {
      _sendSyntheticKey(
        LogicalKeyboardKey.backspace,
        PhysicalKeyboardKey.backspace,
      );
    }

    // Forward the newly typed characters as text input.
    final added = text.substring(common);
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
    LogicalKeyboardKey logical,
    PhysicalKeyboardKey physical,
  ) {
    final now = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);
    widget.transport?.sendKeyEvent(
      KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: now,
        synthesized: true,
      ),
    );
    widget.transport?.sendKeyEvent(
      KeyUpEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: now,
        synthesized: true,
      ),
    );
  }

  /// Android system back: if the soft keyboard is up, close it and reveal the
  /// stream UI in the same press; otherwise toggle the chrome. Returns true
  /// when consumed.
  ///
  /// A back press while the IME is open is sometimes consumed by the OS (the
  /// focus listener clears the flag for that) and sometimes routed here (on
  /// predictive-back builds). Testing the flag, held focus AND the visible
  /// inset covers both, so the press always lands: it closes the keyboard AND
  /// shows the chrome, and a stale flag can never wedge the back button.
  bool handleSystemBack() {
    // The Android back button can be delivered twice for one press (once as a
    // key event handled by the surface Focus, once as a system pop through the
    // navigator). Deduplicate so the second delivery doesn't re-toggle the
    // chrome, which would look like "back did nothing".
    final now = DateTime.now();
    final lastBack = _lastBackHandledAt;
    _lastBackHandledAt = now;
    if (lastBack != null && now.difference(lastBack) < _backDedupeWindow) {
      return true;
    }
    final keyboardUp = _keyboardOpen ||
        _keyboardFocus.hasFocus ||
        View.of(context).viewInsets.bottom > 0;
    if (keyboardUp) {
      setState(() {
        _keyboardOpen = false;
        _chromeVisible = true;
        _mouseLocked = false;
        _streamSettingsOpen = false;
      });
      _keyboardCloseDebounce?.cancel();
      _keyboardCloseDebounce = null;
      _keyboardFocus.unfocus();
      _gameFocus.requestFocus();
      return true;
    }
    if (!_chromeVisible) {
      // In-game: back shows the stream UI.
      setState(() {
        _chromeVisible = true;
        _streamSettingsOpen = false;
      });
      return true;
    }
    // Stream UI is showing: back only exits the stream UI (back into the
    // game). It never stops the session — that's what the Exit button is for.
    setState(() {
      _chromeVisible = false;
      _streamSettingsOpen = false;
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final transport = widget.transport;
    // With a physical/hardware keyboard attached, Flutter turns on the
    // "traditional" focus-highlight mode which draws a yellow focus ring over
    // Material ancestors of the focused widget — on the stream that's glue for
    // the hidden input field and looks like a bug. Kill the overlay.
    final focusFreeTheme = Theme.of(context).copyWith(
      focusColor: Colors.transparent,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
    );
    return Theme(
      data: focusFreeTheme,
      child: Focus(
        autofocus: true,
        focusNode: _gameFocus,
        onKeyEvent: (node, event) {
          // Android back (system button OR hardware KEYCODE_BACK) can arrive
          // as a key event. Route it through handleSystemBack (chrome toggle /
          // keyboard close) instead of forwarding it to the game — otherwise
          // it is swallowed here and the pop the navigator also receives never
          // shows the stream UI. The dedupe inside handleSystemBack collapses
          // the key-event + system-pop pair into a single toggle.
          if (event.logicalKey == LogicalKeyboardKey.goBack) {
            if (event is KeyDownEvent && event is! KeyRepeatEvent) {
              handleSystemBack();
            }
            return KeyEventResult.handled;
          }
          // Escape: a single press is read by the game; a quick second press
          // within the double-press window shows the stream UI instead.
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            _handleEscKey(event);
            return KeyEventResult.handled;
          }
          // Ctrl+G: toggle the stream UI chrome. Ignore the OS key auto-repeat
          // (KeyRepeatEvent is a KeyDownEvent) so holding the key flips once,
          // not repeatedly.
          if (event.logicalKey == LogicalKeyboardKey.keyG &&
              HardwareKeyboard.instance.isControlPressed) {
            if (event is KeyDownEvent && event is! KeyRepeatEvent) {
              _toggleChromeFromKey();
            }
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
                      // With the soft keyboard up, don't enter mouse lock —
                      // _enterMouseLock hides the chrome AND drops the IME
                      // (its pointer-lock tap fights the focused text field).
                      // The pointer-down already forwarded the tap to the
                      // game; the keyboard is closed by back or the Keyboard
                      // button, not by tapping the surface.
                      if (_keyboardOpen) return;
                      // Tapping the stream surface enters mouse lock whenever a
                      // grab isn't already live: the capture click (chrome
                      // visible), a re-lock after a release, or the chrome-visible
                      // Hide-UI path that set _mouseLocked without starting the
                      // grab. _enterMouseLock no-ops once the grab session is
                      // active, so gameplay clicks still stream to the game.
                      // Double-Esc releases.
                      _enterMouseLock();
                    },
                    child: MouseRegion(
                      // In-game the OS cursor is hidden (soft lock — this is what
                      // actually hides it on Linux/Wayland, where no native grab
                      // exists). With the cursor overlay enabled, server-streamed
                      // predefined styles take over the OS cursor; custom bitmaps
                      // are drawn as an image overlay instead.
                      cursor: _videoCursor,
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

              // Top-edge escape: while in-game, moving the cursor to the top
              // edge shows the stream UI. This is the mouse-only way out that
              // works even when the keyboard stops reaching the app (some
              // Wayland compositors drop focus during OS fullscreen) — the
              // double-Esc path can't be relied on there.
              if (!_chromeVisible)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: _edgeZoneHeight,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.basic,
                    // Explicit opaque so the zone is hit-testable over its whole
                    // area (not just the child), and onHover so it also fires
                    // when the cursor is already parked here as the chrome hides.
                    opaque: true,
                    onHover: (_) => _showChromeFromEdge(),
                    child: const SizedBox.expand(),
                  ),
                ),

              // In-game cursor overlay: draws the game cursor (custom bitmap
              // from the WebRTC cursor_channel, or the built-in predefined style
              // decoded from the ported ICO table) at the tracked position. The
              // OS cursor stays hidden in-game (_videoCursor); this bitmap is
              // what the user sees, rendered under both soft lock and native
              // grabs (under a grab the OS cursor is captured, so without this
              // overlay the game cursor would be invisible).
              if (widget.settings.inputCursorOverlay &&
                  !_chromeVisible &&
                  _cursorVisible &&
                  _cursorPositionKnown &&
                  (_cursorImageBytes != null || _cursorPredefinedImage != null))
                Positioned.fill(
                  child: IgnorePointer(
                    // Rebuild on tracked-position changes so the cursor follows
                    // the mouse per-delta, without rebuilding the whole surface.
                    child: ValueListenableBuilder<Offset>(
                      valueListenable: _cursorPos,
                      builder: (context, _, _) => LayoutBuilder(
                        builder: (context, constraints) {
                          final w = constraints.maxWidth;
                          final h = constraints.maxHeight;
                          if (w <= 0 || h <= 0) return const SizedBox.shrink();
                          final dpr = MediaQuery.devicePixelRatioOf(context);
                          final baseW = _cursorBitmapW.toDouble();
                          final baseH = _cursorBitmapH.toDouble();
                          // Render at native bitmap resolution on any display
                          // scale (bitmap px / dpr = logical px), like OpenNOW's
                          // image-set 2x cursor handling.
                          final imgW = baseW / dpr * _cursorScale;
                          final imgH = baseH / dpr * _cursorScale;
                          // Map the server cursor within the fitted video
                          // content rectangle (not the letterboxed window) so
                          // it matches where absolute-input clicks land.
                          final rect = _videoContentRect(Size(w, h));
                          final left =
                              (rect.left +
                                      _cursorNormX / 65535 * rect.width -
                                      _cursorHotspotX / dpr * _cursorScale)
                                  .clamp(-imgW, w);
                          final top =
                              (rect.top +
                                      _cursorNormY / 65535 * rect.height -
                                      _cursorHotspotY / dpr * _cursorScale)
                                  .clamp(-imgH, h);
                          // Positioned must be a direct Stack child, so the
                          // LayoutBuilder returns its own Stack for the image.
                          // Custom cursors are drawn with a decoded ui.Image via
                          // RawImage (the same robust path as predefined); the raw
                          // Image.memory fallback only covers a still-decoding
                          // frame. The debug box wraps the bitmap so its placement
                          // can be inspected independently of the pixel content.
                          final Widget customChild;
                          if (_cursorCustomImage != null) {
                            customChild = RawImage(
                              image: _cursorCustomImage!,
                              width: imgW,
                              height: imgH,
                              fit: BoxFit.fill,
                              filterQuality: FilterQuality.none,
                            );
                          } else {
                            customChild = _cursorImageBytes != null
                                ? Image.memory(
                                    _cursorImageBytes!,
                                    width: imgW,
                                    height: imgH,
                                    fit: BoxFit.fill,
                                    filterQuality: FilterQuality.none,
                                    gaplessPlayback: true,
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox.shrink(),
                                  )
                                : const SizedBox.shrink();
                          }
                          final cursorChild =
                              widget.settings.debugCursorOverlayBox
                              ? Container(
                                  width: imgW,
                                  height: imgH,
                                  color: const Color(0x60FF1493),
                                  alignment: Alignment.center,
                                  child: customChild,
                                )
                              : customChild;
                          return Stack(
                            children: [
                              Positioned(
                                left: left,
                                top: top,
                                width: imgW,
                                height: imgH,
                                child: _cursorPredefinedImage != null
                                    ? RawImage(
                                        image: _cursorPredefinedImage!,
                                        width: imgW,
                                        height: imgH,
                                        fit: BoxFit.fill,
                                        filterQuality: FilterQuality.none,
                                      )
                                    : cursorChild,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),

              // Stats overlay (left side). Stays visible when the stream UI hides
              // so stats remain readable in-game. Painted BELOW the gamepad and
              // chrome so it never covers the controller or the UI.
              if (widget.settings.streamShowFps)
                Positioned(
                  top: 96,
                  left: 16,
                  child: _StatsOverlay(transport: widget.transport),
                ),

              // Virtual gamepad overlay (independent of chrome visibility). Uses
              // deferToChild hit-testing so only the actual controller widgets
              // swallow taps (the pad never toggles the chrome), while the gaps
              // between them pass through to the video surface. Painted BELOW
              // the chrome/stats/sidebar so the stream UI always stays on top
              // and hit-tests first.
              if (widget.settings.streamGamepad)
                Positioned(
                  left: 0,
                  right: 0,
                  // Anchored to the bottom with the user's position lift, so
                  // the pad can float above the bottom edge without resizing.
                  // The chrome paints and hit-tests on top.
                  bottom: widget.settings.streamGamepadPosition * 240,
                  child: GestureDetector(
                    behavior: HitTestBehavior.deferToChild,
                    onTap: () {},
                    child: Opacity(
                      opacity: widget.settings.streamGamepadOpacity,
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
                            spacing: widget.settings.streamGamepadSpacing,
                            showShoulders:
                                widget.settings.streamGamepadShowShoulders,
                            showSticks: widget.settings.streamGamepadShowSticks,
                            showDpad: widget.settings.streamGamepadShowDpad,
                            showFaceButtons:
                                widget.settings.streamGamepadShowFaceButtons,
                            showMenu: widget.settings.streamGamepadShowMenu,
                            onLeftStickDrag: _onLeftStickDrag,
                            onLeftStickDragEnd: () {
                              _gamepadFlushTimer?.cancel();
                              _gamepadFlushTimer = null;
                              _leftStickX = 0;
                              _leftStickY = 0;
                              _sendGamepadState();
                            },
                            onRightStickDrag: _onRightStickDrag,
                            onRightStickDragEnd: () {
                              _gamepadFlushTimer?.cancel();
                              _gamepadFlushTimer = null;
                              _rightStickX = 0;
                              _rightStickY = 0;
                              _sendGamepadState();
                            },
                            onDpadPressed: _onDpadPressed,
                            onDpadReleased: _onDpadReleased,
                            onFaceButtonPressed: _onFaceButtonPressed,
                            onFaceButtonReleased: _onFaceButtonReleased,
                            onStartPressed: () =>
                                _setGamepadBit(gamepadStart, true),
                            onStartReleased: () =>
                                _setGamepadBit(gamepadStart, false),
                            onSelectPressed: () =>
                                _setGamepadBit(gamepadBack, true),
                            onSelectReleased: () =>
                                _setGamepadBit(gamepadBack, false),
                            onHomePressed: () =>
                                _setGamepadBit(gamepadGuide, true),
                            onHomeReleased: () =>
                                _setGamepadBit(gamepadGuide, false),
                            onLeftBumperPressed: () =>
                                _setGamepadBit(gamepadLb, true),
                            onLeftBumperReleased: () =>
                                _setGamepadBit(gamepadLb, false),
                            onRightBumperPressed: () =>
                                _setGamepadBit(gamepadRb, true),
                            onRightBumperReleased: () =>
                                _setGamepadBit(gamepadRb, false),
                            onLeftTriggerPressed: () => _setTrigger(0, 1.0),
                            onLeftTriggerReleased: () => _setTrigger(0, 0),
                            onRightTriggerPressed: () => _setTrigger(1, 1.0),
                            onRightTriggerReleased: () => _setTrigger(1, 0),
                          ),
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
                    startedAt: _sessionStartedAt,
                    webrtcStatus: widget.webrtcStatus,
                    onStop: widget.onStop,
                  ),
                ),

              // Hint pill: mouse-lock + double-Esc gestures.
              if (_chromeVisible)
                Positioned(
                  top: 88,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(child: Center(child: _HintPill())),
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
                    settingsOpen: _streamSettingsOpen,
                    isFullscreen: _osFullscreen,
                    onKeyboard: _toggleKeyboard,
                    onFullscreen: _toggleFullscreen,
                    onOpenSettings: () {
                      setState(() {
                        _streamSettingsOpen = !_streamSettingsOpen;
                        if (_streamSettingsOpen) {
                          _mouseLocked = true;
                          _chromeVisible = false;
                        }
                      });
                      if (_streamSettingsOpen) _applyMobileSystemUi(true);
                    },
                    onHideUi: _enterGameMode,
                    onHideChromeKeepKeyboard: _hideChromeKeepKeyboard,
                  ),
                ),

              // Live stream-settings sidebar: gamepad scale/opacity, mouse sensitivity and
              // touch mode, applied immediately while streaming. Tapping the
              // rest of the screen (outside the panel) closes it.
              if (_streamSettingsOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _streamSettingsOpen = false),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  child: StreamSettingsSidebar(
                    settings: widget.settings,
                    onClose: () => setState(() => _streamSettingsOpen = false),
                  ),
                ),
              ],

              // Soft keyboard (touch devices): a focusable text field lives just
              // off-screen so the Android keyboard shows, and whatever the user
              // types there is forwarded to the game. No input bar is drawn.
              //
              // The Positioned carries a stable key: it lives in a Stack whose
              // earlier children (the in-game cursor overlay, stats/gamepad)
              // are inserted/removed while the session runs. Without a key,
              // index-based reconciliation would recreate this field's element
              // the moment a sibling is inserted in front of it (which the game
              // does by showing a text caret when the user types a character),
              // detaching the FocusNode and hiding the keyboard mid-edit.
              if (_keyboardOpen)
                Positioned(
                  key: const ValueKey('soft-keyboard-field'),
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 1,
                  child: Opacity(
                    opacity: 0,
                    child: TextField(
                      controller: _keyboardController,
                      focusNode: _keyboardFocus,
                      onChanged: _onKeyboardChanged,
                      onSubmitted: _onKeyboardSubmitted,
                      textInputAction: TextInputAction.go,
                      keyboardType: TextInputType.text,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
            ],
          ),
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
        const DecoratedBox(decoration: BoxDecoration(gradient: Neon.scrim)),
      ],
    );
  }
}

/// Top gradient chrome with the session timer, game title, and exit button.
class _TopChrome extends StatelessWidget {
  final CatalogGame game;
  final SessionInfo session;
  final DateTime? startedAt;
  final String? webrtcStatus;
  final VoidCallback onStop;

  const _TopChrome({
    required this.game,
    required this.session,
    this.startedAt,
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
          colors: [Colors.black.withValues(alpha: 0.72), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          SessionTimer(startedAt: startedAt),
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
          IconButton(
            tooltip: 'Exit stream',
            icon: const Icon(Icons.stop_circle_outlined),
            iconSize: 36,
            color: Neon.error,
            onPressed: onStop,
          ),
        ],
      ),
    );
  }
}

/// Bottom gradient chrome: gamepad / stats toggles + keyboard + fullscreen +
/// stream-settings sidebar toggle.
class _BottomChrome extends StatelessWidget {
  final UserSettings settings;
  final bool keyboardOpen;
  final bool settingsOpen;
  final bool isFullscreen;
  final VoidCallback onKeyboard;
  final VoidCallback onFullscreen;
  final VoidCallback onOpenSettings;
  final VoidCallback onHideUi;

  /// Hide the chrome but keep the soft keyboard up (used by the Keyboard
  /// button — [onHideUi] would immediately close the keyboard it just opened).
  final VoidCallback onHideChromeKeepKeyboard;

  const _BottomChrome({
    required this.settings,
    required this.keyboardOpen,
    required this.settingsOpen,
    required this.isFullscreen,
    required this.onKeyboard,
    required this.onFullscreen,
    required this.onOpenSettings,
    required this.onHideUi,
    required this.onHideChromeKeepKeyboard,
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
          colors: [Colors.black.withValues(alpha: 0.72), Colors.transparent],
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
            onTap: () {
              settings.streamGamepad = !settings.streamGamepad;
              onHideUi();
            },
          ),
          const SizedBox(width: 20),
          _ChromeButton(
            icon: Icons.speed,
            label: 'Stats',
            active: settings.streamShowFps,
            onTap: () {
              settings.streamShowFps = !settings.streamShowFps;
              onHideUi();
            },
          ),
          const SizedBox(width: 20),
          _ChromeButton(
            icon: Icons.touch_app,
            label: 'Touch',
            active: settings.inputTouchEnabled,
            onTap: () {
              settings.inputTouchEnabled = !settings.inputTouchEnabled;
              onHideUi();
            },
          ),
          const SizedBox(width: 20),
          _ChromeButton(
            icon: isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            label: isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
            onTap: () {
              onFullscreen();
              onHideUi();
            },
          ),
          const SizedBox(width: 20),
          _ChromeButton(
            icon: Icons.keyboard,
            label: 'Keyboard',
            active: keyboardOpen,
            onTap: () {
              onKeyboard();
              onHideChromeKeepKeyboard();
            },
          ),
          const SizedBox(width: 20),
          _ChromeButton(
            icon: Icons.tune,
            label: 'Settings',
            active: settingsOpen,
            // Toggles the sidebar (which hides the chrome itself — see
            // onOpenSettings). Must NOT run [onHideUi] first: that path clears
            // the open flag the moment it is set.
            onTap: onOpenSettings,
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
            'click to lock mouse · Esc Esc or Ctrl+G opens UI',
            style: TextStyle(color: Neon.inkSoft, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Live stream-settings sidebar shown over the stream. Every control mutates
/// [UserSettings] (a ChangeNotifier) so the change applies instantly to the
/// running stream — gamepad scale/opacity, stats overlay and mouse sensitivity.
class StreamSettingsSidebar extends StatelessWidget {
  final UserSettings settings;
  final VoidCallback onClose;

  const StreamSettingsSidebar({
    super.key,
    required this.settings,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ListenableBuilder(
        listenable: settings,
        builder: (context, _) {
          return Container(
            width: 300,
            padding: const EdgeInsets.only(top: 18, left: 16, right: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerRight,
                end: Alignment.centerLeft,
                // Spread the dark chrome deep into the screen, not a thin
                // right-hand strip: strong black from the edge fades out
                // across ~half the panel so the video behind stays readable
                // but the panel region is clearly darkened.
                stops: const [0.0, 0.25, 0.6, 1.0],
                colors: [
                  Colors.black.withValues(alpha: 0.95),
                  Colors.black.withValues(alpha: 0.88),
                  Colors.black.withValues(alpha: 0.5),
                  Colors.transparent,
                ],
              ),
            ),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                const Text(
                  'STREAM SETTINGS',
                  style: TextStyle(
                    color: Neon.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 14),
                _SidebarSection(
                  title: 'GAMEPAD',
                  children: [
                    _SliderRow(
                      label: 'Component size',
                      valueLabel:
                          '${(settings.streamGamepadScale * 100).round()}%',
                      value: settings.streamGamepadScale,
                      min: 0.6,
                      max: 1.4,
                      divisions: 16,
                      onChanged: (v) => settings.streamGamepadScale = v,
                    ),
                    const SizedBox(height: 14),
                    _SliderRow(
                      label: 'Component offset',
                      valueLabel:
                          '${(settings.streamGamepadSpacing * 100).round()}%',
                      value: settings.streamGamepadSpacing,
                      min: 0.5,
                      max: 2.0,
                      divisions: 30,
                      onChanged: (v) => settings.streamGamepadSpacing = v,
                    ),
                    const SizedBox(height: 14),
                    _SliderRow(
                      label: 'Vertical position',
                      valueLabel:
                          '${(settings.streamGamepadPosition * 100).round()}%',
                      value: settings.streamGamepadPosition,
                      min: 0.0,
                      max: 1.0,
                      divisions: 20,
                      onChanged: (v) => settings.streamGamepadPosition = v,
                    ),
                    const SizedBox(height: 14),
                    _SliderRow(
                      label: 'Transparency',
                      valueLabel:
                          '${((1 - settings.streamGamepadOpacity) * 100).round()}%',
                      value: settings.streamGamepadOpacity,
                      min: 0.2,
                      max: 1.0,
                      divisions: 16,
                      onChanged: (v) => settings.streamGamepadOpacity = v,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Elements',
                      style: TextStyle(color: Neon.inkSoft, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    _ToggleRow(
                      label: 'Shoulders (LB/RB/LT/RT)',
                      value: settings.streamGamepadShowShoulders,
                      onChanged: (v) => settings.streamGamepadShowShoulders = v,
                    ),
                    _ToggleRow(
                      label: 'Analog sticks',
                      value: settings.streamGamepadShowSticks,
                      onChanged: (v) => settings.streamGamepadShowSticks = v,
                    ),
                    _ToggleRow(
                      label: 'D-pad',
                      value: settings.streamGamepadShowDpad,
                      onChanged: (v) => settings.streamGamepadShowDpad = v,
                    ),
                    _ToggleRow(
                      label: 'Face buttons (A/B/X/Y)',
                      value: settings.streamGamepadShowFaceButtons,
                      onChanged: (v) =>
                          settings.streamGamepadShowFaceButtons = v,
                    ),
                    _ToggleRow(
                      label: 'Menu (Select/Start/Home)',
                      value: settings.streamGamepadShowMenu,
                      onChanged: (v) => settings.streamGamepadShowMenu = v,
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _SidebarSection(
                  title: 'MOUSE & TOUCH',
                  children: [
                    _SliderRow(
                      label: 'Sensitivity',
                      valueLabel: settings.inputMouseSensitivity
                          .toStringAsFixed(2),
                      value: settings.inputMouseSensitivity,
                      min: 0.25,
                      max: 4.0,
                      divisions: 30,
                      onChanged: (v) => settings.inputMouseSensitivity = v,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Touch input',
                      style: TextStyle(color: Neon.ink, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _ModeButton(
                          label: 'Absolute',
                          subtitle: 'direct touch',
                          selected:
                              settings.inputTouchMode ==
                              TouchInputMode.absolute,
                          onTap: () =>
                              settings.inputTouchMode = TouchInputMode.absolute,
                        ),
                        const SizedBox(width: 8),
                        _ModeButton(
                          label: 'Relative',
                          subtitle: 'trackpad',
                          selected:
                              settings.inputTouchMode ==
                              TouchInputMode.relative,
                          onTap: () =>
                              settings.inputTouchMode = TouchInputMode.relative,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _SidebarSection(
                  title: 'KEYBOARD',
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Tap to dismiss',
                                style: TextStyle(
                                  color: Neon.ink,
                                  fontSize: 13,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Tap the stream to close the keyboard '
                                'instead of keeping it up to type',
                                style: TextStyle(
                                  color: Neon.inkMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        NeonSwitch(
                          value: settings.keyboardTapToDismiss,
                          onChanged: (v) =>
                              settings.keyboardTapToDismiss = v,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _SidebarSection(
                  title: 'VIDEO SHADERS',
                  children: [
                    VideoShaderControls(settings: settings),
                  ],
                ),
                const SizedBox(height: 24),
                const Text(
                  'Changes apply instantly while streaming.',
                  style: TextStyle(color: Neon.inkMuted, fontSize: 11),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SidebarSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SidebarSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Neon.inkSoft,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            // Dark glass (matches the app's card surfaces) instead of the
            // whitish surface tint, so the sidebar reads dark + moody. No
            // border — pure, seamless panels.
            color: Neon.bgC.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            gradient: selected ? Neon.accentGradient : null,
            color: selected ? null : const Color(0xFF1A1A26),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? Neon.accent : Neon.outlineSoft,
            ),
          ),
          child: Column(
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: selected ? Neon.bgA : Neon.ink,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: selected
                      ? Neon.bgA.withValues(alpha: 0.8)
                      : Neon.inkMuted,
                  fontSize: 9.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact label + switch row used in the stream-settings sidebar.
class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Neon.ink, fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          NeonSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  const _SliderRow({    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Neon.ink, fontSize: 13),
              ),
            ),
            Text(
              valueLabel,
              style: const TextStyle(color: Neon.inkSoft, fontSize: 12),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Neon.accent,
            inactiveTrackColor: Neon.outlineSoft,
            thumbColor: Neon.accent,
            overlayColor: Neon.accent.withValues(alpha: 0.15),
            trackHeight: 3,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
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
        _row(
          'Resolution',
          '${snap.videoWidth ?? '?'}x${snap.videoHeight ?? '?'}',
        ),
        _row('Bitrate', fmtKbps(snap.videoBitrateKbps)),
        _row('Decode FPS', fmtFps(snap.decodeFps)),
        _row('Receive FPS', fmtFps(snap.receivedFps)),
        _row('Backlog', '${snap.backlogFrames} frames'),
        _row(
          'Frames',
          '${snap.framesDecoded} dec / ${snap.framesReceived} recv',
        ),
        _row('Dropped', '${snap.framesDropped} (${snap.keyFramesDecoded} key)'),
        _row('Jitter', '${snap.jitterMs.toStringAsFixed(1)} ms'),
        _row('JB delay', '${snap.jitterBufferDelayMs.toStringAsFixed(1)} ms'),
        _row(
          'Decode/frame',
          '${snap.decodeTimePerFrameMs.toStringAsFixed(2)} ms',
        ),
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
