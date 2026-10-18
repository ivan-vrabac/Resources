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
- Pick-up is exclusive: the first valid collector gets the crate (atomic conditional update);
  retries and simultaneous attempts can't pay twice. (eva.txt describes shared crates; next.txt
  requires preventing duplicate collection, which takes precedence.)
- Stacked Cargo Rain (one map object = 100 crates' contents) unlocks at Haulage Firm level
  STACK_HF_LEVEL. Stacks can only be collected by truck (needs ≥1 Trucks item, 124, not used up;
  within the hand collection range) or by drone (uses 1 Scan Drone, 117; needs Drone Research ≥ 5
  as in eva.txt; within the drone scan range).
- Crates expire CRATE_HOURS after being dropped.
- Recycling (sfo.txt "*From recycling" sources) needs ratios the sources don't give: implemented
  with RECYCLE ratios below behind feature flag RECYCLING (off by default) — decision needed.
"""
from __future__ import annotations

import datetime
import json
import math
import random
import uuid

import econ
from . import float_arg, int_arg

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
MAX_STACKS_PER_DROP = 10
DROP_SCATTER_M = 40.0
CRATE_HOURS = 60
LOCAL_RANGE_BASE_M = 50.0
LOCAL_RANGE_PER_MUSEUM_M = 15.0
MUSEUM_QTY_BONUS = 0.05

# sfo.txt found objects: item_id → (name, drop chance %, museum level)
LOOT = {
    57: ("Old Tires", 11.5, 0), 41: ("Fossils", 23.0, 0), 55: ("Copper Coins", 21.85, 0),
    40: ("Roman Coins", 14.95, 0), 70: ("Scrap Metal", 9.11, 3), 74: ("Used Oil", 7.36, 4),
    43: ("Maintenance Kit", 7.36, 4), 115: ("Waste Glass", 5.52, 6), 78: ("Electronic Scrap", 5.29, 6),
    77: ("Plastic Scrap", 4.6, 6), 120: ("Drone Wreckage", 3.68, 7), 42: ("Giant Diamond", 0.02, 10),
    44: ("Tech Upgrade 1", 0.58, 10), 45: ("Tech Upgrade 2", 0.23, 10), 46: ("Tech Upgrade 3", 0.12, 10),
    48: ("Tech Upgrade 4", 0.02, 10), 159: ("Overtime", 0.12, 0), 158: ("Night Shift", 0.12, 0),
    160: ("Guest Workers", 0.12, 0), 161: ("Wage Subsidy", 0.12, 0),
}
# Assumed quantity per crate (min, max) — not in the sources.
QTY = {57: (1, 20), 41: (1, 20), 55: (1, 10), 40: (1, 10), 70: (5, 50), 74: (5, 50), 43: (1, 1),
       115: (5, 50), 78: (5, 30), 77: (5, 50), 120: (1, 3), 42: (1, 1), 44: (1, 3), 45: (1, 2),
       46: (1, 2), 48: (1, 1), 159: (1, 1), 158: (1, 1), 160: (1, 1), 161: (1, 1)}
# Recycling (sfo.txt sources; ratios assumed): input → [(output, units of output per input unit)]
RECYCLE = {
    120: [(70, 3), (74, 2), (78, 2), (77, 2)],   # drone wreckage
    115: [(70, 0.5), (77, 0.5)],                  # waste glass
    74: [(70, 0.5)],                              # used oil
    77: [(74, 0.5)],                              # plastic scrap
    43: [(77, 5)],                                # maintenance kit
    55: [(44, 0.01)],                             # copper coins → TU1
    40: [(45, 0.01)],                             # roman coins → TU2
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
            created_at   TEXT NOT NULL,
            expires_at   TEXT NOT NULL,
            collected_by TEXT,
            collected_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_crates_geo ON cargo_crates(lat, lng);
        CREATE INDEX IF NOT EXISTS idx_crates_open ON cargo_crates(collected_by, expires_at);
    """)


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


def collect_range(museum_level: int) -> float:
    return LOCAL_RANGE_BASE_M + LOCAL_RANGE_PER_MUSEUM_M * max(0, min(10, museum_level))


def roll(rng: random.Random, stacked: bool = False):
    """Roll one crate's content: (item_id, qty, museum level). A stack holds STACK_SIZE crates of
    the same rolled item."""
    items = list(LOOT)
    item = rng.choices(items, weights=[LOOT[i][1] for i in items])[0]
    lo, hi = QTY[item]
    n = STACK_SIZE if stacked else 1
    q = sum(rng.randint(lo, hi) for _ in range(n)) if hi > lo else lo * n
    return item, q, LOOT[item][2]


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

    def drone_range(dr_level: int) -> float:
        if dr_level < DRONE_DR_LEVEL:
            return 0.0
        return float(h.DRONE_SCAN_RANGES[min(dr_level, len(h.DRONE_SCAN_RANGES)) - 1])

    @api.endpoint("/api/v1/cargo/stock", feature="CARGO")
    def get_stock(conn, hid, form):
        lv = levels(conn, hid)
        return {"err": 0, "crates": stock(conn, hid), **lv,
                "collectRange": collect_range(lv["museum"]),
                "droneRange": drone_range(lv["droneResearch"]),
                "stackUnlocked": lv["haulage"] >= STACK_HF_LEVEL, "stackSize": STACK_SIZE,
                "stackHaulageLevel": STACK_HF_LEVEL, "maxDrop": MAX_DROP,
                "trucks": econ.qty_of(conn, hid, TRUCKS), "drones": econ.qty_of(conn, hid, SCAN_DRONE)}

    @api.endpoint("/api/v1/cargo/drop", feature="CARGO")
    def drop(conn, hid, form):
        """Drop crates around the player's position: count=1..100 normal crates, or stacks=1..10
        stacked crates (100 each, Haulage Firm level ≥ 5)."""
        lat, lng = econ.parse_pos(form)
        stacks = int_arg(form, "stacks", 0, 0, MAX_STACKS_PER_DROP)
        count = 0 if stacks else int_arg(form, "count", None, 1, MAX_DROP)
        rid = (form.get("rid") or "").strip()[:64]
        with econ.tx(conn):
            if rid:
                prev = econ.once_get(conn, "cargo_drop", hid, rid)
                if prev is not None:
                    return prev
            if stacks and h.building_level(conn, hid, HAULAGE_FIRM) < STACK_HF_LEVEL:
                raise econ.GameError("locked", f"Stacked Cargo Rain needs Haulage Firm level {STACK_HF_LEVEL}")
            spend(conn, hid, stacks * STACK_SIZE if stacks else count, "drop")
            rng = random.Random()
            now = econ.utcnow()
            exp = (now + datetime.timedelta(hours=CRATE_HOURS)).isoformat()
            n_objects = stacks or count
            for _ in range(n_objects):
                r = DROP_SCATTER_M * math.sqrt(rng.random())
                a = rng.random() * 2 * math.pi
                clat = lat + r * math.cos(a) / 111320.0
                clng = lng + r * math.sin(a) / (111320.0 * max(0.01, math.cos(math.radians(lat))))
                item, q, mus = roll(rng, stacked=bool(stacks))
                conn.execute("INSERT INTO cargo_crates(id, dropper_hid, lat, lng, item_id, qty, museum_level, stacked, "
                             "created_at, expires_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                             (uuid.uuid4().hex, hid, clat, clng, item, q, mus, 1 if stacks else 0,
                              now.isoformat(), exp))
            econ.emit(conn, "cargo_rain", hid, {"crates": stacks * STACK_SIZE if stacks else count,
                                                "stacked": bool(stacks)},
                      lat=round(lat, 2), lng=round(lng, 2))
            out = {"err": 0, "dropped": n_objects, "stacked": bool(stacks), "left": stock(conn, hid)}
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
        rows = conn.execute("SELECT id, lat, lng, item_id, stacked, expires_at FROM cargo_crates "
                            "WHERE collected_by IS NULL AND expires_at > ? AND museum_level <= ? "
                            "AND lat BETWEEN ? AND ? AND lng BETWEEN ? AND ? LIMIT 2000",
                            (econ.utcnow_iso(), museum, lat1, lat2, lng1, lng2)).fetchall()
        return {"err": 0, "crates": [{"id": r[0], "lat": r[1], "lng": r[2], "itemID": r[3],
                                      "stacked": bool(r[4]), "expiresAt": r[5]} for r in rows]}

    @api.endpoint("/api/v1/cargo/collect", feature="CARGO")
    def collect(conn, hid, form):
        """Collect one crate. method=hand (normal crates), truck or drone (stacked crates).
        lat/lng = player's position (validated against the crate's position and the range)."""
        crate_id = (form.get("id") or "").strip()
        method = form.get("method", "hand")
        lat, lng = econ.parse_pos(form)
        with econ.tx(conn):
            c = conn.execute("SELECT * FROM cargo_crates WHERE id=?", (crate_id,)).fetchone()
            if not c or c["collected_by"] or c["expires_at"] <= econ.utcnow_iso():
                raise econ.GameError("gone", "This crate is gone")
            lv = levels(conn, hid)
            if lv["museum"] < c["museum_level"]:
                raise econ.GameError("not_visible", "Your Museum level is too low for this crate")
            d = econ.dist_m(lat, lng, c["lat"], c["lng"])
            if c["stacked"]:
                if method == "truck":
                    if econ.qty_of(conn, hid, TRUCKS) < 1:
                        raise econ.GameError("no_vehicle", "You need a Truck to collect stacked cargo")
                    econ.require_within(lat, lng, c["lat"], c["lng"], collect_range(lv["museum"]), "stack")
                elif method == "drone":
                    rng_m = drone_range(lv["droneResearch"])
                    if rng_m <= 0:
                        raise econ.GameError("locked", f"Drone pick-up needs Drone Research level {DRONE_DR_LEVEL}")
                    econ.require_within(lat, lng, c["lat"], c["lng"], rng_m, "stack")
                    econ.take(conn, hid, SCAN_DRONE, 1, "cargo_drone", c["id"])
                else:
                    raise econ.GameError("needs_vehicle", "Stacked cargo can only be collected by truck or drone")
            else:
                if method != "hand":
                    raise econ.GameError("bad_input", "Collect normal crates by hand")
                econ.require_within(lat, lng, c["lat"], c["lng"], collect_range(lv["museum"]), "crate")
            cur = conn.execute("UPDATE cargo_crates SET collected_by=?, collected_at=? "
                               "WHERE id=? AND collected_by IS NULL", (hid, econ.utcnow_iso(), crate_id))
            if cur.rowcount != 1:          # someone else got it first
                raise econ.GameError("gone", "This crate is gone")
            amount = round(c["qty"] * (1 + MUSEUM_QTY_BONUS * lv["museum"]), 2)
            got = econ.give(conn, hid, c["item_id"], amount, "cargo_collect", c["id"], strict=True)
            crates = STACK_SIZE if c["stacked"] else 1
            econ.emit(conn, "cargo_collected", hid, {"crates": crates, "itemID": c["item_id"], "qty": got},
                      public=False)
            if c["item_id"] == 42 or c["item_id"] == 48:
                econ.emit(conn, "rare_find", hid, {"itemID": c["item_id"], "qty": got},
                          lat=round(c["lat"], 2), lng=round(c["lng"], 2))
        return {"err": 0, "itemID": c["item_id"], "qty": got, "distance": round(d)}

    @api.endpoint("/api/v1/cargo/recycle", feature="RECYCLING")
    def recycle(conn, hid, form):
        """Recycle found objects in the Recycling Plant (ratios are assumptions, see RECYCLE)."""
        item_id = int_arg(form, "itemID", None, 1)
        qty = float_arg(form, "qty", None, 0, 1e12)
        if item_id not in RECYCLE or qty <= 0:
            raise econ.GameError("bad_input", "This item can't be recycled")
        with econ.tx(conn):
            level = h.building_level(conn, hid, RECYCLING_PLANT)
            if level < 1:
                raise econ.GameError("locked", "Build a Recycling Plant first")
            yield_ = 0.5 + 0.05 * min(10, level)      # 55% at L1 … 100% at L10 (assumed)
            econ.take(conn, hid, item_id, qty, "recycle_in")
            out = []
            for target, per_unit in RECYCLE[item_id]:
                q = round(qty * per_unit * yield_ / len(RECYCLE[item_id]), 2)
                if q > 0:
                    econ.give(conn, hid, target, q, "recycle_out", ignore_capacity=False)
                    out.append({"itemID": target, "qty": q})
        return {"err": 0, "outputs": out, "yield": yield_}
