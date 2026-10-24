"""Phase 4: Cargo Rain drop/collect, museum visibility, stacks with trucks/drones, races, idempotency."""
import random
import threading
import uuid

import pytest

import econ
import main
from helpers import call, give, new_player, qty, set_building
from systems import cargo

C = "/api/v1/cargo/"
LAT, LNG = 45.8150, 15.9819


def _grant(hid, n):
    with main.get_db() as conn:
        cargo.grant(conn, hid, n, "test")
        conn.commit()


def _crates(dropper_hid):
    with main.get_db() as conn:
        return [dict(r) for r in conn.execute(
            "SELECT * FROM cargo_crates WHERE dropper_hid=? AND collected_by IS NULL ORDER BY created_at", (dropper_hid,))]


def _place(hid, item=41, q=5.0, museum=0, stacked=0, lat=LAT, lng=LNG):
    cid = uuid.uuid4().hex
    with main.get_db() as conn:
        conn.execute("INSERT INTO cargo_crates(id, dropper_hid, lat, lng, item_id, qty, museum_level, stacked, "
                     "created_at, expires_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                     (cid, hid, lat, lng, item, q, museum, stacked, econ.utcnow_iso(), "2999-01-01"))
        conn.commit()
    return cid


def test_roll_follows_sfo_table():
    rng = random.Random(1)
    seen = {}
    for _ in range(20000):
        item, q, mus = cargo.roll(rng)
        assert item in cargo.LOOT and mus == cargo.LOOT[item][2]
        lo, hi = cargo.QTY[item]
        assert lo <= q <= hi
        seen[item] = seen.get(item, 0) + 1
    assert seen[41] > seen[56] > seen[70] > seen.get(120, 0)   # fossils most common, wreckage rare


def test_drop_spends_stock_and_scatters_within_range():
    hid, sid, _ = new_player("cd")
    _grant(hid, 120)
    r = call(C + "drop", sid, count=100, lat=LAT, lng=LNG)
    assert r["dropped"] == 100 and r["left"] == 20
    crates = _crates(hid)
    assert len(crates) == 100
    assert all(econ.dist_m(LAT, LNG, c["lat"], c["lng"]) <= cargo.DROP_SCATTER_M + 0.5 for c in crates)
    assert call(C + "drop", sid, count=21, lat=LAT, lng=LNG)["code"] == "no_cargo"
    assert call(C + "drop", sid, count=101, lat=LAT, lng=LNG)["code"] == "bad_input"
    rid = uuid.uuid4().hex
    a = call(C + "drop", sid, count=5, lat=LAT, lng=LNG, rid=rid)
    b = call(C + "drop", sid, count=5, lat=LAT, lng=LNG, rid=rid)       # retry: no second drop
    assert a == b and call(C + "stock", sid)["crates"] == 15


def test_collect_range_museum_visibility_and_bonus():
    a_hid, a_sid, _ = new_player("ca", wh_level=3)
    b_hid, b_sid, _ = new_player("cb", wh_level=3)
    hidden = _place(a_hid, item=120, q=2, museum=7)
    far = _place(a_hid, item=41, q=10_000, lat=LAT + 0.001)          # ~111 m away
    near = _place(a_hid, item=41, q=10_000)
    seen = {c["id"] for c in call(C + "nearby", b_sid, lat1=LAT - .01, lng1=LNG - .01,
                                  lat2=LAT + .01, lng2=LNG + .01)["crates"]}
    assert near in seen and far in seen and hidden not in seen
    assert call(C + "collect", b_sid, id=hidden, lat=LAT, lng=LNG)["code"] == "not_visible"
    assert call(C + "collect", b_sid, id=far, lat=LAT, lng=LNG)["code"] == "out_of_range"   # 50 m at museum 0
    set_building(b_hid, 65, 5)                                              # 125 m, 1/32 of the Museum-10 amount
    r = call(C + "collect", b_sid, id=far, lat=LAT, lng=LNG)
    assert r["qty"] == round(10_000 * cargo.museum_factor(5)) == 316 and qty(b_hid, 41) == 316
    assert call(C + "collect", b_sid, id=far, lat=LAT, lng=LNG)["code"] == "gone"           # once per player


def test_shared_crate_each_player_once_then_gone_after_15_min():
    d_hid, _, _ = new_player("cr")
    cid = _place(d_hid, item=41, q=10_000)                                  # 10 at Museum 0
    players = [new_player(f"cp{i}", wh_level=3) for i in range(6)]
    out = []
    ts = [threading.Thread(target=lambda s=p[1]: out.append(call(C + "collect", s, id=cid, lat=LAT, lng=LNG)))
          for p in players]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert sum(1 for r in out if r["err"] == 0) == 6                       # shared: everyone gets it
    assert all(qty(p[0], 41) == 10 for p in players)
    again = [call(C + "collect", p[1], id=cid, lat=LAT, lng=LNG) for p in players[:2]]
    assert all(r["code"] == "gone" for r in again)                          # but only once each
    late, late_sid, _ = new_player("cl", wh_level=3)
    with main.get_db() as conn:                                             # first pick-up 16 min ago
        conn.execute("UPDATE cargo_crates SET collected_at='2000-01-01T00:00:00' WHERE id=?", (cid,))
        conn.commit()
    assert call(C + "collect", late_sid, id=cid, lat=LAT, lng=LNG)["code"] == "gone"


def test_no_special_items_in_cargo():
    for banned in (42, 44, 45, 46, 48, 158, 159, 160, 161):
        assert banned not in cargo.LOOT


def test_truck_collects_everything_nearby():
    hid, sid, _ = new_player("ct", wh_level=10)
    d_hid, _, _ = new_player("ctd")
    lat0, lng0 = LAT + 1.0, LNG + 1.0                                             # away from other tests' crates
    for i in range(12):                                                            # 12 crates within ~130 m
        _place(d_hid, item=41, q=3000, lat=lat0 + i * 0.0001, lng=lng0)         # 3 each at Museum 0
    assert call(C + "truck", sid, lat=lat0, lng=lng0, preview=1)["code"] == "locked"
    set_building(hid, 123, 5)                                                      # range 150 m
    p = call(C + "truck", sid, lat=lat0, lng=lng0, preview=1)
    assert p["crates"] == 12 and p["trucksNeeded"] == 1 and p["trucks"] == 0      # one truck carries 100 crates
    assert call(C + "truck", sid, lat=lat0, lng=lng0)["code"] == "no_vehicle"
    give(hid, 124, 1)
    r = call(C + "truck", sid, lat=lat0, lng=lng0)
    assert r["collected"] == 12 and r["left"] == 0 and r["items"] == [{"itemID": 41, "qty": 36}]
    assert qty(hid, 124) == 1                                                      # trucks are not used up


def test_stacked_cargo_split_and_one_vehicle_per_100_crates():
    hid, sid, _ = new_player("cs", wh_level=60)
    _grant(hid, 1000)
    assert call(C + "drop", sid, stacked=1, count=300, lat=LAT, lng=LNG)["code"] == "locked"
    set_building(hid, 123, 5)
    assert call(C + "drop", sid, stacked=1, count=250, lat=LAT, lng=LNG)["code"] == "bad_input"   # steps of 100
    r = call(C + "drop", sid, stacked=1, count=300, lat=LAT, lng=LNG)
    assert 1 <= r["dropped"] <= 3 and sum(r["stacks"]) == 300 and all(x % 100 == 0 for x in r["stacks"])
    assert call(C + "stock", sid)["crates"] == 700
    stacks = sorted(_crates(hid), key=lambda c: c["crates"])
    big = stacks[-1]
    assert big["museum_level"] == 0 and big["mix"]                       # visible to everyone, a mix
    seen = {c["id"] for c in call(C + "nearby", sid, lat1=LAT - .01, lng1=LNG - .01,
                                  lat2=LAT + .01, lng2=LNG + .01)["crates"]}
    assert big["id"] in seen                                             # Museum 0 still sees stacks
    n = big["crates"]
    assert call(C + "collect", sid, id=big["id"], lat=LAT, lng=LNG)["code"] == "needs_vehicle"
    need = cargo.vehicles_for(n)                                          # one truck per 100 crates
    give(hid, 124, need - 1)
    assert call(C + "collect", sid, id=big["id"], lat=LAT, lng=LNG, method="truck")["code"] == "no_vehicle"
    give(hid, 124, 1)
    r = call(C + "collect", sid, id=big["id"], lat=LAT, lng=LNG, method="truck")
    assert r["err"] == 0 and qty(hid, 124) == need and r["items"]             # trucks are not used up
    allowed = {i for i, v in cargo.BOX_LOOT.items() if v[2] == 0}           # Museum 0: only level-0 objects (boxes too)
    assert {x["itemID"] for x in r["items"]} <= allowed


def test_drone_collects_stack_drones_are_kept():
    hid, sid, _ = new_player("cdr", wh_level=60)
    _grant(hid, 100)
    set_building(hid, 123, 5)
    set_building(hid, 119, 5)
    call(C + "drop", sid, stacked=1, count=100, lat=LAT + 0.3, lng=LNG)
    st = _crates(hid)[0]
    far_lat = st["lat"] + 0.02                                              # ~2 km away
    assert call(C + "collect", sid, id=st["id"], lat=far_lat, lng=LNG, method="drone")["code"] == "insufficient_items"
    give(hid, 117, 1)                                                       # 100 crates: one drone
    assert call(C + "collect", sid, id=st["id"], lat=far_lat, lng=LNG, method="drone")["err"] == 0
    assert qty(hid, 117) == 1                                               # the drone is kept


def test_boxes_can_hold_specials_containers_cannot():
    import random as _r
    rng = _r.Random(3)
    box_items = {cargo.roll(rng, table=cargo.BOX_LOOT)[0] for _ in range(200000)}
    assert box_items & {42, 44, 45, 46, 48}                                  # boxes: specials possible
    cont_items = {cargo.roll(rng)[0] for _ in range(20000)}
    assert not cont_items & {42, 44, 45, 46, 48, 158, 159, 160, 161}


def test_cargo_collected_counts_for_quests():
    hid, sid, _ = new_player("cq", wh_level=3)
    for _ in range(3):
        call(C + "collect", sid, id=_place(hid), lat=LAT, lng=LNG)
    with main.get_db() as conn:
        assert econ.count_events(conn, hid, "cargo_collected", "2000-01-01") == 3


def test_recycling_found_objects():
    hid, sid, _ = new_player("rc", wh_level=10)
    give(hid, 41, 100)
    assert call(C + "recycle", sid, itemID=41, qty=10)["code"] == "locked"          # needs a Recycling Plant
    set_building(hid, 58, 10)                                                       # 100 % yield
    r = call(C + "recycle", sid, itemID=41, qty=100)
    outs = {o["itemID"]: o["qty"] for o in r["outputs"]}
    assert qty(hid, 41) == 0 and outs == {2: 200, 10: 2, 20: 120, 3: 120, 53: 2}  # fossils → 5 resources
    assert all(float(v).is_integer() for v in outs.values())
    info = call(C + "recycling", sid)
    assert {x["itemID"] for x in info["recipes"]} >= {41, 74, 115, 120}


def test_stack_holds_what_the_same_loose_crates_would():
    """Owner 2026-10-23: 100 000 stacked crates = 100 000 loose crates (incl. the box specials)."""
    import random
    from systems import cargo
    n = 1_000_000
    mix = cargo.stack_mix(random.Random(7), n)
    exp_all = {}
    for table, share in ((cargo.BOX_LOOT, cargo.BOX_SHARE), (cargo.LOOT, 1 - cargo.BOX_SHARE)):
        tot = sum(v[1] for v in table.values())
        for i, (_, w, _) in table.items():
            lo, hi = cargo.QTY[i]
            exp_all[i] = exp_all.get(i, 0) + n * share * w / tot * (lo + hi) / 2
    for i, exp in exp_all.items():
        if exp >= 1000:
            assert abs(mix.get(i, 0) - exp) / exp < 0.1, (i, mix.get(i), exp)
    assert any(i in mix for i in cargo.BOX_EXTRA)        # box specials can be in a stack


def test_every_collector_gets_the_same_contents():
    """Owner 2026-10-23: a crate holds the same for everyone (rolled once at the drop)."""
    dropper, d_sid, _ = new_player("same0", credits=0, wh_level=20)
    with main.get_db() as conn:
        with econ.tx(conn):
            cargo.grant(conn, dropper, 20, "test")
    call(C + "drop", d_sid, count=20, lat=LAT, lng=LNG)
    got = []
    for i in range(2):
        hid, sid, _ = new_player(f"same{i + 1}", credits=0, wh_level=20)
        set_building(hid, 65, 10)                      # same Museum level → same visible crates and bonus
        crates = call(C + "nearby", sid, lat1=LAT - 0.01, lng1=LNG - 0.01, lat2=LAT + 0.01, lng2=LNG + 0.01)["crates"]
        out = {}
        for c in crates:
            r = call(C + "collect", sid, id=c["id"], lat=c["lat"], lng=c["lng"])
            if r["err"] == 0:
                out[c["id"]] = (r["itemID"], r["qty"])
        got.append(out)
    assert got[0] and got[0] == got[1]

