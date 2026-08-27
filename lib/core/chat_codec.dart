/// Chat text codec — English-efficient packing.
///
/// 220 bytes of BLE payload is the wire limit (20 × 11B chunks). UTF-8 is
/// already 1 byte per ASCII char (0–127), so English is optimal at 1:1.
/// To squeeze more English into the same 220B we can pack 7-bit ASCII
/// (128 symbols) → 8 chars per 7 bytes (+12.5% → 251 → 249 after header).
/// For pure ASCII text between 221–249 chars we auto-pack; otherwise we
/// send raw UTF-8. Wire format: [0x00 + utf8] or [0x01, charCount, 7bitPacked].
/// Old devices that never sent a flag will send raw UTF-8 without the leading
/// 0x00 — the receiver detects that by the fallback below.
library;

import 'dart:convert';
import 'dart:typed_data';

bool isAsciiPrintable(String s) {
  for (final c in s.codeUnits) {
    if (c > 127) return false;
  }
  return true;
}

/// Pack 7-bit ASCII chars (0–127) into 8-bit bytes, 8 chars → 7 bytes.
Uint8List pack7Bit(String text) {
  final n = text.length;
  final outLen = (n * 7 + 7) ~/ 8;
  final out = Uint8List(outLen);
  var bitPos = 0;
  for (var i = 0; i < n; i++) {
    var v = text.codeUnitAt(i) & 0x7f;
    for (var b = 0; b < 7; b++) {
      if ((v & (1 << b)) != 0) {
        out[bitPos ~/ 8] |= (1 << (bitPos % 8));
      }
      bitPos++;
    }
  }
  return out;
}

String unpack7Bit(Uint8List packed, int charCount) {
  final out = StringBuffer();
  var bitPos = 0;
  for (var i = 0; i < charCount; i++) {
    var v = 0;
    for (var b = 0; b < 7; b++) {
      if ((packed[bitPos ~/ 8] & (1 << (bitPos % 8))) != 0) {
        v |= (1 << b);
      }
      bitPos++;
    }
    out.writeCharCode(v);
  }
  return out.toString();
}

/// Wire encode chat text for the mesh. Returns null if too long even after
/// packing.
Uint8List? encodeChatWire(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  // ASCII fast path: raw with flag fits?
  if (isAsciiPrintable(trimmed)) {
    if (trimmed.length + 1 <= 220) {
      return Uint8List.fromList([0x00, ...trimmed.codeUnits]);
    }
    // Overflow raw but may fit packed (221–249)
    if (trimmed.length <= 249) {
      final packed = pack7Bit(trimmed);
      if (packed.length + 2 <= 220) {
        return Uint8List.fromList([0x01, trimmed.length, ...packed]);
      }
    }
    return null;
  }
  // Non-ascii: UTF-8 bytes + flag
  final bytes = utf8.encode(trimmed);
  if (bytes.length + 1 <= 220) {
    return Uint8List.fromList([0x00, ...bytes]);
  }
  return null;
}

String decodeChatWire(Uint8List wire) {
  if (wire.isEmpty) return '';
  final flag = wire[0];
  if (flag == 0x00) {
    try {
      return utf8.decode(wire.sublist(1), allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(wire.sublist(1));
    }
  } else if (flag == 0x01) {
    if (wire.length < 2) return '';
    final count = wire[1];
    final packed = wire.sublist(2);
    try {
      return unpack7Bit(packed, count);
    } catch (_) {
      try {
        return utf8.decode(wire.sublist(1), allowMalformed: true);
      } catch (_) {
        return '';
      }
    }
  } else {
    // Legacy: no flag, raw UTF-8 (devices before this patch)
    try {
      return utf8.decode(wire, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(wire);
    }
  }
}

/// Bytes length of the wire payload for the given text (including flag/header),
/// or null if it would exceed 220 even with packing. Used for UI counter.
int? wireLengthFor(String text) {
  final enc = encodeChatWire(text);
  return enc?.length;
}
