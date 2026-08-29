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
  @override
  void boostScan() {
    // Linux scans continuously (tier CONTINUOUS, 0ms sleep) so a boost is
    // unnecessary; restart the window to force a propertyChanged refresh.
    _scanWindow();
  }

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
      // Already discovering → don't re-enter; BlueZ throws InProgress and
      // the burst's boostScan() can otherwise spam the log every 15s.
      final discovering = _adapter!.discovering;
      if (!discovering) {
        await _adapter!.startDiscovery();
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('InProgress') || msg.contains('Already')) {
        // Benign race: another scanWindow/boost already started discovery.
      } else {
        _error = 'discovery: $e';
        debugPrint('GridZero: bluez discovery failed: $e');
      }
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

  /// Every registration BlueZ still holds for us. The LE advertising
  /// manager allows only a handful per app: leaking handles (e.g. when a
  /// swap fails between unregister and re-register) eventually triggers
  /// org.bluez.Error.NotPermitted: Maximum advertisements reached.
  final List<BlueZAdvertisement> _liveRegistrations = [];

  Future<void> _startAdvertising() async {
    if (_advertising) return;
    // Recovery: a previous failure may have leaked registrations. Drop them
    // before asking for another slot.
    for (final stale in List.of(_liveRegistrations)) {
      try {
        await _adapter!.advertisingManager.unregisterAdvertisement(stale);
      } catch (_) {
        // BlueZ already dropped it: that is exactly what we wanted.
      }
      _liveRegistrations.remove(stale);
    }
    try {
      _advert = await _adapter!.advertisingManager.registerAdvertisement(
        type: BlueZAdvertisementType.broadcast,
        manufacturerData: {
          BlueZManufacturerId(kMeshCompanyId): DBusArray.byte(
            advertisingPayload,
          ),
        },
      );
      _liveRegistrations.add(_advert!);
      _advertising = true;
      _advDirty = false;
    } catch (e) {
      _error = 'adv: $e';
      debugPrint('GridZero: bluez advertising failed: $e');
    }
  }

  /// Latest persistent frame (announce with coords, or SOS). After the
  /// rotation drains a heartbeat burst, the slot returns here so peers catch
  /// our live position instead of a one-shot identity/ledger frame.
  Uint8List? _persistentPayload;

  /// Frames waiting to take the advertisement slot. broadcast() only enqueues;
  /// a 2s rotation timer swaps the radio onto each frame in turn, so a burst
  /// (announce + identity + ledger on one heartbeat) doesn't leave only the
  /// last frame on the air: otherwise a scanning peer would catch the identity
  /// frame while the coords-carrying announce is overwritten within
  /// milliseconds.
  final List<Uint8List> _rotateQueue = [];
  Timer? _rotateTimer;

  void _scheduleRotation() {
    if (_rotateTimer != null) return;
    void tick() async {
      _rotateTimer = null;
      if (_rotateQueue.isEmpty) {
        final sticky = _persistentPayload;
        if (sticky != null && !listEquals(advertisingPayload, sticky)) {
          await _swapPayload(sticky);
        }
        return;
      }
      final next = _rotateQueue.removeAt(0);
      final ok = await _swapPayload(next);
      // Fast drain for burst (400ms) so 20-chunk landmark drains in ~8s not 40s.
      _rotateTimer = Timer(Duration(milliseconds: ok ? 400 : 1000), tick);
    }

    _rotateTimer = Timer(Duration.zero, tick);
  }

  Future<bool> _swapPayload(Uint8List payload) async {
    advertisingPayload = payload;
    // Unregister BEFORE clearing state: if this throws we still track the
    // handle in _liveRegistrations and clean it up on the next attempt: // clearing first is what leaked BlueZ advertisement slots.
    final advert = _advert;
    if (advert != null) {
      try {
        await _adapter!.advertisingManager.unregisterAdvertisement(advert);
      } catch (e) {
        // DoesNotExist = BlueZ already dropped it: the goal is achieved.
        final message = e.toString();
        if (!message.contains('Does Not Exist') &&
            !message.contains('DoesNotExist')) {
          debugPrint('GridZero: bluez unregister failed: $e');
        }
      }
      _liveRegistrations.remove(advert);
      _advert = null;
      _advertising = false;
    }
    try {
      await _startAdvertising();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> broadcast(MeshPacket packet, {bool persistent = false}) async {
    final payload = packet.encode();
    if (persistent) {
      _persistentPayload = payload;
      if (listEquals(advertisingPayload, payload)) return;
      await _swapPayload(payload);
      return;
    }
    if (listEquals(advertisingPayload, payload)) return;
    if (_rotateQueue.isNotEmpty && listEquals(_rotateQueue.last, payload)) {
      return;
    }
    _rotateQueue.add(payload);
    if (_rotateQueue.length > 8) _rotateQueue.removeAt(0);
    _scheduleRotation();
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

  // BlueZ keeps scanning continuously, so the governor has no duty-cycle knob
  // to turn; accepting the hints keeps the transport contract uniform.
  @override
  Future<void> setRadioAlert(bool active) async {}

  @override
  Future<void> setRadioActive(bool active) async {}

  @override
  Map<String, String> get diagnostics => {
    'tier': 'CONTINUOUS',
    'scanSleep': '0ms (BlueZ)',
    'peers': '${_peers.length}',
  };

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
      if (_adapter != null) {
        for (final reg in List.of(_liveRegistrations)) {
          await _adapter!.advertisingManager.unregisterAdvertisement(reg);
        }
        _liveRegistrations.clear();
      }
      if (_advert != null && _adapter != null) {
        await _adapter!.advertisingManager.unregisterAdvertisement(_advert!);
      }
    } catch (_) {
      // Advertisement may already be gone.
    }
    _advert = null;
    _advertising = false;
    _scanOn = false;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    await _client?.close();
    _client = null;
    await _rx.close();
  }
}
