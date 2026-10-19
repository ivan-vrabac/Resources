import 'dart:math';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import 'async_view.dart';
import 'foreign_target_sheet.dart';
import 'top_banner.dart';

/// Phase 6 actions on another player's mine: free external maintenance (Service Center) and
/// mafia attacks. Registered once into [ForeignTargetSheet.extraActions].
class CombatActions {
  static bool _registered = false;

  static void register() {
    if (_registered) return;
    _registered = true;
    ForeignTargetSheet.extraActions.add(_build);
  }

  static Widget _build(BuildContext context, Map<String, dynamic> t, LatLng? pos, VoidCallback onChanged) {
    if (t['type'] == 'hq' || t['mID'] == null) return const SizedBox.shrink();
    final cond = (t['cond'] as num?)?.toDouble() ?? 100;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.build_outlined, size: 16),
            label: const Text('Maintain'),
            onPressed: cond > 96 || pos == null ? null : () => _repair(context, t, pos, onChanged),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade800),
            icon: const Icon(Icons.gpp_bad_outlined, size: 16),
            label: const Text('Attack'),
            onPressed: pos == null ? null : () => _attack(context, t, pos, onChanged),
          ),
        ),
      ]),
    );
  }

  static Future<void> _repair(BuildContext context, Map<String, dynamic> t, LatLng pos, VoidCallback onChanged) async {
    final sid = context.read<PlayerProvider>().sid;
    final r = await GameApi.call('/api/v1/service/repair', sid,
        {'mineID': t['mID'], 'lat': pos.latitude, 'lng': pos.longitude});
    if (!context.mounted) return;
    if (r.ok) {
      final q = (r.data['rewardQty'] as num? ?? 0);
      final crates = (r.data['crates'] as num? ?? 0).toInt();
      AppNotify.show(context, 'Mine maintained.'
          '${q > 0 ? ' Reward: ${fmtQty(q)}' : ''}${crates > 0 ? ' + $crates crates' : ''}');
      Navigator.pop(context);
      onChanged();
    } else {
      AppNotify.show(context, r.message ?? 'Maintenance failed', isError: true);
    }
  }

  static Future<void> _attack(BuildContext context, Map<String, dynamic> t, LatLng pos, VoidCallback onChanged) async {
    final sid = context.read<PlayerProvider>().sid;
    final info = await GameApi.call('/api/v1/combat/info', sid, {'mineID': t['mID']});
    if (!context.mounted) return;
    if (!info.ok) {
      AppNotify.show(context, info.message ?? 'Unavailable', isError: true);
      return;
    }
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _AttackDialog(info: info.data),
    );
    if (res == null || !context.mounted) return;
    final r = await GameApi.call('/api/v1/combat/attack', sid, {
      'mineID': t['mID'], 'lat': pos.latitude, 'lng': pos.longitude,
      'dogs': res['dogs'], 'gangsters': res['gangsters'], 'army': res['army'],
      'rid': '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(1 << 20)}',
    });
    if (!context.mounted) return;
    if (!r.ok) {
      AppNotify.show(context, r.message ?? 'Attack failed', isError: true);
      return;
    }
    Navigator.pop(context);
    onChanged();
    await showDialog(context: context, builder: (_) => _ResultDialog(r: r.data));
  }
}

class _AttackDialog extends StatefulWidget {
  final Map<String, dynamic> info;
  const _AttackDialog({required this.info});
  @override
  State<_AttackDialog> createState() => _AttackDialogState();
}

class _AttackDialogState extends State<_AttackDialog> {
  static const _units = [('102', 'dogs', 'Attack Dogs'), ('103', 'gangsters', 'Gangsters'), ('104', 'army', 'Private Army')];
  final _n = <String, int>{'dogs': 0, 'gangsters': 0, 'army': 0};

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    final have = (i['units'] as Map).cast<String, dynamic>();
    final target = (i['target'] as Map?)?.cast<String, dynamic>() ?? {};
    final def = (target['defence'] as List?) ?? [0, 0, 0];
    final atk = (i['attackValues'] as List?) ?? [0, 0, 0];
    final mafia = (i['mafiaLevel'] as num? ?? 0).toInt();
    return AlertDialog(
      title: const Text('Attack mine'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (mafia < 1)
            const Text('You need a Mafia HQ (Special Buildings) to attack.', style: TextStyle(color: Colors.orange)),
          Text('Mafia HQ $mafia · range ${(i['attackRange'] as num).round()} m', style: const TextStyle(fontSize: 12)),
          Text('Defence: ${def[0]} watch dogs · ${def[1]} security staff · ${def[2]} elite'
              '${target['inHqArea'] == true ? ' (HQ area +25%)' : ''}', style: const TextStyle(fontSize: 12)),
          Text('Loot if successful: up to ${fmtQty(target['lootEstimate'] as num? ?? 0)}',
              style: const TextStyle(fontSize: 12, color: Colors.white70)),
          const SizedBox(height: 8),
          for (var k = 0; k < _units.length; k++)
            _unitRow(_units[k], (have[_units[k].$1] as num? ?? 0).toInt(), atk[k] as num),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: mafia < 1 || _n.values.every((v) => v == 0) ? null : () => Navigator.pop(context, _n),
          child: const Text('Attack'),
        ),
      ],
    );
  }

  Widget _unitRow((String, String, String) u, int have, num value) {
    final v = _n[u.$2]!;
    return Row(children: [
      Expanded(child: Text('${u.$3}\nvalue $value · have $have', style: const TextStyle(fontSize: 12))),
      IconButton(icon: const Icon(Icons.remove), onPressed: v == 0 ? null : () => setState(() => _n[u.$2] = max(0, v - 10))),
      SizedBox(width: 44, child: Text('$v', textAlign: TextAlign.center)),
      IconButton(icon: const Icon(Icons.add), onPressed: v >= have ? null : () => setState(() => _n[u.$2] = min(have, v + 10))),
      TextButton(onPressed: have == 0 ? null : () => setState(() => _n[u.$2] = have), child: const Text('all')),
    ]);
  }
}

class _ResultDialog extends StatelessWidget {
  final Map<String, dynamic> r;
  const _ResultDialog({required this.r});

  @override
  Widget build(BuildContext context) {
    final ok = r['success'] == true;
    final sent = (r['sent'] as List).cast<num>(), left = (r['attackersLeft'] as List).cast<num>();
    return AlertDialog(
      title: Text(ok ? 'Attack successful' : 'Attack repelled', style: TextStyle(color: ok ? Colors.green : Colors.red)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Units returned: ${left.reduce((a, b) => a + b)} of ${sent.reduce((a, b) => a + b)}'),
        if (ok) ...[
          Text(r['destroyed'] == true ? 'The mine was demolished.' : 'Damage: ${r['damage']}% → ${r['condition']}%'),
          Text('Loot: ${fmtQty(r['loot'] as num? ?? 0)}'),
        ] else
          Text('Deserters joined the defender: ${(r['deserters'] as List? ?? []).fold<num>(0, (a, b) => a + (b as num))}'),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    );
  }
}
