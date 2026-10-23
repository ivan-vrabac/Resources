"""Phase 8: one luxury auction at a time, bids in the item's resource, luxury points,
outbid refund, ownership limit, settlement, per-holder casino dividends."""
import datetime
import json
import threading
import zlib

import econ
import main
from helpers import call, client, credits, give, new_player, qty
from systems import auctions as A


def lux(hid, item, n):
    """Luxury items live in luxury_items, not the warehouse."""
    with main.get_db() as conn:
        conn.execute("INSERT INTO luxury_items(hid, item_id, qty) VALUES(?,?,?) ON CONFLICT(hid, item_id) "
                     "DO UPDATE SET qty=qty+excluded.qty", (hid, item, n))
        conn.commit()


def lux_qty(hid, item):
    with main.get_db() as conn:
        r = conn.execute("SELECT qty FROM luxury_items WHERE hid=? AND item_id=?", (hid, item)).fetchone()
        return r[0] if r else 0

R = "/api/v1/auctions"


def _hq(hid, level):
    with main.get_db() as conn:
        conn.execute("INSERT INTO hq(hid, lat, lng, level) VALUES(?,?,?,?) ON CONFLICT(hid) DO UPDATE SET level=excluded.level",
                     (hid, 45.0, 15.0, level))
        conn.execute("UPDATE players SET wh_level=60 WHERE hID=?", (hid,))
        conn.commit()


def _bidder(prefix):
    hid, sid, _ = new_player(prefix)
    _hq(hid, 10)
    return hid, sid


def _end(aid):
    with main.get_db() as conn:
        conn.execute("UPDATE auctions SET ends_at=? WHERE id=?",
                     ((econ.utcnow() - datetime.timedelta(seconds=1)).isoformat(), aid))
        conn.execute("DELETE FROM scheduler WHERE name='auctions_sweep'")
        conn.commit()


def _lot(sid):
    with main.get_db() as conn:
        conn.execute("DELETE FROM scheduler WHERE name='auctions_sweep'")
        conn.commit()
    lots = call(R, sid)["active"]
    assert len(lots) == 1                                         # one auction at a time
    return lots[0]


def _points(hid):
    with main.get_db() as conn:
        r = conn.execute("SELECT points FROM luxury_points WHERE hid=?", (hid,)).fetchone()
        return r[0] if r else 0


def test_mapping_is_exclusive_and_complete():
    assert sorted(A.BID_RESOURCE) == sorted(A.LUXURY) and len(A.LUXURY) == 31
    assert len(set(A.BID_RESOURCE.values())) == 31
    assert A.BID_RESOURCE[128] == 59 and A.BID_RESOURCE[131] == 95 and A.BID_RESOURCE[152] == 24 \
        and A.BID_RESOURCE[132] == 53


def test_hq10_required_and_min_bid():
    hid, sid, _ = new_player("au1")
    lot = _lot(sid)
    give(hid, lot["resID"], lot["minBid"] * 3)
    assert call(R + "/bid", sid, auctionID=lot["id"], amount=lot["minBid"])["code"] == "locked"
    _hq(hid, 10)
    assert call(R + "/bid", sid, auctionID=lot["id"], amount=lot["minBid"] - 1)["code"] == "bad_bid"   # only offered bids


def test_resources_reserved_refunded_points_and_settlement():
    a, a_sid = _bidder("au2")
    b, b_sid = _bidder("au3")
    lot = _lot(a_sid)
    res = lot["resID"]
    give(a, res, lot["minBid"] * 10)
    give(b, res, lot["minBid"] * 10)
    c_before = credits(a)
    r1 = call(R + "/bid", a_sid, auctionID=lot["id"], amount=lot["minBid"])
    assert r1["err"] == 0 and qty(a, res) == lot["minBid"] * 9 and credits(a) == c_before
    bid_pts = _points(a)
    assert bid_pts == A.points_for(lot["itemID"], lot["minBid"])
    nxt = r1["auction"]["minBid"]
    assert call(R + "/bid", b_sid, auctionID=lot["id"], amount=nxt)["err"] == 0
    assert qty(a, res) == lot["minBid"] * 10                      # resources back
    assert _points(a) == 0                                        # outbid: bid points taken back
    _end(lot["id"])
    data = call(R, b_sid)
    assert len(data["active"]) == 1 and data["active"][0]["itemID"] != lot["itemID"]   # next item
    assert lux_qty(b, lot["itemID"]) == 1 and qty(b, lot["itemID"]) == 0 and qty(b, res) == lot["minBid"] * 10 - nxt
    assert _points(b) == A.points_for(lot["itemID"], nxt) + A.win_points(lot["itemID"], nxt)
    assert A.win_points(lot["itemID"], nxt) > 10 * A.points_for(lot["itemID"], nxt)
    h = call(R + "/item", a_sid, itemID=lot["itemID"])
    assert "bids" not in h and h["lastSale"]["price"] == nxt and b not in json.dumps(h)     # no bid history
    assert h["sales"][-1]["price"] == nxt


def test_ownership_limit_counts_owned_and_leading():
    hid, sid = _bidder("au4")
    lot = _lot(sid)
    lux(hid, lot["itemID"], 10)
    give(hid, lot["resID"], lot["minBid"])
    assert call(R + "/bid", sid, auctionID=lot["id"], amount=lot["minBid"])["code"] == "limit"


def test_concurrent_bids_one_wins_other_untouched():
    a, a_sid = _bidder("au5")
    b, b_sid = _bidder("au6")
    lot = _lot(a_sid)
    for x in (a, b):
        give(x, lot["resID"], lot["minBid"] * 5)
    out = []
    amount = lot["minBid"] * 2
    ts = [threading.Thread(target=lambda s=s: out.append(call(R + "/bid", s, auctionID=lot["id"], amount=amount)))
          for s in (a_sid, b_sid)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert sum(1 for r in out if r["err"] == 0) == 1
    assert qty(a, lot["resID"]) + qty(b, lot["resID"]) == lot["minBid"] * 10 - amount


def test_dividend_per_holder_new_money_jackpot_unchanged():
    h1, _, _ = new_player("au7")
    h2, _, _ = new_player("au8")
    spinner, _, _ = new_player("au9")
    item = A.symbol_item(5)
    with main.get_db() as conn:
        conn.execute("DELETE FROM luxury_items WHERE item_id=?", (item,))
        conn.execute("UPDATE jackpot SET amount=100000000000 WHERE id=1")
        conn.commit()
    lux(h1, item, 30)                                            # counts as 10 → 10 %
    lux(h2, item, 3)                                             # 3 %
    c1, c2 = credits(h1), credits(h2)
    with main.get_db() as conn:
        with econ.tx(conn):
            d = A.pay_dividend(conn, 5, spinner)
        jackpot = conn.execute("SELECT amount FROM jackpot WHERE id=1").fetchone()[0]
    assert credits(h1) - c1 == 10_000_000_000 and credits(h2) - c2 == 3_000_000_000
    assert d["paid"] == 13_000_000_000 and jackpot == 100_000_000_000
    assert A.symbol_item(31) is None


def test_casino_roll_still_works_atomically():
    hid, sid, _ = new_player("au10", credits=10_000_000)
    with main.get_db() as conn:
        conn.execute("INSERT INTO factories(factory_id, hid, item_id, level) VALUES(?,?,61,1)", (main.new_id(), hid))
        conn.commit()
    r = json.loads(zlib.decompress(client.post("/flut23/casinoNewRoll.php",
                                               data={"sid": sid, "bet": "1000000", "count": "5"}).content))
    assert r["err"] == 0 and "dividends" in r
    assert credits(hid) == 10_000_000 - 5_000_000 + r["total_win"] + sum(d["paid"] for d in r["dividends"]) * 0
    r = json.loads(zlib.decompress(client.post("/flut23/casinoNewRoll.php",
                                               data={"sid": sid, "bet": "1000000", "count": "500"}).content))
    assert r["err"] == 5


def test_bid_in_last_30_seconds_sets_the_clock_to_60():
    import datetime
    a, a_sid = _bidder("au9")
    lot = _lot(a_sid)
    give(a, lot["resID"], lot["minBid"] * 3)
    soon = (datetime.datetime.utcnow() + datetime.timedelta(seconds=20)).isoformat()
    with main.get_db() as conn:
        conn.execute("UPDATE auctions SET ends_at=? WHERE id=?", (soon, lot["id"]))
        conn.commit()
    r = call(R + "/bid", a_sid, auctionID=lot["id"], amount=lot["minBid"])
    left = (datetime.datetime.fromisoformat(r["auction"]["endsAt"]) - datetime.datetime.utcnow()).total_seconds()
    assert 55 <= left <= 61


def test_bids_use_the_offered_steps_and_a_new_lot_follows_every_end():
    a, a_sid = _bidder("au10")
    lot = _lot(a_sid)
    give(a, lot["resID"], lot["minBid"] * 10)
    steps = lot["bidSteps"]
    assert [x["pct"] for x in steps] == [0, 10, 25, 50, 100] and steps[0]["amount"] == lot["minBid"]
    assert call(R + "/bid", a_sid, auctionID=lot["id"], step=2, seenMin=lot["minBid"] + 1)["code"] == "price_changed"
    r = call(R + "/bid", a_sid, auctionID=lot["id"], step=2, seenMin=lot["minBid"])
    assert r["err"] == 0 and r["auction"]["topBid"] == steps[2]["amount"]
    for _ in range(3):                              # ends with or without bids: there is always a next lot
        cur = call(R, a_sid)["active"][0]
        _end(cur["id"])
        nxt = call(R, a_sid)["active"]
        assert len(nxt) == 1 and nxt[0]["id"] != cur["id"]


def test_simultaneous_bids_are_atomic():
    """Many players clicking "Place bid" at the same moment: every accepted bid is a valid raise,
    only the final leader's resources stay reserved, nothing is created or lost."""
    import threading
    bidders = [_bidder(f"aux{i}") for i in range(8)]
    lot = _lot(bidders[0][1])
    res = lot["resID"]
    stock = lot["minBid"] * 50
    for hid, _ in bidders:
        give(hid, res, stock)
    out = []
    ts = [threading.Thread(target=lambda sid=sid: out.append(call(R + "/bid", sid, auctionID=lot["id"])))
          for _, sid in bidders]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    ok = [r for r in out if r["err"] == 0]
    assert ok
    final = call(R, bidders[0][1])["active"][0]
    leader = [hid for hid, _ in bidders if qty(hid, res) < stock]
    assert len(leader) == 1                                              # only one bid is held
    assert stock - qty(leader[0], res) == final["topBid"]
    assert sum(qty(hid, res) for hid, _ in bidders) == 8 * stock - final["topBid"]

