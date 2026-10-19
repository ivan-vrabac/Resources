import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import '../services/game_api.dart';
import 'async_view.dart';
import 'top_banner.dart';

/// Artifact detector on the map: while active it asks the server for the direction to the
/// nearest artifact (every 20 s, and when the player moved > 25 m) and draws a yellow triangle
/// from the player towards it. The exact spot only appears once within the reveal range.
class ArchaeologyController extends ChangeNotifier {
  bool active = false;
  bool showRing = false;
  double? bearing;
  String? band;
  double revealRange = 0;
  Map<String, dynamic>? revealed;
  String? message;
  Timer? _timer;
  LatLng? _lastQueryPos;
  String Function()? _sid;
  LatLng? Function()? _pos;
  bool _busy = false;

  void attach(String Function() sid, LatLng? Function() pos) {
    _sid = sid;
    _pos = pos;
  }

  Future<void> toggle(BuildContext context) async {
    active = !active;
    if (active) {
      await query(force: true);
      if (message != null && context.mounted) AppNotify.show(context, message!, isError: true);
      if (message != null) {
        active = false;
      } else {
        _timer = Timer.periodic(const Duration(seconds: 20), (_) => query());
      }
    } else {
      _timer?.cancel();
      bearing = null;
      revealed = null;
    }
    notifyListeners();
  }

  /// Called by the map when the GPS position changes; re-queries after real movement only.
  void onMoved() {
    if (!active) return;
    final p = _pos?.call(), last = _lastQueryPos;
    if (p != null && (last == null || const Distance().as(LengthUnit.Meter, p, last) > 25)) query();
  }

  Future<void> query({bool force = false}) async {
    final sid = _sid?.call(), pos = _pos?.call();
    if (sid == null || pos == null || _busy) {
      if (pos == null) message = 'Waiting for GPS…';
      return;
    }
    _busy = true;
    final r = await GameApi.call('/api/v1/archaeology/detect', sid, {'lat': pos.latitude, 'lng': pos.longitude});
    _busy = false;
    _lastQueryPos = pos;
    if (!r.ok) {
      message = r.message;
    } else {
      message = null;
      revealRange = (r.data['revealRange'] as num? ?? 0).toDouble();
      if (r.data['found'] == true) {
        bearing = (r.data['bearing'] as num).toDouble();
        band = r.data['band'] as String?;
        revealed = r.data['revealed'] as Map<String, dynamic>?;
      } else {
        bearing = null;
        band = null;
        revealed = null;
      }
    }
    notifyListeners();
  }

  Future<void> recover(BuildContext context) async {
    final sid = _sid?.call(), pos = _pos?.call(), site = revealed;
    if (sid == null || pos == null || site == null) return;
    final r = await GameApi.call('/api/v1/archaeology/recover', sid,
        {'id': site['id'], 'lat': pos.latitude, 'lng': pos.longitude});
    if (!context.mounted) return;
    if (r.ok) {
      AppNotify.show(context, 'Recovered ${r.data['name']}! (${r.data['archaeologistsUsed']} archaeologists)');
      revealed = null;
      await query(force: true);
    } else {
      AppNotify.show(context, r.message ?? 'Recovery failed', isError: true);
    }
  }

  void toggleRing() {
    showRing = !showRing;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class ArchaeologyLayers extends StatelessWidget {
  final ArchaeologyController controller;
  final LatLng? pos;
  const ArchaeologyLayers({super.key, required this.controller, required this.pos});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (ctx, __) {
        final c = controller;
        if (!c.active || pos == null) return const SizedBox.shrink();
        return Stack(children: [
          if (c.showRing && c.revealRange > 0)
            CircleLayer(circles: [
              CircleMarker(point: pos!, radius: c.revealRange, useRadiusInMeter: true,
                  color: Colors.yellow.withValues(alpha: 0.05),
                  borderColor: Colors.yellowAccent.withValues(alpha: 0.7), borderStrokeWidth: 1.2),
            ]),
          MarkerLayer(markers: [
            if (c.bearing != null && c.revealed == null)
              Marker(
                point: pos!,
                width: 120, height: 120,
                child: IgnorePointer(
                  child: Transform.rotate(
                    angle: c.bearing! * pi / 180,
                    child: CustomPaint(painter: _TrianglePainter()),
                  ),
                ),
              ),
            if (c.revealed != null)
              Marker(
                point: LatLng((c.revealed!['lat'] as num).toDouble(), (c.revealed!['lng'] as num).toDouble()),
                width: 44, height: 44,
                child: GestureDetector(
                  onTap: () => _confirmRecover(ctx),
                  child: Container(
                    decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black54,
                        border: Border.all(color: Colors.yellowAccent, width: 2)),
                    padding: const EdgeInsets.all(4),
                    child: Image.asset('assets/images/imgArtifact${c.revealed!['itemID']}.png',
                        errorBuilder: (_, __, ___) => const Icon(Icons.diamond, color: Colors.yellowAccent)),
                  ),
                ),
              ),
          ]),
        ]);
      },
    );
  }

  Future<void> _confirmRecover(BuildContext context) async {
    final site = controller.revealed!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Recover ${site['name']}?'),
        content: Text('${site['distance']} m away. Recovering uses archaeologists; '
            'you must be within your Museum pick-up range.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Recover')),
        ],
      ),
    );
    if (ok == true && context.mounted) controller.recover(context);
  }
}

class _TrianglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    // triangle 30–56 px "north" of the player (rotated by the bearing around the centre)
    final path = Path()
      ..moveTo(c.dx, c.dy - 56)
      ..lineTo(c.dx - 11, c.dy - 30)
      ..lineTo(c.dx + 11, c.dy - 30)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.yellowAccent.withValues(alpha: 0.9));
    canvas.drawPath(path, Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class DetectorButton extends StatelessWidget {
  final ArchaeologyController controller;
  const DetectorButton({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (_, __) => Material(
        color: controller.active ? Colors.yellow.shade700 : Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => controller.toggle(context),
          onLongPress: controller.active ? controller.toggleRing : null,
          child: SizedBox(
            width: 46, height: 46,
            child: Tooltip(
              message: controller.active
                  ? 'Detector on${controller.band != null ? ' · artifact ${controller.band}' : ' · nothing in range'}'
                      ' (long-press: reveal ring)'
                  : 'Artifact detector',
              child: Icon(Icons.track_changes, color: controller.active ? Colors.black : Colors.yellowAccent),
            ),
          ),
        ),
      ),
    );
  }
}

/// Archeology tab: levels, ranges, archaeologists and the artifact collection.
class ArchaeologyScreen extends StatefulWidget {
  final String Function() sid;
  const ArchaeologyScreen({super.key, required this.sid});
  @override
  State<ArchaeologyScreen> createState() => _ArchaeologyScreenState();
}

class _ArchaeologyScreenState extends State<ArchaeologyScreen> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await GameApi.call('/api/v1/archaeology/status', widget.sid());
    if (!mounted) return;
    setState(() { _loading = false; _error = r.ok ? null : r.message; if (r.ok) _d = r.data; });
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      builder: () {
        final d = _d!;
        final coll = (d['collection'] as List).cast<Map<String, dynamic>>();
        Widget row(String k, String v) => ListTile(dense: true, title: Text(k), trailing: Text(v));
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            if ((d['centerLevel'] as num) < 1)
              const Card(child: Padding(padding: EdgeInsets.all(12),
                  child: Text('Build an Archaeological Center (Special Buildings) to start detecting artifacts.'))),
            row('Archaeological Center', 'level ${d['centerLevel']}'),
            row('Detection range', '${((d['detectRange'] as num) / 1000).toStringAsFixed(1)} km'),
            row('Reveal range', '${(d['revealRange'] as num).round()} m'),
            row('Pick-up range (Museum ${d['museumLevel']})', '${(d['pickupRange'] as num).round()} m'),
            row('Archaeologists per recovery', '${d['archaeologistsNeeded']} (you have ${fmtQty(d['archaeologists'] as num)})'),
            row('Artifact Detectors', fmtQty(d['detectors'] as num)),
            const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
                child: Text('Turn on the detector with the yellow button on the left of the map. '
                    'Follow the triangle; the artifact appears when you are close enough.',
                    style: TextStyle(color: Colors.white54, fontSize: 12))),
            const Divider(),
            const Text('Collection', style: TextStyle(color: Colors.white54, fontSize: 12)),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 3,
              children: [
                for (final a in coll)
                  Opacity(
                    opacity: (a['found'] as num) > 0 ? 1 : 0.3,
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Image.asset('assets/images/imgArtifact${a['itemID']}.png', height: 56,
                          errorBuilder: (_, __, ___) => const Icon(Icons.diamond, size: 40)),
                      Text(a['name'] as String, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
                      Text('found ${a['found']}', style: const TextStyle(fontSize: 10, color: Colors.white54)),
                    ]),
                  ),
              ],
            ),
          ]),
        );
      },
    );
  }
}
