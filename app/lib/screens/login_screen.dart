import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../branding.dart';
import '../services/api_service.dart';
import '../services/fcm_service.dart';
import '../services/storage_service.dart';
import '../models/player_provider.dart';
import 'game_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static final _validName = RegExp(r'^[a-zA-Z0-9 .,\[\]()\-]+$');

  Future<void> _submit() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty) return;
    if (name.length > 20) {
      setState(() => _error = 'Name must be 20 characters or less');
      return;
    }
    if (!_validName.hasMatch(name)) {
      setState(() => _error = 'Only letters, digits, spaces and . , [ ] ( ) - allowed');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Try existing account first, register if new
      String? hid = await ApiService.login(name);
      hid ??= await ApiService.register(name);

      if (hid == null || hid.isEmpty) {
        setState(() {
          _error = 'Could not reach the server. Check your connection.';
          _loading = false;
        });
        return;
      }

      await StorageService.saveHid(hid);
      final player = await ApiService.getPlayerData(hid);

      if (!mounted) return;
      if (player != null) {
        context.read<PlayerProvider>().setPlayer(player);
        FcmService.init(context.read<PlayerProvider>().sid);
      }
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const GameScreen()));
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (Branding.logoAsset.isNotEmpty) ...[
                Image.asset(Branding.logoAsset, height: 96),
                const SizedBox(height: 16),
              ],
              Text(
                Branding.appTitle,
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter your company name to play',
                style: TextStyle(color: Colors.white54),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              TextField(
                controller: _ctrl,
                autofocus: true,
                textInputAction: TextInputAction.go,
                maxLength: 20,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: 'Company name',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              if (_error != null) ...[
                Text(_error!,
                    style: const TextStyle(color: Colors.redAccent),
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
              ],
              FilledButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Sign in / Register'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
