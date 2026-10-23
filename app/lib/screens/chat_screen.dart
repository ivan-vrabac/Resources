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
import 'dm_screen.dart';
import 'profile_screen.dart';

import '../app_colors.dart';
class ChatScreen extends StatefulWidget {
  /// Inside the Social tab (no app bar of its own).
  final bool embedded;
  const ChatScreen({super.key, this.embedded = false});
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
  List<String> _rules = const [];   // chat rules from the server (shown on top)
  int _maxLen = 300;

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
    if (r.data['rules'] is List) _rules = (r.data['rules'] as List).cast<String>();
    _maxLen = (r.data['maxLength'] as num? ?? _maxLen).toInt();

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

  /// Long-press on a message: add "@name " to your message.
  void _mention(String name) {
    if (name.isEmpty) return;
    final t = _input.text;
    final add = '${t.isEmpty || t.endsWith(' ') ? '' : ' '}@$name ';
    _input.value = TextEditingValue(text: t + add, selection: TextSelection.collapsed(offset: (t + add).length));
    _focus.requestFocus();
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
    final sid = context.read<PlayerProvider>().sid;
    GameApi.call('/api/v1/chat/dm/threads', sid).then((th) {
      if (!mounted) return;
      final unread = th.ok
          ? (th.list('threads').firstWhere((t) => t['pid'] == hid, orElse: () => const {})['unread'] as num? ?? 0).toInt()
          : 0;
      _openPlayerSheet(hid, name, isMuted, unread);
    });
  }

  void _openPlayerSheet(String hid, String name, bool isMuted, int unread) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(name,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          ListTile(
            leading: Icon(Icons.query_stats, color: AppColors.accent),
            title: const Text('View stats', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              ProfileScreen.open(context, hid);
            },
          ),
          ListTile(
            leading: Icon(Icons.mail_outline, color: AppColors.accent),
            title: const Text('Private messages', style: TextStyle(color: Colors.white)),
            trailing: unread > 0
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: Colors.deepOrange, borderRadius: BorderRadius.circular(10)),
                    child: Text('$unread new', style: const TextStyle(color: Colors.white, fontSize: 12)),
                  )
                : null,
            onTap: () {
              Navigator.pop(context);
              DmScreen.open(context, hid, name);
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
                style: TextStyle(color: AppColors.t54, fontSize: 11)),
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
            subtitle: Text('Hide all messages from this player (undo in Contacts)',
                style: TextStyle(color: AppColors.t54, fontSize: 11)),
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
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Muted players',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            if (allMuted.isEmpty)
              Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No muted players', style: TextStyle(color: AppColors.t54)))
            else
              ...allMuted.map(((String, String) pair) => ListTile(
                title: Text(pair.$2, style: const TextStyle(color: Colors.white)),
                subtitle: Text(pair.$1.substring(0, 8), style: TextStyle(color: AppColors.t38, fontSize: 10)),
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

    // same colour as the bottom bar; no title (it's obviously the chat) — only a slim bar for
    // the back button (opened from More) or the muted-players list
    final bg = Theme.of(context).colorScheme.surface;
    final showBar = !widget.embedded && (ModalRoute.of(context)?.canPop == true || _mutedHids.isNotEmpty);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: bg,
      appBar: !showBar ? null : AppBar(
        backgroundColor: bg,
        toolbarHeight: 36,
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
          // chat rules (from the server)
          if (_rules.isNotEmpty)
            Container(
              width: double.infinity,
              color: cs.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                Icon(Icons.gavel, size: 14, color: cs.primary),
                const SizedBox(width: 6),
                Expanded(child: Text(_rules.join(' · '), style: TextStyle(fontSize: 11, color: AppColors.t70))),
                if (widget.embedded && _mutedHids.isNotEmpty)
                  InkWell(onTap: _showMutedList,
                      child: const Icon(Icons.notifications_off, size: 16, color: Colors.orange)),
              ]),
            ),
          // Messages
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _messages.isEmpty
                    ? Center(
                        child: Text('No messages yet.\nBe the first to say something!',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.t38, fontSize: 14)))
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) => _buildMsgTile(_messages[i], myHid),
                      ),
          ),

          // @ suggestions
          if (_showSuggestions && _filteredSuggestions.isNotEmpty)
            Container(
              color: cs.surfaceContainerHigh,
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView(
                shrinkWrap: true,
                children: _filteredSuggestions.map((name) => ListTile(
                  dense: true,
                  leading: Icon(Icons.alternate_email, color: AppColors.accent, size: 16),
                  title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  onTap: () => _insertMention(name),
                )).toList(),
              ),
            ),

          // Input bar
          Container(
            color: cs.surface,
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
                  maxLength: _maxLen,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Type a message… use @ to mention',
                    hintStyle: TextStyle(color: AppColors.t38, fontSize: 13),
                    filled: true,
                    fillColor: cs.surfaceContainerHighest,
                    // show what's left only near the limit, so the bar never jumps
                    counterText: _input.text.length > _maxLen * 0.8 ? '${_maxLen - _input.text.length}' : '',
                    counterStyle: TextStyle(fontSize: 10, color: AppColors.t38),
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
                    : Icon(Icons.send_rounded, color: cs.primary),
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
    final cs = Theme.of(context).colorScheme;

    String timeStr = '';
    try {
      final dt = DateTime.parse(ts).toLocal();
      final h  = dt.hour.toString().padLeft(2, '0');
      final m  = dt.minute.toString().padLeft(2, '0');
      timeStr  = '$h:$m';
    } catch (_) {}

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: pid.isEmpty ? null : () => ProfileScreen.open(context, pid),
      onLongPress: isMe ? null : () => _mention(name),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  // every message has an outline; yours are highlighted
                  color: isMe ? cs.primary.withValues(alpha: 0.18) : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: isMe ? cs.primary : cs.outline.withValues(alpha: 0.6),
                      width: isMe ? 1.5 : 1),
                ),
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    GestureDetector(
                      onTap: isMe ? null : () => _showMuteBlockMenu(msg),
                      child: Text(name,
                          style: TextStyle(
                              color: isMe ? cs.primary : cs.onSurface.withValues(alpha: 0.8),
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
        style: TextStyle(color: AppColors.t70, fontSize: 13, height: 1.4),
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
