"""Phase 5: artifact detection (direction only), reveal, recovery once, archaeologist cost."""
import threading

import econ
from helpers import call, give, new_player, qty, set_building
from systems import archaeology as A

R = "/api/v1/archaeology/"


def _a_site():
    week = A.week_of(econ.utcnow())
    for cx in range(780, 900):
        s = A.site_in_cell(cx, 2290, week)
        if s:
            return s
    raise AssertionError("no site generated")


def test_sites_are_deterministic():
    week = A.week_of(econ.utcnow())
    assert A.site_in_cell(800, 2290, week) == A.site_in_cell(800, 2290, week)
    n = sum(1 for cx in range(1000) if A.site_in_cell(cx, 7, week))
    assert 250 < n < 450                                      # ≈ SITE_CHANCE


def test_detect_requires_center_and_detector_and_hides_position():
    site = _a_site()
    hid, sid, _ = new_player("ar1")
    far_lat = site["lat"] - 0.009                             # ~1 km south
    assert call(R + "detect", sid, lat=far_lat, lng=site["lng"])["code"] == "locked"
    set_building(hid, 164, 1)
    assert call(R + "detect", sid, lat=far_lat, lng=site["lng"])["code"] == "no_detector"
    give(hid, 166, 1)
    r = call(R + "detect", sid, lat=far_lat, lng=site["lng"])
    assert r["found"] and "revealed" not in r
    assert abs(r["bearing"] - 0) < 15 or abs(r["bearing"] - 360) < 15     # points north
    near = call(R + "detect", sid, lat=site["lat"] + 0.0003, lng=site["lng"])   # ~33 m
    assert near["revealed"]["id"] == site["id"]


def test_recover_once_costs_archaeologists_and_needs_range():
    site = _a_site()
    a_hid, a_sid, _ = new_player("ar2")
    b_hid, b_sid, _ = new_player("ar3")
    for h in (a_hid, b_hid):
        set_building(h, 164, 4)                               # needs 6 archaeologists
        give(h, 166, 1)
        give(h, 167, 10)
    lat_off = site["lat"] + 0.0008                            # ~89 m: revealed (L4 = 90 m) but museum 0 = 50 m
    assert call(R + "recover", a_sid, id=site["id"], lat=lat_off, lng=site["lng"])["code"] == "out_of_range"
    out = []
    ts = [threading.Thread(target=lambda s=s: out.append(call(R + "recover", s, id=site["id"],
                                                            lat=site["lat"], lng=site["lng"])))
          for s in (a_sid, b_sid)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert sum(1 for r in out if r["err"] == 0) == 1
    winner = a_hid if qty(a_hid, site["item"]) == 1 else b_hid
    loser = b_hid if winner == a_hid else a_hid
    assert qty(winner, 167) == 4 and qty(loser, 167) == 10    # loser paid nothing (rolled back)
    assert call(R + "detect", a_sid, lat=site["lat"], lng=site["lng"]).get("revealed", {}).get("id") != site["id"]


def test_forged_site_id_rejected():
    hid, sid, _ = new_player("ar4")
    set_building(hid, 164, 10)
    assert call(R + "recover", sid, id="1:1:1999W01", lat=0, lng=0)["code"] == "gone"
    assert call(R + "recover", sid, id="garbage", lat=0, lng=0)["code"] == "gone"
