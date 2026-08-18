import 'package:flutter/material.dart';

import 'core/app_state.dart';

/// Hands the singleton [AppState] to any widget in the tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
