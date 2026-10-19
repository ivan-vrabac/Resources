"""Phase 8: luxury auctions (HQ 10, escrow, outbid refund, limit 10, settlement) and casino dividends."""
import datetime
import threading

import econ
import main
from helpers import call, credits, give, new_player, qty
from systems import auctions as A

R = "/api/v1/auctions"


def _hq(hid, level):
    with main.get_db() as conn:
        conn.execute("INSERT INTO hq(hid, lat, lng, level) VALUES(?,?,?,?) ON CONFLICT(hid) DO UPDATE SET level=excluded.level",
                     (hid, 45.0, 15.0, level))
        conn.commit()


def _bidder(prefix, cr=10_000_000_000):
    hid, sid, _ = new_player(prefix, credits=cr)
    _hq(hid, 10)
    return hid, sid


def _end(aid):
    with main.get_db() as conn:
        conn.execute("UPDATE auctions SET ends_at=? WHERE id=?",
                     ((econ.utcnow() - datetime.timedelta(seconds=1)).isoformat(), aid))
        conn.execute("DELETE FROM scheduler WHERE name='auctions_sweep'")
        conn.commit()


def _lot(sid):
    lots = call(R, sid)["active"]
    assert len(lots) == A.LOTS_ACTIVE and len({l["itemID"] for l in lots}) == A.LOTS_ACTIVE
    return lots[0]


def test_hq10_required_and_min_bid():
    hid, sid, _ = new_player("au1", credits=10**10)
    lot = _lot(sid)
    assert call(R + "/bid", sid, auctionID=lot["id"], amount=lot["minBid"])["code"] == "locked"
    _hq(hid, 10)
    assert call(R + "/bid", sid, auctionID=lot["id"], amount=lot["minBid"] - 1)["code"] == "too_low"


def test_outbid_refund_and_settlement():
    a, a_sid = _bidder("au2")
    b, b_sid = _bidder("au3")
    lot = _lot(a_sid)
    r1 = call(R + "/bid", a_sid, auctionID=lot["id"], amount=lot["minBid"])
    assert r1["err"] == 0 and credits(a) == 10**10 - lot["minBid"]
    assert call(R + "/bid", a_sid, auctionID=lot["id"], amount=lot["minBid"] * 2)["code"] == "leading"
    nxt = r1["auction"]["minBid"]
    assert call(R + "/bid", b_sid, auctionID=lot["id"], amount=nxt)["err"] == 0
    assert credits(a) == 10**10                                   # refunded
    assert credits(b) == 10**10 - nxt
    _end(lot["id"])
    data = call(R, b_sid)
    assert any(w["id"] == lot["id"] for w in data["won"])
    assert qty(b, lot["itemID"]) == 1 and qty(a, lot["itemID"]) == 0
    assert credits(b) == 10**10 - nxt                             # paid once, nothing refunded
    assert call(R + "/bid", a_sid, auctionID=lot["id"], amount=nxt * 2)["code"] == "gone"


def test_ownership_limit_counts_owned_and_leading():
    hid, sid = _bidder("au4")
    lot = _lot(sid)
    give(hid, lot["itemID"], 10)
    assert call(R + "/bid", sid, auctionID=lot["id"], amount=lot["minBid"])["code"] == "limit"


def test_concurrent_bids_one_wins_other_untouched():
    a, a_sid = _bidder("au5")
    b, b_sid = _bidder("au6")
    lot = _lot(a_sid)
    out = []
    ts = [threading.Thread(target=lambda s=s: out.append(call(R + "/bid", s, auctionID=lot["id"], amount=lot["minBid"])))
          for s in (a_sid, b_sid)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    oks = [r for r in out if r["err"] == 0]
    assert len(oks) == 1
    assert credits(a) + credits(b) == 2 * 10**10 - lot["minBid"]


def test_dividend_pool_shared_capped_and_from_jackpot():
    h1, _, _ = new_player("au7")
    h2, _, _ = new_player("au8")
    spinner, _, _ = new_player("au9")
    item = A.symbol_item(5)
    with main.get_db() as conn:
        conn.execute("DELETE FROM warehouse WHERE item_id=?", (item,))
        conn.execute("UPDATE jackpot SET amount=100000000000 WHERE id=1")
        conn.commit()
    give(h1, item, 30)                                            # counts as 10
    give(h2, item, 10)
    c1, c2 = credits(h1), credits(h2)
    with main.get_db() as conn:
        with econ.tx(conn):
            d = A.pay_dividend(conn, 5, spinner)
        jackpot = conn.execute("SELECT amount FROM jackpot WHERE id=1").fetchone()[0]
    assert d["pool"] == 10_000_000_000 and d["paid"] == 10_000_000_000
    assert credits(h1) - c1 == credits(h2) - c2 == 5_000_000_000
    assert jackpot == 90_000_000_000
    assert A.symbol_item(31) is None


def test_casino_roll_still_works_atomically():
    hid, sid, _ = new_player("au10", credits=10_000_000)
    with main.get_db() as conn:
        conn.execute("INSERT INTO factories(factory_id, hid, item_id, level) VALUES(?,?,61,1)", (main.new_id(), hid))
        conn.commit()
    import json, zlib
    from helpers import client
    r = json.loads(zlib.decompress(client.post("/flut23/casinoNewRoll.php",
                                               data={"sid": sid, "bet": "1000000", "count": "5"}).content))
    assert r["err"] == 0 and "dividends" in r
    assert credits(hid) == 10_000_000 - 5_000_000 + r["total_win"]
    r = json.loads(zlib.decompress(client.post("/flut23/casinoNewRoll.php",
                                               data={"sid": sid, "bet": "1000000", "count": "500"}).content))
    assert r["err"] == 5                                          # not enough spins left
