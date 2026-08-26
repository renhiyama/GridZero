/// Windows BLE mesh — scan via flutter_blue_plus_winrt, advertise stub.
///
/// `ble_peripheral_plus` does not expose WinRT AdvertisementPublisher on
/// Windows, so the HQ cannot advertise frames in MVP. The adapter still
/// scans so HQ sees officer/citizen beacons and can sync over WiFi. All
/// `broadcast()` calls are queued logicially but dropped with diagnostics so
/// callers don't crash.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';

import '../mesh_packet.dart';
import 'mesh_adapter.dart';
import 'native_mesh.dart';

class WinMeshAdapter implements MeshAdapter {
  WinMeshAdapter({required Uint8List advertisingPayload})
      : _inner = NativeMeshAdapter(advertisingPayload: advertisingPayload);

  final NativeMeshAdapter _inner;
  bool _advStubWarned = false;

  @override
  String get name => 'WIN-BLE';

  @override
  Stream<MeshRxPacket> get onPacket => _inner.onPacket;

  @override
  String get status {
    final inner = _inner.status;
    return '$inner · ADV UNSUPPORTED (Windows — scan only, HQ joins via WiFi)';
  }

  @override
  Future<String> ensurePermissions() => _inner.ensurePermissions();

  @override
  Future<void> start() async {
    // Start the inner but swallow peripheral init failures: scan still works.
    try {
      await _inner.start();
    } catch (e) {
      debugPrint('GridZero: win mesh start: $e');
    }
  }

  @override
  Future<void> broadcast(MeshPacket packet, {bool persistent = false}) async {
    if (!_advStubWarned) {
      debugPrint('GridZero: Windows BLE advertise not supported — chat/landmark relay is receive-only on HQ. WiFi sync still works.');
      _advStubWarned = true;
    }
    // No-op: keep queue semantics so callers think they broadcast, but don't
    // throw. Landing in WiFi sync instead keeps HQ useful.
  }

  @override
  Future<void> injectRemote(MeshPacket packet) => _inner.injectRemote(packet);

  @override
  Future<void> setRadioAlert(bool active) => _inner.setRadioAlert(active);

  @override
  Future<void> setRadioActive(bool active) => _inner.setRadioActive(active);

  @override
  void boostScan() => _inner.boostScan();

  @override
  Map<String, String> get diagnostics => {
        ..._inner.diagnostics,
        'winAdv': 'UNSUPPORTED — scan only (HQ sync via WiFi)',
        'winHint': 'Run phone-hosted GZ- link for Windows HQ',
      };

  @override
  Future<void> stop() => _inner.stop();
}
