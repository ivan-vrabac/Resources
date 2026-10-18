import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// A launcher icon/label variant that is prepackaged in the APK as an
/// `<activity-alias>` (see android/app/src/main/AndroidManifest.xml).
/// Android cannot set arbitrary icons or names at runtime; it can only switch
/// between components declared at build time.
class LauncherVariant {
  final String id;    // matches the alias suffix: .Launcher<Id>
  final String label; // shown in the picker
  final String asset; // preview image inside the app bundle
  const LauncherVariant(this.id, this.label, this.asset);
}

const kLauncherVariants = <LauncherVariant>[
  LauncherVariant('Default', 'Default', 'assets/branding/launcher_default.png'),
  LauncherVariant('Alt1', 'Alternative 1', 'assets/branding/launcher_alt1.png'),
  LauncherVariant('Alt2', 'Alternative 2', 'assets/branding/launcher_alt2.png'),
];

class LauncherIconService {
  static const _channel = MethodChannel('resources/launcher_icon');

  static bool get supported => Platform.isAndroid;

  static Future<String> current() async {
    if (!supported) return 'Default';
    try {
      return await _channel.invokeMethod<String>('current') ?? 'Default';
    } on PlatformException {
      return 'Default';
    }
  }

  /// Enables the chosen alias and disables the others. Some launchers take a few
  /// seconds to refresh, and some restart the app when the icon changes.
  static Future<bool> select(String id) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('select', {'id': id}) ?? false;
    } on PlatformException {
      return false;
    }
  }
}
