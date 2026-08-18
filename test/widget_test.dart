import 'package:aapadsetu/app_scope.dart';
import 'package:aapadsetu/core/app_state.dart';
import 'package:aapadsetu/core/master_key.dart';
import 'package:aapadsetu/core/mesh/mesh_adapter.dart';
import 'package:aapadsetu/core/mesh/simulated_mesh.dart';
import 'package:aapadsetu/ui/hud_theme.dart';
import 'package:aapadsetu/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

AppState makeState() {
  AppState.nativeAdapterFactory =
      (nodeId) => SimulatedMeshAdapter() as MeshAdapter;
  return AppState();
}

Widget app(AppState state) => AppScope(
      state: state,
      child: MaterialApp(
        theme: HudTheme.dark,
        home: const ModeShell(),
      ),
    );

Future<void> initState(WidgetTester tester, AppState state) =>
    tester.runAsync(() => state.init());

Future<void> teardown(WidgetTester tester, AppState state) async {
  // Unmount widgets so their periodic timers are disposed, then drop state.
  await tester.pumpWidget(const SizedBox());
  state.dispose();
}

void main() {
  testWidgets('citizen shell renders dynamic QR and mesh HUD', (tester) async {
    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    expect(find.text('SOS BROADCAST'), findsOneWidget);
    expect(find.textContaining('DYNAMIC RATION QR'), findsOneWidget);
    expect(find.textContaining('CITIZEN ▸'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.textContaining('NO GPS HW FOUND', findRichText: true),
        findsWidgets);

    await teardown(tester, state);
  });

  testWidgets('officer mode gates on enlistment', (tester) async {
    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    await tester.tap(find.text('OFFICER'));
    await tester.pumpAndSettle();

    expect(find.textContaining('OFFICER ENLISTMENT'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('enlisted officer sees SCAN/LEDGER/MAP tabs', (tester) async {
    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    await tester.tap(find.text('OFFICER'));
    await tester.pumpAndSettle();

    await tester.runAsync(() => state.enlistOfficer(kSampleMasterKeyPayload));
    await tester.pumpAndSettle();

    expect(find.text('OFFICER ▸ OFF-0A3F0FAB'), findsOneWidget);
    expect(find.text('SCAN'), findsOneWidget);
    expect(find.text('LEDGER'), findsOneWidget);
    expect(find.text('MAP'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('HQ tab shows command dashboard telemetry', (tester) async {
    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    await tester.tap(find.text('HQ'));
    await tester.pumpAndSettle();

    expect(find.textContaining('COMMAND HQ'), findsOneWidget);
    expect(find.textContaining('AGGREGATE MESH HEALTH'), findsOneWidget);
    expect(find.textContaining('TRIAGE HEATMAP'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('settings tab exposes theme, accent and permission controls',
      (tester) async {
    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    await tester.tap(find.text('SETTINGS'));
    await tester.pumpAndSettle();

    expect(find.textContaining('APPEARANCE'), findsOneWidget);
    expect(find.textContaining('THEME'), findsOneWidget);
    expect(find.textContaining('USE DEVICE ACCENT COLOR'), findsOneWidget);
    expect(find.text('MESH LINK'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('material you off reveals accent swatches', (tester) async {
    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    await tester.tap(find.text('SETTINGS'));
    await tester.pumpAndSettle();

    state.setUseSystemDynamic(false);
    await tester.pumpAndSettle();

    expect(find.text('ACCENT COLOR'), findsOneWidget);
    expect(find.byTooltip('GREEN (FF00FF9C)'), findsOneWidget);
    expect(find.byTooltip('AMBER (FFFFB300)'), findsOneWidget);

    await teardown(tester, state);
  });
}