import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Branding: read the same values the Dart code sees. Flutter passes every
// --dart-define / --dart-define-from-file entry to Gradle as base64 in "dart-defines".
val dartDefines: Map<String, String> = (project.findProperty("dart-defines") as String?)
    ?.split(",")
    ?.mapNotNull { enc ->
        val kv = String(Base64.getDecoder().decode(enc), Charsets.UTF_8)
        val i = kv.indexOf('=')
        if (i > 0) kv.substring(0, i) to kv.substring(i + 1) else null
    }
    ?.toMap() ?: emptyMap()

fun brand(key: String, default: String): String =
    (project.findProperty(key) as String?) ?: dartDefines[key]?.takeIf { it.isNotBlank() } ?: default

val appId = brand("APP_ID", "com.example.resources")
val appName = brand("APP_NAME", "Resources")

// Release signing: key.properties (gitignored) or RELEASE_* environment variables.
// Without either, release builds fall back to the debug key so forks can build out of the box.
val keyPropsFile = rootProject.file("key.properties")
val keyProps = Properties()
if (keyPropsFile.exists()) {
    keyPropsFile.inputStream().use { keyProps.load(it) }
}
fun signing(key: String, env: String): String? = (keyProps[key] as String?) ?: System.getenv(env)
val releaseStoreFile = signing("storeFile", "RELEASE_STORE_FILE")

android {
    namespace = "com.example.resources"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = appId
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        manifestPlaceholders["appLabel"] = appName
        manifestPlaceholders["appLabelAlt1"] = brand("APP_NAME_ALT1", appName)
        manifestPlaceholders["appLabelAlt2"] = brand("APP_NAME_ALT2", appName)
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storePassword = signing("storePassword", "RELEASE_STORE_PASSWORD")
                keyAlias = signing("keyAlias", "RELEASE_KEY_ALIAS")
                keyPassword = signing("keyPassword", "RELEASE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseStoreFile != null) signingConfigs.getByName("release")
                            else signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
