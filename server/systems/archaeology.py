"""Phase 5 — archaeology: artifact detector, discovery, recovery, museum collection.

Items (existing constants): Archaeological Center 164 (special building, levels 1–10),
Artifact Detector 166, Archaeologists 167, artifacts 172–177 (Astrolabium, Throne of Depths,
Shadow Obelisk, Thor's Crucible, Aeon Mechanism, Dwarven Pick), Museum 65.

Documented assumptions (configurable below — the sources define no numbers):
- Sites: the world is split into CELL_DEG cells; each cell holds one artifact site per ISO week
  with probability SITE_CHANCE, at a deterministic random spot (hash of cell + week). A site can
  be recovered once (first player wins, atomic); it then stays recovered for that week.
- Detector: needs ≥1 Artifact Detector and Archaeological Center ≥1. Detection range
  1000 m + 500 m × level. It reports only a bearing and a distance band, never the position.
- Reveal: within 50 m + 10 m × Center level the exact position is returned.
- Recovery: player within the Museum pick-up range (50 m + 15 m × Museum level, same as Cargo
  Rain), and consumes max(1, 10 − Center level) Archaeologists. The detector is not used up.
"""
from __future__ import annotations

import datetime
import hashlib
import math

import econ

ARCH_CENTER = 164
DETECTOR = 166
ARCHAEOLOGISTS = 167
MUSEUM = 65
ARTIFACTS = {172: "Astrolabium", 173: "Throne of Depths", 174: "Shadow Obelisk",
             175: "Thor's Crucible", 176: "Aeon Mechanism", 177: "Dwarven Pick"}
ARTIFACT_WEIGHTS = {172: 30, 173: 10, 174: 20, 175: 15, 176: 5, 177: 20}
CELL_DEG = 0.02
SITE_CHANCE = 0.35


def detect_range(level: int) -> float:
    return 0.0 if level < 1 else 1000.0 + 500.0 * min(10, level)


def reveal_range(level: int) -> float:
    return 0.0 if level < 1 else 50.0 + 10.0 * min(10, level)


def pickup_range(museum_level: int) -> float:
    return 50.0 + 15.0 * max(0, min(10, museum_level))


def archaeologists_needed(level: int) -> int:
    return max(1, 10 - min(10, level))


def week_of(now: datetime.datetime) -> str:
    y, w, _ = now.isocalendar()
    return f"{y}W{w:02d}"


def _h(*parts) -> int:
    return int(hashlib.sha256("|".join(map(str, parts)).encode()).hexdigest()[:15], 16)


def site_in_cell(cx: int, cy: int, week: str):
    """Deterministic artifact site of a cell for a week, or None."""
    r = _h("site", cx, cy, week)
    if (r % 10000) / 10000.0 >= SITE_CHANCE:
        return None
    fx = (_h("x", cx, cy, week) % 100000) / 100000.0
    fy = (_h("y", cx, cy, week) % 100000) / 100000.0
    total = sum(ARTIFACT_WEIGHTS.values())
    pick = _h("t", cx, cy, week) % total
    for item, wgt in ARTIFACT_WEIGHTS.items():
        if pick < wgt:
            break
        pick -= wgt
    return {"id": f"{cx}:{cy}:{week}", "lat": (cy + fy) * CELL_DEG, "lng": (cx + fx) * CELL_DEG,
            "item": item}


def sites_near(lat, lng, radius_m, week):
    lat1, lat2, lng1, lng2 = econ.bbox(lat, lng, radius_m)
    out = []
    for cy in range(math.floor(lat1 / CELL_DEG), math.floor(lat2 / CELL_DEG) + 1):
        for cx in range(math.floor(lng1 / CELL_DEG), math.floor(lng2 / CELL_DEG) + 1):
            s = site_in_cell(cx, cy, week)
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
            site_id    TEXT PRIMARY KEY,
            hid        TEXT NOT NULL,
            item_id    INTEGER NOT NULL,
            lat        REAL NOT NULL,
            lng        REAL NOT NULL,
            ts         TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_artrec_hid ON artifact_recoveries(hid);
    """)
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

    def recovered(conn, site_ids):
        if not site_ids:
            return set()
        q = ",".join("?" * len(site_ids))
        return {r[0] for r in conn.execute(f"SELECT site_id FROM artifact_recoveries WHERE site_id IN ({q})",
                                           list(site_ids))}

    @api.endpoint("/api/v1/archaeology/status", feature="ARCHAEOLOGY")
    def status(conn, hid, form):
        coll = {}
        for r in conn.execute("SELECT item_id, COUNT(*) FROM artifact_recoveries WHERE hid=? GROUP BY item_id", (hid,)):
            coll[r[0]] = r[1]
        return {"err": 0, **levels(conn, hid),
                "collection": [{"itemID": i, "name": n, "found": coll.get(i, 0),
                                "owned": econ.qty_of(conn, hid, i)} for i, n in ARTIFACTS.items()]}

    @api.endpoint("/api/v1/archaeology/detect", feature="ARCHAEOLOGY")
    def detect(conn, hid, form):
        """Direction to the nearest unrecovered artifact in detection range (position only once
        within the reveal range)."""
        lat, lng = econ.parse_pos(form)
        lv = levels(conn, hid)
        if lv["centerLevel"] < 1:
            raise econ.GameError("locked", "Build an Archaeological Center first")
        if lv["detectors"] < 1:
            raise econ.GameError("no_detector", "You need an Artifact Detector")
        sites = sites_near(lat, lng, lv["detectRange"], week_of(econ.utcnow()))
        done = recovered(conn, [s["id"] for s in sites])
        sites = [s for s in sites if s["id"] not in done]
        if not sites:
            return {"err": 0, "found": False, "detectRange": lv["detectRange"]}
        s = sites[0]
        out = {"err": 0, "found": True, "bearing": round(bearing_deg(lat, lng, s["lat"], s["lng"]), 1),
               "band": band(s["dist"]), "detectRange": lv["detectRange"], "revealRange": lv["revealRange"]}
        if s["dist"] <= lv["revealRange"]:
            out["revealed"] = {"id": s["id"], "lat": s["lat"], "lng": s["lng"], "itemID": s["item"],
                               "name": ARTIFACTS[s["item"]], "distance": round(s["dist"])}
        return out

    @api.endpoint("/api/v1/archaeology/recover", feature="ARCHAEOLOGY")
    def recover(conn, hid, form):
        site_id = (form.get("id") or "").strip()
        lat, lng = econ.parse_pos(form)
        try:
            cx, cy, week = site_id.split(":")
            site = site_in_cell(int(cx), int(cy), week)
        except ValueError:
            site = None
        if not site or week != week_of(econ.utcnow()):
            raise econ.GameError("gone", "This artifact site is gone")
        with econ.tx(conn):
            lv = levels(conn, hid)
            if lv["centerLevel"] < 1:
                raise econ.GameError("locked", "Build an Archaeological Center first")
            d = econ.dist_m(lat, lng, site["lat"], site["lng"])
            if d > lv["revealRange"]:
                raise econ.GameError("not_revealed", "Get closer to reveal the artifact first")
            econ.require_within(lat, lng, site["lat"], site["lng"], lv["pickupRange"], "artifact")
            need = lv["archaeologistsNeeded"]
            econ.take(conn, hid, ARCHAEOLOGISTS, need, "artifact_recovery", site_id)
            cur = conn.execute("INSERT OR IGNORE INTO artifact_recoveries(site_id, hid, item_id, lat, lng, ts) "
                               "VALUES(?,?,?,?,?,?)", (site_id, hid, site["item"], site["lat"], site["lng"],
                                                       econ.utcnow_iso()))
            if cur.rowcount != 1:
                raise econ.GameError("gone", "Someone else recovered this artifact first")
            econ.give(conn, hid, site["item"], 1, "artifact_recovery", site_id, ignore_capacity=True)
            econ.emit(conn, "artifact_found", hid, {"itemID": site["item"], "name": ARTIFACTS[site["item"]]},
                      lat=round(site["lat"], 2), lng=round(site["lng"], 2), dedup=f"artifact:{site_id}")
            conn.execute("INSERT OR IGNORE INTO achievements(hid, code, title, ts) VALUES(?,?,?,?)",
                         (hid, f"artifact_{site['item']}", f"Found {ARTIFACTS[site['item']]}", econ.utcnow_iso()))
        return {"err": 0, "itemID": site["item"], "name": ARTIFACTS[site["item"]], "archaeologistsUsed": need}
