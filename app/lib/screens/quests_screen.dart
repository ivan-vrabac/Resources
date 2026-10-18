import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
          : ' · Streak bonus: ${ms.map((m) => '${m['diamonds']} Giant Diamonds (${m['days']} days)').join(', ')}';
      AppNotify.show(context, 'Reward: ${fmtCredits(r.data['credits'] as num)} + ${r.data['crates']} Cargo Rain$extra');
      context.read<PlayerProvider>().refresh();
    }
    _load();
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
                    const SizedBox(height: 4),
                    const Text('Every 7 days: 5 Giant Diamonds · every 30 days: 10 Giant Diamonds',
                        style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
                  ])),
                  const ItemIcon(42, size: 32),
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
