import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:gridzero/core/db_sync.dart';

void main() {
  group('db sync protocol', () {
    test('exchange round-trips both directions with hash verification',
        () async {
      final server = await startDbSyncServer(
        port: 0,
        snapshotProvider: () async => '{"peer":"data"}',
        onSnapshot: (json) async => json == '{"hello":"world"}' ? null : 'bad',
      );
      expect(server, isNotNull);

      final result = await exchangeDbSnapshot(
        host: '127.0.0.1',
        port: server!.port,
        json: '{"hello":"world"}',
      );
      expect(result.error, isNull);
      // Reverse push: the client pulls the peer's snapshot back.
      expect(result.pulledJson, '{"peer":"data"}');
      await server.cancel();
    });

    test('server rejects a tampered payload via sha256 mismatch', () async {
      String? received;
      final server = await startDbSyncServer(
        port: 0,
        snapshotProvider: () async => '{}',
        onSnapshot: (json) async {
          received = json;
          return null;
        },
      );

      // Bypass the client helper: craft a frame with a wrong hash.
      final socket = await Socket.connect('127.0.0.1', server!.port);
      socket.add(utf8.encode('GZSYNC1|${'a' * 64}|4\n'));
      socket.add(utf8.encode('data'));
      await socket.flush();
      final reply = StringBuffer();
      await for (final chunk in socket) {
        reply.write(String.fromCharCodes(chunk));
        if (reply.toString().contains('\n')) break;
      }
      await socket.close();
      expect(reply.toString().trim(), startsWith('ERR'));
      expect(received, isNull);
      await server.cancel();
    });

    test('client reports an importer error from the server', () async {
      final server = await startDbSyncServer(
        port: 0,
        snapshotProvider: () async => '{}',
        onSnapshot: (_) async => 'snapshot import failed: boom',
      );
      final result = await exchangeDbSnapshot(
        host: '127.0.0.1',
        port: server!.port,
        json: '{"x":1}',
      );
      expect(result.error, contains('boom'));
      await server.cancel();
    });

    test('client fails fast when the server is unreachable', () async {
      // Bind then close: the port should be free (or rejected) immediately.
      final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final port = probe.port;
      await probe.close();
      final result = await exchangeDbSnapshot(
        host: '127.0.0.1',
        port: port,
        json: '{}',
        timeout: const Duration(seconds: 2),
      );
      expect(result.error, isNotNull);
    });
  });
}