import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resources_game/branding.dart';
import 'package:resources_game/constants.dart';
import 'package:resources_game/services/launcher_icon_service.dart';

void main() {
  test('branding defaults are generic', () {
    // Run without --dart-define, so these are the public defaults.
    expect(Branding.appName, 'Resources');
    expect(Branding.appTitle, 'Resources');
    expect(Branding.appId, 'com.example.resources');
    expect(kBaseUrl, Branding.apiBaseUrl);
    expect(Branding.apiBaseUrl, 'http://10.0.2.2:8000');
  });

  test('launcher variant previews exist', () {
    for (final v in kLauncherVariants) {
      expect(File(v.asset).existsSync(), isTrue, reason: v.asset);
    }
  });

  test('every resource image path resolves to a bundled file', () {
    var checked = 0;
    for (final id in kItemNames.keys) {
      final path = resImagePath(id);
      if (path == null) continue;
      for (final variant in ['', '2x/', '3x/']) {
        final p = path.replaceFirst('images_res/', 'images_res/$variant');
        expect(File(p).existsSync(), isTrue, reason: p);
      }
      checked++;
    }
    expect(checked, greaterThan(0));
  });

  test('HQ level thumbnails exist for levels 1-10', () {
    for (var lvl = 1; lvl <= 10; lvl++) {
      expect(File('assets/images/hq_thumb_$lvl.png').existsSync(), isTrue);
    }
  });
}
