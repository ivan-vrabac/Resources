import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import 'dm_screen.dart';
import 'profile_screen.dart';

import '../app_colors.dart';
import '../widgets/popups.dart';
/// Friends, enemies, blacklist and watchlist, plus player search.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> with SingleTickerProviderStateMixin {
  static const _tabs = [
    ('friend', 'Friends', Icons.people_alt_outlined),
    ('enemy', 'Enemies', Icons.gpp_bad_outlined),
    ('watch', 'Watchlist', Icons.visibility_outlined),
    ('blacklist', 'Blocked', Icons.block),
  ];
  late final TabController _tc = TabController(length: _tabs.length, vsync: this);
  final _search = TextEditingController();
  Timer? _debounce;
  Map<String, List<Map<String, dynamic>>> _contacts = {};
  List<Map<String, dynamic>>? _results;
  bool _loading = true;
  String? _error;
  int _unreadDm = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tc.dispose();
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  String get _sid => context.read<PlayerProvider>().sid;

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final r = await GameApi.call('/api/v1/social/contacts', _sid);
    final dm = await GameApi.call('/api/v1/chat/dm/threads', _sid);
    if (dm.ok) _unreadDm = (dm.data['unread'] as num? ?? 0).toInt();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r.ok) {
        final c = r.get<Map<String, dynamic>>('contacts') ?? {};
        _contacts = {for (final e in c.entries) e.key: (e.value as List).cast<Map<String, dynamic>>()};
      } else {
        _error = r.message;
      }
    });
  }

  void _onSearch(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final r = await GameApi.call('/api/v1/social/search', _sid, {'q': q.trim()});
      if (mounted && r.ok) setState(() => _results = r.list('players'));
    });
  }

  /// The player's HQ picture (their level), with a dot when they sent you unread messages.
  Widget _hqAvatar(Map<String, dynamic> p) {
    final lvl = ((p['hqLevel'] as num?) ?? 0).toInt().clamp(1, 10);
    final unread = (p['unread'] as num? ?? 0).toInt();
    return SizedBox(
      width: 44, height: 44,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(child: Image.asset('assets/images/hq_thumb_$lvl.png', fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Icon(Icons.location_city, size: 32, color: AppColors.t54))),
        if (unread > 0)
          Positioned(
            right: -4, top: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(color: Colors.deepOrange, borderRadius: BorderRadius.circular(9)),
              child: Text('$unread', style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
      ]),
    );
  }

  Widget _playerTile(Map<String, dynamic> p, {String? subtitle}) => ListTile(
        leading: _hqAvatar(p),
        title: Text(p['name'] as String? ?? ''),
        subtitle: Text(subtitle ?? 'Level ${p['level']} · HQ ${p['hqLevel']}',
            style: TextStyle(color: AppColors.t54, fontSize: 12)),
        trailing: Icon(Icons.chevron_right, color: AppColors.t38),
        onTap: () => _playerActions(p),
      );

  /// Tap on a player: view their stats or send a private message.
  Future<void> _playerActions(Map<String, dynamic> p) async {
    final pid = p['pid'] as String, name = p['name'] as String? ?? '';
    final pick = await showAppSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold))),
        ListTile(leading: const Icon(Icons.query_stats), title: const Text('View stats'),
            onTap: () => popIfCurrent(ctx, 'stats')),
        ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Private messages'),
            trailing: (p['unread'] as num? ?? 0) > 0
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: Colors.deepOrange, borderRadius: BorderRadius.circular(10)),
                    child: Text('${p['unread']} new', style: const TextStyle(color: Colors.white, fontSize: 12)),
                  )
                : null,
            onTap: () => popIfCurrent(ctx, 'dm')),
      ])),
    );
    if (!mounted || pick == null) return;
    if (pick == 'stats') {
      await ProfileScreen.open(context, pid);
    } else {
      await DmScreen.open(context, pid, name);
    }
    if (mounted) _load(); // relations / unread may have changed
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
        child: Row(children: [
          Expanded(child: TextField(
          controller: _search,
          onChanged: _onSearch,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search players',
            border: const OutlineInputBorder(),
            suffixIcon: _results == null
                ? null
                : IconButton(icon: const Icon(Icons.close), onPressed: () {
                    _search.clear();
                    setState(() => _results = null);
                  }),
          ),
        )),
          IconButton(
            tooltip: 'Private messages',
            icon: Badge(isLabelVisible: _unreadDm > 0, label: Text('$_unreadDm'),
                child: const Icon(Icons.mail_outline)),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DmThreadsScreen()));
              if (mounted) _load();
            },
          ),
        ]),
      ),
      if (_results != null)
        Expanded(
          child: _results!.isEmpty
              ? Center(child: Text('No players found', style: TextStyle(color: AppColors.t54)))
              : ListView(children: _results!.map((p) => _playerTile(p)).toList()),
        )
      else ...[
        // four equal tabs that always fit the screen (no scrolling, no left gap)
        TabBar(
          controller: _tc,
          isScrollable: false,
          labelPadding: EdgeInsets.zero,
          labelStyle: const TextStyle(fontSize: 11),
          tabs: [
            for (final t in _tabs)
              Tab(
                height: 52,
                icon: Icon(t.$3, size: 18),
                child: FittedBox(child: Text('${t.$2} ${_contacts[t.$1]?.length ?? 0}')),
              ),
          ],
        ),
        Expanded(
          child: AsyncView(
            loading: _loading,
            error: _error,
            onRetry: _load,
            builder: () => TabBarView(controller: _tc, children: [
              for (final t in _tabs)
                RefreshIndicator(
                  onRefresh: _load,
                  child: (_contacts[t.$1] ?? const []).isEmpty
                      ? ListView(children: [
                          SizedBox(height: 80),
                          Center(child: Text('Nobody here yet.\nOpen a player profile to add them.',
                              textAlign: TextAlign.center, style: TextStyle(color: AppColors.t54))),
                        ])
                      : ListView(children: (_contacts[t.$1] ?? const []).map((p) => _playerTile(p)).toList()),
                ),
            ]),
          ),
        ),
      ],
    ]);
  }
}
