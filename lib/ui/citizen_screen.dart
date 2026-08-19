/// Persona A: Citizen / Survivor. One-tap SOS beacon + dynamic offline QR.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_scope.dart';
import '../core/mesh/mesh_node.dart';
import '../core/mesh_packet.dart';
import '../core/totp.dart';
import 'hud_theme.dart';

class CitizenScreen extends StatefulWidget {
  const CitizenScreen({super.key});

  @override
  State<CitizenScreen> createState() => _CitizenScreenState();
}

class _CitizenScreenState extends State<CitizenScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    final secondsLeft =
        totpWindowSeconds -
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) % totpWindowSeconds;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(app: app),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              children: [
                HudPanel(
                  title: 'SOS BROADCAST',
                  borderColor: app.sosActive ? p.error : p.primaryDim,
                  child: _SosPanel(app: app),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'IDENTITY CARD  /  TIER-1 + TIER-2',
                  child: _IdentityCard(app: app),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'DYNAMIC RATION QR  /  TOKEN ROTATES ${secondsLeft}s',
                  child: _DynamicQr(app: app, secondsLeft: secondsLeft),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'LOCATION',
                  child: _LocationPanel(app: app),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'MESH LINK',
                  child: _MeshStatus(app: app),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: p.primary),
              color: p.primary.withValues(alpha: 0.12),
            ),
            child: Text(
              'CITIZEN ▸ ${app.citizenId}',
              style: TextStyle(
                color: p.primary,
                fontFamily: 'monospace',
                fontSize: 12,
                letterSpacing: 1,
              ),
            ),
          ),
          const Spacer(),
          Text(
            'NODE ${app.mesh.nodeId.toRadixString(16).padLeft(4, '0').toUpperCase()}',
            style: TextStyle(
              color: p.textDim,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _SosPanel extends StatelessWidget {
  const _SosPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final flags = app.sosFlags;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('SEVERITY', style: _dim(context)),
            const Spacer(),
            for (var s = 1; s <= 5; s++)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: InkWell(
                  onTap: () => app.setSosFlags(
                    TriageFlags(
                      severity: s,
                      medical: flags.medical,
                      trapped: flags.trapped,
                      water: flags.water,
                      food: flags.food,
                    ),
                  ),
                  child: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: s <= flags.severity ? p.error : p.textDim,
                      ),
                      color: s <= flags.severity
                          ? p.error.withValues(alpha: 0.15)
                          : null,
                    ),
                    child: Text(
                      '$s',
                      style: TextStyle(
                        color: s <= flags.severity ? p.error : p.textDim,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final need in const [
              ('MED', 'medical'),
              ('TRAP', 'trapped'),
              ('WATER', 'water'),
              ('FOOD', 'food'),
            ])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _NeedToggle(
                    label: need.$1,
                    on: switch (need.$2) {
                      'medical' => flags.medical,
                      'trapped' => flags.trapped,
                      'water' => flags.water,
                      _ => flags.food,
                    },
                    onTap: () => app.setSosFlags(
                      TriageFlags(
                        severity: flags.severity,
                        medical: need.$2 == 'medical'
                            ? !flags.medical
                            : flags.medical,
                        trapped: need.$2 == 'trapped'
                            ? !flags.trapped
                            : flags.trapped,
                        water: need.$2 == 'water' ? !flags.water : flags.water,
                        food: need.$2 == 'food' ? !flags.food : flags.food,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: app.sosActive ? p.error : p.primary,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          onPressed: () => app.setSosActive(!app.sosActive),
          child: Text(
            app.sosActive ? '■ CANCEL SOS BEACON' : '► ACTIVATE SOS BEACON',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
        ),
        const SizedBox(height: 8),
        HduReadout(
          'PACKET',
          '18B TTL5 TYPE=0x01 TRIAGE=${flags.value.toString().padLeft(2, '0')}',
        ),
        if (app.sosActive)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: HudAlertBar('SOS ACTIVE — broadcasting every 30s via mesh'),
          ),
      ],
    );
  }

  TextStyle _dim(BuildContext context) => TextStyle(
    color: AppPalette.of(context).textDim,
    fontFamily: 'monospace',
    fontSize: 11,
    letterSpacing: 1,
  );
}

class _NeedToggle extends StatelessWidget {
  const _NeedToggle({
    required this.label,
    required this.on,
    required this.onTap,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: on ? p.secondary : p.textDim, width: 1),
          color: on ? p.secondary.withValues(alpha: 0.14) : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: on ? p.secondary : p.textDim,
            fontFamily: 'monospace',
            fontSize: 11,
            fontWeight: on ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final name = (app.username as String).isNotEmpty
        ? app.username as String
        : app.citizenId as String;
    final initials = name
        .split(' ')
        .where((s) => s.isNotEmpty)
        .take(2)
        .map((s) => s[0].toUpperCase())
        .join();
    final pinSet = app.pinHash != null;
    final famId = app.familyId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: p.primary, width: 2),
                color: p.primary.withValues(alpha: 0.12),
              ),
              child: Text(
                initials,
                style: TextStyle(
                  color: p.primary,
                  fontFamily: 'monospace',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      color: p.text,
                      fontFamily: 'monospace',
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    app.citizenId,
                    style: TextStyle(
                      color: p.textDim,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _Badge(
              label: pinSet ? 'PIN SET' : 'NO PIN',
              color: pinSet ? p.primary : p.textDim,
            ),
            const SizedBox(width: 8),
            if (famId != null)
              _Badge(label: 'FAMILY $famId', color: p.secondary),
          ],
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        color: color.withValues(alpha: 0.10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontFamily: 'monospace',
          fontSize: 10,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _DynamicQr extends StatelessWidget {
  const _DynamicQr({required this.app, required this.secondsLeft});

  final dynamic app;
  final int secondsLeft;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final payload = app.citizenQrPayload();
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          color: Colors.white,
          child: QrImageView(
            data: payload,
            version: QrVersions.auto,
            size: 180,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        HduReadout('TOKEN', app.currentToken().substring(0, 16)),
        const SizedBox(height: 4),
        HduReadout(
          'REFRESH',
          '${secondsLeft.toString().padLeft(2, '0')}s',
          color: secondsLeft <= 5 ? p.error : p.primary,
        ),
        const SizedBox(height: 4),
        Text(
          payload,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: p.textDim,
            fontFamily: 'monospace',
            fontSize: 9,
          ),
        ),
      ],
    );
  }
}

class _LocationPanel extends StatelessWidget {
  const _LocationPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final mesh = app.mesh;
    if (mesh.gpsFix) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HduReadout('LAT', '${mesh.gpsLatitude!.toStringAsFixed(5)}° N'),
          const SizedBox(height: 4),
          HduReadout('LONG', '${mesh.gpsLongitude!.toStringAsFixed(5)}° E'),
        ],
      );
    }
    final est = mesh.approxLatitude != null;
    if (est) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HduReadout(
            'LAT (APPROX)',
            '${mesh.approxLatitude!.toStringAsFixed(5)}° N',
          ),
          const SizedBox(height: 4),
          HduReadout(
            'LONG (APPROX)',
            '${mesh.approxLongitude!.toStringAsFixed(5)}° E',
          ),
          const SizedBox(height: 4),
          Text(
            'Estimate from ${peopleCount(mesh.approxSourceCount)} nearby '
            '(no GPS hardware). Radius ≈ ${mesh.approxRadiusKm!.toStringAsFixed(1)} km.',
            style: TextStyle(
              color: p.textDim,
              fontFamily: 'monospace',
              fontSize: 9,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HduReadout('POSITION', 'NO GPS HW FOUND'),
        const SizedBox(height: 4),
        Text(
          'LOOKING FOR NEARBY PEOPLE…\n'
          'Position will be estimated from mesh people once they are heard.',
          style: TextStyle(
            color: p.textDim,
            fontFamily: 'monospace',
            fontSize: 9,
          ),
        ),
      ],
    );
  }
}

class _MeshStatus extends StatelessWidget {
  const _MeshStatus({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final nodes = (app.mesh.nodes.values as Iterable<MeshNodeState>).toList();
    final ok = nodes.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(width: 10, height: 10, color: ok ? p.primary : p.error),
            const SizedBox(width: 8),
            Text(
              ok ? 'LINK OK' : 'SCANNING…',
              style: TextStyle(
                color: ok ? p.primary : p.error,
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            const Spacer(),
            Text(
              '${nodes.length} NODE${nodes.length == 1 ? '' : 'S'}',
              style: TextStyle(
                color: p.textDim,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        HduReadout(
          'SOS BEACONS',
          '${nodes.where((n) => n.hasSos).length} ACTIVE',
          color: nodes.where((n) => n.hasSos).isNotEmpty ? p.error : p.primary,
        ),
        const SizedBox(height: 6),
        HduReadout(
          'RADIO',
          '${app.mesh.adapter.name} :: ${app.mesh.adapter.status}',
          color: p.textDim,
        ),
      ],
    );
  }
}
