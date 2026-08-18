/// Ledger domain model and store interface.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Shared genesis anchor so every chain starts from the same root hash.
final String genesisHash =
    sha256.convert(utf8.encode('AapadSetu-Genesis-Anchored')).toString();

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

  /// 0: Local Only, 1: Mesh Synced, 2: Cloud Synced.
  final int syncStatus;

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

/// Persistence contract used by both the SQLite and in-memory backends.
abstract class LedgerStore {
  Future<void> close();

  Future<String> lastHash();

  Future<List<LedgerRecord>> allRecords();

  Future<int> recordsCount();

  /// Persists a claim after validation; rejects duplicates within the same
  /// UTC day (FR-3.4) and any hash-chain break.
  Future<ClaimResult> append(LedgerRecord record);

  Future<void> upsertNode({
    required int nodeId,
    double? latitude,
    double? longitude,
    int? severity,
  });

  Future<List<Map<String, Object?>>> knownNodes();
}
