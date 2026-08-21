import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../main.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_chip.dart';

/// Neon-branded login screen with browser OAuth and device-code QR login.
class LoginPage extends StatefulWidget {
  final AppServices services;
  final VoidCallback onAuthenticated;

  const LoginPage({
    super.key,
    required this.services,
    required this.onAuthenticated,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _busy = false;
  String? _error;

  Future<void> _loginBrowser() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.services.auth.login();
      if (!mounted) return;
      widget.onAuthenticated();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Sign-in failed: $e';
      });
    }
  }

  Future<void> _startQr() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final challenge = await widget.services.auth.startDeviceLogin();
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _QrLoginPage(
            services: widget.services,
            challenge: challenge,
            onAuthenticated: widget.onAuthenticated,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not start device login: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bgA,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder<BackgroundStyle>(
            valueListenable: BackgroundGlow.current,
            builder: (context, style, _) => NeonBackground(style: style),
          ),
          // Floating neon orbs for extra depth — subtle, blurred
          IgnorePointer(
            child: Stack(
              children: [
                Positioned(
                  top: -60,
                  right: -40,
                  child: Container(
                    width: 280,
                    height: 280,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Neon.accent.withValues(alpha: 0.18),
                          Colors.transparent
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: -80,
                  left: -60,
                  child: Container(
                    width: 360,
                    height: 360,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Neon.violet.withValues(alpha: 0.14),
                          Colors.transparent
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: _FancyLoginCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _Brand(),
                      const SizedBox(height: 8),
                      const Text(
                        'GE FORCE NOW, but with neon',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Neon.inkMuted,
                          fontSize: 12.5,
                          letterSpacing: 1.1,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 28),
                      if (_error != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: Neon.error.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: Neon.error.withValues(alpha: 0.38)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline,
                                  size: 16, color: Neon.error),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: const TextStyle(
                                      color: Neon.error, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      NeonButton(
                        label: 'Sign in',
                        icon: Icons.lock_open,
                        wide: true,
                        busy: _busy,
                        onPressed: _loginBrowser,
                      ),
                      const SizedBox(height: 12),
                      NeonOutlineButton(
                        label: 'Device-code login',
                        icon: Icons.qr_code,
                        onPressed: _busy ? null : _startQr,
                      ),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                              child: Container(
                                  height: 1,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        Colors.transparent,
                                        Neon.outlineSoft
                                      ],
                                    ),
                                  ))),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              'NVIDIA GeForce NOW account required',
                              style: TextStyle(
                                  color: Neon.inkMuted, fontSize: 10.5),
                            ),
                          ),
                          Expanded(
                              child: Container(
                                  height: 1,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        Neon.outlineSoft,
                                        Colors.transparent
                                      ],
                                    ),
                                  ))),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const _ThirdPartyDisclaimer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
       ),
    );
  }
}

class _FancyLoginCard extends StatelessWidget {
  final Widget child;
  const _FancyLoginCard({required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Neon.bgC.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Neon.outline.withValues(alpha: 0.9)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 28,
              offset: const Offset(0, 12)),
          BoxShadow(
              color: Neon.accent.withValues(alpha: 0.14),
              blurRadius: 32,
              offset: const Offset(0, 0)),
        ],
      ),
      child: child,
    );
  }
}

class _Brand extends StatefulWidget {
  const _Brand({super.key});
  @override
  State<_Brand> createState() => _BrandState();
}

class _BrandState extends State<_Brand>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);
  late final Animation<double> _glow = Tween<double>(begin: 0.42, end: 0.62)
      .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AnimatedBuilder(
          animation: _glow,
          builder: (context, _) => Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              gradient: Neon.accentGradient,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                    color: Neon.accent.withValues(alpha: _glow.value),
                    blurRadius: 28,
                    spreadRadius: 1),
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 6)),
              ],
            ),
            child: const Center(
              child: Text(
                'N',
                style: TextStyle(
                  color: Neon.bgA,
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        ShaderMask(
          shaderCallback: (b) => Neon.accentGradient.createShader(b),
          child: const Text(
            'NEXTCLIENT',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w900,
              letterSpacing: 4.5,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: 56,
          height: 3,
          decoration: BoxDecoration(
            gradient: Neon.accentGradient,
            borderRadius: BorderRadius.circular(2),
            boxShadow: [
              BoxShadow(
                  color: Neon.accent.withValues(alpha: 0.45), blurRadius: 8)
            ],
          ),
        ),
      ],
    );
  }
}

class _QrLoginPage extends StatefulWidget {
  final AppServices services;
  final AuthDeviceLoginChallenge challenge;
  final VoidCallback onAuthenticated;

  const _QrLoginPage({
    required this.services,
    required this.challenge,
    required this.onAuthenticated,
  });

  @override
  State<_QrLoginPage> createState() => _QrLoginPageState();
}

class _QrLoginPageState extends State<_QrLoginPage> {
  AuthDeviceLoginPollStatus? _status;
  String? _error;
  bool _polling = true;

  @override
  void initState() {
    super.initState();
    _poll();
  }

  Future<void> _poll() async {
    while (mounted) {
      final result = await widget.services.auth.pollDeviceLogin(
        attemptId: widget.challenge.attemptId,
        deviceCode: widget.challenge.deviceCode,
      );
      if (!mounted) return;
      setState(() {
        _status = result.status;
        _error = result.error;
      });

      if (result.status == AuthDeviceLoginPollStatus.authorized) {
        await widget.services.auth.completeDeviceLogin(
          attemptId: widget.challenge.attemptId,
        );
        if (!mounted) return;
        Navigator.of(context).pop();
        widget.onAuthenticated();
        return;
      }
      if (result.status == AuthDeviceLoginPollStatus.expired ||
          result.status == AuthDeviceLoginPollStatus.accessDenied ||
          result.status == AuthDeviceLoginPollStatus.error) {
        setState(() => _polling = false);
        return;
      }
      await Future<void>.delayed(
        Duration(seconds: widget.challenge.intervalSeconds),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bgA,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Neon.inkSoft,
        title: const Text('Device-code login'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              NeonCard(
                glow: true,
                radius: 20,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: QrImageView(
                    data: widget.challenge.verificationUriComplete,
                    size: 200,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Scan with your phone, or open the link:',
                style: TextStyle(color: Neon.inkSoft, fontSize: 13),
              ),
              const SizedBox(height: 8),
              SelectableText(
                widget.challenge.verificationUriComplete,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Neon.accent, fontSize: 12),
              ),
              const SizedBox(height: 8),
              NeonChip(
                label: 'Code ${widget.challenge.userCode}',
                tone: NeonChipTone.violet,
              ),
              const SizedBox(height: 20),
              Text(
                _statusText(),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _status == AuthDeviceLoginPollStatus.authorized
                      ? Neon.success
                      : Neon.inkSoft,
                  fontSize: 13,
                ),
              ),
              if (_polling) ...[
                const SizedBox(height: 16),
                const CircularProgressIndicator(color: Neon.accent, strokeWidth: 2.5),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _statusText() {
    return switch (_status) {
      AuthDeviceLoginPollStatus.pending => 'Waiting for approval...',
      AuthDeviceLoginPollStatus.slowDown => 'Retrying...',
      AuthDeviceLoginPollStatus.authorized => 'Approved!',
      AuthDeviceLoginPollStatus.expired => 'Expired: ${_error ?? ""}',
      AuthDeviceLoginPollStatus.accessDenied => 'Denied: ${_error ?? ""}',
      AuthDeviceLoginPollStatus.error => 'Error: ${_error ?? ""}',
      null => 'Waiting...',
    };
  }
}

/// Disclaimer shown at the bottom of the login screen. This is a
/// community-built client, not an official NVIDIA product.
class _ThirdPartyDisclaimer extends StatelessWidget {
  const _ThirdPartyDisclaimer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Neon.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Neon.warning.withValues(alpha: 0.25)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: Neon.warning),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Unofficial third-party client. Not created by, affiliated '
              'with, or endorsed by NVIDIA. GeForce NOW is a trademark of '
              'NVIDIA Corporation. Use at your own risk.',
              style: TextStyle(
                color: Neon.inkSoft,
                fontSize: 10.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
