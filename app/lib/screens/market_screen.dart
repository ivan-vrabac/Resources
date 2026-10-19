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

/// Market: system trade (sell 100% / buy 150%) and player BUY orders (sell by filling one),
/// Haulage Firm transport tax included in every price shown.
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
                          title: Text('Buy ${itemName(o['itemID'] as int)}'),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => MarketItemScreen(itemId: o['itemID'] as int)));
                            if (mounted) _load();
                          },
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
    // ASK = cheapest price you can buy at (the system's selling price);
    // BID = best price you can sell at (highest player bid or what the system pays).
    final ask = e['systemBuy'] as num?;
    final bids = [e['bestBid'] as num?, e['systemSell'] as num?].whereType<num>();
    final bid = bids.isEmpty ? null : bids.reduce((a, b) => a > b ? a : b);
    Widget quote(String label, num? v, Color c) => Text.rich(TextSpan(children: [
          TextSpan(text: '$label ', style: TextStyle(fontSize: 10, color: c.withValues(alpha: 0.8), fontWeight: FontWeight.bold)),
          TextSpan(text: v == null ? '–' : fmtCredits(v), style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.bold)),
        ]));
    return ListTile(
      leading: ItemIcon(id),
      title: Text(itemName(id)),
      subtitle: Row(children: [
        quote('ASK', ask, kAskColor),
        const SizedBox(width: 12),
        quote('BID', bid, kBidColor),
      ]),
      trailing: Text(fmtQty(e['owned'] as num? ?? 0), style: const TextStyle(color: Colors.white54)),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MarketItemScreen(itemId: id)));
        if (mounted) _load();
      },
    );
  }
}

/// One item: an order book of BUY orders only. Top: buy from the system; middle: players' buy
/// orders (highest price first, oldest first at equal price) that you can sell into; bottom: sell
/// to the system. You can have one buy order per item (edit or cancel it).
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
  String _rid() => '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(1 << 30)}';

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

  Future<void> _done(ApiResult r, String ok) async {
    if (!mounted) return;
    AppNotify.show(context, r.ok ? ok : (r.message ?? 'Failed'), isError: !r.ok);
    if (r.ok) context.read<PlayerProvider>().refresh();
    _load();
  }

  /// Quantity-only trades: buy from / sell to the system, sell into a player's buy order.
  Future<void> _qtyTrade({required String title, required num price, required int maxQty,
      required bool selling, required Future<ApiResult> Function(int qty) run, double taxRate = 0}) async {
    final q = await showDialog<int>(
      context: context,
      builder: (_) => _QtyDialog(title: title, itemId: widget.itemId, price: price, maxQty: maxQty,
          selling: selling, taxRate: taxRate),
    );
    if (q == null || q <= 0) return;
    final r = await run(q);
    await _done(r, selling ? 'Sold $q × ${itemName(widget.itemId)}' : 'Bought $q × ${itemName(widget.itemId)}');
  }

  Future<void> _orderDialog({Map<String, dynamic>? mine}) async {
    final b = _b!;
    final bids = (b['bids'] as List).cast<Map<String, dynamic>>();
    final topOther = bids.where((o) => o['isMe'] != true).map((o) => o['price'] as num).fold<num?>(null,
        (a, p) => a == null || p > a ? p : a);
    final res = await showDialog<(int, double)>(
      context: context,
      builder: (_) => _OrderDialog(
        itemId: widget.itemId,
        taxRate: (b['taxRate'] as num).toDouble(),
        credits: (b['credits'] as num).toDouble() + ((mine?['escrow'] as num?) ?? 0),
        freeSpace: ((b['freeSpace'] as num) + (mine != null ? (mine['qty'] as num) : 0)).toInt(),
        initialPrice: (mine?['price'] as num?)?.toDouble() ?? topOther?.toDouble() ?? (b['systemSell'] as num?)?.toDouble() ?? 1,
        initialQty: (mine?['qty'] as num?)?.toInt(),
        maxPrice: (b['systemBuy'] as num?)?.toDouble(),
        editing: mine != null,
      ),
    );
    if (res == null) return;
    final r = mine == null
        ? await GameApi.call('/api/v1/market/order', _sid,
            {'side': 'buy', 'itemID': widget.itemId, 'qty': res.$1, 'price': res.$2, 'rid': _rid()})
        : await GameApi.call('/api/v1/market/edit', _sid,
            {'orderID': mine['id'], 'qty': res.$1, 'price': res.$2, 'rid': _rid()});
    await _done(r, mine == null ? 'Buy order placed' : 'Buy order updated');
  }

  Future<void> _cancelMine(Map<String, dynamic> mine) async {
    final r = await GameApi.call('/api/v1/market/cancel', _sid, {'orderID': mine['id']});
    await _done(r, 'Order cancelled, credits returned');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 40, title: Text(itemName(widget.itemId))),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        builder: () {
          final b = _b!;
          final owned = (b['owned'] as num? ?? 0).toInt();
          final credits = (b['credits'] as num).toDouble();
          final space = (b['freeSpace'] as num? ?? 0).toInt();
          final tax = (b['taxRate'] as num).toDouble();
          final sysSell = b['systemSell'] as num?;
          final sysBuy = b['systemBuy'] as num?;
          final bids = (b['bids'] as List).cast<Map<String, dynamic>>();
          final mine = (b['myOrder'] as Map?)?.cast<String, dynamic>();
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(12), children: [
              Row(children: [
                ItemIcon(widget.itemId, size: 44),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('You have ${fmtNum(owned)} · free space ${fmtNum(space)}'),
                  Text('Credits ${fmtCredits(credits)} · your transport tax ${(tax * 100).round()}%',
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ])),
              ]),
              const SizedBox(height: 12),
              if (mine == null)
                _wideButton(Icons.add_shopping_cart, 'Place buy order', () => _orderDialog(), filled: true)
              else
                Card(
                  color: Colors.teal.withValues(alpha: 0.12),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Your buy order: ${fmtNum((mine['qty'] as num).toInt())} @ ${fmtCredits(mine['price'] as num)}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('Held: ${fmtCredits(mine['escrow'] as num)} incl. tax',
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      const SizedBox(height: 6),
                      Row(children: [
                        Expanded(child: _wideButton(Icons.edit, 'Edit', () => _orderDialog(mine: mine))),
                        const SizedBox(width: 8),
                        Expanded(child: _wideButton(Icons.close, 'Cancel', () => _cancelMine(mine))),
                      ]),
                    ]),
                  ),
                ),
              const SizedBox(height: 16),
              const Text('Order book', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 4),
              if (sysBuy != null)
                _bookRow(
                  label: 'System sells', price: sysBuy, qtyText: '', color: kAskColor,
                  action: 'Buy', onTap: () => _qtyTrade(
                    title: 'Buy from the system', price: sysBuy, selling: false, taxRate: tax,
                    maxQty: max(0, min(space, (credits / (sysBuy * (1 + tax))).floor())),
                    run: (q) => GameApi.call('/api/v1/market/system', _sid,
                        {'side': 'buy', 'itemID': widget.itemId, 'qty': q, 'rid': _rid()})),
                ),
              if (bids.isEmpty)
                const Padding(padding: EdgeInsets.all(10),
                    child: Text('No player buy orders yet.', style: TextStyle(color: Colors.white38))),
              for (final o in bids)
                _bookRow(
                  label: o['isMe'] == true ? 'You' : (o['name'] as String? ?? 'Player'),
                  price: o['price'] as num, qtyText: fmtNum((o['qty'] as num).toInt()),
                  color: o['isMe'] == true ? Colors.tealAccent : Colors.white,
                  action: o['isMe'] == true ? null : 'Sell',
                  onTap: owned <= 0 ? null : () => _qtyTrade(
                    title: 'Sell to ${o['name'] ?? 'player'}', price: o['price'] as num, selling: true,
                    maxQty: min(owned, (o['qty'] as num).toInt()),
                    run: (q) => GameApi.call('/api/v1/market/take', _sid, {'orderID': o['id'], 'qty': q, 'rid': _rid()})),
                ),
              if (sysSell != null)
                _bookRow(
                  label: 'System buys', price: sysSell, qtyText: '', color: kBidColor,
                  action: 'Sell', onTap: owned <= 0 ? null : () => _qtyTrade(
                    title: 'Sell to the system', price: sysSell, selling: true, maxQty: owned,
                    run: (q) => GameApi.call('/api/v1/market/system', _sid,
                        {'side': 'sell', 'itemID': widget.itemId, 'qty': q, 'rid': _rid()})),
                ),
              if (sysSell == null)
                const Padding(padding: EdgeInsets.only(top: 8),
                    child: Text('The system does not trade this item — players only.',
                        style: TextStyle(color: Colors.white54, fontSize: 12))),
              const SizedBox(height: 12),
              const Text('Selling into a buy order is free of tax for you; the buyer paid the transport tax '
                  'when placing the order. Equal prices: the older order is served first.',
                  style: TextStyle(color: Colors.white38, fontSize: 11)),
            ]),
          );
        },
      ),
    );
  }

  Widget _wideButton(IconData icon, String text, VoidCallback? onTap, {bool filled = false}) {
    final child = FittedBox(fit: BoxFit.scaleDown, child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18), const SizedBox(width: 6), Text(text, maxLines: 1),
    ]));
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: filled ? FilledButton(onPressed: onTap, child: child) : OutlinedButton(onPressed: onTap, child: child),
    );
  }

  Widget _bookRow({required String label, required num price, required String qtyText, required Color color,
      String? action, VoidCallback? onTap}) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Expanded(flex: 4, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color))),
        Expanded(flex: 4, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight,
            child: Text(fmtCredits(price), style: const TextStyle(fontWeight: FontWeight.bold)))),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight,
            child: Text(qtyText, style: const TextStyle(color: Colors.white70)))),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: action == null
              ? const SizedBox.shrink()
              : FilledButton.tonal(
                  style: FilledButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                  onPressed: onTap, child: Text(action)),
        ),
      ]),
    );
  }
}

/// Whole-unit quantity with a slider (up to what you can afford / store / own) and a number field.
class _QtyDialog extends StatefulWidget {
  final String title;
  final int itemId, maxQty;
  final num price;
  final bool selling;
  final double taxRate;      // added on top when buying from the system
  const _QtyDialog({required this.title, required this.itemId, required this.price, required this.maxQty,
      required this.selling, this.taxRate = 0});
  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late int _q = widget.maxQty;
  late final _ctl = TextEditingController(text: '${widget.maxQty}');

  void _set(int v) {
    setState(() => _q = v.clamp(0, widget.maxQty));
    final t = '$_q';
    if (_ctl.text != t) _ctl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  @override
  Widget build(BuildContext context) {
    final value = (_q * widget.price).round();
    final tax = (value * widget.taxRate).round();
    final total = value + tax;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ItemIcon(widget.itemId, size: 32),
          const SizedBox(width: 8),
          Expanded(child: Text('${fmtCredits(widget.price)} per unit'
              '${widget.taxRate > 0 ? ' + ${(widget.taxRate * 100).round()}% tax' : ''}')),
        ]),
        if (widget.maxQty <= 0)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text(widget.selling
              ? "You don't have any to sell." : 'Not enough credits or warehouse space.',
              style: const TextStyle(color: Colors.orangeAccent)))
        else ...[
          Slider(value: _q.toDouble(), min: 0, max: widget.maxQty.toDouble(),
              onChanged: (v) => _set(v.round())),
          TextField(
            controller: _ctl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: 'Quantity', helperText: 'max ${fmtNum(widget.maxQty)}'),
            onChanged: (t) => _set(int.tryParse(t) ?? 0),
          ),
          const SizedBox(height: 10),
          if (tax > 0)
            Row(children: [
              const Expanded(child: Text('Transport tax', style: TextStyle(color: Colors.white70))),
              Text(fmtCredits(tax)),
            ]),
          Row(children: [
            Expanded(child: Text(widget.selling ? 'You receive' : 'You pay', style: const TextStyle(color: Colors.white70))),
            Text(fmtCredits(total), style: const TextStyle(fontWeight: FontWeight.bold)),
          ]),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _q <= 0 ? null : () => Navigator.pop(context, _q), child: const Text('Confirm')),
      ],
    );
  }
}

/// New or edited buy order: price (prefilled with the top bid) and a quantity slider limited by
/// your credits (price + tax) and warehouse space. Shows the price per unit including tax.
class _OrderDialog extends StatefulWidget {
  final int itemId, freeSpace;
  final double taxRate, credits, initialPrice;
  final double? maxPrice;
  final int? initialQty;
  final bool editing;
  const _OrderDialog({required this.itemId, required this.taxRate, required this.credits, required this.freeSpace,
      required this.initialPrice, this.initialQty, this.maxPrice, this.editing = false});
  @override
  State<_OrderDialog> createState() => _OrderDialogState();
}

class _OrderDialogState extends State<_OrderDialog> {
  late double _price = widget.initialPrice;
  late final _priceCtl = TextEditingController(text: _fmt(widget.initialPrice));
  late final _qtyCtl = TextEditingController();
  int _q = 0;

  static String _fmt(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

  int get _maxQty {
    if (_price <= 0) return 0;
    final afford = (widget.credits / (_price * (1 + widget.taxRate))).floor();
    return max(0, min(afford, widget.freeSpace));
  }

  @override
  void initState() {
    super.initState();
    _q = min(widget.initialQty ?? _maxQty, _maxQty);
    _qtyCtl.text = '$_q';
  }

  void _setQ(int v) {
    setState(() => _q = v.clamp(0, _maxQty));
    final t = '$_q';
    if (_qtyCtl.text != t) _qtyCtl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  @override
  Widget build(BuildContext context) {
    final unitWithTax = _price * (1 + widget.taxRate);
    final value = (_q * _price).round();
    final tax = (value * widget.taxRate).round();
    final m = _maxQty;
    final tooHigh = widget.maxPrice != null && _price > widget.maxPrice!;
    return AlertDialog(
      title: Text(widget.editing ? 'Edit buy order' : 'Place buy order'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ItemIcon(widget.itemId, size: 32),
            const SizedBox(width: 8),
            Expanded(child: Text(itemName(widget.itemId))),
          ]),
          TextField(
            controller: _priceCtl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(
              labelText: 'Price per unit',
              helperText: '${fmtCredits(unitWithTax)} per unit incl. ${(widget.taxRate * 100).round()}% tax',
              errorText: tooHigh ? 'Above the system price — buy from the system instead' : null,
            ),
            onChanged: (t) => setState(() {
              _price = double.tryParse(t) ?? 0;
              _q = min(_q, _maxQty);
              _qtyCtl.text = '$_q';
            }),
          ),
          const SizedBox(height: 8),
          if (m > 0)
            Slider(value: _q.toDouble().clamp(0, m.toDouble()), min: 0, max: m.toDouble(), onChanged: (v) => _setQ(v.round())),
          TextField(
            controller: _qtyCtl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: 'Quantity', helperText: 'max ${fmtNum(m)} (credits / warehouse space)'),
            onChanged: (t) => _setQ(int.tryParse(t) ?? 0),
          ),
          const SizedBox(height: 10),
          _line('Value', fmtCredits(value)),
          _line('Transport tax', fmtCredits(tax)),
          _line('Held now', fmtCredits(value + tax), bold: true),
          const SizedBox(height: 6),
          const Text('Credits are held until players sell to you. Unfilled quantity is refunded on cancel '
              'or after 2 days. Editing the price puts the order behind older ones at the same price.',
              style: TextStyle(fontSize: 11, color: Colors.white54)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _q <= 0 || _price <= 0 || tooHigh ? null : () => Navigator.pop(context, (_q, _price)),
          child: Text(widget.editing ? 'Update' : 'Place order'),
        ),
      ],
    );
  }

  Widget _line(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          Expanded(child: Text(k, style: const TextStyle(color: Colors.white70))),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ]),
      );
}
