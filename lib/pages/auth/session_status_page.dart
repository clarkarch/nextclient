import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../main.dart';

class SessionStatusPage extends StatefulWidget {
  final AppServices services;

  const SessionStatusPage({super.key, required this.services});

  @override
  State<SessionStatusPage> createState() => _SessionStatusPageState();
}

class _SessionStatusPageState extends State<SessionStatusPage> {
  bool _busy = false;
  String? _message;
  String? _error;

  AuthSession? get _session => widget.services.auth.getSession();

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_error != null)
          Card(
            color: Colors.red.withValues(alpha: 0.1),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          ),
        if (_message != null)
          Card(
            color: Colors.blue.withValues(alpha: 0.1),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_message!),
            ),
          ),
        const SizedBox(height: 8),
        _SessionCard(session: session),
        const SizedBox(height: 16),
        if (session == null) _buildLoginButtons() else _buildLogoutButton(),
      ],
    );
  }

  Widget _buildLoginButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          icon: const Icon(Icons.login),
          label: const Text('Login with browser (OAuth)'),
          onPressed: _busy ? null : _loginOAuth,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.qr_code),
          label: const Text('Device-code login (QR)'),
          onPressed: _busy ? null : _startDeviceLogin,
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Widget _buildLogoutButton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.logout),
          label: const Text('Logout'),
          onPressed: _busy ? null : _logout,
        ),
      ],
    );
  }

  Future<void> _loginOAuth() async {
    setState(() {
      _busy = true;
      _message = 'Opened browser. Waiting for redirect...';
      _error = null;
    });
    try {
      await widget.services.auth.login();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'Authenticated!';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = null;
        _error = 'OAuth failed: $e';
      });
    }
  }

  Future<void> _startDeviceLogin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final challenge = await widget.services.auth.startDeviceLogin();
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _DeviceLoginPage(
            services: widget.services,
            challenge: challenge,
          ),
        ),
      );
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Device login start failed: $e';
      });
    }
  }

  Future<void> _logout() async {
    setState(() {
      _busy = true;
      _message = null;
      _error = null;
    });
    await widget.services.auth.logout();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = 'Logged out';
    });
  }
}

class _SessionCard extends StatelessWidget {
  final AuthSession? session;

  const _SessionCard({this.session});

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Not logged in'),
        ),
      );
    }
    final remaining = s.tokens.expiresAt - DateTime.now().millisecondsSinceEpoch;
    final minutes = (remaining / 60000).floor();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Signed in as ${s.user.displayName}',
                style: Theme.of(context).textTheme.titleLarge),
            Text('User ID: ${s.user.userId}'),
            Text('Email: ${s.user.email ?? "n/a"}'),
            Text('Tier: ${s.user.membershipTier}'),
            Text('Provider: ${s.provider.code}'),
            Text('Token expires: ${s.tokens.expiresAt} (in ~$minutes min)'),
            if (s.tokens.clientToken != null)
              Text('Client token: present'),
          ],
        ),
      ),
    );
  }
}

class _DeviceLoginPage extends StatefulWidget {
  final AppServices services;
  final AuthDeviceLoginChallenge challenge;

  const _DeviceLoginPage({
    required this.services,
    required this.challenge,
  });

  @override
  State<_DeviceLoginPage> createState() => _DeviceLoginPageState();
}

class _DeviceLoginPageState extends State<_DeviceLoginPage> {
  AuthDeviceLoginPollStatus? _status;
  String? _error;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  Future<void> _startPolling() async {
    setState(() => _polling = true);
    try {
      while (mounted) {
        final result = await widget.services.auth.pollDeviceLogin(
          attemptId: widget.challenge.attemptId,
          deviceCode: widget.challenge.deviceCode,
        );
        if (!mounted) return;
        setState(() => _status = result.status);
        _error = result.error;

        if (result.status == AuthDeviceLoginPollStatus.authorized) {
          final session = await widget.services.auth.completeDeviceLogin(
            attemptId: widget.challenge.attemptId,
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Logged in as ${session.user.displayName}')),
          );
          Navigator.of(context).pop();
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _polling = false;
        _error = 'Polling failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device-code login')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              QrImageView(
                data: widget.challenge.verificationUriComplete,
                size: 220,
              ),
              const SizedBox(height: 16),
              Text('Scan with your phone or open:'),
              SelectableText(
                widget.challenge.verificationUriComplete,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text('Code: ${widget.challenge.userCode}'),
              const SizedBox(height: 16),
              _statusText(),
              if (_polling) const CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusText() {
    final status = _status;
    final text = switch (status) {
      AuthDeviceLoginPollStatus.pending => 'Waiting for approval...',
      AuthDeviceLoginPollStatus.slowDown => 'Slow down, retrying...',
      AuthDeviceLoginPollStatus.authorized => 'Approved!',
      AuthDeviceLoginPollStatus.expired => 'Expired: ${_error ?? ""}',
      AuthDeviceLoginPollStatus.accessDenied => 'Denied: ${_error ?? ""}',
      AuthDeviceLoginPollStatus.error => 'Error: ${_error ?? ""}',
      null => 'Waiting...',
    };
    return Text(text);
  }
}