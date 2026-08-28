/// Battery + foreground helpers for keeping BLE/GPS alive when the app is
/// backgrounded or swiped away. Android-only; other platforms are no-ops.
library;

import 'package:flutter/services.dart';

const _battery = MethodChannel('gridzero/battery');
const _fg = MethodChannel('gridzero/foreground');

Future<bool> isIgnoringBatteryOptimizations() async {
  try {
    final v = await _battery.invokeMethod<bool>('isIgnoringOptimizations');
    return v ?? false;
  } catch (_) {
    return false;
  }
}

Future<void> requestIgnoreBatteryOptimizations() async {
  try {
    await _battery.invokeMethod('requestIgnoreOptimizations');
  } catch (_) {}
}

Future<void> startMeshForegroundService() async {
  try {
    await _fg.invokeMethod('start');
  } catch (_) {}
}

Future<void> stopMeshForegroundService() async {
  try {
    await _fg.invokeMethod('stop');
  } catch (_) {}
}
