import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/storage_service.dart';
import '../services/api_service.dart';
import '../services/fcm_service.dart';
import '../services/update_service.dart';
import '../models/player_provider.dart';
import '../constants.dart' show precacheResImages;
import 'login_screen.dart';
import 'game_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    // Decode all resource images while the splash spinner is visible so every
    // tab shows them instantly on first open — runs parallel to the API call.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) precacheResImages(context);
    });
    _init();
  }

  Future<void> _init() async {
    UpdateService.cleanupOldDownloads();       // the update worked: remove its downloaded APK
    // Older installs stored only the player ID; they have no session and must sign in.
    final sid = await StorageService.getSid();
    if (sid == null || sid.isEmpty) {
      _go(const LoginScreen());
      return;
    }
    final player = await ApiService.getPlayerData(sid);
    if (player == null || !mounted) {
      _go(const LoginScreen());
      return;
    }
    context.read<PlayerProvider>().setPlayer(player, sid: sid);
    FcmService.init(context.read<PlayerProvider>().sid);
    _go(const GameScreen());
  }

  void _go(Widget screen) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
