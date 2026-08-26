/// In-memory ledger backend for tests. Enforces the same
/// daily-duplicate and hash-chain rules as the SQLite backend.
library;

import 'dart:typed_data';
import 'dart:convert';

import 'ledger_store.dart';

class MemoryLedgerStore implements LedgerStore {
  final List<LedgerRecord> _records = [];
  final List<LedgerRecord> _syncRecords = [];
  final Map<int, Map<String, Object?>> _nodes = {};
  final Map<String, RevocationEntry> _revocations = {};
  final Map<String, (List<int>, List<int>)> _officerKeys = {};
  final Map<String, LandmarkRecord> _landmarks = {};
  final Map<String, FamilyCard> _familyCards = {};
  final Map<String, OfficerRecord> _officers = {};
  final Map<String, Float32List> _faceEmbeddings = {};

  @override
  Future<void> close() async {}

  @override
  Future<void> wipe() async {
    _records.clear();
    _syncRecords.clear();
    _nodes.clear();
    _revocations.clear();
    _officerKeys.clear();
    _familyCards.clear();
    _officers.clear();
    _faceEmbeddings.clear();
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

  @override
  Future<void> upsertOfficer(OfficerRecord officer) async {
    _officers[officer.officerId] = officer;
  }

  @override
  Future<List<OfficerRecord>> officers() async {
    final records = _officers.values.toList()
      ..sort((a, b) => b.enlistedAt.compareTo(a.enlistedAt));
    return records;
  }

  @override
  Future<void> upsertLandmark(LandmarkRecord landmark) async {
    _landmarks['${landmark.officerId}/${landmark.label}'] = landmark;
  }

  @override
  Future<List<LandmarkRecord>> landmarks() async =>
      _landmarks.values.toList();


  @override
  Future<void> upsertFamilyCard(FamilyCard card) async {
    _familyCards[card.familyId] = card;
  }

  @override
  Future<FamilyCard?> familyCard(String familyId) async =>
      _familyCards[familyId];

  @override
  Future<List<FamilyCard>> familyCards() async => _familyCards.values.toList();

  @override
  Future<double> familyUsedUnits(String familyId, int dayStartEpoch) async {
    final day = dayStartEpoch ~/ 86400;
    double used = 0;
    for (final r in _records) {
      if (r.familyId == familyId && r.claimedAt ~/ 86400 == day) {
        used += r.claimUnits;
      }
    }
    for (final r in _syncRecords) {
      if (r.familyId == familyId && r.claimedAt ~/ 86400 == day) {
        used += r.claimUnits;
      }
    }
    return used;
  }

  @override
  Future<void> saveFaceEmbedding(String citizenId, Float32List embedding) async {
    _faceEmbeddings[citizenId] = Float32List.fromList(embedding);
  }

  @override
  Future<Float32List?> faceEmbedding(String citizenId) async =>
      _faceEmbeddings[citizenId];

  @override
  Future<String> exportSnapshot() async {
    final embEntries = [
      for (final e in _faceEmbeddings.entries)
        {
          'citizen_id': e.key,
          'embedding': base64Encode(
            ByteData.sublistView(e.value).buffer.asUint8List(),
          ),
        },
    ];
    return jsonEncode({
      'v': 1,
      'records': [for (final r in _records) r.toMap()],
      'revocations': [
        for (final e in _revocations.values)
          {
            'citizen_id': e.citizenId,
            'reason_code': e.reasonCode,
            'issued_at': e.issuedAt,
            'source_node': e.sourceNode,
          },
      ],
      'officers': [for (final o in _officers.values) o.toMap()],
      'family_cards': [for (final c in _familyCards.values) c.toMap()],
      'face_embeddings': embEntries,
    });
  }

  @override
  Future<String?> importSnapshot(String json) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return 'malformed DB snapshot';
    }
    if (decoded is! Map<String, Object?>) return 'malformed DB snapshot';
    if (decoded['v'] != 1) return 'unsupported snapshot version';
    try {
      for (final raw in (decoded['records'] as List?) ?? const []) {
        if (raw is! Map) throw const FormatException('bad record');
        final record = LedgerRecord.fromMap(raw.cast<String, Object?>());
        if (!_syncRecords.any((r) => r.recordId == record.recordId)) {
          _syncRecords.add(record);
        }
      }
      for (final raw in (decoded['family_cards'] as List?) ?? const []) {
        if (raw is! Map) throw const FormatException('bad family card');
        final card = FamilyCard.fromMap(raw.cast<String, Object?>());
        _familyCards[card.familyId] = card;
      }
      for (final raw in (decoded['revocations'] as List?) ?? const []) {
        if (raw is! Map) throw const FormatException('bad revocation');
        final e = RevocationEntry(
          citizenId: raw['citizen_id'] as String,
          reasonCode: raw['reason_code'] as int,
          issuedAt: raw['issued_at'] as int,
          sourceNode: raw['source_node'] as int,
        );
        _revocations[e.citizenId] = e;
      }
      for (final raw in (decoded['officers'] as List?) ?? const []) {
        if (raw is! Map) throw const FormatException('bad officer');
        final o = OfficerRecord.fromMap(raw.cast<String, Object?>());
        _officers[o.officerId] = o;
      }
      for (final raw in (decoded['face_embeddings'] as List?) ?? const []) {
        if (raw is! Map) throw const FormatException('bad embedding');
        final bytes = base64Decode(raw['embedding'] as String);
        _faceEmbeddings[raw['citizen_id'] as String] =
            Float32List.sublistView(ByteData.sublistView(bytes));
      }
      return null;
    } on Exception catch (e) {
      return 'snapshot import failed: $e';
    }
  }
}
