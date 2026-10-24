import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a map ring looks (owner 2026-10-24): shown or hidden, colour, opacity, filled or not.
/// Rings are always plain circles (owner: no dotted/dashed lines).
class RingLook {
  bool show;
  Color color;
  double opacity;
  bool fill;
  RingLook(this.color, this.opacity, {this.fill = true, this.show = true});
}

/// Ring keys → (title in settings, default look).
final Map<String, (String, RingLook)> kRingDefaults = {
  'drone':  ('Drone range', RingLook(Colors.orange, 0.5)),
  'scan':   ('Tech Center scan radius', RingLook(Colors.teal, 0.5)),
  'local':  ('Local range', RingLook(Colors.blueAccent, 0.7)),
  'boss':   ('Boss range (Haulage Firm: trucks, free repairs)', RingLook(Colors.grey, 0.8, fill: false)),
  'museum': ('Museum pick-up range', RingLook(Colors.yellow, 0.8, fill: false)),
  'reveal': ('Artifact reveal range', RingLook(Colors.purpleAccent, 0.8, fill: false)),
  'mafia':  ('Mafia attack range', RingLook(Colors.redAccent, 0.8, fill: false)),
};

final Map<String, RingLook> kRingLooks = {
  for (final e in kRingDefaults.entries)
    e.key: RingLook(e.value.$2.color, e.value.$2.opacity, fill: e.value.$2.fill, show: e.value.$2.show),
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
    final sh = p.getBool('${e.key}_ring_show');
    if (sh != null) e.value.show = sh;
  }
}

Future<void> saveRingLook(String key) async {
  final p = await SharedPreferences.getInstance();
  final l = kRingLooks[key]!;
  await p.setInt('${key}_ring_color', l.color.toARGB32());
  await p.setDouble('${key}_ring_opacity', l.opacity);
  await p.setBool('${key}_ring_fill', l.fill);
  await p.setBool('${key}_ring_show', l.show);
}

/// A ring of `radiusM` metres around `c` as a polygon (fill + plain border).
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
  );
}
