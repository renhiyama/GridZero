import 'package:gridzero/core/mesh/mesh_controller.dart';
import 'package:gridzero/core/mesh_packet.dart';
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
  test('own broadcast never registers own node in the peer map', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();
    await ctrl.broadcastSos(triage: TriageFlags(severity: 2));
    ctrl.setGpsFix(latitude: 19.1, longitude: 72.9);

    // The local radio hears its own advertisement back (loopback), but own
    // frames must not pollute the peer map: this device is drawn from its own
    // GPS/estimate state, so SELF never appears as a peer/relayer/SOS source.
    await ctrl.announce();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ctrl.nodes.containsKey(0x1111), isFalse);
    expect(ctrl.nodes.isEmpty, isTrue);
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

  test('relayed SOS takes the persistent advertisement slot', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    await adapter.injectRemote(foreignPacket(seq: 21, ttl: 3));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final relayed = adapter.broadcasted.last;
    expect(relayed.type, MeshPacketType.sosBeacon);
    expect(relayed.senderId, 0x5555);
    expect(relayed.latitude, 19.0);
    expect(relayed.longitude, 72.8);
    expect(relayed.hopCount, 1);
    expect(adapter.broadcastPersistent.last, isTrue);
    await ctrl.stop();
  });

  test('ordinary relays do not dwell in the advertisement slot', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    final relaysBefore = ctrl.framesRelayed;
    await adapter.injectRemote(
      MeshPacket(
        type: MeshPacketType.relayStatus,
        senderId: 0x6666,
        latitude: 19.0,
        longitude: 72.8,
        triage: TriageFlags(severity: 3),
        seq: 22,
        initialTtl: 3,
        hopCount: 0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(ctrl.framesRelayed - relaysBefore, 1);
    expect(adapter.broadcastPersistent.last, isFalse);
    await ctrl.stop();
  });

  test('radio governor hints forward to the transport', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    await ctrl.setRadioActive(false);
    expect(adapter.radioActive, isFalse);
    await ctrl.setRadioActive(true);
    expect(adapter.radioActive, isTrue);
    await ctrl.setRadioAlert(true);
    expect(adapter.radioAlert, isTrue);
    await ctrl.stop();
  });

  test('no GPS hardware -> announce broadcasts 0,0 no-fix sentinel', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();
    await ctrl.announce();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // No own node in the peer map; the 0,0 sentinel goes out on the wire so
    // peers never mistake this device for a located peer.
    expect(ctrl.nodes.isEmpty, isTrue);
    expect(ctrl.gpsFix, isFalse);
    expect(ctrl.approxLatitude, isNull);
    final sent = adapter.broadcasted.last;
    expect(sent.latitude, 0);
    expect(sent.longitude, 0);
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
    ctrl.setGpsFix(latitude: 19.1, longitude: 72.9, altitude: 50);
    await ctrl.start();
    await ctrl.announce();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(ctrl.gpsFix, isTrue);
    expect(ctrl.effectiveLatitude, closeTo(19.1, 1e-6));
    expect(ctrl.effectiveLongitude, closeTo(72.9, 1e-6));
    final sent = adapter.broadcasted.last;
    expect(sent.latitude, closeTo(19.1, 1e-6));
    expect(sent.longitude, closeTo(72.9, 1e-6));
    expect(ctrl.nodes.containsKey(0x1111), isFalse);
    await ctrl.stop();
  });

  test(
    'effective coordinates fall back to peer consensus without a GPS fix',
    () async {
      final adapter = FakeMeshAdapter();
      final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
      await ctrl.start();
      expect(ctrl.gpsFix, isFalse);

      // Two nearby peers around (20.3, 85.8).
      for (final (id, lat, lon, seq) in [
        (0xAA, 20.30, 85.80, 1),
        (0xBB, 20.34, 85.84, 2),
        (0xCC, 20.32, 85.82, 3),
      ]) {
        await adapter.injectRemote(
          MeshPacket(
            type: MeshPacketType.relayStatus,
            senderId: id,
            latitude: lat,
            longitude: lon,
            triage: TriageFlags(),
            seq: seq,
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(ctrl.approxLatitude, isNotNull);
      expect(ctrl.effectiveLatitude, ctrl.approxLatitude);
      expect(ctrl.effectiveLongitude, ctrl.approxLongitude);
      expect(ctrl.approxLatitude!, closeTo(20.32, 1e-3));

      // With a real fix, the GPS position wins the wire coordinates.
      ctrl.setGpsFix(latitude: 9.9, longitude: 76.2);
      expect(ctrl.effectiveLatitude, 9.9);
      expect(ctrl.effectiveLongitude, 76.2);
      await ctrl.stop();
    },
  );

  test('sosBeacon floods through relays with TTL (FEAT-MESH-02)', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    // A, two hops away: A -> B (this ctrl) -> C. B must relay the SOS frame.
    final sos = MeshPacket(
      type: MeshPacketType.sosBeacon,
      senderId: 0xA,
      latitude: 20.35,
      longitude: 85.82,
      altitudeCm: 4500,
      triage: TriageFlags(severity: 5, trapped: true),
      seq: 7,
      initialTtl: 5,
    );
    await adapter.injectRemote(sos);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final relayed = adapter.broadcasted;
    final fwd = relayed.firstWhere(
      (p) => p.senderId == 0xA && p.type == MeshPacketType.sosBeacon,
    );
    expect(fwd.hopCount, 1); // hop bumped for the next leg
    expect(fwd.seq, 7); // same frame, not re-stamped
    expect(fwd.altitudeCm, 4500); // altitude survives relaying
    expect(ctrl.framesRelayed, 1);
    await ctrl.stop();
  });

  test(
    'sosStarted/sosEnded fire once per transition, cleared frame turns off',
    () async {
      final adapter = FakeMeshAdapter();
      final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
      final started = <int>[];
      final ended = <int>[];
      ctrl.sosStarted.listen((n) => started.add(n.nodeId));
      ctrl.sosEnded.listen((n) => ended.add(n.nodeId));
      await ctrl.start();

      final sos = MeshPacket(
        type: MeshPacketType.sosBeacon,
        senderId: 0xA,
        latitude: 20.35,
        longitude: 85.82,
        triage: TriageFlags(severity: 3),
        seq: 1,
      );
      await adapter.injectRemote(sos);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(started, [0xA]);
      expect(ctrl.nodes[0xA]!.hasSos, isTrue);

      // Re-broadcast of the same episode must not re-alert.
      await adapter.injectRemote(
        MeshPacket(
          type: MeshPacketType.sosBeacon,
          senderId: 0xA,
          latitude: 20.35,
          longitude: 85.82,
          triage: TriageFlags(severity: 3),
          seq: 2,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(started, [0xA]);

      // Cleared frame flips the receiver off and emits sosEnded.
      await adapter.injectRemote(
        MeshPacket(
          type: MeshPacketType.sosBeacon,
          senderId: 0xA,
          latitude: 20.35,
          longitude: 85.82,
          triage: TriageFlags(severity: 3),
          seq: 3,
          flags: 1,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ctrl.nodes[0xA]!.hasSos, isFalse);
      expect(ended, [0xA]);
      await ctrl.stop();
    },
  );

  test(
    'identity announce names the node without clobbering position',
    () async {
      final adapter = FakeMeshAdapter();
      final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
      await ctrl.start();

      await adapter.injectRemote(
        MeshPacket(
          type: MeshPacketType.relayStatus,
          senderId: 0x2222,
          latitude: 19.0,
          longitude: 72.8,
          triage: TriageFlags(),
          seq: 1,
        ),
      );
      await adapter.injectRemote(
        MeshPacket(
          type: MeshPacketType.identityAnnounce,
          senderId: 0x2222,
          latitude: 0,
          longitude: 0,
          triage: TriageFlags(),
          seq: 2,
          identityUsername: 'REN',
          identityRole: kRoleCitizen,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final node = ctrl.nodes[0x2222]!;
      expect(node.username, 'REN');
      expect(node.roleCode, kRoleCitizen);
      // The identity frame must not erase the position learned earlier.
      expect(node.latitude, closeTo(19.0, 1e-9));
      expect(node.longitude, closeTo(72.8, 1e-9));
      await ctrl.stop();
    },
  );

  test(
    'ledger record routes to onLedgerRecord; request routes to pull',
    () async {
      final adapter = FakeMeshAdapter();
      final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
      final records = <CompactRecord>[];
      final requests = <int>[];
      ctrl.onLedgerRecord = (r, from) => records.add(r);
      ctrl.onLedgerSyncRequest = requests.add;
      await ctrl.start();

      await adapter.injectRemote(
        MeshPacket(
          type: MeshPacketType.ledgerRecord,
          senderId: 0x2222,
          latitude: 0,
          longitude: 0,
          triage: TriageFlags(),
          seq: 1,
          syncRecord: CompactRecord(
            citizenId: 'CIT-0A3F0FAB',
            officerId: 'OFF-00BEEF',
            claimedAt: 1700000000,
            rationCode: 'Rice',
          ),
        ),
      );
      await adapter.injectRemote(
        MeshPacket(
          type: MeshPacketType.ledgerSyncRequest,
          senderId: 0x2222,
          latitude: 0,
          longitude: 0,
          triage: TriageFlags(),
          seq: 2,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(records, hasLength(1));
      expect(records.single.citizenId, 'CIT-0A3F0FAB');
      expect(requests, [0x2222]);
      await ctrl.stop();
    },
  );

  test('payload frames relay with payload intact (no null crash)', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();

    await adapter.injectRemote(
      MeshPacket(
        type: MeshPacketType.ledgerRecord,
        senderId: 0x2222,
        latitude: 0,
        longitude: 0,
        triage: TriageFlags(),
        seq: 1,
        syncRecord: CompactRecord(
          citizenId: 'CIT-0A3F0FAB',
          officerId: 'OFF-00BEEFA1',
          claimedAt: 1700000000,
          rationCode: 'Rice',
        ),
      ),
    );
    await adapter.injectRemote(
      MeshPacket(
        type: MeshPacketType.identityAnnounce,
        senderId: 0x3333,
        latitude: 0,
        longitude: 0,
        triage: TriageFlags(),
        seq: 2,
        identityUsername: 'REN',
        identityRole: kRoleCitizen,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final relayed = adapter.broadcasted
        .where((p) => p.senderId != ctrl.nodeId)
        .toList();
    final fwd = relayed.firstWhere(
      (p) => p.type == MeshPacketType.ledgerRecord,
    );
    expect(fwd.syncRecord!.citizenId, 'CIT-0A3F0FAB');
    expect(fwd.syncRecord!.rationCode, 'Rice');
    expect(fwd.hopCount, 1);

    final idFwd = relayed.firstWhere(
      (p) => p.type == MeshPacketType.identityAnnounce,
    );
    expect(idFwd.identityUsername, 'REN');
    expect(idFwd.identityRole, kRoleCitizen);
    expect(idFwd.hopCount, 1);
    await ctrl.stop();
  });
}
