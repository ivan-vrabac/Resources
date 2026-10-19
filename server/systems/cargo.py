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
  range, 100 m + 10 m/level) — TRUCK_CAPACITY crates or one stack per truck; trucks aren't used up.
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
MAX_STACKS_PER_DROP = 10
DROP_SCATTER_M = 40.0
CRATE_HOURS = 24
GONE_AFTER_FIRST_S = 15 * 60
TRUCK_CAPACITY = 10          # normal crates per truck per run (a stack needs one truck)
TRUCK_HF_LEVEL = 5
LOCAL_RANGE_BASE_M = 50.0
LOCAL_RANGE_PER_MUSEUM_M = 15.0
MUSEUM_QTY_BONUS = 0.05

# sfo.txt found objects: item_id → (name, drop chance %, museum level)
LOOT = {
    57: ("Old Tires", 11.5, 0), 41: ("Fossils", 23.0, 0), 55: ("Copper Coins", 21.85, 0),
    40: ("Roman Coins", 14.95, 0), 70: ("Scrap Metal", 9.11, 3), 74: ("Used Oil", 7.36, 4),
    43: ("Maintenance Kit", 7.36, 4), 115: ("Waste Glass", 5.52, 6), 78: ("Electronic Scrap", 5.29, 6),
    77: ("Plastic Scrap", 4.6, 6), 120: ("Drone Wreckage", 3.68, 7),
    # sfo.txt also lists Giant Diamond, Tech Upgrades 1–4 and the production boosters 158–161;
    # the owner excluded those from cargo (2026-10-19).
}
# Assumed quantity per crate (min, max) — not in the sources.
QTY = {57: (1, 20), 41: (1, 20), 55: (1, 10), 40: (1, 10), 70: (5, 50), 74: (5, 50), 43: (1, 1),
       115: (5, 50), 78: (5, 30), 77: (5, 50), 120: (1, 3), 42: (1, 1), 44: (1, 3), 45: (1, 2),
       46: (1, 2), 48: (1, 1), 159: (1, 1), 158: (1, 1), 160: (1, 1), 161: (1, 1)}
# Recycling sources from sfo.txt and srs.txt ("*From recycling"); the ratios are not in the
# sources and are a documented proposal: input → [(output, units of output per input unit)].
# The units are split evenly over the outputs, then × the Recycling Plant yield.
RECYCLE = {
    41: [(2, 10), (10, 2), (20, 6), (3, 6), (53, 6)],   # fossils → clay, crude oil, limestone, gravel, quartz sand (srs.txt)
    120: [(70, 3), (74, 2), (78, 2), (77, 2)],          # drone wreckage → scrap metal, used oil, e-scrap, plastic scrap
    115: [(70, 0.5), (77, 0.5)],                         # waste glass → scrap metal, plastic scrap
    74: [(70, 0.5), (10, 0.5)],                          # used oil → scrap metal, crude oil (srs.txt)
    77: [(74, 0.5)],                                     # plastic scrap → used oil
    43: [(77, 5)],                                       # maintenance kit → plastic scrap
    55: [(44, 0.01)],                                    # copper coins → Tech Upgrade I
    40: [(45, 0.01)],                                    # roman coins → Tech Upgrade II
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
        CREATE TABLE IF NOT EXISTS cargo_pickups (
            crate_id TEXT NOT NULL,
            hid      TEXT NOT NULL,
            ts       TEXT NOT NULL,
            PRIMARY KEY (crate_id, hid)
        );
    """)
    # crates of earlier builds that hold items no longer allowed in cargo: drop them
    conn.execute("DELETE FROM cargo_crates WHERE item_id IN (42, 44, 45, 46, 48, 158, 159, 160, 161) "
                 "AND collected_by IS NULL")


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
        amount = int(round(c["qty"] * (1 + MUSEUM_QTY_BONUS * museum)))
        got = int(econ.give(conn, hid, c["item_id"], amount, "cargo_collect", c["id"], strict=strict))
        econ.emit(conn, "cargo_collected", hid, {"crates": STACK_SIZE if c["stacked"] else 1,
                                                  "itemID": c["item_id"], "qty": got}, public=False)
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
        rows = conn.execute(OPEN_SQL + " AND c.museum_level <= ? AND c.lat BETWEEN ? AND ? AND c.lng BETWEEN ? AND ? "
                            "LIMIT 2000", open_args(hid) + (museum, lat1, lat2, lng1, lng2)).fetchall()
        return {"err": 0, "crates": [{"id": r["id"], "lat": r["lat"], "lng": r["lng"], "itemID": r["item_id"],
                                      "stacked": bool(r["stacked"]), "expiresAt": gone_at(r)} for r in rows]}

    @api.endpoint("/api/v1/cargo/collect", feature="CARGO")
    def collect(conn, hid, form):
        """Collect one crate. method=hand (normal crates), truck or drone (stacked crates).
        lat/lng = player's position (validated against the crate's position and the range)."""
        crate_id = (form.get("id") or "").strip()
        method = form.get("method", "hand")
        lat, lng = econ.parse_pos(form)
        with econ.tx(conn):
            c = conn.execute(OPEN_SQL + " AND c.id=?", open_args(hid) + (crate_id,)).fetchone()
            if not c:
                raise econ.GameError("gone", "This crate is gone (or you already collected it)")
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
            got = take_crate(conn, hid, c, lv["museum"])
        return {"err": 0, "itemID": c["item_id"], "qty": got, "distance": round(d)}

    @api.endpoint("/api/v1/cargo/truck", feature="CARGO")
    def truck(conn, hid, form):
        """Collect every crate in truck range with your trucks (Haulage Firm ≥ 5).
        preview=1 → how many crates/stacks are in range and how many trucks that needs."""
        lat, lng = econ.parse_pos(form)
        preview = form.get("preview") == "1"
        with econ.tx(conn):
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
            needed = math.ceil(len(normal) / TRUCK_CAPACITY) + len(stacks)
            if preview or not rows:
                return {"err": 0, "crates": len(normal), "stacks": len(stacks), "trucksNeeded": needed,
                        "trucks": trucks, "range": rng_m}
            if trucks < 1:
                raise econ.GameError("no_vehicle", "You have no Trucks")
            # fill the trucks: normal crates first (TRUCK_CAPACITY per truck), then one stack per truck
            loads = min(len(normal), trucks * TRUCK_CAPACITY)
            free = trucks - math.ceil(loads / TRUCK_CAPACITY)
            chosen = normal[:loads] + stacks[:max(0, free)]
            got = {}
            for c in chosen:
                try:
                    q = take_crate(conn, hid, c, lv["museum"], strict=False)
                except econ.GameError:
                    continue
                if q > 0:
                    got[c["item_id"]] = got.get(c["item_id"], 0) + q
            used = math.ceil(loads / TRUCK_CAPACITY) + min(len(stacks), max(0, free))
        return {"err": 0, "trucksUsed": used, "trucks": trucks, "collected": len(chosen),
                "left": len(rows) - len(chosen),
                "items": [{"itemID": k, "qty": v} for k, v in sorted(got.items(), key=lambda x: -x[1])]}

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
        y = (0.5 + 0.05 * min(10, level)) * (1 + archaeology.effect(conn, hid, 174) / 100) if level else 0
        return {"err": 0, "plantLevel": level, "yield": round(y, 3), "recipes": [
            {"itemID": i, "owned": int(econ.qty_of(conn, hid, i)),
             "outputs": [{"itemID": t, "perUnit": round(u * y / len(outs), 4)} for t, u in outs]}
            for i, outs in RECYCLE.items()]}
