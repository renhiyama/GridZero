/// Simulated mesh transport. Broadcasts echo back as if received from a peer
/// with randomized RSSI, and `injectRemote` lets the HQ simulator or desktop
/// demo drive synthetic multi-hop traffic with zero radio hardware.
library;

import 'dart:async';
import 'dart:math';

import '../mesh_packet.dart';
import 'mesh_adapter.dart';

class SimulatedMeshAdapter implements MeshAdapter {
  SimulatedMeshAdapter({int seed = 1}) : _rng = Random(seed);

  final Random _rng;
  final _rx = StreamController<MeshRxPacket>.broadcast();

  @override
  String get name => 'SIM';

  @override
  String get status => 'simulated transport — no radio, no permissions';

  @override
  bool get isSimulated => true;

  @override
  Future<String> ensurePermissions() async => status;

  @override
  Stream<MeshRxPacket> get onPacket => _rx.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    await _rx.close();
  }

  @override
  Future<void> broadcast(MeshPacket packet) async {
    _emit(packet, jitter: 0);
  }

  @override
  Future<void> injectRemote(MeshPacket packet) async {
    _emit(packet, jitter: 12);
  }

  void _emit(MeshPacket packet, {required int jitter}) {
    final rssi = -40 - _rng.nextInt(50 + jitter);
    scheduleMicrotask(() {
      if (!_rx.isClosed) {
        _rx.add(MeshRxPacket(packet: packet, rssi: rssi));
      }
    });
  }
}
