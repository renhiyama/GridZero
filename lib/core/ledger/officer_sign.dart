/// Officer block signing for the relief ledger (FEAT-LEDG-03 / step 2).
///
/// pointycastle ships no Ed25519, so officer signatures use ECDSA-P256
/// (prime256v1) with SHA-256 and deterministic RFC-6979 k — no RNG on the
/// signing path, and the same 64-byte signature format everywhere.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/random/fortuna_random.dart';

/// NIST P-256 domain name used across generate/sign/verify.
const String kOfficerCurve = 'prime256v1';

/// Generates a fresh officer signing keypair.
/// Returns ([publicKey], [privateKey]); public is 65 bytes (uncompressed
/// point), private is the 32-byte scalar d.
(List<int> publicKey, List<int> privateKey) generateOfficerKey() {
  final params = ECDomainParameters(kOfficerCurve);
  final gen = KeyGenerator('EC');
  gen.init(
    ParametersWithRandom(ECKeyGeneratorParameters(params), _seededRandom()),
  );
  final pair = gen.generateKeyPair();
  final pub = pair.publicKey as ECPublicKey;
  final priv = pair.privateKey as ECPrivateKey;
  return (pub.Q!.getEncoded(false).toList(), _bigIntToBytes(priv.d!, 32));
}

/// Signs the record payload with the officer's private key (RFC-6979).
/// Returns a 64-byte (r || s) signature.
List<int> signOfficerRecord(List<int> privateKey, String recordData) {
  final priv = ECPrivateKey(
    _bytesToBigInt(privateKey),
    ECDomainParameters(kOfficerCurve),
  );
  final signer = Signer('SHA-256/DET-ECDSA');
  signer.init(true, PrivateKeyParameter(priv));
  final sig = signer.generateSignature(
    Uint8List.fromList(utf8.encode(recordData)),
  ) as ECSignature;
  return [..._bigIntToBytes(sig.r, 32), ..._bigIntToBytes(sig.s, 32)];
}

/// Verifies a record signature against the officer's public key. Returns
/// false on malformed keys, bad signatures, or curve mismatch.
bool verifyOfficerRecord(
  List<int> publicKey,
  String recordData,
  List<int> signature,
) {
  if (signature.length != 64) return false;
  final params = ECDomainParameters(kOfficerCurve);
  final q = params.curve.decodePoint(Uint8List.fromList(publicKey));
  if (q == null) return false;
  final verifier = Signer('SHA-256/DET-ECDSA');
  verifier.init(false, PublicKeyParameter(ECPublicKey(q, params)));
  final sig = ECSignature(
    _bytesToBigInt(signature.sublist(0, 32)),
    _bytesToBigInt(signature.sublist(32, 64)),
  );
  return verifier.verifySignature(
    Uint8List.fromList(utf8.encode(recordData)),
    sig,
  );
}

BigInt _bytesToBigInt(List<int> b) => BigInt.parse(
  b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(),
  radix: 16,
);

List<int> _bigIntToBytes(BigInt v, int len) {
  final hex = v.toRadixString(16).padLeft(len * 2, '0');
  return [
    for (var i = 0; i < len; i++)
      int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  ];
}

/// Fortuna PRNG seeded from the platform CSPRNG for key generation only.
SecureRandom _seededRandom() {
  final rng = FortunaRandom();
  final rand = Random.secure();
  rng.seed(
    KeyParameter(
      Uint8List.fromList([for (var i = 0; i < 32; i++) rand.nextInt(256)]),
    ),
  );
  return rng;
}
