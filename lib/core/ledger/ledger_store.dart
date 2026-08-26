/// Ledger domain model and store interface.
library;

import 'dart:convert';
import 'dart:typed_data';

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
    this.signature,
    this.signerPublic,
    this.claimUnits = 1.0,
    this.familyId,
  });

  final String recordId;
  final String citizenId;
  final String rationCode;
  final int claimedAt;
  final String officerId;

  /// Ration entitlement consumed by this claim, in fraction units
  /// (0.25–1.0). An individual claim is 1.0; a family member may take a
  /// partial share so a household card stretches across members.
  final double claimUnits;

  /// Family ration card (Tier-2 identity) this claim drew against; null for
  /// individual-only claims. The daily cap is enforced per card.
  final String? familyId;

  /// Chain anchors. [prevHash] links to the previous record; [currentHash]
  /// is SHA256(recordData || prevHash). Made mutable so builders can compute
  /// them after construction.
  String prevHash;
  String currentHash;

  /// 0: Local Only, 1: Mesh Synced, 2: Cloud Synced. Mutable so the store can
  /// flag records as shipped after they leave on the mesh.
  int syncStatus;

  /// Officer ECDSA-P256 signature over [recordData] (64 bytes r||s) and the
  /// issuer's 65-byte uncompressed public key. Non-repudiation anchor for HQ
  /// audit; sync does not broadcast these, only the sender's own chain holds
  /// them. Mutable so the claim builder can attach them after hashing.
  List<int>? signature;
  List<int>? signerPublic;

  /// Canonical record data used to build the chain hash and sign.
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
    'signature': signature,
    'signer_public': signerPublic,
    'claim_units': claimUnits,
    'family_id': familyId,
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
    signature: map['signature'] as List<int>?,
    signerPublic: map['signer_public'] as List<int>?,
    claimUnits: (map['claim_units'] as num?)?.toDouble() ?? 1.0,
    familyId: map['family_id'] as String?,
  );
}

enum ClaimStatus {
  granted,
  duplicate,
  invalidToken,
  chainMismatch,
  revoked,
  familyUnknown,
  notFamilyMember,
  familyExhausted,
  pinMismatch,
  error,
}

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

/// A card flagged stolen/suspended/cleared on the mesh.
class RevocationEntry {
  RevocationEntry({
    required this.citizenId,
    required this.reasonCode,
    required this.issuedAt,
    required this.sourceNode,
  });

  final String citizenId;
  final int reasonCode;
  final int issuedAt;
  final int sourceNode;
}

/// Tier-2 identity: a household ration card grouping several citizen
/// identities under one daily entitlement. Provisioned offline by HQ via a
/// signed family enlistment QR and cached in every terminal that needs it.
class FamilyCard {
  FamilyCard({
    required this.familyId,
    required this.rationCode,
    required this.dailyUnits,
    required this.memberCitizenIds,
  });

  final String familyId;
  final String rationCode;

  /// Total ration units the household may draw per UTC day; members share
  /// it via fractional claims.
  final double dailyUnits;

  /// Citizen identities entitled to draw against this card.
  final List<String> memberCitizenIds;

  Map<String, Object?> toMap() => {
    'family_id': familyId,
    'ration_code': rationCode,
    'daily_units': dailyUnits,
    'member_ids': jsonEncode(memberCitizenIds),
  };

  factory FamilyCard.fromMap(Map<String, Object?> map) => FamilyCard(
    familyId: map['family_id'] as String,
    rationCode: map['ration_code'] as String,
    dailyUnits: (map['daily_units'] as num).toDouble(),
    memberCitizenIds: (jsonDecode(map['member_ids'] as String) as List)
        .cast<String>(),
  );
}

/// A registered officer identity: public signing key plus when and through
/// which channel they enlisted. Public keys only: private signing material
/// never enters this directory. At-rest encryption of the directory is a
/// planned follow-up; public keys are not secret, so plaintext today.
class OfficerRecord {
  OfficerRecord({
    required this.officerId,
    required this.publicKey,
    required this.enlistedAt,
    this.registeredBy,
  });

  final String officerId;

  /// Base64 of the 65-byte uncompressed P-256 public key.
  final String publicKey;

  /// Unix seconds when the officer was enrolled.
  final int enlistedAt;

  /// Enlistment channel: 'REGISTER' (local account) or 'OFF-PROVISION'
  /// (HQ-issued provisioning QR).
  final String? registeredBy;

  Map<String, Object?> toMap() => {
    'officer_id': officerId,
    'signer_public': publicKey,
    'enlisted_at': enlistedAt,
    'registered_by': registeredBy,
  };

  static OfficerRecord fromMap(Map<String, Object?> map) => OfficerRecord(
    officerId: map['officer_id'] as String,
    publicKey: map['signer_public'] as String,
    enlistedAt: (map['enlisted_at'] as num).toInt(),
    registeredBy: map['registered_by'] as String?,
  );
}

/// A verified officer-signed point of interest, persisted so restarts and
/// rebroadcasts never duplicate or lose entries. Primary key: officer+label.
class LandmarkRecord {
  LandmarkRecord({
    required this.officerId,
    required this.label,
    required this.typeCode,
    required this.latitude,
    required this.longitude,
    required this.expiresAt,
  });

  final String officerId;
  final String label;
  final int typeCode;
  final double latitude;
  final double longitude;
  final int expiresAt; // unix seconds

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;

  Map<String, Object?> toMap() => {
        'officer_id': officerId,
        'label': label,
        'type_code': typeCode,
        'lat': latitude,
        'lon': longitude,
        'expires_at': expiresAt,
      };

  static LandmarkRecord fromMap(Map<String, Object?> m) => LandmarkRecord(
        officerId: m['officer_id'] as String,
        label: m['label'] as String,
        typeCode: (m['type_code'] as num).toInt(),
        latitude: (m['lat'] as num).toDouble(),
        longitude: (m['lon'] as num).toDouble(),
        expiresAt: (m['expires_at'] as num).toInt(),
      );
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

  /// Revocation state (FR: stolen-card blacklist). Upsert by citizen id;
  /// reason kRevokeCleared removes the flag.
  Future<void> upsertRevocation(RevocationEntry entry);

  Future<void> clearRevocation(String citizenId);

  Future<List<RevocationEntry>> revocations();

  /// Officer signing keypair for block signatures. Returns
  /// ([publicKey], [privateKey]) or null when the officer has no key yet.
  Future<(List<int>, List<int>)?> officerKey(String officerId);

  Future<void> saveOfficerKey(
    String officerId,
    List<int> publicKey,
    List<int> privateKey,
  );

  /// Enrolment directory: records an officer identity (public key only).
  Future<void> upsertOfficer(OfficerRecord officer);

  /// Insert-or-replace by (officer_id, label): rebroadcasts of a landmark
  /// already stored refresh it instead of duplicating.
  Future<void> upsertLandmark(LandmarkRecord landmark);

  /// All stored landmarks, including expired ones (callers filter).
  Future<List<LandmarkRecord>> landmarks();

  /// Every locally registered officer, newest first.
  Future<List<OfficerRecord>> officers();

  /// Tier-2 family ration cards (Schema v3): provisioned by HQ, verified by
  /// any terminal that holds the card, capped by [familyUsedUnits].
  Future<void> upsertFamilyCard(FamilyCard card);

  Future<FamilyCard?> familyCard(String familyId);

  Future<List<FamilyCard>> familyCards();

  /// Total units already drawn against a card in the given UTC day (epoch
  /// seconds at day start), summed over local and mesh-synced claims.
  Future<double> familyUsedUnits(String familyId, int dayStartEpoch);

  /// Face embedding captured at enrolment, keyed by citizen id. Stored as raw
  /// L2-normalized float bytes; embeddings are biometric data and never leave
  /// the device.
  Future<void> saveFaceEmbedding(String citizenId, Float32List embedding);

  Future<Float32List?> faceEmbedding(String citizenId);

  /// Full DB snapshot as a JSON string, for the officer/hotspot DB sync
  /// channel. Includes records, family cards, revocations, the officer
  /// registry and face embeddings so a freshly synced phone is a true clone.
  Future<String> exportSnapshot();

  /// Replaces nothing: merges a snapshot produced by [exportSnapshot] into
  /// this store. Records are absorbed via [mergeRecord] so the local chain is
  /// never rewritten; reference rows are upserted. Returns an error string on
  /// malformed input, else null.
  Future<String?> importSnapshot(String json);
}
