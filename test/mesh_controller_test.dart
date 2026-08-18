import 'package:aapadsetu/core/mesh/mesh_controller.dart';
import 'package:aapadsetu/core/mesh_packet.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_mesh_adapter.dart';

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
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();
    await ctrl.broadcastSos(triage: TriageFlags(severity: 2));

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ctrl.nodes.containsKey(0x1111), isTrue);
    expect(ctrl.nodes[0x1111]!.hasSos, isTrue);
    await ctrl.stop();
  });

  test('duplicate frames are deduplicated (FR-1.4)', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
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

  test(
    'foreign packet with TTL is relayed with incremented hop (FR-1.3)',
    () async {
      final adapter = FakeMeshAdapter();
      final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
      await ctrl.start();

      final relaysBefore = ctrl.framesRelayed;
      await adapter.injectRemote(foreignPacket(seq: 7, ttl: 3));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(ctrl.framesRelayed - relaysBefore, 1);
      expect(ctrl.nodes[0x5555]!.hopCount, 0);
      await ctrl.stop();
    },
  );

  test('packet at hop == initial TTL is dropped (FR-1.3)', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    final relaysBefore = ctrl.framesRelayed;
    await adapter.injectRemote(foreignPacket(seq: 8, ttl: 1, hop: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(ctrl.framesRelayed - relaysBefore, 0);
    await ctrl.stop();
  });

  test('own packet is never re-relayed', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    final relaysBefore = ctrl.framesRelayed;
    await ctrl.broadcastSos(triage: TriageFlags(severity: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(ctrl.framesRelayed - relaysBefore, 0);
    await ctrl.stop();
  });

  test('no GPS hardware -> announce broadcasts 0,0 no-fix sentinel', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();
    await ctrl.announce();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final own = ctrl.nodes[0x1111]!;
    expect(own.latitude, 0);
    expect(own.longitude, 0);
    expect(ctrl.gpsFix, isFalse);
    expect(ctrl.approxLatitude, isNull);
    await ctrl.stop();
  });

  test('approx position is a consensus median of GPS peers', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    // Cluster around 19.07/72.87 with one far-away spoofed node.
    final cluster = [
      (19.0700, 72.8700),
      (19.0710, 72.8720),
      (19.0690, 72.8680),
      (19.0720, 72.8740),
      (19.0680, 72.8660),
    ];
    for (var i = 0; i < cluster.length; i++) {
      final (lat, lon) = cluster[i];
      await adapter.injectRemote(
        MeshPacket(
          type: MeshPacketType.relayStatus,
          senderId: 0x2000 + i,
          latitude: lat,
          longitude: lon,
          triage: TriageFlags(),
          seq: i,
        ),
      );
    }
    // Malicious outlier ~11km south.
    await adapter.injectRemote(
      MeshPacket(
        type: MeshPacketType.relayStatus,
        senderId: 0x3000,
        latitude: 18.97,
        longitude: 72.87,
        triage: TriageFlags(),
        seq: 99,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(ctrl.approxSourceCount, greaterThanOrEqualTo(5));
    expect(ctrl.approxLatitude, closeTo(19.07, 0.005));
    expect(ctrl.approxLongitude, closeTo(72.87, 0.005));
    expect(ctrl.approxRadiusKm, lessThan(2));
    await ctrl.stop();
  });

  test('gpsFix sets own coordinates and advertises them', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    ctrl.setGpsFix(latitude: 19.1, longitude: 72.9);
    await ctrl.start();
    await ctrl.announce();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(ctrl.nodes[0x1111]!.latitude, closeTo(19.1, 1e-6));
    expect(ctrl.nodes[0x1111]!.longitude, closeTo(72.9, 1e-6));
    await ctrl.stop();
  });
}
