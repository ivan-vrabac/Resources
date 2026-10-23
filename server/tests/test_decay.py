"""Mine condition decays with real time on the server (not only when the owner collects)."""
import datetime
import json
import zlib

import main
from helpers import client, new_player


def test_condition_decays_with_real_time_and_markers_show_it():
    owner, _, _ = new_player("dec1")
    viewer, v_sid, _ = new_player("dec2")
    mid = main.new_id()
    ten_days = (datetime.datetime.utcnow() - datetime.timedelta(days=5)).isoformat()
    with main.get_db() as conn:
        conn.execute("INSERT INTO mines(mine_id, owner_hid, lat, lng, item_id, quality, condition, last_coll) "
                     "VALUES(?,?,?,?,4,100,100,?)", (mid, owner, 44.1, 15.1, ten_days))
        conn.commit()
    r = client.post("/flut23/mineLoadMarkers.php", data={"sid": v_sid, "lat1": 44, "lng1": 15, "lat2": 44.2, "lng2": 15.2})
    m = next(x for x in json.loads(zlib.decompress(r.content)) if x["mID"] == mid)
    assert 79 < m["cond"] < 81                                   # 5 days × 4 % = 20 points
    with main.get_db() as conn:
        mine = conn.execute("SELECT * FROM mines WHERE mine_id=?", (mid,)).fetchone()
        main.collect_mine(conn, mine)
        conn.commit()
        cond = conn.execute("SELECT condition FROM mines WHERE mine_id=?", (mid,)).fetchone()[0]
    assert 79 < cond < 81                                        # not just 4 points (the 24 h production cap)
