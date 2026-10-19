import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';

/// Luxury item auctions (HQ level 10, max 10 of each item) and the player's luxury collection,
/// which earns casino dividends when someone spins five of a kind of that item.
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
    final ctl = TextEditingController(text: '$min');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Bid on ${kItemNames[a['itemID']] ?? 'item'}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctl, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Your bid', helperText: 'minimum ${fmtCredits(min)}')),
          const SizedBox(height: 8),
          const Text('The full bid is reserved now and refunded if someone outbids you.',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
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

  @override
  Widget build(BuildContext context) {
    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      builder: () {
        final d = _d!;
        final active = (d['active'] as List).cast<Map<String, dynamic>>();
        final coll = (d['collection'] as Map).cast<String, dynamic>();
        final owned = coll.entries.where((e) => (e.value as num) > 0).toList();
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(8), children: [
            if (d['eligible'] != true)
              Card(child: Padding(padding: const EdgeInsets.all(12),
                  child: Text('Bidding needs headquarters level ${d['hqRequired']} (yours: ${d['hqLevel']}).'))),
            for (final a in active)
              Card(
                child: ListTile(
                  leading: ItemIcon((a['itemID'] as num).toInt(), size: 40),
                  title: Text(kItemNames[a['itemID']] ?? 'Item ${a['itemID']}'),
                  subtitle: Text(
                      '${(a['topBid'] as num) > 0 ? 'Top bid ${fmtCredits(a['topBid'] as num)}${a['youLead'] == true ? ' (you)' : ' · ${(a['leader'] as Map?)?['name'] ?? ''}'}' : 'Starts at ${fmtCredits(a['startPrice'] as num)}'}\n'
                      'Ends in ${_left(a['endsAt'] as String)} · you own ${a['owned']}/${d['maxOwn']}'),
                  isThreeLine: true,
                  trailing: FilledButton(
                    onPressed: d['eligible'] != true || a['youLead'] == true || _busy ? null : () => _bid(a),
                    child: const Text('Bid'),
                  ),
                ),
              ),
            const Divider(),
            const Padding(padding: EdgeInsets.all(8),
                child: Text('Your luxury collection — when someone spins five of a kind of an item you hold, '
                    'holders share 10% of the casino jackpot (up to 10 of each item count).',
                    style: TextStyle(color: Colors.white54, fontSize: 12))),
            if (owned.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No luxury items yet.')),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in owned)
                Chip(avatar: ItemIcon(int.parse(e.key), size: 20),
                    label: Text('${kItemNames[int.parse(e.key)] ?? e.key} ×${(e.value as num).toInt()}')),
            ]),
          ]),
        );
      },
    );
  }
}
