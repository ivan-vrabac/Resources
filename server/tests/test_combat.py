"""Phase 6: attacks (dice battle, range, cooldown, loot from defender, deserters) and external repair."""
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
    assert C.attack_range(10) == 400 and C.helper_range(10) == 200


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


def test_strong_attack_succeeds_loots_defender_and_cooldown():
    att, a_sid, _ = new_player("cb3")
    dfd, _, _ = new_player("cb4")
    set_building(att, C.MAFIA_HQ, 10)
    mid = _mine(dfd, lat=LAT + 0.01)
    res = main.MINE_TYPES[4]["res"]
    give(dfd, res, 1_000_000)
    give(att, 104, 500)
    r = call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT + 0.01, lng=LNG, army=500, rid="x1")
    assert r["err"] == 0 and r["success"]
    assert r["loot"] > 0
    assert qty(dfd, res) == 1_000_000 - r["loot"]                     # loot moved, not created
    assert qty(att, res) == r["loot"]
    assert qty(att, 104) == sum(r["attackersLeft"])
    # idempotent replay returns the same result, no second battle
    again = call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT + 0.01, lng=LNG, army=500, rid="x1")
    assert again["attackID"] == r["attackID"]
    if not r["destroyed"]:
        assert _cond(mid) == r["condition"] < 100
        give(att, 104, 10)
        assert call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT + 0.01, lng=LNG, army=10)["code"] == "cooldown"


def test_weak_attack_fails_and_deserters_join_defence():
    att, a_sid, _ = new_player("cb5")
    dfd, _, _ = new_player("cb6")
    set_building(att, C.MAFIA_HQ, 1)
    mid = _mine(dfd, lat=LAT + 0.02)
    give(att, 102, 100)                                               # 100 dogs vs 200 dogs + 5 staff + 1 elite
    r = call("/api/v1/combat/attack", a_sid, mineID=mid, lat=LAT + 0.02, lng=LNG, dogs=100)
    assert r["err"] == 0 and not r["success"]
    assert _cond(mid) == 100
    info = call("/api/v1/combat/info", a_sid, mineID=mid)
    assert info["target"]["stationed"][0] == r["deserters"][0] == int((100 - r["attackersLeft"][0]) * 0.1)


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

