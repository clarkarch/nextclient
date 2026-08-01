import 'dart:convert' show JsonEncoder;

import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../session/session_page.dart';

class CatalogPage extends StatefulWidget {
  final AppServices services;

  const CatalogPage({super.key, required this.services});

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  List<CatalogGame>? _games;
  String? _error;
  bool _loading = false;
  bool _libraryOnly = false;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await widget.services.auth.resolveJwtToken();
      final games = await widget.services.catalog.fetchMainGamesUncached(
        token: token,
      );
      if (!mounted) return;
      setState(() {
        _games = games;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final games = _games;
    final shown = _libraryOnly
        ? (games ?? []).where((g) => g.isInLibrary).toList()
        : (games ?? []);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Fetch catalog'),
              onPressed: _loading ? null : _load,
            ),
            const Spacer(),
            FilterChip(
              label: const Text('Library only'),
              selected: _libraryOnly,
              onSelected: (v) => setState(() => _libraryOnly = v),
            ),
          ],
        ),
        if (_loading) const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        if (games != null)
          Text(
            '${shown.length} games${_libraryOnly ? ' in library' : ''} '
            '(total ${games.length})',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (games != null)
          ...shown.map((game) => ListTile(
                leading: game.isInLibrary
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : _Thumb(url: game.id),
                title: Text(
                  game.title,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  'appId: ${game.launchAppId ?? "n/a"}'
                  '${game.isInLibrary ? " · in library" : ""}'
                  '${game.variants.isNotEmpty ? " · ${game.variants.length} variants" : ""}',
                ),
                isThreeLine: false,
                trailing: game.launchAppId != null
                    ? IconButton(
                        icon: const Icon(Icons.play_arrow),
                        tooltip: 'Launch this game',
                        onPressed: () => _launchGame(game),
                      )
                    : null,
                onTap: () => _showDetail(game),
              )),
      ],
    );
  }

  void _launchGame(CatalogGame game) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('Launch ${game.title}')),
          body: SessionPage(
            services: widget.services,
            initialGame: game,
          ),
        ),
      ),
    );
  }

  void _showDetail(CatalogGame game) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(game.title),
        content: SingleChildScrollView(
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(game.toJson()),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final String url;

  const _Thumb({required this.url});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: Colors.blueGrey.withValues(alpha: 0.2),
      alignment: Alignment.center,
      child: const Text('?'),
    );
  }
}