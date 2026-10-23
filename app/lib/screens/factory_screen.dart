import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/player_provider.dart';
import '../services/api_service.dart';
import '../constants.dart';

import '../app_colors.dart';
import '../widgets/popups.dart';
DateTime _srvUtc(String s) =>
    DateTime.parse(s.endsWith('Z') || s.contains('+') ? s : '${s}Z');

DateTime? _srvUtcOpt(String? s) {
  if (s == null || s.isEmpty) return null;
  try { return _srvUtc(s); } catch (_) { return null; }
}

/// Instant-production cooldown in days for this player (5, shortened by Thor's Crucible).
double kBoostCooldownDays = 5;

String _fmtDays(double d) {
  final whole = d.floor(), hours = ((d - whole) * 24).round();
  return hours == 0 ? '$whole-day' : '${whole}d ${hours}h';
}

class FactoryScreen extends StatefulWidget {
  const FactoryScreen({super.key});
  @override
  State<FactoryScreen> createState() => _FactoryScreenState();
}

class _FactoryScreenState extends State<FactoryScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  Timer? _refreshTimer;
  // player's own order of factories (item ids), kept on this device
  static const _kOrder = 'factory_order';
  List<int> _order = [];
  bool _arranging = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _order = (p.getStringList(_kOrder) ?? []).map(int.tryParse).whereType<int>().toList());
    });
    _load();
    _refreshTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.getFactories(sid);
    // the server catalog lists every factory type; keep the shared table in sync with it
    for (final c in (result?['catalog'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      kFactoryTypes[(c['itemID'] as num).toInt()] = {'produces': c['produces'], 'out': c['out'], 'hrs': c['hrs']};
    }
    kBoostCooldownDays = (result?['boostCooldownDays'] as num? ?? 5).toDouble();
    if (mounted) setState(() { _data = result; _loading = false; });
  }

  Future<void> _buy(int itemId) async {
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.buyFactory(sid, itemId);
    if (!mounted) return;
    if (result != null && result['err'] == 0) {
      context.read<PlayerProvider>().refresh();
      _load();
    }
  }

  Future<void> _collect(String fid) async {
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.collectFactory(sid, fid);
    if (!mounted) return;
    if (result != null && result['err'] == 0) {
      context.read<PlayerProvider>().refresh();
      _load(silent: true);
    }
  }

  Future<void> _stop(String fid) async {
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.stopProduction(sid, fid);
    if (!mounted) return;
    if (result != null && result['err'] == 0) {
      context.read<PlayerProvider>().refresh();
      _load(silent: true);
    }
  }

  Future<void> _startProd(String fid) async {
    final factories = _data?['factories'] as List? ?? [];
    final f = factories.firstWhere((x) => x['fID'] == fid, orElse: () => null);
    if (f == null) return;
    final catalog = _data?['catalog'] as List? ?? [];
    final itemId = f['itemID'] as int;
    final catalogEntry = catalog.firstWhere(
        (c) => c['itemID'] == itemId, orElse: () => null);
    if (catalogEntry == null) return;
    final player = context.read<PlayerProvider>().player;

    final batches = await showAppSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _StartProdSheet(
          factory: f, catalogEntry: catalogEntry, player: player),
    );
    if (batches == null || !mounted) return;
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.startProduction(sid, fid, batches);
    if (!mounted) return;
    if (result != null && result['err'] == 0) _load(silent: true);
  }

  Future<void> _upgrade(String fid) async {
    final factories = _data?['factories'] as List? ?? [];
    final f = factories.firstWhere((x) => x['fID'] == fid, orElse: () => null);
    if (f == null) return;
    final upgCredits = (f['upgCredits'] as num? ?? 0).toInt();
    final upgRes = f['upgRes'] as Map<String, dynamic>? ?? {};
    final level = (f['lvl'] as num? ?? 1).toInt();
    final ft = kFactoryTypes[f['itemID'] as int? ?? 0];
    final baseOut = ft?['out'] as int? ?? 0;
    final baseHrs = ft?['hrs'] as int? ?? 1;
    final curLevelMult = level.toDouble();
    final newLevelMult = (level + 1).toDouble();
    final curHrsPerBatch = baseHrs / curLevelMult;
    final newHrsPerBatch = baseHrs / newLevelMult;
    final curOutPerHr = baseOut / curHrsPerBatch;
    final newOutPerHr = baseOut / newHrsPerBatch;
    final outputItemId = ft?['produces'] as int?;
    final player = context.read<PlayerProvider>().player;
    final lager = (player?.lager as Map<String, double>?) ?? {};
    final canAffordUpgrade = (player?.credits ?? 0) >= upgCredits &&
        upgRes.entries.every((e) => (lager[e.key] ?? 0) >= (e.value as num).toDouble());

    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Upgrade Factory'),
            Text('Level $level', style: TextStyle(
                color: AppColors.accent, fontSize: 13, fontWeight: FontWeight.normal)),
          ],
        ),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 4),
          // Cost row
          Row(children: [
            const Icon(Icons.monetization_on, size: 14, color: Colors.amber),
            const SizedBox(width: 4),
            Text('êž“${fmtNum(upgCredits)}', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
          ]),
          // Resource requirements
          if (upgRes.isNotEmpty) ...[
            const SizedBox(height: 6),
            ...upgRes.entries.map((e) {
              final id = int.tryParse(e.key) ?? 0;
              final have = (lager[e.key] ?? 0);
              final need = (e.value as num).toDouble();
              final ok = have >= need;
              final imgPath = resImagePath(id);
              return Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(children: [
                  SizedBox(width: 16, height: 16,
                      child: imgPath != null
                          ? Image.asset(imgPath, fit: BoxFit.contain)
                          : const Icon(Icons.inventory_2_outlined, size: 14)),
                  const SizedBox(width: 4),
                  Text('${fmtNum(need)} ${itemName(id)}',
                      style: TextStyle(fontSize: 12,
                          color: ok ? AppColors.t70 : Colors.red,
                          fontWeight: ok ? FontWeight.normal : FontWeight.bold)),
                ]),
              );
            }),
          ],
          const Divider(height: 16),
          // Speed / output improvement
          if (outputItemId != null) ...[
            Row(children: [
              if (resImagePath(outputItemId) != null)
                Padding(padding: const EdgeInsets.only(right: 6),
                    child: Image.asset(resImagePath(outputItemId)!, width: 18, height: 18)),
              Text(itemName(outputItemId), style: TextStyle(color: AppColors.t54, fontSize: 12)),
            ]),
            const SizedBox(height: 4),
          ],
          Row(children: [
            Text('${fmtNum(curOutPerHr.round())} u/hr',
                style: TextStyle(color: AppColors.t38, fontSize: 12)),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.arrow_forward, size: 14, color: Colors.greenAccent)),
            Text('${fmtNum(newOutPerHr.round())} u/hr',
                style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Text('${_fmtHrsStatic(curHrsPerBatch)}/batch',
                style: TextStyle(color: AppColors.t38, fontSize: 11)),
            Padding(padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.arrow_forward, size: 12, color: AppColors.accent)),
            Expanded(child: Text('${_fmtHrsStatic(newHrsPerBatch)}/batch  (${(newLevelMult / curLevelMult * 100 - 100).round()}% faster)',
                style: TextStyle(color: AppColors.accent, fontSize: 11))),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => popIfCurrent(_, false),
              child: const Text('Cancel'),
            )),
            const SizedBox(width: 12),
            Expanded(child: FilledButton(
              onPressed: canAffordUpgrade ? () => popIfCurrent(_, true) : null,
              child: const Text('Upgrade'),
            )),
          ]),
        ]),
      ),
    );
    if (confirm != true || !mounted) return;
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.upgradeFactory(sid, fid);
    if (!mounted) return;
    if (result != null && result['err'] == 0) {
      context.read<PlayerProvider>().refresh();
      _load();
    }
  }

  Future<void> _boost(String fid) async {
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.boostFactory(sid, fid);
    if (!mounted) return;
    if (result != null && result['err'] == 0) {
      context.read<PlayerProvider>().refresh();
      _load();
    }
  }

  Future<void> _confirmAndBoost(String fid, Map<String, dynamic> factory) async {
    final ft = kFactoryTypes[factory['itemID'] as int? ?? 0];
    if (ft == null) return;
    final player = context.read<PlayerProvider>().player;
    final level = (factory['lvl'] as num? ?? 1).toInt();
    final levelMult = level.toDouble();
    final outPerHr = (ft['out'] as int) * levelMult / (ft['hrs'] as int);
    final prodEnd = factory['prodEnd'] as String?;
    final prodEndDt = prodEnd != null ? _srvUtcOpt(prodEnd) : null;
    final remainingHrs = prodEndDt != null
        ? prodEndDt.difference(DateTime.now()).inMinutes / 60.0
        : 0.0;
    final applyHrs = min(7 * 24.0, max(0.0, remainingHrs));
    final instantOutput = outPerHr * applyHrs;
    final producesId = ft['produces'] as int;
    final whCap = player?.whCap ?? 5000;
    final currentInWh = (player?.lager[producesId.toString()] ?? 0).toDouble();
    final overflow = (currentInWh + instantOutput - whCap).clamp(0.0, double.infinity);
    final isUnderWeek = remainingHrs < 7 * 24 - 0.1;

    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Use Giant Diamond?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (resImagePath(producesId) != null)
              Padding(padding: const EdgeInsets.only(right: 8),
                  child: Image.asset(resImagePath(producesId)!, width: 28, height: 28)),
            Text('+${fmtNum(instantOutput)} ${itemName(producesId)}',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.accent)),
          ]),
          const SizedBox(height: 4),
          Text('instantly added to warehouse', style: TextStyle(color: AppColors.t54, fontSize: 12)),
          if (isUnderWeek) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6)),
              child: Row(children: [
                const Icon(Icons.info_outline, color: Colors.orange, size: 14),
                const SizedBox(width: 6),
                Expanded(child: Text(
                  'Only ${applyHrs < 24 ? '${applyHrs.round()}h' : '${(applyHrs/24).toStringAsFixed(1)}d'} remaining â€” less than the 7-day max',
                  style: const TextStyle(color: Colors.orange, fontSize: 11),
                )),
              ]),
            ),
          ],
          if (overflow > 0) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6)),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 14),
                const SizedBox(width: 6),
                Expanded(child: Text(
                  '${fmtNum(overflow)} units will overflow and be lost',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                )),
              ]),
            ),
          ],
          const SizedBox(height: 8),
          Text('${_fmtDays(kBoostCooldownDays)} cooldown starts after use.',
              style: TextStyle(color: AppColors.t38, fontSize: 11)),
        ]),
        actions: [
          TextButton(onPressed: () => popIfCurrent(_, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => popIfCurrent(_, true), child: const Text('Use Diamond')),
        ],
      ),
    );
    if (confirm == true && mounted) _boost(fid);
  }

  Future<void> _useBooster(String fid, int itemId) async {
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.useBooster(sid, fid, itemId);
    if (!mounted) return;
    if (result != null && result['err'] == 0) {
      context.read<PlayerProvider>().refresh();
      _load();
    }
  }

  static String _fmtHrsStatic(double h) {
    if (h < 1) return '${(h * 60).round()}m';
    final hi = h.floor();
    final mi = ((h - hi) * 60).round();
    return mi == 0 ? '${hi}h' : '${hi}h ${mi}m';
  }

  void _showBoostSheet(String fid, Map<String, dynamic> factory) {
    final player = context.read<PlayerProvider>().player;
    final prodItem = factory['prodItem'];
    final prodEndStr = factory['prodEnd'] as String?;
    final prodEndDt = _srvUtcOpt(prodEndStr);
    final isProducing = prodItem != null && prodEndDt != null && prodEndDt.isAfter(DateTime.now());
    final onCooldown = factory['cooldownUntil'] != null;
    final boosterItem = factory['boosterItem'] as int?;
    final boosterUntil = factory['boosterUntil'] as String?;
    final hasActiveBooster = boosterItem != null && boosterUntil != null &&
        _srvUtcOpt(boosterUntil)?.isAfter(DateTime.now()) == true;

    showAppSheet(
      context: context,
      builder: (_) => _BoostSheet(
        factory: factory,
        player: player,
        isProducing: isProducing,
        hasActiveBooster: hasActiveBooster,
        onDiamondBoost: (isProducing && !onCooldown) ? () { popIfCurrent(_); _confirmAndBoost(fid, factory); } : null,
        onBooster: (isProducing && !hasActiveBooster)
            ? (itemId) { popIfCurrent(_); _useBooster(fid, itemId); }
            : null,
      ),
    );
  }

  /// Own factories (no special buildings) in the player's order; new ones go last.
  List<dynamic> get _myFactories {
    final list = (_data?['factories'] as List? ?? const [])
        .where((f) => !kSpecialBuildings.containsKey(f['itemID'] as int? ?? 0)).toList();
    int pos(dynamic f) {
      final i = _order.indexOf(f['itemID'] as int? ?? 0);
      return i < 0 ? 1 << 30 : i;
    }
    final idx = {for (var i = 0; i < list.length; i++) list[i]: i};
    list.sort((a, b) { final c = pos(a).compareTo(pos(b)); return c != 0 ? c : idx[a]!.compareTo(idx[b]!); });
    return list;
  }

  Widget _arrangeView(List<dynamic> mine) => Scaffold(
        appBar: AppBar(toolbarHeight: 40, title: const Text('Arrange factories'), actions: [
          TextButton(onPressed: () => setState(() => _arranging = false), child: const Text('Done')),
        ]),
        body: ReorderableListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: mine.length,
          onReorderItem: (from, to) async {
            final ids = mine.map((f) => f['itemID'] as int).toList();
            ids.insert(to, ids.removeAt(from));
            setState(() => _order = ids);
            final p = await SharedPreferences.getInstance();
            await p.setStringList(_kOrder, ids.map((e) => '$e').toList());
          },
          itemBuilder: (_, i) {
            final f = mine[i];
            final out = kFactoryTypes[f['itemID']]?['produces'];
            return Card(
              key: ValueKey(f['fID']),
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                leading: SizedBox(width: 32, height: 32, child: Image.asset('assets/images_res/res${f['itemID']}.png',
                    errorBuilder: (_, __, ___) => const Icon(Icons.factory_outlined))),
                title: Text(itemName(f['itemID'] as int)),
                subtitle: out is int ? Text('Produces ${itemName(out)}') : null,
                trailing: Text('Lv ${f['lvl'] ?? 1}'),
              ),
            );
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>().player;
    final canPop = ModalRoute.of(context)?.canPop == true;
    final mine = _myFactories;
    if (_arranging && !_loading) return _arrangeView(mine);
    if (_loading) {
      return Scaffold(
        appBar: canPop ? AppBar(toolbarHeight: 36) : null,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: canPop ? AppBar(toolbarHeight: 36) : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(12), children: [
          if (mine.isNotEmpty) ...[
            Row(children: [
              const Expanded(child: _SectionHeader('My Factories')),
              if (mine.length > 1)
                TextButton.icon(
                  onPressed: () => setState(() => _arranging = true),
                  icon: const Icon(Icons.swap_vert, size: 16),
                  label: const Text('Arrange', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
            ]),
            ...mine.map((f) => _FactoryTile(
              key: ValueKey(f['fID']),
              factory: f,
              player: player,
              onCollect: () => _collect(f['fID'] as String),
              onStart: () => _startProd(f['fID'] as String),
              onStop: () => _stop(f['fID'] as String),
              onUpgrade: () => _upgrade(f['fID'] as String),
              onBoost: () => _showBoostSheet(f['fID'] as String, f),
            )),
            const SizedBox(height: 16),
          ],
          const _SectionHeader('Build a Factory'),
          if (_data != null)
            ...(_data!['catalog'] as List)
                .where((c) => c['owned'] != true &&
                    !kSpecialBuildings.containsKey(c['itemID'] as int? ?? 0))
                .map((c) => _CatalogTile(
                  item: c,
                  player: player,
                  onBuy: () => _buy(c['itemID'] as int),
                )),
          if (_data != null &&
              (_data!['catalog'] as List)
                  .where((c) => !kSpecialBuildings.containsKey(c['itemID'] as int? ?? 0))
                  .every((c) => c['owned'] == true))
            Padding(
              padding: EdgeInsets.all(16),
              child: Text('You own all available factories!',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.t54)),
            ),
        ]),
      ),
    );
  }
}


class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text.toUpperCase(),
        style: TextStyle(fontSize: 11, color: AppColors.t38, letterSpacing: 1.2)),
  );
}

class _FactoryTile extends StatefulWidget {
  final dynamic factory;
  final dynamic player;
  final VoidCallback onCollect;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onUpgrade;
  final VoidCallback onBoost;
  const _FactoryTile({
    super.key,
    required this.factory, required this.player,
    required this.onCollect, required this.onStart,
    required this.onStop, required this.onUpgrade, required this.onBoost,
  });
  @override
  State<_FactoryTile> createState() => _FactoryTileState();
}

class _FactoryTileState extends State<_FactoryTile> {
  Timer? _timer;
  String _countdown = '';
  bool _isDone = false;
  String _boostCountdown = '';

  @override
  void initState() {
    super.initState();
    _updateCountdown();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateCountdown());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _updateCountdown() {
    final prodEnd = widget.factory['prodEnd'] as String?;
    if (prodEnd == null || prodEnd.isEmpty) {
      if (mounted) setState(() { _countdown = ''; _isDone = false; });
    } else {
      try {
        final end = _srvUtc(prodEnd);
        final rem = end.difference(DateTime.now());
        if (rem.isNegative) {
          if (mounted) setState(() { _countdown = 'Ready!'; _isDone = true; });
        } else {
          final h = rem.inHours;
          final m = rem.inMinutes % 60;
          final s = rem.inSeconds % 60;
          final str = h > 0 ? '${h}h ${m.toString().padLeft(2,'0')}m'
              : '${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
          if (mounted) setState(() { _countdown = str; _isDone = false; });
        }
      } catch (_) {}
    }

    final cooldownUntil = widget.factory['cooldownUntil'] as String?;
    final fireUntil = widget.factory['fireUntil'] as String?;
    final isOnFire = fireUntil != null &&
        _srvUtcOpt(fireUntil)?.isAfter(DateTime.now()) == true;
    String newCountdown = '';
    if (isOnFire) {
      final rem = _srvUtcOpt(fireUntil)?.difference(DateTime.now());
      if (rem != null && !rem.isNegative) newCountdown = '${rem.inDays}d ${rem.inHours % 24}h';
    } else if (cooldownUntil != null) {
      final rem = _srvUtcOpt(cooldownUntil)?.difference(DateTime.now());
      if (rem != null && !rem.isNegative) newCountdown = '${rem.inDays}d ${rem.inHours % 24}h';
    }
    if (mounted) setState(() => _boostCountdown = newCountdown);
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.factory;
    final itemId = f['itemID'] as int;
    final level = (f['lvl'] as num? ?? 1).toInt();
    final prodItem = f['prodItem'] as int?;
    final name = kFactoryNames[itemId] ?? itemName(itemId);
    final onCooldown = f['cooldownUntil'] != null;
    final isProducing = prodItem != null && _countdown.isNotEmpty;
    final fireUntil = f['fireUntil'] as String?;
    final isOnFire = fireUntil != null &&
        _srvUtcOpt(fireUntil)?.isAfter(DateTime.now()) == true;
    final boosterItem = f['boosterItem'] as int?;
    final boosterUntil = f['boosterUntil'] as String?;
    final hasBooster = boosterItem != null && boosterUntil != null &&
        _srvUtcOpt(boosterUntil)?.isAfter(DateTime.now()) == true;
    final upgCredits = (f['upgCredits'] as num? ?? 0).toInt();
    final upgRes = (f['upgRes'] as Map<String, dynamic>? ?? {});
    final credits = widget.player?.credits ?? 0;
    final lager = widget.player?.lager ?? {};
    final canAffordUpgrade = credits >= upgCredits &&
        upgRes.entries.every((e) =>
            (lager[e.key] ?? 0) >= (e.value as num).toDouble());
    final ft = kFactoryTypes[itemId];
    final outputItemId = ft?['produces'] as int?;
    final outputImgPath = outputItemId != null ? resImagePath(outputItemId) : null;

    final baseOut = ft?['out'] as int? ?? 0;
    final baseHrs = ft?['hrs'] as int? ?? 1;
    final levelMult = level.toDouble();
    final hrsPerBatch = baseHrs / levelMult;
    final outPerHr = baseOut / hrsPerBatch;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            if (outputImgPath != null)
              Image.asset(outputImgPath, width: 48, height: 48, fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Icon(Icons.factory, size: 40, color: AppColors.accent))
            else
              Icon(Icons.factory, size: 40, color: AppColors.accent),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              Row(children: [
                _badge('Level $level', AppColors.accent),
                if (hasBooster) ...[
                  const SizedBox(width: 4),
                  _badge('+${((((kWaBoosters[boosterItem]?['boost'] as num?) ?? 1.0) - 1.0) * 100).round()}%',
                      Colors.green),
                ],
                if (isOnFire) ...[
                  const SizedBox(width: 4),
                  _badge('ON FIRE', Colors.red),
                ],
              ]),
            ])),
            // Boost button â€” always tappable
            GestureDetector(
              onTap: widget.onBoost,
              child: ColorFiltered(
                colorFilter: (!isProducing)
                    ? const ColorFilter.matrix([
                        0.3,0,0,0,0, 0,0.3,0,0,0, 0,0,0.3,0,0, 0,0,0,0.6,0])
                    : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
                child: Image.asset('assets/images/2x/factoryboost.png', width: 36, height: 36,
                    errorBuilder: (_, __, ___) =>
                        Icon(Icons.rocket_launch, size: 28,
                            color: isProducing ? AppColors.accent : Colors.white24)),
              ),
            ),
          ]),

          if (isOnFire) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(children: [
                const Icon(Icons.local_fire_department, color: Colors.redAccent, size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text('Factory on fire! Cannot produce for $_boostCountdown',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 11))),
              ]),
            ),
          ],

          const SizedBox(height: 10),

          if (isProducing) ...[
            if (_isDone) ...[
              Row(children: [
                const Expanded(child: Text('Ready to collect!',
                    style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold))),
                FilledButton.icon(
                  icon: const Icon(Icons.inventory, size: 14),
                  label: const Text('Collect'),
                  onPressed: widget.onCollect,
                ),
              ]),
            ] else ...[
              Row(children: [
                // ignore: unnecessary_non_null_assertion
                Expanded(child: Text('${itemName(prodItem!)}  â€¢  ${fmtNum(f['prodAmt'] as num)} units',
                    style: TextStyle(color: AppColors.t54, fontSize: 11))),
                Text(_countdown,
                    style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, size: 16, color: Colors.red),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                  onPressed: widget.onStop,
                  tooltip: 'Cancel production',
                ),
              ]),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: _prodProgress(),
                backgroundColor: Colors.white12,
                color: AppColors.accent,
              ),
            ],
          ] else ...[
            if (isOnFire)
              const Text('Cannot produce while on fire.',
                  style: TextStyle(color: Colors.red, fontSize: 11))
            else ...[
              Text('${fmtNum(outPerHr.round())} units/hr  â€¢  ${fmtNum(baseOut)} per batch  â€¢  ${_fmtHrs(hrsPerBatch)}',
                  style: TextStyle(color: AppColors.t54, fontSize: 11)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: FilledButton.tonal(
                  onPressed: widget.onStart,
                  child: const Text('Start Production'),
                )),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton(
                  onPressed: !isProducing ? () => widget.onUpgrade() : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.lightBlue,
                    side: const BorderSide(color: Colors.lightBlue),
                  ),
                  child: const Text('Upgrade', style: TextStyle(fontSize: 12)),
                )),
              ]),
            ],
          ],
        ]),
      ),
    );
  }

  String _fmtHrs(double h) {
    if (h < 1) return '${(h * 60).round()}m';
    final hi = h.floor();
    final mi = ((h - hi) * 60).round();
    return mi == 0 ? '${hi}h' : '${hi}h ${mi}m';
  }

  double _prodProgress() {
    final prodEnd   = widget.factory['prodEnd']   as String?;
    final prodStart = widget.factory['prodStart'] as String?;
    final prodItem  = widget.factory['prodItem'];
    if (prodEnd == null || prodItem == null) return 0;
    try {
      final end = _srvUtc(prodEnd);
      final now = DateTime.now();
      if (now.isAfter(end)) return 1.0;
      if (prodStart != null) {
        final start = _srvUtc(prodStart);
        final totalSecs = end.difference(start).inSeconds;
        if (totalSecs <= 0) return 1.0;
        final elapsed = now.difference(start).inSeconds;
        return (elapsed / totalSecs).clamp(0.0, 1.0);
      }
      // Fallback: estimate from batch count (no booster correction)
      final ft = kFactoryTypes[widget.factory['itemID'] as int? ?? 0];
      if (ft == null) return 0;
      final level = (widget.factory['lvl'] as num? ?? 1).toInt();
      final levelMult = level.toDouble();
      final batches = ((widget.factory['prodAmt'] as num? ?? 1) / (ft['out'] as num)).ceil();
      final totalSecs = (ft['hrs'] as int) * batches / levelMult * 3600;
      if (totalSecs <= 0) return 0;
      return (1.0 - end.difference(now).inSeconds / totalSecs).clamp(0.0, 1.0);
    } catch (_) { return 0; }
  }

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
  );
}

class _CatalogTile extends StatelessWidget {
  final dynamic item;
  final dynamic player;
  final VoidCallback onBuy;
  const _CatalogTile({required this.item, required this.player, required this.onBuy});

  @override
  Widget build(BuildContext context) {
    final name = item['name'] as String;
    final cost = (item['cost'] as num).toInt();
    final produces = item['produces'] as int;
    final minLvl = item['minLvl'] as int;
    final needs = item['needs'] as Map<String, dynamic>? ?? {};
    final buildRes = item['buildRes'] as Map<String, dynamic>? ?? {};
    final lager = (player?.lager as Map<String, double>?) ?? {};
    final playerLevel = player?.level ?? 1;
    final credits = player?.credits ?? 0;

    final levelOk = playerLevel >= minLvl;
    final creditsOk = credits >= cost;
    final resOk = buildRes.entries.every((e) =>
        (lager[e.key] ?? 0) >= (e.value as num).toDouble());
    final canBuild = levelOk && creditsOk && resOk;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold))),
            if (!levelOk)
              Text('Lv $minLvl required',
                  style: const TextStyle(color: Colors.red, fontSize: 11)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            if (resImagePath(produces) != null)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: SizedBox(width: 16, height: 16,
                    child: Image.asset(resImagePath(produces)!, fit: BoxFit.contain)),
              ),
            Text('Produces: ${itemName(produces)}',
                style: TextStyle(color: AppColors.t54, fontSize: 12)),
          ]),
          if (needs.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Input per batch:', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8, runSpacing: 4,
              children: needs.entries.map((e) {
                final id = int.tryParse(e.key) ?? 0;
                final imgPath = resImagePath(id);
                return Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    width: 16, height: 16,
                    child: imgPath != null
                        ? Image.asset(imgPath, fit: BoxFit.contain)
                        : Icon(Icons.inventory_2_outlined, size: 14, color: AppColors.t38),
                  ),
                  const SizedBox(width: 4),
                  Text('${e.value} ${itemName(id)}',
                      style: TextStyle(fontSize: 11, color: AppColors.t54)),
                ]);
              }).toList(),
            ),
          ],
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _costRow('1', fmtNum(cost), creditsOk),
              ...buildRes.entries.map((e) {
                final have = (lager[e.key] ?? 0);
                final need = (e.value as num).toDouble();
                final ok = have >= need;
                return _costRow(e.key, fmtNum(need), ok);
              }),
            ])),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: canBuild ? onBuy : null,
              child: const Text('Build'),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _costRow(String itemIdStr, String qty, bool ok) {
    final id = int.tryParse(itemIdStr) ?? 0;
    final imgPath = id == 1 ? 'assets/images_res/res1.png' : resImagePath(id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(children: [
        SizedBox(
          width: 18, height: 18,
          child: imgPath != null
              ? Image.asset(imgPath, fit: BoxFit.contain,
                  color: ok ? null : Colors.red.withValues(alpha: 0.8),
                  colorBlendMode: ok ? null : BlendMode.modulate)
              : Icon(Icons.monetization_on, size: 14,
                    color: ok ? Colors.amber : Colors.red),
        ),
        const SizedBox(width: 4),
        Text(qty,
            style: TextStyle(
                fontSize: 11,
                color: ok ? AppColors.t70 : Colors.red,
                fontWeight: ok ? FontWeight.normal : FontWeight.bold)),
      ]),
    );
  }
}

class _StartProdSheet extends StatefulWidget {
  final dynamic factory;
  final dynamic catalogEntry;
  final dynamic player;
  const _StartProdSheet(
      {required this.factory, required this.catalogEntry, required this.player});
  @override
  State<_StartProdSheet> createState() => _StartProdSheetState();
}

class _StartProdSheetState extends State<_StartProdSheet> {
  int _batches = 1;
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _batches = max(1, _maxBatches > 0 ? _maxBatches : 1);
    _ctrl = TextEditingController(text: '$_batches');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Map<String, double> get _lager =>
      (widget.player?.lager as Map<String, double>?) ?? {};
  int get _whCap => widget.player?.whCap ?? 5000;
  Map<String, dynamic> get _needs =>
      widget.catalogEntry['needs'] as Map<String, dynamic>? ?? {};
  int get _outRaw => widget.catalogEntry['out'] as int? ?? 1;
  int get _hrs => widget.catalogEntry['hrs'] as int? ?? 1;
  int get _producesId => widget.catalogEntry['produces'] as int? ?? 0;
  int get _level => (widget.factory['lvl'] as num? ?? 1).toInt();
  double get _levelMult => _level.toDouble();
  double get _outPerBatch => _outRaw.toDouble();  // output fixed; level only reduces time
  double get _hrsPerBatch => _hrs / _levelMult;   // level speeds up production

  int get _maxFromRes {
    if (_needs.isEmpty) return 999999;
    int m = 999999;
    for (final e in _needs.entries) {
      final perBatch = (e.value as num).toInt();
      final have = (_lager[e.key] ?? 0).floor();
      if (perBatch > 0) m = min(m, have ~/ perBatch);
    }
    return m;
  }

  int get _maxFromWh {
    final current = _lager[_producesId.toString()] ?? 0;
    final remaining = (_whCap - current).clamp(0, _whCap.toDouble());
    if (_outPerBatch <= 0) return 999999;
    return (remaining / _outPerBatch).floor();
  }

  int get _maxBatches => min(_maxFromRes, _maxFromWh).clamp(0, 999999);

  String _fmtHrs(double h) {
    if (h < 1) return '${(h * 60).round()}m';
    final hi = h.floor();
    final mi = ((h - hi) * 60).round();
    return mi == 0 ? '${hi}h' : '${hi}h ${mi}m';
  }

  void _setBatches(int v) {
    final clamped = v.clamp(1, max(1, _maxBatches)) as int;
    setState(() => _batches = clamped);
    if (_ctrl.text != '$clamped') {
      _ctrl.text = '$clamped';
      _ctrl.selection = TextSelection.fromPosition(
          TextPosition(offset: _ctrl.text.length));
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = kFactoryNames[widget.factory['itemID'] as int? ?? 0] ?? 'Factory';
    final totalOut = _outPerBatch * _batches;
    final current = _lager[_producesId.toString()] ?? 0;
    final whFreeAfter = _whCap - current - totalOut;
    final whWarning = whFreeAfter < 0;
    final canStart = _maxBatches >= 1 && _batches >= 1 && _batches <= _maxBatches;

    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        const Text('Start Production',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        Text(name, style: TextStyle(color: AppColors.t54, fontSize: 12)),
        const SizedBox(height: 16),

        if (_needs.isNotEmpty) ...[
          Text('Required per batch:',
              style: TextStyle(color: AppColors.t38, fontSize: 11)),
          const SizedBox(height: 6),
          ..._needs.entries.map((e) {
            final id = int.tryParse(e.key) ?? 0;
            final perBatch = (e.value as num).toInt();
            final totalNeed = perBatch * _batches;
            final have = (_lager[e.key] ?? 0).floor();
            final ok = have >= totalNeed;
            final imgPath = resImagePath(id);
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                SizedBox(
                  width: 32, height: 32,
                  child: imgPath != null
                      ? Image.asset(imgPath, fit: BoxFit.contain)
                      : CircleAvatar(
                          radius: 16,
                          backgroundColor: AppColors.accentDeep,
                          child: Text('$id', style: const TextStyle(fontSize: 9))),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(itemName(id), style: const TextStyle(fontSize: 12))),
                Text(
                  '$totalNeed / $have',
                  style: TextStyle(
                      fontSize: 12,
                      color: ok ? AppColors.t54 : Colors.red,
                      fontWeight: ok ? FontWeight.normal : FontWeight.bold),
                ),
              ]),
            );
          }),
          const Divider(height: 16),
        ],

        // Output line
        Row(children: [
          SizedBox(
            width: 32, height: 32,
            child: resImagePath(_producesId) != null
                ? Image.asset(resImagePath(_producesId)!, fit: BoxFit.contain)
                : Icon(Icons.inventory_2_outlined, color: AppColors.accent),
          ),
          const SizedBox(width: 8),
          Text(
            '${fmtNum(totalOut)} ${itemName(_producesId)}  â€¢  ${_fmtHrs(_hrsPerBatch * _batches)}',
            style: TextStyle(color: AppColors.accent, fontSize: 12),
          ),
          const Spacer(),
          TextButton(
            onPressed: _maxBatches > 0 ? () => _setBatches(_maxBatches) : null,
            child: const Text('Max', style: TextStyle(fontSize: 12)),
          ),
        ]),
        const SizedBox(height: 12),

        // Batch input row
        if (_maxBatches == 0)
          const Text('Not enough resources or warehouse full',
              style: TextStyle(color: Colors.red, fontSize: 11))
        else
          Row(children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: _batches > 1 ? () => _setBatches(_batches - 1) : null,
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_double_arrow_left, size: 18),
              onPressed: _batches > 1 ? () => _setBatches(max(1, _batches - 10)) : null,
              tooltip: '-10',
            ),
            Expanded(
              child: TextField(
                controller: _ctrl,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  labelText: 'Batches',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 1) setState(() => _batches = n);
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_double_arrow_right, size: 18),
              onPressed: _batches < _maxBatches ? () => _setBatches(min(_maxBatches, _batches + 10)) : null,
              tooltip: '+10',
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: _batches < _maxBatches ? () => _setBatches(_batches + 1) : null,
            ),
          ]),

        if (whWarning) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 14),
              const SizedBox(width: 6),
              Expanded(child: Text(
                'Warehouse full â€” ${fmtNum(-whFreeAfter)} units excess will be lost',
                style: const TextStyle(color: Colors.orange, fontSize: 11),
              )),
            ]),
          ),
        ],
        const SizedBox(height: 12),

        Row(children: [
          TextButton(
              onPressed: () => popIfCurrent(context),
              child: const Text('Cancel')),
          const Spacer(),
          FilledButton(
            onPressed: canStart ? () => popIfCurrent(context, _batches) : null,
            child: const Text('Start'),
          ),
        ]),
      ]),
    );
  }
}

class _BoostSheet extends StatelessWidget {
  final dynamic factory;
  final dynamic player;
  final bool isProducing;
  final bool hasActiveBooster;
  final VoidCallback? onDiamondBoost;
  final void Function(int itemId)? onBooster;
  const _BoostSheet({
    required this.factory, required this.player,
    required this.isProducing, required this.hasActiveBooster,
    required this.onDiamondBoost, required this.onBooster,
  });

  static String _diamondSubtitle(bool onCooldown, dynamic factory, double out7days) {
    if (onCooldown) {
      final cu = factory['cooldownUntil'] as String?;
      if (cu != null) {
        final rem = _srvUtcOpt(cu)?.difference(DateTime.now());
        if (rem != null && !rem.isNegative) {
          final d = rem.inDays;
          final h = rem.inHours % 24;
          return 'Boost on cooldown  â€¢  ${d}d ${h}h remaining';
        }
      }
      return 'Boost on cooldown';
    }
    return 'Instantly collect ~${fmtNum(out7days)} units (7-day output)  â€¢  ${_fmtDays(kBoostCooldownDays)} cooldown';
  }

  @override
  Widget build(BuildContext context) {
    final lager = (player?.lager as Map<String, double>?) ?? {};
    final ft = kFactoryTypes[factory['itemID'] as int? ?? 0];
    final level = (factory['lvl'] as num? ?? 1).toInt();
    final levelMult = level.toDouble();
    final baseOut = ft?['out'] as int? ?? 0;
    final baseHrs = ft?['hrs'] as int? ?? 1;
    final out7days = baseOut * (7 * 24 / baseHrs) * levelMult;
    final onCooldown = factory['cooldownUntil'] != null;
    final whCap = player?.whCap ?? 5000;
    final producesId = ft?['produces'] as int?;
    final currentOut = producesId != null ? (lager[producesId.toString()] ?? 0) : 0.0;
    final gdExcess = (currentOut + out7days - whCap).clamp(0, double.infinity);
    final boosterItem = factory['boosterItem'] as int?;
    final boosterUntil = factory['boosterUntil'] as String?;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Factory Boost', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        if (!isProducing) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8)),
            child: const Row(children: [
              Icon(Icons.info_outline, color: Colors.orange, size: 16),
              SizedBox(width: 8),
              Text('Start production first to activate boosts',
                  style: TextStyle(color: Colors.orange, fontSize: 12)),
            ]),
          ),
        ],
        const SizedBox(height: 16),

        // Diamond boost
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: (() {
            final lager2 = (player?.lager as Map<String, double>?) ?? {};
            final hasDiamond = (lager2['42'] ?? 0) >= 1;
            ColorFilter filter;
            if (onCooldown) {
              filter = ColorFilter.mode(Colors.red.withValues(alpha: 0.55), BlendMode.srcATop);
            } else if (!hasDiamond) {
              filter = const ColorFilter.matrix([
                0.3,0,0,0,0, 0,0.3,0,0,0, 0,0,0.3,0,0, 0,0,0,0.6,0]);
            } else {
              filter = const ColorFilter.mode(Colors.transparent, BlendMode.dst);
            }
            return ColorFiltered(
              colorFilter: filter,
              child: Image.asset('assets/images/3x/diamondbutton.png', width: 40, height: 40),
            );
          })(),
          title: Text('Giant Diamond',
              style: TextStyle(
                  color: (onCooldown || !isProducing) ? AppColors.t38 : Colors.white,
                  fontWeight: FontWeight.bold)),
          subtitle: Text(_diamondSubtitle(onCooldown, factory, out7days),
              style: const TextStyle(fontSize: 11)),
          trailing: onDiamondBoost != null
              ? FilledButton(onPressed: onDiamondBoost, child: const Text('Use'))
              : null,
        ),
        if (!onCooldown && isProducing && gdExcess > 0)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 14),
              const SizedBox(width: 6),
              Expanded(child: Text(
                'Warehouse warning: ${fmtNum(gdExcess)} units will be lost',
                style: const TextStyle(color: Colors.orange, fontSize: 11),
              )),
            ]),
          ),
        const Divider(),
        Text('Production Boosters', style: TextStyle(color: AppColors.t38, fontSize: 11)),
        const SizedBox(height: 8),
        ...kWaBoosters.entries.map((entry) {
          final id = entry.key;
          final b = entry.value;
          final qty = (lager[id.toString()] ?? 0).floor();
          final waDelta = b['waDelta'] as int;
          final boost = b['boost'] as double;
          final pct = ((boost - 1) * 100).round();
          final isActiveThis = hasActiveBooster && boosterItem == id &&
              boosterUntil != null &&
              _srvUtcOpt(boosterUntil)?.isAfter(DateTime.now()) == true;
          final canUse = onBooster != null && qty > 0 && !isActiveThis;
          return ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: SizedBox(width: 36, height: 36,
                child: resImagePath(id) != null
                    ? Image.asset(resImagePath(id)!, fit: BoxFit.contain)
                    : const Icon(Icons.work_outline, color: Colors.amber)),
            title: Text(b['name'] as String,
                style: TextStyle(color: isActiveThis ? Colors.green : null)),
            subtitle: Text('+$pct% output  â€¢  WA ${waDelta >= 0 ? '+' : ''}$waDelta  â€¢  8h',
                style: const TextStyle(fontSize: 10)),
            trailing: SizedBox(
              width: 80,
              child: isActiveThis
                ? FilledButton.tonal(
                    onPressed: null,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1A3A3A),
                      disabledBackgroundColor: const Color(0xFF1E4040),
                      disabledForegroundColor: const Color(0xFF4DD0C4),
                      minimumSize: const Size(80, 36),
                    ),
                    child: const Text('Active', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)))
                : FilledButton.tonal(
                    onPressed: canUse ? () async {
                      final confirm = await showAppDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: Text(b['name'] as String),
                          content: Column(mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('This will provide a +$pct% output boost for 8 hours.',
                                style: const TextStyle(fontSize: 13)),
                            const SizedBox(height: 8),
                            Row(children: [
                              Icon(Icons.people,
                                  size: 14,
                                  color: waDelta >= 0 ? Colors.greenAccent : Colors.redAccent),
                              const SizedBox(width: 6),
                              Text('Working Atmosphere: ${waDelta >= 0 ? '+' : ''}$waDelta',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: waDelta >= 0 ? Colors.greenAccent : Colors.redAccent,
                                  )),
                            ]),
                            const SizedBox(height: 16),
                            Row(children: [
                              Expanded(child: OutlinedButton(
                                onPressed: () => popIfCurrent(_, false),
                                child: const Text('Cancel'),
                              )),
                              const SizedBox(width: 12),
                              Expanded(child: FilledButton(
                                onPressed: () => popIfCurrent(_, true),
                                child: const Text('Confirm'),
                              )),
                            ]),
                          ]),
                        ),
                      );
                      if (confirm == true) onBooster!(id);
                    } : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: qty > 0
                          ? Colors.green.withValues(alpha: 0.25)
                          : null,
                      foregroundColor: qty > 0 ? Colors.greenAccent : null,
                      minimumSize: const Size(80, 36),
                    ),
                    child: const Text('Use')),
            ),
          );
        }),
      ]),
    );
  }
}
