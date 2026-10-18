// FCM Service — Firebase Cloud Messaging integration.
//
// BLOCKED: This file requires Firebase setup before it can be activated.
//
// ═══════════════════════════════════════════════════════════════════
// SETUP CHECKLIST (do once, in order)
// ═══════════════════════════════════════════════════════════════════
// 1. Create a Firebase project at https://console.firebase.google.com/
//    • Add an Android app with your APP_ID (see config/branding.json)
//    • Download google-services.json → save to app/android/app/ (gitignored)
//
// 2. Add Google Services plugin to app/android/settings.gradle.kts:
//    In the `plugins` block, add:
//      id("com.google.gms.google-services") version "4.4.2" apply false
//
// 3. Apply plugin in app/android/app/build.gradle.kts:
//    In the `plugins` block, add:
//      id("com.google.gms.google-services")
//
// 4. Uncomment firebase packages in pubspec.yaml:
//      firebase_core: ^3.6.0
//      firebase_messaging: ^15.1.3
//    Then run: flutter pub get
//
// 5. Uncomment the AndroidManifest service entry (see below).
//
// 6. Set FIREBASE_PROJECT_ID and mount the service-account JSON as described
//    in docs/FIREBASE.md, then: docker compose up -d --build (from deploy/)
//
// 7. In main.dart, replace the FcmService stub call with the real one:
//      await FcmService.init(sid);
// ═══════════════════════════════════════════════════════════════════
//
// AndroidManifest.xml addition (android/app/src/main/AndroidManifest.xml)
// Add inside <application>:
//   <service
//     android:name="com.google.firebase.messaging.FirebaseMessagingService"
//     android:exported="false">
//     <intent-filter>
//       <action android:name="com.google.firebase.MESSAGING_EVENT"/>
//     </intent-filter>
//   </service>
//
// ═══════════════════════════════════════════════════════════════════

// ignore_for_file: unused_import
// Remove these comments and activate by following the checklist above.

/*  ← REMOVE THIS LINE after setup

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'api_service.dart';

/// Called when a notification arrives while the app is fully closed (background isolate).
@pragma('vm:entry-point')
Future<void> _fcmBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // flutter_local_notifications is not available in background isolates,
  // but FCM will display the notification automatically via the system tray
  // when the message contains a `notification` payload.
}

class FcmService {
  static final _localNotif = FlutterLocalNotificationsPlugin();
  static const _channelId = 'warehouse_alerts';
  static const _channelName = 'Warehouse Alerts';

  /// Call once at app startup, after the player SID is known.
  static Future<void> init(String sid) async {
    await Firebase.initializeApp();

    // Register background handler.
    FirebaseMessaging.onBackgroundMessage(_fcmBackgroundHandler);

    // Request Android notification permission (Android 13+).
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // Set up local notifications channel for foreground messages.
    const androidChannel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: 'Warehouse capacity and mine condition alerts',
      importance: Importance.high,
    );
    await _localNotif
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);

    await _localNotif.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    // Display foreground notifications manually.
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final n = message.notification;
      if (n == null) return;
      _localNotif.show(
        message.hashCode,
        n.title,
        n.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    });

    // Register/refresh token with the server.
    await _registerToken(sid);

    // Re-register if the token is rotated by FCM.
    FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      ApiService.registerFcmToken(sid, token);
    });
  }

  static Future<void> _registerToken(String sid) async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null && sid.isNotEmpty) {
      await ApiService.registerFcmToken(sid, token);
    }
  }
}

*/  // ← REMOVE THIS LINE after setup

/// Stub used before Firebase is activated.
/// Replace with the real FcmService.init(sid) call after completing the setup checklist.
class FcmService {
  static Future<void> init(String sid) async {
    // No-op until Firebase credentials are provided.
  }
}
