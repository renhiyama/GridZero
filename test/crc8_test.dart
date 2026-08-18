import 'package:aapadsetu/core/crc8.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CRC8 known vector matches x^8+x^2+x+1 (0x07)', () {
    expect(crc8([0x00]), 0);
    expect(crc8([0x01]), 0x07);
    // standard check value for poly 0x07, init 0, no reflection
    expect(crc8([0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39]), 0xf4);
  });
}