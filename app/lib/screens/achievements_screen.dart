import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart' show fmtNum;
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';

import '../app_colors.dart';
/// Achievements: three stars each, progress to the next star (all computed by the server).
class AchievementsScreen extends StatefulWidget {
  const AchievementsScreen({super.key});
  @override
  State<AchievementsScreen> createState() => _AchievementsScreenState();
}

class _AchievementsScreenState extends State<AchievementsScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await GameApi.call('/api/v1/achievements', context.read<PlayerProvider>().sid);
    if (!mounted) return;
    setState(() { _loading = false; _error = r.ok ? null : r.message; if (r.ok) _d = r.data; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 40, title: const Text('Achievements')),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        builder: () {
          final list = (_d!['achievements'] as List).cast<Map<String, dynamic>>();
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(12), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    const Icon(Icons.star, color: Colors.amber, size: 36),
                    const SizedBox(width: 12),
                    Text('${_d!['stars']} / ${_d!['maxStars']} stars',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
              for (final a in list) _tile(a),
            ]),
          );
        },
      ),
    );
  }

  Widget _tile(Map<String, dynamic> a) {
    final tiers = (a['tiers'] as List).cast<num>();
    final stars = (a['stars'] as num).toInt();
    final value = (a['value'] as num);
    final next = a['next'] as num?;
    final prev = stars == 0 ? 0 : tiers[stars - 1];
    final frac = next == null ? 1.0 : ((value - prev) / (next - prev)).clamp(0.0, 1.0).toDouble();
    final unit = (a['unit'] as String? ?? '');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(a['title'] as String, style: const TextStyle(fontWeight: FontWeight.bold))),
            for (var i = 0; i < 3; i++)
              Icon(i < stars ? Icons.star : Icons.star_border, size: 20,
                  color: i < stars ? Colors.amber : Colors.white24),
          ]),
          Text(a['description'] as String, style: TextStyle(fontSize: 12, color: AppColors.t54)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: frac, minHeight: 6, backgroundColor: Colors.white12,
                color: next == null ? Colors.amber : AppColors.accent),
          ),
          const SizedBox(height: 4),
          Text('${a['label'] ?? unit}: ${fmtNum(value)} / ${fmtNum(next ?? tiers.last)}',
              style: TextStyle(fontSize: 12, color: AppColors.t70)),
        ]),
      ),
    );
  }
}
