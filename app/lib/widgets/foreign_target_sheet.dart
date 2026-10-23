import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../constants.dart';
import '../screens/profile_screen.dart';

import '../app_colors.dart';
/// Sheet for another player's mine or HQ tapped on the map: owner, basic state, profile link.
/// Later phases add actions here (external repair, attack) through [extraActions].
class ForeignTargetSheet extends StatelessWidget {
  final Map<String, dynamic> target;
  final VoidCallback onChanged;
  final LatLng? playerPos;
  static final List<Widget Function(BuildContext, Map<String, dynamic>, LatLng?, VoidCallback)>
      extraActions = [];

  const ForeignTargetSheet({super.key, required this.target, required this.onChanged, this.playerPos});

  @override
  Widget build(BuildContext context) {
    final isHq = target['type'] == 'hq';
    final owner = target['ownerName'] as String? ?? '?';
    final pid = target['ownerHID'] as String? ?? '';
    final itemId = (target['itemID'] as num?)?.toInt() ?? 0;
    final cond = (target['cond'] as num?)?.toDouble();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(isHq ? Icons.location_city : Icons.construction, color: AppColors.t70),
            const SizedBox(width: 8),
            Expanded(child: Text(
              isHq ? 'Headquarters (level ${target['lvl']})' : (kMineNames[itemId] ?? 'Mine'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
            )),
            if (cond != null)
              Text('${cond.ceil()}%', style: TextStyle(
                  color: cond > 60 ? Colors.green : cond > 30 ? Colors.orange : Colors.red)),
          ]),
          const SizedBox(height: 4),
          Text('Owner: $owner', style: TextStyle(color: AppColors.t70)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.person_outline, size: 16),
              label: Text('View $owner'),
              onPressed: pid.isEmpty ? null : () {
                Navigator.pop(context);
                ProfileScreen.open(context, pid);
              },
            ),
          ),
          for (final b in extraActions) b(context, target, playerPos, onChanged),
        ]),
      ),
    );
  }
}
