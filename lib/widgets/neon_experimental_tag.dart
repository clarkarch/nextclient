import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// Small "EXPERIMENTAL" pill used to flag unverified options on the settings
/// pages. Experimental options are kept but distinguished from stable ones.
class NeonExperimentalTag extends StatelessWidget {
  final String label;

  const NeonExperimentalTag({this.label = 'EXPERIMENTAL', super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Neon.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Neon.warning.withValues(alpha: 0.55)),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: Neon.warning,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
          fontFamily: theme.textTheme.labelSmall?.fontFamily,
        ),
      ),
    );
  }
}