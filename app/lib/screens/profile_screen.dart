import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart' show itemName, kMineNames, kMineResource;
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';

/// Public profile of a player ([pid]), or your own statistics when [pid] is null.
class ProfileScreen extends StatefulWidget {
  final String? pid;
  final bool embedded; // shown inside a tab (no app bar)
  const ProfileScreen({super.key, this.pid, this.embedded = false});

  static Future<void> open(BuildContext context, String pid) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProfileScreen(pid: pid)));

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? _p;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final r = await GameApi.call('/api/v1/social/profile', context.read<PlayerProvider>().sid,
        {'pid': widget.pid});
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r.ok) {
        _p = r.get<Map<String, dynamic>>('profile');
      } else {
        _error = r.message;
      }
    });
  }

  Future<void> _toggle(String kind, bool on) async {
    if (_busy || _p == null) return;
    setState(() => _busy = true);
    final r = await GameApi.call('/api/v1/social/contact', context.read<PlayerProvider>().sid,
        {'pid': _p!['pid'], 'kind': kind, 'action': on ? 'add' : 'remove'});
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) _p!['relations'] = r.get<List>('relations') ?? [];
    });
    if (!r.ok) AppNotify.show(context, r.message ?? 'Failed', isError: true);
  }

  Widget _stat(String label, String value, {IconData? icon}) => Expanded(
        child: Container(
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8)),
          child: Column(children: [
            if (icon != null) Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
            Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 10, color: Colors.white54), textAlign: TextAlign.center),
          ]),
        ),
      );

  /// A titled wrap of item images with a small label (count or level) under each.
  Widget _itemSection(String title, dynamic list, String key, {String prefix = '', Widget Function(int)? image}) {
    final items = (list as List? ?? const []).cast<Map<String, dynamic>>();
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(spacing: 10, runSpacing: 8, children: [
          for (final it in items)
            Tooltip(
              message: kMineNames[(it['itemID'] as num).toInt()] ?? itemName((it['itemID'] as num).toInt()),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                image != null ? image((it['itemID'] as num).toInt()) : ItemIcon((it['itemID'] as num).toInt(), size: 34),
                Text('$prefix${it[key]}', style: const TextStyle(fontSize: 10, color: Colors.white70)),
              ]),
            ),
        ]),
      ]),
    );
  }

  Widget _relationChip(String kind, String label, IconData icon, Color color) {
    final rel = (_p?['relations'] as List? ?? const []).contains(kind);
    return FilterChip(
      avatar: Icon(icon, size: 16, color: rel ? Colors.black : color),
      label: Text(label),
      selected: rel,
      selectedColor: color,
      onSelected: _busy ? null : (v) => _toggle(kind, v),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      builder: () {
        final p = _p!;
        final isMe = p['isMe'] == true;
        final ach = (p['achievements'] as List? ?? const []).cast<Map<String, dynamic>>();
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              // country flag in place of an avatar (letter avatar only when no country is set)
              (p['country'] as String? ?? '').isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.asset('assets/images_countryflags/${(p['country'] as String).toLowerCase()}.png',
                          width: 52, height: 36, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.flag_outlined, size: 36)),
                    )
                  : CircleAvatar(radius: 26, child: Text((p['name'] as String? ?? '?').characters.first.toUpperCase(),
                      style: const TextStyle(fontSize: 20))),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p['name'] as String? ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Text('Member since ${p['memberSince'] ?? '?'}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ])),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              _stat('Level', '${p['level']}', icon: Icons.military_tech),
              _stat('HQ level', '${p['hqLevel']}', icon: Icons.location_city),
              _stat('Mines', '${p['mines']}', icon: Icons.construction),
            ]),
            Row(children: [
              _stat('Mines ever built', '${p['minesEverBuilt']}'),
              _stat('Production / h', fmtQty(p['productionPerHour'] as num? ?? 0)),
            ]),
            Row(children: [
              _stat('Age', p['ageDays'] == null ? '?' : '${p['ageDays']} days', icon: Icons.cake_outlined),
              _stat('Luxury points', fmtQty(p['luxuryPoints'] as num? ?? 0), icon: Icons.diamond_outlined),
              _stat('Artifacts', '${p['artifacts'] ?? 0}', icon: Icons.museum_outlined),
            ]),
            Row(children: [
              _stat('Rank by XP', '#${p['rankXp']}'),
              _stat('Rank by mines', '#${p['rankMines']}'),
              if (isMe) _stat('Credits', fmtCredits(p['credits'] as num? ?? 0)),
            ]),
            if (p['combat'] is Map)
              Row(children: [
                _stat('Attacks won', '${p['combat']['attacksWon']} / ${p['combat']['attacks']}', icon: Icons.gpp_bad_outlined),
                _stat('Defences won', '${p['combat']['defencesWon']} / ${p['combat']['defences']}', icon: Icons.shield_outlined),
              ]),
            _itemSection('Mines', p['minesByType'], 'count', prefix: '×',
                image: (id) => Image.asset('assets/mapmarkers/map_res${kMineResource[id] ?? id}.png',
                    width: 34, height: 34, errorBuilder: (_, __, ___) => ItemIcon(kMineResource[id] ?? id, size: 34))),
            _itemSection('Factories', p['factories'], 'level', prefix: 'Lv '),
            _itemSection('Special buildings', p['specialBuildings'], 'level', prefix: 'Lv '),
            _itemSection('Luxury items', p['luxuryItems'], 'qty', prefix: '×'),
            if (!isMe) ...[
              const SizedBox(height: 12),
              const Text('Contacts', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                _relationChip('friend', 'Friend', Icons.person_add_alt, Colors.lightBlueAccent),
                _relationChip('enemy', 'Enemy', Icons.gpp_bad_outlined, Colors.orangeAccent),
                _relationChip('watch', 'Watch', Icons.visibility_outlined, Colors.amber),
                _relationChip('blacklist', 'Block', Icons.block, Colors.redAccent),
              ]),
            ],
            const SizedBox(height: 16),
            const Text('Achievements', style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 6),
            if (ach.isEmpty)
              const Text('No achievements yet', style: TextStyle(color: Colors.white38))
            else
              ...ach.map((a) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.emoji_events, color: Colors.amber),
                    title: Text(a['title'] as String? ?? ''),
                    subtitle: Text((a['ts'] as String? ?? '').split('T').first),
                  )),
          ]),
        );
      },
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(toolbarHeight: 40, title: const Text('Company')),
      body: body,
    );
  }
}
