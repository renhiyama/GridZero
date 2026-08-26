/// SQLite hash-chain ledger backend (FR-3). Schema mirrors docs/REQ.md 2.2.
library;

import 'dart:typed_data';
import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ledger_store.dart';

const String kLedgerSchema = '''
CREATE TABLE IF NOT EXISTS ledger_records (
    record_id TEXT PRIMARY KEY,
    citizen_id TEXT NOT NULL,
    ration_code TEXT NOT NULL,
    claimed_at INTEGER NOT NULL,
    officer_id TEXT NOT NULL,
    prev_hash TEXT NOT NULL,
    current_hash TEXT NOT NULL,
    sync_status INTEGER DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_citizen_daily_claim
ON ledger_records (citizen_id, ration_code, (claimed_at / 86400));
CREATE TABLE IF NOT EXISTS known_mesh_nodes (
    node_id INTEGER PRIMARY KEY,
    last_latitude REAL,
    last_longitude REAL,
    triage_severity INTEGER,
    last_seen_epoch INTEGER
);

-- Records absorbed from other devices' chains via mesh sync (FR-3.5).
-- Original hashes are kept verbatim so a foreign chain stays auditable;
-- the local chain is never rewritten.
CREATE TABLE IF NOT EXISTS sync_records (
    record_id TEXT PRIMARY KEY,
    citizen_id TEXT NOT NULL,
    ration_code TEXT NOT NULL,
    claimed_at INTEGER NOT NULL,
    officer_id TEXT NOT NULL,
    received_from INTEGER NOT NULL,
    received_at INTEGER NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_daily_claim
ON sync_records (citizen_id, ration_code, (claimed_at / 86400));
''';

/// v3 additions: officer block signatures, revocation blacklist, officer
/// signing keys. Applied on upgrade; existing v1/v2 DBs keep their rows.
const String kLedgerSchemaV3 = '''
ALTER TABLE ledger_records ADD COLUMN signature BLOB;
ALTER TABLE ledger_records ADD COLUMN signer_public BLOB;
CREATE TABLE IF NOT EXISTS revocations (
    citizen_id TEXT PRIMARY KEY,
    reason_code INTEGER NOT NULL,
    issued_at INTEGER NOT NULL,
    source_node INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS officer_keys (
    officer_id TEXT PRIMARY KEY,
    signer_public BLOB NOT NULL,
    signer_private BLOB NOT NULL
);
''';

/// v4 additions: Tier-2 family ration cards and fractional claims. Both
/// claim tables gain the card link + units; existing rows default to 1.0
/// individual claims.
const String kLedgerSchemaV4 = '''
ALTER TABLE ledger_records ADD COLUMN claim_units REAL NOT NULL DEFAULT 1.0;
ALTER TABLE ledger_records ADD COLUMN family_id TEXT;
ALTER TABLE sync_records ADD COLUMN claim_units REAL NOT NULL DEFAULT 1.0;
ALTER TABLE sync_records ADD COLUMN family_id TEXT;
CREATE TABLE IF NOT EXISTS family_cards (
    family_id TEXT PRIMARY KEY,
    ration_code TEXT NOT NULL,
    daily_units REAL NOT NULL,
    member_ids TEXT NOT NULL
);
''';

/// v5 additions: officer enrolment directory. Public signing keys only; the
/// private half stays in `officer_keys`. At-rest encryption is planned.
const String kLedgerSchemaV5 = '''
CREATE TABLE IF NOT EXISTS officer_registry (
    officer_id TEXT PRIMARY KEY,
    signer_public TEXT NOT NULL,
    enlisted_at INTEGER NOT NULL,
    registered_by TEXT
);
        CREATE TABLE IF NOT EXISTS landmarks (
          officer_id TEXT NOT NULL,
          label TEXT NOT NULL,
          type_code INTEGER NOT NULL,
          lat REAL NOT NULL,
          lon REAL NOT NULL,
          expires_at INTEGER NOT NULL,
          PRIMARY KEY (officer_id, label)
        );
''';

/// v6 addition: per-citizen face embeddings from enrolment. Stored as raw
/// L2-normalized float32 bytes; local-only biometric data.
const String kLedgerSchemaV6 = '''
CREATE TABLE IF NOT EXISTS face_embeddings (
    citizen_id TEXT PRIMARY KEY,
    embedding BLOB NOT NULL,
    enrolled_at INTEGER NOT NULL
);
''';

class SqliteLedgerStore implements LedgerStore {
  SqliteLedgerStore(this._db, this._path);

  final Database _db;
  final String _path;

  static Future<LedgerStore> open(DatabaseFactory factory, String path) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: (db, _) async {
          await db.execute(kLedgerSchema);
          await _applyV3(db);
          await _applyV4(db);
          await _applyV5(db);
          await _applyV6(db);
        },
        // v1 DBs predate sync_records; CREATE IF NOT EXISTS upgrades in place.
        // v2->v3 adds signatures + revocation tables; v3->v4 adds families;
        // v4->v5 adds the officer directory; v5->v6 adds face embeddings.
        onUpgrade: (db, oldVersion, _) async {
          await db.execute(kLedgerSchema);
          if (oldVersion < 3) await _applyV3(db);
          if (oldVersion < 4) await _applyV4(db);
          if (oldVersion < 5) await _applyV5(db);
          if (oldVersion < 6) await _applyV6(db);
        },
      ),
    );
    return SqliteLedgerStore(db, path);
  }

  /// v3 migration: ALTERs fail if the columns already exist (fresh v3 build
  /// runs this through onCreate too), so each statement is best-effort.
  static Future<void> _applyV3(Database db) async {
    final statements = kLedgerSchemaV3.split(';');
    for (final stmt in statements) {
      final trimmed = stmt.trim();
      if (trimmed.isEmpty) continue;
      try {
        await db.execute(trimmed);
      } on Exception {
        // column already present, or table exists: nothing to migrate.
      }
    }
  }

  /// v4 migration, same best-effort semantics as [_applyV3].
  static Future<void> _applyV4(Database db) async {
    final statements = kLedgerSchemaV4.split(';');
    for (final stmt in statements) {
      final trimmed = stmt.trim();
      if (trimmed.isEmpty) continue;
      try {
        await db.execute(trimmed);
      } on Exception {
        // column already present, or table exists: nothing to migrate.
      }
    }
  }

  /// v5 migration, same best-effort semantics.
  static Future<void> _applyV5(Database db) async {
    final statements = kLedgerSchemaV5.split(';');
    for (final stmt in statements) {
      final trimmed = stmt.trim();
      if (trimmed.isEmpty) continue;
      try {
        await db.execute(trimmed);
      } on Exception {
        // table already present: nothing to migrate.
      }
    }
  }

  static Future<void> _applyV6(Database db) async {
    final statements = kLedgerSchemaV6.split(';');
    for (final stmt in statements) {
      final trimmed = stmt.trim();
      if (trimmed.isEmpty) continue;
      try {
        await db.execute(trimmed);
      } on Exception {
        // table already present: nothing to migrate.
      }
    }
  }

  @override
  Future<void> close() => _db.close();

  @override
  Future<void> wipe() async {
    await _db.close();
    await databaseFactoryFfi.deleteDatabase(_path);
  }

  @override
  Future<String> lastHash() async {
    final rows = await _db.query(
      'ledger_records',
      columns: ['current_hash'],
      orderBy: 'claimed_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? genesisHash : rows.first['current_hash'] as String;
  }

  @override
  Future<List<LedgerRecord>> allRecords() async {
    final rows = await _db.query('ledger_records', orderBy: 'claimed_at DESC');
    return rows.map(LedgerRecord.fromMap).toList();
  }

  @override
  Future<int> recordsCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM ledger_records');
    return rows.first['c'] as int;
  }

  @override
  Future<List<LedgerRecord>> pendingRecords() async {
    final rows = await _db.query(
      'ledger_records',
      where: 'sync_status = 0',
      orderBy: 'claimed_at ASC',
    );
    return rows.map(LedgerRecord.fromMap).toList();
  }

  @override
  Future<void> markSynced(List<String> recordIds) async {
    if (recordIds.isEmpty) return;
    for (final id in recordIds) {
      await _db.update(
        'ledger_records',
        {'sync_status': 1},
        where: 'record_id = ?',
        whereArgs: [id],
      );
    }
  }

  @override
  Future<int> syncRecordsCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM sync_records');
    return rows.first['c'] as int;
  }

  @override
  Future<SyncResult> mergeRecord({
    required LedgerRecord record,
    required int receivedFrom,
  }) async {
    try {
      final count = await _db.insert('sync_records', {
        'record_id': record.recordId,
        'citizen_id': record.citizenId,
        'ration_code': record.rationCode,
        'claimed_at': record.claimedAt,
        'officer_id': record.officerId,
        'claim_units': record.claimUnits,
        'family_id': record.familyId,
        'received_from': receivedFrom,
        'received_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      if (count == 0) {
        return SyncResult(
          SyncStatus.duplicate,
          message: 'already known or daily double-claim',
        );
      }
      return SyncResult(SyncStatus.merged);
    } on DatabaseException catch (e) {
      return SyncResult(SyncStatus.duplicate, message: e.toString());
    }
  }

  @override
  Future<ClaimResult> append(LedgerRecord record) async {
    final expectedPrev = await lastHash();
    if (record.prevHash != expectedPrev) {
      return ClaimResult(
        ClaimStatus.chainMismatch,
        message: 'chain broken: record prev_hash != stored last hash',
      );
    }
    if (await _hasDailyDuplicate(record)) {
      return ClaimResult(
        ClaimStatus.duplicate,
        message:
            'citizen ${record.citizenId} already claimed '
            '${record.rationCode} within 24h window',
      );
    }
    try {
      await _db.insert(
        'ledger_records',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return ClaimResult(ClaimStatus.granted, record: record);
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        return ClaimResult(
          ClaimStatus.duplicate,
          message:
              'citizen ${record.citizenId} already claimed '
              '${record.rationCode} within 24h window',
        );
      }
      return ClaimResult(ClaimStatus.error, message: e.toString());
    }
  }

  /// FR-3.4 duplicate guard keyed on the UTC day of the claim.
  Future<bool> _hasDailyDuplicate(LedgerRecord record) async {
    final day = record.claimedAt ~/ 86400;
    final rows = await _db.query(
      'ledger_records',
      where: 'citizen_id = ? AND ration_code = ? AND (claimed_at / 86400) = ?',
      whereArgs: [record.citizenId, record.rationCode, day],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> upsertNode({
    required int nodeId,
    double? latitude,
    double? longitude,
    int? severity,
  }) async {
    await _db.insert('known_mesh_nodes', {
      'node_id': nodeId,
      'last_latitude': latitude,
      'last_longitude': longitude,
      'triage_severity': severity,
      'last_seen_epoch': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<Map<String, Object?>>> knownNodes() =>
      _db.query('known_mesh_nodes', orderBy: 'last_seen_epoch DESC');

  @override
  Future<void> upsertRevocation(RevocationEntry entry) async {
    await _db.insert('revocations', {
      'citizen_id': entry.citizenId,
      'reason_code': entry.reasonCode,
      'issued_at': entry.issuedAt,
      'source_node': entry.sourceNode,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> clearRevocation(String citizenId) async {
    await _db.delete(
      'revocations',
      where: 'citizen_id = ?',
      whereArgs: [citizenId],
    );
  }

  @override
  Future<List<RevocationEntry>> revocations() async {
    final rows = await _db.query('revocations', orderBy: 'issued_at DESC');
    return [
      for (final r in rows)
        RevocationEntry(
          citizenId: r['citizen_id'] as String,
          reasonCode: r['reason_code'] as int,
          issuedAt: r['issued_at'] as int,
          sourceNode: r['source_node'] as int,
        ),
    ];
  }

  @override
  Future<(List<int>, List<int>)?> officerKey(String officerId) async {
    final rows = await _db.query(
      'officer_keys',
      where: 'officer_id = ?',
      whereArgs: [officerId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      (row['signer_public'] as List<int>).toList(),
      (row['signer_private'] as List<int>).toList(),
    );
  }

  @override
  Future<void> saveOfficerKey(
    String officerId,
    List<int> publicKey,
    List<int> privateKey,
  ) async {
    // sqflite blob columns require Uint8List, not List<int>.
    await _db.insert('officer_keys', {
      'officer_id': officerId,
      'signer_public': Uint8List.fromList(publicKey),
      'signer_private': Uint8List.fromList(privateKey),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> upsertOfficer(OfficerRecord officer) async {
    await _db.insert(
      'officer_registry',
      officer.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<OfficerRecord>> officers() async {
    final rows = await _db.query(
      'officer_registry',
      orderBy: 'enlisted_at DESC',
    );
    return rows.map(OfficerRecord.fromMap).toList();
  }

  @override
  Future<void> upsertLandmark(LandmarkRecord landmark) async {
    await _db.insert(
      'landmarks',
      landmark.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<LandmarkRecord>> landmarks() async {
    final rows = await _db.query('landmarks');
    return rows.map(LandmarkRecord.fromMap).toList();
  }

  @override
  Future<void> upsertFamilyCard(FamilyCard card) async {
    await _db.insert(
      'family_cards',
      card.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<FamilyCard?> familyCard(String familyId) async {
    final rows = await _db.query(
      'family_cards',
      where: 'family_id = ?',
      whereArgs: [familyId],
      limit: 1,
    );
    return rows.isEmpty ? null : FamilyCard.fromMap(rows.first);
  }

  @override
  Future<List<FamilyCard>> familyCards() async {
    final rows = await _db.query('family_cards');
    return rows.map(FamilyCard.fromMap).toList();
  }

  @override
  Future<double> familyUsedUnits(String familyId, int dayStartEpoch) async {
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(claim_units), 0) AS used FROM ('
      '  SELECT claim_units FROM ledger_records '
      '   WHERE family_id = ? AND claimed_at >= ? AND claimed_at < ?'
      '  UNION ALL '
      '  SELECT claim_units FROM sync_records '
      '   WHERE family_id = ? AND claimed_at >= ? AND claimed_at < ?'
      ')',
      [
        familyId,
        dayStartEpoch,
        dayStartEpoch + 86400,
        familyId,
        dayStartEpoch,
        dayStartEpoch + 86400,
      ],
    );
    return (rows.first['used'] as num).toDouble();
  }

  @override
  Future<void> saveFaceEmbedding(String citizenId, Float32List embedding) async {
    final bytes = ByteData.sublistView(embedding).buffer.asUint8List();
    await _db.insert(
      'face_embeddings',
      {
        'citizen_id': citizenId,
        'embedding': bytes,
        'enrolled_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<Float32List?> faceEmbedding(String citizenId) async {
    final rows = await _db.query(
      'face_embeddings',
      where: 'citizen_id = ?',
      whereArgs: [citizenId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final blob = rows.first['embedding'] as Uint8List?;
    if (blob == null || blob.isEmpty) return null;
    return Float32List.sublistView(ByteData.sublistView(blob));
  }

  @override
  Future<String> exportSnapshot() async {
    final records = await allRecords();
    final revs = await revocations();
    final offs = await officers();
    final fams = await familyCards();
    final embRows = await _db.query('face_embeddings');
    return jsonEncode({
      'v': 1,
      'records': [for (final r in records) r.toMap()],
      'revocations': [
        for (final e in revs)
          {
            'citizen_id': e.citizenId,
            'reason_code': e.reasonCode,
            'issued_at': e.issuedAt,
            'source_node': e.sourceNode,
          },
      ],
      'officers': [for (final o in offs) o.toMap()],
      'family_cards': [for (final c in fams) c.toMap()],
      'face_embeddings': [
        for (final row in embRows)
          {
            'citizen_id': row['citizen_id'],
            'embedding': base64Encode(row['embedding'] as List<int>),
          },
      ],
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
    final records = decoded['records'] as List? ?? const [];
    final familyCards = decoded['family_cards'] as List? ?? const [];
    final revocations = decoded['revocations'] as List? ?? const [];
    final officers = decoded['officers'] as List? ?? const [];
    final faceEmbeddings = decoded['face_embeddings'] as List? ?? const [];
    try {
      await _db.transaction((txn) async {
        for (final raw in records) {
          final m = Map<String, Object?>.from(raw as Map);
          await txn.insert(
            'sync_records',
            {
              'record_id': m['record_id'],
              'citizen_id': m['citizen_id'],
              'ration_code': m['ration_code'],
              'claimed_at': m['claimed_at'],
              'officer_id': m['officer_id'],
              'claim_units': m['claim_units'] ?? 1.0,
              'family_id': m['family_id'],
              'received_from': 0,
              'received_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        for (final raw in familyCards) {
          final m = Map<String, Object?>.from(raw as Map);
          await txn.insert(
            'family_cards',
            {
              'family_id': m['family_id'],
              'ration_code': m['ration_code'],
              'daily_units': m['daily_units'],
              'member_ids': m['member_ids'],
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final raw in revocations) {
          final m = Map<String, Object?>.from(raw as Map);
          await txn.insert(
            'revocations',
            {
              'citizen_id': m['citizen_id'],
              'reason_code': m['reason_code'],
              'issued_at': m['issued_at'],
              'source_node': m['source_node'],
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final raw in officers) {
          final m = Map<String, Object?>.from(raw as Map);
          await txn.insert(
            'officer_registry',
            m,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final raw in faceEmbeddings) {
          final m = Map<String, Object?>.from(raw as Map);
          final citizenId = m['citizen_id'] as String;
          final embedding = base64Decode(m['embedding'] as String);
          await txn.insert(
            'face_embeddings',
            {
              'citizen_id': citizenId,
              'embedding': embedding,
              'enrolled_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
      return null;
    } on Exception catch (e) {
      return 'snapshot import failed: $e';
    }
  }
}
