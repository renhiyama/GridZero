import 'dart:developer' as developer;
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'core/app_state.dart';
import 'package:flutter/foundation.dart';
import 'core/mesh/native_mesh.dart';
import 'core/mesh/win_mesh_adapter.dart';
import 'core/mesh_packet.dart';
import 'core/notifications.dart';
import 'ui/hud_theme.dart';
import 'ui/login_screen.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  AppState.nativeAdapterFactory = (nodeId) {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return WinMeshAdapter(advertisingPayload: Uint8List(meshPacketLength));
    }
    return NativeMeshAdapter(advertisingPayload: Uint8List(meshPacketLength));
  };

  final state = AppState();
  // Paint the boot splash BEFORE the slow radio/db bring-up so the phone
  // shows a frame immediately. init()/notifier/restoreSession previously ran
  // ahead of runApp(), leaving a blank window for seconds on every cold start
  // (SQLite open + BLE turnOn + scan + GPS all block the main isolate).
  runApp(GridZeroApp(state: state));
  AppState.debugInstance = state;
  registerSyncDebugExtension(state);

  await state.init();
  final notifier = SosNotifier(state);
  // The mesh now runs from boot (anonymous), so notifications can subscribe
  // immediately and stay valid across login/logout cycles.
  await notifier.init();
  // Resume the last session account so a restart lands in the shell instead
  // of the login screen.
  await state.restoreSession();
}

class BootSplash extends StatelessWidget {
  const BootSplash({super.key});

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 8, height: 8, color: p.primary),
            const SizedBox(height: 14),
            Text(
              'GRIDZERO',
              style: TextStyle(
                color: p.primary,
                fontFamily: 'monospace',
                fontSize: 16,
                letterSpacing: 4,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: p.primary),
            ),
          ],
        ),
      ),
    );
  }
}

class GridZeroApp extends StatelessWidget {
  const GridZeroApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return AppScope(
          state: state,
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) {
              // Pull only the primary colour from the platform's Material You
              // scheme; the rest of the HUD structure stays ours.
              final seed = state.useSystemDynamic && lightDynamic != null
                  ? lightDynamic.primary
                  : state.seedColor;
              return MaterialApp(
                title: 'GridZero',
                debugShowCheckedModeBanner: false,
                theme: HudTheme.build(seed: seed, brightness: Brightness.light),
                darkTheme: HudTheme.build(
                  seed: seed,
                  brightness: Brightness.dark,
                ),
                themeMode: state.themeMode,
                home: !state.initialized
                    ? const BootSplash()
                    : state.loggedIn
                    ? const ModeShell()
                    : const LoginScreen(),
              );
            },
          ),
        );
      },
    );
  }
}

/// VM-service debug hook for live two-device diagnosis. Not wired to any UI:
/// call `ext.gridzero.syncDebug` over the Dart VM Service to read the sync
/// state of a running app (phone or laptop).
void registerSyncDebugExtension(AppState state) {
  developer.registerExtension('ext.gridzero.syncDebug', (method, parameters) {
    return state.syncDebugJson().then(
      (json) => developer.ServiceExtensionResponse.result(json),
    );
  });
}
