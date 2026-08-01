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
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.6,
            colors: [Color(0x1F00D9FF), Color(0x00000000)],
            stops: [0, 0.6],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: NeonCard(
                padding: const EdgeInsets.all(32),
                glow: true,
                radius: 24,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Brand(),
                    const SizedBox(height: 8),
                    const Text(
                      'GE FORCE NOW, but with neon',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 12.5,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 32),
                    if (_error != null) ...[
                      NeonChip(
                        label: _error!,
                        tone: NeonChipTone.error,
                        filled: true,
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
                    const SizedBox(height: 20),
                    const Row(
                      children: [
                        Expanded(child: Divider()),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            'NVIDIA GeForce NOW account required',
                            style: TextStyle(color: Neon.inkMuted, fontSize: 10.5),
                          ),
                        ),
                        Expanded(child: Divider()),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            gradient: Neon.accentGradient,
            borderRadius: BorderRadius.circular(18),
            boxShadow: Neon.glowShadow(radius: 24, alpha: 0.5),
          ),
          child: const Center(
            child: Text(
              'N',
              style: TextStyle(
                color: Neon.bgA,
                fontSize: 30,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'NEXTC',
          style: TextStyle(
            color: Neon.ink,
            fontSize: 28,
            fontWeight: FontWeight.w900,
            letterSpacing: 4,
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
