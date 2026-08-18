/// Mesh transport abstraction. Native adapters ride on real BLE: phones use
/// flutter_blue_plus + ble_peripheral_plus, Linux desktops use BlueZ via
/// system D-Bus. There is no simulated transport.
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

  /// One-line runtime health / permission status for the HUD.
  String get status;

  Stream<MeshRxPacket> get onPacket;

  Future<void> start();

  Future<void> stop();

  Future<void> broadcast(MeshPacket packet);

  /// Requests runtime OS permissions needed by this transport.
  Future<String> ensurePermissions() async => status;

  /// Injects a packet from a remote node (test harnesses only).
  Future<void> injectRemote(MeshPacket packet) async {
    throw UnsupportedError('injectRemote not supported on this adapter');
  }
}
