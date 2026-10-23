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

  Future<void> _bid(Map<String, dynamic> a) async {
    final min = (a['minBid'] as num).toInt();
    final res = (a['resID'] as num).toInt();
    final ctl = TextEditingController(text: '$min');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Bid on ${itemName((a['itemID'] as num).toInt())}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ItemIcon(res, size: 28),
            const SizedBox(width: 8),
            Expanded(child: Text('Paid in ${itemName(res)} · you have ${fmtQty(a['youHave'] as num)}')),
          ]),
          TextField(controller: ctl, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Your bid (${itemName(res)})', helperText: 'minimum ${fmtQty(min)}')),
          const SizedBox(height: 8),
          Text('Bid now: +${a['minBidPoints']} luxury points · winning: about +${a['winPoints']}',
              style: const TextStyle(fontSize: 12, color: Colors.amberAccent)),
          Text('The resources leave your warehouse now and come back if someone outbids you.',
              style: TextStyle(fontSize: 12, color: AppColors.t54)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Bid')),
        ],
      ),
    );
    if (ok != true || _busy) return;
    final amount = int.tryParse(ctl.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    setState(() => _busy = true);
    final r = await GameApi.call('/api/v1/auctions/bid', _sid, {'auctionID': a['id'], 'amount': amount});
    if (!mounted) return;
    setState(() => _busy = false);
    AppNotify.show(context, r.ok ? 'You are the highest bidder' : (r.message ?? 'Bid failed'), isError: !r.ok);
    if (r.ok) context.read<PlayerProvider>().refresh();
    _load();
  }

  void _history(int itemId) {
    showModalBottomSheet(
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
            if (recent.isNotEmpty)
              Padding(padding: EdgeInsets.fromLTRB(8, 12, 8, 4),
                  child: Text('Recently sold', style: TextStyle(color: AppColors.t54))),
            for (final a in recent.take(10))
              ListTile(
                dense: true,
                leading: ItemIcon((a['itemID'] as num).toInt(), size: 28),
                title: Text(itemName((a['itemID'] as num).toInt())),
                subtitle: Text('${(a['leader'] as Map?)?['name'] ?? '?'} · ${fmtQty(a['topBid'] as num)} '
                    '${itemName((a['resID'] as num).toInt())}'),
                onTap: () => _history((a['itemID'] as num).toInt()),
              ),
            const Divider(),
            Padding(padding: EdgeInsets.all(8),
                child: Text('Your luxury collection — when someone spins five of a kind of an item you hold in the '
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
                          child: Text(a['youLead'] == true ? 'you' : (leader?['name'] as String? ?? ''),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.lightBlueAccent, decoration: TextDecoration.underline)),
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
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                Text('Recent bids', style: TextStyle(color: AppColors.t54, fontSize: 12)),
                SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: (d['bids'] as List).isEmpty
                      ? const Center(child: Text('No bids yet'))
                      : CustomPaint(painter: _BidChart((d['bids'] as List)
                          .map((b) => ((b as Map)['amount'] as num).toDouble()).toList())),
                ),
                const SizedBox(height: 12),
                if (d['lastSale'] != null) ...[
                  Text('Last sold to', style: TextStyle(color: AppColors.t54, fontSize: 12)),
                  _playerTile((d['lastSale'] as Map).cast<String, dynamic>(), d),
                ] else
                  Text('Never sold yet.', style: TextStyle(color: AppColors.t54)),
                if ((d['bids'] as List).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Latest bidders', style: TextStyle(color: AppColors.t54, fontSize: 12)),
                  for (final b in (d['bids'] as List).reversed.take(5).cast<Map<String, dynamic>>())
                    _playerTile({'player': b['player'], 'price': b['amount'], 'ts': b['ts']}, d),
                ],
              ]),
      ),
    );
  }

  Widget _playerTile(Map<String, dynamic> s, Map<String, dynamic> d) {
    final p = (s['player'] as Map?)?.cast<String, dynamic>() ?? {};
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.business, size: 20),
      title: Text(p['name'] as String? ?? '?', style: const TextStyle(color: Colors.lightBlueAccent)),
      subtitle: Text('${fmtQty(s['price'] as num)} ${itemName((d['resID'] as num).toInt())} · '
          '${(s['ts'] as String? ?? '').replaceFirst('T', ' ').substring(0, min(16, (s['ts'] as String? ?? '').length))}'),
      onTap: p['pid'] == null ? null : () => ProfileScreen.open(context, p['pid'] as String),
    );
  }
}

class _BidChart extends CustomPainter {
  final List<double> v;
  _BidChart(this.v);

  @override
  void paint(Canvas canvas, Size size) {
    final hi = v.reduce(max), lo = v.reduce(min);
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    final grid = Paint()..color = Colors.white12..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final x = v.length == 1 ? size.width / 2 : size.width * i / (v.length - 1);
      final y = size.height - (v[i] - lo) / span * (size.height - 16) - 8;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      canvas.drawCircle(Offset(x, y), 2.5, Paint()..color = Colors.amberAccent);
    }
    canvas.drawPath(path, Paint()
      ..color = Colors.amberAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final (val, y) in [(hi, 0.0), (lo, size.height - 12)]) {
      tp.text = TextSpan(text: fmtQty(val), style: TextStyle(color: AppColors.t54, fontSize: 10));
      tp.layout();
      tp.paint(canvas, Offset(0, y));
    }
  }

  @override
  bool shouldRepaint(covariant _BidChart old) => old.v != v;
}
