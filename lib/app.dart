import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import 'main.dart';
import 'pages/home/home_page.dart';
import 'pages/library/library_page.dart';
import 'pages/login/login_page.dart';
import 'pages/settings/settings_page.dart';
import 'pages/stream/stream_page.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _servicesFuture = AppServices.create();
  }

  void _onServicesReady(AppServices services) {
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
      HomePage(
        services: widget.services,
        onSignOut: widget.onSignOut,
        // No sidebar in portrait — always show the brand in the top bar.
        showBrand: isPortrait || !_sidebarExpanded,
      ),
      LibraryPage(services: widget.services),
      SettingsPage(services: widget.services, onSignOut: widget.onSignOut),
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
