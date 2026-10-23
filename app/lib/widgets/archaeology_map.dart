import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../models/player_provider.dart';
import 'package:provider/provider.dart';
import 'package:latlong2/latlong.dart' hide Path;
import '../services/game_api.dart';
import 'async_view.dart';
import 'top_banner.dart';
import '../screens/settings_screen.dart' show kShowRevealRing;

import '../app_colors.dart';
import 'popups.dart';
/// Artifact detector on the map. Every scan uses up one Artifact Detector (server rule): the
/// result (a yellow triangle towards the nearest artifact, or the artifact itself once within the
/// reveal range) stays on the map for [resultTtl] or until the next scan.
class ArchaeologyController extends ChangeNotifier {
  static const resultTtl = Duration(minutes: 10);
  bool showRing = false;
  bool scanning = false;
  double? bearing;
  String? band;
  double revealRange = 0;
  int? detectorsLeft;
  Map<String, dynamic>? revealed;
  DateTime? _scannedAt;
  Timer? _expiry;
  String Function()? _sid;
  LatLng? Function()? _pos;

  /// A scan result is showing on the map.
  bool get active => _scannedAt != null;

  void attach(String Function() sid, LatLng? Function() pos) {
    _sid = sid;
    _pos = pos;
  }

  /// Kept for the map's GPS hook; scans are only made on purpose now (they cost a detector).
  void onMoved() {}

  Future<void> scan(BuildContext context) async {
    final sid = _sid?.call(), pos = _pos?.call();
    if (sid == null || scanning) return;
    if (pos == null) {
      AppNotify.show(context, 'Waiting for GPS…', isError: true);
      return;
    }
    scanning = true;
    notifyListeners();
    final r = await GameApi.call('/api/v1/archaeology/detect', sid, {'lat': pos.latitude, 'lng': pos.longitude});
    scanning = false;
    if (!r.ok) {
      notifyListeners();
      if (context.mounted) AppNotify.show(context, r.message ?? 'Scan failed', isError: true);
      return;
    }
    detectorsLeft = (r.data['detectorsLeft'] as num?)?.toInt();
    revealRange = (r.data['revealRange'] as num? ?? revealRange).toDouble();
    if (r.data['found'] == true) {
      bearing = (r.data['bearing'] as num).toDouble();
      band = r.data['band'] as String?;
      revealed = r.data['revealed'] as Map<String, dynamic>?;
    } else {
      bearing = null;
      band = null;
      revealed = null;
    }
    _scannedAt = DateTime.now();
    _expiry?.cancel();
    _expiry = Timer(resultTtl, clear);
    notifyListeners();
    if (context.mounted) {
      AppNotify.show(context, r.data['found'] == true
          ? (revealed != null ? 'Artifact found: ${revealed!['name']} (${revealed!['distance']} m)'
                              : 'Artifact signal ${band ?? ''} — follow the yellow triangle')
          : 'No artifact signal in range'
          '${detectorsLeft != null ? ' · $detectorsLeft detectors left' : ''}');
    }
  }

  void clear() {
    _expiry?.cancel();
    _scannedAt = null;
    bearing = null;
    band = null;
    revealed = null;
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
      clear();
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
    _expiry?.cancel();
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
          if (kShowRevealRing && c.revealRange > 0)
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
                // real-world size (60 m across), never smaller than a tappable 36 px
                width: _artifactPx(ctx), height: _artifactPx(ctx),
                child: GestureDetector(
                  onTap: () => _confirmRecover(ctx),
                  child: Container(
                    decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black54,
                        border: Border.all(color: Colors.yellowAccent, width: 3)),
                    padding: const EdgeInsets.all(8),
                    child: Image.asset('assets/mapmarkers/artifact.png',
                        errorBuilder: (_, __, ___) => const Icon(Icons.diamond, color: Colors.yellowAccent)),
                  ),
                ),
              ),
          ]),
        ]);
      },
    );
  }

  static double _artifactPx(BuildContext ctx) {
    final cam = MapCamera.of(ctx);
    final mpp = 156543.03392 * cos(cam.center.latitude * pi / 180) / pow(2, cam.zoom);
    return max(36.0, 60 / mpp);
  }

  Future<void> _confirmRecover(BuildContext context) async {
    final site = controller.revealed!;
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dlg) => AlertDialog(
        title: Text('Recover ${site['name']}?'),
        content: Text('${site['distance']} m away. Recovering uses archaeologists; '
            'you must be within your Museum pick-up range.'),
        actions: [
          TextButton(onPressed: () => popIfCurrent(dlg, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => popIfCurrent(dlg, true), child: const Text('Recover')),
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

  /// Detectors you have: from your warehouse, or the server's count right after a scan.
  int _count(BuildContext context) {
    final inv = (context.watch<PlayerProvider>().player?.lager['166'] ?? 0).toInt();
    return controller.detectorsLeft ?? inv;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (_, __) => Material(
        // plain button like Cargo Rain; the scan result shows on the map, not on the button
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: controller.scanning ? null : () => controller.scan(context),
          child: SizedBox(
            width: 46, height: 46,
            child: Tooltip(
              message: 'Scan for artifacts (uses 1 Artifact Detector)',
              child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
                // steady icon (no spinner / flashing while a scan runs)
                Image.asset('assets/mapmarkers/artifactscanicon.png', width: 30, height: 30, gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => const Icon(Icons.track_changes, color: Colors.yellowAccent)),
                if (_count(context) > 0)
                  Positioned(
                    right: -2, top: -2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: Colors.amber.shade800, borderRadius: BorderRadius.circular(8)),
                      child: Text('${_count(context)}', style: const TextStyle(fontSize: 9, color: Colors.white)),
                    ),
                  ),
              ]),
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

  /// Artifact sheet in the style of the tech-upgrade sheet: level bars, a slider for how many to
  /// invest (with a preview on the bars) and the effect of every level.
  Future<void> _openArtifact(Map<String, dynamic> a) async {
    final levelAt = ((_d?['levelAt'] as List?) ?? const [100, 500, 1000]).cast<num>().map((e) => e.toInt()).toList();
    final qty = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ArtifactInvestSheet(artifact: a, levelAt: levelAt),
    );
    if (qty == null || qty <= 0 || !mounted) return;
    final r = await GameApi.call('/api/v1/archaeology/invest', widget.sid(), {'itemID': a['itemID'], 'qty': qty});
    if (!mounted) return;
    AppNotify.show(context, r.ok ? '${a['name']}: invested $qty · level ${r.data['level']}' : (r.message ?? 'Failed'),
        isError: !r.ok);
    _load();
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
            Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
                child: Text('Scan with the detector button on the left of the map — each scan uses one '
                    'Artifact Detector. Follow the triangle and scan again when closer; the artifact appears '
                    'within your reveal range. Several players can recover the same artifact; it disappears '
                    '15 minutes after the first recovery.',
                    style: TextStyle(color: AppColors.t54, fontSize: 12))),
            const Divider(),
            Text('Collection', style: TextStyle(color: AppColors.t54, fontSize: 12)),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 3,
              children: [
                for (final a in coll)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _openArtifact(a),
                    child: Opacity(
                      opacity: (a['found'] as num) > 0 || (a['invested'] as num? ?? 0) > 0 ? 1 : 0.35,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Image.asset('assets/images/imgArtifact${a['itemID']}.png', height: 56,
                            errorBuilder: (_, __, ___) => const Icon(Icons.diamond, size: 40)),
                        Text(a['name'] as String, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
                        Text('level ${a['level'] ?? 0} · have ${a['owned'] ?? 0}',
                            style: TextStyle(fontSize: 10, color: AppColors.t54)),
                      ]),
                    ),
                  ),
              ],
            ),
          ]),
        );
      },
    );
  }
}


const _kBronze = Color(0xFFCD7F32);

class _ArtifactInvestSheet extends StatefulWidget {
  final Map<String, dynamic> artifact;
  final List<int> levelAt;
  const _ArtifactInvestSheet({required this.artifact, required this.levelAt});
  @override
  State<_ArtifactInvestSheet> createState() => _ArtifactInvestSheetState();
}

class _ArtifactInvestSheetState extends State<_ArtifactInvestSheet> {
  int _add = 0;

  int get _owned => (widget.artifact['owned'] as num? ?? 0).toInt();
  int get _invested => (widget.artifact['invested'] as num? ?? 0).toInt();
  int get _maxUseful => max(0, min(_owned, widget.levelAt.last - _invested));

  @override
  void initState() {
    super.initState();
    // preselect what is needed for the next level (or all you have)
    final next = widget.levelAt.firstWhere((t) => t > _invested, orElse: () => widget.levelAt.last);
    _add = min(_maxUseful, max(0, next - _invested));
  }

  int _levelFor(int n) => widget.levelAt.where((t) => n >= t).length;

  @override
  Widget build(BuildContext context) {
    final a = widget.artifact;
    final effects = ((a['effects'] as List?) ?? const []).cast<String>();
    final lvl = _levelFor(_invested), newLvl = _levelFor(_invested + _add);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Image.asset('assets/images/imgArtifact${a['itemID']}.png', height: 52,
                errorBuilder: (_, __, ___) => const Icon(Icons.diamond, size: 40, color: _kBronze)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a['name'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              Text('Level $lvl · invested $_invested · you have $_owned',
                  style: TextStyle(color: AppColors.t60, fontSize: 12)),
            ])),
          ]),
          const SizedBox(height: 14),
          for (var i = 0; i < widget.levelAt.length; i++) _levelRow(i, effects.length > i ? effects[i] : ''),
          const SizedBox(height: 10),
          if (_maxUseful > 0) ...[
            Row(children: [
              Text('Invest', style: TextStyle(color: AppColors.t70)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(activeTrackColor: _kBronze, thumbColor: Colors.amberAccent,
                      inactiveTrackColor: Colors.white12),
                  child: Slider(value: _add.toDouble(), min: 0, max: _maxUseful.toDouble(),
                      onChanged: (v) => setState(() => _add = v.round())),
                ),
              ),
              SizedBox(width: 52, child: Text('$_add', textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amberAccent))),
            ]),
            Row(children: [
              for (final n in const [100, 500, 1000])
                Expanded(child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: _kBronze,
                        side: BorderSide(color: _kBronze.withValues(alpha: 0.6))),
                    onPressed: () => setState(() => _add = min(_maxUseful, n)),
                    child: FittedBox(child: Text('$n')),
                  ),
                )),
            ]),
          ] else
            Text(_invested >= widget.levelAt.last ? 'Maximum level reached.' : 'Recover more of these artifacts to invest.',
                style: TextStyle(color: AppColors.t54)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kBronze, foregroundColor: Colors.black),
              onPressed: _add <= 0 ? null : () => popIfCurrent(context, _add),
              child: Text(_add <= 0 ? 'Invest' : newLvl > lvl
                  ? 'Invest $_add → level $newLvl' : 'Invest $_add'),
            ),
          ),
          const SizedBox(height: 4),
          Text('Invested artifacts are used up and raise the level permanently.',
              style: TextStyle(color: AppColors.t38, fontSize: 11)),
        ]),
      ),
    );
  }

  /// One level: progress bar (solid = invested, lighter = what this investment adds) and its effect.
  Widget _levelRow(int i, String effect) {
    final lo = i == 0 ? 0 : widget.levelAt[i - 1], hi = widget.levelAt[i];
    double frac(int n) => ((n - lo) / (hi - lo)).clamp(0.0, 1.0);
    final cur = frac(_invested), prev = frac(_invested + _add);
    final reached = _invested >= hi, willReach = !reached && _invested + _add >= hi;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(width: 30, child: Text('L${i + 1}', style: TextStyle(
              color: reached ? Colors.amberAccent : willReach ? _kBronze : AppColors.t54,
              fontWeight: reached || willReach ? FontWeight.bold : FontWeight.normal, fontSize: 12))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(height: 8, child: Stack(children: [
                Container(color: Colors.white12),
                FractionallySizedBox(widthFactor: prev, child: Container(color: _kBronze.withValues(alpha: 0.4))),
                FractionallySizedBox(widthFactor: cur, child: Container(color: Colors.amber.shade700)),
              ])),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 64, child: Text('${min(max(_invested + _add - lo, 0), hi - lo)}/${hi - lo}',
              textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppColors.t54))),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 30, top: 2),
          child: Text(effect, style: TextStyle(fontSize: 12,
              color: reached ? Colors.white : willReach ? _kBronze : AppColors.t38)),
        ),
      ]),
    );
  }
}
