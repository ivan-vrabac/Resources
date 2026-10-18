"""Lite player data, mine list/near/dots and bulk repair."""
import datetime
import json
import zlib

from fastapi.testclient import TestClient

import main

client = TestClient(main.app)


def unz(resp):
    return json.loads(zlib.decompress(resp.content))


def _player_with_mines(name, n=50):
    s = client.post("/api/v1/auth/session", data={"name": name, "password": "password1"}).json()
    hid, sid = s["hID"], s["sid"]
    now = datetime.datetime.utcnow()
    with main.get_db() as conn:
        conn.execute("UPDATE players SET credits=10000000 WHERE hID=?", (hid,))
        conn.executemany(
            "INSERT INTO mines(mine_id, owner_hid, lat, lng, item_id, quality, condition, last_coll, created_at) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            [(f"{name[:4]}{i:05d}", hid, 45.80 + i * 0.001, 15.97, 4, 50 + i % 50, 60 if i % 2 else 100,
              now.isoformat(), now.isoformat()) for i in range(n)])
        conn.execute("INSERT OR REPLACE INTO warehouse(hid,item_id,qty) VALUES(?,?,?)", (hid, 43, 3))
        conn.commit()
    return hid, sid


def test_lite_player_data_has_stats_not_mines():
    hid, sid = _player_with_mines("Lite Co")
    lite = unz(client.post("/flut23/playerGetData.php", data={"sid": sid, "lite": "1"}))[0]
    assert lite["mines"] == [] and lite["minesOmitted"] is True
    assert lite["mineStats"]["count"] == 50
    full = unz(client.post("/flut23/playerGetData.php", data={"sid": sid}))[0]
    assert len(full["mines"]) == 50 and full["minesOmitted"] is False


def test_mine_list_sorted_and_paged():
    hid, sid = _player_with_mines("List Co")
    r = unz(client.post("/flut23/mineList.php", data={"sid": sid, "sort": "quality", "asc": "1",
                                                      "limit": "10", "offset": "5"}))
    assert r["total"] == 50 and len(r["mines"]) == 10
    q = [m["qual"] for m in r["mines"]]
    assert q == sorted(q)


def test_mines_near():
    hid, sid = _player_with_mines("Near Co")
    r = unz(client.post("/flut23/minesNear.php", data={"sid": sid, "lat": "45.80", "lng": "15.97", "r": "250"}))
    assert {m["mID"] for m in r["mines"]} == {"Near00000", "Near00001", "Near00002"}


def test_mine_dots():
    hid, sid = _player_with_mines("Dots Co")
    flat = unz(client.post("/flut23/mineDots.php", data={"sid": sid, "lat1": "45.79", "lng1": "15.96",
                                                         "lat2": "45.86", "lng2": "15.98"}))
    assert len(flat) % 2 == 0 and len(flat) // 2 >= 50


def test_bulk_repair_pay_and_kit():
    hid, sid = _player_with_mines("Fix Co", n=10)
    ids = [f"Fix {i:05d}" for i in range(10)]  # mine IDs from _player_with_mines; odd ones at 60%
    r = unz(client.post("/flut23/mineBulkRepair.php", data={"sid": sid, "ids": json.dumps(ids), "mode": "kit"}))
    assert r["err"] == 0 and r["repaired"] == 3          # 5 damaged, only 3 kits
    r = unz(client.post("/flut23/mineBulkRepair.php", data={"sid": sid, "ids": json.dumps(ids), "mode": "pay"}))
    assert r["err"] == 0 and r["repaired"] == 2 and r["cost"] > 0
    with main.get_db() as conn:
        assert conn.execute("SELECT MIN(condition) FROM mines WHERE owner_hid=?", (hid,)).fetchone()[0] >= 99
