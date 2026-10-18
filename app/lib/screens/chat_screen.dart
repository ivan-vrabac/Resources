import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../services/storage_service.dart';
import '../widgets/top_banner.dart';
import 'profile_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scroll   = ScrollController();
  final _input    = TextEditingController();
  final _focus    = FocusNode();

  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  bool _sending = false;
  int  _lastId  = 0;
  Timer? _pollTimer;

  Set<String> _mutedHids   = {};   // muted player ids (pid), local: no mention alerts
  bool _loadingOlder = false;
  bool _noOlder      = false;

  // @ autocomplete
  bool         _showSuggestions = false;
  String       _mentionQuery    = '';
  List<String> _mentionHints    = [];

  @override
  void initState() {
    super.initState();
    _loadMuteBlock();
    _fetchMessages(initial: true);
    _pollTimer = Timer.periodic(const Duration(seconds: 8), (_) => _fetchMessages());
    _input.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scroll.dispose();
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadMuteBlock() async {
    final m = await StorageService.getMutedHids();
    if (mounted) setState(() => _mutedHids = m);
  }

  Future<void> _fetchMessages({bool initial = false}) async {
    final sid = context.read<PlayerProvider>().sid;
    if (sid.isEmpty) return;
    final r = await GameApi.call('/api/v1/chat/messages', sid,
        {'after': initial ? null : _lastId, 'limit': 50});
    if (!mounted) return;
    if (!r.ok) { if (mounted) setState(() => _loading = false); return; }

    final myName = context.read<PlayerProvider>().player?.name ?? '';
    final newMsgs = r.list('messages');

    bool hasMention = false;
    for (final m in newMsgs) {
      final msg = m['msg'] as String? ?? '';
      if (myName.isNotEmpty && msg.contains('@$myName')) {
        final mPid = m['pid'] as String? ?? '';
        if (!_mutedHids.contains(mPid) && m['isMe'] != true) hasMention = true;
      }
    }

    if (newMsgs.isNotEmpty) {
      final maxId = newMsgs.map((m) => m['id'] as int? ?? 0).reduce((a, b) => a > b ? a : b);
      setState(() {
        if (initial) {
          _messages = newMsgs;
        } else {
          _messages = [..._messages, ...newMsgs];
          // trim to last 200
          if (_messages.length > 200) _messages = _messages.sublist(_messages.length - 200);
        }
        if (maxId > _lastId) _lastId = maxId;
        _loading = false;
        _rebuildHints();
      });
      if (hasMention) context.read<PlayerProvider>().addChatMention();
      context.read<PlayerProvider>().markChatSeen(_lastId);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollBottom());
    } else {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || _noOlder || _messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    final r = await GameApi.call('/api/v1/chat/messages', context.read<PlayerProvider>().sid,
        {'before': _messages.first['id'], 'limit': 50});
    if (!mounted) return;
    final older = r.ok ? r.list('messages') : <Map<String, dynamic>>[];
    setState(() {
      _loadingOlder = false;
      if (older.isEmpty) _noOlder = true;
      _messages = [...older, ..._messages];
      _rebuildHints();
    });
  }

  void _scrollBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  void _rebuildHints() {
    final seen = <String>{};
    _mentionHints = _messages
        .map((m) => m['name'] as String? ?? '')
        .where((n) => n.isNotEmpty && seen.add(n))
        .toList();
  }

  void _onInputChanged() {
    final text   = _input.text;
    final cursor = _input.selection.baseOffset;
    if (cursor < 0) { setState(() => _showSuggestions = false); return; }
    final before = text.substring(0, cursor);
    final atIdx  = before.lastIndexOf('@');
    if (atIdx < 0) { setState(() => _showSuggestions = false); return; }
    final query = before.substring(atIdx + 1);
    if (query.contains(' ')) { setState(() => _showSuggestions = false); return; }
    _mentionQuery = query.toLowerCase();
    setState(() => _showSuggestions = true);
  }

  List<String> get _filteredSuggestions {
    if (_mentionQuery.isEmpty) return _mentionHints.take(5).toList();
    return _mentionHints
        .where((n) => n.toLowerCase().startsWith(_mentionQuery))
        .take(5)
        .toList();
  }

  void _insertMention(String name) {
    final text   = _input.text;
    final cursor = _input.selection.baseOffset.clamp(0, text.length);
    final before = text.substring(0, cursor);
    final atIdx  = before.lastIndexOf('@');
    if (atIdx < 0) return;
    final after    = text.substring(cursor);
    final newText  = '${before.substring(0, atIdx + 1)}$name $after';
    final newPos   = atIdx + 1 + name.length + 1;
    _input.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newPos),
    );
    setState(() => _showSuggestions = false);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    final sid = context.read<PlayerProvider>().sid;
    setState(() => _sending = true);
    _input.clear();
    setState(() => _showSuggestions = false);
    final res = await GameApi.call('/api/v1/chat/send', sid, {'msg': text});
    if (mounted) setState(() => _sending = false);
    if (res.ok) {
      await _fetchMessages();
    } else if (mounted) {
      AppNotify.show(context, res.message ?? 'Failed to send message', isError: true);
      _input.text = text;
    }
  }

  void _showMuteBlockMenu(Map<String, dynamic> msg) {
    final hid  = msg['pid']  as String? ?? '';   // public player id
    final name = msg['name'] as String? ?? '';
    if (hid.isEmpty) return;
    final isMuted   = _mutedHids.contains(hid);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(name,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          ListTile(
            leading: const Icon(Icons.person_outline, color: Colors.tealAccent),
            title: const Text('View profile', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              ProfileScreen.open(context, hid);
            },
          ),
          ListTile(
            leading: Icon(isMuted ? Icons.notifications_active : Icons.notifications_off,
                color: isMuted ? Colors.greenAccent : Colors.orange),
            title: Text(isMuted ? 'Unmute' : 'Mute',
                style: const TextStyle(color: Colors.white)),
            subtitle: Text(isMuted
                ? 'Re-enable mention notifications from this player'
                : 'Suppress mention notifications from this player',
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
            onTap: () async {
              final newSet = Set<String>.from(_mutedHids);
              isMuted ? newSet.remove(hid) : newSet.add(hid);
              await StorageService.saveMutedHids(newSet);
              if (mounted) setState(() => _mutedHids = newSet);
              if (mounted) Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.block, color: Colors.red),
            title: const Text('Block', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Hide all messages from this player (undo in Contacts)',
                style: TextStyle(color: Colors.white54, fontSize: 11)),
            onTap: () async {
              Navigator.pop(context);
              final r = await GameApi.call('/api/v1/social/contact',
                  context.read<PlayerProvider>().sid, {'pid': hid, 'kind': 'blacklist'});
              if (!mounted) return;
              if (r.ok) {
                setState(() => _messages.removeWhere((m) => m['pid'] == hid));
              } else {
                AppNotify.show(context, r.message ?? 'Failed', isError: true);
              }
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  void _showMutedList() {
    final mutedNames = _messages
        .where((m) => _mutedHids.contains(m['pid'] as String? ?? ''))
        .map((m) => (m['pid'] as String, m['name'] as String? ?? ''))
        .toSet()
        .toList();
    final allMuted = {
      ..._mutedHids.map((h) {
        final nm = _messages
            .where((m) => m['pid'] == h)
            .map((m) => m['name'] as String? ?? '')
            .firstOrNull ?? h.substring(0, 8);
        return (h, nm);
      }),
    };

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Muted players',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            if (allMuted.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No muted players', style: TextStyle(color: Colors.white54)))
            else
              ...allMuted.map(((String, String) pair) => ListTile(
                title: Text(pair.$2, style: const TextStyle(color: Colors.white)),
                subtitle: Text(pair.$1.substring(0, 8), style: const TextStyle(color: Colors.white38, fontSize: 10)),
                trailing: TextButton(
                  onPressed: () async {
                    final newSet = Set<String>.from(_mutedHids)..remove(pair.$1);
                    await StorageService.saveMutedHids(newSet);
                    if (mounted) setState(() => _mutedHids = newSet);
                    setSheet(() {});
                  },
                  child: const Text('Unmute', style: TextStyle(color: Colors.greenAccent)),
                ),
              )),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.read<PlayerProvider>().clearChatMentions();
    final myHid = context.read<PlayerProvider>().player?.hid ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D1A),
        title: const Text('Chat', style: TextStyle(color: Colors.white)),
        actions: [
          if (_mutedHids.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.notifications_off, color: Colors.orange),
              tooltip: 'Muted players',
              onPressed: _showMutedList,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _messages.isEmpty
                    ? const Center(
                        child: Text('No messages yet.\nBe the first to say something!',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38, fontSize: 14)))
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        itemCount: _messages.length + 1,
                        itemBuilder: (_, i) => i == 0
                            ? (_noOlder
                                ? const SizedBox(height: 4)
                                : TextButton(
                                    onPressed: _loadingOlder ? null : _loadOlder,
                                    child: Text(_loadingOlder ? 'Loading…' : 'Load older messages')))
                            : _buildMsgTile(_messages[i - 1], myHid),
                      ),
          ),

          // @ suggestions
          if (_showSuggestions && _filteredSuggestions.isNotEmpty)
            Container(
              color: const Color(0xFF1A1A2E),
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView(
                shrinkWrap: true,
                children: _filteredSuggestions.map((name) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.alternate_email, color: Colors.tealAccent, size: 16),
                  title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  onTap: () => _insertMention(name),
                )).toList(),
              ),
            ),

          // Input bar
          Container(
            color: const Color(0xFF12122A),
            padding: EdgeInsets.only(
              left: 12, right: 8, top: 8,
              bottom: MediaQuery.of(context).viewInsets.bottom + 8,
            ),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  maxLength: 500,
                  maxLines: null,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Type a message… use @ to mention',
                    hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                    filled: true,
                    fillColor: const Color(0xFF1E1E3A),
                    counterText: '',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_rounded, color: Colors.tealAccent),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _buildMsgTile(Map<String, dynamic> msg, String myHid) {
    final pid  = msg['pid']  as String? ?? '';
    final name = msg['name'] as String? ?? '';
    final text = msg['msg']  as String? ?? '';
    final ts   = msg['ts']   as String? ?? '';
    final isMe = msg['isMe'] == true;

    String timeStr = '';
    try {
      final dt = DateTime.parse(ts).toLocal();
      final h  = dt.hour.toString().padLeft(2, '0');
      final m  = dt.minute.toString().padLeft(2, '0');
      timeStr  = '$h:$m';
    } catch (_) {}

    return GestureDetector(
      onLongPress: isMe ? null : () => _showMuteBlockMenu(msg),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Avatar
            CircleAvatar(
              radius: 14,
              backgroundColor: isMe ? Colors.teal.shade800 : const Color(0xFF2A2A4A),
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    GestureDetector(
                      onTap: pid.isEmpty ? null : () => ProfileScreen.open(context, pid),
                      child: Text(name,
                          style: TextStyle(
                              color: isMe ? Colors.tealAccent : Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 6),
                    Text(timeStr,
                        style: const TextStyle(color: Colors.white30, fontSize: 10)),
                  ]),
                  const SizedBox(height: 2),
                  _buildRichText(text, context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRichText(String text, BuildContext ctx) {
    final coordRe = RegExp(r'(-?\d{1,3}\.\d{3,6}),\s*(-?\d{1,3}\.\d{3,6})');
    final mentionRe = RegExp(r'@(\w+)');

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    // Merge and sort all matches by position, skip overlaps
    final allMatches = <_MsgSpan>[];
    for (final m in coordRe.allMatches(text)) {
      allMatches.add(_MsgSpan(m.start, m.end, true, m));
    }
    for (final m in mentionRe.allMatches(text)) {
      allMatches.add(_MsgSpan(m.start, m.end, false, m));
    }
    allMatches.sort((a, b) => a.start.compareTo(b.start));

    final filtered = <_MsgSpan>[];
    for (final ms in allMatches) {
      if (filtered.isEmpty || ms.start >= filtered.last.end) {
        filtered.add(ms);
      }
    }

    for (final ms in filtered) {
      if (ms.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, ms.start)));
      }
      if (ms.isCoord) {
        final lat = double.tryParse(ms.match.group(1) ?? '');
        final lng = double.tryParse(ms.match.group(2) ?? '');
        final coordText = text.substring(ms.start, ms.end);
        spans.add(TextSpan(
          text: coordText,
          style: const TextStyle(
              color: Colors.lightBlueAccent,
              decoration: TextDecoration.underline),
          recognizer: TapGestureRecognizer()
            ..onTap = () {
              if (lat != null && lng != null) {
                ctx.read<PlayerProvider>().setChatNavigateTo(LatLng(lat, lng));
                if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
              }
            },
        ));
      } else {
        spans.add(TextSpan(
          text: text.substring(ms.start, ms.end),
          style: const TextStyle(
              color: Colors.amberAccent, fontWeight: FontWeight.bold),
        ));
      }
      lastEnd = ms.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        children: spans,
      ),
    );
  }
}

class _MsgSpan {
  final int start, end;
  final bool isCoord;
  final RegExpMatch match;
  const _MsgSpan(this.start, this.end, this.isCoord, this.match);
}
