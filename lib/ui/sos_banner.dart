/// In-app SOS alert: a persistent red bar across the top of the shell and the
/// login screen while any peer is actively beaconing. Tap opens the responder
/// radar; X silences the current episode (a fresh SOS from a new node
/// re-alerts). Lives on the always-running anonymous mesh, so a peer's beacon
/// is visible even before this device logs in.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/mesh/mesh_node.dart';
import 'hud_theme.dart';
import 'radar_screen.dart';

class SosAlertBanner extends StatefulWidget {
  const SosAlertBanner({super.key, required this.app});

  final AppState app;

  @override
  State<SosAlertBanner> createState() => _SosAlertBannerState();
}

class _SosAlertBannerState extends State<SosAlertBanner> {
  final Set<int> _dismissed = {};
  StreamSubscription<MeshNodeState>? _startedSub;
  StreamSubscription<MeshNodeState>? _endedSub;

  @override
  void initState() {
    super.initState();
    // A brand-new SOS re-alerts even if a previous one was dismissed.
    final m = widget.app.mesh;
    if (m == null) return;
    _startedSub = m.sosStarted.listen(
      (n) => setState(() => _dismissed.remove(n.nodeId)),
    );
    _endedSub = m.sosEnded.listen(
      (n) => setState(() => _dismissed.remove(n.nodeId)),
    );
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
    if (mesh == null) return const SizedBox.shrink();
    return StreamBuilder<Map<int, MeshNodeState>>(
      stream: mesh.nodeUpdates,
      initialData: mesh.nodes,
      builder: (context, snap) {
        final active =
            (snap.data?.values ?? <MeshNodeState>[])
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
                            Icon(Icons.sos, color: onColor(p.error), size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                active.length == 1
                                    ? 'SOS ACTIVE: NODE '
                                          '${top.nodeId.toRadixString(16).toUpperCase()} · '
                                          'TRIAGE ${top.severity}: TAP TO TRACK'
                                    : '${active.length} SOS ACTIVE: '
                                          'TOP TRIAGE ${top.severity}: '
                                          'TAP TO TRACK',
                                style: TextStyle(
                                  color: onColor(p.error),
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.close, color: onColor(p.error)),
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
