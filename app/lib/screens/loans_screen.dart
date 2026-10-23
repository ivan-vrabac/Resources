import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';

import '../app_colors.dart';
import '../widgets/popups.dart';
/// Loans: your credit rating and limit, open loan requests from other players (lend), and your
/// borrowing/lending history with repayment.
class LoansScreen extends StatefulWidget {
  const LoansScreen({super.key});
  @override
  State<LoansScreen> createState() => _LoansScreenState();
}

class _LoansScreenState extends State<LoansScreen> {
  Map<String, dynamic>? _status, _market, _mine, _stats;
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
      GameApi.call('/api/v1/loans/stats', _sid),
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
        _stats = rs[3].data;
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

  /// Longer terms allow bigger loans (server: loans.max_for_term): all of it at 30 days, a third at 10.
  int _maxForTerm(int available, int term, int maxTerm) => (available * term / maxTerm).floor();

  Future<void> _requestDialog() async {
    final s = _status!;
    final minTerm = (s['minTerm'] as num? ?? 10).toInt(), maxTerm = (s['maxTerm'] as num? ?? 30).toInt();
    final minP = (s['minPrincipal'] as num? ?? 10000).toInt();
    final available = (s['available'] as num? ?? 0).toInt();
    final rate = (s['weeklyRate'] as num? ?? 0).toDouble();
    var term = maxTerm;
    var amount = max(minP, _maxForTerm(available, term, maxTerm));
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final cap = _maxForTerm(available, term, maxTerm);
        final possible = cap >= minP;
        if (possible) amount = amount.clamp(minP, cap);
        final interest = (amount * rate * term / 7).round();
        // 100 steps between the minimum and the maximum for this term, whole thousands
        final steps = possible ? max(1, min(100, (cap - minP) ~/ 1000)) : 1;
        return AlertDialog(
          title: const Text('Request a loan'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pay back within $term days', style: const TextStyle(fontWeight: FontWeight.bold)),
            Slider(
              value: term.toDouble(), min: minTerm.toDouble(), max: maxTerm.toDouble(),
              divisions: maxTerm - minTerm, label: '$term days',
              onChanged: (v) => set(() => term = v.round()),
            ),
            Text('A longer term allows a bigger loan.', style: TextStyle(fontSize: 11, color: AppColors.t54)),
            const SizedBox(height: 12),
            if (!possible)
              Text('For $term days you can borrow at most ${fmtCredits(cap)}, below the minimum of ${fmtCredits(minP)}. '
                  'Choose a longer term.', style: const TextStyle(color: Colors.orangeAccent))
            else ...[
              Text('Amount: ${fmtCredits(amount)}', style: const TextStyle(fontWeight: FontWeight.bold)),
              Slider(
                value: amount.toDouble(), min: minP.toDouble(), max: max(minP + 1, cap).toDouble(),
                divisions: steps, label: fmtCredits(amount),
                onChanged: (v) => set(() => amount = ((v / 1000).round() * 1000).clamp(minP, cap)),
              ),
              Text('${fmtCredits(minP)} … ${fmtCredits(cap)}', style: TextStyle(fontSize: 11, color: AppColors.t54)),
              const SizedBox(height: 12),
              Text('Interest ${fmtCredits(interest)} (${(rate * 100).toStringAsFixed(1)}% per week)'),
              Text('You repay ${fmtCredits(amount + interest)}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: possible ? () => popIfCurrent(ctx, true) : null, child: const Text('Request')),
          ],
        );
      }),
    );
    if (ok != true) return;
    await _act('/api/v1/loans/request', {'principal': amount, 'termDays': term}, 'Loan request published');
  }

  /// Global loan market figures (server: /api/v1/loans/stats), one per row.
  Future<void> _marketInfo() async {
    final st = _stats;
    if (st == null) return;
    String c(Object? v) => fmtCredits((v as num? ?? 0).toInt());
    final rows = <(String, String)>[
      ('Active loans', '${st['activeLoans']}'),
      ('Outstanding (still to repay)', c(st['outstanding'])),
      ('Overdue loans', '${st['overdue']}'),
      ('Open requests', '${st['openRequests']} (${c(st['requested'])})'),
      ('Lent in total', c(st['totalLent'])),
      ('Loans funded', '${st['loansFunded']}'),
      ('Repaid loans', '${st['repaidLoans']}'),
      ('Defaults', '${st['defaults']}'),
      ('Defaulted amount', c(st['defaultedAmount'])),
      ('Average loan', c(st['averageLoan'])),
      ('Median loan', c(st['medianLoan'])),
      ('Average rating (active loans)', '${st['averageRating'] ?? '—'}'),
    ];
    await showAppSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
        const Text('Loan market', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final (k, v) in rows)
          ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(k),
              trailing: Text(v, style: const TextStyle(fontWeight: FontWeight.bold))),
      ])),
    );
  }

  Widget _marketButton() => Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.info_outline, size: 18),
          label: const Text('Loan market info'),
          onPressed: _stats == null ? null : _marketInfo,
        ),
      );

  Widget _lendTab() {
    final reqs = (_market!['requests'] as List).cast<Map<String, dynamic>>();
    if (reqs.isEmpty) {
      return RefreshIndicator(onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(8), children: [_marketButton(), const Padding(padding: EdgeInsets.all(24),
              child: Text('No open loan requests right now.', textAlign: TextAlign.center))]));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(8), children: [
        _marketButton(),
        for (final l in reqs)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(l['rating'] as String, style: const TextStyle(fontSize: 11))),
              title: Text('${fmtCredits(l['principal'] as num)} for ${l['term_days']} days'),
              subtitle: Text('Risk ${l['risk']}\n'
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
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Lend ${fmtCredits(l['principal'] as num)}?'),
        content: Text('Rating ${l['rating']}, risk ${l['risk']}.\n'
            'Repayment of ${fmtCredits(l['total'] as num)} is due ${l['term_days']} days after funding. '
            'If it is late, 50% of the borrower\'s output and sales go to you for 30 days; whatever is still '
            'unpaid after that is forgiven.'),
        actions: [
          TextButton(onPressed: () => popIfCurrent(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => popIfCurrent(ctx, true), child: const Text('Lend')),
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
      final status = x['status'] as String;
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${fmtCredits(x['principal'] as num)} · ${x['term_days']} days',
                  style: const TextStyle(fontWeight: FontWeight.bold))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: col(status).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                child: Text(open ? 'waiting for a lender' : status, style: TextStyle(color: col(status), fontSize: 11)),
              ),
            ]),
            const SizedBox(height: 4),
            Text('Rating ${x['rating']} · repaid ${fmtCredits(x['repaid'] as num)} of ${fmtCredits(x['total'] as num)}',
                style: TextStyle(fontSize: 12, color: AppColors.t70)),
            if (x['due_at'] != null)
              Text('Due ${(x['due_at'] as String).substring(0, 16).replaceFirst('T', ' ')} UTC',
                  style: TextStyle(fontSize: 12, color: AppColors.t54)),
            if (borrowed && (owes || open)) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: owes
                    ? FilledButton(onPressed: _busy ? null : () => _act('/api/v1/loans/repay', {'loanID': x['id']}, 'Repayment sent'),
                        child: Text('Repay ${fmtCredits(x['outstanding'] as num)}'))
                    : OutlinedButton(onPressed: _busy ? null : () => _act('/api/v1/loans/cancel', {'loanID': x['id']}, 'Request cancelled'),
                        child: const Text('Cancel request')),
              ),
            ],
          ]),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(8), children: [
        Padding(padding: EdgeInsets.all(8), child: Text('Borrowed', style: TextStyle(color: AppColors.t54))),
        if (b.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No running loans. Finished loans are in the log.')),
        for (final x in b) tile(x, true),
        Padding(padding: EdgeInsets.all(8), child: Text('Lent', style: TextStyle(color: AppColors.t54))),
        if (l.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No money lent right now.')),
        for (final x in l) tile(x, false),
      ]),
    );
  }
}
