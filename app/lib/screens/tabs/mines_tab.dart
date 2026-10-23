import 'dart:math' show min;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/player.dart';
import '../../models/player_provider.dart';
import '../../services/api_service.dart';
import '../../constants.dart';
import '../../widgets/top_banner.dart';

import '../../app_colors.dart';
import '../../widgets/popups.dart';
import '../../widgets/hold_button.dart';
// ── Sort / view helpers ─────────────────────────────────────────────────────

enum _SortMode { output, quality, condition }
enum _ViewMode  { category, flat }

String _sortLabel(_SortMode m) => switch (m) {
  _SortMode.output    => 'Output',
  _SortMode.quality   => 'Quality',
  _SortMode.condition => 'Condition',
};

List<Mine> _sortMines(List<Mine> mines, _SortMode mode, bool asc) {
  final list = List<Mine>.from(mines);
  switch (mode) {
    case _SortMode.output:
      list.sort((a, b) => asc ? a.rateHr.compareTo(b.rateHr) : b.rateHr.compareTo(a.rateHr));
    case _SortMode.quality:
      list.sort((a, b) => asc ? a.quality.compareTo(b.quality) : b.quality.compareTo(a.quality));
    case _SortMode.condition:
      list.sort((a, b) => asc ? a.condition.compareTo(b.condition) : b.condition.compareTo(a.condition));
  }
  return list;
}

int _mineRefund(Mine m)     => ((kMineBuildCost[m.itemId] ?? 0) * 0.1).round();
/// Server-calculated repair cost (see repair_cost_of in server/main.py).
int _mineRepairCost(Mine m) => m.repairCost;

// ── MinesTab ────────────────────────────────────────────────────────────────

class MinesTab extends StatefulWidget {
  const MinesTab({super.key});
  @override
  State<MinesTab> createState() => _MinesTabState();
}

class _MinesTabState extends State<MinesTab> {
  _ViewMode         _viewMode    = _ViewMode.category;
  _SortMode         _sort        = _SortMode.output;
  bool              _sortAsc     = false;
  final Set<int>    _expandedIds = {};
  bool              _massMode    = false;
  final Set<String> _selected    = {};
  bool              _bulkBusy    = false;
  bool              _isDragSelecting = false;
  bool              _dragSelectAdd   = true;
  final Map<String, GlobalKey> _tileKeys = {};
  final GlobalKey   _sortBtnKey  = GlobalKey();
  double            _selectThreshold = 100.0;
  bool              _popupOpen   = false;
  List<String>      _frozenMineOrder = [];

  void _toggleMassMode() => setState(() {
    _massMode = !_massMode;
    _selected.clear();
    _isDragSelecting = false;
    _selectThreshold = 100.0;
  });

  Future<void> _showSortMenu(BuildContext context) async {
    final box = _sortBtnKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos    = box.localToGlobal(Offset.zero);
    final w      = box.size.width;
    final screenW = MediaQuery.of(context).size.width;
    final result = await showMenu<_SortMode>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + box.size.height + 2,
        screenW - pos.dx - w,
        0,
      ),
      constraints: BoxConstraints.tightFor(width: w),
      items: _SortMode.values.map((m) => PopupMenuItem(
        value: m,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          Expanded(child: Text(_sortLabel(m),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: _sort == m ? AppColors.accent : Colors.white,
                fontWeight: _sort == m ? FontWeight.bold : FontWeight.normal,
              ))),
          if (_sort == m)
            Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                size: 13, color: AppColors.accent)
          else
            const SizedBox(width: 13),
        ]),
      )).toList(),
    );
    if (result != null && mounted) {
      setState(() {
        if (_sort == result) { _sortAsc = !_sortAsc; }
        else { _sort = result; _sortAsc = false; }
      });
    }
  }

  GlobalKey _keyFor(String mineId) =>
      _tileKeys.putIfAbsent(mineId, () => GlobalKey());

  void _onTileDragStart(String mineId, bool add) {
    setState(() {
      _isDragSelecting = true;
      _dragSelectAdd = add;
      add ? _selected.add(mineId) : _selected.remove(mineId);
    });
  }

  void _onTileDragMove(Offset globalPos) {
    for (final entry in _tileKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final tl = box.localToGlobal(Offset.zero);
      if (Rect.fromLTWH(tl.dx, tl.dy, box.size.width, box.size.height).contains(globalPos)) {
        final alreadyIn = _selected.contains(entry.key);
        if (_dragSelectAdd != alreadyIn) {
          setState(() {
            _dragSelectAdd ? _selected.add(entry.key) : _selected.remove(entry.key);
          });
        }
        break;
      }
    }
  }

  void _onTileDragEnd() => setState(() => _isDragSelecting = false);

  void _selectBelowThreshold(List<Mine> pool, int threshold) {
    setState(() {
      for (final m in pool) {
        if (m.condition < threshold) _selected.add(m.id);
      }
    });
  }

  Map<int, List<Mine>> _grouped(List<Mine> mines) {
    final map = <int, List<Mine>>{};
    for (final m in mines) map.putIfAbsent(m.itemId, () => []).add(m);
    return map;
  }

  // ── Bulk actions ──────────────────────────────────────────────────────────

  Future<void> _bulkRepairPay(List<Mine> toRepair) async {
    final cost = toRepair.fold(0, (s, m) => s + _mineRepairCost(m));
    final ok   = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Repair ${toRepair.length} mines?'),
        content: Text('Total cost: ꞓ$cost',
            style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
        actions: [
          TextButton(onPressed: () => popIfCurrent(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => popIfCurrent(context, true), child: const Text('Repair All')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _bulkBusy = true);
    final sid = context.read<PlayerProvider>().sid;
    final ids = [for (final m in toRepair) if (m.condition <= 99) m.id];
    final r = await ApiService.bulkRepairMines(sid, ids, kits: false);
    final repaired = (r?['err'] == 0) ? (r!['repaired'] as num).toInt() : 0;
    final failed = ids.length - repaired;
    if (!mounted) return;
    setState(() { _bulkBusy = false; _massMode = false; _selected.clear(); });
    AppNotify.show(context,
        'Repaired $repaired mine${repaired == 1 ? '' : 's'}${failed > 0 ? ', $failed failed' : ''}');
    context.read<PlayerProvider>()
      ..adjustCredits(((r?['cost'] as num?) ?? 0).toInt())   // show the new balance right away
      ..refresh();
  }

  Future<void> _bulkRepairKit(List<Mine> toRepair, int kitsAvailable) async {
    final needed = toRepair.where((m) => m.condition <= 99).length;
    if (needed == 0) return;
    final actual = min(needed, kitsAvailable);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Use $actual kit${actual == 1 ? '' : 's'}?'),
        content: Text(
          needed > kitsAvailable
              ? 'You have $kitsAvailable kits but $needed mines need repair. Will repair $actual.'
              : 'Repair $actual mine${actual == 1 ? '' : 's'} to 100% condition.',
          style: TextStyle(color: AppColors.t70),
        ),
        actions: [
          TextButton(onPressed: () => popIfCurrent(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => popIfCurrent(context, true), child: const Text('Use Kits')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _bulkBusy = true);
    final sid = context.read<PlayerProvider>().sid;
    final ids = [for (final m in toRepair) if (m.condition <= 99) m.id].take(actual).toList();
    final r = await ApiService.bulkRepairMines(sid, ids, kits: true);
    final repaired = (r?['err'] == 0) ? (r!['repaired'] as num).toInt() : 0;
    if (!mounted) return;
    setState(() { _bulkBusy = false; _massMode = false; _selected.clear(); });
    AppNotify.show(context, 'Repaired $repaired mine${repaired == 1 ? '' : 's'} with kits');
    context.read<PlayerProvider>().refresh();
  }

  Future<void> _bulkDemolish(List<Mine> selected) async {
    final totalRefund  = selected.fold(0, (s, m) => s + _mineRefund(m));
    final hasHighValue = selected.any((m) => m.quality >= 80 || m.hasTech);
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Demolish ${selected.length} mines?'),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (hasHighValue)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: const Row(children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                SizedBox(width: 8),
                Expanded(child: Text('Some selected mines are high quality or tech upgraded.',
                    style: TextStyle(color: Colors.orange, fontSize: 12))),
              ]),
            ),
          Text('Total refund: ꞓ$totalRefund',
              style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('This cannot be undone.',
              style: TextStyle(color: AppColors.t54, fontSize: 12)),
        ]),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => popIfCurrent(context, false),
              child: const Text('Cancel'),
            )),
            const SizedBox(width: 8),
            Expanded(child: selected.length > 1
              ? HoldFilledButton(
                  label: 'Hold to Confirm',
                  onTriggered: () => popIfCurrent(context, true),
                )
              : FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => popIfCurrent(context, true),
                  child: const Text('Demolish'),
                ),
            ),
          ]),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final sid = context.read<PlayerProvider>().sid;
    final r = await ApiService.bulkDemolishMines(sid, selected.map((m) => m.id).toList());
    if (!mounted) return;
    setState(() { _massMode = false; _selected.clear(); });
    if (r == null || r['err'] != 0) {
      AppNotify.show(context, r?['msg'] ?? 'Demolish failed', isError: true);
    } else {
      AppNotify.show(context, 'Demolished ${r['deleted']} mines. Refund: ꞓ${r['refund']}');
      context.read<PlayerProvider>()
        ..adjustCredits(-((r['refund'] as num?) ?? 0).toInt())
        ..refresh();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final prov   = context.watch<PlayerProvider>();
    final player = prov.player;
    if (player == null) return const Center(child: CircularProgressIndicator());

    final loaded = prov.mines;
    if (loaded == null) {
      if (!prov.minesLoading) {
        WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) prov.loadMines(); });
      }
      return const Center(child: CircularProgressIndicator());
    }
    final allMines = loaded;
    if (allMines.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.construction, size: 64, color: Colors.white24),
          SizedBox(height: 16),
          Text('No mines yet.\nGo to the map and tap Scan to find resources.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.t54)),
        ]),
      );
    }

    // While a popup is open, preserve the existing mine order so the list
    // doesn't jump. Mine objects are refreshed in-place so data stays current.
    final sortedFresh = _sortMines(allMines, _sort, _sortAsc);
    if (!_popupOpen) {
      _frozenMineOrder = sortedFresh.map((m) => m.id).toList();
    }
    final mineById = {for (final m in allMines) m.id: m};
    final sorted = _frozenMineOrder
        .map((id) => mineById[id])
        .whereType<Mine>()
        .toList();
    final grouped = _grouped(sorted);

    final selectedMines  = _massMode
        ? allMines.where((m) => _selected.contains(m.id)).toList()
        : <Mine>[];
    final toRepair       = selectedMines.where((m) => m.condition <= 99).toList();
    final repairCost     = toRepair.fold(0, (s, m) => s + _mineRepairCost(m));
    final kitsAvailable  = (player.lager['43'] ?? 0).toInt();
    final totalRefund    = selectedMines.fold(0, (s, m) => s + _mineRefund(m));

    return Stack(children: [
      RefreshIndicator(
        onRefresh: () => prov.refresh(),
        child: CustomScrollView(slivers: [

          // ── Toolbar ────────────────────────────────────────────────
          SliverToBoxAdapter(child: _buildToolbar()),

          // ── Content ────────────────────────────────────────────────
          if (_viewMode == _ViewMode.category)
            ..._categorySliver(grouped, allMines, player)
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _MineTile(
                  mine: sorted[i], player: player,
                  massMode: _massMode,
                  selected: _selected.contains(sorted[i].id),
                  tileKey: _keyFor(sorted[i].id),
                  onSelectionChanged: (v) => setState(() =>
                      v ? _selected.add(sorted[i].id)
                        : _selected.remove(sorted[i].id)),
                  onDragSelectStart: (add) =>
                      _onTileDragStart(sorted[i].id, add),
                  onDragMove: _onTileDragMove,
                  onDragSelectEnd: _onTileDragEnd,
                  onPopupOpened: () => setState(() => _popupOpen = true),
                  onPopupClosed: () => setState(() => _popupOpen = false),
                ),
                childCount: sorted.length,
              ),
            ),

          SliverToBoxAdapter(child: SizedBox(height: _massMode ? 170 : 8)),
        ]),
      ),

      // ── Drag counter overlay ───────────────────────────────────────
      if (_massMode && _isDragSelecting)
        Positioned(
          top: MediaQuery.of(context).padding.top + 56,
          left: 0, right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.93),
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [BoxShadow(
                    color: Colors.black54, blurRadius: 8)],
              ),
              child: Text('${_selected.length} selected',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14)),
            ),
          ),
        ),

      // ── Mass action bar ────────────────────────────────────────────
      if (_massMode)
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: _buildMassBar(selectedMines, toRepair, repairCost,
              kitsAvailable, totalRefund, allMines),
        ),
    ]);
  }

  // ── Toolbar ───────────────────────────────────────────────────────────────

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(children: [
        _viewBtn('Category', _ViewMode.category),
        const SizedBox(width: 4),
        _viewBtn('All', _ViewMode.flat),
        const SizedBox(width: 6),
        GestureDetector(
          key: _sortBtnKey,
          onTap: () => _showSortMenu(context),
          child: Container(
            width: 100,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(children: [
              Expanded(child: Text(_sortLabel(_sort),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: AppColors.t70))),
              Icon(
                _sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                size: 12, color: AppColors.t70,
              ),
            ]),
          ),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: _toggleMassMode,
          icon: Icon(_massMode ? Icons.close : Icons.checklist, size: 14),
          label: Text(_massMode ? 'Cancel' : 'Select',
              style: const TextStyle(fontSize: 11)),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            visualDensity: VisualDensity.compact,
          ),
        ),
      ]),
    );
  }

  Widget _viewBtn(String label, _ViewMode mode) {
    final active = _viewMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _viewMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? AppColors.accent.withValues(alpha: 0.25) : Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: active ? AppColors.accent : Colors.white12),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                color: active ? AppColors.accent : AppColors.t54,
                fontWeight: active ? FontWeight.bold : FontWeight.normal)),
      ),
    );
  }

  // ── Category sliver ────────────────────────────────────────────────────────

  List<Widget> _categorySliver(
      Map<int, List<Mine>> grouped, List<Mine> allMines, Player player) {
    final result = <Widget>[];

    // Categories ordered by the category as a whole (total output / average quality /
    // average condition), not by their single best mine.
    double catValue(List<Mine> ms) => switch (_sort) {
          _SortMode.output    => ms.fold(0.0, (s, m) => s + m.rateHr),
          _SortMode.quality   => ms.fold(0.0, (s, m) => s + m.quality) / ms.length,
          _SortMode.condition => ms.fold(0.0, (s, m) => s + m.condition) / ms.length,
        };
    final cats = grouped.entries.toList()
      ..sort((a, b) => _sortAsc
          ? catValue(a.value).compareTo(catValue(b.value))
          : catValue(b.value).compareTo(catValue(a.value)));
    for (final entry in cats) {
      final itemId    = entry.key;
      final mines     = entry.value;
      final expanded  = _expandedIds.contains(itemId);
      final totalRate = mines.fold(0.0, (s, m) => s + m.rateHr);
      final avgCond   = mines.fold(0.0, (s, m) => s + m.condition) / mines.length;
      final condColor = avgCond > 60
          ? Colors.green : avgCond > 30 ? Colors.orange : Colors.red;
      final imgPath   = resImagePath(kMineResource[itemId] ?? 0);
      final selCount  = mines.where((m) => _selected.contains(m.id)).length;

      // ── Category header ────────────────────────────────────────────
      void selectCategory(bool on) => setState(() {
            for (final m in mines) {
              on ? _selected.add(m.id) : _selected.remove(m.id);
            }
          });
      result.add(SliverToBoxAdapter(
        child: InkWell(
          onTap: () => setState(() =>
              expanded ? _expandedIds.remove(itemId) : _expandedIds.add(itemId)),
          // long-press a category: start selecting and pick all of its mines
          onLongPress: () {
            if (!_massMode) _toggleMassMode();
            selectCategory(true);
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              border: const Border(bottom: BorderSide(color: Colors.white12)),
            ),
            child: Row(children: [
              // Resource icon
              SizedBox(width: 34, height: 34,
                child: imgPath != null
                    ? Image.asset(imgPath, fit: BoxFit.contain)
                    : CircleAvatar(
                        backgroundColor: AppColors.accentDeep,
                        child: Text((kMineNames[itemId] ?? '?')[0],
                            style: const TextStyle(fontSize: 12)))),
              const SizedBox(width: 10),
              // Name + stats
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('${kMineNames[itemId] ?? 'Mine'} (${mines.length})',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  if (_massMode && selCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('$selCount',
                          style: TextStyle(
                              color: AppColors.accent, fontSize: 10)),
                    ),
                  ],
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  Text('${totalRate.toStringAsFixed(0)}/hr',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.greenAccent)),
                  const SizedBox(width: 10),
                  Text('${avgCond.round()}%',
                      style: TextStyle(fontSize: 11, color: condColor)),
                ]),
              ])),
              if (_massMode)
                Tooltip(
                  message: 'Select all ${kMineNames[itemId] ?? 'mines'}',
                  child: Checkbox(
                    tristate: true,
                    value: selCount == 0 ? false : selCount == mines.length ? true : null,
                    onChanged: (_) => selectCategory(selCount < mines.length),
                  ),
                ),
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  color: AppColors.t38, size: 20),
            ]),
          ),
        ),
      ));

      // ── Expanded mine list ─────────────────────────────────────────
      if (expanded) {
        result.add(SliverPadding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _MineTile(
                mine: mines[i], player: player,
                massMode: _massMode,
                selected: _selected.contains(mines[i].id),
                tileKey: _keyFor(mines[i].id),
                onSelectionChanged: (v) => setState(() =>
                    v ? _selected.add(mines[i].id)
                      : _selected.remove(mines[i].id)),
                onDragSelectStart: (add) =>
                    _onTileDragStart(mines[i].id, add),
                onDragMove: _onTileDragMove,
                onDragSelectEnd: _onTileDragEnd,
                onPopupOpened: () => setState(() => _popupOpen = true),
                onPopupClosed: () => setState(() => _popupOpen = false),
              ),
              childCount: mines.length,
            ),
          ),
        ));
      }
    }

    return result;
  }

  // ── Mass action bar ────────────────────────────────────────────────────────

  Widget _buildMassBar(
    List<Mine> selected, List<Mine> toRepair,
    int repairCost, int kitsAvailable, int totalRefund,
    List<Mine> allMines,
  ) {
    final kitCount = min(toRepair.length, kitsAvailable);
    return Container(
      padding: EdgeInsets.fromLTRB(12, 10, 12,
          MediaQuery.of(context).padding.bottom + 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8, offset: const Offset(0, -2))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Row 1: count + clear
        Row(children: [
          Text('${selected.length} selected',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13)),
          if (selected.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text('• ꞓ$totalRefund',
                style: const TextStyle(color: Colors.amber, fontSize: 11)),
          ],
          const Spacer(),
          if (selected.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() {
                _selected.clear();
                _selectThreshold = 100.0;
              }),
              child: Text('Clear',
                  style: TextStyle(color: AppColors.t38, fontSize: 11)),
            ),
        ]),
        // Condition threshold slider
        Row(children: [
          Text('30%', style: TextStyle(color: AppColors.t38, fontSize: 11)),
          Expanded(
            child: Slider(
              value: _selectThreshold,
              min: 30, max: 100, divisions: 70,
              activeColor: Colors.orange,
              inactiveColor: Colors.white12,
              label: _selectThreshold >= 100
                  ? 'All (≤100%)'
                  : '≤${_selectThreshold.round()}%',
              onChanged: (v) => setState(() {
                _selectThreshold = v;
                _selected.clear();
                for (final m in allMines) {
                  if (m.condition <= v.round()) _selected.add(m.id);
                }
              }),
            ),
          ),
          Text('100%', style: TextStyle(color: AppColors.t38, fontSize: 11)),
        ]),
        const SizedBox(height: 8),
        // Row 2: action buttons
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            icon: const Icon(Icons.build, size: 13),
            label: Text('Repair ꞓ$repairCost',
                style: const TextStyle(fontSize: 11),
                overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(
              foregroundColor: toRepair.isNotEmpty
                  ? Colors.orange : Colors.white24,
              side: BorderSide(color: toRepair.isNotEmpty
                  ? Colors.orange.withValues(alpha: 0.5) : Colors.white12),
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 6),
            ),
            onPressed: (toRepair.isNotEmpty && !_bulkBusy)
                ? () => _bulkRepairPay(toRepair) : null,
          )),
          const SizedBox(width: 6),
          Expanded(child: OutlinedButton.icon(
            icon: const Icon(Icons.construction, size: 13),
            label: Text('Kits ×$kitCount',
                style: const TextStyle(fontSize: 11)),
            style: OutlinedButton.styleFrom(
              foregroundColor: (toRepair.isNotEmpty && kitsAvailable > 0)
                  ? Colors.deepOrange : Colors.white24,
              side: BorderSide(color:
                  (toRepair.isNotEmpty && kitsAvailable > 0)
                  ? Colors.deepOrange.withValues(alpha: 0.5)
                  : Colors.white12),
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 6),
            ),
            onPressed: (toRepair.isNotEmpty && kitsAvailable > 0 && !_bulkBusy)
                ? () => _bulkRepairKit(toRepair, kitsAvailable) : null,
          )),
          const SizedBox(width: 6),
          Expanded(child: OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline, size: 13),
            label: Text('Demolish ${selected.length}',
                style: const TextStyle(fontSize: 11),
                overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(
              foregroundColor: selected.isNotEmpty && !_bulkBusy
                  ? Colors.red : Colors.white24,
              side: BorderSide(color: selected.isNotEmpty && !_bulkBusy
                  ? Colors.red.withValues(alpha: 0.5) : Colors.white12),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            ),
            onPressed: (selected.isNotEmpty && !_bulkBusy)
                ? () => _bulkDemolish(selected) : null,
          )),
        ]),
      ]),
    );
  }
}

// ── _MineTile ───────────────────────────────────────────────────────────────

class _MineTile extends StatefulWidget {
  final Mine mine;
  final Player player;
  final bool massMode;
  final bool selected;
  final ValueChanged<bool> onSelectionChanged;
  final GlobalKey? tileKey;
  final void Function(bool add)? onDragSelectStart;
  final void Function(Offset globalPos)? onDragMove;
  final VoidCallback? onDragSelectEnd;
  final VoidCallback? onPopupOpened;
  final VoidCallback? onPopupClosed;
  const _MineTile({
    required this.mine, required this.player,
    required this.massMode, required this.selected,
    required this.onSelectionChanged,
    this.tileKey, this.onDragSelectStart,
    this.onDragMove, this.onDragSelectEnd,
    this.onPopupOpened, this.onPopupClosed,
  });
  @override
  State<_MineTile> createState() => _MineTileState();
}

class _MineTileState extends State<_MineTile> {
  bool _busy = false;

  Mine   get mine   => widget.mine;
  Player get player => widget.player;

  Color get _condColor =>
      mine.condition > 60 ? Colors.green
      : mine.condition > 30 ? Colors.orange : Colors.red;

  String get _mineName => kMineNames[mine.itemId] ?? 'Mine';
  String get _resName  => kItemNames[mine.resId]  ?? 'Resource';

  bool get _hasKit => (player.lager['43'] ?? 0) >= 1;

  int? get _activeTuLevel {
    if (mine.tu1 < 100) return 1;
    if (mine.tu2 < 100) return 2;
    if (mine.tu3 < 100) return 3;
    if (mine.tu4 < 100) return 4;
    return null;
  }

  Widget _condBar({double height = 4}) => ClipRRect(
    borderRadius: BorderRadius.circular(height / 2),
    child: LinearProgressIndicator(
      value: mine.condition / 100.0,
      backgroundColor: Colors.white12,
      valueColor: AlwaysStoppedAnimation(_condColor),
      minHeight: height,
    ),
  );

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await fn(); } finally { if (mounted) setState(() => _busy = false); }
  }

  void _snack(String msg, {bool error = false}) =>
      AppNotify.show(context, msg, isError: error);

  Future<void> _repairPay() => _run(() async {
    final sid = context.read<PlayerProvider>().sid;
    final r   = await ApiService.repairMinePay(sid, mine.id);
    if (!mounted) return;
    if (r == null || r['err'] != 0) {
      _snack(r?['msg'] ?? 'Repair failed');
    } else {
      _snack('Repaired! Cost: ꞓ${r['cost']}');
      context.read<PlayerProvider>()
        ..adjustCredits(((r['cost'] as num?) ?? 0).toInt())
        ..refresh();
    }
  });

  Future<void> _repairKit() => _run(() async {
    final sid = context.read<PlayerProvider>().sid;
    final r   = await ApiService.repairMineKit(sid, mine.id);
    if (!mounted) return;
    if (r == null || r['err'] != 0) {
      _snack(r?['msg'] ?? 'Kit repair failed');
    } else {
      _snack('Repaired with kit!');
      context.read<PlayerProvider>().refresh();
    }
  });

  void _openTechSheet() {
    widget.onPopupOpened?.call();
    showAppSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => TechUpgradeSheet(
        mine: mine, player: player,
        onDone: () => context.read<PlayerProvider>().refresh(),
      ),
    ).then((_) {
      if (mounted) widget.onPopupClosed?.call();
    });
  }

  Future<void> _demolish() => _run(() async {
    final refund     = _mineRefund(mine);
    final isHighValue = mine.quality >= 80 || mine.hasTech;
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Demolish mine?'),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (isHighValue)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: const Row(children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                SizedBox(width: 8),
                Expanded(child: Text('This mine has high quality or tech upgrades!',
                    style: TextStyle(color: Colors.orange, fontSize: 12))),
              ]),
            ),
          Text('Refund: ꞓ$refund',
              style: const TextStyle(
                  color: Colors.amber, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('This cannot be undone.',
              style: TextStyle(color: AppColors.t54, fontSize: 12)),
        ]),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => popIfCurrent(context, false),
              child: const Text('Cancel'),
            )),
            const SizedBox(width: 8),
            Expanded(child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => popIfCurrent(context, true),
              child: const Text('Demolish'),
            )),
          ]),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final sid = context.read<PlayerProvider>().sid;
    final r   = await ApiService.demolishMine(sid, mine.id);
    if (!mounted) return;
    if (r == null || r['err'] != 0) {
      _snack('Demolish failed');
    } else {
      _snack('Demolished. Refund: ꞓ${r['refund']}');
      context.read<PlayerProvider>().refresh();
    }
  });

  @override
  Widget build(BuildContext context) {
    final techBonus    = mine.techBoostPct;
    final effectiveRate = mine.rateHr > 0
        ? mine.rateHr
        : (kMineBaseRate[mine.itemId] ?? 0) *
            (mine.quality / 100) *
            (mine.condition / 100) *
            (1 + techBonus / 100) *
            mine.level.toDouble();

    if (widget.massMode) {
      final tile = CheckboxListTile(
        value: widget.selected,
        onChanged: (v) => widget.onSelectionChanged(v ?? false),
        title: Text(_mineName),
        subtitle: Row(children: [
          _badge('${mine.conditionPct}%', _condColor),
          const SizedBox(width: 6),
          _badge('Q${fmtQual(mine.quality)}', Colors.amber),
          if (mine.hasTech) ...[const SizedBox(width: 6),
            _badge('+${mine.techBoostPct}%', Colors.purpleAccent)],
        ]),
        secondary: Column(mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('Lv ${mine.level}',
              style: TextStyle(fontSize: 11, color: AppColors.t54)),
          Text('ꞓ${_mineRefund(mine)}',
              style: const TextStyle(fontSize: 11, color: Colors.amber)),
        ]),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      );
      return GestureDetector(
        key: widget.tileKey,
        behavior: HitTestBehavior.opaque,
        onLongPressStart: widget.onDragSelectStart != null
            ? (d) => widget.onDragSelectStart!(!widget.selected)
            : null,
        onLongPressMoveUpdate: widget.onDragMove != null
            ? (d) => widget.onDragMove!(d.globalPosition)
            : null,
        onLongPressEnd: widget.onDragSelectEnd != null
            ? (_) => widget.onDragSelectEnd!()
            : null,
        child: tile,
      );
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: ExpansionTile(
        leading: resImagePath(mine.resId) != null
            ? SizedBox(width: 40, height: 40,
                child: Image.asset(resImagePath(mine.resId)!, fit: BoxFit.contain))
            : CircleAvatar(backgroundColor: AppColors.accentDeep,
                child: Text(_resName[0],
                    style: const TextStyle(color: Colors.white))),
        title: Text(_mineName),
        subtitle: Row(children: [
          _badge('${mine.conditionPct}%', _condColor),
          const SizedBox(width: 6),
          _badge('Q${fmtQual(mine.quality)}', Colors.amber),
          if (mine.hasTech) ...[const SizedBox(width: 6),
            _badge('+${mine.techBoostPct}%', Colors.purpleAccent)],
          if (mine.isSick) ...[const SizedBox(width: 6),
            _badge('SICK', Colors.redAccent)],
          if (mine.hqBoost != null) ...[const SizedBox(width: 6),
            _badge('HQ×${mine.hqBoost!.toStringAsFixed(1)}', AppColors.accent)],
        ]),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${effectiveRate.toStringAsFixed(1)}/hr',
              style: const TextStyle(fontSize: 11, color: Colors.greenAccent)),
        ]),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Divider(height: 1),
              const SizedBox(height: 10),
              _statsGrid(effectiveRate, techBonus),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _ActionBtn(
                  icon: Icons.build,
                  label: 'Repair (ꞓ${_repairCost()})',
                  color: Colors.orange,
                  busy: _busy,
                  onTap: mine.condition <= 99 ? _repairPay : null,
                )),
                const SizedBox(width: 8),
                Expanded(child: _ActionBtn(
                  icon: Icons.construction,
                  label: _hasKit ? 'Use Maintenance Kit' : 'No Kits',
                  color: Colors.deepOrange,
                  busy: _busy,
                  onTap: _hasKit && mine.condition <= 99 ? _repairKit : null,
                )),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _ActionBtn(
                  icon: Icons.settings_suggest,
                  label: _activeTuLevel == null
                      ? 'Max Tech (+500%)'
                      : 'Tech +${mine.techBoostPct}%',
                  color: Colors.purple,
                  busy: _busy,
                  onTap: _openTechSheet,
                )),
                const SizedBox(width: 8),
                Expanded(child: _ActionBtn(
                  icon: Icons.delete_outline,
                  label: 'Demolish (ꞓ${_mineRefund(mine)})',
                  color: Colors.red,
                  busy: _busy,
                  onTap: _demolish,
                )),
              ]),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _statsGrid(double rate, int techBonus) => Column(children: [
    Row(children: [
      _statCell('Rate', '${rate.toStringAsFixed(1)}/hr', Colors.greenAccent),
      _statCell('Quality', fmtQual(mine.quality), Colors.amber),
      _statCell('Condition', '${mine.conditionPct}%', _condColor),
      _statCell('Tech', '+$techBonus%', Colors.purpleAccent),
    ]),
    const SizedBox(height: 8),
    _condBar(height: 8),
    const SizedBox(height: 2),
    const Align(
      alignment: Alignment.centerLeft,
      child: Text('−4%/day  •  auto-demolish at 20%',
          style: TextStyle(color: Colors.white24, fontSize: 9)),
    ),
    if (mine.hqBoost != null) ...[
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Icon(Icons.location_city_outlined,
              color: AppColors.accent, size: 14),
          const SizedBox(width: 6),
          Text('HQ boost ×${mine.hqBoost!.toStringAsFixed(1)} active',
              style: TextStyle(color: AppColors.accent, fontSize: 11)),
        ]),
      ),
    ],
    if (mine.isSick) ...[
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Row(children: [
          Icon(Icons.coronavirus_outlined, color: Colors.redAccent, size: 14),
          SizedBox(width: 6),
          Expanded(child: Text('Employees sick  −50% output for 2 weeks',
              style: TextStyle(color: Colors.redAccent, fontSize: 11))),
        ]),
      ),
    ],
  ]);

  Widget _statCell(String label, String value, Color color) => Expanded(
    child: Column(children: [
      Text(value,
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 13)),
      Text(label,
          style: TextStyle(color: AppColors.t38, fontSize: 10)),
    ]),
  );

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4)),
    child: Text(text, style: TextStyle(color: color, fontSize: 11)),
  );

  int _repairCost() => mine.repairCost;
}

// ── TechUpgradeSheet (shared by Mines tab and map mine sheet) ───────────────────────────────────────────────────────

class TechUpgradeSheet extends StatefulWidget {
  final Mine mine;
  final Player player;
  final VoidCallback onDone;
  const TechUpgradeSheet(
      {required this.mine, required this.player, required this.onDone});
  @override
  State<TechUpgradeSheet> createState() => TechUpgradeSheetState();
}

class TechUpgradeSheetState extends State<TechUpgradeSheet> {
  static const _tuItems  = {1: 44, 2: 45, 3: 46, 4: 48};
  static const _tuNames  = {
    1: 'Tech Upgrade I', 2: 'Tech Upgrade II',
    3: 'Tech Upgrade III', 4: 'Tech Upgrade IV'
  };
  static const _tuBoosts = {1: 100, 2: 200, 3: 350, 4: 500};

  bool _busy = false;
  late int _addAmount;
  late int _tu1, _tu2, _tu3, _tu4;
  late Map<int, int> _localStock;

  int _tuCurrent(int level) => switch (level) {
    1 => _tu1, 2 => _tu2, 3 => _tu3, _ => _tu4,
  };

  int _stock(int level) => _localStock[level] ?? 0;

  int get _activeLevel {
    if (_tu1 < 100) return 1;
    if (_tu2 < 100) return 2;
    if (_tu3 < 100) return 3;
    if (_tu4 < 100) return 4;
    return 0;
  }

  double _totalBoostAt(int tu1, int tu2, int tu3, int tu4) =>
      (tu1 * 1.0 + tu2 * 1.0 + tu3 * 1.5 + tu4 * 1.5);

  double get _currentBoost => _totalBoostAt(_tu1, _tu2, _tu3, _tu4);

  double _previewBoost(int amount) {
    final lv = _activeLevel;
    if (lv == 0) return _currentBoost;
    return _totalBoostAt(
      lv == 1 ? _tu1 + amount : _tu1,
      lv == 2 ? _tu2 + amount : _tu2,
      lv == 3 ? _tu3 + amount : _tu3,
      lv == 4 ? _tu4 + amount : _tu4,
    );
  }

  @override
  void initState() {
    super.initState();
    _tu1 = widget.mine.tu1;
    _tu2 = widget.mine.tu2;
    _tu3 = widget.mine.tu3;
    _tu4 = widget.mine.tu4;
    _localStock = {
      for (final e in _tuItems.entries)
        e.key: (widget.player.lager[e.value.toString()] ?? 0).toInt(),
    };
    _resetSlider();
  }

  void _resetSlider() {
    final lv = _activeLevel;
    if (lv == 0) { _addAmount = 0; return; }
    final canAdd  = 100 - _tuCurrent(lv);
    final inStock = _stock(lv);
    _addAmount = 0.clamp(0, canAdd.clamp(0, inStock));
  }

  Future<void> _install() async {
    if (_busy) return;
    final lv = _activeLevel;
    if (lv == 0 || _addAmount <= 0) return;
    setState(() => _busy = true);
    final sid    = context.read<PlayerProvider>().sid;
    final amount = _addAmount;
    final r      = await ApiService.techUpgradeMine(
        sid, widget.mine.id, lv, amount);
    if (!mounted) return;
    if (r == null || r['err'] != 0) {
      setState(() => _busy = false);
      AppNotify.show(context, r?['msg'] ?? 'Install failed', isError: true);
      return;
    }
    widget.onDone();
    setState(() {
      _busy = false;
      switch (lv) {
        case 1: _tu1 = (_tu1 + amount).clamp(0, 100);
        case 2: _tu2 = (_tu2 + amount).clamp(0, 100);
        case 3: _tu3 = (_tu3 + amount).clamp(0, 100);
        case 4: _tu4 = (_tu4 + amount).clamp(0, 100);
      }
      _localStock[lv] = (_localStock[lv]! - amount).clamp(0, 999999);
      _resetSlider();
    });
    AppNotify.show(context, 'TU$lv: installed $amount items');
  }

  @override
  Widget build(BuildContext context) {
    final lv        = _activeLevel;
    final allFull   = lv == 0;
    final canAdd    = allFull ? 0 : (100 - _tuCurrent(lv));
    final inStock   = allFull ? 0 : _stock(lv);
    final maxSlider = canAdd.clamp(0, inStock);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16,
            MediaQuery.of(context).viewInsets.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Tech Upgrades',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16)),
          const SizedBox(height: 12),
          for (int l = 1; l <= 4; l++) ...[
            _tuRow(l),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 8),
          if (!allFull) ...[
            Text('Installing TU$lv — ${_tuNames[lv]}  ($inStock in stock)',
                style: TextStyle(color: AppColors.t70, fontSize: 12)),
            const SizedBox(height: 4),
            if (maxSlider > 0) ...[
              Slider(
                value: _addAmount.toDouble(),
                min: 0, max: maxSlider.toDouble(),
                divisions: maxSlider > 0 ? maxSlider : 1,
                label: _addAmount.toString(),
                activeColor: Colors.purpleAccent,
                onChanged: (v) => setState(() => _addAmount = v.round()),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Add: $_addAmount items',
                    style: TextStyle(
                        color: AppColors.t54, fontSize: 12)),
                Text('Remaining: $canAdd / 100',
                    style: TextStyle(
                        color: AppColors.t38, fontSize: 11)),
              ]),
            ] else
              Text(inStock == 0
                  ? 'No TU$lv items in warehouse'
                  : 'Already full at this level',
                  style: TextStyle(
                      color: AppColors.t38, fontSize: 12)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (!_busy && _addAmount > 0) ? _install : null,
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.purple),
                child: _busy
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text('Install $_addAmount × ${_tuNames[lv]}'),
              ),
            ),
          ] else
            const Center(
              child: Text(
                'All tech upgrades fully installed! (+500% boost)',
                style: TextStyle(color: Colors.greenAccent, fontSize: 13),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _tuRow(int level) {
    final current  = _tuCurrent(level);
    final isActive = level == _activeLevel;
    final isLocked = level > 1 && _tuCurrent(level - 1) < 100;
    final fullBoost = _tuBoosts[level]!;
    final prevBoost = level == 1 ? 0 : _tuBoosts[level - 1]!;

    final barColor = isLocked ? Colors.white12
        : current >= 100 ? Colors.greenAccent : Colors.purpleAccent;

    final hasPreview = isActive && _addAmount > 0;
    final previewVal = hasPreview
        ? ((current + _addAmount) / 100.0).clamp(0.0, 1.0)
        : 0.0;
    final boostDelta = hasPreview
        ? (_previewBoost(_addAmount) - _currentBoost).round()
        : 0;

    final label = hasPreview && boostDelta > 0
        ? '+$boostDelta%'
        : '+${fullBoost - prevBoost}%';

    return Row(children: [
      SizedBox(width: 32,
        child: Text('TU$level',
            style: TextStyle(
              color: isLocked ? Colors.white24
                  : isActive ? Colors.purpleAccent : AppColors.t54,
              fontSize: 12,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ))),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Stack(children: [
              // Background
              Container(color: Colors.white12),
              // Preview extension (semi-transparent)
              if (hasPreview)
                FractionallySizedBox(
                  widthFactor: previewVal,
                  child: Container(color: barColor.withValues(alpha: 0.35)),
                ),
              // Solid current progress
              FractionallySizedBox(
                widthFactor: (current / 100.0).clamp(0.0, 1.0),
                child: Container(color: barColor),
              ),
            ]),
          ),
        ),
      ),
      const SizedBox(width: 8),
      SizedBox(width: 52,
        child: Text(
          label,
          style: TextStyle(
            color: isLocked ? Colors.white24
                : hasPreview ? Colors.purpleAccent : AppColors.t54,
            fontSize: 11,
            fontWeight: hasPreview ? FontWeight.bold : FontWeight.normal,
          ),
        )),
    ]);
  }
}

// ── _ActionBtn ──────────────────────────────────────────────────────────────

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool busy;
  final VoidCallback? onTap;

  const _ActionBtn({
    required this.icon, required this.label, required this.color,
    required this.busy, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    return OutlinedButton.icon(
      icon: Icon(icon, size: 14),
      label: Text(label,
          style: const TextStyle(fontSize: 11),
          overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        foregroundColor: enabled ? color : Colors.white24,
        side: BorderSide(
            color: enabled ? color.withValues(alpha: 0.5) : Colors.white12),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      onPressed: enabled ? onTap : null,
    );
  }
}

