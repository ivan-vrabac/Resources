import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';
import 'profile_screen.dart';

import '../app_colors.dart';
import '../widgets/popups.dart';
import '../widgets/price_chart.dart';
/// The luxury auction: one item at a time, bid with that item's resource (HQ level 10, max 10 of
/// each item). Bids give luxury points, wins give many more. Tap an item for its bid history.
class AuctionsScreen extends StatefulWidget {
  const AuctionsScreen({super.key});
  @override
  State<AuctionsScreen> createState() => _AuctionsScreenState();
}

class _AuctionsScreenState extends State<AuctionsScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String? _error;
  bool _busy = false;
  Timer? _tick;

  String get _sid => context.read<PlayerProvider>().sid;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await GameApi.call('/api/v1/auctions', _sid);
    if (!mounted) return;
    setState(() { _loading = false; _error = r.ok ? null : r.message; if (r.ok) _d = r.data; });
  }

  String _left(String iso) {
    final d = DateTime.parse(iso.endsWith('Z') ? iso : '${iso}Z').difference(DateTime.now().toUtc());
    if (d.isNegative) return 'ending…';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  /// "Place bid": the server bids the current minimum itself (owner 2026-10-23, automatic maths).
  Future<void> _bid(Map<String, dynamic> a) async {
    final res = (a['resID'] as num).toInt();
    final have = (a['youHave'] as num? ?? 0).toDouble();
    final amount = (a['minBid'] as num).toDouble();
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Bid on ${itemName((a['itemID'] as num).toInt())}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ItemIcon(res, size: 28),
            const SizedBox(width: 8),
            Expanded(child: Text('About ${fmtQty(amount)} ${itemName(res)} · you have ${fmtQty(have)}')),
          ]),
          const SizedBox(height: 8),
          Text('The server places the lowest winning bid for you (at least 5% above the current one). '
              'The resources leave your warehouse now and come back if someone outbids you. '
              'A bid in the last 30 seconds sets the clock to 60 seconds.',
              style: TextStyle(fontSize: 12, color: AppColors.t54)),
          const SizedBox(height: 6),
          Text('While you lead: +${a['minBidPoints']} luxury points · winning: about +${a['winPoints']}',
              style: const TextStyle(fontSize: 12, color: Colors.amberAccent)),
        ]),
        actions: [
          TextButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: amount > have ? null : () => popIfCurrent(ctx, true), child: const Text('Place bid')),
        ],
      ),
    );
    if (ok != true || _busy) return;
    setState(() => _busy = true);
    final r = await GameApi.call('/api/v1/auctions/bid', _sid, {'auctionID': a['id']});
    if (!mounted) return;
    setState(() => _busy = false);
    AppNotify.show(context, r.ok ? 'You are the highest bidder' : (r.message ?? 'Bid failed'), isError: !r.ok);
    if (r.ok) context.read<PlayerProvider>().refresh();
    _load();
  }

  void _history(int itemId) {
    showAppSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ItemHistorySheet(itemId: itemId, sid: _sid),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      builder: () {
        final d = _d!;
        final active = (d['active'] as List).cast<Map<String, dynamic>>();
        final recent = (d['recent'] as List).cast<Map<String, dynamic>>().where((a) => a['status'] == 'sold').toList();
        final coll = (d['collection'] as Map).cast<String, dynamic>();
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(8), children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.diamond_outlined, color: Colors.amberAccent),
                title: Text('${fmtQty(d['luxuryPoints'] as num)} luxury points'),
                subtitle: const Text('Earned only by bidding on and winning luxury items'),
              ),
            ),
            if (d['eligible'] != true)
              Card(child: Padding(padding: const EdgeInsets.all(12),
                  child: Text('Bidding needs headquarters level ${d['hqRequired']} (yours: ${d['hqLevel']}).'))),
            for (final a in active) _lotCard(a, d),
            // owner 2026-10-23: only the last sale here (each item's sales are in its sheet)
            if (recent.isNotEmpty) ...[
              Padding(padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                  child: Text('Last sold', style: TextStyle(color: AppColors.t54))),
              Builder(builder: (_) {
                final a = recent.first;
                final ts = (a['settledAt'] as String? ?? '').replaceFirst('T', ' ');
                return ListTile(
                  dense: true,
                  leading: ItemIcon((a['itemID'] as num).toInt(), size: 28),
                  title: Text(itemName((a['itemID'] as num).toInt())),
                  subtitle: Text('${(a['leader'] as Map?)?['name'] ?? '?'} · ${fmtQty(a['topBid'] as num)} '
                      '${itemName((a['resID'] as num).toInt())} · ${ts.substring(0, min(16, ts.length))} UTC'),
                  onTap: () => _history((a['itemID'] as num).toInt()),
                );
              }),
            ],
            const Divider(),
            Padding(padding: EdgeInsets.all(8),
                child: Text('Your luxury collection: when someone spins five of a kind of an item you hold in the '
                    'casino, you get 1% of the jackpot per item you hold (up to 10 items = 10%).',
                    style: TextStyle(color: AppColors.t54, fontSize: 12))),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (final e in coll.entries)
                  _luxurySquare(int.parse(e.key), (e.value as num).toInt()),
              ],
            ),
          ]),
        );
      },
    );
  }

  /// One luxury item: picture (dimmed if you have none) with your count; tap for its history.
  Widget _luxurySquare(int item, int qty) {
    final have = qty > 0;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _history(item),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: have ? 0.08 : 0.03),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: have ? Colors.amberAccent.withValues(alpha: 0.7) : Colors.white12),
        ),
        child: Stack(children: [
          Center(child: Opacity(opacity: have ? 1 : 0.45, child: ItemIcon(item, size: 52))),
          if (have)
            Positioned(
              right: 4, top: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(color: Colors.amber.shade800, borderRadius: BorderRadius.circular(8)),
                child: Text('×$qty', style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _lotCard(Map<String, dynamic> a, Map<String, dynamic> d) {
    final item = (a['itemID'] as num).toInt(), res = (a['resID'] as num).toInt();
    final leader = (a['leader'] as Map?)?.cast<String, dynamic>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: () => _history(item),
            child: Row(children: [
              ItemIcon(item, size: 64),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(itemName(item), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                Text('Ends in ${_left(a['endsAt'] as String)} · ${a['bids']} bids',
                    style: TextStyle(color: AppColors.t70)),
                Text('You own ${a['owned']}/${d['maxOwn']} · tap for history',
                    style: TextStyle(color: AppColors.t38, fontSize: 11)),
              ])),
            ]),
          ),
          const SizedBox(height: 10),
          Row(children: [
            ItemIcon(res, size: 24),
            const SizedBox(width: 6),
            Expanded(
              child: (a['topBid'] as num) > 0
                  ? Row(children: [
                      Text('Top bid ${fmtQty(a['topBid'] as num)} ${itemName(res)} · '),
                      Flexible(
                        child: GestureDetector(
                          onTap: leader?['pid'] == null ? null : () => ProfileScreen.open(context, leader!['pid'] as String),
                          // you: in the app colour; other players: plain text (owner 2026-10-24)
                          // the full company name, also your own (owner 2026-10-24: no "you"), never cut off
                          child: Text(
                              a['youLead'] == true
                                  ? (context.read<PlayerProvider>().player?.name ?? (leader?['name'] as String? ?? ''))
                                  : (leader?['name'] as String? ?? ''),
                              softWrap: true,
                              style: a['youLead'] == true
                                  ? TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold)
                                  : null),
                        ),
                      ),
                    ])
                  : Text('Starts at ${fmtQty(a['startPrice'] as num)} ${itemName(res)}'),
            ),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: d['eligible'] != true || a['youLead'] == true || _busy ? null : () => _bid(a),
              child: Text(a['youLead'] == true ? 'You are leading' : 'Bid (min ${fmtQty(a['minBid'] as num)})'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ItemHistorySheet extends StatefulWidget {
  final int itemId;
  final String sid;
  const _ItemHistorySheet({required this.itemId, required this.sid});
  @override
  State<_ItemHistorySheet> createState() => _ItemHistorySheetState();
}

class _ItemHistorySheetState extends State<_ItemHistorySheet> {
  Map<String, dynamic>? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    GameApi.call('/api/v1/auctions/item', widget.sid, {'itemID': widget.itemId}).then((r) {
      if (mounted) setState(() { _error = r.ok ? null : r.message; if (r.ok) _d = r.data; });
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: d == null
            ? SizedBox(height: 160, child: Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator()))
            : SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  ItemIcon(widget.itemId, size: 48),
                  const SizedBox(width: 12),
                  Expanded(child: Text(itemName(widget.itemId),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                ]),
                const SizedBox(height: 4),
                Text('Bought with ${itemName((d['resID'] as num).toInt())} · you own ${d['owned']}',
                    style: TextStyle(color: AppColors.t70)),
                const SizedBox(height: 12),
                // owner 2026-10-23: sales of the last 365 days under the graph, newest first
                if ((d['sales'] as List? ?? const []).isEmpty)
                  Text('Never sold yet.', style: TextStyle(color: AppColors.t54))
                else ...[
                  Text('Sale prices (${itemName((d['resID'] as num).toInt())}, up to 365 days)',
                      style: TextStyle(color: AppColors.t54, fontSize: 12)),
                  SalesDotsChart(sales: (d['sales'] as List).cast<Map<String, dynamic>>()),
                  const SizedBox(height: 8),
                  Text('Recently sold (past 365 days)', style: TextStyle(color: AppColors.t54, fontSize: 12)),
                  // five rows on screen, scroll for the rest
                  SizedBox(
                    height: 5 * 56.0,
                    child: ListView(children: [
                      for (final x in (d['sales'] as List).reversed.cast<Map<String, dynamic>>()) _playerTile(x, d),
                    ]),
                  ),
                ],
              ])),
      ),
    );
  }

  Widget _playerTile(Map<String, dynamic> s, Map<String, dynamic> d) {
    final p = (s['player'] as Map?)?.cast<String, dynamic>() ?? {};
    final ts = (s['ts'] as String? ?? '').replaceFirst('T', ' ');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(p['name'] as String? ?? '?', style: const TextStyle(color: Colors.lightBlueAccent)),
      subtitle: Text('${fmtQty(s['price'] as num)} ${itemName((d['resID'] as num).toInt())} · '
          '${ts.substring(0, min(16, ts.length))} UTC'),
      onTap: p['pid'] == null ? null : () => ProfileScreen.open(context, p['pid'] as String),
    );
  }
}

