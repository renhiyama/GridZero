/// First-run gate. The primary path is the provisioning QR: HQ issues the
/// account and the device scans it to adopt the identity. Manual
/// username/password login is tucked behind "alternative ways to log in" for
/// HQ staff (ADMIN) and re-logins on a device that already holds an account.
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/provision_packet.dart';
import 'hud_theme.dart';
import 'provision_scan_page.dart';
import 'sos_banner.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _manual = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final app = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await app.login(_username.text, _password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = result;
    });
  }

  Future<void> _provision() async {
    final app = AppScope.of(context);
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const ProvisionScanPage(
          label: 'HQ PROVISIONING',
          expectedType: ProvisionType.account,
        ),
      ),
    );
    if (payload == null || !mounted) return;
    final result = await app.provisionAccount(payload);
    if (!mounted) return;
    if (result != null) {
      setState(() {
        _busy = false;
        _error = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final app = AppScope.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'GRIDZERO',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.primary,
                            fontFamily: 'monospace',
                            fontSize: 30,
                            letterSpacing: 6,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'grid-zero · air-gapped relief mesh',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.textDim,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 28),
                        // Primary path: scan the account QR that HQ shows.
                        HudPanel(
                          title: 'GET STARTED',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              FilledButton.icon(
                                onPressed: _busy ? null : _provision,
                                icon: const Icon(
                                  Icons.qr_code_scanner,
                                  size: 22,
                                ),
                                label: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  child: Column(
                                    children: [
                                      const Text(
                                        'SCAN PROVISIONING QR',
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 14,
                                          letterSpacing: 2,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'point the camera at the code on the '
                                        'HQ screen',
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 10,
                                          color: p.textDim,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (_error != null) ...[
                                const SizedBox(height: 14),
                                Text(
                                  _error!,
                                  style: TextStyle(
                                    color: p.error,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'ACCOUNTS ARE ISSUED BY COMMAND HQ. A NEW DEVICE '
                          'JOINS BY SCANNING THE PROVISIONING QR SHOWN ON THE '
                          'HQ REGISTER TAB.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.textDim,
                            fontFamily: 'monospace',
                            fontSize: 10,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Secondary path, collapsed by default.
                        TextButton.icon(
                          onPressed: () =>
                              setState(() => _manual = !_manual),
                          icon: Icon(
                            _manual ? Icons.expand_less : Icons.expand_more,
                            size: 16,
                            color: p.textDim,
                          ),
                          label: Text(
                            _manual
                                ? 'HIDE ALTERNATIVE WAYS TO LOG IN'
                                : 'ALTERNATIVE WAYS TO LOG IN',
                            style: TextStyle(
                              color: p.textDim,
                              fontFamily: 'monospace',
                              fontSize: 11,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          transitionBuilder: (child, anim) => SizeTransition(
                            sizeFactor: anim,
                            child: FadeTransition(opacity: anim, child: child),
                          ),
                          child: !_manual
                              ? const SizedBox(width: double.infinity)
                              : Container(
                                  key: const ValueKey('manual-login'),
                                  margin: const EdgeInsets.only(top: 8),
                                  child: HudPanel(
                                    title: 'MANUAL LOGIN',
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        TextField(
                                          controller: _username,
                                          autocorrect: false,
                                          enableSuggestions: false,
                                          textInputAction:
                                              TextInputAction.next,
                                          onSubmitted: (_) => FocusScope.of(
                                            context,
                                          ).nextFocus(),
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 14,
                                          ),
                                          decoration: const InputDecoration(
                                            labelText: 'USERNAME',
                                            border: UnderlineInputBorder(),
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        TextField(
                                          controller: _password,
                                          obscureText: true,
                                          autocorrect: false,
                                          enableSuggestions: false,
                                          textInputAction: TextInputAction.done,
                                          onSubmitted: (_) =>
                                              _busy ? null : _submit(),
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 14,
                                          ),
                                          decoration: const InputDecoration(
                                            labelText: 'PASSWORD',
                                            border: UnderlineInputBorder(),
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        FilledButton(
                                          onPressed: _busy ? null : _submit,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                            child: Text(
                                              _busy ? 'CONNECTING…' : 'LOG IN',
                                              style: const TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 14,
                                                letterSpacing: 2,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'HQ STAFF: LOG IN AS ADMIN WITH AN '
                                          'EMPTY PASSWORD FIELD.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: p.textDim,
                                            fontFamily: 'monospace',
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          SosAlertBanner(app: app),
        ],
      ),
    );
  }
}
