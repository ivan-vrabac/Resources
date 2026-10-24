import 'dart:math' as math;
import 'package:flutter/material.dart';

// ── Radar icon painter — 3 rings + radial line + X section dividers ───────────

class RadarIconPainter extends CustomPainter {
  final Color color;
  const RadarIconPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final outerR = size.width * 0.46;
    final ring = Paint()
      ..color = color ..style = PaintingStyle.stroke ..strokeWidth = 1.2;
    for (final frac in [0.33, 0.65, 1.0]) {
      canvas.drawCircle(Offset(cx, cy), outerR * frac, ring);
    }
    // Radial sweep line
    const angle = -math.pi / 5;
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + outerR * math.cos(angle), cy + outerR * math.sin(angle)),
      Paint()..color = color..strokeWidth = 1.4..strokeCap = StrokeCap.round,
    );
    // Thin X dividers — noticeably thinner than the radial line
    final xPaint = Paint()..color = color..strokeWidth = 0.7;
    for (final a in [math.pi / 4, -math.pi / 4]) {
      canvas.drawLine(
        Offset(cx - outerR * math.cos(a), cy - outerR * math.sin(a)),
        Offset(cx + outerR * math.cos(a), cy + outerR * math.sin(a)),
        xPaint,
      );
    }
  }
  @override
  bool shouldRepaint(RadarIconPainter old) => old.color != color;
}

/// The scan button's radar symbol as a small widget (used in the log too).
class RadarIcon extends StatelessWidget {
  final double size;
  final Color color;
  const RadarIcon({super.key, this.size = 18, required this.color});
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: CustomPaint(painter: RadarIconPainter(color: color)));
}
