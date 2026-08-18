import 'dart:async';
import 'dart:math';

import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../mesh_packet.dart';
import 'mesh_adapter.dart';

const int kMeshCompanyId = 0xffff;

/// How long each scan window runs before the radio goes idle (adv-only).
const Duration _scanWindowDuration = Duration(milliseconds: 2200);

/// Idle period between scan windows (advertisement transmits during this).
const Duration _sleepWindowDuration = Duration(seconds: 4);

/// Linux desktop transport: real BLE through BlueZ on the system D-Bus.
///
/// Scanning watches Device1.ManufacturerData on every discovered device;
/// advertising registers a broadcast LE advertisement. BlueZ has no
/// advertisement monitor in this package version, so discovery must read the
/// cached manufacturer data property for each device.
class BluezMeshAdapter implements MeshAdapter {
  BluezMeshAdapter({required this.advertisingPayload});

  Uint8List advertisingPayload;

  final _rx = StreamController<MeshRxPacket>.broadcast();
  BlueZClient? _client;
  BlueZAdapter? _adapter;
  StreamSubscription? _deviceAddedSub;
  StreamSubscription? _adapterAddedSub;
  final Map<String, StreamSubscription<List<String>>> _devicePropSubs = {};
  BlueZAdvertisement? _advert;
  Timer? _dutyCycleTimer;
  bool _scanOn = false;
  bool _advertising = false;
  bool _advDirty = false;
  String? _error;

  /// Peers seen in the last few minutes (id -> last seen epoch). Pruned each
  /// idle window so the HUD count is live, not a lifetime accumulator.
  final Map<int, int> _peers = {};
  final _rand = Random();

  /// Per-cycle jitter breaks phase-lock between radios running near-equal duty
  /// cycles: two devices that drift into "both scanning / both asleep" never
  /// hear each other until luck separates them.
  Duration _jittered(Duration base) =>
      base + Duration(milliseconds: _rand.nextInt(900));

  @override
  String get name => 'BLUEZ';

  @override
  Stream<MeshRxPacket> get onPacket => _rx.stream;

  @override
  String get status {
    if (_client == null) {
      return 'bluez unavailable${_error != null ? ' ($_error)' : ''}';
    }
    return [
      _scanOn ? 'SCANNING' : 'SCAN IDLE',
      _advertising ? 'ADV' : 'ADV OFF',
      if (_peers.isNotEmpty) '${_peers.length} peer(s)',
    ].join(' · ');
  }

  @override
  Future<String> ensurePermissions() async => 'no runtime perms (system D-Bus)';

  @override
  Future<void> start() async {
    try {
      final client = BlueZClient();
      await client.connect();
      _client = client;
      _adapterAddedSub = client.adapterAdded.listen(_initAdapter);
      _deviceAddedSub = client.deviceAdded.listen(_handleDevice);
      for (final device in client.devices) {
        _handleDevice(device);
      }
      if (client.adapters.isNotEmpty) {
        _initAdapter(client.adapters.first);
      }
    } catch (e) {
      _error = '$e';
      debugPrint('GridZero: bluez unavailable: $e');
    }
  }

  Future<void> _initAdapter(BlueZAdapter adapter) async {
    if (_adapter != null) return;
    _adapter = adapter;
    try {
      if (!adapter.powered) {
        await adapter.setPowered(true);
      }
    } catch (e) {
      _error = 'power: $e';
      debugPrint('GridZero: bluez power-on failed: $e');
    }
    // Duty cycle: a single radio cannot transmit its own advertisement while
    // scanning full-time on controllers without concurrent adv+scan support.
    // Scan for a window, then go idle so the advertisement actually gets out.
    _scanWindow();
    await _startAdvertising();
  }

  Future<void> _scanWindow() async {
    _dutyCycleTimer?.cancel();
    _scanOn = true;
    try {
      await _adapter!.startDiscovery();
    } catch (e) {
      _error = 'discovery: $e';
      debugPrint('GridZero: bluez discovery failed: $e');
    }
    _dutyCycleTimer = Timer(_jittered(_scanWindowDuration), _sleepWindow);
  }

  Future<void> _sleepWindow() async {
    _scanOn = false;
    _prunePeers();
    try {
      await _adapter!.stopDiscovery();
    } catch (_) {
      // Discovery may already be stopped.
    }
    // Radio is idle now: a good moment to (re)register the advertisement if
    // a broadcast was deferred during a scan window.
    await _retryAdvertising();
    _dutyCycleTimer = Timer(_jittered(_sleepWindowDuration), _scanWindow);
  }

  void _prunePeers() {
    final cutoff = DateTime.now().millisecondsSinceEpoch - 180000;
    _peers.removeWhere((_, lastSeen) => lastSeen < cutoff);
  }

  void _handleDevice(BlueZDevice device) {
    _ingest(device);
    if (_devicePropSubs.containsKey(device.address)) return;
    _devicePropSubs[device.address] = device.propertiesChanged.listen(
      (_) => _ingest(device),
    );
  }

  void _ingest(BlueZDevice device) {
    final data = device.manufacturerData[BlueZManufacturerId(kMeshCompanyId)];
    if (data == null || data.isEmpty) return;
    try {
      final packet = MeshPacket.decode(Uint8List.fromList(data));
      _peers[packet.senderId] = DateTime.now().millisecondsSinceEpoch;
      _rx.add(MeshRxPacket(packet: packet, rssi: device.rssi));
    } on FormatException {
      // Foreign or corrupt frame; ignore.
    }
  }

  Future<void> _startAdvertising() async {
    if (_advertising) return;
    try {
      _advert = await _adapter!.advertisingManager.registerAdvertisement(
        type: BlueZAdvertisementType.broadcast,
        manufacturerData: {
          BlueZManufacturerId(kMeshCompanyId): DBusArray.byte(
            advertisingPayload,
          ),
        },
      );
      _advertising = true;
      _advDirty = false;
    } catch (e) {
      _error = 'adv: $e';
      debugPrint('GridZero: bluez advertising failed: $e');
    }
  }

  @override
  Future<void> broadcast(MeshPacket packet) async {
    final payload = packet.encode();
    final changed = !listEquals(advertisingPayload, payload);
    advertisingPayload = payload;
    if (!_advertising || !changed) return;
    try {
      final advert = _advert;
      // Clear the guard BEFORE unregistering, or the re-register below would
      // no-op and the radio would silently go dark after the first payload
      // change (the one-way mesh bug).
      _advertising = false;
      _advert = null;
      if (advert != null) {
        await _adapter!.advertisingManager.unregisterAdvertisement(advert);
      }
      _advDirty = true;
      await _startAdvertising();
      if (_advertising) {
        debugPrint(
          'GridZero: adv rotated to ${payload.length}B frame '
          '(sender ${packet.senderId.toRadixString(16).toUpperCase()})',
        );
      } else {
        // Registration rejected (e.g. radio busy mid-scan window); the idle
        // window retries it when the radio is quiet.
        debugPrint('GridZero: adv registration deferred to idle window');
      }
    } catch (e) {
      _advDirty = true;
      debugPrint('GridZero: bluez advertise rotation failed: $e');
    }
  }

  Future<void> _retryAdvertising() async {
    if (!_advDirty) return;
    _advDirty = false;
    await _startAdvertising();
  }

  @override
  Future<void> injectRemote(MeshPacket packet) async {
    throw UnsupportedError('injectRemote is for test harnesses only');
  }

  @override
  Future<void> stop() async {
    _dutyCycleTimer?.cancel();
    _dutyCycleTimer = null;
    await _deviceAddedSub?.cancel();
    _deviceAddedSub = null;
    await _adapterAddedSub?.cancel();
    _adapterAddedSub = null;
    for (final sub in _devicePropSubs.values) {
      await sub.cancel();
    }
    _devicePropSubs.clear();
    try {
      if (_adapter != null) {
        await _adapter!.stopDiscovery();
      }
    } catch (_) {
      // Adapter may already be gone.
    }
    try {
      if (_advert != null && _adapter != null) {
        await _adapter!.advertisingManager.unregisterAdvertisement(_advert!);
      }
    } catch (_) {
      // Advertisement may already be gone.
    }
    _advert = null;
    _advertising = false;
    _scanOn = false;
    await _client?.close();
    _client = null;
    await _rx.close();
  }
}
