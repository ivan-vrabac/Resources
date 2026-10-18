# Push notifications (optional)

Without Firebase the app still shows local notifications (scheduled on-device). Server
push via Firebase Cloud Messaging is optional and disabled by default.

## Server

1. In the Firebase console create a project and a service account with the
   "Firebase Cloud Messaging API" role. Download its JSON key.
2. Save it as `deploy/secrets/firebase-service-account.json`. `deploy/secrets/` is
   gitignored, so never commit this file.
3. In `deploy/.env` set:
   ```
   FIREBASE_PROJECT_ID=your-project-id
   GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/firebase_sa
   ```
4. Uncomment the `secrets:` blocks in `deploy/docker-compose.yml` and restart.

## App

Follow the checklist at the top of `app/lib/services/fcm_service.dart`: register an
Android app with your `APP_ID`, put `google-services.json` in `app/android/app/`
(gitignored), add the Google Services Gradle plugin, and enable the Firebase packages.
