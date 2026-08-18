/// Persona B: Field Relief Officer. QR verification, hash-chain ledger and
/// tactical map HUD.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/ledger/ledger_store.dart';
import '../core/master_key.dart';
import '../core/mesh/mesh_node.dart';
import 'hud_theme.dart';

class OfficerScreen extends StatefulWidget {
  const OfficerScreen({super.key});

  @override
  State<OfficerScreen> createState() => _OfficerScreenState();
}

class _OfficerScreenState extends State<OfficerScreen> {
  ClaimResult? _lastClaim;
  final bool _cameraUsable = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return SafeArea(
      child: app.officerId == null
          ? _EnlistGate(app: app, cameraUsable: _cameraUsable)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          border: Border.all(color: HudColors.primary),
                          color: HudColors.primary.withValues(alpha: 0.12),
                        ),
                        child: Text(
                          'OFFICER ▸ ${app.officerId}',
                          style: const TextStyle(
                            color: HudColors.primary,
                            fontFamily: 'monospace',
                            fontSize: 12,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () =>
                            app.switchRole(Role.citizen),
                        icon: const Icon(Icons.logout,
                            color: HudColors.textDim, size: 18),
                        tooltip: 'Return to citizen mode',
                      ),
                    ],
                  ),
                ),
                const TabBar(tabs: [
                  Tab(text: 'SCAN'),
                  Tab(text: 'LEDGER'),
                  Tab(text: 'MAP'),
                ]),
                Expanded(
                  child: TabBarView(
                    children: [
                      _ScanTab(
                        app: app,
                        cameraUsable: _cameraUsable,
                        onResult: (r) => setState(() => _lastClaim = r),
                      ),
                      _LedgerTab(app: app),
                      _MapTab(app: app),
                    ],
                  ),
                ),
                if (_lastClaim != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: HudAlertBar(
                      _claimText(_lastClaim!),
                      color: _lastClaim!.ok
                          ? HudColors.primary
                          : HudColors.alert,
                    ),
                  ),
              ],
            ),
    );
  }

  String _claimText(ClaimResult r) =>
      '${r.status.name.toUpperCase()}: ${r.message}';
}

class _EnlistGate extends StatelessWidget {
  const _EnlistGate({required this.app, required this.cameraUsable});

  final dynamic app;
  final bool cameraUsable;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        HudPanel(
          title: 'OFFICER ENLISTMENT / AIR-GAPPED',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const HduReadout(
                'REQ',
                'Scan Master Key QR signed by HQ. No internet required.',
              ),
              const SizedBox(height: 12),
              if (cameraUsable) ...[
                _EnlistScanButton(app: app),
                const SizedBox(height: 12),
              ],
              const HduReadout('MANUAL ENTRY', 'Paste signed payload below'),
              const SizedBox(height: 6),
              _EnlistManualField(app: app),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  final check =
                      await app.enlistOfficer(kSampleMasterKeyPayload);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    backgroundColor: check.ok
                        ? HudColors.primary
                        : HudColors.alert,
                    content: Text(check.ok
                        ? 'OFFICER ENLISTED: ${check.masterKey!.officerId}'
                        : check.message),
                  ));
                },
                child: const Text('USE DEMO MASTER KEY',
                    style: TextStyle(
                        fontFamily: 'monospace', letterSpacing: 1)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EnlistScanButton extends StatelessWidget {
  const _EnlistScanButton({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () async {
        final payload = await Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => const _QrScanPage(label: 'MASTER KEY')),
        );
        if (payload == null || !context.mounted) return;
        final check = await app.enlistOfficer(payload);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: check.ok ? HudColors.primary : HudColors.alert,
          content: Text(check.ok ? 'OFFICER ENLISTED' : check.message),
        ));
      },
      icon: const Icon(Icons.qr_code_scanner),
      label: const Text('SCAN MASTER KEY QR',
          style: TextStyle(fontFamily: 'monospace')),
    );
  }
}

class _EnlistManualField extends StatefulWidget {
  const _EnlistManualField({required this.app});

  final dynamic app;

  @override
  State<_EnlistManualField> createState() => _EnlistManualFieldState();
}

class _EnlistManualFieldState extends State<_EnlistManualField> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            decoration: const InputDecoration(hintText: '{"v":1,...}'),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: () async {
            if (_ctrl.text.trim().isEmpty) return;
            final check = await widget.app.enlistOfficer(_ctrl.text.trim());
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              backgroundColor: check.ok ? HudColors.primary : HudColors.alert,
              content: Text(check.message.isEmpty
                  ? 'OFFICER ENLISTED'
                  : check.message),
            ));
          },
          child: const Text('ENLIST'),
        ),
      ],
    );
  }
}

/// Camera scan page returning the first decoded QR payload.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage({required this.label});

  final String label;

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.label)),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          final raw = capture.barcodes
              .map((b) => b.rawValue)
              .whereType<String>()
              .firstOrNull;
          if (raw != null) {
            _done = true;
            Navigator.of(context).pop(raw);
          }
        },
      ),
    );
  }
}

class _ScanTab extends StatefulWidget {
  const _ScanTab({
    required this.app,
    required this.cameraUsable,
    required this.onResult,
  });

  final dynamic app;
  final bool cameraUsable;
  final ValueChanged<ClaimResult> onResult;

  @override
  State<_ScanTab> createState() => _ScanTabState();
}

class _ScanTabState extends State<_ScanTab> {
  final _ctrl = TextEditingController();
  String _rationCode = 'Rice';

  static const _items = ['Rice', 'Water', 'Blanket', 'Medicine', 'Fuel'];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<ClaimResult> _claim(String payload) =>
      widget.app.claimFromPayload(payload, _rationCode);

  void _showClaimResult(ClaimResult result) {
    widget.onResult(result);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: result.ok ? HudColors.primary : HudColors.alert,
      content: Text(result.ok
          ? 'GRANTED: ${result.record!.citizenId} / ${result.record!.rationCode}'
          : result.message),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Text('RATION ITEM',
                style: TextStyle(color: HudColors.textDim, fontFamily: 'monospace')),
            const Spacer(),
            DropdownButton<String>(
              value: _rationCode,
              dropdownColor: HudColors.panel,
              style: const TextStyle(
                  color: HudColors.primary, fontFamily: 'monospace'),
              items: _items
                  .map((i) => DropdownMenuItem(value: i, child: Text(i)))
                  .toList(),
              onChanged: (v) => setState(() => _rationCode = v ?? 'Rice'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (widget.cameraUsable) ...[
          FilledButton.icon(
            onPressed: () async {
              final payload = await Navigator.of(context).push<String>(
                MaterialPageRoute(builder: (_) => const _QrScanPage(label: 'CITIZEN CLAIM QR')),
              );
              if (payload == null) return;
              _showClaimResult(await _claim(payload));
            },
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('SCAN CITIZEN DYNAMIC QR',
                style: TextStyle(fontFamily: 'monospace')),
          ),
          const SizedBox(height: 12),
          const HduReadout('OR', 'manual claim payload entry'),
          const SizedBox(height: 6),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                decoration: const InputDecoration(hintText: '{"v":1,"c":"CIT-..","w":..,"tok":".."}'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () async {
                if (_ctrl.text.trim().isNotEmpty) {
                  _showClaimResult(await _claim(_ctrl.text.trim()));
                }
              },
              child: const Text('CLAIM'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        HduReadout('VERIFY PATH',
            'TOTP-HMAC-SHA256 30s window ▸ daily-duplicate rejection ▸ append-only chain'),
      ],
    );
  }
}

class _LedgerTab extends StatelessWidget {
  const _LedgerTab({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<LedgerRecord>>(
      future: app.ledger.allRecords(),
      builder: (context, snapshot) {
        final records = snapshot.data ?? const <LedgerRecord>[];
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            HduReadout('RECORDS', '${records.length}'),
            HduReadout('CHAIN TAIL',
                records.isEmpty
                    ? 'GENESIS'
                    : records.first.currentHash.substring(0, 16)),
            const SizedBox(height: 8),
            for (final r in records.take(40))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${r.claimedAt} ${r.citizenId} ${r.rationCode} '
                  'by ${r.officerId} [${r.currentHash.substring(0, 8)}]',
                  style: const TextStyle(
                    color: HudColors.text,
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MapTab extends StatelessWidget {
  const _MapTab({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _TacticalMapPainter(
              ownNodeId: app.mesh.nodeId,
              nodes: app.mesh.nodes.values.toList(),
            ),
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: HduReadout(
              'NODES', '${app.mesh.nodes.length}', color: HudColors.amber),
        ),
      ],
    );
  }
}

class _TacticalMapPainter extends CustomPainter {
  _TacticalMapPainter({required this.ownNodeId, required this.nodes});

  final int ownNodeId;
  final List<MeshNodeState> nodes;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = HudColors.grid
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const step = 36.0;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Normalize node positions into the canvas via a simple local projection.
    if (nodes.isNotEmpty) {
      final lats = [0.0, ...nodes.map((n) => n.latitude)];
      final lons = [0.0, ...nodes.map((n) => n.longitude)];
      final minLat = lats.reduce((a, b) => a < b ? a : b);
      final maxLat = lats.reduce((a, b) => a > b ? a : b);
      final minLon = lons.reduce((a, b) => a < b ? a : b);
      final maxLon = lons.reduce((a, b) => a > b ? a : b);
      final latSpan = (maxLat - minLat).abs().clamp(1e-6, double.infinity);
      final lonSpan = (maxLon - minLon).abs().clamp(1e-6, double.infinity);

      for (final node in nodes) {
        final x = (node.longitude - minLon) / lonSpan * (size.width - 24) + 12;
        final y = (size.height - 24) -
            (node.latitude - minLat) / latSpan * (size.height - 24) +
            12;
        final isSelf = node.nodeId == ownNodeId;
        final color = isSelf
            ? HudColors.primary
            : node.hasSos
                ? HudColors.alert
                : HudColors.cyan;
        final r = isSelf ? 8.0 : 5.0;

        canvas.drawCircle(Offset(x, y), r, Paint()..color = color);
        if (node.hasSos || isSelf) {
          canvas.drawCircle(
            Offset(x, y),
            r + 6,
            Paint()
              ..color = color.withValues(alpha: 0.15)
              ..style = PaintingStyle.fill,
          );
          canvas.drawCircle(
            Offset(x, y),
            r + 10,
            Paint()
              ..color = color.withValues(alpha: 0.35)
              ..style = PaintingStyle.stroke,
          );
        }
        canvas.drawCircle(
          Offset(x, y),
          r + 2,
          Paint()
            ..color = HudColors.bg
            ..style = PaintingStyle.stroke,
        );
      }
    } else {
      final tp = TextPainter(
        text: const TextSpan(
          text: 'AWAITING MESH BEACONS',
          style: TextStyle(color: HudColors.textDim, fontFamily: 'monospace', fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((size.width - tp.width) / 2, size.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _TacticalMapPainter oldDelegate) =>
      oldDelegate.nodes.length != nodes.length ||
      oldDelegate.ownNodeId != ownNodeId;
}