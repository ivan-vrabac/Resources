import 'package:flutter/material.dart';

/// Confirm button that fires only after being held for 5 seconds (destructive actions).
class HoldFilledButton extends StatefulWidget {
  final String label;
  final VoidCallback onTriggered;
  const HoldFilledButton({super.key, required this.label, required this.onTriggered});
  @override
  State<HoldFilledButton> createState() => HoldFilledButtonState();
}

class HoldFilledButtonState extends State<HoldFilledButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 5));
    _ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        _ctrl.reset();
        widget.onTriggered();
      }
    });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  void _start() => _ctrl.forward();
  void _cancel() => _ctrl.reset();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _start(),
      onTapUp: (_) => _cancel(),
      onTapCancel: () => _cancel(),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          final holding = _ctrl.value > 0;
          final secs = (5 - (_ctrl.value * 5).floor()).clamp(1, 5);
          return ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Stack(
              alignment: Alignment.center,
              children: [
                LinearProgressIndicator(
                  value: _ctrl.value,
                  backgroundColor: Colors.red,
                  valueColor: AlwaysStoppedAnimation(Colors.brown.shade800),
                  minHeight: 40,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    holding ? '${secs}s' : widget.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
