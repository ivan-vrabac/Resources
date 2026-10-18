import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/player_provider.dart';
import '../services/game_api.dart';
import '../widgets/async_view.dart';
import 'profile_screen.dart';

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

  Widget _playerTile(Map<String, dynamic> p, {String? subtitle}) => ListTile(
        leading: CircleAvatar(child: Text((p['name'] as String? ?? '?').characters.first.toUpperCase())),
        title: Text(p['name'] as String? ?? ''),
        subtitle: Text(subtitle ?? 'Level ${p['level']} · HQ ${p['hqLevel']}',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        trailing: const Icon(Icons.chevron_right, color: Colors.white38),
        onTap: () async {
          await ProfileScreen.open(context, p['pid'] as String);
          if (mounted) _load(); // relations may have changed
        },
      );

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: TextField(
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
        ),
      ),
      if (_results != null)
        Expanded(
          child: _results!.isEmpty
              ? const Center(child: Text('No players found', style: TextStyle(color: Colors.white54)))
              : ListView(children: _results!.map((p) => _playerTile(p)).toList()),
        )
      else ...[
        TabBar(controller: _tc, isScrollable: true, tabs: [
          for (final t in _tabs)
            Tab(icon: Icon(t.$3, size: 18), text: '${t.$2} (${_contacts[t.$1]?.length ?? 0})'),
        ]),
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
                      ? ListView(children: const [
                          SizedBox(height: 80),
                          Center(child: Text('Nobody here yet.\nOpen a player profile to add them.',
                              textAlign: TextAlign.center, style: TextStyle(color: Colors.white54))),
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
