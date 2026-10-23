import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../constants.dart';
import '../services/game_api.dart';
import 'async_view.dart';
import 'top_banner.dart';
import '../screens/settings_screen.dart' show kShowMuseumRing;

/// Holiday crate art: the week (Mon–Sun) containing Christmas, Easter Sunday or Halloween uses
/// its own crate set; otherwise the regular cargo box / container art.
String? _holiday(DateTime d) {
  bool sameWeek(DateTime a, DateTime b) {
    final ma = DateTime(a.year, a.month, a.day).subtract(Duration(days: a.weekday - 1));
    final mb = DateTime(b.year, b.month, b.day).subtract(Duration(days: b.weekday - 1));
    return ma == mb;
  }
  if (sameWeek(d, DateTime(d.year, 12, 25))) return 'chris';
  if (sameWeek(d, DateTime(d.year, 10, 31))) return 'hw';
  if (sameWeek(d, _easter(d.year))) return 'easter';
  return null;
}

DateTime _easter(int y) {            // Anonymous Gregorian algorithm
  final a = y % 19, b = y ~/ 100, c = y % 100, d = b ~/ 4, e = b % 4, f = (b + 8) ~/ 25;
  final g = (b - f + 1) ~/ 3, h = (19 * a + b - d - g + 15) % 30, i = c ~/ 4, k = c % 4;
  final l = (32 + 2 * e + 2 * i - h - k) % 7, m = (a + 11 * h + 22 * l) ~/ 451;
  final month = (h + l - 7 * m + 114) ~/ 31, day = ((h + l - 7 * m + 114) % 31) + 1;
  return DateTime(y, month, day);
}

/// Map marker image for a crate (variant picked from its id so it stays the same).
String cargoMarkerAsset(Map<String, dynamic> c) {
  final v = (c['id'] as String? ?? '').hashCode.abs();
  if (c['stacked'] == true) return 'assets/mapmarkers/stacked${1 + v % 2}_map.png';
  final h = _holiday(DateTime.now());
  if (h != null) return 'assets/mapmarkers/cargo$h${v % 5}_map.png';
  return v % 5 == 0 ? 'assets/mapmarkers/cargobox_map.png' : 'assets/mapmarkers/cargocontainer${v % 4}_map.png';
}

/// Cargo Rain on the map: crate markers, the Museum collection-range ring and the left-side
/// controls (stock/drop, trucks). Kept out of map_tab.dart; the map only forwards bounds and taps.
class CargoController extends ChangeNotifier {
  List<Map<String, dynamic>> crates = [];
  Map<String, dynamic> info = const {};
  bool showRing = false;
  bool _loading = false;

  int get haulageLevel => (info['haulage'] as num? ?? 0).toInt();

  /// Repaint once a marker image has been decoded.
  void repaint() => notifyListeners();

  /// The crate under a map tap (within its drawn size), or null.
  Map<String, dynamic>? hitTest(LatLng tap, double zoom) {
    final mpp = metersPerPixel(tap.latitude, zoom);
    Map<String, dynamic>? best;
    var bestD = double.infinity;
    for (final c in crates) {
      final d = const Distance().as(LengthUnit.Meter, tap, LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble()));
      final r = max(cargoMeters(c), 24 * mpp) / 2;          // at least a finger-sized target
      if (d <= r && d < bestD) {
        best = c;
        bestD = d;
      }
    }
    return best;
  }
  int get trucks => (info['trucks'] as num? ?? 0).toInt();

  int get stock => (info['crates'] as num? ?? 0).toInt();
  double get collectRange => (info['collectRange'] as num? ?? 50).toDouble();

  Future<void> refreshInfo(String sid) async {
    final r = await GameApi.call('/api/v1/cargo/stock', sid);
    if (r.ok) {
      info = r.data;
      notifyListeners();
    }
  }

  /// Load visible crates for the viewport (only at close zoom, where they're readable).
  Future<void> load(String sid, LatLngBounds b, double zoom) async {
    if (_loading) return;
    if (zoom < 15) {
      if (crates.isNotEmpty) {
        crates = [];
        notifyListeners();
      }
      return;
    }
    _loading = true;
    final r = await GameApi.call('/api/v1/cargo/nearby', sid,
        {'lat1': b.south, 'lng1': b.west, 'lat2': b.north, 'lng2': b.east});
    _loading = false;
    if (r.ok) {
      crates = r.list('crates');
      notifyListeners();
    }
  }

  void toggleRing() {
    showRing = !showRing;
    notifyListeners();
  }

  Future<void> collect(BuildContext context, String sid, Map<String, dynamic> crate, LatLng? pos) async {
    if (pos == null) {
      AppNotify.show(context, 'Waiting for GPS…', isError: true);
      return;
    }
    String method = 'hand';
    if (crate['stacked'] == true) {
      final pick = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: const Color(0xFF1A1A2E),
        builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('Stacked cargo (${fmtNum((crate['count'] as num? ?? 100).toInt())} crates)'),
              subtitle: const Text('Needs one truck per crate (in range, not used up) or one drone per crate (remote, used up).')),
          ListTile(
            leading: const ItemIcon(124),
            title: Text('Truck (you have ${fmtQty(info['trucks'] as num? ?? 0)})'),
            subtitle: Text('Within ${collectRange.round()} m · truck is not used up'),
            onTap: () => Navigator.pop(context, 'truck'),
          ),
          ListTile(
            leading: const ItemIcon(117),
            title: Text('Scan drone (you have ${fmtQty(info['drones'] as num? ?? 0)})'),
            subtitle: Text((info['droneRange'] as num? ?? 0) > 0
                ? 'Within ${((info['droneRange'] as num) / 1000).toStringAsFixed(1)} km · uses 1 drone'
                : 'Needs Drone Research level 5'),
            onTap: () => Navigator.pop(context, 'drone'),
          ),
        ])),
      );
      if (pick == null) return;
      method = pick;
    }
    final r = await GameApi.call('/api/v1/cargo/collect', sid,
        {'id': crate['id'], 'method': method, 'lat': pos.latitude, 'lng': pos.longitude});
    if (!context.mounted) return;
    if (r.ok) {
      AppNotify.show(context, 'Found ${(r.data['qty'] as num).toInt()} × ${itemName(r.data['itemID'] as int)}');
      crates.removeWhere((c) => c['id'] == crate['id']);
      notifyListeners();
      refreshInfo(sid);
    } else {
      AppNotify.show(context, r.message ?? 'Could not collect', isError: true);
      if (r.code == 'gone') {
        crates.removeWhere((c) => c['id'] == crate['id']);
        notifyListeners();
      }
    }
  }

  /// Haulage Firm ≥ 5: collect every crate in truck range in one go.
  Future<void> truckCollect(BuildContext context, String sid, LatLng? pos) async {
    if (pos == null) {
      AppNotify.show(context, 'Waiting for GPS…', isError: true);
      return;
    }
    final p = await GameApi.call('/api/v1/cargo/truck', sid, {'lat': pos.latitude, 'lng': pos.longitude, 'preview': 1});
    if (!context.mounted) return;
    if (!p.ok) {
      AppNotify.show(context, p.message ?? 'Trucks unavailable', isError: true);
      return;
    }
    final n = (p.data['crates'] as num).toInt(), st = (p.data['stacks'] as num).toInt();
    final loose = (p.data['loose'] as num? ?? n).toInt(), inStacks = (p.data['stackCrates'] as num? ?? 0).toInt();
    final need = (p.data['trucksNeeded'] as num).toInt(), have = (p.data['trucks'] as num).toInt();
    if (n + st == 0) {
      AppNotify.show(context, 'No cargo within ${(p.data['range'] as num).round()} m');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Collect cargo by truck'),
        content: Text('Use ${fmtNum(min(need, have))}/${fmtNum(have)} trucks to collect cargo nearby?\n\n'
            '${fmtNum(loose)} crate${loose == 1 ? '' : 's'}'
            '${st > 0 ? ' and $st stack${st == 1 ? '' : 's'} (${fmtNum(inStacks)} crates)' : ''} within '
            '${(p.data['range'] as num).round()} m · one truck per crate'
            '${need > have ? '\nYou need ${fmtNum(need)} trucks to take everything at once.' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: have < 1 ? null : () => Navigator.pop(ctx, true), child: const Text('Collect')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final r = await GameApi.call('/api/v1/cargo/truck', sid, {'lat': pos.latitude, 'lng': pos.longitude});
    if (!context.mounted) return;
    if (!r.ok) {
      AppNotify.show(context, r.message ?? 'Collection failed', isError: true);
      return;
    }
    final items = (r.data['items'] as List).cast<Map<String, dynamic>>();
    crates = [];                       // the map reloads what is still there
    notifyListeners();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Collected ${fmtNum((r.data['collected'] as num).toInt())} crate${r.data['collected'] == 1 ? '' : 's'}'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (items.isEmpty) const Text('Nothing fit into your warehouse.'),
            for (final it in items)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: ItemIcon((it['itemID'] as num).toInt(), size: 32),
                title: Text(itemName((it['itemID'] as num).toInt())),
                trailing: Text('× ${fmtNum((it['qty'] as num).toInt())}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            if ((r.data['left'] as num) > 0)
              Text('${r.data['left']} crates are still waiting — you need more trucks.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
    refreshInfo(sid);
  }

  Future<void> openPanel(BuildContext context, String sid, LatLng? pos, VoidCallback onDropped) async {
    await refreshInfo(sid);
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      isScrollControlled: true,
      builder: (_) => _CargoPanel(controller: this, sid: sid, pos: pos, onDropped: onDropped),
    );
  }
}

/// Real-world crate sizes on the map (metres across), so crates keep their size relative to the
/// ground when zooming instead of covering the map. Containers are twice a cargo box.
const double kCargoBoxMeters = 40;
const double kCargoContainerMeters = 80;
const double kCargoStackMeters = 100;
const double _kMinCratePx = 6;

double cargoMeters(Map<String, dynamic> c) {
  if (c['stacked'] == true) return kCargoStackMeters;
  return cargoMarkerAsset(c).contains('cargobox') ? kCargoBoxMeters : kCargoContainerMeters;
}

double metersPerPixel(double lat, double zoom) => 156543.03392 * cos(lat * pi / 180) / pow(2, zoom);

/// Decoded marker images, shared by every crate (decoded once per asset).
class _CrateImages {
  static final Map<String, ui.Image> _ready = {};
  static final Set<String> _pending = {};

  static ui.Image? get(String path, VoidCallback onLoaded) {
    final img = _ready[path];
    if (img != null || _pending.contains(path)) return img;
    _pending.add(path);
    rootBundle.load(path).then((data) async {
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      _ready[path] = (await codec.getNextFrame()).image;
      onLoaded();
    }).catchError((_) {});
    return null;
  }
}

/// The two map layers: collection ring (optional) and crate markers. Crates are painted in one
/// pass (no widget per crate), which keeps zooming smooth with many crates; taps are resolved by
/// [CargoController.hitTest] from the map's tap handler.
class CargoLayers extends StatelessWidget {
  final CargoController controller;
  final LatLng? pos;
  const CargoLayers({super.key, required this.controller, required this.pos});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (ctx, __) => Stack(children: [
        if (kShowMuseumRing && pos != null)
          CircleLayer(circles: [
            CircleMarker(
              point: pos!,
              radius: controller.collectRange,
              useRadiusInMeter: true,
              color: Colors.amber.withValues(alpha: 0.06),
              borderColor: Colors.amberAccent.withValues(alpha: 0.8),
              borderStrokeWidth: 1.5,
            ),
          ]),
        if (controller.crates.isNotEmpty)
          MobileLayerTransformer(
            child: CustomPaint(
              size: Size.infinite,
              painter: _CratePainter(MapCamera.of(ctx), controller.crates, controller.repaint),
            ),
          ),
      ]),
    );
  }
}

class _CratePainter extends CustomPainter {
  final MapCamera camera;
  final List<Map<String, dynamic>> crates;
  final VoidCallback onImage;
  _CratePainter(this.camera, this.crates, this.onImage);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..filterQuality = FilterQuality.low;
    final mpp = metersPerPixel(camera.center.latitude, camera.zoom);
    for (final c in crates) {
      final img = _CrateImages.get(cargoMarkerAsset(c), onImage);
      final o = camera.getOffsetFromOrigin(LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble()));
      final px = max(_kMinCratePx, cargoMeters(c) / mpp);
      final dst = Rect.fromCenter(center: o, width: px, height: px);
      if (dst.right < 0 || dst.bottom < 0 || dst.left > size.width || dst.top > size.height) continue;
      if (img == null) {
        canvas.drawRect(dst, Paint()..color = const Color(0xCC6D4C2F));
      } else {
        canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), dst, paint);
      }
      // stacks: how many crates they hold, right above the stack
      if (c['stacked'] == true) {
        final tp = TextPainter(
          text: TextSpan(text: fmtNum((c['count'] as num? ?? 100).toInt()), style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold,
              shadows: [Shadow(color: Colors.black, blurRadius: 3)])),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(dst.center.dx - tp.width / 2, dst.top - tp.height - 1));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CratePainter old) => true;
}

/// Left-side map control with the Cargo Rain stock.
class CargoButton extends StatelessWidget {
  final CargoController controller;
  final VoidCallback onPressed;
  const CargoButton({super.key, required this.controller, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (_, __) => Material(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 46, height: 46,
            child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
              Image.asset('assets/mapmarkers/boxrainicon.png', width: 30, height: 30,
                  errorBuilder: (_, __, ___) => const Icon(Icons.inventory_2_outlined, color: Colors.amberAccent)),
              if (controller.stock > 0)
                Positioned(
                  right: -2, top: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(color: Colors.deepOrange, borderRadius: BorderRadius.circular(8)),
                    child: Text(controller.stock > 999 ? '999+' : '${controller.stock}',
                        style: const TextStyle(fontSize: 9, color: Colors.white)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Left-side truck control (Haulage Firm ≥ 5): collect all cargo nearby.
class TruckButton extends StatelessWidget {
  final CargoController controller;
  final VoidCallback onPressed;
  const TruckButton({super.key, required this.controller, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (_, __) => controller.haulageLevel < 5
          ? const SizedBox.shrink()
          : Material(
              color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onPressed,
                child: SizedBox(
                  width: 46, height: 46,
                  child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
                    Image.asset('assets/mapmarkers/rangelooticon124.png', width: 32, height: 32,
                        errorBuilder: (_, __, ___) => const Icon(Icons.local_shipping_outlined, color: Colors.amberAccent)),
                    Positioned(
                      right: -2, top: -2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(color: Colors.blueGrey, borderRadius: BorderRadius.circular(8)),
                        child: Text('${controller.trucks}', style: const TextStyle(fontSize: 9, color: Colors.white)),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
    );
  }
}

class _CargoPanel extends StatefulWidget {
  final CargoController controller;
  final String sid;
  final LatLng? pos;
  final VoidCallback onDropped;
  const _CargoPanel({required this.controller, required this.sid, required this.pos, required this.onDropped});
  @override
  State<_CargoPanel> createState() => _CargoPanelState();
}

class _CargoPanelState extends State<_CargoPanel> {
  double _count = 10;
  bool _stacked = false;
  int _stacks = 1;
  bool _busy = false;

  Future<void> _drop() async {
    final pos = widget.pos;
    if (pos == null) {
      AppNotify.show(context, 'Waiting for GPS…', isError: true);
      return;
    }
    setState(() => _busy = true);
    final rid = '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(1 << 30)}';
    final r = await GameApi.call('/api/v1/cargo/drop', widget.sid, {
      if (_stacked) ...{'stacked': 1, 'stacks': _stacks, 'count': _count.round()} else 'count': _count.round(),
      'lat': pos.latitude, 'lng': pos.longitude, 'rid': rid,
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) {
      AppNotify.show(context, _stacked
          ? 'Dropped ${fmtNum(_count.round())} crates in $_stacks stack${_stacks == 1 ? '' : 's'}'
          : 'Cargo Rain! ${_count.round()} crates dropped');
      await widget.controller.refreshInfo(widget.sid);
      widget.onDropped();
      if (mounted) Navigator.pop(context);
    } else {
      AppNotify.show(context, r.message ?? 'Failed', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final stock = c.stock;
    final stackUnlocked = c.info['stackUnlocked'] == true;
    final stackSize = (c.info['stackSize'] as num? ?? 100).toInt();
    final maxNormal = min(100, stock);
    final maxStackCrates = (stock ~/ stackSize) * stackSize;          // steps of 100, as many as you have
    final maxVal = (_stacked ? maxStackCrates : maxNormal).toDouble();
    final minVal = _stacked ? stackSize.toDouble() : 1.0;
    if (_count > maxVal) _count = max(minVal, maxVal);
    if (_count < minVal) _count = minVal;
    final maxStacksNow = max(1, min((c.info['maxStacks'] as num? ?? 5).toInt(), _count.round() ~/ stackSize));
    if (_stacks > maxStacksNow) _stacks = maxStacksNow;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Image.asset('assets/mapmarkers/boxrainicon.png', width: 28, height: 28,
                errorBuilder: (_, __, ___) => const Icon(Icons.inventory_2_outlined, color: Colors.amberAccent)),
            const SizedBox(width: 8),
            Text('Cargo Rain: $stock crates', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 4),
          Text('Collection range ${c.collectRange.round()} m (Museum level ${c.info['museum'] ?? 0})',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const Text('The pick-up ring can be shown in Settings › Scan Rings.',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
          const Divider(),
          if (stackUnlocked)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Crates')),
                ButtonSegment(value: true, label: Text('Stacked')),
              ],
              selected: {_stacked},
              onSelectionChanged: (s) => setState(() { _stacked = s.first; _count = s.first ? 100 : 1; _stacks = 1; }),
            )
          else
            Text('Stacked Cargo Rain unlocks at Haulage Firm level ${c.info['stackHaulageLevel'] ?? 5}.',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          if (maxVal >= minVal) ...[
            Slider(
              value: _count.clamp(minVal, maxVal),
              min: minVal, max: maxVal,
              divisions: _stacked ? max(1, ((maxVal - minVal) / stackSize).round())
                                  : (maxVal > 1 ? maxVal.round() - 1 : null),
              label: fmtNum(_count.round()),
              onChanged: maxVal > minVal ? (v) => setState(() =>
                  _count = _stacked ? (v / stackSize).round() * stackSize.toDouble() : v) : null,
            ),
            if (_stacked)
              Row(children: [
                const Text('Split into', style: TextStyle(color: Colors.white70)),
                const SizedBox(width: 8),
                for (var n = 1; n <= 5; n++)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ChoiceChip(
                      label: Text('$n'),
                      selected: _stacks == n,
                      onSelected: n <= maxStacksNow ? (_) => setState(() => _stacks = n) : null,
                    ),
                  ),
                const Text('stacks', style: TextStyle(color: Colors.white70)),
              ]),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.water_drop_outlined),
                label: Text(_stacked
                    ? 'Drop ${fmtNum(_count.round())} crates in $_stacks stack${_stacks == 1 ? '' : 's'}'
                    : 'Drop ${_count.round()} crate${_count.round() == 1 ? '' : 's'} here'),
                onPressed: _busy ? null : _drop,
              ),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No Cargo Rain to drop. Earn crates from daily quests and level-ups.',
                  style: TextStyle(color: Colors.white54)),
            ),
        ]),
      ),
    );
  }
}
