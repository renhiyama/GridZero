/// Mode shell: Citizen (default), Officer (enlisted), Command HQ (web) and
/// Settings.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import 'citizen_screen.dart';
import 'hq_screen.dart';
import 'hud_theme.dart';
import 'officer_screen.dart';
import 'settings_screen.dart';

class ModeShell extends StatefulWidget {
  const ModeShell({super.key});

  @override
  State<ModeShell> createState() => _ModeShellState();
}

class _ModeShellState extends State<ModeShell> {
  late int _index = kIsWeb ? 2 : 0;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    final pages = [
      const CitizenScreen(),
      const OfficerScreen(),
      const HqScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.primaryDim)),
        ),
        child: NavigationBar(
          backgroundColor: p.bg,
          indicatorColor: p.primary.withValues(alpha: 0.18),
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'CITIZEN',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.shield_outlined,
                color: app.role == Role.officer ? p.primary : p.textDim,
              ),
              selectedIcon: const Icon(Icons.shield),
              label: 'OFFICER',
            ),
            const NavigationDestination(
              icon: Icon(Icons.monitor_heart_outlined),
              selectedIcon: Icon(Icons.monitor_heart),
              label: 'HQ',
            ),
            const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'SETTINGS',
            ),
          ],
        ),
      ),
    );
  }
}
