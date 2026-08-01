import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_chip.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_setting_tile.dart';

/// NVIDIA account info, plan details (subscription) + sign out.
class AccountPage extends StatefulWidget {
  final AppServices services;
  final VoidCallback onSignOut;

  const AccountPage({
    super.key,
    required this.services,
    required this.onSignOut,
  });

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  SubscriptionInfo? _subscription;
  bool _loadingSubscription = true;

  @override
  void initState() {
    super.initState();
    widget.services.loadSubscription().then((info) {
      if (!mounted) return;
      setState(() {
        _subscription = info;
        _loadingSubscription = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.services.auth.getSession();
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
                    _profileCard(user),
                    const SizedBox(height: 16),
                    _planCard(),
                    const SizedBox(height: 16),
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
                        await widget.services.auth.logout();
                        widget.onSignOut();
                      },
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _profileCard(AuthUser user) {
    return NeonCard(
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
            label: _subscription?.membershipTier ?? user.membershipTier,
            tone: (user.membershipTier == 'ULTIMATE' ||
                    _subscription?.membershipTier == 'ULTIMATE')
                ? NeonChipTone.accent
                : (user.membershipTier == 'PRIORITY' ||
                        _subscription?.membershipTier == 'PRIORITY')
                    ? NeonChipTone.violet
                    : NeonChipTone.neutral,
            filled: true,
          ),
        ],
      ),
    );
  }

  Widget _planCard() {
    final sub = _subscription;
    return NeonCard(
      padding: const EdgeInsets.all(16),
      child: _loadingSubscription
          ? const SizedBox(
              height: 40,
              child: Center(
                child: CircularProgressIndicator(
                  color: Neon.accent,
                  strokeWidth: 2,
                ),
              ),
            )
          : sub == null
              ? const Text(
                  'Subscription details unavailable.',
                  style: TextStyle(color: Neon.inkMuted, fontSize: 12.5),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'PLAN',
                      style: TextStyle(
                        color: Neon.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (sub.isUnlimited) ...[
                      const _PlanRow(label: 'Type', value: 'Unlimited'),
                      const Divider(height: 14),
                    ],
                    _PlanRow(
                      label: 'Remaining',
                      value: sub.isUnlimited
                          ? 'Unlimited'
                          : '${sub.remainingHours.toStringAsFixed(1)} h',
                    ),
                    const Divider(height: 14),
                    _PlanRow(
                      label: 'Used',
                      value: '${sub.usedHours.toStringAsFixed(1)} h',
                    ),
                    if (sub.storageAddon != null) ...[
                      const Divider(height: 14),
                      _PlanRow(
                        label: 'Storage',
                        value:
                            '${sub.storageAddon!.sizeGb?.toStringAsFixed(0) ?? '?'} GB'
                                ' · ${sub.storageAddon!.regionName ?? 'N/A'}',
                      ),
                    ],
                    if (sub.entitledResolutions.isNotEmpty) ...[
                      const Divider(height: 14),
                      const Text(
                        'ENTITLED RESOLUTIONS',
                        style: TextStyle(
                          color: Neon.inkMuted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final r in sub.entitledResolutions)
                            NeonChip(
                              label:
                                  '${r.width}x${r.height} · ${r.fps}fps',
                              tone: NeonChipTone.violet,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
    );
  }

  String _initial(AuthUser user) {
    final name = user.displayName.trim();
    return name.isEmpty ? '?' : name[0].toUpperCase();
  }
}

class _PlanRow extends StatelessWidget {
  final String label;
  final String value;

  const _PlanRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(color: Neon.inkMuted, fontSize: 12.5),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            color: Neon.ink,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
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
