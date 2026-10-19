"""Leaderboards (overall without XP, luxury points, output per resource) and the company sheet."""
import json

import econ
import main
from helpers import call, give, new_player, set_building
from systems import rankings



def lux(hid, item, n):
    with main.get_db() as conn:
        conn.execute("INSERT INTO luxury_items(hid, item_id, qty) VALUES(?,?,?) ON CONFLICT(hid, item_id) "
                     "DO UPDATE SET qty=qty+excluded.qty", (hid, item, n))
        conn.commit()


def _mine(owner, item_id=4, lat=46.5, lng=16.5, quality=100):
    with main.get_db() as conn:
        conn.execute("INSERT INTO mines(mine_id, owner_hid, lat, lng, item_id, quality, condition) VALUES(?,?,?,?,?,?,100)",
                     (main.new_id(), owner, lat, lng, item_id, quality))
        conn.commit()


def test_overall_has_no_xp_and_public_ids_only():
    a, sid, _ = new_player("rk1")
    rankings._cache.clear()
    r = call("/api/v1/rank/players", sid)
    assert r["rows"] and all("xp" not in row for row in r["rows"])
    assert a not in json.dumps(r)


def test_resource_ranking_mine_and_factory():
    a, a_sid, _ = new_player("rk2")
    b, _, _ = new_player("rk3")
    for _ in range(3):
        _mine(a, item_id=82)                                     # diamond mines → rough diamonds 81
    _mine(b, item_id=82, quality=50)
    rankings._cache.clear()
    r = call("/api/v1/rank/resource", a_sid, kind="mine", item=81)
    rows = [x for x in r["rows"] if x["isMe"] or x["name"].startswith("rk3")]
    assert rows[0]["isMe"] and rows[0]["count"] == 3 and rows[0]["perHour"] > rows[1]["perHour"]
    set_building(a, 25, 3)                                       # brick factory level 3 → bricks 24
    rankings._cache.clear()
    f = call("/api/v1/rank/resource", a_sid, kind="factory", item=24)
    me = next(x for x in f["rows"] if x["isMe"])
    assert me["perHour"] == round(80 / 2 * 3, 1)
    assert call("/api/v1/rank/resource", a_sid, kind="mine", item=24)["code"] == "bad_input"


def test_luxury_board_and_company_sheet():
    a, a_sid, a_name = new_player("rk4")
    viewer, v_sid, _ = new_player("rk5")
    with main.get_db() as conn:
        conn.execute("INSERT INTO luxury_points(hid, points) VALUES(?, 999999)", (a,))
        conn.commit()
    lux(a, 128, 2)
    _mine(a, item_id=4)
    set_building(a, 86, 3)                                       # Mafia HQ (special building)
    set_building(a, 25, 2)                                       # brick factory
    board = call("/api/v1/rank/luxury", v_sid)
    top = board["rows"][0]
    assert top["name"] == a_name and top["points"] == 999999 and top["items"][0]["itemID"] == 128
    pid = top["pid"]
    p = call("/api/v1/social/profile", v_sid, pid=pid)["profile"]
    assert p["ageDays"] == 0 and p["luxuryPoints"] == 999999
    assert any(x["itemID"] == 86 for x in p["specialBuildings"]) and any(x["itemID"] == 25 for x in p["factories"])
    assert p["minesByType"][0]["itemID"] == 4 and a not in json.dumps(p)


def test_remote_build_cooldown_helper():
    hid, _, _ = new_player("rk6")
    assert main._remote_build_wait(hid) is None
    with main.get_db() as conn:
        econ.emit(conn, "remote_build", hid, {}, public=False)
        conn.commit()
    assert "h" in main._remote_build_wait(hid)
