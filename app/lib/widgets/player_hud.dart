import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart' show fmtNum;
import '../models/player_provider.dart';
import '../screens/profile_screen.dart';
import '../screens/settings_screen.dart' show mapPanelOpacityNotifier;

class PlayerHud extends StatelessWidget {
  const PlayerHud({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>().player;
    if (player == null) return const SizedBox();
    // tap the bar (name, credits, level, XP) to open your own company stats
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
      child: ValueListenableBuilder<double>(
      valueListenable: mapPanelOpacityNotifier,
      builder: (context, opacity, _) => Container(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: opacity.clamp(0.0, 1.0)),
        padding: EdgeInsets.fromLTRB(
            12, MediaQuery.of(context).padding.top + 6, 12, 0),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: Text(player.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  overflow: TextOverflow.ellipsis),
            ),
            _stat(Icons.monetization_on_outlined, 'ꞓ${fmtNum(player.credits)}', Colors.amber),
            const SizedBox(width: 12),
            _stat(Icons.military_tech_outlined, 'Lv ${player.level}', Colors.lightBlueAccent),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: player.xpProgress,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.greenAccent),
                  minHeight: 3,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${(player.xpProgress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 9, color: Colors.white38),
            ),
          ]),
          const SizedBox(height: 6),
        ]),
      ),
      ),
    );
  }

  Widget _stat(IconData icon, String label, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 2),
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
    ],
  );
}
