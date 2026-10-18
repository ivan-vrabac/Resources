import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../branding.dart';
import '../../constants.dart';
import '../../models/player.dart';
import '../../models/player_provider.dart';
import '../../screens/settings_screen.dart' show kCloudOpacity,
    kDroneRingColor, kDroneRingOpacity,
    kScanRingColor, kScanRingOpacity,
    kLocalRingColor, kLocalRingOpacity,
    kShowRingLabels,
    kGpsIntervalSeconds,
    kHeatmapScheme,
    kMapPanelOpacity,
    heatmapSchemeNotifier,
    mapPanelOpacityNotifier,
    paletteColorAt;
import '../../services/api_service.dart';
import '../../widgets/top_banner.dart';

// ── Heatmap data from server ───────────────────────────────────────────────────

class _HeatmapData {
  final LatLng center;
  final int gridN;
  final double stepM;
  final Map<int, Uint8List> pngs; // mineItemId → server-rendered PNG bytes
  const _HeatmapData({required this.center, required this.gridN, required this.stepM, required this.pngs});
}



// ── Resource colors for scan clouds and mine dots ──────────────────────────────

const Map<int, Color> _kMineColor = {
  4:   Color(0xFFBD9B4C), // Clay Pit – tan
  5:   Color(0xFF9E9E9E), // Gravel Pit – grey
  9:   Color(0xFF546E7A), // Coal Mine – blue-grey
  11:  Color(0xFF1565C0), // Oil Derrick – navy
  16:  Color(0xFFE65100), // Bauxite Mine – deep orange
  17:  Color(0xFFB71C1C), // Iron Ore Mine – dark red
  18:  Color(0xFFFFD600), // Gold Mine – amber
  19:  Color(0xFFCFD8DC), // Silver Mine – silver
  21:  Color(0xFFECEFF1), // Limestone Quarry – near-white
  27:  Color(0xFFBF360C), // Copper Mine – copper
  50:  Color(0xFF7B1FA2), // Ilmenite Mine – purple
  54:  Color(0xFFF9A825), // Sand Mine – yellow
  82:  Color(0xFF00BCD4), // Diamond Mine – cyan
  89:  Color(0xFF00897B), // Lithium Mine – teal
  168: Color(0xFF00695C), // Wolframite Mine – dark teal
};


// ── Hex clipper for mine images ────────────────────────────────────────────────

class _HexClipper extends CustomClipper<Path> {
  const _HexClipper();
  @override
  Path getClip(Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = size.width / 2;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final x = cx + r * math.cos(a);
      final y = cy - r * math.sin(a);
      if (i == 0) path.moveTo(x, y);
      else path.lineTo(x, y);
    }
    path.close();
    return path;
  }
  @override
  bool shouldReclip(covariant CustomClipper<Path> _) => false;
}

// ── Hex frame painter: colored ring + dark inner ───────────────────────────────

class _HexFramePainter extends CustomPainter {
  final Color ringColor;
  const _HexFramePainter({required this.ringColor});

  Path _hexPath(double cx, double cy, double r) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final x = cx + r * math.cos(a);
      final y = cy - r * math.sin(a);
      if (i == 0) path.moveTo(x, y);
      else path.lineTo(x, y);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx    = size.width / 2;
    final cy    = size.height / 2;
    final outer = size.width / 2;
    final inner = outer * 0.78;

    canvas.drawPath(_hexPath(cx, cy, outer),
        Paint()..color = ringColor.withValues(alpha: 0.85)..style = PaintingStyle.fill);
    canvas.drawPath(_hexPath(cx, cy, inner),
        Paint()..color = const Color(0xFF0A0A0A)..style = PaintingStyle.fill);
    final sw = (outer * 0.08).clamp(0.3, 1.5);
    canvas.drawPath(_hexPath(cx, cy, outer - sw / 2),
        Paint()
          ..color = const Color(0xFF888888)
          ..style = PaintingStyle.stroke
          ..strokeWidth = sw);
  }

  @override
  bool shouldRepaint(_HexFramePainter old) => old.ringColor != ringColor;
}

// ── Ghost hex outline painter: stroke only, no fill ───────────────────────────

class _HexOutlinePainter extends CustomPainter {
  final Color color;
  const _HexOutlinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = size.width / 2;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final x = cx + r * math.cos(a);
      final y = cy - r * math.sin(a);
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    path.close();
    final sw = (r * 0.12).clamp(0.5, 1.5);
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw);
  }

  @override
  bool shouldRepaint(_HexOutlinePainter old) => old.color != color;
}

// ── Absent resource background painter: grey hex fill + outline ───────────────

class _HexAbsentPainter extends CustomPainter {
  const _HexAbsentPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2, r = size.width / 2;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final x = cx + r * math.cos(a), y = cy - r * math.sin(a);
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    path.close();
    canvas.drawPath(path, Paint()
      ..color = Colors.grey.withValues(alpha: 0.20)
      ..style = PaintingStyle.fill);
    canvas.drawPath(path, Paint()
      ..color = Colors.grey.withValues(alpha: 0.60)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (r * 0.12).clamp(0.5, 1.5));
  }

  @override
  bool shouldRepaint(_HexAbsentPainter old) => false;
}

// ── Absent resource foreground painter: centered symmetrical red X ────────────
// Drawn on top of the icon child. Arms extend equal length at ±45°, clipped to hex.

class _HexAbsentXPainter extends CustomPainter {
  const _HexAbsentXPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2, r = size.width / 2;
    final hexPath = Path();
    for (int i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final x = cx + r * math.cos(a), y = cy - r * math.sin(a);
      if (i == 0) hexPath.moveTo(x, y); else hexPath.lineTo(x, y);
    }
    hexPath.close();
    canvas.save();
    canvas.clipPath(hexPath);
    final arm = math.min(size.width, size.height) * 0.40;
    final xPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx - arm, cy - arm), Offset(cx + arm, cy + arm), xPaint);
    canvas.drawLine(Offset(cx + arm, cy - arm), Offset(cx - arm, cy + arm), xPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HexAbsentXPainter old) => false;
}

// ── GPS position painter: compass tick marks around a white center dot ─────────

class _PosCrosshairPainter extends CustomPainter {
  final double? headingDeg;
  const _PosCrosshairPainter({this.headingDeg});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final tickPaint = Paint()
      ..color = Colors.yellow
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    const innerR = 12.0;
    const outerR = 18.0;
    const innerRSmall = 14.0;
    const outerRSmall = 17.0;
    // Main ticks (every 45°)
    for (int i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      canvas.drawLine(
        Offset(cx + innerR * math.cos(a), cy + innerR * math.sin(a)),
        Offset(cx + outerR * math.cos(a), cy + outerR * math.sin(a)),
        tickPaint,
      );
    }
    // Small ticks between main ones (every 45°, offset by 22.5°)
    final smallPaint = Paint()
      ..color = Colors.yellow.withValues(alpha: 0.6)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < 8; i++) {
      final a = (i + 0.5) * math.pi / 4;
      canvas.drawLine(
        Offset(cx + innerRSmall * math.cos(a), cy + innerRSmall * math.sin(a)),
        Offset(cx + outerRSmall * math.cos(a), cy + outerRSmall * math.sin(a)),
        smallPaint,
      );
    }
    // White heading tick — slightly longer, drawn on top
    if (headingDeg != null) {
      final a = headingDeg! * math.pi / 180 - math.pi / 2;
      canvas.drawLine(
        Offset(cx + innerR * math.cos(a), cy + innerR * math.sin(a)),
        Offset(cx + (outerR + 3) * math.cos(a), cy + (outerR + 3) * math.sin(a)),
        Paint()..color = Colors.white..strokeWidth = 1.5..style = PaintingStyle.stroke,
      );
    }
    // Yellow center dot
    canvas.drawCircle(Offset(cx, cy), 1.5,
        Paint()..color = Colors.yellow..style = PaintingStyle.fill);
  }
  @override
  bool shouldRepaint(_PosCrosshairPainter old) => old.headingDeg != headingDeg;
}

// ── Thin red crosshair painter ────────────────────────────────────────────────

class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red.withValues(alpha: 0.75)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    final cx = size.width / 2;
    final cy = size.height / 2;
    const gap = 3.0;
    // horizontal
    canvas.drawLine(Offset(0, cy), Offset(cx - gap, cy), paint);
    canvas.drawLine(Offset(cx + gap, cy), Offset(size.width, cy), paint);
    // vertical
    canvas.drawLine(Offset(cx, 0), Offset(cx, cy - gap), paint);
    canvas.drawLine(Offset(cx, cy + gap), Offset(cx, size.height), paint);
  }
  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}

// ── Palette colorization: build LUTs from palette stops ──────────────────────

Uint8List _buildPaletteLut(String palette) {
  final lut = Uint8List(256 * 4); // [R, G, B, A] per v
  for (int v = 1; v < 256; v++) {
    final c = paletteColorAt(v, palette);
    lut[v * 4]     = (c.r * 255).round();
    lut[v * 4 + 1] = (c.g * 255).round();
    lut[v * 4 + 2] = (c.b * 255).round();
    lut[v * 4 + 3] = (c.a * 255).round();
  }
  return lut;
}

final _classicLut  = _buildPaletteLut('classic');
final _coldLut     = _buildPaletteLut('cold');
final _contrastLut = _buildPaletteLut('contrast');

Uint8List _getLut(String palette) {
  switch (palette) {
    case 'cold':     return _coldLut;
    case 'contrast': return _contrastLut;
    default:         return _classicLut;
  }
}

// Apply LUT to a grayscale PNG, returning a decoded ui.Image.
// Eliminates the expensive PNG re-encode that was the primary scan latency bottleneck.
Future<ui.Image> _applyLutToUiImage(Uint8List grayscalePng, Uint8List lut) async {
  final codec = await ui.instantiateImageCodec(grayscalePng);
  final frame = await codec.getNextFrame();
  final srcImg = frame.image;
  final w = srcImg.width, h = srcImg.height;
  final bd = await srcImg.toByteData(format: ui.ImageByteFormat.rawRgba);
  srcImg.dispose();
  if (bd == null) {
    final c2 = await ui.instantiateImageCodec(grayscalePng);
    return (await c2.getNextFrame()).image;
  }
  final src = bd.buffer.asUint8List();
  final dst = Uint8List(src.length);
  for (int i = 0; i < src.length; i += 4) {
    final v = src[i];
    dst[i]     = lut[v * 4];
    dst[i + 1] = lut[v * 4 + 1];
    dst[i + 2] = lut[v * 4 + 2];
    dst[i + 3] = lut[v * 4 + 3];
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(dst, w, h, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

// ImageProvider that wraps a decoded ui.Image directly — no encode/decode roundtrip.
class _UiImageProvider extends ImageProvider<_UiImageProvider> {
  final ui.Image image;
  const _UiImageProvider(this.image);

  @override
  Future<_UiImageProvider> obtainKey(ImageConfiguration _) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_UiImageProvider key, ImageDecoderCallback _) =>
      OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: key.image.clone())),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _UiImageProvider && other.image == image);

  @override
  int get hashCode => image.hashCode;
}

// ── Mine cluster cloud painter ─────────────────────────────────────────────────
// Draws nearby mines as a merged blob (union of circles) at low zoom.
// Soft cluster clouds: one blurred circle per pre-computed cluster centroid.
// No Path.combine — clusters are computed once at load time, not every frame.

// ── Hex icon painter for mine toggle button — clean outline only ──────────────

class _HexIconPainter extends CustomPainter {
  final Color color;
  const _HexIconPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final r = size.width / 2 - 1.5;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = i * math.pi / 3 - math.pi / 6;
      final x = cx + r * math.cos(a), y = cy + r * math.sin(a);
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    path.close();
    canvas.drawPath(path, Paint()
      ..color = color ..style = PaintingStyle.stroke ..strokeWidth = 2.0);
  }
  @override
  bool shouldRepaint(_HexIconPainter old) => old.color != color;
}

// ── Radar icon painter — 3 rings + radial line + X section dividers ───────────

class _RadarIconPainter extends CustomPainter {
  final Color color;
  const _RadarIconPainter({required this.color});
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
  bool shouldRepaint(_RadarIconPainter old) => old.color != color;
}

class _MineCloudPainter extends CustomPainter {
  final List<_ClusterDot> clusters;
  final LatLng center;
  final double zoom;
  const _MineCloudPainter({required this.clusters, required this.center, required this.zoom});

  static double _tx(double lng, double z) =>
      (lng + 180) / 360 * 256 * math.pow(2, z);
  static double _ty(double lat, double z) {
    final lr = lat * math.pi / 180;
    return (1 - math.log(math.tan(lr) + 1 / math.cos(lr)) / math.pi) / 2 * 256 * math.pow(2, z);
  }

  Offset _toScreen(double lat, double lng, Size size) {
    final cx = _tx(center.longitude, zoom);
    final cy = _ty(center.latitude, zoom);
    return Offset(size.width / 2 + _tx(lng, zoom) - cx,
                  size.height / 2 + _ty(lat, zoom) - cy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (clusters.isEmpty) return;

    // Screen-pixel radius: small at far zoom (~8px), larger close-up (~50px).
    // Geographic footprint stays small — nearby clusters merge visually because
    // their soft edges overlap as the map zooms out, not because the radius grows.
    final zoomT = ((zoom - 3.0) / 12.0).clamp(0.0, 1.0);
    final baseR = (8.0 * math.pow(5.0, zoomT)).clamp(6.0, 60.0);

    // saveLayer: circles are drawn into an offscreen buffer first.
    // BlendMode.lighten on each circle = max(src, buffer) per channel → no alpha
    // accumulation. Hundreds of overlapping circles produce the same max opacity as one.
    canvas.saveLayer(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..blendMode = BlendMode.srcOver,
    );

    for (final dot in clusters) {
      final sp = _toScreen(dot.lat, dot.lng, size);
      if (sp.dx < -baseR || sp.dx > size.width + baseR ||
          sp.dy < -baseR || sp.dy > size.height + baseR) continue;

      // Absolute normalization against count=50 as the saturation point.
      // Independent of how many dots the viewport contains (no viewport-relative max).
      // count=1: 0.16 opacity, count=10: 0.25, count>=50: 0.40 ceiling.
      final norm = (dot.count / 50.0).clamp(0.0, 1.0);
      final opacity = 0.12 + 0.28 * math.sqrt(norm);
      // Denser cells are slightly larger, but growth is very slow (max +25%).
      final r = baseR * (1.0 + 0.25 * norm).clamp(1.0, 1.25);

      canvas.drawCircle(
        sp, r,
        Paint()
          ..blendMode = BlendMode.lighten
          ..shader = RadialGradient(
            colors: [
              const Color(0xFFFF8C00).withValues(alpha: opacity),
              const Color(0xFFFF8C00).withValues(alpha: opacity * 0.30),
              const Color(0x00FF8C00),
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(Rect.fromCircle(center: sp, radius: r)),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MineCloudPainter old) =>
      old.clusters != clusters || old.center != center || old.zoom != zoom;
}

// ── Pre-computed cluster dot (centroid + mine count) ──────────────────────────

class _ClusterDot {
  final double lat, lng;
  final int count;
  const _ClusterDot(this.lat, this.lng, this.count);
}

// ── Marquee text — scrolls slowly after 3 s when text overflows ───────────────

class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final bool running;
  const _MarqueeText({required this.text, this.style, required this.running, super.key});
  @override State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _delay;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this)
      ..addListener(() => setState(() {}))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted) {
          _delay = Timer(const Duration(seconds: 2), () {
            if (mounted && widget.running) { _ctrl.value = 0; _scheduleScroll(); }
          });
        }
      });
    if (widget.running) _scheduleScroll();
  }

  @override
  void didUpdateWidget(_MarqueeText old) {
    super.didUpdateWidget(old);
    if (!widget.running) {
      _delay?.cancel(); _ctrl.stop(); _ctrl.value = 0;
    } else if (!old.running || widget.text != old.text) {
      _delay?.cancel(); _ctrl.stop(); _ctrl.value = 0; _scheduleScroll();
    }
  }

  @override
  void dispose() { _delay?.cancel(); _ctrl.dispose(); super.dispose(); }

  void _scheduleScroll() {
    _delay?.cancel();
    _delay = Timer(const Duration(seconds: 3), () {
      if (!mounted || _overflow <= 0) return;
      _ctrl.duration = Duration(milliseconds: (_overflow * 50).round().clamp(800, 4000));
      _ctrl.forward(from: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final tp = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style ?? DefaultTextStyle.of(ctx).style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: double.infinity);
      final newOverflow = (tp.width - constraints.maxWidth).clamp(0.0, double.infinity);
      if (newOverflow != _overflow) {
        _overflow = newOverflow;
        if (_overflow > 0 && widget.running && !_ctrl.isAnimating && _ctrl.value == 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _scheduleScroll(); });
        }
      }
      if (_overflow <= 0) {
        return Text(widget.text, style: widget.style, overflow: TextOverflow.ellipsis);
      }
      return ClipRect(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Transform.translate(
            offset: Offset(-_ctrl.value * _overflow, 0),
            child: Text(widget.text, style: widget.style, softWrap: false),
          ),
        ),
      );
    });
  }
}

// ── MapTab ─────────────────────────────────────────────────────────────────────

class MapTab extends StatefulWidget {
  const MapTab({super.key});
  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final _mapCtrl = MapController();
  LatLng? _pos;        // GPS position
  LatLng? _lastLoadPos; // GPS position at last _loadMarkers call
  LatLng? _mapCenter;  // Map center = crosshair target
  // Updated on every pan frame without setState — drives the live distance display.
  final _crosshairDist = ValueNotifier<double>(0.0);
  bool _following    = true;
  bool _scanning     = false;
  bool _showClouds   = false;
  bool _showHQs      = true;
  bool _showMines    = true;
  bool _mockDetected = false;
  double? _heading;

  List<dynamic> _markers = [];
  List<dynamic> _hqMarkers = [];
  int _hqLoadSeq = 0; // independent sequence counter for HQ requests
  int _hqLastMinLevel = -1;  // last tier successfully loaded
  DateTime? _hqLastFetch;    // time of last successful HQ fetch
  LatLngBounds? _hqLastBounds; // bounds of last successful HQ fetch
  final List<_HeatmapData> _heatmapScans = [];
  List<OverlayImage> _cachedHeatmapOverlays = [];
  List<Map<String, dynamic>> _lastResults = [];
  int _selectedMineType = 4; // Clay — never null; persisted across sessions
  double _mapZoom = 15.0;
  double _builtZoom = 15.0; // zoom at last build; compared vs _mapZoom to detect drift
  bool _showResourcePicker = false;
  LatLng? _lastScanPos;
  Timer? _markerTimer;
  Timer? _markerDebounce;
  Timer? _mapMoveDebounce;
  int _loadSeq = 0; // incremented before each request; stale responses are discarded
  String? _prospectToken;  // single-use token from last scan; null = no valid scan
  bool _building = false;  // guard against concurrent construction taps
  List<_ClusterDot> _mineClusters = [];
  // Bounded density tile cache: up to _kDensityCacheMax entries, FIFO eviction.
  final Map<String, List<_ClusterDot>> _densityCache = {};
  final List<String> _densityCacheKeys = [];
  static const int _kDensityCacheMax = 30;
  StreamSubscription<Position>? _posStream;
  DateTime _lastPosApplied = DateTime.fromMillisecondsSinceEpoch(0);
  // Palette colorization: grayscale PNGs stored in _heatmapScans; decoded+colored ui.Images here.
  Map<int, ui.Image> _colorizedImages = {};
  String _colorizedPalette = '';
  // Scan-in-flight flag: prevents GPS camera follow from displacing the heatmap anchor.
  bool _scanInFlight = false;
  final _resourceScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _initLocation();
    _loadLastMineType();
    _loadMapToggles();
    heatmapSchemeNotifier.addListener(_onPaletteChanged);
    mapPanelOpacityNotifier.addListener(_onPanelOpacityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PlayerProvider>().addListener(_onProviderChanged);
      _scheduleLoadMarkers();
      // HQ loading does not require GPS — fire immediately after map initialises.
      Future.delayed(const Duration(milliseconds: 250), () {
        if (!mounted) return;
        final sid = context.read<PlayerProvider>().sid;
        if (sid.isEmpty) return;
        try {
          final bounds = _mapCtrl.camera.visibleBounds;
          unawaited(_loadHqMarkers(sid, bounds));
        } catch (_) {}
      });
    });
  }

  Future<void> _loadMapToggles() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showMines = p.getBool('map_show_mines') ?? true;
      _showHQs   = p.getBool('map_show_hqs')   ?? true;
    });
  }

  void _onPaletteChanged() {
    if (_heatmapScans.isNotEmpty && mounted) _colorizeAndRebuild();
  }

  void _onPanelOpacityChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadLastMineType() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getInt('last_mine_type');
    if (saved != null && mounted) setState(() { _selectedMineType = saved; _rebuildHeatmapOverlays(); });
  }

  Future<void> _saveLastMineType(int mineId) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('last_mine_type', mineId);
  }

  void _onProviderChanged() {
    final nav = context.read<PlayerProvider>().chatNavigateTo;
    if (nav != null && mounted) {
      setState(() { _mapCenter = nav; _following = false; });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapCtrl.move(nav, 16);
      });
      context.read<PlayerProvider>().setChatNavigateTo(null);
    }
  }

  @override
  void dispose() {
    _markerTimer?.cancel();
    _markerDebounce?.cancel();
    _mapMoveDebounce?.cancel();
    _posStream?.cancel();
    _crosshairDist.dispose();
    _resourceScrollCtrl.dispose();
    heatmapSchemeNotifier.removeListener(_onPaletteChanged);
    mapPanelOpacityNotifier.removeListener(_onPanelOpacityChanged);
    context.read<PlayerProvider>().removeListener(_onProviderChanged);
    for (final img in _colorizedImages.values) img.dispose();
    super.dispose();
  }

  Future<void> _initLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) return;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      _onPos(pos);
    } catch (_) {}
    _startPosStream();
    _markerTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadMarkers());
  }

  void _startPosStream() {
    _posStream?.cancel();
    final intervalMs = kGpsIntervalSeconds * 1000;
    _posStream = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        intervalDuration: Duration(milliseconds: intervalMs),
      ),
    ).listen(_onPos);
  }

  void _onPos(Position pos) {
    if (!mounted) return;
    if (pos.isMocked) {
      setState(() => _mockDetected = true);
      return;
    }
    // Reject clearly inaccurate fixes (Android Fused Location Provider occasionally delivers stale fixes)
    if (pos.accuracy > 80) return;

    // Client-side throttle: apply update only if enough time has elapsed
    final now = DateTime.now();
    if (now.difference(_lastPosApplied).inSeconds < kGpsIntervalSeconds) return;

    // Plausibility check: reject impossible speed (>300 km/h ≈ 83 m/s)
    if (_pos != null) {
      final elapsed = now.difference(_lastPosApplied).inMilliseconds / 1000.0;
      final ll0 = _pos!;
      final ll1 = LatLng(pos.latitude, pos.longitude);
      if (elapsed > 0 && elapsed < 30) {
        final dist = _distM(ll0, ll1);
        if (dist / elapsed > 83) return; // impossible speed — ignore
      }
    }

    _lastPosApplied = now;
    final ll = LatLng(pos.latitude, pos.longitude);
    setState(() {
      _pos = ll;
      _mapCenter ??= ll;
      if (pos.heading >= 0) _heading = pos.heading;
    });
    // Do not move camera during an in-flight scan to avoid displacing heatmap anchor
    if (_following && !_scanInFlight) _mapCtrl.move(ll, _mapCtrl.camera.zoom);
    if (_lastLoadPos == null || _distM(_lastLoadPos!, ll) > 50) {
      _lastLoadPos = ll;
      _scheduleLoadMarkers();
    }
  }

  Future<void> _colorizeAndRebuild({bool autoShow = false}) async {
    if (_heatmapScans.isEmpty || !mounted) return;
    final palette = kHeatmapScheme;
    final lut = _getLut(palette);
    final data = _heatmapScans.first;
    final priorityKey = _selectedMineType;

    // Colorize selected resource first so the overlay appears as soon as possible.
    final selPng = data.pngs[priorityKey];
    if (selPng != null) {
      final img = await _applyLutToUiImage(selPng, lut);
      if (!mounted) { img.dispose(); return; }
      final old = _colorizedImages[priorityKey];
      setState(() {
        _colorizedImages[priorityKey] = img;
        _colorizedPalette = palette;
        if (autoShow) _showClouds = true;
        _rebuildHeatmapOverlays();
      });
      old?.dispose();
    }

    // Colorize remaining resources in the background.
    for (final entry in data.pngs.entries) {
      if (entry.key == priorityKey) continue;
      final img = await _applyLutToUiImage(entry.value, lut);
      if (!mounted) { img.dispose(); return; }
      final old = _colorizedImages[entry.key];
      setState(() { _colorizedImages[entry.key] = img; });
      old?.dispose();
    }
    if (mounted) setState(() => _colorizedPalette = palette);
  }

  void _scheduleLoadMarkers() {
    _markerDebounce?.cancel();
    _markerDebounce = Timer(const Duration(milliseconds: 100), _loadMarkers);
  }

  // Cache key for density responses: zoom bucket + bbox snapped to 0.5° grid.
  String _densityKey(double zoom, LatLngBounds b) {
    final z = zoom.floor();
    final lat1 = (b.south / 0.5).floor();
    final lat2 = (b.north  / 0.5).ceil();
    final lng1 = (b.west   / 0.5).floor();
    final lng2 = (b.east   / 0.5).ceil();
    return '$z,$lat1,$lat2,$lng1,$lng2';
  }

  void _storeDensityCache(String key, List<_ClusterDot> dots) {
    if (_densityCache.containsKey(key)) return; // already cached
    _densityCache[key] = dots;
    _densityCacheKeys.add(key);
    while (_densityCacheKeys.length > _kDensityCacheMax) {
      _densityCache.remove(_densityCacheKeys.removeAt(0));
    }
  }

  // Load HQ markers independently of GPS and mine loading sequence.
  // Server filters other players' HQs by min_level derived from current zoom.
  Future<void> _loadHqMarkers(String sid, LatLngBounds bounds) async {
    final minLevel = _hqMinLevel(_mapZoom);
    // Skip redundant request: same tier, recent fetch, and current view within cached bounds.
    final now = DateTime.now();
    if (minLevel == _hqLastMinLevel &&
        _hqLastFetch != null && now.difference(_hqLastFetch!).inSeconds < 120 &&
        _hqLastBounds != null && _hqBoundsSubsumed(bounds, _hqLastBounds!)) return;

    final seq = ++_hqLoadSeq;
    final hqData = await ApiService.getHQMarkers(
        sid, bounds.south, bounds.west, bounds.north, bounds.east,
        minLevel: minLevel);
    if (!mounted || seq != _hqLoadSeq) return;
    if (hqData != null) {
      _hqLastMinLevel = minLevel;
      _hqLastFetch    = DateTime.now();
      _hqLastBounds   = bounds;
      final hqs = hqData.map((h) {
        final m = Map<String, dynamic>.from(h as Map);
        m['type'] = 'hq';
        return m;
      }).toList();
      setState(() => _hqMarkers = hqs);
    }
  }

  // Min HQ level visible at the given zoom (level N requires its threshold ≤ zoom).
  int _hqMinLevel(double zoom) {
    if (zoom >= 16.0) return 1;
    if (zoom >= 15.5) return 2;
    if (zoom >= 15.0) return 3;
    if (zoom >= 14.5) return 4;
    if (zoom >= 14.0) return 5;
    if (zoom >= 13.5) return 6;
    if (zoom >= 12.5) return 7;
    if (zoom >= 11.5) return 8;
    if (zoom >= 10.5) return 9;
    if (zoom >= 9.0)  return 10;
    return 11; // nothing visible at this zoom
  }

  // True when inner bounds is fully contained within outer (with tolerance).
  static bool _hqBoundsSubsumed(LatLngBounds inner, LatLngBounds outer) =>
      inner.south >= outer.south - 0.05 && inner.north <= outer.north + 0.05 &&
      inner.west  >= outer.west  - 0.10 && inner.east  <= outer.east  + 0.10;

  Future<void> _loadMarkers() async {
    final sid = context.read<PlayerProvider>().sid;
    if (sid.isEmpty) return;
    late final LatLngBounds bounds;
    try { bounds = _mapCtrl.camera.visibleBounds; } catch (_) { return; }

    // HQ loading is GPS-independent and has its own sequence guard.
    unawaited(_loadHqMarkers(sid, bounds));

    // Mine loading requires GPS position.
    if (_pos == null) return;
    final seq = ++_loadSeq;
    final currentZoom = _mapZoom;

    if (currentZoom < 14.5) {
      // Far/medium zoom: server-side density aggregates for mines.
      // HQs already loaded above and shown via _hqMarkers.
      final cacheKey = _densityKey(currentZoom, bounds);
      if (_densityCache.containsKey(cacheKey)) {
        if (seq == _loadSeq && mounted) {
          setState(() => _mineClusters = _densityCache[cacheKey]!);
        }
        return;
      }
      final data = await ApiService.getMineDensity(
          sid, bounds.south, bounds.west, bounds.north, bounds.east, currentZoom);
      if (!mounted || seq != _loadSeq || data == null) return;
      final dots = data.map((d) => _ClusterDot(
          (d['lat'] as num).toDouble(),
          (d['lng'] as num).toDouble(),
          (d['count'] as num).toInt())).toList();
      _storeDensityCache(cacheKey, dots);
      setState(() => _mineClusters = dots);
    } else {
      // Close zoom: individual mine markers for the visible viewport.
      final result = await ApiService.getMapMarkers(
          sid, bounds.south, bounds.west, bounds.north, bounds.east);
      if (!mounted || seq != _loadSeq || result == null) return;
      setState(() {
        _markers = result;
        _computeClustersGrid(); // O(n) grid — used for zoom-out transitions
      });
    }
  }

  double _distM(LatLng a, LatLng b) {
    final lat1 = a.latitude  * math.pi / 180;
    final lat2 = b.latitude  * math.pi / 180;
    final dLat = (b.latitude  - a.latitude)  * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.sin(dLat/2)*math.sin(dLat/2) +
              math.cos(lat1)*math.cos(lat2)*math.sin(dLng/2)*math.sin(dLng/2);
    return 12742000 * math.asin(math.sqrt(h.clamp(0, 1)));
  }


  String _fmtDist(double m) {
    if (m < 1000) return '${m.round()} m';
    if (m < 10000) return '${(m / 1000).toStringAsFixed(2)} km';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }

  // Aggregate detail markers into centroid+count cells (0.003° ≈ 330m).
  // Used as instant fallback when the dedicated density endpoint hasn't responded yet.
  void _computeClustersGrid() {
    final mines = _markers.where((m) => m['type'] != 'hq').toList();
    if (mines.isEmpty) { _mineClusters = []; return; }
    const cell = 0.003;
    final Map<String, List<double>> grid = {};
    for (final m in mines) {
      final lat = (m['lat'] as num).toDouble();
      final lng = (m['lng'] as num).toDouble();
      final latC = (lat / cell).floorToDouble() * cell + cell / 2;
      final lngC = (lng / cell).floorToDouble() * cell + cell / 2;
      final key = '${latC.toStringAsFixed(6)}:${lngC.toStringAsFixed(6)}';
      if (grid.containsKey(key)) {
        grid[key]![0] += lat; grid[key]![1] += lng; grid[key]![2] += 1;
      } else {
        grid[key] = [lat, lng, 1.0];
      }
    }
    _mineClusters = grid.values
        .map((v) => _ClusterDot(v[0] / v[2], v[1] / v[2], v[2].toInt()))
        .toList();
  }

  LatLng _offsetPt(LatLng from, double distM, double angle) {
    final cosLat = math.cos(from.latitude * math.pi / 180);
    final safeCos = cosLat.abs() < 0.001 ? 0.001 : cosLat;
    return LatLng(
      from.latitude  + (distM / 111320.0) * math.cos(angle),
      from.longitude + (distM / (111320.0 * safeCos)) * math.sin(angle),
    );
  }

  double _bearingRad(LatLng from, LatLng to) {
    final cosLat = math.cos(from.latitude * math.pi / 180);
    final safeCos = cosLat.abs() < 0.001 ? 0.001 : cosLat;
    final dlng = (to.longitude - from.longitude) * 111320.0 * safeCos;
    final dlat = (to.latitude  - from.latitude)  * 111320.0;
    return math.atan2(dlng, dlat);
  }

  // 6 hex vertices at radiusM from center — flat-top orientation (matches screen image).
  // Offset by π/6 so vertex 0 is NE (not N), giving flat sides at top/bottom on the map.
  List<LatLng> _hexGeoPoints(LatLng center, double radiusM) {
    final cosLat = math.cos(center.latitude * math.pi / 180);
    final safeCos = cosLat.abs() < 0.001 ? 0.001 : cosLat;
    return List.generate(6, (i) {
      final a = math.pi / 6 + i * math.pi / 3;
      return LatLng(
        center.latitude  + (radiusM * math.cos(a)) / 111320.0,
        center.longitude + (radiusM * math.sin(a)) / (111320.0 * safeCos),
      );
    });
  }

  // Minimum center-to-center distance for flat-top hex tiles of circumradius 15m
  // in the direction from [from] to [to]. At edge-normal directions this is √3×15≈25.98m;
  // at vertex directions (30° off) it rises to 2×15=30m.
  double _hexMinDist(LatLng from, LatLng to) {
    final bearing = _bearingRad(from, to);
    final b = ((bearing % (2 * math.pi)) + 2 * math.pi) % (2 * math.pi);
    // Round to nearest edge-normal (0°,60°,…) rather than using %, which maps
    // exact multiples of π/3 to sector=0 → phi=π/6 (vertex) — wrong.
    final nearest = (b / (math.pi / 3)).round() * (math.pi / 3);
    final phi = (b - nearest).abs().clamp(0.0, math.pi / 6 - 0.001);
    return 15.0 * math.sqrt(3) / math.cos(phi);
  }

  // Snap to the nearest valid hex-grid slot around existing mines.
  // Adjacent mines are exactly sqrt(3)*15 ≈ 25.98m apart (edge-to-edge tiling).
  // Enumerate all 6 neighbor slots of each mine; pick the valid slot closest to target.
  LatLng _snapBuildPos(LatLng target) {
    const kEdgeDist = 25.98; // sqrt(3) * 15m
    const kDirs = <double>[
      0,                 // 0°   N
      math.pi / 3,      // 60°  NE
      2 * math.pi / 3,  // 120° SE
      math.pi,          // 180° S
      4 * math.pi / 3,  // 240° SW
      5 * math.pi / 3,  // 300° NW
    ];

    final mines = _markers
        .where((m) => m['type'] != 'hq')
        .map((m) => LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()))
        .toList();

    if (mines.isEmpty) return target;

    // Direction-aware hex overlap check: minimum distance depends on bearing.
    bool isValid(LatLng pt) {
      for (final m in mines) {
        if (_distM(pt, m) < _hexMinDist(m, pt) - 0.1) return false;
      }
      return true;
    }

    if (isValid(target)) return target;

    LatLng? best;
    double bestDist = double.infinity;
    for (final mine in mines) {
      for (final dir in kDirs) {
        final candidate = _offsetPt(mine, kEdgeDist, dir);
        if (!isValid(candidate)) continue;
        final d = _distM(candidate, target);
        if (d < bestDist) { bestDist = d; best = candidate; }
      }
    }
    return best ?? target;
  }

  void _rebuildHeatmapOverlays() {
    final overlays = <OverlayImage>[];
    if (_showClouds && _colorizedImages.isNotEmpty && _heatmapScans.isNotEmpty) {
      final data = _heatmapScans.first;
      final img = _colorizedImages[_selectedMineType];
      if (img != null) {
        final cosLat = math.cos(data.center.latitude * math.pi / 180).abs().clamp(0.001, 1.0);
        final halfM  = data.stepM * (data.gridN ~/ 2);
        final dLat   = halfM / 111320.0;
        final dLng   = halfM / (111320.0 * cosLat);
        final bounds = LatLngBounds(
          LatLng(data.center.latitude - dLat, data.center.longitude - dLng),
          LatLng(data.center.latitude + dLat, data.center.longitude + dLng),
        );
        overlays.add(OverlayImage(
          bounds: bounds,
          imageProvider: _UiImageProvider(img),
          opacity: kCloudOpacity,
          gaplessPlayback: true,
        ));
      }
    }
    _cachedHeatmapOverlays = overlays;
  }

  Future<void> _scan({bool drone = false}) async {
    if (_scanning || _pos == null) return;
    // Capture scan center once at press time — immutable for the lifetime of this request.
    final scanCenter = _mapCenter ?? _pos!;
    final dist = _distM(_pos!, scanCenter);
    if (!drone && dist > 100) {
      _snack('Crosshair is outside build range (100m). Try drone scan.');
      return;
    }
    _scanInFlight = true; // blocks GPS camera follow until overlay is ready
    setState(() { _scanning = true; _prospectToken = null; _showResourcePicker = false; });
    final sid = context.read<PlayerProvider>().sid;
    final t0 = DateTime.now();
    debugPrint('[SCAN_DBG ${t0.toIso8601String()}] pressed drone=$drone scanCenter=${scanCenter.latitude.toStringAsFixed(6)},${scanCenter.longitude.toStringAsFixed(6)} cameraZoom=${_mapCtrl.camera.zoom.toStringAsFixed(2)} cameraCenter=${_mapCtrl.camera.center.latitude.toStringAsFixed(6)},${_mapCtrl.camera.center.longitude.toStringAsFixed(6)}');
    final res  = await ApiService.scan(sid, scanCenter.latitude, scanCenter.longitude,
        drone: drone, playerLat: _pos?.latitude, playerLng: _pos?.longitude);
    if (!mounted) { _scanInFlight = false; return; }
    debugPrint('[SCAN_DBG ${DateTime.now().toIso8601String()}] response err=${res?['err']} cameraCenter=${_mapCtrl.camera.center.latitude.toStringAsFixed(6)},${_mapCtrl.camera.center.longitude.toStringAsFixed(6)}');

    if (res == null || res['err'] != 0) {
      _scanInFlight = false;
      setState(() => _scanning = false);
      _snack(res?['msg'] ?? 'Scan failed');
      return;
    }

    // Refresh player after drone scan to update drone count in UI
    if (drone) {
      context.read<PlayerProvider>().refresh();
    }

    // Parse all response data before touching widget state.
    final results = (res['results'] as List? ?? []).cast<Map<String, dynamic>>();

    _HeatmapData? newScan;
    final hm = res['heatmap'] as Map<String, dynamic>?;
    if (hm != null && hm['pngs'] is Map) {
      final gridN   = (hm['grid'] as int?) ?? 61;
      final stepM   = ((hm['step_m'] as num?)?.toDouble()) ?? 4.0;
      final tileLat = (hm['center_lat'] as num?)?.toDouble() ?? scanCenter.latitude;
      final tileLng = (hm['center_lng'] as num?)?.toDouble() ?? scanCenter.longitude;
      final tileCenter = LatLng(tileLat, tileLng);
      debugPrint('[SCAN_DBG ${DateTime.now().toIso8601String()}] heatmap tileCenter=${tileLat.toStringAsFixed(6)},${tileLng.toStringAsFixed(6)} grid=$gridN step=$stepM');
      final pngs = <int, Uint8List>{};
      for (final e in (hm['pngs'] as Map<String, dynamic>).entries) {
        final id  = int.tryParse(e.key);
        final b64 = e.value as String?;
        if (id != null && b64 != null) pngs[id] = base64Decode(b64);
      }
      if (pngs.isNotEmpty) {
        newScan = _HeatmapData(center: tileCenter, gridN: gridN, stepM: stepM, pngs: pngs);
      }
    }

    final newToken = res['prospect_token'] as String?;

    // Commit scan metadata immediately, but keep old overlay visible until
    // new colorization is complete to avoid a flash of blank map.
    setState(() {
      _scanning = false;
      _heatmapScans.clear();
      if (newScan != null) _heatmapScans.add(newScan);
      _lastResults = results;
      _lastScanPos = scanCenter;
      _prospectToken = newToken;
      // _colorizedImages and _cachedHeatmapOverlays kept until new images are ready.
    });
    debugPrint('[SCAN_DBG ${DateTime.now().toIso8601String()}] state committed, starting colorization');

    if (newScan != null) {
      // _colorizeAndRebuild disposes old images and swaps in new ones atomically.
      await _colorizeAndRebuild(autoShow: true);
      debugPrint('[SCAN_DBG ${DateTime.now().toIso8601String()}] colorization done, overlay placed cameraCenter=${_mapCtrl.camera.center.latitude.toStringAsFixed(6)},${_mapCtrl.camera.center.longitude.toStringAsFixed(6)}');
    } else {
      // No heatmap in this scan — clear old overlay now.
      final oldImages = Map<int, ui.Image>.from(_colorizedImages);
      setState(() { _colorizedImages = {}; _cachedHeatmapOverlays = []; });
      for (final img in oldImages.values) img.dispose();
    }
    _scanInFlight = false; // release GPS camera follow only after overlay is fully placed

    // Refresh nearby mine markers without clearing the scan result, heatmap, or token.
    _refreshNearbyMines(scanCenter);

    if (results.isEmpty) _snack('Nothing found here. Try a different spot.');
  }

  // Invalidate density cache tiles that contain the scan position, then reload.
  // Does NOT clear scan result, heatmap, prospect token, or last scan pos.
  void _refreshNearbyMines(LatLng scanCenter) {
    // Invalidate any cached density tile that contains the scan center.
    final toRemove = _densityCacheKeys
        .where((k) => _densityCacheKeyContains(k, scanCenter))
        .toList();
    for (final k in toRemove) {
      _densityCache.remove(k);
      _densityCacheKeys.remove(k);
    }
    // Re-run the marker load (density or close-zoom as appropriate).
    _loadMarkers();
  }

  // Check if a density cache key's bbox contains the given point.
  bool _densityCacheKeyContains(String key, LatLng pt) {
    final parts = key.split(',');
    if (parts.length != 5) return false;
    try {
      final lat1 = int.parse(parts[1]) * 0.5;
      final lat2 = int.parse(parts[2]) * 0.5;
      final lng1 = int.parse(parts[3]) * 0.5;
      final lng2 = int.parse(parts[4]) * 0.5;
      return pt.latitude  >= lat1 && pt.latitude  <= lat2
          && pt.longitude >= lng1 && pt.longitude <= lng2;
    } catch (_) { return false; }
  }

  Future<void> _buildMine(Map<String, dynamic> r,
      {LatLng? buildAt, LatLng? curPos}) async {
    if (_building) return;
    final token = _prospectToken;
    if (token == null) { _snack('Scan first before building', error: true); return; }
    setState(() { _building = true; _prospectToken = null; });
    final base   = buildAt ?? _lastScanPos ?? _mapCenter ?? _pos!;
    final target = buildAt ?? _snapBuildPos(base);
    final sid = context.read<PlayerProvider>().sid;
    final res = await ApiService.buildMine(
        sid, target.latitude, target.longitude,
        r['mine_item_id'] as int, r['quality'] as int,
        prospectToken: token,
        curLat: curPos?.latitude,
        curLng: curPos?.longitude);
    if (!mounted) return;
    setState(() { _building = false; });
    if (res == null || res['err'] != 0) {
      _snack(res?['msg'] ?? 'Build failed', error: true);
    } else {
      final diamondUsed = res['diamondUsed'] == true;
      _snack(diamondUsed ? 'Mine built remotely!' : 'Mine built!');
      setState(() {
        _lastScanPos = null;
        _markers = [
          ..._markers,
          {
            'lat': target.latitude, 'lng': target.longitude,
            'type': 'mine', 'isMine': true, 'cond': 100, 'wip': true,
            'itemID': r['mine_item_id'] as int,
            'resID': kMineResource[r['mine_item_id'] as int] ?? 0,
          }
        ];
        _computeClustersGrid();
      });
      context.read<PlayerProvider>().refresh();
      _loadMarkers();
    }
  }

  void _snack(String msg, {bool error = false}) =>
      AppNotify.show(context, msg, isError: error);

  void _onMapTap(LatLng tapped) {
    if (_showResourcePicker) {
      setState(() => _showResourcePicker = false);
      return;
    }
    final player = context.read<PlayerProvider>().player;
    if (player == null) return;
    // Collect own mines within 15m, then pick the single closest one.
    // Tie-break by mine ID for determinism at shared borders/vertices.
    final candidates = player.mines.where((mine) {
      return _distM(tapped, LatLng(mine.lat, mine.lng)) <= 15;
    }).toList();
    if (candidates.isEmpty) return;
    candidates.sort((a, b) {
      final da = _distM(tapped, LatLng(a.lat, a.lng));
      final db = _distM(tapped, LatLng(b.lat, b.lng));
      final cmp = da.compareTo(db);
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });
    final mine = candidates.first;
    final gpsPos = _pos;
    final inBossRange = gpsPos != null &&
        _distM(gpsPos, LatLng(mine.lat, mine.lng)) <= player.bossRangeM;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A2E),
      builder: (_) => _MapMineSheet(
        mine: mine,
        player: player,
        inBossRange: inBossRange,
        onDone: () {
          context.read<PlayerProvider>().refresh();
          _loadMarkers();
        },
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final player     = context.watch<PlayerProvider>().player;
    final lvl        = player?.level ?? 1;
    final center     = _pos ?? const LatLng(45.815, 15.982);

    const kDroneOverride = false;
    final drResearchLevel = (player?.factories
        .firstWhere((f) => (f['itemID'] as int? ?? 0) == 119,
            orElse: () => <String, dynamic>{'lvl': 0})['lvl'] as int? ?? 0);
    final kDroneRange = drResearchLevel > 0
        ? kDroneScanRanges[(drResearchLevel - 1).clamp(0, kDroneScanRanges.length - 1)]
        : 0;
    final hasDrone = kDroneOverride || (player?.lager['117'] ?? 0.0) >= 1;
    final droneRange = hasDrone ? kDroneRange : 0;
    final distToTarget = (_pos != null && _mapCenter != null)
        ? _distM(_pos!, _mapCenter!)
        : double.infinity;
    final inLocalRange = distToTarget <= 100;
    final inDroneRange = droneRange > 0 && distToTarget <= droneRange;

    // All mines sorted: highest unlock level at top, tie-break by mine_id descending (rarer first).
    final allMines = kMineMinLevel.keys.toList()
      ..sort((a, b) {
        final lvlCmp = (kMineMinLevel[b] ?? 0).compareTo(kMineMinLevel[a] ?? 0);
        return lvlCmp != 0 ? lvlCmp : b.compareTo(a);
      });

    // TC level + scan radius
    final tcLevel = player?.tcLevel ?? 0;
    final scanRadius = kTcScanRadius[tcLevel.clamp(0, kTcScanRadius.length - 1)].toDouble();
    final mineCount = player?.mines.length ?? 0;
    final rawCost = 10 * math.pow(2.4, tcLevel) * (1 + mineCount / 1000.0);
    final scanCost = math.max(5000, (rawCost / 5000).round() * 5000);

    // Selected resource's scan result (for mine build icon)
    final selectedResult = _lastResults.cast<Map<String, dynamic>?>()
        .firstWhere((r) => r?['mine_item_id'] == _selectedMineType, orElse: () => null);

    final canBuild = inLocalRange || inDroneRange;
    final hasActiveSelection = _lastScanPos != null;
    final browseBase = _mapCenter ?? _pos ?? const LatLng(45.815, 15.982);
    final browseSnapPos = canBuild ? _snapBuildPos(browseBase) : null;
    final buildSnapPos  = hasActiveSelection ? _snapBuildPos(_lastScanPos!) : null;

    return Stack(children: [

      // ── Flutter Map ────────────────────────────────────────────────────────
      FlutterMap(
        mapController: _mapCtrl,
        options: MapOptions(
          initialCenter: center,
          initialZoom: 15,
          minZoom: 3,
          maxZoom: 19,
          backgroundColor: const Color(0xFF343434),
          // contain (not containCenter) constrains the VIEWPORT edges — the user
          // can never scroll past the tile coverage area and see the blank background.
          cameraConstraint: CameraConstraint.contain(
            bounds: LatLngBounds(
              const LatLng(-85, -180),
              const LatLng(85,   180),
            ),
          ),
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate & ~InteractiveFlag.doubleTapZoom,
          ),
          onPositionChanged: (camera, hasGesture) {
            double lat = camera.center.latitude;
            double lng = camera.center.longitude;
            while (lng >  180) lng -= 360;
            while (lng < -180) lng += 360;
            _mapCenter = LatLng(lat, lng);
            if (_pos != null) {
              _crosshairDist.value = _distM(_pos!, _mapCenter!);
            }
            final newZoom = camera.zoom;
            // Compare against _builtZoom (zoom at last build), not _mapZoom (last frame).
            // With 0.04/frame pinch zoom, comparing against _mapZoom means the threshold
            // is never reached; comparing against _builtZoom accumulates drift correctly.
            final zoomChanged = (newZoom - _builtZoom).abs() > 0.02;
            _mapZoom = newZoom;
            // Rebuild when zoom drifts (mine hex sizes depend on zoom), when
            // _following transitions false, or when prospect token is cleared.
            // Pure constant-zoom pan skips setState entirely.
            bool needsBuild = zoomChanged;
            if (hasGesture && _following) {
              _following = false;
              needsBuild = true;
            }
            if (hasGesture && _prospectToken != null && _lastScanPos != null &&
                _distM(_mapCenter!, _lastScanPos!) > 30) {
              _prospectToken = null;
              needsBuild = true;
            }
            if (needsBuild && mounted) setState(() { _builtZoom = newZoom; });
            // Reload markers 600 ms after the user stops panning or zooming.
            if (hasGesture || zoomChanged) {
              _mapMoveDebounce?.cancel();
              _mapMoveDebounce = Timer(
                  const Duration(milliseconds: 600), _loadMarkers);
            }
          },
          onTap: (tapPos, latLng) => _onMapTap(latLng),
        ),
        children: [

          // Dark greyscale OSM tiles
          ColorFiltered(
            colorFilter: const ColorFilter.matrix([
              -0.2126, -0.7152, -0.0722, 0, 255,
              -0.2126, -0.7152, -0.0722, 0, 255,
              -0.2126, -0.7152, -0.0722, 0, 255,
                    0,       0,       0, 1,   0,
            ]),
            child: TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: Branding.appId,
              maxNativeZoom: 19,
            ),
          ),

          // Scan range circles around GPS (TC radius + local 200m + drone)
          if (_pos != null) ...[
            CircleLayer(circles: [
              if (droneRange > 0)
                CircleMarker(
                  point: _pos!,
                  radius: droneRange.toDouble(),
                  useRadiusInMeter: true,
                  color: kDroneRingColor.withValues(alpha: kDroneRingOpacity * 0.12),
                  borderColor: kDroneRingColor,
                  borderStrokeWidth: 1.5,
                ),
              if (canBuild)
                CircleMarker(
                  point: _mapCenter ?? _pos!,
                  radius: scanRadius,
                  useRadiusInMeter: true,
                  color: kScanRingColor.withValues(alpha: kScanRingOpacity * 0.12),
                  borderColor: kScanRingColor,
                  borderStrokeWidth: 1.5,
                ),
              CircleMarker(
                point: _pos!,
                radius: 100,
                useRadiusInMeter: true,
                color: kLocalRingColor.withValues(alpha: kLocalRingOpacity * 0.12),
                borderColor: kLocalRingColor,
                borderStrokeWidth: 1.5,
              ),
            ]),
            // Ring labels — anchored to circle top, only shown when circle ≥ 80px diameter
            (() {
              final refLat = _pos!.latitude * math.pi / 180;
              final ppm = (256 * math.pow(2, _mapZoom)) /
                  (40075017.0 * math.cos(refLat).abs().clamp(0.001, 1.0));
              TextStyle s(Color c) => TextStyle(color: c, fontSize: 9,
                  shadows: const [Shadow(color: Colors.black, blurRadius: 2)]);
              final scanCenter = _mapCenter ?? _pos!;
              Marker lblAt(String text, LatLng center, double radiusM, Color c) => Marker(
                point: LatLng(center.latitude + radiusM / 111320.0, center.longitude),
                width: 96, height: 14,
                alignment: Alignment.topCenter,
                child: Center(child: Text(text, style: s(c))),
              );
              return MarkerLayer(markers: [
                if (!kShowRingLabels) ...[],
                if (kShowRingLabels && droneRange > 0 && droneRange * ppm > 40)
                  lblAt('Drone range', _pos!, droneRange.toDouble(), kDroneRingColor),
                if (kShowRingLabels && canBuild && scanRadius * ppm > 40)
                  lblAt('TC Scan Range', scanCenter, scanRadius, kScanRingColor),
                if (kShowRingLabels && 100 * ppm > 40)
                  lblAt('Local Range', _pos!, 100.0, kLocalRingColor),
              ]);
            })(),
          ],

          // Accumulated scan heatmap — stable cached list, rebuilt only when scan data changes.
          if (_cachedHeatmapOverlays.isNotEmpty)
            OverlayImageLayer(overlayImages: _cachedHeatmapOverlays),

          // Mine markers — cloud blobs at low zoom, geo-scaled hex images at high zoom.
          if (_showMines) ...[
            if (_mapZoom < 14.5)
              Builder(builder: (ctx) {
                final cam = MapCamera.of(ctx);
                return CustomPaint(
                  painter: _MineCloudPainter(
                    clusters: _mineClusters,
                    center: cam.center,
                    zoom: cam.zoom,
                  ),
                  size: Size.infinite,
                );
              })
            else (() {
              // Geo-scaled: mine diameter = 30m real-world, scale with zoom/latitude
              final refLat = (_pos?.latitude ?? 45.0) * math.pi / 180;
              final ppm = (256 * math.pow(2, _mapZoom)) /
                  (40075017.0 * math.cos(refLat).abs().clamp(0.001, 1.0));
              final totalPx = (2 * 15.0 * ppm).clamp(4.0, 200.0);
              // Cull to visible bounds + small buffer to avoid rendering off-screen mines
              LatLngBounds? vBounds;
              try { vBounds = _mapCtrl.camera.visibleBounds; } catch (_) {}
              final visibleMines = vBounds == null
                  ? _markers.where((m) => m['type'] != 'hq').toList()
                  : _markers.where((m) {
                      if (m['type'] == 'hq') return false;
                      final lat = (m['lat'] as num).toDouble();
                      final lng = (m['lng'] as num).toDouble();
                      return lat >= vBounds!.south - 0.005 && lat <= vBounds.north + 0.005 &&
                             lng >= vBounds.west  - 0.01  && lng <= vBounds.east  + 0.01;
                    }).toList();
              return MarkerLayer(
                markers: visibleMines.map((m) {
                  final lat    = (m['lat'] as num).toDouble();
                  final lng    = (m['lng'] as num).toDouble();
                  final cond   = (m['cond'] as num? ?? 100).toInt();
                  final itemID = (m['itemID'] as num? ?? 0).toInt();
                  final resID  = (m['resID'] as num? ?? 0).toInt();
                  final isOwn  = m['isMine'] == true;
                  final isWip  = m['wip'] == true;
                  final imgPath = isWip ? null : resImagePath(resID);
                  Color ringColor;
                  if (isWip)           ringColor = Colors.greenAccent;
                  else if (cond < 50)  ringColor = const Color(0xFF8B5A2B);
                  else if (isOwn)      ringColor = Colors.greenAccent;
                  else                 ringColor = const Color(0xFF666666);
                  // WIP markers are fixed-size UI indicators; regular mines are geo-scaled.
                  final markerPx = totalPx;
                  final markerH  = markerPx * 0.866;
                  const barH    = 5.0;
                  final showBar = !isWip && cond <= 90;
                  return Marker(
                    point: LatLng(lat, lng),
                    width: markerPx,
                    height: markerH + (showBar ? barH : 0),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: markerPx, height: markerH,
                          child: CustomPaint(
                            painter: _HexFramePainter(ringColor: ringColor),
                            child: Center(
                              child: SizedBox(
                                width: markerPx * 0.76, height: markerH * 0.76,
                                child: ClipPath(
                                  clipper: const _HexClipper(),
                                  child: Transform.scale(
                                    scale: 1.1,
                                    child: imgPath != null
                                        ? Image.asset(imgPath, fit: BoxFit.cover)
                                        : Container(
                                            color: const Color(0xFF101418),
                                            child: Center(child: Icon(
                                              isWip ? Icons.construction : Icons.terrain,
                                              color: isWip ? Colors.greenAccent
                                                  : (_kMineColor[itemID] ?? Colors.grey),
                                              size: (markerPx * 0.35).clamp(6.0, 18.0),
                                            )),
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (showBar)
                          SizedBox(width: markerPx, height: barH,
                            child: ClipRRect(borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: cond / 100.0,
                                backgroundColor: Colors.black54,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  cond < 50 ? Colors.redAccent
                                      : cond < 80 ? Colors.amber
                                      : Colors.greenAccent,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                }).toList(),
              );
            })(),
          ],

          // Ghost hex — uses live MapCamera so position and size stay correct during pan/zoom.
          if (_showMines)
            Builder(builder: (ghCtx) {
              final cam = MapCamera.of(ghCtx);
              if (cam.zoom < 14.5) return const SizedBox.shrink();
              // Recompute browse position from current camera centre (not stale _mapCenter).
              final camCenter = cam.center;
              final distCam = _pos != null ? _distM(_pos!, camCenter) : double.infinity;
              final canBuildLive = distCam <= 100 || (droneRange > 0 && distCam <= droneRange);
              final browseSnapLive = canBuildLive ? _snapBuildPos(camCenter) : null;
              if (browseSnapLive == null && buildSnapPos == null) return const SizedBox.shrink();
              final refLat = camCenter.latitude * math.pi / 180;
              final ppm = (256 * math.pow(2, cam.zoom)) /
                  (40075017.0 * math.cos(refLat).abs().clamp(0.001, 1.0));
              final ghostPx = (2 * 15.0 * ppm).clamp(4.0, 200.0);
              final markers = <Marker>[];
              if (browseSnapLive != null) {
                markers.add(Marker(
                  point: browseSnapLive,
                  width: ghostPx,
                  height: ghostPx * 0.866,
                  alignment: Alignment.center,
                  child: CustomPaint(
                    painter: _HexOutlinePainter(
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ));
              }
              if (buildSnapPos != null) {
                final confirmedAbsent = selectedResult == null;
                markers.add(Marker(
                  point: buildSnapPos,
                  width: ghostPx,
                  height: ghostPx * 0.866,
                  alignment: Alignment.center,
                  child: confirmedAbsent
                      ? CustomPaint(
                          painter: const _HexAbsentPainter(),
                          foregroundPainter: const _HexAbsentXPainter(),
                          child: Center(
                            child: Icon(Icons.construction,
                              color: Colors.grey.withValues(alpha: 0.55),
                              size: (ghostPx * 0.32).clamp(5.0, 16.0)),
                          ),
                        )
                      : CustomPaint(
                          painter: _HexOutlinePainter(
                            color: Colors.greenAccent.withValues(alpha: 0.9),
                          ),
                          child: Center(child: Icon(Icons.construction,
                                color: Colors.greenAccent,
                                size: (ghostPx * 0.38).clamp(6.0, 20.0))),
                        ),
                ));
              }
              return MarkerLayer(markers: markers);
            }),
          // Own HQ boost radius — rendered above mines so it's visible
          if (player?.hq != null && _showHQs) (() {
            final hq = player!.hq!;
            final hqRangeM = 100.0 + hq.level * 15.0;
            return CircleLayer(circles: [
              CircleMarker(
                point: LatLng(hq.lat, hq.lng),
                radius: hqRangeM,
                useRadiusInMeter: true,
                color: Colors.white.withValues(alpha: 0.04),
                borderColor: Colors.white.withValues(alpha: 0.45),
                borderStrokeWidth: 1.5,
              ),
            ]);
          })(),

          // HQ markers — loaded independently at any zoom via _hqMarkers
          MarkerLayer(
            markers: [
              ..._hqMarkers
                  .where((m) {
                    if (!_showHQs) return false;
                    if (m['isMine'] == true) return true; // own HQ always visible
                    final lvl    = (m['lvl'] as num? ?? 1).toInt().clamp(1, 10);
                    final subLvl = (m['sub_lvl'] as num? ?? 0).toInt();
                    return _mapZoom >= _hqMinZoom(lvl, subLvl);
                  })
                  .map(_buildMapMarker),
              // GPS position dot
              if (_pos != null)
                Marker(
                  point: _pos!,
                  width: 44, height: 44,
                  child: CustomPaint(painter: _PosCrosshairPainter(headingDeg: _heading)),
                ),
            ],
          ),
        ],
      ),

      // ── Thin red crosshair ─────────────────────────────────────────────────
      const Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: SizedBox(
              width: 20, height: 20,
              child: CustomPaint(painter: _CrosshairPainter()),
            ),
          ),
        ),
      ),

      // ── Top control bar ─────────────────────────────────────────────────────
      Positioned(
        top: MediaQuery.of(context).padding.top,
        left: 0, right: 0,
        child: Container(
          height: 42,
          color: Theme.of(context).colorScheme.surface.withValues(alpha: kMapPanelOpacity.clamp(0.0, 1.0)),
          child: Row(
            children: [
              const SizedBox(width: 4),
              // Scan/heatmap visibility toggle — no-op when no scan available
              _mapBtnW(
                CustomPaint(
                  painter: _RadarIconPainter(
                    color: _showClouds ? Colors.white : Colors.white70),
                ),
                () {
                  if (!_showClouds && _heatmapScans.isEmpty) return;
                  setState(() { _showClouds = !_showClouds; _rebuildHeatmapOverlays(); });
                },
                active: _showClouds, tip: 'Heatmap',
              ),
              const SizedBox(width: 4),
              _mapBtn(Icons.apartment, () async {
                setState(() => _showHQs = !_showHQs);
                final p = await SharedPreferences.getInstance();
                await p.setBool('map_show_hqs', _showHQs);
              }, active: _showHQs, tip: 'HQs'),
              const SizedBox(width: 4),
              // Mine visibility toggle — hex icon
              _mapBtnW(
                CustomPaint(
                  painter: _HexIconPainter(
                    color: _showMines ? Colors.white : Colors.white70),
                ),
                () async {
                  setState(() => _showMines = !_showMines);
                  final p = await SharedPreferences.getInstance();
                  await p.setBool('map_show_mines', _showMines);
                },
                active: _showMines, tip: 'Mines',
              ),
              const Spacer(),
              // Navigation
              _mapBtn(Icons.my_location, () {
                setState(() => _following = true);
                if (_pos != null) _mapCtrl.move(_pos!, 15);
              }, active: _following, tip: 'My location'),
              const SizedBox(width: 4),
              _mapBtn(Icons.refresh, () {
                final old = Map<int, ui.Image>.from(_colorizedImages);
                setState(() {
                  _heatmapScans.clear();
                  _colorizedImages = {};
                  _cachedHeatmapOverlays = [];
                  _lastResults = [];
                  _lastScanPos = null;
                  _prospectToken = null;
                  _showClouds = false;
                });
                for (final img in old.values) img.dispose();
                _loadMarkers();
              }, tip: 'Refresh & clear scan'),
              const SizedBox(width: 8),
              // Zoom
              _mapBtn(Icons.add, () {
                final z = (_mapCtrl.camera.zoom + 1).clamp(3.0, 19.0);
                _mapCtrl.move(_mapCtrl.camera.center, z);
              }, tip: 'Zoom in'),
              const SizedBox(width: 4),
              _mapBtn(Icons.remove, () {
                final z = (_mapCtrl.camera.zoom - 1).clamp(3.0, 19.0);
                _mapCtrl.move(_mapCtrl.camera.center, z);
              }, tip: 'Zoom out'),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),

      // ── Right resource selector panel — flush against bottom bar ─────────────
      if (_showResourcePicker)
        Positioned(
          bottom: MediaQuery.of(context).padding.bottom + 78,
          right: 0,
          child: Container(
            width: 140,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.55,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface.withValues(alpha: kMapPanelOpacity.clamp(0.0, 1.0)),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              border: Border.all(color: Colors.white12),
            ),
            child: ListView.builder(
              controller: _resourceScrollCtrl,
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: allMines.length,
              itemBuilder: (_, i) {
                final mineId   = allMines[i];
                final resId    = kMineResource[mineId] ?? 0;
                final imgPath  = resImagePath(resId);
                final name     = kMineNames[mineId] ?? 'Mine';
                final selected = _selectedMineType == mineId;
                final minLevel = kMineMinLevel[mineId] ?? 1;
                final isLocked = minLevel > lvl;
                final q = _lastResults.cast<Map<String, dynamic>?>()
                    .firstWhere((r) => r?['mine_item_id'] == mineId, orElse: () => null)
                    ?['quality'] as int?;
                return GestureDetector(
                  onTap: isLocked ? null : () {
                    setState(() {
                      _selectedMineType = mineId;
                      _prospectToken = null;
                      _rebuildHeatmapOverlays();
                      _showResourcePicker = false;
                    });
                    _saveLastMineType(mineId);
                  },
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    color: selected ? Colors.teal.withValues(alpha: 0.20) : Colors.transparent,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _MarqueeText(
                                text: name,
                                running: _showResourcePicker,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isLocked
                                      ? Colors.white38
                                      : selected ? Colors.tealAccent : Colors.white70,
                                ),
                              ),
                              if (isLocked)
                                Text('Unlocks at level $minLevel',
                                    style: const TextStyle(fontSize: 9, color: Colors.orange))
                              else if (q != null)
                                Text('$q%', style: TextStyle(
                                  fontSize: 10,
                                  color: q > 70 ? Colors.greenAccent
                                       : q > 40 ? Colors.amber : Colors.orange,
                                )),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Stack(
                          children: [
                            Container(
                              width: 30, height: 30,
                              decoration: BoxDecoration(
                                color: (_kMineColor[mineId] ?? Colors.grey)
                                    .withValues(alpha: isLocked ? 0.08 : 0.15),
                                borderRadius: BorderRadius.circular(4),
                                border: selected
                                    ? Border.all(color: Colors.tealAccent.withValues(alpha: 0.5))
                                    : null,
                              ),
                              child: Opacity(
                                opacity: isLocked ? 0.35 : 1.0,
                                child: imgPath != null
                                    ? Padding(
                                        padding: const EdgeInsets.all(3),
                                        child: Image.asset(imgPath, fit: BoxFit.contain))
                                    : Icon(Icons.terrain,
                                        color: _kMineColor[mineId] ?? Colors.grey, size: 16),
                              ),
                            ),
                            if (isLocked)
                              Positioned.fill(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.52),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Center(
                                    child: Icon(Icons.lock, size: 14, color: Colors.white60),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),

      // ── Distance display ─────────────────────────────────────────────────────
      if (_pos != null && _mapCenter != null)
        Positioned(
          bottom: MediaQuery.of(context).padding.bottom + 82,
          left: 8,
          child: IgnorePointer(
            child: ValueListenableBuilder<double>(
              valueListenable: _crosshairDist,
              builder: (ctx, dist, _) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surface.withValues(alpha: kMapPanelOpacity.clamp(0.0, 1.0)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _fmtDist(dist),
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            ),
          ),
        ),

      // ── Bottom panel (scan + build) ─────────────────────────────────────────
      Positioned(
        bottom: 0, left: 0, right: 0,
        child: Container(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: kMapPanelOpacity.clamp(0.0, 1.0)),
          padding: EdgeInsets.fromLTRB(6, 6, 6,
              MediaQuery.of(context).padding.bottom + 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [

              // ── Left: coords + mine build ─────────────────────────────────
              SizedBox(
                width: 52,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Coordinates copy button — always copies the crosshair position
                    GestureDetector(
                      onTap: () {
                        final pos = _mapCenter ?? _pos;
                        if (pos == null) return;
                        final coords =
                            '${pos.latitude.toStringAsFixed(6)},${pos.longitude.toStringAsFixed(6)}';
                        Clipboard.setData(ClipboardData(text: coords));
                        _snack('Copied');
                      },
                      child: Container(
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.teal.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.5)),
                        ),
                        child: const Center(
                          child: Icon(Icons.location_pin, size: 14, color: Colors.tealAccent),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Mine build icon
                    GestureDetector(
                      onTap: (selectedResult != null && _prospectToken != null)
                          ? () => _showBuildDialog(selectedResult!)
                          : null,
                      child: Container(
                        height: 36, width: 52,
                        decoration: BoxDecoration(
                          color: (selectedResult != null && _prospectToken != null)
                              ? Colors.amber.withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          border: (selectedResult != null && _prospectToken != null)
                              ? Border.all(color: Colors.amber.withValues(alpha: 0.6))
                              : Border.all(color: Colors.white12),
                        ),
                        child: Center(
                          child: Icon(Icons.construction, size: 22,
                              color: (selectedResult != null && _prospectToken != null)
                                  ? Colors.amber : Colors.white24),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // ── Center: scan button ───────────────────────────────────────
              Expanded(
                child: (() {
                  final disabled = _scanning || _pos == null ||
                      (!inLocalRange && !inDroneRange);
                  final bgColor = inLocalRange
                      ? Colors.teal.shade700
                      : inDroneRange
                          ? Colors.teal.shade900
                          : Colors.grey.shade800;
                  final droneCount = (player?.lager['117'] ?? 0.0).toInt();
                  final costLine = (!inLocalRange && !inDroneRange)
                      ? null
                      : (inDroneRange && !inLocalRange)
                          ? 'Drone count: $droneCount'
                          : 'ꞓ${fmtNum(scanCost)}';
                  return SizedBox(
                    height: 66,
                    child: Material(
                      color: disabled
                          ? Colors.grey.shade800.withValues(alpha: 0.5)
                          : bgColor,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        onTap: disabled
                            ? null
                            : () => _scan(drone: !inLocalRange && inDroneRange),
                        borderRadius: BorderRadius.circular(8),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              _scanning
                                  ? const SizedBox(width: 14, height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white))
                                  : (inDroneRange && !inLocalRange)
                                      ? Icon(Icons.flight,
                                          size: 16,
                                          color: disabled ? Colors.white38 : Colors.white)
                                      : SizedBox(width: 16, height: 16,
                                          child: CustomPaint(
                                            painter: _RadarIconPainter(
                                              color: disabled ? Colors.white38 : Colors.white),
                                          )),
                              const SizedBox(width: 6),
                              Text(
                                inLocalRange ? 'Scan for resource'
                                    : inDroneRange ? 'Scan with Drone'
                                    : 'Out of range',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: disabled ? Colors.white38 : Colors.white),
                              ),
                            ]),
                            if (costLine != null) ...[
                              const SizedBox(height: 2),
                              Text(costLine, style: TextStyle(
                                  fontSize: 10,
                                  color: disabled ? Colors.white24 : Colors.white70)),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                })(),
              ),

              const SizedBox(width: 8),

              // ── Right: resource selector toggle ───────────────────────────
              SizedBox(
                width: 52,
                height: 66,
                child: GestureDetector(
                  onTap: () {
                    final wasOpen = _showResourcePicker;
                    setState(() => _showResourcePicker = !wasOpen);
                    if (!wasOpen) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _resourceScrollCtrl.hasClients) {
                          _resourceScrollCtrl.jumpTo(_resourceScrollCtrl.position.maxScrollExtent);
                        }
                      });
                    }
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: _showResourcePicker
                          ? Colors.teal.withValues(alpha: 0.25)
                          : Colors.white.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: _showResourcePicker
                            ? Colors.tealAccent.withValues(alpha: 0.6)
                            : Colors.white12,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        (() {
                          final imgP = resImagePath(kMineResource[_selectedMineType] ?? 0);
                          return imgP != null
                              ? Image.asset(imgP, width: 24, height: 24, fit: BoxFit.contain)
                              : Icon(Icons.terrain,
                                  size: 22,
                                  color: _kMineColor[_selectedMineType] ?? Colors.white70);
                        })(),
                        const SizedBox(height: 2),
                        Icon(
                          _showResourcePicker ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                          size: 12, color: Colors.white54,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),

      // ── GPS mock/spoof blocker ──────────────────────────────────────────────
      if (_mockDetected)
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.gps_off, color: Colors.redAccent, size: 64),
                    SizedBox(height: 16),
                    Text('Cheating Not Allowed',
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    SizedBox(height: 12),
                    Text(
                      'A GPS emulator or location spoofer has been detected.\n\n'
                      'If you are not cheating, please clear the app cache or reinstall.',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ]);
  }

  // ── Build dialog ───────────────────────────────────────────────────────────

  void _showBuildDialog(Map<String, dynamic> r) {
    final mineId   = r['mine_item_id'] as int;
    final quality  = r['quality'] as int;
    final cost     = r['build_cost'] as int;
    final minLevel = r['min_level'] as int? ?? kMineMinLevel[mineId] ?? 1;
    final name     = kMineNames[mineId] ?? 'Mine';
    final player   = context.read<PlayerProvider>().player;
    final playerLv = player?.level ?? 1;
    final hasToken = _prospectToken != null;
    final meetsLevel = playerLv >= minLevel;
    final qColor   = quality > 70 ? Colors.greenAccent
                   : quality > 40 ? Colors.amber
                   : Colors.orange;

    final buildBase = (_lastScanPos ?? _mapCenter ?? _pos!);
    final target    = _snapBuildPos(buildBase);

    // Drone Research level (item_id = 119) — must be computed before range check.
    final drLevel = (player?.factories
        .firstWhere((f) => (f['itemID'] as int? ?? 0) == 119,
            orElse: () => <String, dynamic>{'lvl': 0})['lvl'] as int? ?? 0);
    // 100m matches server LOCAL_CONSTRUCTION_RANGE_M; drone range is DR-level-based.
    const kLocalM = 100.0;
    final kDroneM = drLevel > 0
        ? kDroneScanRanges[(drLevel - 1).clamp(0, kDroneScanRanges.length - 1)].toDouble()
        : 0.0;
    // Use _pos at dialog-open time for display only.
    final distToTarget = _pos != null ? _distM(_pos!, target) : double.infinity;
    final inLocalRange = distToTarget <= kLocalM;
    final inDroneRange = kDroneM > 0 && distToTarget <= kDroneM;

    final hasDrone   = (player?.lager['117'] ?? 0.0) >= 1;
    final hasDiamond = (player?.lager['42']  ?? 0.0) >= 1;

    // Local build: in range + level + token. Remote: drone range + DR10 + items + level + token.
    // canBuild is for dialog-open-time display only — the Build button revalidates GPS at press.
    final canLocalBuild  = hasToken && meetsLevel && inLocalRange;
    final canRemoteBuild = hasToken && meetsLevel && inDroneRange && drLevel >= 10 && hasDrone && hasDiamond;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(name),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Quality: ', style: TextStyle(color: Colors.white54)),
            Text(fmtQual(quality), style: TextStyle(
                color: qColor, fontWeight: FontWeight.bold, fontSize: 18)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Text('Build cost: ', style: TextStyle(color: Colors.white54)),
            Text('ꞓ${fmtNum(cost)}', style: const TextStyle(color: Colors.amber)),
          ]),
          const SizedBox(height: 8),
          if (!inDroneRange) ...[
            Text(
              distToTarget < double.infinity
                  ? 'Mine hex is ${distToTarget.round()}m away — local limit is 100m.'
                  : 'Out of range — move closer to build.',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ]
          else if (!inLocalRange) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.cyan.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Remote build costs:',
                    style: TextStyle(color: Colors.cyanAccent, fontSize: 11,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Row(children: [
                  (() {
                    final p = resImagePath(117);
                    return p != null
                        ? Image.asset(p, width: 16, height: 16, fit: BoxFit.contain)
                        : Icon(Icons.flight, size: 13,
                            color: hasDrone ? Colors.cyanAccent : Colors.redAccent);
                  })(),
                  const SizedBox(width: 4),
                  Text('1× Scan Drone${hasDrone ? "" : " (missing)"}',
                      style: TextStyle(
                          color: hasDrone ? Colors.white70 : Colors.redAccent,
                          fontSize: 11)),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  (() {
                    final p = resImagePath(42);
                    return p != null
                        ? Image.asset(p, width: 16, height: 16, fit: BoxFit.contain)
                        : Icon(Icons.diamond, size: 13,
                            color: hasDiamond ? Colors.cyanAccent : Colors.redAccent);
                  })(),
                  const SizedBox(width: 4),
                  Text('1× Giant Diamond${hasDiamond ? "" : " (missing)"}',
                      style: TextStyle(
                          color: hasDiamond ? Colors.white70 : Colors.redAccent,
                          fontSize: 11)),
                ]),
                if (drLevel < 10) ...[
                  const SizedBox(height: 4),
                  Text('Requires Drone Research level 10 (yours: $drLevel)',
                      style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
                ],
              ]),
            ),
          ],
          if (!hasToken) ...[
            const SizedBox(height: 8),
            const Text('Perform a new scan before building',
                style: TextStyle(color: Colors.redAccent, fontSize: 12)),
          ],
          if (hasToken && !meetsLevel) ...[
            const SizedBox(height: 8),
            Text('Requires player level $minLevel',
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: (!inLocalRange && inDroneRange && canRemoteBuild)
                ? FilledButton.styleFrom(backgroundColor: Colors.cyan.shade700)
                : null,
            onPressed: (canLocalBuild || canRemoteBuild)
                ? () {
                    Navigator.pop(ctx);
                    // Re-read GPS at the moment Build is pressed (not when dialog opened).
                    final freshPos = _pos;
                    if (freshPos == null) {
                      _snack('GPS unavailable — cannot build without a location fix', error: true);
                      return;
                    }
                    final freshDist = _distM(freshPos, target);
                    final freshLocal = freshDist <= kLocalM;
                    final freshDrone = kDroneM > 0 && freshDist <= kDroneM;
                    // Mode is locked to what was chosen when dialog opened — no silent conversion.
                    if (inLocalRange && !freshLocal) {
                      _snack('Building failed: Construction zone is out of range.', error: true);
                      return;
                    }
                    if (!inLocalRange && inDroneRange && !freshDrone) {
                      _snack('Building failed: Construction zone is out of range.', error: true);
                      return;
                    }
                    if (freshLocal) {
                      _buildMine(r, buildAt: target, curPos: freshPos);
                    } else {
                      _showRemoteBuildConfirm(r, target, freshPos, cost, hasDrone, hasDiamond);
                    }
                  }
                : null,
            child: const Text('Build'),
          ),
        ],
      ),
    );
  }

  void _showRemoteBuildConfirm(Map<String, dynamic> r, LatLng target, LatLng? curPos,
      int cost, bool hasDrone, bool hasDiamond) {
    final name = kMineNames[r['mine_item_id'] as int] ?? 'Mine';
    final droneImg   = resImagePath(117);
    final diamondImg = resImagePath(42);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Remote Build'),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.monetization_on_outlined, size: 14, color: Colors.amber),
            const SizedBox(width: 4),
            Text('ꞓ${fmtNum(cost)}',
                style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.cyan.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.3)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Also consumes:',
                  style: TextStyle(color: Colors.cyanAccent, fontSize: 11,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(children: [
                if (droneImg != null)
                  Image.asset(droneImg, width: 28, height: 28, fit: BoxFit.contain)
                else
                  const Icon(Icons.flight, size: 28, color: Colors.cyanAccent),
                const SizedBox(width: 10),
                Expanded(child: Text('1× Scan Drone',
                    style: TextStyle(
                        color: hasDrone ? Colors.white : Colors.redAccent,
                        fontWeight: FontWeight.bold))),
                if (!hasDrone)
                  const Text('missing', style: TextStyle(color: Colors.redAccent, fontSize: 11)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                if (diamondImg != null)
                  Image.asset(diamondImg, width: 28, height: 28, fit: BoxFit.contain)
                else
                  const Icon(Icons.diamond, size: 28, color: Colors.cyanAccent),
                const SizedBox(width: 10),
                Expanded(child: Text('1× Giant Diamond',
                    style: TextStyle(
                        color: hasDiamond ? Colors.white : Colors.redAccent,
                        fontWeight: FontWeight.bold))),
                if (!hasDiamond)
                  const Text('missing', style: TextStyle(color: Colors.redAccent, fontSize: 11)),
              ]),
            ]),
          ),
          const SizedBox(height: 8),
          const Text('This cannot be undone.',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.cyan.shade700),
            onPressed: (hasDrone && hasDiamond)
                ? () {
                    Navigator.pop(ctx);
                    // Re-read GPS at Confirm press; server validates range server-side.
                    final freshPos = _pos;
                    if (freshPos == null) {
                      _snack('GPS unavailable — cannot build without a location fix', error: true);
                      return;
                    }
                    _buildMine(r, buildAt: target, curPos: freshPos);
                  }
                : null,
            child: const Text('Confirm Build'),
          ),
        ],
      ),
    );
  }

  // ── HQ zoom thresholds — centralised table; own HQ always visible ──────────
  // Levels 1–10: lower minZoom = visible when more zoomed out.
  static const Map<int, double> _kHqMinZoom = {
    1:  16.0, // close zoom only
    2:  15.5,
    3:  15.0,
    4:  14.5,
    5:  14.0,
    6:  13.5,
    7:  12.5,
    8:  11.5,
    9:  10.5,
    10:  9.0, // visible well zoomed out
  };
  // Future 10_N sub-level variants: progressively more global visibility.
  static const Map<int, double> _kHqSubLvlMinZoom = {
    2: 7.0,
    3: 6.0,
    4: 5.0,
    5: 4.0,
    6: 3.0, // world view
  };

  static double _hqMinZoom(int level, [int subLvl = 0]) {
    if (subLvl > 0) return _kHqSubLvlMinZoom[subLvl] ?? 7.0;
    return _kHqMinZoom[level.clamp(1, 10)] ?? 16.0;
  }

  // ── Marker builder ─────────────────────────────────────────────────────────

  Marker _buildMapMarker(dynamic m) {
    final lat   = (m['lat'] as num).toDouble();
    final lng   = (m['lng'] as num).toDouble();
    final isMine = m['isMine'] == true;

    if (m['type'] == 'hq') {
      final lvl    = (m['lvl'] as num? ?? 1).toInt().clamp(1, 10);
      final subLvl = (m['sub_lvl'] as num? ?? 0).toInt();
      final owner  = m['ownerName'] as String? ?? '';
      // Sub-level variants use hq_thumb_10_2.png etc; base levels use hq_thumb_N.png.
      final imgName = subLvl > 0 ? 'hq_thumb_${lvl}_$subLvl' : 'hq_thumb_$lvl';

      if (isMine) {
        return Marker(
          point: LatLng(lat, lng), width: 48, height: 48,
          child: Image.asset(
            'assets/images/$imgName.png',
            width: 48, height: 48, fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.apartment, color: Colors.amber, size: 36),
          ),
        );
      } else {
        return Marker(
          point: LatLng(lat, lng), width: 80, height: 68,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              constraints: const BoxConstraints(maxWidth: 80),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(owner,
                  style: const TextStyle(color: Colors.white, fontSize: 9),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  textAlign: TextAlign.center),
            ),
            const SizedBox(height: 2),
            Opacity(
              opacity: 0.65,
              child: Image.asset(
                'assets/images/$imgName.png',
                width: 44, height: 44, fit: BoxFit.contain,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.apartment, color: Colors.grey, size: 36),
              ),
            ),
          ]),
        );
      }
    }

    // Non-HQ markers are now drawn as CircleLayer — should not reach here
    return Marker(point: LatLng(lat, lng), width: 0, height: 0, child: const SizedBox.shrink());
  }

  // ── Widgets ────────────────────────────────────────────────────────────────

  Widget _mapBtn(IconData icon, VoidCallback onTap, {bool active = false, String? tip}) {
    final w = Material(
      color: active ? Colors.teal.shade700 : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () {
          if (_showResourcePicker) setState(() => _showResourcePicker = false);
          onTap();
        },
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 20,
              color: active ? Colors.white : Colors.white70),
        ),
      ),
    );
    return tip != null ? Tooltip(message: tip, child: w) : w;
  }

  Widget _mapBtnW(Widget iconWidget, VoidCallback onTap, {bool active = false, String? tip}) {
    final w = Material(
      color: active ? Colors.teal.shade700 : Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: () {
          if (_showResourcePicker) setState(() => _showResourcePicker = false);
          onTap();
        },
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(width: 20, height: 20, child: iconWidget),
        ),
      ),
    );
    return tip != null ? Tooltip(message: tip, child: w) : w;
  }

  String fmtNum(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}k';
    return '$n';
  }

}

// ── Mine tap bottom sheet (map) ────────────────────────────────────────────

class _MapMineSheet extends StatefulWidget {
  final Mine mine;
  final Player player;
  final bool inBossRange;
  final VoidCallback onDone;
  const _MapMineSheet({
    required this.mine, required this.player,
    required this.inBossRange, required this.onDone,
  });
  @override
  State<_MapMineSheet> createState() => _MapMineSheetState();
}

class _MapMineSheetState extends State<_MapMineSheet> {
  bool _busy = false;

  Mine get mine => widget.mine;
  Player get player => widget.player;

  Color get _condColor =>
      mine.condition > 60 ? Colors.green : mine.condition > 30 ? Colors.orange : Colors.red;

  int? get _activeTuLevel {
    if (mine.tu1 < 100) return 1;
    if (mine.tu2 < 100) return 2;
    if (mine.tu3 < 100) return 3;
    if (mine.tu4 < 100) return 4;
    return null;
  }

  bool get _hasKit => (player.lager['43'] ?? 0) >= 1;

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await fn(); } finally { if (mounted) setState(() => _busy = false); }
  }

  void _done(String msg, {bool error = false}) {
    if (!mounted) return;
    AppNotify.show(context, msg, isError: error);
    if (!error) {
      Navigator.pop(context);
      widget.onDone();
    }
  }

  Future<void> _repairFree() => _run(() async {
    final sid = context.read<PlayerProvider>().sid;
    final r = await ApiService.repairMineKit(sid, mine.id);
    if (!mounted) return;
    if (r == null || r['err'] != 0) {
      _done(r?['msg'] ?? 'Repair failed', error: true);
    } else {
      _done('Repaired for free (boss range)!');
    }
  });

  Future<void> _repairPay() => _run(() async {
    final sid = context.read<PlayerProvider>().sid;
    final r = await ApiService.repairMinePay(sid, mine.id);
    if (!mounted) return;
    if (r == null || r['err'] != 0) {
      _done(r?['msg'] ?? 'Repair failed', error: true);
    } else {
      _done('Repaired! Cost: ꞓ${r['cost']}');
    }
  });

  Future<void> _repairKit() => _run(() async {
    final sid = context.read<PlayerProvider>().sid;
    final r = await ApiService.repairMineKit(sid, mine.id);
    if (!mounted) return;
    if (r == null || r['err'] != 0) {
      _done(r?['msg'] ?? 'Kit repair failed', error: true);
    } else {
      _done('Repaired with kit!');
    }
  });

  Future<void> _demolish() async {
    final refund = ((kMineBuildCost[mine.itemId] ?? 0) * 0.1).round();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Demolish mine?'),
        content: Text('Refund: ꞓ$refund'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Demolish'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await _run(() async {
      final sid = context.read<PlayerProvider>().sid;
      final r = await ApiService.demolishMine(sid, mine.id);
      if (!mounted) return;
      if (r == null || r['err'] != 0) {
        _done('Demolish failed', error: true);
      } else {
        _done('Demolished. Refund: ꞓ${r['refund']}');
      }
    });
  }

  void _openTechSheet() {
    final ctx = context;
    Navigator.pop(ctx);
    Future.microtask(() {
      if (!ctx.mounted) return;
      showModalBottomSheet(
        context: ctx,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF1A1A2E),
        builder: (_) => _MapTechSheet(mine: mine, player: player, onDone: widget.onDone),
      );
    });
  }

  int _repairCost() {
    final deficit = 100 - mine.condition;
    final base = (kMineBaseRate[mine.itemId] ?? 100) * 10;
    return (deficit * base / 100).round();
  }

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(4)),
    child: Text(text, style: TextStyle(color: color, fontSize: 11)),
  );

  @override
  Widget build(BuildContext context) {
    final mineName = kMineNames[mine.itemId] ?? 'Mine';
    final techBonus = mine.techBoostPct;
    final effectiveRate = mine.rateHr > 0
        ? mine.rateHr
        : (kMineBaseRate[mine.itemId] ?? 0) *
            (mine.quality / 100) * (mine.condition / 100) *
            (1 + techBonus / 100) * mine.level.toDouble();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Text(mineName,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                const Spacer(),
                if (widget.inBossRange)
                  _badge('BOSS RANGE', Colors.greenAccent),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: [
                _badge('${mine.conditionPct}%', _condColor),
                _badge('Q${fmtQual(mine.quality)}', Colors.amber),
                _badge('Lv ${mine.level}', Colors.white54),
                if (mine.hasTech) _badge('+${mine.techBoostPct}%', Colors.purpleAccent),
                if (mine.isSick) _badge('SICK', Colors.redAccent),
                if (mine.hqBoost != null) _badge('HQ×${mine.hqBoost!.toStringAsFixed(1)}', Colors.tealAccent),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.speed, size: 13, color: Colors.greenAccent),
                const SizedBox(width: 4),
                Text('${effectiveRate.toStringAsFixed(1)}/hr',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
                const SizedBox(width: 16),
                Text('${mine.lat.toStringAsFixed(5)}, ${mine.lng.toStringAsFixed(5)}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ]),
              const Divider(height: 20),
              if (_busy)
                const Center(child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: CircularProgressIndicator(),
                ))
              else ...[
                if (mine.condition <= 99.00) ...[
                  if (widget.inBossRange) ...[
                    SizedBox(width: double.infinity, child: FilledButton.icon(
                      icon: const Icon(Icons.build, size: 16),
                      label: const Text('Free Repair (boss range)'),
                      style: FilledButton.styleFrom(backgroundColor: Colors.greenAccent,
                          foregroundColor: Colors.black),
                      onPressed: _repairFree,
                    )),
                    const SizedBox(height: 8),
                  ],
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(
                      icon: const Icon(Icons.build_outlined, size: 14),
                      label: Text('Pay ꞓ${_repairCost()}'),
                      onPressed: _repairPay,
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: OutlinedButton.icon(
                      icon: const Icon(Icons.construction, size: 14),
                      label: Text(_hasKit ? 'Use Kit' : 'No Kits'),
                      onPressed: _hasKit ? _repairKit : null,
                    )),
                  ]),
                  const SizedBox(height: 8),
                ],
                Row(children: [
                  Expanded(child: OutlinedButton.icon(
                    icon: const Icon(Icons.settings_suggest, size: 14),
                    label: Text(_activeTuLevel == null
                        ? 'Max Tech' : 'Tech +${mine.techBoostPct}%'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.purpleAccent,
                        side: const BorderSide(color: Colors.purple)),
                    onPressed: _openTechSheet,
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 14),
                    label: const Text('Demolish'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.red)),
                    onPressed: _demolish,
                  )),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Tech upgrade sheet (map context) ──────────────────────────────────────

class _MapTechSheet extends StatefulWidget {
  final Mine mine;
  final Player player;
  final VoidCallback onDone;
  const _MapTechSheet({required this.mine, required this.player, required this.onDone});
  @override
  State<_MapTechSheet> createState() => _MapTechSheetState();
}

class _MapTechSheetState extends State<_MapTechSheet> {
  double _sliderVal = 0;
  bool _busy = false;

  Mine get mine => widget.mine;
  Player get player => widget.player;

  int? get _activeTuLevel {
    if (mine.tu1 < 100) return 1;
    if (mine.tu2 < 100) return 2;
    if (mine.tu3 < 100) return 3;
    if (mine.tu4 < 100) return 4;
    return null;
  }

  int _currentForLevel(int lvl) {
    switch (lvl) {
      case 1: return mine.tu1;
      case 2: return mine.tu2;
      case 3: return mine.tu3;
      case 4: return mine.tu4;
      default: return 0;
    }
  }

  int _tuItemId(int lvl) => [44, 45, 46, 48][lvl - 1];

  int _stockForLevel(int lvl) {
    final itemId = _tuItemId(lvl).toString();
    return (player.lager[itemId] ?? 0).toInt();
  }

  double _previewBoost(int lvl, int amount) {
    final tu1 = lvl == 1 ? mine.tu1 + amount : mine.tu1;
    final tu2 = lvl == 2 ? mine.tu2 + amount : mine.tu2;
    final tu3 = lvl == 3 ? mine.tu3 + amount : mine.tu3;
    final tu4 = lvl == 4 ? mine.tu4 + amount : mine.tu4;
    return tu1 * 1.0 + tu2 * 1.0 + tu3 * 1.5 + tu4 * 1.5;
  }

  @override
  Widget build(BuildContext context) {
    final activeLevel = _activeTuLevel;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('Tech Upgrades',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                const Spacer(),
                Text('+${mine.techBoostPct}% boost',
                    style: const TextStyle(color: Colors.purpleAccent, fontSize: 13)),
              ]),
              const SizedBox(height: 12),
              for (int lvl = 1; lvl <= 4; lvl++) ...[
                _TuRow(lvl: lvl, current: _currentForLevel(lvl)),
                const SizedBox(height: 4),
              ],
              if (activeLevel == null) ...[
                const SizedBox(height: 8),
                const Center(child: Text('All tech upgrades installed! (+500% max)',
                    style: TextStyle(color: Colors.greenAccent))),
              ] else ...[
                const Divider(height: 20),
                Text('Install TU$activeLevel',
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 4),
                Builder(builder: (_) {
                  final current = _currentForLevel(activeLevel);
                  final stock = _stockForLevel(activeLevel);
                  final maxInstall = math.min(100 - current, stock);
                  final amount = _sliderVal.round().clamp(0, maxInstall);
                  final preview = _previewBoost(activeLevel, amount);
                  if (maxInstall == 0) {
                    return Text(
                      stock == 0 ? 'No TU$activeLevel items in warehouse' : 'Already full',
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text('Amount: $amount / $maxInstall',
                            style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        const Spacer(),
                        Text('+${preview.toStringAsFixed(0)}% boost',
                            style: const TextStyle(color: Colors.purpleAccent, fontSize: 12)),
                      ]),
                      Slider(
                        value: _sliderVal.clamp(0, maxInstall.toDouble()),
                        min: 0, max: maxInstall.toDouble(),
                        divisions: maxInstall > 0 ? maxInstall : 1,
                        activeColor: Colors.purpleAccent,
                        onChanged: (v) => setState(() => _sliderVal = v),
                      ),
                      SizedBox(width: double.infinity, child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: Colors.purple),
                        onPressed: amount > 0 && !_busy ? () async {
                          setState(() => _busy = true);
                          final sid = context.read<PlayerProvider>().sid;
                          final r = await ApiService.techUpgradeMine(
                              sid, mine.id, activeLevel, amount);
                          if (!mounted) return;
                          setState(() => _busy = false);
                          if (r == null || r['err'] != 0) {
                            AppNotify.show(context, r?['msg'] ?? 'Upgrade failed', isError: true);
                          } else {
                            AppNotify.show(context,
                                'Installed $amount TU$activeLevel → +${r['boostPct']}%');
                            Navigator.pop(context);
                            widget.onDone();
                          }
                        } : null,
                        child: _busy
                            ? const SizedBox(width: 16, height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('Install'),
                      )),
                    ],
                  );
                }),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TuRow extends StatelessWidget {
  final int lvl;
  final int current;
  const _TuRow({required this.lvl, required this.current});
  @override
  Widget build(BuildContext context) {
    final pct = current / 100.0;
    final boost = [100.0, 200.0, 350.0, 500.0][lvl - 1];
    return Row(children: [
      SizedBox(width: 36, child: Text('TU$lvl', style: const TextStyle(color: Colors.white54, fontSize: 12))),
      Expanded(child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: pct,
          backgroundColor: Colors.white12,
          color: current == 100 ? Colors.greenAccent : Colors.purpleAccent,
          minHeight: 10,
        ),
      )),
      const SizedBox(width: 8),
      SizedBox(width: 60, child: Text('$current/100 (+${boost.toStringAsFixed(0)}%)',
          style: const TextStyle(color: Colors.white38, fontSize: 10))),
    ]);
  }
}
