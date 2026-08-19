import 'package:gridzero/app_scope.dart';
import 'package:gridzero/core/app_state.dart';
import 'package:gridzero/core/master_key.dart';
import 'package:gridzero/ui/hud_theme.dart';
import 'package:gridzero/ui/login_screen.dart';
import 'package:gridzero/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_mesh_adapter.dart';

AppState makeState() {
  AppState.nativeAdapterFactory = (nodeId) => FakeMeshAdapter();
  return AppState();
}

Widget app(AppState state) => AppScope(
  state: state,
  child: MaterialApp(theme: HudTheme.dark, home: const ModeShell()),
);

Widget loginApp(AppState state) => AppScope(
  state: state,
  child: MaterialApp(theme: HudTheme.dark, home: const LoginScreen()),
);

Future<void> initState(WidgetTester tester, AppState state) =>
    tester.runAsync(() async {
      await state.init();
      // The shell only exists after a session; log in as a citizen.
      await state.register('TESTUSER', 'pass', Role.citizen);
    });

Future<void> teardown(WidgetTester tester, AppState state) async {
  // Unmount widgets so their periodic timers are disposed, then drop state.
  await tester.pumpWidget(const SizedBox());
  state.dispose();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
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
    expect(
      find.textContaining('NO GPS HW FOUND', findRichText: true),
      findsWidgets,
    );

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
    expect(find.textContaining('ENLISTMENT QR'), findsOneWidget);
    expect(find.textContaining('FAMILY CARD QR'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('settings tab exposes theme, accent and permission controls', (
    tester,
  ) async {
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

  testWidgets('login screen gates the shell', (tester) async {
    final state = makeState();
    await tester.runAsync(() => state.init());
    await tester.pumpWidget(loginApp(state));
    await tester.pump();

    expect(state.loggedIn, isFalse);
    expect(find.text('LOGIN'), findsOneWidget);
    expect(find.textContaining('USERNAME ADMIN'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'ADMIN');
    await tester.enterText(find.byType(TextField).last, 'anything');
    await tester.tap(find.text('LOG IN'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();

    expect(state.loggedIn, isTrue);

    await teardown(tester, state);
  });

  testWidgets('admin shell shows HQ + settings only', (tester) async {
    final state = makeState();
    await tester.runAsync(() async {
      await state.init();
      await state.login('ADMIN', '');
    });
    await tester.pumpWidget(app(state));
    await tester.pump();

    expect(state.role, Role.admin);
    expect(find.text('HQ'), findsWidgets);
    expect(find.text('SETTINGS'), findsWidgets);
    expect(find.text('CITIZEN'), findsNothing);
    expect(find.text('OFFICER'), findsNothing);

    await tester.drag(find.byType(ListView).first, const Offset(0, -1400));
    await tester.pumpAndSettle();
    expect(find.text('PEERS'), findsWidgets);

    await teardown(tester, state);
  });
}
