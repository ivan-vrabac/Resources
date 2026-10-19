"""Phase 9: news from real events (dedup, privacy, pagination), earthquakes, protection factors."""
import datetime

import econ
import main
import protection as P
from helpers import call, new_player, set_building
from systems import news as N


def _digest():
    with main.get_db() as conn:
        with econ.tx(conn):
            N.digest_events(conn)


def _emit(type_, hid, data, **kw):
    with main.get_db() as conn:
        econ.emit(conn, type_, hid, data, **kw)
        conn.commit()


def test_news_from_events_once():
    hid, sid, name = new_player("nw1")
    _emit("casino_jackpot", hid, {"amount": 123})
    _digest()
    _digest()                                                    # cursor: never twice
    items = [i for i in call("/api/v1/news", sid, category="casino")["items"] if i["kind"] == "jackpot"
             and i["players"] and i["players"][0].get("name") == name]
    assert len(items) == 1 and name in items[0]["title"]
    assert hid not in str(items)


def test_mines_24h_milestone_dedup():
    hid, sid, _ = new_player("nw3")
    for _ in range(N.MINES_24H_THRESHOLDS[0] + 5):
        _emit("mine_built", hid, {}, public=False)
    _digest()
    _emit("mine_built", hid, {}, public=False)
    _digest()
    with main.get_db() as conn:
        n = conn.execute("SELECT COUNT(*) FROM news_items WHERE kind='mines24' AND hid=?", (hid,)).fetchone()[0]
    assert n == 1


def test_pagination():
    hid, sid, _ = new_player("nw4")
    for i in range(N.PAGE + 5):
        _emit("auction_won", hid, {"itemID": 128, "price": i})
    _digest()
    p1 = call("/api/v1/news", sid, category="auctions")
    assert p1["more"] and len(p1["items"]) == N.PAGE
    p2 = call("/api/v1/news", sid, category="auctions", before=p1["next"])
    assert p2["items"] and p2["items"][0]["id"] < p1["items"][-1]["id"]


def test_quake_plan_deterministic_and_in_range():
    qs = [N.plan_quake(f"2026-01-{d:02d}") for d in range(1, 29)]
    assert N.plan_quake("2026-01-05") == qs[4]
    assert all(5 <= q["magnitude"] <= 9 and 1 <= q["radius_km"] <= 50 for q in qs)
    q = {**qs[0], "radius_km": 50, "peak": 70}
    assert N.quake_damage(q, 0) == 70 and N.quake_damage(q, 50_001) == 0
    assert N.quake_damage(q, 0, seismo_level=10) == 70 * P.quake_factor(10)


def test_quake_runs_once_damages_without_deleting():
    day = "2026-02-03"
    q = N.plan_quake(day)
    owner, sid, _ = new_player("nw5")
    prot, _, _ = new_player("nw6")
    set_building(prot, P.SEISMOLOGY, 10)
    ids = []
    with main.get_db() as conn:
        for o in (owner, prot):
            mid = main.new_id()
            conn.execute("INSERT INTO mines(mine_id, owner_hid, lat, lng, item_id, quality, condition, last_coll) "
                         "VALUES(?,?,?,?,4,100,30,?)", (mid, o, q["lat"], q["lng"], econ.utcnow_iso()))
            ids.append(mid)
        conn.commit()
    when = datetime.datetime.fromisoformat(q["at"]) + datetime.timedelta(minutes=1)
    with main.get_db() as conn:
        res = N.run_quake(conn, main.SYSTEM_HELPERS, when, day)
        again = N.run_quake(conn, main.SYSTEM_HELPERS, when, day)
        conds = [conn.execute("SELECT condition FROM mines WHERE mine_id=?", (m,)).fetchone() for m in ids]
        news = conn.execute("SELECT COUNT(*) FROM news_items WHERE dedup=?", (f"quake:{day}",)).fetchone()[0]
    assert res and again is None and news == 1
    assert all(c is not None for c in conds)                     # still there (no direct deletion)
    assert conds[0][0] <= conds[1][0] < 30                       # seismology centre reduces damage
    assert res["damaged_mines"] >= 2 and res["companies"] >= 2


def test_protection_factors():
    assert P.disease_factor(0) == 1 and round(P.disease_factor(10), 2) == 0.3
    assert round(P.fire_factor(10), 2) == 0.2 and round(P.quake_factor(10), 2) == 0.4


def test_daily_awards_and_anniversaries_once_per_day():
    rich, sid, rich_name = new_player("nwrich")
    old, _, old_name = new_player("nwold")
    now = econ.utcnow()
    with main.get_db() as conn:
        conn.execute("UPDATE players SET credits=? WHERE hID=?", (10**15, rich))
        conn.execute("UPDATE players SET created_at=? WHERE hID=?",
                     (now.replace(year=now.year - 5, hour=0).isoformat(), old))
        conn.execute("DELETE FROM news_items WHERE category='awards' OR kind IN ('jubilee100', 'anniversary')")
        conn.commit()
        with econ.tx(conn):
            assert N.daily_awards(conn, main.SYSTEM_HELPERS, now) > 0
            assert N.daily_awards(conn, main.SYSTEM_HELPERS, now) == 0          # once per day
    items = call("/api/v1/news", sid, category="awards")["items"]
    assert any(i["kind"] == "rich" and rich_name in i["title"] for i in items)
    assert all(i["kind"] != "marker" for i in items)
    assert rich not in str(items)
    players = call("/api/v1/news", sid, category="players")["items"]
    assert any(i["kind"] == "anniversary" and "Five years" in i["title"] for i in players)
