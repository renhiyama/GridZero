/// SOS alerts surfaced as OS notifications. Android-only for now; the laptop
/// HQ stays a full-screen command board, not a lock-screen notifier.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_state.dart';
import 'mesh/mesh_node.dart';

class SosNotifier {
  SosNotifier(this.state);

  final AppState state;
  final _plugin = FlutterLocalNotificationsPlugin();

  /// Node ids currently notifying, so a 30s SOS re-broadcast can't re-alert.
  final _active = <int>{};
  StreamSubscription<MeshNodeState>? _startSub;
  StreamSubscription<MeshNodeState>? _endSub;

  static const _channelId = 'sos';
  static const _channelName = 'SOS Alerts';

  Future<void> init() async {
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) return;
    await _startSub?.cancel();
    await _endSub?.cancel();
    _active.clear();
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onTap,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    final m = state.mesh;
    if (m == null) return;
    _startSub = m.sosStarted.listen(_onStarted);
    _endSub = m.sosEnded.listen(_onEnded);
  }

  Future<void> dispose() async {
    await _startSub?.cancel();
    await _endSub?.cancel();
  }

  void _onStarted(MeshNodeState node) {
    if (!_active.add(node.nodeId)) return;
    _plugin.show(
      id: node.nodeId,
      title: 'SOS ALERT',
      body:
          'Node ${node.nodeId.toRadixString(16).toUpperCase()} · '
          'triage ${node.severity}',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Emergency SOS beacon alerts',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
      payload: 'sos:${node.nodeId}',
    );
  }

  void _onEnded(MeshNodeState node) {
    _active.remove(node.nodeId);
    _plugin.cancel(id: node.nodeId);
  }

  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.startsWith('sos:')) {
      state.openSos(payload.substring(4));
    }
  }
}
