"""Owner 2026-10-24: anyone may build on exactly the same hex as other players' mines within
SHARED_HEX_S seconds of the first mine there; never next to your own mine on that hex, never a
partial overlap, never after the window."""
import datetime
import json
import time
import uuid
import zlib

import main
from helpers import client, new_player


def _spot(start_lat, start_lng):
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
    return json.loads(zlib.decompress(r.content))


def _age_mines(lat, lng, seconds):
    with main.get_db() as conn:
        old = (datetime.datetime.utcnow() - datetime.timedelta(seconds=seconds)).isoformat()
        conn.execute("UPDATE mines SET created_at=? WHERE lat=? AND lng=?", (old, lat, lng))
        conn.commit()


def _markers(sid, lat, lng):
    r = client.post("/flut23/mineLoadMarkers.php", data={"sid": sid, "lat1": lat - .01, "lng1": lng - .01,
                                                         "lat2": lat + .01, "lng2": lng + .01})
    return [m for m in json.loads(zlib.decompress(r.content)) if m["lat"] == lat and m["lng"] == lng]


def test_six_players_share_a_hex():
    lat, lng = _spot(45.80, 15.95)
    players = [new_player(f"shx{i}", credits=10_000_000) for i in range(7)]
    (h0, s0, _), others = players[0], players[1:]
    assert _build(s0, h0, lat, lng)["err"] == 0
    assert _build(s0, h0, lat, lng)["err"] == 6                       # own mine on the hex: never
    for h, s, _ in others[:5]:                                         # 5 more players, strangers
        assert all(0 < m["overlapLeft"] <= main.SHARED_HEX_S for m in _markers(s, lat, lng))
        assert _build(s, h, lat, lng)["err"] == 0
    assert all("overlapLeft" not in m for m in _markers(s0, lat, lng))   # owners see no timer
    assert all(m["stack"] == 6 for m in _markers(s0, lat, lng))
    # the window counts from the first mine on the hex
    _age_mines(lat, lng, main.SHARED_HEX_S + 1)
    h6, s6, _ = others[5]
    assert all("overlapLeft" not in m for m in _markers(s6, lat, lng))
    assert _build(s6, h6, lat, lng)["err"] == 6


def test_partial_overlap_is_refused():
    lat, lng = _spot(46.20, 16.30)
    a_hid, a_sid, _ = new_player("shpa", credits=10_000_000)
    b_hid, b_sid, _ = new_player("shpb", credits=10_000_000)
    assert _build(a_sid, a_hid, lat, lng)["err"] == 0
    assert _build(b_sid, b_hid, lat + 10 / 111320.0, lng)["err"] == 6   # 10 m off: not the same hex
