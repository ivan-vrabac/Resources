"""Phase 8 — luxury item auctions and casino dividends.

Luxury items = the casino reel symbols: reel 0–29 → items 128–157, reel 30 → 163 (the app's
casino_screen mapping); reel 31 is the jackpot symbol.

Auctions (no prices or schedule exist in the game files → configurable proposal):
- The server keeps LOTS_ACTIVE lots open; each sells 1 luxury item for LOT_HOURS. A new lot
  never repeats an item that already has an open lot.
- Bidding needs HQ level 10. A player can own at most MAX_OWN of each luxury item; owned +
  currently-leading bids for that item must stay below the cap.
- A bid must be ≥ START_PRICE and ≥ current × (1 + MIN_RAISE). The full bid is reserved
  (debited) immediately; the previous leader is refunded in the same transaction. A bid in the
  last EXTEND_S seconds extends the lot by EXTEND_S (anti-sniping).
- Settlement (lazy sweep): the leader gets the item; credits paid go to nobody (a money sink —
  auctions never create money). A lot without bids just expires.

Casino dividends — interpretation (documented, not guessed silently):
The existing casino has one shared jackpot pool. A five-of-a-kind of luxury symbol X therefore
pays ONE dividend pool of DIVIDEND_SHARE (10 %) of the current jackpot, taken OUT of the jackpot
and split pro rata among holders of item X by quantity, each holding counted up to MAX_OWN.
No holders → nothing is paid and the jackpot is untouched. This can never pay more than 10 % of
the jackpot per event, so it cannot create unlimited money or bankrupt the casino. It runs inside
the spin's transaction (exactly once per winning spin) and every payout is in the ledger.
"""
from __future__ import annotations

import datetime
import random
import uuid

import econ
from . import int_arg, social

LUXURY = list(range(128, 158)) + [163]          # index = reel symbol
HQ_LEVEL_REQUIRED = 10
MAX_OWN = 10
LOTS_ACTIVE = 6
LOT_HOURS = 24
START_PRICE = 100_000_000
MIN_RAISE = 0.05
EXTEND_S = 300
SWEEP_S = 60
DIVIDEND_SHARE = 0.10


def symbol_item(sym: int):
    return LUXURY[sym] if 0 <= sym < len(LUXURY) else None


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
        CREATE TABLE IF NOT EXISTS auction_bids (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            auction_id TEXT NOT NULL,
            hid        TEXT NOT NULL,
            amount     INTEGER NOT NULL,
            ts         TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_auction_bids ON auction_bids(auction_id, id);
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
    conn.commit()


def owned(conn, hid, item_id) -> int:
    return int(econ.qty_of(conn, hid, item_id))


def leading(conn, hid, item_id) -> int:
    return conn.execute("SELECT COALESCE(SUM(qty),0) FROM auctions WHERE status='open' AND top_hid=? AND item_id=?",
                        (hid, item_id)).fetchone()[0]


def pay_dividend(conn, sym, spinner_hid, h=None):
    """Five of a kind of luxury symbol `sym`: split 10 % of the jackpot among holders. In the spin tx."""
    item = symbol_item(sym)
    if item is None:
        return None
    jackpot = int(conn.execute("SELECT amount FROM jackpot WHERE id=1").fetchone()[0])
    holders = [(r[0], min(MAX_OWN, int(r[1]))) for r in
               conn.execute("SELECT hid, qty FROM warehouse WHERE item_id=? AND qty>=1", (item,)).fetchall()]
    total_q = sum(q for _, q in holders)
    pool = int(jackpot * DIVIDEND_SHARE)
    did = uuid.uuid4().hex
    paid = 0
    if total_q and pool > 0:
        for hid, q in holders:
            amount = pool * q // total_q
            if amount > 0:
                econ.credit(conn, hid, amount, "casino_dividend", did)
                paid += amount
                if h:
                    h.add_proto(conn, hid, "dividend", {"itemID": item, "amount": amount})
        conn.execute("UPDATE jackpot SET amount=amount-? WHERE id=1", (paid,))
    conn.execute("INSERT INTO casino_dividends(id, ts, spinner, item_id, jackpot, pool, paid, holders) "
                 "VALUES(?,?,?,?,?,?,?,?)", (did, econ.utcnow_iso(), spinner_hid, item, jackpot, pool, paid, len(holders)))
    econ.emit(conn, "casino_dividend", spinner_hid, {"itemID": item, "paid": paid, "holders": len(holders)})
    return {"itemID": item, "pool": pool, "paid": paid, "holders": len(holders)}


def sweep(conn, h, now, rng=None) -> list:
    """Settle ended lots and open new ones. Inside tx(). Returns [(hid, title, body)] to push after commit."""
    rng = rng or random.Random()
    iso = now.isoformat()
    pushes = []
    for a in conn.execute("SELECT * FROM auctions WHERE status='open' AND ends_at<=?", (iso,)).fetchall():
        if a["top_hid"]:
            cur = conn.execute("UPDATE auctions SET status='sold', settled_at=? WHERE id=? AND status='open'", (iso, a["id"]))
            if cur.rowcount != 1:
                continue
            econ.give(conn, a["top_hid"], a["item_id"], a["qty"], "auction_won", a["id"], ignore_capacity=True)
            h.add_proto(conn, a["top_hid"], "auctionwon", {"itemID": a["item_id"], "price": a["top_bid"]})
            econ.emit(conn, "auction_won", a["top_hid"], {"itemID": a["item_id"], "price": a["top_bid"]})
            pushes.append((a["top_hid"], "Auction won", "You won an auction. The item is in your warehouse."))
        else:
            conn.execute("UPDATE auctions SET status='expired', settled_at=? WHERE id=? AND status='open'", (iso, a["id"]))
    open_items = {r[0] for r in conn.execute("SELECT item_id FROM auctions WHERE status='open'")}
    free = [i for i in LUXURY if i not in open_items]
    for _ in range(max(0, LOTS_ACTIVE - len(open_items))):
        if not free:
            break
        item = free.pop(rng.randrange(len(free)))
        # stagger end times so lots don't all end together
        ends = now + datetime.timedelta(hours=LOT_HOURS) + datetime.timedelta(minutes=rng.randint(0, 240))
        conn.execute("INSERT INTO auctions(id, item_id, qty, start_price, status, created_at, ends_at) "
                     "VALUES(?,?,1,?,'open',?,?)", (uuid.uuid4().hex, item, START_PRICE, iso, ends.isoformat()))
    return pushes


def install(api) -> None:
    h = api.h
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

    def view(conn, a, hid):
        return {"id": a["id"], "itemID": a["item_id"], "qty": a["qty"], "startPrice": a["start_price"],
                "topBid": a["top_bid"], "bids": a["bids"], "status": a["status"], "endsAt": a["ends_at"],
                "minBid": max(a["start_price"], int(a["top_bid"] * (1 + MIN_RAISE)) + 1) if a["top_bid"] else a["start_price"],
                "leader": social.public_ref(conn, a["top_hid"]) if a["top_hid"] else None,
                "youLead": a["top_hid"] == hid, "owned": owned(conn, hid, a["item_id"])}

    @api.endpoint("/api/v1/auctions", feature="AUCTIONS")
    def listing(conn, hid, form):
        now = econ.utcnow()
        maybe_sweep(conn, now)
        active = conn.execute("SELECT * FROM auctions WHERE status='open' ORDER BY ends_at").fetchall()
        recent = conn.execute("SELECT * FROM auctions WHERE status<>'open' ORDER BY settled_at DESC LIMIT 20").fetchall()
        mine = conn.execute("SELECT * FROM auctions WHERE status='sold' AND top_hid=? ORDER BY settled_at DESC LIMIT 50",
                            (hid,)).fetchall()
        lvl = hq_level(conn, hid)
        return {"err": 0, "eligible": lvl >= HQ_LEVEL_REQUIRED, "hqLevel": lvl, "hqRequired": HQ_LEVEL_REQUIRED,
                "maxOwn": MAX_OWN, "minRaise": MIN_RAISE,
                "active": [view(conn, a, hid) for a in active],
                "recent": [view(conn, a, hid) for a in recent],
                "won": [view(conn, a, hid) for a in mine],
                "collection": {str(i): owned(conn, hid, i) for i in LUXURY}}

    @api.endpoint("/api/v1/auctions/bid", feature="AUCTIONS")
    def bid(conn, hid, form):
        aid = (form.get("auctionID") or "").strip()
        amount = int_arg(form, "amount", None, 1, 10**15)
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
            min_bid = view(conn, a, hid)["minBid"]
            if amount < min_bid:
                raise econ.GameError("too_low", f"Minimum bid is {min_bid:,} credits")
            econ.debit(conn, hid, amount, "auction_bid", aid)
            if a["top_hid"]:
                econ.credit(conn, a["top_hid"], a["top_bid"], "auction_refund", aid)
                outbid = a["top_hid"]
                h.add_proto(conn, outbid, "auctionoutbid", {"itemID": a["item_id"], "bid": amount})
            ends = datetime.datetime.fromisoformat(a["ends_at"])
            if (ends - now).total_seconds() < EXTEND_S:
                ends = now + datetime.timedelta(seconds=EXTEND_S)
            cur = conn.execute("UPDATE auctions SET top_bid=?, top_hid=?, bids=bids+1, ends_at=? "
                               "WHERE id=? AND status='open' AND top_bid=?",
                               (amount, hid, ends.isoformat(), aid, a["top_bid"]))
            if cur.rowcount != 1:
                raise econ.GameError("conflict", "Someone else bid first — try again")
            conn.execute("INSERT INTO auction_bids(auction_id, hid, amount, ts) VALUES(?,?,?,?)",
                         (aid, hid, amount, now.isoformat()))
            a = conn.execute("SELECT * FROM auctions WHERE id=?", (aid,)).fetchone()
            out = {"err": 0, "auction": view(conn, a, hid)}
        if outbid:
            try:
                h.push(conn, outbid, "Outbid", "Someone outbid you at an auction. Your credits were refunded.")
            except Exception:
                pass
        return out
