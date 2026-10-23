"""Scans are verified on the server: local scans within 100 m of the player, drone scans within
the Drone Research range (max 10 km)."""
import json
import zlib

import main
from helpers import client, give, new_player, set_building

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
