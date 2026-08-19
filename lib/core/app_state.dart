/// Central application state: role, identity, ledger, mesh and the claim flow
/// that ties TOTP verification to the hash-chain ledger.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Color;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ledger/ledger_store.dart';
import 'ledger/officer_sign.dart';
import 'ledger/open.dart';
import 'master_key.dart';
import 'mesh/bluez_mesh.dart';
import 'mesh/mesh_adapter.dart';
import 'mesh/mesh_controller.dart';
import 'mesh/mesh_node.dart';
import 'mesh_packet.dart';
import 'totp.dart';

enum Role { citizen, officer, admin }

/// Accounts are per-device and stored in shared_preferences as a JSON map of
/// username -> {role, passwordHash}. Prototype cheat: the ADMIN login skips
/// password verification entirely so the HQ laptop is always reachable.
const String _kAccountsPref = 'accounts';

class Account {
  Account({
    required this.username,
    required this.role,
    required this.hash,
    this.pinHash,
    this.familyId,
  });

  final String username;
  final Role role;
  final String hash;

  /// Knowledge-factor PIN hash (Tier-2 fallback verification). Rides the
  /// claim QR as `ph` so an officer can verify possession without a secret
  /// ever leaving this device.
  final String? pinHash;

  /// Tier-2 family ration card this citizen draws against, if any.
  final String? familyId;

  Map<String, Object?> toJson() => {
    'role': role.name,
    'hash': hash,
    'pin': pinHash,
    'family': familyId,
  };

  static Account fromJson(String username, Map<String, Object?> json) =>
      Account(
        username: username,
        role: Role.values.byName(json['role'] as String),
        hash: json['hash'] as String,
        pinHash: json['pin'] as String?,
        familyId: json['family'] as String?,
      );
}

class AppState extends ChangeNotifier {
  Role _role = Role.citizen;
  Role get role => _role;

  String? _officerId;
  String? get officerId => _officerId;

  /// Knowledge-PIN hash for this session's account (fallback verification).
  /// Empty until an account with a PIN logs in.
  String? _pinHash;
  String? get pinHash => _pinHash;

  /// Tier-2 family ration card this session's account draws against.
  String? _familyId;
  String? get familyId => _familyId;

  bool loggedIn = false;
  String _username = '';
  String get username => _username;

  String _citizenId = '';
  String get citizenId => _citizenId;
  List<int> get citizenKey =>
      sha256.convert(utf8.encode('gridzero:citizen:$_citizenId')).bytes;

  late LedgerStore ledger;
  MeshController? mesh;

  bool sosActive = false;
  TriageFlags sosFlags = TriageFlags(severity: 3);
  int claimCount = 0;
  bool initialized = false;

  /// Cards flagged stolen/suspended (canonical citizen id -> reason code).
  /// Diffused by officers over the mesh and persisted in the ledger store.
  final Map<String, int> _revoked = {};
  Map<String, int> get revokedCitizens => Map.unmodifiable(_revoked);

  /// Credentials heard on the mesh: username -> (role, full password hash).
  /// Assembled from chunked account frames so a fresh device can adopt an
  /// account it has never registered locally. Trust model is physical
  /// adjacency: anyone within BLE range can register a shadow account, the
  /// same threat the mesh accepts for every other frame.
  final Map<String, ({String username, int roleCode, List<int> hashBytes})>
  _meshAccounts = {};

  /// Per-sender account chunk assembly buffers.
  final Map<int, _ChunkBuf> _chunkBufs = {};
  static const int _chunkBufCap = 16;

  /// Tab switch requested by a deep link or notification tap; the shell
  /// consumes it and resets it to null.
  final ValueNotifier<int?> navRequest = ValueNotifier<int?>(null);

  /// Node id the HQ map should fly to after a notification tap.
  int? sosFocusId;

  /// Notification tap target: jump to the HQ tab and focus the SOS node.
  void openSos(String nodeIdHex) {
    final id = int.tryParse(nodeIdHex, radix: 16);
    if (id != null) sosFocusId = id;
    navRequest.value = 2; // ModeShell HQ tab
  }

  // ---- appearance ----
  ThemeMode themeMode = ThemeMode.system;
  Color seedColor = const Color(0xFF00FF9C);
  // Off by default: keep the brand green. User can opt into the platform
  // accent (Android 12+ / desktop) but must be able to flip back.
  bool useSystemDynamic = false;

  void setThemeMode(ThemeMode mode) {
    themeMode = mode;
    notifyListeners();
  }

  void setSeedColor(Color color) {
    seedColor = color;
    notifyListeners();
  }

  void setUseSystemDynamic(bool value) {
    useSystemDynamic = value;
    notifyListeners();
  }

  Future<String> requestMeshPermissions() {
    final m = mesh;
    if (m == null) return Future.value('not logged in');
    return m.adapter.ensurePermissions();
  }

  /// Loads persistence only. The mesh transport is brought up by [login] so
  /// nobody advertises before they identify themselves. [store] lets tests
  /// share one ledger across several AppState instances.
  Future<void> init({LedgerStore? store}) async {
    ledger = store ?? await openLedgerStore();
    for (final r in await ledger.revocations()) {
      _revoked[r.citizenId] = r.reasonCode;
    }
    initialized = true;
    notifyListeners();
  }

  static String _hashPassword(String password) =>
      sha256.convert(utf8.encode('gridzero:pw:$password')).toString();

  static String _hashPin(String pin) =>
      sha256.convert(utf8.encode('gridzero:pin:$pin')).toString();

  /// Deterministic per-account identity: stable across logins so peers never
  /// see this device as a new node, and identical on this phone after a
  /// "Delete All Data & Logout" + re-register with the same username.
  String _seed() => 'gridzero:mesh:$username';

  static String _freshCitizenId(String seed) =>
      'CIT-${sha256.convert(utf8.encode(seed)).toString().substring(0, 8).toUpperCase()}';

  /// Login gate. ADMIN bypasses password (prototype HQ). Other users must
  /// exist locally and match their stored password hash, or be adoptable from
  /// an adjacent terminal that announced the account over the mesh.
  Future<String?> login(String username, String password) async {
    final name = username.trim().toUpperCase();
    if (name.isEmpty) return 'enter a username';
    if (name == 'ADMIN') {
      return _startSession(username: 'ADMIN', role: Role.admin);
    }
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    final account = accounts[name];
    if (account != null) {
      if (account.hash != _hashPassword(password)) return 'wrong password';
      return _startSession(username: name, role: account.role);
    }
    // Not local: ask the mesh whether a neighbouring terminal holds this
    // account, then adopt it if the password verifies (cross-device login).
    return _loginViaMesh(name, password);
  }

  /// Fresh-device login probe: bring up the radio anonymously for a short
  /// window, request account announcements, and adopt the target account when
  /// its credential hash matches the typed password. ADMIN is never probed.
  Future<String?> _loginViaMesh(String name, String password) async {
    final targetHash = _hexBytes(_hashPassword(password));
    final m = _buildMesh(_seed());
    m.onAccountChunk = _onAccountChunk;
    m.onAccountRequest = (_) => _broadcastLocalAccounts();
    await m.start();
    await m.broadcastAccountRequest();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(deadline)) {
        final account = _meshAccounts[name];
        if (account != null) {
          if (_bytesEqual(account.hashBytes, targetHash)) {
            final role = switch (account.roleCode) {
              kRoleOfficer => Role.officer,
              _ => Role.citizen,
            };
            await _importAccount(name, role, _hashPassword(password));
            final err = await _startSession(username: name, role: role);
            return err;
          }
          return 'wrong password';
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      return 'no account $name heard on the mesh — register first, or bring '
          'the device holding that account within range';
    } finally {
      await m.stop();
      _chunkBufs.clear();
      _meshAccounts.clear();
    }
  }

  Future<void> _importAccount(String username, Role role, String hash) async {
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    accounts[username] = Account(username: username, role: role, hash: hash);
    await _writeAccounts(prefs, accounts);
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Assemble one credential chunk into the per-sender buffer; when a full
  /// account is complete it joins the mesh account registry.
  void _onAccountChunk(AccountChunk c, int fromNodeId) {
    if (_chunkBufs.length >= _chunkBufCap) {
      _chunkBufs.remove(_chunkBufs.keys.first);
    }
    final buf = _chunkBufs.putIfAbsent(fromNodeId, _ChunkBuf.new);
    if (c.index == 0) buf.reset();
    if (c.index != buf.next) {
      return; // out of order / restarted; next burst heals
    }
    buf.add(c);
    if (buf.next == c.total) {
      final account = assembleAccount(buf.chunks);
      if (account != null) {
        _meshAccounts[account.username] = account;
        notifyListeners();
      }
      buf.reset();
    }
  }

  /// Respond to a login probe by announcing every local account (twice, so a
  /// single lost frame doesn't strand the probe).
  Future<void> _broadcastLocalAccounts() async {
    final m = mesh;
    if (m == null) return;
    final prefs = await SharedPreferences.getInstance();
    for (final entry in _readAccounts(prefs).entries) {
      final chunks = buildAccountChunks(
        entry.key,
        _roleCode(entry.value.role),
        _hexBytes(entry.value.hash),
      );
      await m.broadcastAccount(chunks);
      await m.broadcastAccount(chunks);
    }
  }

  /// Creates a local account then logs it in.
  Future<String?> register(
    String username,
    String password,
    Role role, {
    String? pin,
    String? familyId,
  }) async {
    final name = username.trim().toUpperCase();
    if (name.isEmpty) return 'enter a username';
    if (name.length > 12) {
      return 'username must be 12 characters or less (fits the mesh frame)';
    }
    if (name == 'ADMIN') return 'ADMIN is reserved for HQ';
    if (password.length < 4) return 'password must be 4+ characters';
    if (pin != null && !RegExp(r'^\d{4,6}$').hasMatch(pin)) {
      return 'PIN must be 4-6 digits';
    }
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    if (accounts.containsKey(name)) return 'account $name already exists';
    accounts[name] = Account(
      username: name,
      role: role,
      hash: _hashPassword(password),
      pinHash: pin == null ? null : _hashPin(pin),
      familyId: familyId,
    );
    await _writeAccounts(prefs, accounts);
    return _startSession(username: name, role: role);
  }

  static Map<String, Account> _readAccounts(SharedPreferences prefs) {
    final raw = prefs.getString(_kAccountsPref);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (name, json) => MapEntry(
          name,
          Account.fromJson(name, json as Map<String, Object?>),
        ),
      );
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeAccounts(
    SharedPreferences prefs,
    Map<String, Account> accounts,
  ) => prefs.setString(
    _kAccountsPref,
    jsonEncode(accounts.map((n, a) => MapEntry(n, a.toJson()))),
  );

  Future<String?> _startSession({
    required String username,
    required Role role,
  }) async {
    if (mesh != null) await logout();
    _username = username;
    _role = role;
    _citizenId = _freshCitizenId(_seed());
    final prefs = await SharedPreferences.getInstance();
    final sessionAccount = _readAccounts(prefs)[username];
    _pinHash = sessionAccount?.pinHash;
    _familyId = sessionAccount?.familyId;
    mesh = _buildMesh(_seed());
    final m = mesh!;
    m.onLedgerRecord = _onLedgerRecord;
    m.onLedgerSyncRequest = (_) => _pushPendingRecords();
    m.onRevocation = _onRevocation;
    m.onAccountChunk = _onAccountChunk;
    m.onAccountRequest = (_) => _broadcastLocalAccounts();
    _knownPeerIds.clear();
    m.nodeUpdates.listen(_onPeerDiscovery);
    await m.start();
    m.announce();
    // Tell peers who we are so their peer list shows a name, not a hex id.
    m.broadcastIdentity(username, _roleCode(role));
    // Seed the mesh account registry so fresh devices can adopt this account.
    await _broadcastLocalAccounts();
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      final mesh = this.mesh;
      if (mesh == null) return;
      mesh.announce();
      mesh.broadcastIdentity(this.username, _roleCode(this.role));
      // Every third tick, ask the mesh to push records we haven't seen.
      if (_heartbeatTick % 3 == 2) mesh.broadcastLedgerSyncRequest();
      _heartbeatTick++;
    });
    loggedIn = true;
    notifyListeners();
    await _acquireGps();
    return null;
  }

  static int _roleCode(Role role) => switch (role) {
    Role.citizen => kRoleCitizen,
    Role.officer => kRoleOfficer,
    Role.admin => kRoleAdmin,
  };

  final Set<int> _knownPeerIds = {};
  int _heartbeatTick = 0;

  /// When a new node appears (fresh peer, not us), pull its records. A relay
  /// carries the request onward, so officers deep in the mesh eventually
  /// answer even if this device only hears the edge.
  void _onPeerDiscovery(Map<int, MeshNodeState> nodes) {
    for (final id in nodes.keys) {
      if (id == mesh?.nodeId) continue;
      if (_knownPeerIds.add(id)) {
        mesh?.broadcastLedgerSyncRequest();
      }
    }
  }

  /// Push all locally-unsynced claims as compact records, then mark shipped.
  Future<void> _pushPendingRecords() async {
    final m = mesh;
    if (m == null) return;
    final pending = await ledger.pendingRecords();
    for (final r in pending) {
      m.broadcastLedgerRecord(
        CompactRecord(
          citizenId: r.citizenId,
          officerId: r.officerId,
          claimedAt: r.claimedAt,
          rationCode: r.rationCode,
        ),
      );
    }
    await ledger.markSynced(pending.map((r) => r.recordId).toList());
    if (pending.isNotEmpty) notifyListeners();
  }

  /// Absorb a record relayed from another device's chain. Duplicates and
  /// cross-officer daily double-claims are rejected by the store.
  Future<void> _onLedgerRecord(CompactRecord record, int fromNodeId) async {
    final now = record.claimedAt;
    final recordId = sha256
        .convert(utf8.encode('${record.citizenId}|${record.rationCode}|$now'))
        .toString()
        .substring(0, 24);
    final result = await ledger.mergeRecord(
      receivedFrom: fromNodeId,
      record: LedgerRecord(
        recordId: recordId,
        citizenId: record.citizenId,
        rationCode: record.rationCode,
        claimedAt: now,
        officerId: record.officerId,
        prevHash: '',
        currentHash: '',
        syncStatus: 1,
        claimUnits: record.claimUnits,
      ),
    );
    if (result.ok) notifyListeners();
  }

  /// Absorb a stolen/suspended card alert relayed from another officer. A
  /// CLEARED alert unflags the card. Persisted so the blacklist survives
  /// restarts and stays consistent with the HQ dashboard.
  Future<void> _onRevocation(RevocationAlert alert, int fromNodeId) async {
    final canon = bitsToId('CIT-', idToBits(alert.citizenId));
    if (alert.reasonCode == kRevokeCleared) {
      _revoked.remove(canon);
      await ledger.clearRevocation(canon);
    } else {
      _revoked[canon] = alert.reasonCode;
      await ledger.upsertRevocation(
        RevocationEntry(
          citizenId: canon,
          reasonCode: alert.reasonCode,
          issuedAt: alert.issuedAt,
          sourceNode: fromNodeId,
        ),
      );
    }
    notifyListeners();
  }

  /// Officer/admin action: flag a citizen's card as stolen/suspended, diffuse
  /// the alert over the mesh, and persist it. Cleared removes the flag.
  Future<void> revokeCitizen(
    String citizenId, {
    required int reasonCode,
  }) async {
    if (_role != Role.officer && _role != Role.admin) return;
    final canon = bitsToId('CIT-', idToBits(citizenId));
    final m = mesh;
    if (reasonCode == kRevokeCleared) {
      _revoked.remove(canon);
      await ledger.clearRevocation(canon);
      m?.broadcastRevocation(canon, reasonCode: kRevokeCleared);
    } else {
      _revoked[canon] = reasonCode;
      final entry = RevocationEntry(
        citizenId: canon,
        reasonCode: reasonCode,
        issuedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        sourceNode: m?.nodeId ?? 0,
      );
      await ledger.upsertRevocation(entry);
      m?.broadcastRevocation(canon, reasonCode: reasonCode);
    }
    notifyListeners();
  }

  /// Stops the radio and returns to the login screen. Identity and ledger
  /// stay intact — use [deleteAllData] to erase everything.
  Future<void> logout() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _sosTimer?.cancel();
    _sosTimer = null;
    sosActive = false;
    final m = mesh;
    mesh = null;
    if (m != null) {
      await m.stop();
    }
    _knownPeerIds.clear();
    _meshAccounts.clear();
    _chunkBufs.clear();
    _heartbeatTick = 0;
    loggedIn = false;
    _username = '';
    _role = Role.citizen;
    _citizenId = '';
    _officerId = null;
    _pinHash = null;
    _familyId = null;
    notifyListeners();
  }

  /// Destructive factory reset: wipes the ledger, clears every preference
  /// (accounts, appearance) and logs out. Back to a pristine first-run.
  Future<void> deleteAllData() async {
    await logout();
    await ledger.wipe();
    _revoked.clear();
    ledger = await openLedgerStore();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    notifyListeners();
  }

  /// Real GPS lives on phones; laptops have none. Failure is normal —
  /// the app then falls back to the peer-consensus estimate.
  Future<void> _acquireGps() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          // High accuracy (GPS, not cell/wifi): medium put users a road off.
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      mesh?.setGpsFix(
        latitude: pos.latitude,
        longitude: pos.longitude,
        altitude: pos.altitude,
      );
      notifyListeners();
    } catch (_) {
      // no fix (e.g. denied, no satellites); keep the no-GPS fallback
    }
  }

  Timer? _heartbeat;
  Timer? _sosTimer;

  MeshController _buildMesh(String seed) {
    final digest = sha256.convert(utf8.encode(seed)).bytes;
    final nodeId = (digest[0] << 8 | digest[1]) & 0xffff;
    final adapter = switch (defaultTargetPlatform) {
      TargetPlatform.linux => BluezMeshAdapter(
        advertisingPayload: Uint8List(meshPacketLength),
      ) as MeshAdapter,
      _ => _nativeAdapter(nodeId),
    };
    return MeshController(nodeId: nodeId, adapter: adapter);
  }

  // Late binding so the platform MeshAdapter can be swapped out in tests.
  static MeshAdapter Function(int nodeId) nativeAdapterFactory = (nodeId) {
    throw UnsupportedError('no native mesh adapter registered');
  };

  MeshAdapter _nativeAdapter(int nodeId) => nativeAdapterFactory(nodeId);

  /// Current TOTP token for this device's citizen QR.
  String currentToken() => totpToken(
    citizenId: citizenId,
    citizenKey: citizenKey,
    timeWindow: totpTimeWindow(DateTime.now()),
  );

  String citizenQrPayload() => jsonEncode({
    'v': 1,
    'c': citizenId,
    'w': totpTimeWindow(DateTime.now()),
    'tok': currentToken(),
    if (username.isNotEmpty) 'n': username,
    if (_pinHash != null) 'ph': _pinHash,
    if (_familyId != null) 'f': _familyId,
  });

  void setSosActive(bool active) {
    sosActive = active;
    _sosTimer?.cancel();
    final m = mesh;
    if (m == null) return;
    if (active) {
      m.broadcastSos(triage: sosFlags);
      _sosTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        m.broadcastSos(triage: sosFlags);
      });
    } else {
      // One cleared beacon so peers turn the alarm off now, not in 90s.
      m.broadcastSos(triage: sosFlags, cleared: true);
    }
    notifyListeners();
  }

  void setSosFlags(TriageFlags flags) {
    sosFlags = flags;
    notifyListeners();
  }

  /// Officer path: verify a scanned citizen QR and append a claim. Primary
  /// verification is the rotating TOTP token; when the token window fails
  /// (expired or a forged QR) the officer may fall back to the citizen's
  /// knowledge PIN carried in the payload ([fallbackPin]) plus a visual
  /// identity check at the terminal. Claim units (0.25–1.0) draw against a
  /// Tier-2 family card when the citizen belongs to one.
  Future<ClaimResult> claimFromPayload(
    String payload,
    String rationCode, {
    double claimUnits = 1.0,
    String? fallbackPin,
  }) async {
    final map = _decodeClaimPayload(payload);
    if (map == null) {
      return ClaimResult(ClaimStatus.error, message: 'malformed claim QR');
    }
    final citizenIdFromQr = map['c'] as String?;
    final window = map['w'] as int?;
    final token = map['tok'] as String?;
    final familyIdFromQr = map['f'] as String?;
    final pinHashFromQr = map['ph'] as String?;
    if (citizenIdFromQr == null || window == null || token == null) {
      return ClaimResult(ClaimStatus.error, message: 'claim QR missing fields');
    }
    if (claimUnits <= 0 || claimUnits > 1) {
      return ClaimResult(
        ClaimStatus.error,
        message: 'claim units must be within 0.25–1.0',
      );
    }
    final key = sha256
        .convert(utf8.encode('gridzero:citizen:$citizenIdFromQr'))
        .bytes;
    final valid = totpVerify(
      citizenId: citizenIdFromQr,
      citizenKey: key,
      claimedToken: token,
      now: DateTime.now(),
    );
    if (!valid) {
      if (fallbackPin != null && pinHashFromQr != null) {
        if (_hashPin(fallbackPin) != pinHashFromQr) {
          return ClaimResult(
            ClaimStatus.pinMismatch,
            message: 'PIN fallback rejected — knowledge factor mismatch',
          );
        }
      } else {
        return ClaimResult(
          ClaimStatus.invalidToken,
          message: 'TOTP token expired or forged — use PIN fallback',
        );
      }
    }
    return _appendClaim(
      citizenId: citizenIdFromQr,
      rationCode: rationCode,
      officerId: officerId ?? 'OFF-UNENLISTED',
      claimUnits: claimUnits,
      familyId: familyIdFromQr,
      fallback: valid == false,
    );
  }

  Future<ClaimResult> _appendClaim({
    required String citizenId,
    required String rationCode,
    required String officerId,
    required double claimUnits,
    String? familyId,
    bool fallback = false,
  }) async {
    final revokedReason = _revoked[bitsToId('CIT-', idToBits(citizenId))];
    if (revokedReason != null) {
      return ClaimResult(
        ClaimStatus.revoked,
        message:
            'citizen ${bitsToId('CIT-', idToBits(citizenId))} card is '
            '${revocationReasonLabel(revokedReason)} — claims refused',
      );
    }
    // Tier-2 gate: a family claim must reference a known card and the
    // citizen must be on its roster; the daily cap is enforced below.
    if (familyId != null) {
      final card = await ledger.familyCard(familyId);
      if (card == null) {
        return ClaimResult(
          ClaimStatus.familyUnknown,
          message: 'family card $familyId not cached — enlist it first',
        );
      }
      if (card.rationCode != rationCode) {
        return ClaimResult(
          ClaimStatus.familyUnknown,
          message:
              'family card $familyId is ${card.rationCode}, not $rationCode',
        );
      }
      if (!card.memberCitizenIds.contains(citizenId)) {
        return ClaimResult(
          ClaimStatus.notFamilyMember,
          message: 'citizen $citizenId is not on family card $familyId roster',
        );
      }
      final dayStart =
          DateTime.now().toUtc().millisecondsSinceEpoch ~/
          1000 ~/
          86400 *
          86400;
      final used = await ledger.familyUsedUnits(familyId, dayStart);
      if (used + claimUnits > card.dailyUnits) {
        return ClaimResult(
          ClaimStatus.familyExhausted,
          message:
              'family card $familyId daily ration exhausted '
              '(${used.toStringAsFixed(2)}/${card.dailyUnits.toStringAsFixed(2)} units)',
        );
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final prevHash = await ledger.lastHash();
    final recordId = sha256
        .convert(utf8.encode('$citizenId|$rationCode|$now'))
        .toString()
        .substring(0, 24);
    final record = LedgerRecord(
      recordId: recordId,
      citizenId: citizenId,
      rationCode: rationCode,
      claimedAt: now,
      officerId: officerId,
      prevHash: prevHash,
      currentHash: '',
      claimUnits: claimUnits,
      familyId: familyId,
    );
    record.currentHash = record.computeCurrentHash();
    if (_role == Role.officer) {
      final signed = await _signRecord(record);
      if (signed == null) {
        return ClaimResult(
          ClaimStatus.error,
          message: 'could not initialise officer signing key',
        );
      }
      record
        ..signature = signed.$1
        ..signerPublic = signed.$2;
    }
    final result = await ledger.append(record);
    if (result.ok) {
      claimCount++;
      final m = mesh;
      if (m != null) {
        // Push the fresh claim immediately (store-and-forward) and mark it
        // shipped; the periodic request re-syncs anything the mesh missed.
        m.broadcastLedgerRecord(
          CompactRecord(
            citizenId: record.citizenId,
            officerId: record.officerId,
            claimedAt: record.claimedAt,
            rationCode: record.rationCode,
            claimUnits: record.claimUnits,
          ),
        );
        m.broadcastLedgerSyncRequest();
        await ledger.markSynced([record.recordId]);
      }
    }
    notifyListeners();
    return result;
  }

  /// Signs a claim block with the officer's deterministic ECDSA-P256 key,
  /// creating the keypair on first use. Returns (signature, publicKey) or
  /// null when signing failed.
  Future<(List<int>, List<int>)?> _signRecord(LedgerRecord record) async {
    final officerId = this.officerId ?? 'OFF-UNENLISTED';
    var key = await ledger.officerKey(officerId);
    if (key == null) {
      final fresh = generateOfficerKey();
      await ledger.saveOfficerKey(officerId, fresh.$1, fresh.$2);
      key = fresh;
    }
    try {
      return (signOfficerRecord(key.$2, record.recordData()), key.$1);
    } on Exception {
      return null;
    }
  }

  Map<String, Object?>? _decodeClaimPayload(String payload) {
    try {
      final map = jsonDecode(payload);
      return map is Map<String, Object?> ? map : null;
    } catch (_) {
      return null;
    }
  }

  /// Officer enlistment from a scanned Master Key QR (FR-2.3).
  Future<MasterKeyCheck> enlistOfficer(String payload) async {
    final check = await verifyMasterKey(payload: payload);
    if (check.ok) {
      _officerId = check.masterKey!.officerId;
      _role = Role.officer;
      notifyListeners();
    }
    return check;
  }

  /// Tier-2 family enlistment from a signed HQ QR. Caches the card locally
  /// so claims against it can be verified and capped offline.
  Future<FamilyCardCheck> enlistFamily(String payload) async {
    final check = await verifyFamilyCard(payload: payload);
    if (check.ok) {
      await ledger.upsertFamilyCard(check.card!);
      notifyListeners();
    }
    return check;
  }

  void switchRole(Role role) {
    _role = role;
    notifyListeners();
  }

  String randomNodeId() =>
      Random().nextInt(0xffff).toRadixString(16).padLeft(4, '0').toUpperCase();

  @override
  void dispose() {
    _heartbeat?.cancel();
    _sosTimer?.cancel();
    mesh?.stop();
    ledger.close();
    super.dispose();
  }
}

/// Hex string -> raw bytes (sha256 password hashes travel as hex in prefs).
List<int> _hexBytes(String hex) => [
  for (var i = 0; i + 2 <= hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

/// In-order chunk accumulator for one sender's account credential.
class _ChunkBuf {
  int next = 0;
  final List<AccountChunk> chunks = [];

  void reset() {
    next = 0;
    chunks.clear();
  }

  void add(AccountChunk c) {
    chunks.add(c);
    next++;
  }
}
