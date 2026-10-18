import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/api_service.dart';
import '../constants.dart';
import '../widgets/top_banner.dart';

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});
  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  final Map<int, int> _qtys = {for (final id in kShopItemIds) id: 1};
  bool _buying = false;

  Future<void> _buy(int itemId) async {
    if (_buying) return;
    setState(() => _buying = true);
    final sid = context.read<PlayerProvider>().sid;
    final qty = _qtys[itemId] ?? 1;
    final result = await ApiService.buyShopItem(sid, itemId, qty);
    setState(() => _buying = false);
    if (!mounted) return;
    if (result == null || result['err'] != 0) {
      AppNotify.show(context, result?['msg'] ?? 'Purchase failed', isError: true);
    } else {
      AppNotify.show(context, 'Bought $qty × ${itemName(itemId)}');
      context.read<PlayerProvider>().refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>().player;
    final credits = player?.credits ?? 0;

    return Scaffold(
      appBar: ModalRoute.of(context)?.canPop == true ? AppBar(toolbarHeight: 36) : null,
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: kShopItemIds.length,
        itemBuilder: (_, i) {
          final itemId = kShopItemIds[i];
          final price = kShopPrice[itemId] ?? 0;
          final desc = kShopDesc[itemId] ?? '';
          final qty = _qtys[itemId] ?? 1;
          final total = price * qty;
          final canAfford = credits >= total;

          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(itemName(itemId),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  Text('ꞓ${_fmtNum(price)} each',
                      style: const TextStyle(color: Colors.amber, fontSize: 13)),
                ]),
                const SizedBox(height: 4),
                Text(desc, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 12),
                Row(children: [
                  _QtyBtn(Icons.remove, qty > 1 ? () => setState(() => _qtys[itemId] = qty - 1) : null),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 32,
                    child: Text('$qty',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  const SizedBox(width: 8),
                  _QtyBtn(Icons.add, qty < 99 ? () => setState(() => _qtys[itemId] = qty + 1) : null),
                  const Spacer(),
                  FilledButton(
                    onPressed: canAfford && !_buying ? () => _buy(itemId) : null,
                    child: Text('Buy  ꞓ${_fmtNum(total)}'),
                  ),
                ]),
                if (!canAfford)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('Not enough credits',
                        style: TextStyle(color: Colors.red, fontSize: 11)),
                  ),
              ]),
            ),
          );
        },
      ),
    );
  }

  String _fmtNum(num n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
    return n.toStringAsFixed(0);
  }
}

class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _QtyBtn(this.icon, this.onTap);

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 32, height: 32,
    child: IconButton(
      padding: EdgeInsets.zero,
      icon: Icon(icon, size: 18),
      onPressed: onTap,
    ),
  );
}
