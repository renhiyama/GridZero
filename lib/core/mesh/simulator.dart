/// Synthetic mesh generator for the Command HQ (FR-4.2). Drives 20–50 virtual
/// nodes with moving coordinates, fluctuating RSSI and periodic triage
/// broadcasts so judge demos run without any BLE hardware.
library;

import 'dart:async';
import 'dart:math';

import '../mesh_packet.dart';
import 'mesh_adapter.dart';

class MeshSimulator {
  MeshSimulator(this.adapter, {this.nodeCount = 35});

  final MeshAdapter adapter;
  int nodeCount;

  final Random _rng = Random(42);
  Timer? _timer;
  int _seq = 0;

  final List<_VirtualNode> _nodes = [];

  static const _latBase = 19.00;
  static const _latSpan = 0.16;
  static const _lonBase = 72.80;
  static const _lonSpan = 0.16;

  void start() {
    _nodes.clear();
    for (var i = 0; i < nodeCount; i++) {
      _nodes.add(
        _VirtualNode(
          id: 0x1000 + i,
          lat: _latBase + _rng.nextDouble() * _latSpan,
          lon: _lonBase + _rng.nextDouble() * _lonSpan,
          dx:
              (0.0004 + _rng.nextDouble() * 0.0012) *
              (_rng.nextBool() ? 1 : -1),
          dy:
              (0.0004 + _rng.nextDouble() * 0.0012) *
              (_rng.nextBool() ? 1 : -1),
        ),
      );
    }
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 900), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    for (final node in _nodes) {
      node.lat = (node.lat + node.dy).clamp(_latBase, _latBase + _latSpan);
      node.lon = (node.lon + node.dx).clamp(_lonBase, _lonBase + _lonSpan);
      if (node.lat >= _latBase + _latSpan || node.lat <= _latBase) {
        node.dy = -node.dy;
      }
      if (node.lon >= _lonBase + _lonSpan || node.lon <= _lonBase) {
        node.dx = -node.dx;
      }

      _seq = (_seq + 1) & 0xffff;
      final isSos = _rng.nextDouble() < 0.28;
      final packet = MeshPacket(
        type: isSos ? MeshPacketType.sosBeacon : MeshPacketType.relayStatus,
        senderId: node.id,
        latitude: node.lat,
        longitude: node.lon,
        triage: TriageFlags(
          medical: _rng.nextDouble() < 0.4,
          trapped: _rng.nextDouble() < 0.3,
          water: _rng.nextDouble() < 0.5,
          food: _rng.nextDouble() < 0.6,
          severity: 1 + _rng.nextInt(maxSeverity),
        ),
        seq: _seq,
        initialTtl: 2 + _rng.nextInt(3),
      );
      adapter.injectRemote(packet);
    }
  }
}

class _VirtualNode {
  _VirtualNode({
    required this.id,
    required this.lat,
    required this.lon,
    required this.dx,
    required this.dy,
  });

  final int id;
  double lat;
  double lon;
  double dx;
  double dy;
}
