import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../branding.dart';
import '../constants.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';
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
  String _cat = '';
  bool _loading = true, _more = false, _loadingMore = false;
  int? _next;
  String? _error;

  String get _sid => context.read<PlayerProvider>().sid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool append = false}) async {
    if (append) setState(() => _loadingMore = true);
    final r = await GameApi.call('/api/v1/news', _sid, {
      'category': _cat,
      if (append && _next != null) 'before': _next,
    });
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadingMore = false;
      _error = r.ok ? null : r.message;
      if (r.ok) {
        if (!append) _items.clear();
        _items.addAll((r.data['items'] as List).cast<Map<String, dynamic>>());
        _more = r.data['more'] == true;
        _next = (r.data['next'] as num?)?.toInt();
      }
    });
  }

  String _ago(String iso) {
    final d = DateTime.now().toUtc().difference(DateTime.parse(iso.endsWith('Z') ? iso : '${iso}Z'));
    if (d.inDays > 0) return '${d.inDays} d ago';
    if (d.inHours > 0) return '${d.inHours} h ago';
    return '${d.inMinutes} min ago';
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SizedBox(
        height: 48,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          for (final e in _labels.entries)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
              child: ChoiceChip(
                label: Text(e.value),
                selected: _cat == e.key,
                onSelected: (_) { setState(() { _cat = e.key; _loading = true; }); _load(); },
              ),
            ),
        ]),
      ),
      Expanded(
        child: AsyncView(
          loading: _loading,
          error: _error,
          onRetry: _load,
          builder: () => RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(8), children: [
              if (_items.isEmpty)
                const Padding(padding: EdgeInsets.all(24),
                    child: Text('No news yet. Big wins, discoveries and earthquakes appear here.', textAlign: TextAlign.center)),
              for (final n in _items) _tile(n),
              if (_more)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: OutlinedButton(
                    onPressed: _loadingMore ? null : () => _load(append: true),
                    child: Text(_loadingMore ? 'Loading…' : 'Older news'),
                  ),
                ),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _tile(Map<String, dynamic> n) {
    final d = (n['data'] as Map?)?.cast<String, dynamic>() ?? {};
    final players = (n['players'] as List).cast<Map<String, dynamic>>();
    final item = (d['itemID'] as num?)?.toInt();
    final quake = n['kind'] == 'earthquake';
    return Card(
      child: InkWell(
        onTap: quake
            ? () => _showQuake(n)
            : players.isNotEmpty && players.first['pid'] != null
                ? () => ProfileScreen.open(context, players.first['pid'] as String)
                : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            item != null
                ? ItemIcon(item, size: 36)
                : Icon(_icons[n['category']] ?? Icons.newspaper, size: 32,
                    color: quake ? Colors.orangeAccent : AppColors.t70),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n['title'] as String, style: const TextStyle(fontWeight: FontWeight.bold)),
                if ((n['body'] as String).isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text(n['body'] as String,
                      style: TextStyle(color: AppColors.t70, fontSize: 13))),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${_ago(n['ts'] as String)}${item != null && kItemNames[item] != null ? ' · ${kItemNames[item]}' : ''}',
                      style: TextStyle(color: AppColors.t38, fontSize: 11)),
                ),
              ]),
            ),
          ]),
        ),
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
