import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart' show fmtNum;
import '../models/player_provider.dart';
import '../services/api_service.dart';

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});
  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  List<dynamic> _rows = [];
  bool _loading = true;
  bool _error = false;
  bool _countryFilter = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = false; });
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.getLeaderboard(sid);
    if (mounted) {
      final rows = result?['leaderboard'] as List?;
      setState(() {
        _rows = rows ?? [];
        _error = rows == null;
        _loading = false;
      });
    }
  }

  String? get _myCountry {
    final me = _rows.where((r) => r['isMe'] == true).firstOrNull;
    final code = me?['countryCode'] as String? ?? '';
    return code.isEmpty ? null : code;
  }

  List<dynamic> get _filtered {
    if (!_countryFilter || _myCountry == null) return _rows;
    return _rows.where((r) => r['countryCode'] == _myCountry).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      appBar: ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.cloud_off, size: 40, color: Colors.white38),
                  const SizedBox(height: 8),
                  const Text('Could not load leaderboard',
                      style: TextStyle(color: Colors.white54)),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ]))
          : Column(children: [
              // Filter bar
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(children: [
                  const Text('Leaderboard',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const Spacer(),
                  if (_myCountry != null)
                    FilterChip(
                      label: Text('My country',
                          style: TextStyle(
                            fontSize: 11,
                            color: _countryFilter ? Colors.teal : Colors.white54,
                          )),
                      selected: _countryFilter,
                      onSelected: (v) => setState(() => _countryFilter = v),
                      visualDensity: VisualDensity.compact,
                    ),
                ]),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: filtered.length,
                    itemBuilder: (_, i) {
                      final r = filtered[i];
                      final rank = (r['rank'] as num? ?? i + 1).toInt();
                      final isMe = r['isMe'] == true;
                      final code = r['countryCode'] as String? ?? '';
                      final score = (r['score'] as num? ?? 0).toInt();
                      final xp = (r['xp'] as num? ?? 0).toInt();
                      final activity = (r['activity'] as num? ?? 0).toInt();
                      final level = r['level'] as int? ?? 1;

                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                        decoration: BoxDecoration(
                          color: isMe
                              ? Colors.teal.withValues(alpha: 0.10)
                              : Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(8),
                          border: isMe
                              ? Border.all(color: Colors.teal.withValues(alpha: 0.4))
                              : null,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(children: [
                            // Rank
                            SizedBox(
                              width: 32,
                              child: Text('#$rank',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  color: isMe ? Colors.tealAccent : Colors.white54,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Flag
                            SizedBox(
                              width: 24,
                              child: code.isNotEmpty
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(2),
                                      child: Image.asset(
                                        'assets/images_countryflags/$code.png',
                                        width: 22, height: 15, fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) =>
                                            const Icon(Icons.flag_outlined, size: 16,
                                                color: Colors.white24),
                                      ),
                                    )
                                  : const Icon(Icons.flag_outlined, size: 16,
                                      color: Colors.white24),
                            ),
                            const SizedBox(width: 8),
                            // Name + stats
                            Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(r['name'] as String? ?? '—',
                                style: TextStyle(
                                  fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                                  color: isMe ? Colors.tealAccent : Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Row(children: [
                                Text('Lv $level',
                                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
                                const SizedBox(width: 8),
                                Icon(Icons.bolt, size: 11,
                                    color: activity >= 80
                                        ? Colors.greenAccent : Colors.white38),
                                Text('$activity%',
                                    style: TextStyle(
                                      color: activity >= 80
                                          ? Colors.greenAccent : Colors.white38,
                                      fontSize: 11,
                                    )),
                                const SizedBox(width: 8),
                                Text('${fmtNum(xp)} XP',
                                    style: const TextStyle(
                                        color: Colors.white38, fontSize: 11)),
                              ]),
                            ])),
                            // Score
                            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Text(fmtNum(score),
                                style: TextStyle(
                                  color: isMe ? Colors.tealAccent : Colors.white70,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              const Text('pts',
                                  style: TextStyle(color: Colors.white38, fontSize: 10)),
                            ]),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ]),
    );
  }
}
