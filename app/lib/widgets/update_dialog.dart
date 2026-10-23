import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../branding.dart';
import '../services/update_service.dart';

import '../app_colors.dart';
import 'popups.dart';
/// Shows the installed and the newest published build, and downloads + installs the update.
class UpdateDialog extends StatefulWidget {
  final BuildInfo? info;
  const UpdateDialog({super.key, this.info});

  /// Settings > Updates: always opens (checks first).
  static Future<void> open(BuildContext context) =>
      showDialog(context: context, builder: (_) => const UpdateDialog());

  /// At startup: quietly checks once per launch and only offers builds the player
  /// hasn't dismissed yet.
  static Future<void> checkOnStart(BuildContext context) async {
    if (!UpdateService.supported) return;
    final info = await UpdateService.latest();
    if (info == null || !info.isNewer || !context.mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt('update_dismissed_build') == info.build || !context.mounted) return;
    final later = await showDialog<bool>(context: context, builder: (_) => UpdateDialog(info: info));
    if (later == true) await prefs.setInt('update_dismissed_build', info.build);
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  BuildInfo? _info;
  bool _checking = true;
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.info != null) {
      _info = widget.info;
      _checking = false;
    } else {
      UpdateService.latest().then((i) {
        if (mounted) setState(() { _info = i; _checking = false; if (i == null) _error = 'Could not reach the update server'; });
      });
    }
  }

  Future<void> _install() async {
    setState(() { _progress = 0; _error = null; });
    final err = await UpdateService.downloadAndInstall(_info!, (p) { if (mounted) setState(() => _progress = p); });
    if (!mounted) return;
    setState(() { _progress = null; _error = err; });
  }

  @override
  Widget build(BuildContext context) {
    final i = _info;
    final newer = i != null && i.isNewer;
    return AlertDialog(
      title: Text(newer ? 'Update available' : 'App updates'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Installed: ${Branding.buildName} (build ${Branding.buildNumber})'),
          if (_checking) const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())),
          if (i != null) ...[
            Text('Latest: ${i.version} (build ${i.build})'),
            Text('Published ${i.date.replaceFirst('T', ' ').split('.').first} · ${UpdateService.fmtSize(i.size)}',
                style: TextStyle(color: AppColors.t54, fontSize: 12)),
            if (!newer)
              const Padding(padding: EdgeInsets.only(top: 8),
                  child: Text('You have the latest version.', style: TextStyle(color: Colors.greenAccent))),
            if (newer && i.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text("What's new", style: TextStyle(color: AppColors.t54, fontSize: 12)),
              for (final n in i.notes.take(12)) Text('• $n', style: const TextStyle(fontSize: 13)),
            ],
          ],
          if (_progress != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: _progress),
            Text('${((_progress ?? 0) * 100).round()}% of ${UpdateService.fmtSize(i?.size ?? 0)}',
                style: TextStyle(fontSize: 12, color: AppColors.t54)),
          ],
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.orangeAccent))),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: _progress != null ? null : () => popIfCurrent(context, true),
          child: Text(newer ? 'Later' : 'Close'),
        ),
        if (newer)
          FilledButton.icon(
            icon: const Icon(Icons.system_update),
            label: const Text('Download & install'),
            onPressed: _progress != null ? null : _install,
          ),
      ],
    );
  }
}
