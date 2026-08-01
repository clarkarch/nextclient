import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../utils/friendly_error.dart';
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
                    _accountsCard(),
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

  /// Saved-account switcher: switch / add / remove accounts.
  Widget _accountsCard() {
    final saved = widget.services.auth.getSavedAccounts();
    final activeId = widget.services.auth.getSession()?.user.userId;
    return NeonCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'ACCOUNTS',
                style: TextStyle(
                  color: Neon.accent,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.6,
                ),
              ),
            ),
          ),
          for (final acc in saved) ...[
            if (acc != saved.first) const Divider(height: 1),
            _AccountRow(
              account: acc,
              active: acc.userId == activeId,
              onSwitch: () => _switchAccount(acc),
              onRemove: () => _removeAccount(acc),
            ),
          ],
          const Divider(height: 1),
          NeonSettingTile(
            icon: Icons.person_add_alt_1,
            title: 'Add account',
            subtitle: 'Sign in with another NVIDIA account',
            onTap: _addAccount,
            trailing: const Icon(Icons.chevron_right, color: Neon.inkMuted),
          ),
        ],
      ),
    );
  }

  Future<void> _switchAccount(SavedAccount acc) async {
    try {
      await widget.services.auth.switchAccount(userId: acc.userId);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onSignOut();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Switch failed: ${friendlyError(e)}')),
      );
    }
  }

  Future<void> _addAccount() async {
    try {
      await widget.services.auth.login();
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onSignOut();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Add account failed: ${friendlyError(e)}')),
      );
    }
  }

  Future<void> _removeAccount(SavedAccount acc) async {
    await widget.services.auth.removeAccount(userId: acc.userId);
    if (!mounted) return;
    setState(() {});
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

class _AccountRow extends StatelessWidget {
  final SavedAccount account;
  final bool active;
  final VoidCallback onSwitch;
  final VoidCallback onRemove;

  const _AccountRow({
    required this.account,
    required this.active,
    required this.onSwitch,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: active ? null : onSwitch,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                gradient: Neon.accentGradient,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(
                  account.displayName.isNotEmpty
                      ? account.displayName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    color: Neon.bgA,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.displayName,
                    style: const TextStyle(
                      color: Neon.ink,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    account.email ?? account.providerCode,
                    style: const TextStyle(
                      color: Neon.inkMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              const Icon(Icons.check_circle, color: Neon.accent, size: 18)
            else
              const Icon(Icons.swap_horiz, color: Neon.inkMuted, size: 18),
            IconButton(
              tooltip: 'Remove account',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline,
                  size: 16, color: Neon.inkMuted),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
