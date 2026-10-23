import 'package:flutter/material.dart';

/// Colours picked in Settings › App Appearance (null = default). Screens use these instead of
/// fixed colours, so the choice reaches every screen (owner 2026-10-23).
class AppColors {
  static Color? text;        // text colour, default white
  static Color? icon;        // icons, symbols, buttons and highlights
  static Color? background;  // backgrounds and panels

  static const Color defaultBackground = Colors.blueGrey;
  static const Color defaultIcon = Colors.tealAccent;

  static Color get fg => text ?? Colors.white;
  static Color get t38 => fg.withValues(alpha: 0.45);
  static Color get t54 => fg.withValues(alpha: 0.60);
  static Color get t60 => fg.withValues(alpha: 0.66);
  static Color get t70 => fg.withValues(alpha: 0.76);
  static Color get accent => icon ?? defaultIcon;
  static Color get accentDark => Color.lerp(accent, Colors.black, 0.45)!;
  static Color get accentDeep => Color.lerp(accent, Colors.black, 0.65)!;
  static Color get bg => background ?? defaultBackground;
  static bool get isBlack => bg.toARGB32() == 0xFF000000;
}
