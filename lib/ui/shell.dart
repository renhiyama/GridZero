/// Mode shell: Citizen (default), Officer (enlisted), Command HQ and
/// Settings.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/mesh/mesh_node.dart';
import 'citizen_screen.dart';
import 'hq_screen.dart';
import 'hud_theme.dart';
import 'officer_screen.dart';
import 'radar_screen.dart';
import 'settings_screen.dart';

class ModeShell extends StatefulWidget {
  const ModeShell({super.key});

  @override
  State<ModeShell> createState() => _ModeShellState();
}

class _ModeShellState extends State<ModeShell> {
  late int _index = 0;
  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app ??= AppScope.of(context)..navRequest.addListener(_consumeNav);
  }

  @override
  void dispose() {
    _app?.navRequest.removeListener(_consumeNav);
    super.dispose();
  }

  /// Notification taps and deep links switch tabs; consume after one use so a
  /// stale request doesn't keep forcing the user back to HQ.
  void _consumeNav() {
    final target = _app!.navRequest.value;
    if (target == null) return;
    _app!.navRequest.value = null;
    if (target != _index) setState(() => _index = target);
  }

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
      body: Stack(
        children: [
          Positioned.fill(child: pages[_index]),
          _SosAlertBanner(app: app),
        ],
      ),
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

/// In-app SOS alert: a persistent red bar across every tab while any peer is
/// actively beaconing. Tap opens the responder radar; X silences the current
/// episode (a fresh SOS from a new node re-alerts).
class _SosAlertBanner extends StatefulWidget {
  const _SosAlertBanner({required this.app});

  final AppState app;

  @override
  State<_SosAlertBanner> createState() => _SosAlertBannerState();
}

class _SosAlertBannerState extends State<_SosAlertBanner> {
  final Set<int> _dismissed = {};
  StreamSubscription<MeshNodeState>? _startedSub;
  StreamSubscription<MeshNodeState>? _endedSub;

  @override
  void initState() {
    super.initState();
    // A brand-new SOS re-alerts even if a previous one was dismissed.
    _startedSub = widget.app.mesh.sosStarted
        .listen((n) => setState(() => _dismissed.remove(n.nodeId)));
    _endedSub = widget.app.mesh.sosEnded
        .listen((n) => setState(() => _dismissed.remove(n.nodeId)));
  }

  @override
  void dispose() {
    _startedSub?.cancel();
    _endedSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final mesh = widget.app.mesh;
    return StreamBuilder<Map<int, MeshNodeState>>(
      stream: mesh.nodeUpdates,
      initialData: mesh.nodes,
      builder: (context, snap) {
        final active = (snap.data?.values ?? <MeshNodeState>[])
            .where((n) => n.hasSos && !_dismissed.contains(n.nodeId))
            .toList()
          ..sort((a, b) => b.severity.compareTo(a.severity));
        final top = active.isEmpty ? null : active.first;
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: top == null
              // Must stay Positioned so it never becomes the Stack's sizing
              // child: a loose Stack collapses to the biggest non-positioned
              // child, which would crush the page to 0x0.
              ? const SizedBox.shrink()
              : Material(
                  color: p.error,
                  child: SafeArea(
                    bottom: false,
                    child: InkWell(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RadarScreen(nodeId: top.nodeId),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.sos,
                              color: Colors.white,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                active.length == 1
                                    ? 'SOS ACTIVE — NODE '
                                        '${top.nodeId.toRadixString(16).toUpperCase()} · '
                                        'TRIAGE ${top.severity} — TAP TO TRACK'
                                    : '${active.length} SOS ACTIVE — '
                                        'TOP TRIAGE ${top.severity} — '
                                        'TAP TO TRACK',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.close,
                                color: Colors.white,
                              ),
                              onPressed: () => setState(
                                () => _dismissed.addAll(
                                  active.map((n) => n.nodeId),
                                ),
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        );
      },
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
