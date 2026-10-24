import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/api_service.dart';

import '../app_colors.dart';
import '../constants.dart' show fmtNum;
import '../widgets/radar_icon.dart';
const _kCategories = [
  ('All', ''),
  ('Mines', 'newmine'),
  ('Demolish', 'demolish'),
  ('Repair', 'repair'),
  ('Market', 'marketsell'),
  ('Factory', 'buyfactory'),
  ('Warehouse', 'lagerupgrade'),
  ('Tech', 'techupgrade'),
  ('Other', '__other__'),
];

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});
  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  List<dynamic> _entries = [];
  bool _loading = true;
  int _offset = 0;
  int _total = 0;
  String _filterType = '';
  final _searchCtrl = TextEditingController();

  static const _pageSize = 100;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearch() => setState(() {});

  Future<void> _load({int offset = 0}) async {
    setState(() => _loading = true);
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.getLog(sid, offset: offset, type: _filterType == '__other__' ? '' : _filterType);
    if (mounted) {
      setState(() {
        final raw = result?['entries'] as List? ?? [];
        _entries = _filterType == '__other__'
            ? raw.where((e) => !_isKnownType(e['type'] as String)).toList()
            : raw;
        _total = result?['total'] as int? ?? 0;
        _offset = offset;
        _loading = false;
      });
    }
  }

  bool _isKnownType(String t) => const {
    'scan','newmine','demolish','repair','repairkit','repairfree','lagerupgrade','hq',
    'buyfactory','factcollect','marketsell','marketbuy','marketsold',
    'mineupgrade','techupgrade','accident','strikesettled',
    'loanrequested','loancancelled','loanfunded','loanlent','loanrepaid','loanforgiven','levelup',
  }.contains(t);

  List<dynamic> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _entries;
    return _entries.where((e) {
      final label = _labelForType(e['type'] as String, (e['data'] as Map?)?.cast<String, dynamic>() ?? {}).toLowerCase();
      return label.contains(q) || (e['type'] as String).toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop == true;
    final filtered = _filtered;
    final totalPages = (_total / _pageSize).ceil().clamp(1, 9999);
    final currentPage = (_offset / _pageSize).floor() + 1;

    return Scaffold(
      appBar: canPop ? AppBar(toolbarHeight: 36) : null,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search logs...',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () => _searchCtrl.clear())
                  : null,
              isDense: true,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 34,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            scrollDirection: Axis.horizontal,
            itemCount: _kCategories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final (label, type) = _kCategories[i];
              final selected = _filterType == type;
              return FilterChip(
                label: Text(label, style: const TextStyle(fontSize: 11)),
                selected: selected,
                onSelected: (_) {
                  _filterType = type;
                  _load();
                },
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
                  ? Center(child: Text('No log entries', style: TextStyle(color: AppColors.t54)))
                  : RefreshIndicator(
                      onRefresh: () => _load(offset: _offset),
                      child: ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final e = filtered[i];
                          final type = e['type'] as String;
                          final ts = e['ts'] as String? ?? '';
                          final data = (e['data'] as Map?)?.cast<String, dynamic>() ?? {};
                          return ListTile(
                            dense: true,
                            leading: type == 'scan'
                                ? RadarIcon(size: 18, color: _colorForType(type))
                                : Icon(_iconForType(type), size: 18, color: _colorForType(type)),
                            title: Text(_labelForType(type, data)),
                            subtitle: Text(
                              ts.length > 16 ? ts.substring(0, 16).replaceAll('T', ' ') : ts,
                              style: TextStyle(fontSize: 10, color: AppColors.t38),
                            ),
                          );
                        },
                      ),
                    ),
        ),
        if (_total > _pageSize)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: _offset > 0 ? () => _load(offset: (_offset - _pageSize).clamp(0, 999999)) : null,
              ),
              Expanded(
                child: Text(
                  'Page $currentPage / $totalPages  (${_total} total)',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppColors.t54),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _offset + _pageSize < _total ? () => _load(offset: _offset + _pageSize) : null,
              ),
            ]),
          ),
      ]),
    );
  }

  IconData _iconForType(String t) {
    switch (t) {
      case 'scan': return Icons.radar;
      case 'newmine': return Icons.add_location;
      case 'demolish': return Icons.delete;
      case 'repair': case 'repairkit': case 'repairfree': return Icons.build;
      case 'lagerupgrade': return Icons.upgrade;
      case 'hq': return Icons.apartment;
      case 'buyfactory': return Icons.factory;
      case 'factcollect': return Icons.inventory;
      case 'marketsell': return Icons.sell;
      case 'marketbuy': return Icons.shopping_cart;
      case 'marketsold': return Icons.payments;
      case 'mineupgrade': return Icons.upgrade;
      case 'techupgrade': return Icons.settings_suggest;
      case 'accident': return Icons.warning_amber;
      case 'levelup': return Icons.military_tech;
      case 'strikesettled': return Icons.handshake_outlined;
      case 'loanrequested': case 'loancancelled': case 'loanfunded': case 'loanlent': case 'loanrepaid':
      case 'loanforgiven': return Icons.account_balance_wallet_outlined;
      default: return Icons.info_outline;
    }
  }

  Color _colorForType(String t) {
    switch (t) {
      case 'scan': return Colors.blue;
      case 'newmine': return Colors.green;
      case 'demolish': return Colors.red;
      case 'repair': case 'repairkit': return Colors.orange;
      case 'repairfree': return Colors.greenAccent;
      case 'marketsell': case 'marketbuy': case 'marketsold': return Colors.amber;
      case 'mineupgrade': case 'techupgrade': return Colors.lightBlueAccent;
      case 'accident': return Colors.redAccent;
      case 'strikesettled': return Colors.orangeAccent;
      default: return AppColors.accent;
    }
  }

  String _labelForType(String t, Map<String, dynamic> data) {
    switch (t) {
      case 'scan': return 'Scanned at (${(data['lat'] ?? 0.0).toStringAsFixed(3)}, ${(data['lng'] ?? 0.0).toStringAsFixed(3)})';
      case 'newmine': return 'Built mine (ID: ${data['mID'] ?? ''})';
      case 'demolish': return 'Demolished mine. Refund: ꞓ${fmtNum(data['refund'] as num? ?? 0)}';
      case 'repair': return 'Repaired mine. Cost: ꞓ${fmtNum(data['cost'] as num? ?? 0)}';
      case 'repairfree': return 'Repaired mine for free (boss range)';
      case 'repairkit': return 'Repaired mine with kit';
      case 'hq': return 'Placed HQ';
      case 'lagerupgrade': return 'Warehouse upgraded to Lv ${data['newLvl'] ?? 1}';
      case 'buyfactory': return 'Built factory';
      case 'factcollect': return 'Collected ${data['qty']} from factory';
      case 'marketsell': return 'Listed item ${data['itemID']} × ${data['qty']} @ ꞓ${fmtNum(data['price'] as num? ?? 0)}';
      case 'marketbuy': return 'Bought ${data['qty']} × item ${data['itemID']} for ꞓ${fmtNum(data['cost'] as num? ?? 0)}';
      case 'marketsold': return 'Sold to buyer. Earned ꞓ${fmtNum(data['earned'] as num? ?? 0)}';
      case 'mineupgrade': return 'Upgraded mine to Lv ${data['newLvl'] ?? '?'}. Cost: ꞓ${fmtNum(data['cost'] as num? ?? 0)}';
      case 'techupgrade': return 'Tech upgraded mine (Tech Lv ${data['newTech'] ?? '?'})';
      case 'accident':
        final what = const {'fire': 'Factory fire', 'strike': 'Strike', 'disease': 'Disease outbreak at a mine',
            'earthquake': 'Earthquake damage'}[data['kind']] ?? 'Accident';
        final p = (data['penalty'] as num? ?? 0).toInt();
        return p > 0 ? '$what. Penalty: ꞓ${fmtNum(p)}' : what;
      case 'loanrequested': return 'Requested a loan of ꞓ${fmtNum((data['principal'] as num? ?? 0).toInt())} for ${data['termDays']} days';
      case 'loancancelled': return 'Cancelled a loan request';
      case 'loanfunded': return 'Your loan of ꞓ${fmtNum((data['principal'] as num? ?? 0).toInt())} was funded';
      case 'loanlent': return 'Lent ꞓ${fmtNum((data['principal'] as num? ?? 0).toInt())} (you get back ꞓ${fmtNum((data['total'] as num? ?? 0).toInt())})';
      case 'loanrepaid': return data['borrowed'] == true
          ? 'Repaid your loan in full (ꞓ${fmtNum((data['total'] as num? ?? 0).toInt())})'
          : 'A loan you gave was repaid in full (ꞓ${fmtNum((data['total'] as num? ?? 0).toInt())})';
      case 'loanforgiven': return 'Loan forgiven after the grace period';
      case 'levelup': return 'Level up: ${data['from']} → ${data['to']}';
      case 'strikesettled': return data['how'] == 'pay'
          ? 'Strike ended: workers paid ꞓ${fmtNum((data['paid'] as num? ?? 0).toInt())}'
          : 'Strike broken up by ${data['units'] ?? ''} security staff';
      default: return t;
    }
  }
}
