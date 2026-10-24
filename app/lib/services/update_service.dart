import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../branding.dart';

/// Information about the newest published build (`<UPDATE_URL>/latest.json`, written by the
/// build script when it publishes an APK).
class BuildInfo {
  final String version;
  final int build;
  final int size;
  final String sha256;
  final String date;
  final String apk;
  final List<String> notes;
  BuildInfo(this.version, this.build, this.size, this.sha256, this.date, this.apk, this.notes);

  factory BuildInfo.fromJson(Map<String, dynamic> j) => BuildInfo(
        j['version'] as String? ?? '?',
        (j['build'] as num? ?? 0).toInt(),
        (j['size'] as num? ?? 0).toInt(),
        j['sha256'] as String? ?? '',
        j['date'] as String? ?? '',
        j['apk'] as String? ?? 'vresources.apk',
        ((j['notes'] as List?) ?? const []).cast<String>(),
      );

  bool get isNewer => build > Branding.buildNumber;
}

/// Checks for, downloads and installs app updates (Android only; needs UPDATE_URL).
class UpdateService {
  static const _ch = MethodChannel('resources/updater');

  static bool get supported =>
      !kIsWeb && Platform.isAndroid && Branding.updateUrl.isNotEmpty;

  static Uri _u(String path) => Uri.parse('${Branding.updateUrl.replaceAll(RegExp(r'/$'), '')}/$path');

  /// The newest published build, or null if it can't be reached.
  static Future<BuildInfo?> latest() async {
    if (!supported) return null;
    try {
      final r = await http.get(_u('latest.json?t=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      return BuildInfo.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Downloads [info]'s APK (reporting 0..1 progress), verifies size and SHA-256, then opens
  /// the system installer. Returns null on success or an error message.
  static Future<String?> downloadAndInstall(BuildInfo info, void Function(double) onProgress) async {
    final client = http.Client();
    try {
      final dir = await _ch.invokeMethod<String>('updateDir');
      if (dir == null) return 'No storage for the download';
      final file = File('$dir/update-${info.build}.apk');
      if (!(await file.exists() && await file.length() == info.size)) {
        final resp = await client.send(http.Request('GET', _u('${info.apk}?b=${info.build}')));
        if (resp.statusCode != 200) return 'Download failed (${resp.statusCode})';
        final total = resp.contentLength ?? info.size;
        final sink = file.openWrite();
        var got = 0;
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress(got / total);
        }
        await sink.close();
      }
      onProgress(1);
      if (info.size > 0 && await file.length() != info.size) {
        await file.delete();
        return 'The download was incomplete — please try again';
      }
      if (info.sha256.isNotEmpty) {
        final digest = await sha256.bind(file.openRead()).first;
        if (digest.toString() != info.sha256.toLowerCase()) {
          await file.delete();
          return 'The download is corrupted — please try again';
        }
      }
      final res = await _ch.invokeMethod<String>('install', {'path': file.path});
      if (res == 'permission') {
        return 'Allow "Install unknown apps" for this app, then tap Install again';
      }
      return res == 'started' ? null : 'Could not start the installer';
    } catch (e) {
      return 'Update failed: $e';
    } finally {
      client.close();
    }
  }

  /// After a successful update (the new version is running), delete the downloaded APKs of this
  /// build and older ones (owner 2026-10-24). A newer one that is not installed yet is kept.
  static Future<void> cleanupOldDownloads() async {
    if (!supported) return;
    try {
      final dir = await _ch.invokeMethod<String>('updateDir');
      if (dir == null) return;
      await for (final f in Directory(dir).list()) {
        final m = RegExp(r'update-(\d+)\.apk$').firstMatch(f.path);
        if (f is File && m != null && int.parse(m.group(1)!) <= Branding.buildNumber) {
          await f.delete();
        }
      }
    } catch (_) {}
  }
  static String fmtSize(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
