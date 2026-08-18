/// Three-mode shell: Citizen (default), Officer (enlisted), Command HQ (web).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import 'citizen_screen.dart';
import 'hq_screen.dart';
import 'hud_theme.dart';
import 'officer_screen.dart';

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
    final pages = [
      const CitizenScreen(),
      const OfficerScreen(),
      const HqScreen(),
    ];
    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: HudColors.primaryDim)),
        ),
        child: NavigationBar(
          backgroundColor: HudColors.bg,
          indicatorColor: HudColors.primary.withValues(alpha: 0.18),
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.person_outline),
              selectedIcon: const Icon(Icons.person),
              label: 'CITIZEN',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.shield_outlined,
                color: app.role == Role.officer
                    ? HudColors.primary
                    : HudColors.textDim,
              ),
              selectedIcon: const Icon(Icons.shield),
              label: 'OFFICER',
            ),
            const NavigationDestination(
              icon: Icon(Icons.monitor_heart_outlined),
              selectedIcon: Icon(Icons.monitor_heart),
              label: 'HQ',
            ),
          ],
        ),
      ),
    );
  }
}