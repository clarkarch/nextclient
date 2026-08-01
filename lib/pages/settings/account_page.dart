import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';

/// NVIDIA account info + sign out.
class AccountPage extends StatelessWidget {
  final AppServices services;
  final VoidCallback onSignOut;

  const AccountPage({
    super.key,
    required this.services,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final session = services.auth.getSession();
    final user = session?.user;

    return NeonPageScaffold(
      title: 'Account',
      showBack: true,
      child: user == null
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'Not signed in.',
                  style: TextStyle(color: Neon.inkMuted, fontSize: 13),
                ),
              ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    NeonCard(
                      glow: true,
                      child: Column(
                        children: [
                          ClipOval(
                            child: user.avatarUrl != null
                                ? Image.network(
                                    user.avatarUrl!,
                                    width: 72,
                                    height: 72,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        _AvatarFallback(initial: _initial(user)),
                                  )
                                : _AvatarFallback(initial: _initial(user)),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            user.displayName,
                            style: const TextStyle(
                              color: Neon.ink,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (user.email != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              user.email!,
                              style: const TextStyle(
                                color: Neon.inkMuted,
                                fontSize: 13,
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          NeonChip(
                            label: user.membershipTier,
                            tone: user.membershipTier == 'ULTIMATE'
                                ? NeonChipTone.accent
                                : user.membershipTier == 'PRIORITY'
                                    ? NeonChipTone.violet
                                    : NeonChipTone.neutral,
                            filled: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    NeonCard(
                      padding: EdgeInsets.zero,
                      child: NeonSettingTile(
                        icon: Icons.badge_outlined,
                        title: 'User ID',
                        subtitle: user.userId,
                      ),
                    ),
                    const SizedBox(height: 20),
                    NeonButton(
                      label: 'Sign out',
                      icon: Icons.logout,
                      onPressed: () async {
                        await services.auth.logout();
                        onSignOut();
                      },
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  String _initial(AuthUser user) {
    final name = user.displayName.trim();
    return name.isEmpty ? '?' : name[0].toUpperCase();
  }
}

class _AvatarFallback extends StatelessWidget {
  final String initial;

  const _AvatarFallback({required this.initial});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        gradient: Neon.accentGradient,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            color: Neon.bgA,
            fontSize: 28,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}
