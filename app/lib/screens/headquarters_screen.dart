import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import '../branding.dart';
import '../constants.dart';
import '../models/player.dart';
import '../models/player_provider.dart';
import '../widgets/top_banner.dart';
import '../services/api_service.dart';
import '../services/game_api.dart';

const Map<int, Map<int, int>> kHqUpgradeReqs = {
  2:  {2: 750000,  3: 750000,  8: 750000,  20: 750000},
  3:  {7: 1500000, 13: 1500000, 22: 1500000, 24: 1500000},
  4:  {10: 2000000, 12: 2000000, 26: 2000000, 53: 2000000},
  5:  {28: 3000000, 30: 3000000, 36: 3000000, 38: 3000000},
  6:  {32: 4000000, 49: 4000000, 90: 4000000, 92: 4000000},
  7:  {57: 5000000, 59: 5000000, 67: 5000000, 93: 5000000},
  8:  {14: 10000000, 15: 10000000, 51: 10000000, 81: 10000000},
  9:  {35: 25000000, 66: 25000000, 75: 25000000, 79: 25000000},
  10: {30: 50000000, 59: 50000000, 84: 50000000, 87: 50000000},
};

const List<double> kHqBoostRadius = [115, 130, 145, 160, 175, 190, 205, 220, 235, 250];
const List<double> kHqBoostFactor = [1.9, 2.8, 3.7, 4.6, 5.5, 6.4, 7.3, 8.2, 9.1, 10.0];
const List<String> kHqBonusTags = ['10_2', '10_3', '10_4', '10_5', '10_6'];

class HeadquartersScreen extends StatefulWidget {
  /// Shown as a section inside Special Buildings (no scaffold, no scrolling of its own).
  final bool embedded;
  const HeadquartersScreen({super.key, this.embedded = false});
  @override
  State<HeadquartersScreen> createState() => _HeadquartersScreenState();
}

class _HeadquartersScreenState extends State<HeadquartersScreen> {
  bool _placing = false;

  Future<void> _placeHQ() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _snack('Location services disabled');
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _snack('Location permission denied');
      return;
    }
    setState(() => _placing = true);
    late final Position pos;
    try {
      pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
    } catch (_) {
      if (mounted) setState(() => _placing = false);
      _snack('Failed to get location');
      return;
    }
    if (!mounted) return;
    setState(() => _placing = false);

    final hqLevel = context.read<PlayerProvider>().player?.hq?.level ?? 1;
    final selected = await Navigator.push<LatLng?>(
      context,
      MaterialPageRoute(
        builder: (_) => _HQPlaceScreen(
          userPos: LatLng(pos.latitude, pos.longitude),
          hqLevel: hqLevel,
        ),
      ),
    );
    if (selected == null || !mounted) return;

    setState(() => _placing = true);
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.placeHQ(sid, selected.latitude, selected.longitude);
    if (!mounted) return;
    setState(() => _placing = false);
    if (result == null || result['err'] != 0) {
      _snack(result?['msg'] ?? 'Failed to place HQ');
    } else {
      context.read<PlayerProvider>().refresh();
    }
  }

  void _snack(String msg, {bool error = false}) =>
      AppNotify.show(context, msg, isError: error);

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>().player;
    final hq = player?.hq;
    final lager = player?.lager ?? {};

    final children = <Widget>[
        if (hq == null) ...[
          const _SectionHeader('Headquarters'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('No HQ placed yet.',
                    style: TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 8),
                const Text(
                  'Your HQ is your base of operations. Place it within 500m of your location.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: _placing
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.map_outlined),
                    label: const Text('Place HQ on map'),
                    onPressed: _placing ? null : _placeHQ,
                  ),
                ),
              ]),
            ),
          ),
        ] else ...[
          _HQInfoCard(hq: hq),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(children: [
                const Icon(Icons.location_on_outlined, color: Colors.white38, size: 16),
                const SizedBox(width: 6),
                Text(
                  '${hq.lat.toStringAsFixed(4)}, ${hq.lng.toStringAsFixed(4)}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _placing ? null : _placeHQ,
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: _placing
                      ? const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Move HQ', style: TextStyle(fontSize: 12)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          if (hq.level < 10) ...[
            _UpgradeCard(hq: hq, lager: lager),
          ] else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  const Icon(Icons.star, color: Colors.amber, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('HQ at maximum level!',
                      style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold))),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            const _SectionHeader('Bonus Levels'),
            ...kHqBonusTags.asMap().entries.map((e) => _BonusLevelCard(
                index: e.key + 1, tag: e.value,
                unlocked: (hq.subLevel) > e.key, points: hq.luxuryPoints)),
          ],
        ],
    ];
    if (widget.embedded) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    }
    return Scaffold(
      appBar: ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: ListView(padding: const EdgeInsets.all(16), children: children),
    );
  }
}

// ── HQ Info Card ───────────────────────────────────────────────────────────────

class _HQInfoCard extends StatelessWidget {
  final HQ hq;
  const _HQInfoCard({required this.hq});

  @override
  Widget build(BuildContext context) {
    final boostR = kHqBoostRadius[hq.level - 1].toInt();
    final boostF = kHqBoostFactor[hq.level - 1];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          SizedBox(
            width: 64, height: 64,
            child: Image.asset(
              'assets/images/hq_thumb_${hq.level}.png',
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.location_city, size: 48, color: Colors.teal),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Headquarters',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
              IconButton(
                tooltip: 'Information',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.info_outline, color: Colors.white70),
                onPressed: () => showHqInfo(context),
              ),
            ]),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.teal.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('Level ${hq.level}',
                  style: const TextStyle(color: Colors.tealAccent,
                      fontWeight: FontWeight.bold, fontSize: 13)),
            ),
            const SizedBox(height: 6),
            Text('Level ${hq.level} headquarters boost their employees\' efficiency — they would love to work '
                'at the HQ one day — by ${((boostF - 1) * 100).round()}%. Mines within ${boostR} m, where the '
                'building can be seen, are affected.',
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ])),
        ]),
      ),
    );
  }
}

// ── Upgrade Card (shows requirements, opens deposit dialog) ────────────────────

class _UpgradeCard extends StatelessWidget {
  final HQ hq;
  final Map<String, double> lager;
  const _UpgradeCard({required this.hq, required this.lager});

  @override
  Widget build(BuildContext context) {
    final targetLevel = hq.level + 1;
    final reqs = kHqUpgradeReqs[targetLevel] ?? {};

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Upgrade to Level $targetLevel',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 4),
          const Text('Resources needed to upgrade your HQ',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(height: 12),
          ...reqs.entries.map((e) {
            final id = e.key;
            final need = e.value.toDouble();
            final deposited = (hq.deposits[id] ?? 0.0);
            final remaining = max(0.0, need - deposited);
            final done = deposited >= need;
            final imgPath = resImagePath(id);
            final progress = (deposited / need).clamp(0.0, 1.0);

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  SizedBox(width: 20, height: 20,
                    child: imgPath != null
                        ? Image.asset(imgPath, fit: BoxFit.contain)
                        : const Icon(Icons.inventory_2_outlined, size: 16, color: Colors.white38)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(itemName(id),
                      style: const TextStyle(fontSize: 12))),
                  if (done)
                    const Icon(Icons.check_circle, size: 14, color: Colors.greenAccent)
                  else
                    Text(
                      '${fmtNum(remaining)} left',
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                ]),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: Colors.white12,
                    color: done ? Colors.greenAccent : Colors.teal,
                  ),
                ),
                if (deposited > 0 && !done)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('${fmtNum(deposited)} / ${fmtNum(need)} deposited',
                        style: const TextStyle(fontSize: 10, color: Colors.white38)),
                  ),
              ]),
            );
          }),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.move_to_inbox, size: 18),
              label: const Text('Deposit Resources'),
              onPressed: () => _openDepositDialog(context, reqs),
            ),
          ),
        ]),
      ),
    );
  }

  void _openDepositDialog(BuildContext context, Map<int, int> reqs) {
    showDialog(
      context: context,
      builder: (_) => _DepositDialog(hq: hq, lager: lager, reqs: reqs),
    );
  }
}

// ── Deposit Dialog ─────────────────────────────────────────────────────────────

class _DepositDialog extends StatefulWidget {
  final HQ hq;
  final Map<String, double> lager;
  final Map<int, int> reqs;
  const _DepositDialog({required this.hq, required this.lager, required this.reqs});
  @override
  State<_DepositDialog> createState() => _DepositDialogState();
}

class _DepositDialogState extends State<_DepositDialog> {
  late Map<int, double> _amounts;
  bool _depositing = false;

  @override
  void initState() {
    super.initState();
    _amounts = {for (final id in widget.reqs.keys) id: 0.0};
  }

  double _maxAmount(int id) {
    final need = widget.reqs[id]!.toDouble();
    final have = widget.lager[id.toString()] ?? 0.0;
    final deposited = widget.hq.deposits[id] ?? 0.0;
    final remaining = max(0.0, need - deposited);
    return min(have, remaining);
  }

  void _fillAll() {
    setState(() {
      for (final id in widget.reqs.keys) {
        _amounts[id] = _maxAmount(id);
      }
    });
  }

  Future<void> _deposit() async {
    final toDeposit = {
      for (final e in _amounts.entries) if (e.value > 0) e.key: e.value
    };
    if (toDeposit.isEmpty) return;
    setState(() => _depositing = true);
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.depositHQ(sid, toDeposit);
    if (!mounted) return;
    setState(() => _depositing = false);
    if (result == null || result['err'] != 0) {
      AppNotify.show(context, result?['msg'] ?? 'Deposit failed', isError: true);
    } else {
      context.read<PlayerProvider>().refresh();
      Navigator.of(context).pop();
      if (result['upgraded'] == true) {
        AppNotify.show(context, 'HQ upgraded!');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final targetLevel = widget.hq.level + 1;
    final hasAnything = _amounts.values.any((v) => v > 0);

    return AlertDialog(
      title: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Deposit Resources'),
        Text('Toward Level $targetLevel',
            style: const TextStyle(fontSize: 12, color: Colors.white38,
                fontWeight: FontWeight.normal)),
      ]),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
              onPressed: _fillAll,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero),
              child: const Text('Fill all', style: TextStyle(fontSize: 12)),
            ),
          ]),
          ...widget.reqs.entries.map((e) {
            final id = e.key;
            final need = e.value.toDouble();
            final have = widget.lager[id.toString()] ?? 0.0;
            final deposited = widget.hq.deposits[id] ?? 0.0;
            final remaining = max(0.0, need - deposited);
            final maxAmt = _maxAmount(id);
            final imgPath = resImagePath(id);

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  SizedBox(width: 20, height: 20,
                    child: imgPath != null
                        ? Image.asset(imgPath, fit: BoxFit.contain)
                        : const Icon(Icons.inventory_2_outlined, size: 16,
                            color: Colors.white38)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(itemName(id),
                      style: const TextStyle(fontSize: 12))),
                  Text('${fmtNum(_amounts[id] ?? 0)} / ${fmtNum(remaining)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: (_amounts[id] ?? 0) >= remaining
                            ? Colors.greenAccent : Colors.white54,
                      )),
                ]),
                if (deposited > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, top: 1),
                    child: Text('${fmtNum(deposited)} already deposited',
                        style: const TextStyle(fontSize: 10, color: Colors.tealAccent)),
                  ),
                if (have < remaining && deposited < need)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, top: 1),
                    child: Text('You have ${fmtNum(have)} (need ${fmtNum(remaining)} more)',
                        style: const TextStyle(fontSize: 10, color: Colors.redAccent)),
                  ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 3),
                  child: Slider(
                    value: maxAmt <= 0 ? 0 : (_amounts[id] ?? 0).clamp(0, maxAmt),
                    min: 0,
                    max: maxAmt <= 0 ? 1 : maxAmt,
                    onChanged: maxAmt > 0
                        ? (v) => setState(() => _amounts[id] = v)
                        : null,
                    activeColor: (_amounts[id] ?? 0) >= remaining
                        ? Colors.greenAccent : Colors.teal,
                    inactiveColor: Colors.white12,
                  ),
                ),
              ]),
            );
          }),
        ]),
      ),
      actions: [
        Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          )),
          const SizedBox(width: 12),
          Expanded(child: FilledButton(
            onPressed: (hasAnything && !_depositing) ? _deposit : null,
            child: _depositing
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Deposit'),
          )),
        ]),
      ],
    );
  }
}

// ── Bonus Level Card ───────────────────────────────────────────────────────────

class _BonusLevelCard extends StatelessWidget {
  final int index;
  final String tag;
  final bool unlocked;
  final int points;
  const _BonusLevelCard({required this.index, required this.tag, this.unlocked = false, this.points = 0});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          SizedBox(
            width: 48, height: 48,
            child: Opacity(
              opacity: unlocked ? 1 : 0.45,
              child: Image.asset(
                'assets/images/hq_thumb_$tag.png',
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.location_city, size: 36, color: Colors.white24),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('HQ Bonus Level $index',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13,
                    color: unlocked ? Colors.amberAccent : Colors.white54)),
            const SizedBox(height: 2),
            Text(unlocked
                    ? 'Unlocked with luxury points'
                    : 'Needs ${index * 10000} luxury points (you have $points)',
                style: TextStyle(color: unlocked ? Colors.white54 : Colors.white24, fontSize: 11)),
          ])),
          Icon(unlocked ? Icons.lock_open : Icons.lock_outline,
              color: unlocked ? Colors.amberAccent : Colors.white24, size: 20),
        ]),
      ),
    ),
  );
}

// ── Section Header ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text.toUpperCase(),
        style: const TextStyle(fontSize: 11, color: Colors.white38, letterSpacing: 1.2)),
  );
}

// ── HQ Place Screen ────────────────────────────────────────────────────────────

class _HQPlaceScreen extends StatefulWidget {
  final LatLng userPos;
  final int hqLevel;
  const _HQPlaceScreen({required this.userPos, required this.hqLevel});
  @override
  State<_HQPlaceScreen> createState() => _HQPlaceScreenState();
}

class _HQPlaceScreenState extends State<_HQPlaceScreen> {
  LatLng? _selected;
  late LatLng _liveUserPos;
  StreamSubscription<Position>? _posSub;
  final _mapCtrl = MapController();
  double _mapZoom = 16.0;
  double? _heading;

  static const double _stepMeter  = 1.0;
  static const double _placeRange = 200.0;

  // Own mines around the placement area (player data no longer carries every mine).
  List<Mine> _nearMines = [];

  Future<void> _loadNearMines() async {
    final sid = context.read<PlayerProvider>().sid;
    final boostR = kHqBoostRadius[(widget.hqLevel - 1).clamp(0, 9)];
    final list = await ApiService.getMinesNear(sid, widget.userPos.latitude,
        widget.userPos.longitude, _placeRange + boostR + 300);
    if (mounted && list != null) setState(() => _nearMines = list);
  }

  @override
  void initState() {
    super.initState();
    _liveUserPos = widget.userPos;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadNearMines());
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).listen((pos) {
      if (!mounted) return;
      final ll = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _liveUserPos = ll;
        if (pos.heading >= 0) _heading = pos.heading;
      });
      _mapCtrl.move(ll, _mapCtrl.camera.zoom);
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  double get _distance {
    if (_selected == null) return double.infinity;
    const R = 6371000.0;
    final lat1 = _liveUserPos.latitude * pi / 180;
    final lat2 = _selected!.latitude * pi / 180;
    final dLat = (_selected!.latitude - _liveUserPos.latitude) * pi / 180;
    final dLng = (_selected!.longitude - _liveUserPos.longitude) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  bool get _withinRange => _distance <= _placeRange;

  void _nudge(double dLat, double dLng) {
    if (_selected == null) return;
    final newLat = _selected!.latitude + dLat;
    final newLng = _selected!.longitude + dLng;
    setState(() => _selected = LatLng(newLat.clamp(-85.0, 85.0), newLng));
  }

  void _nudgeMeters(double northM, double eastM) {
    if (_selected == null) return;
    const deg = pi / 180;
    final latDeg = northM / 111320.0;
    final lngDeg = eastM / (111320.0 * cos(_selected!.latitude * deg));
    _nudge(latDeg, lngDeg);
  }

  double _distM(LatLng a, LatLng b) {
    const R = 6371000.0;
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return R * 2 * atan2(sqrt(h), sqrt(1 - h));
  }

  void _autoPosition() {
    final mines = _nearMines;
    if (mines.isEmpty) {
      AppNotify.show(context, 'No mines to optimize for');
      return;
    }
    final boostR = kHqBoostRadius[(widget.hqLevel - 1).clamp(0, 9)];
    final maxRange = _placeRange;
    const step = 8.0;
    final cosLat = cos(_liveUserPos.latitude * pi / 180);
    final stepsR = (maxRange / step).ceil();

    LatLng? best;
    double bestScore = -1;

    for (var dy = -stepsR; dy <= stepsR; dy++) {
      for (var dx = -stepsR; dx <= stepsR; dx++) {
        final northM = dy * step;
        final eastM  = dx * step;
        if (northM * northM + eastM * eastM > maxRange * maxRange) continue;
        final candidate = LatLng(
          _liveUserPos.latitude  + northM / 111320.0,
          _liveUserPos.longitude + eastM  / (111320.0 * cosLat),
        );
        double score = 0;
        for (final m in mines) {
          if (_distM(candidate, LatLng(m.lat, m.lng)) <= boostR) {
            score += m.quality.toDouble();
          }
        }
        if (score > bestScore) { bestScore = score; best = candidate; }
      }
    }

    final target = (best != null && bestScore > 0) ? best! : _liveUserPos;
    setState(() => _selected = target);
  }

  @override
  Widget build(BuildContext context) {
    final boostR  = kHqBoostRadius[(widget.hqLevel - 1).clamp(0, 9)];
    final mines   = _nearMines;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 36,
        title: const Text('Place HQ', style: TextStyle(fontSize: 14)),
      ),
      body: Stack(children: [
        FlutterMap(
          mapController: _mapCtrl,
          options: MapOptions(
            initialCenter: widget.userPos,
            initialZoom: 16,
            backgroundColor: Colors.black,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.none,
            ),
            onPositionChanged: (camera, _) =>
                setState(() => _mapZoom = camera.zoom),
            onTap: (_, latLng) {
              setState(() => _selected = latLng);
            },
          ),
          children: [
            ColorFiltered(
              colorFilter: const ColorFilter.matrix([
                -0.2126, -0.7152, -0.0722, 0, 255,
                -0.2126, -0.7152, -0.0722, 0, 255,
                -0.2126, -0.7152, -0.0722, 0, 255,
                0, 0, 0, 1, 0,
              ]),
              child: TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: Branding.appId,
                maxNativeZoom: 19,
              ),
            ),
            // Map data attribution (required by the OSM tile usage policy)
            const Align(
              alignment: Alignment.bottomRight,
              child: IgnorePointer(
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Text('© OpenStreetMap contributors',
                      style: TextStyle(color: Colors.white54, fontSize: 9)),
                ),
              ),
            ),
            // Mine markers — geo-scaled hex like the main map
            (() {
              final refLat = _liveUserPos.latitude * pi / 180;
              final ppm    = (256 * pow(2, _mapZoom)) /
                  (40075017.0 * cos(refLat).abs().clamp(0.001, 1.0));
              final totalPx = (2 * 15.0 * ppm).clamp(4.0, 200.0);
              if (_mapZoom < 14.5) {
                return MarkerLayer(markers: mines.map((m) => Marker(
                  point: LatLng(m.lat, m.lng), width: 8, height: 8,
                  child: Container(decoration: BoxDecoration(
                    color: Colors.greenAccent.withValues(alpha: 0.85),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1),
                  )),
                )).toList());
              }
              return MarkerLayer(markers: mines.map((m) {
                final cond    = m.condition;
                final imgPath = resImagePath(m.resId);
                Color ringColor = cond < 50
                    ? const Color(0xFF8B5A2B)
                    : Colors.greenAccent;
                final markerH = totalPx * 0.866;
                const barH    = 4.0;
                final showBar = cond <= 90;
                return Marker(
                  point: LatLng(m.lat, m.lng),
                  width: totalPx,
                  height: markerH + (showBar ? barH : 0),
                  alignment: Alignment.center,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(width: totalPx, height: markerH,
                      child: CustomPaint(
                        painter: _HexFramePainter(ringColor: ringColor),
                        child: Center(child: SizedBox(
                          width: totalPx * 0.76, height: markerH * 0.76,
                          child: ClipPath(
                            clipper: const _HexClipper(),
                            child: imgPath != null
                                ? Image.asset(imgPath, fit: BoxFit.cover)
                                : Container(color: const Color(0xFF101418),
                                    child: Center(child: Icon(Icons.terrain,
                                      color: _kHqMineColor[m.itemId] ?? Colors.grey,
                                      size: (totalPx * 0.35).clamp(6.0, 18.0)))),
                          ),
                        )),
                      ),
                    ),
                    if (showBar)
                      SizedBox(width: totalPx, height: barH,
                        child: ClipRRect(borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: cond / 100.0,
                            backgroundColor: Colors.black54,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              cond < 50 ? Colors.redAccent
                                  : cond < 80 ? Colors.amber
                                  : Colors.greenAccent),
                          ))),
                  ]),
                );
              }).toList());
            })(),
            (() {
              final refLat = _liveUserPos.latitude * pi / 180;
              final ppm    = (256 * pow(2, _mapZoom)) /
                  (40075017.0 * cos(refLat).abs().clamp(0.001, 1.0));
              final rangeDiam = _placeRange * 2 * ppm;
              final markers = <Marker>[
                Marker(
                  point: _liveUserPos,
                  width: rangeDiam, height: rangeDiam,
                  alignment: Alignment.center,
                  child: CustomPaint(painter: _RangeCirclePainter(
                    color: Colors.orange, fillOpacity: 0.06, strokeWidth: 1.5)),
                ),
                if (_selected != null)
                  Marker(
                    point: _selected!,
                    width: boostR * 2 * ppm, height: boostR * 2 * ppm,
                    alignment: Alignment.center,
                    child: CustomPaint(painter: _RangeCirclePainter(
                      color: Colors.teal, fillOpacity: 0.08, strokeWidth: 1.0)),
                  ),
              ];
              return MarkerLayer(markers: markers);
            })(),
            MarkerLayer(markers: [
              Marker(
                point: _liveUserPos,
                width: 44, height: 44,
                child: CustomPaint(painter: _PosCrosshairPainter(headingDeg: _heading)),
              ),
              if (_selected != null)
                Marker(
                  point: _selected!,
                  width: 40, height: 40,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) {
                      final latRad = _selected!.latitude * pi / 180;
                      final zoom = _mapCtrl.camera.zoom;
                      final ppm = (256 * pow(2, zoom)) /
                          (40075017.0 * cos(latRad).abs().clamp(0.001, 1.0));
                      final dlat = -d.delta.dy / (111320.0 * ppm);
                      final dlng =  d.delta.dx / (111320.0 * cos(latRad) * ppm);
                      setState(() => _selected = LatLng(
                        (_selected!.latitude  + dlat).clamp(-85.0, 85.0),
                        _selected!.longitude + dlng,
                      ));
                    },
                    child: Stack(alignment: Alignment.center, children: [
                      Image.asset(
                        'assets/images/hq_thumb_${widget.hqLevel}.png',
                        width: 38, height: 38,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.location_city,
                          color: _withinRange ? Colors.amber : Colors.red,
                          size: 36,
                        ),
                      ),
                      if (!_withinRange)
                        Positioned(
                          bottom: 0, right: 0,
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Colors.red, shape: BoxShape.circle),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(Icons.close, size: 10, color: Colors.white),
                          ),
                        ),
                    ]),
                  ),
                ),
            ]),
          ],
        ),

        // D-pad precision arrows (bottom-right, above action bar)
        if (_selected != null)
          Positioned(
            bottom: 160, right: 12,
            child: _DPad(onNudge: _nudgeMeters),
          ),

        if (_selected == null)
          const Positioned(
            top: 12, left: 0, right: 0,
            child: Center(
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.all(Radius.circular(8)),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text('Tap map to place HQ',
                      style: TextStyle(fontSize: 12, color: Colors.white70)),
                ),
              ),
            ),
          ),

        // Bottom action bar
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(16, 12, 16,
                MediaQuery.of(context).padding.bottom + 16),
            color: Colors.black87,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_selected != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(
                      _withinRange ? Icons.check_circle_outline : Icons.cancel_outlined,
                      size: 14,
                      color: _withinRange ? Colors.greenAccent : Colors.redAccent,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _withinRange
                          ? '${_distance.toStringAsFixed(0)}m from you — within range'
                          : '${_distance.toStringAsFixed(0)}m — too far (max 200m)',
                      style: TextStyle(
                        fontSize: 12,
                        color: _withinRange ? Colors.greenAccent : Colors.redAccent,
                      ),
                    ),
                  ]),
                ),
              Row(children: [
                Expanded(child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Cancel'),
                )),
                const SizedBox(width: 8),
                (() {
                  final canAuto = mines.any((m) =>
                      _distM(_liveUserPos, LatLng(m.lat, m.lng)) <= 200 + boostR);
                  return OutlinedButton.icon(
                    onPressed: canAuto ? _autoPosition : null,
                    icon: const Icon(Icons.auto_fix_high, size: 14),
                    label: const Text('Auto'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.tealAccent,
                        side: BorderSide(color: canAuto ? Colors.teal : Colors.white24)),
                  );
                })(),
                const SizedBox(width: 8),
                Expanded(child: FilledButton(
                  onPressed: _withinRange ? () => Navigator.pop(context, _selected) : null,
                  child: const Text('Place here'),
                )),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ── Range circle painter ───────────────────────────────────────────────────────

class _RangeCirclePainter extends CustomPainter {
  final Color color;
  final double fillOpacity;
  final double strokeWidth;
  const _RangeCirclePainter({required this.color, required this.fillOpacity, required this.strokeWidth});
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 - strokeWidth / 2;
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: fillOpacity)..style = PaintingStyle.fill);
    canvas.drawCircle(c, r, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = strokeWidth);
  }
  @override
  bool shouldRepaint(_RangeCirclePainter old) =>
      old.color != color || old.fillOpacity != fillOpacity || old.strokeWidth != strokeWidth;
}

// ── Mine hex painters (mirrors map_tab.dart) ──────────────────────────────────

const Map<int, Color> _kHqMineColor = {
  4: Color(0xFFBD9B4C), 5: Color(0xFF9E9E9E), 9: Color(0xFF546E7A),
  11: Color(0xFF1565C0), 16: Color(0xFFE65100), 17: Color(0xFFB71C1C),
  18: Color(0xFFFFD600), 19: Color(0xFFCFD8DC), 21: Color(0xFFECEFF1),
  27: Color(0xFFBF360C), 50: Color(0xFF7B1FA2), 54: Color(0xFFF9A825),
  82: Color(0xFF00BCD4), 89: Color(0xFF00897B), 168: Color(0xFF00695C),
};

class _HexClipper extends CustomClipper<Path> {
  const _HexClipper();
  @override
  Path getClip(Size size) {
    final cx = size.width / 2; final cy = size.height / 2; final r = size.width / 2;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = i * pi / 3;
      final x = cx + r * cos(a); final y = cy - r * sin(a);
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    return path..close();
  }
  @override bool shouldReclip(covariant CustomClipper<Path> _) => false;
}

class _HexFramePainter extends CustomPainter {
  final Color ringColor;
  const _HexFramePainter({required this.ringColor});
  Path _hexPath(double cx, double cy, double r) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = i * pi / 3;
      final x = cx + r * cos(a); final y = cy - r * sin(a);
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    return path..close();
  }
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2; final cy = size.height / 2;
    final outer = size.width / 2; final inner = outer * 0.78;
    canvas.drawPath(_hexPath(cx, cy, outer),
        Paint()..color = ringColor.withValues(alpha: 0.85)..style = PaintingStyle.fill);
    canvas.drawPath(_hexPath(cx, cy, inner),
        Paint()..color = const Color(0xFF0A0A0A)..style = PaintingStyle.fill);
    final sw = (outer * 0.08).clamp(0.3, 1.5);
    canvas.drawPath(_hexPath(cx, cy, outer - sw / 2),
        Paint()..color = const Color(0xFF888888)..style = PaintingStyle.stroke..strokeWidth = sw);
  }
  @override bool shouldRepaint(_HexFramePainter old) => old.ringColor != ringColor;
}

// ── GPS compass painter (reused from map tab) ─────────────────────────────────

class _PosCrosshairPainter extends CustomPainter {
  final double? headingDeg;
  const _PosCrosshairPainter({this.headingDeg});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    const innerR = 12.0;
    const outerR = 18.0;
    final tickPaint = Paint()..color = Colors.yellow..strokeWidth = 1.0..style = PaintingStyle.stroke;
    for (int i = 0; i < 8; i++) {
      final a = i * pi / 4;
      canvas.drawLine(Offset(cx + innerR * cos(a), cy + innerR * sin(a)),
          Offset(cx + outerR * cos(a), cy + outerR * sin(a)), tickPaint);
    }
    final smallPaint = Paint()..color = const Color(0x99FFFF00)..strokeWidth = 0.8..style = PaintingStyle.stroke;
    for (int i = 0; i < 8; i++) {
      final a = (i + 0.5) * pi / 4;
      canvas.drawLine(Offset(cx + 14.0 * cos(a), cy + 14.0 * sin(a)),
          Offset(cx + 17.0 * cos(a), cy + 17.0 * sin(a)), smallPaint);
    }
    if (headingDeg != null) {
      final a = headingDeg! * pi / 180 - pi / 2;
      canvas.drawLine(
          Offset(cx + innerR * cos(a), cy + innerR * sin(a)),
          Offset(cx + (outerR + 3) * cos(a), cy + (outerR + 3) * sin(a)),
          Paint()..color = Colors.white..strokeWidth = 1.5..style = PaintingStyle.stroke);
    }
    canvas.drawCircle(Offset(cx, cy), 1.5,
        Paint()..color = Colors.yellow..style = PaintingStyle.fill);
  }
  @override
  bool shouldRepaint(_PosCrosshairPainter old) => old.headingDeg != headingDeg;
}

// ── D-Pad widget ───────────────────────────────────────────────────────────────

class _DPad extends StatefulWidget {
  final void Function(double northM, double eastM) onNudge;
  const _DPad({required this.onNudge});
  @override
  State<_DPad> createState() => _DPadState();
}

class _DPadState extends State<_DPad> {
  Timer? _timer;

  void _stopNudge() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopNudge();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 140.0;
    const cx   = size / 2;
    const ar   = cx * 0.57;
    const as_  = 26.0;

    return Listener(
      onPointerDown: (event) {
        final dx = event.localPosition.dx - cx;
        final dy = event.localPosition.dy - cx;
        if (dx * dx + dy * dy > cx * cx) return;
        double n = 0, e = 0;
        if (dx.abs() > dy.abs()) {
          if (dx > 0) e = 1; else e = -1;
        } else {
          if (dy > 0) n = -1; else n = 1;
        }
        widget.onNudge(n, e);
        _stopNudge();
        _timer = Timer.periodic(
          const Duration(milliseconds: 500),
          (_) => widget.onNudge(n, e),
        );
      },
      onPointerUp: (_) => _stopNudge(),
      onPointerCancel: (_) => _stopNudge(),
      child: SizedBox(
        width: size, height: size,
        child: Stack(children: [
          const CustomPaint(
            size: Size(size, size),
            painter: _DPadPainter(),
          ),
          Positioned(left: cx - as_/2, top:  cx - ar - as_/2,
              child: const Icon(Icons.keyboard_arrow_up,    color: Colors.white, size: as_)),
          Positioned(left: cx - as_/2, top:  cx + ar - as_/2,
              child: const Icon(Icons.keyboard_arrow_down,  color: Colors.white, size: as_)),
          Positioned(left: cx - ar - as_/2, top: cx - as_/2,
              child: const Icon(Icons.keyboard_arrow_left,  color: Colors.white, size: as_)),
          Positioned(left: cx + ar - as_/2, top: cx - as_/2,
              child: const Icon(Icons.keyboard_arrow_right, color: Colors.white, size: as_)),
        ]),
      ),
    );
  }
}

class _DPadPainter extends CustomPainter {
  const _DPadPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height / 2;
    final r  = size.width  / 2 - 1;
    const gap = 0.07; // radians gap on each side between sectors (~4°)

    final fill   = Paint()
      ..color = const Color(0x33ADD8E6) // lightBlue ~20% opacity (80% transparent)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (int i = 0; i < 4; i++) {
      final startAngle = i * pi / 2 - pi / 4 + gap;
      final sweepAngle = pi / 2 - 2 * gap;
      final path = Path()
        ..moveTo(cx, cy)
        ..arcTo(Rect.fromCircle(center: Offset(cx, cy), radius: r),
            startAngle, sweepAngle, false)
        ..close();
      canvas.drawPath(path, fill);
      canvas.drawPath(path, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}

/// HQ information: boost and range for every level and what each upgrade needs (/api/v1/hq/info).
Future<void> showHqInfo(BuildContext context) async {
  final r = await GameApi.call('/api/v1/hq/info', context.read<PlayerProvider>().sid);
  if (!context.mounted || !r.ok) return;
  final levels = (r.data['levels'] as List).cast<Map<String, dynamic>>();
  final cur = (r.data['level'] as num? ?? 0).toInt();
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A2E),
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (_, scroll) => ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
        const Text('Headquarters', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(r.data['bonusLevels'] as String? ?? '', style: const TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 36,
            dataRowMinHeight: 32,
            dataRowMaxHeight: 56,
            columnSpacing: 18,
            columns: const [
              DataColumn(label: Text('Level')),
              DataColumn(label: Text('Mine boost')),
              DataColumn(label: Text('Boost range')),
              DataColumn(label: Text('Needs')),
            ],
            rows: [
              for (final l in levels)
                DataRow(
                  color: WidgetStatePropertyAll((l['level'] as num).toInt() == cur ? Colors.teal.withValues(alpha: 0.25) : null),
                  cells: [
                    DataCell(Text('${l['level']}')),
                    for (final e in (l['effects'] as List).cast<Map<String, dynamic>>()) DataCell(Text(e['value'] as String)),
                    DataCell(Text((l['res'] as Map).entries
                        .map((e) => '${fmtNum(e.value as num)} ${itemName(int.parse(e.key as String))}').join('\n'),
                        style: const TextStyle(fontSize: 11, color: Colors.white70))),
                  ],
                ),
            ],
          ),
        ),
      ]),
    ),
  );
}

