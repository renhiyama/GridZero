import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/mesh/mesh_controller.dart';
import 'package:gridzero/core/mesh_packet.dart';

import 'fake_mesh_adapter.dart';

void main() {
  group('respond ack (0x09)', () {
    test('wire roundtrip preserves target and type', () {
      final p = MeshPacket(
        type: MeshPacketType.respond,
        senderId: 0x1234,
        latitude: 0,
        longitude: 0,
        triage: TriageFlags(),
        seq: 42,
        targetNodeId: 0x0abc,
      );
      final decoded = MeshPacket.decode(p.encode());
      expect(decoded.type, MeshPacketType.respond);
      expect(decoded.targetNodeId, 0x0abc);
      expect(decoded.senderId, 0x1234);
      expect(decoded.seq, 42);
      expect(decoded.latitude, 0);
    });

    test('target device tracks the responder and fires the alert stream',
        () async {
      final me = MeshController(
        nodeId: 0x0abc,
        adapter: FakeMeshAdapter(),
      );
      final arrived = <int>[];
      me.responderArrived.listen(arrived.add);

      await me.adapter.injectRemote(
        MeshPacket(
          type: MeshPacketType.respond,
          senderId: 0x1234,
          latitude: 0,
          longitude: 0,
          triage: TriageFlags(),
          seq: 1,
          targetNodeId: 0x0abc, // addressed to me
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(me.responders, {0x1234});
      expect(arrived, [0x1234]);

      // A second ack from the same responder dedupes: no double ring.
      await me.adapter.injectRemote(
        MeshPacket(
          type: MeshPacketType.respond,
          senderId: 0x1234,
          latitude: 0,
          longitude: 0,
          triage: TriageFlags(),
          seq: 2,
          targetNodeId: 0x0abc,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(arrived, [0x1234]);

      me.clearResponders();
      expect(me.responders, isEmpty);
      await me.stop();
    });

    test('respond frames addressed to another node are ignored', () async {
      final me = MeshController(
        nodeId: 0x0abc,
        adapter: FakeMeshAdapter(),
      );
      await me.adapter.injectRemote(
        MeshPacket(
          type: MeshPacketType.respond,
          senderId: 0x1234,
          latitude: 0,
          longitude: 0,
          triage: TriageFlags(),
          seq: 1,
          targetNodeId: 0xdead, // someone else's SOS
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(me.responders, isEmpty);
      await me.stop();
    });

    test('broadcastRespond floods a decodable ack frame', () async {
      final radio = FakeMeshAdapter();
      final responder = MeshController(nodeId: 0x1234, adapter: radio);
      await responder.broadcastRespond(0x0abc);
      final sent = radio.broadcasted.last;
      final decoded = MeshPacket.decode(sent.encode());
      expect(decoded.type, MeshPacketType.respond);
      expect(decoded.targetNodeId, 0x0abc);
      expect(decoded.senderId, 0x1234);
      await responder.stop();
    });
  });
}