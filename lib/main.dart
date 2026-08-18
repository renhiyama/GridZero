import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'core/app_state.dart';
import 'core/mesh/native_mesh.dart';
import 'core/mesh_packet.dart';
import 'ui/hud_theme.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  AppState.nativeAdapterFactory = (nodeId) =>
      NativeMeshAdapter(advertisingPayload: Uint8List(meshPacketLength));

  final state = AppState();
  await state.init();

  runApp(AapadSetuApp(state: state));
}

class AapadSetuApp extends StatelessWidget {
  const AapadSetuApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'AapadSetu / आपदसेतु',
        debugShowCheckedModeBanner: false,
        theme: HudTheme.dark,
        home: const ModeShell(),
      ),
    );
  }
}
