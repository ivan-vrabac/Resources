import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/player_provider.dart';
import '../../services/api_service.dart';
import '../../services/storage_service.dart';
import '../login_screen.dart';
import '../factory_screen.dart';
import '../leaderboard_screen.dart';
import '../market_screen.dart';
import '../log_screen.dart';

import '../../app_colors.dart';
import '../../services/game_api.dart';
import '../../widgets/popups.dart';
import '../../constants.dart';
class MoreTab extends StatefulWidget {
  const MoreTab({super.key});
  @override
  State<MoreTab> createState() => _MoreTabState();
}

class _MoreTabState extends State<MoreTab> {
  String? _countryCode = ApiService.countryNow;   // cached: the flag shows at once
  int? _rank;

  @override
  void initState() {
    super.initState();
    _loadCountry();
    _loadRank();
  }

  Future<void> _loadCountry() async {
    final had = _countryCode;
    final code = await ApiService.getCountryCode();
    if (mounted && code != null && code != had) {
      setState(() => _countryCode = code);
      final sid = context.read<PlayerProvider>().sid;
      ApiService.setCountryCode(sid, code);
    }
  }

  Future<void> _loadRank() async {
    final sid = context.read<PlayerProvider>().sid;
    if (sid.isEmpty) return;
    final result = await ApiService.getLeaderboard(sid);
    if (!mounted) return;
    final rows = result?['leaderboard'] as List? ?? [];
    final me = rows.where((r) => r['isMe'] == true).firstOrNull;
    if (me != null) setState(() => _rank = me['rank'] as int?);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>().player;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (player != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                if (_countryCode != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.asset(
                      'assets/images_countryflags/$_countryCode.png',
                      width: 60, height: 40, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _fallbackAvatar(player),
                    ),
                  )
                else
                  _fallbackAvatar(player),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(player.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  if (_rank != null)
                    Text('Rank #$_rank', style: TextStyle(color: AppColors.accent, fontSize: 12))
                  else
                    Text('Loading rank...', style: TextStyle(color: AppColors.t38, fontSize: 12)),
                  const SizedBox(height: 4),
                  InkWell(onTap: () => showWorkingAtmosphere(context), child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('WA ', style: TextStyle(color: AppColors.t38, fontSize: 11)),
                    _waColor(player.wa) != null
                        ? Text('${player.wa}%',
                            style: TextStyle(
                              color: _waColor(player.wa),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ))
                        : const SizedBox.shrink(),
                    Icon(Icons.info_outline, size: 12, color: AppColors.t38),
                  ])),

                ])),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LeaderboardScreen())),
                  child: const Text('Leaderboard'),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
        ],

        _sectionTitle('Game'),
        _tile(context, Icons.factory_outlined, 'Factories',
            'Build and manage production factories', const FactoryScreen()),
        _tile(context, Icons.storefront_outlined, 'Market',
            'Buy and sell resources', const MarketScreen()),
        _tile(context, Icons.history, 'Activity Log',
            'View recent game events', const LogScreen()),

        const SizedBox(height: 16),
        _sectionTitle('Account'),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.red),
          title: const Text('Log out'),
          subtitle: const Text('Sign in as a different company'),
          onTap: () async {
            await StorageService.clearHid();
            if (!context.mounted) return;
            context.read<PlayerProvider>().clear();
            Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginScreen()));
          },
        ),
      ],
    );
  }

  Color? _waColor(int wa) {
    if (wa >= 70) return AppColors.accent;   // good WA in the appearance colour
    if (wa >= 40) return Colors.amber;
    return Colors.redAccent;
  }

  Widget _fallbackAvatar(dynamic player) => CircleAvatar(
    backgroundColor: AppColors.accent, radius: 24,
    child: Text(
      player.name.isNotEmpty ? player.name[0].toUpperCase() : '?',
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
    ),
  );

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(title.toUpperCase(),
        style: TextStyle(fontSize: 11, color: AppColors.t38, letterSpacing: 1.2)),
  );

  Widget _tile(BuildContext context, IconData icon, String title,
      String subtitle, Widget screen) {
    return ListTile(
      leading: Icon(icon, color: AppColors.accent),
      title: Text(title),
      subtitle: Text(subtitle, style: TextStyle(color: AppColors.t38, fontSize: 12)),
      trailing: Icon(Icons.chevron_right, color: AppColors.t38),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
    );
  }
}


/// Working atmosphere: current value, today's accident chance and the latest accidents
/// (server: /api/v1/incidents). Penalty rules stay a secret; only what happened is shown.
Future<void> showWorkingAtmosphere(BuildContext context) async {
  final r = await GameApi.call('/api/v1/incidents', context.read<PlayerProvider>().sid);
  if (!context.mounted || !r.ok) return;
  final list = (r.data['incidents'] as List).cast<Map<String, dynamic>>();
  const names = {'fire': 'Factory fire', 'strike': 'Strike', 'disease': 'Disease at a mine', 'earthquake': 'Earthquake'};
  await showAppSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Working atmosphere: ${(r.data['wa'] as num).toStringAsFixed(1)}%',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text('Chance of an accident today: about ${r.data['chancePerDay']}% per factory. '
            'Idle factories, accidents and attacks lower the atmosphere; finished quests raise it. '
            'Accidents cost money, and the Law Firm softens them.',
            style: TextStyle(fontSize: 12, color: AppColors.t60)),
        if ((r.data['strikes'] as num? ?? 0) > 0)
          Padding(padding: const EdgeInsets.only(top: 6),
              child: Text('${r.data['strikes']} factory(ies) on strike', style: const TextStyle(color: Colors.orangeAccent))),
        const SizedBox(height: 10),
        Text('Recent accidents', style: TextStyle(fontSize: 12, color: AppColors.t54)),
        if (list.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('None so far.')),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.4),
          child: ListView(shrinkWrap: true, children: [
            for (final i in list)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warning_amber, color: Colors.redAccent, size: 18),
                title: Text(names[i['kind']] ?? '${i['kind']}'),
                subtitle: Text((i['ts'] as String).replaceFirst('T', ' ').substring(0, 16)),
                trailing: (i['penalty'] as num? ?? 0) > 0
                    ? Text('−ꞓ${fmtNum((i['penalty'] as num).toInt())}', style: const TextStyle(color: Colors.redAccent))
                    : null,
              ),
          ]),
        ),
      ]),
    )),
  );
}

