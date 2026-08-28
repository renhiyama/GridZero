import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/app_state.dart';
import 'package:gridzero/core/mesh/mesh_controller.dart';
import 'package:gridzero/core/mesh_packet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_mesh_adapter.dart';

AppState makeState() {
  AppState.nativeAdapterFactory = (nodeId) => FakeMeshAdapter();
  return AppState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('mesh chat reliability', () {
    test('admin to officer single-chunk chat arrives', () async {
      final officer = makeState();
      await officer.init();
      await officer.register('OFF1', 'pass', Role.officer);
      final ctrl = officer.mesh!;
      final got = <DataMessageRx>[];
      ctrl.dataMessages.listen((rx) {
        if (rx.type == MeshPacketType.chat) got.add(rx);
      });
      final text = 'bsdk';
      final wire = Uint8List.fromList(text.codeUnits);
      // Use a known senderId different from officer's own
      final senderId = (ctrl.nodeId + 1) & 0xffff;
      final packet = MeshPacket(
        type: MeshPacketType.chat,
        senderId: senderId,
        latitude: 0,
        longitude: 0,
        triage: TriageFlags(),
        seq: 1,
        chunk: MeshDataChunk(index: 0, total: 1, data: wire),
      );
      (ctrl.adapter as FakeMeshAdapter).injectRemote(packet);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(got, isNotEmpty);
      expect(String.fromCharCodes(got.first.bytes), text);
      officer.dispose();
    });

    test('back-to-back chats within cooldown are rate-limited', () async {
      final app = makeState();
      await app.init();
      await app.register('TESTER', 'pass', Role.citizen);
      await app.mesh!.start();
      final first = await app.sendBroadcastMessage('first message');
      expect(first, isNull);
      final second = await app.sendBroadcastMessage('second message');
      expect(second, contains('wait'));
      app.dispose();
    });

    test('large chat near 220B is chunked and reassembled', () async {
      final adapter = FakeMeshAdapter();
      final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
      await ctrl.start();
      final got = <DataMessageRx>[];
      ctrl.dataMessages.listen(got.add);
      final longText = 'A' * 200; // 200 chars, 200 bytes, 19 chunks
      final wire = Uint8List.fromList(longText.codeUnits);
      final total = (wire.length / MeshDataChunk.chunkBytes).ceil();
      // Simulate remote sender with different nodeId so it is not dropped as loopback
      final senderId = 0x2222;
      for (var i = 0; i < total; i++) {
        final slice = wire.sublist(i * MeshDataChunk.chunkBytes, (i + 1) * MeshDataChunk.chunkBytes > wire.length ? wire.length : (i + 1) * MeshDataChunk.chunkBytes);
        adapter.injectRemote(MeshPacket(
          type: MeshPacketType.chat,
          senderId: senderId,
          latitude: 0,
          longitude: 0,
          triage: TriageFlags(),
          seq: 100 + i,
          chunk: MeshDataChunk(index: i, total: total, data: Uint8List.fromList(slice)),
        ));
        // Small delay to mimic paced broadcast
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(got, hasLength(1));
      expect(got.first.bytes.length, 200);
      expect(String.fromCharCodes(got.first.bytes), longText);
      await ctrl.stop();
    });

    test('chat persists and survives wipe', () async {
      final app = makeState();
      await app.init();
      await app.register('TESTER', 'pass', Role.citizen);
      await app.sendBroadcastMessage('hello');
      expect(app.chatMessages, hasLength(1));
      await app.deleteAllData();
      expect(app.chatMessages, isEmpty);
      expect(app.officialLandmarks, isEmpty);
      // Mesh nodes should also be wiped
      expect(app.mesh?.nodes, isEmpty);
      app.dispose();
    });
  });
}
