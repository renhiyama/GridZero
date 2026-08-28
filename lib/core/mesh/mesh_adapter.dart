/// Mesh transport abstraction. Native adapters ride on real BLE: phones use
/// flutter_blue_plus + ble_peripheral_plus, Linux desktops use BlueZ via
/// system D-Bus. There is no simulated transport.
library;

import '../mesh_packet.dart';

class MeshRxPacket {
  MeshRxPacket({required this.packet, this.rssi = -70});

  final MeshPacket packet;
  final int rssi;
  bool get wasEncrypted => packet.wasEncrypted;
}

abstract class MeshAdapter {
  /// Human-readable transport label for the HUD.
  /// Forces near-continuous scanning for a short period so multi-frame
  /// broadcasts (chat, landmarks) are actually heard by sleepy receivers.
  void boostScan();

    String get name;

  /// One-line runtime health / permission status for the HUD.
  String get status;

  /// Live radio-governor state for the HUD diagnostics readout (tier, scan
  /// sleep, leases). Empty on transports with no duty-cycle knob.
  Map<String, String> get diagnostics => const {};

  Stream<MeshRxPacket> get onPacket;

  Future<void> start();

  Future<void> stop();

  /// Sends a frame onto the mesh. [persistent] frames (relay-status announces
  /// carrying coordinates, SOS beacons) take the advertisement slot as the
  /// sticky frame: after a burst of ordinary frames rotates through, the radio
  /// returns to the latest persistent frame so a peer's scan window nearly
  /// always catches this node's live position instead of a one-shot frame.
  Future<void> broadcast(MeshPacket packet, {bool persistent = false});

  /// Requests runtime OS permissions needed by this transport.
  Future<String> ensurePermissions() async => status;

  /// Radio-governor hints (deterministic state machine, no ML). The controller
  /// tells the transport how urgent the local situation is so it can trade
  /// scan duty for latency exactly when it matters and bank battery the rest
  /// of the time. [active] marks a live signed-in session vs anonymous/standby.
  Future<void> setRadioAlert(bool active) async {}

  Future<void> setRadioActive(bool active) async {}

  /// Injects a packet from a remote node (test harnesses only).
  Future<void> injectRemote(MeshPacket packet) async {
    throw UnsupportedError('injectRemote not supported on this adapter');
  }
}
