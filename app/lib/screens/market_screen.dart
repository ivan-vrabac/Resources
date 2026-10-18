import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../constants.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';

/// Market v2: system trade (sell 100% / buy 150%), player buy & sell orders with matching,
/// Haulage Firm transport tax shown before every confirmation.
class MarketScreen extends StatefulWidget {
  const MarketScreen({super.key});
  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> _trades = [];
  double _taxRate = 0.15;
  bool _loading = true;
  String? _error;
  String _filter = '';

  String get _sid => context.read<PlayerProvider>().sid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final res = await Future.wait([
      GameApi.call('/api/v1/market/overview', _sid),
      GameApi.call('/api/v1/market/mine', _sid),
      GameApi.call('/api/v1/market/history', _sid),
    ]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (!res[0].ok) { _error = res[0].message; return; }
      _items = res[0].list('items');
      _taxRate = (res[0].data['taxRate'] as num? ?? 0.15).toDouble();
      _orders = res[1].list('orders');
      _trades = res[2].list('trades');
    });
  }

  Future<void> _cancel(Map<String, dynamic> o) async {
    final r = await GameApi.call('/api/v1/market/cancel', _sid, {'orderID': o['id']});
    if (!mounted) return;
    AppNotify.show(context, r.ok ? 'Order cancelled, escrow returned' : (r.message ?? 'Failed'), isError: !r.ok);
    context.read<PlayerProvider>().refresh();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _items.where((e) =>
        _filter.isEmpty || itemName(e['itemID'] as int).toLowerCase().contains(_filter)).toList();
    return Column(children: [
      TabBar(controller: _tabs, tabs: [
        const Tab(text: 'Market'),
        Tab(text: 'My orders (${_orders.length})'),
        const Tab(text: 'History'),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        child: Row(children: [
          const Icon(Icons.local_shipping_outlined, size: 14, color: Colors.white54),
          const SizedBox(width: 4),
          Text('Transport tax ${(_taxRate * 100).round()}% (Haulage Firm)',
              style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ]),
      ),
      Expanded(
        child: AsyncView(
          loading: _loading,
          error: _error,
          onRetry: _load,
          builder: () => TabBarView(controller: _tabs, children: [
            // ── Market items ──
            RefreshIndicator(
              onRefresh: _load,
              child: ListView(children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search),
                        hintText: 'Filter items', border: OutlineInputBorder()),
                    onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
                  ),
                ),
                for (final e in shown) _itemTile(e),
              ]),
            ),
            // ── My orders ──
            RefreshIndicator(
              onRefresh: _load,
              child: _orders.isEmpty
                  ? ListView(children: const [SizedBox(height: 80),
                      Center(child: Text('No open orders', style: TextStyle(color: Colors.white54)))])
                  : ListView(children: [
                      for (final o in _orders)
                        ListTile(
                          leading: ItemIcon(o['itemID'] as int),
                          title: Text('${o['side'] == 'buy' ? 'Buy' : 'Sell'} ${itemName(o['itemID'] as int)}'),
                          subtitle: Text('${fmtQty(o['qtyOpen'] as num)} of ${fmtQty(o['qtyTotal'] as num)} @ '
                              '${fmtCredits(o['price'] as num)}'
                              '${o['side'] == 'buy' ? ' · escrow ${fmtCredits(o['escrow'] as num)}' : ''}'
                              '\nexpires ${(o['expiresAt'] as String).replaceFirst('T', ' ').substring(0, 16)} UTC',
                              style: const TextStyle(fontSize: 11)),
                          isThreeLine: true,
                          trailing: TextButton(onPressed: () => _cancel(o), child: const Text('Cancel')),
                        ),
                    ]),
            ),
            // ── History ──
            RefreshIndicator(
              onRefresh: _load,
              child: _trades.isEmpty
                  ? ListView(children: const [SizedBox(height: 80),
                      Center(child: Text('No trades yet', style: TextStyle(color: Colors.white54)))])
                  : ListView(children: [
                      for (final t in _trades)
                        ListTile(
                          dense: true,
                          leading: ItemIcon(t['itemID'] as int, size: 24),
                          title: Text('${t['side'] == 'buy' ? 'Bought' : 'Sold'} ${fmtQty(t['qty'] as num)} '
                              '${itemName(t['itemID'] as int)}'),
                          subtitle: Text('${t['kind'] == 'player' ? 'player' : 'system'} · '
                              '${fmtCredits(t['price'] as num)}/unit'
                              '${(t['tax'] as num? ?? 0) > 0 ? ' · tax ${fmtCredits(t['tax'] as num)}' : ''}'),
                          trailing: Text((t['ts'] as String).substring(5, 16).replaceFirst('T', ' '),
                              style: const TextStyle(fontSize: 10, color: Colors.white38)),
                        ),
                    ]),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _itemTile(Map<String, dynamic> e) {
    final id = e['itemID'] as int;
    String p(String k) => e[k] == null ? '–' : fmtCredits(e[k] as num);
    return ListTile(
      leading: ItemIcon(id),
      title: Text(itemName(id)),
      subtitle: Text('System ${p('systemSell')} / ${p('systemBuy')} · bid ${p('bestBid')} · ask ${p('bestAsk')}',
          style: const TextStyle(fontSize: 11)),
      trailing: Text(fmtQty(e['owned'] as num? ?? 0), style: const TextStyle(color: Colors.white54)),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MarketItemScreen(itemId: id)));
        if (mounted) _load();
      },
    );
  }
}

/// Order book and actions for one item.
class MarketItemScreen extends StatefulWidget {
  final int itemId;
  const MarketItemScreen({super.key, required this.itemId});
  @override
  State<MarketItemScreen> createState() => _MarketItemScreenState();
}

class _MarketItemScreenState extends State<MarketItemScreen> {
  Map<String, dynamic>? _b;
  bool _loading = true;
  String? _error;

  String get _sid => context.read<PlayerProvider>().sid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await GameApi.call('/api/v1/market/book', _sid, {'itemID': widget.itemId});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = r.ok ? null : r.message;
      if (r.ok) _b = r.data;
    });
  }

  Future<void> _act(String title, String action, {num? price, num? maxQty, String? orderId, String? side}) async {
    final res = await showDialog<_TradeInput>(
      context: context,
      builder: (_) => _TradeDialog(
        title: title, itemId: widget.itemId, action: action, sid: _sid,
        fixedPrice: price, maxQty: maxQty,
      ),
    );
    if (res == null || !mounted) return;
    final rid = '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(1 << 30)}';
    ApiResult r;
    switch (action) {
      case 'system_sell':
      case 'system_buy':
        r = await GameApi.call('/api/v1/market/system', _sid, {
          'side': action == 'system_sell' ? 'sell' : 'buy', 'itemID': widget.itemId, 'qty': res.qty, 'rid': rid});
      case 'take':
        r = await GameApi.call('/api/v1/market/take', _sid, {'orderID': orderId, 'qty': res.qty, 'rid': rid});
      default:
        r = await GameApi.call('/api/v1/market/order', _sid, {
          'side': side, 'itemID': widget.itemId, 'qty': res.qty, 'price': res.price, 'rid': rid});
    }
    if (!mounted) return;
    if (r.ok) {
      final filled = r.data['filled'] as num?;
      final resting = r.data['resting'] as num? ?? 0;
      AppNotify.show(context, filled != null
          ? 'Filled ${fmtQty(filled)}${resting > 0 ? ', ${fmtQty(resting)} waiting in the book' : ''}'
          : 'Done');
      context.read<PlayerProvider>().refresh();
    } else {
      AppNotify.show(context, r.message ?? 'Failed', isError: true);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    return Scaffold(
      appBar: AppBar(toolbarHeight: 40, title: Text(itemName(widget.itemId))),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        builder: () {
          final owned = (b!['owned'] as num? ?? 0);
          final sysSell = b['systemSell'] as num?;
          final sysBuy = b['systemBuy'] as num?;
          final bids = (b['bids'] as List).cast<Map<String, dynamic>>();
          final asks = (b['asks'] as List).cast<Map<String, dynamic>>();
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(12), children: [
              Row(children: [
                ItemIcon(widget.itemId, size: 44),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('You have ${fmtQty(owned)}'),
                  Text('Credits ${fmtCredits(b['credits'] as num)} · tax ${((b['taxRate'] as num) * 100).round()}%',
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ])),
              ]),
              const SizedBox(height: 12),
              if (sysSell != null && sysBuy != null)
                Row(children: [
                  Expanded(child: OutlinedButton(
                    onPressed: owned > 0 ? () => _act('Sell to system', 'system_sell', price: sysSell, maxQty: owned) : null,
                    child: Text('Sell to system\n${fmtCredits(sysSell)}', textAlign: TextAlign.center),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: OutlinedButton(
                    onPressed: () => _act('Buy from system', 'system_buy', price: sysBuy),
                    child: Text('Buy from system\n${fmtCredits(sysBuy)}', textAlign: TextAlign.center),
                  )),
                ])
              else
                const Text('The system does not trade this item — players only.',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: FilledButton.tonal(
                  onPressed: () => _act('Place buy order', 'buy_order', side: 'buy'),
                  child: const Text('Place buy order'))),
                const SizedBox(width: 8),
                Expanded(child: FilledButton.tonal(
                  onPressed: owned > 0 ? () => _act('Place sell order', 'sell_order', side: 'sell', maxQty: owned) : null,
                  child: const Text('Place sell order'))),
              ]),
              const SizedBox(height: 16),
              _bookSection('Buy orders (players buying)', bids, isBid: true, owned: owned),
              const SizedBox(height: 12),
              _bookSection('Sell orders (players selling)', asks, isBid: false, owned: owned),
            ]),
          );
        },
      ),
    );
  }

  Widget _bookSection(String title, List<Map<String, dynamic>> rows, {required bool isBid, required num owned}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      if (rows.isEmpty)
        const Padding(padding: EdgeInsets.all(8),
            child: Text('None', style: TextStyle(color: Colors.white38)))
      else
        for (final o in rows)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${fmtQty(o['qty'] as num)} @ ${fmtCredits(o['price'] as num)}'),
            subtitle: Text(o['isMe'] == true ? 'your order' : (o['name'] as String? ?? '')),
            trailing: o['isMe'] == true
                ? null
                : TextButton(
                    onPressed: isBid && owned <= 0
                        ? null
                        : () => _act(isBid ? 'Sell into this order' : 'Buy from this order', 'take',
                            price: o['price'] as num, orderId: o['id'] as String,
                            maxQty: isBid ? min(owned, o['qty'] as num) : o['qty'] as num),
                    child: Text(isBid ? 'Sell' : 'Buy'),
                  ),
          ),
    ]);
  }
}

class _TradeInput {
  final double qty;
  final double? price;
  const _TradeInput(this.qty, this.price);
}

/// Quantity (and price for new orders) with a server-side preview of value, tax and total.
class _TradeDialog extends StatefulWidget {
  final String title, action, sid;
  final int itemId;
  final num? fixedPrice, maxQty;
  const _TradeDialog({required this.title, required this.action, required this.sid, required this.itemId,
      this.fixedPrice, this.maxQty});
  @override
  State<_TradeDialog> createState() => _TradeDialogState();
}

class _TradeDialogState extends State<_TradeDialog> {
  final _qty = TextEditingController();
  final _price = TextEditingController();
  Timer? _debounce;
  Map<String, dynamic>? _quote;
  String? _quoteError;

  bool get _needsPrice => widget.action == 'buy_order' || widget.action == 'sell_order';

  @override
  void initState() {
    super.initState();
    if (widget.maxQty != null) _qty.text = fmtPlain(widget.maxQty!);
    if (widget.fixedPrice != null && _needsPrice) _price.text = widget.fixedPrice.toString();
    _qty.addListener(_requote);
    _price.addListener(_requote);
    _requote();
  }

  @override
  void dispose() {
    _qty.dispose();
    _price.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  static String fmtPlain(num v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

  void _requote() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final q = double.tryParse(_qty.text);
      final p = double.tryParse(_price.text);
      if (q == null || q <= 0 || (_needsPrice && (p == null || p <= 0))) {
        if (mounted) setState(() { _quote = null; _quoteError = null; });
        return;
      }
      if (widget.action == 'take') {
        final v = (q * widget.fixedPrice!).round();
        if (mounted) setState(() { _quote = {'value': v, 'tax': 0, 'total': v}; _quoteError = null; });
        return;
      }
      final r = await GameApi.call('/api/v1/market/quote', widget.sid,
          {'action': widget.action, 'itemID': widget.itemId, 'qty': q, 'price': p});
      if (mounted) setState(() { _quote = r.ok ? r.data : null; _quoteError = r.ok ? null : r.message; });
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _quote;
    final isSale = widget.action == 'system_sell' || widget.action == 'sell_order' ||
        (widget.action == 'take' && widget.title.startsWith('Sell'));
    return AlertDialog(
      title: Text(widget.title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _qty,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(labelText: 'Quantity',
              helperText: widget.maxQty != null ? 'max ${fmtQty(widget.maxQty!)}' : null),
        ),
        if (_needsPrice)
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Price per unit'),
          )
        else if (widget.fixedPrice != null)
          Padding(padding: const EdgeInsets.only(top: 8),
              child: Text('Price ${fmtCredits(widget.fixedPrice!)} per unit')),
        const SizedBox(height: 12),
        if (_quoteError != null) Text(_quoteError!, style: const TextStyle(color: Colors.redAccent)),
        if (q != null) ...[
          _row('Value', fmtCredits(q['value'] as num)),
          if ((q['tax'] as num? ?? 0) > 0)
            _row(widget.action == 'buy_order' ? 'Transport tax (paid now)' : 'Transport tax (when filled)',
                fmtCredits(q['tax'] as num)),
          _row(isSale ? 'You receive' : 'You pay', fmtCredits(q['total'] as num), bold: true),
          if (widget.action == 'buy_order')
            const Text('Unfilled quantity and its tax are refunded when the order is cancelled or expires.',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
          if (widget.action == 'sell_order')
            const Text('Matching buy orders fill immediately without tax for you; the rest waits 2 days.',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: q == null ? null : () => Navigator.pop(context,
              _TradeInput(double.parse(_qty.text), double.tryParse(_price.text))),
          child: const Text('Confirm'),
        ),
      ],
    );
  }

  Widget _row(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(k, style: const TextStyle(color: Colors.white70))),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );
}
