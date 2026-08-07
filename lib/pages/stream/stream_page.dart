import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb, kProfileMode, kReleaseMode;
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
import '../../widgets/stream/queue_ad_player.dart';
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
    String line(String label, String value) =>
        '${label.padRight(12)}$value';
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
        'priority',
        '${s.streamPriority.name}'
            '${s.streamPriorityEnabled ? '' : ' (off)'}',
      ),
      line(
        'gamepad',
        s.streamGamepad
            ? 'on ${s.streamGamepadScale.toStringAsFixed(1)}x'
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
      reportAd: _reportAdAction,
    );
  }
}

class _ProgressSurface extends StatefulWidget {
  final CatalogGame game;
  final SessionState state;
  final SessionInfo? session;
  final List<SessionPhaseEvent> events;
  final Future<void> Function(SessionAdAction action, String adId,
      {int? watchedMs}) reportAd;

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
              _QueueAdCard(
                adState: s.adState!,
                reportAd: widget.reportAd,
              ),
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
  final Future<void> Function(SessionAdAction action, String adId,
      {int? watchedMs}) reportAd;

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

class _ReadySurfaceState extends State<_ReadySurface> {
  bool _chromeVisible = true;

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

  @override
  void initState() {
    super.initState();
    _attachCursorOverlay(widget.transport);
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
      } else {
        final bitmap = _predefinedBitmapCache[update.cursorId] ??
            decodeIcoCursor(base64Decode(predefined.imageBase64));
        if (bitmap == null) return; // malformed table entry — skip
        _predefinedBitmapCache[update.cursorId] = bitmap;
        _cursorBitmapW = bitmap.width;
        _cursorBitmapH = bitmap.height;
        _cursorHotspotX = predefined.hotspotX;
        _cursorHotspotY = predefined.hotspotY;
        _cursorScale = 1;
        _cursorVisible = true;
        // Skip the async decode when this id is already the displayed cursor
        // (id-only updates re-stream the same style every frame); the image
        // only needs (re)building when the cursor actually changes.
        if (_cursorPredefinedId != update.cursorId) {
          _cursorPredefinedId = update.cursorId;
          _decodePredefinedImage(bitmap.rgba, bitmap.width, bitmap.height,
              update.cursorId);
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
      Uint8List rgba, int width, int height, int cursorId) {
    final gen = ++_predefinedImageGen;
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted || gen != _predefinedImageGen) {
          image.dispose();
          return;
        }
        setState(() {
          _cursorPredefinedImage?.dispose();
          _cursorPredefinedImage = image;
        });
      },
    );
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
    _cursorNormY =
        (_cursorNormY + dy / size.height * 65535).clamp(0.0, 65535.0);
    // Repaint only the cursor overlay on this delta (not the whole surface),
    // mirroring OpenNOW's canvas transform update so the cursor tracks the
    // mouse input smoothly instead of waiting for the next server position.
    if (_cursorVisible && _cursorPositionKnown && !_chromeVisible) {
      _cursorPos.value = Offset(_cursorNormX, _cursorNormY);
    }
  }

  /// OS cursor shown over the video surface. In-game the OS cursor is ALWAYS
  /// hidden — never swapped to a real predefined cursor. On the soft-lock
  /// path (no native grab) the OS cursor is the one the user physically moves,
  /// so showing it means it hits the window edge and the pointer deltas stop:
  /// the mouse "freezes" exactly as observed with the overlay enabled. The
  /// game cursor is drawn client-side by the bitmap overlay instead.
  SystemMouseCursor get _videoCursor {
    if (!_mouseLocked) return SystemMouseCursors.basic;
    return SystemMouseCursors.none;
  }

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
    // Real OS fullscreen alongside the in-game mode: the compositor stops
    // re-compositing the windowed surface (direct scanout), which is a
    // full-screen pass saved per frame on iGPUs. No-op on mobile/web and when
    // the platform plugin has no implementation. The flag is set BEFORE the
    // await so a dispose during the in-flight transition (user exits the
    // stream) still runs _leaveOsFullscreen and restores the window.
    if (!kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
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
    _leaveOsFullscreen();
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
    if (kIsWeb || !(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return;
    }
    unawaited(windowManager.setFullScreen(false).catchError((_) => false));
  }

  /// Fired when the platform releases the pointer on its own (e.g. the
  /// browser exits pointer lock on Esc during web builds).
  void _onPointerLockReleased() {
    _pendingUnlock = null;
    _leaveOsFullscreen();
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
    _keyboardController.dispose();
    _keyboardFocus.dispose();
    _leaveOsFullscreen();
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
      currentIntervalMs:
          _mouseFlushIntervalMs == 0 ? base : _mouseFlushIntervalMs,
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
                      final left = (_cursorNormX / 65535 * w -
                              _cursorHotspotX / dpr * _cursorScale)
                          .clamp(-imgW, w);
                      final top = (_cursorNormY / 65535 * h -
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
          SizedBox(width: 7),            Text(
              'click to lock mouse · Esc Esc or top edge opens UI',
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
