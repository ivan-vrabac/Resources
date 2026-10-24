import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a map ring looks (owner 2026-10-24): colour, opacity, filled or not, line style.
class RingLook {
  Color color;
  double opacity;
  bool fill;
  String pattern;      // solid, dotted, dashed, dotdash, dashdashdot
  RingLook(this.color, this.opacity, {this.fill = true, this.pattern = 'solid'});
}

const kRingPatterns = ['solid', 'dotted', 'dashed', 'dotdash', 'dashdashdot'];
const kRingPatternNames = {
  'solid': 'Solid', 'dotted': 'Dotted', 'dashed': 'Dashed', 'dotdash': 'Dot-dash', 'dashdashdot': 'Dash-dash-dot',
};

/// Ring keys → (title in settings, default look).
final Map<String, (String, RingLook)> kRingDefaults = {
  'drone':  ('Drone range', RingLook(Colors.orange, 0.5)),
  'scan':   ('Tech Center scan radius', RingLook(Colors.teal, 0.5)),
  'local':  ('Local range', RingLook(Colors.blueAccent, 0.7)),
  'boss':   ('Boss range (Haulage Firm: trucks, free repairs)', RingLook(Colors.grey, 0.8, fill: false, pattern: 'dotdash')),
  'museum': ('Museum pick-up range', RingLook(Colors.yellow, 0.8, fill: false, pattern: 'dashed')),
  'reveal': ('Artifact reveal range', RingLook(Colors.purpleAccent, 0.8, fill: false, pattern: 'dotted')),
  'mafia':  ('Mafia attack range', RingLook(Colors.redAccent, 0.8, fill: false, pattern: 'dashdashdot')),
};

final Map<String, RingLook> kRingLooks = {
  for (final e in kRingDefaults.entries)
    e.key: RingLook(e.value.$2.color, e.value.$2.opacity, fill: e.value.$2.fill, pattern: e.value.$2.pattern),
};

/// Colours offered for rings (more than before: yellow and grey included).
const List<Color> kRingColorPresets = [
  Colors.teal, Colors.blueAccent, Colors.deepPurple, Colors.greenAccent, Colors.orange, Colors.redAccent,
  Colors.yellow, Colors.grey, Colors.purpleAccent, Colors.white, Colors.cyanAccent, Colors.pinkAccent,
];

Future<void> loadRingLooks() async {
  final p = await SharedPreferences.getInstance();
  for (final e in kRingLooks.entries) {
    final c = p.getInt('${e.key}_ring_color');
    if (c != null) e.value.color = Color(c);
    final o = p.getDouble('${e.key}_ring_opacity');
    if (o != null) e.value.opacity = o.clamp(0.0, 1.0);
    final f = p.getBool('${e.key}_ring_fill');
    if (f != null) e.value.fill = f;
    final pt = p.getString('${e.key}_ring_pattern');
    if (pt != null && kRingPatterns.contains(pt)) e.value.pattern = pt;
  }
}

Future<void> saveRingLook(String key) async {
  final p = await SharedPreferences.getInstance();
  final l = kRingLooks[key]!;
  await p.setInt('${key}_ring_color', l.color.toARGB32());
  await p.setDouble('${key}_ring_opacity', l.opacity);
  await p.setBool('${key}_ring_fill', l.fill);
  await p.setString('${key}_ring_pattern', l.pattern);
}

StrokePattern strokePattern(String p) => switch (p) {
      'dotted' => const StrokePattern.dotted(spacingFactor: 2.5),
      'dashed' => StrokePattern.dashed(segments: const [12, 7]),
      'dotdash' => StrokePattern.dashed(segments: const [2, 6, 12, 6]),
      'dashdashdot' => StrokePattern.dashed(segments: const [12, 5, 12, 5, 2, 5]),
      _ => const StrokePattern.solid(),
    };

/// A ring of `radiusM` metres around `c` as a polygon (fill + patterned border).
Polygon ringPolygon(LatLng c, double radiusM, String key) {
  final look = kRingLooks[key]!;
  const n = 120;
  final dLat = radiusM / 111320.0;
  final dLng = dLat / math.max(0.01, math.cos(c.latitude * math.pi / 180));
  final pts = [
    for (var i = 0; i <= n; i++)
      LatLng(c.latitude + dLat * math.cos(2 * math.pi * i / n), c.longitude + dLng * math.sin(2 * math.pi * i / n)),
  ];
  return Polygon(
    points: pts,
    color: look.fill ? look.color.withValues(alpha: look.opacity * 0.12) : null,
    borderColor: look.color.withValues(alpha: look.opacity.clamp(0.15, 1.0)),
    borderStrokeWidth: 1.6,
    pattern: strokePattern(look.pattern),
  );
}
