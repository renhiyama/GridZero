import 'package:gridzero/app_scope.dart';
import 'package:gridzero/core/app_state.dart';
import 'package:gridzero/core/provision_packet.dart';
import 'package:gridzero/ui/hud_theme.dart';
import 'package:gridzero/ui/login_screen.dart';
import 'package:gridzero/ui/mesh_map.dart';
import 'package:gridzero/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gridzero/core/mesh_crypto.dart';
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
  setUp(() {
    setNetworkKey(null);
    SharedPreferences.setMockInitialValues({});
    // Path provider has no plugin in tests. FlutterMap's tile cache needs a
    // cache dir; the ledger's sqlite backend needs a support dir: returning
    // null there makes it fall back to its in-memory store, which is what the
    // tests expect. A null cache dir would let the map throw, so give it one.
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationCacheDirectory') {
        return '/tmp/gz_test_cache';
      }
      return null;
    });
  });
  testWidgets('citizen shell renders dynamic QR and mesh HUD', (tester) async {
    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    expect(find.text('SOS BROADCAST'), findsOneWidget);
    expect(find.textContaining('RATION QR'), findsOneWidget);
    // Presentation mode hides the technical header and reads big.
    expect(find.text('CITIZEN'), findsWidgets);
    expect(find.textContaining('AADHAAR ▸'), findsNothing);
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('FINDING YOUR LOCATION', findRichText: true),
      findsWidgets,
    );

    await teardown(tester, state);
  });

  testWidgets('technical details toggle reveals debug readouts', (tester) async {
    final state = makeState();
    await initState(tester, state);
    await state.setShowDebugInfo(true);
    await tester.pumpWidget(app(state));
    await tester.pump();

    expect(find.textContaining('AADHAAR ▸'), findsOneWidget);
    expect(find.textContaining('DYNAMIC RATION QR'), findsOneWidget);
    expect(find.textContaining('PACKET:', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('TOKEN:', findRichText: true),
      findsWidgets,
    );

    await teardown(tester, state);
  });

  testWidgets('page transition axis follows the shell layout', (tester) async {
    // Wide window: side rail layout slides pages vertically.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    expect(find.text('GRIDZERO'), findsOneWidget);
    final railView = tester.widget<PageView>(find.byType(PageView).first);
    expect(railView.scrollDirection, Axis.vertical);

    // Narrow window: bottom bar layout slides pages horizontally.
    tester.view.physicalSize = const Size(420, 900);
    await tester.pump();
    final barView = tester.widget<PageView>(find.byType(PageView).first);
    expect(barView.scrollDirection, Axis.horizontal);

    await teardown(tester, state);
  });

  testWidgets('officer tab gates on role, not on the tab bar', (tester) async {
    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    expect(find.text('OFFICER'), findsNothing);

    // Promotion routes through HQ provisioning, not self-enlistment: the
    // settings button scans an HQ-issued QR instead of promoting directly.
    await tester.tap(find.text('SETTINGS'));
    await tester.pumpAndSettle();
    expect(find.text('BECOME OFFICER (SCAN HQ QR)'), findsOneWidget);
    expect(find.text('OFFICER'), findsNothing);

    // A provisioned officer account unlocks the tab.
    final payload = encodeAccountProvision(
      purpose: ProvisionPurpose.officer,
      username: 'NAVIN',
      passwordHash: List.filled(64, 'a').join(),
      officerId: 'OFF-0A3F0FAB',
    );
    await tester.runAsync(() => state.provisionAccount(payload));
    await tester.pumpAndSettle();

    expect(state.role, Role.officer);
    expect(state.officerId, 'OFF-0A3F0FAB');
    expect(find.text('OFFICER'), findsOneWidget);
    await tester.tap(find.text('OFFICER'));
    await tester.pumpAndSettle();
    expect(find.text('SCAN'), findsOneWidget);
    expect(find.text('LEDGER'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('enlisted officer sees SCAN/LEDGER/MAP tabs', (tester) async {
    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    await tester.runAsync(() async {
      await state.provisionAccount(
        encodeAccountProvision(
          purpose: ProvisionPurpose.officer,
          username: 'NAVIN',
          passwordHash: List.filled(64, 'a').join(),
          officerId: 'OFF-0A3F0FAB',
        ),
      );
      // Suppress the post-provision one-shot dialog so it doesn't cover the
      // shell during the tab assertions.
      state.pendingFaceEnrollFor = null;
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('OFFICER'));
    await tester.pumpAndSettle();

    expect(find.text('OFFICER ▸ OFF-0A3F0FAB'), findsOneWidget);
    expect(find.text('SCAN'), findsOneWidget);
    expect(find.text('LEDGER'), findsOneWidget);
    expect(find.text('MAP'), findsWidgets);

    await teardown(tester, state);
  });

  testWidgets('HQ tab shows command dashboard telemetry', (tester) async {
    final state = makeState();
    await tester.runAsync(() async {
      await state.init();
      await state.login('ADMIN', 'x'); // HQ is admin-only
    });
    await tester.pumpWidget(app(state));
    await tester.pump();

    expect(find.text('HQ'), findsWidgets);
    await tester.tap(find.text('HQ'));
    await tester.pumpAndSettle();

    expect(find.textContaining('COMMAND HQ'), findsOneWidget);
    expect(find.textContaining('AGGREGATE MESH HEALTH'), findsOneWidget);
    expect(find.text('FIELD MAP'), findsOneWidget);
    expect(find.text('TRIAGE HEATMAP'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('admin REGISTER page separates citizen and officer onboarding', (
    tester,
  ) async {
    final state = makeState();
    await tester.runAsync(() async {
      await state.init();
      await state.login('ADMIN', 'x');
    });
    await tester.pumpWidget(app(state));
    await tester.pump();

    await tester.tap(find.text('REGISTER'));
    await tester.pumpAndSettle();

    // Citizen tab is default: account + family card provisioning only.
    expect(find.text('CREATE CITIZEN ACCOUNT'), findsWidgets);
    expect(find.text('FAMILY CARD QR'), findsOneWidget);
    expect(find.text('ENLISTMENT QR'), findsNothing);

    // Officer tab carries the promotion generator + officer registry.
    await tester.tap(find.text('OFFICER'));
    await tester.pumpAndSettle();
    expect(find.text('ENROL OFFICER (FROM EXISTING USER)'), findsWidgets);
    expect(find.text('OFFICER REGISTRY'), findsOneWidget);
    expect(find.textContaining('ENCRYPTED OFFICER DB'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('citizen shell hides the HQ tab', (tester) async {
    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    expect(find.text('HQ'), findsNothing);
    expect(find.text('CITIZEN'), findsWidgets);
    expect(find.text('MAP'), findsOneWidget);
    expect(find.text('OFFICER'), findsNothing);

    await teardown(tester, state);
  });

  testWidgets('wide window switches to the desktop side rail', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = makeState();
    await initState(tester, state);
    await tester.pumpWidget(app(state));
    await tester.pump();

    expect(find.text('GRIDZERO'), findsOneWidget);
    expect(find.text('CITIZEN'), findsWidgets);
    expect(find.text('MAP'), findsOneWidget);
    expect(find.text('OFFICER'), findsNothing);

    await tester.tap(find.text('SETTINGS'));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE'), findsOneWidget);

    await teardown(tester, state);
  });

  testWidgets('map zoom slider and buttons drive the camera', (tester) async {
    final state = makeState();
    await tester.runAsync(() => state.init());
    final mesh = state.mesh!;
    addTearDown(() => state.dispose());

    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          theme: HudTheme.dark,
          home: Scaffold(
            body: SizedBox(width: 600, height: 400, child: MeshMap(mesh: mesh)),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('16×'), findsOneWidget);

    await tester.tap(find.text('＋'));
    await tester.pump();
    expect(find.text('16.5×'), findsOneWidget);

    await tester.drag(find.byType(Slider), const Offset(-120, 0));
    await tester.pump();
    final zoomText = tester
        .widgetList<Text>(find.textContaining('×'))
        .map((t) => t.data)
        .toList();
    expect(zoomText, isNotEmpty);
    expect(double.parse(zoomText.single!.replaceAll('×', '')), lessThan(16.5));

    await tester.pumpWidget(const SizedBox());
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
    // Primary path is the QR scan; the manual form lives collapsed behind
    // "alternative ways".
    expect(find.text('SCAN PROVISIONING QR'), findsOneWidget);
    expect(find.text('MANUAL LOGIN'), findsNothing);
    await tester.tap(find.text('ALTERNATIVE WAYS TO LOG IN'));
    await tester.pumpAndSettle();
    expect(find.text('MANUAL LOGIN'), findsOneWidget);
    expect(find.text('USERNAME'), findsOneWidget);
    expect(find.text('PASSWORD'), findsOneWidget);

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

  testWidgets('admin shell shows HQ + REGISTER + settings only', (
    tester,
  ) async {
    final state = makeState();
    await tester.runAsync(() async {
      await state.init();
      await state.login('ADMIN', '');
    });
    await tester.pumpWidget(app(state));
    await tester.pump();

    expect(state.role, Role.admin);
    expect(find.text('HQ'), findsWidgets);
    expect(find.text('REGISTER'), findsWidgets);
    expect(find.text('SETTINGS'), findsWidgets);
    expect(find.text('CITIZEN'), findsNothing);
    expect(find.text('OFFICER'), findsNothing);

    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -1400),
    );
    await tester.pumpAndSettle();
    expect(find.text('DEVICES ON MESH'), findsWidgets);
    expect(find.text('SELF'), findsWidgets);

    await teardown(tester, state);
  });
}
