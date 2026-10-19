import 'package:shared_preferences/shared_preferences.dart';

/// Every tab the game knows about.
enum GameTabId {
  map,
  mines,
  warehouse,
  factories,
  market,
  log,
  leaderboard,
  headquarters,
  specialBuildings,
  auctions,
  archeology,
  chat,
  loans,
  news,
  quests,
  stats,
  contacts,
}

const _kPrefKey = 'bottom_bar_tabs';

/// Default tabs shown in the bottom bar (must include at most 4; 'more' is always appended)
const List<GameTabId> kDefaultBottomTabs = [
  GameTabId.map,
  GameTabId.mines,
  GameTabId.warehouse,
];

class TabConfig {
  /// Tabs shown in the bottom bar (excluding the implicit "More" button)
  final List<GameTabId> bottomTabs;

  const TabConfig(this.bottomTabs);

  static Future<TabConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kPrefKey);
    if (raw == null) return const TabConfig(kDefaultBottomTabs);
    final ids = raw
        .map((s) => GameTabId.values.where((e) => e.name == s).firstOrNull)
        .whereType<GameTabId>()
        .toList();
    if (ids.isEmpty) return const TabConfig(kDefaultBottomTabs);
    return TabConfig(ids);
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kPrefKey, bottomTabs.map((e) => e.name).toList());
  }

  TabConfig withBottomTabs(List<GameTabId> tabs) => TabConfig(tabs);
}
