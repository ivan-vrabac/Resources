import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../constants.dart';
import '../models/player_provider.dart';
import '../services/api_service.dart';
import '../services/game_api.dart';
import '../widgets/top_banner.dart';
import 'casino_screen.dart';
import 'headquarters_screen.dart';

import '../app_colors.dart';
import '../widgets/popups.dart';
// Helper: resolve res map keys/values to int entries
List<MapEntry<int, int>> _resEntries(dynamic resMap) {
  if (resMap == null) return [];
  final m = resMap as Map<Object, dynamic>;
  return m.entries.map((e) {
    final k = e.key is int ? e.key as int : int.parse(e.key.toString());
    final v = (e.value as num).toInt();
    return MapEntry(k, v);
  }).toList();
}

class SpecialBuildingsScreen extends StatefulWidget {
  const SpecialBuildingsScreen({super.key});
  @override
  State<SpecialBuildingsScreen> createState() => _SpecialBuildingsScreenState();
}

class _SpecialBuildingsScreenState extends State<SpecialBuildingsScreen> {
  // Order and open cards are a per-device preference (closed by default).
  static const _kOrder = 'special_buildings_order', _kOpen = 'special_buildings_open';
  List<int> _order = [];
  Set<String> _open = {};

  /// Costs come from the server (rebalanced there); the built-in table is only the fallback.
  Future<void> _loadCosts() async {
    final r = await GameApi.call('/api/v1/buildings/info', context.read<PlayerProvider>().sid);
    if (!mounted || !r.ok) return;
    for (final b in (r.data['buildings'] as List).cast<Map<String, dynamic>>()) {
      final id = (b['itemID'] as num).toInt();
      final cfg = kSpecialBuildings[id];
      if (cfg == null) continue;
      cfg['costs'] = [
        for (final l in (b['levels'] as List).cast<Map<String, dynamic>>())
          {'credits': (l['credits'] as num).toInt(),
           'res': {for (final e in (l['res'] as Map).entries) int.parse(e.key as String): (e.value as num).toInt()}},
      ];
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _loadCosts();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _order = (p.getStringList(_kOrder) ?? []).map(int.tryParse).whereType<int>().toList();
        _open = (p.getStringList(_kOpen) ?? []).toSet();
      });
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kOrder, _order.map((e) => '$e').toList());
    await p.setStringList(_kOpen, _open.toList());
  }

  void _toggle(String key) {
    setState(() => _open.contains(key) ? _open.remove(key) : _open.add(key));
    _save();
  }

  /// Saved order first, then any building not in it yet (new ones) in the default order.
  List<int> get _ids => [
        ..._order.where(kSpecialBuildings.containsKey),
        ...kSpecialBuildings.keys.where((k) => !_order.contains(k)),
      ];

  void _snack(String msg, {bool error = false}) =>
      AppNotify.show(context, msg, isError: error);

  Map<int, dynamic> _ownedMap(List<dynamic> facts) {
    final map = <int, dynamic>{};
    for (final f in facts) {
      if (f['isSpecial'] == true) map[f['itemID'] as int] = f;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>().player;
    final facts   = player?.factories ?? [];
    final lager   = player?.lager ?? {};
    final credits = player?.credits ?? 0;
    final owned   = _ownedMap(facts);
    final ids = _ids;
    final hqLevel = player?.hq?.level ?? 0;

    return Scaffold(
      appBar: ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: ReorderableListView.builder(
        padding: const EdgeInsets.all(16),
        header: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const _SectionHeader('Special Buildings'),
          const SizedBox(height: 4),
          Text('Tap a building to open it; hold and drag to change the order.',
              style: TextStyle(color: AppColors.t38, fontSize: 12)),
          const SizedBox(height: 12),
          // Headquarters is always the first section
          CollapsibleCard(
            open: _open.contains('hq'),
            onToggle: () => _toggle('hq'),
            image: 'assets/images/hq_thumb_${hqLevel.clamp(1, 10)}.png',
            name: 'Headquarters',
            level: hqLevel == 0 ? 'Not placed' : 'Level $hqLevel',
            body: const HeadquartersScreen(embedded: true),
          ),
        ]),
        itemCount: ids.length,
        onReorderItem: (from, to) {
          setState(() {
            final list = [...ids];
            list.insert(to, list.removeAt(from));
            _order = list;
          });
          _save();
        },
        itemBuilder: (_, i) {
          final itemId = ids[i];
          final cfg    = kSpecialBuildings[itemId]!;
          final ownedF = owned[itemId];
          final currentLevel = ownedF != null ? (ownedF['lvl'] as int? ?? 0) : 0;
          final maxLevel = cfg['maxLevel'] as int;
          final costs = (cfg['costs'] as List).cast<Map<String, dynamic>>();
          return _SpecialBuildingCard(
            key: ValueKey(itemId),
            itemId: itemId,
            cfg: cfg,
            currentLevel: currentLevel,
            maxLevel: maxLevel,
            costs: costs,
            ownedFid: ownedF?['fID'] as String?,
            lager: lager,
            credits: credits,
            open: _open.contains('$itemId'),
            onToggle: () => _toggle('$itemId'),
            onAction: () => context.read<PlayerProvider>().refresh(),
            snack: _snack,
          );
        },
      ),
    );
  }
}

/// Compact card (picture, name, level) that opens to show [body].
class CollapsibleCard extends StatelessWidget {
  final bool open;
  final VoidCallback onToggle;
  final String image;
  final String name;
  final String level;
  final Widget? trailing;
  final Widget body;
  const CollapsibleCard({super.key, required this.open, required this.onToggle, required this.image,
      required this.name, required this.level, required this.body, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(children: [
              SizedBox(width: 40, height: 40, child: Image.asset(image, fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Icon(Icons.account_balance, size: 30, color: AppColors.accent))),
              const SizedBox(width: 12),
              Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
              if (level.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.accent.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(6)),
                  child: Text(level, style: TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              if (trailing != null) trailing!,
              Icon(open ? Icons.expand_less : Icons.expand_more, color: AppColors.t54),
            ]),
          ),
        ),
        if (open) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: body),
      ]),
    );
  }
}

// ── Card for each special building ────────────────────────────────────────────

class _SpecialBuildingCard extends StatefulWidget {
  final int itemId;
  final Map<String, dynamic> cfg;
  final int currentLevel;
  final int maxLevel;
  final List<Map<String, dynamic>> costs;
  final String? ownedFid;
  final Map<String, double> lager;
  final int credits;
  final VoidCallback onAction;
  final void Function(String) snack;
  final bool open;
  final VoidCallback onToggle;

  const _SpecialBuildingCard({
    super.key, required this.open, required this.onToggle,
    required this.itemId, required this.cfg, required this.currentLevel,
    required this.maxLevel, required this.costs, required this.ownedFid,
    required this.lager, required this.credits,
    required this.onAction, required this.snack,
  });

  @override
  State<_SpecialBuildingCard> createState() => _SpecialBuildingCardState();
}

class _SpecialBuildingCardState extends State<_SpecialBuildingCard> {
  bool _loading = false;

  bool get _isMaxLevel => widget.currentLevel >= widget.maxLevel;
  bool get _owned => widget.ownedFid != null;

  Map<String, dynamic> get _nextCost {
    final idx = widget.currentLevel; // 0 = build, 1+ = upgrade
    if (idx >= widget.costs.length) return {};
    return widget.costs[idx];
  }

  bool _canAfford() {
    final cost = _nextCost;
    if (cost.isEmpty) return false;
    if (widget.credits < (cost['credits'] as int)) return false;
    final res = (cost['res'] as Map<Object, dynamic>? ?? {});
    for (final entry in res.entries) {
      final have = widget.lager[entry.key.toString()] ?? 0.0;
      if (have < (entry.value as num)) return false;
    }
    return true;
  }

  Future<void> _buy() async {
    setState(() => _loading = true);
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.buySpecialBuilding(sid, widget.itemId);
    if (!mounted) return;
    setState(() => _loading = false);
    if (result == null || result['err'] != 0) {
      widget.snack(result?['msg'] ?? 'Build failed');
    } else {
      widget.snack('${widget.cfg['name']} built!');
      widget.onAction();
    }
  }

  Future<void> _upgrade() async {
    if (widget.ownedFid == null) return;
    setState(() => _loading = true);
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.upgradeSpecialBuilding(sid, widget.ownedFid!);
    if (!mounted) return;
    setState(() => _loading = false);
    if (result == null || result['err'] != 0) {
      widget.snack(result?['msg'] ?? 'Upgrade failed');
    } else {
      widget.snack('${widget.cfg['name']} upgraded to level ${result['newLvl']}!');
      widget.onAction();
    }
  }

  @override
  Widget build(BuildContext context) {
    final name  = widget.cfg['name'] as String;
    final desc  = widget.cfg['desc'] as String;
    final cost  = _nextCost;
    final canAfford = !_isMaxLevel && _canAfford();

    Widget? effectWidget;
    if (widget.itemId == 116) {
      final lvl = widget.currentLevel;
      final nextLvl = lvl + 1;
      final curQ  = lvl     < kTcMaxQuality.length  ? kTcMaxQuality[lvl]     : 100;
      final nextQ = nextLvl < kTcMaxQuality.length  ? kTcMaxQuality[nextLvl] : 100;
      final curR  = lvl     < kTcScanRadius.length  ? kTcScanRadius[lvl]     : 2250;
      final nextR = nextLvl < kTcScanRadius.length  ? kTcScanRadius[nextLvl] : 2250;
      effectWidget = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.radar, size: 14, color: AppColors.accent),
          const SizedBox(width: 4),
          Text('Scan radius: ', style: TextStyle(color: AppColors.t54, fontSize: 11)),
          Text('${curR}m', style: TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.bold)),
          if (!_isMaxLevel) ...[
            Text(' → ', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            Text('${nextR}m', style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ]),
        const SizedBox(height: 3),
        Row(children: [
          const Icon(Icons.visibility, size: 14, color: Colors.amberAccent),
          const SizedBox(width: 4),
          Text('Quality cap: ', style: TextStyle(color: AppColors.t54, fontSize: 11)),
          Text('$curQ%', style: const TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold)),
          if (!_isMaxLevel) ...[
            Text(' → ', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            Text('$nextQ%', style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ]),
      ]);
    } else if (widget.itemId == 123) {
      final lvl = widget.currentLevel;
      final range = lvl <= 0 ? 100 : (100.0 + (lvl - 1) * 11.0).clamp(100.0, 200.0).round();
      effectWidget = Row(children: [
        Icon(Icons.zoom_out_map, size: 14, color: AppColors.accent),
        const SizedBox(width: 4),
        Text('Boss range: ', style: TextStyle(color: AppColors.t54, fontSize: 11)),
        Text('${range}m', style: TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.bold)),
      ]);
    }

    return CollapsibleCard(
      open: widget.open,
      onToggle: widget.onToggle,
      image: 'assets/images_res/res${kSpecialBuildingImageId[widget.itemId] ?? widget.itemId}.png',
      name: name,
      level: !_owned ? 'Not built' : _isMaxLevel ? '' : 'Level ${widget.currentLevel}',   // maxed: just the star
      trailing: _isMaxLevel ? const Icon(Icons.star, color: Colors.amber, size: 20) : null,
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(desc, style: TextStyle(color: AppColors.t54, fontSize: 12)),
            )),
            IconButton(
              tooltip: 'Information',
              icon: Icon(Icons.info_outline, color: AppColors.t70),
              onPressed: () => showBuildingInfo(context, widget.itemId),
            ),
          ]),
          if (effectWidget != null) ...[
            const SizedBox(height: 6),
            effectWidget,
          ],

          // Progress bar for level (if owned)
          if (_owned) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: widget.currentLevel / widget.maxLevel,
                backgroundColor: Colors.white12,
                color: _isMaxLevel ? Colors.amber : AppColors.accent,
                minHeight: 4,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('Level ${widget.currentLevel} / ${widget.maxLevel}',
                  style: TextStyle(color: AppColors.t38, fontSize: 10)),
            ),
          ],

          // Casino play button
          if (widget.itemId == 61 && _owned) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.casino, size: 18),
                label: const Text('Play Casino'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CasinoScreen()),
                ),
                // high-contrast play button
                style: FilledButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black,
                    textStyle: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],

          // Cost section (if not max level)
          if (!_isMaxLevel && cost.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: Colors.white12),
            const SizedBox(height: 10),
            Text(_owned ? 'Upgrade cost:' : 'Build cost:',
                style: TextStyle(color: AppColors.t54, fontSize: 11)),
            const SizedBox(height: 6),
            _CostRow(
              credits: cost['credits'] as int,
              res: Map.fromEntries(_resEntries(cost['res'])),
              lager: widget.lager,
              playerCredits: widget.credits,
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: _loading
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(_owned ? Icons.arrow_upward : Icons.build_outlined, size: 18),
                label: Text(_owned ? 'Upgrade' : 'Build'),
                onPressed: (_loading || !canAfford)
                    ? null
                    : (_owned ? _upgrade : _buy),
                style: FilledButton.styleFrom(
                  backgroundColor: canAfford ? AppColors.accentDark : Colors.grey.shade800,
                ),
              ),
            ),
          ],
      ]),
    );
  }
}

// ── Cost row ──────────────────────────────────────────────────────────────────

class _CostRow extends StatelessWidget {
  final int credits;
  final Map<int, int> res;
  final Map<String, double> lager;
  final int playerCredits;
  const _CostRow({required this.credits, required this.res,
      required this.lager, required this.playerCredits});

  @override
  Widget build(BuildContext context) {
    final hasCredits = playerCredits >= credits;
    return Wrap(spacing: 8, runSpacing: 4, children: [
      _chip(
        label: 'ꞓ${fmtNum(credits)}',
        icon: Icons.monetization_on_outlined,
        ok: hasCredits,
      ),
      ...res.entries.map((e) {
        final have = lager[e.key.toString()] ?? 0.0;
        return _chip(
          label: '${fmtNum(e.value)} ${itemName(e.key)}',
          imgId: e.key,
          ok: have >= e.value,
        );
      }),
    ]);
  }

  Widget _chip({required String label, IconData? icon, int? imgId, required bool ok}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ok ? AppColors.accent.withValues(alpha: 0.15) : Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: ok ? AppColors.accent.withValues(alpha: 0.4) : Colors.redAccent.withValues(alpha: 0.4),
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (imgId != null)
          Image.asset(resAsset(imgId), width: 14, height: 14,
              errorBuilder: (_, __, ___) => const SizedBox())
        else if (icon != null)
          Icon(icon, size: 14, color: ok ? AppColors.accent : Colors.redAccent),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(
            fontSize: 11, color: ok ? AppColors.t70 : Colors.redAccent)),
      ]),
    );
  }
}

// ── Section Header ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: TextStyle(fontSize: 11, color: AppColors.t38, letterSpacing: 1.2));
}

/// Information sheet: what the building gives at every level and what each level costs (from
/// the server's own formulas, /api/v1/buildings/info).
Future<void> showBuildingInfo(BuildContext context, int itemId) async {
  final sid = context.read<PlayerProvider>().sid;
  final r = await GameApi.call('/api/v1/buildings/info', sid);
  if (!context.mounted) return;
  if (!r.ok) {
    AppNotify.show(context, r.message ?? 'Information unavailable', isError: true);
    return;
  }
  final b = (r.data['buildings'] as List).cast<Map<String, dynamic>>().firstWhere(
      (x) => (x['itemID'] as num).toInt() == itemId, orElse: () => const {});
  if (b.isEmpty) return;
  final levels = (b['levels'] as List).cast<Map<String, dynamic>>();
  final labels = levels.isEmpty ? <String>[]
      : (levels.first['effects'] as List).cast<Map<String, dynamic>>().map((e) => e['label'] as String).toList();
  final cur = (b['level'] as num? ?? 0).toInt();
  await showAppSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (_, scroll) => ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
        Text(b['name'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(b['desc'] as String? ?? '', style: TextStyle(color: AppColors.t60, fontSize: 12)),
        const SizedBox(height: 12),
        // one card per level, like the HQ information (owner 2026-10-23)
        for (final l in levels) Builder(builder: (_) {
          final lvl = (l['level'] as num).toInt();
          final eff = (l['effects'] as List).cast<Map<String, dynamic>>();
          final res = (l['res'] as Map).entries.toList();
          final credits = (l['credits'] as num? ?? 0).toInt();
          final cs = Theme.of(context).colorScheme;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: lvl == cur ? cs.primary.withValues(alpha: 0.15) : cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: lvl == cur ? cs.primary : cs.outline.withValues(alpha: 0.5)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('Level $lvl', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),

              ]),
              const SizedBox(height: 6),
              for (final e in eff)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('${e['label']}: ${e['value']}', style: const TextStyle(fontSize: 13)),
                ),
              if (credits > 0 || res.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(lvl == 1 ? 'Costs to build:' : 'Costs to reach this level:',
                    style: TextStyle(fontSize: 12, color: AppColors.t60)),
                const SizedBox(height: 4),
                Wrap(spacing: 10, runSpacing: 6, children: [
                  if (credits > 0)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.monetization_on_outlined, size: 18, color: AppColors.accent),
                      const SizedBox(width: 4),
                      Text('ꞓ${fmtNum(credits)}', style: const TextStyle(fontSize: 12)),
                    ]),
                  for (final e in res)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Image.asset(resAsset(int.parse(e.key as String)), width: 18, height: 18,
                          errorBuilder: (_, __, ___) => const SizedBox(width: 18)),
                      const SizedBox(width: 4),
                      Text('${fmtNum(e.value as num)} ${itemName(int.parse(e.key as String))}',
                          style: const TextStyle(fontSize: 12)),
                    ]),
                ]),
              ],
            ]),
          );
        }),
      ]),
    ),
  );
}

