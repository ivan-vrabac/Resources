"""Phase 5 — archaeology: artifact detector, discovery, recovery, museum collection.

Items (existing constants): Archaeological Center 164 (special building, levels 1–10),
Artifact Detector 166, Archaeologists 167, artifacts 172–177 (Astrolabium, Throne of Depths,
Shadow Obelisk, Thor's Crucible, Aeon Mechanism, Dwarven Pick), Museum 65.

Rules (owner's rules 2026-10-19 marked *, the rest a documented proposal):
- Sites: the world is split into CELL_DEG cells; each cell holds one artifact site per 24-hour
  period* with probability SITE_CHANCE, at a deterministic random spot (hash of cell + period).
- * Several players can recover the same artifact (each once). After the first recovery the
  site disappears 15 minutes later (GONE_AFTER_FIRST_S); otherwise it lasts its 24 hours.
- * Every detector scan uses up one Artifact Detector (166). Needs Archaeological Center ≥ 1.
  Detection range 300 m + 20 m × level (500 m at level 10); the scan reports a bearing and a band.
- * Reveal range: 100 m at Center level 1 → 300 m at level 10 (linear).
- Recovery: within the Museum pick-up range (50 m + 25 m × Museum level, 300 m at level 10, same as
  Cargo Rain);
  * uses 100 Archaeologists at Center level 1 → 70 at level 10 (linear).
"""
from __future__ import annotations

import datetime
import hashlib
import math
import random

import econ

ARCH_CENTER = 164
DETECTOR = 166
ARCHAEOLOGISTS = 167
MUSEUM = 65
ARTIFACTS = {172: "Astrolabium", 173: "Throne of Depths", 174: "Shadow Obelisk",
             175: "Thor's Crucible", 176: "Aeon Mechanism", 177: "Dwarven Pick"}
# Artifact levels (owner's rules 2026-10-19): invest artifacts of a kind — 100 → level 1,
# 500 → level 2, 1000 → level 3 (total invested). Effects per level 1/2/3:
LEVEL_AT = (100, 500, 1000)
ARTIFACT_EFFECTS = {
    172: ("Remote (drone) construction every {} h", (12, 11, 10, 8)),        # Astrolabium: cooldown hours
    173: ("{}% chance to recover two artifacts", (0, 10, 20, 30)),           # Throne of Depths
    174: ("+{}% recycling yield", (0, 15, 20, 30)),                           # Shadow Obelisk
    175: ("Factory instant production cooldown −{}%", (0, 15, 20, 30)),       # Thor's Crucible
    176: ("+{}% quest rewards", (0, 10, 20, 30)),                             # Aeon Mechanism
    177: ("Mine repairs (credits) −{}%", (0, 25, 35, 50)),                    # Dwarven Pick
}
ARTIFACT_WEIGHTS = {172: 30, 173: 10, 174: 20, 175: 15, 176: 5, 177: 20}
CELL_DEG = 0.02
SITE_CHANCE = 0.35
PERIOD_S = 24 * 3600
GONE_AFTER_FIRST_S = 15 * 60


def detect_range(level: int) -> float:
    """320 m at Center level 1 … 500 m at level 10 (owner 2026-10-20: at most 500 m)."""
    return 0.0 if level < 1 else 300.0 + 20.0 * min(10, level)


def reveal_range(level: int) -> float:
    return 0.0 if level < 1 else round(100.0 + (min(10, level) - 1) * 200.0 / 9, 1)


def pickup_range(museum_level: int) -> float:
    """50 m without a Museum … 300 m at Museum level 10 (owner 2026-10-20: at most 300 m)."""
    return 50.0 + 25.0 * max(0, min(10, museum_level))


def archaeologists_needed(level: int) -> int:
    return int(round(100 - (max(1, min(10, level)) - 1) * 30 / 9))


def period_of(now: datetime.datetime) -> str:
    """24-hour site period id, e.g. 'D20380'."""
    return f"D{int(now.replace(tzinfo=datetime.timezone.utc).timestamp() // PERIOD_S)}"


def level_for(invested: int) -> int:
    return sum(1 for t in LEVEL_AT if invested >= t)


def artifact_level(conn, hid, item_id) -> int:
    """Investment level 0–3 of one artifact kind for a player (0 if the table doesn't exist yet)."""
    try:
        r = conn.execute("SELECT invested FROM artifact_levels WHERE hid=? AND item_id=?", (hid, item_id)).fetchone()
    except Exception:
        return 0
    return level_for(int(r[0])) if r else 0


def effect(conn, hid, item_id) -> float:
    """The artifact's effect value at the player's level (hours for 172, percent for the others)."""
    return ARTIFACT_EFFECTS[item_id][1][artifact_level(conn, hid, item_id)]


def _h(*parts) -> int:
    return int(hashlib.sha256("|".join(map(str, parts)).encode()).hexdigest()[:15], 16)


def site_in_cell(cx: int, cy: int, period: str):
    """Deterministic artifact site of a cell for a period, or None."""
    r = _h("site", cx, cy, period)
    if (r % 10000) / 10000.0 >= SITE_CHANCE:
        return None
    fx = (_h("x", cx, cy, period) % 100000) / 100000.0
    fy = (_h("y", cx, cy, period) % 100000) / 100000.0
    total = sum(ARTIFACT_WEIGHTS.values())
    pick = _h("t", cx, cy, period) % total
    for item, wgt in ARTIFACT_WEIGHTS.items():
        if pick < wgt:
            break
        pick -= wgt
    return {"id": f"{cx}:{cy}:{period}", "lat": (cy + fy) * CELL_DEG, "lng": (cx + fx) * CELL_DEG,
            "item": item}


def sites_near(lat, lng, radius_m, period):
    lat1, lat2, lng1, lng2 = econ.bbox(lat, lng, radius_m)
    out = []
    for cy in range(math.floor(lat1 / CELL_DEG), math.floor(lat2 / CELL_DEG) + 1):
        for cx in range(math.floor(lng1 / CELL_DEG), math.floor(lng2 / CELL_DEG) + 1):
            s = site_in_cell(cx, cy, period)
            if s:
                s["dist"] = econ.dist_m(lat, lng, s["lat"], s["lng"])
                if s["dist"] <= radius_m:
                    out.append(s)
    return sorted(out, key=lambda s: s["dist"])


def bearing_deg(lat1, lng1, lat2, lng2) -> float:
    p = math.pi / 180
    y = math.sin((lng2 - lng1) * p) * math.cos(lat2 * p)
    x = math.cos(lat1 * p) * math.sin(lat2 * p) - math.sin(lat1 * p) * math.cos(lat2 * p) * math.cos((lng2 - lng1) * p)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def band(d: float) -> str:
    for limit, label in ((100, "very close"), (500, "close"), (1500, "near"), (3000, "far")):
        if d <= limit:
            return label
    return "very far"


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS artifact_recoveries (
            site_id    TEXT NOT NULL,
            hid        TEXT NOT NULL,
            item_id    INTEGER NOT NULL,
            lat        REAL NOT NULL,
            lng        REAL NOT NULL,
            ts         TEXT NOT NULL,
            PRIMARY KEY (site_id, hid)
        );
    """)
    # earlier builds: one recovery per site (site_id PRIMARY KEY) → one per site and player
    pk = [r[1] for r in conn.execute("PRAGMA table_info(artifact_recoveries)") if r[5]]
    if pk == ["site_id"]:
        conn.executescript("""
            ALTER TABLE artifact_recoveries RENAME TO artifact_recoveries_old;
            CREATE TABLE artifact_recoveries (
                site_id TEXT NOT NULL, hid TEXT NOT NULL, item_id INTEGER NOT NULL,
                lat REAL NOT NULL, lng REAL NOT NULL, ts TEXT NOT NULL, PRIMARY KEY (site_id, hid));
            INSERT INTO artifact_recoveries SELECT site_id, hid, item_id, lat, lng, ts FROM artifact_recoveries_old;
            DROP TABLE artifact_recoveries_old;
        """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_artrec_hid ON artifact_recoveries(hid)")
    conn.execute("""CREATE TABLE IF NOT EXISTS artifact_levels (
        hid TEXT NOT NULL, item_id INTEGER NOT NULL, invested INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (hid, item_id))""")
    conn.commit()


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)

    def levels(conn, hid):
        lvl = h.building_level(conn, hid, ARCH_CENTER)
        mus = h.building_level(conn, hid, MUSEUM)
        return {"centerLevel": lvl, "museumLevel": mus, "detectRange": detect_range(lvl),
                "revealRange": reveal_range(lvl), "pickupRange": pickup_range(mus),
                "archaeologistsNeeded": archaeologists_needed(lvl),
                "detectors": econ.qty_of(conn, hid, DETECTOR),
                "archaeologists": econ.qty_of(conn, hid, ARCHAEOLOGISTS)}

    def unavailable(conn, hid, site_ids):
        """Sites this player already recovered, or first recovered by anyone > 15 min ago."""
        if not site_ids:
            return set()
        q = ",".join("?" * len(site_ids))
        cutoff = (econ.utcnow() - datetime.timedelta(seconds=GONE_AFTER_FIRST_S)).isoformat()
        rows = conn.execute(f"SELECT site_id, MIN(ts), MAX(hid=?) FROM artifact_recoveries WHERE site_id IN ({q}) "
                            f"GROUP BY site_id", [hid, *site_ids]).fetchall()
        return {r[0] for r in rows if r[2] or r[1] < cutoff}

    @api.endpoint("/api/v1/archaeology/status", feature="ARCHAEOLOGY")
    def status(conn, hid, form):
        coll = {}
        for r in conn.execute("SELECT item_id, COUNT(*) FROM artifact_recoveries WHERE hid=? GROUP BY item_id", (hid,)):
            coll[r[0]] = r[1]
        inv = {r[0]: int(r[1]) for r in conn.execute("SELECT item_id, invested FROM artifact_levels WHERE hid=?", (hid,))}

        def entry(i, n):
            invested = inv.get(i, 0)
            lvl = level_for(invested)
            text, vals = ARTIFACT_EFFECTS[i]
            return {"itemID": i, "name": n, "found": coll.get(i, 0), "owned": int(econ.qty_of(conn, hid, i)),
                    "invested": invested, "level": lvl, "nextAt": LEVEL_AT[lvl] if lvl < 3 else None,
                    "effect": text.format(vals[lvl]) if (lvl or i == 172) else None,
                    "effects": [text.format(v) for v in vals[1:]]}
        return {"err": 0, **levels(conn, hid), "levelAt": LEVEL_AT,
                "collection": [entry(i, n) for i, n in ARTIFACTS.items()]}

    @api.endpoint("/api/v1/archaeology/invest", feature="ARCHAEOLOGY")
    def invest(conn, hid, form):
        """Invest artifacts of one kind to raise its level (100 / 500 / 1000 in total)."""
        item = int(form.get("itemID") or 0)
        try:
            qty = int(form.get("qty") or 0)
        except ValueError:
            qty = 0
        if item not in ARTIFACTS or qty <= 0:
            raise econ.GameError("bad_input", "Choose an artifact and a quantity")
        with econ.tx(conn):
            econ.take(conn, hid, item, qty, "artifact_invest")
            conn.execute("INSERT INTO artifact_levels(hid, item_id, invested) VALUES(?,?,?) ON CONFLICT(hid, item_id) "
                         "DO UPDATE SET invested = invested + excluded.invested", (hid, item, qty))
            invested = conn.execute("SELECT invested FROM artifact_levels WHERE hid=? AND item_id=?",
                                    (hid, item)).fetchone()[0]
        return {"err": 0, "itemID": item, "invested": invested, "level": level_for(invested)}

    @api.endpoint("/api/v1/archaeology/detect", feature="ARCHAEOLOGY")
    def detect(conn, hid, form):
        """One scan (uses up one Artifact Detector): direction to the nearest artifact this player
        can still recover in detection range; the position only within the reveal range."""
        lat, lng = econ.parse_pos(form)
        with econ.tx(conn):
            lv = levels(conn, hid)
            if lv["centerLevel"] < 1:
                raise econ.GameError("locked", "Build an Archaeological Center first")
            if lv["detectors"] < 1:
                raise econ.GameError("no_detector", "You need an Artifact Detector")
            econ.take(conn, hid, DETECTOR, 1, "artifact_scan")
        left = int(lv["detectors"]) - 1
        sites = sites_near(lat, lng, lv["detectRange"], period_of(econ.utcnow()))
        done = unavailable(conn, hid, [s["id"] for s in sites])
        sites = [s for s in sites if s["id"] not in done]
        if not sites:
            return {"err": 0, "found": False, "detectRange": lv["detectRange"], "detectorsLeft": left}
        s = sites[0]
        out = {"err": 0, "found": True, "bearing": round(bearing_deg(lat, lng, s["lat"], s["lng"]), 1),
               "band": band(s["dist"]), "detectRange": lv["detectRange"], "revealRange": lv["revealRange"],
               "detectorsLeft": left}
        if s["dist"] <= lv["revealRange"]:
            out["revealed"] = {"id": s["id"], "lat": s["lat"], "lng": s["lng"], "itemID": s["item"],
                               "name": ARTIFACTS[s["item"]], "distance": round(s["dist"])}
        return out

    @api.endpoint("/api/v1/archaeology/recover", feature="ARCHAEOLOGY")
    def recover(conn, hid, form):
        site_id = (form.get("id") or "").strip()
        lat, lng = econ.parse_pos(form)
        try:
            cx, cy, period = site_id.split(":")
            site = site_in_cell(int(cx), int(cy), period)
        except ValueError:
            site = None
        if not site or period != period_of(econ.utcnow()):
            raise econ.GameError("gone", "This artifact site is gone")
        with econ.tx(conn):
            lv = levels(conn, hid)
            if lv["centerLevel"] < 1:
                raise econ.GameError("locked", "Build an Archaeological Center first")
            d = econ.dist_m(lat, lng, site["lat"], site["lng"])
            if d > lv["revealRange"]:
                raise econ.GameError("not_revealed", "Get closer to reveal the artifact first")
            econ.require_within(lat, lng, site["lat"], site["lng"], lv["pickupRange"], "artifact")
            if site_id in unavailable(conn, hid, [site_id]):
                raise econ.GameError("gone", "You already recovered this artifact, or it is gone")
            need = lv["archaeologistsNeeded"]
            econ.take(conn, hid, ARCHAEOLOGISTS, need, "artifact_recovery", site_id)
            cur = conn.execute("INSERT OR IGNORE INTO artifact_recoveries(site_id, hid, item_id, lat, lng, ts) "
                               "VALUES(?,?,?,?,?,?)", (site_id, hid, site["item"], site["lat"], site["lng"],
                                                       econ.utcnow_iso()))
            if cur.rowcount != 1:
                raise econ.GameError("gone", "You already recovered this artifact")
            n = 2 if random.random() * 100 < effect(conn, hid, 173) else 1      # Throne of Depths
            econ.give(conn, hid, site["item"], n, "artifact_recovery", site_id, ignore_capacity=True)
            econ.emit(conn, "artifact_found", hid, {"itemID": site["item"], "name": ARTIFACTS[site["item"]]},
                      lat=round(site["lat"], 2), lng=round(site["lng"], 2), dedup=f"artifact:{site_id}:{hid}")
            conn.execute("INSERT OR IGNORE INTO achievements(hid, code, title, ts) VALUES(?,?,?,?)",
                         (hid, f"artifact_{site['item']}", f"Found {ARTIFACTS[site['item']]}", econ.utcnow_iso()))
        return {"err": 0, "itemID": site["item"], "name": ARTIFACTS[site["item"]], "archaeologistsUsed": need,
                "count": n}
