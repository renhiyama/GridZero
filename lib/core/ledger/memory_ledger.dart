/// In-memory ledger backend for web builds and tests. Enforces the same
/// daily-duplicate and hash-chain rules as the SQLite backend.
library;

import 'ledger_store.dart';

class MemoryLedgerStore implements LedgerStore {
  final List<LedgerRecord> _records = [];
  final Map<int, Map<String, Object?>> _nodes = {};

  @override
  Future<void> close() async {}

  @override
  Future<String> lastHash() async =>
      _records.isEmpty ? genesisHash : _records.last.currentHash;

  @override
  Future<List<LedgerRecord>> allRecords() async =>
      List.unmodifiable(_records.reversed);

  @override
  Future<int> recordsCount() async => _records.length;

  @override
  Future<ClaimResult> append(LedgerRecord record) async {
    final expectedPrev = await lastHash();
    if (record.prevHash != expectedPrev) {
      return ClaimResult(
        ClaimStatus.chainMismatch,
        message: 'chain broken: record prev_hash != stored last hash',
      );
    }
    final day = record.claimedAt ~/ 86400;
    final dup = _records.any(
      (r) =>
          r.citizenId == record.citizenId &&
          r.rationCode == record.rationCode &&
          r.claimedAt ~/ 86400 == day,
    );
    if (dup) {
      return ClaimResult(
        ClaimStatus.duplicate,
        message:
            'citizen ${record.citizenId} already claimed '
            '${record.rationCode} within 24h window',
      );
    }
    _records.add(record);
    return ClaimResult(ClaimStatus.granted, record: record);
  }

  @override
  Future<void> upsertNode({
    required int nodeId,
    double? latitude,
    double? longitude,
    int? severity,
  }) async {
    _nodes[nodeId] = {
      'node_id': nodeId,
      'last_latitude': latitude,
      'last_longitude': longitude,
      'triage_severity': severity,
      'last_seen_epoch': DateTime.now().millisecondsSinceEpoch,
    };
  }

  @override
  Future<List<Map<String, Object?>>> knownNodes() async =>
      _nodes.values.toList();
}
