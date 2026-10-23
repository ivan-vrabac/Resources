import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_colors.dart';
import '../branding.dart';
import '../models/player_provider.dart';
import '../models/tab_config.dart';
import '../services/api_service.dart';
import '../services/launcher_icon_service.dart';
import '../services/update_service.dart';
import '../widgets/update_dialog.dart';
import '../constants.dart' show kNumDecimals, kInvertAskBid;
import 'game_screen.dart' show tabMeta;

// ── Notification settings ──────────────────────────────────────────────────────
bool kNotifEnabled       = true;
bool kNotifMineWarning   = true;
bool kNotifMineDestroyed = true;
bool kNotifWarehouseFull = true;

// ── App color palette ──────────────────────────────────────────────────────────
// owner 2026-10-23: no separate accent; background, text and icon colours (AppColors) + strength
double kSurfaceTone   = 0.5; // 0.0 = very dark, 1.0 = less dark
double kBgStrength    = 0.3; // how strongly backgrounds and panels take the background colour

ThemeData _buildAppTheme() {
  final accent = AppColors.accent, fg = AppColors.fg, bg = AppColors.bg;
  final scheme = ColorScheme.fromSeed(
      seedColor: accent, brightness: Brightness.dark, dynamicSchemeVariant: DynamicSchemeVariant.vibrant);
  late final Color scaffold, surface, c1, c2, c3;
  if (AppColors.isBlack) {
    // true OLED black: black screens, panels just visible enough to separate
    scaffold = Colors.black;
    surface = const Color(0xFF000000);
    c1 = const Color(0xFF121212);
    c2 = const Color(0xFF1C1C1C);
    c3 = const Color(0xFF262626);
  } else {
    final base = Color.lerp(const Color(0xFF0A0A0A), const Color(0xFF2D2D3D), kSurfaceTone)!;
    final k = kBgStrength;
    scaffold = Color.lerp(base, bg, k * 0.6)!;
    surface = Color.lerp(base, bg, k * 0.9)!;
    c1 = Color.lerp(base, bg, (k * 1.2).clamp(0.0, 1.0))!;
    c2 = Color.lerp(base, bg, (k * 1.5).clamp(0.0, 1.0))!;
    c3 = Color.lerp(base, bg, (k * 1.8).clamp(0.0, 1.0))!;
  }
  // outlines are mixed from the text colour, so panels never melt into the background
  final outline = Color.lerp(c2, fg, 0.35)!;
  final cs = scheme.copyWith(
    primary: accent,
    onPrimary: accent.computeLuminance() > 0.45 ? Colors.black : Colors.white,
    secondary: accent,
    surface: surface,
    onSurface: fg,
    onSurfaceVariant: fg.withValues(alpha: 0.75),
    surfaceContainerLowest: scaffold,
    surfaceContainerLow: c1,
    surfaceContainer: c1,
    surfaceContainerHigh: c2,
    surfaceContainerHighest: c3,
    outline: outline,
    outlineVariant: outline.withValues(alpha: 0.6),
  );
  final base = ThemeData(colorScheme: cs, useMaterial3: true, scaffoldBackgroundColor: scaffold);
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: fg, displayColor: fg),
    iconTheme: base.iconTheme.copyWith(color: accent),
    listTileTheme: base.listTileTheme.copyWith(iconColor: accent, textColor: fg),
    appBarTheme: base.appBarTheme.copyWith(backgroundColor: surface, foregroundColor: fg,
        iconTheme: IconThemeData(color: accent), actionsIconTheme: IconThemeData(color: accent)),
    cardTheme: base.cardTheme.copyWith(color: c1, shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12), side: BorderSide(color: outline.withValues(alpha: 0.7)))),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(backgroundColor: c1, modalBackgroundColor: c1),
    dialogTheme: base.dialogTheme.copyWith(backgroundColor: c2),
    dividerColor: outline.withValues(alpha: 0.5),
    navigationBarTheme: base.navigationBarTheme.copyWith(backgroundColor: surface),
  );
}

final appThemeNotifier = ValueNotifier<ThemeData>(_buildAppTheme());

class SettingsScreen extends StatefulWidget {
  final TabConfig config;
  final ValueChanged<TabConfig> onSave;

  const SettingsScreen({super.key, required this.config, required this.onSave});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

double kCloudOpacity = 0.55;

final List<Color> kRingPresets = [
  AppColors.accent, Colors.blueAccent, Colors.deepPurple,
  Colors.greenAccent, Colors.orange, Colors.redAccent,
];
Color  kDroneRingColor   = Colors.orange;
double kDroneRingOpacity = 0.50;
Color  kScanRingColor    = AppColors.accent;
double kScanRingOpacity  = 0.50;
Color  kLocalRingColor   = Colors.blueAccent;
double kLocalRingOpacity = 0.70;
bool   kShowRingLabels   = true;
// optional range rings (Settings > Scan Rings): Museum pick-up, artifact reveal, Mafia attack
bool   kShowMuseumRing   = false;
bool   kShowRevealRing   = false;
bool   kShowMafiaRing    = false;

const List<String> kHeatmapSchemes      = ['classic', 'cold', 'contrast'];
const List<String> kHeatmapSchemeLabels = ['Classic', 'Cold', 'Contrast'];
String kHeatmapScheme = 'classic';

// Notifier so the map tab re-renders the heatmap immediately on palette change.
final heatmapSchemeNotifier = ValueNotifier<String>('classic');

// GPS refresh interval (seconds)
int kGpsIntervalSeconds = 3;

// Map panel background opacity (1.0 = fully opaque, matches bottom nav)
double kMapPanelOpacity = 1.0;
final mapPanelOpacityNotifier = ValueNotifier<double>(1.0);

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Settings')),
      body: ListView(children: [
        _sectionHeader('Interface'),
        ListTile(
          leading: Icon(Icons.tab, color: AppColors.accent),
          title: const Text('Bottom bar'),
          subtitle: Text(
            '${widget.config.bottomTabs.length} tab${widget.config.bottomTabs.length == 1 ? '' : 's'} pinned',
            style: TextStyle(color: AppColors.t38, fontSize: 12),
          ),
          trailing: Icon(Icons.chevron_right, color: AppColors.t38),
          onTap: () => Navigator.push(context, MaterialPageRoute(
            builder: (_) => _BottomBarSettings(config: widget.config, onSave: widget.onSave),
          )),
        ),
        _sectionHeader('Map'),
        _categoryTile(context, Icons.thermostat, 'Scan Heatmap',
            'Opacity · palette', () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _ScanHeatmapPage()))),
        _categoryTile(context, Icons.radio_button_checked, 'Scan Rings',
            'Labels · ring colors & opacity', () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _ScanRingsPage()))),
        _categoryTile(context, Icons.layers, 'Map Appearance',
            'Panel color & opacity', () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _MapAppearancePage()))),
        _sectionHeader('App'),
        _categoryTile(context, Icons.palette_outlined, 'App Appearance',
            'Primary color · surface tone', () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _AppAppearancePage()))),
        if (LauncherIconService.supported)
          _categoryTile(context, Icons.apps, 'App Icon',
              'Choose a launcher icon variant', () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => const _AppIconPage()))),
        _categoryTile(context, Icons.notifications_outlined, 'Notifications',
            'Mine warnings · warehouse alerts', () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _NotificationsPage()))),
        _sectionHeader('Account'),
        _categoryTile(context, Icons.lock_outline, 'Change password',
            'Update the password for this company', () => showDialog(
              context: context, builder: (_) => const _ChangePasswordDialog())),
        _sectionHeader('System'),
        _categoryTile(context, Icons.speed, 'Performance',
            'GPS update interval', () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _PerformancePage()))),
        if (UpdateService.supported)
          _categoryTile(context, Icons.system_update, 'Updates',
              'Version ${Branding.buildName} (build ${Branding.buildNumber}) · check for a newer build',
              () => UpdateDialog.open(context)),
        _categoryTile(context, Icons.pin, 'Numbers & Display',
            'Decimal places in compact notation', () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _NumbersDisplayPage()))),
      ]),
    );
  }

  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4, left: 16),
    child: Text(title.toUpperCase(),
        style: TextStyle(fontSize: 10, color: AppColors.t38, letterSpacing: 1.1)),
  );

  Widget _categoryTile(BuildContext context, IconData icon, String title,
      String subtitle, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: AppColors.accent),
      title: Text(title),
      subtitle: Text(subtitle, style: TextStyle(color: AppColors.t38, fontSize: 12)),
      trailing: Icon(Icons.chevron_right, color: AppColors.t38),
      onTap: onTap,
    );
  }
}

// ── Shared helpers ─────────────────────────────────────────────────────────────

Widget _settingsSectionHeader(String title) => Padding(
  padding: const EdgeInsets.only(top: 12, bottom: 4, left: 16),
  child: Text(title.toUpperCase(),
      style: TextStyle(fontSize: 10, color: AppColors.t38, letterSpacing: 1.1)),
);

// ── Reusable color picker ──────────────────────────────────────────────────────
// Shows preset swatches. [selected] is the currently selected color;
// [onChanged] fires on any pick. [swatchSize] controls swatch diameter.

class _ColorPickerWidget extends StatelessWidget {
  final Color selected;
  final ValueChanged<Color> onChanged;
  final List<Color> presets;
  final double swatchSize;

  const _ColorPickerWidget({
    required this.selected,
    required this.onChanged,
    required this.presets,
    this.swatchSize = 28,
  });

  static bool _hasGoodContrast(Color c) {
    double lum(double x) => x <= 0.04045 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
    final r = lum(c.r), g = lum(c.g), b = lum(c.b);
    final L1 = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    return (L1 + 0.05) / 0.05 >= 3.0;
  }

  @override
  Widget build(BuildContext context) {
    final selArgb = selected.toARGB32();
    final showWarning = !_hasGoodContrast(selected);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in presets)
          GestureDetector(
            onTap: () => onChanged(c),
            child: Container(
              width: swatchSize, height: swatchSize,
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(
                  color: c.toARGB32() == selArgb ? Colors.white : Colors.transparent,
                  width: 2.5,
                ),
                boxShadow: c.toARGB32() == selArgb
                    ? [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 6)]
                    : null,
              ),
              child: c.toARGB32() == selArgb
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
          ),
      ]),
      if (showWarning)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            const Icon(Icons.warning_amber, size: 14, color: Colors.orange),
            const SizedBox(width: 4),
            const Expanded(
              child: Text(
                'Low contrast — this color may be hard to read on dark backgrounds.',
                style: TextStyle(fontSize: 11, color: Colors.orange),
              ),
            ),
          ]),
        ),
    ]);
  }
}

// ── Scan Heatmap settings page ─────────────────────────────────────────────────

class _ScanHeatmapPage extends StatefulWidget {
  const _ScanHeatmapPage();
  @override
  State<_ScanHeatmapPage> createState() => _ScanHeatmapPageState();
}

class _ScanHeatmapPageState extends State<_ScanHeatmapPage> {
  late double _cloudOpacity;
  late String _heatmapScheme;

  @override
  void initState() {
    super.initState();
    _cloudOpacity = kCloudOpacity;
    _heatmapScheme = kHeatmapScheme;
  }

  Future<void> _setCloudOpacity(double v) async {
    setState(() => _cloudOpacity = v);
    kCloudOpacity = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('res_cloud_opacity', v);
  }

  Future<void> _setHeatmapScheme(String s) async {
    setState(() { _heatmapScheme = s; kHeatmapScheme = s; });
    heatmapSchemeNotifier.value = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('heatmap_scheme', s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Scan Heatmap')),
      body: ListView(children: [
        _settingsSectionHeader('Opacity'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '${(_cloudOpacity * 100).round()}%  —  '
              '${_cloudOpacity < 0.3 ? "subtle" : _cloudOpacity < 0.6 ? "medium" : "bright"}',
              style: TextStyle(fontSize: 12, color: AppColors.accent),
            ),
            Row(children: [
              Text('10%', style: TextStyle(color: AppColors.t38, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _cloudOpacity,
                  min: 0.10, max: 0.90, divisions: 16,
                  activeColor: AppColors.accent,
                  label: '${(_cloudOpacity * 100).round()}%',
                  onChanged: _setCloudOpacity,
                ),
              ),
              Text('90%', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            ]),
          ]),
        ),
        _settingsSectionHeader('Color Palette'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (int i = 0; i < kHeatmapSchemes.length; i++) ...[
              GestureDetector(
                onTap: () => _setHeatmapScheme(kHeatmapSchemes[i]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: _heatmapScheme == kHeatmapSchemes[i]
                        ? AppColors.accent.withValues(alpha: 0.20)
                        : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _heatmapScheme == kHeatmapSchemes[i]
                          ? AppColors.accent.withValues(alpha: 0.6)
                          : Colors.white12,
                    ),
                  ),
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: 80, height: 20,
                        child: CustomPaint(painter: _PalettePreviewPainter(palette: kHeatmapSchemes[i])),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(kHeatmapSchemeLabels[i], style: TextStyle(
                      fontSize: 13,
                      color: _heatmapScheme == kHeatmapSchemes[i] ? AppColors.accent : AppColors.t70,
                    )),
                    const Spacer(),
                    if (_heatmapScheme == kHeatmapSchemes[i])
                      Icon(Icons.check, size: 16, color: AppColors.accent),
                  ]),
                ),
              ),
            ],
            Text('Updates the current heatmap immediately.',
                style: TextStyle(fontSize: 11, color: AppColors.t38)),
          ]),
        ),
      ]),
    );
  }
}

// ── Scan Rings settings page ───────────────────────────────────────────────────

class _ScanRingsPage extends StatefulWidget {
  const _ScanRingsPage();
  @override
  State<_ScanRingsPage> createState() => _ScanRingsPageState();
}

class _ScanRingsPageState extends State<_ScanRingsPage> {
  late Color  _droneColor;
  late double _droneOpacity;
  late Color  _scanColor;
  late double _scanOpacity;
  late Color  _localColor;
  late double _localOpacity;
  late bool   _showRingLabels;

  @override
  void initState() {
    super.initState();
    _droneColor    = kDroneRingColor;
    _droneOpacity  = kDroneRingOpacity;
    _scanColor     = kScanRingColor;
    _scanOpacity   = kScanRingOpacity;
    _localColor    = kLocalRingColor;
    _localOpacity  = kLocalRingOpacity;
    _showRingLabels = kShowRingLabels;
  }

  Future<void> _setRing(String key, {Color? color, double? opacity}) async {
    final prefs = await SharedPreferences.getInstance();
    if (color != null) {
      setState(() {
        if (key == 'drone') { _droneColor = color; kDroneRingColor = color; }
        else if (key == 'scan') { _scanColor = color; kScanRingColor = color; }
        else { _localColor = color; kLocalRingColor = color; }
      });
      await prefs.setInt('${key}_ring_color', color.toARGB32());
    }
    if (opacity != null) {
      setState(() {
        if (key == 'drone') { _droneOpacity = opacity; kDroneRingOpacity = opacity; }
        else if (key == 'scan') { _scanOpacity = opacity; kScanRingOpacity = opacity; }
        else { _localOpacity = opacity; kLocalRingOpacity = opacity; }
      });
      await prefs.setDouble('${key}_ring_opacity', opacity);
    }
  }

  Widget _ringToggle(String title, String subtitle, String pref, bool Function() get, void Function(bool) set) =>
      SwitchListTile(
        dense: true,
        title: Text(title, style: const TextStyle(fontSize: 13)),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 11, color: AppColors.t38)),
        value: get(),
        activeColor: AppColors.accent,
        onChanged: (v) async {
          setState(() => set(v));
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(pref, v);
        },
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Scan Rings')),
      body: ListView(children: [
        SwitchListTile(
          dense: true,
          title: const Text('Show ring labels', style: TextStyle(fontSize: 13)),
          value: _showRingLabels,
          activeColor: AppColors.accent,
          onChanged: (v) async {
            setState(() => _showRingLabels = v);
            kShowRingLabels = v;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('show_ring_labels', v);
          },
        ),
        _settingsSectionHeader('More rings'),
        _ringToggle('Museum pick-up range', 'Cargo Rain crates and artifacts', 'show_museum_ring',
            () => kShowMuseumRing, (v) => kShowMuseumRing = v),
        _ringToggle('Artifact reveal range', 'Archaeological Center', 'show_reveal_ring',
            () => kShowRevealRing, (v) => kShowRevealRing = v),
        _ringToggle('Mafia attack range', 'Mafia HQ', 'show_mafia_ring',
            () => kShowMafiaRing, (v) => kShowMafiaRing = v),
        _settingsSectionHeader('Ring Colors & Opacity'),
        _ringSection('Drone range', 'drone', _droneColor, _droneOpacity),
        _ringSection('TC scan radius', 'scan', _scanColor, _scanOpacity),
        _ringSection('Local Range', 'local', _localColor, _localOpacity),
      ]),
    );
  }

  Widget _ringSection(String label, String key, Color color, double opacity) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: AppColors.t70)),
        const SizedBox(height: 6),
        _ColorPickerWidget(
          selected: color,
          presets: kRingPresets,
          swatchSize: 24,
          onChanged: (c) => _setRing(key, color: c),
        ),
        const SizedBox(height: 4),
        Row(children: [
          Text('Opacity: ${(opacity * 100).round()}%',
              style: TextStyle(fontSize: 11, color: color)),
          Expanded(
            child: Slider(
              value: opacity,
              min: 0.0, max: 1.0, divisions: 20,
              activeColor: color,
              onChanged: (v) => _setRing(key, opacity: v),
            ),
          ),
        ]),
      ]),
    );
  }
}

// ── Map Appearance settings page ───────────────────────────────────────────────

class _MapAppearancePage extends StatefulWidget {
  const _MapAppearancePage();
  @override
  State<_MapAppearancePage> createState() => _MapAppearancePageState();
}

class _MapAppearancePageState extends State<_MapAppearancePage> {
  late double _panelOpacity;

  @override
  void initState() {
    super.initState();
    _panelOpacity = kMapPanelOpacity;
  }

  Future<void> _setPanelOpacity(double v) async {
    setState(() => _panelOpacity = v);
    kMapPanelOpacity = v;
    mapPanelOpacityNotifier.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('map_panel_opacity', v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Map Appearance')),
      body: ListView(children: [
        _settingsSectionHeader('Map Panel Background'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Controls the opacity of map UI panels (scan buttons, resource selector, top bar). '
              'At 100% the panels match the bottom navigation bar exactly.',
              style: TextStyle(fontSize: 12, color: AppColors.t54),
            ),
            const SizedBox(height: 12),
            Text(
              '${(_panelOpacity * 100).round()}%  —  '
              '${_panelOpacity >= 0.95 ? "opaque (matches nav bar)" : _panelOpacity >= 0.6 ? "semi-transparent" : "very transparent"}',
              style: TextStyle(fontSize: 12, color: AppColors.accent),
            ),
            Row(children: [
              Text('20%', style: TextStyle(color: AppColors.t38, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _panelOpacity,
                  min: 0.20, max: 1.0, divisions: 16,
                  activeColor: AppColors.accent,
                  label: '${(_panelOpacity * 100).round()}%',
                  onChanged: _setPanelOpacity,
                ),
              ),
              Text('100%', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            ]),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _setPanelOpacity(1.0),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reset to default'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: BorderSide(color: AppColors.accent),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ── Performance settings page ──────────────────────────────────────────────────

class _PerformancePage extends StatefulWidget {
  const _PerformancePage();
  @override
  State<_PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<_PerformancePage> {
  late int _gpsInterval;

  @override
  void initState() {
    super.initState();
    _gpsInterval = kGpsIntervalSeconds;
  }

  Future<void> _setGpsInterval(int seconds) async {
    setState(() { _gpsInterval = seconds; kGpsIntervalSeconds = seconds; });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('gps_interval', seconds);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Performance')),
      body: ListView(children: [
        _settingsSectionHeader('GPS'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('GPS refresh interval',
                style: TextStyle(fontSize: 13, color: AppColors.t70)),
            const SizedBox(height: 4),
            Text(
              '$_gpsInterval second${_gpsInterval == 1 ? '' : 's'}  —  '
              '${_gpsInterval <= 2 ? "very frequent" : _gpsInterval <= 4 ? "balanced (recommended)" : _gpsInterval <= 9 ? "power saving" : "minimal updates"}',
              style: TextStyle(fontSize: 12, color: AppColors.accent),
            ),
            Row(children: [
              Text('1s', style: TextStyle(color: AppColors.t38, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _gpsInterval.toDouble(),
                  min: 1, max: 10, divisions: 9,
                  activeColor: AppColors.accent,
                  label: '${_gpsInterval}s',
                  onChanged: (v) => _setGpsInterval(v.round()),
                ),
              ),
              Text('10s', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            ]),
            Text(
              'Controls how often the app applies GPS position updates. '
              'Android Fused Location Provider is used for high accuracy.',
              style: TextStyle(fontSize: 11, color: AppColors.t38),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ── Numbers & Display settings page ───────────────────────────────────────────

class _NumbersDisplayPage extends StatefulWidget {
  const _NumbersDisplayPage();
  @override
  State<_NumbersDisplayPage> createState() => _NumbersDisplayPageState();
}

class _NumbersDisplayPageState extends State<_NumbersDisplayPage> {
  late int _numDecimals;

  @override
  void initState() {
    super.initState();
    _numDecimals = kNumDecimals;
  }

  Future<void> _setDecimals(int d) async {
    setState(() => _numDecimals = d);
    // ignore: invalid_use_of_visible_for_testing_member
    kNumDecimals = d;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('numDecimals', d);
  }

  String _preview(int d) {
    if (d < 0) return '1,234  1,234,567  1,234,567,890';
    String fmt(double n, String suf) => '${n.toStringAsFixed(d)}$suf';
    return '${fmt(1.2345, 'K')}  ${fmt(1.2345, 'M')}  ${fmt(1.2345, 'B')}  ${fmt(1.2345, 'T')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Numbers & Display')),
      body: ListView(children: [
        _settingsSectionHeader('Compact Notation'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Decimal places in compact notation',
                style: TextStyle(fontSize: 13, color: AppColors.t70)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'e.g. ${_preview(_numDecimals)}',
                style: TextStyle(fontSize: 13, color: AppColors.accent,
                    fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Text('0', style: TextStyle(color: AppColors.t38, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _numDecimals < 0 ? 5 : _numDecimals.toDouble(),
                  min: 0, max: 5, divisions: 5,
                  label: _numDecimals < 0 ? 'Full' : '$_numDecimals',
                  onChanged: (v) => _setDecimals(v.round() == 5 ? -1 : v.round()),
                ),
              ),
              Text('Full', style: TextStyle(color: AppColors.t38, fontSize: 11)),
            ]),
          ]),
        ),
        _settingsSectionHeader('Market'),
        SwitchListTile(
          title: const Text('Invert ASK / BID colours'),
          subtitle: Text(kInvertAskBid ? 'ASK green · BID red' : 'ASK red · BID green',
              style: TextStyle(color: AppColors.t38, fontSize: 12)),
          value: kInvertAskBid,
          onChanged: (v) async {
            setState(() => kInvertAskBid = v);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('invert_ask_bid', v);
          },
        ),
      ]),
    );
  }
}

// ── App Appearance settings page ───────────────────────────────────────────────


// backgrounds: black (OLED) first, default grey (blueGrey) among them
final _kBgPresetColors = <Color>[
  Colors.black, Color(0xFF424242), Colors.blueGrey, Colors.brown, Colors.indigo, Colors.blue, Colors.lightBlue,
  Colors.cyan, AppColors.accent, Colors.green, Color(0xFF1B5E20), Colors.lime, Colors.amber, Colors.orange,
  Colors.deepOrange, Colors.red, Color(0xFFB71C1C), Colors.pink, Colors.purple, Colors.deepPurple,
];

final _kIconPresetColors = <Color>[
  AppColors.accent, Colors.cyanAccent, Colors.lightBlueAccent, Colors.blueAccent, Colors.indigoAccent,
  Colors.deepPurpleAccent, Colors.purpleAccent, Colors.pinkAccent, Colors.redAccent, Colors.deepOrangeAccent,
  Colors.orangeAccent, Colors.amberAccent, Colors.yellowAccent, Colors.limeAccent, Colors.lightGreenAccent,
  Colors.greenAccent, Colors.white, Color(0xFFBDBDBD),
];

// readable text colours on dark backgrounds
const _kTextPresetColors = <Color>[
  Colors.white, Color(0xFFE0E0E0), Color(0xFFFFF8E1), Color(0xFFFFE082), Color(0xFFFFCC80),
  Color(0xFFB2DFDB), Color(0xFF80DEEA), Color(0xFFB3E5FC), Color(0xFFC5CAE9), Color(0xFFE1BEE7),
  Color(0xFFF8BBD0), Color(0xFFC8E6C9), Color(0xFFDCEDC8),
];

class _AppAppearancePage extends StatefulWidget {
  const _AppAppearancePage();
  @override
  State<_AppAppearancePage> createState() => _AppAppearancePageState();
}

class _AppAppearancePageState extends State<_AppAppearancePage> {
  Future<void> _apply() async {
    setState(() {});
    appThemeNotifier.value = _buildAppTheme();
    // screens that read AppColors directly repaint now, not only when they are reopened
    WidgetsBinding.instance.addPostFrameCallback((_) {
      void mark(Element e) { e.markNeedsBuild(); e.visitChildren(mark); }
      WidgetsBinding.instance.rootElement?.visitChildren(mark);
    });
    final prefs = await SharedPreferences.getInstance();
    Future<void> put(String key, Color? c) => c == null ? prefs.remove(key) : prefs.setInt(key, c.toARGB32());
    await put('app_bg_color', AppColors.background);
    await put('app_text_color', AppColors.text);
    await put('app_icon_color', AppColors.icon);
    await prefs.setDouble('app_bg_strength', kBgStrength);
    await prefs.setDouble('app_surface_tone', kSurfaceTone);
  }

  Future<void> _reset() async {
    AppColors.background = null;
    AppColors.text = null;
    AppColors.icon = null;
    kBgStrength = 0.3;
    kSurfaceTone = 0.5;
    await _apply();
  }

  Widget _swatches(Color current, List<Color> presets, void Function(Color) onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final c in presets)
          GestureDetector(
            onTap: () => onTap(c),
            child: Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: c, shape: BoxShape.circle,
                border: Border.all(
                    color: current.toARGB32() == c.toARGB32() ? AppColors.fg : AppColors.fg.withValues(alpha: 0.3),
                    width: current.toARGB32() == c.toARGB32() ? 3 : 1),
              ),
              child: current.toARGB32() == c.toARGB32()
                  ? Icon(Icons.check, size: 18, color: c.computeLuminance() > 0.45 ? Colors.black : Colors.white)
                  : null,
            ),
          ),
      ]),
    );
  }

  Widget _slider(String left, String right, double value, double max, ValueChanged<double> onChanged) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Text(left, style: TextStyle(color: AppColors.t54, fontSize: 11)),
          Expanded(child: Slider(value: value, min: 0.0, max: max, divisions: 10, onChanged: onChanged)),
          Text(right, style: TextStyle(color: AppColors.t54, fontSize: 11)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('App Appearance')),
      body: ListView(children: [
        _settingsSectionHeader('Background Colour'),
        _swatches(AppColors.bg, _kBgPresetColors, (c) { AppColors.background = c; _apply(); }),
        if (!AppColors.isBlack) ...[
          _slider('Subtle', 'Strong', kBgStrength, 0.6, (v) { kBgStrength = v; _apply(); }),
          _slider('Darker', 'Lighter', kSurfaceTone, 1.0, (v) { kSurfaceTone = v; _apply(); }),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Black: true black screens (saves battery on OLED displays).',
                style: TextStyle(fontSize: 11, color: AppColors.t54)),
          ),
        _settingsSectionHeader('Text Colour'),
        _swatches(AppColors.fg, _kTextPresetColors, (c) { AppColors.text = c; _apply(); }),
        _settingsSectionHeader('Icon & Symbol Colour'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Icons, buttons, sliders and highlights.', style: TextStyle(fontSize: 11, color: AppColors.t54)),
        ),
        _swatches(AppColors.accent, _kIconPresetColors, (c) { AppColors.icon = c; _apply(); }),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Reset to Default'),
            style: OutlinedButton.styleFrom(
              foregroundColor: cs.primary,
              side: BorderSide(color: cs.primary),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ]),
    );
  }
}

// ── Change password dialog ─────────────────────────────────────────────────────

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();
  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_new.text != _confirm.text) {
      setState(() => _error = 'New passwords do not match');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final err = await ApiService.changePassword(
        context.read<PlayerProvider>().sid, _old.text, _new.text);
    if (!mounted) return;
    if (err != null) {
      setState(() { _busy = false; _error = err; });
      return;
    }
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed')));
  }

  Widget _field(TextEditingController c, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(controller: c, obscureText: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        _field(_old, 'Current password'),
        _field(_new, 'New password (min. 6 characters)'),
        _field(_confirm, 'Repeat new password'),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
      ]),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}

// ── App icon page ──────────────────────────────────────────────────────────────

class _AppIconPage extends StatefulWidget {
  const _AppIconPage();
  @override
  State<_AppIconPage> createState() => _AppIconPageState();
}

class _AppIconPageState extends State<_AppIconPage> {
  String? _current;

  @override
  void initState() {
    super.initState();
    LauncherIconService.current().then((v) { if (mounted) setState(() => _current = v); });
  }

  Future<void> _select(String id) async {
    final ok = await LauncherIconService.select(id);
    if (!mounted) return;
    if (ok) setState(() => _current = id);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok
        ? 'Launcher icon changed. Your launcher may take a moment to update.'
        : 'Could not change the launcher icon on this device.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('App Icon')),
      body: RadioGroup<String>(
        groupValue: _current,
        onChanged: (id) { if (_current != null && id != null) _select(id); },
        child: ListView(children: [
        for (final v in kLauncherVariants)
          RadioListTile<String>(
            value: v.id,
            title: Text(v.label),
            secondary: Image.asset(v.asset, width: 40, height: 40,
                errorBuilder: (_, __, ___) => const Icon(Icons.apps)),
          ),
        Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Only icons bundled with this build can be selected. To ship your own icons '
            'or app name, see docs/BRANDING.md.',
            style: TextStyle(fontSize: 11, color: AppColors.t38),
          ),
        ),
      ])),
    );
  }
}

// ── Notifications settings page ────────────────────────────────────────────────

class _NotificationsPage extends StatefulWidget {
  const _NotificationsPage();
  @override
  State<_NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<_NotificationsPage> {
  late bool _enabled, _mineWarning, _mineDestroyed, _whFull;

  @override
  void initState() {
    super.initState();
    _enabled      = kNotifEnabled;
    _mineWarning  = kNotifMineWarning;
    _mineDestroyed = kNotifMineDestroyed;
    _whFull       = kNotifWarehouseFull;
  }

  Future<void> _set(String key, bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36, title: const Text('Notifications')),
      body: ListView(children: [
        SwitchListTile(
          dense: true,
          title: const Text('Enable notifications'),
          subtitle: Text('Master on/off for all game alerts',
              style: TextStyle(fontSize: 11, color: AppColors.t38)),
          value: _enabled,
          activeColor: AppColors.accent,
          onChanged: (v) async {
            setState(() { _enabled = v; kNotifEnabled = v; });
            await _set('notif_enabled', v);
          },
        ),
        _settingsSectionHeader('Event Types'),
        SwitchListTile(
          dense: true,
          title: const Text('Mine destruction warning'),
          subtitle: Text('~24 hours before a mine is destroyed',
              style: TextStyle(fontSize: 11, color: AppColors.t38)),
          value: _enabled && _mineWarning,
          activeColor: Colors.orange,
          onChanged: _enabled ? (v) async {
            setState(() { _mineWarning = v; kNotifMineWarning = v; });
            await _set('notif_mine_warning', v);
          } : null,
        ),
        SwitchListTile(
          dense: true,
          title: const Text('Mine destroyed'),
          subtitle: Text('When a mine reaches 0 condition',
              style: TextStyle(fontSize: 11, color: AppColors.t38)),
          value: _enabled && _mineDestroyed,
          activeColor: Colors.redAccent,
          onChanged: _enabled ? (v) async {
            setState(() { _mineDestroyed = v; kNotifMineDestroyed = v; });
            await _set('notif_mine_destroyed', v);
          } : null,
        ),
        SwitchListTile(
          dense: true,
          title: const Text('Warehouse full'),
          subtitle: Text('When storage is full and production is being lost',
              style: TextStyle(fontSize: 11, color: AppColors.t38)),
          value: _enabled && _whFull,
          activeColor: Colors.amber,
          onChanged: _enabled ? (v) async {
            setState(() { _whFull = v; kNotifWarehouseFull = v; });
            await _set('notif_wh_full', v);
          } : null,
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'At most one notification per category per 24 hours. '
            'Multiple mine events are combined into a single notification. '
            'Notifications are scheduled locally based on mine conditions at last sync.',
            style: TextStyle(fontSize: 11, color: AppColors.t38),
          ),
        ),
        const SizedBox(height: 16),
      ]),
    );
  }
}

Future<void> loadNumDecimalsPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  kNumDecimals = prefs.getInt('numDecimals') ?? 1;
  kInvertAskBid = prefs.getBool('invert_ask_bid') ?? false;
  kCloudOpacity = (prefs.getDouble('res_cloud_opacity') ?? 0.35).clamp(0.10, 0.90);
  final droneC = prefs.getInt('drone_ring_color');
  if (droneC != null) kDroneRingColor = Color(droneC);
  kDroneRingOpacity = (prefs.getDouble('drone_ring_opacity') ?? 0.50).clamp(0.0, 1.0);
  final scanC = prefs.getInt('scan_ring_color');
  if (scanC != null) kScanRingColor = Color(scanC);
  kScanRingOpacity = (prefs.getDouble('scan_ring_opacity') ?? 0.50).clamp(0.0, 1.0);
  final localC = prefs.getInt('local_ring_color');
  if (localC != null) kLocalRingColor = Color(localC);
  kLocalRingOpacity = (prefs.getDouble('local_ring_opacity') ?? 0.70).clamp(0.0, 1.0);
  kShowRingLabels = prefs.getBool('show_ring_labels') ?? true;
  kShowMuseumRing = prefs.getBool('show_museum_ring') ?? false;
  kShowRevealRing = prefs.getBool('show_reveal_ring') ?? false;
  kShowMafiaRing = prefs.getBool('show_mafia_ring') ?? false;
  final raw = prefs.getString('heatmap_scheme') ?? 'classic';
  kHeatmapScheme = kHeatmapSchemes.contains(raw) ? raw : 'classic';
  heatmapSchemeNotifier.value = kHeatmapScheme;
  kGpsIntervalSeconds = (prefs.getInt('gps_interval') ?? 3).clamp(1, 10);
  kMapPanelOpacity = (prefs.getDouble('map_panel_opacity') ?? 1.0).clamp(0.2, 1.0);
  mapPanelOpacityNotifier.value = kMapPanelOpacity;
  kNotifEnabled       = prefs.getBool('notif_enabled')        ?? true;
  kNotifMineWarning   = prefs.getBool('notif_mine_warning')   ?? true;
  kNotifMineDestroyed = prefs.getBool('notif_mine_destroyed') ?? true;
  kNotifWarehouseFull = prefs.getBool('notif_wh_full')        ?? true;
  kSurfaceTone = (prefs.getDouble('app_surface_tone') ?? 0.5).clamp(0.0, 1.0);
  final bgArgb = prefs.getInt('app_bg_color'), textArgb = prefs.getInt('app_text_color'),
      iconArgb = prefs.getInt('app_icon_color');
  AppColors.background = bgArgb == null ? null : Color(bgArgb);
  AppColors.text = textArgb == null ? null : Color(textArgb);
  AppColors.icon = iconArgb == null ? null : Color(iconArgb);
  kBgStrength = (prefs.getDouble('app_bg_strength') ?? 0.3).clamp(0.0, 0.6);
  appThemeNotifier.value = _buildAppTheme();
}

// ── Palette color stops (v = 0-255 grayscale quality byte) ────────────────────

const _kClassicStops = <List<int>>[
  [0,   0,   0,  80],
  [26,  0,  40, 180],
  [64,  0, 180, 200],
  [115, 0, 220,  80],
  [158,220, 220,   0],
  [199,230,  90,   0],
  [230,200,  20,   0],
  [255,120,   0,   0],
];

Color paletteColorAt(int v, String palette) {
  if (v == 0) return const Color(0x00000000);
  if (palette == 'contrast') {
    return Color.fromARGB(v, v, v, v);
  }
  // Cold is a genuine reversal of Classic: dark red at low quality, dark blue at high.
  final lookupV = palette == 'cold' ? (256 - v).clamp(1, 255) : v;
  final stops = _kClassicStops;
  for (int i = 1; i < stops.length; i++) {
    if (lookupV <= stops[i][0] || i == stops.length - 1) {
      final v0 = stops[i-1][0], r0 = stops[i-1][1], g0 = stops[i-1][2], b0 = stops[i-1][3];
      final v1 = stops[i][0],   r1 = stops[i][1],   g1 = stops[i][2],   b1 = stops[i][3];
      final t = v1 > v0 ? (lookupV - v0) / (v1 - v0) : 1.0;
      return Color.fromARGB(
        v,
        (r0 + (r1 - r0) * t).round().clamp(0, 255),
        (g0 + (g1 - g0) * t).round().clamp(0, 255),
        (b0 + (b1 - b0) * t).round().clamp(0, 255),
      );
    }
  }
  return const Color(0x00000000);
}

// ── Visual palette preview painter ────────────────────────────────────────────

class _PalettePreviewPainter extends CustomPainter {
  final String palette;
  const _PalettePreviewPainter({required this.palette});

  @override
  void paint(Canvas canvas, Size size) {
    // Checkerboard background
    const sq = 4.0;
    final p1 = Paint()..color = const Color(0xFF888888);
    final p2 = Paint()..color = const Color(0xFFAAAAAA);
    for (double y = 0; y < size.height; y += sq) {
      for (double x = 0; x < size.width; x += sq) {
        final even = ((x / sq).floor() + (y / sq).floor()) % 2 == 0;
        canvas.drawRect(
          Rect.fromLTWH(x, y, math.min(sq, size.width - x), math.min(sq, size.height - y)),
          even ? p1 : p2,
        );
      }
    }
    // Gradient strips (32 steps from v=8 to v=255)
    const steps = 32;
    final sw = size.width / steps;
    for (int s = 0; s < steps; s++) {
      final v = (8 + s * 247 ~/ steps).clamp(0, 255);
      final color = paletteColorAt(v, palette);
      canvas.drawRect(
        Rect.fromLTWH(s * sw, 0, sw + 1, size.height),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_PalettePreviewPainter old) => old.palette != palette;
}

class _BottomBarSettings extends StatefulWidget {
  final TabConfig config;
  final ValueChanged<TabConfig> onSave;
  const _BottomBarSettings({required this.config, required this.onSave});
  @override
  State<_BottomBarSettings> createState() => _BottomBarSettingsState();
}

class _BottomBarSettingsState extends State<_BottomBarSettings> {
  late List<GameTabId> _bottom;
  late List<GameTabId> _overflow;

  // Tabs that must always be in the bottom bar and cannot be moved to overflow.
  static const _kFixed = {GameTabId.map, GameTabId.warehouse};
  // Tabs that should never appear in the configurable list at all.
  static const _kHidden = {GameTabId.leaderboard};

  @override
  void initState() {
    super.initState();
    _bottom = List.of(widget.config.bottomTabs);
    // Ensure fixed tabs are always present
    for (final id in _kFixed) {
      if (!_bottom.contains(id)) _bottom.insert(0, id);
    }
    _overflow = GameTabId.values
        .where((t) => tabMeta.containsKey(t) && !_bottom.contains(t) && !_kHidden.contains(t))
        .toList();
  }

  void _moveToBottom(GameTabId id) {
    setState(() {
      _overflow.remove(id);
      _bottom.add(id);
    });
  }

  void _moveToOverflow(GameTabId id) {
    if (_kFixed.contains(id)) return; // cannot remove fixed tabs
    setState(() {
      _bottom.remove(id);
      _overflow.add(id);
    });
  }

  void _save() {
    final cfg = widget.config.withBottomTabs(_bottom);
    cfg.save();
    widget.onSave(cfg);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(toolbarHeight: 36),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _sectionHeader('Pinned tabs (drag to reorder)'),
        if (_bottom.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No tabs pinned — all appear in More',
                style: TextStyle(color: AppColors.t38)),
          ),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          onReorder: (oldIndex, newIndex) {
            setState(() {
              if (newIndex > oldIndex) newIndex--;
              final item = _bottom.removeAt(oldIndex);
              _bottom.insert(newIndex, item);
            });
          },
          children: [
            for (final id in _bottom)
              ListTile(
                key: ValueKey(id),
                leading: Icon(tabMeta[id]?.icon ?? Icons.circle_outlined,
                    color: _kFixed.contains(id) ? AppColors.accent : AppColors.accent),
                title: Text(tabMeta[id]?.label ?? id.name),
                subtitle: _kFixed.contains(id)
                    ? Text('Required', style: TextStyle(fontSize: 10, color: AppColors.accent))
                    : null,
                trailing: _kFixed.contains(id)
                    ? const Icon(Icons.lock_outline, size: 18, color: Colors.white24)
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.drag_handle, color: AppColors.t38),
                        IconButton(
                          icon: Icon(Icons.arrow_downward, size: 18,
                              color: AppColors.t54),
                          tooltip: 'Remove from bar',
                          onPressed: () => _moveToOverflow(id),
                        ),
                      ]),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _sectionHeader('More / overflow'),
        ..._overflow.map((id) => ListTile(
          leading: Icon(tabMeta[id]?.icon ?? Icons.circle_outlined,
              color: AppColors.t38),
          title: Text(tabMeta[id]?.label ?? id.name),
          trailing: IconButton(
            icon: Icon(Icons.arrow_upward, size: 18, color: AppColors.accent),
            tooltip: 'Pin to bar',
            onPressed: () => _moveToBottom(id),
          ),
        )),
        const SizedBox(height: 8),
        _sectionHeader('Always present'),
        ListTile(
          leading: Icon(Icons.menu, color: AppColors.t38),
          title: const Text('More'),
          subtitle: Text('Profile, settings & overflow',
              style: TextStyle(color: AppColors.t38, fontSize: 11)),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: FilledButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4, left: 4),
    child: Text(title.toUpperCase(),
        style: TextStyle(fontSize: 10, color: AppColors.t38, letterSpacing: 1.1)),
  );
}
