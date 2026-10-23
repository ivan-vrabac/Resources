import '../services/game_api.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../models/player_provider.dart';
import '../services/api_service.dart';
import '../widgets/top_banner.dart';
import 'casino_screen.dart';

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
  // Local state for which special buildings the player owns + their levels
  // Driven from PlayerProvider's factory list (isSpecial == true)

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

    return Scaffold(
      appBar: ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader('Special Buildings'),
          const SizedBox(height: 4),
          const Text(
            'Powerful buildings that unlock permanent bonuses.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 16),
          ...kSpecialBuildings.entries.map((e) {
            final itemId = e.key;
            final cfg    = e.value;
            final ownedF = owned[itemId];
            final currentLevel = ownedF != null ? (ownedF['lvl'] as int? ?? 0) : 0;
            final maxLevel = cfg['maxLevel'] as int;
            final costs = (cfg['costs'] as List).cast<Map<String, dynamic>>();
            return _SpecialBuildingCard(
              itemId: itemId,
              cfg: cfg,
              currentLevel: currentLevel,
              maxLevel: maxLevel,
              costs: costs,
              ownedFid: ownedF?['fID'] as String?,
              lager: lager,
              credits: credits,
              onAction: () => context.read<PlayerProvider>().refresh(),
              snack: _snack,
            );
          }),
        ],
      ),
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

  const _SpecialBuildingCard({
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
          const Icon(Icons.radar, size: 14, color: Colors.tealAccent),
          const SizedBox(width: 4),
          const Text('Scan radius: ', style: TextStyle(color: Colors.white54, fontSize: 11)),
          Text('${curR}m', style: const TextStyle(color: Colors.tealAccent, fontSize: 11, fontWeight: FontWeight.bold)),
          if (!_isMaxLevel) ...[
            const Text(' → ', style: TextStyle(color: Colors.white38, fontSize: 11)),
            Text('${nextR}m', style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ]),
        const SizedBox(height: 3),
        Row(children: [
          const Icon(Icons.visibility, size: 14, color: Colors.amberAccent),
          const SizedBox(width: 4),
          const Text('Quality cap: ', style: TextStyle(color: Colors.white54, fontSize: 11)),
          Text('$curQ%', style: const TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold)),
          if (!_isMaxLevel) ...[
            const Text(' → ', style: TextStyle(color: Colors.white38, fontSize: 11)),
            Text('$nextQ%', style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ]),
      ]);
    } else if (widget.itemId == 123) {
      final lvl = widget.currentLevel;
      final range = lvl <= 0 ? 100 : (100.0 + (lvl - 1) * 11.0).clamp(100.0, 200.0).round();
      effectWidget = Row(children: [
        const Icon(Icons.zoom_out_map, size: 14, color: Colors.tealAccent),
        const SizedBox(width: 4),
        const Text('Boss range: ', style: TextStyle(color: Colors.white54, fontSize: 11)),
        Text('${range}m', style: const TextStyle(color: Colors.tealAccent, fontSize: 11, fontWeight: FontWeight.bold)),
      ]);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header row
          Row(children: [
            SizedBox(
              width: 48, height: 48,
              child: Image.asset(
                'assets/images_res/res${kSpecialBuildingImageId[widget.itemId] ?? widget.itemId}.png',
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.account_balance, size: 36, color: Colors.teal),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 2),
              Row(children: [
                if (_owned) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.teal.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _isMaxLevel ? 'Max Level' : 'Level ${widget.currentLevel}',
                      style: const TextStyle(color: Colors.tealAccent, fontSize: 11,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ] else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('Not built',
                        style: TextStyle(color: Colors.white54, fontSize: 11)),
                  ),
              ]),
            ])),
            if (_isMaxLevel)
              const Icon(Icons.star, color: Colors.amber, size: 22),
            IconButton(
              tooltip: 'Information',
              icon: const Icon(Icons.info_outline, color: Colors.white70),
              onPressed: () => showBuildingInfo(context, widget.itemId),
            ),
          ]),
          const SizedBox(height: 10),
          Text(desc, style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
                color: _isMaxLevel ? Colors.amber : Colors.teal,
                minHeight: 4,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('Level ${widget.currentLevel} / ${widget.maxLevel}',
                  style: const TextStyle(color: Colors.white38, fontSize: 10)),
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
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
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
                  backgroundColor: canAfford ? Colors.teal.shade700 : Colors.grey.shade800,
                ),
              ),
            ),
          ],
        ]),
      ),
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
        color: ok ? Colors.teal.withValues(alpha: 0.15) : Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: ok ? Colors.teal.withValues(alpha: 0.4) : Colors.redAccent.withValues(alpha: 0.4),
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (imgId != null)
          Image.asset('assets/images_res/res$imgId.png', width: 14, height: 14,
              errorBuilder: (_, __, ___) => const SizedBox())
        else if (icon != null)
          Icon(icon, size: 14, color: ok ? Colors.tealAccent : Colors.redAccent),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(
            fontSize: 11, color: ok ? Colors.white70 : Colors.redAccent)),
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
      style: const TextStyle(fontSize: 11, color: Colors.white38, letterSpacing: 1.2));
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
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A2E),
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (_, scroll) => ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
        Text(b['name'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(b['desc'] as String? ?? '', style: const TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 36,
            dataRowMinHeight: 32,
            dataRowMaxHeight: 52,
            columnSpacing: 18,
            columns: [
              const DataColumn(label: Text('Level')),
              for (final l in labels) DataColumn(label: Text(l, style: const TextStyle(fontSize: 12))),
              const DataColumn(label: Text('Cost')),
            ],
            rows: [
              for (final l in levels)
                DataRow(
                  color: WidgetStatePropertyAll((l['level'] as num).toInt() == cur
                      ? Colors.teal.withValues(alpha: 0.25) : null),
                  cells: [
                    DataCell(Text('${l['level']}', style: TextStyle(
                        fontWeight: (l['level'] as num).toInt() == cur ? FontWeight.bold : FontWeight.normal))),
                    for (final e in (l['effects'] as List).cast<Map<String, dynamic>>())
                      DataCell(Text(e['value'] as String, style: const TextStyle(fontSize: 12))),
                    DataCell(Text(['ꞓ${fmtNum(l['credits'] as num)}',
                      for (final res in (l['res'] as Map).entries) '${fmtNum(res.value as num)} ${itemName(int.parse(res.key as String))}',
                    ].join('\n'), style: const TextStyle(fontSize: 11, color: Colors.white70))),
                  ],
                ),
            ],
          ),
        ),
      ]),
    ),
  );
}

