"""Phase 2 — market v2: system trade, player buy/sell orders with matching, Haulage Firm tax.

Rules (documented assumptions, see .private/NEXT-PROGRESS.md):
- System trade (items with a system price only): sell to the system at 100% of the system price,
  buy from the system at 150% plus your transport tax (owner's rule). Unlimited volume.
- * Only BUY orders can be placed (owner's rule 2026-10-19): a player sells by filling an existing
  buy order (or to the system). One open buy order per player and item; it can be edited (price
  change = new time priority) or cancelled. Book order: price high→low, then oldest first.
  Buy orders escrow credits (price × qty + tax) and stay open ORDER_DAYS days, then are refunded.
  Quantities are whole units.
- Transport tax (Haulage Firm, item 123): 15% − 1% per level (5% at level 10), as in eva.txt.
  Charged once per trade to the side that placed the RESTING order (the "request"):
    · resting buy order → buyer paid it up front with the order (refunded pro rata if unfilled);
    · resting sell order → deducted from the seller's proceeds when it fills.
  The side that fills an existing order (taker) pays no tax. No trade is taxed twice.
- A buy order may bid at most 25% above the current best bid (eva.txt), and never more than the
  system's buy price (150%) when the item has a system price (buying from the system is cheaper).
- Not tradeable here: Giant Diamonds (42), Tech Upgrade IV (48), luxury items (auction-only,
  ownership-capped), artifacts, special buildings.
All movements go through econ (atomic, non-negative, ledgered); order placement accepts an
idempotency key `rid` so a retried request never places a second order.
"""
from __future__ import annotations

import datetime
import uuid

import econ
from . import float_arg, int_arg

HAULAGE_FIRM = 123
ORDER_DAYS = 2
SYSTEM_BUY_MARKUP = 1.5
MAX_BID_OVER_TOP = 1.25
LUXURY_ITEMS = set(range(128, 158)) | {163}
ARTIFACTS = set(range(172, 178))
RESTRICTED = {42: "Giant Diamonds", 48: "Tech Upgrade IV"}
MAX_QTY = 1e12


def tax_rate(level: int) -> float:
    """15% at Haulage Firm level 0, minus 1% per level, 5% at level 10."""
    return round(max(0.05, 0.15 - 0.01 * max(0, min(10, int(level)))), 4)


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS mkt_orders (
            id          TEXT PRIMARY KEY,
            hid         TEXT NOT NULL,
            side        TEXT NOT NULL CHECK (side IN ('buy','sell')),
            item_id     INTEGER NOT NULL,
            price       REAL NOT NULL,
            qty_total   REAL NOT NULL,
            qty_open    REAL NOT NULL,
            escrow      REAL NOT NULL DEFAULT 0,   -- buy: credits still held (incl. tax)
            tax_rate    REAL NOT NULL,
            status      TEXT NOT NULL DEFAULT 'open',
            created_at  TEXT NOT NULL,
            expires_at  TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_mkt_book ON mkt_orders(item_id, side, status, price);
        CREATE INDEX IF NOT EXISTS idx_mkt_hid ON mkt_orders(hid, status);
        CREATE TABLE IF NOT EXISTS mkt_trades (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ts         TEXT NOT NULL,
            kind       TEXT NOT NULL,          -- player | system_sell | system_buy
            item_id    INTEGER NOT NULL,
            qty        REAL NOT NULL,
            price      REAL NOT NULL,
            buyer_hid  TEXT,
            seller_hid TEXT,
            tax        REAL NOT NULL DEFAULT 0,
            tax_payer  TEXT,
            buy_order  TEXT,
            sell_order TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_trades_item_ts ON mkt_trades(item_id, ts);
        CREATE INDEX IF NOT EXISTS idx_trades_buyer ON mkt_trades(buyer_hid, ts);
        CREATE INDEX IF NOT EXISTS idx_trades_seller ON mkt_trades(seller_hid, ts);
    """)
    conn.commit()


def install(api) -> None:
    h = api.h
    prices = h.SYSTEM_PRICES
    with h.get_db() as conn:
        init_schema(conn)

    # ── helpers ─────────────────────────────────────────────────────────────

    def check_tradeable(item_id: int) -> None:
        if item_id in RESTRICTED:
            raise econ.GameError("restricted", f"{RESTRICTED[item_id]} can't be traded on the market")
        if item_id in LUXURY_ITEMS:
            raise econ.GameError("restricted", "Luxury items are only sold at auctions")
        if item_id in ARTIFACTS:
            raise econ.GameError("restricted", "Artifacts can't be traded")
        if item_id in h.SPECIAL_BUILDINGS or item_id in h.MINE_TYPES or item_id <= 1:
            raise econ.GameError("restricted", "This can't be traded")

    def my_tax(conn, hid) -> float:
        return tax_rate(h.building_level(conn, hid, HAULAGE_FIRM))

    def expire(conn) -> int:
        """Refund orders past their expiry (call inside a tx)."""
        now = econ.utcnow_iso()
        rows = conn.execute("SELECT * FROM mkt_orders WHERE status='open' AND expires_at <= ?", (now,)).fetchall()
        for o in rows:
            close_order(conn, o, "expired")
        return len(rows)

    def close_order(conn, o, status: str) -> None:
        """Return whatever the order still holds to its owner and close it."""
        if o["side"] == "buy":
            econ.credit(conn, o["hid"], o["escrow"], f"market_{status}", o["id"])
        else:
            econ.give(conn, o["hid"], o["item_id"], o["qty_open"], f"market_{status}", o["id"],
                      ignore_capacity=True)
        conn.execute("UPDATE mkt_orders SET status=?, qty_open=0, escrow=0 WHERE id=?", (status, o["id"]))

    def record(conn, kind, item_id, qty, price, buyer, seller, tax=0.0, tax_payer=None,
               buy_order=None, sell_order=None) -> None:
        conn.execute("INSERT INTO mkt_trades(ts, kind, item_id, qty, price, buyer_hid, seller_hid, tax, "
                     "tax_payer, buy_order, sell_order) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                     (econ.utcnow_iso(), kind, item_id, qty, price, buyer, seller, tax, tax_payer,
                      buy_order, sell_order))
        econ.emit(conn, "market_trade", buyer or seller, {"kind": kind, "itemID": item_id, "qty": qty,
                                                          "price": price}, public=False)

    def fill_resting_buy(conn, o, seller_hid: str, qty: float) -> dict:
        """Seller (taker) sells qty into resting buy order o at o.price."""
        value = round(qty * o["price"])
        tax = round(value * o["tax_rate"])
        if value + tax > o["escrow"] + 1e-6:      # rounding guard: never pay out more than held
            tax = max(0, round(o["escrow"]) - value)
        econ.take(conn, seller_hid, o["item_id"], qty, "market_sell", o["id"])
        econ.credit(conn, seller_hid, value, "market_sell", o["id"])
        econ.give(conn, o["hid"], o["item_id"], qty, "market_buy", o["id"], ignore_capacity=True)
        new_open = round(o["qty_open"] - qty, 6)
        new_escrow = o["escrow"] - value - tax
        if new_open <= 1e-6:
            econ.credit(conn, o["hid"], max(0, round(new_escrow)), "market_escrow_rest", o["id"])
            conn.execute("UPDATE mkt_orders SET qty_open=0, escrow=0, status='filled' WHERE id=?", (o["id"],))
        else:
            conn.execute("UPDATE mkt_orders SET qty_open=?, escrow=? WHERE id=?", (new_open, new_escrow, o["id"]))
        h.award_xp(conn, o["hid"], int(value))
        record(conn, "player", o["item_id"], qty, o["price"], o["hid"], seller_hid, tax, o["hid"], buy_order=o["id"])
        return {"qty": qty, "price": o["price"], "value": value, "tax": 0}

    def fill_resting_sell(conn, o, buyer_hid: str, qty: float) -> dict:
        """Buyer (taker) buys qty from resting sell order o at o.price."""
        value = round(qty * o["price"])
        tax = round(value * o["tax_rate"])
        econ.debit(conn, buyer_hid, value, "market_buy", o["id"])
        econ.give(conn, buyer_hid, o["item_id"], qty, "market_buy", o["id"])  # strict: buyer needs space
        econ.credit(conn, o["hid"], value - tax, "market_sell", o["id"])
        new_open = round(o["qty_open"] - qty, 6)
        conn.execute("UPDATE mkt_orders SET qty_open=?, status=? WHERE id=?",
                     (max(0.0, new_open), "filled" if new_open <= 1e-6 else "open", o["id"]))
        h.award_xp(conn, buyer_hid, int(value))
        record(conn, "player", o["item_id"], qty, o["price"], buyer_hid, o["hid"], tax, o["hid"], sell_order=o["id"])
        return {"qty": qty, "price": o["price"], "value": value, "tax": 0}

    def best(conn, item_id, side):
        order = "price DESC" if side == "buy" else "price ASC"
        return conn.execute(f"SELECT * FROM mkt_orders WHERE item_id=? AND side=? AND status='open' "
                            f"ORDER BY {order}, created_at LIMIT 1", (item_id, side)).fetchone()

    def book_side(conn, hid, item_id, side, limit=20):
        order = "price DESC" if side == "buy" else "price ASC"
        rows = conn.execute(f"SELECT o.id, o.price, o.qty_open, o.hid, o.expires_at, p.company_name "
                            f"FROM mkt_orders o JOIN players p ON p.hID=o.hid WHERE o.item_id=? AND o.side=? "
                            f"AND o.status='open' ORDER BY {order}, o.created_at LIMIT ?",
                            (item_id, side, limit)).fetchall()
        return [{"id": r[0], "price": r[1], "qty": r[2], "isMine": r[3] == hid, "expiresAt": r[4],
                 "name": r[5]} for r in rows]

    def parse_order(form):
        item_id = int_arg(form, "itemID", None, 1)
        qty = int_arg(form, "qty", None, 0, int(MAX_QTY))     # whole units only
        if qty <= 0:
            raise econ.GameError("bad_input", "Quantity must be positive")
        return item_id, qty

    def check_bid(conn, hid, item_id, price):
        top = conn.execute("SELECT * FROM mkt_orders WHERE item_id=? AND side='buy' AND status='open' AND hid<>? "
                           "ORDER BY price DESC, created_at LIMIT 1", (item_id, hid)).fetchone()
        if top and price > top["price"] * MAX_BID_OVER_TOP + 1e-9:
            raise econ.GameError("price_too_high",
                                 f"Bid at most 25% above the best bid ({top['price'] * MAX_BID_OVER_TOP:.2f})")
        sp = prices.get(item_id)
        if sp and price > sp * SYSTEM_BUY_MARKUP:
            raise econ.GameError("price_too_high", "Buying from the system is cheaper")

    # ── read endpoints ──────────────────────────────────────────────────────

    @api.endpoint("/api/v1/market/overview", feature="MARKET_V2")
    def overview(conn, hid, form):
        with econ.tx(conn):
            expire(conn)
        items = {}
        for iid, p in prices.items():
            items[iid] = {"itemID": iid, "systemSell": p, "systemBuy": round(p * SYSTEM_BUY_MARKUP, 2)}
        for r in conn.execute("SELECT item_id, side, MAX(price), MIN(price), SUM(qty_open) FROM mkt_orders "
                              "WHERE status='open' GROUP BY item_id, side"):
            e = items.setdefault(r[0], {"itemID": r[0], "systemSell": None, "systemBuy": None})
            if r[1] == "buy":
                e["bestBid"], e["bidQty"] = r[2], r[4]
            else:
                e["bestAsk"], e["askQty"] = r[3], r[4]
        mine = {r[0]: r[1] for r in conn.execute("SELECT item_id, qty FROM warehouse WHERE hid=? AND qty > 0", (hid,))}
        for iid, q in mine.items():
            if iid in RESTRICTED or iid in LUXURY_ITEMS or iid in ARTIFACTS or iid in h.SPECIAL_BUILDINGS:
                continue
            items.setdefault(iid, {"itemID": iid, "systemSell": None, "systemBuy": None})
        for iid, e in items.items():
            e["owned"] = mine.get(iid, 0)
        return {"err": 0, "items": sorted(items.values(), key=lambda e: e["itemID"]),
                "taxRate": my_tax(conn, hid), "orderDays": ORDER_DAYS}

    @api.endpoint("/api/v1/market/book", feature="MARKET_V2")
    def book(conn, hid, form):
        item_id = int_arg(form, "itemID", None, 1)
        p = prices.get(item_id)
        mine = conn.execute("SELECT * FROM mkt_orders WHERE hid=? AND item_id=? AND side='buy' AND status='open'",
                            (hid, item_id)).fetchone()
        return {"err": 0, "itemID": item_id, "bids": book_side(conn, hid, item_id, "buy", limit=50),
                "systemSell": p, "systemBuy": round(p * SYSTEM_BUY_MARKUP, 2) if p else None,
                "owned": econ.qty_of(conn, hid, item_id), "taxRate": my_tax(conn, hid),
                "credits": econ.credits_of(conn, hid), "freeSpace": int(econ.free_space(conn, hid)),
                "myOrder": None if not mine else {"id": mine["id"], "price": mine["price"], "qty": int(mine["qty_open"]),
                                                  "escrow": round(mine["escrow"]), "expiresAt": mine["expires_at"]}}

    @api.endpoint("/api/v1/market/mine", feature="MARKET_V2")
    def my_orders(conn, hid, form):
        rows = conn.execute("SELECT * FROM mkt_orders WHERE hid=? AND status='open' ORDER BY created_at DESC",
                            (hid,)).fetchall()
        return {"err": 0, "orders": [{
            "id": o["id"], "side": o["side"], "itemID": o["item_id"], "price": o["price"],
            "qtyTotal": o["qty_total"], "qtyOpen": o["qty_open"], "escrow": round(o["escrow"]),
            "taxRate": o["tax_rate"], "expiresAt": o["expires_at"]} for o in rows]}

    @api.endpoint("/api/v1/market/history", feature="MARKET_V2")
    def history(conn, hid, form):
        rows = conn.execute("SELECT * FROM mkt_trades WHERE buyer_hid=? OR seller_hid=? ORDER BY id DESC LIMIT 100",
                            (hid, hid)).fetchall()
        out = []
        for t in rows:
            bought = t["buyer_hid"] == hid
            out.append({"ts": t["ts"], "kind": t["kind"], "itemID": t["item_id"], "qty": t["qty"],
                        "price": t["price"], "side": "buy" if bought else "sell",
                        "tax": t["tax"] if t["tax_payer"] == hid else 0})
        return {"err": 0, "trades": out}

    @api.endpoint("/api/v1/market/quote", feature="MARKET_V2")
    def quote(conn, hid, form):
        """Preview of costs/proceeds and tax for any market action (nothing is changed)."""
        action = form.get("action", "")
        item_id, qty = parse_order(form)
        rate = my_tax(conn, hid)
        p = prices.get(item_id)
        if action == "system_sell":
            if not p:
                raise econ.GameError("no_price", "The system doesn't buy this item")
            return {"err": 0, "value": round(qty * p), "tax": 0, "total": round(qty * p)}
        if action == "system_buy":
            if not p:
                raise econ.GameError("no_price", "The system doesn't sell this item")
            v = round(qty * p * SYSTEM_BUY_MARKUP)
            tax = round(v * rate)
            return {"err": 0, "value": v, "tax": tax, "total": v + tax, "taxRate": rate}
        price = float_arg(form, "price", None, 0)
        value = round(qty * price)
        if action == "buy_order":    # up-front: value + tax (tax refunded for any unfilled part)
            tax = round(value * rate)
            return {"err": 0, "value": value, "tax": tax, "total": value + tax, "taxRate": rate}
        if action == "sell_order":   # proceeds after tax when it fills as a resting order
            tax = round(value * rate)
            return {"err": 0, "value": value, "tax": tax, "total": value - tax, "taxRate": rate}
        raise econ.GameError("bad_input", "Unknown action")

    # ── write endpoints ─────────────────────────────────────────────────────

    def idempotent(conn, hid, form, scope, fn):
        rid = (form.get("rid") or "").strip()[:64]
        with econ.tx(conn):
            if rid:
                prev = econ.once_get(conn, scope, hid, rid)
                if prev is not None:
                    return prev
            expire(conn)
            out = fn()
            if rid:
                econ.once_put(conn, scope, hid, rid, out)
            return out

    @api.endpoint("/api/v1/market/system", feature="MARKET_V2")
    def system_trade(conn, hid, form):
        """side=sell: sell to the system at 100%. side=buy: buy from the system at 150%."""
        side = form.get("side", "")
        item_id, qty = parse_order(form)
        if not (side == "buy" and item_id in getattr(h, "SYSTEM_ONLY_BUY", ())):
            check_tradeable(item_id)
        p = prices.get(item_id)
        if not p:
            raise econ.GameError("no_price", "The system doesn't trade this item")

        def run():
            if side == "sell":
                value = round(qty * p)
                econ.take(conn, hid, item_id, qty, "system_sell")
                econ.credit(conn, hid, value, "system_sell")
                record(conn, "system_sell", item_id, qty, p, None, hid)
                return {"err": 0, "qty": qty, "credits": value}
            if side == "buy":       # 150 % of the system price + your transport tax (owner's rule)
                value = round(qty * p * SYSTEM_BUY_MARKUP)
                tax = round(value * my_tax(conn, hid))
                econ.debit(conn, hid, value + tax, "system_buy")
                econ.give(conn, hid, item_id, qty, "system_buy")
                h.award_xp(conn, hid, int(value))
                record(conn, "system_buy", item_id, qty, p * SYSTEM_BUY_MARKUP, hid, None, tax, hid)
                return {"err": 0, "qty": qty, "cost": value + tax, "tax": tax}
            raise econ.GameError("bad_input", "side must be buy or sell")
        return idempotent(conn, hid, form, "market_system", run)

    @api.endpoint("/api/v1/market/order", feature="MARKET_V2")
    def place_order(conn, hid, form):
        """Place a buy order (the only kind of player order). Credits (price × qty + your tax) are
        held until it fills, is edited, cancelled or expires. One open order per item."""
        if form.get("side", "buy") != "buy":
            raise econ.GameError("bad_input", "Only buy orders can be placed — sell by filling a buy order")
        item_id, qty = parse_order(form)
        check_tradeable(item_id)
        price = round(float_arg(form, "price", None, 0.01, 1e12), 2)

        def run():
            if conn.execute("SELECT 1 FROM mkt_orders WHERE hid=? AND item_id=? AND side='buy' AND status='open'",
                            (hid, item_id)).fetchone():
                raise econ.GameError("duplicate", "You already have a buy order for this item — edit or cancel it")
            check_bid(conn, hid, item_id, price)
            if econ.free_space(conn, hid) < qty:
                raise econ.GameError("warehouse_full", "Not enough warehouse space for this order")
            rate = my_tax(conn, hid)
            value = round(qty * price)
            escrow = value + round(value * rate)
            order_id = uuid.uuid4().hex
            econ.debit(conn, hid, escrow, "market_order_escrow", order_id)
            now = econ.utcnow()
            conn.execute("INSERT INTO mkt_orders(id, hid, side, item_id, price, qty_total, qty_open, escrow, "
                         "tax_rate, status, created_at, expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                         (order_id, hid, "buy", item_id, price, qty, qty, escrow, rate, "open", now.isoformat(),
                          (now + datetime.timedelta(days=ORDER_DAYS)).isoformat()))
            return {"err": 0, "orderID": order_id, "escrow": escrow, "tax": escrow - value}
        return idempotent(conn, hid, form, "market_order", run)

    @api.endpoint("/api/v1/market/edit", feature="MARKET_V2")
    def edit_order(conn, hid, form):
        """Change price and/or quantity of your buy order. A new price gets a new time priority."""
        order_id = (form.get("orderID") or "").strip()
        qty = int_arg(form, "qty", None, 1, int(MAX_QTY))
        price = round(float_arg(form, "price", None, 0.01, 1e12), 2)

        def run():
            o = conn.execute("SELECT * FROM mkt_orders WHERE id=? AND hid=? AND status='open' AND side='buy'",
                             (order_id, hid)).fetchone()
            if not o:
                raise econ.GameError("gone", "Order not found or already closed")
            check_tradeable(o["item_id"])
            check_bid(conn, hid, o["item_id"], price)
            econ.credit(conn, hid, o["escrow"], "market_edit_refund", o["id"])
            if econ.free_space(conn, hid) < qty:
                raise econ.GameError("warehouse_full", "Not enough warehouse space for this order")
            rate = my_tax(conn, hid)
            value = round(qty * price)
            escrow = value + round(value * rate)
            econ.debit(conn, hid, escrow, "market_order_escrow", o["id"])
            now = econ.utcnow()
            created = o["created_at"] if abs(price - o["price"]) < 1e-9 else now.isoformat()
            conn.execute("UPDATE mkt_orders SET price=?, qty_total=?, qty_open=?, escrow=?, tax_rate=?, created_at=?, "
                         "expires_at=? WHERE id=?", (price, qty, qty, escrow, rate, created,
                                                     (now + datetime.timedelta(days=ORDER_DAYS)).isoformat(), o["id"]))
            return {"err": 0, "orderID": o["id"], "escrow": escrow, "tax": escrow - value}
        return idempotent(conn, hid, form, "market_edit", run)

    @api.endpoint("/api/v1/market/take", feature="MARKET_V2")
    def take_order(conn, hid, form):
        """Fill a specific resting order (sell into a buy order, or buy from a sell order)."""
        order_id = (form.get("orderID") or "").strip()
        qty = int_arg(form, "qty", None, 0, int(MAX_QTY))

        def run():
            o = conn.execute("SELECT * FROM mkt_orders WHERE id=? AND status='open'", (order_id,)).fetchone()
            if not o:
                raise econ.GameError("gone", "This order is no longer available")
            if o["hid"] == hid:
                raise econ.GameError("own_order", "You can't fill your own order")
            q = min(qty, o["qty_open"])
            if q <= 0:
                raise econ.GameError("bad_input", "Quantity must be positive")
            fill = fill_resting_buy(conn, o, hid, q) if o["side"] == "buy" else fill_resting_sell(conn, o, hid, q)
            return {"err": 0, **fill}
        return idempotent(conn, hid, form, "market_take", run)

    @api.endpoint("/api/v1/market/cancel", feature="MARKET_V2")
    def cancel(conn, hid, form):
        order_id = (form.get("orderID") or "").strip()
        with econ.tx(conn):
            o = conn.execute("SELECT * FROM mkt_orders WHERE id=? AND hid=? AND status='open'",
                             (order_id, hid)).fetchone()
            if not o:
                raise econ.GameError("gone", "Order not found or already closed")
            refund = round(o["escrow"]) if o["side"] == "buy" else o["qty_open"]
            close_order(conn, o, "cancelled")
        return {"err": 0, "side": o["side"], "refunded": refund}

    # sell orders no longer exist (owner's rule): return the items of any still open
    with h.get_db() as conn:
        for o in conn.execute("SELECT * FROM mkt_orders WHERE side='sell' AND status='open'").fetchall():
            with econ.tx(conn):
                close_order(conn, o, "cancelled")
