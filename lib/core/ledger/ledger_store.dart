/// Ledger domain model and store interface.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Shared genesis anchor so every chain starts from the same root hash.
final String genesisHash = sha256
    .convert(utf8.encode('GridZero-Genesis-Anchored'))
    .toString();

class LedgerRecord {
  LedgerRecord({
    required this.recordId,
    required this.citizenId,
    required this.rationCode,
    required this.claimedAt,
    required this.officerId,
    required this.prevHash,
    required this.currentHash,
    this.syncStatus = 0,
  });

  final String recordId;
  final String citizenId;
  final String rationCode;
  final int claimedAt;
  final String officerId;

  /// Chain anchors. [prevHash] links to the previous record; [currentHash]
  /// is SHA256(recordData || prevHash). Made mutable so builders can compute
  /// them after construction.
  String prevHash;
  String currentHash;

  /// 0: Local Only, 1: Mesh Synced, 2: Cloud Synced. Mutable so the store can
  /// flag records as shipped after they leave on the mesh.
  int syncStatus;

  /// Canonical record data used to build the chain hash.
  String recordData() =>
      '$recordId|$citizenId|$rationCode|$claimedAt|$officerId';

  String computeCurrentHash() =>
      sha256.convert(utf8.encode('${recordData()}$prevHash')).toString();

  Map<String, Object?> toMap() => {
    'record_id': recordId,
    'citizen_id': citizenId,
    'ration_code': rationCode,
    'claimed_at': claimedAt,
    'officer_id': officerId,
    'prev_hash': prevHash,
    'current_hash': currentHash,
    'sync_status': syncStatus,
  };

  factory LedgerRecord.fromMap(Map<String, Object?> map) => LedgerRecord(
    recordId: map['record_id'] as String,
    citizenId: map['citizen_id'] as String,
    rationCode: map['ration_code'] as String,
    claimedAt: map['claimed_at'] as int,
    officerId: map['officer_id'] as String,
    prevHash: map['prev_hash'] as String,
    currentHash: map['current_hash'] as String,
    syncStatus: map['sync_status'] as int? ?? 0,
  );
}

enum ClaimStatus { granted, duplicate, invalidToken, chainMismatch, error }

class ClaimResult {
  ClaimResult(this.status, {this.message = '', this.record});

  final ClaimStatus status;
  final String message;
  final LedgerRecord? record;

  bool get ok => status == ClaimStatus.granted;
}

enum SyncStatus { merged, duplicate }

class SyncResult {
  const SyncResult(this.status, {this.message = ''});

  final SyncStatus status;
  final String message;

  bool get ok => status == SyncStatus.merged;
}

/// Persistence contract used by both the SQLite and in-memory backends.
abstract class LedgerStore {
  Future<void> close();

  Future<String> lastHash();

  Future<List<LedgerRecord>> allRecords();

  Future<int> recordsCount();

  /// Persists a claim after validation; rejects duplicates within the same
  /// UTC day (FR-3.4) and any hash-chain break.
  Future<ClaimResult> append(LedgerRecord record);

  /// Records not yet shipped onto the mesh (sync_status == 0).
  Future<List<LedgerRecord>> pendingRecords();

  /// Marks shipped records as mesh-synced (sync_status = 1).
  Future<void> markSynced(List<String> recordIds);

  /// How many records this node has absorbed from other devices' chains
  /// (store-and-forward ledger sync).
  Future<int> syncRecordsCount();

  /// Merges a record received over the mesh into the aggregated store.
  /// Rejects exact duplicates (same record_id) and cross-officer double
  /// claims within a UTC day (same citizen + ration).
  Future<SyncResult> mergeRecord({
    required LedgerRecord record,
    required int receivedFrom,
  });

  /// Destructive: discards every stored record. Used by "Delete All Data".
  Future<void> wipe();

  Future<void> upsertNode({
    required int nodeId,
    double? latitude,
    double? longitude,
    int? severity,
  });

  Future<List<Map<String, Object?>>> knownNodes();
}
