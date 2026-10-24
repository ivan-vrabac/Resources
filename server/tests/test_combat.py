"""Phase 6: attacks (dice battle, range, 24 h cooldown, created loot halving, damage, intel), repair cost,
external repair."""
import datetime
import random

import econ
import main
from helpers import call, give, new_player, qty, set_building
from systems import combat as C

LAT, LNG = 45.80, 15.97


def _mine(owner, lat=LAT, lng=LNG, condition=100, item_id=4):
    mid = main.new_id()
    with main.get_db() as conn:
        conn.execute("INSERT INTO mines(mine_id, owner_hid, lat, lng, item_id, quality, condition) "
                     "VALUES(?,?,?,?,?,?,?)", (mid, owner, lat, lng, item_id, 100, condition))
        conn.execute("INSERT OR IGNORE INTO player_activity(hid, day) VALUES(?,?)",
                     (owner, econ.utcnow().strftime("%Y-%m-%d")))
        conn.commit()
    return mid


def _cond(mid):
    with main.get_db() as conn:
        r = conn.execute("SELECT condition FROM mines WHERE mine_id=?", (mid,)).fetchone()
        return None if r is None else r[0]


def test_calibration_matches_eva_examples():
    assert C.attack_values(5) == (7.2, 72.2, 144.4)
    assert C.defence_values(10) == (10.0, 100.0, 200.0)
    assert C.attack_range(1) == 100 and C.attack_range(10) == 500 and C.helper_range(10) == 200


def test_battle_is_conserving_and_decisive():
    a, d = C.battle((50, 0, 0), (7.2, 72.2, 144.4), (10, 0, 0), (5, 50, 100), 1, 1, random.Random(1))
    assert (sum(a) == 0) != (sum(d) == 0)
    assert all(0 <= x <= y for x, y in zip(a, (50, 0, 0)))


def test_attack_rules_range_mafia_own_mine():
    att, a_sid, _ = new_player("cb1")
    dfd, d_sid, _ = new_player("cb2")
    mid = _mine(dfd)
    give(att, 104, 10)
    assert call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT, lng=LNG, army=1)["code"] == "locked"
    set_building(att, C.MAFIA_HQ, 1)                                  # 40 m
    far = call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT + 0.001, lng=LNG, army=1)
    assert far["code"] == "out_of_range"
    own = _mine(att)
    assert call("/api/v1/combat/attack", a_sid, mineID=own, lat=LAT, lng=LNG, army=1)["code"] == "own_mine"
    assert call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT, lng=LNG, army=11)["code"] == "insufficient_items"
    assert qty(att, 104) == 10                                        # nothing taken on failure


def test_strong_attack_creates_loot_and_24h_cooldown():
    att, a_sid, _ = new_player("cb3")
    dfd, _, _ = new_player("cb4")
    set_building(att, C.MAFIA_HQ, 10)
    with main.get_db() as conn:
        conn.execute("UPDATE players SET wh_level=40 WHERE hID=?", (att,))
        conn.commit()
    mid = _mine(dfd, lat=LAT + 0.01)
    res = main.MINE_TYPES[4]["res"]
    give(dfd, res, 1_000_000)
    give(att, 104, 500)
    r = call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT + 0.01, lng=LNG, army=500, rid="x1")
    assert r["err"] == 0 and r["success"]
    assert r["loot"] > 0 and r["lootHalvings"] == 0
    assert qty(dfd, res) == 1_000_000                                 # defender keeps stock: loot is new
    assert qty(att, res) == r["loot"]
    assert qty(att, 104) == sum(r["attackersLeft"])
    assert 10 <= r["damage"] <= 70
    again = call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT + 0.01, lng=LNG, army=500, rid="x1")
    assert again["attackID"] == r["attackID"]                         # idempotent replay
    if not r["destroyed"]:
        assert _cond(mid) == r["condition"] < 100
        give(att, 104, 10)
        with main.get_db() as conn:                                   # 23 h later: still cooling down
            conn.execute("UPDATE attacks SET ts=? WHERE mine_id=?",
                         ((econ.utcnow() - datetime.timedelta(hours=23)).isoformat(), mid))
            conn.commit()
        assert call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT + 0.01, lng=LNG, army=10)["code"] == "cooldown"
    # second successful attack (another mine) in 24 h: loot halved
    mid2 = _mine(dfd, lat=LAT + 0.011)
    give(att, 104, 500)
    r2 = call("/api/v1/combat/attack", a_sid, mineID=mid2, lat=LAT + 0.011, lng=LNG, army=500)
    assert r2["success"] and r2["lootHalvings"] == 1


def test_weak_attack_fails_damages_less_and_deserters_join_defence():
    att, a_sid, _ = new_player("cb5")
    dfd, d_sid, _ = new_player("cb6")
    set_building(att, C.MAFIA_HQ, 1)
    mid = _mine(dfd, lat=LAT + 0.02)
    give(att, 102, 100)                                               # 100 dogs vs 200 dogs + 5 staff + 1 elite
    r = call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT + 0.02, lng=LNG, dogs=100)
    assert r["err"] == 0 and not r["success"] and "loot" not in r
    assert 10 <= r["damage"] <= 30 and abs(_cond(mid) - (100 - r["damage"])) < 0.2
    own = call("/api/v1/combat/info", d_sid, mineID=mid)["target"]
    assert own["stationed"][0] == r["deserters"][0] == int((100 - r["attackersLeft"][0]) * 0.1)


def test_damage_scales_with_strength_and_outcome():
    assert C.attack_damage(0, True) == 10 and C.attack_damage(C.STRENGTH_FULL, True) == 70
    assert C.attack_damage(C.STRENGTH_FULL, False) == 30
    assert C.attack_damage(1000, True) < C.attack_damage(10000, True)


def test_defence_estimate_exact_only_at_mafia_10():
    exact, ok = C.estimate([200, 5, 1], 10, "k")
    assert ok and exact == [200, 5, 1]
    est, ok = C.estimate([1000, 100, 10], 3, "k")
    assert not ok and est == C.estimate([1000, 100, 10], 3, "k")[0]          # stable
    assert all(abs(e - t) <= t * 0.7 + 1 for e, t in zip(est, [1000, 100, 10]))


def test_repair_cost_rewards_output_and_charges_defence():
    plain = main.repair_cost_of(4, 100, 100, 0, 0, 0, 0, 1.0)
    best = main.repair_cost_of(4, 100, 100, 100, 100, 100, 100, 10.0)
    half = main.repair_cost_of(4, 100, 50, 0, 0, 0, 0, 1.0)
    away = main.repair_cost_of(4, 100, 100, 100, 100, 100, 100, 1.0)
    guarded = main.repair_cost_of(4, 100, 100, 0, 0, 0, 0, 1.0, 0, 0, 100)   # 100 elite = 10 000 pts
    clay = main.MINE_TYPES[4]["cost"] * main.REPAIR_BASE_SHARE         # 5 % of the clay pit's base cost
    assert plain == round(clay) and best == max(main.REPAIR_MIN, round(clay / 60))
    big = main.repair_cost_of(82, 100, 100, 0, 0, 0, 0, 1.0)                 # diamond mine 50 000 → 2 500
    d = round(main.MINE_TYPES[82]["cost"] * main.REPAIR_BASE_SHARE)
    assert big == d and main.repair_cost_of(82, 100, 50, 0, 0, 0, 0, 1.0) == 2 * d
    assert main.repair_cost_of(82, 100, 100, 100, 100, 100, 100, 1.0) == round(d / 6)     # +500 % tech
    assert main.repair_cost_of(82, 100, 100, 0, 0, 0, 0, 10.0) == round(d / 10)           # HQ 10 area: 10× cheaper
    assert half >= plain and away >= best and guarded >= plain
    assert main.repair_cost_of(82, 100, 100, 0, 0, 0, 0, 1.0, 0, 0, 100) == 2 * d   # +100 %


def test_station_defence_only_on_own_mine():
    me, sid, _ = new_player("cb7")
    other, _, _ = new_player("cb8")
    mine, theirs = _mine(me, lat=LAT + 0.03), _mine(other, lat=LAT + 0.03)
    give(me, 97, 20)
    assert call("/api/v1/combat/station", sid, mineID=theirs, staff=5)["code"] == "not_yours"
    r = call("/api/v1/combat/station", sid, mineID=mine, staff=5)
    assert r["defence"] == [200, 10, 1] and qty(me, 97) == 15


def test_external_repair_rules_and_reward():
    helper, h_sid, _ = new_player("cb9")
    owner, _, _ = new_player("cb10")
    set_building(helper, C.SERVICE_CENTER, 3)
    healthy = _mine(owner, lat=LAT + 0.04)
    assert call("/api/v1/service/repair", h_sid, mineID=healthy, lat=LAT + 0.04, lng=LNG)["code"] == "not_needed"
    mid = _mine(owner, lat=LAT + 0.04, condition=60)
    assert call("/api/v1/service/repair", h_sid, mineID=mid, lat=LAT + 0.042, lng=LNG)["code"] == "out_of_range"
    own = _mine(helper, lat=LAT + 0.04, condition=60)
    assert call("/api/v1/service/repair", h_sid, mineID=own, lat=LAT + 0.04, lng=LNG)["code"] == "own_mine"
    r = call("/api/v1/service/repair", h_sid, mineID=mid, lat=LAT + 0.04, lng=LNG)
    assert r["err"] == 0 and r["rewardQty"] > 0 and _cond(mid) == 100
    assert qty(helper, r["rewardItem"]) == r["rewardQty"]
    with main.get_db() as conn:
        conn.execute("UPDATE mines SET condition=50 WHERE mine_id=?", (mid,))
        conn.commit()
    assert call("/api/v1/service/repair", h_sid, mineID=mid, lat=LAT + 0.04, lng=LNG)["code"] == "cooldown"


def test_external_repair_inactive_owner():
    helper, h_sid, _ = new_player("cb11")
    owner, _, _ = new_player("cb12")
    mid = _mine(owner, lat=LAT + 0.05, condition=50)
    with main.get_db() as conn:
        conn.execute("DELETE FROM player_activity WHERE hid=?", (owner,))
        conn.execute("INSERT INTO player_activity(hid, day) VALUES(?, '2020-01-01')", (owner,))
        conn.commit()
    assert call("/api/v1/service/repair", h_sid, mineID=mid, lat=LAT + 0.05, lng=LNG)["code"] == "inactive_owner"



def test_training_costs_resources_and_gets_cheaper_with_level():
    import economy
    from systems import market
    for u in C.TRAIN_RECIPES:
        prices = economy.system_prices()
        market_price = prices[u] * market.SYSTEM_BUY_MARKUP
        value = lambda lvl: sum(q * prices[i] for i, q in C.train_cost_per_unit(u, lvl).items())
        assert abs(value(1) - 1.5 * market_price) < 1e-6
        assert abs(value(10) - 0.9 * market_price) < 1e-6        # a bit cheaper than the market at level 10

    hid, sid, _ = new_player("train", wh_level=10)
    assert call("/api/v1/combat/train", sid, unit=103, qty=5)["err"] != 0       # no Mafia HQ
    set_building(hid, C.MAFIA_HQ, 10)
    cost = C.train_cost(103, 10, 5)
    for i, q in cost.items():
        give(hid, i, q)
    r = call("/api/v1/combat/train", sid, unit=103, qty=5)
    assert r["err"] == 0 and qty(hid, 103) == 5
    assert all(qty(hid, i) == 0 for i in cost)
    assert call("/api/v1/combat/train", sid, unit=97, qty=1)["err"] != 0        # defence needs an Army Camp
    set_building(hid, C.TRAINING_CAMP, 1)
    info = call("/api/v1/combat/training", sid, building=C.TRAINING_CAMP)
    assert info["level"] == 1 and [u["unit"] for u in info["units"]] == list(C.DEFENCE_UNITS)
