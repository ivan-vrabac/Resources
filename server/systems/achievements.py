"""Achievements (owner's list, 2026-10-20): three tiers each, computed on the server from the
player's real data and recorded once per tier in the `achievements` table (code "<key>_<tier>").
Some thresholds (points, luxury points) are placeholders until the economy rework.
"""
from __future__ import annotations

import datetime

import econ

MAFIA_HQ = 86

# key: (title, description, (tier thresholds), unit)
DEFS = {
    "hq_level":     ("Headquarters", "Reach headquarters level", (3, 7, 10), ""),
    "hq_influence": ("HQ influence", "Mines inside your HQ boost area", (50, 100, 200), "mines"),
    "age":          ("Veteran", "Account age", (100, 180, 365), "days"),
    "balance":      ("Tycoon", "Account balance", (100_000_000, 10_000_000_000, 500_000_000_000), "credits"),
    "points":       ("High score", "Leaderboard points", (100_000, 1_000_000, 10_000_000), "points"),
    "luxury_points": ("Connoisseur", "Luxury points", (1_000, 10_000, 100_000), "points"),
    "gambler":      ("Gambler", "Casino four of a kind or better", (1, 10, 50), "times"),
    "decadence":    ("Boundless decadence", "Luxury items owned", (1, 10, 100), "items"),
    "factories":    ("Industrialist", "Total factory levels", (10, 100, 500), "levels"),
    "hoarder":      ("Hoarder", "Mines owned", (100, 1000, 10000), "mines"),
    "attacker":     ("Attacker", "Attacks won", (10, 100, 1000), "wins"),
    "friend":       ("Friend in need", "Other players' mines repaired", (10, 100, 1000), "mines"),
    "special":      ("Master builder", "Special building upgrades", (10, 50, 100), "levels"),
    "artifacts":    ("Archaeologist", "Artifact sites recovered", (10, 100, 500), "artifacts"),
    "repairs":      ("Mechanic", "Mines repaired", (1000, 50000, 100000), "repairs"),
    "streak":       ("Quest solver", "Daily quest streak", (7, 30, 90), "days"),
    "warehouse":    ("Storekeeper", "Warehouse level", (10, 50, 100), ""),
    "level":        ("Experience", "Player level", (20, 60, 100), ""),
}
TIER_NAMES = ("First star", "Second star", "Third star")
# short score label shown as "<label>: value / target"
LABELS = {
    "hq_level": "HQ level", "hq_influence": "Mines in HQ area", "age": "Days", "balance": "Credits",
    "points": "Points", "luxury_points": "Luxury points", "gambler": "Four of a kind+", "decadence": "Luxury items",
    "factories": "Factory levels", "hoarder": "Mines", "attacker": "Attacks won", "friend": "Repairs for others",
    "special": "Upgrades", "artifacts": "Artifacts", "repairs": "Repairs", "streak": "Streak days",
    "warehouse": "Warehouse level", "level": "Level",
}


def _one(conn, sql, args=()):
    try:
        r = conn.execute(sql, args).fetchone()
    except Exception:          # table of a disabled system may not exist
        return 0
    return (r[0] or 0) if r else 0


def metrics(conn, h, hid) -> dict:
    p = conn.execute("SELECT * FROM players WHERE hID=?", (hid,)).fetchone()
    hq = conn.execute("SELECT lat, lng, level FROM hq WHERE hid=?", (hid,)).fetchone()
    now = econ.utcnow()
    try:
        age = max(0, (now - datetime.datetime.fromisoformat(p["created_at"])).days)
    except (TypeError, ValueError):
        age = 0
    influence = 0
    if hq:
        radius = h.HQ_BOOST_RADIUS.get(hq["level"], 115)
        s_lat, n_lat, w_lng, e_lng = econ.bbox(hq["lat"], hq["lng"], radius)
        influence = sum(1 for m in conn.execute(
            "SELECT lat, lng FROM mines WHERE owner_hid=? AND lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?",
            (hid, s_lat, n_lat, w_lng, e_lng)) if econ.dist_m(hq["lat"], hq["lng"], m[0], m[1]) <= radius)
    # leaderboard points (same formula as the overall board)
    days = _one(conn, "SELECT COUNT(*) FROM player_activity WHERE hid=? AND day>=?",
                (hid, (now - datetime.timedelta(days=min(max(age, 1), 100))).strftime("%Y-%m-%d")))
    points = round((p["xp"] or 0) * min(1.0, days / min(max(age, 1), 100)))      # same as the board
    special = set(h.SPECIAL_BUILDINGS)
    fac = conn.execute("SELECT item_id, level FROM factories WHERE hid=?", (hid,)).fetchall()
    return {
        "hq_level": hq["level"] if hq else 0,
        "hq_influence": influence,
        "age": age,
        "balance": int(p["credits"] or 0),
        "points": points,
        "luxury_points": _one(conn, "SELECT points FROM luxury_points WHERE hid=?", (hid,)),
        "gambler": _one(conn, "SELECT value FROM news_counters WHERE hid=? AND key='casino_four_plus'", (hid,)),
        "decadence": _one(conn, "SELECT SUM(qty) FROM luxury_items WHERE hid=?", (hid,)),
        "factories": sum(r[1] or 0 for r in fac if r[0] not in special),
        "hoarder": _one(conn, "SELECT COUNT(*) FROM mines WHERE owner_hid=?", (hid,)),
        "attacker": _one(conn, "SELECT COUNT(*) FROM attacks WHERE attacker_hid=? AND success=1", (hid,)),
        "friend": _one(conn, "SELECT COUNT(*) FROM external_repairs WHERE helper_hid=?", (hid,)),
        # every level beyond the first is an upgrade
        "special": sum(max(0, (r[1] or 0) - 1) for r in fac if r[0] in special),
        "artifacts": _one(conn, "SELECT COUNT(*) FROM artifact_recoveries WHERE hid=?", (hid,)),
        "repairs": _one(conn, "SELECT COUNT(*) FROM game_events WHERE hid=? AND type='mine_repaired'", (hid,)),
        "streak": max(_one(conn, "SELECT MAX(length) FROM streak_rewards WHERE hid=? AND every=1", (hid,)), 0),
        "warehouse": int(p["wh_level"] or 1),
        "level": int(p["level"] or 1),
    }


def check(conn, h, hid) -> list:
    """Record newly reached tiers (inside the caller's tx). Returns the new ones."""
    m = metrics(conn, h, hid)
    new = []
    now = econ.utcnow_iso()
    for key, (title, _, tiers, _) in DEFS.items():
        for i, t in enumerate(tiers):
            if m[key] >= t:
                cur = conn.execute("INSERT OR IGNORE INTO achievements(hid, code, title, ts) VALUES(?,?,?,?)",
                                   (hid, f"{key}_{i + 1}", f"{title} — {TIER_NAMES[i]}", now))
                if cur.rowcount == 1:
                    new.append({"key": key, "tier": i + 1, "title": title})
    return new


def install(api) -> None:
    h = api.h

    @api.endpoint("/api/v1/achievements")
    def achievements(conn, hid, form):
        """Your achievements, or another player's (pid=..., public) — only your own are updated."""
        new = []
        pid = (form.get("pid") or "").strip()
        if pid:
            from . import social
            target = social.hid_of(conn, pid)            # raises no_player
        else:
            target = hid
        if target == hid:
            with econ.tx(conn):
                new = check(conn, h, hid)
        hid = target
        m = metrics(conn, h, hid)
        got = {r[0]: r[1] for r in conn.execute("SELECT code, ts FROM achievements WHERE hid=?", (hid,))}
        out = []
        for key, (title, desc, tiers, unit) in DEFS.items():
            stars = sum(1 for i in range(len(tiers)) if f"{key}_{i + 1}" in got)
            nxt = next((t for t in tiers if m[key] < t), None)
            out.append({"key": key, "title": title, "description": desc, "unit": unit, "label": LABELS[key],
                        "value": m[key],
                        "tiers": list(tiers), "stars": stars, "next": nxt,
                        "unlockedAt": [got.get(f"{key}_{i + 1}") for i in range(len(tiers))]})
        return {"err": 0, "achievements": out, "new": new,
                "stars": sum(a["stars"] for a in out), "maxStars": 3 * len(out)}
