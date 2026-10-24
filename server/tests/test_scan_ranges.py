"""Scans are verified on the server: local scans within 100 m of the player, drone scans within
the Drone Research range (max 10 km)."""
import json
import zlib

import main
from helpers import client, credits, give, new_player, qty, set_building

LAT, LNG = 45.80, 15.97


def scan(sid, lat, lng, plat, plng, drone=False):
    r = client.post("/flut23/scannerPayscan.php", data={
        "sid": sid, "lat": lat, "lng": lng, "player_lat": plat, "player_lng": plng, "drone": "1" if drone else "0"})
    return json.loads(zlib.decompress(r.content))


def test_local_scan_must_be_near_the_player():
    hid, sid, _ = new_player("scl", credits=10_000_000)
    assert scan(sid, LAT, LNG, LAT, LNG)["err"] == 0
    far = scan(sid, LAT + 0.002, LNG, LAT, LNG)                       # ~222 m
    assert far["err"] != 0 and "drone" in far["msg"].lower()


def test_drone_scan_within_drone_range_only():
    hid, sid, _ = new_player("scd", credits=10_000_000)
    set_building(hid, 119, 1)                                         # 500 m
    give(hid, 117, 5)
    assert scan(sid, LAT + 0.004, LNG, LAT, LNG, drone=True)["err"] == 0      # ~445 m
    r = scan(sid, LAT + 0.02, LNG, LAT, LNG, drone=True)                       # ~2.2 km
    assert r["err"] != 0 and "km" in r["msg"]
    assert max(main.DRONE_SCAN_RANGES) == 10_000


def test_drone_scan_uses_one_drone_and_no_credits():
    hid, sid, _ = new_player("sdc", credits=10_000_000, level=30)
    set_building(hid, 119, 3)
    give(hid, 117, 2)
    before = credits(hid)
    r = scan(sid, LAT + 0.004, LNG, LAT, LNG, drone=True)
    assert r["err"] == 0 and r["cost"] == 0 and credits(hid) == before and qty(hid, 117) == 1
    assert scan(sid, LAT + 0.004, LNG, LAT, LNG, drone=True)["err"] == 0 and qty(hid, 117) == 0
    r = scan(sid, LAT + 0.004, LNG, LAT, LNG, drone=True)                      # no drones left
    assert r["err"] != 0 and credits(hid) == before


def test_remote_build_cooldown_follows_astrolabium():
    import datetime
    hid, _, _ = new_player("sdr")
    with main.get_db() as conn:
        assert main.remote_build_next(conn, hid) is None
        conn.execute("INSERT INTO game_events(ts, type, hid, data) VALUES(?,?,?,?)",
                     (datetime.datetime.utcnow().isoformat(), "remote_build", hid, "{}"))
        nxt = datetime.datetime.fromisoformat(main.remote_build_next(conn, hid))
        assert abs((nxt - datetime.datetime.utcnow()).total_seconds() / 3600 - 12) < 0.01        # 12 h
        conn.execute("INSERT INTO artifact_levels(hid, item_id, invested) VALUES(?,?,?)", (hid, 172, 1000))
        nxt = datetime.datetime.fromisoformat(main.remote_build_next(conn, hid))
        assert abs((nxt - datetime.datetime.utcnow()).total_seconds() / 3600 - 8) < 0.01         # Astrolabium 3: 8 h