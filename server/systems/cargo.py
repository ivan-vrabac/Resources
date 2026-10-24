"""Phase 4 — Cargo Rain (crates & containers).

Sources: sfo.txt (found objects: item, drop chance, museum level, recycling sources), eva.txt
(30 crates per level up, 15 per mission, cargo rain drops at the player's position, crates vanish
after 2–3 days), next.txt (drop 1–100, stacked cargo of 100 via Haulage Firm, trucks/drones,
museum range ring, no duplicate collection).

Documented assumptions (values are configurable constants below):
- Loot: each crate's content is rolled at drop time from LOOT (sfo.txt drop chances as weights).
  Quantities are NOT in the sources → QTY ranges below. Collector's Museum level adds
  +5 %/level to the quantity ("museum influences loot quality").
- Visibility: a crate is visible/collectable only for players whose Museum level ≥ the content
  item's museum level (sfo.txt column "Discoverable from museum level").
- Collection range (by hand): 50 m + 15 m × Museum level (200 m at L10). Drop range: crates are
  scattered within DROP_SCATTER_M of the dropping player's position.
- * Shared crates (owner's rule): every player can collect a crate once (cargo_pickups primary key
  (crate, player) → no duplicate collection). A crate disappears GONE_AFTER_FIRST_S (15 min) after
  its first collection, otherwise CRATE_HOURS (24 h) after the drop.
- * Contents are regular found objects only — no Giant Diamonds, Tech Upgrades or production
  boosters (owner's rule) — and always whole units.
- * Trucks (Haulage Firm ≥ 5): one tap collects every crate in truck range (the Haulage Firm boss
  range, 100 m + 10 m/level). Owner 2026-10-23 (rebalance): one truck or drone carries
  CRATES_PER_VEHICLE (100) crates; trucks and drones are equipment you keep (not used up).
- * Stacked Cargo Rain (owner 2026-10-20): drop any number of crates in steps of 100, split over at
  most MAX_STACKS_PER_DROP stacks; every stack records how many crates it holds.
- Stacked Cargo Rain (one map object = 100 crates' contents) unlocks at Haulage Firm level
  STACK_HF_LEVEL. Stacks can only be collected by truck (needs ≥1 Trucks item, 124, not used up;
  within the hand collection range) or by drone (uses 1 Scan Drone, 117; needs Drone Research ≥ 5
  as in eva.txt; within the drone scan range).
- Crates expire CRATE_HOURS after being dropped.
- Recycling (sfo.txt / srs.txt "*From recycling" sources) is on (owner's decision 2026-10-19); the
  ratios aren't in the sources — see RECYCLE. Needs a Recycling Plant; Shadow Obelisk adds yield.
"""
from __future__ import annotations

import datetime
import json
import math
import random
import uuid

import econ
from . import archaeology, float_arg, int_arg

CARGO_ITEM = 0          # ledger item id used for Cargo Rain crates (not a warehouse item)
LEVEL_UP_CRATES = 30    # eva.txt: 30 C&C per level up
QUEST_CRATES = 15       # eva.txt: 15 C&C per mission
MUSEUM = 65
HAULAGE_FIRM = 123
DRONE_RESEARCH = 119
RECYCLING_PLANT = 58
TRUCKS = 124
SCAN_DRONE = 117
STACK_SIZE = 100
STACK_HF_LEVEL = 5
DRONE_DR_LEVEL = 5
MAX_DROP = 100
MAX_STACKS_PER_DROP = 5
DROP_SCATTER_M = 40.0
CRATE_HOURS = 24
GONE_AFTER_FIRST_S = 15 * 60
TRUCK_CAPACITY = 100         # crates per truck (rebalance 2026-10-23; was 1)
CRATES_PER_VEHICLE = 100     # a truck or a drone carries this many crates (neither is used up)


def vehicles_for(crates: int) -> int:
    return -(-int(crates) // CRATES_PER_VEHICLE)
TRUCK_HF_LEVEL = 5
LOCAL_RANGE_BASE_M = 50.0
LOCAL_RANGE_PER_MUSEUM_M = 25.0     # 300 m at Museum level 10 (owner 2026-10-20)
MUSEUM_QTY_BONUS = 0.05

# sfo.txt found objects: item_id → (name, drop chance %, museum level)
LOOT = {
    # Old Tires is its own item 56 (it was 57 = Plastics by mistake)
    56: ("Old Tires", 11.5, 0), 41: ("Fossils", 23.0, 0), 55: ("Copper Coins", 21.85, 0),
    40: ("Roman Coins", 14.95, 0), 70: ("Scrap Metal", 9.11, 3), 74: ("Used Oil", 7.36, 4),
    43: ("Maintenance Kit", 7.36, 4), 115: ("Waste Glass", 5.52, 6), 78: ("Electronic Scrap", 5.29, 6),
    77: ("Plastic Scrap", 4.6, 6), 120: ("Drone Wreckage", 3.68, 7),
}
# Cargo BOXES (owner 2026-10-23, eva.txt: Giant Diamonds come in crates, not containers) can also
# hold the sfo.txt specials; containers and stacks hold the regular LOOT only.
BOX_EXTRA = {
    42: ("Giant Diamond", 0.02, 10), 44: ("Tech Upgrade 1", 0.58, 10), 45: ("Tech Upgrade 2", 0.23, 10),
    # boosters are worth billions now (owner 2026-10-24), so only a Museum level 10 finds them
    46: ("Tech Upgrade 3", 0.12, 10), 48: ("Tech Upgrade 4", 0.02, 10), 159: ("Overtime", 0.12, 10),
    158: ("Night Shift", 0.12, 10), 160: ("Guest Workers", 0.12, 10), 161: ("Wage Subsidy", 0.12, 10),
}
BOX_LOOT = {**LOOT, **BOX_EXTRA}
BOX_SHARE = 0.2              # one crate in five is a cargo box, the rest are containers


def drop_table() -> list:
    """How many of 100 crates hold each found object (owner 2026-10-24: drop table in the app):
    4 in 5 crates are containers (LOOT), 1 in 5 cargo boxes (LOOT + specials)."""
    w_loot = sum(v[1] for v in LOOT.values())
    w_box = sum(v[1] for v in BOX_LOOT.values())
    out = []
    for item, (name, w, museum) in BOX_LOOT.items():
        per100 = 100 * ((1 - BOX_SHARE) * (w / w_loot if item in LOOT else 0) + BOX_SHARE * w / w_box)
        lo, hi = QTY[item]
        out.append({"itemID": item, "name": name, "per100": round(per100, 3), "min": lo, "max": hi,
                    "museum": museum, "boxOnly": item not in LOOT})
    return sorted(out, key=lambda e: -e["per100"])


def by_rarity(got: dict) -> list:
    """[{itemID, qty}] from common to rare (owner 2026-10-23: Tech Upgrades go 1, 2, 3, 4)."""
    return [{"itemID": k, "qty": v} for k, v in
            sorted(got.items(), key=lambda kv: (-BOX_LOOT.get(kv[0], ("", 0, 0))[1], kv[0]))]
# Assumed quantity per crate (min, max) — not in the sources.
QTY = {56: (1, 20), 57: (1, 20), 41: (1, 20), 55: (1, 10), 40: (1, 10), 70: (5, 50), 74: (5, 50), 43: (1, 1),
       115: (5, 50), 78: (5, 30), 77: (5, 50), 120: (1, 3), 42: (1, 1), 44: (1, 3), 45: (1, 2),
       46: (1, 2), 48: (1, 1), 159: (1, 1), 158: (1, 1), 160: (1, 1), 161: (1, 1)}
# Recycling sources from sfo.txt and srs.txt ("*From recycling"); the ratios are not in the
# sources and are a documented proposal: input → [(output, units of output per input unit)].
# The units are split evenly over the outputs, then × the Recycling Plant yield.
RECYCLE = {
    # owner 2026-10-24 audit: crude oil and quartz sand cut (2 / 6 → 0.1): bought from the system and
    # recycled, fossils returned 10× their price (used oil 3×)
    41: [(2, 10), (10, 0.1), (20, 6), (3, 6), (53, 0.1)],   # fossils → clay, crude oil, limestone, gravel, quartz sand (srs.txt)
    120: [(70, 3), (74, 2), (78, 2), (77, 2)],          # drone wreckage → scrap metal, used oil, e-scrap, plastic scrap
    115: [(70, 0.5), (77, 0.5)],                         # waste glass → scrap metal, plastic scrap
    74: [(70, 0.5), (10, 0.1)],                          # used oil → scrap metal, crude oil (srs.txt)
    77: [(74, 0.5)],                                     # plastic scrap → used oil
    43: [(77, 5)],                                       # maintenance kit → plastic scrap
    # coins: about their own value in Tech Upgrades at 100 % yield (economy revamp 2026-10-23)
    55: [(44, 0.00024)],                                 # copper coins → Tech Upgrade I (1 per ~4 200)
    40: [(45, 0.0002)],                                  # roman coins → Tech Upgrade II (1 per 5 000)
    56: [(77, 1.0), (70, 0.5)],                          # old tires → plastic scrap, scrap metal
}


def ensure_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS cargo_stock (
            hid    TEXT PRIMARY KEY,
            crates INTEGER NOT NULL DEFAULT 0 CHECK (crates >= 0)
        );
        CREATE TABLE IF NOT EXISTS cargo_crates (
            id           TEXT PRIMARY KEY,
            dropper_hid  TEXT NOT NULL,
            lat          REAL NOT NULL,
            lng          REAL NOT NULL,
            item_id      INTEGER NOT NULL,
            qty          REAL NOT NULL,
            museum_level INTEGER NOT NULL,
            stacked      INTEGER NOT NULL DEFAULT 0,
            crates       INTEGER NOT NULL DEFAULT 1,       -- crates in this object (stacks: many)
            kind         TEXT NOT NULL DEFAULT 'container',  -- box | container | stack
            mix          TEXT,                              -- stacks: JSON {item: qty}
            created_at   TEXT NOT NULL,
            expires_at   TEXT NOT NULL,
            collected_by TEXT,
            collected_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_crates_geo ON cargo_crates(lat, lng);
        CREATE INDEX IF NOT EXISTS idx_crates_open ON cargo_crates(collected_by, expires_at);
        CREATE TABLE IF NOT EXISTS cargo_pickups (
            crate_id TEXT NOT NULL,
            hid      TEXT NOT NULL,
            ts       TEXT NOT NULL,
            PRIMARY KEY (crate_id, hid)
        );
    """)
    cols = [r[1] for r in conn.execute("PRAGMA table_info(cargo_crates)")]
    if "crates" not in cols:
        conn.execute("ALTER TABLE cargo_crates ADD COLUMN crates INTEGER NOT NULL DEFAULT 1")
        conn.execute("UPDATE cargo_crates SET crates=? WHERE stacked=1", (STACK_SIZE,))
    cols = [r[1] for r in conn.execute("PRAGMA table_info(cargo_crates)")]
    if "kind" not in cols:
        conn.execute("ALTER TABLE cargo_crates ADD COLUMN kind TEXT NOT NULL DEFAULT 'container'")
        conn.execute("ALTER TABLE cargo_crates ADD COLUMN mix TEXT")
        conn.execute("UPDATE cargo_crates SET kind='stack' WHERE stacked=1")
    # stacks of earlier builds held one item (often invisible to the dropper): turn them into a mix,
    # make them visible to everyone and give them a fresh day
    rng0 = random.Random()
    tomorrow = (econ.utcnow() + datetime.timedelta(hours=CRATE_HOURS)).isoformat()
    for r in conn.execute("SELECT id, crates FROM cargo_crates WHERE stacked=1 AND mix IS NULL AND collected_at IS NULL").fetchall():
        conn.execute("UPDATE cargo_crates SET mix=?, museum_level=0, kind='stack', expires_at=MAX(expires_at, ?) WHERE id=?",
                     (json.dumps(stack_mix(rng0, int(r[1] or STACK_SIZE))), tomorrow, r[0]))
    # crates of earlier builds that hold items no longer allowed in cargo: drop them
    conn.execute("DELETE FROM cargo_crates WHERE item_id IN (42, 44, 45, 46, 48, 158, 159, 160, 161) "
                 "AND collected_by IS NULL AND kind <> 'box'")


def stock(conn, hid) -> int:
    r = conn.execute("SELECT crates FROM cargo_stock WHERE hid=?", (hid,)).fetchone()
    return int(r[0]) if r else 0


def grant(conn, hid, n: int, source: str) -> None:
    """Add n Cargo Rain crates to a player's stock (inside the caller's transaction)."""
    n = int(n)
    if n <= 0:
        return
    conn.execute("INSERT INTO cargo_stock(hid, crates) VALUES(?,?) "
                 "ON CONFLICT(hid) DO UPDATE SET crates = crates + excluded.crates", (hid, n))
    econ._ledger(conn, hid, f"cargo_{source}", item_id=CARGO_ITEM, qty=n)


def spend(conn, hid, n: int, source: str) -> None:
    n = int(n)
    cur = conn.execute("UPDATE cargo_stock SET crates = crates - ? WHERE hid=? AND crates >= ?", (n, hid, n))
    if cur.rowcount != 1:
        raise econ.GameError("no_cargo", "Not enough Cargo Rain")
    econ._ledger(conn, hid, f"cargo_{source}", item_id=CARGO_ITEM, qty=-n)


# crates a player can still see/collect: not expired, not gone 15 min after the first pick-up,
# and not already collected by this player
OPEN_SQL = ("SELECT c.* FROM cargo_crates c WHERE c.expires_at > ? "
            "AND (c.collected_at IS NULL OR c.collected_at > ?) "
            "AND NOT EXISTS (SELECT 1 FROM cargo_pickups p WHERE p.crate_id = c.id AND p.hid = ?)")


def open_args(hid):
    now = econ.utcnow()
    return (now.isoformat(), (now - datetime.timedelta(seconds=GONE_AFTER_FIRST_S)).isoformat(), hid)


def gone_at(c) -> str:
    if c["collected_at"]:
        t = datetime.datetime.fromisoformat(c["collected_at"]) + datetime.timedelta(seconds=GONE_AFTER_FIRST_S)
        return min(t.isoformat(), c["expires_at"])
    return c["expires_at"]


def collect_range(museum_level: int) -> float:
    return LOCAL_RANGE_BASE_M + LOCAL_RANGE_PER_MUSEUM_M * max(0, min(10, museum_level))


def roll(rng: random.Random, stacked: bool = False, crates: int = 1, table=None):
    """Roll a crate's content: (item_id, qty, museum level) from `table` (default: regular LOOT)."""
    table = table or LOOT
    items = list(table)
    item = rng.choices(items, weights=[table[i][1] for i in items])[0]
    lo, hi = QTY[item]
    n = max(1, crates) if stacked else 1
    if hi <= lo:
        q = lo * n
    elif n <= 2000:
        q = sum(rng.randint(lo, hi) for _ in range(n))
    else:
        q = int(round(n * (lo + hi) / 2))
    return item, q, table[item][2]


def _poisson(rng: random.Random, lam: float) -> int:
    if lam <= 0:
        return 0
    limit, k, p = math.exp(-lam), 0, 1.0
    while True:
        p *= rng.random()
        if p <= limit:
            return k
        k += 1


def _binom(rng: random.Random, n: int, p: float) -> int:
    """Binomial(n, p) draw: exact for small n, Poisson for rare outcomes, normal otherwise."""
    if n <= 0 or p <= 0:
        return 0
    if p >= 1:
        return n
    if n <= 2000:
        return sum(1 for _ in range(n) if rng.random() < p)
    if n * p < 30:
        return min(n, _poisson(rng, n * p))
    if n * (1 - p) < 30:
        return n - min(n, _poisson(rng, n * (1 - p)))
    return max(0, min(n, int(round(rng.gauss(n * p, math.sqrt(n * p * (1 - p)))))))


def _qty(rng: random.Random, item: int, k: int) -> int:
    """Total quantity of `k` crates of `item` (each QTY-uniform)."""
    lo, hi = QTY[item]
    if k <= 0:
        return 0
    if hi <= lo:
        return lo * k
    if k <= 2000:
        return sum(rng.randint(lo, hi) for _ in range(k))
    var = k * ((hi - lo + 1) ** 2 - 1) / 12
    return max(k * lo, min(k * hi, int(round(rng.gauss(k * (lo + hi) / 2, math.sqrt(var))))))


def stack_mix(rng: random.Random, crates: int) -> dict:
    """Content of a stack of `crates` crates: {item: qty}. Exactly what the same number of loose
    crates would hold (owner 2026-10-23: stacked or not, same for the player): one in five is a
    cargo box (BOX_LOOT, incl. Giant Diamonds and Tech Upgrades), the rest containers (LOOT)."""
    mix = {}
    boxes = _binom(rng, crates, BOX_SHARE)
    for table, n in ((BOX_LOOT, boxes), (LOOT, crates - boxes)):
        left, mass = n, float(sum(v[1] for v in table.values()))
        for item, (_, w, _) in table.items():       # multinomial as a chain of binomials
            if left <= 0 or mass <= 0:
                break
            k = _binom(rng, left, min(1.0, w / mass))
            left -= k
            mass -= w
            q = _qty(rng, item, k)
            if q > 0:
                mix[item] = mix.get(item, 0) + q
    return mix


def split_stacks(total: int, stacks: int) -> list:
    """Split `total` crates (a multiple of STACK_SIZE) into `stacks` stacks, each a multiple of
    STACK_SIZE, as evenly as possible."""
    units = total // STACK_SIZE
    stacks = max(1, min(stacks, units))
    base, extra = divmod(units, stacks)
    return [(base + (1 if i < extra else 0)) * STACK_SIZE for i in range(stacks)]


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        ensure_schema(conn)
        conn.commit()

    def on_level_up(conn, hid, old_level, new_level):
        ensure_schema(conn)
        grant(conn, hid, LEVEL_UP_CRATES * (new_level - old_level), "level_up")
        econ.emit(conn, "level_up", hid, {"from": old_level, "to": new_level},
                  dedup=f"level_up:{hid}:{new_level}")

    if not any(getattr(f, "__name__", "") == "on_level_up" for f in h.LEVEL_UP_HOOKS):
        h.LEVEL_UP_HOOKS.append(on_level_up)

    def levels(conn, hid):
        return {"museum": h.building_level(conn, hid, MUSEUM),
                "haulage": h.building_level(conn, hid, HAULAGE_FIRM),
                "droneResearch": h.building_level(conn, hid, DRONE_RESEARCH)}

    def truck_range(hf_level: int) -> float:
        return min(200.0, 100.0 + 10.0 * max(0, hf_level))

    def take_crate(conn, hid, c, museum, strict=True) -> int:
        """Record this player's pick-up of crate `c` and give the contents (whole units)."""
        now = econ.utcnow_iso()
        cur = conn.execute("INSERT OR IGNORE INTO cargo_pickups(crate_id, hid, ts) VALUES(?,?,?)", (c["id"], hid, now))
        if cur.rowcount != 1:
            raise econ.GameError("gone", "You already collected this crate")
        conn.execute("UPDATE cargo_crates SET collected_by=COALESCE(collected_by, ?), "
                     "collected_at=COALESCE(collected_at, ?) WHERE id=?", (hid, now, c["id"]))
        bonus = 1 + MUSEUM_QTY_BONUS * museum
        if c["mix"]:
            got = {}
            for item, q in json.loads(c["mix"]).items():
                item = int(item)
                if BOX_LOOT.get(item, ("", 0, 99))[2] > museum:
                    continue                      # your Museum can't find this one
                n = int(econ.give(conn, hid, item, int(round(q * bonus)), "cargo_collect", c["id"], strict=False))
                if n:
                    got[item] = n
                    if item in (42, 48):
                        econ.emit(conn, "rare_find", hid, {"itemID": item, "qty": n})
            econ.emit(conn, "cargo_collected", hid, {"crates": int(c["crates"] or 1), "items": got}, public=False)
            return got
        amount = int(round(c["qty"] * bonus))
        got = int(econ.give(conn, hid, c["item_id"], amount, "cargo_collect", c["id"], strict=strict))
        econ.emit(conn, "cargo_collected", hid, {"crates": int(c["crates"] or 1),
                                                  "itemID": c["item_id"], "qty": got}, public=False)
        if c["item_id"] in (42, 48):
            econ.emit(conn, "rare_find", hid, {"itemID": c["item_id"], "qty": got})
        return got

    def drone_range(dr_level: int) -> float:
        if dr_level < DRONE_DR_LEVEL:
            return 0.0
        return float(h.DRONE_SCAN_RANGES[min(dr_level, len(h.DRONE_SCAN_RANGES)) - 1])

    @api.endpoint("/api/v1/cargo/stock", feature="CARGO")
    def get_stock(conn, hid, form):
        lv = levels(conn, hid)
        return {"err": 0, "crates": stock(conn, hid), **lv,
                "collectRange": collect_range(lv["museum"]),
                "truckRange": truck_range(lv["haulage"]),
                "droneRange": drone_range(lv["droneResearch"]),
                "stackUnlocked": lv["haulage"] >= STACK_HF_LEVEL, "stackSize": STACK_SIZE,
                "maxStacks": MAX_STACKS_PER_DROP,
                "stackHaulageLevel": STACK_HF_LEVEL, "maxDrop": MAX_DROP,
                "trucks": econ.qty_of(conn, hid, TRUCKS), "drones": econ.qty_of(conn, hid, SCAN_DRONE),
                "dropTable": drop_table()}

    @api.endpoint("/api/v1/cargo/drop", feature="CARGO")
    def drop(conn, hid, form):
        """Drop crates around the player's position: count=1..100 normal crates, or stacked=1 with
        count = any multiple of 100 split over stacks=1..5 stacks (Haulage Firm level ≥ 5)."""
        lat, lng = econ.parse_pos(form)
        stacked = form.get("stacked") == "1"
        if stacked:
            count = int_arg(form, "count", STACK_SIZE, STACK_SIZE, 10**9)
            if count % STACK_SIZE:
                raise econ.GameError("bad_input", f"Stacked Cargo Rain goes in steps of {STACK_SIZE} crates")
            # the server decides how many stacks (1–5, never more than count / 100)
            stacks = random.randint(1, min(MAX_STACKS_PER_DROP, count // STACK_SIZE))
        else:
            stacks = 0
            count = int_arg(form, "count", None, 1, MAX_DROP)
        rid = (form.get("rid") or "").strip()[:64]
        with econ.tx(conn):
            if rid:
                prev = econ.once_get(conn, "cargo_drop", hid, rid)
                if prev is not None:
                    return prev
            h.check_travel(conn, hid, lat, lng)
            if stacks and h.building_level(conn, hid, HAULAGE_FIRM) < STACK_HF_LEVEL:
                raise econ.GameError("locked", f"Stacked Cargo Rain needs Haulage Firm level {STACK_HF_LEVEL}")
            spend(conn, hid, count, "drop")
            rng = random.Random()
            now = econ.utcnow()
            exp = (now + datetime.timedelta(hours=CRATE_HOURS)).isoformat()
            sizes = split_stacks(count, stacks) if stacked else [1] * count
            for size in sizes:
                r = DROP_SCATTER_M * math.sqrt(rng.random())
                a = rng.random() * 2 * math.pi
                clat = lat + r * math.cos(a) / 111320.0
                clng = lng + r * math.sin(a) / (111320.0 * max(0.01, math.cos(math.radians(lat))))
                if stacked:            # a mix of regular found objects, visible to everyone
                    mix = stack_mix(rng, size)
                    item, q, mus, kind = max(mix, key=mix.get), sum(mix.values()), 0, "stack"
                else:                  # one crate: a cargo box (may hold specials) or a container
                    kind = "box" if rng.random() < BOX_SHARE else "container"
                    item, q, mus = roll(rng, table=BOX_LOOT if kind == "box" else LOOT)
                    mix = None
                conn.execute("INSERT INTO cargo_crates(id, dropper_hid, lat, lng, item_id, qty, museum_level, stacked, "
                             "crates, kind, mix, created_at, expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                             (uuid.uuid4().hex, hid, clat, clng, item, q, mus, 1 if stacked else 0, size, kind,
                              json.dumps(mix) if mix else None, now.isoformat(), exp))
            econ.emit(conn, "cargo_rain", hid, {"crates": count, "stacked": stacked},
                      lat=round(lat, 2), lng=round(lng, 2))
            out = {"err": 0, "dropped": len(sizes), "crates": count, "stacks": sizes if stacked else [],
                   "stacked": stacked, "left": stock(conn, hid)}
            if rid:
                econ.once_put(conn, "cargo_drop", hid, rid, out)
        return out

    @api.endpoint("/api/v1/cargo/nearby", feature="CARGO")
    def nearby(conn, hid, form):
        """Crates in a bbox that this player can see (Museum level), not collected, not expired."""
        try:
            lat1, lng1 = float(form.get("lat1")), float(form.get("lng1"))
            lat2, lng2 = float(form.get("lat2")), float(form.get("lng2"))
        except (TypeError, ValueError):
            raise econ.GameError("bad_input", "bbox missing")
        if (lat2 - lat1) * (lng2 - lng1) > 1.0:          # don't serve continent-sized boxes
            return {"err": 0, "crates": [], "tooLarge": True}
        museum = h.building_level(conn, hid, MUSEUM)
        rows = conn.execute(OPEN_SQL + " AND c.museum_level <= ? AND c.lat BETWEEN ? AND ? AND c.lng BETWEEN ? AND ? "
                            "LIMIT 2000", open_args(hid) + (museum, lat1, lat2, lng1, lng2)).fetchall()
        return {"err": 0, "crates": [{"id": r["id"], "lat": r["lat"], "lng": r["lng"], "itemID": r["item_id"],
                                      "stacked": bool(r["stacked"]), "count": r["crates"], "kind": r["kind"],
                                      "expiresAt": gone_at(r)} for r in rows]}

    @api.endpoint("/api/v1/cargo/collect", feature="CARGO")
    def collect(conn, hid, form):
        """Collect one crate. method=hand (normal crates), truck or drone (stacked crates).
        lat/lng = player's position (validated against the crate's position and the range)."""
        crate_id = (form.get("id") or "").strip()
        method = form.get("method", "hand")
        lat, lng = econ.parse_pos(form)
        with econ.tx(conn):
            h.check_travel(conn, hid, lat, lng)
            c = conn.execute(OPEN_SQL + " AND c.id=?", open_args(hid) + (crate_id,)).fetchone()
            if not c:
                raise econ.GameError("gone", "This crate is gone (or you already collected it)")
            lv = levels(conn, hid)
            if lv["museum"] < c["museum_level"]:
                raise econ.GameError("not_visible", "Your Museum level is too low for this crate")
            d = econ.dist_m(lat, lng, c["lat"], c["lng"])
            if c["stacked"]:
                n = int(c["crates"] or STACK_SIZE)
                need = vehicles_for(n)
                if method == "truck":                 # one truck per 100 crates, not used up
                    have = int(econ.qty_of(conn, hid, TRUCKS))
                    if have < need:
                        raise econ.GameError("no_vehicle", f"This stack holds {n:,} crates, so you need {need:,} trucks "
                                                           f"(you have {have:,})")
                    econ.require_within(lat, lng, c["lat"], c["lng"], truck_range(lv["haulage"]), "stack")
                elif method == "drone":               # one drone per 100 crates, not used up
                    rng_m = drone_range(lv["droneResearch"])
                    if rng_m <= 0:
                        raise econ.GameError("locked", f"Drone pick-up needs Drone Research level {DRONE_DR_LEVEL}")
                    econ.require_within(lat, lng, c["lat"], c["lng"], rng_m, "stack")
                    have = int(econ.qty_of(conn, hid, SCAN_DRONE))
                    if have < need:
                        raise econ.GameError("insufficient_items", f"This stack holds {n:,} crates, so you need "
                                                                   f"{need:,} Scan Drones (you have {have:,})")
                else:
                    raise econ.GameError("needs_vehicle", "Stacked cargo can only be collected by truck or drone")
            else:
                if method != "hand":
                    raise econ.GameError("bad_input", "Collect normal crates by hand")
                econ.require_within(lat, lng, c["lat"], c["lng"], collect_range(lv["museum"]), "crate")
            got = take_crate(conn, hid, c, lv["museum"])
        if isinstance(got, dict):
            return {"err": 0, "items": by_rarity(got),
                    "distance": round(d)}
        return {"err": 0, "itemID": c["item_id"], "qty": got, "distance": round(d)}

    @api.endpoint("/api/v1/cargo/truck", feature="CARGO")
    def truck(conn, hid, form):
        """Collect every crate in truck range with your trucks (Haulage Firm ≥ 5).
        preview=1 → how many crates/stacks are in range and how many trucks that needs."""
        lat, lng = econ.parse_pos(form)
        preview = form.get("preview") == "1"
        with econ.tx(conn):
            h.check_travel(conn, hid, lat, lng)
            lv = levels(conn, hid)
            if lv["haulage"] < TRUCK_HF_LEVEL:
                raise econ.GameError("locked", f"Truck collection needs Haulage Firm level {TRUCK_HF_LEVEL}")
            trucks = int(econ.qty_of(conn, hid, TRUCKS))
            rng_m = truck_range(lv["haulage"])
            s_lat, n_lat, w_lng, e_lng = econ.bbox(lat, lng, rng_m)
            rows = [c for c in conn.execute(OPEN_SQL + " AND c.museum_level <= ? AND c.lat BETWEEN ? AND ? "
                                            "AND c.lng BETWEEN ? AND ? ORDER BY c.stacked, c.created_at",
                                            open_args(hid) + (lv["museum"], s_lat, n_lat, w_lng, e_lng)).fetchall()
                    if econ.dist_m(lat, lng, c["lat"], c["lng"]) <= rng_m]
            normal = [c for c in rows if not c["stacked"]]
            stacks = [c for c in rows if c["stacked"]]
            stack_crates = sum(int(c["crates"] or STACK_SIZE) for c in stacks)
            needed = vehicles_for(len(normal) + stack_crates)         # one truck per 100 crates
            if preview or not rows:
                return {"err": 0, "crates": len(normal) + stack_crates, "loose": len(normal), "stacks": len(stacks),
                        "stackCrates": stack_crates, "trucksNeeded": needed, "trucks": trucks, "range": rng_m}
            if trucks < 1:
                raise econ.GameError("no_vehicle", "You have no Trucks")
            # fill the trucks (100 crates each): loose crates first, then whole stacks that still fit
            capacity = trucks * CRATES_PER_VEHICLE
            chosen = normal[:capacity]
            free = capacity - len(chosen)
            for c in stacks:
                n = int(c["crates"] or STACK_SIZE)
                if n <= free:
                    chosen.append(c)
                    free -= n
            got = {}
            for c in chosen:
                try:
                    q = take_crate(conn, hid, c, lv["museum"], strict=False)
                except econ.GameError:
                    continue
                for k, v in (q.items() if isinstance(q, dict) else ((c["item_id"], q),)):
                    if v > 0:
                        got[k] = got.get(k, 0) + v
            collected = sum(int(c["crates"] or 1) for c in chosen)
            used = vehicles_for(collected)
        return {"err": 0, "trucksUsed": used, "trucks": trucks, "collected": collected,
                "left": len(normal) + stack_crates - collected,
                "items": by_rarity(got)}

    @api.endpoint("/api/v1/cargo/recycle", feature="RECYCLING")
    def recycle(conn, hid, form):
        """Recycle found objects in the Recycling Plant (ratios are assumptions, see RECYCLE)."""
        item_id = int_arg(form, "itemID", None, 1)
        qty = int_arg(form, "qty", None, 0, 10**12)                 # whole units
        if item_id not in RECYCLE or qty <= 0:
            raise econ.GameError("bad_input", "This item can't be recycled")
        with econ.tx(conn):
            level = h.building_level(conn, hid, RECYCLING_PLANT)
            if level < 1:
                raise econ.GameError("locked", "Build a Recycling Plant first")
            yield_ = 0.5 + 0.05 * min(10, level)      # 55% at L1 … 100% at L10 (assumed)
            yield_ *= 1 + archaeology.effect(conn, hid, 174) / 100    # Shadow Obelisk: +15/20/30 %
            econ.take(conn, hid, item_id, qty, "recycle_in")
            out = []
            for target, per_unit in RECYCLE[item_id]:
                q = qty * per_unit * yield_ / len(RECYCLE[item_id])
                if q > 0:
                    got = econ.give(conn, hid, target, q, "recycle_out", strict=False)   # whole units, fraction carried
                    if got:
                        out.append({"itemID": target, "qty": int(got)})
        return {"err": 0, "outputs": out, "yield": round(yield_, 3)}

    @api.endpoint("/api/v1/cargo/recycling", feature="RECYCLING")
    def recycling_info(conn, hid, form):
        """What can be recycled, into what, and your yield."""
        level = h.building_level(conn, hid, RECYCLING_PLANT)
        base = (0.5 + 0.05 * min(10, level)) if level else 0
        obelisk = archaeology.effect(conn, hid, 174)
        y = base * (1 + obelisk / 100)
        return {"err": 0, "plantLevel": level, "yield": round(y, 3), "plantYield": round(base, 3),
                "obeliskBonus": obelisk, "recipes": [
            {"itemID": i, "owned": int(econ.qty_of(conn, hid, i)),
             "outputs": [{"itemID": t, "perUnit": round(u * y / len(outs), 4)} for t, u in outs]}
            for i, outs in RECYCLE.items()]}
