"""Economy tables and formulas (owner's revamp, 2026-10-23). One place for every number.

Sources: srs.txt (resource unlock levels, max extraction per hour at 100 % quality), costs.txt
(mine base costs, cost growth 1 + mines/50), srx.txt (factory recipes, base production per hour,
build costs and materials). Everything else is derived here so that the numbers stay consistent:

- Mines: output/h = srs rate × quality × condition × tech (up to +500 %) × HQ (up to ×10).
  No mine levels. Build cost = costs.txt base / COST_DIVISOR × (1 + mines owned / 50).
- Raw resource prices (what the system pays): a new 100 % mine pays back its base cost in
  MINE_PAYBACK_H hours at the system price.
- Products: price = (input value + recipe credits) / output × margin, so every factory earns
  (margin grows a little with the unlock level). The system sells at 150 % of that.
- Factories: production/h = base rate × level (srx.txt). Build cost = what pays back in
  FACTORY_PAYBACK_H at level 1; upgrades cost build × L^1.2 × 1.001^L, so the payback of each
  further level keeps growing (about 1.5 years at level 100, about 60 years at level 1000).
- XP comes only from permanent sinks (credits and resources spent for good, resources valued at
  the system price). The level curve is calibrated so that a steady player reaches level 50
  (all resources) in about 30 days and level 60 (all factories) in about 40.
"""
from __future__ import annotations

import math

COST_DIVISOR = 25            # costs.txt mine costs are divided by this
MINE_COST_GROWTH = 50        # build cost × (1 + mines owned / 50)
MINE_PAYBACK_H = 24          # a new 100 % mine pays back its base cost in this many hours
DEMOLISH_REFUND = 0.10       # share of the paid build cost returned on demolition
FACTORY_PAYBACK_H = 48       # a level-1 factory pays back its build cost in about this many hours
FACTORY_BATCH_H = 1          # one batch = one hour of level-1 production (whole hours: the app expects an int)
SYSTEM_SELL_MARKUP = 1.5     # the system sells at 150 % of its buying price

# mine item → (resource item, unlock level, srs max/h at 100 %, costs.txt base cost, map share)
MINES = {
    4:   (2,   1,  1530.0,     1_000_000, 0.95),   # Clay Pit → Clay
    11:  (10,  1,   306.0,   100_000_000, 0.21),   # Oil Derrick → Crude Oil
    21:  (20,  2,   510.0,     2_500_000, 0.86),   # Limestone Quarry → Limestone
    5:   (3,   3,   542.0,     5_000_000, 0.68),   # Gravel Pit → Gravel
    17:  (13,  4,   382.5,    10_000_000, 0.47),   # Iron Ore Mine → Iron Ore
    9:   (8,   4,   510.0,    50_000_000, 0.51),   # Coal Mine → Coal
    54:  (53,  7,   765.0,   200_000_000, 0.34),   # Sand Mine → Quartz Sand
    27:  (26,  9,   408.0,   400_000_000, 0.38),   # Copper Mine → Chalcopyrite
    16:  (12, 11,   306.0,   600_000_000, 0.43),   # Bauxite Mine → Bauxite
    89:  (90, 15,  2040.0,   800_000_000, 0.30),   # Lithium Ore Mine → Lithium Ore
    50:  (49, 20,   280.5, 1_000_000_000, 0.41),   # Ilmenite Mine → Ilmenite
    19:  (15, 33,   637.5, 1_250_000_000, 0.16),   # Silver Mine → Silver Ore
    18:  (14, 38,  2040.0, 1_500_000_000, 0.05),   # Gold Mine → Gold Ore
    82:  (81, 48,  1275.0, 2_000_000_000, 0.03),   # Diamond Mine → Rough Diamonds
    168: (169, 50,  510.0, 1_800_000_000, 0.12),   # Wolframite Mine → Wolframite
}

# factory item → (name, product, unlock, srx base production/h, recipe inputs {item: qty},
#                 recipe credits, recipe output, srx build credits, srx build materials)
FACTORIES = {
    25:  ("Brick Factory", 24, 1, 800, {2: 3}, 10, 2, 500_000, {2: 200}),
    6:   ("Concrete Factory", 7, 3, 2100, {3: 3, 20: 2}, 20, 14, 2_000_000, {24: 1000, 2: 1000, 20: 500}),
    23:  ("Fertilizer Factory", 22, 4, 1210, {20: 8}, 90, 11, 4_000_000, {7: 5000, 24: 2500, 20: 500}),
    31:  ("Ironworks", 30, 5, 450, {13: 7, 8: 10}, 350, 1, 10_000_000, {7: 9000, 24: 500, 20: 3000}),
    39:  ("Oil Refinery", 38, 6, 640, {10: 4}, 150, 4, 20_000_000, {7: 16000, 30: 500, 3: 500}),
    60:  ("Glazier's Workshop", 59, 8, 640, {53: 6, 38: 8, 20: 4}, 3000, 8, 20_000_000, {7: 25000, 24: 3000, 20: 150}),
    37:  ("Copper Refinery", 36, 10, 270, {26: 9}, 2500, 3, 40_000_000, {7: 25000, 30: 1000, 59: 500}),
    29:  ("Insecticide Factory", 28, 11, 3500, {36: 1, 20: 3}, 2400, 35, 30_000_000, {7: 25000, 30: 2000, 36: 500}),
    33:  ("Aluminium Factory", 32, 12, 320, {12: 24}, 5000, 4, 40_000_000, {7: 25000, 30: 2500, 59: 1500}),
    62:  ("Plastic Factory", 57, 14, 1800, {10: 1}, 400, 10, 50_000_000, {7: 16000, 30: 1000, 32: 500}),
    91:  ("Lithium Refinery", 92, 16, 750, {90: 115}, 5000, 5, 60_000_000, {7: 25000, 30: 10000, 59: 1000}),
    94:  ("Battery Factory", 93, 18, 600, {92: 20, 57: 40, 32: 10}, 75000, 10, 100_000_000, {7: 20000, 32: 10000, 59: 6000}),
    99:  ("Arms Factory", 87, 21, 125, {30: 1, 32: 1, 93: 1}, 250000, 25, 200_000_000, {24: 500000, 7: 50000, 59: 10000}),
    68:  ("Silicon Refinery", 67, 24, 120, {53: 20, 2: 1, 38: 5}, 49500, 2, 220_000_000, {7: 20000, 30: 1200, 59: 1500}),
    69:  ("Electronics Factory", 66, 27, 480, {57: 4, 36: 3, 67: 1}, 5000, 8, 300_000_000, {7: 20000, 32: 1000, 59: 8000}),
    52:  ("Titanium Refinery", 51, 30, 320, {49: 8}, 10000, 4, 350_000_000, {7: 30000, 30: 10000, 59: 2500}),
    76:  ("Medical Technology Inc.", 75, 35, 400, {51: 4, 57: 2, 66: 2}, 90000, 10, 500_000_000, {7: 40000, 30: 9500, 57: 16000}),
    34:  ("Silver Refinery", 35, 40, 3000, {15: 8}, 10000, 50, 750_000_000, {7: 35000, 30: 15000, 59: 1500}),
    80:  ("Gold Refinery", 79, 45, 240, {14: 20}, 20000, 3, 1_000_000_000, {7: 20000, 30: 20000, 59: 20000}),
    85:  ("Goldsmith", 84, 50, 100, {81: 1000, 79: 1, 35: 1}, 50000, 2, 500_000_000, {7: 20000, 24: 90000, 59: 20000}),
    170: ("Tungsten Smelter", 171, 50, 200, {169: 40, 38: 5, 20: 20}, 20000, 5, 3_000_000_000, {7: 30000, 30: 10000, 51: 10000}),
    # trucks, drones and detectors: lighter recipes than srx.txt (owner 2026-10-23: rebalance, no need to
    # follow the original) so they cost ~0.1 M / ~10 M / ~20 M; trucks and drones are equipment you keep
    125: ("Truck Plant", 124, 55, 100, {30: 100, 93: 25, 35: 50}, 250_000, 50, 2_000_000_000, {24: 500000, 66: 90000, 35: 50000}),
    118: ("Drone Shipyard", 117, 60, 1, {66: 10, 51: 20, 93: 50}, 1_000_000, 1, 2_000_000_000, {7: 80000, 57: 120000, 59: 40000}),
    # detector: cheap (owner 2026-10-24): ≈ 0.5 M, so even 50 scans for one site pay off 5-10×
    165: ("Detector Factory", 166, 60, 5, {93: 1, 66: 5, 171: 2}, 30_000, 1, 2_000_000_000, {7: 40000, 93: 1000, 59: 40000}),
}
# owner 2026-10-23: drones, detectors and trucks are priced like every product (and stay on the market)
FIXED_PRICES: dict = {}


def margin(unlock: int) -> float:
    """Value added by a factory: 20 % at level 1 rising to 50 % at level 60."""
    return 1.2 + 0.3 * min(60, unlock) / 60


def mine_base_cost(mine_id: int) -> int:
    return int(MINES[mine_id][3] // COST_DIVISOR)


def mine_cost(mine_id: int, mines_owned: int) -> int:
    """costs.txt: base × (1 + mines owned / 50), rounded to 100."""
    c = mine_base_cost(mine_id) * (1 + mines_owned / MINE_COST_GROWTH)
    return max(100, int(round(c / 100.0)) * 100)


def _derive_prices() -> dict:
    p = {}
    for mid, (res, _, rate, _, _) in MINES.items():
        p[res] = round(mine_base_cost(mid) / (rate * MINE_PAYBACK_H), 2)
    # products in unlock order (inputs are always priced earlier)
    for fid, (_, prod, unlock, _, inp, cr, out, _, _) in sorted(FACTORIES.items(), key=lambda x: x[1][2]):
        if prod in FIXED_PRICES:
            p[prod] = FIXED_PRICES[prod]
            continue
        # owner 2026-10-24: buying inputs from the system for a small profit is allowed, as long as
        # a player's own mined resources always pay more (they do: they cost 100 %, not 150 % + tax)
        cost = sum(p[i] * q for i, q in inp.items()) + cr
        p[prod] = round(cost / out * margin(unlock), 2)
    return p


PRICES = _derive_prices()


def batch(fid: int) -> dict:
    """One batch = FACTORY_BATCH_H of level-1 production: inputs, credits and output."""
    _, prod, _, rate, inp, cr, out, _, _ = FACTORIES[fid]
    cycles = rate * FACTORY_BATCH_H / out
    return {"produces": prod, "out": round(rate * FACTORY_BATCH_H),
            "needs": {i: int(math.ceil(q * cycles - 1e-9)) for i, q in inp.items()},   # whole units
            "credits": int(round(cr * cycles)), "hrs": FACTORY_BATCH_H}


def factory_profit_h(fid: int) -> float:
    b = batch(fid)
    cost = sum(PRICES[i] * q for i, q in b["needs"].items()) + b["credits"]
    return (PRICES[b["produces"]] * b["out"] - cost) / b["hrs"]


def factory_build(fid: int) -> dict:
    """Level-1 cost: srx.txt credits and materials on the same scale as mines (÷ COST_DIVISOR).
    A factory adds 20-50 % to the value of the resources it is fed, so it is worth as much as the
    player can supply (production is limited by inputs, not by the factory)."""
    srx_credits, srx_mats = FACTORIES[fid][7], FACTORIES[fid][8]
    return {"credits": int(round(srx_credits / COST_DIVISOR, -2)),
            "res": {i: max(1, int(math.ceil(q / COST_DIVISOR))) for i, q in srx_mats.items()}}


def upgrade_factor(level: int) -> float:
    """Cost multiplier for upgrading from `level` to level+1 (level ≥ 1)."""
    return max(1.0, level) ** 1.2 * 1.001 ** level


def factory_upgrade(fid: int, level: int) -> dict:
    b = factory_build(fid)
    f = upgrade_factor(level)
    return {"credits": int(round(b["credits"] * f, -2)), "res": {i: int(math.ceil(q * f)) for i, q in b["res"].items()}}


# ── warehouse ────────────────────────────────────────────────────────────────

WAREHOUSE_BASE = 5000


def wh_capacity(level: int) -> float:
    return WAREHOUSE_BASE * level ** 2


def wh_upgrade_cost(level: int) -> int:
    """Upgrade from `level` to level+1: 8 125 × L² × 1.03^L (grows exponentially in the end;
    owner 2026-10-24: 35 % cheaper than the old 12 500)."""
    return int(round(8_125 * level ** 2 * 1.03 ** level, -2))


# ── scans ────────────────────────────────────────────────────────────────────

FREE_SCAN_LEVEL = 5          # scans are free below this player level (a new company can't go broke)


def scan_cost(level: int, tc_level: int) -> int:
    if level < FREE_SCAN_LEVEL:
        return 0
    return int(round(25 * level ** 2 * (1 + 0.1 * tc_level), -1))


# ── XP and levels ────────────────────────────────────────────────────────────

XP_PER_CREDIT = 1 / 100      # 1 XP per 100 credits of permanent value spent
# Total XP needed to START each level 1..60, calibrated by tools/econ_sim.py (see module doc);
# beyond level 60 every level costs 6 % more than the one before.
LEVEL_XP: list = []          # filled by _build_levels()
LEVEL_GROWTH_AFTER_60 = 1.06


def _build_levels(table60) -> None:
    LEVEL_XP.clear()
    LEVEL_XP.extend(int(x) for x in table60)


def xp_to_start(level: int) -> int:
    if level <= 1:
        return 0
    if level <= len(LEVEL_XP):
        return LEVEL_XP[level - 1]
    last = LEVEL_XP[-1] - LEVEL_XP[-2]
    total = LEVEL_XP[-1]
    for _ in range(len(LEVEL_XP), level):
        last *= LEVEL_GROWTH_AFTER_60
        total += last
    return int(total)


def level_from_xp(xp: float) -> int:
    lo, hi = 1, 2
    while xp_to_start(hi) <= xp:
        lo, hi = hi, hi * 2
        if hi > 100_000:
            break
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if xp_to_start(mid) <= xp:
            lo = mid
        else:
            hi = mid
    return lo


def level_progress(xp: float, level: int) -> float:
    a, b = xp_to_start(level), xp_to_start(level + 1)
    return round(max(0.0, min(1.0, (xp - a) / max(1, b - a))), 4)


def sink_xp(credits: float = 0, res: dict | None = None) -> int:
    """XP for a permanent sink: credits + resources at the system (buying) price."""
    value = float(credits or 0) + sum(PRICES.get(int(i), 0) * float(q) for i, q in (res or {}).items())
    return int(value * XP_PER_CREDIT)


# generated by tools/econ_sim.py (steady player: level 10 ≈ day 2.6, 20 ≈ day 7.6, 30 ≈ day 14,
# 40 ≈ day 21, 50 ≈ day 30, 60 ≈ day 39)
LEVEL_TABLE_60 = [0, 2270, 2420, 2670, 2920, 3220, 3570, 4360, 4810, 5700, 6620, 8070, 9070, 11200, 13400, 15700,
                  18100, 22000, 26100, 30500, 35900, 42600, 49700, 58300, 67400, 77100, 89800, 103000, 119000,
                  134000, 152000, 173000, 194000, 217000, 243000, 270000, 303000, 336000, 368000, 409000, 446000,
                  491000, 537000, 586000, 637000, 693000, 751000, 812000, 875000, 944000, 1020000, 1090000,
                  1170000, 1250000, 1340000, 1430000, 1520000, 1620000, 1730000, 1830000]
_build_levels(LEVEL_TABLE_60)


# ── everything that isn't mined or produced ──────────────────────────────────
# Special items are much dearer than resources and products (owner 2026-10-23); found objects make
# a crate worth about 2 000 credits (an hour or so of an early mine). Drones and detectors keep their
# market price (see FIXED_PRICES).
OTHER_PRICES = {
    # found objects (Cargo Rain)
    56: 40, 41: 60, 55: 120, 40: 300, 70: 30, 74: 40, 115: 20, 78: 150, 77: 25, 120: 2_000,
    # Maintenance Kit: crates hold up to 50 000 of them now (owner 2026-10-24, like coins and scrap),
    # so a kit is priced like the other plentiful found objects
    43: 2_000,
    # Tech Upgrades (IV is not tradeable): each unit is +1 % (TU3 +1.5 %) output on one mine for
    # ever; on a mid-game mine (8 M base cost = 8 M a day) that's 80 k a day, paid back in about a week
    44: 500_000, 45: 600_000, 46: 900_000,
    # production boosters (one factory, 8 h, every batch made in those 8 h at the factory's level):
    # priced by what they boost (owner 2026-10-24: billions), a late factory makes billions in 8 h
    159: 1_000_000_000, 160: 2_000_000_000, 158: 3_000_000_000, 161: 5_000_000_000,
    # units: 1 000 credits per point of defence, 2 000 per point of attack (loot is 10 h of the
    # target mine's output per Mafia HQ level, so a big mine is worth sending an army)
    95: 5_000, 97: 50_000, 98: 100_000, 102: 10_000, 103: 100_000, 104: 200_000,
    # archaeologists: 70-100 go into every recovery (owner 2026-10-24: hunting must pay 5-10× even
    # in a bad case of 50 scans and 1 000 archaeologists for one site: 50 × 0.5 M + 1 000 × 20 k = 45 M
    # against ≈ 360 M a site)
    167: 20_000,
}


# Artifacts (owner 2026-10-24): a site holds about 100 of mixed kinds and a 5 km detector finds one
# with nearly every scan. A find costs a detector (≈ 0.5 M) and 70-100 archaeologists (20 k each),
# so a site (≈ 100 artifacts, ≈ 360 M on average) pays 5-10× even when it took 50 scans and
# 1 000 archaeologists, and far more usually; rarer = dearer.
ARTIFACT_VALUE = {172: 2_000_000, 173: 6_000_000, 174: 3_000_000, 175: 4_000_000, 176: 12_000_000,
                  177: 3_000_000}
OTHER_PRICES.update(ARTIFACT_VALUE)

# Special items (owner 2026-10-24): the system BUYS them (players can sell them) but never SELLS
# them, so money can't replace finding them. Players may still trade them among themselves.
SELL_ONLY = {43, 44, 45, 46, 158, 159, 160, 161, *ARTIFACT_VALUE}


def system_prices() -> dict:
    return {**PRICES, **OTHER_PRICES}


# ── special buildings (owner 2026-10-23: rebalanced for this economy) ─────────
# Each level costs base × 2.2^(level−1) in value (level 10 ≈ 1 200 × level 1): half credits, half
# products. The products follow the building's theme and what a player can make at that stage:
# levels 1–3 early products, 4–6 middle, 7–10 late ones (drones, trucks, detectors only late).
SPECIAL_GROWTH = 2.2
SPECIAL_CREDIT_SHARE = 0.5
SPECIAL_PLAN = {
    # building: (level-1 value, early items, middle items, late items)
    116: (200_000,   (24, 7),   (59, 36),  (66, 93)),     # Tech Center
    123: (200_000,   (24, 7),   (30, 32),  (124, 93)),    # Haulage Firm
    58:  (300_000,   (24, 30),  (32, 57),  (66, 51)),     # Recycling Plant
    65:  (500_000,   (24, 7),   (59, 40),  (79, 35)),     # Museum
    71:  (800_000,   (24, 7),   (57, 59),  (75, 66)),     # Hospital
    72:  (800_000,   (24, 7),   (59, 57),  (79, 35)),     # Law Firm
    121: (800_000,   (7, 30),   (36, 93),  (93, 66)),     # Service Center
    122: (800_000,   (24, 7),   (59, 57),  (75, 66)),     # HR Department
    119: (1_500_000, (30, 24),  (32, 57),  (66, 117)),    # Drone Research
    127: (1_500_000, (7, 30),   (36, 59),  (66, 93)),     # Seismology Centre
    126: (1_500_000, (7, 30),   (32, 59),  (124, 93)),    # Fire Station
    86:  (2_000_000, (24, 30),  (87, 32),  (87, 79)),     # Mafia HQ
    96:  (2_000_000, (24, 30),  (87, 32),  (87, 79)),     # Army Camp (Training Camp)
    164: (3_000_000, (167, 24), (59, 93),  (166, 66)),    # Archaeological Center
    61:  (3_000_000, (24, 7),   (59, 36),  (79, 84)),     # Casino
}


def _nice(q: float) -> int:
    """Round to two significant digits (1 234 → 1 200)."""
    if q < 10:
        return max(1, int(round(q)))
    d = 10 ** (int(math.log10(q)) - 1)
    return int(round(q / d) * d)


def special_costs(sid: int) -> list:
    base, early, mid, late = SPECIAL_PLAN[sid]
    prices = system_prices()
    out = []
    for lvl in range(1, 11):
        value = base * SPECIAL_GROWTH ** (lvl - 1)
        items = early if lvl <= 3 else mid if lvl <= 6 else late
        share = value * (1 - SPECIAL_CREDIT_SHARE) / len(items)
        out.append({"credits": _nice(value * SPECIAL_CREDIT_SHARE),
                    "res": {i: _nice(share / prices[i]) for i in items}})
    return out
