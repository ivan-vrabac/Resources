import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../constants.dart' show itemName;
import '../models/player_provider.dart';
import '../services/game_api.dart';
import 'async_view.dart';
import 'top_banner.dart';

import '../app_colors.dart';
import 'popups.dart';

/// Mafia HQ trains attack units, Army Camp defence units; paid in resources, cheaper per level
/// (server: combat.train_cost).
Future<void> showTrainTroops(BuildContext context, int buildingId) async {
  final sid = context.read<PlayerProvider>().sid;
  final r = await GameApi.call('/api/v1/combat/training', sid, {'building': '$buildingId'});
  if (!context.mounted) return;
  if (!r.ok) {
    AppNotify.show(context, r.message ?? 'Unavailable', isError: true);
    return;
  }
  await showAppDialog<void>(context: context, builder: (_) => _TrainDialog(info: r.data));
}

class _TrainDialog extends StatefulWidget {
  final Map<String, dynamic> info;
  const _TrainDialog({required this.info});
  @override
  State<_TrainDialog> createState() => _TrainDialogState();
}

class _TrainDialogState extends State<_TrainDialog> {
  late final List<Map<String, dynamic>> _units =
      (widget.info['units'] as List).cast<Map<String, dynamic>>();
  int _sel = 0;
  final _qty = TextEditingController(text: '1');
  bool _busy = false;

  int get _n => int.tryParse(_qty.text.trim()) ?? 0;

  Map<int, double> _perUnit() => (_units[_sel]['cost'] as Map).map(
      (k, v) => MapEntry(int.parse(k.toString()), (v as num).toDouble()));

  int _need(double perUnit, int n) => (perUnit * n - 1e-9).ceil();

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  Future<void> _train() async {
    setState(() => _busy = true);
    final unit = _units[_sel]['unit'] as int;
    final pp = context.read<PlayerProvider>();
    final r = await GameApi.call('/api/v1/combat/train', pp.sid, {'unit': '$unit', 'qty': '$_n'});
    if (!mounted) return;
    setState(() => _busy = false);
    AppNotify.show(context, r.ok ? 'Trained ${fmtQty(_n)} ${itemName(unit)}' : (r.message ?? 'Failed'), isError: !r.ok);
    if (r.ok) {
      _units[_sel]['have'] = ((_units[_sel]['have'] as num) + _n);
      await pp.refresh();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final lager = context.watch<PlayerProvider>().player?.lager ?? const <String, double>{};
    final level = widget.info['level'] as int? ?? 0;
    final per = _perUnit();
    final most = per.entries.fold<int>(1 << 30, (m, e) => min(m, ((lager['${e.key}'] ?? 0) / e.value + 1e-9).floor()));
    final n = _n;
    final enough = n > 0 && per.entries.every((e) => (lager['${e.key}'] ?? 0) >= _need(e.value, n));
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('Train troops'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (level < 1)
              Text('Build this first to train troops.', style: TextStyle(color: Colors.red.shade300, fontSize: 12)),
            Row(children: [
              for (var k = 0; k < _units.length; k++)
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => _sel = k),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: k == _sel ? AppColors.accent : Colors.transparent, width: 2),
                      ),
                      child: Column(children: [
                        ItemIcon(_units[k]['unit'] as int, size: 36),
                        Text(itemName(_units[k]['unit'] as int),
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
                        Text('have ${fmtQty(_units[k]['have'] as num)}',
                            style: TextStyle(fontSize: 10, color: AppColors.t38)),
                      ]),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'How many', isDense: true),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: most < 1 ? null : () => setState(() => _qty.text = '${min(most, 100000)}'),
                child: Text('Max ${fmtQty(min(most, 100000))}'),
              ),
            ]),
            const SizedBox(height: 10),
            Text('Cost', style: TextStyle(color: AppColors.t54, fontSize: 12)),
            for (final e in per.entries)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  ItemIcon(e.key, size: 20),
                  const SizedBox(width: 6),
                  Expanded(child: Text(itemName(e.key), style: const TextStyle(fontSize: 13))),
                  Text('${fmtQty(_need(e.value, max(n, 1)))} / ${fmtQty(lager['${e.key}'] ?? 0)}',
                      style: TextStyle(fontSize: 13,
                          color: (lager['${e.key}'] ?? 0) >= _need(e.value, max(n, 1)) ? AppColors.t54 : Colors.red)),
                ]),
              ),
            const SizedBox(height: 8),
            Text('Higher levels train for fewer resources; at level 10 it is cheaper than the market.',
                style: TextStyle(fontSize: 11, color: AppColors.t38)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => popIfCurrent(context), child: const Text('Close')),
        FilledButton(onPressed: level < 1 || !enough || _busy ? null : _train, child: const Text('Train')),
      ],
    );
  }
}
