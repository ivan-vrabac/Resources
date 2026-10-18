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
  final _pwCtrl = TextEditingController();
  bool _loading = false;
  bool _showPw = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    _pwCtrl.dispose();
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
    final password = _pwCtrl.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter a password');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Signs in, or registers the company name if it is still free.
      final res = await ApiService.signIn(name, password);
      if (res.error != null) {
        setState(() {
          _error = res.error;
          _loading = false;
        });
        return;
      }

      await StorageService.saveSession(res.hid!, res.sid!);
      final player = await ApiService.getPlayerData(res.sid!);

      if (!mounted) return;
      if (player != null) {
        context.read<PlayerProvider>().setPlayer(player, sid: res.sid);
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
                'Sign in, or pick a new company name and password to start playing',
                style: TextStyle(color: Colors.white54),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              TextField(
                controller: _ctrl,
                autofocus: true,
                textInputAction: TextInputAction.next,
                maxLength: 20,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: 'Company name',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pwCtrl,
                obscureText: !_showPw,
                textInputAction: TextInputAction.go,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Password (min. 6 characters)',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showPw = !_showPw),
                  ),
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
