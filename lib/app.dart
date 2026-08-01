import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import 'main.dart';
import 'pages/home/home_page.dart';
import 'pages/library/library_page.dart';
import 'pages/login/login_page.dart';
import 'pages/settings/settings_page.dart';
import 'theme/neon.dart';
import 'widgets/neon_sidebar.dart';

class DebugShellApp extends StatefulWidget {
  const DebugShellApp({super.key});

  @override
  State<DebugShellApp> createState() => _DebugShellAppState();
}

class _DebugShellAppState extends State<DebugShellApp> {
  Future<AppServices>? _servicesFuture;

  @override
  void initState() {
    super.initState();
    _servicesFuture = AppServices.create();
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
          return AuthGate(services: snapshot.data!);
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
    setState(() {
      _session = widget.services.auth.getSession();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return LoginPage(
        services: widget.services,
        onAuthenticated: _refresh,
      );
    }
    return Shell(
      services: widget.services,
      onSignOut: _refresh,
    );
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
    final pages = <Widget>[
      HomePage(
        services: widget.services,
        onSignOut: widget.onSignOut,
        showBrand: !_sidebarExpanded,
      ),
      LibraryPage(services: widget.services),
      SettingsPage(
        services: widget.services,
        onSignOut: widget.onSignOut,
      ),
    ];

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
