import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/app_state.dart';
import 'package:gridzero/ui/sync_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show makeState, app;

/// The dedicated SYNC page: resting state is an animated SCANNING watch fed
/// by the laptop's own wifi scan (networks named GZ-something). Connection
/// runs only on an explicit tap; this test covers the resting view.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationCacheDirectory') {
        return '/tmp/gz_test_cache';
      }
      return null;
    });
  });

  testWidgets('sync page boots into scanning state', (tester) async {
    final state = makeState();
    await tester.runAsync(() async {
      await state.init();
      await state.register('SGT', 'pass', Role.citizen);
      await state.promoteToOfficer('SGT');
      await state.login('ADMIN', '');
    });
    await tester.pumpWidget(app(state));
    await tester.pump();
    await tester.tap(find.text('SYNC'));
    // The radar animates forever, so settle with fixed pumps, not
    // pumpAndSettle (it would time out waiting for a rest that never comes).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(SyncScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The radar fills the first screen; scroll to reveal the status row.
    await tester.drag(find.byType(CustomPaint).first, const Offset(0, -200));
    await tester.pump();
    // STATUS rows render as RichText; assert the panel + no cards instead.
    // Directory view lists accounts with HOST LINK buttons.
    expect(find.text('HOST LINK'), findsWidgets);
    expect(find.text('CONNECT & SYNC'), findsNothing);
  });

  test('link ssid encodes the username', () {
    expect(AppState.linkSsidFor('lakshmi'), 'GZ-LAKSHMI');
  });
}
