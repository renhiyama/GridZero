/// Persona C: Disaster Command HQ (FEAT-DASH-01 / FR-4). Live aggregate mesh
/// telemetry, field map, triage heatmap, supply logs and the air-gapped
/// enlistment QR that signs officers into the mesh.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_scope.dart';
import '../core/ledger/ledger_store.dart';
import '../core/master_key.dart';
import '../core/mesh/mesh_node.dart';
import 'hud_theme.dart';
import 'mesh_map.dart';

class HqScreen extends StatefulWidget {
  const HqScreen({super.key});

  @override
  State<HqScreen> createState() => _HqScreenState();
}

class _HqScreenState extends State<HqScreen> {
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Text(
                  '▚▞ COMMAND HQ',
                  style: TextStyle(
                    color: p.primary,
                    fontFamily: 'monospace',
                    fontSize: 16,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: p.primary),
                    color: p.primary.withValues(alpha: 0.12),
                  ),
                  child: Text(
                    'LIVE MESH',
                    style: TextStyle(
                      color: p.primary,
                      fontFamily: 'monospace',
                      fontSize: 11,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth > 900;
                final telemetry = _TelemetryPanel(app: app);
                final fieldMap = _FieldMapPanel(app: app);
                final enlistQr = _EnlistmentPanel();
                final heatmap = _HeatmapPanel(
                  nodes: app.mesh.nodes.values.toList(),
                  palette: AppPalette.of(context),
                );
                final logs = _LogsPanel(app: app);

                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.all(12),
                          children: [
                            telemetry,
                            const SizedBox(height: 12),
                            fieldMap,
                            const SizedBox(height: 12),
                            heatmap,
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.all(12),
                          children: [
                            enlistQr,
                            const SizedBox(height: 12),
                            logs,
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    telemetry,
                    const SizedBox(height: 12),
                    enlistQr,
                    const SizedBox(height: 12),
                    fieldMap,
                    const SizedBox(height: 12),
                    heatmap,
                    const SizedBox(height: 12),
                    logs,
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TelemetryPanel extends StatelessWidget {
  const _TelemetryPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final nodes = (app.mesh.nodes.values as Iterable<MeshNodeState>).toList();
    final sosCount = nodes.where((MeshNodeState n) => n.hasSos).length;
    return HudPanel(
      title: 'AGGREGATE MESH HEALTH',
      child: FutureBuilder<int>(
        future: app.ledger.recordsCount(),
        builder: (context, snapshot) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HduReadout('FRAMES RX', '${app.mesh.framesSeen}'),
            HduReadout('FRAMES RELAYED', '${app.mesh.framesRelayed}'),
            HduReadout('PEOPLE IN MESH', '${nodes.length}'),
            HduReadout(
              'ACTIVE SOS BEACONS',
              '$sosCount',
              color: sosCount > 0 ? p.error : p.primary,
            ),
            HduReadout('RATIONS ALLOCATED', '${app.claimCount}'),
            HduReadout('LEDGER RECORDS', '${snapshot.data ?? '…'}'),
            HduReadout(
              'MAX HOP SEEN',
              '${nodes.fold<int>(0, (int m, MeshNodeState n) => n.hopCount > m ? n.hopCount : m)}',
            ),
          ],
        ),
      ),
    );
  }
}

/// Live map of the field (same view as an officer's MAP tab).
class _FieldMapPanel extends StatelessWidget {
  const _FieldMapPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    return HudPanel(
      title: 'FIELD MAP',
      child: SizedBox(height: 320, child: MeshMap(mesh: app.mesh)),
    );
  }
}

/// Air-gapped handoff: an officer scans this QR to enlist (FR-2.3).
class _EnlistmentPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return HudPanel(
      title: 'ENLISTMENT QR',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.white,
              child: QrImageView(
                data: kSampleMasterKeyPayload,
                version: QrVersions.auto,
                size: 150,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const HduReadout(
            'HOW',
            'Officer app ▸ OFFICER ▸ SCAN MASTER KEY QR pointed at this code.',
          ),
        ],
      ),
    );
  }
}

class _HeatmapPanel extends StatelessWidget {
  const _HeatmapPanel({required this.nodes, required this.palette});

  final List<MeshNodeState> nodes;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return HudPanel(
      title: 'TRIAGE HEATMAP',
      child: SizedBox(
        height: 220,
        child: CustomPaint(
          painter: _HeatmapPainter(nodes: nodes, palette: palette),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({required this.nodes, required this.palette});

  final List<MeshNodeState> nodes;
  final AppPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    const cols = 8;
    const rows = 6;
    final cellW = size.width / cols;
    final cellH = size.height / rows;

    for (var c = 0; c < cols; c++) {
      for (var r = 0; r < rows; r++) {
        final cell = Rect.fromLTWH(c * cellW, r * cellH, cellW, cellH);
        final cx = cell.center.dx;
        final cy = cell.center.dy;
        double heat = 0;
        for (final n in nodes) {
          // Skip peers without a fix (0,0 sentinel) so they add no heat.
          if (n.latitude.abs() < 1e-6 && n.longitude.abs() < 1e-6) continue;
          final nx = (n.longitude - 72.75) / 0.3 * size.width;
          final ny = (19.20 - n.latitude) / 0.35 * size.height;
          final d = (Offset(nx, ny) - Offset(cx, cy)).distance;
          if (d < 40) heat += n.hasSos ? n.severity * 2.2 : 0.6;
        }
        final alpha = (heat.clamp(0, 6) / 6).toDouble();
        canvas.drawRect(
          cell,
          Paint()..color = Color.lerp(palette.panel, palette.error, alpha)!,
        );
        canvas.drawRect(
          cell,
          Paint()
            ..color = palette.grid
            ..style = PaintingStyle.stroke,
        );
      }
    }

    final tp = TextPainter(
      text: TextSpan(
        text: 'SOS DENSITY / SECTOR GRID',
        style: TextStyle(
          color: palette.textDim,
          fontFamily: 'monospace',
          fontSize: 10,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(8, size.height - tp.height - 6));
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter oldDelegate) =>
      oldDelegate.nodes.length != nodes.length ||
      oldDelegate.palette.error != palette.error;
}

class _LogsPanel extends StatelessWidget {
  const _LogsPanel({required this.app});

  final dynamic app;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return FutureBuilder<List<LedgerRecord>>(
      future: app.ledger.allRecords(),
      builder: (context, snapshot) {
        final records = snapshot.data ?? const <LedgerRecord>[];
        return HudPanel(
          title: 'SUPPLY ALLOCATION LOG',
          child: records.isEmpty
              ? const HduReadout('LOG', 'no allocations yet')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final r in records.take(30))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '[${r.claimedAt}] ${r.citizenId} → '
                          '${r.rationCode} by ${r.officerId} '
                          '·${r.currentHash.substring(0, 8)}',
                          style: TextStyle(
                            color: p.text,
                            fontFamily: 'monospace',
                            fontSize: 10,
                          ),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}
