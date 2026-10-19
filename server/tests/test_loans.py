"""Phase 7: loan eligibility, rating, funding once, repayment, overdue auto-collection, default."""
import datetime
import threading

import econ
import main
from helpers import call, credits, new_player
from systems import loans as L

R = "/api/v1/loans/"


def _age(hid, days):
    with main.get_db() as conn:
        t = (econ.utcnow() - datetime.timedelta(days=days)).isoformat()
        conn.execute("UPDATE players SET created_at=? WHERE hID=?", (t, hid))
        conn.commit()


def _income(hid, amount, kind="system_sell"):
    with main.get_db() as conn:
        conn.execute("INSERT INTO ledger(ts, hid, kind, credits) VALUES(?,?,?,?)",
                     (econ.utcnow_iso(), hid, kind, amount))
        conn.commit()


def _shift_due(loan_id, days_ago):
    with main.get_db() as conn:
        t = (econ.utcnow() - datetime.timedelta(days=days_ago)).isoformat()
        conn.execute("UPDATE loans SET due_at=? WHERE id=?", (t, loan_id))
        conn.execute("DELETE FROM scheduler WHERE name='loans_sweep'")
        conn.commit()


def _borrower(prefix, income=10_000_000):
    hid, sid, _ = new_player(prefix, credits=0)
    _age(hid, 30)
    _income(hid, income)
    return hid, sid


def test_new_accounts_and_loan_income_are_not_eligible():
    hid, sid, _ = new_player("ln1")
    st = call(R + "status", sid)
    assert not st["eligible"] and "7 days" in st["reason"]
    _age(hid, 10)
    _income(hid, 10_000_000, kind="loan_received")            # borrowed money never counts as income
    assert call(R + "status", sid)["income30d"] == 0
    assert call(R + "request", sid, principal=50_000, termDays=7)["code"] == "not_eligible"


def test_rating_and_limit_scale_with_income():
    _, poor = _borrower("ln2", income=200_000)
    _, rich = _borrower("ln3", income=1_000_000_000)
    a, b = call(R + "status", poor), call(R + "status", rich)
    assert b["score"] > a["score"] and b["limit"] > a["limit"]
    assert b["weeklyRate"] < a["weeklyRate"]
    assert call(R + "request", poor, principal=a["available"] + 1, termDays=7)["code"] == "over_limit"


def test_fund_once_repay_and_history():
    b_hid, b_sid = _borrower("ln4")
    l1, l1_sid, _ = new_player("ln5", credits=1_000_000)
    l2, l2_sid, _ = new_player("ln6", credits=1_000_000)
    req = call(R + "request", b_sid, principal=100_000, termDays=7)
    loan = req["loan"]
    assert loan["interest"] > 0 and call(R + "request", b_sid, principal=20_000, termDays=3)["code"] == "duplicate"
    assert call(R + "fund", b_sid, loanID=loan["id"])["code"] == "own_loan"
    out = []
    ts = [threading.Thread(target=lambda s=s: out.append(call(R + "fund", s, loanID=loan["id"]))) for s in (l1_sid, l2_sid)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert sum(1 for r in out if r["err"] == 0) == 1
    assert credits(l1) + credits(l2) == 2_000_000 - 100_000      # funded exactly once
    assert credits(b_hid) == 100_000
    lender, lender_sid = (l1, l1_sid) if credits(l1) < 1_000_000 else (l2, l2_sid)
    before = credits(lender)
    call(R + "repay", b_sid, loanID=loan["id"], amount=40_000)
    with main.get_db() as conn:
        conn.execute("UPDATE players SET credits=credits+? WHERE hID=?", (loan["interest"], b_hid))
        conn.commit()
    r = call(R + "repay", b_sid, loanID=loan["id"])
    assert r["closed"] and r["loan"]["status"] == "repaid"
    assert credits(lender) == before + loan["total"]
    assert credits(b_hid) == 0
    assert call(R + "repay", b_sid, loanID=loan["id"])["code"] == "gone"
    hist = call(R + "mine", lender_sid)
    assert hist["lent"][0]["id"] == loan["id"] and "hid" not in str(hist["lent"][0]["borrower"]).lower()


def test_overdue_auto_collects_then_defaults():
    b_hid, b_sid = _borrower("ln7")
    lender, l_sid, _ = new_player("ln8", credits=1_000_000)
    loan = call(R + "request", b_sid, principal=100_000, termDays=3)["loan"]
    call(R + "fund", l_sid, loanID=loan["id"])
    with main.get_db() as conn:                                  # borrower spent most of it
        conn.execute("UPDATE players SET credits=30000 WHERE hID=?", (b_hid,))
        conn.commit()
    _shift_due(loan["id"], 1)
    st = call(R + "mine", b_sid)["borrowed"][0]
    assert st["status"] == "overdue" and st["repaid"] == 30_000 and credits(b_hid) == 0
    assert call(R + "status", b_sid)["eligible"] is False
    _shift_due(loan["id"], L.GRACE_DAYS + 1)
    st = call(R + "mine", b_sid)["borrowed"][0]
    assert st["status"] == "defaulted"
    assert call(R + "status", b_sid)["defaults"] == 1


def test_cancel_open_request():
    _, sid = _borrower("ln9")
    loan = call(R + "request", sid, principal=50_000, termDays=14)["loan"]
    assert call(R + "cancel", sid, loanID=loan["id"])["err"] == 0
    assert call(R + "cancel", sid, loanID=loan["id"])["code"] == "gone"
