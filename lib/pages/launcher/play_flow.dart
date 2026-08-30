import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
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

    // Check for active sessions before creating a new one — mirrors
    // OpenNOW's useGameLaunch active-session check + conflict dialog.
    final numericAppId = int.tryParse(plan.appId);
    String? token;
    try {
      token = await services.auth.resolveJwtToken();
    } catch (_) {
      token = null;
    }
    ExistingSessionStrategy? existingStrategy;
    SessionClaimRequest? resumeClaim;

    if (token != null && token.isNotEmpty && numericAppId != null) {
      try {
        final activeSessions = await services.cloudMatch.getActiveSessions(
          token: token,
          streamingBaseUrl: plan.streamingBaseUrl,
        );
        if (activeSessions.isNotEmpty && context.mounted) {
          // Same-app ready session → auto-resume (status 2/3 only; status 1
          // still in queue — let createSession handle queue/ads).
          ActiveSessionInfo? matchingSession;
          for (final s in activeSessions) {
            if (s.appId == numericAppId && (s.status == 2 || s.status == 3)) {
              matchingSession = s;
              break;
            }
          }
          if (matchingSession != null) {
            resumeClaim = SessionClaimRequest(
              token: token,
              streamingBaseUrl: matchingSession.streamingBaseUrl,
              sessionId: matchingSession.sessionId,
              serverIp: matchingSession.serverIp ?? '',
              appId: plan.appId,
              appLaunchMode: matchingSession.appLaunchMode,
              settings: services.settings.buildStreamSettings(),
            );
          } else {
            // Other app ready session → conflict dialog.
            ActiveSessionInfo? otherSession;
            for (final s in activeSessions) {
              if (s.status == 2 || s.status == 3) {
                otherSession = s;
                break;
              }
            }
            if (otherSession != null) {
              final choice = await _showSessionConflictDialog(context);
              if (!context.mounted) return;
              if (choice == SessionConflictChoice.cancel) return;
              if (choice == SessionConflictChoice.resume) {
                resumeClaim = SessionClaimRequest(
                  token: token,
                  streamingBaseUrl: otherSession.streamingBaseUrl,
                  sessionId: otherSession.sessionId,
                  serverIp: otherSession.serverIp ?? '',
                  appId: otherSession.appId.toString(),
                  appLaunchMode: otherSession.appLaunchMode,
                  settings: services.settings.buildStreamSettings(),
                );
              } else if (choice == SessionConflictChoice.new_) {
                existingStrategy = ExistingSessionStrategy.forceNew;
                // Stop existing sessions before creating new one (like
                // sessionLifecycle.ts stopActiveSessionsForCreate).
                try {
                  final toStop = activeSessions.where(isActiveCreateSessionConflict).toList();
                  for (final s in toStop) {
                    final ip = s.serverIp;
                    if (ip == null || ip.isEmpty) continue;
                    try {
                      await services.cloudMatch.stopSession(SessionStopRequest(
                        token: token,
                        streamingBaseUrl: plan.streamingBaseUrl,
                        serverIp: ip,
                        zone: 'prod',
                        sessionId: s.sessionId,
                      ));
                    } catch (_) {}
                  }
                } catch (_) {}
              }
            }
          }
        }
      } catch (_) {
        // getActiveSessions failure is non-fatal — fall through to create.
      }
    }

    if (!context.mounted) return;

    // Resume path
    if (resumeClaim != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => StreamPage(
            services: services,
            game: game,
            resumeClaim: resumeClaim,
          ),
        ),
      );
      return;
    }

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
            existingSessionStrategy: existingStrategy,
          ),
        ),
      ),
    );
  }

  static Future<SessionConflictChoice> _showSessionConflictDialog(
    BuildContext context,
  ) async {
    final result = await showDialog<SessionConflictChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Neon.bgB,
        title: const Text('Active Session Detected',
            style: TextStyle(color: Neon.ink, fontWeight: FontWeight.w800)),
        content: const Text(
          'You have an active session running. Resume it or start a new one?',
          style: TextStyle(color: Neon.inkSoft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(SessionConflictChoice.cancel),
            child: const Text('Cancel', style: TextStyle(color: Neon.inkMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(SessionConflictChoice.new_),
            child: const Text('Start New', style: TextStyle(color: Neon.warning)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Neon.accent),
            onPressed: () => Navigator.of(ctx).pop(SessionConflictChoice.resume),
            child: const Text('Resume', style: TextStyle(color: Neon.bgA)),
          ),
        ],
      ),
    );
    return result ?? SessionConflictChoice.cancel;
  }
}
