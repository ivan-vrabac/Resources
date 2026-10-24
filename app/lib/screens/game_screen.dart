import '../constants.dart' show precacheResImages;
import '../widgets/update_dialog.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/tab_config.dart';
import '../models/player_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../widgets/player_hud.dart';
import 'tabs/map_tab.dart';
import 'tabs/mines_tab.dart';
import 'tabs/warehouse_tab.dart';
import 'factory_screen.dart';
import 'market_screen.dart';
import 'log_screen.dart';
import 'leaderboard_screen.dart';
import 'special_buildings_screen.dart';
import 'social_screen.dart';
import 'profile_screen.dart';
import 'quests_screen.dart';
import 'loans_screen.dart';
import 'auctions_screen.dart';
import 'news_screen.dart';
import '../widgets/archaeology_map.dart';
import 'placeholder_screen.dart';
import 'settings_screen.dart';
import 'login_screen.dart';

import '../app_colors.dart';
import '../widgets/popups.dart';
class _TabMeta {
  final String label;
  final IconData icon;
  final Widget Function() build;
  // true for tabs that are raw content widgets (no Scaffold of their own)
  // — they need one when pushed standalone from the More menu.
  final bool needsScaffold;
  const _TabMeta({required this.label, required this.icon, required this.build, this.needsScaffold = false});
}

final Map<GameTabId, _TabMeta> tabMeta = {
  GameTabId.map: _TabMeta(label: 'Map', icon: Icons.map_outlined,
      build: () => const MapTab(), needsScaffold: true),
  GameTabId.mines: _TabMeta(label: 'Mines', icon: Icons.construction_outlined,
      build: () => const MinesTab(), needsScaffold: true),
  GameTabId.warehouse: _TabMeta(label: 'Warehouse', icon: Icons.inventory_2_outlined,
      build: () => const WarehouseTab(), needsScaffold: true),
  GameTabId.factories: _TabMeta(label: 'Factories', icon: Icons.factory_outlined,
      build: () => const FactoryScreen()),
  GameTabId.market: _TabMeta(label: 'Market', icon: Icons.storefront_outlined,
      build: () => const MarketScreen(), needsScaffold: true),
  GameTabId.log: _TabMeta(label: 'Log', icon: Icons.history,
      build: () => const LogScreen()),
  // Leaderboard accessible from the More tab profile card — not a standalone tab
  GameTabId.specialBuildings: _TabMeta(label: 'Buildings', icon: Icons.account_balance_outlined,
      build: () => const SpecialBuildingsScreen()),
  GameTabId.auctions: _TabMeta(label: 'Auctions', icon: Icons.gavel,
      build: () => const AuctionsScreen(), needsScaffold: true),
  GameTabId.archeology: _TabMeta(label: 'Archeology', icon: Icons.museum_outlined,
      build: () => const _ArchaeologyTab(), needsScaffold: true),
  GameTabId.loans: _TabMeta(label: 'Loans', icon: Icons.account_balance_wallet_outlined,
      build: () => const LoansScreen(), needsScaffold: true),
  GameTabId.news: _TabMeta(label: 'News', icon: Icons.newspaper_outlined,
      build: () => const NewsScreen(), needsScaffold: true),
  GameTabId.quests: _TabMeta(label: 'Quests', icon: Icons.emoji_events_outlined,
      build: () => const QuestsScreen(), needsScaffold: true),
  GameTabId.stats: _TabMeta(label: 'Stats', icon: Icons.bar_chart_outlined,
      build: () => const ProfileScreen(embedded: true), needsScaffold: true),
  GameTabId.social: _TabMeta(label: 'Social', icon: Icons.connect_without_contact,
      build: () => const SocialScreen()),
};

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  int? _seenLevel;    // level-up popup (owner 2026-10-24)

  void _checkLevelUp(int? level) {
    if (level == null) return;
    final before = _seenLevel;
    _seenLevel = level;
    if (before == null || level <= before) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showAppDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.military_tech, size: 48, color: AppColors.accent),
          title: Text('Level $level!'),
          content: Text(level - before > 1
              ? 'You climbed ${level - before} levels. New mines, factories and rewards may be unlocked.'
              : 'You reached level $level. New mines, factories and rewards may be unlocked.'),
          actions: [FilledButton(onPressed: () => popIfCurrent(ctx), child: const Text('Great'))],
        ),
      );
    });
  }

  TabConfig _config = const TabConfig(kDefaultBottomTabs);
  bool _configLoaded = false;
  late PageController _pageCtrl;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pageCtrl = PageController(initialPage: 1);
    // item pictures decoded up front (also after a fresh login): market and warehouse icons show at once
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) precacheResImages(context); });
    TabConfig.load().then((cfg) {
      if (mounted) setState(() { _config = cfg; _configLoaded = true; });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final prov = context.read<PlayerProvider>();
      prov.addListener(_onProviderChanged);
      prov.pollChatUnread();
      // offer a newer published build (once per build; Settings > Updates anytime)
      Future.delayed(const Duration(seconds: 4), () { if (mounted) UpdateDialog.checkOnStart(context); });
    });
    _chatPoll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) context.read<PlayerProvider>().pollChatUnread();
    });
  }

  Timer? _chatPoll;

  @override
  void dispose() {
    _chatPoll?.cancel();
    context.read<PlayerProvider>().removeListener(_onProviderChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pageCtrl.dispose();
    super.dispose();
  }

  void _onProviderChanged() {
    if (!mounted) return;
    final nav = context.read<PlayerProvider>().chatNavigateTo;
    if (nav != null) {
      final mapIdx = _config.bottomTabs.indexOf(GameTabId.map);
      if (mapIdx >= 0 && mapIdx != _currentIndex) _goToTab(mapIdx);
    }
  }

  int get _totalTabs => _config.bottomTabs.length + 1; // +1 for More

  List<GameTabId> get _overflowIds => GameTabId.values
      .where((t) => tabMeta.containsKey(t) && !_config.bottomTabs.contains(t))
      .toList();

  Widget _tabBody(int i) {
    if (i == _totalTabs - 1) {
      return _MoreTab(overflowIds: _overflowIds, onOpenSettings: _openSettings);
    }
    final id = _config.bottomTabs[i];
    return tabMeta[id]?.build() ??
        PlaceholderScreen(title: id.name, icon: Icons.help_outline, subtitle: '');
  }

  // Keep state alive so tab icons/data don't reload on every switch.
  // Warehouse and Mines are now included — their data is stable enough between switches.
  static const _kKeepAlive = {
    GameTabId.map,
    GameTabId.factories,
    GameTabId.warehouse,
    GameTabId.mines,
  };

  Widget _wrapPage(int i) {
    final w = _tabBody(i);
    final isMore = i == _totalTabs - 1;
    if (isMore) {
      return _KeepAliveTab(key: const ValueKey('__more__'), child: w);
    }
    final id = _config.bottomTabs[i];
    if (_kKeepAlive.contains(id)) {
      return _KeepAliveTab(key: ValueKey(id), child: w);
    }
    return w;
  }

  // Page layout: [lastDup(0), tab0(1)..tabN(N), firstDup(N+1)]
  // Real pages 1..N correspond to _currentIndex 0..N-1
  List<Widget> _buildPages() {
    final n = _totalTabs;
    return [
      _tabBody(n - 1), // sentinel: last tab duplicate
      for (int i = 0; i < n; i++) _wrapPage(i),
      _tabBody(0), // sentinel: first tab duplicate
    ];
  }

  void _onPageChanged(int page) {
    final n = _totalTabs;
    if (page == 0) {
      // Swiped right past first — jump to real last tab
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageCtrl.hasClients) _pageCtrl.jumpToPage(n);
      });
      setState(() => _currentIndex = n - 1);
    } else if (page == n + 1) {
      // Swiped left past last — jump to real first tab
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageCtrl.hasClients) _pageCtrl.jumpToPage(1);
      });
      setState(() => _currentIndex = 0);
    } else {
      setState(() => _currentIndex = page - 1);
    }
  }

  void _goToTab(int index) {
    if (index == _currentIndex) return;
    _pageCtrl.animateToPage(
      index + 1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    setState(() => _currentIndex = index);
  }

  void _onConfigSaved(TabConfig cfg) {
    setState(() { _config = cfg; _currentIndex = 0; });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageCtrl.hasClients) _pageCtrl.jumpToPage(1);
    });
  }

  /// The top bar opens the Stats tab: switch to it if it's in the bottom bar, otherwise open it
  /// the same way the More tab does.
  void _openStats() {
    final idx = _config.bottomTabs.indexOf(GameTabId.stats);
    if (idx >= 0) {
      _goToTab(idx);
      return;
    }
    final meta = tabMeta[GameTabId.stats]!;
    Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
      appBar: AppBar(title: Text(meta.label), toolbarHeight: 44),
      body: meta.build(),
    )));
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(config: _config, onSave: _onConfigSaved),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_configLoaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final cs   = Theme.of(context).colorScheme;
    final prov = context.watch<PlayerProvider>();
    _checkLevelUp(prov.player?.level);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
        PlayerHud(onTap: _openStats),
        Expanded(
          child: PageView(
            controller: _pageCtrl,
            physics: const NeverScrollableScrollPhysics(),
            onPageChanged: _onPageChanged,
            children: _buildPages(),
          ),
        ),
      ]),
      ),
      bottomNavigationBar: Material(
        color: cs.surface,
        elevation: 3,
        child: SafeArea(
          child: SizedBox(
            height: 60,
            child: LayoutBuilder(builder: (context, constraints) {
              const double minTabW = 68;
              final n = _totalTabs;
              final natural = constraints.maxWidth / n;
              final tabW = natural < minTabW ? minTabW : natural;
              final scrollable = tabW * n > constraints.maxWidth;

              Widget buildTab(int i) {
                final isMore     = i == n - 1;
                final isSelected = i == _currentIndex;
                final id         = isMore ? null : _config.bottomTabs[i];
                final icon       = isMore ? Icons.menu : tabMeta[id]!.icon;
                final label      = isMore ? 'More' : tabMeta[id]!.label;
                final isChat     = !isMore && id == GameTabId.social;
                final unread     = isChat ? prov.chatUnread : 0;
                final hasBadge   = isChat && unread > 0;

                final iconColor = isSelected ? cs.primary : cs.onSurfaceVariant;
                Widget iconWidget = Icon(icon, size: 22, color: iconColor);
                if (hasBadge) {
                  iconWidget = Stack(clipBehavior: Clip.none, children: [
                    iconWidget,
                    Positioned(
                      top: -4, right: unread > 0 ? -10 : -3,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 9, minHeight: 9),
                        padding: unread > 0 ? const EdgeInsets.symmetric(horizontal: 3) : EdgeInsets.zero,
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: cs.surface, width: 1.5),
                        ),
                        child: unread > 0
                            ? Text(unread > 99 ? '99+' : '$unread',
                                style: const TextStyle(fontSize: 9, color: Colors.white, height: 1.2))
                            : null,
                      ),
                    ),
                  ]);
                }

                return SizedBox(
                  width: tabW,
                  child: InkWell(
                    onTap: () => _goToTab(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        iconWidget,
                        const SizedBox(height: 2),
                        Text(label,
                            style: TextStyle(
                                fontSize: 10,
                                color: isSelected ? cs.primary : cs.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1),
                      ],
                    ),
                  ),
                );
              }

              final tabs = List.generate(n, buildTab);
              if (scrollable) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: tabs),
                );
              }
              return Row(children: tabs);
            }),
          ),
        ),
      ),
    );
  }
}

class _KeepAliveTab extends StatefulWidget {
  final Widget child;
  const _KeepAliveTab({super.key, required this.child});
  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _MoreTab extends StatefulWidget {
  final List<GameTabId> overflowIds;
  final VoidCallback onOpenSettings;
  const _MoreTab({required this.overflowIds, required this.onOpenSettings});
  @override
  State<_MoreTab> createState() => _MoreTabState();
}

class _MoreTabState extends State<_MoreTab> {
  String? _countryCode = ApiService.countryNow;   // cached: the flag shows at once
  int? _rank;

  @override
  void initState() {
    super.initState();
    _loadCountry();
    _loadRank();
  }

  Future<void> _loadCountry() async {
    final had = _countryCode;
    final code = await ApiService.getCountryCode();
    if (mounted && code != null && code != had) {
      setState(() => _countryCode = code);
      final sid = context.read<PlayerProvider>().sid;
      ApiService.setCountryCode(sid, code);
    }
  }

  Future<void> _loadRank() async {
    final sid = context.read<PlayerProvider>().sid;
    if (sid.isEmpty) return;
    final result = await ApiService.getLeaderboard(sid);
    if (!mounted) return;
    final rows = result?['leaderboard'] as List? ?? [];
    final me = rows.where((r) => r['isMe'] == true).firstOrNull;
    if (me != null) setState(() => _rank = me['rank'] as int?);
  }

  Color _waColor(int wa) {
    if (wa >= 70) return AppColors.accent;   // good WA in the appearance colour
    if (wa >= 40) return Colors.amber;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>().player;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (player != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                if (_countryCode != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.asset(
                      'assets/images_countryflags/$_countryCode.png',
                      width: 60, height: 40, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _fallbackAvatar(player),
                    ),
                  )
                else
                  _fallbackAvatar(player),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_rank != null)
                    Text('Rank #$_rank',
                        style: TextStyle(
                            color: AppColors.accent, fontSize: 13,
                            fontWeight: FontWeight.bold))
                  else
                    Text('Loading rank...',
                        style: TextStyle(color: AppColors.t38, fontSize: 12)),
                  const SizedBox(height: 2),
                  Row(children: [
                    Text('WA ', style: TextStyle(color: AppColors.t38, fontSize: 11)),
                    Text('${player.wa}%',
                        style: TextStyle(
                            color: _waColor(player.wa),
                            fontSize: 11, fontWeight: FontWeight.bold)),
                  ]),
                ])),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LeaderboardScreen())),
                  child: const Text('Leaderboard'),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
        ],

        if (widget.overflowIds.isNotEmpty) ...[
          _sectionTitle('Game'),
          ...widget.overflowIds.map((id) {
            final meta = tabMeta[id]!;
            return ListTile(
              leading: Icon(meta.icon, color: AppColors.accent),
              title: Text(meta.label),
              trailing: Icon(Icons.chevron_right, color: AppColors.t38),
              onTap: () {
                final content = meta.build();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => meta.needsScaffold
                        ? Scaffold(
                            appBar: AppBar(title: Text(meta.label), toolbarHeight: 44),
                            body: content,
                          )
                        : content,
                  ),
                );
              },
            );
          }),
          const SizedBox(height: 16),
        ],

        _sectionTitle('System'),
        ListTile(
          leading: Icon(Icons.settings, color: AppColors.accent),
          title: const Text('Settings'),
          trailing: Icon(Icons.chevron_right, color: AppColors.t38),
          onTap: widget.onOpenSettings,
        ),

        const SizedBox(height: 16),
        _sectionTitle('Account'),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.red),
          title: const Text('Log out'),
          subtitle: const Text('Sign in as a different company'),
          onTap: () async {
            await StorageService.clearHid();
            if (!context.mounted) return;
            context.read<PlayerProvider>().clear();
            Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const LoginScreen()));
          },
        ),
      ],
    );
  }

  Widget _fallbackAvatar(dynamic player) => CircleAvatar(
    backgroundColor: AppColors.accent, radius: 24,
    child: Text(
      player.name.isNotEmpty ? player.name[0].toUpperCase() : '?',
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
    ),
  );

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(title.toUpperCase(),
        style: TextStyle(fontSize: 11, color: AppColors.t38, letterSpacing: 1.2)),
  );
}


class _ArchaeologyTab extends StatelessWidget {
  const _ArchaeologyTab();
  @override
  Widget build(BuildContext context) =>
      ArchaeologyScreen(sid: () => context.read<PlayerProvider>().sid);
}
