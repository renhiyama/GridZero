/// Dedicated HQ sync page: HQ hosts a wifi network named `GZ-<USERNAME>` whose
/// passphrase derives from that account's stored hash. The page shows a
/// WIFI: QR: the phone's system camera joins on scan: and then animates
/// through LINK UP → EXCHANGING DATA → SYNCED as the device connects.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import 'hud_theme.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _radar = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  String? _hostingFor;
  final List<String> _steps = [];
  String? _current;
  String? _error;

  @override
  void dispose() {
    _radar.dispose();
    super.dispose();
  }

  Future<void> _host(String username) async {
    if (_hostingFor != null) return;
    final app = AppScope.of(context);
    setState(() {
      _hostingFor = username;
      _steps.clear();
      _current = null;
      _error = null;
    });
    final error = await app.hostLinkFor(username, onStep: (s) {
      if (!mounted) return;
      setState(() {
        _steps.add(s);
        _current = s;
      });
    });
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _error = error;
        _hostingFor = null;
      });
    }
  }

  Future<void> _teardown() async {
    final app = AppScope.of(context);
    await app.stopHostLink();
    if (!mounted) return;
    setState(() => _hostingFor = null);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return SafeArea(
      child: AnimatedBuilder(
        animation: app,
        builder: (context, _) {
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: child,
            ),
            child: _hostingFor != null
                ? _HostingView(
                    key: ValueKey('host-$_hostingFor'),
                    username: _hostingFor!,
                    linkUp: _steps.contains('LINK UP: SHOW QR TO THE DEVICE'),
                    steps: _steps,
                    current: _current,
                    error: _error,
                    radar: _radar,
                    onTeardown: _teardown,
                  )
                : _DirectoryView(
                    key: const ValueKey('directory'),
                    radar: _radar,
                    error: _error,
                    onHost: _host,
                  ),
          );
        },
      ),
    );
  }
}

/// Pick an account to host a link for. Only accounts issued from THIS
/// terminal can join: the phone must hold the matching hash.
class _DirectoryView extends StatelessWidget {
  const _DirectoryView({
    super.key,
    required this.radar,
    required this.error,
    required this.onHost,
  });

  final Animation<double> radar;
  final String? error;
  final void Function(String username) onHost;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    final linkError = error;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          Text(
            '▚▞ DEVICE SYNC',
            style: TextStyle(
              color: p.primary,
              fontFamily: 'monospace',
              fontSize: 16,
              letterSpacing: 3,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (linkError != null) ...[
            HudPanel(
              title: 'LINK FAILED',
              child: Text(
                linkError,
                style: TextStyle(
                  color: p.error,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          HudPanel(
            title: 'HOST A LINK',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 120,
                  child: AnimatedBuilder(
                    animation: radar,
                    builder: (context, _) => CustomPaint(
                      painter: _RadarPainter(
                        progress: radar.value,
                        color: p.primary,
                        dim: p.primaryDim,
                      ),
                    ),
                  ),
                ),
                HduReadout(
                  'HOW',
                  'pick an account: HQ opens a wifi network named after it; '
                  'the device scans the QR to join and exchange data.',
                ),
                HduReadout(
                  'NOTE',
                  'device-to-device today: after deployment this exchange '
                      'runs over ordinary internet infrastructure.',
                  color: p.textDim,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FutureBuilder(
            future: app.accounts(),
            builder: (context, snap) {
              final accounts = snap.data ?? const <Account>[];
              if (accounts.isEmpty) {
                return HudPanel(
                  title: 'NO ACCOUNTS',
                  child: const HduReadout(
                    'EMPTY',
                    'issue an account from REGISTER first',
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final a in accounts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: HudPanel(
                        title: a.username,
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: a.role == Role.officer
                                      ? p.primary
                                      : p.textDim,
                                ),
                              ),
                              child: Text(
                                a.role.name.toUpperCase(),
                                style: TextStyle(
                                  color: a.role == Role.officer
                                      ? p.primary
                                      : p.textDim,
                                  fontFamily: 'monospace',
                                  fontSize: 9,
                                ),
                              ),
                            ),
                            const Spacer(),
                            FilledButton.icon(
                              onPressed: () => onHost(a.username),
                              icon: const Icon(Icons.wifi_tethering, size: 16),
                              label: const Text(
                                'HOST LINK',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Hosting live for one account: WIFI QR + step log.
class _HostingView extends StatelessWidget {
  const _HostingView({
    super.key,
    required this.linkUp,
    required this.username,
    required this.steps,
    required this.current,
    required this.error,
    required this.radar,
    required this.onTeardown,
  });

  final bool linkUp;
  final String username;
  final List<String> steps;
  final String? current;
  final String? error;
  final Animation<double> radar;
  final VoidCallback onTeardown;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    final ssid = AppState.linkSsidFor(username);
    // Standard WIFI payload: Android/iOS system cameras offer to join
    // straight from the scan result. Passphrase is this session's OTP.
    final otp = app.hotspotPassword ?? '';
    final wifiQr = otp.isEmpty ? null : 'WIFI:T:WPA;S:$ssid;P:$otp;;';
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Text(
          '▚▞ DEVICE SYNC',
          style: TextStyle(
            color: p.primary,
            fontFamily: 'monospace',
            fontSize: 16,
            letterSpacing: 3,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        HudPanel(
          title: 'LINK OPEN · $username',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wifiQr != null && linkUp) ...[
                Center(child: HudQr(data: wifiQr, size: 190)),
                const SizedBox(height: 6),
                HduReadout(
                  'SCAN',
                  'phone camera → join network → exchange starts by itself',
                ),
              ] else ...[
                SizedBox(
                  height: 90,
                  child: Center(
                    child: CircularProgressIndicator(color: p.primary),
                  ),
                ),
                HduReadout('STATUS', current ?? 'BRINGING UP LINK…'),
              ],
              for (final s in steps)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 14, color: p.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          s,
                          style: TextStyle(
                            color: p.text,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (app.lastSyncImported > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${app.lastSyncImported} records absorbed from the device',
                    style: TextStyle(
                      color: p.primary,
                      fontFamily: 'monospace',
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onTeardown,
                  child: Text(
                    'CLOSE LINK',
                    style: TextStyle(
                      color: p.error,
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Concentric expanding rings: the "listening" motif.
class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.progress,
    required this.color,
    required this.dim,
  });

  final double progress;
  final Color color;
  final Color dim;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.shortestSide * 0.48;
    for (var i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final radius = maxRadius * t;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Color.lerp(color, dim, t)!
            .withValues(alpha: (1 - t).clamp(0.0, 1.0) * 0.9);
      canvas.drawCircle(center, radius, paint);
    }
    canvas.drawCircle(center, 3.5, Paint()..color = color);
    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = dim;
    canvas.drawLine(
      center,
      center +
          Offset(maxRadius * 0.92 * cos(progress * 2 * pi),
              maxRadius * 0.92 * sin(progress * 2 * pi)),
      sweep,
    );
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.progress != progress || old.color != color;
}
