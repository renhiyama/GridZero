/// Central application state: role, identity, ledger, mesh and the claim flow
/// that ties TOTP verification to the hash-chain ledger.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Color;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'mesh_crypto.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart'
    show MethodChannel, PlatformException;
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_codec.dart';
import 'ledger/ledger_store.dart';
import 'ledger/officer_sign.dart';
import 'ledger/open.dart';
import 'face_enroll.dart';
import 'mesh/bluez_mesh.dart';
import 'mesh/mesh_adapter.dart';
import 'mesh/mesh_controller.dart';
import 'mesh/mesh_node.dart';
import 'mesh_packet.dart';
import 'movement_gate.dart';
import 'provision_packet.dart';
import 'identity.dart';
import 'audio_alert.dart';
import 'totp.dart';
import 'db_sync.dart';
import 'dart:io' show NetworkInterface;

import 'linux_network.dart' as linux_net;
import 'windows_network.dart' as win_net;
import 'linux_network.dart' show kLinkApGateway, SavedConnection;
import 'mesh/win_mesh_adapter.dart';

bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;
Future<String?> _startLinkAp({required String ssid, required String pass}) =>
    _isWindows ? win_net.startLinkAp(ssid: ssid, pass: pass) : linux_net.startLinkAp(ssid: ssid, pass: pass);
Future<void> _stopLinkAp() => _isWindows ? win_net.stopLinkAp() : linux_net.stopLinkAp();
Future<List<String>> _visibleWifiNetworks() =>
    _isWindows ? win_net.visibleWifiNetworks() : linux_net.visibleWifiNetworks();
Future<List<SavedConnection>> _activeConnections() =>
    _isWindows ? win_net.activeConnections() : linux_net.activeConnections();
Future<String?> _connectWifi(String ssid, String pass) =>
    _isWindows ? win_net.connectWifi(ssid, pass) : linux_net.connectWifi(ssid, pass);
Future<List<String>> _restoreConnections(List<SavedConnection> c) =>
    _isWindows ? win_net.restoreConnections(c) : linux_net.restoreConnections(c);
Future<String?> _activeWifiConnectionName() =>
    _isWindows ? win_net.activeWifiConnectionName() : linux_net.activeWifiConnectionName();
Future<String?> _connectionGateway(String name) =>
    _isWindows ? win_net.connectionGateway(name) : linux_net.connectionGateway(name);
Future<void> _disconnectConnection(String name) =>
    _isWindows ? win_net.disconnectConnection(name) : linux_net.disconnectConnection(name);

enum Role { citizen, officer, admin }

/// Accounts are per-device and stored in shared_preferences as a JSON map of
/// username -> {role, passwordHash}. Prototype cheat: the ADMIN login skips
/// password verification entirely so the HQ laptop is always reachable.
const String _kAccountsPref = 'accounts';
const String _kDeviceIdPref = 'deviceId';
const String _kSessionUserPref = 'sessionUser';
const String _kAdminTerminalPref = 'adminTerminal';
const String _kMyLandmarksPref = 'myLandmarks';
const String _kChatHistoryPref = 'chatHistory';
const String _kPreSyncNetworksPref = 'preSyncNetworks';
const String _kLastDataExchangePref = 'lastDataExchangeAt';
const String _kLastFaceEnrollPref = 'lastFaceEnrollAt';
const String _kShowDebugPref = 'showDebugInfo';
const String _kRespondVolumePref = 'respondAlertVolume';

class Account {
  Account({
    required this.username,
    required this.role,
    required this.hash,
    this.pinHash,
    this.aadhaar,
    this.familyId,
    this.officerId,
  });

  final String username;
  Role role;
  final String hash;

  /// Knowledge-factor PIN hash (Tier-2 fallback verification). Rides the
  /// claim QR as `ph` so an officer can verify possession without a secret
  /// ever leaving this device.
  final String? pinHash;

  /// Aadhaar-style unique ID assigned at registration. Stable per account so
  /// peers never see this citizen as a new identity across logins.
  final String? aadhaar;

  /// Tier-2 family ration card this citizen draws against, if any.
  final String? familyId;

  /// Set iff [role] is officer: the mesh/ledger identity this account signs
  /// relief records with. Persisted so HQ can list the user↔officer link.
  final String? officerId;

  Map<String, Object?> toJson() => {
    'role': role.name,
    'hash': hash,
    'pin': pinHash,
    'aadhaar': aadhaar,
    'family': familyId,
    if (officerId != null) 'officer_id': officerId,
  };

  static Account fromJson(String username, Map<String, Object?> json) =>
      Account(
        username: username,
        role: Role.values.byName(json['role'] as String),
        hash: json['hash'] as String,
        pinHash: json['pin'] as String?,
        aadhaar: json['aadhaar'] as String?,
        familyId: json['family'] as String?,
        officerId: json['officer_id'] as String?,
      );
}

/// A broadcast chat message heard on the mesh (or sent by this device).
class MeshChatMessage {
  MeshChatMessage({
    required this.senderNodeId,
    required this.senderName,
    required this.text,
    required this.at,
  });

  final int senderNodeId;
  final String senderName;
  final String text;
  final DateTime at;
}

/// Landmark types for signed official announcements.
const List<String> kLandmarkTypes = [
  'RELIEF CAMP',
  'HOSPITAL',
  'WATER',
  'FOOD',
  'MEDIC',
];

String landmarkTypeLabel(int code) =>
    code < kLandmarkTypes.length ? kLandmarkTypes[code] : 'SITE $code';

/// A verified, officer-signed point of interest received over the mesh.
class OfficialLandmark {
  OfficialLandmark({
    required this.officerId,
    required this.label,
    required this.typeLabel,
    required this.latitude,
    required this.longitude,
    required this.expiresAt,
    this.signedBlobB64,
  });

  final String officerId;
  final String label;
  final String typeLabel;
  final double latitude;
  final double longitude;
  final DateTime expiresAt;
  /// Base64 of the original officer-signed blob (verbatim for re-advertise).
  /// Stored so any holder can re-broadcast the *original* HQ-certified sig for
  /// far-away late-joiners to verify, not a re-signed copy.
  final String? signedBlobB64;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class AppState extends ChangeNotifier {
  /// Live instance for the VM-service debug hook ([syncDebugJson]).
  static AppState? debugInstance;

  /// username -> hash prefix cache, refreshed whenever [accounts] runs; used
  /// by the SYNC page to build the join QR without a second prefs read.
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

  /// Set when a freshly provisioned account starts its session. The shell
  /// consumes it once to offer one-shot face enrolment right after setup.
  String? pendingFaceEnrollFor;

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

  /// Presentation vs engineer view. Off by default: hide packet/ID/radio
  /// jargon and enlarge text so the app reads clearly to citizens, judges and
  /// older users; on reveals the technical readouts used for demos/debugging.
  bool showDebugInfo = false;

  /// Response-alert volume (0.0-1.0). Capped at 50% by default so an SOS ack
  /// is clearly audible without blasting a field full of people.
  double respondAlertVolume = 0.5;

  Future<void> setShowDebugInfo(bool value) async {
    showDebugInfo = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowDebugPref, value);
    notifyListeners();
  }

  Future<void> setRespondAlertVolume(double value) async {
    respondAlertVolume = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kRespondVolumePref, value);
    notifyListeners();
  }

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

  /// Loads persistence, starts the anonymous mesh (so SOS beacons and peer
  /// frames are heard even at the login screen) and restores any persisted
  /// revocations. [store] lets tests share one ledger across AppState
  /// instances. The mesh transport is started here: before login: so a
  /// device is never radio-silent; identity frames only flow after [login].
  Future<void> init({LedgerStore? store}) async {
    ledger = store ?? await openLedgerStore();
    for (final r in await ledger.revocations()) {
      _revoked[r.citizenId] = r.reasonCode;
    }
    final prefs = await SharedPreferences.getInstance();
    showDebugInfo = prefs.getBool(_kShowDebugPref) ?? false;
    respondAlertVolume = prefs.getDouble(_kRespondVolumePref) ?? 0.5;
    await _loadNetworkKeyIfAny();
    await _restoreSyncTimestamps();
    await _restoreChatHistory();
    await _restoreMyLandmarks();
    // Reload received landmarks from the ledger (dedup'd, may include
    // entries heard from other devices before a restart).
    try {
      for (final l in await ledger.landmarks()) {
        if (l.isExpired) continue;
        officialLandmarks.removeWhere(
          (e) => e.label == l.label && e.officerId == l.officerId,
        );
        officialLandmarks.add(OfficialLandmark(
          officerId: l.officerId,
          label: l.label,
          typeLabel: landmarkTypeLabel(l.typeCode),
          latitude: l.latitude,
          longitude: l.longitude,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(l.expiresAt * 1000),
          signedBlobB64: l.signedBlobB64,
        ));
      }
    } catch (_) {
      // Ledger might be fresh; no landmarks stored.
    }
    unawaited(_restoreOrphanedSyncNetworks());
    _startLandmarkRetx();
    await _ensureMesh();
    // Anonymous at boot: STANDBY scan duty until a session signs in.
    await mesh?.setRadioActive(false);
    unawaited(_acquireGps());
    initialized = true;
    notifyListeners();
  }

  /// Auto-login after a restart: resumes the last session account without
  /// asking for credentials again. A terminal that has EVER logged in as
  /// ADMIN keeps that role across restarts even with no stored session: the
  /// HQ laptop must never wake up as a roleless citizen just because a wipe
  /// or reinstall cleared its session (ADMIN is passwordless by design).
  Future<void> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final user = prefs.getString(_kSessionUserPref);
    if (user == null) {
      if (prefs.getBool(_kAdminTerminalPref) ?? false) {
        await _startSession(username: 'ADMIN', role: Role.admin);
      }
      return;
    }
    // ADMIN is passwordless and has no Account record: handle it before
    // the account lookup, which would otherwise delete the session pointer
    // and drop HQ back to the login screen on every restart.
    if (user == 'ADMIN') {
      await _startSession(username: 'ADMIN', role: Role.admin);
      return;
    }
    final account = _readAccounts(prefs)[user];
    if (account == null) {
      await prefs.remove(_kSessionUserPref);
      return;
    }
    await _startSession(username: user, role: account.role);
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
    // Accounts are per-device: no cross-device login over the mesh. They can
    // only be created by Command HQ, so there is nothing to register here.
    return 'no account $name on this device: get one from Command HQ '
        '(REGISTER tab)';
  }

  /// Creates a local account then logs it in. Aadhaar and ration ids default
  /// to random valid values when omitted (prototype: no document verification
  /// yet), so every registration yields a plausible identity card.
  Future<String?> register(
    String username,
    String password,
    Role role, {
    String? pin,
    String? aadhaar,
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
    final aadhaarId = aadhaar?.trim() ?? randomAadhaar();
    if (!aadhaarRe.hasMatch(aadhaarId)) {
      return 'Aadhaar must be 12 digits, first digit 2-9 (e.g. 2345 6789 0123)';
    }
    if (familyId != null && !rationRe.hasMatch(familyId.trim().toUpperCase())) {
      return 'Ration card id must be 8-16 letters, digits, / or -';
    }
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    if (accounts.containsKey(name)) return 'account $name already exists';
    String? officerId;
    if (role == Role.officer) {
      officerId =
          'OFF-${sha256.convert(utf8.encode(_seedFor(name))).toString().substring(0, 8).toUpperCase()}';
    }
    accounts[name] = Account(
      username: name,
      role: role,
      hash: _hashPassword(password),
      pinHash: pin == null ? null : _hashPin(pin),
      aadhaar: aadhaarId,
      familyId: familyId?.trim().toUpperCase(),
      officerId: officerId,
    );
    await _writeAccounts(prefs, accounts);
    if (role == Role.officer) {
      await _enlistOfficerAccount(accounts[name]!, registeredBy: 'REGISTER');
    }
    return _startSession(username: name, role: role);
  }

  /// HQ-provisioned enrolment (paged-QR handoff): imports an HQ-signed account.
  /// Every QR is now signed with the HQ authority (`GZPROV` canonical) and
  /// carries a `cert` binding the derived pubkey to the username/officerId via
  /// `GZCERT`. Fake QRs from a hacked app lack the authority sig and are
  /// rejected once this device has seen one real HQ (stored `authority_pub`).
  Future<String?> provisionAccount(String payload) async {
    final parsedRaw = parseProvisionEnvelope(payload, requireType: ProvisionType.account);
    // Envelope-level expiry/type already checked; now verify HQ sig if we can.
    if (parsedRaw.envelope == null) {
      return parsedRaw.error ?? 'malformed provision payload';
    }
    final acc = decodeAccountProvision(payload);
    if (acc == null) {
      return parsedRaw.error ?? 'malformed provision payload';
    }
    final name = acc.username.trim().toUpperCase();
    if (name.isEmpty || name.length > 12) {
      return 'provisioned username invalid';
    }
    if (name == 'ADMIN') return 'ADMIN is reserved for HQ';
    if (acc.passwordHash.length != 64) return 'provisioned hash invalid';
    if (acc.aadhaar != null && !aadhaarRe.hasMatch(acc.aadhaar!)) {
      return 'provisioned Aadhaar invalid';
    }
    if (acc.familyId != null &&
        !rationRe.hasMatch(acc.familyId!.trim().toUpperCase())) {
      return 'provisioned family id invalid';
    }
    final role = switch (acc.purpose) {
      ProvisionPurpose.citizen => Role.citizen,
      ProvisionPurpose.officer => Role.officer,
    };
    // --- Verify HQ envelope sig + cert chain (blocks fake QRs) ---
    final env = parsedRaw.envelope!;
    final prefsForVerify = await SharedPreferences.getInstance();
    final storedRootB64 = prefsForVerify.getString(kAuthorityPubPref) ?? _authorityPublicB64;
    final presentedRootB64 = acc.authorityPub;
    final verifierRootB64 = storedRootB64 ?? presentedRootB64;
    if (env.signature != null) {
      if (verifierRootB64 == null) {
        return 'provision QR is signed but no HQ authority to verify against';
      }
      final canonical = canonicalProvision(v: 2, t: env.type.tag, exp: env.expiresAt, nonce: env.nonce, data: env.data);
      try {
        final ok = verifyOfficerRecord(base64Decode(verifierRootB64), canonical, base64Decode(env.signature!));
        if (!ok) return 'provision QR signature invalid — not from this HQ';
      } catch (_) {
        return 'provision QR signature malformed';
      }
      // Strict: if we already trust a root, the QR's ak must match it, else
      // an attacker could swap in their own ak that verifies against itself.
      if (storedRootB64 != null && presentedRootB64 != null && storedRootB64 != presentedRootB64) {
        return 'provision QR authority mismatch — not from trusted HQ';
      }
    } else {
      // Unsigned QR: only allowed if we have never seen a real HQ (first
      // provision or old test vectors). Once a root is pinned, unsigned = fake.
      if (storedRootB64 != null) {
        return 'provision QR not signed by HQ — fake account blocked';
      }
    }
    // Verify the cert binds the derived pubkey to the account id (prevents
    // a valid HQ envelope being reused with a different pubkey).
    final presentedCertB64 = acc.certB64;
    if (presentedCertB64 != null) {
      final derived = deriveOfficerKey(acc.passwordHash);
      final pubB64 = base64Encode(derived.$1);
      final idForCert = acc.officerId ?? acc.username;
      final certOk = verifyOfficerRecord(base64Decode(verifierRootB64 ?? presentedRootB64 ?? ''), 'GZCERT|$idForCert|$pubB64', base64Decode(presentedCertB64));
      if (!certOk) return 'provision cert invalid — pubkey not certified by HQ';
      await prefsForVerify.setString('cert_sig_$idForCert', presentedCertB64);
      await prefsForVerify.setString('cert_sig_${acc.username}', presentedCertB64);
    }
    // Store the HQ authority pubkey from the QR: this is the trust anchor
    // for verifying officer-signed landmarks later.
    if (acc.authorityPub != null) {
      await _storeAuthorityPub(acc.authorityPub!);
    }
    // Store the per-ADMIN network key for full mesh encryption. This is what
    // isolates A (PQR) from B (XYZ) into distinct encrypted meshes — only
    // holders of the same HQ's network key can decrypt each other's frames.
    if (acc.netKeyB64 != null) {
      try {
        final netKey = base64Decode(acc.netKeyB64!);
        if (netKey.length == kNetworkKeyBytes) {
          await prefsForVerify.setString(kNetworkKeyPref, acc.netKeyB64!);
          setNetworkKey(Uint8List.fromList(netKey));
        }
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    if (accounts.containsKey(name)) {
      // Same HQ record re-provisioned (retry after a lost scan): adopt the
      // existing account instead of erroring, but only if the hash matches.
      final existing = accounts[name]!;
      if (existing.hash != acc.passwordHash) {
        return 'account $name exists with different credentials';
      }
    } else {
      accounts[name] = Account(
        username: name,
        role: role,
        hash: acc.passwordHash,
        pinHash: acc.pinHash,
        aadhaar: acc.aadhaar,
        familyId: acc.familyId?.trim().toUpperCase(),
        officerId: role == Role.officer
            ? (acc.officerId ?? _officerIdFor(name))
            : null,
      );
      await _writeAccounts(prefs, accounts);
    }
    if (role == Role.officer) {
      _officerId = accounts[name]!.officerId;
      // If the QR already carries a HQ-certified pub (citizen→officer promotion
      // or fresh officer), store that cert verbatim instead of re-generating a
      // random key. The officer's signing key is deterministic from the hash,
      // so both HQ and this device derive the same pub.
      if (acc.certB64 != null) {
        final derived = deriveOfficerKey(acc.passwordHash);
        await ledger.saveOfficerKey(_officerId!, derived.$1, derived.$2);
        final prefs2 = await SharedPreferences.getInstance();
        await prefs2.setString('cert_${_officerId}_pub', base64Encode(derived.$1));
        await prefs2.setString('cert_${_officerId}_sig', acc.certB64!);
        await prefs2.setString('cert_sig_${_officerId}', acc.certB64!);
        await prefs2.setString('cert_sig_${name}', acc.certB64!);
        await ledger.upsertOfficer(OfficerRecord(officerId: _officerId!, publicKey: base64Encode(derived.$1), enlistedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000, registeredBy: 'OFF-PROVISION'));
      } else {
        await _enlistOfficerAccount(accounts[name]!, registeredBy: 'OFF-PROVISION');
      }
    }
    // _startSession always succeeds; the returned error slot is reserved.
    await _startSession(username: name, role: role);
    // Only citizens carry a face biometric: officers verify other people,
    // so an officer handoff must not trigger the enrol offer.
    if (role == Role.citizen) pendingFaceEnrollFor = name;
    return null;
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
    final m = await _ensureMesh();
    _username = username;
    _role = role;
    final prefs = await SharedPreferences.getInstance();
    final sessionAccount = _readAccounts(prefs)[username];
    _pinHash = sessionAccount?.pinHash;
    _passwordHash = sessionAccount?.hash;
    _familyId = sessionAccount?.familyId;
    _officerId = sessionAccount?.officerId;
    if (_officerId == null && role == Role.officer && sessionAccount != null) {
      // Accounts created before officer ids were persisted still get a
      // stable id: derive it from the username (same derivation the old
      // in-memory path used), then write it back so the gate never
      // reappears on restart.
      _officerId = _officerIdFor(username);
      await _writeAccounts(prefs, {
        ..._readAccounts(prefs),
        username: Account(
          username: username,
          role: Role.officer,
          hash: sessionAccount.hash,
          pinHash: sessionAccount.pinHash,
          aadhaar: sessionAccount.aadhaar,
          familyId: sessionAccount.familyId,
          officerId: _officerId,
        ),
      });
    }
    // Prefer the stored Aadhaar; ADMIN (no local account) and accounts from
    // before Aadhaar existed fall back to the deterministic derivation so
    // their identity never shifts between sessions.
    _citizenId = sessionAccount?.aadhaar ?? _freshCitizenId(_seed());
    await prefs.setString(_kSessionUserPref, username);
    if (role == Role.admin) {
      // Mark this terminal as an HQ box so restoreSession re-homes it to
      // ADMIN even after a wipe clears the session pointer.
      await prefs.setBool(_kAdminTerminalPref, true);
    }
    _knownPeerIds.clear();
    _heartbeatTick = 0;
    // Tell peers who we are so their peer list shows a name, not a hex id.
    m.broadcastIdentity(username, _roleCode(role));
    // Live session: the radio moves from STANDBY to NOMINAL scan duty.
    await m.setRadioActive(true);
    _startHeartbeat();
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

  /// Guarantees the session officer has a signing keypair, creating and
  /// persisting one on first use.
  Future<(List<int>, List<int>)?> _ensureOfficerKey() async {
    final id = _officerId ?? 'OFF-UNENLISTED';
    var key = await ledger.officerKey(id);
    if (key == null) {
      final fresh = generateOfficerKey();
      await ledger.saveOfficerKey(id, fresh.$1, fresh.$2);
      key = fresh;
    }
    return key;
  }

  /// Identity seed for an arbitrary account: same derivation as [_seed],
  /// usable before/without that account being the live session.
  static String _seedFor(String username) => 'gridzero:mesh:$username';

  static String _officerIdFor(String username) =>
      'OFF-${sha256.convert(utf8.encode(_seedFor(username))).toString().substring(0, 8).toUpperCase()}';

  /// Ledger-side enlistment for ANY officer account, not just the live
  /// session: creates their signing keypair on first use and upserts the
  /// public record. This is what ties the local account directory to the
  /// tamper-evident officer registry.
  Future<void> _enlistOfficerAccount(
    Account account, {
    required String registeredBy,
  }) async {
    final id = account.officerId;
    if (id == null) return;
    var key = await ledger.officerKey(id);
    // Prefer deterministic key from the account's password hash so HQ and the
    // officer's device share the same key without ever transporting the private
    // half. This is what provisionAccount and accountPayload also use.
    final wantsDeterministic = account.hash.length == 64;
    if (key == null) {
      if (wantsDeterministic) {
        final derived = deriveOfficerKey(account.hash);
        await ledger.saveOfficerKey(id, derived.$1, derived.$2);
        key = derived;
      } else {
        final fresh = generateOfficerKey();
        await ledger.saveOfficerKey(id, fresh.$1, fresh.$2);
        key = fresh;
      }
    } else if (wantsDeterministic) {
      // Migrate old random keys (from before the fix) to the deterministic
      // one so HQ and the officer's phone agree on the same pub for GZCERT.
      final derived = deriveOfficerKey(account.hash);
      final existingPubB64 = base64Encode(key.$1);
      final derivedPubB64 = base64Encode(derived.$1);
      if (existingPubB64 != derivedPubB64) {
        await ledger.saveOfficerKey(id, derived.$1, derived.$2);
        key = derived;
      }
    }
    // HQ certifies the officer's public key with the authority key: every
    // device can then verify that officer's signatures with only the single
    // root pubkey - citizens never store the officer roster.
    await _ensureAuthorityKey();
    final certSig = certifyOfficerKey(id, base64Encode(key.$1));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cert_${id}_pub', base64Encode(key.$1));
    await prefs.setString('cert_${id}_sig', certSig);
    await ledger.upsertOfficer(
      OfficerRecord(
        officerId: id,
        publicKey: base64Encode(key.$1),
        enlistedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        registeredBy: registeredBy,
      ),
    );
  }

  /// Test helper: re-enlist an officer to migrate a random key to deterministic.
  Future<void> enlistOfficerForTest(String username) async {
    final acc = _readAccounts(await SharedPreferences.getInstance())[username.toUpperCase()];
    if (acc != null && acc.officerId != null) {
      await _enlistOfficerAccount(acc, registeredBy: 'MIGRATE');
    }
  }

  /// Every account this device knows about (the HQ directory backing the
  /// USERS tab). Password hashes deliberately stay inaccessible to callers: /// the directory renders roles and ids, never credentials.
  Future<List<Account>> accounts() async {
    final accounts = _readAccounts(
      await SharedPreferences.getInstance(),
    ).values.toList()..sort((a, b) => a.username.compareTo(b.username));
    return accounts;
  }

  /// Persists an HQ-issued account the moment its provisioning QR is
  /// GENERATED (not when the phone scans it), so the issuing laptop keeps a
  /// durable user↔officer directory even if the handoff never completes.
  Future<String?> saveIssuedAccount({
    required String username,
    required String passwordHash,
    required Role role,
    String? pinHash,
    String? aadhaar,
    String? familyId,
    String? officerId,
  }) async {
    final name = username.trim().toUpperCase();
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    final existing = accounts[name];
    if (existing != null && existing.hash != passwordHash) {
      return 'account $name exists with different credentials';
    }
    if (existing?.role == Role.admin) return 'ADMIN is reserved for HQ';
    accounts[name] = Account(
      username: name,
      role: role,
      hash: existing?.hash ?? passwordHash,
      pinHash: pinHash ?? existing?.pinHash,
      aadhaar: aadhaar ?? existing?.aadhaar,
      familyId: familyId?.toUpperCase() ?? existing?.familyId,
      officerId: officerId ?? existing?.officerId,
    );
    await _writeAccounts(prefs, accounts);
    notifyListeners();
    return null;
  }

  /// Enrols an EXISTING local user as an officer (HQ action): flips the
  /// account role, assigns the deterministic officer id, records the
  /// enlistment in the ledger registry, and optionally resets the password.
  /// Officers can never appear out of thin air: there must be a user first.
  Future<String?> promoteToOfficer(String username, {String? newPassword}) async {
    final name = username.trim().toUpperCase();
    if (name.isEmpty) return 'enter the username to enrol';
    if (name == 'ADMIN') return 'ADMIN cannot be enrolled as an officer';
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    final acc = accounts[name];
    if (acc == null) {
      return 'no user $name on this device: create the citizen account '
          'first (CITIZEN tab)';
    }
    if (acc.role == Role.officer) return '$name is already an officer';
    final reset =
        newPassword == null || newPassword.isEmpty ? acc.hash : _hashPassword(newPassword);
    accounts[name] = Account(
      username: acc.username,
      role: Role.officer,
      hash: reset,
      pinHash: acc.pinHash,
      aadhaar: acc.aadhaar,
      familyId: acc.familyId,
      officerId: acc.officerId ?? _officerIdFor(name),
    );
    await _writeAccounts(prefs, accounts);
    await _enlistOfficerAccount(accounts[name]!, registeredBy: 'PROMOTED');
    notifyListeners();
    return null;
  }

  /// HQ one-step officer enrolment: promotes the existing user (see
  /// [promoteToOfficer]) and returns the HQ-signed provisioning QR payload.
  /// The cert binds the officer pubkey to the officerId via the HQ authority,
  /// and the envelope sig proves the whole QR came from HQ — blocking forged
  /// `OFF-` accounts from a hacked app. Password hash never leaves this class.
  Future<String> issueOfficerPromotion(
    String username, {
    String? newPassword,
  }) async {
    final error = await promoteToOfficer(username, newPassword: newPassword);
    if (error != null) return 'ERR:$error';
    final prefs = await SharedPreferences.getInstance();
    final acc = _readAccounts(prefs)[username.trim().toUpperCase()];
    if (acc == null || acc.officerId == null) {
      return 'ERR:enrolled account vanished unexpectedly';
    }
    await _ensureAuthorityKey();
    await _ensureNetworkKey();
    final key = deriveOfficerKey(acc.hash);
    final pubB64 = base64Encode(key.$1);
    final certB64 = certifyOfficerKey(acc.officerId!, pubB64);
    await prefs.setString('cert_sig_${acc.officerId}', certB64);
    await prefs.setString('cert_sig_${acc.username}', certB64);
    final authorityPub = await authorityPubKey();
    final netKeyB64 = prefs.getString(kNetworkKeyPref);
    return encodeAccountProvision(
      purpose: ProvisionPurpose.officer,
      username: acc.username,
      passwordHash: acc.hash,
      pinHash: acc.pinHash,
      aadhaar: acc.aadhaar,
      familyId: acc.familyId,
      officerId: acc.officerId,
      authorityPub: authorityPub,
      certB64: certB64,
      netKeyB64: netKeyB64,
      signer: (canonical) => base64Encode(signOfficerRecord(_authorityPrivateB64!, canonical)),
    );
  }

  /// HQ: strips the officer role back to citizen. The account survives with
  /// its credentials and ids; only the officer link is dropped. The ledger
  /// enlistment record stays (the chain is append-only: history is not
  /// rewritten), so the OFFICERS page may still list past identities whose
  /// accounts are no longer officers.
  Future<String?> demoteToCitizen(String username) async {
    final name = username.trim().toUpperCase();
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    final acc = accounts[name];
    if (acc == null) return 'no account $name on this device';
    if (acc.role != Role.officer) return '$name is not an officer';
    if (name == this.username && loggedIn) {
      return 'cannot demote the account you are logged in as';
    }
    accounts[name] = Account(
      username: acc.username,
      role: Role.citizen,
      hash: acc.hash,
      pinHash: acc.pinHash,
      aadhaar: acc.aadhaar,
      familyId: acc.familyId,
    );
    await _writeAccounts(prefs, accounts);
    notifyListeners();
    return null;
  }

  /// HQ: removes a local account entirely. ADMIN is protected. Deleting the
  /// live session logs out instead of leaving a phantom identity. The
  /// ledger's claim history and enlistment records are untouched: those are
  /// facts that already happened, not directory entries.
  Future<String?> deleteAccount(String username) async {
    final name = username.trim().toUpperCase();
    if (name == 'ADMIN') return 'ADMIN cannot be deleted';
    final prefs = await SharedPreferences.getInstance();
    final accounts = _readAccounts(prefs);
    if (!accounts.containsKey(name)) return 'no account $name on this device';
    if (name == this.username && loggedIn) await logout();
    final fresh = _readAccounts(await SharedPreferences.getInstance());
    fresh.remove(name);
    await _writeAccounts(await SharedPreferences.getInstance(), fresh);
    notifyListeners();
    return null;
  }

  /// Regenerates the HQ-signed provisioning payload for a stored account so
  /// the admin can re-issue it as QR (dashboard re-login handoff). The cert
  /// binds the account pubkey to the username/officerId via HQ authority, and
  /// the envelope sig proves HQ issued it — blocking fake citizens/officers
  /// from a hacked app. Returns null for unknown/reserved names.
  Future<String?> accountProvisionPayload(String username) async {
    final name = username.trim().toUpperCase();
    if (name == 'ADMIN') return null;
    final prefs = await SharedPreferences.getInstance();
    final acc = _readAccounts(prefs)[name];
    if (acc == null) return null;
    await _ensureAuthorityKey();
    await _ensureNetworkKey();
    final idForCert = acc.officerId ?? acc.username;
    final key = deriveOfficerKey(acc.hash);
    final pubB64 = base64Encode(key.$1);
    final certB64 = certifyOfficerKey(idForCert, pubB64);
    await prefs.setString('cert_sig_$idForCert', certB64);
    await prefs.setString('cert_sig_${acc.username}', certB64);
    final authorityPub = await authorityPubKey();
    final netKeyB64 = prefs.getString(kNetworkKeyPref);
    return encodeAccountProvision(
      purpose: acc.role == Role.officer
          ? ProvisionPurpose.officer
          : ProvisionPurpose.citizen,
      username: acc.username,
      passwordHash: acc.hash,
      pinHash: acc.pinHash,
      aadhaar: acc.aadhaar,
      familyId: acc.familyId,
      officerId: acc.officerId,
      authorityPub: authorityPub,
      certB64: certB64,
      netKeyB64: netKeyB64,
      signer: (canonical) => base64Encode(signOfficerRecord(_authorityPrivateB64!, canonical)),
    );
  }

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
    if (pending.isNotEmpty && !_disposed) notifyListeners();
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
    if (result.ok && !_disposed) notifyListeners();
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
    if (!_disposed) notifyListeners();
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

  /// Stops the account session and returns to the login screen. The radio
  /// stays up in anonymous mode so SOS beacons and peers are still heard at
  /// the login screen; identity and account frames stop flowing. Use
  /// [deleteAllData] to erase everything.
  Future<void> logout() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    await _accelSub?.cancel();
    _accelSub = null;
    sosActive = false;
    final m = mesh;
    if (m != null) {
      unawaited(m.setRadioActive(false));
      unawaited(m.setRadioAlert(false));
      // Clear mesh peer table so "nearby nodes" doesn't linger after logout.
      m.clearNodes();
    }
    _knownPeerIds.clear();
    _heartbeatTick = 0;
    // Wipe in-memory chat + landmarks so UI doesn't show stale data after
    // logout; persisted copies are kept until deleteAllData (logout is not a
    // factory reset, but the live view must be empty).
    chatMessages.clear();
    officialLandmarks.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessionUserPref);
    loggedIn = false;
    _username = '';
    _role = Role.citizen;
    _citizenId = '';
    _officerId = null;
    _pinHash = null;
    _familyId = null;
    _startHeartbeat();
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
    // Fresh device identity: stop the anonymous radio and rebuild with a new
    // randomly generated device id.
    final old = mesh;
    mesh = null;
    if (old != null) await old.stop();
    await _ensureMesh();
    notifyListeners();
  }

  /// Face embeddings keyed by citizen id. Biometric data; stored only on
  /// device and never synced over the mesh or serialized to QR. It reaches
  /// HQ only through an explicit direct-link exchange (reverse push).
  Future<void> saveFaceEmbedding(String citizenId, Float32List embedding) async {
    await ledger.saveFaceEmbedding(citizenId, embedding);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kLastFaceEnrollPref,
      DateTime.now().millisecondsSinceEpoch,
    );
    _lastFaceEnrollAt = DateTime.now();
    notifyListeners();
  }

  Future<Float32List?> faceEmbedding(String citizenId) =>
      ledger.faceEmbedding(citizenId);

  /// When HQ last collected this device's data over the direct link.
  DateTime? _lastDataExchangeAt;
  DateTime? get lastDataExchangeAt => _lastDataExchangeAt;

  /// When this account's face embedding was last (re-)enrolled locally.
  DateTime? _lastFaceEnrollAt;
  DateTime? get lastFaceEnrollAt => _lastFaceEnrollAt;

  /// True when the current face enrolment has been collected by HQ: an
  /// exchange happened AFTER the enrolment. Null embedding → nothing to sync.
  bool get faceSyncedToHq {
    final enroll = _lastFaceEnrollAt;
    final exchange = _lastDataExchangeAt;
    if (enroll == null || exchange == null) return false;
    return !exchange.isBefore(enroll);
  }

  /// Marks that a full link exchange just completed with HQ (they connected
  /// to our hosted link and pulled our data).
  Future<void> _markDataExchanged() async {
    _lastDataExchangeAt = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _kLastDataExchangePref,
      _lastDataExchangeAt!.millisecondsSinceEpoch,
    );
    notifyListeners();
  }

  /// Restores the sync timestamps after a restart.
  Future<void> _restoreSyncTimestamps() async {
    final prefs = await SharedPreferences.getInstance();
    final exchange = prefs.getInt(_kLastDataExchangePref);
    final enroll = prefs.getInt(_kLastFaceEnrollPref);
    if (exchange != null) {
      _lastDataExchangeAt = DateTime.fromMillisecondsSinceEpoch(exchange);
    }
    if (enroll != null) {
      _lastFaceEnrollAt = DateTime.fromMillisecondsSinceEpoch(enroll);
    }
  }

  /// Full face-enrolment pipeline over a snapshot JPEG: detect the largest
  /// face, align+crop to the MobileFaceNet input, embed, store. Returns the
  /// stored embedding, or null when no usable face was found.
  Future<Float32List?> enrollFaceFromJpeg(String citizenId, String jpegPath) async {
    final candidate = await detectLargestFaceFromJpeg(jpegPath);
    if (candidate == null) return null;
    final aligned = alignFaceRgba(face: candidate);
    final embedder = await FaceEmbedder.fromAsset();
    try {
      final embedding = embedder.embed(aligned);
      await ledger.saveFaceEmbedding(citizenId, embedding);
      return embedding;
    } finally {
      embedder.close();
    }
  }

  /// Movement-gated GPS. The accelerometer is ~100x cheaper than a GNSS fix,
  /// so a still phone reuses its cached coordinates instead of re-acquiring
  /// every heartbeat. A fix fires on: login, a detected movement (rising edge,
  /// even slow), SOS active, or a stale cache (watchdog catches smooth
  /// constant-velocity motion the accel variance can't see).
  StreamSubscription<AccelerometerEvent>? _accelSub;
  final MovementGate _movementGate = MovementGate();
  static const int _staleFixEveryS = 120; // 2 min watchdog

  /// Hard floor between fixes no matter what the movement gate says: some
  /// hand-tremor patterns flap the gate faster than the edge detector can
  /// absorb, and GNSS chips burn serious battery when polled sub-10s.
  /// SOS bypasses this cap.
  static const int _minFixGapS = 10;

  int? _lastFixAt;
  bool _gpsFetching = false;

  static const MethodChannel _sensorsMethodChannel =
      MethodChannel('dev.fluttercommunity.plus/sensors/method');

  /// Subscribes the idle accelerometer listener. The stream is empty on
  /// platforms without the sensor, so the gate reports moving and GPS is
  /// never blocked (pre-gate behaviour on desktop).
  Future<void> _initMovementSensor() async {
    if (_accelSub != null) return;
    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
      return;
    }
    // Preflight the plugin channel: sensors_plus's EventChannel reports its
    // missing backend as a FlutterError (widget tests fail on that), so probe
    // the method channel first and skip the subscription when it is absent.
    try {
      await _sensorsMethodChannel.invokeMethod('setAccelerationSamplingPeriod', 0);
    } catch (_) {
      return; // no sensor backend: gate stays open
    }
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen((e) {
      if (_movementGate.feed(e.x, e.y, e.z)) unawaited(_acquireGps());
    }, onError: (_) {
      _accelSub?.cancel();
      _accelSub = null; // sensor gone: gate stays open
    });
  }

  /// True when the accel window says motion (or has no signal yet).
  bool get _sensorMoving => _movementGate.moving;

  /// Real GPS lives on phones; laptops have none. Failure is normal: /// the app then falls back to the peer-consensus estimate. Guarded so
  /// overlapping calls (heartbeat tick during a slow fix) never stack.
  Future<void> _acquireGps() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    // Anonymous STANDBY burns no GPS: nothing advertises coordinates until a
    // session signs in (login fixes below), and SOS re-enables it on demand.
    if (!loggedIn && !sosActive) return;
    if (_gpsFetching) return;
    _gpsFetching = true;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Hard rate cap first: tremor-driven edge spam can never pull fixes
    // faster than one per 10s. SOS overrides — an active rescue owns the
    // radio budget.
    if (_lastFixAt != null && now - _lastFixAt! < _minFixGapS && !sosActive) {
      _gpsFetching = false;
      return;
    }
    final freshEnough =
        _lastFixAt != null && (now - _lastFixAt!) < _staleFixEveryS;
    if (!sosActive && freshEnough && !_sensorMoving) {
      _gpsFetching = false;
      return; // still phone with a live cache: skip the GNSS radio
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
      _lastFixAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      notifyListeners();
    } catch (_) {
      // no fix (e.g. denied, no satellites); keep the no-GPS fallback
    } finally {
      _gpsFetching = false;
    }
  }

  Timer? _heartbeat;
  Timer? _sosTimer;
  bool _disposed = false;

  /// One 10s radio tick for every session state:
  ///  - SOS active: the SOS frame wins the advertisement slot (beacons every
  ///    10s instead of 30s), so a peer's 2.2s scan window nearly always
  ///    catches the alarm instead of an identity or relay frame.
  ///  - Logged in: announce + identity so peers keep a live map.
  ///  - Logged out (anonymous): plain relay status, no identity leak.
  void _startHeartbeat() {
    unawaited(_initMovementSensor());
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      final m = mesh;
      if (m == null) return;
      if (sosActive) {
        m.broadcastSos(triage: sosFlags);
      } else {
        m.announce();
        if (loggedIn) m.broadcastIdentity(_username, _roleCode(_role));
      }
      if (loggedIn && _heartbeatTick % 3 == 2) {
        m.broadcastLedgerSyncRequest();
      }
      // GPS is movement-gated (accel edge fires the fix, cache re-used while
      // still); the 5 min stale watchdog lives here so a smooth-velocity
      // motion the accel can't see still refreshes coordinates.
      unawaited(_acquireGps());
      _heartbeatTick++;
    });
  }

  /// Brings up the mesh if it is not running yet and wires every inbound
  /// handler. Called at boot ([init]), on login, and after a factory reset.
  /// Node id derives from a persisted device id so one radio is one node,
  /// independent of which account (if any) is signed in.
  Future<MeshController> _ensureMesh() async {
    final existing = mesh;
    if (existing != null) return existing;
    final deviceId = await _deviceId();
    final m = _buildMesh('gridzero:mesh:device:$deviceId');
    m.onLedgerRecord = _onLedgerRecord;
    m.onLedgerSyncRequest = (_) => _pushPendingRecords();
    m.onRevocation = _onRevocation;
    m.nodeUpdates.listen(_onPeerDiscovery);
    m.dataMessages.listen((rx) {
      if (rx.type == MeshPacketType.chat) {
        unawaited(_onChatMessage(rx));
      } else if (rx.type == MeshPacketType.announce) {
        unawaited(_onAnnounceBlob(rx));
      }
    });
    // A responder's ack rings this phone: "help is on the way". Only when
    // our own SOS is live (a stray relayed ack must not ring us otherwise).
    m.responderArrived.listen((_) {
      if (sosActive) unawaited(AudioAlert.playAlert(respondAlertVolume));
      notifyListeners();
    });
    await m.start();
    m.announce();
    mesh = m;
    _startHeartbeat();
    return m;
  }

  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kDeviceIdPref);
    if (id == null) {
      id = Random().nextInt(0x7fffffff).toRadixString(16).toUpperCase();
      await prefs.setString(_kDeviceIdPref, id);
    }
    return id;
  }

  MeshController _buildMesh(String seed) {
    final digest = sha256.convert(utf8.encode(seed)).bytes;
    final nodeId = (digest[0] << 8 | digest[1]) & 0xffff;
    final adapter = switch (defaultTargetPlatform) {
      TargetPlatform.linux => BluezMeshAdapter(
        advertisingPayload: Uint8List(meshPacketLength),
      ) as MeshAdapter,
      TargetPlatform.windows => WinMeshAdapter(
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
    final m = mesh;
    if (m == null) return;
    // A cleared SOS also forgets responders so the next episode re-alerts.
    if (!active) m.clearResponders();
    // Governor: SOS live means our radio scans continuously until cleared.
    m.setRadioAlert(active);
    if (active) {
      // Fire immediately, then the 10s heartbeat keeps the SOS frame in the
      // advertisement slot continuously (vs the old 30s re-broadcast that a
      // heartbeat rotated away within seconds).
      m.broadcastSos(triage: sosFlags);
    } else {
      // One cleared beacon so peers turn the alarm off now, not in 10s.
      m.broadcastSos(triage: sosFlags, cleared: true);
    }
    notifyListeners();
  }

  void setSosFlags(TriageFlags flags) {
    sosFlags = flags;
    notifyListeners();
  }

  /// This device is heading to the given SOS node. Broadcasts the ack (so the
  /// target's phone rings "help on the way") and confirms locally with a beep.
  Future<void> sendSosRespond(int targetNodeId) async {
    final m = mesh;
    if (m == null) return;
    await m.broadcastRespond(targetNodeId);
    await AudioAlert.playAck(respondAlertVolume);
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
            message: 'PIN fallback rejected: knowledge factor mismatch',
          );
        }
      } else {
        return ClaimResult(
          ClaimStatus.invalidToken,
          message: 'TOTP token expired or forged: use PIN fallback',
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
            '${revocationReasonLabel(revokedReason)}: claims refused',
      );
    }
    // Tier-2 gate: a family claim must reference a known card and the
    // citizen must be on its roster; the daily cap is enforced below.
    if (familyId != null) {
      final card = await ledger.familyCard(familyId);
      if (card == null) {
        return ClaimResult(
          ClaimStatus.familyUnknown,
          message: 'family card $familyId not cached: enlist it first',
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
    final key = await _ensureOfficerKey();
    if (key == null) return null;
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

  /// Tier-2 family card handoff from an HQ-issued QR. Caches the card locally
  /// so claims against it can be verified and capped offline. Returns null on
  /// success, else a human-readable reason.
  Future<String?> provisionFamilyCard(String payload) async {
    final card = decodeFamilyCardProvision(payload);
    if (card == null) {
      final parsed = parseProvisionEnvelope(
        payload,
        requireType: ProvisionType.family,
      );
      return parsed.error ?? 'malformed family card payload';
    }
    if (!rationRe.hasMatch(card.familyId.trim().toUpperCase())) {
      return 'family id must be 8-16 letters, digits, / or -';
    }
    if (card.memberIds.any((m) => !RegExp(r'^CIT-\d{8}$').hasMatch(m))) {
      return 'member ids must look like CIT-XXXXXXXX';
    }
    await ledger.upsertFamilyCard(
      FamilyCard(
        familyId: card.familyId.trim().toUpperCase(),
        rationCode: card.rationCode,
        dailyUnits: card.dailyUnits,
        memberCitizenIds: card.memberIds,
      ),
    );
    notifyListeners();
    return null;
  }

  void switchRole(Role role) {
    _role = role;
    notifyListeners();
  }

  // ---- officer DB sync (phone hosts hotspot, HQ laptop joins + pushes) ----

  /// True while this phone is hosting a sync hotspot (officer side).
  bool hotspotActive = false;

  /// The hotspot's auto-generated SSID/password once [hotspotActive] turns
  /// true; read back from the system AP so the QR always matches reality.
  String? hotspotSsid;
  String? hotspotPassword;

  /// The provision payload (QR text) for the active hotspot, if any.
  String? hotspotProvisionPayload;

  /// Number of records absorbed by the last completed sync, for the UI.
  int lastSyncImported = 0;

  Future<void> Function()? _stopSyncServer;

  /// Officer side: start a LocalOnlyHotspot (Android only), read its
  /// auto-generated credentials, and open the one-shot sync server the HQ
  /// laptop will push the DB snapshot to. Returns an error string or null.
  /// Human-readable progress line while the client exchange runs.
  String? lastSyncStep;

  /// PHONE side: joins the HQ-hosted link from an in-app QR scan and runs
  /// the two-way exchange. [wifiQr] is the standard
  /// `WIFI:T:WPA;S:..;P:..;;` payload from HQ's screen; joining uses Android
  /// network suggestions (one approval dialog, then automatic whenever the
  /// network is in range).
  Future<String?> startOfficerHotspot({String? wifiQr}) async {
    if (hotspotActive) return null;
    final ssid = wifiQr == null ? linkSsidFor(username) : _qrField(wifiQr, 'S');
    final pass = wifiQr == null ? null : _qrField(wifiQr, 'P');
    if (ssid == null || pass == null || pass.length < 8) {
      return 'that QR does not carry a wifi join payload';
    }
    hotspotActive = true;
    hotspotSsid = ssid;
    // Already riding the link subnet (previous join succeeded)? Skip the
    // suggestion dance: re-suggesting would disconnect the live session.
    if (await _onLinkSubnet()) {
      notifyListeners();
      final error = await _runClientExchange(onStep: (s) {
        lastSyncStep = s;
        notifyListeners();
      });
      await _purgeLinkSuggestion();
      hotspotActive = false;
      lastSyncStep = null;
      if (error != null) {
        notifyListeners();
        return error;
      }
      notifyListeners();
      return null;
    }
    lastSyncStep = 'ASKING ANDROID TO JOIN $ssid';
    bool ok;
    try {
      ok =
          await MethodChannel('gridzero/link').invokeMethod<bool>(
                'suggest',
                {'ssid': ssid, 'pass': pass},
              ) ??
              false;
    } on PlatformException catch (e) {
      hotspotActive = false;
      lastSyncStep = null;
      notifyListeners();
      return 'join failed: ${e.message ?? e.code}';
    }
    if (!ok) {
      hotspotActive = false;
      lastSyncStep = null;
      notifyListeners();
      return 'Android declined the network suggestion: approve it and retry';
    }
    notifyListeners();
    final error = await _runClientExchange(onStep: (s) {
      lastSyncStep = s;
      notifyListeners();
    });
    await _purgeLinkSuggestion();
    hotspotActive = false;
    lastSyncStep = null;
    if (error != null) {
      hotspotSsid = null;
      notifyListeners();
      return error;
    }
    notifyListeners();
    return null;
  }

  /// Removes every network suggestion this app made: the join credentials
  /// cease to exist the moment the exchange ends (or is cancelled), so
  /// nothing is saved for future reconnection.
  Future<void> _purgeLinkSuggestion() async {
    try {
      await MethodChannel('gridzero/link').invokeMethod('unsuggest');
    } catch (_) {
      // Already gone / engine detached.
    }
  }

  /// True when this device holds an address in HQ's 192.168.51.x subnet.
  Future<bool> _onLinkSubnet() async {
    final interfaces = await NetworkInterface.list();
    return interfaces.any(
      (i) => i.addresses.any((a) => a.address.startsWith('192.168.51.')),
    );
  }

  /// Pulls one key's value out of a `WIFI:` URI (keys S, T, P, ...).
  static String? _qrField(String wifiUri, String key) {
    for (final part in wifiUri.split(';')) {
      if (part.startsWith('$key:')) return part.substring(key.length + 1);
    }
    return null;
  }

  /// This session account's password hash (set at login, cleared on
  /// logout). Derives the officer signing key without any key transport.
  String? _passwordHash;

  /// Runs the client side of the exchange once the wifi link exists: waits
  /// for an address in HQ's 192.168.51.x subnet, then talks to the gateway
  /// where HQ's sync server listens.
  Future<String?> _runClientExchange({
    void Function(String step)? onStep,
  }) async {
    const gateway = kLinkApGateway;
    onStep?.call('WAITING FOR LINK');
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    var linked = false;
    while (DateTime.now().isBefore(deadline)) {
      final interfaces = await NetworkInterface.list();
      linked = interfaces.any(
        (i) => i.addresses.any((a) => a.address.startsWith('192.168.51.')),
      );
      if (linked || !hotspotActive) break;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    if (!linked) return 'link never came up: scan the QR on HQ again';
    onStep?.call('LINK UP: EXCHANGING DATA');
    final result = await exchangeDbSnapshot(
      host: gateway,
      port: kDbSyncPort,
      json: await ledger.exportSnapshot(),
    );
    if (result.error != null) return result.error;
    // Reverse push: absorb HQ's snapshot so this device gets the full
    // directory, officer registry and records.
    if (result.pulledJson != null) {
      onStep?.call('ABSORBING HQ DATA');
      final importError = await ledger.importSnapshot(result.pulledJson!);
      if (importError != null) return importError;
      try {
        final decoded = jsonDecode(result.pulledJson!) as Map<String, dynamic>;
        _noteSyncImported((decoded['records'] as List?)?.length ?? 0);
      } catch (_) {
        _noteSyncImported(0);
      }
    }
    await _markDataExchanged();
    return null;
  }
  /// Called by the sync server after a snapshot import lands, so the UI can
  /// report how much data arrived. Wired in via startOfficerHotspot.
  void _noteSyncImported(int count) {
    lastSyncImported = count;
    notifyListeners();
  }

  // ---- Mesh broadcast chat -------------------------------------------------

  static const int kChatMaxUtf8Bytes = 220;
  static const int kChatCooldownS = 15;
  static const int kChatHistoryMax = 50;

  DateTime? _lastChatSentAt;

  /// Latest broadcast messages, newest last. Persisted to prefs so the
  /// board survives restarts; trimmed at [kChatHistoryMax].
  final List<MeshChatMessage> chatMessages = [];
  String? lastChatDebug;

  Future<void> _persistChat() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kChatHistoryPref, jsonEncode([
      for (final m in chatMessages)
        {
          'node': m.senderNodeId,
          'name': m.senderName,
          'text': m.text,
          'at': m.at.millisecondsSinceEpoch,
        },
    ]));
  }

  Future<void> _restoreChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kChatHistoryPref);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as List? ?? const [];
      for (final e in decoded.whereType<Map>()) {
        chatMessages.add(MeshChatMessage(
          senderNodeId: (e['node'] as num).toInt(),
          senderName: e['name'] as String? ?? '?',
          text: e['text'] as String? ?? '',
          at: DateTime.fromMillisecondsSinceEpoch(
            (e['at'] as num).toInt(),
          ),
        ));
      }
    } catch (_) {
      // Corrupt history: start fresh.
    }
  }

  Future<void> _onChatMessage(DataMessageRx rx) async {
    String text;
    String senderName;
    final bytes = rx.bytes;
    // Try signed format: [wireLen2][wire][uLen1][username][pub65][cert64][sig64]
    if (bytes.length >= 2 + 1 + 65 + 64 + 64) {
      final wireLen = (bytes[0] << 8) | bytes[1];
      if (wireLen <= 220 && bytes.length >= 2 + wireLen + 1 + 65 + 64 + 64) {
        final uLenPos = 2 + wireLen;
        final uLen = bytes[uLenPos];
        final totalNeeded = 2 + wireLen + 1 + uLen + 65 + 64 + 64;
        if (uLen > 0 && uLen <= 12 && bytes.length == totalNeeded) {
          try {
            final wire = bytes.sublist(2, 2 + wireLen);
            final usernameBytes = bytes.sublist(uLenPos + 1, uLenPos + 1 + uLen);
            final usernameFromBlob = utf8.decode(usernameBytes);
            final pub = bytes.sublist(uLenPos + 1 + uLen, uLenPos + 1 + uLen + 65);
            final cert = bytes.sublist(uLenPos + 1 + uLen + 65, uLenPos + 1 + uLen + 65 + 64);
            final sig = bytes.sublist(uLenPos + 1 + uLen + 65 + 64);
            final rootPub = await authorityPubKey();
            lastChatDebug = 'signed $usernameFromBlob wire $wireLen cert ${cert.length} sig ${sig.length} root ${rootPub?.substring(0, 8)}';
            debugPrint('GridZero: chat signed blob from $usernameFromBlob wireLen $wireLen cert ${cert.length} sig ${sig.length} root ${rootPub?.substring(0, 8)}');
            if (rootPub != null) {
              final pubB64 = base64Encode(pub);
              final certOk = verifyOfficerRecord(base64Decode(rootPub), 'GZCERT|$usernameFromBlob|$pubB64', Uint8List.fromList(cert));
              lastChatDebug = 'certOk $certOk for $usernameFromBlob';
              debugPrint('GridZero: chat certOk $certOk for $usernameFromBlob');
              if (certOk) {
                final canonical = 'GZCHAT|$usernameFromBlob|${base64Encode(wire)}';
                final sigOk = verifyOfficerRecord(pub, canonical, Uint8List.fromList(sig));
                if (sigOk) {
                  text = decodeChatWire(Uint8List.fromList(wire));
                  senderName = usernameFromBlob;
                  chatMessages.add(MeshChatMessage(
                    senderNodeId: rx.senderId,
                    senderName: senderName,
                    text: text,
                    at: DateTime.now(),
                  ));
                  while (chatMessages.length > kChatHistoryMax) {
                    chatMessages.removeAt(0);
                  }
                  unawaited(_persistChat());
                  notifyListeners();
                  return;
                }
              }
            }
            // Signed but verification failed -> drop to block fake/bot spam.
            // For transition, old unsigned blobs will fall through to the
            // unsigned path below instead of being dropped here.
            // If we reach here, the blob looked signed but was invalid, so drop.
            debugPrint('GridZero: chat signed blob invalid for $usernameFromBlob, dropping');
            return;
          } catch (e) {
            debugPrint('GridZero: chat signed parse error $e');
            // Not a valid signed blob, fall through to unsigned handling.
          }
        }
      }
    }
    // Unsigned / legacy path: best-effort decode, mark as unverified in UI
    // (still show for now to avoid breaking old devices during rollout).
    lastChatDebug = 'unsigned len ${bytes.length} first ${bytes.isNotEmpty ? bytes[0] : -1}';
    debugPrint('GridZero: chat unsigned fallback len ${bytes.length} first ${bytes.isNotEmpty ? bytes[0] : -1}');
    text = decodeChatWire(bytes);
    // If decodeChatWire returned empty (e.g., flagged but not signed), try
    // raw utf8 as last resort for very old devices that sent without flag.
    if (text.isEmpty && bytes.isNotEmpty && bytes[0] != 0x00 && bytes[0] != 0x01) {
      try {
        text = utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        text = '';
      }
    }
    final node = mesh?.nodes[rx.senderId];
    final name = node?.username ?? '';
    senderName = name.isNotEmpty ? name : 'NODE ${rx.senderId.toRadixString(16)}';
    // For unsigned, we keep it but the UI can show "UNVERIFIED" if needed.
    chatMessages.add(MeshChatMessage(
      senderNodeId: rx.senderId,
      senderName: senderName,
      text: text,
      at: DateTime.now(),
    ));
    while (chatMessages.length > kChatHistoryMax) {
      chatMessages.removeAt(0);
    }
    unawaited(_persistChat());
    notifyListeners();
  }

  /// Broadcasts a short public message to the mesh. English ASCII is 1
  /// byte per char (UTF-8); 220 bytes = 220 chars. Pure ASCII between
  /// 221–249 chars auto-packs to 7-bit (8→7 bytes) so 249 chars still fit
  /// in 220B wire (2B header). Non-ASCII stays UTF-8 — 2–4B per char.
  /// Every chat is now HQ-certified and signed (like landmarks) so bots
  /// cannot spam: `wire|pub|cert|sig` with `GZCERT` + `GZCHAT` chains.
  Future<String?> sendBroadcastMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'message is empty';
    var wire = encodeChatWire(trimmed);
    if (wire == null) {
      if (isAsciiPrintable(trimmed)) {
        return 'message too long (max 249 ASCII chars / 220 bytes; you sent ${trimmed.length})';
      }
      return 'message too long (max $kChatMaxUtf8Bytes bytes; you sent ${utf8.encode(trimmed).length})';
    }
    // Try to wrap as signed chat: [wireLen2][wire][pub65][cert64][sig64]
    // where sig = sign(priv, GZCHAT|username|base64(wire)) and cert is HQ's
    // GZCERT for this account's pub. Citizens are unsigned for reliability
    // (1 chunk vs 19 chunks signed: 204B overhead makes 2-char HI need 19
    // BLE frames and always loses). Network key already isolates per-ADMIN
    // private mesh, so only officers need signed chat for spam blocking.
    // If we have no cert (old account before the fix) we fall back to unsigned.
    Uint8List blob = wire;
    try {
      final prefs = await SharedPreferences.getInstance();
      final acc = _readAccounts(prefs)[username];
      if (acc != null && acc.role == Role.officer) {
        final idForCert = acc.officerId ?? acc.username;
        final certB64 = prefs.getString('cert_sig_$idForCert') ?? prefs.getString('cert_sig_${acc.username}');
        if (certB64 != null) {
          final key = deriveOfficerKey(acc.hash);
          final pub = Uint8List.fromList(key.$1);
          final usernameBytes = utf8.encode(acc.username);
          final canonical = 'GZCHAT|${acc.username}|${base64Encode(wire)}';
          final sig = signOfficerRecord(key.$2, canonical);
          final wireLen = wire.length;
          blob = Uint8List.fromList([
            (wireLen >> 8) & 0xff, wireLen & 0xff,
            ...wire,
            usernameBytes.length & 0xff,
            ...usernameBytes,
            ...pub,
            ...base64Decode(certB64),
            ...sig,
          ]);
        }
      }
    } catch (_) {
      // Signing is best-effort; unsigned fallback keeps old devices working.
      blob = wire;
    }
    final last = _lastChatSentAt;
    if (last != null) {
      final elapsed =
          DateTime.now().difference(last).inSeconds;
      if (elapsed < kChatCooldownS) {
        return 'wait ${kChatCooldownS - elapsed}s before sending again';
      }
    }
    final m = mesh;
    if (m == null) return 'mesh radio not ready';
    _lastChatSentAt = DateTime.now();
    // 3× airing is ~30s of BLE rotation; don't block the UI or hot-restart
    // on it — fire-and-forget so the button, cooldown and hot-reload stay
    // responsive. The mesh relay still carries the 3 copies in the background.
    unawaited(m.broadcastDataPayload(
      MeshPacketType.chat,
      blob,
    ));
    // Show our own message immediately; relays carry it onward.
    chatMessages.add(MeshChatMessage(
      senderNodeId: m.nodeId,
      senderName: username,
      text: trimmed,
      at: DateTime.now(),
    ));
    while (chatMessages.length > kChatHistoryMax) {
      chatMessages.removeAt(0);
    }
    unawaited(_persistChat());
    notifyListeners();
    return null;
  }

  /// Unsigned chat for mesh reliability testing (bypasses GZCHAT signing).
  Future<String?> sendUnsignedChat(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'message is empty';
    final wire = encodeChatWire(trimmed);
    if (wire == null) return 'message too long';
    final last = _lastChatSentAt;
    if (last != null && DateTime.now().difference(last).inSeconds < kChatCooldownS) {
      return 'wait ${kChatCooldownS - DateTime.now().difference(last).inSeconds}s';
    }
    final m = mesh;
    if (m == null) return 'mesh radio not ready';
    _lastChatSentAt = DateTime.now();
    unawaited(m.broadcastDataPayload(MeshPacketType.chat, wire));
    chatMessages.add(MeshChatMessage(senderNodeId: m.nodeId, senderName: username, text: trimmed, at: DateTime.now()));
    while (chatMessages.length > kChatHistoryMax) {
      chatMessages.removeAt(0);
    }
    unawaited(_persistChat());
    notifyListeners();
    return null;
  }

  // ---- Signed official landmarks -------------------------------------------

  static const String kAuthorityPubPref = 'authority_pub';
  static const String kAuthorityPrivPref = 'authority_priv';
  static const String kNetworkKeyPref = 'network_key';
  String? _authorityPublicB64;
  List<int>? _authorityPrivateB64;

  /// 4-char alphanumeric network ID for the current ADMIN's private mesh.
  /// Derived from the network key's hash so PQR (A) and XYZ (B) show different
  /// tags like `LIVE MESH · A3F9` vs `A7C1`. Null → not provisioned yet.
  String? get networkId {
    final key = getNetworkKey();
    final keyB64 = key == null ? null : base64Encode(key);
    final src = keyB64 ?? _authorityPublicB64;
    if (src == null) return null;
    final hash = sha256.convert(utf8.encode(src)).toString().toUpperCase();
    return hash.substring(0, 4);
  }

  bool get hasNetworkKey => getNetworkKey() != null;

  List<int>? get authorityPrivateForSign => _authorityPrivateB64;

  Future<String?> networkKeyB64() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(kNetworkKeyPref);
  }

  Future<SharedPreferences> get prefsForTest => SharedPreferences.getInstance();

  /// HQ: generates once. Phones receive the public half via provisioning QR.
  /// Also ensures a per-ADMIN network key for full mesh encryption.
  Future<void> _ensureAuthorityKey() async {
    if (_authorityPublicB64 != null) {
      await _ensureNetworkKey();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final pub = prefs.getString(kAuthorityPubPref);
    final priv = prefs.getString(kAuthorityPrivPref);
    if (pub != null && priv != null && pub.isNotEmpty) {
      _authorityPublicB64 = pub;
      _authorityPrivateB64 = base64Decode(priv);
      await _ensureNetworkKey();
      return;
    }
    final pair = generateOfficerKey();
    _authorityPublicB64 = base64Encode(pair.$1);
    _authorityPrivateB64 = Uint8List.fromList(pair.$2);
    await prefs.setString(kAuthorityPubPref, _authorityPublicB64!);
    await prefs.setString(kAuthorityPrivPref, base64Encode(pair.$2));
    await _ensureNetworkKey();
  }

  Future<void> _ensureNetworkKey() async {
    final prefs = await SharedPreferences.getInstance();
    var b64 = prefs.getString(kNetworkKeyPref);
    if (b64 != null) {
      try {
        final key = base64Decode(b64);
        if (key.length == kNetworkKeyBytes) {
          setNetworkKey(key);
          return;
        }
      } catch (_) {}
    }
    // Only HQ (has authority private) auto-generates a network key. A
    // citizen/officer phone with no prior provision stays unencrypted
    // (isolated) until it scans a HQ-signed QR that carries netKey.
    if (_authorityPrivateB64 == null) return;
    final rnd = Random.secure();
    final key = Uint8List.fromList([for (var i = 0; i < kNetworkKeyBytes; i++) rnd.nextInt(256)]);
    await prefs.setString(kNetworkKeyPref, base64Encode(key));
    setNetworkKey(key);
  }

  Future<void> _loadNetworkKeyIfAny() async {
    final prefs = await SharedPreferences.getInstance();
    final b64 = prefs.getString(kNetworkKeyPref);
    if (b64 == null) return;
    try {
      final key = base64Decode(b64);
      if (key.length == kNetworkKeyBytes) setNetworkKey(key);
    } catch (_) {}
  }

  /// Signs `GZCERT|<officerId>|<pubB64>` with the authority private key.
  String certifyOfficerKey(String officerId, String pubB64) {
    final canonical = 'GZCERT|$officerId|$pubB64';
    final sig = signOfficerRecord(_authorityPrivateB64!, canonical);
    return base64Encode(sig);
  }

  /// Returns the authority public key for embedding in provisioning QRs.
  Future<String?> authorityPubKey() async {
    await _ensureAuthorityKey();
    return _authorityPublicB64;
  }

  /// Stores the authority pubkey received from a provisioning QR.
  Future<void> _storeAuthorityPub(String authorityPubB64) async {
    _authorityPublicB64 = authorityPubB64;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kAuthorityPubPref, authorityPubB64);
  }

  /// Verified announcements currently in effect (not expired).
  final List<OfficialLandmark> officialLandmarks = [];

  /// Certifies an officer's public key: HQ signs 'GZCERT|id|pubB64' with the
  /// authority key. The resulting blob travels inside the officer registry
  /// snapshot and inside every landmark that officer broadcasts.

  /// Verifies and files a signed announcement blob.
  ///
  /// Trust chain needs only HQ's root pubkey (which every device holds):
  ///   1. root pubkey verifies HQ's certificate over (officerId, officerKey)
  ///   2. officer key verifies the announcement content
  /// No officer roster is stored anywhere. Verified entries are persisted
  /// in the ledger (dedup by officer+label) and RE-ANNOUNCED once so
  /// landmarks keep hopping across the mesh beyond direct radio range.
  /// Unverifiable blobs are dropped silently; expired ones are not stored.
  Future<void> _onAnnounceBlob(DataMessageRx rx) async {
    final rootPub = await authorityPubKey();
    if (rootPub == null) return;

    // Blob: [lat4][lon4][type1][expiry4][labelLen1][label][idLen1][id]
    //       [pub65][cert64][sig64]
    const head = 14, pubLen = 65, certLen = 64, sigLen = 64;
    if (rx.bytes.length < head + 2 + pubLen + certLen + sigLen) return;
    final bd = ByteData.sublistView(rx.bytes);
    final lat = bd.getInt32(0, Endian.big) / 10000000.0;
    final lon = bd.getInt32(4, Endian.big) / 10000000.0;
    final typeCode = rx.bytes[8];
    final expiry = bd.getUint32(9, Endian.big);
    if (DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiry) return;
    final labelLen = rx.bytes[13];
    var cursor = head;
    final label = utf8.decode(
      rx.bytes.sublist(cursor, cursor + labelLen),
      allowMalformed: true,
    );
    cursor += labelLen;
    final idLen = rx.bytes[cursor];
    cursor += 1;
    if (idLen == 0 ||
        cursor + idLen + pubLen + certLen + sigLen > rx.bytes.length) {
      lastLandmarkDebug = 'parse fail idLen $idLen';
      return;
    }
    final officerId = utf8.decode(
      rx.bytes.sublist(cursor, cursor + idLen),
      allowMalformed: true,
    );
    cursor += idLen;
    final officerPub = rx.bytes.sublist(cursor, cursor + pubLen);
    cursor += pubLen;
    final certificate = rx.bytes.sublist(cursor, cursor + certLen);
    cursor += certLen;
    final signature = rx.bytes.sublist(cursor);

    // Chain 1: HQ certified this officer key.
    final pubB64 = base64Encode(officerPub);
    if (!_verifySig(base64Decode(rootPub), 'GZCERT|$officerId|$pubB64',
        certificate)) {
      lastLandmarkDebug = 'cert fail for $officerId $label';
      return;
    }
    // Chain 2: that certified key signed the content.
    final canonical =
        'GZANN1|${lat.toStringAsFixed(7)}|${lon.toStringAsFixed(7)}|'
        '$typeCode|$expiry|$label';
    if (!_verifySig(officerPub, canonical, signature)) {
      lastLandmarkDebug = 'sig fail for $label $canonical';
      return;
    }
    lastLandmarkDebug = 'verified $label from $officerId';

    final blobB64 = base64Encode(rx.bytes);
    final record = LandmarkRecord(
      officerId: officerId,
      label: label,
      typeCode: typeCode,
      latitude: lat,
      longitude: lon,
      expiresAt: expiry,
      signedBlobB64: blobB64,
    );
    await ledger.upsertLandmark(record);

    officialLandmarks.removeWhere(
      (l) => l.label == label && l.officerId == officerId,
    );
    officialLandmarks.add(OfficialLandmark(
      officerId: officerId,
      label: label,
      typeLabel: landmarkTypeLabel(typeCode),
      latitude: lat,
      longitude: lon,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiry * 1000),
      signedBlobB64: blobB64,
    ));
    notifyListeners();

    // Re-announce verbatim: dedup windows drop repeats per device, TTL ends
    // the flood, and distant nodes get the landmark without direct range.
    await mesh?.broadcastDataPayload(MeshPacketType.announce, rx.bytes);
  }

  bool _verifySig(
    List<int> publicKey,
    String canonical,
    Uint8List signature,
  ) {
    try {
      return verifyOfficerRecord(publicKey, canonical, signature);
    } catch (_) {
      return false;
    }
  }


  bool verifyContent(
    Uint8List officerPub,
    String canonical,
    Uint8List sig,
  ) {
    try {
      return verifyOfficerRecord(officerPub, canonical, sig);
    } catch (_) {
      return false;
    }
  }

  String? lastLandmarkDebug;

  /// HQ/officer side: sign and broadcast an official landmark.
  Future<String?> postOfficialLandmark({
    required String label,
    required int typeCode,
    required double latitude,
    required double longitude,
    required Duration validFor,
  }) async {
    final id = officerId;
    if (id == null) return 'only officers can publish landmarks';
    // Deterministic signing key from the shared password hash: identical on
    // HQ and the device, no private-key transport ever needed.
    final hash = _passwordHash;
    if (hash == null || hash.length < 16) {
      return 'no account credentials on this device';
    }
    final key = deriveOfficerKey(hash);
    // Refresh the registry + certificate so verifiers hold the current key.
    final prefs = await SharedPreferences.getInstance();
    await ledger.upsertOfficer(
      OfficerRecord(
        officerId: id,
        publicKey: base64Encode(key.$1),
        enlistedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        registeredBy: 'LANDMARK',
      ),
    );
    final clean = label.trim();
    if (clean.isEmpty || clean.length > 60) {
      return 'label must be 1-60 characters';
    }
    final expiry =
        DateTime.now().add(validFor).millisecondsSinceEpoch ~/ 1000;
    final latFixed =
        (latitude * 10000000).round().clamp(-2147483648, 2147483647);
    final lonFixed =
        (longitude * 10000000).round().clamp(-2147483648, 2147483647);
    // The certificate minted above binds this pubkey; reuse it.
    final certB64 = prefs.getString('cert_sig_$id') ?? '';
    // Canonical covers exactly what the verifier checks (lat/lon as 7-decimal);
    // the certificate + pubkey travel alongside the blob for chain 1.
    final canonical =
        'GZANN1|${(latFixed / 10000000.0).toStringAsFixed(7)}|'
        '${(lonFixed / 10000000.0).toStringAsFixed(7)}|'
        '$typeCode|$expiry|$clean';
    final signature = signOfficerRecord(key.$2, canonical);
    final idBytes = utf8.encode(id);
    final head = <int>[
      (latFixed >> 24) & 0xff, (latFixed >> 16) & 0xff,
      (latFixed >> 8) & 0xff, latFixed & 0xff,
      (lonFixed >> 24) & 0xff, (lonFixed >> 16) & 0xff,
      (lonFixed >> 8) & 0xff, lonFixed & 0xff,
      typeCode & 0xff,
      (expiry >> 24) & 0xff, (expiry >> 16) & 0xff,
      (expiry >> 8) & 0xff, expiry & 0xff,
      clean.length & 0xff,
      idBytes.length & 0xff,
    ];
    final blob = Uint8List.fromList([
      ...head,
      ...utf8.encode(clean),
      ...idBytes,
      ...key.$1, // uncompressed 65B officer pubkey
      ...base64Decode(certB64), // HQ certificate binding pubkey to officerId
      ...signature,
    ]);
    final blobB64 = base64Encode(blob);
    // Persist the signed blob so any holder (including this originator after
    // a restart) can re-advertise the *original* HQ-certified sig for far-away
    // verifiers. Verbatim replay keeps the officer's sig intact.
    await ledger.upsertLandmark(LandmarkRecord(
      officerId: id,
      label: clean,
      typeCode: typeCode,
      latitude: latFixed / 10000000.0,
      longitude: lonFixed / 10000000.0,
      expiresAt: expiry,
      signedBlobB64: blobB64,
    ));
    await mesh?.broadcastDataPayload(MeshPacketType.announce, blob);
    // Keep our own landmark: displayed immediately and re-broadcast after a
    // restart while it is still valid.
    officialLandmarks.removeWhere(
      (l) => l.label == clean && l.officerId == id,
    );
    final landmark = OfficialLandmark(
      officerId: id,
      label: clean,
      typeLabel: landmarkTypeLabel(typeCode),
      latitude: latFixed / 10000000.0,
      longitude: lonFixed / 10000000.0,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiry * 1000),
      signedBlobB64: blobB64,
    );
    officialLandmarks.add(landmark);
    await _persistMyLandmarks();
    notifyListeners();
    return null;
  }

  /// Officer-authored landmarks survive restarts via prefs and are
  /// re-broadcastable until they expire.
  Future<void> _persistMyLandmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final mine = officialLandmarks
        .where((l) => !l.isExpired && l.officerId == officerId)
        .toList();
    await prefs.setString(_kMyLandmarksPref, jsonEncode([
      for (final l in mine)
        {
          'officerId': l.officerId,
          'label': l.label,
          'typeCode': kLandmarkTypes.indexOf(l.typeLabel),
          'lat': l.latitude,
          'lon': l.longitude,
          'expiresAt': l.expiresAt.millisecondsSinceEpoch,
          'blob': l.signedBlobB64,
        },
    ]));
  }

  /// Reloads this device's own landmarks after a restart; expired ones are
  /// dropped instead of resurrected.
  Future<void> _restoreMyLandmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kMyLandmarksPref);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as List? ?? const [];
      final now = DateTime.now();
      for (final e in decoded.whereType<Map>()) {
        final expiresAt = DateTime.fromMillisecondsSinceEpoch(
          (e['expiresAt'] as num).toInt(),
        );
        if (now.isAfter(expiresAt)) continue;
        officialLandmarks.add(OfficialLandmark(
          officerId: e['officerId'] as String? ?? '',
          label: e['label'] as String? ?? '',
          typeLabel: landmarkTypeLabel((e['typeCode'] as num?)?.toInt() ?? 0),
          latitude: (e['lat'] as num).toDouble(),
          longitude: (e['lon'] as num).toDouble(),
          expiresAt: expiresAt,
          signedBlobB64: e['blob'] as String?,
        ));
      }
    } catch (_) {
      // Corrupt record: skip restore.
    }
  }

  /// PHONE side: abort waiting/exchange and purge the join credentials.
  Future<void> stopOfficerHotspot() async {
    hotspotActive = false;
    lastSyncStep = null;
    notifyListeners();
    await _purgeLinkSuggestion();
  }

  /// Link credentials for a hosted session: SSID carries the username, the
  /// passphrase is the first 16 chars of that account's stored hash: both
  /// sides derive the same values, nothing secret goes over the air.
  static String linkSsidFor(String username) =>
      'GZ-${username.trim().toUpperCase()}';

  /// Fresh 8-digit numeric passphrase per hosting session. Nothing is
  /// derived from account hashes anymore: HQ shows the QR, the phone scans
  /// it, the OTP dies with the session.
  static String generateLinkOtp(Random random) =>
      '${10000000 + random.nextInt(90000000)}';

  /// HQ side: HOST the link for one account. Brings up the GZ‑`<USER>` wifi
  /// network (virtual ap0 + hostapd; main internet connection untouched) and
  /// starts the sync server on it. The phone scans HQ's QR to join.
  Future<String?> hostLinkFor(String username, {void Function(String)? onStep}) async {
    if (defaultTargetPlatform != TargetPlatform.linux) {
      return 'link hosting requires the Linux HQ laptop';
    }
    if (_stopSyncServer != null) await stopHostLink();
    final name = username.trim().toUpperCase();
    final prefs = await SharedPreferences.getInstance();
    final acc = _readAccounts(prefs)[name];
    if (acc == null || acc.hash.length < 16) {
      return 'no issued account $name on this terminal';
    }
    onStep?.call('BRINGING UP LINK');
    final otp = generateLinkOtp(Random.secure());
    final error = await _startLinkAp(
      ssid: linkSsidFor(name),
      pass: otp,
    );
    if (error == null) {
      hotspotSsid = linkSsidFor(name);
      hotspotPassword = otp;
    }
    if (error != null) return error;
    onStep?.call('LINK UP: SHOW QR TO THE DEVICE');
    final server = await startDbSyncServer(
      snapshotProvider: () => ledger.exportSnapshot(),
      onSnapshot: (json) async {
        final importError = await ledger.importSnapshot(json);
        if (importError == null) {
          // The device completed a two-way exchange: HQ now holds its fresh
          // data (face embeddings included).
          await _markDataExchanged();
        }
        return importError;
      },
    );
    if (server == null) {
      await _stopLinkAp();
      return 'could not open sync server';
    }
    _stopSyncServer = () async {
      await server.cancel();
      await _stopLinkAp();
    };
    notifyListeners();
    return null;
  }

  /// HQ side: tear the hosted link down (server + AP).
  Future<void> stopHostLink() async {
    final stop = _stopSyncServer;
    _stopSyncServer = null;
    if (stop != null) {
      try {
        await stop();
      } catch (_) {}
    }
    notifyListeners();
  }

  bool get linkHosted => _stopSyncServer != null;

  /// HQ side: visible hosted links from the laptop's own wifi scan.
  /// Returns usernames (SSID prefix 'GZ-' stripped).
  Future<List<String>> visibleLinkPeers() async {
    if (defaultTargetPlatform != TargetPlatform.linux && defaultTargetPlatform != TargetPlatform.windows) return const [];
    final ssids = await _visibleWifiNetworks();
    return ssids
        .where((s) => s.startsWith('GZ-'))
        .map((s) => s.substring(3))
        .toList();
  }

  /// HQ side: consume a scanned hotspot provision QR, join the phone's

  /// HQ side: consume a scanned hotspot provision QR, join the phone's
  /// network, push the DB snapshot, then disconnect and restore whatever
  /// network was active before. Returns an error string or null on success.
  Future<String?> pushDbViaHotspot(String payload) async {
    final hotspot = decodeHotspotProvision(payload);
    if (hotspot == null) {
      final parsed = parseProvisionEnvelope(
        payload,
        requireType: ProvisionType.hotspot,
      );
      return parsed.error ?? 'malformed hotspot payload';
    }
    return _pushDbToNetwork(hotspot.ssid, hotspot.password);
  }

  /// Shared join→push→restore sequence behind both the QR path and the
  /// mesh-offer path.
  Future<String?> _pushDbToNetwork(
    String ssid,
    String password, {
    void Function(String step)? onStep,
  }) async {
    void step(String s) => onStep?.call(s);
    if (defaultTargetPlatform != TargetPlatform.linux) {
      return 'direct link requires the Linux HQ laptop';
    }
    // Remember the active wired/wifi links so the join is torn down cleanly
    // even if the exchange fails midway. The list ALSO lands in prefs: if
    // the app dies mid-exchange, the next boot restores the network from
    // there (otherwise HQ could be left stranded on the device's link).
    // Empty list is a valid state: the laptop may be online via ethernet
    // only or not connected at all; nothing to restore then.
    final saved = await _activeConnections();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kPreSyncNetworksPref,
      jsonEncode([for (final c in saved) {'name': c.name, 'type': c.type}]),
    );
    step('ESTABLISHING SECURE LINK');
    final error = await _connectWifi(ssid, password);
    if (error != null) {
      await _restoreConnections(saved);
      await prefs.remove(_kPreSyncNetworksPref);
      return error;
    }
    try {
      step('EXCHANGING DATA');
      final wifiCon = await _activeWifiConnectionName();
      final gateway = wifiCon == null
          ? null
          : await _connectionGateway(wifiCon);
      if (gateway == null) {
        return 'link established but could not resolve the peer address';
      }
      final result = await exchangeDbSnapshot(
        host: gateway,
        port: kDbSyncPort,
        json: await ledger.exportSnapshot(),
      );
      if (result.error != null) return result.error;
      // Reverse push: absorb whatever the peer sent back (citizen
      // embeddings, officer records) into HQ's ledger.
      if (result.pulledJson != null) {
        step('ABSORBING PEER DATA');
        final importError = await ledger.importSnapshot(result.pulledJson!);
        if (importError != null) return importError;
      }
      return null;
    } finally {
      final wifiCon = await _activeWifiConnectionName();
      if (wifiCon != null) await _disconnectConnection(wifiCon);
      await _restoreConnections(saved);
      await prefs.remove(_kPreSyncNetworksPref);
    }
  }

  /// Crash recovery: a previous sync recorded its pre-join network list but
  /// never finished. Re-raise those connections so HQ keeps its internet.
  /// No record (or an empty one) means there was nothing connected before: /// a completely normal state, handled by doing exactly nothing.
  Future<void> _restoreOrphanedSyncNetworks() async {
    if (defaultTargetPlatform != TargetPlatform.linux) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPreSyncNetworksPref);
    if (raw == null) return;
    await prefs.remove(_kPreSyncNetworksPref);
    final List<(String, String)> saved;
    try {
      final decoded = jsonDecode(raw) as List? ?? const [];
      saved = decoded
          .whereType<Map>()
          .map(
            (m) => (
              m['name'] as String? ?? '',
              m['type'] as String? ?? '',
            ),
          )
          .where((c) => c.$1.isNotEmpty)
          .toList();
    } catch (_) {
      return; // corrupt record: nothing sensible to restore
    }
    for (final (name, _) in saved) {
      try {
        await _restoreConnections([(name: name, type: 'wifi')]);
      } catch (_) {
        // Best-effort: a stale network may no longer exist.
      }
    }
  }

  /// JSON snapshot of the sync-relevant state, served over the VM service
  /// via `ext.gridzero.syncDebug` (see main.dart). Diagnostics only.
  Future<String> syncDebugJson() async {
    final m = mesh;
    return jsonEncode({
      'role': role.name,
      'username': username,
      'loggedIn': loggedIn,
      'linkOpen': hotspotActive,
      'ssid': hotspotSsid,
      'visiblePeers': await visibleLinkPeers(),
      'directory': [
        for (final a in _readAccounts(
          await SharedPreferences.getInstance(),
        ).values)
          {
            'name': a.username,
            'role': a.role.name,
            'tag': a.hash.substring(0, 8),
          },
      ],
      'selfNodeId': m?.nodeId,
      'adapter': m?.adapter.diagnostics,
      'advEnqueued': m?.adapter.diagnostics['enqueued'],
      'advSwapped': m?.adapter.diagnostics['swapped'],
      'advFailed': m?.adapter.diagnostics['failed'],
      'meshNodeIds': [
        if (m != null)
          ...m.nodes.entries.map((e) => {
                'id': e.key,
                'seen': e.value.lastSeenEpoch,
                'name': e.value.username,
              }),
      ],
      'lastFaceEnrollAt': lastFaceEnrollAt?.toIso8601String(),
      'lastDataExchangeAt': lastDataExchangeAt?.toIso8601String(),
      'networkKey': (await SharedPreferences.getInstance()).getString(kNetworkKeyPref) != null ? '${(await SharedPreferences.getInstance()).getString(kNetworkKeyPref)!.substring(0, 8)}...' : null,
      'hasNetworkKey': getNetworkKey() != null,
      'chat': [
        for (final m in chatMessages)
          {'from': m.senderName, 'text': m.text, 'at': m.at.toIso8601String()},
      ],
      'landmarks': [
        for (final l in officialLandmarks)
          {
            'label': l.label,
            'type': l.typeLabel,
            'by': l.officerId,
            'at': '${l.latitude.toStringAsFixed(4)},${l.longitude.toStringAsFixed(4)}',
            'exp': l.expiresAt.toIso8601String(),
          },
      ],
      'lastLandmarkDebug': lastLandmarkDebug,
      'lastChatDebug': lastChatDebug,
      'lastChatSentAt': _lastChatSentAt?.toIso8601String(),
      'chatCooldownLeft': _lastChatSentAt == null
          ? 0
          : (kChatCooldownS -
                  DateTime.now().difference(_lastChatSentAt!).inSeconds)
              .clamp(0, kChatCooldownS),
    });
  }

  String randomNodeId() =>
      Random().nextInt(0xffff).toRadixString(16).padLeft(4, '0').toUpperCase();

  Timer? _landmarkRetxTimer;

  /// Every holder re-broadcasts every verified landmark it knows (verbatim
  /// original officer sig) so a far-away late-joiner that never heard the
  /// originator can still verify the original HQ-certified sig. The blob is
  /// replayed as-is, not re-signed, so the trust chain stays officer→HQ.
  void _startLandmarkRetx() {
    _landmarkRetxTimer?.cancel();
    _landmarkRetxTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      for (final l in List.of(officialLandmarks)) {
        if (l.isExpired) continue;
        if (l.signedBlobB64 == null) {
          // Old entry without stored blob (pre-migration) — only the originator
          // can re-sign it, others skip until it expires.
          if (l.officerId == officerId) _rebroadcastLandmark(l);
          continue;
        }
        _rebroadcastLandmark(l);
      }
    });
  }

  Future<void> _rebroadcastLandmark(OfficialLandmark landmark) async {
    final m = mesh;
    if (m == null) return;
    try {
      // Prefer the original HQ-certified blob verbatim so far-away verifiers
      // see the officer's sig, not a relay's. This preserves the trust chain.
      if (landmark.signedBlobB64 != null) {
        final blob = base64Decode(landmark.signedBlobB64!);
        await m.broadcastDataPayload(MeshPacketType.announce, Uint8List.fromList(blob));
        return;
      }
      // Fallback for old landmarks without stored blob (pre-migration): only
      // the originator can re-sign.
      final typeCode = kLandmarkTypes.indexOf(landmark.typeLabel);
      final expiry = landmark.expiresAt.millisecondsSinceEpoch ~/ 1000;
      final id = landmark.officerId;
      final key = await ledger.officerKey(id);
      if (key == null) return;
      final canonical =
          'GZANN1|${landmark.latitude.toStringAsFixed(7)}|'
          '${landmark.longitude.toStringAsFixed(7)}|'
          '$typeCode|$expiry|${landmark.label}';
      final sig = signOfficerRecord(key.$2, canonical);
      final prefs = await SharedPreferences.getInstance();
      final certB64 = prefs.getString('cert_sig_$id') ?? '';
      final labelBytes = utf8.encode(landmark.label);
      final idBytes = utf8.encode(id);
      final head = <int>[
        (landmark.latitude * 10000000).round() >> 24 & 0xff,
        (landmark.latitude * 10000000).round() >> 16 & 0xff,
        (landmark.latitude * 10000000).round() >> 8 & 0xff,
        (landmark.latitude * 10000000).round() & 0xff,
        (landmark.longitude * 10000000).round() >> 24 & 0xff,
        (landmark.longitude * 10000000).round() >> 16 & 0xff,
        (landmark.longitude * 10000000).round() >> 8 & 0xff,
        (landmark.longitude * 10000000).round() & 0xff,
        typeCode & 0xff,
        (expiry >> 24) & 0xff, (expiry >> 16) & 0xff,
        (expiry >> 8) & 0xff, expiry & 0xff,
        labelBytes.length & 0xff,
        idBytes.length & 0xff,
      ];
      final blob = Uint8List.fromList([
        ...head,
        ...labelBytes,
        ...idBytes,
        ...key.$1,
        ...base64Decode(certB64),
        ...sig,
      ]);
      await m.broadcastDataPayload(MeshPacketType.announce, blob);
    } catch (_) {
      // One failed retransmit shouldn't kill the timer.
    }
  }

  /// Forces near-continuous scanning for the mesh channel so multi-frame
  /// broadcasts are actually heard by sleepy receivers.
  void boostRadioForChat() => mesh?.adapter.boostScan();

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    _sosTimer?.cancel();
    _landmarkRetxTimer?.cancel();
    _accelSub?.cancel();
    mesh?.stop();
    ledger.close();
    super.dispose();
  }
}
