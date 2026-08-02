import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/neon.dart';

/// Show a modern neon snackbar. [isError] tints it red; when [copyable], a
/// copy button is appended so error text can be grabbed for bug reports.
/// Optionally pass [actionLabel] + [onAction] for an action button.
void showNeonSnackbar(
  BuildContext context,
  String message, {
  bool isError = false,
  bool copyable = true,
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: duration ?? Duration(seconds: isError ? 6 : 3),
      backgroundColor: isError
          ? Neon.error.withValues(alpha: 0.16)
          : Neon.bgC,
      content: Row(
        children: [
          if (isError) ...[
            const Icon(Icons.error_outline, color: Neon.error, size: 18),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Neon.ink, fontSize: 13),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            TextButton(
              onPressed: () {
                messenger.hideCurrentSnackBar();
                onAction();
              },
              style: TextButton.styleFrom(
                foregroundColor: Neon.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(
                actionLabel.toUpperCase(),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
          if (copyable)
            IconButton(
              tooltip: 'Copy',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 16, color: Neon.inkSoft),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: message));
                messenger.hideCurrentSnackBar();
                messenger.showSnackBar(
                  const SnackBar(
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 2),
                    backgroundColor: Neon.bgC,
                    content: Text(
                      'Copied to clipboard',
                      style: TextStyle(color: Neon.ink, fontSize: 13),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    ),
  );
}
