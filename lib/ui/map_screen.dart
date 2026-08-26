/// Phone-side field map: full-bleed `MeshMap` as the dedicated MAP tab on
/// narrow screens. No chrome of its own: the map owns the whole surface.
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import 'hud_theme.dart';
import 'mesh_map.dart';

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final mesh = app.mesh;
    if (mesh == null) {
      final p = AppPalette.of(context);
      return ColoredBox(
        color: p.bg,
        child: Center(
          child: Text(
            'MESH NOT UP',
            style: TextStyle(
              color: p.textDim,
              fontFamily: 'monospace',
              fontSize: 12,
              letterSpacing: 2,
            ),
          ),
        ),
      );
    }
    return MeshMap(
      mesh: mesh,
      landmarks: AppScope.of(context).officialLandmarks
          .where((l) => !l.isExpired)
          .toList(),
    );
  }
}
