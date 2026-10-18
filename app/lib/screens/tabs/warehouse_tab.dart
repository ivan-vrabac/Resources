import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/player_provider.dart';
import '../../services/api_service.dart';
import '../../constants.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.getWarehouse(sid);
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
                    Text('Warehouse  Lv $_whLevel',
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
              return ListTile(
                dense: true,
                leading: _ItemIcon(itemId: id),
                title: Text(itemName(id)),
                trailing: Text(
                  fmtNum(e.value),
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber, fontSize: 14),
                ),
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

