import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../branding.dart';
import '../constants.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import 'profile_screen.dart';

import '../app_colors.dart';
import '../widgets/popups.dart';
/// Server-generated news (real game events), with category filter, paging, earthquake
/// reports with an epicenter map, and the player's anonymity setting.
class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key});
  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  static const _labels = {
    '': 'All', 'world': 'World', 'awards': 'Awards', 'casino': 'Casino', 'auctions': 'Auctions', 'archaeology': 'Archaeology',
    'combat': 'Combat', 'players': 'Players', 'cargo': 'Cargo', 'quests': 'Quests',
  };
  static const _icons = {
    'world': Icons.public, 'awards': Icons.workspace_premium_outlined, 'casino': Icons.casino, 'auctions': Icons.gavel, 'archaeology': Icons.museum_outlined,
    'combat': Icons.gpp_bad_outlined, 'players': Icons.emoji_events_outlined, 'cargo': Icons.inventory_2_outlined,
    'quests': Icons.local_fire_department_outlined,
  };

  final _items = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;

  String get _sid => context.read<PlayerProvider>().sid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// One page: everything from the last 24 hours (owner 2026-10-24: no filters, no paging).
  Future<void> _load() async {
    final r = await GameApi.call('/api/v1/news', _sid, {'all': 1});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = r.ok ? null : r.message;
      if (r.ok) {
        _items
          ..clear()
          ..addAll((r.data['items'] as List).cast<Map<String, dynamic>>());
      }
    });
  }

  String _ago(String iso) {
    final d = DateTime.now().toUtc().difference(DateTime.parse(iso.endsWith('Z') ? iso : '${iso}Z'));
    if (d.inDays > 0) return '${d.inDays} d ago';
    if (d.inHours > 0) return '${d.inHours} h ago';
    return '${d.inMinutes} min ago';
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  Color _catColor(String? c) => switch (c) {
        'world' => Colors.orangeAccent,
        'awards' => Colors.amber,
        'casino' => Colors.pinkAccent,
        'auctions' => Colors.lightBlueAccent,
        'archaeology' => Colors.yellowAccent,
        'combat' => Colors.redAccent,
        'cargo' => Colors.tealAccent,
        'quests' => Colors.deepOrangeAccent,
        _ => AppColors.accent,
      };

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(children: [
      // masthead: today's paper
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.fg.withValues(alpha: 0.25), width: 2))),
        child: Column(children: [
          Text('${Branding.appTitle.toUpperCase()} NEWS',
              style: const TextStyle(fontFamily: 'serif', fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 2),
          Text('${_days[now.weekday - 1]}, ${now.day} ${_months[now.month - 1]} ${now.year} · the last 24 hours',
              style: TextStyle(fontSize: 11, color: AppColors.t54, letterSpacing: 0.5)),
        ]),
      ),
      Expanded(
        child: AsyncView(
          loading: _loading,
          error: _error,
          onRetry: _load,
          builder: () => RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.fromLTRB(10, 4, 10, 10), children: [
              if (_items.isEmpty)
                Padding(padding: const EdgeInsets.all(32),
                    child: Text('No news in the last 24 hours.\nBig wins, discoveries and earthquakes appear here.',
                        textAlign: TextAlign.center, style: TextStyle(color: AppColors.t54))),
              for (var i = 0; i < _items.length; i++) _tile(_items[i], top: i == 0),
            ]),
          ),
        ),
      ),
    ]);
  }

  /// One story: category kicker, headline, text, time. The newest one is the top story.
  Widget _tile(Map<String, dynamic> n, {bool top = false}) {
    final d = (n['data'] as Map?)?.cast<String, dynamic>() ?? {};
    final players = (n['players'] as List).cast<Map<String, dynamic>>();
    final item = (d['itemID'] as num?)?.toInt();
    final quake = n['kind'] == 'earthquake';
    final cat = n['category'] as String?;
    final color = quake ? Colors.orangeAccent : _catColor(cat);
    final body = n['body'] as String? ?? '';
    final picture = item != null
        ? ItemIcon(item, size: top ? 56 : 40)
        : Icon(_icons[cat] ?? Icons.newspaper, size: top ? 48 : 34, color: color);
    return InkWell(
      onTap: quake
          ? () => _showQuake(n)
          : players.isNotEmpty && players.first['pid'] != null
              ? () => ProfileScreen.open(context, players.first['pid'] as String)
              : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.fg.withValues(alpha: 0.10)))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 3, height: 11, color: color),
            const SizedBox(width: 6),
            Text((top ? 'TOP STORY · ' : '') + (_labels[cat] ?? 'News').toUpperCase(),
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2, color: color)),
            const Spacer(),
            Text(_ago(n['ts'] as String), style: TextStyle(color: AppColors.t38, fontSize: 10)),
          ]),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n['title'] as String,
                    style: TextStyle(fontFamily: 'serif', fontSize: top ? 20 : 15, fontWeight: FontWeight.bold, height: 1.2)),
                if (body.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text(body,
                      style: TextStyle(color: AppColors.t70, fontSize: top ? 14 : 13, height: 1.3))),
                if (quake)
                  Padding(padding: const EdgeInsets.only(top: 4),
                      child: Text('Tap for the map of the area', style: TextStyle(color: color, fontSize: 11))),
              ]),
            ),
            const SizedBox(width: 10),
            picture,
          ]),
        ]),
      ),
    );
  }

  void _showQuake(Map<String, dynamic> n) {
    final d = (n['data'] as Map).cast<String, dynamic>();
    final c = LatLng((n['lat'] as num).toDouble(), (n['lng'] as num).toDouble());
    final r = (d['radius_km'] as num).toDouble() * 1000;
    showAppSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: 260,
            child: FlutterMap(
              // a fixed picture of the area: no zooming or panning
              options: MapOptions(
                initialCenter: c,
                initialZoom: r > 30000 ? 7 : r > 10000 ? 8 : 10,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
              ),
              children: [
                // dark greyscale OSM tiles, same as the Map tab
                ColorFiltered(
                  colorFilter: const ColorFilter.matrix([
                    -0.2126, -0.7152, -0.0722, 0, 255,
                    -0.2126, -0.7152, -0.0722, 0, 255,
                    -0.2126, -0.7152, -0.0722, 0, 255,
                          0,       0,       0, 1,   0,
                  ]),
                  child: TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: Branding.appId, maxNativeZoom: 19),
                ),
                _QuakeWaves(center: c, radius: r),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(n['title'] as String, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Epicenter ${c.latitude.toStringAsFixed(3)}, ${c.longitude.toStringAsFixed(3)} · radius ${d['radius_km']} km'),
              Text('Mines in the area: ${d['affected_mines']} · damaged: ${d['damaged_mines']}'),
              Text('Companies hit: ${d['companies']} · total damage ${d['total_damage']} points · max ${d['max_damage']}'),
              if ((d['below_20'] as num? ?? 0) > 0)
                Text('${d['below_20']} mines fell below 20% condition and need repair to survive.',
                    style: const TextStyle(color: Colors.orangeAccent)),
              const SizedBox(height: 8),
              Text('A Seismology Centre reduces earthquake damage to your mines.',
                  style: TextStyle(color: AppColors.t54, fontSize: 12)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Seismic waves: rings rippling out from the epicenter to the affected radius.
class _QuakeWaves extends StatefulWidget {
  final LatLng center;
  final double radius;
  const _QuakeWaves({required this.center, required this.radius});
  @override
  State<_QuakeWaves> createState() => _QuakeWavesState();
}

class _QuakeWavesState extends State<_QuakeWaves> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      builder: (_, __) {
        const waves = 4;
        return CircleLayer(circles: [
          // the affected area
          CircleMarker(point: widget.center, radius: widget.radius, useRadiusInMeter: true,
              color: Colors.deepOrange.withValues(alpha: 0.10),
              borderColor: Colors.deepOrange.withValues(alpha: 0.8), borderStrokeWidth: 1.5),
          // rings moving outwards, fading as they travel
          for (var i = 0; i < waves; i++)
            (() {
              final t = (_a.value + i / waves) % 1.0;
              return CircleMarker(point: widget.center, radius: widget.radius * t, useRadiusInMeter: true,
                  color: Colors.transparent,
                  borderColor: Colors.orangeAccent.withValues(alpha: (1 - t) * 0.9), borderStrokeWidth: 2);
            })(),
          CircleMarker(point: widget.center, radius: 5, color: Colors.redAccent),
        ]);
      },
    );
  }
}
