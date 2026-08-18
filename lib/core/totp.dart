/// TOTP-HMAC-SHA256 dynamic ration token per FR-2.1 / FR-2.2.
///
///   Token = HMAC-SHA256(K_citizen, T_window || CitizenID)
///
/// where T_window = floor(EpochSeconds / 30). Tokens auto-expire after the
/// 30-second window, so static prints or screenshots cannot be replayed.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int totpWindowSeconds = 30;
const int totpToleranceWindows = 1;

int totpTimeWindow(DateTime now) =>
    now.millisecondsSinceEpoch ~/ 1000 ~/ totpWindowSeconds;

/// Full-length token as 16 hex chars (first 8 bytes of the HMAC).
String totpToken({
  required String citizenId,
  required List<int> citizenKey,
  required int timeWindow,
}) {
  final key = Uint8List.fromList(citizenKey);
  final window = ByteData(8);
  window.setInt64(0, timeWindow, Endian.big);
  final hmac = Hmac(sha256, key);
  final digest = hmac.convert(
    Uint8List.fromList([
      ...window.buffer.asUint8List(),
      ...utf8.encode(citizenId),
    ]),
  );
  return digest.toString().substring(0, 32);
}

bool totpVerify({
  required String citizenId,
  required List<int> citizenKey,
  required String claimedToken,
  required DateTime now,
}) {
  final window = totpTimeWindow(now);
  for (
    var w = window - totpToleranceWindows;
    w <= window + totpToleranceWindows;
    w++
  ) {
    if (totpToken(
          citizenId: citizenId,
          citizenKey: citizenKey,
          timeWindow: w,
        ) ==
        claimedToken) {
      return true;
    }
  }
  return false;
}
