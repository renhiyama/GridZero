import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/mesh/mesh_controller.dart';
import 'package:gridzero/core/mesh_packet.dart';

import 'fake_mesh_adapter.dart';

MeshPacket chunkPacket({
  required int sender,
  required int seq,
  required int index,
  required int total,
  required List<int> slice,
}) =>
    MeshPacket(
      type: MeshPacketType.chat,
      senderId: sender,
      latitude: 0,
      longitude: 0,
      triage: TriageFlags(),
      seq: seq,
      chunk: MeshDataChunk(
        index: index,
        total: total,
        data: Uint8List.fromList(slice),
      ),
    );

void main() {
  test('chat and announce wire round-trips share the chunk layout', () {
    final data = Uint8List.fromList([9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 255]);
    for (final type in [MeshPacketType.chat, MeshPacketType.announce]) {
      final wire = MeshPacket(
        type: type,
        senderId: 0xBEEF,
        latitude: 0,
        longitude: 0,
        triage: TriageFlags(),
        seq: 7,
        chunk: MeshDataChunk(index: 2, total: 6, data: data),
      ).encode();
      final decoded = MeshPacket.decode(wire);
      expect(decoded.type, type);
      expect(decoded.chunk!.index, 2);
      expect(decoded.chunk!.total, 6);
      expect(decoded.chunk!.data, data);
    }
  });

  test('controller reassembles interleaved chat bursts per sender', () async {
    final adapter = FakeMeshAdapter();
    final ctrl = MeshController(nodeId: 0x1111, adapter: adapter);
    await ctrl.start();
    final got = <DataMessageRx>[];
    ctrl.dataMessages.listen(got.add);

    Uint8List blob(String s) => Uint8List.fromList(s.codeUnits);

    // Two senders, chunks arriving interleaved.
    final a = blob('hello from alpha');
    final b = blob('beta reporting');
    for (var i = 0; i < 2; i++) {
      adapter.injectRemote(chunkPacket(
        sender: 0x2222,
        seq: 10 + i,
        index: i,
        total: 2,
        slice: a.sublist(i * 11, (i + 1) * 11 > a.length ? a.length : (i + 1) * 11),
      ));
      adapter.injectRemote(chunkPacket(
        sender: 0x3333,
        seq: 20 + i,
        index: i,
        total: 2,
        slice: b.sublist(i * 11, (i + 1) * 11 > b.length ? b.length : (i + 1) * 11),
      ));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // ignore: avoid_print
    // ignore: avoid_print
    final gotText = [
      for (final m in got) '${m.senderId}:${String.fromCharCodes(m.bytes)}',
    ].join(' | ');
    // ignore: avoid_print
    print('GOT=$gotText');
    expect(got, hasLength(2));
    final texts = got.map((m) => String.fromCharCodes(m.bytes)).toSet();
    expect(texts.contains('hello from alpha'), isTrue);
    expect(texts.contains('beta reporting'), isTrue);
    expect(ctrl.dataMessages, isA<Stream>());
    await ctrl.stop();
  });
}
