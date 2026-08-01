import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import 'main.dart';
import 'pages/home/home_page.dart';
import 'pages/library/library_page.dart';
import 'pages/login/login_page.dart';
import 'pages/settings/settings_page.dart';
import 'theme/neon.dart';
import 'widgets/neon_rail.dart';
import 'widgets/neon_sidenav_button.dart';

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
      HomePage(services: widget.services, onSignOut: widget.onSignOut),
      LibraryPage(services: widget.services),
      SettingsPage(
        services: widget.services,
        onSignOut: widget.onSignOut,
      ),
    ];

    return Scaffold(
      backgroundColor: Neon.bgA,
      drawer: _NeonDrawer(
        destinations: _destinations,
        selectedIndex: _index,
        onSelect: (i) => setState(() => _index = i),
      ),
      body: Row(
        children: [
          NeonRail(
            destinations: _destinations,
            selectedIndex: _index,
            onSelect: (i) => setState(() => _index = i),
            footer: Builder(
              builder: (railContext) => NeonSidenavButton(
                onPressed: () => Scaffold.of(railContext).openDrawer(),
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(index: _index, children: pages),
          ),
        ],
      ),
    );
  }
}

/// Neon side navigation drawer (native Scaffold drawer).
class _NeonDrawer extends StatelessWidget {
  final List<RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const _NeonDrawer({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: Neon.bgB,
      width: 280,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(right: BorderSide(color: Color(0x1FFFFFFF))),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: ShaderMask(
                  shaderCallback: _gradientShader,
                  child: Text(
                    'NEXTCLIENT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
              const Divider(),
              for (var i = 0; i < destinations.length; i++)
                _DrawerTile(
                  destination: destinations[i],
                  selected: i == selectedIndex,
                  onTap: () {
                    onSelect(i);
                    Navigator.of(context).pop();
                  },
                ),
              const Spacer(),
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: Text(
                  'NEXTCLIENT · open-source GFN client',
                  style: TextStyle(
                    color: Color(0xFF5C6B85),
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Shader _gradientShader(Rect bounds) =>
      Neon.accentGradient.createShader(bounds);
}

class _DrawerTile extends StatelessWidget {
  final RailDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _DrawerTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? Neon.accent : Neon.inkSoft;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? Neon.accent.withValues(alpha: 0.1) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          children: [
            if (selected)
              Container(
                width: 3,
                height: 20,
                margin: const EdgeInsets.only(right: 14),
                decoration: BoxDecoration(
                  gradient: Neon.accentGradient,
                  borderRadius: BorderRadius.circular(2),
                ),
              )
            else
              const SizedBox(width: 17),
            Icon(
              selected
                  ? destination.selectedIcon ?? destination.icon
                  : destination.icon,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 12),
            Text(
              destination.label,
              style: TextStyle(
                color: selected ? Neon.accent : Neon.ink,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
