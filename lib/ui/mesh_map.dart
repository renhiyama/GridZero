/// Reusable OpenStreetMap view of the mesh: device markers, GPS/estimate
/// status badge and an offline grid fallback. Used by the officer MAP tab
/// and the Command HQ field map.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/mesh/mesh_controller.dart';
import 'hud_theme.dart';

class MeshMap extends StatefulWidget {
  const MeshMap({super.key, required this.mesh});

  final MeshController mesh;

  @override
  State<MeshMap> createState() => _MeshMapState();
}

class _MeshMapState extends State<MeshMap> {
  final _mapController = MapController();
  Timer? _ticker;
  LatLng _lastCenter = const LatLng(0, 0);

  static const _fallbackCenter = LatLng(20.5937, 78.9629);

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      final center = _center;
      if (MeshController.kmBetween(
            center.latitude,
            center.longitude,
            _lastCenter.latitude,
            _lastCenter.longitude,
          ) >
          0.2) {
        _lastCenter = center;
        _mapController.move(center, 15);
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  LatLng get _center {
    final m = widget.mesh;
    return m.approxLatitude != null
        ? LatLng(m.approxLatitude!, m.approxLongitude!)
        : _fallbackCenter;
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final m = widget.mesh;
    final nodes = m.nodes.values.toList();
    final estimated = m.approxLatitude != null;
    final center = _center;
    if (_lastCenter == const LatLng(0, 0)) _lastCenter = center;

    return Stack(
      children: [
        Positioned.fill(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 15,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              // Offline fallback: grid shows through failed/blank tiles.
              CustomPaint(
                painter: _GridPainter(grid: p.grid, textDim: p.textDim),
              ),
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'org.aapadsetu.aapadsetu',
              ),
              MarkerLayer(
                markers: [
                  for (final n in nodes)
                    if (MeshController.validCoord(n.latitude, n.longitude))
                      Marker(
                        point: LatLng(n.latitude, n.longitude),
                        width: 14,
                        height: 14,
                        child: _MapDot(
                          color: n.nodeId == m.nodeId
                              ? p.primary
                              : n.hasSos
                              ? p.error
                              : p.secondary,
                          self: n.nodeId == m.nodeId,
                          sos: n.hasSos,
                        ),
                      ),
                ],
              ),
              const RichAttributionWidget(
                attributions: [TextSourceAttribution('OpenStreetMap')],
              ),
            ],
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: HduReadout('PEOPLE', '${nodes.length}', color: p.secondary),
        ),
        Positioned(
          left: 8,
          top: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: estimated ? p.secondary : p.error),
              color: p.bg.withValues(alpha: 0.8),
            ),
            child: Text(
              estimated
                  ? 'ESTIMATED POSITION (${peopleCount(m.approxSourceCount)} · '
                        '≈${m.approxRadiusKm!.toStringAsFixed(1)} km)'
                  : 'NO GPS HW FOUND — LOOKING FOR PEOPLE',
              style: TextStyle(
                color: estimated ? p.secondary : p.error,
                fontFamily: 'monospace',
                fontSize: 9,
                letterSpacing: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MapDot extends StatelessWidget {
  const _MapDot({required this.color, required this.self, required this.sos});

  final Color color;
  final bool self;
  final bool sos;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: self ? 12 : 8,
        height: self ? 12 : 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: sos
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.6),
                    blurRadius: 10,
                    spreadRadius: 4,
                  ),
                ]
              : null,
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.grid, required this.textDim});

  final Color grid;
  final Color textDim;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = grid
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const step = 36.0;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    final tp = TextPainter(
      text: TextSpan(
        text: 'OFFLINE — AWAITING TILE MAP',
        style: TextStyle(color: textDim, fontFamily: 'monospace', fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, size.height / 2));
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.grid != grid;
}
