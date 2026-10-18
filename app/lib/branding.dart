import 'package:flutter/material.dart';

/// Build-time branding. Values come from `--dart-define-from-file=config/<file>.json`
/// (see docs/BRANDING.md). The same JSON also drives the Android application ID and
/// launcher labels via android/app/build.gradle.kts.
class Branding {
  Branding._();

  /// Launcher label and default in-app title.
  static const appName = String.fromEnvironment('APP_NAME', defaultValue: 'Resources');

  /// Title shown inside the app (login screen, task switcher). Defaults to [appName].
  static const _appTitle = String.fromEnvironment('APP_TITLE');
  static String get appTitle => _appTitle.isEmpty ? appName : _appTitle;

  /// Android application ID; also sent as the map tile User-Agent package name.
  static const appId = String.fromEnvironment('APP_ID', defaultValue: 'com.example.resources');

  /// Game server base URL, no trailing slash. 10.0.2.2 is the host machine from the Android emulator.
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8000');

  /// Default accent colour (ARGB hex, e.g. "0xFF009688"). Players can still change it in Settings.
  static const _themeSeed = String.fromEnvironment('THEME_SEED', defaultValue: '0xFF009688');
  static Color get themeSeed => Color(int.tryParse(_themeSeed) ?? 0xFF009688);

  /// Optional logo asset shown above the title on the login screen. Empty = no logo.
  static const logoAsset = String.fromEnvironment('LOGO_ASSET');
}
