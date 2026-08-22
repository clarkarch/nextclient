import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import 'main.dart';
import 'pages/home/home_page.dart';
import 'pages/library/library_page.dart';
import 'pages/login/login_page.dart';
import 'pages/settings/settings_page.dart';
import 'pages/stream/stream_page.dart';
import 'state/desktop_gamepad.dart';
import 'state/title_bar_controller.dart';
import 'theme/neon.dart';
import 'widgets/neon_bottom_nav.dart';
import 'widgets/neon_sidebar.dart';
import 'widgets/neon_snackbar.dart';

class DebugShellApp extends StatefulWidget {
  const DebugShellApp({super.key});

  @override
  State<DebugShellApp> createState() => _DebugShellAppState();
}

class _DebugShellAppState extends State<DebugShellApp>
    with WidgetsBindingObserver {
  Future<AppServices>? _servicesFuture;

  /// The loaded services, captured once the root [FutureBuilder] resolves so
  /// the [MaterialApp.builder] can live-reapply the UI scale (the future alone
  /// can't drive it — the builder only runs when the app widget itself
  /// rebuilds, and settings changes must reach it through a listener).
  AppServices? _services;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _servicesFuture = AppServices.create();
  }

  void _onServicesReady(AppServices services) {
    if (!identical(_services, services)) {
      _services = services;
      // Requested during build (inside the FutureBuilder builder), so the
      // rebuild must be deferred past the current frame. Once it lands, the
      // MaterialApp builder re-runs with _services set and the scale wrapper
      // (ListenableBuilder on settings) takes over.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    // Apply the persisted "Hide title bar" UI setting to the native window.
    unawaited(TitleBarController.apply(services.settings));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Flush the disk log when the app is being torn down so the tail of the
    // session is persisted even if the process exits before the periodic
    // auto-flush fires.
    if (state == AppLifecycleState.detached) {
      _servicesFuture?.then((services) => services.flushLogs());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NEXTCLIENT',
      debugShowCheckedModeBanner: false,
      theme: buildNeonTheme(),
      // Wraps the Navigator (everything the app pushes, stream page included)
      // with the persisted UI scale. This zooms the WHOLE UI (layout chrome
      // and text together), not just text: the app lays out in a design
      // viewport of size/scale and a FittedBox rasterizes it back to the real
      // window size — hit testing goes through the same transform, so taps
      // stay accurate. Safe-area / keyboard insets are divided out so the
      // scaled result still lines up with the physical screen edges.
      builder: (context, child) {
        final services = _services;
        if (services == null) return child!;
        return ListenableBuilder(
          listenable: services.settings,
          builder: (context, _) {
            final scale = services.settings.effectiveUiScale();
            if ((scale - 1.0).abs() < 0.005) return child!;
            final mq = MediaQuery.of(context);
            final inv = 1.0 / scale;
            EdgeInsets shrink(EdgeInsets e) =>
                e == EdgeInsets.zero ? e : e * inv;
            return FittedBox(
              fit: BoxFit.fill,
              child: SizedBox(
                width: mq.size.width * inv,
                height: mq.size.height * inv,
                child: MediaQuery(
                  data: mq.copyWith(
                    size: mq.size * inv,
                    padding: shrink(mq.padding),
                    viewPadding: shrink(mq.viewPadding),
                    viewInsets: shrink(mq.viewInsets),
                    systemGestureInsets: shrink(mq.systemGestureInsets),
                  ),
                  child: child!,
                ),
              ),
            );
          },
        );
      },
      home: FutureBuilder<AppServices>(
        future: _servicesFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              backgroundColor: Neon.bgA,
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Failed to init: ${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Neon.error),
                  ),
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              backgroundColor: Neon.bgA,
              body: Center(
                child: CircularProgressIndicator(color: Neon.accent),
              ),
            );
          }
          final services = snapshot.data!;
          _onServicesReady(services);
          return AuthGate(services: services);
        },
      ),
    );
  }
}

/// Renders Login when signed out, the app Shell when signed in.
class AuthGate extends StatefulWidget {
  final AppServices services;

  const AuthGate({super.key, required this.services});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AuthSession? _session;

  @override
  void initState() {
    super.initState();
    _session = widget.services.auth.getSession();
  }

  void _refresh() {
    final session = widget.services.auth.getSession();
    widget.services.logSink.log(
      LogLevel.info,
      'auth',
      session == null
          ? 'Signed out — returning to login'
          : 'Authenticated as [USER ID REDACTED]',
    );
    setState(() {
      _session = session;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return LoginPage(services: widget.services, onAuthenticated: _refresh);
    }
    return Shell(services: widget.services, onSignOut: _refresh);
  }
}

class Shell extends StatefulWidget {
  final AppServices services;
  final VoidCallback onSignOut;

  const Shell({super.key, required this.services, required this.onSignOut});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  bool _sidebarExpanded = true;

  @override
  void initState() {
    super.initState();
    _checkActiveSession();
    // Surface physical controller connect/disconnect (Linux) app-wide, so the
    // user sees the gamepad is live before they even reach the stream page.
    DesktopGamepad.instance.onConnectionChanged = _onGamepadConnection;
    DesktopGamepad.instance.start();
  }

  @override
  void dispose() {
    DesktopGamepad.instance.onConnectionChanged = null;
    DesktopGamepad.instance.stop();
    super.dispose();
  }

  /// Controller connected/disconnected notification.
  void _onGamepadConnection(bool connected, String name) {
    if (!mounted) return;
    showNeonSnackbar(
      context,
      connected
          ? 'Controller connected: $name'
          : 'Controller disconnected: $name',
      copyable: false,
      duration: Duration(seconds: connected ? 3 : 2),
    );
  }

  /// If a GFN session is already running (e.g. app was restarted), offer to
  /// resume it via a modern snackbar.
  Future<void> _checkActiveSession() async {
    try {
      final session = await widget.services.auth.ensureValidSession();
      if (session == null) return;
      final token = session.tokens.idToken ?? session.tokens.accessToken;
      final active = await widget.services.cloudMatch.getActiveSessions(
        token: token,
        streamingBaseUrl: defaultStreamingBaseUrl,
      );
      if (!mounted || active.isEmpty) return;
      final first = active.first;
      widget.services.logSink.log(
        LogLevel.info,
        'app',
        'Found ${active.length} active session(s); offering resume '
            '(appId ${first.appId})',
      );
      // Defer past the shell's first build frame: showing a snackbar while
      // the Scaffold is still mounting can drop it. The prompt is persistent
      // — no timeout, no swipe-dismiss — so it can't be missed: the only way
      // out is tapping Resume or Kill.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showNeonSnackbar(
          context,
          'Active session found (appId ${first.appId}). Resume or kill it?',
          actionLabel: 'Resume',
          altActionLabel: 'Kill',
          copyable: false,
          persistent: true,
          onAction: () => _resumeActiveSession(first),
          altOnAction: () => _terminateActiveSession(first),
        );
      });
    } catch (e) {
      debugPrint('[resume] check failed: $e');
    }
  }

  /// Terminates the remotely-active session instead of resuming it, so the
  /// spot is freed and no process keeps running on the server.
  Future<void> _terminateActiveSession(ActiveSessionInfo info) async {
    try {
      final session = await widget.services.auth.ensureValidSession();
      if (session == null) return;
      final token = session.tokens.idToken ?? session.tokens.accessToken;
      await widget.services.cloudMatch.stopSession(
        SessionStopRequest(
          token: token,
          streamingBaseUrl: info.streamingBaseUrl,
          serverIp: info.serverIp,
          zone: '',
          sessionId: info.sessionId,
        ),
      );
      widget.services.logSink.log(
        LogLevel.info,
        'app',
        'Terminated active session (appId ${info.appId})',
      );
      if (!mounted) return;
      showNeonSnackbar(context, 'Session terminated', copyable: false);
    } catch (e) {
      debugPrint('[resume] terminate failed: $e');
      widget.services.logSink.log(LogLevel.warn, 'app', 'Terminate failed: $e');
    }
  }

  void _resumeActiveSession(ActiveSessionInfo info) {
    final settings = widget.services.settings.buildStreamSettings();
    final appId = '${info.appId}';
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StreamPage(
          services: widget.services,
          game: CatalogGame(
            id: appId,
            title: 'Resume session',
            launchAppId: appId,
          ),
          resumeClaim: SessionClaimRequest(
            streamingBaseUrl: info.streamingBaseUrl,
            sessionId: info.sessionId,
            serverIp: info.serverIp ?? '',
            appId: appId,
            settings: settings,
          ),
        ),
      ),
    );
  }

  static const _destinations = [
    RailDestination(
      label: 'Home',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home,
    ),
    RailDestination(
      label: 'Library',
      icon: Icons.gamepad_outlined,
      selectedIcon: Icons.gamepad,
    ),
    RailDestination(
      label: 'Settings',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    // Portrait (phones, or a narrow/tall desktop window): bottom navigation.
    // Landscape (PC, tablets): the sidebar rail, pushed content layout.
    final isPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;

    final pages = <Widget>[
      // TickerMode pauses every animation controller on hidden tabs (animated
      // backgrounds, shimmer, etc.) — IndexedStack keeps them mounted but
      // otherwise lets their tickers run at full rate behind the scenes.
      TickerMode(
        enabled: _index == 0,
        child: HomePage(
          services: widget.services,
          onSignOut: widget.onSignOut,
          // No sidebar in portrait — always show the brand in the top bar.
          showBrand: isPortrait || !_sidebarExpanded,
        ),
      ),
      TickerMode(
        enabled: _index == 1,
        child: LibraryPage(services: widget.services),
      ),
      TickerMode(
        enabled: _index == 2,
        child: SettingsPage(
          services: widget.services,
          onSignOut: widget.onSignOut,
        ),
      ),
    ];

    if (isPortrait) {
      return Scaffold(
        backgroundColor: Neon.bgA,
        body: IndexedStack(index: _index, children: pages),
        bottomNavigationBar: NeonBottomNav(
          destinations: _destinations,
          selectedIndex: _index,
          onSelect: (i) => setState(() => _index = i),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Neon.bgA,
      body: Row(
        children: [
          NeonSidebar(
            destinations: _destinations,
            selectedIndex: _index,
            onSelect: (i) => setState(() => _index = i),
            expanded: _sidebarExpanded,
            onToggle: () =>
                setState(() => _sidebarExpanded = !_sidebarExpanded),
          ),
          Expanded(
            child: IndexedStack(index: _index, children: pages),
          ),
        ],
      ),
    );
  }
}
