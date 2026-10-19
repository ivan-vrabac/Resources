"""Artifact investment levels (100 / 500 / 1000) and their effects."""
import main
from helpers import call, give, new_player, qty, set_building
from systems import archaeology as A

R = "/api/v1/archaeology/"


def test_invest_levels():
    hid, sid, _ = new_player("al1")
    give(hid, 172, 1200)
    assert call(R + "invest", sid, itemID=172, qty=99)["level"] == 0
    assert call(R + "invest", sid, itemID=172, qty=1)["level"] == 1
    assert call(R + "invest", sid, itemID=172, qty=400)["level"] == 2
    assert call(R + "invest", sid, itemID=172, qty=500)["level"] == 3
    assert qty(hid, 172) == 200
    assert call(R + "invest", sid, itemID=172, qty=1000)["code"] == "insufficient_items"
    st = call(R + "status", sid)
    astro = next(c for c in st["collection"] if c["itemID"] == 172)
    assert astro["level"] == 3 and "8 h" in astro["effect"]


def test_effects():
    hid, sid, _ = new_player("al2")
    with main.get_db() as conn:
        assert main.remote_build_hours(conn, hid) == 12
        conn.execute("INSERT INTO artifact_levels(hid, item_id, invested) VALUES(?,?,?)", (hid, 172, 100))
        conn.execute("INSERT INTO artifact_levels(hid, item_id, invested) VALUES(?,?,?)", (hid, 177, 1000))
        conn.execute("INSERT INTO artifact_levels(hid, item_id, invested) VALUES(?,?,?)", (hid, 176, 500))
        conn.commit()
        assert main.remote_build_hours(conn, hid) == 11
        assert main.repair_discount(conn, hid) == 0.5
        assert A.effect(conn, hid, 176) == 20 and A.effect(conn, hid, 173) == 0
