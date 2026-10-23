"""Economy revamp (owner 2026-10-23): atomic legacy endpoints, XP only from permanent sinks,
working atmosphere, accidents, strikes, penalties, travel check."""
import datetime
import json
import threading
import zlib

import econ
import economy
import main
from helpers import call, client, credits, give, new_player, qty, set_building


def legacy(path, sid, **form):
    r = client.post("/flut23/" + path, data={"sid": sid, **{k: str(v) for k, v in form.items()}})
    return json.loads(zlib.decompress(r.content))


def xp(hid):
    with main.get_db() as conn:
        return conn.execute("SELECT xp FROM players WHERE hID=?", (hid,)).fetchone()[0]


def factory_id(hid, item_id):
    with main.get_db() as conn:
        return conn.execute("SELECT factory_id FROM factories WHERE hid=? AND item_id=?", (hid, item_id)).fetchone()[0]


def test_economy_tables_are_consistent():
    # every product earns (except the fixed-price drones and detectors)
    for fid, f in economy.FACTORIES.items():
        if f[1] not in economy.FIXED_PRICES:
            assert economy.factory_profit_h(fid) > 0, f[0]
    # srs.txt rates at 100 % quality, no mine levels
    assert main.MINE_TYPES[4]["rate"] == 1530 and main.MINE_TYPES[82]["rate"] == 1275
    # payback of factory upgrades keeps growing
    b = economy.factory_build(25)["credits"]
    assert economy.factory_upgrade(25, 100)["credits"] > 100 * b
    # level curve: smooth and increasing, exponential beyond 60
    xs = [economy.xp_to_start(l) for l in range(1, 80)]
    assert all(b > a for a, b in zip(xs, xs[1:]))
    assert economy.level_from_xp(economy.xp_to_start(50)) == 50


def test_market_trades_give_no_xp_but_sinks_do():
    hid, sid, _ = new_player("rvx", credits=10_000_000, wh_level=5)
    before = xp(hid)
    call("/api/v1/market/system", sid, side="buy", itemID=2, qty=100)
    assert xp(hid) == before                                  # buying gives no XP
    r = legacy("lagerUpgrade.php", sid)
    assert r["err"] == 0 and xp(hid) == before + int(r["cost"] * economy.XP_PER_CREDIT)


def test_hq_deposit_xp_by_value_and_hq_needs_gps():
    hid, sid, _ = new_player("rvh", credits=1_000_000, wh_level=50)
    assert legacy("HQNewPosition.php", sid, lat=45.0, lng=15.0)["err"] != 0              # no GPS: refused
    assert legacy("HQNewPosition.php", sid, lat=45.0, lng=15.0, cur_lat=45.05, cur_lng=15.0)["code"] == "range"
    assert legacy("HQNewPosition.php", sid, lat=45.0, lng=15.0, cur_lat=45.001, cur_lng=15.0)["err"] == 0
    r = legacy("HQNewPosition.php", sid, lat=45.0005, lng=15.0, cur_lat=45.001, cur_lng=15.0)
    assert r["code"] == "cooldown"                                                      # one move per day
    give(hid, 2, 1000)
    before = xp(hid)
    r = legacy("hqDeposit.php", sid, amt_2=1000)
    assert r["deposited"] == {"2": 1000}
    assert xp(hid) == before + int(1000 * main.SYSTEM_PRICES[2] * economy.XP_PER_CREDIT)


def test_double_collect_and_double_refund_are_impossible():
    hid, sid, _ = new_player("rvd", credits=0, wh_level=50)
    set_building(hid, 25, 1)
    fid = factory_id(hid, 25)
    past = (datetime.datetime.utcnow() - datetime.timedelta(hours=1)).isoformat()
    with main.get_db() as conn:
        conn.execute("UPDATE factories SET prod_item=24, prod_amount=800, prod_start=?, prod_end=? WHERE factory_id=?",
                     (past, past, fid))
        conn.commit()
    out = []
    ts = [threading.Thread(target=lambda: out.append(legacy("factoryCollect.php", sid, fID=fid))) for _ in range(6)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert sum(1 for r in out if r["err"] == 0) == 1 and qty(hid, 24) == 800
    mid = main.new_id()
    with main.get_db() as conn:
        conn.execute("INSERT INTO mines(mine_id, owner_hid, lat, lng, item_id, quality, paid) VALUES(?,?,?,?,4,50,40000)",
                     (mid, hid, 44.0, 15.0))
        conn.commit()
    out = []
    ts = [threading.Thread(target=lambda: out.append(legacy("mineDelete.php", sid, mID=mid))) for _ in range(6)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert sum(1 for r in out if r["err"] == 0) == 1 and credits(hid) == 4000


def test_legacy_market_and_mine_levels_are_gone_and_bulk_upgrade_is_bounded():
    hid, sid, _ = new_player("rvl", credits=10**15)
    assert legacy("marketNewReq.php", sid, itemID=2, qty=1, priceUnit=1)["err"] == 9
    assert legacy("mineUpgrade.php", sid, mID="x")["err"] == 2
    r = legacy("lagerUpgradeMulti.php", sid, levels=10**9)             # bounded to 1000 levels, priced, refused
    assert r["err"] == 2 and r["cost"] > 10**15
    r = legacy("lagerUpgradeMulti.php", sid, levels=5)
    assert r["err"] == 0 and r["newLvl"] == 6


def test_factory_upgrade_has_no_cap_and_boost_needs_a_diamond():
    hid, sid, _ = new_player("rvf", credits=10**12, wh_level=200)
    set_building(hid, 25, 7)
    fid = factory_id(hid, 25)
    cost = economy.factory_upgrade(25, 7)
    for i, q in cost["res"].items():
        give(hid, i, q)
    r = legacy("factoryUpgrade.php", sid, fID=fid)
    assert r["err"] == 0 and r["newLvl"] == 8 and r["cost"] == cost["credits"]
    give(hid, 2, 100_000)
    assert legacy("factoryNewOrder.php", sid, fID=fid, batches=10)["err"] == 0
    assert legacy("factoryBoost.php", sid, fID=fid)["err"] == 5                     # no Giant Diamond
    give(hid, 42, 1)
    assert legacy("factoryBoost.php", sid, fID=fid)["err"] == 0 and qty(hid, 42) == 0


def test_strike_freezes_until_settled_and_wa_moves():
    hid, sid, _ = new_player("rvs", credits=1_000_000, wh_level=50)
    set_building(hid, 25, 1)
    fid = factory_id(hid, 25)
    with main.get_db() as conn:
        conn.execute("UPDATE factories SET strike_at=?, strike_cost=50000 WHERE factory_id=?", (main.utcnow_iso(), fid))
        conn.execute("UPDATE players SET wa=50 WHERE hID=?", (hid,))
        conn.commit()
    give(hid, 2, 10_000)
    assert legacy("factoryNewOrder.php", sid, fID=fid)["err"] == 7                  # frozen
    assert legacy("factoryUpgrade.php", sid, fID=fid)["err"] == 7
    assert call("/api/v1/strike/settle", sid, fID=fid, how="force")["code"] == "insufficient_items"
    r = call("/api/v1/strike/settle", sid, fID=fid, how="pay")
    assert r["paid"] == 50000 and r["wa"] == 55.0 and credits(hid) == 950_000
    assert legacy("factoryNewOrder.php", sid, fID=fid)["err"] == 0


def test_penalty_takes_credits_and_warehouse_share_and_may_go_negative():
    hid, sid, _ = new_player("rvp", credits=1_000_000, wh_level=50)
    give(hid, 2, 10_000)
    with main.get_db() as conn:
        conn.execute("UPDATE players SET wa=100 WHERE hID=?", (hid,))
        conn.commit()
        with econ.tx(conn):
            charged = main.SYSTEM_HELPERS.PENALTY(conn, hid, "fire", "f1", {})
    assert charged == round(0.05 * 1_000_000 + 0.05 * 10_000 * main.SYSTEM_PRICES[2])
    set_building(hid, 72, 10)                                                     # Law Firm 10: −50 %
    with main.get_db() as conn:
        conn.execute("UPDATE players SET credits=0 WHERE hID=?", (hid,))
        conn.commit()
        with econ.tx(conn):
            charged = main.SYSTEM_HELPERS.PENALTY(conn, hid, "fire", "f1", {})
    assert charged == round(0.5 * 0.05 * 10_000 * main.SYSTEM_PRICES[2]) and credits(hid) == -charged


def test_idle_factories_lower_wa_and_empty_companies_stay_at_100():
    hid, sid, _ = new_player("rvi")
    set_building(hid, 25, 1)
    old = (datetime.datetime.utcnow() - datetime.timedelta(days=3)).isoformat()
    yesterday = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
    with main.get_db() as conn:
        conn.execute("UPDATE factories SET last_active=? WHERE hid=?", (old, hid))
        conn.execute("UPDATE players SET wa=80 WHERE hID=?", (hid,))
        conn.execute("INSERT OR REPLACE INTO incident_clock(hid, last_day) VALUES(?,?)", (hid, yesterday))
        conn.commit()
    import systems.incidents as inc
    old_p = (inc.P_AT_100, inc.P_AT_0)
    inc.P_AT_100 = inc.P_AT_0 = 0.0          # no random accidents in this test
    try:
        r = call("/api/v1/incidents", sid)
    finally:
        inc.P_AT_100, inc.P_AT_0 = old_p
    assert r["wa"] == 78.0                                                         # one idle factory, one day
    e_hid, e_sid, _ = new_player("rve")
    assert call("/api/v1/incidents", e_sid)["wa"] == 100.0                        # new companies start at 100 %
    with main.get_db() as conn:
        conn.execute("UPDATE players SET wa=99.9 WHERE hID=?", (e_hid,))         # e.g. after a won attack
        conn.execute("INSERT OR REPLACE INTO incident_clock(hid, last_day) VALUES(?,?)", (e_hid, yesterday))
        conn.commit()
    assert call("/api/v1/incidents", e_sid)["wa"] == 99.9                         # no reset over attack losses


def test_accident_chance_scales_with_wa():
    import systems.incidents as inc
    assert inc.accident_chance(100) == 0.01 and abs(inc.accident_chance(0) - 0.10) < 1e-9
    assert inc.accident_chance(50) > inc.accident_chance(80)


def test_teleporting_is_refused():
    hid, sid, _ = new_player("rvt", credits=1_000_000)
    with main.get_db() as conn:
        with econ.tx(conn):
            main.check_travel(conn, hid, 45.0, 15.0)
        try:
            with econ.tx(conn):
                main.check_travel(conn, hid, 48.0, 15.0)        # 333 km a moment later
            assert False, "teleport accepted"
        except econ.GameError as e:
            assert e.code == "teleport"
        with econ.tx(conn):
            main.check_travel(conn, hid, 45.01, 15.0)           # 1 km: fine


def test_rename_costs_and_rules():
    hid, sid, name = new_player("rvn")
    assert call("/api/v1/account/rename", sid, name="F.u.c.k Ltd")["code"] == "invalid_name"
    r = call("/api/v1/account/rename", sid, name="Clean Mining")
    assert r["err"] == 0 and r["costGD"] == 0 and r["nextCostGD"] == 10              # first change free
    assert call("/api/v1/account/rename", sid, name="Clean Mining Two")["code"] == "insufficient_items"
    give(hid, 42, 10)
    r = call("/api/v1/account/rename", sid, name="Clean Mining Two")
    assert r["costGD"] == 10 and r["nextCostGD"] == 20 and qty(hid, 42) == 0
    r = client.post("/api/v1/auth/session", data={"name": "Clean Mining Two", "password": "password1", "mode": "login"})
    assert r.json()["hID"] == hid                                                   # signs in with the new name


def test_gdpr_delete_young_now_old_after_30_days_login_cancels():
    hid, sid, name = new_player("rvg")
    give(hid, 2, 100)
    r = call("/api/v1/account/delete", sid, confirm="DELETE")
    assert r["deleted"] is True
    with main.get_db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM players WHERE hID=?", (hid,)).fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM warehouse WHERE hid=?", (hid,)).fetchone()[0] == 0
    r = client.post("/api/v1/auth/session", data={"name": name, "password": "password1", "mode": "register"})
    assert r.json().get("created") is True                                          # the name is free again
    old, old_sid, old_name = new_player("rvo")
    with main.get_db() as conn:
        conn.execute("UPDATE players SET created_at='2026-01-01T00:00:00' WHERE hID=?", (old,))
        conn.commit()
    r = call("/api/v1/account/delete", old_sid, confirm="DELETE")
    assert r["deleted"] is False and r["deleteAt"]
    r = client.post("/api/v1/auth/session", data={"name": old_name, "password": "password1", "mode": "login"})
    assert r.json()["deletionCancelled"] is True
    assert call("/api/v1/account/info", old_sid)["deleteAt"] is None


def test_accidents_need_level_50_and_buildings_cut_their_impact():
    import systems.incidents as inc
    hid, sid, _ = new_player("rva", credits=1_000_000, level=10)
    set_building(hid, 25, 1)
    yesterday = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
    with main.get_db() as conn:
        conn.execute("UPDATE factories SET last_active=? WHERE hid=?", (main.utcnow_iso(), hid))
        conn.execute("INSERT OR REPLACE INTO incident_clock(hid, last_day) VALUES(?,?)", (hid, yesterday))
        conn.commit()
    old = (inc.P_AT_100, inc.P_AT_0)
    inc.P_AT_100 = inc.P_AT_0 = 1.0                     # an accident would be certain
    try:
        assert call("/api/v1/incidents", sid)["incidents"] == []                   # level 10: none
    finally:
        inc.P_AT_100, inc.P_AT_0 = old
    with main.get_db() as conn:
        conn.execute("UPDATE players SET wa=100, credits=1000000 WHERE hID=?", (hid,))
        conn.commit()
        with econ.tx(conn):
            plain = main.SYSTEM_HELPERS.PENALTY(conn, hid, "disease", "m", {})
    set_building(hid, 71, 10)                                                     # Hospital 10
    with main.get_db() as conn:
        conn.execute("UPDATE players SET wa=100, credits=1000000 WHERE hID=?", (hid,))
        conn.commit()
        with econ.tx(conn):
            protected = main.SYSTEM_HELPERS.PENALTY(conn, hid, "disease", "m", {})
    assert protected < plain * 0.4


def test_notification_kinds_defaults_and_limits():
    hid, sid, _ = new_player("rvq")
    r = call("/api/v1/notify/prefs", sid)
    by = {k["kind"]: k for k in r["kinds"]}
    assert set(by) == {"outbid", "auction_won", "order_filled", "factory_done", "accident"}
    assert by["outbid"]["maxPerDay"] == 0 and by["auction_won"]["maxPerDay"] == 0          # auctions: unlimited
    assert by["accident"]["maxPerDay"] > 0
    r = call("/api/v1/notify/set", sid, kind="accident", enabled=1, maxPerDay=0)            # unlimited allowed
    assert {k["kind"]: k for k in r["kinds"]}["accident"]["maxPerDay"] == 0
    assert call("/api/v1/notify/set", sid, kind="accident", maxPerDay=7)["code"] == "bad_input"
    r = call("/api/v1/notify/set", sid, kind="factory_done", enabled=0, maxPerDay=10)
    assert {k["kind"]: k for k in r["kinds"]}["factory_done"]["enabled"] is False

