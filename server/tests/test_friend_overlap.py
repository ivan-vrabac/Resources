"""Owner 2026-10-24: friends may build over a friend's new mine for FRIEND_OVERLAP_S seconds;
never over their own mines, never over strangers' mines, never after the window."""
import datetime
import time
import uuid

import main
from helpers import call, client, new_player


def _spot(start_lat=45.80, start_lng=15.95):
    """A spot with clay (Clay Pit, item 4) on it."""
    for i in range(400):
        lat, lng = start_lat + i * 0.001, start_lng
        if main.resource_quality_at(lat, lng, 4) >= 1:
            return lat, lng
    raise AssertionError("no clay found")


def _build(sid, hid, lat, lng):
    tok = str(uuid.uuid4())
    main._scan_tokens[tok] = {"hid": hid, "lat": lat, "lng": lng, "player_lat": lat, "player_lng": lng,
                              "item_ids": [4], "expires": time.time() + 600}
    r = client.post("/flut23/mineNew.php", data={"sid": sid, "lat": lat, "lng": lng, "itemID": 4,
                                                 "prospect_token": tok, "cur_lat": lat, "cur_lng": lng})
    import json, zlib
    return json.loads(zlib.decompress(r.content))


def _age_mines(hid, seconds):
    with main.get_db() as conn:
        old = (datetime.datetime.utcnow() - datetime.timedelta(seconds=seconds)).isoformat()
        conn.execute("UPDATE mines SET created_at=? WHERE owner_hid=?", (old, hid))
        conn.commit()


def _friend(a_sid, b_sid):
    b_pid = call("/api/v1/social/profile", b_sid)["profile"]["pid"]
    assert call("/api/v1/social/contact", a_sid, pid=b_pid, kind="friend")["relations"] == ["friend"]


def _markers(sid, lat, lng):
    import json, zlib
    r = client.post("/flut23/mineLoadMarkers.php", data={"sid": sid, "lat1": lat - .01, "lng1": lng - .01,
                                                         "lat2": lat + .01, "lng2": lng + .01})
    return json.loads(zlib.decompress(r.content))


def test_friend_overlap_window():
    lat, lng = _spot()
    a_hid, a_sid, _ = new_player("ovla", credits=10_000_000)
    b_hid, b_sid, _ = new_player("ovlb", credits=10_000_000)
    c_hid, c_sid, _ = new_player("ovlc", credits=10_000_000)
    assert _build(a_sid, a_hid, lat, lng)["err"] == 0
    # own mine: never
    assert _build(a_sid, a_hid, lat, lng)["err"] == 6
    # stranger: never
    assert _build(c_sid, c_hid, lat, lng)["err"] == 6
    # friend (either direction) within the window: allowed, and the marker says so
    _friend(a_sid, b_sid)
    m = [x for x in _markers(b_sid, lat, lng) if x["lat"] == lat and x["lng"] == lng]
    assert m and 0 < m[0]["overlapLeft"] <= main.FRIEND_OVERLAP_S
    assert all("overlapLeft" not in x for x in _markers(c_sid, lat, lng))
    assert _build(b_sid, b_hid, lat, lng)["err"] == 0


def test_friend_overlap_expires():
    lat, lng = _spot(46.20, 16.30)
    a_hid, a_sid, _ = new_player("ovld", credits=10_000_000)
    b_hid, b_sid, _ = new_player("ovle", credits=10_000_000)
    _friend(b_sid, a_sid)
    assert _build(a_sid, a_hid, lat, lng)["err"] == 0
    _age_mines(a_hid, main.FRIEND_OVERLAP_S + 1)
    assert all("overlapLeft" not in x for x in _markers(b_sid, lat, lng))
    assert _build(b_sid, b_hid, lat, lng)["err"] == 6
