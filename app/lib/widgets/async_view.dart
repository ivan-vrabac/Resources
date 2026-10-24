import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../constants.dart' show resAsset;
/// Consistent loading / error / empty states for screens backed by a server call.
class AsyncView extends StatelessWidget {
  final bool loading;
  final String? error;
  final bool empty;
  final String emptyText;
  final IconData emptyIcon;
  final VoidCallback? onRetry;
  final Widget Function() builder;

  const AsyncView({
    super.key,
    required this.loading,
    required this.builder,
    this.error,
    this.empty = false,
    this.emptyText = 'Nothing here yet',
    this.emptyIcon = Icons.inbox_outlined,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            const SizedBox(height: 12),
            Text(error!, textAlign: TextAlign.center, style: TextStyle(color: AppColors.t70)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry')),
            ],
          ]),
        ),
      );
    }
    if (empty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(emptyIcon, color: Colors.white24, size: 48),
          const SizedBox(height: 12),
          Text(emptyText, textAlign: TextAlign.center, style: TextStyle(color: AppColors.t54)),
        ]),
      );
    }
    return builder();
  }
}

/// Item image by item id (same asset convention as the rest of the app), with a fallback icon.
class ItemIcon extends StatelessWidget {
  final int itemId;
  final double size;
  const ItemIcon(this.itemId, {super.key, this.size = 28});

  @override
  Widget build(BuildContext context) => Image.asset(
        resAsset(itemId),
        width: size, height: size, fit: BoxFit.contain, gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Icon(Icons.inventory_2_outlined, size: size * 0.8, color: AppColors.t38),
      );
}

String fmtCredits(num v) {
  final a = v.abs();
  String s;
  if (a >= 1e12) {
    s = '${(v / 1e12).toStringAsFixed(2)}T';
  } else if (a >= 1e9) {
    s = '${(v / 1e9).toStringAsFixed(2)}B';
  } else if (a >= 1e6) {
    s = '${(v / 1e6).toStringAsFixed(2)}M';
  } else if (a >= 1e4) {
    s = '${(v / 1e3).toStringAsFixed(1)}k';
  } else {
    s = v.round().toString();
  }
  return 'ꞓ$s';
}

String fmtQty(num v) {
  final a = v.abs();
  if (a >= 1e9) return '${(v / 1e9).toStringAsFixed(2)}B';
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
  if (a >= 1e4) return '${(v / 1e3).toStringAsFixed(1)}k';
  return v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);
}
