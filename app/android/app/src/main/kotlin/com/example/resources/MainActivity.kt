package com.example.resources

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Must match the <activity-alias> names in AndroidManifest.xml.
    private val variants = listOf("Default", "Alt1", "Alt2")

    private fun alias(id: String) =
        ComponentName(packageName, "${MainActivity::class.java.`package`!!.name}.Launcher$id")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "resources/launcher_icon")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "current" -> result.success(current())
                    "select" -> {
                        val id = call.argument<String>("id")
                        if (id == null || id !in variants) result.success(false)
                        else result.success(select(id))
                    }
                    else -> result.notImplemented()
                }
            }
        // In-app updates: Dart downloads the APK into updateDir, then asks us to install it.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "resources/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "updateDir" -> result.success(File(cacheDir, "updates").apply { mkdirs() }.absolutePath)
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) result.success("error") else result.success(install(File(path)))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** "started", or "permission" when the user must first allow installs from this app. */
    private fun install(apk: File): String {
        if (!apk.exists()) return "error"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
            return "permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        })
        return "started"
    }

    private fun isEnabled(id: String): Boolean {
        val state = packageManager.getComponentEnabledSetting(alias(id))
        return when (state) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
            else -> id == "Default" // manifest default
        }
    }

    private fun current(): String = variants.firstOrNull { isEnabled(it) } ?: "Default"

    private fun select(id: String): Boolean = try {
        // Enable the new alias first so the app always has a launcher entry.
        packageManager.setComponentEnabledSetting(alias(id),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
        for (other in variants) if (other != id) {
            packageManager.setComponentEnabledSetting(alias(other),
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
        }
        true
    } catch (e: Exception) {
        false
    }
}
