"""Account: name change and GDPR deletion (owner 2026-10-23).

Name change: the first one is free, then 10 Giant Diamonds, +10 for every further change
(10, 20, 30 …). The new name must pass names.name_problem (no rude or misleading names; such
accounts can be banned or deleted).

Deletion (GDPR): accounts up to DELAY_AFTER_DAYS old are deleted at once; older accounts are deleted
after DELAY_DAYS, and signing in during that time cancels the deletion. Deleting removes the
company (mines, HQ, warehouse, buildings, orders, messages, contacts …) and frees the name; other
players' history keeps the rows without the player's id.
"""
from __future__ import annotations

import datetime

import econ
import names

GIANT_DIAMOND = 42
RENAME_STEP_GD = 10
DELAY_AFTER_DAYS = 30
DELAY_DAYS = 30
SWEEP_S = 3600
# tables whose rows are someone else's history: the player's id is blanked instead of deleting the row
KEEP_ROWS = {("mkt_trades", "buyer_hid"), ("mkt_trades", "seller_hid"), ("mkt_trades", "tax_payer"),
             ("attacks", "attacker_hid"), ("attacks", "defender_hid"), ("external_repairs", "helper_hid"),
             ("external_repairs", "owner_hid"), ("loans", "lender"), ("auction_bids", "hid")}
ID_COLUMNS = {"hid", "hID", "owner_hid", "borrower", "lender", "dropper_hid", "from_hid", "to_hid", "target_hid",
              "buyer_hid", "seller_hid", "tax_payer", "attacker_hid", "defender_hid", "helper_hid", "spinner",
              "collected_by", "winner_hid", "leader_hid"}


def rename_cost(changes: int) -> int:
    return RENAME_STEP_GD * max(0, int(changes or 0))


def purge(conn, hid: str) -> int:
    """Delete a company everywhere (inside a tx). Returns the number of rows touched."""
    n = 0
    tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    for t in tables:
        if t == "players":
            continue
        cols = [r[1] for r in conn.execute(f'PRAGMA table_info("{t}")')]
        for c in cols:
            if c not in ID_COLUMNS:
                continue
            if (t, c) in KEEP_ROWS:
                try:
                    n += conn.execute(f'UPDATE "{t}" SET "{c}"=NULL WHERE "{c}"=?', (hid,)).rowcount
                    continue
                except Exception:
                    pass
            n += conn.execute(f'DELETE FROM "{t}" WHERE "{c}"=?', (hid,)).rowcount
    # open loans of a deleted borrower are forgiven (lenders see why), requests withdrawn
    n += conn.execute("DELETE FROM players WHERE hID=?", (hid,)).rowcount
    return n


def install(api) -> None:
    h = api.h

    def sweep(conn) -> None:
        if not econ.due(conn, "account_deletions", SWEEP_S):
            return
        now = econ.utcnow_iso()
        for r in conn.execute("SELECT hID FROM players WHERE delete_at IS NOT NULL AND delete_at <= ?", (now,)).fetchall():
            purge(conn, r[0])

    h.ACCOUNT_SWEEP = sweep

    @api.endpoint("/api/v1/account/info")
    def info(conn, hid, form):
        p = conn.execute("SELECT company_name, created_at, name_changes, delete_at FROM players WHERE hID=?",
                         (hid,)).fetchone()
        try:
            age = (econ.utcnow() - datetime.datetime.fromisoformat(p["created_at"])).days
        except (TypeError, ValueError):
            age = 0
        return {"err": 0, "name": p["company_name"], "ageDays": age, "nameChanges": int(p["name_changes"] or 0),
                "renameCostGD": rename_cost(p["name_changes"]), "giantDiamonds": int(econ.qty_of(conn, hid, GIANT_DIAMOND)),
                "deleteAt": p["delete_at"], "deletionDelayed": age > DELAY_AFTER_DAYS, "delayDays": DELAY_DAYS,
                "rules": "3-20 letters, digits, spaces and . , [ ] ( ) -. Rude or misleading names are not accepted; "
                         "accounts with such names can be banned or deleted."}

    @api.endpoint("/api/v1/account/rename")
    def rename(conn, hid, form):
        new = (form.get("name") or "").strip()
        problem = names.name_problem(new)
        if problem:
            raise econ.GameError("invalid_name", problem)
        canon = h.norm_name(new)
        with econ.tx(conn):
            p = conn.execute("SELECT company_name, name_changes FROM players WHERE hID=?", (hid,)).fetchone()
            if canon == p["company_name"]:
                raise econ.GameError("same_name", "That is already your name")
            if conn.execute("SELECT 1 FROM players WHERE company_name=?", (canon,)).fetchone():
                raise econ.GameError("name_taken", "That company name is taken")
            cost = rename_cost(p["name_changes"])
            if cost:
                try:
                    econ.take(conn, hid, GIANT_DIAMOND, cost, "rename")
                except econ.GameError:
                    raise econ.GameError("insufficient_items", f"A name change costs {cost} Giant Diamonds")
            conn.execute("UPDATE players SET company_name=?, name_changes=COALESCE(name_changes,0)+1 WHERE hID=?",
                         (canon, hid))
            h.add_proto(conn, hid, "rename", {"from": p["company_name"], "to": canon, "costGD": cost})
        return {"err": 0, "name": canon, "costGD": cost, "nextCostGD": rename_cost((p["name_changes"] or 0) + 1)}

    @api.endpoint("/api/v1/account/delete")
    def delete(conn, hid, form):
        """confirm=DELETE. Young accounts go at once; older ones in DELAY_DAYS (signing in cancels)."""
        if form.get("confirm") != "DELETE":
            raise econ.GameError("bad_input", "Confirmation missing")
        with econ.tx(conn):
            p = conn.execute("SELECT created_at FROM players WHERE hID=?", (hid,)).fetchone()
            try:
                age = (econ.utcnow() - datetime.datetime.fromisoformat(p["created_at"])).days
            except (TypeError, ValueError):
                age = 0
            if age <= DELAY_AFTER_DAYS:
                purge(conn, hid)
                return {"err": 0, "deleted": True}
            at = (econ.utcnow() + datetime.timedelta(days=DELAY_DAYS)).isoformat()
            conn.execute("UPDATE players SET delete_at=? WHERE hID=?", (at, hid))
        return {"err": 0, "deleted": False, "deleteAt": at}

    @api.endpoint("/api/v1/account/cancel_delete")
    def cancel_delete(conn, hid, form):
        with econ.tx(conn):
            conn.execute("UPDATE players SET delete_at=NULL WHERE hID=?", (hid,))
        return {"err": 0}
