import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'branding.dart';
import 'models/player_provider.dart';
import 'screens/settings_screen.dart' show loadNumDecimalsPrefs, appThemeNotifier;
import 'screens/splash_screen.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadNumDecimalsPrefs();
  await NotificationService.init();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(
    ChangeNotifierProvider(
      create: (_) => PlayerProvider(),
      child: const ResourcesApp(),
    ),
  );
}

class ResourcesApp extends StatelessWidget {
  const ResourcesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeData>(
      valueListenable: appThemeNotifier,
      builder: (_, theme, __) => MaterialApp(
        title: Branding.appTitle,
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: const SplashScreen(),
      ),
    );
  }
}
