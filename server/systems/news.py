"""Phase 9 — server-generated news and daily earthquakes.

News items are created only from real backend events (game_events) by a sweep that keeps a
cursor, so every event is considered once; items carry a UNIQUE dedup key. Names are resolved
when news is read. (The anonymity option was removed by the owner on 2026-10-19; the table stays
so older data keeps working.) Player locations are rounded to 0.01° (~1 km).

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
CATEGORIES = ("world", "awards", "casino", "auctions", "archaeology", "combat", "players", "cargo", "quests")
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


def daily_awards(conn, h, now) -> int:
    """Once per UTC day: award news (richest companies, hardest-working, decadence, top raw and
    factory output) and company anniversaries (100 days, every year, 5 and 10 years). Inside tx()."""
    day = now.strftime("%Y-%m-%d")
    if conn.execute("SELECT 1 FROM news_items WHERE dedup=?", (f"awards:{day}",)).fetchone():
        return 0
    ts = now.isoformat()
    n = 0

    def put(kind, hid, data, key):
        nonlocal n
        add_news(conn, "awards" if kind not in ANNIVERSARY_KINDS else "players", kind, hid, data=data,
                 dedup=f"{key}:{day}", ts=ts)
        n += 1

    rich = conn.execute("SELECT hID, credits FROM players WHERE credits > 0 ORDER BY credits DESC LIMIT 3").fetchall()
    if rich:
        put("rich", rich[0][0], {"credits": int(rich[0][1]),
                                 "others": [{"hid": r[0], "credits": int(r[1])} for r in rich[1:]]}, "rich")
    # hardest-working: activity-weighted score (same as the overall leaderboard)
    best = None
    for r in conn.execute("SELECT hID, xp, created_at FROM players WHERE xp > 0"):
        try:
            age = max(1, (now - datetime.datetime.fromisoformat(r[2])).days)
        except (TypeError, ValueError):
            age = 1
        days = conn.execute("SELECT COUNT(*) FROM player_activity WHERE hid=? AND day>=?",
                            (r[0], (now - datetime.timedelta(days=min(age, 100))).strftime("%Y-%m-%d"))).fetchone()[0]
        score = round((r[1] or 0) * 2 * min(1.0, days / min(age, 100)))
        if not best or score > best[1]:
            best = (r[0], score)
    if best and best[1] > 0:
        put("workhorse", best[0], {"points": best[1]}, "workhorse")
    try:
        lux = conn.execute("SELECT p.hid, p.points, COALESCE((SELECT SUM(qty) FROM luxury_items l WHERE l.hid=p.hid), 0) "
                           "FROM luxury_points p WHERE p.points > 0 ORDER BY p.points DESC LIMIT 1").fetchone()
    except Exception:
        lux = None
    if lux:
        put("decadence", lux[0], {"points": int(lux[1]), "items": int(lux[2])}, "decadence")
    raw = conn.execute(
        "SELECT owner_hid, SUM(r.rate * quality / 100.0 * MAX(0.1, condition / 100.0) * level * "
        "(1.0 + (COALESCE(tu1,0) + COALESCE(tu2,0) + 1.5*COALESCE(tu3,0) + 1.5*COALESCE(tu4,0)) / 100.0)) AS out "
        f"FROM mines m JOIN (SELECT column1 AS item_id, column2 AS rate FROM (VALUES {_mine_rate_values(h)})) r "
        "ON r.item_id = m.item_id GROUP BY owner_hid ORDER BY out DESC LIMIT 1").fetchone()
    if raw and raw[1]:
        put("raw_output", raw[0], {"perHour": round(raw[1])}, "raw_output")
    fac_rate = {fid: ft["out"] / ft["hrs"] for fid, ft in h.FACTORY_TYPES.items()}
    acc = {}
    for r in conn.execute("SELECT hid, item_id, level FROM factories"):
        if r[1] in fac_rate:
            acc[r[0]] = acc.get(r[0], 0) + fac_rate[r[1]] * (r[2] or 1)
    if acc:
        top = max(acc.items(), key=lambda x: x[1])
        put("factory_output", top[0], {"perHour": round(top[1])}, "factory_output")
    # anniversaries
    for r in conn.execute("SELECT hID, created_at FROM players"):
        try:
            created = datetime.datetime.fromisoformat(r[1])
        except (TypeError, ValueError):
            continue
        age = (now.date() - created.date()).days
        if age == 100:
            put("jubilee100", r[0], {"days": 100}, f"anniv:{r[0]}")
        elif age >= 365 and created.month == now.month and created.day == now.day:
            put("anniversary", r[0], {"years": now.year - created.year}, f"anniv:{r[0]}")
    add_news(conn, "awards", "marker", data={}, dedup=f"awards:{day}", ts=ts)   # hidden: marks the day done
    return n


ANNIVERSARY_KINDS = {"jubilee100", "anniversary"}


def _mine_rate_values(h) -> str:
    return ",".join(f"({int(k)},{float(v['rate'])})" for k, v in h.MINE_TYPES.items())


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
                daily_awards(conn, h, econ.utcnow())

    def world_loop():
        time.sleep(30)
        while True:
            try:
                with h.get_db() as conn:
                    with econ.tx(conn):
                        digest_events(conn)
                        daily_awards(conn, h, econ.utcnow())
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
        for r in rows:
            for o in json.loads(r["data"] or "{}").get("others", []):
                hids.add(o["hid"])
        anon = anonymous(conn, hids) if hids else set()
        refs = {x: ({"pid": None, "name": "A company"} if x in anon and x != viewer else social.public_ref(conn, x))
                for x in hids}
        out = []
        for r in rows:
            d = json.loads(r["data"] or "{}")
            if "others" in d:       # never send internal ids
                d["others"] = [{"name": refs[o["hid"]]["name"], "credits": o["credits"]} for o in d["others"]]
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
        sql, args = "SELECT * FROM news_items WHERE kind<>'marker'", []
        if cat in CATEGORIES:
            sql += " AND category=?"
            args.append(cat)
        if before:
            sql += " AND id<?"
            args.append(before)
        rows = conn.execute(sql + " ORDER BY id DESC LIMIT ?", (*args, PAGE + 1)).fetchall()
        more = len(rows) > PAGE
        rows = rows[:PAGE]
        return {"err": 0, "items": render(conn, rows, hid), "more": more,
                "next": rows[-1]["id"] if more and rows else None, "categories": CATEGORIES}

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
        "rich": f"Rich, richer, {_n(p1)}!",
        "workhorse": f"Hardest-working company: {_n(p1)}",
        "decadence": f"Decadence award: {_n(p1)}",
        "raw_output": f"Mining magnate: {_n(p1)}",
        "factory_output": f"Industrial giant: {_n(p1)}",
        "jubilee100": f"{_n(p1)} celebrates 100 days!",
        "anniversary": _anniversary_title(_n(p1), int(d.get("years", 1))),
    }.get(kind, kind)


def _anniversary_title(name, years):
    if years == 1:
        return f"{name} turns one year old!"
    if years == 5:
        return f"Five years of {name}!"
    if years == 10:
        return f"{name} — ten years in business!"
    return f"{name} celebrates {years} years!"


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
    if kind == "rich":
        rest = "; ".join(f"{o['name']} ꞓ{o['credits']:,}" for o in d.get("others", []))
        return f"The richest company holds ꞓ{int(d.get('credits', 0)):,}." + (f" Close behind: {rest}." if rest else "")
    if kind == "workhorse":
        return f"{int(d.get('points', 0)):,} points — nobody worked harder today."
    if kind == "decadence":
        return (f"{int(d.get('items', 0)):,} luxury items and {int(d.get('points', 0)):,} luxury points. "
                "Gold-plated everything.")
    if kind == "raw_output":
        return f"Its mines dig up {int(d.get('perHour', 0)):,} raw resources every hour."
    if kind == "factory_output":
        return f"Its factories turn out {int(d.get('perHour', 0)):,} products every hour."
    if kind == "jubilee100":
        return "100 days of hard work — the first bottle of Moët & Chandon is open. Cheers!"
    if kind == "anniversary":
        y = int(d.get("years", 1))
        if y == 1:
            return "365 days in business: time for Dom Pérignon!"
        if y == 5:
            return "Half a decade! A jeroboam of Dom Pérignon for the whole company."
        if y == 10:
            return "A whole decade — Dom Pérignon Plénitude P3 from the vault, as is tradition."
        return f"Another year, another Dom Pérignon. {y} years and counting."
    return ""
