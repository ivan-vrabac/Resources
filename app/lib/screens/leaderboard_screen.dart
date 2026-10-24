import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart' show fmtNum, itemName;
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import 'profile_screen.dart';

import '../app_colors.dart';
/// Leaderboards: overall score, luxury points (with luxury items), and output per hour of one
/// raw resource (mines) or factory product. Compact one-line rows; tap a row for the company sheet.
class LeaderboardScreen extends StatelessWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: const DefaultTabController(
        length: 3,
        child: Column(children: [
          TabBar(tabs: [Tab(text: 'Overall'), Tab(text: 'Luxury'), Tab(text: 'Resource')]),
          Expanded(child: TabBarView(children: [_OverallBoard(), _LuxuryBoard(), _ResourceBoard()])),
        ]),
      ),
    );
  }
}

void _openProfile(BuildContext context, Map<String, dynamic> r) {
  final pid = r['isMe'] == true ? null : r['pid'] as String?;
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileScreen(pid: pid)));
}

/// One compact row: rank · name (+ optional middle widget) · value.
Widget _row(BuildContext context, Map<String, dynamic> r, {Widget? middle, required String value, String? unit}) {
  final isMe = r['isMe'] == true;
  return InkWell(
    onTap: () => _openProfile(context, r),
    child: Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: isMe ? AppColors.accent.withValues(alpha: 0.12) : null,
      child: Row(children: [
        SizedBox(width: 38, child: Text('#${r['rank']}', textAlign: TextAlign.right,
            style: TextStyle(color: isMe ? AppColors.accent : AppColors.t54, fontSize: 12, fontWeight: FontWeight.bold))),
        const SizedBox(width: 8),
        Expanded(
          flex: 5,
          child: Text(r['name'] as String? ?? '—', overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: isMe ? AppColors.accent : AppColors.fg,
                  fontWeight: isMe ? FontWeight.bold : FontWeight.normal)),
        ),
        if (middle != null) Expanded(flex: 4, child: middle),
        SizedBox(
          width: 92,
          child: Text(unit == null ? value : '$value $unit', textAlign: TextAlign.right,
              style: TextStyle(color: isMe ? AppColors.accent : AppColors.t70, fontSize: 13, fontWeight: FontWeight.bold)),
        ),
      ]),
    ),
  );
}

/// Column titles above a board (owner 2026-10-24): Rank · Player · middle column · value.
Widget _infoRow(String middle, String value) => Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(children: [
        SizedBox(width: 38, child: Text('Rank', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppColors.t54))),
        const SizedBox(width: 8),
        Expanded(flex: 5, child: Text('Player', style: TextStyle(fontSize: 11, color: AppColors.t54))),
        Expanded(flex: 4, child: Text(middle, style: TextStyle(fontSize: 11, color: AppColors.t54))),
        SizedBox(width: 92, child: Text(value, textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppColors.t54))),
      ]),
    );

abstract class _BoardState<T extends StatefulWidget> extends State<T> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? data;
  bool loading = true;
  String? error;
  bool country = false;   // only my country (ranks recounted by the server)
  int page = 0;           // 100 players per page
  String get path;
  Map<String, dynamic> get params => const {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    final r = await GameApi.call(path, context.read<PlayerProvider>().sid,
        {...params, 'page': page, if (country) 'country': 1});
    if (!mounted) return;
    setState(() { loading = false; error = r.ok ? null : r.message; if (r.ok) data = r.data; });
  }

  /// "My country" filter and page arrows, shown on every board.
  Widget controls({String? note}) {
    final d = data!;
    final pages = (d['pages'] as num? ?? 1).toInt();
    final hasCountry = (d['myCountry'] as String? ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(children: [
        if (hasCountry)
          FilterChip(
            label: const Text('My country', style: TextStyle(fontSize: 11)),
            selected: country, visualDensity: VisualDensity.compact,
            onSelected: (v) { setState(() { country = v; page = 0; }); load(); },
          ),
        const SizedBox(width: 8),
        Expanded(child: Text(note ?? (d['myRank'] != null ? 'Your rank: #${d['myRank']}' : ''),
            style: TextStyle(color: AppColors.t54, fontSize: 12), overflow: TextOverflow.ellipsis)),
        IconButton(
          visualDensity: VisualDensity.compact, icon: const Icon(Icons.chevron_left),
          onPressed: page > 0 ? () { setState(() => page--); load(); } : null,
        ),
        Text('${page + 1}/$pages', style: const TextStyle(fontSize: 12)),
        IconButton(
          visualDensity: VisualDensity.compact, icon: const Icon(Icons.chevron_right),
          onPressed: page + 1 < pages ? () { setState(() => page++); load(); } : null,
        ),
      ]),
    );
  }

  Widget list(List<Map<String, dynamic>> rows, Widget Function(Map<String, dynamic>) tile, {Widget? header}) {
    final h = header != null ? 1 : 0;
    return RefreshIndicator(
      onRefresh: load,
      child: ListView.separated(
        itemCount: rows.length + h,
        separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
        itemBuilder: (_, i) => h == 1 && i == 0 ? header! : tile(rows[i - h]),
      ),
    );
  }
}

class _OverallBoard extends StatefulWidget {
  const _OverallBoard();
  @override
  State<_OverallBoard> createState() => _OverallBoardState();
}

class _OverallBoardState extends _BoardState<_OverallBoard> {
  @override
  String get path => '/api/v1/rank/players';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AsyncView(loading: loading && data == null, error: error, onRetry: load, builder: () {
      final rows = (data!['rows'] as List).cast<Map<String, dynamic>>();
      return list(rows, (r) => _row(context, r, value: fmtNum((r['score'] as num).toInt()),
          middle: Text('${r['level']}', style: TextStyle(color: AppColors.t70, fontSize: 12))),
          header: Column(mainAxisSize: MainAxisSize.min, children: [controls(), _infoRow('Level', 'Points')]));
    });
  }
}

class _LuxuryBoard extends StatefulWidget {
  const _LuxuryBoard();
  @override
  State<_LuxuryBoard> createState() => _LuxuryBoardState();
}

class _LuxuryBoardState extends _BoardState<_LuxuryBoard> {
  @override
  String get path => '/api/v1/rank/luxury';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AsyncView(loading: loading && data == null, error: error, onRetry: load, builder: () {
      final rows = (data!['rows'] as List).cast<Map<String, dynamic>>();
      return list(rows, (r) {
        final n = (r['itemCount'] as num? ?? 0).toInt();     // just how many luxury items
        return _row(context, r, value: fmtNum((r['points'] as num).toInt()),
            middle: Text('$n', style: TextStyle(fontSize: 12, color: AppColors.t70)));
      }, header: Column(mainAxisSize: MainAxisSize.min, children: [
        controls(note: 'Your luxury points: ${fmtNum((data!['myPoints'] as num).toInt())}'
            '${data!['myRank'] != null ? ' · #${data!['myRank']}' : ''}'),
        _infoRow('Luxury items', 'Luxury points'),
      ]));
    });
  }
}

class _ResourceBoard extends StatefulWidget {
  const _ResourceBoard();
  @override
  State<_ResourceBoard> createState() => _ResourceBoardState();
}

class _ResourceBoardState extends _BoardState<_ResourceBoard> {
  String _kind = 'mine';
  int? _item;
  @override
  String get path => '/api/v1/rank/resource';
  @override
  Map<String, dynamic> get params => {'kind': _kind, if (_item != null) 'item': _item};

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AsyncView(loading: loading && data == null, error: error, onRetry: load, builder: () {
      final rows = (data!['rows'] as List).cast<Map<String, dynamic>>();
      final options = ((data!['options'] as Map)[_kind] as List).cast<int>();
      final item = (data!['item'] as num).toInt();
      return list(rows, (r) => _row(context, r, value: fmtNum((r['perHour'] as num).round()),
          middle: Text('${r['count']}', style: TextStyle(color: AppColors.t70, fontSize: 12))),
          header: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Row(children: [
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'mine', label: Text('Raw')), ButtonSegment(value: 'factory', label: Text('Factory'))],
                selected: {_kind},
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: (v) { setState(() { _kind = v.first; _item = null; page = 0; }); load(); },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: options.contains(item) ? item : null,
                  items: [
                    for (final o in options)
                      DropdownMenuItem(value: o, child: Row(children: [
                        ItemIcon(o, size: 22), const SizedBox(width: 6),
                        Flexible(child: Text(itemName(o), overflow: TextOverflow.ellipsis)),
                      ])),
                  ],
                  onChanged: (v) { setState(() { _item = v; page = 0; }); load(); },
                ),
              ),
            ]),
          ),
          controls(),
          _infoRow(_kind == 'mine' ? 'Mines' : 'Level', 'Output / h'),
          ]));
    });
  }
}
