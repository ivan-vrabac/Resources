import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../branding.dart';
import '../services/api_service.dart';
import '../services/fcm_service.dart';
import '../services/storage_service.dart';
import '../models/player_provider.dart';
import 'game_screen.dart';

import '../app_colors.dart';
import '../widgets/top_banner.dart';
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _ctrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _pw2Ctrl = TextEditingController();
  bool _register = false;
  bool _loading = false;
  bool _showPw = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    _pwCtrl.dispose();
    _pw2Ctrl.dispose();
    super.dispose();
  }

  static final _validName = RegExp(r'^[a-zA-Z0-9 .,\[\]()\-]+$');

  void _setMode(bool register) => setState(() {
    _register = register;
    _error = null;
  });

  Future<void> _submit() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter your company name');
      return;
    }
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
    if (_register) {
      if (password.length < 6) {
        setState(() => _error = 'Password must be at least 6 characters');
        return;
      }
      if (password != _pw2Ctrl.text) {
        setState(() => _error = 'Passwords do not match');
        return;
      }
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final res = await ApiService.signIn(name, password, register: _register);
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
      if (res.deletionCancelled) {
        AppNotify.show(context, 'Welcome back! The deletion of your company was cancelled.');
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

  Widget _passwordField(TextEditingController c, String label, TextInputAction action) =>
      TextField(
        controller: c,
        obscureText: !_showPw,
        textInputAction: action,
        autofillHints: [_register ? AutofillHints.newPassword : AutofillHints.password],
        onSubmitted: action == TextInputAction.go ? (_) => _submit() : null,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _showPw = !_showPw),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: AutofillGroup(
              child: Column(
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
                  const SizedBox(height: 32),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Log in'), icon: Icon(Icons.login)),
                      ButtonSegment(value: true, label: Text('Register'), icon: Icon(Icons.person_add)),
                    ],
                    selected: {_register},
                    onSelectionChanged: _loading ? null : (s) => _setMode(s.first),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _register
                        ? 'Pick a company name and a password to start playing.'
                        : 'Playing since before passwords? Log in with your company name '
                          'and choose a password now — it will protect your account.',
                    style: TextStyle(color: AppColors.t54, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _ctrl,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    maxLength: 20,
                    autofillHints: [_register ? AutofillHints.newUsername : AutofillHints.username],
                    decoration: const InputDecoration(
                      labelText: 'Company name',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _passwordField(_pwCtrl,
                      _register ? 'Password (min. 6 characters)' : 'Password',
                      _register ? TextInputAction.next : TextInputAction.go),
                  if (_register) ...[
                    const SizedBox(height: 12),
                    _passwordField(_pw2Ctrl, 'Repeat password', TextInputAction.go),
                  ],
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
                        : Text(_register ? 'Create account' : 'Log in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
