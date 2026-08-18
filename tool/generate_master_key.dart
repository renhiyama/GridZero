/// Offline HQ key generation tool.
///
/// Emits assets/officer_pubkey.pem (embedded in the app) and prints a signed
/// master-key payload that can be encoded into an enlistment QR code.
///
/// Run: dart run tool/generate_master_key.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

final BigInt _publicExponent = BigInt.parse('65537');

Uint8List _derLength(int length) {
  if (length < 0x80) return Uint8List.fromList([length]);
  final bytes = <int>[];
  var tmp = length;
  while (tmp > 0) {
    bytes.insert(0, tmp & 0xff);
    tmp >>= 8;
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

Uint8List _derInteger(BigInt value) {
  var bytes = Uint8List((value.bitLength + 7) ~/ 8);
  var tmp = value;
  for (var i = bytes.length - 1; i >= 0; i--) {
    bytes[i] = (tmp & BigInt.from(0xff)).toInt();
    tmp >>= 8;
  }
  if ((bytes[0] & 0x80) != 0) {
    final withPad = Uint8List(bytes.length + 1);
    withPad.setAll(1, bytes);
    bytes = withPad;
  }
  final len = _derLength(bytes.length);
  return Uint8List.fromList([0x02, ...len, ...bytes]);
}

Uint8List _derSequence(List<Uint8List> members) {
  final body = members.fold<List<int>>(
      [], (acc, m) => [...acc, ...m]);
  final len = _derLength(body.length);
  return Uint8List.fromList([0x30, ...len, ...body]);
}

String _pemEncode(String label, Uint8List der) {
  final b64 = base64Encode(der);
  final lines = <String>['-----BEGIN $label-----'];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  lines.add('-----END $label-----');
  return lines.join('\n');
}

String _canonical(String officerId, int issuedAt) =>
    'v=1|officer_id=$officerId|issued_at=$issuedAt';

void main() {
  final random = FortunaRandom()
    ..seed(KeyParameter(
        Uint8List.fromList(List<int>.generate(32, (i) => i + 1))));
  final keyGen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(_publicExponent, 2048, 64),
      random,
    ));
  final pair = keyGen.generateKeyPair();
  final publicKey = pair.publicKey;
  final privateKey = pair.privateKey;

  final pubDer = _derSequence([
    _derInteger(publicKey.modulus!),
    _derInteger(publicKey.exponent!)
  ]);
  final pem = _pemEncode('PUBLIC KEY', pubDer);
  File('assets/officer_pubkey.pem').writeAsStringSync('$pem\n');

  final digest = sha256.convert(utf8.encode(pem)).toString();
  final officerId = 'OFF-${digest.substring(0, 8).toUpperCase()}';
  final issuedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
  final signature = signer.generateSignature(utf8.encode(_canonical(officerId, issuedAt)));

  final payload = jsonEncode({
    'v': 1,
    'officer_id': officerId,
    'issued_at': issuedAt,
    'sig': base64Encode(signature.bytes),
  });

  stdout.writeln('OFFICER_ID:  $officerId');
  stdout.writeln('ISSUED_AT:   $issuedAt');
  stdout.writeln('');
  stdout.writeln('MASTER_KEY_PAYLOAD:');
  stdout.writeln(payload);
}
