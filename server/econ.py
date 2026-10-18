"""Shared foundations for game systems.

Every money/item movement in new systems goes through these helpers so that it is:
- atomic: run inside `tx(conn)` (BEGIN IMMEDIATE … COMMIT, rollback on any error);
- non-negative: debits are conditional UPDATEs that fail instead of going below zero;
- audited: each movement is written to the `ledger` table;
- idempotent where needed: `once(conn, scope, hid, key)` returns the stored result of a
  previous identical request (reward claims, retries after reconnects).

Also: game events (source for News and statistics), feature flags, a small rate limiter and
geographic range checks.
"""
from __future__ import annotations

import contextlib
import datetime
import json
import math
import os
import threading
import time

# Warehouse capacity for a player row; main.py installs the real rule at startup.
_capacity_fn = lambda player_row: float("inf")  # noqa: E731
# Items that are not warehouse goods (special buildings) — set by main.py.
NON_WAREHOUSE_ITEMS: set = set()


class GameError(Exception):
    """A rule violation that is reported to the client (not a server bug)."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message

    def resp(self) -> dict:
        return {"err": 1, "code": self.code, "msg": self.message}


def utcnow() -> datetime.datetime:
    return datetime.datetime.utcnow()


def utcnow_iso() -> str:
    return utcnow().isoformat()


# ── schema ───────────────────────────────────────────────────────────────────

def init(conn, capacity_fn=None, non_warehouse_items=None) -> None:
    global _capacity_fn
    if capacity_fn:
        _capacity_fn = capacity_fn
    if non_warehouse_items is not None:
        NON_WAREHOUSE_ITEMS.clear()
        NON_WAREHOUSE_ITEMS.update(non_warehouse_items)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS ledger (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            ts       TEXT NOT NULL,
            hid      TEXT NOT NULL,
            kind     TEXT NOT NULL,          -- e.g. market_sell, quest_reward
            credits  REAL NOT NULL DEFAULT 0, -- +in / -out
            item_id  INTEGER,
            qty      REAL NOT NULL DEFAULT 0,
            ref      TEXT                     -- order id, quest id, ...
        );
        CREATE INDEX IF NOT EXISTS idx_ledger_hid_ts ON ledger(hid, ts);
        CREATE TABLE IF NOT EXISTS idempotency (
            scope  TEXT NOT NULL,
            hid    TEXT NOT NULL,
            key    TEXT NOT NULL,
            result TEXT NOT NULL,
            ts     TEXT NOT NULL,
            PRIMARY KEY (scope, hid, key)
        );
        CREATE TABLE IF NOT EXISTS game_events (
            id     INTEGER PRIMARY KEY AUTOINCREMENT,
            ts     TEXT NOT NULL,
            type   TEXT NOT NULL,
            hid    TEXT,
            public INTEGER NOT NULL DEFAULT 1,
            lat    REAL,
            lng    REAL,
            data   TEXT NOT NULL DEFAULT '{}',
            dedup  TEXT UNIQUE
        );
        CREATE INDEX IF NOT EXISTS idx_events_ts ON game_events(ts);
        CREATE INDEX IF NOT EXISTS idx_events_hid_type ON game_events(hid, type, ts);
        CREATE TABLE IF NOT EXISTS scheduler (
            name     TEXT PRIMARY KEY,
            last_run TEXT,
            state    TEXT NOT NULL DEFAULT '{}'
        );
    """)
    conn.commit()


# ── transactions ─────────────────────────────────────────────────────────────

@contextlib.contextmanager
def tx(conn):
    """Exclusive write transaction. Other writers wait (connection timeout) instead of
    interleaving, so read-check-write sequences inside are safe across threads/processes."""
    if conn.in_transaction:
        conn.commit()
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
        conn.commit()
    except BaseException:
        conn.rollback()
        raise


def _ledger(conn, hid, kind, credits=0.0, item_id=None, qty=0.0, ref=None):
    conn.execute("INSERT INTO ledger(ts, hid, kind, credits, item_id, qty, ref) VALUES(?,?,?,?,?,?,?)",
                 (utcnow_iso(), hid, kind, credits, item_id, qty, ref))


# ── credits ──────────────────────────────────────────────────────────────────

def credits_of(conn, hid) -> float:
    r = conn.execute("SELECT credits FROM players WHERE hID=?", (hid,)).fetchone()
    if not r:
        raise GameError("no_player", "Player not found")
    return float(r[0] or 0)


def debit(conn, hid, amount, kind, ref=None) -> None:
    """Take credits; fails (GameError) instead of going negative."""
    amount = round(float(amount))
    if amount < 0:
        raise ValueError("negative debit")
    if amount == 0:
        return
    cur = conn.execute("UPDATE players SET credits = credits - ? WHERE hID=? AND credits >= ?",
                       (amount, hid, amount))
    if cur.rowcount != 1:
        raise GameError("insufficient_credits", "Not enough credits")
    _ledger(conn, hid, kind, credits=-amount, ref=ref)


def credit(conn, hid, amount, kind, ref=None) -> None:
    amount = round(float(amount))
    if amount < 0:
        raise ValueError("negative credit")
    if amount == 0:
        return
    cur = conn.execute("UPDATE players SET credits = credits + ? WHERE hID=?", (amount, hid))
    if cur.rowcount != 1:
        raise GameError("no_player", "Player not found")
    _ledger(conn, hid, kind, credits=amount, ref=ref)


# ── items (warehouse) ────────────────────────────────────────────────────────

def qty_of(conn, hid, item_id) -> float:
    r = conn.execute("SELECT qty FROM warehouse WHERE hid=? AND item_id=?", (hid, item_id)).fetchone()
    return float(r[0]) if r else 0.0


def free_space(conn, hid) -> float:
    p = conn.execute("SELECT * FROM players WHERE hID=?", (hid,)).fetchone()
    if not p:
        raise GameError("no_player", "Player not found")
    used = conn.execute("SELECT COALESCE(SUM(qty),0) FROM warehouse WHERE hid=?", (hid,)).fetchone()[0]
    return max(0.0, _capacity_fn(p) - float(used))


def take(conn, hid, item_id, qty, kind, ref=None) -> None:
    """Remove items; fails instead of going negative."""
    qty = float(qty)
    if qty < 0:
        raise ValueError("negative take")
    if qty == 0:
        return
    cur = conn.execute("UPDATE warehouse SET qty = qty - ? WHERE hid=? AND item_id=? AND qty >= ? - 1e-9",
                       (qty, hid, item_id, qty))
    if cur.rowcount != 1:
        raise GameError("insufficient_items", "Not enough items")
    conn.execute("UPDATE warehouse SET qty = 0 WHERE hid=? AND item_id=? AND qty < 0", (hid, item_id))
    _ledger(conn, hid, kind, item_id=item_id, qty=-qty, ref=ref)


def give(conn, hid, item_id, qty, kind, ref=None, *, strict=True, ignore_capacity=False) -> float:
    """Add items. strict=True: fail if the warehouse can't hold all of it (purchases, transfers).
    strict=False: add what fits and return the amount added (rewards, like production).
    ignore_capacity=True: always add everything — only for returning the player's own escrowed
    items or completing a purchase they already paid for, so nothing is ever lost."""
    qty = float(qty)
    if qty < 0:
        raise ValueError("negative give")
    if qty == 0:
        return 0.0
    if item_id in NON_WAREHOUSE_ITEMS:
        raise GameError("not_storable", "This item can't be stored in the warehouse")
    if not ignore_capacity:
        space = free_space(conn, hid)
        if qty > space + 1e-9:
            if strict:
                raise GameError("warehouse_full", "Not enough warehouse space")
            qty = space
            if qty <= 0:
                return 0.0
    conn.execute("INSERT INTO warehouse(hid,item_id,qty) VALUES(?,?,?) "
                 "ON CONFLICT(hid,item_id) DO UPDATE SET qty = qty + excluded.qty", (hid, item_id, qty))
    _ledger(conn, hid, kind, item_id=item_id, qty=qty, ref=ref)
    return qty


# ── idempotency ──────────────────────────────────────────────────────────────

def once_get(conn, scope, hid, key):
    """Stored result of an earlier request with the same (scope, player, key), or None."""
    r = conn.execute("SELECT result FROM idempotency WHERE scope=? AND hid=? AND key=?",
                     (scope, hid, key)).fetchone()
    return json.loads(r[0]) if r else None


def once_put(conn, scope, hid, key, result) -> None:
    conn.execute("INSERT INTO idempotency(scope, hid, key, result, ts) VALUES(?,?,?,?,?)",
                 (scope, hid, key, json.dumps(result), utcnow_iso()))


# ── events (news / stats / audit) ────────────────────────────────────────────

def emit(conn, type_, hid=None, data=None, *, public=True, lat=None, lng=None, dedup=None) -> None:
    """Record a game event. `dedup` makes the event unique (second emit is ignored)."""
    conn.execute("INSERT OR IGNORE INTO game_events(ts, type, hid, public, lat, lng, data, dedup) "
                 "VALUES(?,?,?,?,?,?,?,?)",
                 (utcnow_iso(), type_, hid, 1 if public else 0, lat, lng,
                  json.dumps(data or {}, ensure_ascii=False), dedup))


def count_events(conn, hid, type_, since_iso) -> int:
    return conn.execute("SELECT COUNT(*) FROM game_events WHERE hid=? AND type=? AND ts>=?",
                        (hid, type_, since_iso)).fetchone()[0]


# ── feature flags ────────────────────────────────────────────────────────────

# Systems that are complete and tested default to on; set FEATURE_<NAME>=0 to switch off.
DEFAULT_FEATURES = {
    "SOCIAL": True, "MARKET_V2": True, "QUESTS": True, "CARGO": True, "ARCHAEOLOGY": True,
    "COMBAT": True, "LOANS": True, "AUCTIONS": True, "NEWS": True, "EARTHQUAKES": True,
    # Ratios not defined by the sources — off until the owner decides (systems/cargo.py RECYCLE).
    "RECYCLING": False,
}


def feature(name: str) -> bool:
    v = os.environ.get(f"FEATURE_{name}")
    if v is None:
        return DEFAULT_FEATURES.get(name, False)
    return v.strip().lower() in ("1", "true", "on", "yes")


# ── rate limiting ────────────────────────────────────────────────────────────

class RateLimit:
    """At most `n` actions per `window` seconds per key (in-process)."""

    def __init__(self, n: int, window: float):
        self.n, self.window = n, window
        self._hits: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.time()
        with self._lock:
            hits = [t for t in self._hits.get(key, []) if now - t < self.window]
            if len(hits) >= self.n:
                self._hits[key] = hits
                return False
            hits.append(now)
            self._hits[key] = hits
            return True


# ── geography ────────────────────────────────────────────────────────────────

def dist_m(lat1, lng1, lat2, lng2) -> float:
    p = math.pi / 180
    a = (math.sin((lat2 - lat1) * p / 2) ** 2 +
         math.cos(lat1 * p) * math.cos(lat2 * p) * math.sin((lng2 - lng1) * p / 2) ** 2)
    return 2 * 6371000 * math.asin(math.sqrt(min(1.0, a)))


def bbox(lat, lng, radius_m):
    dlat = radius_m / 111320.0
    dlng = dlat / max(0.01, math.cos(math.radians(lat)))
    return lat - dlat, lat + dlat, lng - dlng, lng + dlng


def require_within(lat1, lng1, lat2, lng2, radius_m, what="target") -> None:
    if dist_m(lat1, lng1, lat2, lng2) > radius_m + 1e-6:
        raise GameError("out_of_range", f"The {what} is out of range ({int(radius_m)} m)")


def parse_pos(form, prefix=""):
    try:
        lat = float(form.get(prefix + "lat"))
        lng = float(form.get(prefix + "lng"))
    except (TypeError, ValueError):
        raise GameError("bad_position", "Position missing or invalid")
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        raise GameError("bad_position", "Position out of bounds")
    return lat, lng


# ── scheduling ───────────────────────────────────────────────────────────────

def due(conn, name, interval_s) -> bool:
    """True (and marks the run) if `name` hasn't run within interval_s. Call inside tx()."""
    r = conn.execute("SELECT last_run FROM scheduler WHERE name=?", (name,)).fetchone()
    now = utcnow()
    if r and r[0]:
        try:
            if (now - datetime.datetime.fromisoformat(r[0])).total_seconds() < interval_s:
                return False
        except ValueError:
            pass
    conn.execute("INSERT INTO scheduler(name, last_run) VALUES(?,?) "
                 "ON CONFLICT(name) DO UPDATE SET last_run=excluded.last_run", (name, now.isoformat()))
    return True
