"""Phase 3: daily quests, progress from events, exactly-once claims, streak milestones, level-up crates."""
import datetime
import threading

import econ
import main
from helpers import call, credits, new_player, qty
from systems import cargo, quests

Q = "/api/v1/quests"


def _force_quests(hid, codes, day=None, hours_ago=0):
    """Replace today's batch with known quests (deterministic tests)."""
    now = econ.utcnow() - datetime.timedelta(hours=hours_ago)
    day = day or now.strftime("%Y-%m-%d")
    with main.get_db() as conn:
        conn.execute("DELETE FROM daily_quests WHERE hid=? AND day=?", (hid, day))
        for c in codes:
            conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at) VALUES(?,?,?,?,?)",
                         (hid, day, c, now.isoformat(), (now + datetime.timedelta(hours=48)).isoformat()))
        conn.commit()


def _events(hid, type_, n):
    with main.get_db() as conn:
        for _ in range(n):
            econ.emit(conn, type_, hid, {}, public=False)
        conn.commit()


def test_assignment_is_deterministic_and_daily():
    hid, sid, _ = new_player("qa")
    a = call(Q, sid)["quests"]
    b = call(Q, sid)["quests"]
    assert len(a) == quests.DAILY_COUNT and [q["code"] for q in a] == [q["code"] for q in b]
    assert quests.pick(hid, "2026-01-01", list(quests.POOL)) == quests.pick(hid, "2026-01-01", list(quests.POOL))


def test_progress_claim_once_and_rewards():
    hid, sid, _ = new_player("qb", credits=0, level=10)
    _force_quests(hid, ["scan", "repair", "factory"])
    qs = {q["code"]: q for q in call(Q, sid)["quests"]}
    assert qs["scan"]["progress"] == 0 and not qs["scan"]["claimable"]
    assert call(Q + "/claim", sid, id=qs["scan"]["id"])["code"] == "not_done"
    _events(hid, "scan", 12)
    qs = {q["code"]: q for q in call(Q, sid)["quests"]}
    assert qs["scan"]["progress"] == 10 and qs["scan"]["claimable"]
    r = call(Q + "/claim", sid, id=qs["scan"]["id"])
    assert r["credits"] == 20000 and r["crates"] == 15
    assert credits(hid) == 20000
    assert call(Q + "/claim", sid, id=qs["scan"]["id"])["code"] == "already_claimed"
    with main.get_db() as conn:
        assert cargo.stock(conn, hid) == 15


def test_events_before_assignment_do_not_count():
    hid, sid, _ = new_player("qc")
    _events(hid, "scan", 10)
    _force_quests(hid, ["scan", "repair", "factory"])
    qs = {q["code"]: q for q in call(Q, sid)["quests"]}
    assert qs["scan"]["progress"] == 0


def test_concurrent_claims_pay_once():
    hid, sid, _ = new_player("qd", credits=0, level=1)
    _force_quests(hid, ["factory", "scan", "repair"])
    _events(hid, "factory_started", 1)
    qid = next(q["id"] for q in call(Q, sid)["quests"] if q["code"] == "factory")
    out = []
    ts = [threading.Thread(target=lambda: out.append(call(Q + "/claim", sid, id=qid))) for _ in range(6)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert sum(1 for r in out if r["err"] == 0) == 1
    assert credits(hid) == 2000


def test_expired_quest_cannot_be_claimed():
    hid, sid, _ = new_player("qe")
    yesterday = (econ.utcnow() - datetime.timedelta(days=3)).strftime("%Y-%m-%d")
    _force_quests(hid, ["factory"], day=yesterday, hours_ago=72)
    _events(hid, "factory_started", 1)
    with main.get_db() as conn:
        qid = conn.execute("SELECT id FROM daily_quests WHERE hid=? AND day=?", (hid, yesterday)).fetchone()[0]
    assert call(Q + "/claim", sid, id=qid)["code"] == "expired"


def test_seven_and_thirty_day_streak_milestones_paid_once():
    hid, sid, _ = new_player("qf", level=1)
    today = econ.utcnow().date()
    with main.get_db() as conn:          # 29 previous fully-claimed days
        for i in range(29, 0, -1):
            d = (today - datetime.timedelta(days=i)).isoformat()
            for c in ("scan", "repair", "factory"):
                conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at, claimed_at) "
                             "VALUES(?,?,?,?,?,?)", (hid, d, c, d, d, d))
        conn.commit()
    _force_quests(hid, ["factory", "scan", "repair"])
    _events(hid, "factory_started", 1)
    _events(hid, "scan", 10)
    _events(hid, "mine_repaired", 3)
    paid = []
    for q in call(Q, sid)["quests"]:
        paid += call(Q + "/claim", sid, id=q["id"])["milestones"]
    # day 30 completes: 7,14,21,28 (5 GD each) + 30 (10 GD)
    assert sorted((m["days"], m["diamonds"]) for m in paid if "diamonds" in m) == \
        [(7, 5), (14, 5), (21, 5), (28, 5), (30, 10)]
    assert qty(hid, 42) == 30
    assert [m["qty"] for m in paid if m.get("daily")] == [50]          # day 30 of the streak: 50 Tech Upgrades IV
    assert qty(hid, 48) == 50
    with main.get_db() as conn:
        assert quests.pay_milestones(conn, hid, today.isoformat()) == []   # never twice
        assert quests.current_streak(conn, hid) == 30


def test_broken_streak_restarts_milestones():
    hid, sid, _ = new_player("qg")
    today = econ.utcnow().date()
    with main.get_db() as conn:
        # 7-day streak long ago (already paid), a gap, then 6 days up to yesterday
        days = [today - datetime.timedelta(days=i) for i in list(range(20, 13, -1)) + list(range(6, 0, -1))]
        for d in days:
            for c in ("scan",):
                conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at, claimed_at) "
                             "VALUES(?,?,?,?,?,?)", (hid, d.isoformat(), c, d.isoformat(), d.isoformat(), d.isoformat()))
        quests.pay_milestones(conn, hid, (today - datetime.timedelta(days=14)).isoformat())
        conn.commit()
    assert qty(hid, 42) == 5
    _force_quests(hid, ["scan"])
    _events(hid, "scan", 10)
    q = call(Q, sid)["quests"][0]
    r = call(Q + "/claim", sid, id=q["id"])
    assert [(m["days"], m["diamonds"]) for m in r["milestones"] if "diamonds" in m] == [(7, 5)]   # new streak
    assert qty(hid, 42) == 10


def test_level_up_grants_cargo():
    hid, sid, _ = new_player("qh", level=1)
    with main.get_db() as conn:
        before = cargo.stock(conn, hid)
        main.award_xp(conn, hid, 1_000_000)          # +10,000 xp → several levels
        conn.commit()
        lvl = conn.execute("SELECT level FROM players WHERE hID=?", (hid,)).fetchone()[0]
        assert lvl > 1
        assert cargo.stock(conn, hid) - before == 30 * (lvl - 1)


def test_daily_tech_upgrade_tiers_and_variable_targets():
    assert [quests.daily_tu(d) for d in (1, 2, 3, 9, 10, 11, 40)] == [5, 10, 15, 45, 50, 50, 50]
    t = {quests.target_of("cargo", f"h{i}", "2026-01-01") for i in range(200)}
    assert min(t) >= 5 and max(t) <= 20 and len(t) > 5
    assert all(1 <= quests.target_of("artifacts", f"h{i}", "2026-01-02") <= 3 for i in range(50))
    hid, sid, _ = new_player("qtu")
    codes = {q["code"] for q in call(Q, sid)["quests"]}
    assert "artifacts" not in codes                                     # needs an Archaeological Center
    plan = call(Q, sid)["rewardPlan"]
    assert plan["daily"][0]["qty"] == 5 and plan["milestones"][0]["every"] == 7


def test_one_missed_day_keeps_the_streak_two_end_it():
    hid, _, _ = new_player("qrest")
    today = econ.utcnow().date()
    with main.get_db() as conn:
        # qualifying: today, (gap 1 day), 2 days ago, 3 days ago, (gap 2 days), 6 days ago
        for back in (0, 2, 3, 6):
            d = (today - datetime.timedelta(days=back)).isoformat()
            conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at, claimed_at) "
                         "VALUES(?,?,?,?,?,?)", (hid, d, "scan", d, d, d))
        conn.commit()
        assert quests.streak_ending(conn, hid, today.isoformat()) == 3     # day 6 is cut off by the 2-day gap
        assert quests.current_streak(conn, hid) == 3
