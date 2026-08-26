/// Windows counterpart to `linux_network.dart`.
///
/// Linux shells out to `nmcli`/`iw`/`hostapd`/`dnsmasq` — none exist on
/// Windows. The Windows HQ instead uses `netsh wlan` for client joins; the
/// hosted-AP path (`startLinkAp`) is intentionally degraded to a clear
/// "not supported, run reverse link (phone hosts)" message unless the
/// machine has a TetheringManager-capable adapter AND the app is elevated.
/// All functions return the same shapes as the Linux module so `app_state.dart`
/// can dispatch by `defaultTargetPlatform` without branching callers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef SavedConnection = ({String name, String type});

const String kLinkApIface = 'ap0';
const String kLinkApGateway = '192.168.51.1';
const String kLinkApSubnet = '192.168.51.1/24';
const String kLinkApDhcpRange = '192.168.51.10,192.168.51.200,255.255.255.0,12h';
const String kLinkStaIface = 'Wi-Fi';

Future<(int, String, String)> _run(
  String exe,
  List<String> args, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  try {
    final r = await Process.run(
      exe,
      args,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      runInShell: false,
    ).timeout(timeout);
    return (r.exitCode, (r.stdout as String).trim(), (r.stderr as String).trim());
  } on TimeoutException {
    return (-1, '', '$exe timed out');
  } on ProcessException catch (e) {
    return (-1, '', e.toString());
  }
}

Future<List<SavedConnection>> activeConnections() async {
  final (code, out, _) = await _run('netsh', ['wlan', 'show', 'interfaces']);
  if (code != 0) return const [];
  // Parse ' SSID : <name>' lines with State : connected.
  final result = <SavedConnection>[];
  var ssid = '';
  var connected = false;
  for (final line in out.split('\n')) {
    final t = line.trim();
    if (t.startsWith('SSID') && t.contains(':')) {
      ssid = t.split(':').last.trim();
    } else if (t.startsWith('State') && t.contains(':')) {
      connected = t.split(':').last.trim().toLowerCase().contains('connected');
      if (connected && ssid.isNotEmpty) {
        result.add((name: ssid, type: 'wifi'));
      }
      ssid = '';
      connected = false;
    }
  }
  return result;
}

Future<String?> connectWifi(String ssid, String password) async {
  // Build a temporary profile XML (WPA2-PSK, AES) and connect.
  final dir = Directory('${Platform.environment['TEMP'] ?? '.'}\\gridzero');
  await dir.create(recursive: true);
  final profilePath = '${dir.path}\\gz_$ssid.xml';
  // Escape XML special chars in SSID/pass.
  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  final xml = '''<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>${esc(ssid)}</name>
  <SSIDConfig><SSID><name>${esc(ssid)}</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security>
    <authEncryption><authentication>WPA2PSK</authentication>
    <encryption>AES</encryption><useOneX>false</useOneX></authEncryption>
    <sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>${esc(password)}</keyMaterial></sharedKey>
  </security></MSM>
</WLANProfile>''';
  await File(profilePath).writeAsString(xml);
  final (c1, o1, e1) = await _run('netsh', ['wlan', 'add', 'profile', 'filename="$profilePath"', 'user=current']);
  if (c1 != 0) return (o1.isNotEmpty ? o1 : e1).trim().isEmpty ? 'netsh add profile failed' : (o1.isNotEmpty ? o1 : e1).trim();
  final (c2, o2, e2) = await _run('netsh', ['wlan', 'connect', 'name="$ssid"']);
  if (c2 == 0) return null;
  final msg = (o2.isNotEmpty ? o2 : e2).trim();
  if (msg.toLowerCase().contains('access is denied') || msg.toLowerCase().contains('elevation')) {
    return 'Windows needs Administrator to join WiFi from the app. Right-click GridZero → Run as administrator, or join $ssid from Windows Settings → WiFi.';
  }
  return msg.isEmpty ? 'netsh connect failed' : msg;
}

Future<String?> connectionGateway(String connectionName) async {
  final (code, out, _) = await _run('netsh', ['interface', 'ip', 'show', 'addresses', connectionName]);
  if (code != 0 || out.isEmpty) return null;
  final m = RegExp(r'Default Gateway[^:]*:\s*([0-9.]+)').firstMatch(out);
  return m?.group(1)?.trim();
}

Future<String?> activeWifiConnectionName() async {
  final conns = await activeConnections();
  return conns.isEmpty ? null : conns.first.name;
}

Future<List<String>> restoreConnections(List<SavedConnection> connections) async {
  final failures = <String>[];
  for (final c in connections) {
    final (code, out, err) = await _run('netsh', ['wlan', 'connect', 'name="${c.name}"']);
    if (code != 0) failures.add('${c.name}: ${out.isNotEmpty ? out : err}');
  }
  return failures;
}

Future<void> disconnectConnection(String connectionName) async {
  await _run('netsh', ['wlan', 'disconnect']);
}

Future<List<String>> visibleWifiNetworks() async {
  final (code, out, _) = await _run('netsh', ['wlan', 'show', 'networks']);
  if (code != 0) return const [];
  final ssids = <String>{};
  for (final line in out.split('\n')) {
    final t = line.trim();
    if (t.startsWith('SSID') && t.contains(':')) {
      final ssid = t.split(':').last.trim();
      if (ssid.isNotEmpty && !ssid.toLowerCase().contains('ssid')) ssids.add(ssid);
    }
  }
  return ssids.toList();
}

/// Hosted-AP on Windows: requires WinRT NetworkOperatorTetheringManager +
/// elevation + capable driver. Not implemented in MVP — return a clear
/// instruction to use the reverse link (phone hosts, HQ joins via
/// `connectWifi`) which already works above.
Future<String?> startLinkAp({required String ssid, required String pass}) async {
  // Probe capability so Diagnostics HUD can surface it.
  final (code, out, _) = await _run('netsh', ['wlan', 'show', 'drivers']);
  final hosted = out.toLowerCase().contains('hosted network supported') &&
      out.toLowerCase().contains('yes');
  if (!hosted) {
    return 'Windows hosted network not supported on this adapter/driver (Hosted network supported: No). '
        'Use reverse link instead: on the phone open GRIDZERO → SOS → SHARE OFFICER LINK, then on this HQ scan the QR — the phone hosts the GZ- hotspot and this HQ joins it.';
  }
  // Even when hosted is supported, `netsh wlan set hostednetwork` is deprecated
  // and TetheringManager needs Packaged + elevated context via PowerShell.
  return 'Windows HQ hosted-AP needs an elevated PowerShell TetheringManager. MVP supports reverse link only: have the phone host GZ- and this HQ join it. '
      '(Planned: PowerShell Start-Tethering via win32 WinRT when admin.)';
}

Future<void> stopLinkApDaemons() async {
  // No background daemons on Windows client path.
}

Future<void> stopLinkAp() async {
  // Best-effort disconnect of any staged profile is handled by restoreConnections.
}
