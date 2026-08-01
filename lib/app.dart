import 'package:flutter/material.dart';

import 'main.dart';
import 'pages/auth/session_status_page.dart';
import 'pages/catalog/catalog_page.dart';
import 'pages/log_viewer_page.dart';
import 'pages/queue/queue_page.dart';
import 'pages/session/session_page.dart';

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
      title: 'GFN Client Debug Shell',
      theme: ThemeData.dark(useMaterial3: true),
      home: FutureBuilder<AppServices>(
        future: _servicesFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Failed to init: ${snapshot.error}',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return _Shell(services: snapshot.data!);
        },
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  final AppServices services;

  const _Shell({required this.services});

  @override
  Widget build(BuildContext context) {
    return Home(
      services: services,
    );
  }
}

class Home extends StatefulWidget {
  final AppServices services;

  const Home({super.key, required this.services});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      SessionStatusPage(services: widget.services),
      CatalogPage(services: widget.services),
      QueuePage(services: widget.services),
      SessionPage(services: widget.services),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('GFN Debug Shell'),
        actions: [
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: 'Log viewer',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LogViewerPage(logSink: widget.services.logSink),
                ),
              );
            },
          ),
        ],
      ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.account_circle), label: 'Session'),
          NavigationDestination(icon: Icon(Icons.grid_view), label: 'Catalog'),
          NavigationDestination(icon: Icon(Icons.query_stats), label: 'Queue'),
          NavigationDestination(icon: Icon(Icons.play_circle), label: 'Launch'),
        ],
      ),
    );
  }
}