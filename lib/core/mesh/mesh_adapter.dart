/// Mesh transport abstraction. Native adapters ride on real BLE; the
/// simulated adapter powers desktop/web demos without radio hardware.
library;

import '../mesh_packet.dart';

class MeshRxPacket {
  MeshRxPacket({required this.packet, this.rssi = -70});

  final MeshPacket packet;
  final int rssi;
}

abstract class MeshAdapter {
  /// Human-readable transport label for the HUD.
  String get name;

  /// True when packets are generated locally (no radio involved).
  bool get isSimulated;

  Stream<MeshRxPacket> get onPacket;

  Future<void> start();

  Future<void> stop();

  Future<void> broadcast(MeshPacket packet);

  /// Injects a packet from a remote node (simulator / desktop demo only).
  Future<void> injectRemote(MeshPacket packet) async {
    throw UnsupportedError('injectRemote not supported on this adapter');
  }
}
