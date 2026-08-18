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

import 'ledger/ledger_store.dart';
import 'ledger/open.dart';
import 'master_key.dart';
import 'mesh/mesh_adapter.dart';
import 'mesh/mesh_controller.dart';
import 'mesh/simulated_mesh.dart';
import 'mesh/simulator.dart';
import 'mesh_packet.dart';
import 'totp.dart';

enum Role { citizen, officer }

class AppState extends ChangeNotifier {
  Role _role = Role.citizen;
  Role get role => _role;

  String? _officerId;
  String? get officerId => _officerId;

  final String citizenId =
      'CIT-${sha256.convert(utf8.encode('${DateTime.now().microsecondsSinceEpoch}')).toString().substring(0, 8).toUpperCase()}';
  List<int> get citizenKey =>
      sha256.convert(utf8.encode('aapadsetu:citizen:$citizenId')).bytes;

  late LedgerStore ledger;
  late MeshController mesh;
  // BLE mesh is a phone thing; desktop/web default to the local simulator
  // (scanning may still work via bluez, but advertising generally does not).
  bool _useSimulator =
      !(defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get useSimulator => _useSimulator;

  bool sosActive = false;
  TriageFlags sosFlags = TriageFlags(severity: 3);
  int claimCount = 0;
  int _claimSeq = 0;
  bool initialized = false;

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

  Future<String> requestMeshPermissions() => mesh.adapter.ensurePermissions();

  Future<void> init() async {
    ledger = await openLedgerStore();
    mesh = _buildMesh();
    await mesh.start();
    // Announce immediately so peers learn of this node without waiting for
    // the first 10s heartbeat; the BLE advertising payload starts empty.
    mesh.announce();
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      mesh.announce();
    });
    _startVirtualNetworkIfDesktop();
    initialized = true;
    notifyListeners();
    await _acquireGps();
  }

  /// Desktop has no BLE radio, so it runs a small virtual network so the
  /// maps / links actually show live traffic. Phones use real BLE only.
  MeshSimulator? _virtualNetwork;
  bool get virtualNetworkActive => _virtualNetwork != null;

  void _startVirtualNetworkIfDesktop() {
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return;
    }
    _virtualNetwork = MeshSimulator(mesh.adapter, nodeCount: 10)..start();
  }

  /// Real GPS lives on phones; laptops/web have none. Failure is normal —
  /// the app then falls back to the peer-consensus estimate.
  Future<void> _acquireGps() async {
    if (kIsWeb) return;
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
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 8),
        ),
      );
      mesh.setGpsFix(latitude: pos.latitude, longitude: pos.longitude);
      notifyListeners();
    } catch (_) {
      // no fix (e.g. denied, no satellites); keep the no-GPS fallback
    }
  }

  Timer? _heartbeat;
  Timer? _sosTimer;

  MeshController _buildMesh() {
    final nodeId =
        (sha256.convert(utf8.encode(citizenId)).bytes[0] << 8 |
            sha256.convert(utf8.encode(citizenId)).bytes[1]) &
        0xffff;
    final adapter = _useSimulator
        ? SimulatedMeshAdapter() as MeshAdapter
        : _nativeAdapter(nodeId);
    return MeshController(nodeId: nodeId, adapter: adapter);
  }

  // Late binding so the platform MeshAdapter can be swapped out in tests.
  static MeshAdapter Function(int nodeId) nativeAdapterFactory = (nodeId) {
    throw UnsupportedError('no native mesh adapter registered');
  };

  MeshAdapter _nativeAdapter(int nodeId) => nativeAdapterFactory(nodeId);

  Future<void> setUseSimulator(bool value) async {
    if (value == _useSimulator) return;
    _useSimulator = value;
    await mesh.stop();
    mesh = _buildMesh();
    await mesh.start();
    notifyListeners();
  }

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
    if (active) {
      mesh.broadcastSos(triage: sosFlags);
      _sosTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        mesh.broadcastSos(triage: sosFlags);
      });
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
      mesh.broadcast(_buildLedgerPacket());
    }
    notifyListeners();
    return result;
  }

  MeshPacket _buildLedgerPacket() => MeshPacket(
    type: MeshPacketType.ledgerSyncRequest,
    senderId: mesh.nodeId,
    latitude: mesh.gpsFix ? mesh.gpsLatitude! : 0,
    longitude: mesh.gpsFix ? mesh.gpsLongitude! : 0,
    triage: TriageFlags(),
    seq: _claimSeq & 0xffff,
  );

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
    _virtualNetwork?.stop();
    _heartbeat?.cancel();
    _sosTimer?.cancel();
    mesh.stop();
    ledger.close();
    super.dispose();
  }
}
