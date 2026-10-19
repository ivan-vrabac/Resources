"""Phase 7 — player-to-player loans with credit ratings.

The game files define no loan or rating formulas (eva.txt: the original had "no game mechanics
or control for paying loans back"). Everything below is a documented, configurable proposal:

- Eligibility: account ≥ 7 days old; limit on outstanding principal = 50 % of the money
  *generated* in the rolling 30 days × rating factor. "Generated" = ledger income of kinds in
  INCOME_KINDS (market/system sales, quest rewards). Loan transfers, refunds and casino wins never
  count, so borrowing cannot inflate the limit.
- Rating (S&P/Moody-style ladder AAA … C, D = no borrowing) from a 0–100 score: 30-day income
  (log scale, up to 50), account age (up to 20), repayment history (+5 per on-time repayment up
  to 25, +1 late, −40 per default, −20 per loan currently overdue).
- Interest is fixed when the request is made: principal × weekly rate(rating) × term / 7 days.
- One lender funds a whole request (no partial funding → no overfunding). Funding is a
  conditional status change open→active inside BEGIN IMMEDIATE, so two lenders can't both fund.
- Repayment any time, any amount up to the outstanding total; goes straight to the lender.
- Due date passed → overdue; every sweep auto-collects what the borrower has. 7 days overdue →
  defaulted (permanent in the history); collection continues until the debt is paid.
- Money is only moved between players: interest is paid by the borrower, never created.
"""
from __future__ import annotations

import datetime
import math
import uuid

import econ
from . import int_arg, social

INCOME_KINDS = ("market_sell", "market_sell_legacy", "system_sell", "quest_reward")
MIN_AGE_DAYS = 7
INCOME_WINDOW_DAYS = 30
LIMIT_SHARE = 0.5
MIN_PRINCIPAL = 10_000
TERMS = (3, 7, 14)
REQUEST_HOURS = 72
GRACE_DAYS = 7
SWEEP_S = 300

# rating: (min score, weekly interest rate, limit factor)
LADDER = [
    ("AAA", 85, 0.010, 1.0), ("AA", 75, 0.015, 0.9), ("A", 65, 0.020, 0.8),
    ("BBB", 55, 0.030, 0.7), ("BB", 45, 0.040, 0.6), ("B", 35, 0.060, 0.5),
    ("CCC", 25, 0.080, 0.4), ("CC", 15, 0.110, 0.3), ("C", 5, 0.150, 0.2),
]
RISK = {"AAA": "minimal", "AA": "very low", "A": "low", "BBB": "moderate", "BB": "elevated",
        "B": "high", "CCC": "very high", "CC": "very high", "C": "extreme", "D": "in default"}


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS loans (
            id          TEXT PRIMARY KEY,
            borrower    TEXT NOT NULL,
            lender      TEXT,
            principal   INTEGER NOT NULL,
            interest    INTEGER NOT NULL,
            term_days   INTEGER NOT NULL,
            rating      TEXT NOT NULL,
            status      TEXT NOT NULL,          -- open, active, overdue, defaulted, repaid, cancelled, expired
            repaid      INTEGER NOT NULL DEFAULT 0,
            created_at  TEXT NOT NULL,
            expires_at  TEXT NOT NULL,
            funded_at   TEXT,
            due_at      TEXT,
            closed_at   TEXT,
            on_time     INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_loans_borrower ON loans(borrower, status);
        CREATE INDEX IF NOT EXISTS idx_loans_lender ON loans(lender, status);
        CREATE INDEX IF NOT EXISTS idx_loans_status ON loans(status, due_at);
    """)
    conn.commit()


def income_30d(conn, hid, now) -> float:
    since = (now - datetime.timedelta(days=INCOME_WINDOW_DAYS)).isoformat()
    q = ",".join("?" * len(INCOME_KINDS))
    r = conn.execute(f"SELECT COALESCE(SUM(credits),0) FROM ledger WHERE hid=? AND ts>=? AND credits>0 "
                     f"AND kind IN ({q})", (hid, since, *INCOME_KINDS)).fetchone()
    return float(r[0] or 0)


def account_age_days(conn, hid, now) -> float:
    r = conn.execute("SELECT created_at FROM players WHERE hID=?", (hid,)).fetchone()
    try:
        created = datetime.datetime.fromisoformat(r[0])
    except (TypeError, ValueError):
        return 0.0
    return (now - created).total_seconds() / 86400


def rating_of(conn, hid, now):
    """→ (rating, score, details)."""
    income = income_30d(conn, hid, now)
    age = account_age_days(conn, hid, now)
    rows = conn.execute("SELECT status, on_time FROM loans WHERE borrower=? AND status IN "
                        "('repaid','overdue','defaulted')", (hid,)).fetchall()
    on_time = sum(1 for s, o in rows if s == "repaid" and o)
    late = sum(1 for s, o in rows if s == "repaid" and not o)
    defaults = sum(1 for s, _ in rows if s == "defaulted")
    overdue = sum(1 for s, _ in rows if s == "overdue")
    score = (max(0.0, min(5.0, math.log10(income + 1) - 4)) * 10 + min(20.0, age / 3)
             + min(25, on_time * 5) + late - 40 * defaults - 20 * overdue)
    score = round(max(0.0, min(100.0, score)), 1)
    rating = next((name for name, lo, _, _ in LADDER if score >= lo), "D")
    if defaults and rating in ("AAA", "AA", "A"):
        rating = "BBB"
    return rating, score, {"income30d": round(income), "ageDays": round(age, 1), "onTime": on_time,
                           "late": late, "defaults": defaults, "overdue": overdue}


def ladder_row(rating):
    return next((r for r in LADDER if r[0] == rating), None)


def total_due(loan) -> int:
    return int(loan["principal"]) + int(loan["interest"])


def sweep(conn, h, now) -> None:
    """Expire stale requests, mark overdue, auto-collect, default. Call inside tx()."""
    iso = now.isoformat()
    conn.execute("UPDATE loans SET status='expired', closed_at=? WHERE status='open' AND expires_at<?", (iso, iso))
    conn.execute("UPDATE loans SET status='overdue' WHERE status='active' AND due_at<?", (iso,))
    grace = (now - datetime.timedelta(days=GRACE_DAYS)).isoformat()
    for loan in conn.execute("SELECT id, borrower FROM loans WHERE status='overdue' AND due_at<?", (grace,)).fetchall():
        conn.execute("UPDATE loans SET status='defaulted' WHERE id=?", (loan["id"],))
        econ.emit(conn, "loan_default", loan["borrower"], {"loan": loan["id"]}, public=False)
    for loan in conn.execute("SELECT * FROM loans WHERE status IN ('overdue','defaulted') AND repaid < principal+interest "
                             "ORDER BY due_at").fetchall():
        have = econ.credits_of(conn, loan["borrower"])
        pay = min(int(have), total_due(loan) - int(loan["repaid"]))
        if pay > 0:
            _pay(conn, loan, pay, now, auto=True)


def _pay(conn, loan, amount, now, auto=False) -> dict:
    econ.debit(conn, loan["borrower"], amount, "loan_repay", loan["id"])
    econ.credit(conn, loan["lender"], amount, "loan_repaid", loan["id"])
    repaid = int(loan["repaid"]) + amount
    done = repaid >= total_due(loan)
    if done:
        on_time = 1 if loan["status"] == "active" else 0
        status = "repaid" if loan["status"] != "defaulted" else "defaulted"
        conn.execute("UPDATE loans SET repaid=?, status=?, closed_at=?, on_time=? WHERE id=?",
                     (repaid, status, now.isoformat(), on_time, loan["id"]))
    else:
        conn.execute("UPDATE loans SET repaid=? WHERE id=?", (repaid, loan["id"]))
    return {"repaid": repaid, "closed": done, "auto": auto}


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)

    def maybe_sweep(conn, now):
        if econ.due(conn, "loans_sweep", SWEEP_S):
            sweep(conn, h, now)

    def limits(conn, hid, now):
        rating, score, det = rating_of(conn, hid, now)
        row = ladder_row(rating)
        outstanding = conn.execute(
            "SELECT COALESCE(SUM(principal),0) FROM loans WHERE borrower=? AND status IN ('open','active','overdue','defaulted') "
            "AND repaid < principal+interest", (hid,)).fetchone()[0]
        bad = conn.execute("SELECT COUNT(*) FROM loans WHERE borrower=? AND status IN ('overdue','defaulted') "
                           "AND repaid < principal+interest", (hid,)).fetchone()[0]
        limit = int(LIMIT_SHARE * det["income30d"] * row[3]) if row else 0
        reason = None
        if det["ageDays"] < MIN_AGE_DAYS:
            reason = f"Loans unlock after {MIN_AGE_DAYS} days of play"
        elif bad:
            reason = "Repay your overdue loans first"
        elif not row:
            reason = "Your credit rating is too low (D)"
        elif limit - outstanding < MIN_PRINCIPAL:
            reason = "Your credit limit is used up (it grows with the money you earn)"
        return {"rating": rating, "score": score, "risk": RISK[rating], **det,
                "weeklyRate": row[2] if row else None, "limit": limit, "outstanding": int(outstanding),
                "available": max(0, limit - int(outstanding)), "eligible": reason is None, "reason": reason}

    def view(conn, loan, viewer):
        d = {k: loan[k] for k in ("id", "principal", "interest", "term_days", "rating", "status", "repaid",
                                  "created_at", "expires_at", "funded_at", "due_at", "closed_at")}
        d["total"] = total_due(loan)
        d["outstanding"] = max(0, d["total"] - int(loan["repaid"]))
        d["risk"] = RISK.get(loan["rating"], "")
        d["borrower"] = social.public_ref(conn, loan["borrower"])
        d["lender"] = social.public_ref(conn, loan["lender"]) if loan["lender"] else None
        d["isBorrower"] = loan["borrower"] == viewer
        d["isLender"] = loan["lender"] == viewer
        d["schedule"] = [{"due": loan["due_at"], "amount": d["total"]}] if loan["due_at"] else []
        return d

    @api.endpoint("/api/v1/loans/status", feature="LOANS")
    def status(conn, hid, form):
        now = econ.utcnow()
        with econ.tx(conn):
            maybe_sweep(conn, now)
        return {"err": 0, **limits(conn, hid, now), "terms": TERMS, "minPrincipal": MIN_PRINCIPAL,
                "ladder": [{"rating": n, "minScore": lo, "weeklyRate": r, "risk": RISK[n]} for n, lo, r, _ in LADDER]}

    @api.endpoint("/api/v1/loans/list", feature="LOANS")
    def market(conn, hid, form):
        now = econ.utcnow()
        with econ.tx(conn):
            maybe_sweep(conn, now)
        rows = conn.execute("SELECT * FROM loans WHERE status='open' AND borrower<>? ORDER BY created_at DESC LIMIT 100",
                            (hid,)).fetchall()
        return {"err": 0, "requests": [view(conn, r, hid) for r in rows]}

    @api.endpoint("/api/v1/loans/mine", feature="LOANS")
    def mine(conn, hid, form):
        now = econ.utcnow()
        with econ.tx(conn):
            maybe_sweep(conn, now)
        b = conn.execute("SELECT * FROM loans WHERE borrower=? ORDER BY created_at DESC LIMIT 100", (hid,)).fetchall()
        l = conn.execute("SELECT * FROM loans WHERE lender=? ORDER BY funded_at DESC LIMIT 100", (hid,)).fetchall()
        return {"err": 0, "borrowed": [view(conn, r, hid) for r in b], "lent": [view(conn, r, hid) for r in l]}

    @api.endpoint("/api/v1/loans/request", feature="LOANS")
    def request_loan(conn, hid, form):
        principal = int_arg(form, "principal", None, MIN_PRINCIPAL, 10**13)
        term = int_arg(form, "termDays", 7, 1, 30)
        if term not in TERMS:
            raise econ.GameError("bad_input", "Choose a term of 3, 7 or 14 days")
        now = econ.utcnow()
        with econ.tx(conn):
            maybe_sweep(conn, now)
            if conn.execute("SELECT 1 FROM loans WHERE borrower=? AND status='open'", (hid,)).fetchone():
                raise econ.GameError("duplicate", "You already have an open loan request")
            lim = limits(conn, hid, now)
            if not lim["eligible"]:
                raise econ.GameError("not_eligible", lim["reason"])
            if principal > lim["available"]:
                raise econ.GameError("over_limit", f"You can borrow at most {lim['available']:,} credits")
            interest = int(round(principal * lim["weeklyRate"] * term / 7))
            lid = uuid.uuid4().hex
            conn.execute("INSERT INTO loans(id, borrower, principal, interest, term_days, rating, status, created_at, expires_at) "
                         "VALUES(?,?,?,?,?,?,'open',?,?)",
                         (lid, hid, principal, interest, term, lim["rating"], now.isoformat(),
                          (now + datetime.timedelta(hours=REQUEST_HOURS)).isoformat()))
            loan = conn.execute("SELECT * FROM loans WHERE id=?", (lid,)).fetchone()
            return {"err": 0, "loan": view(conn, loan, hid)}

    @api.endpoint("/api/v1/loans/cancel", feature="LOANS")
    def cancel(conn, hid, form):
        lid = (form.get("loanID") or "").strip()
        with econ.tx(conn):
            cur = conn.execute("UPDATE loans SET status='cancelled', closed_at=? WHERE id=? AND borrower=? AND status='open'",
                               (econ.utcnow_iso(), lid, hid))
            if cur.rowcount != 1:
                raise econ.GameError("gone", "This request can no longer be cancelled")
        return {"err": 0}

    @api.endpoint("/api/v1/loans/fund", feature="LOANS")
    def fund(conn, hid, form):
        lid = (form.get("loanID") or "").strip()
        now = econ.utcnow()
        with econ.tx(conn):
            maybe_sweep(conn, now)
            loan = conn.execute("SELECT * FROM loans WHERE id=?", (lid,)).fetchone()
            if not loan or loan["status"] != "open":
                raise econ.GameError("gone", "This loan request is no longer open")
            if loan["borrower"] == hid:
                raise econ.GameError("own_loan", "You can't fund your own loan")
            due = now + datetime.timedelta(days=int(loan["term_days"]))
            cur = conn.execute("UPDATE loans SET status='active', lender=?, funded_at=?, due_at=? WHERE id=? AND status='open'",
                               (hid, now.isoformat(), due.isoformat(), lid))
            if cur.rowcount != 1:
                raise econ.GameError("gone", "This loan request is no longer open")
            econ.debit(conn, hid, loan["principal"], "loan_fund", lid)
            econ.credit(conn, loan["borrower"], loan["principal"], "loan_received", lid)
            econ.emit(conn, "loan_funded", hid, {"loan": lid, "principal": loan["principal"]}, public=False)
            h.add_proto(conn, loan["borrower"], "loanfunded", {"loan": lid, "principal": loan["principal"]})
            loan = conn.execute("SELECT * FROM loans WHERE id=?", (lid,)).fetchone()
            out = {"err": 0, "loan": view(conn, loan, hid)}
        try:
            with h.get_db() as c2:
                h.push(c2, loan["borrower"], "Loan funded",
                       f"Your loan of {loan['principal']:,} credits was funded. Due in {loan['term_days']} days.")
        except Exception:
            pass
        return out

    @api.endpoint("/api/v1/loans/repay", feature="LOANS")
    def repay(conn, hid, form):
        lid = (form.get("loanID") or "").strip()
        now = econ.utcnow()
        with econ.tx(conn):
            maybe_sweep(conn, now)
            loan = conn.execute("SELECT * FROM loans WHERE id=? AND borrower=?", (lid, hid)).fetchone()
            if not loan or loan["status"] not in ("active", "overdue", "defaulted"):
                raise econ.GameError("gone", "Nothing to repay on this loan")
            outstanding = total_due(loan) - int(loan["repaid"])
            if outstanding <= 0:
                raise econ.GameError("gone", "This loan is already repaid")
            amount = int_arg(form, "amount", outstanding, 1, 10**14)
            amount = min(amount, outstanding)
            res = _pay(conn, loan, amount, now)
            loan = conn.execute("SELECT * FROM loans WHERE id=?", (lid,)).fetchone()
            return {"err": 0, **res, "loan": view(conn, loan, hid)}
