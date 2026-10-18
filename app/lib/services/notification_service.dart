import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import '../branding.dart';
import '../models/player.dart';
import '../screens/settings_screen.dart'
    show kNotifEnabled, kNotifMineWarning, kNotifMineDestroyed, kNotifWarehouseFull;

class NotificationService {
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
    if (!kNotifEnabled) return;

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();

    // ── Mine warning (approaching destruction, ~24% condition) ────────────────
    if (kNotifMineWarning) {
      final List<int> criticalMines = [];
      DateTime? firstWarningTime;

      for (final mine in player.mines) {
        if (mine.condition <= 20 || mine.condition > 100) continue;
        // Destruction at condition = 20; decay 4%/day = 1/6 per hour
        // Warning fires when condition hits 24% → (condition-24)*6 hours from now
        final hoursToWarning = (mine.condition - 24) * 6.0;
        if (hoursToWarning > 72) continue; // only look 72h ahead
        criticalMines.add(mine.itemId);
        final warnAt = hoursToWarning <= 0
            ? now.add(const Duration(seconds: 30))
            : now.add(Duration(seconds: (hoursToWarning * 3600).round()));
        if (firstWarningTime == null || warnAt.isBefore(firstWarningTime)) {
          firstWarningTime = warnAt;
        }
      }

      if (criticalMines.isNotEmpty && firstWarningTime != null) {
        final lastMs = prefs.getInt('notif_last_warn') ?? 0;
        final sinceLastH = now.difference(DateTime.fromMillisecondsSinceEpoch(lastMs)).inHours;
        if (sinceLastH >= 24) {
          final body = criticalMines.length == 1
              ? '1 mine is approaching destruction. Repair it soon.'
              : '${criticalMines.length} mines are approaching destruction. Repair them soon.';
          await _schedule(id: 1, title: 'Mine Condition Warning', body: body, at: firstWarningTime);
          await prefs.setInt('notif_last_warn', now.millisecondsSinceEpoch);
        }
      }
    }

    // ── Mine destroyed (predicted destruction time) ────────────────────────
    if (kNotifMineDestroyed) {
      final List<int> doomed = [];
      DateTime? firstDestrTime;

      for (final mine in player.mines) {
        if (mine.condition <= 20 || mine.condition > 100) continue;
        final hoursToDestr = (mine.condition - 20) * 6.0;
        if (hoursToDestr > 24 * 14) continue; // look 14 days ahead
        doomed.add(mine.itemId);
        final destrAt = now.add(Duration(seconds: (hoursToDestr * 3600).round()));
        if (firstDestrTime == null || destrAt.isBefore(firstDestrTime)) {
          firstDestrTime = destrAt;
        }
      }

      if (doomed.isNotEmpty && firstDestrTime != null) {
        final lastMs = prefs.getInt('notif_last_destr') ?? 0;
        final sinceLastH = now.difference(DateTime.fromMillisecondsSinceEpoch(lastMs)).inHours;
        if (sinceLastH >= 24) {
          final body = doomed.length == 1
              ? '1 mine has been destroyed.'
              : '${doomed.length} mines have been destroyed.';
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

      for (final mine in player.mines) {
        if (mine.rateHr <= 0) continue;
        if (globalRemaining <= 0) {
          minHoursToFull = 0;
          break;
        }
        final h = globalRemaining / mine.rateHr;
        if (h < minHoursToFull) minHoursToFull = h;
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
