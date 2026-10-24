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
    boosted = min(100, -(-8 // ft["hrs"]))       # the batches of its 8 h (level 1 here)
    assert abs(r["prodAmt"] - ft["out"] * (100 + boosted * 0.5)) < 1e-6


def test_quest_credits_follow_the_level():
    assert quests.quest_credits(30) > 20 * quests.quest_credits(10) / 10
    for lvl in (1, 10, 30, 60, 80):
        step = economy.xp_to_start(lvl + 1) - economy.xp_to_start(lvl)
        assert quests.quest_credits(lvl) == max(quests.QUEST_MIN_CREDITS,
                                                round(step / economy.XP_PER_CREDIT * 0.15, -2))


def test_special_items_sold_to_the_system_never_bought():
    p = economy.system_prices()
    assert all(i in p for i in economy.SELL_ONLY)
    v = economy.ARTIFACT_VALUE
    assert v[176] > v[173] > v[175] > v[174] >= v[172]               # rarer = dearer
    hid, sid, _ = new_player("ap", credits=10**13)
    assert call("/api/v1/market/system", sid, side="buy", itemID=176, qty=1)["err"] != 0
    give(hid, 172, 1)
    assert call("/api/v1/market/system", sid, side="sell", itemID=172, qty=1)["err"] == 0
    items = {e["itemID"]: e for e in call("/api/v1/market/overview", sid)["items"]}
    assert all(items[i]["systemBuy"] is None and items[i]["systemSell"] for i in economy.SELL_ONLY)


def test_own_resources_beat_buying_inputs():
    """Buying inputs from the system may pay a little (owner 2026-10-24), but a player's own mined
    resources always pay more."""
    p = economy.system_prices()
    for fid in economy.FACTORIES:
        b = economy.batch(fid)
        inputs = sum(p[i] * q for i, q in b["needs"].items())
        own = p[b["produces"]] * b["out"] - inputs - b["credits"]
        bought = p[b["produces"]] * b["out"] - inputs * 1.5 * 1.05 - b["credits"]
        assert own > bought and economy.factory_profit_h(fid) > 0, economy.FACTORIES[fid][0]


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


def test_site_holds_about_100_mixed_artifacts_same_for_everyone():
    from systems import archaeology as A
    for sid in ("1:2:D3", "4:5:D6", "-7:8:D9"):
        m = A.site_mix(sid)
        assert m == A.site_mix(sid) and 90 <= sum(m.values()) <= 110 and set(m) <= set(A.ARTIFACTS)


def test_drop_table_per_100_crates():
    from systems import cargo
    t = cargo.drop_table()
    assert abs(sum(e["per100"] for e in t) - 100) < 0.01
    assert {e["itemID"] for e in t} == set(cargo.BOX_LOOT)


def test_artifact_hunting_pays_5_to_10_times_even_in_a_bad_case():
    from systems import archaeology as A
    p = economy.system_prices()
    w = A.ARTIFACT_WEIGHTS
    site = 100 * sum(economy.ARTIFACT_VALUE[k] * q for k, q in w.items()) / sum(w.values())
    bad = 50 * p[166] + 1000 * p[167]           # 50 scans and 1 000 archaeologists for one site
    assert site / bad >= 5
    usual = 2 * p[166] + A.archaeologists_needed(1) * p[167]
    assert site / usual > 10
