import 'package:aapadsetu/core/mesh/mesh_controller.dart';
import 'package:aapadsetu/core/mesh/simulated_mesh.dart';
import 'package:aapadsetu/core/mesh_packet.dart';
import 'package:flutter_test/flutter_test.dart';

MeshPacket foreignPacket({int seq = 1, int ttl = 3, int hop = 0}) => MeshPacket(
      type: MeshPacketType.sosBeacon,
      senderId: 0x5555,
      latitude: 19.0,
      longitude: 72.8,
      triage: TriageFlags(severity: 4, trapped: true),
      seq: seq,
      initialTtl: ttl,
      hopCount: hop,
    );

void main() {
  test('own broadcast registers own node state', () async {
    final adapter = SimulatedMeshAdapter();
    final ctrl = MeshController(
      nodeId: 0x1111,
      startLatitude: 19.0,
      startLongitude: 72.8,
      adapter: adapter,
    );
    await ctrl.start();
    await ctrl.broadcastSos(triage: TriageFlags(severity: 2));

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ctrl.nodes.containsKey(0x1111), isTrue);
    expect(ctrl.nodes[0x1111]!.hasSos, isTrue);
    await ctrl.stop();
  });

  test('duplicate frames are deduplicated (FR-1.4)', () async {
    final adapter = SimulatedMeshAdapter();
    final ctrl = MeshController(
      nodeId: 0x1111,
      startLatitude: 19.0,
      startLongitude: 72.8,
      adapter: adapter,
    );
    final sosEvents = <MeshPacket>[];
    ctrl.sosStream.listen(sosEvents.add);
    await ctrl.start();

    final p = foreignPacket(seq: 99);
    await adapter.injectRemote(p);
    await adapter.injectRemote(p); // same sender+seq replayed
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // first frame processed and relayed exactly once; replay dropped
    expect(sosEvents.length, 1);
    expect(ctrl.framesRelayed, 1);
    await ctrl.stop();
  });

  test('foreign packet with TTL is relayed with incremented hop (FR-1.3)',
      () async {
    final adapter = SimulatedMeshAdapter();
    final ctrl = MeshController(
      nodeId: 0x1111,
      startLatitude: 19.0,
      startLongitude: 72.8,
      adapter: adapter,
    );
    await ctrl.start();

    final relaysBefore = ctrl.framesRelayed;
    await adapter.injectRemote(foreignPacket(seq: 7, ttl: 3));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(ctrl.framesRelayed - relaysBefore, 1);
    expect(ctrl.nodes[0x5555]!.hopCount, 0);
    await ctrl.stop();
  });

  test('packet at hop == initial TTL is dropped (FR-1.3)', () async {
    final adapter = SimulatedMeshAdapter();
    final ctrl = MeshController(
      nodeId: 0x1111,
      startLatitude: 19.0,
      startLongitude: 72.8,
      adapter: adapter,
    );
    await ctrl.start();

    final relaysBefore = ctrl.framesRelayed;
    await adapter.injectRemote(foreignPacket(seq: 8, ttl: 1, hop: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(ctrl.framesRelayed - relaysBefore, 0);
    await ctrl.stop();
  });

  test('own packet is never re-relayed', () async {
    final adapter = SimulatedMeshAdapter();
    final ctrl = MeshController(
      nodeId: 0x1111,
      startLatitude: 19.0,
      startLongitude: 72.8,
      adapter: adapter,
    );
    await ctrl.start();

    final relaysBefore = ctrl.framesRelayed;
    await ctrl.broadcastSos(triage: TriageFlags(severity: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(ctrl.framesRelayed - relaysBefore, 0);
    await ctrl.stop();
  });
}