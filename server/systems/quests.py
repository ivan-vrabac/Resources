"""Phase 3 — daily quests, streaks and their rewards.

Lifecycle (documented assumptions):
- Each UTC day a player gets DAILY_COUNT quests, picked deterministically from POOL by
  hash(player, day) when they first open the quest list that day.
- A quest is completed by doing the activity after it was assigned. Progress is counted from
  recorded game events (game_events), so it is server-side and survives restarts.
- A quest stays open for 48 hours. If it isn't completed and claimed in that time it expires and
  its progress is gone (the next day's quests start from zero).
- Claiming is atomic and happens at most once per quest (conditional UPDATE + unique keys).
  Reward: QUEST_CRATES Cargo Rain crates (eva.txt: 15 per mission) + credits = 2000 × player level.
- Streak: a "qualifying day" is a UTC day whose whole quest set was claimed (within the 48 h
  window). The streak is the run of consecutive qualifying days. Milestones (relative to the
  streak's first day, paid once per streak):
    · every 7 consecutive days  → 5 Giant Diamonds
    · every 30 consecutive days → 10 Giant Diamonds  (30-day milestones, NOT calendar months;
      both are paid when a day is a multiple of 7 and of 30, e.g. day 210)
  Missing a day ends the streak; a new streak starts its own milestones from day 1.
"""
from __future__ import annotations

import datetime
import hashlib

import econ
from . import cargo, int_arg

DAILY_COUNT = 3
QUEST_HOURS = 48
GIANT_DIAMOND = 42
CREDITS_PER_LEVEL = 2000
STREAK_MILESTONES = ((7, 5), (30, 10))     # (every N days, giant diamonds)

# code: (title, event type, target)
POOL = {
    "build_mines":  ("Build 5 mines", "mine_built", 5),
    "scan":         ("Scan for resources 10 times", "scan", 10),
    "factory":      ("Start a factory production", "factory_started", 1),
    "trade":        ("Make 3 market trades", "market_trade", 3),
    "repair":       ("Repair 3 mines", "mine_repaired", 3),
    "tech":         ("Install tech upgrades on a mine", "tech_installed", 1),
    "cargo":        ("Collect 20 Cargo Rain crates", "cargo_collected", 20),
}


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS daily_quests (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            hid          TEXT NOT NULL,
            day          TEXT NOT NULL,          -- UTC date of the batch (YYYY-MM-DD)
            code         TEXT NOT NULL,
            assigned_at  TEXT NOT NULL,
            expires_at   TEXT NOT NULL,
            claimed_at   TEXT,
            UNIQUE (hid, day, code)
        );
        CREATE INDEX IF NOT EXISTS idx_dq_hid ON daily_quests(hid, day);
        CREATE TABLE IF NOT EXISTS streak_rewards (
            hid        TEXT NOT NULL,
            start_day  TEXT NOT NULL,
            length     INTEGER NOT NULL,
            every      INTEGER NOT NULL,
            diamonds   INTEGER NOT NULL,
            ts         TEXT NOT NULL,
            PRIMARY KEY (hid, start_day, length, every)
        );
    """)
    conn.commit()


def _day(dt: datetime.datetime) -> str:
    return dt.strftime("%Y-%m-%d")


def pick(hid: str, day: str, codes) -> list:
    """Deterministic choice of DAILY_COUNT quest codes for (player, day)."""
    ranked = sorted(codes, key=lambda c: hashlib.sha256(f"{hid}|{day}|{c}".encode()).hexdigest())
    return ranked[:DAILY_COUNT]


def assign_today(conn, hid, now=None) -> None:
    now = now or econ.utcnow()
    day = _day(now)
    if conn.execute("SELECT 1 FROM daily_quests WHERE hid=? AND day=?", (hid, day)).fetchone():
        return
    codes = [c for c in POOL if c != "cargo" or econ.feature("CARGO")]
    for code in pick(hid, day, codes):
        conn.execute("INSERT OR IGNORE INTO daily_quests(hid, day, code, assigned_at, expires_at) "
                     "VALUES(?,?,?,?,?)", (hid, day, code, now.isoformat(),
                                           (now + datetime.timedelta(hours=QUEST_HOURS)).isoformat()))


def progress(conn, q) -> int:
    title, event, target = POOL[q["code"]]
    if event == "cargo_collected":   # one event per pick-up carries the crate count
        r = conn.execute("SELECT data FROM game_events WHERE hid=? AND type=? AND ts>=?",
                         (q["hid"], event, q["assigned_at"])).fetchall()
        import json
        n = sum(int(json.loads(x[0]).get("crates", 1)) for x in r)
    else:
        n = econ.count_events(conn, q["hid"], event, q["assigned_at"])
    return min(n, target)


def streak_ending(conn, hid, day: str) -> int:
    """Length of the run of consecutive qualifying days ending at `day` (0 if day isn't qualifying)."""
    qualifying = {r[0] for r in conn.execute(
        "SELECT day FROM daily_quests WHERE hid=? GROUP BY day "
        "HAVING COUNT(*) = SUM(CASE WHEN claimed_at IS NOT NULL THEN 1 ELSE 0 END)", (hid,))}
    n, d = 0, datetime.date.fromisoformat(day)
    while d.isoformat() in qualifying:
        n += 1
        d -= datetime.timedelta(days=1)
    return n


def current_streak(conn, hid, now=None) -> int:
    now = now or econ.utcnow()
    today, yesterday = _day(now), _day(now - datetime.timedelta(days=1))
    return streak_ending(conn, hid, today) or streak_ending(conn, hid, yesterday)


def pay_milestones(conn, hid, day: str) -> list:
    """Pay any streak milestones reached by the run ending at `day` (idempotent per streak)."""
    length = streak_ending(conn, hid, day)
    if not length:
        return []
    start = (datetime.date.fromisoformat(day) - datetime.timedelta(days=length - 1)).isoformat()
    paid = []
    for every, diamonds in STREAK_MILESTONES:
        for m in range(every, length + 1, every):
            cur = conn.execute("INSERT OR IGNORE INTO streak_rewards(hid, start_day, length, every, diamonds, ts) "
                               "VALUES(?,?,?,?,?,?)", (hid, start, m, every, diamonds, econ.utcnow_iso()))
            if cur.rowcount == 1:
                econ.give(conn, hid, GIANT_DIAMOND, diamonds, "streak_reward", f"{start}+{m}",
                          ignore_capacity=True)
                econ.emit(conn, "streak_milestone", hid, {"days": m, "diamonds": diamonds},
                          dedup=f"streak:{hid}:{start}:{m}:{every}")
                conn.execute("INSERT OR IGNORE INTO achievements(hid, code, title, ts) VALUES(?,?,?,?)",
                             (hid, f"streak_{m}", f"{m}-day quest streak", econ.utcnow_iso()))
                paid.append({"days": m, "diamonds": diamonds})
    return paid


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)
        cargo.ensure_schema(conn)
        conn.commit()

    def view(conn, hid, now):
        rows = conn.execute("SELECT * FROM daily_quests WHERE hid=? AND (claimed_at IS NULL AND expires_at > ? "
                            "OR day = ?) ORDER BY day DESC, id", (hid, now.isoformat(), _day(now))).fetchall()
        out = []
        for q in rows:
            title, event, target = POOL[q["code"]]
            p = progress(conn, q)
            out.append({"id": q["id"], "day": q["day"], "code": q["code"], "title": title, "target": target,
                        "progress": p, "expiresAt": q["expires_at"], "claimed": q["claimed_at"] is not None,
                        "claimable": q["claimed_at"] is None and p >= target and q["expires_at"] > now.isoformat()})
        return out

    @api.endpoint("/api/v1/quests", feature="QUESTS")
    def quests(conn, hid, form):
        now = econ.utcnow()
        with econ.tx(conn):
            assign_today(conn, hid, now)
        level = conn.execute("SELECT level FROM players WHERE hID=?", (hid,)).fetchone()[0] or 1
        streak = current_streak(conn, hid, now)
        nxt = min(((streak // e) + 1) * e for e, _ in STREAK_MILESTONES)
        return {"err": 0, "quests": view(conn, hid, now), "streak": streak, "nextMilestone": nxt,
                "reward": {"crates": cargo.QUEST_CRATES, "credits": CREDITS_PER_LEVEL * level},
                "milestones": [{"every": e, "diamonds": d} for e, d in STREAK_MILESTONES]}

    @api.endpoint("/api/v1/quests/claim", feature="QUESTS")
    def claim(conn, hid, form):
        qid = int_arg(form, "id", None, 1)
        now = econ.utcnow()
        with econ.tx(conn):
            q = conn.execute("SELECT * FROM daily_quests WHERE id=? AND hid=?", (qid, hid)).fetchone()
            if not q:
                raise econ.GameError("not_found", "Quest not found")
            if q["claimed_at"]:
                raise econ.GameError("already_claimed", "Reward already claimed")
            if q["expires_at"] <= now.isoformat():
                raise econ.GameError("expired", "This quest has expired")
            if progress(conn, q) < POOL[q["code"]][2]:
                raise econ.GameError("not_done", "Quest not completed yet")
            cur = conn.execute("UPDATE daily_quests SET claimed_at=? WHERE id=? AND claimed_at IS NULL",
                               (now.isoformat(), qid))
            if cur.rowcount != 1:      # lost a race with a concurrent claim
                raise econ.GameError("already_claimed", "Reward already claimed")
            level = conn.execute("SELECT level FROM players WHERE hID=?", (hid,)).fetchone()[0] or 1
            credits = CREDITS_PER_LEVEL * level
            econ.credit(conn, hid, credits, "quest_reward", str(qid))
            cargo.grant(conn, hid, cargo.QUEST_CRATES, "quest")
            econ.emit(conn, "quest_completed", hid, {"code": q["code"]}, public=False)
            conn.execute("INSERT OR IGNORE INTO achievements(hid, code, title, ts) VALUES(?,?,?,?)",
                         (hid, "first_quest", "Completed a daily quest", now.isoformat()))
            milestones = pay_milestones(conn, hid, q["day"])
        return {"err": 0, "credits": credits, "crates": cargo.QUEST_CRATES, "milestones": milestones,
                "streak": current_streak(conn, hid, now)}
