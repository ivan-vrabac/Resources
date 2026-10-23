"""Leaderboards: overall (activity-weighted score, no XP shown), luxury points, and output per
resource — raw resources from mines or products from factories, per hour.

Mining output uses the same formula as rateHr (quality × condition × tech × level × HQ boost);
the HQ boost is evaluated in SQL with a flat-earth distance (exact enough within ≤ 250 m).
Results are cached for CACHE_S seconds per board so large worlds stay cheap.
"""
from __future__ import annotations

import datetime
import math
import time

import econ
from . import int_arg, social

CACHE_S = 300
MAX_ROWS = 100_000      # computed boards are cached in full and paged
PAGE = 100
_cache: dict = {}


def _cached(key, fn):
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < CACHE_S:
        return hit[1]
    val = fn()
    _cache[key] = (time.time(), val)
    return val


def overall_rows(conn):
    """Overall board rows (points, activity %, hid, level, country), best first (cached)."""
    return _cached("overall", lambda: _overall(conn))


def _overall(conn):
    now = datetime.datetime.utcnow()
    today = now.strftime("%Y-%m-%d")
    cutoff = (now - datetime.timedelta(days=100)).strftime("%Y-%m-%d")
    act_all = dict(conn.execute("SELECT hid, COUNT(*) FROM player_activity WHERE day<=? GROUP BY hid", (today,)).fetchall())
    act_100 = dict(conn.execute("SELECT hid, COUNT(*) FROM player_activity WHERE day>=? AND day<=? GROUP BY hid",
                                (cutoff, today)).fetchall())
    rows = []
    for r in conn.execute("SELECT hID, xp, level, country_code, created_at FROM players"):
        try:
            age = max(1, (now - datetime.datetime.fromisoformat(r["created_at"])).days)
        except (TypeError, ValueError):
            age = 1
        activity = min(1.0, act_all.get(r["hID"], 0) / age if age < 100 else act_100.get(r["hID"], 0) / 100.0)
        # points = XP × activity (share of days active, last 100 days) — owner 2026-10-23
        rows.append((round((r["xp"] or 0) * activity), round(activity * 100), r["hID"], r["level"], r["country_code"]))
    rows.sort(key=lambda x: -x[0])
    return rows


def install(api) -> None:
    h = api.h
    mine_res = {}                              # resource → [mine item ids]
    for mid, mt in h.MINE_TYPES.items():
        mine_res.setdefault(mt["res"], []).append(mid)
    factory_res = {}                           # product → [factory item ids]
    for fid, ft in h.FACTORY_TYPES.items():
        factory_res.setdefault(ft["produces"], []).append(fid)

    def mining(conn, res):
        ids = mine_res.get(res)
        if not ids:
            return []
        conn.execute("CREATE TEMP TABLE IF NOT EXISTS _hqc(hid TEXT PRIMARY KEY, lat REAL, lng REAL, r2 REAL, f REAL, k REAL)")
        conn.execute("DELETE FROM _hqc")
        conn.executemany("INSERT INTO _hqc VALUES(?,?,?,?,?,?)", [
            (r[0], r[1], r[2], h.HQ_BOOST_RADIUS.get(r[3], 115) ** 2, h.HQ_BOOST_FACTORS.get(r[3], 1.0),
             math.cos(math.radians(r[1]))) for r in conn.execute("SELECT hid, lat, lng, level FROM hq")])
        conn.execute("CREATE TEMP TABLE IF NOT EXISTS _mrate(item_id INTEGER PRIMARY KEY, rate REAL)")
        conn.execute("DELETE FROM _mrate")
        conn.executemany("INSERT INTO _mrate VALUES(?,?)", [(i, h.MINE_TYPES[i]["rate"]) for i in ids])
        sql = """
            SELECT m.owner_hid, SUM(t.rate * m.quality / 100.0 * MAX(0.1, m.condition / 100.0)
                   * (1.0 + (COALESCE(m.tu1,0) + COALESCE(m.tu2,0) + 1.5*COALESCE(m.tu3,0) + 1.5*COALESCE(m.tu4,0)) / 100.0)
                   * m.level
                   * CASE WHEN q.hid IS NOT NULL AND
                          ((m.lat-q.lat)*111320.0)*((m.lat-q.lat)*111320.0)
                          + ((m.lng-q.lng)*111320.0*q.k)*((m.lng-q.lng)*111320.0*q.k) <= q.r2
                     THEN q.f ELSE 1.0 END) AS out, COUNT(*)
            FROM mines m JOIN _mrate t ON t.item_id = m.item_id LEFT JOIN _hqc q ON q.hid = m.owner_hid
            GROUP BY m.owner_hid ORDER BY out DESC LIMIT ?"""
        rows = conn.execute(sql, (MAX_ROWS,)).fetchall()
        conn.commit()
        return [(round(r[1], 1), r[2], r[0]) for r in rows]

    def factory(conn, res):
        ids = factory_res.get(res)
        if not ids:
            return []
        rate = {fid: h.FACTORY_TYPES[fid]["out"] / h.FACTORY_TYPES[fid]["hrs"] for fid in ids}
        q = ",".join("?" * len(ids))
        acc = {}
        for r in conn.execute(f"SELECT hid, item_id, level FROM factories WHERE item_id IN ({q})", ids):
            v = acc.setdefault(r[0], [0.0, 0])
            v[0] += rate[r[1]] * (r[2] or 1)
            v[1] += 1
        rows = sorted(((round(v[0], 1), v[1], hid) for hid, v in acc.items()), reverse=True)[:MAX_ROWS]
        return rows

    def refs(conn, hids, viewer):
        return {x: social.public_ref(conn, x) for x in hids}

    def countries(conn):
        return _cached("countries", lambda: {r[0]: (r[1] or "") for r in
                                             conn.execute("SELECT hID, country_code FROM players")})

    def page_of(conn, hid, form, rows, hid_at):
        """Filter to the viewer's country (country=1), rank 1..n AFTER filtering, cut one page."""
        cc = countries(conn)
        mine_cc = cc.get(hid, "")
        if form.get("country") == "1" and mine_cc:
            rows = [r for r in rows if cc.get(hid_at(r), "") == mine_cc]
        page = int_arg(form, "page", 0, 0, 10**6)
        me = next((i for i, r in enumerate(rows) if hid_at(r) == hid), None)
        part = rows[page * PAGE:(page + 1) * PAGE]
        meta = {"page": page, "pages": max(1, -(-len(rows) // PAGE)), "total": len(rows),
                "myRank": None if me is None else me + 1, "myCountry": mine_cc,
                "countryFilter": form.get("country") == "1" and bool(mine_cc)}
        return [(page * PAGE + i + 1, r) for i, r in enumerate(part)], meta

    @api.endpoint("/api/v1/rank/players")
    def players(conn, hid, form):
        rows = overall_rows(conn)
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        return {"err": 0, **meta, "rows": [{"rank": n, **rf[r[2]], "score": r[0], "activity": r[1],
                                            "country": r[4] or "", "isMe": r[2] == hid} for n, r in part]}

    @api.endpoint("/api/v1/rank/luxury")
    def luxury(conn, hid, form):
        rows = conn.execute("SELECT hid, points FROM luxury_points WHERE points>0 ORDER BY points DESC").fetchall()
        part, meta = page_of(conn, hid, form, rows, lambda r: r[0])
        cc = countries(conn)
        out = []
        for n, r in part:
            items = [{"itemID": x[0], "qty": int(x[1])} for x in conn.execute(
                "SELECT item_id, qty FROM luxury_items WHERE hid=? AND qty>=1 ORDER BY qty DESC", (r[0],))]
            out.append({"rank": n, **social.public_ref(conn, r[0]), "points": r[1], "items": items,
                        "country": cc.get(r[0], ""), "isMe": r[0] == hid})
        mine = conn.execute("SELECT points FROM luxury_points WHERE hid=?", (hid,)).fetchone()
        return {"err": 0, **meta, "rows": out, "myPoints": int(mine[0]) if mine else 0}

    @api.endpoint("/api/v1/rank/resource")
    def resource(conn, hid, form):
        kind = (form.get("kind") or "mine").strip()
        options = {"mine": sorted(mine_res), "factory": sorted(factory_res)}
        item = int_arg(form, "item", options["mine"][0] if kind == "mine" else options["factory"][0], 0, 10**6)
        if kind not in options or item not in options[kind]:
            raise econ.GameError("bad_input", "Choose a resource from the list")
        rows = _cached(f"{kind}:{item}", lambda: (mining if kind == "mine" else factory)(conn, item))
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        cc = countries(conn)
        return {"err": 0, **meta, "kind": kind, "item": item, "options": options,
                "rows": [{"rank": n, **rf[r[2]], "perHour": r[0], "count": r[1], "country": cc.get(r[2], ""),
                          "isMe": r[2] == hid} for n, r in part]}
