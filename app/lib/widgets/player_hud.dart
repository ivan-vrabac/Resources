import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart' show fmtNum;
import '../models/player_provider.dart';
import '../screens/settings_screen.dart' show mapPanelOpacityNotifier;

import '../app_colors.dart';
class PlayerHud extends StatelessWidget {
  /// Tap on the bar (name, credits, level, XP): the game screen opens the Stats tab.
  final VoidCallback? onTap;
  const PlayerHud({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<PlayerProvider>();
    final player = prov.player;
    if (player == null) return const SizedBox();
    // tap the bar (name, credits, level, XP) to open your own company stats
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
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
            // a negative balance (after penalties) is shown in red
            _stat(Icons.monetization_on_outlined, 'ꞓ${fmtNum(prov.credits)}', Colors.amber,
                textColor: prov.credits < 0 ? Colors.redAccent : null),
            const SizedBox(width: 12),
            _stat(Icons.military_tech_outlined, 'Lv ${player.level}', AppColors.accent),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: player.xpProgress,
                  backgroundColor: AppColors.fg.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                  minHeight: 3,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${(player.xpProgress * 100).toStringAsFixed(0)}%',
              style: TextStyle(fontSize: 9, color: AppColors.t38),
            ),
          ]),
          const SizedBox(height: 6),
        ]),
      ),
      ),
    );
  }

  Widget _stat(IconData icon, String label, Color color, {Color? textColor}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 2),
      Text(label, style: TextStyle(fontSize: 12, color: textColor ?? AppColors.t70,
          fontWeight: textColor != null ? FontWeight.bold : null)),
    ],
  );
}
