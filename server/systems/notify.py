"""Push notifications per kind with on/off and a daily maximum (owner 2026-10-23).

Kinds: outbid, auction won, order fulfilled, factory finished, accident. Each player can switch a
kind off and choose how many per day (or unlimited, stored as 0). Defaults are chosen so nobody is
flooded: auctions are unlimited, the rest have a sensible cap. Sending happens on a background
thread with its own connection, so a slow push service never holds a game transaction.
"""
from __future__ import annotations

import datetime
import os
import threading
import time

import econ
from . import int_arg

KINDS = {
    # kind: (label, default max per day, 0 = unlimited)
    "outbid":       ("Outbid at an auction", 0),
    "auction_won":  ("Auction won", 1),
    "order_filled": ("Buy order fulfilled", 20),
    "factory_done": ("Factory production finished", 10),
    "accident":     ("Accidents (fire, strike, disease, earthquake)", 5),
    "mine_warning": ("Mine close to destruction", 1),
    "mine_destroyed": ("Mine destroyed", 1),
    "wh_almost":    ("Warehouse almost full (80 %)", 1),
    "wh_full":      ("Warehouse full", 1),
}
CHOICES = (1, 3, 5, 10, 20, 50, 0)


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS notif_kinds (
            hid      TEXT NOT NULL,
            kind     TEXT NOT NULL,
            enabled  INTEGER NOT NULL DEFAULT 1,
            max_day  INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (hid, kind)
        );
        CREATE TABLE IF NOT EXISTS notif_sent (
            hid   TEXT NOT NULL,
            kind  TEXT NOT NULL,
            day   TEXT NOT NULL,
            n     INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (hid, kind, day)
        );
    """)
    conn.commit()


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)
        try:
            conn.execute("ALTER TABLE factories ADD COLUMN notified_end TEXT")
            conn.commit()
        except Exception:
            pass

    def prefs(conn, hid) -> dict:
        got = {r[0]: (bool(r[1]), int(r[2])) for r in conn.execute(
            "SELECT kind, enabled, max_day FROM notif_kinds WHERE hid=?", (hid,))}
        return {k: got.get(k, (True, d)) for k, (_, d) in KINDS.items()}

    def _send(hid, kind, title, body) -> None:
        try:
            with h.get_db() as conn:
                g = conn.execute("SELECT enabled FROM notif_prefs WHERE hid=?", (hid,)).fetchone()
                if g is not None and not g[0]:
                    return                                  # all notifications off
                on, cap = prefs(conn, hid)[kind]
                if not on:
                    return
                day = econ.utcnow().strftime("%Y-%m-%d")
                with econ.tx(conn):
                    n = conn.execute("SELECT n FROM notif_sent WHERE hid=? AND kind=? AND day=?",
                                     (hid, kind, day)).fetchone()
                    if cap and n and n[0] >= cap:
                        return
                    conn.execute("INSERT INTO notif_sent(hid, kind, day, n) VALUES(?,?,?,1) ON CONFLICT(hid, kind, day) "
                                 "DO UPDATE SET n=n+1", (hid, kind, day))
                h.push(conn, hid, title, body)
        except Exception:
            pass

    def notify(hid, kind, title, body) -> None:
        """Queue a push of `kind` for `hid` (respects the player's settings and daily maximum)."""
        if kind not in KINDS or not hid:
            return
        threading.Thread(target=_send, args=(hid, kind, title, body), daemon=True).start()

    h.notify = notify

    def factory_watch() -> None:
        """Tell players when a factory production has finished (checked every minute)."""
        while True:
            try:
                with h.get_db() as conn:
                    now = econ.utcnow_iso()
                    rows = conn.execute("SELECT factory_id, hid, item_id, prod_end FROM factories WHERE prod_item IS NOT NULL "
                                        "AND prod_end <= ? AND (notified_end IS NULL OR notified_end <> prod_end)",
                                        (now,)).fetchall()
                    for r in rows:
                        conn.execute("UPDATE factories SET notified_end=? WHERE factory_id=?", (r[3], r[0]))
                    conn.commit()
                for r in rows:
                    name = h.FACTORY_TYPES.get(r[2], {}).get("name", "Your factory")
                    notify(r[1], "factory_done", "Production finished", f"{name} has finished. Collect it now.")
            except Exception:
                pass
            time.sleep(60)

    if os.environ.get("WORLD_EVENTS_THREAD", "1") != "0":
        threading.Thread(target=factory_watch, daemon=True, name="factory-watch").start()

    @api.endpoint("/api/v1/notify/prefs")
    def get_prefs(conn, hid, form):
        p = prefs(conn, hid)
        return {"err": 0, "choices": list(CHOICES),
                "kinds": [{"kind": k, "label": KINDS[k][0], "enabled": p[k][0], "maxPerDay": p[k][1],
                           "default": KINDS[k][1]} for k in KINDS]}

    @api.endpoint("/api/v1/notify/set")
    def set_pref(conn, hid, form):
        kind = (form.get("kind") or "").strip()
        if kind not in KINDS:
            raise econ.GameError("bad_input", "Unknown notification")
        enabled = 1 if form.get("enabled", "1") in ("1", "true") else 0
        mx = int_arg(form, "maxPerDay", KINDS[kind][1], 0, 1000)
        if mx not in CHOICES:
            raise econ.GameError("bad_input", "Choose one of the offered limits")
        with econ.tx(conn):
            conn.execute("INSERT INTO notif_kinds(hid, kind, enabled, max_day) VALUES(?,?,?,?) ON CONFLICT(hid, kind) "
                         "DO UPDATE SET enabled=excluded.enabled, max_day=excluded.max_day", (hid, kind, enabled, mx))
        return get_prefs(conn, hid, form)
