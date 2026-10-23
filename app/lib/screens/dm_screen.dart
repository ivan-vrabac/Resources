import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import '../widgets/top_banner.dart';
import 'profile_screen.dart';

/// Private conversation with one player (by public id). Polls for new messages while open.
class DmScreen extends StatefulWidget {
  final String pid;
  final String name;
  const DmScreen({super.key, required this.pid, required this.name});

  static Future<void> open(BuildContext context, String pid, String name) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DmScreen(pid: pid, name: name)));

  @override
  State<DmScreen> createState() => _DmScreenState();
}

class _DmScreenState extends State<DmScreen> {
  final _ctl = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _msgs = [];
  bool _loading = true, _sending = false;
  String? _error;
  Timer? _poll;

  String get _sid => context.read<PlayerProvider>().sid;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ctl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final r = await GameApi.call('/api/v1/chat/dm/messages', _sid, {'pid': widget.pid});
    if (!mounted) return;
    final grew = r.ok && r.list('messages').length != _msgs.length;
    setState(() {
      _loading = false;
      if (!quiet) _error = r.ok ? null : r.message;
      if (r.ok) _msgs = r.list('messages');
    });
    if (grew) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  Future<void> _send() async {
    final msg = _ctl.text.trim();
    if (msg.isEmpty || _sending) return;
    setState(() => _sending = true);
    final r = await GameApi.call('/api/v1/chat/dm/send', _sid, {'pid': widget.pid, 'msg': msg});
    if (!mounted) return;
    setState(() => _sending = false);
    if (r.ok) {
      _ctl.clear();
      _load(quiet: true);
    } else {
      AppNotify.show(context, r.message ?? 'Could not send', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: Text(widget.name),
        actions: [
          IconButton(
            tooltip: 'View stats',
            icon: const Icon(Icons.query_stats),
            onPressed: () => ProfileScreen.open(context, widget.pid),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: AsyncView(
            loading: _loading,
            error: _error,
            onRetry: _load,
            builder: () => _msgs.isEmpty
                ? const Center(child: Text('No messages yet — say hello!', style: TextStyle(color: Colors.white54)))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    itemCount: _msgs.length,
                    itemBuilder: (_, i) {
                      final m = _msgs[i];
                      final me = m['isMe'] == true;
                      return Align(
                        alignment: me ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: me ? Colors.teal.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(m['msg'] as String),
                            Text((m['ts'] as String).substring(5, 16).replaceFirst('T', ' '),
                                style: const TextStyle(fontSize: 9, color: Colors.white38)),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _ctl,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(isDense: true, hintText: 'Private message', border: OutlineInputBorder()),
                ),
              ),
              IconButton(icon: const Icon(Icons.send), onPressed: _sending ? null : _send),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Your private conversations, newest first, with unread counts.
class DmThreadsScreen extends StatefulWidget {
  /// Inside the Social tab (no app bar of its own).
  final bool embedded;
  const DmThreadsScreen({super.key, this.embedded = false});
  @override
  State<DmThreadsScreen> createState() => _DmThreadsScreenState();
}

class _DmThreadsScreenState extends State<DmThreadsScreen> {
  List<Map<String, dynamic>> _threads = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await GameApi.call('/api/v1/chat/dm/threads', context.read<PlayerProvider>().sid);
    if (!mounted) return;
    setState(() { _loading = false; _error = r.ok ? null : r.message; if (r.ok) _threads = r.list('threads'); });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.embedded ? Colors.transparent : null,
      appBar: widget.embedded ? null : AppBar(toolbarHeight: 40, title: const Text('Private messages')),
      body: AsyncView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        builder: () => RefreshIndicator(
          onRefresh: _load,
          child: _threads.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 80),
                  Center(child: Text('No conversations yet.\nTap a player in Contacts to message them.',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.white54))),
                ])
              : ListView(children: [
                  for (final t in _threads)
                    ListTile(
                      leading: SizedBox(width: 40, height: 40, child: Image.asset(
                          'assets/images/hq_thumb_${((t['hqLevel'] as num?) ?? 1).toInt().clamp(1, 10)}.png',
                          errorBuilder: (_, __, ___) => const Icon(Icons.location_city))),
                      title: Text(t['name'] as String? ?? ''),
                      subtitle: Text('${t['lastFromMe'] == true ? 'You: ' : ''}${t['last']}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: (t['unread'] as num? ?? 0) > 0
                          ? CircleAvatar(radius: 11, backgroundColor: Colors.deepOrange,
                              child: Text('${t['unread']}', style: const TextStyle(fontSize: 11, color: Colors.white)))
                          : null,
                      onTap: () async {
                        await DmScreen.open(context, t['pid'] as String, t['name'] as String? ?? '');
                        if (mounted) _load();
                      },
                    ),
                ]),
        ),
      ),
    );
  }
}
