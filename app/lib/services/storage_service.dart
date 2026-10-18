import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const _keyHid            = 'hid';
  static const _keySid            = 'sid';
  static const _keyMuted          = 'chat_muted_hids';
  static const _keyBlocked        = 'chat_blocked_hids';
  static const _keyCloudOpacity   = 'res_cloud_opacity';

  static Future<double> getCloudOpacity() async {
    final p = await SharedPreferences.getInstance();
    return (p.getDouble(_keyCloudOpacity) ?? 0.35).clamp(0.10, 0.90);
  }

  static Future<void> saveCloudOpacity(double v) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_keyCloudOpacity, v.clamp(0.10, 0.90));
  }

  /// Server-signed session token (see server/auth.py).
  static Future<String?> getSid() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_keySid);
  }

  static Future<void> saveSession(String hid, String sid) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyHid, hid);
    await p.setString(_keySid, sid);
  }

  /// Signs out: forgets both the player ID and the session.
  static Future<void> clearHid() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_keyHid);
    await p.remove(_keySid);
  }

  static Future<Set<String>> getMutedHids() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_keyMuted) ?? []).toSet();
  }

  static Future<void> saveMutedHids(Set<String> hids) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_keyMuted, hids.toList());
  }

  static Future<Set<String>> getBlockedHids() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_keyBlocked) ?? []).toSet();
  }

  static Future<void> saveBlockedHids(Set<String> hids) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_keyBlocked, hids.toList());
  }
}
