import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import 'main.dart';
import 'pages/home/home_page.dart';
import 'pages/library/library_page.dart';
import 'pages/login/login_page.dart';
import 'pages/settings/account_page.dart';
import 'pages/settings/settings_page.dart';
import 'theme/neon.dart';
import 'widgets/neon_chip.dart';
import 'widgets/neon_rail.dart';

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
      title: 'NEXTC',
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

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomePage(services: widget.services),
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
          NeonRail(
            brand: 'N',
            destinations: const [
              RailDestination(
                label: 'Home',
                icon: Icons.home_outlined,
                selectedIcon: Icons.home,
              ),
              RailDestination(
                label: 'Library',
                icon: Icons.library_books_outlined,
                selectedIcon: Icons.library_books,
              ),
              RailDestination(
                label: 'Settings',
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings,
              ),
            ],
            selectedIndex: _index,
            onSelect: (i) => setState(() => _index = i),
            footer: _AccountFooter(
              services: widget.services,
              onSignOut: widget.onSignOut,
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

class _AccountFooter extends StatelessWidget {
  final AppServices services;
  final VoidCallback onSignOut;

  const _AccountFooter({
    required this.services,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final user = services.auth.getSession()?.user;
    if (user == null) return const SizedBox.shrink();
    return Column(
      children: [
        _RailAvatar(
          initial: user.displayName.isNotEmpty
              ? user.displayName[0].toUpperCase()
              : '?',
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AccountPage(
                  services: services,
                  onSignOut: onSignOut,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        NeonChip(
          label: user.membershipTier,
          tone: user.membershipTier == 'ULTIMATE'
              ? NeonChipTone.accent
              : user.membershipTier == 'PRIORITY'
                  ? NeonChipTone.violet
                  : NeonChipTone.neutral,
        ),
      ],
    );
  }
}

class _RailAvatar extends StatelessWidget {
  final String initial;
  final VoidCallback onTap;

  const _RailAvatar({required this.initial, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          gradient: Neon.accentGradient,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Neon.accent.withValues(alpha: 0.5)),
          boxShadow: Neon.glowShadow(radius: 14, alpha: 0.3),
        ),
        child: Center(
          child: Text(
            initial,
            style: const TextStyle(
              color: Neon.bgA,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}
