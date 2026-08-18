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
import 'ledger/open.dart';
import 'master_key.dart';
import 'mesh/bluez_mesh.dart';
import 'mesh/mesh_adapter.dart';
import 'mesh/mesh_controller.dart';
import 'mesh_packet.dart';
import 'totp.dart';

enum Role { citizen, officer, admin }

/// Accounts are per-device and stored in shared_preferences as a JSON map of
/// username -> {role, passwordHash}. Prototype cheat: the ADMIN login skips
/// password verification entirely so the HQ laptop is always reachable.
const String _kAccountsPref = 'accounts';

class Account {
  Account({required this.username, required this.role, required this.hash});

  final String username;
  final Role role;
  final String hash;

  Map<String, Object?> toJson() => {'role': role.name, 'hash': hash};

  static Account fromJson(String username, Map<String, Object?> json) =>
      Account(
        username: username,
        role: Role.values.byName(json['role'] as String),
        hash: json['hash'] as String,
      );
}

class AppState extends ChangeNotifier {
  Role _role = Role.citizen;
  Role get role => _role;

  String? _officerId;
  String? get officerId => _officerId;

  bool loggedIn = false;
  String _username = '';
  String get username => _username;

  String _citizenId = '';
  String get citizenId => _citizenId;
  List<int> get citizenKey =>
      sha256.convert(utf8.encode('aapadsetu:citizen:$_citizenId')).bytes;

  late LedgerStore ledger;
  MeshController? mesh;

  bool sosActive = false;
  TriageFlags sosFlags = TriageFlags(severity: 3);
  int claimCount = 0;
  int _claimSeq = 0;
  bool initialized = false;

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
  /// nobody advertises before they identify themselves.
  Future<void> init() async {
    ledger = await openLedgerStore();
    initialized = true;
    notifyListeners();
  }

  static String _hashPassword(String password) =>
      sha256.convert(utf8.encode('aapadsetu:pw:$password')).toString();

  /// Deterministic per-account identity: stable across logins so peers never
  /// see this device as a new node, and identical on this phone after a
  /// "Delete All Data & Logout" + re-register with the same username.
  String _seed() => 'aapadsetu:mesh:$username';

  static String _freshCitizenId(String seed) =>
      'CIT-${sha256.convert(utf8.encode(seed)).toString().substring(0, 8).toUpperCase()}';

  /// Login gate. ADMIN bypasses password (prototype HQ). Other users must
  /// exist and match their stored password hash.
  Future<String?> login(String username, String password) async {
    final name = username.trim().toUpperCase();
    if (name.isEmpty) return 'enter a username';
    if (name == 'ADMIN') {
      return _startSession(username: 'ADMIN', role: Role.admin);
    }
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    final account = accounts[name];
    if (account == null) return 'no account for $name — register first';
    if (account.hash != _hashPassword(password)) return 'wrong password';
    return _startSession(username: name, role: account.role);
  }

  /// Creates a local account then logs it in.
  Future<String?> register(String username, String password, Role role) async {
    final name = username.trim().toUpperCase();
    if (name.isEmpty) return 'enter a username';
    if (name == 'ADMIN') return 'ADMIN is reserved for HQ';
    if (password.length < 4) return 'password must be 4+ characters';
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    if (accounts.containsKey(name)) return 'account $name already exists';
    accounts[name] = Account(
      username: name,
      role: role,
      hash: _hashPassword(password),
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
    mesh = _buildMesh(_seed());
    final m = mesh!;
    await m.start();
    m.announce();
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      mesh?.announce();
    });
    loggedIn = true;
    notifyListeners();
    await _acquireGps();
    return null;
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
    loggedIn = false;
    _username = '';
    _role = Role.citizen;
    _citizenId = '';
    _officerId = null;
    notifyListeners();
  }

  /// Destructive factory reset: wipes the ledger, clears every preference
  /// (accounts, appearance) and logs out. Back to a pristine first-run.
  Future<void> deleteAllData() async {
    await logout();
    await ledger.wipe();
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

  /// Officer path: verify a scanned citizen QR and append a claim.
  Future<ClaimResult> claimFromPayload(
    String payload,
    String rationCode,
  ) async {
    final map = _decodeClaimPayload(payload);
    if (map == null) {
      return ClaimResult(ClaimStatus.error, message: 'malformed claim QR');
    }
    final citizenIdFromQr = map['c'] as String?;
    final window = map['w'] as int?;
    final token = map['tok'] as String?;
    if (citizenIdFromQr == null || window == null || token == null) {
      return ClaimResult(ClaimStatus.error, message: 'claim QR missing fields');
    }
    final key = sha256
        .convert(utf8.encode('aapadsetu:citizen:$citizenIdFromQr'))
        .bytes;
    final valid = totpVerify(
      citizenId: citizenIdFromQr,
      citizenKey: key,
      claimedToken: token,
      now: DateTime.now(),
    );
    if (!valid) {
      return ClaimResult(
        ClaimStatus.invalidToken,
        message: 'TOTP token expired or forged',
      );
    }
    return _appendClaim(
      citizenId: citizenIdFromQr,
      rationCode: rationCode,
      officerId: officerId ?? 'OFF-UNENLISTED',
    );
  }

  Future<ClaimResult> _appendClaim({
    required String citizenId,
    required String rationCode,
    required String officerId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final prevHash = await ledger.lastHash();
    final record = LedgerRecord(
      recordId: sha256
          .convert(utf8.encode('$citizenId|$rationCode|$now'))
          .toString()
          .substring(0, 24),
      citizenId: citizenId,
      rationCode: rationCode,
      claimedAt: now,
      officerId: officerId,
      prevHash: prevHash,
      currentHash: '',
    );
    record.currentHash = record.computeCurrentHash();
    final result = await ledger.append(record);
    if (result.ok) {
      claimCount++;
      _claimSeq++;
      mesh?.broadcast(_buildLedgerPacket());
    }
    notifyListeners();
    return result;
  }

  MeshPacket _buildLedgerPacket() {
    final m = mesh!;
    return MeshPacket(
      type: MeshPacketType.ledgerSyncRequest,
      senderId: m.nodeId,
      latitude: m.gpsFix ? m.gpsLatitude! : 0,
      longitude: m.gpsFix ? m.gpsLongitude! : 0,
      triage: TriageFlags(),
      seq: _claimSeq & 0xffff,
    );
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
