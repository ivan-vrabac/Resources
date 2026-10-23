"""Phase 2: market — system trade, buy orders only (one per item, edit/cancel), selling by filling a
buy order, escrow, Haulage Firm tax, whole units, concurrency."""
import threading
import uuid

import main
from helpers import call, credits, give, new_player, qty, set_building
from systems.market import tax_rate

import pytest

M = "/api/v1/market/"
# These tests check the market RULES (tax, escrow, bounds). They pin the prices they were written
# with; the real prices come from economy.py and change with the economy.
PINNED = {2: 5, 3: 5, 13: 20, 14: 200, 79: 500}


@pytest.fixture(autouse=True)
def _pinned_prices():
    old = {k: main.SYSTEM_PRICES.get(k) for k in PINNED}
    main.SYSTEM_PRICES.update(PINNED)
    yield
    for k, v in old.items():
        main.SYSTEM_PRICES[k] = v
CLAY = 2          # system price 5
GOLD = 79         # system price 500


def test_tax_rate_progression():
    assert [tax_rate(l) for l in (0, 1, 5, 9, 10)] == [0.15, 0.14, 0.10, 0.06, 0.05]


def test_system_trade_prices_and_restrictions():
    hid, sid, _ = new_player("sys", credits=1_000_000, wh_level=3)
    give(hid, CLAY, 1000)
    r = call(M + "system", sid, side="sell", itemID=CLAY, qty=1000)
    assert r["credits"] == 5000 and qty(hid, CLAY) == 0
    r = call(M + "system", sid, side="buy", itemID=CLAY, qty=100)
    assert r["cost"] == 750 + 112 and r["tax"] == 112 and qty(hid, CLAY) == 100   # 150% + 15% tax
    assert credits(hid) == 1_000_000 + 5000 - 862
    for banned in (42, 48):                                         # Giant Diamonds, TU IV: not tradeable at all
        assert call(M + "system", sid, side="buy", itemID=banned, qty=1)["code"] == "restricted"
    give(hid, 172, 1)                                               # artifacts are tradeable now
    assert call(M + "system", sid, side="sell", itemID=172, qty=1)["err"] == 0
    for restricted in (42, 48, 130):
        give(hid, restricted, 1)
        assert call(M + "system", sid, side="sell", itemID=restricted, qty=1)["code"] == "restricted"
        assert call(M + "order", sid, side="buy", itemID=restricted, qty=1, price=10)["code"] == "restricted"
    assert call(M + "system", sid, side="sell", itemID=CLAY, qty=999999)["code"] == "insufficient_items"
    assert call(M + "system", sid, side="buy", itemID=CLAY, qty=-5)["code"] == "bad_input"


def test_sell_orders_cannot_be_placed():
    hid, sid, _ = new_player("nosell", wh_level=3)
    give(hid, GOLD, 10)
    assert call(M + "order", sid, side="sell", itemID=GOLD, qty=10, price=450)["code"] == "bad_input"
    assert qty(hid, GOLD) == 10


def test_buy_order_escrow_tax_fill_and_refund():
    b_hid, b_sid, _ = new_player("buyer", credits=100_000, wh_level=3)
    s_hid, s_sid, _ = new_player("seller", credits=0, wh_level=3)
    set_building(b_hid, 123, 5)                                     # 10% tax
    q = call(M + "quote", b_sid, action="buy_order", itemID=GOLD, qty=100, price=600)
    assert q == {"err": 0, "value": 60000, "tax": 6000, "total": 66000, "taxRate": 0.10}
    r = call(M + "order", b_sid, side="buy", itemID=GOLD, qty=100, price=600)
    assert r["escrow"] == 66000 and credits(b_hid) == 100_000 - 66000
    give(s_hid, GOLD, 60)
    r = call(M + "take", s_sid, orderID=r["orderID"], qty=60)           # seller fills 60 (taker, no tax)
    assert r["value"] == 36000 and credits(s_hid) == 36000 and qty(b_hid, GOLD) == 60
    mine = call(M + "mine", b_sid)["orders"][0]
    assert mine["qtyOpen"] == 40 and mine["escrow"] == 66000 - 36000 - 3600
    r = call(M + "cancel", b_sid, orderID=mine["id"])
    assert r["refunded"] == 26400
    assert credits(b_hid) == 100_000 - 36000 - 3600


def test_one_order_per_item_edit_and_priority():
    a_hid, a_sid, _ = new_player("onea", credits=10_000_000, wh_level=3)
    b_hid, b_sid, _ = new_player("oneb", credits=10_000_000, wh_level=3)
    oa = call(M + "order", a_sid, side="buy", itemID=GOLD, qty=10, price=520)["orderID"]
    assert call(M + "order", a_sid, side="buy", itemID=GOLD, qty=5, price=530)["code"] == "duplicate"
    assert call(M + "order", b_sid, side="buy", itemID=GOLD, qty=10, price=499)["code"] == "price_too_low"
    call(M + "order", b_sid, side="buy", itemID=GOLD, qty=10, price=520)
    book = call(M + "book", b_sid, itemID=GOLD)
    same = [x for x in book["bids"] if x["price"] == 520]
    assert same[0]["id"] == oa                                     # same price: older first
    assert book["myOrder"] and book["freeSpace"] > 0
    before = credits(a_hid)
    r = call(M + "edit", a_sid, orderID=oa, qty=20, price=540)
    assert r["err"] == 0 and credits(a_hid) == before + 5980 - (10800 + 1620)  # old escrow back, new escrow held
    assert call(M + "book", b_sid, itemID=GOLD)["bids"][0]["id"] == oa       # higher price on top


def test_bid_cap_own_orders_and_idempotency():
    a_hid, a_sid, _ = new_player("capa", credits=10_000_000, wh_level=3)
    b_hid, b_sid, _ = new_player("capb", credits=10_000_000, wh_level=3)
    call(M + "order", a_sid, side="buy", itemID=14, qty=10, price=200)          # gold ore, sys 200 (floor)
    assert call(M + "order", b_sid, side="buy", itemID=14, qty=10, price=251)["code"] == "price_too_high"
    assert call(M + "order", b_sid, side="buy", itemID=14, qty=10, price=250)["err"] == 0
    assert call(M + "order", b_sid, side="buy", itemID=13, qty=1, price=31)["code"] == "price_too_high"  # > 150% sys
    own = call(M + "mine", b_sid)["orders"][0]
    assert call(M + "take", b_sid, orderID=own["id"], qty=1)["code"] == "own_order"
    rid = uuid.uuid4().hex
    first = call(M + "order", a_sid, side="buy", itemID=3, qty=5, price=6, rid=rid)
    again = call(M + "order", a_sid, side="buy", itemID=3, qty=5, price=6, rid=rid)
    assert first == again
    assert sum(1 for o in call(M + "mine", a_sid)["orders"] if o["itemID"] == 3) == 1


def test_concurrent_sellers_never_overfill():
    b_hid, b_sid, _ = new_player("race", credits=10_000, wh_level=3)
    order = call(M + "order", b_sid, side="buy", itemID=CLAY, qty=100, price=6)["orderID"]
    sellers = [new_player(f"rs{i}", credits=0, wh_level=3) for i in range(8)]
    for s in sellers:
        give(s[0], CLAY, 30)
    results = []
    ts = [threading.Thread(target=lambda sid=s[1]: results.append(call(M + "take", sid, orderID=order, qty=30)))
          for s in sellers]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert qty(b_hid, CLAY) == 100                                        # exactly what was asked
    assert sum(1 for r in results if r["err"] == 0) == 4                  # 30+30+30+10
    assert sum(credits(s[0]) for s in sellers) == 600


def test_expired_order_refunds():
    hid, sid, _ = new_player("exp", credits=10_000, wh_level=3)
    call(M + "order", sid, side="buy", itemID=CLAY, qty=100, price=6)
    with main.get_db() as conn:
        conn.execute("UPDATE mkt_orders SET expires_at='2000-01-01' WHERE hid=?", (hid,))
        conn.commit()
    call(M + "overview", sid)
    assert call(M + "mine", sid)["orders"] == []
    assert credits(hid) == 10_000


def test_ledger_balances():
    """Every credit movement in the market is in the ledger; per-player ledger sums match balances."""
    hid, sid, _ = new_player("led", credits=0, wh_level=3)
    give(hid, CLAY, 200)
    call(M + "system", sid, side="sell", itemID=CLAY, qty=200)
    call(M + "order", sid, side="buy", itemID=CLAY, qty=10, price=5)
    with main.get_db() as conn:
        s = conn.execute("SELECT SUM(credits) FROM ledger WHERE hid=?", (hid,)).fetchone()[0]
    assert s == credits(hid)
