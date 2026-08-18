/// First-run gate. Users identify before the radio comes up; the HQ laptop
/// logs in as ADMIN (password bypassed — prototype), everyone else registers
/// once then logs in.
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import 'hud_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _registerMode = false;
  Role _registerRole = Role.citizen;
  String? _error;
  bool _busy = false;

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
    final result = _registerMode
        ? await app.register(_username.text, _password.text, _registerRole)
        : await app.login(_username.text, _password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
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
                    'AAPADSETU',
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
                    'आपदसेतु · air-gapped relief mesh',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: p.textDim,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 28),
                  HudPanel(
                    title: _registerMode ? 'REGISTER' : 'LOGIN',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _username,
                          autocorrect: false,
                          enableSuggestions: false,
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
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                          ),
                          onSubmitted: (_) => _busy ? null : _submit(),
                          decoration: const InputDecoration(
                            labelText: 'PASSWORD',
                            border: UnderlineInputBorder(),
                          ),
                        ),
                        if (_registerMode) ...[
                          const SizedBox(height: 16),
                          Text(
                            'ROLE',
                            style: TextStyle(
                              color: p.textDim,
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 6),
                          HudSegmented<Role>(
                            options: const [
                              (Role.citizen, 'CITIZEN'),
                              (Role.officer, 'OFFICER'),
                            ],
                            value: _registerRole,
                            onChanged: (v) => setState(() => _registerRole = v),
                          ),
                        ],
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
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(
                              _busy
                                  ? 'CONNECTING…'
                                  : _registerMode
                                  ? 'CREATE & LOG IN'
                                  : 'LOG IN',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 14,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _registerMode = !_registerMode;
                                  _error = null;
                                }),
                          child: Text(
                            _registerMode
                                ? '← BACK TO LOGIN'
                                : 'NO ACCOUNT? REGISTER →',
                            style: TextStyle(
                              color: p.textDim,
                              fontFamily: 'monospace',
                              fontSize: 12,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _registerMode
                        ? 'ONE ACCOUNT PER DEVICE · KEEPS YOUR MESH ID STABLE'
                        : 'HQ: USERNAME ADMIN · NO PASSWORD NEEDED (PROTOTYPE)',
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
      ),
    );
  }
}
