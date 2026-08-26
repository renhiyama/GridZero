import 'dart:async';

import 'package:gridzero/core/mesh/mesh_adapter.dart';
import 'package:gridzero/core/mesh_packet.dart';

/// Test-only transport: an empty radio that echoes own broadcasts back like
/// an instant loopback. Nothing is generated, nothing leaks: tests feed
/// remote packets in explicitly via [injectRemote]. Not simulation: the app
/// never ships or reaches this adapter.
class FakeMeshAdapter implements MeshAdapter {
  final _rx = StreamController<MeshRxPacket>.broadcast();

  /// Every packet handed to [broadcast], for asserting relay behaviour.
  final List<MeshPacket> broadcasted = [];

  /// Persistent flag paired with [broadcasted] so tests can assert which
  /// frames take the long-dwell advertisement slot (SOS relays must).
  final List<bool> broadcastPersistent = [];

  bool radioAlert = false;
  bool radioActive = true;

  @override
  Map<String, String> get diagnostics => const {
    'tier': 'FAKE',
    'scanSleep': '0ms (test)',
  };

  @override
  @override
  void boostScan() {}

  @override
  String get name => 'FAKE';

  @override
  String get status => 'test';

  @override
  Stream<MeshRxPacket> get onPacket => _rx.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> broadcast(MeshPacket packet, {bool persistent = false}) async {
    broadcasted.add(packet);
    broadcastPersistent.add(persistent);
    _rx.add(MeshRxPacket(packet: packet));
  }

  @override
  Future<void> setRadioAlert(bool active) async => radioAlert = active;

  @override
  Future<void> setRadioActive(bool active) async => radioActive = active;

  @override
  Future<String> ensurePermissions() async => 'test';

  @override
  Future<void> injectRemote(MeshPacket packet) async {
    _rx.add(MeshRxPacket(packet: packet));
  }
}
