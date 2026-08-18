/// CRC-8 with polynomial x^8 + x^2 + x + 1 (0x07), init 0, no reflection.
///
/// Used to guard the 18-byte AapadSetu BLE mesh frame. Kept table-less so the
/// primitive is trivial to audit and constant-time on the wire.
library;

const int _crc8Poly = 0x07;

int crc8(List<int> data) {
  int crc = 0;
  for (final byte in data) {
    crc ^= byte & 0xff;
    for (int i = 0; i < 8; i++) {
      if ((crc & 0x80) != 0) {
        crc = ((crc << 1) ^ _crc8Poly) & 0xff;
      } else {
        crc = (crc << 1) & 0xff;
      }
    }
  }
  return crc;
}
