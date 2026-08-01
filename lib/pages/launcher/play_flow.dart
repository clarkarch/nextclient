import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import 'launcher_page.dart';

/// Central entry point for the Play flow. Used by Home, Library, Recently
/// Played, and Game Details so every Play button routes identically:
/// launcher options → (printedwaste picker) → streaming.
class PlayFlow {
  PlayFlow._();

  static void launch(
    BuildContext context, {
    required AppServices services,
    required CatalogGame game,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LauncherPage(services: services, game: game),
      ),
    );
  }
}
