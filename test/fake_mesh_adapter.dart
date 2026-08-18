import 'dart:async';

import 'package:aapadsetu/core/mesh/mesh_adapter.dart';
import 'package:aapadsetu/core/mesh_packet.dart';

/// Test-only transport: an empty radio that echoes own broadcasts back like
/// an instant loopback. Nothing is generated, nothing leaks — tests feed
/// remote packets in explicitly via [injectRemote]. Not simulation: the app
/// never ships or reaches this adapter.
class FakeMeshAdapter implements MeshAdapter {
  final _rx = StreamController<MeshRxPacket>.broadcast();

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
  Future<void> broadcast(MeshPacket packet) async {
    _rx.add(MeshRxPacket(packet: packet));
  }

  @override
  Future<String> ensurePermissions() async => 'test';

  @override
  Future<void> injectRemote(MeshPacket packet) async {
    _rx.add(MeshRxPacket(packet: packet));
  }
}
