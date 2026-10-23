import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart' show itemName;
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';

/// Daily quests (48 h each), rewards and the streak with its Giant Diamond milestones.
class QuestsScreen extends StatefulWidget {
  const QuestsScreen({super.key});
  @override
  State<QuestsScreen> createState() => _QuestsScreenState();
}

class _QuestsScreenState extends State<QuestsScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String? _error;
  int? _claiming;

  String get _sid => context.read<PlayerProvider>().sid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await GameApi.call('/api/v1/quests', _sid);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = r.ok ? null : r.message;
      if (r.ok) _d = r.data;
    });
  }

  Future<void> _claim(Map<String, dynamic> q) async {
    setState(() => _claiming = q['id'] as int);
    final r = await GameApi.call('/api/v1/quests/claim', _sid, {'id': q['id']});
    if (!mounted) return;
    setState(() => _claiming = null);
    if (!r.ok) {
      AppNotify.show(context, r.message ?? 'Failed', isError: true);
    } else {
      final ms = (r.data['milestones'] as List? ?? const []).cast<Map<String, dynamic>>();
      final extra = ms.isEmpty
          ? ''
          : ' · Streak: ${ms.map((m) => '${m['qty']} ${itemName((m['itemID'] as num).toInt())}').join(', ')}';
      AppNotify.show(context, 'Reward: ${fmtCredits(r.data['credits'] as num)} + ${r.data['crates']} Cargo Rain$extra');
      context.read<PlayerProvider>().refresh();
    }
    _load();
  }

  /// Everything quests pay: per quest, per streak day, and the streak milestones.
  void _showRewards(Map<String, dynamic> plan, int streak) {
    final perQuest = (plan['perQuest'] as List? ?? const []).cast<Map<String, dynamic>>();
    final daily = (plan['daily'] as List? ?? const []).cast<Map<String, dynamic>>();
    final ms = (plan['milestones'] as List? ?? const []).cast<Map<String, dynamic>>();
    final bonus = (plan['aeonBonus'] as num? ?? 0);
    Widget row(Widget icon, String title, String value, {bool active = false}) => ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: icon,
          title: Text(title, style: TextStyle(color: active ? Colors.amberAccent : null)),
          trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        );
    Widget header(String t) => Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 2),
          child: Text(t.toUpperCase(), style: const TextStyle(fontSize: 11, color: Colors.white54, letterSpacing: 1)),
        );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A2E),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Quest rewards', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              header('Every quest'),
              for (final r in perQuest)
                r['cargo'] == true
                    ? row(Image.asset('assets/mapmarkers/boxrainicon.png', width: 32, height: 32,
                          errorBuilder: (_, __, ___) => const Icon(Icons.inventory_2_outlined)),
                        'Cargo Rain crates', '${r['qty']}')
                    : row(const Icon(Icons.monetization_on_outlined, color: Colors.amber), 'Credits',
                        fmtCredits(r['qty'] as num)),
              if (bonus > 0)
                Text('includes your Aeon Mechanism bonus +${(bonus * 100).round()}%',
                    style: const TextStyle(fontSize: 11, color: Colors.white38)),
              header('Every streak day (all quests of the day done)'),
              for (final r in daily)
                row(ItemIcon((r['itemID'] as num).toInt(), size: 32),
                    r['to'] == null ? 'Day ${r['from']} and every day after'
                        : r['from'] == r['to'] ? 'Day ${r['from']}' : 'Days ${r['from']}–${r['to']}',
                    '${r['qty']} × ${itemName((r['itemID'] as num).toInt())}',
                    active: streak + 1 >= (r['from'] as num) && (r['to'] == null || streak + 1 <= (r['to'] as num))),
              header('Streak milestones'),
              for (final m in ms)
                row(ItemIcon((m['itemID'] as num).toInt(), size: 32), 'Every ${m['every']} days',
                    '${m['qty']} × ${itemName((m['itemID'] as num).toInt())}'),
              const SizedBox(height: 8),
              const Text('Missing a day will not end your streak, but missing two days in a row will.',
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
            ]),
          ),
        ),
      ),
    );
  }

  String _left(String iso) {
    final d = DateTime.parse('${iso}Z').difference(DateTime.now().toUtc());
    if (d.isNegative) return 'expired';
    return d.inHours >= 1 ? '${d.inHours} h left' : '${d.inMinutes} min left';
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView(
      loading: _loading,
      error: _error,
      onRetry: _load,
      builder: () {
        final d = _d!;
        final qs = (d['quests'] as List).cast<Map<String, dynamic>>();
        final streak = d['streak'] as int? ?? 0;
        final next = d['nextMilestone'] as int? ?? 7;
        final reward = d['reward'] as Map<String, dynamic>? ?? const {};
        final cs = Theme.of(context).colorScheme;
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Icon(Icons.local_fire_department, color: streak > 0 ? Colors.orangeAccent : Colors.white24, size: 36),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('$streak-day streak', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('Finish all of a day\'s quests to extend it. Next bonus at day $next.',
                        style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  ])),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.card_giftcard, size: 16),
                    label: const Text('Rewards'),
                    onPressed: () => _showRewards(d['rewardPlan'] as Map<String, dynamic>? ?? const {}, streak),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Text('Each quest: ${fmtCredits(reward['credits'] as num? ?? 0)} + ${reward['crates'] ?? 15} Cargo Rain',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 8),
            if (qs.isEmpty)
              const Padding(padding: EdgeInsets.all(24),
                  child: Center(child: Text('No quests right now', style: TextStyle(color: Colors.white54)))),
            for (final q in qs)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(q['title'] as String,
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(q['claimed'] == true ? 'done' : _left(q['expiresAt'] as String),
                          style: const TextStyle(fontSize: 11, color: Colors.white54)),
                    ]),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (q['progress'] as num) / (q['target'] as num),
                        minHeight: 8,
                        backgroundColor: Colors.white12,
                        color: q['claimed'] == true ? Colors.greenAccent : cs.primary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(children: [
                      Text('${q['progress']} / ${q['target']}', style: const TextStyle(fontSize: 12)),
                      if ((q['day'] as String) != (qs.first['day'] as String))
                        const Text('  · from yesterday', style: TextStyle(fontSize: 11, color: Colors.white38)),
                      const Spacer(),
                      if (q['claimed'] == true)
                        const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20)
                      else
                        FilledButton(
                          onPressed: q['claimable'] == true && _claiming == null ? () => _claim(q) : null,
                          child: _claiming == q['id']
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Claim'),
                        ),
                    ]),
                  ]),
                ),
              ),
          ]),
        );
      },
    );
  }
}
