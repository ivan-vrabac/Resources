"""Working atmosphere (WA), accidents, penalties and strikes (owner's rules, 2026-10-23).

Working atmosphere 0–100 % per company:
- every factory that has been idle for more than 24 h costs 2 points per idle day;
- every claimed daily quest gives +WA_QUEST;
- every accident costs points (WA_HIT); a won attack −0.1, a lost attack −10 (systems/combat.py);
- a company without mines and factories always has 100 %.

Accidents happen per day (checked when the player is online, catching up at most CATCH_UP_DAYS):
the chance per factory (fire, strike) and per company (mine disease outbreak) is
  p(WA) = P_AT_100 + (P_AT_0 − P_AT_100) × (1 − WA/100)      (1 %/day at 100 %, 10 %/day at 0 %)
× the protective building (Fire Station, HR Department, Hospital).

Penalty of an accident (not shown to players — "a secret"): a share of the credits between 5 % (WA
100 %) and 50 % (WA 0 %) plus 5 % of the warehouse value at system prices, reduced by the Law Firm.
So keeping wealth in goods is safer than in cash. The balance may go negative (it shows red).

Strikes freeze a factory completely (no production, collection, upgrade or control) until the
player settles: pay the workers (cost cut by the Law Firm, WA +WA_PAY) or send security staff
(units consumed, WA −WA_FORCE). It stays frozen indefinitely otherwise.
"""
from __future__ import annotations

import datetime
import json
import random

import econ
import protection
from . import int_arg

HR_DEPARTMENT = 122
SECURITY_STAFF = 97
P_AT_100, P_AT_0 = 0.01, 0.10
CATCH_UP_DAYS = 7
IDLE_WA_PER_DAY = 2.0
WA_QUEST = 2.0
WA_HIT = {"fire": 5.0, "strike": 10.0, "disease": 3.0, "earthquake": 2.0}
WA_PAY, WA_FORCE = 5.0, 10.0
PENALTY_MIN, PENALTY_MAX, PENALTY_WAREHOUSE = 0.05, 0.50, 0.05
HR_PER_LEVEL = 0.07                 # strike chance −7 % per HR Department level
STRIKE_COST_SHARE = 0.10            # strike cost = 10 % of the factory's next upgrade (credits)
STRIKE_UNITS_PER_LEVEL = 2          # security staff needed = 2 × factory level


def accident_chance(wa: float) -> float:
    wa = max(0.0, min(100.0, float(wa)))
    return P_AT_100 + (P_AT_0 - P_AT_100) * (1 - wa / 100)


def hr_factor(level: int) -> float:
    return max(0.0, 1.0 - HR_PER_LEVEL * max(0, min(10, int(level or 0))))


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS incidents (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            ts       TEXT NOT NULL,
            hid      TEXT NOT NULL,
            kind     TEXT NOT NULL,        -- fire, strike, disease, earthquake, idle
            target   TEXT,
            penalty  INTEGER NOT NULL DEFAULT 0,
            wa_after REAL,
            data     TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS idx_incidents_hid ON incidents(hid, ts);
        CREATE TABLE IF NOT EXISTS incident_clock (
            hid      TEXT PRIMARY KEY,
            last_day TEXT NOT NULL
        );
    """)
    conn.commit()


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)

    def wa_of(conn, hid) -> float:
        r = conn.execute("SELECT wa FROM players WHERE hID=?", (hid,)).fetchone()
        return float(r[0]) if r and r[0] is not None else 80.0

    def warehouse_value(conn, hid) -> float:
        return sum(h.SYSTEM_PRICES.get(r[0], 0) * float(r[1] or 0)
                   for r in conn.execute("SELECT item_id, qty FROM warehouse WHERE hid=? AND qty>0", (hid,)))

    def penalty(conn, hid, kind, target=None, data=None) -> int:
        """Charge an accident penalty (may make the balance negative) and log it. Inside a tx."""
        wa = wa_of(conn, hid)
        cr = max(0.0, econ.credits_of(conn, hid))
        share = PENALTY_MIN + (PENALTY_MAX - PENALTY_MIN) * (1 - wa / 100)
        amount = (share * cr + PENALTY_WAREHOUSE * warehouse_value(conn, hid))
        amount *= protection.law_firm_factor(h.building_level(conn, hid, protection.LAW_FIRM))
        amount = int(round(amount))
        if amount > 0:   # unconditional: the balance may go below zero (owner's rule)
            conn.execute("UPDATE players SET credits = credits - ? WHERE hID=?", (amount, hid))
            econ._ledger(conn, hid, f"penalty_{kind}", credits=-amount, ref=target)
        new_wa = h.change_wa(conn, hid, -WA_HIT.get(kind, 3.0), kind)
        conn.execute("INSERT INTO incidents(ts, hid, kind, target, penalty, wa_after, data) VALUES(?,?,?,?,?,?,?)",
                     (econ.utcnow_iso(), hid, kind, target, amount, new_wa, json.dumps(data or {})))
        h.add_proto(conn, hid, "accident", {"kind": kind, "target": target, "penalty": amount, **(data or {})})
        return amount

    def one_day(conn, hid, day: datetime.date, rng: random.Random, pending: list) -> None:
        facs = conn.execute("SELECT * FROM factories WHERE hid=?", (hid,)).fetchall()
        mines = conn.execute("SELECT COUNT(*) FROM mines WHERE owner_hid=?", (hid,)).fetchone()[0]
        plain = [f for f in facs if f["item_id"] not in h.SPECIAL_BUILDINGS]
        if not plain and mines == 0:
            conn.execute("UPDATE players SET wa=100 WHERE hID=?", (hid,))
            return
        end_of_day = datetime.datetime.combine(day, datetime.time(23, 59, 59))
        # idle factories: −2 per factory idle for more than 24 h
        idle = 0
        for f in plain:
            last = f["last_active"] or f["prod_end"]
            try:
                idle_long = f["prod_item"] is None and last and \
                    end_of_day - datetime.datetime.fromisoformat(last) > datetime.timedelta(hours=24)
            except ValueError:
                idle_long = False
            if idle_long and not f["strike_at"]:
                idle += 1
        if idle:
            h.change_wa(conn, hid, -IDLE_WA_PER_DAY * idle, "idle")
        p = accident_chance(wa_of(conn, hid))
        fire_f = protection.fire_factor(h.building_level(conn, hid, protection.FIRE_STATION))
        strike_f = hr_factor(h.building_level(conn, hid, HR_DEPARTMENT))
        law = protection.law_firm_factor(h.building_level(conn, hid, protection.LAW_FIRM))
        station = h.building_level(conn, hid, protection.FIRE_STATION)
        for f in plain:
            if f["strike_at"]:
                continue
            if rng.random() < p * strike_f:
                up = h.economy.factory_upgrade(f["item_id"], max(1, f["level"]))["credits"]
                cost = max(10_000, int(up * STRIKE_COST_SHARE * law))
                conn.execute("UPDATE factories SET strike_at=?, strike_cost=? WHERE factory_id=?",
                             (econ.utcnow_iso(), cost, f["factory_id"]))
                penalty(conn, hid, "strike", f["factory_id"], {"itemID": f["item_id"]})
                pending.append(("Strike!", f"Workers at your {h.FACTORY_TYPES.get(f['item_id'], {}).get('name', 'factory')} "
                                           "went on strike. The factory is frozen until you settle it."))
            elif rng.random() < p * fire_f:
                until = (datetime.datetime.utcnow() + datetime.timedelta(
                    days=h.FIRE_DURATION_DAYS * protection.fire_duration_factor(station) * law)).isoformat()
                conn.execute("UPDATE factories SET fire_until=? WHERE factory_id=?", (until, f["factory_id"]))
                penalty(conn, hid, "fire", f["factory_id"], {"itemID": f["item_id"], "until": until})
        if mines and rng.random() < p * protection.disease_factor(h.building_level(conn, hid, protection.HOSPITAL)):
            now = datetime.datetime.utcnow()
            m = conn.execute("SELECT mine_id FROM mines WHERE owner_hid=? AND (sick_until IS NULL OR sick_until < ?) "
                             "ORDER BY RANDOM() LIMIT 1", (hid, now.isoformat())).fetchone()
            if m:
                until = (now + datetime.timedelta(days=h.DISEASE_DURATION_DAYS * law)).isoformat()
                conn.execute("UPDATE mines SET sick_until=? WHERE mine_id=?", (until, m[0]))
                penalty(conn, hid, "disease", m[0], {"until": until})

    def tick(conn, hid) -> list:
        """Run the days that passed since the last check (at most CATCH_UP_DAYS). Inside a tx.
        Returns push notifications [(title, body)] to send after the commit."""
        pending = []
        today = econ.utcnow().date()
        r = conn.execute("SELECT last_day FROM incident_clock WHERE hid=?", (hid,)).fetchone()
        if not r:
            conn.execute("INSERT INTO incident_clock(hid, last_day) VALUES(?,?)", (hid, today.isoformat()))
            return pending
        last = datetime.date.fromisoformat(r[0])
        if last >= today:
            return pending
        rng = random.Random()
        day = max(last + datetime.timedelta(days=1), today - datetime.timedelta(days=CATCH_UP_DAYS))
        while day <= today:
            one_day(conn, hid, day, rng, pending)
            day += datetime.timedelta(days=1)
        conn.execute("UPDATE incident_clock SET last_day=? WHERE hid=?", (today.isoformat(), hid))
        return pending

    h.EVENT_HOOKS.append(tick)
    h.PENALTY = penalty

    @api.endpoint("/api/v1/strike/settle")
    def settle(conn, hid, form):
        """how=pay (credits, WA up) or how=force (security staff, WA down)."""
        fid = (form.get("fID") or "").strip()
        how = form.get("how", "pay")
        with econ.tx(conn):
            f = conn.execute("SELECT * FROM factories WHERE factory_id=? AND hid=?", (fid, hid)).fetchone()
            if not f or not f["strike_at"]:
                raise econ.GameError("no_strike", "This factory isn't on strike")
            if how == "pay":
                cost = int(f["strike_cost"] or 10_000)
                econ.debit(conn, hid, cost, "strike_pay", fid)
                h.award_sink(conn, hid, credits=cost)
                wa = h.change_wa(conn, hid, WA_PAY, "strike_pay")
                out = {"paid": cost}
            elif how == "force":
                n = max(1, STRIKE_UNITS_PER_LEVEL * max(1, f["level"]))
                try:
                    econ.take(conn, hid, SECURITY_STAFF, n, "strike_force", fid)
                except econ.GameError:
                    raise econ.GameError("insufficient_items", f"You need {n} Security Staff")
                h.award_sink(conn, hid, res={SECURITY_STAFF: n})
                wa = h.change_wa(conn, hid, -WA_FORCE, "strike_force")
                out = {"units": n}
            else:
                raise econ.GameError("bad_input", "how must be pay or force")
            if conn.execute("UPDATE factories SET strike_at=NULL, strike_cost=NULL WHERE factory_id=? AND strike_at IS NOT NULL",
                            (fid,)).rowcount != 1:
                raise econ.GameError("no_strike", "This factory isn't on strike")
            h.add_proto(conn, hid, "strikesettled", {"fID": fid, "how": how, **out})
        return {"err": 0, "wa": wa, **out}

    @api.endpoint("/api/v1/incidents")
    def history(conn, hid, form):
        """Your recent accidents (kind, when, what) and the current WA. Penalty sizes are shown as
        amounts only, never the formula."""
        with econ.tx(conn):
            tick(conn, hid)
        rows = conn.execute("SELECT ts, kind, target, penalty, wa_after FROM incidents WHERE hid=? "
                            "ORDER BY id DESC LIMIT 50", (hid,)).fetchall()
        f = conn.execute("SELECT COUNT(*) FROM factories WHERE hid=? AND strike_at IS NOT NULL", (hid,)).fetchone()[0]
        return {"err": 0, "wa": wa_of(conn, hid), "strikes": f,
                "chancePerDay": round(accident_chance(wa_of(conn, hid)) * 100, 1),
                "incidents": [{"ts": r[0], "kind": r[1], "target": r[2], "penalty": r[3], "wa": r[4]} for r in rows]}
