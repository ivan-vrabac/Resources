import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../constants.dart';
import '../services/game_api.dart';
import 'async_view.dart';
import 'top_banner.dart';

/// Cargo Rain on the map: crate markers, the Museum collection-range ring and the left-side
/// control (stock, drop). Kept out of map_tab.dart; the map only forwards bounds and taps.
class CargoController extends ChangeNotifier {
  List<Map<String, dynamic>> crates = [];
  Map<String, dynamic> info = const {};
  bool showRing = false;
  bool _loading = false;

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
          const ListTile(title: Text('Stacked cargo (100 crates)'),
              subtitle: Text('Can only be collected by truck (in range) or drone (remote).')),
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
      AppNotify.show(context, 'Found ${fmtQty(r.data['qty'] as num)} ${itemName(r.data['itemID'] as int)}');
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

/// The two map layers: collection ring (optional) and crate markers.
class CargoLayers extends StatelessWidget {
  final CargoController controller;
  final LatLng? pos;
  final void Function(Map<String, dynamic> crate) onTapCrate;
  const CargoLayers({super.key, required this.controller, required this.pos, required this.onTapCrate});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (_, __) => Stack(children: [
        if (controller.showRing && pos != null)
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
        MarkerLayer(markers: [
          for (final c in controller.crates)
            Marker(
              point: LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble()),
              width: c['stacked'] == true ? 34 : 24,
              height: c['stacked'] == true ? 34 : 24,
              child: GestureDetector(
                onTap: () => onTapCrate(c),
                child: Container(
                  decoration: BoxDecoration(
                    color: c['stacked'] == true ? Colors.deepOrange.withValues(alpha: 0.85) : const Color(0xCC6D4C2F),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.amberAccent, width: 1),
                  ),
                  child: Icon(c['stacked'] == true ? Icons.layers : Icons.inventory_2,
                      size: c['stacked'] == true ? 20 : 14, color: Colors.white),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
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
              const Icon(Icons.inventory_2_outlined, color: Colors.amberAccent),
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
      if (_stacked) 'stacks': _count.round() else 'count': _count.round(),
      'lat': pos.latitude, 'lng': pos.longitude, 'rid': rid,
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) {
      AppNotify.show(context, _stacked ? 'Dropped ${_count.round()} cargo stacks' : 'Cargo Rain! ${_count.round()} crates dropped');
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
    final maxStacks = min(10, stock ~/ stackSize);
    final maxVal = (_stacked ? maxStacks : maxNormal).toDouble();
    if (_count > maxVal) _count = max(1, maxVal);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.inventory_2_outlined, color: Colors.amberAccent),
            const SizedBox(width: 8),
            Text('Cargo Rain: $stock crates', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 4),
          Text('Collection range ${c.collectRange.round()} m (Museum level ${c.info['museum'] ?? 0})',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Show collection ring on the map'),
            value: c.showRing,
            onChanged: (_) => setState(c.toggleRing),
          ),
          const Divider(),
          if (stackUnlocked)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Crates')),
                ButtonSegment(value: true, label: Text('Stacks of 100')),
              ],
              selected: {_stacked},
              onSelectionChanged: (s) => setState(() { _stacked = s.first; _count = 1; }),
            )
          else
            Text('Stacked Cargo Rain unlocks at Haulage Firm level ${c.info['stackHaulageLevel'] ?? 5}.',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          if (maxVal >= 1) ...[
            Slider(
              value: _count.clamp(1, maxVal),
              min: 1, max: maxVal < 1 ? 1 : maxVal,
              divisions: maxVal > 1 ? maxVal.round() - 1 : null,
              label: _count.round().toString(),
              onChanged: maxVal > 1 ? (v) => setState(() => _count = v) : null,
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.water_drop_outlined),
                label: Text(_stacked
                    ? 'Drop ${_count.round()} stack${_count.round() == 1 ? '' : 's'} (${_count.round() * stackSize} crates)'
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
