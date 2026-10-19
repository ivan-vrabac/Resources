"""Phase 9 — server-generated news and daily earthquakes.

News items are created only from real backend events (game_events) by a sweep that keeps a
cursor, so every event is considered once; items carry a UNIQUE dedup key. Names are resolved
when news is read, so a player who turns on anonymous news (/api/v1/news/privacy) disappears
from past items too. Player locations are rounded to 0.01° (~1 km).

Earthquakes (configurable, documented): one per UTC day at a time of day derived from the
date; epicenter in one of SEISMIC_ZONES (real seismically active regions) with up to ~150 km
jitter; magnitude 5–9 skewed towards small quakes; radius 1–50 km growing with magnitude; damage
= peak(M) × (1 − d/R)^1.5, peak 10 (M5) … 70 (M9) condition points, × Seismology Centre factor.
Quakes never delete mines: they lower condition, and the existing destruction rule (< 20 %)
applies later as usual. Each day is processed exactly once (earthquakes.day PRIMARY KEY, damage
applied in the same transaction that marks it done). The RNG is seeded from the date and a
server secret, so results are reproducible on this server but not predictable from source code.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import math
import os
import random
import threading
import time

import econ
import protection
from . import int_arg, social

PAGE = 30
CATEGORIES = ("world", "casino", "auctions", "archaeology", "combat", "players", "cargo", "quests")
MINES_24H_THRESHOLDS = (100, 1000, 10000)
CRATES_THRESHOLDS = (1000, 10000, 100000)
LEVEL_MILESTONE_EVERY = 10
BIG_ATTACK_UNITS = 1000
RARE_ITEMS = {42: "Giant Diamond", 48: "Tech Upgrade 4"}
SWEEP_S = 60
QUAKE_MIN_DMG = 0.5

# (name, lat, lng, weight) — real, seismically active regions
SEISMIC_ZONES = [
    ("Japan, Honshu", 37.5, 141.5, 3), ("Indonesia, Sumatra", -1.5, 99.0, 3), ("Chile, central", -33.0, -71.8, 3),
    ("Peru, coast", -12.5, -77.0, 2), ("Mexico, Guerrero", 17.0, -99.8, 2), ("California, San Andreas", 35.8, -120.4, 2),
    ("Alaska, Aleutians", 52.0, -175.0, 2), ("Philippines, Luzon", 15.5, 120.8, 2), ("Taiwan", 23.8, 121.3, 2),
    ("New Zealand", -41.5, 174.0, 2), ("Turkey, Anatolia", 37.9, 37.0, 2), ("Iran, Zagros", 30.0, 51.5, 2),
    ("Nepal, Himalaya", 28.2, 84.7, 2), ("Greece, Aegean", 38.5, 23.5, 2), ("Italy, Apennines", 42.4, 13.4, 2),
    ("Croatia, Zagreb–Petrinja", 45.6, 16.1, 1), ("Albania, Durrës", 41.4, 19.5, 1), ("Iceland", 64.0, -21.0, 1),
    ("Ecuador", -1.0, -80.0, 1), ("Papua New Guinea", -6.0, 147.0, 2), ("China, Sichuan", 31.0, 103.4, 1),
    ("Pakistan, Kashmir", 34.4, 73.5, 1), ("Caribbean, Haiti", 18.5, -72.5, 1), ("Romania, Vrancea", 45.7, 26.6, 1),
]


def world_seed() -> str:
    return os.environ.get("WORLD_EVENT_SEED") or os.environ.get("SESSION_SECRET") or "dev-world"


def day_rng(day: str, salt: str) -> random.Random:
    return random.Random(int(hashlib.sha256(f"{salt}:{day}:{world_seed()}".encode()).hexdigest()[:16], 16))


def plan_quake(day: str) -> dict:
    """Deterministic earthquake for a UTC day: time, epicenter, magnitude, radius."""
    rng = day_rng(day, "quake")
    zone = rng.choices(SEISMIC_ZONES, weights=[z[3] for z in SEISMIC_ZONES])[0]
    dist = rng.uniform(0, 150_000)
    bearing = rng.uniform(0, 2 * math.pi)
    lat = zone[1] + dist * math.cos(bearing) / 111_320
    lng = zone[2] + dist * math.sin(bearing) / (111_320 * max(0.2, math.cos(math.radians(zone[1]))))
    mag = round(5 + 4 * rng.random() ** 2.2, 1)
    s = (mag - 5) / 4
    radius_km = round(max(1.0, min(50.0, 1 + 49 * s * rng.uniform(0.7, 1.0))), 1)
    at = datetime.datetime.fromisoformat(day) + datetime.timedelta(minutes=rng.randint(0, 24 * 60 - 1))
    return {"day": day, "at": at.isoformat(), "place": zone[0], "lat": round(lat, 4), "lng": round(lng, 4),
            "magnitude": mag, "radius_km": radius_km, "peak": round(10 + 60 * s ** 1.2, 1)}


def quake_damage(q, dist_m, seismo_level=0) -> float:
    r = q["radius_km"] * 1000
    if dist_m > r:
        return 0.0
    return round(min(70.0, q["peak"] * (1 - dist_m / r) ** 1.5) * protection.quake_factor(seismo_level), 2)


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS news_items (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            ts        TEXT NOT NULL,
            category  TEXT NOT NULL,
            kind      TEXT NOT NULL,
            hid       TEXT,
            hid2      TEXT,
            lat       REAL,
            lng       REAL,
            data      TEXT NOT NULL DEFAULT '{}',
            dedup     TEXT UNIQUE
        );
        CREATE INDEX IF NOT EXISTS idx_news_cat ON news_items(category, id);
        CREATE TABLE IF NOT EXISTS news_privacy (
            hid       TEXT PRIMARY KEY,
            anonymous INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS news_counters (
            hid   TEXT NOT NULL,
            key   TEXT NOT NULL,
            value REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (hid, key)
        );
        CREATE TABLE IF NOT EXISTS earthquakes (
            day            TEXT PRIMARY KEY,
            status         TEXT NOT NULL,      -- pending, done
            at             TEXT NOT NULL,
            place          TEXT NOT NULL,
            lat            REAL NOT NULL,
            lng            REAL NOT NULL,
            magnitude      REAL NOT NULL,
            radius_km      REAL NOT NULL,
            affected_mines INTEGER DEFAULT 0,
            damaged_mines  INTEGER DEFAULT 0,
            companies      INTEGER DEFAULT 0,
            total_damage   REAL DEFAULT 0,
            max_damage     REAL DEFAULT 0,
            below_20       INTEGER DEFAULT 0
        );
    """)
    # start after existing history: news covers events from the moment the system is installed
    conn.execute("INSERT OR IGNORE INTO scheduler(name, last_run) "
                 "SELECT 'news_cursor', CAST(COALESCE(MAX(id), 0) AS TEXT) FROM game_events")
    conn.commit()


def add_news(conn, category, kind, hid=None, hid2=None, lat=None, lng=None, data=None, dedup=None, ts=None):
    conn.execute("INSERT OR IGNORE INTO news_items(ts, category, kind, hid, hid2, lat, lng, data, dedup) "
                 "VALUES(?,?,?,?,?,?,?,?,?)",
                 (ts or econ.utcnow_iso(), category, kind, hid, hid2,
                  None if lat is None else round(lat, 2), None if lng is None else round(lng, 2),
                  json.dumps(data or {}, ensure_ascii=False), dedup))


def _bump(conn, hid, key, by) -> tuple:
    old = conn.execute("SELECT value FROM news_counters WHERE hid=? AND key=?", (hid, key)).fetchone()
    old = float(old[0]) if old else 0.0
    conn.execute("INSERT INTO news_counters(hid, key, value) VALUES(?,?,?) ON CONFLICT(hid, key) "
                 "DO UPDATE SET value=value+excluded.value", (hid, key, by))
    return old, old + by


def digest_events(conn, limit=5000) -> int:
    """Turn new game_events into news. Inside tx(). Returns events processed."""
    cur = int(conn.execute("SELECT last_run FROM scheduler WHERE name='news_cursor'").fetchone()[0] or 0)
    rows = conn.execute("SELECT * FROM game_events WHERE id>? ORDER BY id LIMIT ?", (cur, limit)).fetchall()
    built = {}
    for e in rows:
        t, hid, d = e["type"], e["hid"], json.loads(e["data"] or "{}")
        key = f"ev:{e['id']}"
        if t == "casino_jackpot":
            add_news(conn, "casino", "jackpot", hid, data=d, dedup=key, ts=e["ts"])
        elif t == "casino_dividend" and d.get("paid", 0) > 0:
            add_news(conn, "casino", "dividend", hid, data=d, dedup=key, ts=e["ts"])
        elif t == "auction_won":
            add_news(conn, "auctions", "auction", hid, data=d, dedup=key, ts=e["ts"])
        elif t == "artifact_found":
            add_news(conn, "archaeology", "artifact", hid, lat=e["lat"], lng=e["lng"], data=d, dedup=key, ts=e["ts"])
        elif t == "attack" and d.get("success") and (d.get("destroyed") or d.get("sent", 0) >= BIG_ATTACK_UNITS):
            add_news(conn, "combat", "attack", hid, d.get("defender"), e["lat"], e["lng"],
                     {"destroyed": bool(d.get("destroyed")), "sent": d.get("sent", 0)}, dedup=key, ts=e["ts"])
        elif t == "level_up" and int(d.get("to", 0)) % LEVEL_MILESTONE_EVERY == 0:
            add_news(conn, "players", "level", hid, data={"level": d.get("to")}, dedup=f"level:{hid}:{d.get('to')}", ts=e["ts"])
        elif t == "rare_find" and int(d.get("itemID", 0)) in RARE_ITEMS:
            add_news(conn, "cargo", "rare", hid, data=d, dedup=key, ts=e["ts"])
        elif t == "streak_milestone":
            add_news(conn, "quests", "streak", hid, data=d, dedup=f"streak:{hid}:{d.get('days')}:{e['ts'][:10]}", ts=e["ts"])
        elif t == "cargo_collected" and hid:
            old, new = _bump(conn, hid, "crates", float(d.get("crates", 1) or 1))
            for th in CRATES_THRESHOLDS:
                if old < th <= new:
                    add_news(conn, "cargo", "crates", hid, data={"crates": th}, dedup=f"crates:{hid}:{th}", ts=e["ts"])
        elif t == "mine_built" and hid:
            built[hid] = e["ts"]
        cur = e["id"]
    since = (econ.utcnow() - datetime.timedelta(hours=24)).isoformat()
    for hid, ts in built.items():
        n = econ.count_events(conn, hid, "mine_built", since)
        for th in MINES_24H_THRESHOLDS:
            if n >= th:
                add_news(conn, "players", "mines24", hid, data={"mines": th},
                         dedup=f"mines24:{hid}:{th}:{ts[:10]}", ts=ts)
    conn.execute("UPDATE scheduler SET last_run=? WHERE name='news_cursor'", (str(cur),))
    return len(rows)


def run_quake(conn, h, now, day=None) -> dict | None:
    """Process the earthquake for `day` (default: today, once its time has come). Exactly once."""
    day = day or now.strftime("%Y-%m-%d")
    q = plan_quake(day)
    if now.isoformat() < q["at"]:
        return None
    with econ.tx(conn):
        row = conn.execute("SELECT status FROM earthquakes WHERE day=?", (day,)).fetchone()
        if row and row[0] == "done":
            return None
        if not row:
            conn.execute("INSERT INTO earthquakes(day, status, at, place, lat, lng, magnitude, radius_km) "
                         "VALUES(?,?,?,?,?,?,?,?)", (day, "pending", q["at"], q["place"], q["lat"], q["lng"],
                                                     q["magnitude"], q["radius_km"]))
    r = q["radius_km"] * 1000
    s_lat, n_lat, w_lng, e_lng = econ.bbox(q["lat"], q["lng"], r)
    hits = [m for m in conn.execute("SELECT mine_id, owner_hid, lat, lng FROM mines WHERE lat BETWEEN ? AND ? "
                                    "AND lng BETWEEN ? AND ?", (s_lat, n_lat, w_lng, e_lng)).fetchall()
            if econ.dist_m(q["lat"], q["lng"], m["lat"], m["lng"]) <= r]
    owners = {}
    for m in hits:
        owners.setdefault(m["owner_hid"], set()).add(m["mine_id"])
    # settle production at the old condition first (collect_mines_bulk commits on its own)
    for owner, ids in owners.items():
        try:
            h.collect_mines_bulk(conn, owner, only_ids=ids)
        except Exception:
            pass
    with econ.tx(conn):
        if conn.execute("SELECT status FROM earthquakes WHERE day=?", (day,)).fetchone()[0] == "done":
            return None
        seismo = {o: h.building_level(conn, o, protection.SEISMOLOGY) for o in owners}
        updates, total, mx, below, damaged_owners = [], 0.0, 0.0, 0, set()
        # re-read after settling (one query); mines destroyed while settling are simply gone
        now_rows = conn.execute("SELECT mine_id, owner_hid, lat, lng, condition FROM mines WHERE lat BETWEEN ? AND ? "
                                "AND lng BETWEEN ? AND ?", (s_lat, n_lat, w_lng, e_lng)).fetchall()
        hit_ids = {m["mine_id"] for m in hits}
        for m in now_rows:
            if m["mine_id"] not in hit_ids:
                continue
            dmg = quake_damage(q, econ.dist_m(q["lat"], q["lng"], m["lat"], m["lng"]), seismo[m["owner_hid"]])
            if dmg < QUAKE_MIN_DMG:
                continue
            cond = float(m["condition"])
            new = round(max(0.0, cond - dmg), 2)
            dmg = round(cond - new, 2)
            updates.append((new, m["mine_id"]))
            total += dmg
            mx = max(mx, dmg)
            below += new < 20
            damaged_owners.add(m["owner_hid"])
        conn.executemany("UPDATE mines SET condition=? WHERE mine_id=?", updates)
        stats = {"affected_mines": len(hits), "damaged_mines": len(updates), "companies": len(damaged_owners),
                 "total_damage": round(total, 1), "max_damage": round(mx, 1), "below_20": below}
        conn.execute("UPDATE earthquakes SET status='done', affected_mines=?, damaged_mines=?, companies=?, "
                     "total_damage=?, max_damage=?, below_20=? WHERE day=?",
                     (*stats.values(), day))
        for o in damaged_owners:
            h.add_proto(conn, o, "earthquake", {"day": day, "magnitude": q["magnitude"]})
        add_news(conn, "world", "earthquake", lat=q["lat"], lng=q["lng"],
                 data={**{k: q[k] for k in ("place", "magnitude", "radius_km", "at")}, **stats,
                       "companiesAffected": len(owners)},
                 dedup=f"quake:{day}", ts=q["at"])
        econ.emit(conn, "earthquake", None, {"day": day, **stats}, lat=q["lat"], lng=q["lng"], dedup=f"quake:{day}")
    for o in damaged_owners:
        try:
            h.push(conn, o, "Earthquake", f"A magnitude {q['magnitude']} earthquake damaged your mines near {q['place']}.")
        except Exception:
            pass
    return {**q, **stats}


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)

    def maybe_sweep(conn):
        with econ.tx(conn):
            if econ.due(conn, "news_sweep", SWEEP_S):
                digest_events(conn)

    def world_loop():
        time.sleep(30)
        while True:
            try:
                with h.get_db() as conn:
                    with econ.tx(conn):
                        digest_events(conn)
                    if econ.feature("EARTHQUAKES"):
                        run_quake(conn, h, econ.utcnow())
            except Exception:
                pass
            time.sleep(300)

    if os.environ.get("WORLD_EVENTS_THREAD", "1") == "1":
        threading.Thread(target=world_loop, daemon=True, name="world-events").start()

    def anonymous(conn, hids):
        q = ",".join("?" * len(hids))
        return {r[0] for r in conn.execute(f"SELECT hid FROM news_privacy WHERE anonymous=1 AND hid IN ({q})", list(hids))}

    def render(conn, rows, viewer):
        hids = {x for r in rows for x in (r["hid"], r["hid2"]) if x}
        anon = anonymous(conn, hids) if hids else set()
        refs = {x: ({"pid": None, "name": "A company"} if x in anon and x != viewer else social.public_ref(conn, x))
                for x in hids}
        out = []
        for r in rows:
            d = json.loads(r["data"] or "{}")
            p1, p2 = refs.get(r["hid"]), refs.get(r["hid2"])
            out.append({"id": r["id"], "ts": r["ts"], "category": r["category"], "kind": r["kind"],
                        "title": _title(r["kind"], d, p1, p2), "body": _body(r["kind"], d, p1, p2),
                        "players": [p for p in (p1, p2) if p], "lat": r["lat"], "lng": r["lng"], "data": d})
        return out

    @api.endpoint("/api/v1/news", feature="NEWS")
    def listing(conn, hid, form):
        maybe_sweep(conn)
        before = int_arg(form, "before", 0, 0, 2**62)
        cat = (form.get("category") or "").strip()
        sql, args = "SELECT * FROM news_items WHERE 1=1", []
        if cat in CATEGORIES:
            sql += " AND category=?"
            args.append(cat)
        if before:
            sql += " AND id<?"
            args.append(before)
        rows = conn.execute(sql + " ORDER BY id DESC LIMIT ?", (*args, PAGE + 1)).fetchall()
        more = len(rows) > PAGE
        rows = rows[:PAGE]
        priv = conn.execute("SELECT anonymous FROM news_privacy WHERE hid=?", (hid,)).fetchone()
        return {"err": 0, "items": render(conn, rows, hid), "more": more,
                "next": rows[-1]["id"] if more and rows else None, "categories": CATEGORIES,
                "anonymous": bool(priv and priv[0])}

    @api.endpoint("/api/v1/news/privacy", feature="NEWS")
    def privacy(conn, hid, form):
        anon = 1 if int_arg(form, "anonymous", 0, 0, 1) else 0
        with econ.tx(conn):
            conn.execute("INSERT INTO news_privacy(hid, anonymous) VALUES(?,?) ON CONFLICT(hid) "
                         "DO UPDATE SET anonymous=excluded.anonymous", (hid, anon))
        return {"err": 0, "anonymous": bool(anon)}

    @api.endpoint("/api/v1/news/earthquakes", feature="EARTHQUAKES")
    def quakes(conn, hid, form):
        rows = conn.execute("SELECT * FROM earthquakes WHERE status='done' ORDER BY day DESC LIMIT 30").fetchall()
        return {"err": 0, "earthquakes": [dict(r) for r in rows]}


def _n(p):
    return (p or {}).get("name", "A company")


def _title(kind, d, p1, p2):
    return {
        "jackpot": f"{_n(p1)} won the casino jackpot!",
        "dividend": "Five of a kind — luxury dividend paid",
        "auction": f"{_n(p1)} won a luxury auction",
        "artifact": f"{_n(p1)} discovered {d.get('name', 'an artifact')}",
        "attack": f"{_n(p1)} {'demolished a mine of' if d.get('destroyed') else 'raided'} {_n(p2)}",
        "level": f"{_n(p1)} reached level {d.get('level')}",
        "rare": f"{_n(p1)} found a {RARE_ITEMS.get(int(d.get('itemID', 0)), 'rare item')} in a crate",
        "streak": f"{_n(p1)} kept a {d.get('days')}-day quest streak",
        "crates": f"{_n(p1)} collected {int(d.get('crates', 0)):,} Cargo Rain crates",
        "mines24": f"{_n(p1)} built {int(d.get('mines', 0)):,} mines in 24 hours",
        "earthquake": f"Magnitude {d.get('magnitude')} earthquake — {d.get('place')}",
    }.get(kind, kind)


def _body(kind, d, p1, p2):
    if kind == "jackpot":
        return f"Jackpot payout: {int(d.get('amount', 0)):,} credits."
    if kind == "dividend":
        return f"{d.get('holders')} holders shared {int(d.get('paid', 0)):,} credits from the jackpot."
    if kind == "auction":
        return f"Winning bid: {int(d.get('price', 0)):,} units of its resource."
    if kind == "earthquake":
        return (f"Radius {d.get('radius_km')} km · {d.get('affected_mines', 0):,} mines in the area · "
                f"{d.get('damaged_mines', 0):,} damaged · {d.get('companies', 0):,} companies hit · "
                f"max damage {d.get('max_damage', 0)} points.")
    if kind == "attack":
        return f"{int(d.get('sent', 0)):,} units took part."
    return ""
