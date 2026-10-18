# Branding and forks

All branding is set at build time from one JSON file passed to Flutter. The same file
drives the Dart code (`lib/branding.dart`) and the Android build (`app/build.gradle.kts`
reads Flutter's `dart-defines`).

```bash
cp app/config/branding.default.json app/config/branding.local.json   # *.local.json is gitignored
flutter build apk --release --dart-define-from-file=config/branding.local.json
```

| Key | Used for | Default |
|---|---|---|
| `APP_NAME` | Android launcher label, notification channel name | `Resources` |
| `APP_TITLE` | In-app title (login screen, task switcher) | = `APP_NAME` |
| `APP_ID` | Android `applicationId`, map tile User-Agent | `com.example.resources` |
| `API_BASE_URL` | Game server URL, no trailing slash | `http://10.0.2.2:8000` |
| `THEME_SEED` | Default accent colour, ARGB hex | `0xFF009688` (teal) |
| `LOGO_ASSET` | Optional image above the login title, e.g. `assets/branding/logo.png` | none |
| `APP_NAME_ALT1`, `APP_NAME_ALT2` | Launcher labels of the alternative icon variants | = `APP_NAME` |

You can also override any key on the Gradle side with `-P` (e.g. `-PAPP_ID=...`).

### Application ID

`com.example.resources` cannot be published to Google Play on purpose: every fork must
choose its own ID (`org.yourname.yourgame`). Changing the ID makes a separate app. It
does not upgrade an existing install, which needs the same ID **and** the same signing
key. The Kotlin namespace (`com.example.resources`) is independent and can stay.

### Icons

| What | Where |
|---|---|
| Default launcher icon | `app/android/app/src/main/res/mipmap-*/ic_launcher*.png` (+ `mipmap-anydpi-v26/ic_launcher.xml`) |
| Alternative launcher icons | `mipmap-*/ic_launcher_alt1.png`, `ic_launcher_alt2.png` |
| In-app previews of the variants | `app/assets/branding/launcher_*.png` |
| Logo | any asset; set `LOGO_ASSET` |

Replace them through `copyrightreplace/` (they are manifest rows) so `validate` keeps working.

## In-app launcher icon selection (Android)

Settings → App → **App Icon** switches between the variants declared as
`<activity-alias>` entries in `AndroidManifest.xml` (`LauncherDefault`, `LauncherAlt1`,
`LauncherAlt2`). What Android does and does not support:

- ✅ Choosing among icons **and labels bundled in the APK** at build time.
- ❌ Arbitrary user-picked images or typed-in names: Android has no API for this.
- ⚠️ Some launchers take a few seconds to refresh, move the icon, or remove a
  home-screen shortcut when the alias changes. Some restart the app.
- ⚠️ The first install after moving from a non-alias build changes the launcher
  component, so existing home-screen shortcuts may need to be re-added.

### Adding a variant

1. Add `mipmap-*/ic_launcher_<name>.png` and `assets/branding/launcher_<name>.png`.
2. Add an `<activity-alias android:name=".Launcher<Name>" android:enabled="false" …>` to
   `AndroidManifest.xml`, copying an existing alias.
3. Add `"<Name>"` to `variants` in `MainActivity.kt` and a `LauncherVariant` to
   `kLauncherVariants` in `lib/services/launcher_icon_service.dart`.
