/// nmcli bridge for the HQ laptop's side of the officer DB sync: save the
/// active connections, join the phone's hotspot, read the phone's address
/// (the hotspot gateway), then tear the join down and restore whatever was
/// active before. All calls shell out to `nmcli`; any failure returns a
/// human-readable error string instead of throwing.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One active NetworkManager connection, as saved before the hotspot join.
typedef SavedConnection = ({String name, String type});

/// Runs `nmcli` and returns (exitCode, stdout, stderr).
Future<(int, String, String)> _nmcli(
  List<String> args, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  try {
    final r = await Process.run(
      'nmcli',
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      runInShell: false,
    ).timeout(timeout);
    return (r.exitCode, (r.stdout as String).trim(), (r.stderr as String).trim());
  } on TimeoutException {
    return (-1, '', 'nmcli timed out');
  } on ProcessException catch (e) {
    return (-1, '', e.toString());
  }
}

/// Lists currently active connections, filtered to wifi/ethernet (the only
/// links worth restoring; loopback/tun/bridge noise is skipped).
Future<List<SavedConnection>> activeConnections() async {
  final (code, out, _) = await _nmcli(
    ['-t', '-f', 'NAME,TYPE', 'con', 'show', '--active'],
  );
  if (code != 0) return const [];
  final result = <SavedConnection>[];
  for (final line in out.split('\n')) {
    if (line.isEmpty) continue;
    final sep = line.indexOf(':');
    if (sep <= 0) continue;
    final name = line.substring(0, sep);
    final type = line.substring(sep + 1);
    if (type == 'wifi' || type == 'ethernet') {
      result.add((name: name, type: type));
    }
  }
  return result;
}

/// Joins the given wifi network. Returns null on success, else an error.
Future<String?> connectWifi(String ssid, String password) async {
  final (code, out, err) = await _nmcli([
    'dev',
    'wifi',
    'connect',
    ssid,
    'password',
    password,
  ]);
  if (code == 0) return null;
  final message = (out.isNotEmpty ? out : err).trim();
  return message.isEmpty ? 'nmcli connect failed' : message;
}

/// Reads the IPv4 gateway of the connection named [connectionName]; on the
/// phone's hotspot that is the phone itself, which is where the sync server
/// listens.
Future<String?> connectionGateway(String connectionName) async {
  final (code, out, _) = await _nmcli(
    ['-g', 'IP4.GATEWAY', 'con', 'show', connectionName],
  );
  if (code != 0 || out.isEmpty) return null;
  return out.split('\n').first.trim();
}

/// Name of the active wifi connection right now (after `connectWifi`), so the
/// caller can target the join for teardown.
Future<String?> activeWifiConnectionName() async {
  final (code, out, _) = await _nmcli(
    ['-t', '-f', 'NAME,TYPE', 'con', 'show', '--active'],
  );
  if (code != 0) return null;
  for (final line in out.split('\n')) {
    final sep = line.indexOf(':');
    if (sep <= 0) continue;
    if (line.substring(sep + 1) == 'wifi') {
      return line.substring(0, sep);
    }
  }
  return null;
}

/// Brings a saved connection back up. Best-effort: individual failures are
/// collected so the caller can surface them.
Future<List<String>> restoreConnections(List<SavedConnection> connections) async {
  final failures = <String>[];
  for (final c in connections) {
    final (code, out, err) = await _nmcli(['con', 'up', c.name]);
    if (code != 0) {
      failures.add('${c.name}: ${out.isNotEmpty ? out : err}');
    }
  }
  return failures;
}

/// Disconnects the named connection (the hotspot join) without deleting it.
Future<void> disconnectConnection(String connectionName) async {
  await _nmcli(['con', 'down', connectionName]);
}
/// SSIDs currently visible in the radio's wifi scan. Triggers a fresh rescan
/// so a just-opened device link shows up within seconds.
Future<List<String>> visibleWifiNetworks() async {
  final (code, out, _) = await _nmcli([
    '--terse',
    '--fields',
    'SSID',
    'device',
    'wifi',
    'list',
    '--rescan',
    'yes',
  ]);
  if (code != 0) return const [];
  final ssids = <String>{};
  for (final line in out.split('\n')) {
    final ssid = line.trim();
    // Skip empty (hidden networks) and NM escape artifacts.
    if (ssid.isEmpty || ssid.contains(r'\x')) continue;
    ssids.add(ssid);
  }
  return ssids.toList();
}

// ---------------------------------------------------------------------------
// GridZero direct link (HQ-hosted AP)
//
/// Minimal port of HotSpotTest/hotspot.js: bring up a virtual `ap0`
/// interface on the SAME radio as the station, run hostapd + dnsmasq on it,
/// and leave the station's own connection completely alone. The two BSSIDs
/// share one channel (MT7922 constraint), which we read off the live link.
///
/// All privileged calls go through `sudo -n`: non-interactive. If sudo
/// needs a password the command fails and the caller surfaces a setup hint
/// instead of hanging.
const String kLinkApIface = 'ap0';
const String kLinkApGateway = '192.168.51.1';
const String kLinkApSubnet = '192.168.51.1/24';
const String kLinkApDhcpRange = '192.168.51.10,192.168.51.200,255.255.255.0,12h';
const String kLinkStaIface = 'wlp1s0';

/// Runs a command under non-interactive sudo. Returns (ok, output).
Future<(bool, String)> _sudo(List<String> args) async {
  try {
    final r = await Process.run(
      'sudo',
      ['-n', ...args],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 20));
    return (
      r.exitCode == 0,
      ((r.stdout as String).trim().isNotEmpty
              ? r.stdout as String
              : r.stderr as String)
          .trim(),
    );
  } on TimeoutException {
    return (false, 'sudo timed out');
  } on ProcessException catch (e) {
    return (false, e.message);
  }
}

String? _staChannelFrom(String iwLink) {
  final m = RegExp(r'freq:\s*(\d+)').firstMatch(iwLink);
  if (m == null) return null;
  final f = int.parse(m.group(1)!);
  if (f >= 2412 && f <= 2484) return f == 2484 ? '14' : '${(f - 2407) ~/ 5}';
  if (f >= 5160 && f <= 5885) return '${(f - 5000) ~/ 5}';
  return null;
}

/// Current station channel (so the AP can share it), or channel 6 when the
/// station is down: hosting still works without an uplink.
Future<String> _staChannel() async {
  final (ok, out) = await _sudo(['iw', 'dev', kLinkStaIface, 'link']);
  if (!ok) return '6';
  return _staChannelFrom(out) ?? '6';
}

/// One-time: make NetworkManager leave `ap0` alone.
Future<(bool, String)> _ensureAp0Unmanaged() async {
  final conf = '[keyfile]\nunmanaged-devices=interface-name:$kLinkApIface\n';
  await Directory('/tmp/gridzero').create(recursive: true);
  await File('/tmp/gridzero/nm.conf').writeAsString(conf);
  final (ok1, o1) = await _sudo([
    'cp',
    '/tmp/gridzero/nm.conf',
    '/etc/NetworkManager/conf.d/90-gridzero-ap0.conf',
  ]);
  if (!ok1) return (false, o1);
  final (ok2, o2) = await _sudo(['nmcli', 'connection', 'reload']);
  return (ok2, o2);
}

/// Brings the HQ-hosted link up. Returns null on success, else an error that
/// may include the sudo setup hint.
Future<String?> startLinkAp({required String ssid, required String pass}) async {
  // Candidate channels: the station's channel first (same-band AP+STA
  // coexistence), then standalone fallbacks: the MT7922 refuses AP on DFS
  // channels entirely (driver CAC failure) and cannot split bands, which
  // forces dropping the station connection for those cases. Restored on
  // teardown.
  final staChannel = await _staChannel();
  final staChNum = int.tryParse(staChannel) ?? 6;
  final candidates = [
    (hw: staChNum > 14 ? 'a' : 'g', ch: staChannel),
    (hw: 'g', ch: '6'),
    (hw: 'a', ch: '36'),
  ];

  var (ok, out) = await _ensureAp0Unmanaged();
  if (!ok) return _sudoFail(out);

  Future<(bool, String)> addApIface() => _sudo([
        'iw',
        'dev',
        kLinkStaIface,
        'interface',
        'add',
        kLinkApIface,
        'type',
        '__ap',
      ]);

  (ok, out) = await addApIface();
  if (!ok) {
    // A leftover ap0 from a previous session may sit in managed mode (NM
    // recreates it that way): hostapd refuses that. Delete and retry once.
    await _sudo(['iw', 'dev', kLinkApIface, 'del']);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    (ok, out) = await addApIface();
    if (!ok) {
      return 'could not create the $kLinkApIface interface: $out';
    }
  }

  (ok, out) = await _sudo(['ip', 'addr', 'flush', 'dev', kLinkApIface]);
  if (!ok) return _sudoFail(out);
  (ok, out) =
      await _sudo(['ip', 'addr', 'add', kLinkApSubnet, 'dev', kLinkApIface]);
  if (!ok) return _sudoFail(out);
  (ok, out) = await _sudo(['ip', 'link', 'set', kLinkApIface, 'up']);
  if (!ok) return _sudoFail(out);

  // UFW with default-deny INPUT silently drops the device's DHCP DISCOVER
  // and the sync TCP connection. Allow everything arriving on ap0: it is
  // our own isolated link subnet.
  (ok, out) = await _sudo(['ufw', 'allow', 'in', 'on', kLinkApIface]);
  if (!ok) {
    stderr.writeln('GridZero: ufw allow failed (continuing): $out');
  }

  // Stop leftovers from a previous session before starting fresh daemons.
  await stopLinkApDaemons();

  final dir = '/tmp/gridzero';
  await Directory(dir).create(recursive: true);
  final dnsmasqConf = '''
interface=$kLinkApIface
bind-interfaces
except-interface=lo
dhcp-range=$kLinkApDhcpRange
''';
  await File('$dir/dnsmasq.conf').writeAsString(dnsmasqConf);

  String lastError = '';
  for (final (hw: hwMode, ch: channel) in candidates) {
    final fiveGhz = int.parse(channel) > 14;
    final hostapdConf = '''
interface=$kLinkApIface
driver=nl80211
ctrl_interface=/tmp/gridzero/ctrl
ctrl_interface_group=wheel
ssid=$ssid
country_code=IN
${fiveGhz ? 'ieee80211d=1\nieee80211h=1' : ''}
hw_mode=$hwMode
channel=$channel
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$pass
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
''';
    await File('$dir/hostapd.conf').writeAsString(hostapdConf);

    // Non-station channels need the radio free: drop the station, remember
    // its profile so teardown can reconnect HQ's internet. Autoconnect must
    // be disabled FIRST or NetworkManager re-activates the profile seconds
    // later, yanking the radio back and killing our freshly started AP.
    if (channel != staChannel) {
      final profiles = await _allWifiProfiles();
      await File('$dir/sta_profiles').writeAsString(profiles.join('\n'));
      for (final prof in profiles) {
        await _sudo([
          'nmcli',
          'connection',
          'modify',
          prof,
          'connection.autoconnect',
          'no',
        ]);
      }
      final profile = await _staConnectionProfile();
      if (!await _stationDisconnected()) {
        await _sudo(['nmcli', 'device', 'disconnect', kLinkStaIface]);
        // Wait until it is REALLY down: NM races the disconnect with an
        // immediate auto-reconnect otherwise.
        var waited = 0;
        while (await _stationDisconnected() == false && waited < 6000) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          waited += 400;
          if (waited % 2000 == 0 && profile != null) {
            await _sudo(['nmcli', 'device', 'disconnect', kLinkStaIface]);
          }
        }
      }
    }

    // Launch via shell redirect instead of -B: daemonized hostapd throws
    // away its stdout, and association failures are invisible without it.
    (ok, out) = await _sudo([
      'sh',
      '-c',
      'hostapd $dir/hostapd.conf >> $dir/hostapd.log 2>&1 &',
    ]);
    if (ok && await _waitApAlive()) {
      (ok, out) = await _sudo(['dnsmasq', '-C', '$dir/dnsmasq.conf']);
      if (!ok) return 'dnsmasq failed: $out';
      // When HQ still has an uplink, share it with the linked device so its
      // Android doesn't complain about a no-internet wifi.
      await _sudo(['sysctl', '-w', 'net.ipv4.ip_forward=1']);
      final nftRules = '''
table inet gridzero_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname != "$kLinkApIface" iifname "$kLinkApIface" masquerade
  }
}''';
      await File('$dir/nft.conf').writeAsString(nftRules);
      await _sudo(['nft', '-f', '$dir/nft.conf']);
      return null;
    }
    lastError = out.isEmpty ? 'hostapd failed on channel $channel' : out;
    await stopLinkApDaemons();
  }
  return lastError;
}

/// Waits for the daemonized hostapd to survive startup AND stay up for 3s.
/// A short-lived process that dies when NetworkManager races a reconnect
/// would otherwise count as success.
Future<bool> _waitApAlive() async {
  var seen = false;
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final r = await Process.run('pgrep', ['-f', 'hostapd.*/tmp/gridzero']);
    if (r.exitCode == 0) {
      seen = true;
      continue;
    }
    return false;
  }
  return seen;
}

/// True once the station has no active link (radio freed for the AP).
Future<bool> _stationDisconnected() async {
  final (_, out) = await _sudo(['iw', 'dev', kLinkStaIface, 'link']);
  return !out.contains('Connected');
}

/// Every saved wifi profile on this machine: autoconnect must be turned
/// off for ALL of them, else NetworkManager simply reconnects through a
/// different profile than the one we disabled.
Future<List<String>> _allWifiProfiles() async {
  final (code, out, _) = await _nmcli([
    '-t',
    '-f',
    'NAME,TYPE',
    'connection',
    'show',
  ]);
  if (code != 0) return const [];
  return out
      .split('\n')
      .where((l) => l.endsWith(':wifi') || l.endsWith(':802-11-wireless'))
      .map((l) => l.substring(0, l.indexOf(':')))
      .where((n) => n.isNotEmpty)
      .toList();
}

/// NM profile name of the station connection, for post-teardown reconnect.
/// Persisted to /tmp so even a crashed app can restore on next boot.
Future<String?> _staConnectionProfile() async {
  final cached = File('/tmp/gridzero/sta_profile');
  if (cached.existsSync()) {
    final name = cached.readAsStringSync().trim();
    if (name.isNotEmpty) return name;
  }
  final (code, out, _) = await _nmcli([
    '-g',
    'GENERAL.CONNECTION',
    'device',
    'show',
    kLinkStaIface,
  ]);
  if (code != 0 || out.trim().isEmpty || out.trim() == '--') return null;
  return out.trim();
}

/// Kills leftover hostapd/dnsmasq for the link (best-effort). Kills by PID
/// file first, then sweeps anything referencing our config dir: pattern
/// matching on 'ap0' missed the real command lines and left a stale
/// dnsmasq holding 192.168.51.1 across sessions.
Future<void> stopLinkApDaemons() async {
  for (final name in ['hostapd', 'dnsmasq']) {
    try {
      final pid = int.tryParse(
        (await File('/tmp/gridzero/$name.pid').readAsString()).trim(),
      );
      if (pid != null && pid > 1) {
        await _sudo(['kill', '$pid']);
      }
    } catch (_) {
      // No pid file: nothing to kill.
    }
  }
  await _sudo(['pkill', '-f', '/tmp/gridzero/']);
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

/// Tears the hosted link down and reconnects the station if we had to drop
/// it (DFS/band-constraint fallback). Re-enables autoconnect that hosting
/// disabled. Never throws.
Future<void> stopLinkAp() async {
  await stopLinkApDaemons();
  await _sudo(['nft', 'delete', 'table', 'inet', 'gridzero_nat']);
  await _sudo(['ip', 'link', 'set', kLinkApIface, 'down']);
  try {
    final profilesFile = File('/tmp/gridzero/sta_profiles');
    final singleFile = File('/tmp/gridzero/sta_profile');
    final toRestore = <String>[
      if (profilesFile.existsSync())
        ...profilesFile
            .readAsStringSync()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty),
      if (singleFile.existsSync() && singleFile.readAsStringSync().trim().isNotEmpty)
        singleFile.readAsStringSync().trim(),
    ];
    if (toRestore.isNotEmpty) {
      // Give the interface a beat after hostapd dies, then reconnect.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (final profile in toRestore.toSet()) {
        await _sudo([
          'nmcli',
          'connection',
          'modify',
          profile,
          'connection.autoconnect',
          'yes',
        ]);
      }
      await _sudo(['nmcli', 'connection', 'up', toRestore.first]);
    }
    if (profilesFile.existsSync()) profilesFile.deleteSync();
    if (singleFile.existsSync()) singleFile.deleteSync();
  } catch (_) {
    // Reconnect is best-effort; HQ's internet is not our responsibility.
  } finally {
    await _sudo(['iw', 'dev', kLinkApIface, 'del']);
  }
}

String _sudoFail(String out) =>
    'one-time setup needed: allow passwordless sudo for iw/ip/hostapd/'
    'dnsmasq on this laptop ($out)';
