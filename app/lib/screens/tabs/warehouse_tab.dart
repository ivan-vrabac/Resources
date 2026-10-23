import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/player_provider.dart';
import '../../services/api_service.dart';
import '../../services/game_api.dart';
import '../../constants.dart';
import '../../widgets/top_banner.dart';

class WarehouseTab extends StatefulWidget {
  const WarehouseTab({super.key});
  @override
  State<WarehouseTab> createState() => _WarehouseTabState();
}

class _WarehouseTabState extends State<WarehouseTab> {
  Map<String, double>? _items;
  int _whLevel = 1;
  int _whCap = 5000;
  bool _loading = false;
  Map<int, Map<String, dynamic>> _recipes = {};   // recyclable found objects (Recycling Plant)
  int _plantLevel = 0;
  double _plantYield = 0, _obelisk = 0, _yield = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.getWarehouse(sid);
    final rec = await GameApi.call('/api/v1/cargo/recycling', sid);
    if (rec.ok) {
      _plantLevel = (rec.data['plantLevel'] as num? ?? 0).toInt();
      _plantYield = (rec.data['plantYield'] as num? ?? 0).toDouble();
      _obelisk = (rec.data['obeliskBonus'] as num? ?? 0).toDouble();
      _yield = (rec.data['yield'] as num? ?? 0).toDouble();
      _recipes = {for (final r in (rec.data['recipes'] as List).cast<Map<String, dynamic>>()) (r['itemID'] as num).toInt(): r};
    }
    if (mounted && result != null && result['err'] == 0) {
      setState(() {
        _items = (result['items'] as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, (v as num).toDouble()));
        _whLevel = (result['whLvl'] as num).toInt();
        _whCap = (result['whCap'] as num).toInt();
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  static int _upgradeCost(int level) => 12500 * level * level;
  static int _capAtLevel(int level) => 5000 * level * level;

  int _maxAffordableLevels(int credits) {
    int total = 0;
    int n = 0;
    while (true) {
      final cost = _upgradeCost(_whLevel + n);
      if (total + cost > credits) break;
      total += cost;
      n++;
      if (n >= 100) break;
    }
    return n;
  }

  Future<void> _showUpgradeDialog() async {
    final credits = context.read<PlayerProvider>().player?.credits ?? 0;
    final maxLevels = _maxAffordableLevels(credits);
    if (maxLevels == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Need ꞓ${fmtNum(_upgradeCost(_whLevel))} for next level')));
      return;
    }

    int selectedLevels = 1;
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          int totalCost = List.generate(selectedLevels,
              (i) => _upgradeCost(_whLevel + i)).fold(0, (a, b) => a + b);
          final newLevel = _whLevel + selectedLevels;
          final newCap = _capAtLevel(newLevel);

          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Upgrade Warehouse',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Lv $_whLevel  →  Lv $newLevel',  // ignore: prefer_const_constructors
                    style: const TextStyle(fontSize: 16, color: Colors.teal)),
                Text('ꞓ${fmtNum(totalCost)}',
                    style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 16)),
              ]),
              const SizedBox(height: 4),
              Text('New capacity: ${fmtNum(newCap)} units',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 16),
              if (maxLevels > 1) ...[
                Slider(
                  value: selectedLevels.toDouble(),
                  min: 1,
                  max: maxLevels.toDouble(),
                  divisions: maxLevels - 1,
                  label: '+$selectedLevels levels',
                  onChanged: (v) => setS(() => selectedLevels = v.round()),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('+1', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  Text('+$maxLevels max', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                ]),
                const SizedBox(height: 12),
              ],
              FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final sid = context.read<PlayerProvider>().sid;
                  final result = selectedLevels == 1
                      ? await ApiService.upgradeWarehouse(sid)
                      : await ApiService.upgradeWarehouseMulti(sid, selectedLevels);
                  if (!mounted) return;
                  if (result == null || result['err'] != 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(result?['msg'] ?? 'Upgrade failed')));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Warehouse upgraded to Lv ${result['newLvl']}!')));
                    context.read<PlayerProvider>().refresh();
                    _load();
                  }
                },
                child: Text('Upgrade $selectedLevels level${selectedLevels > 1 ? 's' : ''}  ꞓ${fmtNum(totalCost)}'),
              ),
            ]),
          );
        },
      ),
    );
  }

  /// Recycle found objects in the Recycling Plant (outputs and yield come from the server).
  Future<void> _recycle(int itemId, int owned) async {
    final recipe = _recipes[itemId]!;
    final outs = (recipe['outputs'] as List).cast<Map<String, dynamic>>();
    if (_plantLevel < 1) {
      AppNotify.show(context, 'Build a Recycling Plant (Special Buildings) to recycle', isError: true);
      return;
    }
    var qty = owned;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
        title: Text('Recycle ${itemName(itemId)}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Recycle $qty of $owned', style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('Yield: plant ${(_plantYield * 100).round()}%'
              '${_obelisk > 0 ? ' × Shadow Obelisk +${_obelisk.round()}%' : ''} = ${(_yield * 100).toStringAsFixed(1)}%',
              style: const TextStyle(fontSize: 12, color: Colors.lightGreenAccent)),
          if (owned > 1)
            Slider(value: qty.toDouble(), min: 1, max: owned.toDouble(), onChanged: (v) => set(() => qty = v.round())),
          const Text('You get about', style: TextStyle(color: Colors.white54, fontSize: 12)),
          for (final o in outs)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: _ItemIcon(itemId: (o['itemID'] as num).toInt()),
              title: Text(itemName((o['itemID'] as num).toInt())),
              trailing: Text(fmtNum(((o['perUnit'] as num) * qty).floor())),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Recycle')),
        ],
      )),
    );
    if (ok != true || !mounted) return;
    final r = await GameApi.call('/api/v1/cargo/recycle', context.read<PlayerProvider>().sid,
        {'itemID': itemId, 'qty': qty});
    if (!mounted) return;
    if (r.ok) {
      final got = (r.data['outputs'] as List).cast<Map<String, dynamic>>()
          .map((o) => '${fmtNum(o['qty'] as num)} ${itemName((o['itemID'] as num).toInt())}').join(', ');
      AppNotify.show(context, got.isEmpty ? 'Recycled (warehouse full?)' : 'Recycled: $got');
      context.read<PlayerProvider>().refresh();
      _load();
    } else {
      AppNotify.show(context, r.message ?? 'Recycling failed', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final items = _items ?? {};
    // Filter out special buildings — they are not warehouse resources.
    final entries = items.entries
        .where((e) => e.value > 0.01 && !kSpecialBuildings.containsKey(int.tryParse(e.key) ?? -1))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final totalUnits = entries.fold(0.0, (a, b) => a + b.value);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Level $_whLevel',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: _whCap > 0 ? (totalUnits / _whCap).clamp(0.0, 1.0) : 0,
                      backgroundColor: Colors.white12,
                    ),
                    const SizedBox(height: 4),
                    Text('${fmtNum(totalUnits)} / ${fmtNum(_whCap)} units',
                        style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  ])),
                  const SizedBox(width: 16),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.upgrade, size: 16),
                    label: const Text('Upgrade'),
                    onPressed: _showUpgradeDialog,
                  ),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Warehouse is empty.\nBuild mines to collect resources.',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
              ),
            )
          else
            ...entries.map((e) {
              final id = int.tryParse(e.key) ?? 0;
              final recyclable = _recipes.containsKey(id);
              return ListTile(
                dense: true,
                leading: _ItemIcon(itemId: id),
                title: Text(itemName(id)),
                subtitle: recyclable
                    ? const Text('tap to recycle', style: TextStyle(fontSize: 11, color: Colors.lightGreenAccent))
                    : null,
                onTap: recyclable ? () => _recycle(id, e.value.floor()) : null,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (recyclable) const Padding(padding: EdgeInsets.only(right: 6),
                      child: Icon(Icons.recycling, size: 16, color: Colors.lightGreenAccent)),
                  Text(
                    fmtNum(e.value),
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber, fontSize: 14),
                  ),
                ]),
              );
            }),
        ],
      ),
    );
  }
}

class _ItemIcon extends StatelessWidget {
  final int itemId;
  const _ItemIcon({required this.itemId});

  @override
  Widget build(BuildContext context) {
    final path = resImagePath(itemId);
    if (path != null) {
      return SizedBox(
        width: 32, height: 32,
        child: Image.asset(path, fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _fallback()),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    final name = itemName(itemId);
    return CircleAvatar(
      radius: 16,
      backgroundColor: Colors.teal.withValues(alpha: 0.3),
      child: Text(
        name.isNotEmpty ? name[0] : '?',
        style: const TextStyle(color: Colors.teal, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }
}

