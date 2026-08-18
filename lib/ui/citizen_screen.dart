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
    final secondsLeft =
        totpWindowSeconds - (DateTime.now().millisecondsSinceEpoch ~/ 1000) % totpWindowSeconds;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(app: app),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                HudPanel(
                  title: 'SOS BROADCAST',
                  borderColor: app.sosActive
                      ? HudColors.alert
                      : HudColors.primaryDim,
                  child: _SosPanel(app: app),
                ),
                const SizedBox(height: 12),
                HudPanel(
                  title: 'DYNAMIC RATION QR  /  TOKEN ROTATES ${secondsLeft}s',
                  child: _DynamicQr(app: app, secondsLeft: secondsLeft),
                ),
                const SizedBox(height: 12),
                HudPanel(title: 'MESH UPLINK', child: _MeshStatus(app: app)),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: HudColors.primary),
              color: HudColors.primary.withValues(alpha: 0.12),
            ),
            child: Text(
              'CITIZEN ▸ ${app.citizenId}',
              style: const TextStyle(
                color: HudColors.primary,
                fontFamily: 'monospace',
                fontSize: 12,
                letterSpacing: 1,
              ),
            ),
          ),
          const Spacer(),
          Text(
            'NODE ${app.mesh.nodeId.toRadixString(16).padLeft(4, '0').toUpperCase()}',
            style: const TextStyle(
              color: HudColors.textDim,
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
    final flags = app.sosFlags;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('SEVERITY', style: _dim()),
            const Spacer(),
            for (var s = 1; s <= 5; s++)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: InkWell(
                  onTap: () => app.setSosFlags(TriageFlags(
                    severity: s,
                    medical: flags.medical,
                    trapped: flags.trapped,
                    water: flags.water,
                    food: flags.food,
                  )),
                  child: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: s <= flags.severity
                            ? HudColors.alert
                            : HudColors.textDim,
                      ),
                      color: s <= flags.severity
                          ? HudColors.alert.withValues(alpha: 0.15)
                          : null,
                    ),
                    child: Text(
                      '$s',
                      style: TextStyle(
                        color: s <= flags.severity
                            ? HudColors.alert
                            : HudColors.textDim,
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
                    onTap: () => app.setSosFlags(TriageFlags(
                      severity: flags.severity,
                      medical: need.$2 == 'medical'
                          ? !flags.medical
                          : flags.medical,
                      trapped: need.$2 == 'trapped'
                          ? !flags.trapped
                          : flags.trapped,
                      water: need.$2 == 'water' ? !flags.water : flags.water,
                      food: need.$2 == 'food' ? !flags.food : flags.food,
                    )),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: app.sosActive ? HudColors.alert : HudColors.primary,
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
        HduReadout('PACKET', '18B TTL5 TYPE=0x01 TRIAGE=${flags.value.toString().padLeft(2, '0')}'),
        if (app.sosActive)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: HudAlertBar('SOS ACTIVE — broadcasting every 30s via mesh'),
          ),
      ],
    );
  }

  TextStyle _dim() => const TextStyle(
        color: HudColors.textDim,
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
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(
            color: on ? HudColors.amber : HudColors.textDim,
            width: 1,
          ),
          color: on ? HudColors.amber.withValues(alpha: 0.14) : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: on ? HudColors.amber : HudColors.textDim,
            fontFamily: 'monospace',
            fontSize: 11,
            fontWeight: on ? FontWeight.bold : FontWeight.normal,
          ),
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
          color: secondsLeft <= 5 ? HudColors.alert : HudColors.primary,
        ),
        const SizedBox(height: 4),
        Text(
          payload,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: HudColors.textDim,
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
    final sosCount = app.mesh.nodes.values
        .where((MeshNodeState n) => n.hasSos)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HduReadout('ADAPTER', '${app.mesh.adapter.name} / ${app.useSimulator ? 'SIMULATED' : 'NATIVE'}'),
        HduReadout('FRAMES RX', '${app.mesh.framesSeen}'),
        HduReadout('FRAMES RELAYED', '${app.mesh.framesRelayed}'),
        HduReadout('KNOWN NODES', '${app.mesh.nodes.length}'),
        HduReadout('ACTIVE SOS', '$sosCount', color: sosCount > 0 ? HudColors.alert : HudColors.primary),
      ],
    );
  }
}