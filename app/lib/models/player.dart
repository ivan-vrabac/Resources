class Mine {
  final String id;
  final double lat, lng;
  final int itemId, resId, quality, level;
  final double condition;
  final int tu1, tu2, tu3, tu4;
  final double rateHr;
  final double? hqBoost;
  final String lastColl;
  final String? sickUntil;
  /// Repair cost from the server (cheaper for high-output mines, dearer with stationed defence).
  final int repairCost;

  // Display: any positive fractional part rounds UP. 99.01 → 100%, 99.00 → 99%.
  int get conditionPct => condition.ceil();

  const Mine({
    required this.id, required this.lat, required this.lng,
    required this.itemId, required this.resId, required this.quality,
    required this.condition, required this.level,
    this.tu1 = 0, this.tu2 = 0, this.tu3 = 0, this.tu4 = 0,
    this.rateHr = 0, this.hqBoost, this.lastColl = '', this.sickUntil, this.repairCost = 0,
  });

  // Total tech boost as a percentage (e.g. 175 = +175%)
  int get techBoostPct =>
      (tu1 * 1.0 + tu2 * 1.0 + tu3 * 1.5 + tu4 * 1.5).round();

  // Convenience: has any tech installed
  bool get hasTech => tu1 > 0;

  bool get isSick {
    if (sickUntil == null) return false;
    try { return DateTime.parse(sickUntil!).isAfter(DateTime.now()); }
    catch (_) { return false; }
  }

  factory Mine.fromJson(Map<String, dynamic> j) => Mine(
    id: j['mID'] as String? ?? '',
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    itemId: (j['itemID'] as num).toInt(),
    resId: (j['resID'] as num? ?? 0).toInt(),
    quality: (j['qual'] as num? ?? 70).toInt(),
    condition: (j['cond'] as num? ?? 100.0).toDouble(),
    level: (j['lvl'] as num? ?? 1).toInt(),
    tu1: (j['tu1'] as num? ?? 0).toInt(),
    tu2: (j['tu2'] as num? ?? 0).toInt(),
    tu3: (j['tu3'] as num? ?? 0).toInt(),
    tu4: (j['tu4'] as num? ?? 0).toInt(),
    rateHr: (j['rateHr'] as num? ?? 0).toDouble(),
    hqBoost: (j['hqBoost'] as num?)?.toDouble(),
    lastColl: j['lastColl'] as String? ?? '',
    sickUntil: j['sickUntil'] as String?,
    repairCost: (j['repairCost'] as num? ?? 0).toInt(),
  );
}

class HQ {
  final double lat, lng;
  final int level;
  final Map<int, double> deposits; // deposited amounts toward next level
  final int subLevel;              // HQ 10 bonus level 1–6 (10 000 luxury points each)
  final int luxuryPoints;
  const HQ({required this.lat, required this.lng, required this.level, this.deposits = const {},
      this.subLevel = 0, this.luxuryPoints = 0});
  factory HQ.fromJson(Map<String, dynamic> j) {
    final raw = j['deposits'] as Map<String, dynamic>? ?? {};
    return HQ(
      lat: (j['lat'] as num).toDouble(),
      lng: (j['lng'] as num).toDouble(),
      level: (j['lvl'] as num? ?? 1).toInt(),
      deposits: {for (final e in raw.entries) int.tryParse(e.key) ?? 0: (e.value as num).toDouble()},
      subLevel: (j['sub_lvl'] as num? ?? 0).toInt(),
      luxuryPoints: (j['luxuryPoints'] as num? ?? 0).toInt(),
    );
  }
}

/// Server-side mine aggregates (lite player data), so the app doesn't need every mine.
class MineStats {
  final int count;
  final int warnCount;      // mines reaching 24% condition within 72 h
  final double? warnInH;    // hours until the first of them does (<= 0: already)
  final int destrCount;     // mines destroyed (20%) within 14 days
  final double? destrInH;
  final double maxRateHr;   // best single mine output
  final double totalRateHr;
  const MineStats({this.count = 0, this.warnCount = 0, this.warnInH,
      this.destrCount = 0, this.destrInH, this.maxRateHr = 0, this.totalRateHr = 0});

  factory MineStats.fromJson(Map<String, dynamic> j) => MineStats(
    count: (j['count'] as num? ?? 0).toInt(),
    warnCount: (j['warnCount'] as num? ?? 0).toInt(),
    warnInH: (j['warnInH'] as num?)?.toDouble(),
    destrCount: (j['destrCount'] as num? ?? 0).toInt(),
    destrInH: (j['destrInH'] as num?)?.toDouble(),
    maxRateHr: (j['maxRateHr'] as num? ?? 0).toDouble(),
    totalRateHr: (j['totalRateHr'] as num? ?? 0).toDouble(),
  );
}

class Player {
  final String hid;
  final String name;
  final int credits;
  /// 0..1 progress inside the current level (the server keeps XP itself private).
  final double levelProgress;
  final int level;
  final int teamId;
  final int whLevel;
  final int whCap;
  final int wa;
  final int tcLevel;
  final int tcMaxQuality;
  final int haulageLevel;
  final double whUsed;
  /// Only filled by servers that don't support lite data; use PlayerProvider.mines,
  /// ApiService.getMinesNear and [mineStats] instead.
  final List<Mine> mines;
  final MineStats mineStats;
  final HQ? hq;
  final Map<String, double> lager;
  final List<Map<String, dynamic>> factories;

  const Player({
    required this.hid, required this.name, required this.credits,
    this.levelProgress = 0, required this.level, required this.teamId,
    required this.whLevel, required this.whCap,
    this.whUsed = 0,
    this.wa = 80,
    this.tcLevel = 0,
    this.tcMaxQuality = 26,
    this.haulageLevel = 0,
    required this.mines, required this.hq, required this.lager,
    this.mineStats = const MineStats(),
    this.factories = const [],
  });

  int get mineCount => mineStats.count > 0 ? mineStats.count : mines.length;

  // Boss maintenance range: 100m at level 0/1, +11m per level, max ~200m at level 10
  double get bossRangeM => (100.0 + 10.0 * (haulageLevel < 0 ? 0 : haulageLevel)).clamp(100.0, 200.0);   // = server helper_range

  double get xpProgress => levelProgress.clamp(0.0, 1.0);

  factory Player.fromJson(Map<String, dynamic> j) {
    final mineList = (j['mines'] as List? ?? [])
        .map((m) => Mine.fromJson(m as Map<String, dynamic>))
        .toList();
    HQ? hq;
    if (j['hq'] != null) hq = HQ.fromJson(j['hq'] as Map<String, dynamic>);
    final lagerRaw = j['lager'] as Map<String, dynamic>? ?? {};
    final lager = {for (final e in lagerRaw.entries)
        e.key: (e.value as num).toDouble()};
    final factsList = (j['facts'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    return Player(
      hid: j['hID'] as String? ?? '',
      name: j['pN'] as String? ?? '',
      credits: (j['crd'] as num? ?? 0).toInt(),
      levelProgress: (j['lvlProgress'] as num? ?? 0).toDouble(),
      level: (j['lvl'] as num? ?? 1).toInt(),
      teamId: (j['teamID'] as num? ?? 0).toInt(),
      whLevel: (j['whLvl'] as num? ?? 1).toInt(),
      whCap: (j['whCap'] as num? ?? 5000).toInt(),
      whUsed: (j['whUsed'] as num? ?? 0).toDouble(),
      wa: (j['wa'] as num? ?? 80).toInt(),
      tcLevel: (j['tcLvl'] as num? ?? 0).toInt(),
      tcMaxQuality: (j['tcMaxQ'] as num? ?? 26).toInt(),
      haulageLevel: (j['haulLvl'] as num? ?? 0).toInt(),
      mines: mineList,
      mineStats: j['mineStats'] is Map<String, dynamic>
          ? MineStats.fromJson(j['mineStats'] as Map<String, dynamic>)
          : MineStats(count: mineList.length),
      hq: hq,
      lager: lager,
      factories: factsList,
    );
  }
}
