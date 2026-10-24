import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import '../branding.dart';
import '../models/player.dart';
import '../screens/settings_screen.dart'
    show kNotifEnabled, kNotifMineWarning, kNotifMineDestroyed, kNotifWarehouseFull;

class NotificationService {
  static const bool _serverSendsAlerts = true;
  static const _androidChannel = AndroidNotificationChannel(
    'vresources_game', // channel ID kept stable so existing installs keep their settings
    Branding.appName,
    description: 'Mine and warehouse alerts',
    importance: Importance.defaultImportance,
  );

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    tz.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(_androidChannel);
  }

  static Future<bool> requestPermission() async {
    final impl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await impl?.requestNotificationsPermission() ?? false;
  }

  static Future<void> scheduleMineNotifications(Player player) async {
    if (!_initialized) return;
    await _plugin.cancelAll();
    // owner 2026-10-24: mine and warehouse alerts now come from the server like every other
    // notification (on/off and a daily maximum in Settings › Notifications), so the phone no
    // longer schedules its own copies.
    if (_serverSendsAlerts || !kNotifEnabled) return;

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();

    // ── Mine warning (approaching destruction, ~24% condition) ────────────────
    // Mine timings come pre-aggregated from the server (player.mineStats), using the same
    // rules as before: decay 4%/day = 1/6 per hour, warning at 24%, destruction at 20%.
    final stats = player.mineStats;

    if (kNotifMineWarning) {
      final criticalCount = stats.warnCount;
      DateTime? firstWarningTime;
      if (criticalCount > 0 && stats.warnInH != null) {
        final hoursToWarning = stats.warnInH!;
        firstWarningTime = hoursToWarning <= 0
            ? now.add(const Duration(seconds: 30))
            : now.add(Duration(seconds: (hoursToWarning * 3600).round()));
      }

      if (criticalCount > 0 && firstWarningTime != null) {
        final lastMs = prefs.getInt('notif_last_warn') ?? 0;
        final sinceLastH = now.difference(DateTime.fromMillisecondsSinceEpoch(lastMs)).inHours;
        if (sinceLastH >= 24) {
          final body = criticalCount == 1
              ? '1 mine is approaching destruction. Repair it soon.'
              : '$criticalCount mines are approaching destruction. Repair them soon.';
          await _schedule(id: 1, title: 'Mine Condition Warning', body: body, at: firstWarningTime);
          await prefs.setInt('notif_last_warn', now.millisecondsSinceEpoch);
        }
      }
    }

    // ── Mine destroyed (predicted destruction time) ────────────────────────
    if (kNotifMineDestroyed) {
      final doomedCount = stats.destrCount;
      final DateTime? firstDestrTime = (doomedCount > 0 && stats.destrInH != null)
          ? now.add(Duration(seconds: (stats.destrInH! * 3600).round()))
          : null;

      if (doomedCount > 0 && firstDestrTime != null) {
        final lastMs = prefs.getInt('notif_last_destr') ?? 0;
        final sinceLastH = now.difference(DateTime.fromMillisecondsSinceEpoch(lastMs)).inHours;
        if (sinceLastH >= 24) {
          final body = doomedCount == 1
              ? '1 mine has been destroyed.'
              : '$doomedCount mines have been destroyed.';
          await _schedule(id: 2, title: 'Mine Destroyed', body: body, at: firstDestrTime);
          await prefs.setInt('notif_last_destr', now.millisecondsSinceEpoch);
        }
      }
    }

    // ── Warehouse full ──────────────────────────────────────────────────────
    if (kNotifWarehouseFull) {
      double minHoursToFull = double.infinity;

      // Use global shared capacity: total stored across all items vs whCap
      final totalStored = player.lager.values.fold(0.0, (a, b) => a + b);
      final globalRemaining = player.whCap.toDouble() - totalStored;

      // Same as the old per-mine minimum: the fastest single mine fills it first.
      if (stats.maxRateHr > 0) {
        minHoursToFull = globalRemaining <= 0 ? 0 : globalRemaining / stats.maxRateHr;
      }

      if (minHoursToFull < double.infinity) {
        final lastMs = prefs.getInt('notif_last_wh') ?? 0;
        final sinceLastH = now.difference(DateTime.fromMillisecondsSinceEpoch(lastMs)).inHours;
        if (sinceLastH >= 24) {
          final fullAt = minHoursToFull <= 0
              ? now.add(const Duration(seconds: 30))
              : now.add(Duration(seconds: (minHoursToFull * 3600).round()));
          await _schedule(
            id: 3,
            title: 'Warehouse Full',
            body: 'Warehouse full. Additional production is being lost.',
            at: fullAt,
          );
          await prefs.setInt('notif_last_wh', now.millisecondsSinceEpoch);
        }
      }
    }
  }

  static Future<void> _schedule({
    required int id,
    required String title,
    required String body,
    required DateTime at,
  }) async {
    final tzNow = tz.TZDateTime.now(tz.local);
    final tzAt = tz.TZDateTime.from(at, tz.local);
    final scheduleAt = tzAt.isBefore(tzNow)
        ? tzNow.add(const Duration(seconds: 5))
        : tzAt;

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      scheduleAt,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannel.id,
          _androidChannel.name,
          channelDescription: _androidChannel.description,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}
