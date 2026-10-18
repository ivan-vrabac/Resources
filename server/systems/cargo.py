"""Phase 4 — Cargo Rain (crates & containers).

Players collect Cargo Rain crates as rewards (30 per level up, 15 per daily quest — eva.txt) and
drop them on the map within their local range; dropped crates can be picked up by players who are
in range. Loot comes from the found-objects table in sfo.txt (drop chance, museum level).
"""
from __future__ import annotations

import econ

CARGO_ITEM = 0          # ledger item id used for Cargo Rain crates (not a warehouse item)
LEVEL_UP_CRATES = 30    # eva.txt: 30 C&C per level up
QUEST_CRATES = 15       # eva.txt: 15 C&C per mission


def ensure_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS cargo_stock (
            hid    TEXT PRIMARY KEY,
            crates INTEGER NOT NULL DEFAULT 0 CHECK (crates >= 0)
        );
    """)


def stock(conn, hid) -> int:
    r = conn.execute("SELECT crates FROM cargo_stock WHERE hid=?", (hid,)).fetchone()
    return int(r[0]) if r else 0


def grant(conn, hid, n: int, source: str) -> None:
    """Add n Cargo Rain crates to a player's stock (inside the caller's transaction)."""
    n = int(n)
    if n <= 0:
        return
    conn.execute("INSERT INTO cargo_stock(hid, crates) VALUES(?,?) "
                 "ON CONFLICT(hid) DO UPDATE SET crates = crates + excluded.crates", (hid, n))
    econ._ledger(conn, hid, f"cargo_{source}", item_id=CARGO_ITEM, qty=n)


def spend(conn, hid, n: int, source: str) -> None:
    n = int(n)
    cur = conn.execute("UPDATE cargo_stock SET crates = crates - ? WHERE hid=? AND crates >= ?", (n, hid, n))
    if cur.rowcount != 1:
        raise econ.GameError("no_cargo", "Not enough Cargo Rain")
    econ._ledger(conn, hid, f"cargo_{source}", item_id=CARGO_ITEM, qty=-n)


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        ensure_schema(conn)
        conn.commit()

    def on_level_up(conn, hid, old_level, new_level):
        ensure_schema(conn)
        grant(conn, hid, LEVEL_UP_CRATES * (new_level - old_level), "level_up")
        econ.emit(conn, "level_up", hid, {"from": old_level, "to": new_level},
                  dedup=f"level_up:{hid}:{new_level}")

    if on_level_up not in h.LEVEL_UP_HOOKS:
        h.LEVEL_UP_HOOKS.append(on_level_up)

    @api.endpoint("/api/v1/cargo/stock", feature="CARGO")
    def get_stock(conn, hid, form):
        return {"err": 0, "crates": stock(conn, hid)}
