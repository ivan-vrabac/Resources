// End-to-end check of the client API against a running dev server. Skipped unless
// API_BASE_URL is passed, e.g.:
//   flutter test test/api_e2e_test.dart --dart-define=API_BASE_URL=http://127.0.0.1:8000
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:resources_game/services/api_service.dart';

const _server = String.fromEnvironment('API_BASE_URL');

void main() {
  final name = 'E2E ${Random().nextInt(1 << 30)}';

  test('register, sign in, fetch player, reject wrong password', () async {
    final created = await ApiService.signIn(name, 'e2e-password');
    expect(created.error, isNull);
    expect(created.created, isTrue);

    final again = await ApiService.signIn(name, 'e2e-password');
    expect(again.hid, created.hid);
    expect(again.created, isFalse);

    final player = await ApiService.getPlayerData(again.sid!);
    expect(player, isNotNull);
    expect(player!.hid, created.hid);

    final wrong = await ApiService.signIn(name, 'not-the-password');
    expect(wrong.sid, isNull);
    expect(wrong.error, isNotNull);
  }, skip: _server.isEmpty ? 'set --dart-define=API_BASE_URL to run' : false);
}
