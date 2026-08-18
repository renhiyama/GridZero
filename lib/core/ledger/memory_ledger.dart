/// In-memory ledger backend for tests. Enforces the same
/// daily-duplicate and hash-chain rules as the SQLite backend.
library;

import 'ledger_store.dart';

class MemoryLedgerStore implements LedgerStore {
  final List<LedgerRecord> _records = [];
  final List<LedgerRecord> _syncRecords = [];
  final Map<int, Map<String, Object?>> _nodes = {};
  final Map<String, RevocationEntry> _revocations = {};
  final Map<String, (List<int>, List<int>)> _officerKeys = {};

  @override
  Future<void> close() async {}

  @override
  Future<void> wipe() async {
    _records.clear();
    _syncRecords.clear();
    _nodes.clear();
    _revocations.clear();
    _officerKeys.clear();
  }

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
  Future<List<LedgerRecord>> pendingRecords() async =>
      _records.where((r) => r.syncStatus == 0).toList();

  @override
  Future<void> markSynced(List<String> recordIds) async {
    for (final id in recordIds) {
      for (final r in _records) {
        if (r.recordId == id) r.syncStatus = 1;
      }
    }
  }

  @override
  Future<int> syncRecordsCount() async => _syncRecords.length;

  @override
  Future<SyncResult> mergeRecord({
    required LedgerRecord record,
    required int receivedFrom,
  }) async {
    if (_syncRecords.any((r) => r.recordId == record.recordId)) {
      return const SyncResult(SyncStatus.duplicate);
    }
    final day = record.claimedAt ~/ 86400;
    final dup = _syncRecords.any(
      (r) =>
          r.citizenId == record.citizenId &&
          r.rationCode == record.rationCode &&
          r.claimedAt ~/ 86400 == day,
    );
    if (dup) return const SyncResult(SyncStatus.duplicate);
    _syncRecords.add(record);
    return SyncResult(SyncStatus.merged);
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

  @override
  Future<void> upsertRevocation(RevocationEntry entry) async {
    _revocations[entry.citizenId] = entry;
  }

  @override
  Future<void> clearRevocation(String citizenId) async {
    _revocations.remove(citizenId);
  }

  @override
  Future<List<RevocationEntry>> revocations() async {
    final entries = _revocations.values.toList()
      ..sort((a, b) => b.issuedAt.compareTo(a.issuedAt));
    return entries;
  }

  @override
  Future<(List<int>, List<int>)?> officerKey(String officerId) async =>
      _officerKeys[officerId];

  @override
  Future<void> saveOfficerKey(
    String officerId,
    List<int> publicKey,
    List<int> privateKey,
  ) async {
    _officerKeys[officerId] = (publicKey, privateKey);
  }
}
