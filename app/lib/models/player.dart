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

  // Display: any positive fractional part rounds UP. 99.01 → 100%, 99.00 → 99%.
  int get conditionPct => condition.ceil();

  const Mine({
    required this.id, required this.lat, required this.lng,
    required this.itemId, required this.resId, required this.quality,
    required this.condition, required this.level,
    this.tu1 = 0, this.tu2 = 0, this.tu3 = 0, this.tu4 = 0,
    this.rateHr = 0, this.hqBoost, this.lastColl = '', this.sickUntil,
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
  );
}

class HQ {
  final double lat, lng;
  final int level;
  final Map<int, double> deposits; // deposited amounts toward next level
  const HQ({required this.lat, required this.lng, required this.level, this.deposits = const {}});
  factory HQ.fromJson(Map<String, dynamic> j) {
    final raw = j['deposits'] as Map<String, dynamic>? ?? {};
    return HQ(
      lat: (j['lat'] as num).toDouble(),
      lng: (j['lng'] as num).toDouble(),
      level: (j['lvl'] as num? ?? 1).toInt(),
      deposits: {for (final e in raw.entries) int.tryParse(e.key) ?? 0: (e.value as num).toDouble()},
    );
  }
}

class Player {
  final String hid;
  final String name;
  final int credits;
  final int xp;
  final int level;
  final int teamId;
  final int whLevel;
  final int whCap;
  final int wa;
  final int tcLevel;
  final int tcMaxQuality;
  final int haulageLevel;
  final double whUsed;
  final List<Mine> mines;
  final HQ? hq;
  final Map<String, double> lager;
  final List<Map<String, dynamic>> factories;

  const Player({
    required this.hid, required this.name, required this.credits,
    required this.xp, required this.level, required this.teamId,
    required this.whLevel, required this.whCap,
    this.whUsed = 0,
    this.wa = 80,
    this.tcLevel = 0,
    this.tcMaxQuality = 26,
    this.haulageLevel = 0,
    required this.mines, required this.hq, required this.lager,
    this.factories = const [],
  });

  // Boss maintenance range: 100m at level 0/1, +11m per level, max ~200m at level 10
  double get bossRangeM => haulageLevel <= 0 ? 100.0 : (100.0 + (haulageLevel - 1) * 11.0).clamp(100.0, 200.0);

  // Progressive XP: level N requires N*1000 XP; total to START level N = 500*N*(N-1)
  int get xpAtLevelStart => level * (level - 1) * 500;
  int get xpForCurrentLevel => level * 1000;
  int get currentLevelXp => xp - xpAtLevelStart;
  double get xpProgress => xpForCurrentLevel > 0
      ? (currentLevelXp / xpForCurrentLevel).clamp(0.0, 1.0)
      : 0.0;

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
      xp: (j['xp'] as num? ?? 0).toInt(),
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
      hq: hq,
      lager: lager,
      factories: factsList,
    );
  }
}
