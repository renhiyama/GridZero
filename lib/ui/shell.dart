/// Mode shell: Citizen (default), Officer (enlisted), Command HQ and
/// Settings.
library;

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
  late int _index = 0;

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
    final items = <(String, IconData)>[
      ('CITIZEN', Icons.person_outline),
      ('OFFICER', Icons.shield_outlined),
      ('HQ', Icons.monitor_heart_outlined),
      ('SETTINGS', Icons.settings_outlined),
    ];
    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.primaryDim)),
          boxShadow: [
            BoxShadow(color: p.primary.withValues(alpha: 0.14), blurRadius: 12),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom,
          ),
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _NavItem(
                    label: items[i].$1,
                    icon: items[i].$2,
                    selected: _index == i,
                    unlocked: i == 1 && app.role == Role.officer,
                    onTap: () => setState(() => _index = i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// HUD-style nav item: icon + label over a 1px top indicator. Matches the
/// rest of the theme instead of the stock Material `NavigationBar`.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.unlocked,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool unlocked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final active = selected || unlocked;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 58,
        color: selected ? p.primary.withValues(alpha: 0.10) : p.bg,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 22,
              height: 2,
              color: selected ? p.primary : Colors.transparent,
            ),
            const SizedBox(height: 5),
            Icon(icon, color: active ? p.primary : p.textDim, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                letterSpacing: 1,
                fontWeight: FontWeight.bold,
                color: selected ? p.primary : p.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
