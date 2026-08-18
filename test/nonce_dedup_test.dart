import 'package:aapadsetu/core/nonce_dedup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('insert returns true only on first sight of a nonce', () {
    final dedup = NonceDeduplicator(capacity: 500);
    expect(dedup.insert(1), isTrue);
    expect(dedup.insert(1), isFalse);
    expect(dedup.isDuplicate(1), isTrue);
    expect(dedup.isDuplicate(2), isFalse);
  });

  test('LRU evicts oldest nonce beyond capacity', () {
    final dedup = NonceDeduplicator(capacity: 3);
    dedup.insert(1);
    dedup.insert(2);
    dedup.insert(3);
    expect(dedup.length, 3);

    dedup.insert(4); // evicts 1
    expect(dedup.isDuplicate(1), isFalse);
    expect(dedup.isDuplicate(4), isTrue);
    expect(dedup.length, 3);
  });

  test('reinserting evicted key is accepted again', () {
    final dedup = NonceDeduplicator(capacity: 2);
    dedup.insert(1);
    dedup.insert(2);
    dedup.insert(3); // evicts 1
    expect(dedup.insert(1), isTrue);
  });
}
