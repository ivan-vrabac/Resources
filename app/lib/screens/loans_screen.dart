import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';

import '../app_colors.dart';
/// Loans: your credit rating and limit, open loan requests from other players (lend), and your
/// borrowing/lending history with repayment.
class LoansScreen extends StatefulWidget {
  const LoansScreen({super.key});
  @override
  State<LoansScreen> createState() => _LoansScreenState();
}

class _LoansScreenState extends State<LoansScreen> {
  Map<String, dynamic>? _status, _market, _mine;
  bool _loading = true;
  String? _error;
  bool _busy = false;

  String get _sid => context.read<PlayerProvider>().sid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rs = await Future.wait([
      GameApi.call('/api/v1/loans/status', _sid),
      GameApi.call('/api/v1/loans/list', _sid),
      GameApi.call('/api/v1/loans/mine', _sid),
    ]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      final bad = rs.where((r) => !r.ok).toList();
      _error = bad.isEmpty ? null : bad.first.message;
      if (bad.isEmpty) {
        _status = rs[0].data;
        _market = rs[1].data;
        _mine = rs[2].data;
      }
    });
  }

  Future<void> _act(String path, Map<String, dynamic> params, String okMsg) async {
    if (_busy) return;
    setState(() => _busy = true);
    final r = await GameApi.call(path, _sid, params);
    if (!mounted) return;
    setState(() => _busy = false);
    AppNotify.show(context, r.ok ? okMsg : (r.message ?? 'Failed'), isError: !r.ok);
    if (r.ok) {
      context.read<PlayerProvider>().refresh();
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(children: [
        const TabBar(tabs: [Tab(text: 'Rating'), Tab(text: 'Lend'), Tab(text: 'My loans')]),
        Expanded(
          child: AsyncView(
            loading: _loading,
            error: _error,
            onRetry: _load,
            builder: () => TabBarView(children: [_ratingTab(), _lendTab(), _mineTab()]),
          ),
        ),
      ]),
    );
  }

  Widget _ratingTab() {
    final s = _status!;
    Widget row(String k, String v) => ListTile(dense: true, title: Text(k), trailing: Text(v));
    final rate = s['weeklyRate'] as num?;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Text(s['rating'] as String, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold)),
              const SizedBox(width: 16),
              Expanded(child: Text('Risk: ${s['risk']}\nScore ${s['score']} / 100',
                  style: TextStyle(color: AppColors.t70))),
            ]),
          ),
        ),
        row('Money earned (30 days)', fmtCredits(s['income30d'] as num)),
        row('Credit limit', fmtCredits(s['limit'] as num)),
        row('Outstanding', fmtCredits(s['outstanding'] as num)),
        row('Interest', rate == null ? '—' : '${(rate * 100).toStringAsFixed(1)}% per week'),
        row('Loans repaid on time / late / defaults', '${s['onTime']} / ${s['late']} / ${s['defaults']}'),
        const SizedBox(height: 8),
        if (s['eligible'] == true)
          FilledButton.icon(
            icon: const Icon(Icons.request_quote_outlined),
            label: const Text('Request a loan'),
            onPressed: _busy ? null : _requestDialog,
          )
        else
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(s['reason'] as String? ?? ''))),
        Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('Your rating comes from the money you earned in the last 30 days, how long you have '
              'played and how you repaid earlier loans. If a loan is not repaid by its due date, your rating '
              'drops to D and for 30 days the game takes 50% of your mining output, factory output and sales '
              'to pay the lender. After those 30 days the rest is forgiven, but your rating stays reset to D.',
              style: TextStyle(color: AppColors.t54, fontSize: 12)),
        ),
      ]),
    );
  }

  Future<void> _requestDialog() async {
    final s = _status!;
    final ctl = TextEditingController();
    var term = (s['minTerm'] as num? ?? 10).toInt();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final p = int.tryParse(ctl.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final interest = (p * (s['weeklyRate'] as num) * term / 7).round();
        return AlertDialog(
          title: const Text('Request a loan'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: ctl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Amount',
                  helperText: 'max ${fmtCredits(s['available'] as num)}, min ${fmtCredits(s['minPrincipal'] as num)}'),
              onChanged: (_) => set(() {}),
            ),
            const SizedBox(height: 8),
            Text('Term: $term days'),
            Slider(
              value: term.toDouble(),
              min: (s['minTerm'] as num? ?? 10).toDouble(),
              max: (s['maxTerm'] as num? ?? 30).toDouble(),
              divisions: ((s['maxTerm'] as num? ?? 30) - (s['minTerm'] as num? ?? 10)).toInt(),
              label: '$term days',
              onChanged: (v) => set(() => term = v.round()),
            ),
            const SizedBox(height: 8),
            Text('Interest ${fmtCredits(interest)} · repay ${fmtCredits(p + interest)}'),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: p <= 0 ? null : () => Navigator.pop(ctx, true), child: const Text('Request')),
          ],
        );
      }),
    );
    if (ok != true) return;
    final p = int.tryParse(ctl.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    await _act('/api/v1/loans/request', {'principal': p, 'termDays': term}, 'Loan request published');
  }

  Widget _lendTab() {
    final reqs = (_market!['requests'] as List).cast<Map<String, dynamic>>();
    if (reqs.isEmpty) {
      return RefreshIndicator(onRefresh: _load,
          child: ListView(children: const [Padding(padding: EdgeInsets.all(24),
              child: Text('No open loan requests right now.', textAlign: TextAlign.center))]));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(8), children: [
        for (final l in reqs)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(l['rating'] as String, style: const TextStyle(fontSize: 11))),
              title: Text('${fmtCredits(l['principal'] as num)} for ${l['term_days']} days'),
              subtitle: Text('Anonymous company · risk ${l['risk']}\n'
                  'You get back ${fmtCredits(l['total'] as num)} (+${fmtCredits(l['interest'] as num)})'),
              isThreeLine: true,
              trailing: FilledButton(
                onPressed: _busy ? null : () => _confirmFund(l),
                child: const Text('Lend'),
              ),
            ),
          ),
      ]),
    );
  }

  Future<void> _confirmFund(Map<String, dynamic> l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Lend ${fmtCredits(l['principal'] as num)}?'),
        content: Text('Anonymous borrower · rating ${l['rating']}, risk ${l['risk']}.\n'
            'Repayment of ${fmtCredits(l['total'] as num)} is due ${l['term_days']} days after funding. '
            'If it is late, 50% of the borrower\'s output and sales go to you for 30 days; whatever is still '
            'unpaid after that is forgiven.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lend')),
        ],
      ),
    );
    if (ok == true) await _act('/api/v1/loans/fund', {'loanID': l['id']}, 'Loan funded');
  }

  Widget _mineTab() {
    final b = (_mine!['borrowed'] as List).cast<Map<String, dynamic>>();
    final l = (_mine!['lent'] as List).cast<Map<String, dynamic>>();
    Color col(String s) => switch (s) {
          'overdue' => Colors.orange,
          'forgiven' => Colors.red,
          'repaid' => Colors.green,
          'active' => Colors.lightBlueAccent,
          _ => AppColors.t54,
        };
    Widget tile(Map<String, dynamic> x, bool borrowed) {
      final open = x['status'] == 'open';
      final owes = ['active', 'overdue'].contains(x['status']) && (x['outstanding'] as num) > 0;
      return Card(
        child: ListTile(
          title: Text('${fmtCredits(x['principal'] as num)} · ${x['term_days']} days · ${x['rating']}'),
          subtitle: Text('${borrowed ? 'Borrowed' : 'Lent'} · anonymous\n'
              'Repaid ${fmtCredits(x['repaid'] as num)} of ${fmtCredits(x['total'] as num)}'
              '${x['due_at'] != null ? ' · due ${(x['due_at'] as String).substring(0, 16).replaceFirst('T', ' ')} UTC' : ''}'),
          isThreeLine: true,
          trailing: borrowed && owes
              ? FilledButton(onPressed: _busy ? null : () => _act('/api/v1/loans/repay', {'loanID': x['id']}, 'Repayment sent'),
                  child: const Text('Repay'))
              : borrowed && open
                  ? TextButton(onPressed: _busy ? null : () => _act('/api/v1/loans/cancel', {'loanID': x['id']}, 'Request cancelled'),
                      child: const Text('Cancel'))
                  : Text(x['status'] as String, style: TextStyle(color: col(x['status'] as String))),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(8), children: [
        Padding(padding: EdgeInsets.all(8), child: Text('Borrowed', style: TextStyle(color: AppColors.t54))),
        if (b.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No loans yet.')),
        for (final x in b) tile(x, true),
        Padding(padding: EdgeInsets.all(8), child: Text('Lent', style: TextStyle(color: AppColors.t54))),
        if (l.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing lent yet.')),
        for (final x in l) tile(x, false),
      ]),
    );
  }
}
