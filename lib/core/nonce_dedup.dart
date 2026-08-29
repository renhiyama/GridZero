/// Sliding-window LRU cache holding the last [capacity] seen frame nonces.
///
/// Per FR-1.4 the mesh must reject looping packets; a fixed-size LRU of the
/// last 500 (sender, seq) pairs bounds memory while flooding the network.
library;

import 'dart:collection';

class NonceDeduplicator {
  NonceDeduplicator({this.capacity = 2048});

  final int capacity;
  final LinkedHashMap<int, bool> _seen = LinkedHashMap();

  bool isDuplicate(int key) => _seen.containsKey(key);

  /// Marks [key] seen. Returns true when the key was newly inserted.
  bool insert(int key) {
    if (_seen.containsKey(key)) {
      return false;
    }
    _seen[key] = true;
    if (_seen.length > capacity) {
      _seen.remove(_seen.keys.first);
    }
    return true;
  }

  void clear() => _seen.clear();

  int get length => _seen.length;
}
