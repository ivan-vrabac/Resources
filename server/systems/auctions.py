"""Phase 8 — luxury item auctions and casino dividends.

Luxury items = the casino reel symbols: reel 0–29 → items 128–157, reel 30 → 163 (the app's
casino_screen mapping); reel 31 is the jackpot symbol.

Auctions [owner rules 2026-10-19 marked *]:
- * One auction at a time, one item; players outbid each other. When it ends, the next luxury
  item (random, never the same twice in a row) goes up for auction.
- * Bids are paid in RESOURCES, not credits: every luxury item has its own exclusive resource
  (BID_RESOURCE, e.g. chandelier → glass, dog house → watch dogs, mansion → bricks, private
  island → sand). A bid is a quantity of that resource.
- * Placing a bid takes the resources at once and gives the bidder (a few) luxury points; when
  outbid, the resources return to the warehouse. The winner pays the resources for the item and
  gets far more points. Luxury points come ONLY from luxury bids and wins.
- Bidding needs HQ level 10; at most MAX_OWN of each item (owned + leading bids).
- Proposal: start bid ≈ START_VALUE credits' worth of the resource; raise ≥ MIN_RAISE; a bid in
  the last EXTEND_S seconds extends the lot; LOT_HOURS per lot. Points: a bid gives bid value in
  credits / BID_POINTS_PER; a win gives WIN_POINTS_BASE + winning value / WIN_POINTS_PER (resource
  valued at SYSTEM_PRICES, or RESOURCE_VALUE for unpriced ones). Start lot → bid 10, win 2,000.

Casino dividends [owner rule]: a five of a kind of luxury symbol X pays every holder of X
DIVIDEND_PER_ITEM (1 %) of the current jackpot per item held, counting at most MAX_OWN items
(→ max 10 %). This is new money; the jackpot is NOT reduced. Paid exactly once per winning spin
inside the spin's transaction, recorded in casino_dividends and the ledger.
"""
from __future__ import annotations

import datetime
import math
import os
import random
import threading
import time
import uuid

import econ
from . import int_arg, social

LUXURY = list(range(128, 158)) + [163]          # index = reel symbol
# luxury item → the one resource it is bought with (each resource used once)
BID_RESOURCE = {
    128: 59,   # Luxury Chandelier ← Glass
    129: 36,   # Ancient Watch ← Copper
    130: 35,   # Unique Plate ← Silver
    131: 95,   # Luxury Dog House ← Watch Dogs
    132: 53,   # Private Island ← Quartz Sand
    133: 51,   # Private Jet ← Titanium
    134: 20,   # Pyramid ← Limestone
    135: 30,   # Eiffel Tower ← Steel
    136: 10,   # Salvator Mundi ← Crude Oil (oil paint)
    137: 41,   # Dinosaur Skeleton ← Fossils
    138: 81,   # Luxury Watch ← Rough Diamonds
    139: 57,   # Painting ← Plastics (acrylics)
    140: 32,   # Luxury Yacht ← Aluminium
    141: 66,   # Space Shuttle ← Electronics
    142: 93,   # Luxury Motorhome ← Batteries
    143: 3,    # Castle ← Gravel
    144: 13,   # Luxury Car ← Iron Ore
    145: 55,   # Old Coins ← Copper Coins
    146: 40,   # Coin Collection ← Roman Coins
    147: 22,   # Luxury Ranch ← Fertilizer
    148: 28,   # Vineyard ← Insecticides
    149: 67,   # Private Satellite ← Silicon
    150: 87,   # Weapons Collection ← Weapons
    151: 7,    # Bunker ← Concrete
    152: 24,   # Private Mansion ← Bricks
    153: 92,   # Private Helicopter ← Lithium
    154: 79,   # Gold Sculpture ← Gold
    155: 14,   # Gold Foot ← Gold Ore
    156: 70,   # Oldtimer ← Scrap Metal
    157: 2,    # Wine Cellar ← Clay
    163: 84,   # Necklace ← Jewellery
}
# credit value per unit for resources without a system price (proposal)
RESOURCE_VALUE = {59: 30, 95: 200, 51: 150, 41: 50, 57: 40, 66: 250, 93: 300, 55: 60, 40: 80,
                  22: 20, 28: 30, 67: 100, 87: 400, 92: 500, 70: 15, 84: 1000}
HQ_LEVEL_REQUIRED = 10
MAX_OWN = 10
LOT_HOURS = 24                 # (old fixed length, kept for reference)
LOT_HOURS_MIN, LOT_HOURS_MAX = 10, 16   # owner 2026-10-23: each lot runs a random 10-16 h
START_VALUE = 1_000_000_000    # HQ 10 companies are rich (HQ 10 alone needs ~15 T of resources)
MIN_RAISE = 0.05
EXTEND_S = 300                 # (old rule, unused)
SNIPE_WINDOW_S, SNIPE_RESET_S = 30, 60
# owner 2026-10-23: bids are set automatically; the player only picks how far above the minimum
BID_STEPS = (0, 10, 25, 50, 100)        # % above the minimum bid

SWEEP_S = 30
BID_POINTS_PER = 100_000
WIN_POINTS_BASE = 1_000
WIN_POINTS_PER = 1_000         # (old linear rule, unused)
WIN_POINTS_LOG = 1_000         # win: 1 000 + 1 000 × log10(1 + value / start value)
DIVIDEND_PER_ITEM = 0.01

_prices = {}


def symbol_item(sym: int):
    return LUXURY[sym] if 0 <= sym < len(LUXURY) else None


def unit_value(res) -> float:
    return float(_prices.get(res) or RESOURCE_VALUE.get(res) or 10)


def start_qty(item) -> int:
    return max(1, int(round(START_VALUE / unit_value(BID_RESOURCE[item]))))


def _value_steps(item, qty) -> float:
    """log10 of the bid value in units of the start value: 1 at 9× the start, 2 at 99×."""
    return math.log10(1 + qty * unit_value(BID_RESOURCE[item]) / START_VALUE)


def points_for(item, qty) -> int:
    """Luxury points for placing a bid of `qty`."""
    # owner 2026-10-23: luxury points grow with the value, but only logarithmically (no endless inflation)
    return 1 + int(10 * _value_steps(item, qty))


def win_points(item, qty) -> int:
    return WIN_POINTS_BASE + int(WIN_POINTS_LOG * _value_steps(item, qty))


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS auctions (
            id          TEXT PRIMARY KEY,
            item_id     INTEGER NOT NULL,
            qty         INTEGER NOT NULL DEFAULT 1,
            start_price INTEGER NOT NULL,
            top_bid     INTEGER NOT NULL DEFAULT 0,
            top_hid     TEXT,
            bids        INTEGER NOT NULL DEFAULT 0,
            status      TEXT NOT NULL,           -- open, sold, expired
            created_at  TEXT NOT NULL,
            ends_at     TEXT NOT NULL,
            settled_at  TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_auctions_status ON auctions(status, ends_at);
        CREATE INDEX IF NOT EXISTS idx_auctions_item ON auctions(item_id, settled_at);
        CREATE TABLE IF NOT EXISTS auction_bids (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            auction_id TEXT NOT NULL,
            hid        TEXT NOT NULL,
            amount     INTEGER NOT NULL,
            ts         TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_auction_bids ON auction_bids(auction_id, id);
        CREATE TABLE IF NOT EXISTS luxury_items (     -- owner's rule: luxury items are not warehouse stock
            hid     TEXT NOT NULL,
            item_id INTEGER NOT NULL,
            qty     INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (hid, item_id)
        );
        CREATE INDEX IF NOT EXISTS idx_luxury_items_item ON luxury_items(item_id);
        CREATE TABLE IF NOT EXISTS luxury_points (
            hid    TEXT PRIMARY KEY,
            points INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS casino_dividends (
            id         TEXT PRIMARY KEY,
            ts         TEXT NOT NULL,
            spinner    TEXT NOT NULL,
            item_id    INTEGER NOT NULL,
            jackpot    INTEGER NOT NULL,
            pool       INTEGER NOT NULL,
            paid       INTEGER NOT NULL,
            holders    INTEGER NOT NULL
        );
    """)
    # move luxury items out of the warehouse (earlier builds stored them there)
    q = ",".join(str(i) for i in LUXURY)
    conn.execute(f"INSERT INTO luxury_items(hid, item_id, qty) SELECT hid, item_id, CAST(qty AS INTEGER) FROM warehouse "
                 f"WHERE item_id IN ({q}) AND qty >= 1 ON CONFLICT(hid, item_id) DO UPDATE SET qty = qty + excluded.qty")
    conn.execute(f"DELETE FROM warehouse WHERE item_id IN ({q})")
    # bid currency changed from credits to resources: settle leftovers of earlier dev builds
    for a in conn.execute("SELECT * FROM auctions WHERE status='open' AND start_price>=1000000 AND top_hid IS NOT NULL").fetchall():
        try:
            econ.credit(conn, a["top_hid"], a["top_bid"], "auction_refund", a["id"])
        except Exception:
            pass
    conn.execute("UPDATE auctions SET status='expired', settled_at=COALESCE(settled_at, ?) "
                 "WHERE status='open' AND start_price>=1000000", (econ.utcnow_iso(),))
    conn.commit()


def owned(conn, hid, item_id) -> int:
    r = conn.execute("SELECT qty FROM luxury_items WHERE hid=? AND item_id=?", (hid, item_id)).fetchone()
    return int(r[0]) if r else 0


def add_luxury(conn, hid, item_id, qty) -> None:
    conn.execute("INSERT INTO luxury_items(hid, item_id, qty) VALUES(?,?,?) ON CONFLICT(hid, item_id) "
                 "DO UPDATE SET qty = qty + excluded.qty", (hid, item_id, int(qty)))


def leading(conn, hid, item_id) -> int:
    return conn.execute("SELECT COALESCE(SUM(qty),0) FROM auctions WHERE status='open' AND top_hid=? AND item_id=?",
                        (hid, item_id)).fetchone()[0]


def add_points(conn, hid, pts) -> None:
    conn.execute("INSERT INTO luxury_points(hid, points) VALUES(?,?) ON CONFLICT(hid) "
                 "DO UPDATE SET points=MAX(0, points+excluded.points)", (hid, pts))


def points_of(conn, hid) -> int:
    r = conn.execute("SELECT points FROM luxury_points WHERE hid=?", (hid,)).fetchone()
    return int(r[0]) if r else 0


def pay_dividend(conn, sym, spinner_hid, h=None):
    """Five of a kind of luxury symbol `sym`: every holder gets 1 % of the jackpot per item (≤ 10)."""
    item = symbol_item(sym)
    if item is None:
        return None
    jackpot = int(conn.execute("SELECT amount FROM jackpot WHERE id=1").fetchone()[0])
    holders = [(r[0], min(MAX_OWN, int(r[1]))) for r in
               conn.execute("SELECT hid, qty FROM luxury_items WHERE item_id=? AND qty>=1", (item,)).fetchall()]
    did = uuid.uuid4().hex
    paid = 0
    for hid, q in holders:
        amount = int(jackpot * DIVIDEND_PER_ITEM * q)
        if amount > 0:
            econ.credit(conn, hid, amount, "casino_dividend", did)
            paid += amount
            if h:
                h.add_proto(conn, hid, "dividend", {"itemID": item, "amount": amount})
    conn.execute("INSERT INTO casino_dividends(id, ts, spinner, item_id, jackpot, pool, paid, holders) "
                 "VALUES(?,?,?,?,?,?,?,?)", (did, econ.utcnow_iso(), spinner_hid, item, jackpot, paid, paid, len(holders)))
    econ.emit(conn, "casino_dividend", spinner_hid, {"itemID": item, "paid": paid, "holders": len(holders)})
    return {"itemID": item, "pool": paid, "paid": paid, "holders": len(holders),
            "perItemShare": DIVIDEND_PER_ITEM}


def sweep(conn, h, now, rng=None) -> list:
    """Settle the ended lot and open the next one. Inside tx(). Returns pushes for after commit."""
    rng = rng or random.Random()
    iso = now.isoformat()
    pushes = []
    last_item = None
    for a in conn.execute("SELECT * FROM auctions WHERE status='open' AND ends_at<=?", (iso,)).fetchall():
        last_item = a["item_id"]
        if a["top_hid"]:
            cur = conn.execute("UPDATE auctions SET status='sold', settled_at=? WHERE id=? AND status='open'", (iso, a["id"]))
            if cur.rowcount != 1:
                continue
            # the bid resources were taken when bidding; the winner now receives the item
            add_luxury(conn, a["top_hid"], a["item_id"], a["qty"])
            add_points(conn, a["top_hid"], win_points(a["item_id"], a["top_bid"]))
            h.add_proto(conn, a["top_hid"], "auctionwon", {"itemID": a["item_id"], "price": a["top_bid"],
                                                            "resID": BID_RESOURCE[a["item_id"]]})
            econ.emit(conn, "auction_won", a["top_hid"], {"itemID": a["item_id"], "price": a["top_bid"],
                                                          "resID": BID_RESOURCE[a["item_id"]]})
            pushes.append((a["top_hid"], "Auction won", "You won the luxury auction. See it in your luxury collection."))
        else:
            conn.execute("UPDATE auctions SET status='expired', settled_at=? WHERE id=? AND status='open'", (iso, a["id"]))
    if not conn.execute("SELECT 1 FROM auctions WHERE status='open'").fetchone():
        if last_item is None:
            r = conn.execute("SELECT item_id FROM auctions ORDER BY created_at DESC LIMIT 1").fetchone()
            last_item = r[0] if r else None
        item = rng.choice([i for i in LUXURY if i != last_item])
        conn.execute("INSERT INTO auctions(id, item_id, qty, start_price, status, created_at, ends_at) "
                     "VALUES(?,?,1,?,'open',?,?)", (uuid.uuid4().hex, item, start_qty(item), iso,
                                                     (now + datetime.timedelta(hours=rng.uniform(LOT_HOURS_MIN, LOT_HOURS_MAX))).isoformat()))
    return pushes


def now_utc():
    return econ.utcnow()


def install(api) -> None:
    h = api.h
    _prices.update(h.SYSTEM_PRICES)
    econ.NON_WAREHOUSE_ITEMS.update(LUXURY)
    with h.get_db() as conn:
        init_schema(conn)
    h.CASINO_FIVE_HOOKS.append(lambda conn, sym, hid: pay_dividend(conn, sym, hid, h))

    def maybe_sweep(conn, now):
        pushes = []
        with econ.tx(conn):
            if econ.due(conn, "auctions_sweep", SWEEP_S):
                pushes = sweep(conn, h, now)
        for hid, title, body in pushes:
            try:
                h.push(conn, hid, title, body)
            except Exception:
                pass

    def hq_level(conn, hid):
        r = conn.execute("SELECT level FROM hq WHERE hid=?", (hid,)).fetchone()
        return int(r[0]) if r else 0

    def clock() -> None:
        """Server-side auction clock (owner 2026-10-23): ends the lot at its real end time, even after
        late bids moved it (30 s → 60 s, any number of times), and opens the next lot at once,
        whether or not anyone is looking. The end time is re-read every few seconds."""
        while True:
            wait = 5.0
            try:
                with h.get_db() as conn:
                    r = conn.execute("SELECT ends_at FROM auctions WHERE status='open' ORDER BY ends_at LIMIT 1").fetchone()
                    now = econ.utcnow()
                    if r is None or r[0] <= now.isoformat():
                        with econ.tx(conn):
                            pushes = sweep(conn, h, now)
                        for hid, title, body in pushes:
                            try:
                                h.push(conn, hid, title, body)
                            except Exception:
                                pass
                        wait = 1.0
                    else:
                        left = (datetime.datetime.fromisoformat(r[0]) - now).total_seconds()
                        wait = max(0.2, min(5.0, left + 0.05))
            except Exception:
                wait = 5.0
            time.sleep(wait)

    if os.environ.get("WORLD_EVENTS_THREAD", "1") != "0":
        threading.Thread(target=clock, daemon=True, name="auction-clock").start()

    def min_bid(a):
        return max(a["start_price"], int(a["top_bid"] * (1 + MIN_RAISE)) + 1) if a["top_bid"] else a["start_price"]

    def bid_steps(a) -> list:
        mb = min_bid(a)
        return [{"pct": p, "amount": int(math.ceil(mb * (1 + p / 100)))} for p in BID_STEPS]

    def view(conn, a, hid):
        res = BID_RESOURCE[a["item_id"]]
        return {"id": a["id"], "itemID": a["item_id"], "qty": a["qty"], "resID": res,
                "startPrice": a["start_price"], "topBid": a["top_bid"], "bids": a["bids"], "status": a["status"],
                "endsAt": a["ends_at"], "settledAt": a["settled_at"], "minBid": min_bid(a),
                "bidSteps": [{**x, "points": points_for(a["item_id"], x["amount"])} for x in bid_steps(a)],
                "minBidPoints": points_for(a["item_id"], min_bid(a)),
                "winPoints": win_points(a["item_id"], max(min_bid(a), a["top_bid"])),
                "leader": social.public_ref(conn, a["top_hid"]) if a["top_hid"] else None,
                "youLead": a["top_hid"] == hid, "owned": owned(conn, hid, a["item_id"]),
                "youHave": econ.qty_of(conn, hid, res)}

    @api.endpoint("/api/v1/auctions", feature="AUCTIONS")
    def listing(conn, hid, form):
        now = econ.utcnow()
        maybe_sweep(conn, now)
        active = conn.execute("SELECT * FROM auctions WHERE status='open' ORDER BY ends_at").fetchall()
        recent = conn.execute("SELECT * FROM auctions WHERE status<>'open' ORDER BY settled_at DESC LIMIT 20").fetchall()
        lvl = hq_level(conn, hid)
        return {"err": 0, "eligible": lvl >= HQ_LEVEL_REQUIRED, "hqLevel": lvl, "hqRequired": HQ_LEVEL_REQUIRED,
                "maxOwn": MAX_OWN, "minRaise": MIN_RAISE, "luxuryPoints": points_of(conn, hid),
                "active": [view(conn, a, hid) for a in active],
                "recent": [view(conn, a, hid) for a in recent],
                "bidResources": {str(k): v for k, v in BID_RESOURCE.items()},
                "collection": {str(i): owned(conn, hid, i) for i in LUXURY}}

    @api.endpoint("/api/v1/auctions/item", feature="AUCTIONS")
    def item_history(conn, hid, form):
        """Bid history (for a graph) and the last sale of one luxury item."""
        item = int_arg(form, "itemID", None, 0, 10**6)
        if item not in BID_RESOURCE:
            raise econ.GameError("bad_input", "Not a luxury item")
        last = conn.execute("SELECT * FROM auctions WHERE item_id=? AND status='sold' ORDER BY settled_at DESC LIMIT 1",
                            (item,)).fetchone()
        return {"err": 0, "itemID": item, "resID": BID_RESOURCE[item], "owned": owned(conn, hid, item),
                "lastSale": {"ts": last["settled_at"], "price": last["top_bid"],
                             "player": social.public_ref(conn, last["top_hid"])} if last else None,
                # owner 2026-10-23: sale prices (resource units) of up to the last 365 days, for a graph
                "sales": [{"ts": r[0], "price": r[1], "player": social.public_ref(conn, r[2]) if r[2] else None}
                          for r in conn.execute(
                    "SELECT settled_at, top_bid, top_hid FROM auctions WHERE item_id=? AND status='sold' AND settled_at >= ? "
                    "ORDER BY settled_at", (item, (now_utc() - datetime.timedelta(days=365)).isoformat()))]}

    @api.endpoint("/api/v1/auctions/bid", feature="AUCTIONS")
    def bid(conn, hid, form):
        aid = (form.get("auctionID") or "").strip()
        now = econ.utcnow()
        maybe_sweep(conn, now)
        outbid = None
        with econ.tx(conn):
            a = conn.execute("SELECT * FROM auctions WHERE id=?", (aid,)).fetchone()
            if not a or a["status"] != "open" or a["ends_at"] <= now.isoformat():
                raise econ.GameError("gone", "This auction has ended")
            if hq_level(conn, hid) < HQ_LEVEL_REQUIRED:
                raise econ.GameError("locked", f"You need headquarters level {HQ_LEVEL_REQUIRED} to bid")
            if a["top_hid"] == hid:
                raise econ.GameError("leading", "You already have the highest bid")
            if owned(conn, hid, a["item_id"]) + leading(conn, hid, a["item_id"]) + a["qty"] > MAX_OWN:
                raise econ.GameError("limit", f"You can own at most {MAX_OWN} of each luxury item")
            # the amount is set by the server from the chosen step (or must be exactly one of the steps)
            steps = bid_steps(a)
            if form.get("step") not in (None, ""):
                i = int_arg(form, "step", 0, 0, len(steps) - 1)
                seen = form.get("seenMin")
                if seen not in (None, "") and int_arg(form, "seenMin", 0, 0) != min_bid(a):
                    raise econ.GameError("price_changed", "Someone bid in the meantime. Choose your bid again.")
                amount = steps[i]["amount"]
            else:
                amount = int_arg(form, "amount", None, 1, 10**15)
                if amount not in {x["amount"] for x in steps}:
                    raise econ.GameError("bad_bid", "Choose one of the offered bids")
            res = BID_RESOURCE[a["item_id"]]
            econ.take(conn, hid, res, amount, "auction_bid", aid)
            add_points(conn, hid, points_for(a["item_id"], amount))
            if a["top_hid"]:
                econ.give(conn, a["top_hid"], res, a["top_bid"], "auction_refund", aid, ignore_capacity=True)
                # bid points last only while you lead: outbid → they are taken back (no ping-pong farming)
                add_points(conn, a["top_hid"], -points_for(a["item_id"], a["top_bid"]))
                outbid = a["top_hid"]
                h.add_proto(conn, outbid, "auctionoutbid", {"itemID": a["item_id"], "bid": amount, "resID": res})
            ends = datetime.datetime.fromisoformat(a["ends_at"])
            # owner 2026-10-23: a bid in the last 30 s sets the clock to 60 s (no sniping)
            if (ends - now).total_seconds() < SNIPE_WINDOW_S:
                ends = now + datetime.timedelta(seconds=SNIPE_RESET_S)
            cur = conn.execute("UPDATE auctions SET top_bid=?, top_hid=?, bids=bids+1, ends_at=? "
                               "WHERE id=? AND status='open' AND top_bid=?",
                               (amount, hid, ends.isoformat(), aid, a["top_bid"]))
            if cur.rowcount != 1:
                raise econ.GameError("conflict", "Someone else bid first. Try again.")
            conn.execute("INSERT INTO auction_bids(auction_id, hid, amount, ts) VALUES(?,?,?,?)",
                         (aid, hid, amount, now.isoformat()))
            a = conn.execute("SELECT * FROM auctions WHERE id=?", (aid,)).fetchone()
            out = {"err": 0, "auction": view(conn, a, hid), "luxuryPoints": points_of(conn, hid)}
        if outbid:
            try:
                h.push(conn, outbid, "Outbid", "Someone outbid you at the luxury auction. Your resources were returned.")
            except Exception:
                pass
        return out
