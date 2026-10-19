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

  /// Own mine: show its defence and station watch dogs / security staff / elite force on it.
  static Future<void> openDefence(BuildContext context, String mineId) async {
    final sid = context.read<PlayerProvider>().sid;
    final info = await GameApi.call('/api/v1/combat/info', sid, {'mineID': mineId});
    if (!context.mounted) return;
    if (!info.ok) {
      AppNotify.show(context, info.message ?? 'Unavailable', isError: true);
      return;
    }
    final res = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => _DefenceDialog(info: info.data));
    if (res == null || !context.mounted) return;
    final r = await GameApi.call('/api/v1/combat/station', sid, {'mineID': mineId, ...res});
    if (!context.mounted) return;
    AppNotify.show(context, r.ok ? 'Units stationed — they stay on this mine' : (r.message ?? 'Failed'), isError: !r.ok);
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

/// One unit type: item image, value, owned count, and a number field (any amount) with "all".
class _UnitQtyRow extends StatefulWidget {
  final int itemId;
  final String name;
  final num value;
  final int have;
  final bool showValue;
  final ValueChanged<int> onChanged;
  const _UnitQtyRow({required this.itemId, required this.name, required this.value, required this.have,
      required this.onChanged, this.showValue = true});
  @override
  State<_UnitQtyRow> createState() => _UnitQtyRowState();
}

class _UnitQtyRowState extends State<_UnitQtyRow> {
  final _ctl = TextEditingController();

  void _set(int v) {
    v = v.clamp(0, widget.have);
    final t = v == 0 ? '' : '$v';
    if (_ctl.text != t) _ctl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    widget.onChanged(v);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        ItemIcon(widget.itemId, size: 32),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
          Text(widget.showValue ? 'value ${widget.value} · have ${fmtQty(widget.have)}' : 'you have ${fmtQty(widget.have)}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ])),
        SizedBox(
          width: 96,
          child: TextField(
            controller: _ctl,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(isDense: true, hintText: '0'),
            onChanged: (t) => _set(int.tryParse(t.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0),
          ),
        ),
        TextButton(onPressed: widget.have == 0 ? null : () => _set(widget.have), child: const Text('all')),
      ]),
    );
  }
}

class _AttackDialog extends StatefulWidget {
  final Map<String, dynamic> info;
  const _AttackDialog({required this.info});
  @override
  State<_AttackDialog> createState() => _AttackDialogState();
}

class _AttackDialogState extends State<_AttackDialog> {
  static const _units = [(102, 'dogs', 'Attack Dogs'), (103, 'gangsters', 'Gangsters'), (104, 'army', 'Private Army')];
  final _n = <String, int>{'dogs': 0, 'gangsters': 0, 'army': 0};

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    final have = (i['units'] as Map).cast<String, dynamic>();
    final target = (i['target'] as Map?)?.cast<String, dynamic>() ?? {};
    final def = (target['defence'] as List?) ?? [0, 0, 0];
    final exact = target['defenceExact'] == true;
    final atk = (i['attackValues'] as List?) ?? [0, 0, 0];
    final mafia = (i['mafiaLevel'] as num? ?? 0).toInt();
    final p = exact ? '' : '~';
    return AlertDialog(
      title: const Text('Attack mine'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (mafia < 1)
            const Text('You need a Mafia HQ (Special Buildings) to attack.', style: TextStyle(color: Colors.orange)),
          Text('Mafia HQ $mafia · range ${(i['attackRange'] as num).round()} m', style: const TextStyle(fontSize: 12)),
          Text('Defence: $p${def[0]} watch dogs · $p${def[1]} security staff · $p${def[2]} elite'
              '${target['inHqArea'] == true ? ' (HQ area +25%)' : ''}', style: const TextStyle(fontSize: 12)),
          if (!exact)
            const Text('Estimate — a Mafia HQ level 10 shows the exact numbers.',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
          Text('Loot if successful: up to ${fmtQty(target['lootEstimate'] as num? ?? 0)}'
              ' (halved for each successful attack you made in the last 24 h)',
              style: const TextStyle(fontSize: 12, color: Colors.white70)),
          const Text('Every attack damages the mine 10–70 points depending on the force sent (less if repelled). '
              'A mine can be attacked once every 24 hours.', style: TextStyle(fontSize: 11, color: Colors.white54)),
          const SizedBox(height: 8),
          for (var k = 0; k < _units.length; k++)
            _UnitQtyRow(
              itemId: _units[k].$1, name: _units[k].$3, value: atk[k] as num,
              have: (have['${_units[k].$1}'] as num? ?? 0).toInt(),
              onChanged: (v) => setState(() => _n[_units[k].$2] = v),
            ),
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
}

class _ResultDialog extends StatelessWidget {
  final Map<String, dynamic> r;
  const _ResultDialog({required this.r});

  @override
  Widget build(BuildContext context) {
    final ok = r['success'] == true;
    final sent = (r['sent'] as List).cast<num>(), left = (r['attackersLeft'] as List).cast<num>();
    final deserters = (r['deserters'] as List? ?? []).fold<num>(0, (a, b) => a + (b as num));
    return AlertDialog(
      title: Text(ok ? 'Attack successful' : 'Attack repelled', style: TextStyle(color: ok ? Colors.green : Colors.red)),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Units returned: ${left.reduce((a, b) => a + b)} of ${sent.reduce((a, b) => a + b)}'),
        Text(r['destroyed'] == true ? 'The mine was demolished.' : 'Damage: ${r['damage']} points → ${r['condition']}%'),
        if (ok) Text('Loot: ${fmtQty(r['loot'] as num? ?? 0)}'
            '${(r['lootHalvings'] as num? ?? 0) > 0 ? ' (halved ${r['lootHalvings']}× for recent attacks)' : ''}'),
        if (!ok && deserters > 0) Text('Deserters joined the defender: $deserters'),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    );
  }
}

class _DefenceDialog extends StatefulWidget {
  final Map<String, dynamic> info;
  const _DefenceDialog({required this.info});
  @override
  State<_DefenceDialog> createState() => _DefenceDialogState();
}

class _DefenceDialogState extends State<_DefenceDialog> {
  static const _units = [(95, 'dogs', 'Watch Dogs'), (97, 'staff', 'Security Staff'), (98, 'elite', 'Elite Force')];
  final _n = <String, int>{'dogs': 0, 'staff': 0, 'elite': 0};

  @override
  Widget build(BuildContext context) {
    final have = (widget.info['units'] as Map).cast<String, dynamic>();
    final t = (widget.info['target'] as Map).cast<String, dynamic>();
    final def = (t['defence'] as List?) ?? [0, 0, 0];
    Widget now(int item, Object n) => Expanded(
          child: Column(children: [
            ItemIcon(item, size: 28),
            Text(fmtQty(n as num), style: const TextStyle(fontWeight: FontWeight.bold)),
          ]),
        );
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Row(children: [
        const Expanded(child: Text('Mine defence')),
        if (t['inHqArea'] == true)
          const Chip(label: Text('HQ area +25%', style: TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact),
      ]),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Defending now', style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 6),
            Row(children: [now(95, def[0]), now(97, def[1]), now(98, def[2])]),
            const Divider(height: 24),
            const Text('Station more', style: TextStyle(color: Colors.white54, fontSize: 12)),
            for (var k = 0; k < _units.length; k++)
              _UnitQtyRow(
                itemId: _units[k].$1, name: _units[k].$3, value: 0, showValue: false,
                have: (have['${_units[k].$1}'] as num? ?? 0).toInt(),
                onChanged: (v) => setState(() => _n[_units[k].$2] = v),
              ),
            const SizedBox(height: 8),
            const Text('Stationed units stay on the mine and make its repairs more expensive. '
                'The free 200 / 5 / 1 guards come back after a repair.',
                style: TextStyle(fontSize: 11, color: Colors.white38)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _n.values.every((v) => v == 0) ? null : () => Navigator.pop(context, _n),
            child: const Text('Station')),
      ],
    );
  }
}
