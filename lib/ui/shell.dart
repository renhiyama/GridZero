/// Mode shell: Citizen (default), Officer (enlisted), Command HQ and
/// Settings.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../core/app_state.dart';
import '../core/mesh/mesh_node.dart';
import 'chat_screen.dart';
import 'citizen_screen.dart';
import 'dashboard_screen.dart';
import 'directory_screen.dart';
import 'face_enroll_page.dart';
import 'hud_theme.dart';
import 'map_screen.dart';
import 'officer_screen.dart';
import 'register_screen.dart';
import 'settings_screen.dart';
import 'sos_banner.dart';
import 'sync_screen.dart';

class ModeShell extends StatefulWidget {
  const ModeShell({super.key});

  @override
  State<ModeShell> createState() => _ModeShellState();
}

class _ModeShellState extends State<ModeShell> {
  static const _navDuration = Duration(milliseconds: 300);
  static const _navCurve = Curves.easeInOutCubic;

  late int _index = 0;
  final PageController _pages = PageController();
  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app ??= AppScope.of(context)..navRequest.addListener(_consumeNav);
    final app = _app;
    if (app != null && app.pendingFaceEnrollFor != null) {
      // One-shot offer right after a fresh HQ provisioning scan. Runs after
      // the frame so the shell is mounted before the modal appears.
      WidgetsBinding.instance.addPostFrameCallback((_) => _offerFaceEnroll(app));
    }
  }

  Future<void> _offerFaceEnroll(AppState app) async {
    final name = app.pendingFaceEnrollFor;
    if (name == null) return;
    app.pendingFaceEnrollFor = null;
    if (!mounted) return;
    final enroll = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppPalette.of(ctx).bg,
        title: const Text('ENROLL FACE NOW?'),
        content: const Text(
          'One-time face capture binds your identity on this device. '
          'You can skip and add it later from Settings.',
          style: TextStyle(fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('SKIP'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ENROLL'),
          ),
        ],
      ),
    );
    if (enroll != true || !mounted) return;
    final embedding = await Navigator.of(context).push<Float32List>(
      MaterialPageRoute(builder: (_) => const FaceEnrollPage()),
    );
    if (embedding == null || !mounted) return;
    await app.saveFaceEmbedding(name, embedding);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            app.faceSyncedToHq
                ? 'FACE ENROLLED: already collected by HQ'
                : 'FACE ENROLLED: HQ collects it on your next link exchange',
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      );
    }
  }

@override
  void dispose() {
    _app?.navRequest.removeListener(_consumeNav);
    _pages.dispose();
    super.dispose();
  }

  /// Notification taps and deep links switch tabs; consume after one use so a
  /// stale request doesn't keep forcing the user back to HQ.
  void _consumeNav() {
    final target = _app!.navRequest.value;
    if (target == null) return;
    _app!.navRequest.value = null;
    // openSos targets the HQ tab; only ADMIN has HQ, and on the admin shell
    // it is the first tab. Other roles ignore the request (the SOS banner
    // already opens the responder radar directly).
    final hqIndex = _app!.role == Role.admin ? 0 : -1;
    final index = target == 2 ? hqIndex : target;
    if (index >= 0) _goTo(index);
  }

  /// Rail taps, notification requests and bottom-bar swipes all land here;
  /// swipes arrive through [PageView.onPageChanged] and converge on the same
  /// `_index`, so the active nav item always tracks the visible page.
  void _goTo(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    if (_pages.hasClients) {
      _pages.animateToPage(index, duration: _navDuration, curve: _navCurve);
    }
  }

  /// The page pager shared by both shells. The same `PageController` powers
  /// the rail and the bottom bar, so a swipe on either layout animates the
  /// page the same way the register tabs do. Desktop pages slide vertically
  /// to match the side rail; phone pages slide sideways under the bottom bar.
  Widget _pageView(List<Widget> pages, {required bool vertical}) => PageView(
    controller: _pages,
    scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
    onPageChanged: (i) {
      if (i != _index) setState(() => _index = i);
    },
    children: pages,
  );

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = AppPalette.of(context);
    final isAdmin = app.role == Role.admin;
    final isOfficer = app.role == Role.officer;
    final pages = isAdmin
        ? const <Widget>[
            DashboardScreen(),
            UsersScreen(),
            OfficersScreen(),
            SyncScreen(),
            ChatScreen(),
            RegisterScreen(),
            SettingsScreen(),
          ]
        : <Widget>[
            const CitizenScreen(),
            // Officers get a map inside the officer screen; no double maps.
            if (!isOfficer) const MapScreen(),
            const ChatScreen(),
            if (isOfficer) const OfficerScreen(),
            const SettingsScreen(),
          ];
    final items = isAdmin
        ? const <(String, IconData)>[
            ('HQ', Icons.monitor_heart_outlined),
            ('USERS', Icons.group_outlined),
            ('OFFICERS', Icons.badge_outlined),
            ('SYNC', Icons.wifi_tethering),
            ('MESH', Icons.forum_outlined),
            ('REGISTER', Icons.how_to_reg_outlined),
            ('SETTINGS', Icons.settings_outlined),
          ]
        : <(String, IconData)>[
            ('CITIZEN', Icons.person_outline),
            if (!isOfficer) ('MAP', Icons.map_outlined),
            ('MESH', Icons.forum_outlined),
            if (isOfficer) ('OFFICER', Icons.shield_outlined),
            ('SETTINGS', Icons.settings_outlined),
          ];
    // Officer enlistment can grow the tab list mid-session; keep the
    // selection in range and re-home the pager after the frame.
    if (_index >= pages.length) {
      _index = pages.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pages.hasClients) _pages.jumpToPage(_index);
      });
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Desktops get a persistent side rail; phones keep the bottom bar.
        if (constraints.maxWidth >= 900) {
          return _railLayout(app, p, items, pages);
        }
        return _bottomLayout(app, p, items, pages);
      },
    );
  }

  /// Wide-screen shell: icon+label rail down the left, content to the right.
  /// No fade overlay: the page owns its whole column. The top SOS banner is
  /// suppressed here: the rail's HQ item carries a live ping badge instead,
  /// and the dashboard's SOS·HELP panel holds the full list.
  Widget _railLayout(
    AppState app,
    AppPalette p,
    List<(String, IconData)> items,
    List<Widget> pages,
  ) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 168,
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: p.primaryDim, width: 1),
                    ),
                    color: p.panel.withValues(alpha: 0.5),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 18, 14, 16),
                        child: Row(
                          children: [
                            Container(width: 8, height: 8, color: p.primary),
                            const SizedBox(width: 8),
                            Text(
                              'GRIDZERO',
                              style: TextStyle(
                                color: p.primary,
                                fontFamily: 'monospace',
                                fontSize: 12,
                                letterSpacing: 2,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      for (var i = 0; i < items.length; i++)
                        _RailItem(
                          label: items[i].$1,
                          icon: items[i].$2,
                          selected: _index == i,
                          trailing: items[i].$1 == 'HQ'
                              ? _sosPingBadge(app)
                              : null,
                          onTap: () => _goTo(i),
                        ),
                    ],
                  ),
                ),
                Expanded(child: _pageView(pages, vertical: true)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Live SOS count pill for the HQ rail item. Streams mesh node updates so
  /// the badge appears the moment a peer beacon goes active.
  Widget _sosPingBadge(AppState app) {
    final mesh = app.mesh;
    if (mesh == null) return const SizedBox.shrink();
    return StreamBuilder<Map<int, MeshNodeState>>(
      stream: mesh.nodeUpdates,
      initialData: mesh.nodes,
      builder: (context, snap) {
        final count = (snap.data?.values ?? const <MeshNodeState>[])
            .where((n) => n.hasSos)
            .length;
        if (count == 0) return const SizedBox.shrink();
        final p = AppPalette.of(context);
        return Container(
          margin: const EdgeInsets.only(left: 8),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: p.error,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              color: onColor(p.error),
              fontFamily: 'monospace',
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      },
    );
  }

  /// Narrow/phone shell: content fades into a bottom bar.
  Widget _bottomLayout(
    AppState app,
    AppPalette p,
    List<(String, IconData)> items,
    List<Widget> pages,
  ) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: _pageView(pages, vertical: false)),
          // Integrated nav: page content fades into the bar instead of
          // stopping at a hard edge.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 86,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      p.bg.withValues(alpha: 0),
                      p.bg.withValues(alpha: 0.75),
                      p.bg,
                    ],
                    stops: const [0, 0.45, 0.8],
                  ),
                ),
              ),
            ),
          ),
          SosAlertBanner(app: app),
        ],
      ),
      extendBody: true,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.primaryDim)),
          color: Colors.transparent,
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
                    onTap: () => _goTo(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Desktop rail item: full-width row with a left indicator bar that grows on
/// selection, plus a hover state for mouse-driven desktops.
class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final target = widget.selected ? 1.0 : (_hovered ? 0.5 : 0.0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: widget.onTap,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: target),
          duration: _ModeShellState._navDuration,
          curve: _ModeShellState._navCurve,
          builder: (context, t, _) {
            final on = p.primary;
            final off = p.textDim;
            return Container(
              height: 54,
              padding: const EdgeInsets.only(left: 8),
              color: on.withValues(alpha: 0.10 * t),
              child: Row(
                children: [
                  Container(
                    width: 2,
                    height: 14 + 12 * t,
                    color: on.withValues(alpha: t),
                  ),
                  const SizedBox(width: 12),
                  Icon(widget.icon, color: Color.lerp(off, on, t), size: 20),
                  const SizedBox(width: 10),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      letterSpacing: 1,
                      fontWeight: FontWeight.bold,
                      color: Color.lerp(off, on, t),
                    ),
                  ),
                  if (widget.trailing != null) widget.trailing!,
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// HUD-style nav item: a rounded pill fills behind the active item while the
/// icon lifts and the indicator bar widens. Keeps the monospace theme but
/// reads as a modern navigation bar instead of a flat row of labels.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: selected ? 1.0 : 0.0),
        duration: _ModeShellState._navDuration,
        curve: _ModeShellState._navCurve,
        builder: (context, t, _) {
          final on = p.primary;
          final off = p.textDim;
          return Container(
            height: 58,
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              color: on.withValues(alpha: 0.12 * t),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 16 + 10 * t,
                  height: 2,
                  color: on.withValues(alpha: t),
                ),
                const SizedBox(height: 5),
                Transform.translate(
                  offset: Offset(0, -2 * t),
                  child: Icon(icon, color: Color.lerp(off, on, t), size: 22),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    letterSpacing: 1,
                    fontWeight: FontWeight.bold,
                    color: Color.lerp(off, on, t),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
