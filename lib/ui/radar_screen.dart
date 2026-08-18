/// Responder locator: AirTag-style radar for a live SOS target. When both
/// devices carry GPS you get a true bearing + range; with no own GPS fix the
/// screen degrades to an RSSI range estimate and says direction needs GPS.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/mesh/mesh_controller.dart';
import '../core/mesh/mesh_node.dart';
import 'hud_theme.dart';

class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key, required this.nodeId});

  final int nodeId;

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  StreamSubscription<CompassEvent>? _compassSub;
  double? _heading;
  bool _responding = false;

  @override
  void initState() {
    super.initState();
    // Compass needs a magnetometer; laptops return null and fall back to
    // north-up mode.
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      _compassSub = FlutterCompass.events?.listen((e) {
        if (!mounted || e.heading == null) return;
        setState(() => _heading = e.heading);
      });
    }
  }

  @override
  void dispose() {
    _compassSub?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final app = AppScope.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final mesh = app.mesh;
        final node = mesh.nodes[widget.nodeId];
        if (node == null) {
          return _targetLost(p);
        }
        final target = _TrackTarget(mesh: mesh, node: node);
        return Scaffold(
          backgroundColor: p.bg,
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(p, mesh, node, target),
                Expanded(
                  child: _RadarDial(
                    spin: _spin,
                    palette: p,
                    bearingDeg: target.bearingDeg,
                    distanceM: target.distanceM,
                    hasGps: target.hasGps,
                    heading: _heading,
                  ),
                ),
                _readouts(p, node, target, _heading),
                _actions(p, app, mesh, node),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _targetLost(AppPalette p) => Scaffold(
    backgroundColor: p.bg,
    body: Center(
      child: Text(
        'TARGET LOST — NO FRESH BEACON',
        style: TextStyle(color: p.error, fontFamily: 'monospace'),
      ),
    ),
  );

  Widget _header(AppPalette p, MeshController mesh, MeshNodeState node,
      _TrackTarget target) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            color: p.textDim,
            onPressed: () => Navigator.of(context).pop(),
          ),
          Text(
            'TRACK NODE ${node.nodeId.toRadixString(16).toUpperCase()}',
            style: TextStyle(
              color: p.primary,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const Spacer(),
          _RespondToggle(
            active: _responding,
            onChanged: (v) => setState(() => _responding = v),
            palette: p,
          ),
        ],
      ),
    );
  }

  Widget _readouts(
      AppPalette p, MeshNodeState node, _TrackTarget target, double? heading) {
    final alt = target.altDeltaM;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            target.distanceLabel,
            style: TextStyle(
              color: p.primary,
              fontFamily: 'monospace',
              fontSize: 42,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            target.hasGps
                ? 'BEARING ${target.bearingDeg!.round().toString().padLeft(3, '0')}° '
                    '${_cardinal(target.bearingDeg!)}'
                : 'DIRECTION NEEDS GPS ON THIS DEVICE',
            style: TextStyle(
              color: target.hasGps ? p.text : p.error,
              fontFamily: 'monospace',
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _chip(p, 'RSSI ${node.rssi} dBm'),
              _chip(p, 'HOP ${node.hopCount}'),
              if (alt != null)
                _chip(p, 'ALT ${alt.abs()} m ${alt < 0 ? 'BELOW' : 'ABOVE'}'),
            ],
          ),
          if (heading != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'HEADING ${heading.round().toString().padLeft(3, '0')}°',
                style: TextStyle(
                  color: p.textDim,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
          if (_responding)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'RESPONDING — SOS KEEPS BROADCASTING TO OTHERS',
                style: TextStyle(
                  color: p.error,
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(AppPalette p, String label) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: p.primaryDim),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: p.textDim,
            fontFamily: 'monospace',
            fontSize: 11,
          ),
        ),
      );

  Widget _actions(AppPalette p, AppState app, MeshController mesh,
      MeshNodeState node) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () {
                app.openSos(widget.nodeId.toRadixString(16));
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('VIEW ON MAP'),
              style: OutlinedButton.styleFrom(
                foregroundColor: p.primary,
                side: BorderSide(color: p.primaryDim),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Position tracking for one target node.
class _TrackTarget {
  _TrackTarget({required this.mesh, required this.node});

  final MeshController mesh;
  final MeshNodeState node;

  bool get _ownGps => mesh.gpsFix;
  bool get _targetGps => MeshController.validCoord(node.latitude, node.longitude);

  bool get hasGps => _ownGps && _targetGps;

  /// Bearing degrees clockwise from north (own → target), or null without
  /// both fixes.
  double? get bearingDeg {
    if (!hasGps) return null;
    final aLat = mesh.gpsLatitude!;
    final aLon = mesh.gpsLongitude!;
    final dLon = (node.longitude - aLon) * pi / 180;
    final y = sin(dLon) * cos(node.latitude * pi / 180);
    final x = cos(aLat * pi / 180) * sin(node.latitude * pi / 180) -
        sin(aLat * pi / 180) *
            cos(node.latitude * pi / 180) *
            cos(dLon);
    return (atan2(y, x) * 180 / pi + 360) % 360;
  }

  /// Range: haversine/equal-lat when both fixes exist (a few metres apart is
  /// noise, so below 5 m we trust the radio), otherwise an RSSI estimate.
  double? get distanceM {
    if (hasGps) {
      final gpsD = MeshController.kmBetween(
            mesh.gpsLatitude!,
            mesh.gpsLongitude!,
            node.latitude,
            node.longitude,
          ) *
          1000;
      if (gpsD > 5) return gpsD;
    }
    final dBm = node.rssi;
    // tx power unknown, assume -59 dBm @1m, path loss exponent 2.4.
    final est = pow(10, (-59 - dBm) / (10 * 2.4)).toDouble();
    return est.clamp(2.0, 5000.0);
  }

  String get distanceLabel {
    final d = distanceM;
    if (d == null) return 'NO RANGE';
    if (d < 1000) return '≈ ${d.round()} m';
    return '≈ ${(d / 1000).toStringAsFixed(1)} km';
  }

  /// How far vertically the target sits vs this device (m).
  double? get altDeltaM {
    if (!_ownGps || node.altitudeM == null) return null;
    return node.altitudeM! - (mesh.gpsAltitude ?? 0);
  }
}

String _cardinal(double deg) {
  const dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  return dirs[((deg + 22.5) % 360) ~/ 45];
}

/// Pulsing radar dial: concentric rings, rotating sweep, target blip at
/// (bearing − heading) so "up" always points where you face.
class _RadarDial extends StatelessWidget {
  const _RadarDial({
    required this.spin,
    required this.palette,
    required this.bearingDeg,
    required this.distanceM,
    required this.hasGps,
    required this.heading,
  });

  final AnimationController spin;
  final AppPalette palette;
  final double? bearingDeg;
  final double? distanceM;
  final bool hasGps;
  final double? heading;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: spin,
      builder: (context, _) => CustomPaint(
        painter: _RadarPainter(
          progress: spin.value,
          palette: palette,
          bearingDeg: bearingDeg,
          distanceM: distanceM,
          hasGps: hasGps,
          heading: heading,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.progress,
    required this.palette,
    required this.bearingDeg,
    required this.distanceM,
    required this.hasGps,
    required this.heading,
  });

  final double progress;
  final AppPalette palette;
  final double? bearingDeg;
  final double? distanceM;
  final bool hasGps;
  final double? heading;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = min(size.width, size.height) / 2 - 24;
    final center = Offset(cx, cy);

    // Concentric rings.
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(
        center,
        radius * i / 3,
        Paint()
          ..color = palette.grid
          ..style = PaintingStyle.stroke,
      );
    }

    // Rotating sweep line.
    final sweepAngle = progress * 2 * pi;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(sweepAngle);
    canvas.drawArc(
      Rect.fromCircle(center: Offset.zero, radius: radius),
      0,
      pi / 3,
      true,
      Paint()..color = palette.primary.withValues(alpha: 0.12),
    );
    canvas.drawLine(
      Offset.zero,
      Offset(0, -radius),
      Paint()..color = palette.primary.withValues(alpha: 0.5),
    );
    canvas.restore();

    if (!hasGps) {
      canvas.drawCircle(
        center,
        6,
        Paint()..color = palette.secondary,
      );
      return;
    }

    // You at the centre.
    canvas.drawCircle(center, 6, Paint()..color = palette.secondary);
    canvas.drawCircle(
      center,
      10,
      Paint()
        ..color = palette.secondary
        ..style = PaintingStyle.stroke,
    );

    // Target blip: bearing relative to heading (0 = north-up).
    final bearing = bearingDeg!;
    final h = heading ?? 0;
    final angle = (bearing - h) * pi / 180;
    final d = distanceM ?? 0;
    // Log-compressed range so 100 m and 2 km both fit on the dial.
    final r = radius * (1 - pow(0.5, d / 80).toDouble());
    final blip = center + Offset(sin(angle), -cos(angle)) * r;
    canvas.drawCircle(blip, 8, Paint()..color = palette.error);
    canvas.drawCircle(
      blip,
      14,
      Paint()
        ..color = palette.error.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke,
    );
    canvas.drawLine(center, blip, Paint()..color = palette.error.withValues(alpha: 0.4));
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.bearingDeg != bearingDeg ||
      oldDelegate.distanceM != distanceM ||
      oldDelegate.heading != heading ||
      oldDelegate.hasGps != hasGps ||
      oldDelegate.palette.error != palette.error;
}

class _RespondToggle extends StatelessWidget {
  const _RespondToggle({
    required this.active,
    required this.onChanged,
    required this.palette,
  });

  final bool active;
  final ValueChanged<bool> onChanged;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!active),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? palette.error : Colors.transparent,
          border: Border.all(
            color: active ? palette.error : palette.primaryDim,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          active ? 'RESPONDING' : 'RESPOND',
          style: TextStyle(
            color: active ? Colors.white : palette.primary,
            fontFamily: 'monospace',
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}