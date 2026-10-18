import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/api_service.dart';
import '../constants.dart';
import '../widgets/top_banner.dart';

class MarketScreen extends StatefulWidget {
  const MarketScreen({super.key});
  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  List<dynamic> _listings = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.getMarket(sid);
    if (mounted) setState(() { _listings = result ?? []; _loading = false; });
  }

  Future<void> _buy(String reqId, double qty) async {
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.buyFromMarket(sid, reqId, qty);
    if (!mounted) return;
    if (result == null || result['err'] != 0) {
      AppNotify.show(context, result?['msg'] ?? 'Purchase failed', isError: true);
    } else {
      AppNotify.show(context, 'Bought ${result['bought']} for ꞓ${result['cost']}');
      context.read<PlayerProvider>().refresh();
      _load();
    }
  }

  void _showSell() {
    final player = context.read<PlayerProvider>().player;
    if (player == null) return;
    final lager = player.lager;
    if (lager.isEmpty) {
      AppNotify.show(context, 'Warehouse is empty', isError: true);
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SellSheet(lager: lager, onSell: _sell),
    );
  }

  Future<void> _cancel(String reqId) async {
    final result = await ApiService.cancelMarketListing(context.read<PlayerProvider>().sid, reqId);
    if (!mounted) return;
    if (result == null || result['err'] != 0) {
      AppNotify.show(context, result?['msg'] ?? 'Cancel failed', isError: true);
    } else {
      AppNotify.show(context, 'Listing cancelled');
      context.read<PlayerProvider>().refresh();
      _load();
    }
  }

  Future<void> _sell(int itemId, double qty, double price) async {
    final sid = context.read<PlayerProvider>().sid;
    final result = await ApiService.sellItem(sid, itemId, qty, price);
    if (!mounted) return;
    Navigator.of(context).pop();
    if (result == null || result['err'] != 0) {
      AppNotify.show(context, result?['msg'] ?? 'Listing failed', isError: true);
    } else {
      AppNotify.show(context, 'Listed on market!');
      context.read<PlayerProvider>().refresh();
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final myListings = _listings.where((l) => l['isMine'] == true).toList();
    final others = _listings.where((l) => l['isMine'] != true).toList();

    return Scaffold(
      appBar: ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: Column(children: [
        TabBar(controller: _tabs, tabs: const [
          Tab(text: 'BUY'), Tab(text: 'MY LISTINGS'),
        ]),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(controller: _tabs, children: [
                  _ListingsList(listings: others, onBuy: _buy, onCancel: null),
                  _ListingsList(listings: myListings, onBuy: null, onCancel: _cancel, isMine: true),
                ]),
        ),
      ]),
      floatingActionButton: FloatingActionButton.small(
        heroTag: 'market_sell',
        onPressed: _showSell,
        tooltip: 'Sell',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _ListingsList extends StatelessWidget {
  final List listings;
  final Function(String, double)? onBuy;
  final Function(String)? onCancel;
  final bool isMine;
  const _ListingsList({required this.listings, required this.onBuy, required this.onCancel, this.isMine = false});

  @override
  Widget build(BuildContext context) {
    if (listings.isEmpty) {
      return Center(child: Text(isMine ? 'No active listings' : 'Market is empty',
          style: const TextStyle(color: Colors.white54)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: listings.length,
      itemBuilder: (_, i) {
        final l = listings[i];
        final itemId = l['itemID'] as int;
        final qty = (l['qty'] as num).toDouble();
        final price = (l['priceUnit'] as num).toDouble();
        return Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            dense: true,
            leading: _ResIcon(itemId: itemId),
            title: Text(itemName(itemId)),
            subtitle: Text('${qty.toStringAsFixed(0)} units  •  ${l['sellerName']}',
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('ꞓ${price.toStringAsFixed(0)}/u',
                  style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 12)),
              if (onBuy != null)
                TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(40, 24)),
                  onPressed: () => onBuy!(l['reqID'] as String, qty),
                  child: const Text('Buy all', style: TextStyle(fontSize: 11)),
                ),
              if (onCancel != null)
                TextButton(
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(40, 24),
                      foregroundColor: Colors.red),
                  onPressed: () => onCancel!(l['reqID'] as String),
                  child: const Text('Cancel', style: TextStyle(fontSize: 11)),
                ),
            ]),
          ),
        );
      },
    );
  }
}

class _ResIcon extends StatelessWidget {
  final int itemId;
  const _ResIcon({required this.itemId});
  @override
  Widget build(BuildContext context) {
    final path = resImagePath(itemId);
    if (path != null) {
      return SizedBox(width: 32, height: 32,
          child: Image.asset(path, fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => _fallback()));
    }
    return _fallback();
  }
  Widget _fallback() => CircleAvatar(radius: 14,
      backgroundColor: Colors.teal.shade900,
      child: Text('$itemId', style: const TextStyle(fontSize: 9)));
}

class _SellSheet extends StatefulWidget {
  final Map<String, double> lager;
  final Future<void> Function(int, double, double) onSell;
  const _SellSheet({required this.lager, required this.onSell});
  @override
  State<_SellSheet> createState() => _SellSheetState();
}

class _SellSheetState extends State<_SellSheet> {
  int? _selectedItem;
  final _qtyCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final entries = widget.lager.entries.where((e) => e.value > 0.01).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Sell Item', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Item', border: OutlineInputBorder()),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _selectedItem,
              isExpanded: true,
              hint: const Text('Select item'),
              items: entries.map((e) {
                final id = int.tryParse(e.key) ?? 0;
                return DropdownMenuItem(value: id,
                    child: Text('${itemName(id)} (${e.value.toStringAsFixed(0)})'));
              }).toList(),
              onChanged: (v) => setState(() => _selectedItem = v),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(
            controller: _qtyCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Quantity', border: OutlineInputBorder()),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextField(
            controller: _priceCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Price/unit (ꞓ)', border: OutlineInputBorder()),
          )),
        ]),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _selectedItem == null ? null : () {
            final qty = double.tryParse(_qtyCtrl.text) ?? 0;
            final price = double.tryParse(_priceCtrl.text) ?? 0;
            if (qty > 0 && price > 0) widget.onSell(_selectedItem!, qty, price);
          },
          child: const Text('List for Sale'),
        ),
      ]),
    );
  }
}
