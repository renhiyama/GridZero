/// Device-to-device DB exchange over a direct wifi link: one side (phone)
/// runs a one-shot TCP server; the other (HQ laptop) connects, pushes its
/// full DB snapshot, and receives the phone's snapshot back in the same
/// session. Plain TCP sockets (not HTTP) keep the transfer free of Android
/// cleartext-traffic policy.
///
/// Frame format:
///   `GZSYNC1|<sha256hex>|<length>\n` followed by exactly [length] bytes.
/// Both sides verify the hash before touching the payload, so a truncated
/// or corrupted transfer never reaches either ledger.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int kDbSyncPort = 7941;
const String _magic = 'GZSYNC1';
const int kMaxSnapshotBytes = 256 * 1024 * 1024;

/// Decodes one header line: returns (sha256hex, length) or null when malformed.
({String hash, int length})? _parseHeader(String line) {
  final parts = line.trim().split('|');
  if (parts.length != 3 || parts[0] != _magic) return null;
  final hash = parts[1];
  final length = int.tryParse(parts[2]);
  if (hash.length != 64 || length == null || length < 0) return null;
  if (length > kMaxSnapshotBytes) return null;
  return (hash: hash, length: length);
}

/// Incremental line/binary reader over a [Socket]. Buffers partial reads so a
/// header split across two TCP segments still reassembles.
class _SocketReader {
  _SocketReader(Socket socket) : _iterator = StreamIterator<Uint8List>(socket);

  final StreamIterator<Uint8List> _iterator;
  BytesBuilder _pending = BytesBuilder(copy: false);

  /// Next chunk available for reading, or null at end of stream.
  Future<Uint8List?> _next() async {
    while (_pending.length == 0) {
      if (!await _iterator.moveNext()) return null;
      _pending.add(_iterator.current);
    }
    return _pending.takeBytes();
  }

  /// Reads exactly [length] bytes, or null on a short/closed stream.
  Future<Uint8List?> readBytes(int length) async {
    final out = BytesBuilder(copy: false);
    while (out.length < length) {
      final chunk = await _next();
      if (chunk == null) return null;
      out.add(chunk);
    }
    return out.takeBytes();
  }

  /// Reads a CR/LF-terminated line (no terminator included), or null at EOF.
  Future<String?> readLine() async {
    final buf = BytesBuilder(copy: false);
    while (true) {
      final chunk = await _next();
      if (chunk == null) {
        return buf.isEmpty ? null : utf8.decode(buf.takeBytes());
      }
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] == 0x0A) {
          if (i + 1 < chunk.length) {
            _pending = BytesBuilder(copy: false)..add(chunk.sublist(i + 1));
          }
          return utf8.decode(buf.takeBytes(), allowMalformed: true);
        }
        buf.addByte(chunk[i]);
      }
    }
  }
}

/// Writes [json] as a framed snapshot onto [socket].
void _writeFrame(Socket socket, String json) {
  final bytes = utf8.encode(json);
  final digest = sha256.convert(bytes).toString();
  socket.add(utf8.encode('$_magic|$digest|${bytes.length}\n'));
  socket.add(bytes);
}

/// Server side (phone). Listens on all interfaces and serves exactly one
/// connection: it imports the incoming snapshot via [onSnapshot], then answers
/// with its own snapshot from [snapshotProvider]. One connection therefore
/// synchronises BOTH directions. Returns the bound port (or null on bind
/// failure) and a canceller.
Future<({int port, Future<void> Function() cancel})?> startDbSyncServer({
  required Future<String?> Function(String json) onSnapshot,
  required Future<String> Function() snapshotProvider,
  int port = kDbSyncPort,
}) async {
  final ServerSocket server;
  try {
    server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
  } on SocketException {
    return null;
  }
  var closed = false;
  final done = Completer<void>();
  server.listen((socket) async {
    try {
      final reader = _SocketReader(socket);
      final frame = await _readFrame(reader);
      if (frame == null) {
        socket.write('ERR malformed frame\n');
        return;
      }
      final error = await onSnapshot(frame.json);
      if (error != null) {
        socket.write('ERR $error\n');
        return;
      }
      // Import landed: answer with this device's snapshot so the visitor
      // pulls our data in the same session (reverse push).
      _writeFrame(socket, await snapshotProvider());
    } catch (_) {
      socket.write('ERR server error\n');
    } finally {
      await socket.close();
      if (!closed) await server.close();
      if (!done.isCompleted) done.complete();
    }
  }, onError: (_) {
    if (!closed) server.close();
    if (!done.isCompleted) done.complete();
  });
  return (
    port: server.port,
    cancel: () async {
      closed = true;
      await server.close();
      if (!done.isCompleted) done.complete();
    },
  );
}

/// Reads a snapshot frame from [reader]. Returns (json, sha256hex) or null on
/// any protocol/tamper failure.
Future<({String json, String hash})?> _readFrame(
  _SocketReader reader,
) async {
  final line = await reader.readLine();
  if (line == null) return null;
  final header = _parseHeader(line);
  if (header == null) return null;
  final bytes = await reader.readBytes(header.length);
  if (bytes == null || bytes.length != header.length) return null;
  final digest = sha256.convert(bytes).toString();
  if (digest != header.hash) return null;
  return (json: utf8.decode(bytes), hash: digest);
}

/// Result of [exchangeDbSnapshot]: [error] is null on protocol success; the
/// peer's snapshot arrives as [pulledJson] when they answered with one.
class DbExchangeResult {
  const DbExchangeResult({this.error, this.pulledJson});
  final String? error;
  final String? pulledJson;
}

/// Client side (laptop). Pushes [json] to the peer's sync server and reads
/// the peer's snapshot reply. Returns error text via the result; a plain OK
/// line (legacy server without reverse push) yields a null pulledJson.
Future<DbExchangeResult> exchangeDbSnapshot({
  required String host,
  required int port,
  required String json,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final bytes = utf8.encode(json);
  final digest = sha256.convert(bytes).toString();
  final Socket socket;
  try {
    socket = await Socket.connect(host, port, timeout: timeout).timeout(
      timeout,
    );
  } on TimeoutException {
    return const DbExchangeResult(error: 'sync server unreachable (timeout)');
  } on SocketException {
    return const DbExchangeResult(error: 'sync server unreachable');
  }
  try {
    socket.add(utf8.encode('$_magic|$digest|${bytes.length}\n'));
    socket.add(bytes);
    await socket.flush();
    final reader = _SocketReader(socket);
    final first = await reader.readLine();
    if (first == null) {
      return const DbExchangeResult(error: 'no reply from phone');
    }
    final trimmed = first.trim();
    if (trimmed.startsWith('$_magic|')) {
      final header = _parseHeader(trimmed);
      if (header == null) {
        return const DbExchangeResult(error: 'malformed reply frame');
      }
      final body = await reader.readBytes(header.length);
      if (body == null || body.length != header.length) {
        return const DbExchangeResult(error: 'truncated reply frame');
      }
      if (sha256.convert(body).toString() != header.hash) {
        return const DbExchangeResult(error: 'reply hash mismatch');
      }
      return DbExchangeResult(pulledJson: utf8.decode(body));
    }
    if (trimmed == 'OK') {
      // Legacy ack-only server: push succeeded, nothing to pull.
      return const DbExchangeResult();
    }
    return DbExchangeResult(
      error: trimmed.startsWith('ERR ')
          ? trimmed.substring(4)
          : 'unexpected reply: $trimmed',
    );
  } finally {
    await socket.close();
  }
}
