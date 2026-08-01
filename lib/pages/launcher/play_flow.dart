import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../stream/stream_page.dart';
import 'launcher_dialog.dart';

/// Central entry point for the Play flow. Used by Home, Library, Recently
/// Played, and Game Details so every Play button routes identically:
/// launcher popup (store picker) → (printedwaste picker) → streaming.
class PlayFlow {
  PlayFlow._();

  static Future<void> launch(
    BuildContext context, {
    required AppServices services,
    required CatalogGame game,
  }) async {
    final plan = await showDialog<LaunchPlan>(
      context: context,
      builder: (_) => LauncherDialog(services: services, game: game),
    );
    if (plan == null || !context.mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StreamPage(
          services: services,
          game: game,
          request: SessionCreateRequest(
            token: null,
            streamingBaseUrl: plan.streamingBaseUrl,
            appId: plan.appId,
            internalTitle: game.title,
            zone: 'prod',
            settings: services.settings.buildStreamSettings(),
          ),
        ),
      ),
    );
  }
}
