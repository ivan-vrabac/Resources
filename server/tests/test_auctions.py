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
    assert call(R + "/bid", sid, auctionID=lot["id"], amount=lot["minBid"] - 1)["code"] == "too_low"


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
    assert _points(a) == bid_pts                                  # bid points stay
    _end(lot["id"])
    data = call(R, b_sid)
    assert len(data["active"]) == 1 and data["active"][0]["itemID"] != lot["itemID"]   # next item
    assert qty(b, lot["itemID"]) == 1 and qty(b, res) == lot["minBid"] * 10 - nxt
    assert _points(b) == A.points_for(lot["itemID"], nxt) + A.win_points(lot["itemID"], nxt)
    assert A.win_points(lot["itemID"], nxt) > 10 * A.points_for(lot["itemID"], nxt)
    h = call(R + "/item", a_sid, itemID=lot["itemID"])
    assert len(h["bids"]) >= 2 and h["lastSale"]["price"] == nxt and b not in json.dumps(h)


def test_ownership_limit_counts_owned_and_leading():
    hid, sid = _bidder("au4")
    lot = _lot(sid)
    give(hid, lot["itemID"], 10)
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
        conn.execute("DELETE FROM warehouse WHERE item_id=?", (item,))
        conn.execute("UPDATE jackpot SET amount=100000000000 WHERE id=1")
        conn.commit()
    give(h1, item, 30)                                            # counts as 10 → 10 %
    give(h2, item, 3)                                             # 3 %
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
