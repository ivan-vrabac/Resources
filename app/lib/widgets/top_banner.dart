import 'package:flutter/material.dart';

class AppNotify {
  static OverlayEntry? _pending;

  static void show(BuildContext context, String message, {bool isError = false}) {
    _pending?.remove();
    _pending = null;

    final topOffset = MediaQuery.of(context).padding.top + 60.0;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TopBanner(
        message: message,
        isError: isError,
        topOffset: topOffset,
        onDone: () {
          try { entry.remove(); } catch (_) {}
          if (_pending == entry) _pending = null;
        },
      ),
    );
    Overlay.of(context).insert(entry);
    _pending = entry;
  }
}

class _TopBanner extends StatefulWidget {
  final String message;
  final bool isError;
  final double topOffset;
  final VoidCallback onDone;
  const _TopBanner({
    required this.message, required this.isError,
    required this.topOffset, required this.onDone,
  });
  @override
  State<_TopBanner> createState() => _TopBannerState();
}

class _TopBannerState extends State<_TopBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) _ctrl.reverse().then((_) => widget.onDone());
    });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: widget.topOffset,
      left: 16, right: 16,
      child: FadeTransition(
        opacity: _opacity,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: widget.isError
                  ? const Color(0xFFB71C1C).withValues(alpha: 0.92)
                  : const Color(0xFF1B5E20).withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 3))],
            ),
            child: Text(
              widget.message,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}
