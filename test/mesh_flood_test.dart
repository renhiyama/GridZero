import 'package:gridzero/core/mesh/mesh_controller.dart';
import 'package:gridzero/core/mesh_packet.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_mesh_adapter.dart';

/// Synthetic N-node flood: stands in for a field full of radios so the relay
/// and dedup machinery is proven under contention without needing hardware.
/// The fake echoes broadcasts back (loopback) like a real concurrent
/// scan+advertise radio, so the test also proves relay loops are cut.
MeshPacket floodPacket(int senderId, int seq, {int ttl = 5, int hop = 0}) =>
  MeshPacket(
    type: MeshPacketType.relayStatus,
    senderId: senderId,
    latitude: 20.0 + senderId * 1e-4,
    longitude: 85.0,
    triage: TriageFlags(),
    seq: seq & 0xffff,
    initialTtl: ttl,
    hopCount: hop,
  );

/// Lets the async scan-stream delivery + relay echoes drain before asserting.
Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

Future<void> inject(FakeMeshAdapter a, List<MeshPacket> pkts) async {
  for (final p in pkts) {
    await a.injectRemote(p);
  }
  await settle();
}

void main() {
  test('N=50 discovery burst: every sender appears once, each frame relayed', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    final burst = [for (var i = 0; i < 50; i++) floodPacket(0x1000 + i, i)];
    await inject(adapter, burst);

    expect(ctrl.framesSeen, 100); // 50 frames + their 50 relay echoes
    expect(ctrl.framesRelayed, 50);
    expect(ctrl.nodes.length, 50);
    for (var i = 0; i < 50; i++) {
      expect(ctrl.nodes.containsKey(0x1000 + i), isTrue);
    }
    await ctrl.stop();
  });

  test('replay of the same burst is fully deduplicated (FR-1.4)', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    final burst = [for (var i = 0; i < 50; i++) floodPacket(0x1000 + i, i)];
    await inject(adapter, burst);
    final seenAfterFirst = ctrl.framesSeen;
    final relayedAfterFirst = ctrl.framesRelayed;

    // The radio hears the replay burst again (framesSeen grows), but dedup
    // stops every one of them: no re-relay, no node churn.
    await inject(adapter, burst);
    expect(ctrl.framesSeen, seenAfterFirst + 50);
    expect(ctrl.framesRelayed, relayedAfterFirst);
    expect(ctrl.nodes.length, 50);
    await ctrl.stop();
  });

  test('N=20 sustained heartbeat churn: node map stays flat at 20, no growth', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    for (var cycle = 0; cycle < 10; cycle++) {
      final frames = [for (var i = 0; i < 20; i++) floodPacket(0x2000 + i, cycle * 20 + i)];
      await inject(adapter, frames);
    }
    expect(ctrl.framesSeen, 400); // 200 frames + their 200 relay echoes
    expect(ctrl.framesRelayed, 200);
    expect(ctrl.nodes.length, 20);
    await ctrl.stop();
  });

  test('N=200 churn flood stays stable and relayed volume is bounded', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    final churn = [for (var i = 0; i < 200; i++) floodPacket(0x3000 + i, i)];
    await inject(adapter, churn);
    expect(ctrl.framesSeen, 400); // 200 frames + their 200 relay echoes
    expect(ctrl.framesRelayed, 200);
    expect(ctrl.nodes.length, 200);

    // A TTL=1 frame (already at the last hop) must NOT be relayed again:
    // relayed volume cannot exceed one broadcast per sender per seq.
    await inject(adapter, [floodPacket(0x4000, 0, ttl: 1)]);
    expect(ctrl.framesSeen, 401);
    expect(ctrl.framesRelayed, 200);
    expect(ctrl.nodes.length, 201);
    await ctrl.stop();
  });

  test('SOS amid the flood still takes the persistent relay slot (FR-3.4)', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    final flood = [for (var i = 0; i < 10; i++) floodPacket(0x5000 + i, i)];
    final sos = MeshPacket(
      type: MeshPacketType.sosBeacon,
      senderId: 0x5abc,
      latitude: 21.0,
      longitude: 86.0,
      triage: TriageFlags(severity: 3, water: true),
      seq: 900,
    );
    await inject(adapter, [...flood, sos]);

    expect(ctrl.nodes[0x5abc]!.hasSos, isTrue);
    // Relay slot: the flood frames rotated through the short slot, the SOS
    // relay took the persistent slot.
    final sosRelay = adapter.broadcasted.lastWhere(
      (p) => p.type == MeshPacketType.sosBeacon && p.senderId == 0x5abc,
    );
    expect(adapter.broadcastPersistent[adapter.broadcasted.indexOf(sosRelay)], isTrue);
    await ctrl.stop();
  });

  test('loopback relay echoes never re-enter the mesh (relay loop cut)', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    await inject(adapter, [floodPacket(0x6001, 1)]);
    await settle();
    await settle();
    // The controller relayed once; the fake echoed that relay back, and dedup
    // swallowed it. No further processing happened: one frame seen as itself
    // plus its own relay echo, one relay, one peer.
    expect(ctrl.framesSeen, 2);
    expect(ctrl.framesRelayed, 1);
    expect(ctrl.nodes.length, 1);
    await ctrl.stop();
  });
}