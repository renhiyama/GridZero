import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gridzero/core/app_state.dart';
import 'package:gridzero/ui/hud_theme.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show makeState, app;

/// Regression: showing a re-login QR from the directory used an AlertDialog,
/// whose IntrinsicWidth measurement crashed against QrImageView's internal
/// LayoutBuilder ("LayoutBuilder does not support returning intrinsic
/// dimensions"): the dialog rendered empty behind the dimmed barrier with a
/// mouse_tracker assertion cascade. The dialog is a plain Dialog now; this
/// test keeps QR popups rendering on both directory pages.
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

  Future<AppState> adminWithUser(WidgetTester tester, AppState state) async {
    await tester.runAsync(() async {
      await state.init();
      // register() starts the new account's session; hand control back to
      // ADMIN afterwards so the directory tabs are on screen.
      await state.register('QRO', 'pass', Role.citizen);
      await state.promoteToOfficer('QRO');
      await state.login('ADMIN', '');
    });
    return state;
  }

  testWidgets('users list re-login QR dialog renders frames', (tester) async {
    final state = await adminWithUser(tester, makeState());
    await tester.pumpWidget(app(state));
    await tester.pump();
    await tester.tap(find.text('USERS'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.qr_code_2).first);
    await tester.pumpAndSettle();

    expect(find.byType(HudPagedQr), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('CLOSE'));
    await tester.pumpAndSettle();
    expect(find.byType(HudPagedQr), findsNothing);
  });

  testWidgets('officers list re-login QR dialog renders frames', (
    tester,
  ) async {
    final state = await adminWithUser(tester, makeState());
    await tester.pumpWidget(app(state));
    await tester.pump();
    await tester.tap(find.text('OFFICERS'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.qr_code_2).first);
    await tester.pumpAndSettle();

    expect(find.byType(HudPagedQr), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('demote and delete ask for confirmation first', (tester) async {
    final state = await adminWithUser(tester, makeState());
    await tester.pumpWidget(app(state));
    await tester.pump();
    await tester.tap(find.text('USERS'));
    await tester.pumpAndSettle();

    // Cancel path: account survives.
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.text('DELETE ACCOUNT?'), findsOneWidget);
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(
      (await state.accounts()).any((u) => u.username == 'QRO'),
      isTrue,
    );

    // Confirm path: demote strips the officer role.
    await tester.tap(find.byIcon(Icons.person_remove_outlined).first);
    await tester.pumpAndSettle();
    expect(find.text('DEMOTE TO CITIZEN?'), findsOneWidget);
    await tester.tap(find.text('CONFIRM'));
    await tester.pumpAndSettle();
    final sgt = (await state.accounts()).singleWhere(
      (u) => u.username == 'QRO',
    );
    expect(sgt.role, Role.citizen);
    expect(sgt.officerId, isNull);
  });
}
