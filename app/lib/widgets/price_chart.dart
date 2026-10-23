import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_colors.dart';
import 'async_view.dart' show fmtQty;
import '../models/player_provider.dart';
import '../services/game_api.dart';

/// Market price history of one item (server: /api/v1/market/prices): the system's buying price
/// (bottom line), its selling price (top line) and the daily average player price in between.
class PriceHistoryChart extends StatefulWidget {
  final int itemId;
  const PriceHistoryChart({super.key, required this.itemId});
  @override
  State<PriceHistoryChart> createState() => _PriceHistoryChartState();
}

class _PriceHistoryChartState extends State<PriceHistoryChart> {
  int _days = 7;
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await GameApi.call('/api/v1/market/prices', context.read<PlayerProvider>().sid,
        {'itemID': widget.itemId, 'days': _days});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rows = r.ok ? (r.data['days'] as List).cast<Map<String, dynamic>>() : [];
    });
  }

  @override
  Widget build(BuildContext context) {
    double? v(Map<String, dynamic> r, String k) => (r[k] as num?)?.toDouble();
    final sell = _rows.map((r) => v(r, 'systemSell')).toList();
    final buy = _rows.map((r) => v(r, 'systemBuy')).toList();
    final avg = _rows.map((r) => v(r, 'avg')).toList();
    final traded = _rows.map((r) => (r['traded'] as num? ?? 0) > 0).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Price history', style: TextStyle(color: AppColors.t54, fontSize: 12))),
        SegmentedButton<int>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: 7, label: Text('7 d')),
            ButtonSegment(value: 30, label: Text('30 d')),
            ButtonSegment(value: 365, label: Text('365 d')),
          ],
          selected: {_days},
          onSelectionChanged: (s) {
            _days = s.first;
            _load();
          },
        ),
      ]),
      const SizedBox(height: 6),
      SizedBox(
        height: 150,
        width: double.infinity,
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : _rows.isEmpty || sell.every((x) => x == null)
                ? Center(child: Text('No price data', style: TextStyle(color: AppColors.t54)))
                : CustomPaint(painter: _LinesPainter(sell, buy, avg, traded)),
      ),
      const SizedBox(height: 4),
      Wrap(spacing: 12, children: [
        _legend(Colors.greenAccent, 'System sells at'),
        _legend(Colors.amberAccent, 'Players paid (daily average)'),
        _legend(Colors.redAccent, 'System buys at'),
      ]),
    ]);
  }

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 3, color: c),
        const SizedBox(width: 4),
        Text(t, style: TextStyle(fontSize: 10, color: AppColors.t54)),
      ]);
}

class _LinesPainter extends CustomPainter {
  final List<double?> sell, buy, avg;
  final List<bool> traded;
  _LinesPainter(this.sell, this.buy, this.avg, this.traded);

  @override
  void paint(Canvas canvas, Size size) {
    final all = [...sell, ...buy, ...avg].whereType<double>().toList();
    if (all.isEmpty) return;
    var hi = all.reduce(max), lo = all.reduce(min);
    if ((hi - lo).abs() < 1e-9) { hi += 1; lo = max(0, lo - 1); }
    final n = sell.length;
    double x(int i) => n == 1 ? size.width / 2 : 40 + (size.width - 44) * i / (n - 1);
    double y(double val) => size.height - 6 - (val - lo) / (hi - lo) * (size.height - 18);
    final grid = Paint()..color = AppColors.fg.withValues(alpha: 0.08)..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final gy = 6 + (size.height - 12) * i / 3;
      canvas.drawLine(Offset(40, gy), Offset(size.width, gy), grid);
    }
    void line(List<double?> s, Color c, {bool dots = false}) {
      final path = Path();
      var started = false;
      for (var i = 0; i < n; i++) {
        final val = s[i];
        if (val == null) continue;
        final p = Offset(x(i), y(val));
        started ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
        started = true;
        if (dots && traded[i]) canvas.drawCircle(p, 3, Paint()..color = c);
      }
      canvas.drawPath(path, Paint()..color = c..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    line(buy, Colors.greenAccent);
    line(sell, Colors.redAccent);
    line(avg, Colors.amberAccent, dots: true);
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final (val, yy) in [(hi, 0.0), (lo, size.height - 12)]) {
      tp.text = TextSpan(text: fmtQty(val), style: TextStyle(color: AppColors.t54, fontSize: 10));
      tp.layout(maxWidth: 38);
      tp.paint(canvas, Offset(0, yy));
    }
  }

  @override
  bool shouldRepaint(covariant _LinesPainter old) => true;
}

/// Sale prices of a luxury item over (up to) the last 365 days, as dots (resource units).
class SalesDotsChart extends StatelessWidget {
  final List<Map<String, dynamic>> sales;
  const SalesDotsChart({super.key, required this.sales});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 120,
        width: double.infinity,
        child: CustomPaint(painter: _DotsPainter(sales)),
      );
}

class _DotsPainter extends CustomPainter {
  final List<Map<String, dynamic>> sales;
  _DotsPainter(this.sales);

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now().toUtc();
    final pts = <(double, double)>[];
    for (final s in sales) {
      final t = DateTime.tryParse('${s['ts']}Z'.replaceAll('ZZ', 'Z'));
      if (t == null) continue;
      pts.add((now.difference(t).inHours / 24.0, (s['price'] as num).toDouble()));
    }
    if (pts.isEmpty) return;
    final span = max(7.0, pts.map((p) => p.$1).reduce(max));
    var hi = pts.map((p) => p.$2).reduce(max), lo = pts.map((p) => p.$2).reduce(min);
    if ((hi - lo).abs() < 1e-9) { hi += 1; lo = max(0, lo - 1); }
    final grid = Paint()..color = AppColors.fg.withValues(alpha: 0.08)..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final gy = 6 + (size.height - 12) * i / 2;
      canvas.drawLine(Offset(40, gy), Offset(size.width, gy), grid);
    }
    for (final (age, price) in pts) {
      final px = 40 + (size.width - 44) * (1 - age / span);
      final py = size.height - 6 - (price - lo) / (hi - lo) * (size.height - 18);
      canvas.drawCircle(Offset(px, py), 4, Paint()..color = Colors.amberAccent);
    }
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final (val, yy) in [(hi, 0.0), (lo, size.height - 12)]) {
      tp.text = TextSpan(text: fmtQty(val), style: TextStyle(color: AppColors.t54, fontSize: 10));
      tp.layout(maxWidth: 38);
      tp.paint(canvas, Offset(0, yy));
    }
  }

  @override
  bool shouldRepaint(covariant _DotsPainter old) => true;
}
