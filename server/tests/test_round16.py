"""Round 16 (owner 2026-10-24): free repair in the boss range, booster limited to its 8 hours,
quest credits that follow the level, artifact prices in billions, news of the last 24 hours."""
import datetime

import economy
import main
from helpers import call, credits, give, new_player, set_building
from systems import quests

LAT, LNG = 45.0, 16.0


def _mine(hid, condition=40):
    mid = main.new_id()
    with main.get_db() as conn:
        conn.execute("INSERT INTO mines(mine_id, owner_hid, lat, lng, item_id, quality, condition) "
                     "VALUES(?,?,?,?,4,80,?)", (mid, hid, LAT, LNG, condition))
        conn.commit()
    return mid


def _cond(mid):
    with main.get_db() as conn:
        return conn.execute("SELECT condition FROM mines WHERE mine_id=?", (mid,)).fetchone()[0]


def test_free_repair_needs_boss_range_and_costs_nothing():
    hid, sid, _ = new_player("fr", credits=1000)
    mid = _mine(hid)
    far = LAT + 150 / 111320.0              # 150 m north: outside 100 m without a Haulage Firm
    r = call("/flut23/mineMaintAFree.php", sid, mID=mid, lat=far, lng=LNG)
    assert r["err"] != 0 and _cond(mid) < 100
    set_building(hid, 123, 5)                # Haulage Firm 5 → 150 m
    r = call("/flut23/mineMaintAFree.php", sid, mID=mid, lat=far, lng=LNG)
    assert r["err"] == 0 and _cond(mid) == 100 and credits(hid) == 1000


def test_free_repair_only_own_mines():
    a, _, _ = new_player("fa")
    _, sid_b, _ = new_player("fb")
    mid = _mine(a)
    r = call("/flut23/mineMaintAFree.php", sid_b, mID=mid, lat=LAT, lng=LNG)
    assert r["err"] != 0 and _cond(mid) < 100


def test_booster_only_raises_batches_in_its_window():
    hid, sid, _ = new_player("bo", credits=10**12, level=60)
    set_building(hid, 25, 1)                 # Brick Factory, level 1
    with main.get_db() as conn:
        fid = conn.execute("SELECT factory_id FROM factories WHERE hid=? AND item_id=25", (hid,)).fetchone()[0]
    ft = main.FACTORY_TYPES[25]
    for i, q in ft["needs"].items():
        give(hid, i, q * 100)
    give(hid, 161, 1)                        # Wage Subsidy +50 % for 8 h
    assert call("/flut23/factoryUseBooster.php", sid, fID=fid, itemID=161)["err"] == 0
    r = call("/flut23/factoryNewOrder.php", sid, fID=fid, batches=100)
    assert r["err"] == 0
    boosted = min(100, -(-8 // ft["hrs"]))       # 8 h of level-1 batches, whatever the level
    assert abs(r["prodAmt"] - ft["out"] * (100 + boosted * 0.5)) < 1e-6


def test_quest_credits_follow_the_level():
    assert quests.quest_credits(30) > 20 * quests.quest_credits(10) / 10
    for lvl in (1, 10, 30, 60, 80):
        step = economy.xp_to_start(lvl + 1) - economy.xp_to_start(lvl)
        assert quests.quest_credits(lvl) == max(quests.QUEST_MIN_CREDITS,
                                                round(step / economy.XP_PER_CREDIT * 0.15, -2))


def test_artifacts_players_only_no_system_trade():
    p = economy.system_prices()
    assert not any(i in p for i in range(172, 178))
    v = economy.ARTIFACT_VALUE
    assert v[176] > v[173] > v[175] > v[174] >= v[172] >= 1e9      # reference value: rarer = dearer
    hid, sid, _ = new_player("ap", credits=10**13)
    r = call("/api/v1/market/system", sid, side="buy", itemID=176, qty=1)
    assert r["err"] != 0
    give(hid, 172, 1)
    r = call("/api/v1/market/system", sid, side="sell", itemID=172, qty=1)
    assert r["err"] != 0
    items = {e["itemID"]: e for e in call("/api/v1/market/overview", sid)["items"]}
    assert all(i in items and items[i]["systemSell"] is None for i in range(172, 178))


def test_no_money_loop_through_factories():
    """Buying every input from the system (150 % + the lowest tax) and selling the product back
    never pays, at any factory."""
    p = economy.system_prices()
    for fid in economy.FACTORIES:
        b = economy.batch(fid)
        cost = sum(p[i] * q for i, q in b["needs"].items()) * 1.5 * 1.05 + b["credits"]
        assert p[b["produces"]] * b["out"] < cost, economy.FACTORIES[fid][0]
        assert economy.factory_profit_h(fid) > 0, economy.FACTORIES[fid][0]   # own resources still pay


def test_no_money_loop_through_recycling():
    from systems import cargo
    p = economy.system_prices()
    best_yield = 1.0 * 1.3          # Recycling Plant 10 + Shadow Obelisk level 3
    for item, outs in cargo.RECYCLE.items():
        value = sum(p.get(t, 0) * u * best_yield / len(outs) for t, u in outs)
        assert value < p[item] * 1.5 * 1.05, item


def test_news_shows_the_last_24_hours():
    _, sid, _ = new_player("nw")
    old = (datetime.datetime.utcnow() - datetime.timedelta(hours=30)).isoformat()
    new = datetime.datetime.utcnow().isoformat()
    with main.get_db() as conn:
        for ts, tag in ((old, "old"), (new, "new")):
            conn.execute("INSERT INTO news_items(ts, category, kind, data, dedup) VALUES(?,?,?,?,?)",
                         (ts, "players", "level", '{"level": 50}', f"r16:{tag}:{ts}"))
        conn.commit()
    items = call("/api/v1/news", sid)["items"]
    assert any(i["ts"] == new for i in items) and not any(i["ts"] == old for i in items)


def test_artifact_area_cooldown_12_hours():
    from systems import archaeology as A
    hid, _, _ = new_player("ac")
    now = datetime.datetime.utcnow()
    with main.get_db() as conn:
        conn.execute("INSERT INTO artifact_recoveries(site_id, hid, item_id, lat, lng, ts) VALUES(?,?,?,?,?,?)",
                     ("100:200:D1", hid, 172, 0, 0, (now - datetime.timedelta(hours=11)).isoformat()))
        conn.execute("INSERT INTO artifact_recoveries(site_id, hid, item_id, lat, lng, ts) VALUES(?,?,?,?,?,?)",
                     ("500:500:D1", hid, 172, 0, 0, (now - datetime.timedelta(hours=13)).isoformat()))
        conn.commit()
        cool = A.cooling_cells(conn, hid, now)
    assert (100, 200) in cool and (101, 201) in cool and (99, 199) in cool
    assert (102, 200) not in cool and (500, 500) not in cool
