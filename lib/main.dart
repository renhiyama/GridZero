import 'dart:typed_data';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'core/app_state.dart';
import 'core/mesh/native_mesh.dart';
import 'core/mesh_packet.dart';
import 'core/notifications.dart';
import 'ui/hud_theme.dart';
import 'ui/login_screen.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  AppState.nativeAdapterFactory = (nodeId) =>
      NativeMeshAdapter(advertisingPayload: Uint8List(meshPacketLength));

  final state = AppState();
  await state.init();

  final notifier = SosNotifier(state);
  // The mesh only exists after login, so notifications subscribe/unsubscribe
  // as sessions start and stop.
  state.addListener(() {
    if (state.loggedIn && state.mesh != null) {
      notifier.init();
    } else if (!state.loggedIn) {
      notifier.dispose();
    }
  });

  runApp(GridZeroApp(state: state));
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
                home: state.loggedIn ? const ModeShell() : const LoginScreen(),
              );
            },
          ),
        );
      },
    );
  }
}
