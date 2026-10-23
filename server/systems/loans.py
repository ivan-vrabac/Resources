"""Phase 7 — player-to-player loans with credit ratings.

The game files define no loan or rating formulas. Rules from the owner (2026-10-19) are marked
[owner]; the rest is a documented, configurable proposal.

- Eligibility: account ≥ 7 days old; limit on outstanding principal = 50 % of the money
  *generated* in the rolling 30 days × rating factor. "Generated" = ledger income of kinds in
  INCOME_KINDS (market/system sales, quest rewards). Loan transfers, refunds and casino wins never
  count, so borrowing cannot inflate the limit.
- Rating (ladder AAA … C, D = no borrowing) from a 0–100 score: 30-day income (log scale, up to
  50), account age (up to 20), repayment history (+5 per on-time repayment up to 25, +1 late,
  −40 per forgiven loan).
- Term [owner]: 10–30 days. Interest is fixed at request time: principal × weekly rate × days / 7.
- One lender funds a whole request (no partial funding → no overfunding). Funding is a
  conditional status change open→active inside BEGIN IMMEDIATE, so two lenders can't both fund.
- Repayment any time, any amount up to the outstanding total; goes straight to the lender.
- Not repaid by the due date [owner] → overdue for GRACE_DAYS (30). Meanwhile the game takes
  GARNISH_SHARE (50 %) of the borrower's mining output, factory output and sales and pays it to
  the lender (resources are converted at the system price). After the 30 days the rest of the
  debt is forgiven (status 'forgiven'). The borrower's rating is D from the due date on and is
  "reset" [owner]: it stays D for RESET_DAYS after forgiveness, then normal scoring resumes with
  the forgiven loan counting as a default.
"""
from __future__ import annotations

import datetime
import math
import uuid

import econ
from . import int_arg, social

INCOME_KINDS = ("market_sell", "market_sell_legacy", "system_sell", "quest_reward")
# owner 2026-10-20: count NET earnings — what was spent buying is subtracted, so buying and selling
# back and forth (or between own accounts) can't make a company look richer than it is
SPEND_KINDS = ("system_buy", "market_buy", "market_order_escrow")
REFUND_KINDS = ("market_cancelled", "market_expired", "market_escrow_rest", "market_edit_refund")
MIN_AGE_DAYS = 7
INCOME_WINDOW_DAYS = 30
LIMIT_SHARE = 0.5
MIN_PRINCIPAL = 10_000
WAREHOUSE_SHARE = 0.2      # part of the warehouse value that counts towards the credit limit
MIN_TERM, MAX_TERM = 10, 30
REQUEST_HOURS = 72
GRACE_DAYS = 30
RESET_DAYS = 30
GARNISH_SHARE = 0.5
SWEEP_S = 300

# rating: (min score, weekly interest rate, limit factor)
LADDER = [
    ("AAA", 85, 0.010, 1.0), ("AA", 75, 0.015, 0.9), ("A", 65, 0.020, 0.8),
    ("BBB", 55, 0.030, 0.7), ("BB", 45, 0.040, 0.6), ("B", 35, 0.060, 0.5),
    ("CCC", 25, 0.080, 0.4), ("CC", 15, 0.110, 0.3), ("C", 5, 0.150, 0.2),
]
RISK = {"NR": "not rated yet", "AAA": "minimal", "AA": "very low", "A": "low", "BBB": "moderate", "BB": "elevated",
        "B": "high", "CCC": "very high", "CC": "very high", "C": "extreme", "D": "in default"}

_prices = {}   # item → system price, set by install()


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
            status      TEXT NOT NULL,          -- open, active, overdue, repaid, forgiven, cancelled, expired
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
    # earlier development builds used 'defaulted' for what is now 'forgiven'
    conn.execute("UPDATE loans SET status='forgiven' WHERE status='defaulted'")
    conn.commit()


def _sum(conn, hid, since, kinds, sign) -> float:
    q = ",".join("?" * len(kinds))
    r = conn.execute(f"SELECT COALESCE(SUM(credits),0) FROM ledger WHERE hid=? AND ts>=? AND credits{sign}0 "
                     f"AND kind IN ({q})", (hid, since, *kinds)).fetchone()
    return float(r[0] or 0)


def income_30d(conn, hid, now) -> float:
    """Net money earned in the window: sales + quest rewards − purchases (never below 0)."""
    since = (now - datetime.timedelta(days=INCOME_WINDOW_DAYS)).isoformat()
    earned = _sum(conn, hid, since, INCOME_KINDS, ">")
    spent = -_sum(conn, hid, since, SPEND_KINDS, "<") - _sum(conn, hid, since, REFUND_KINDS, ">")
    return max(0.0, earned - max(0.0, spent))


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
    iso = now.isoformat()
    rows = conn.execute("SELECT status, on_time, due_at, closed_at FROM loans WHERE borrower=? AND status IN "
                        "('repaid','active','overdue','forgiven')", (hid,)).fetchall()
    on_time = sum(1 for r in rows if r["status"] == "repaid" and r["on_time"])
    late = sum(1 for r in rows if r["status"] == "repaid" and not r["on_time"])
    forgiven = [r for r in rows if r["status"] == "forgiven"]
    overdue = sum(1 for r in rows if r["status"] in ("active", "overdue") and r["due_at"] and r["due_at"] < iso)
    score = (max(0.0, min(5.0, math.log10(income + 1) - 4)) * 10 + min(20.0, age / 3)
             + min(25, on_time * 5) + late - 40 * len(forgiven))
    score = round(max(0.0, min(100.0, score)), 1)
    # below the lowest step without any default: not rated yet (owner 2026-10-23: "D" said "in default")
    rating = next((name for name, lo, _, _ in LADDER if score >= lo), "NR")
    reset_until = None
    if forgiven:
        last = max(r["closed_at"] or "" for r in forgiven)
        try:
            until = datetime.datetime.fromisoformat(last) + datetime.timedelta(days=RESET_DAYS)
            if until > now:
                reset_until = until.isoformat()
        except ValueError:
            pass
    if overdue or reset_until:
        rating = "D"
    return rating, score, {"income30d": round(income), "ageDays": round(age, 1), "onTime": on_time,
                           "late": late, "defaults": len(forgiven), "overdue": overdue,
                           "resetUntil": reset_until}


def max_for_term(available: int, term: int) -> int:
    """Longer terms allow bigger loans: the full available amount at MAX_TERM days, a third at 10."""
    term = max(MIN_TERM, min(MAX_TERM, int(term)))
    return int(available * term / MAX_TERM)


def ladder_row(rating):
    return next((r for r in LADDER if r[0] == rating), None)


def total_due(loan) -> int:
    return int(loan["principal"]) + int(loan["interest"])


def _settle(conn, loan, amount, now) -> dict:
    """Record `amount` as repaid on `loan` (the money has already reached the lender)."""
    repaid = int(loan["repaid"]) + amount
    done = repaid >= total_due(loan)
    if done:
        on_time = 1 if loan["due_at"] and now.isoformat() <= loan["due_at"] else 0
        conn.execute("UPDATE loans SET repaid=?, status='repaid', closed_at=?, on_time=? WHERE id=?",
                     (repaid, now.isoformat(), on_time, loan["id"]))
    else:
        conn.execute("UPDATE loans SET repaid=? WHERE id=?", (repaid, loan["id"]))
    return {"repaid": repaid, "closed": done}


def _pay(conn, loan, amount, now, kind="loan_repay") -> dict:
    econ.debit(conn, loan["borrower"], amount, kind, loan["id"])
    econ.credit(conn, loan["lender"], amount, "loan_repaid", loan["id"])
    return _settle(conn, loan, amount, now)


def _overdue_loans(conn, hid, now):
    return conn.execute("SELECT * FROM loans WHERE borrower=? AND status IN ('active','overdue') AND due_at<? "
                        "AND repaid < principal+interest ORDER BY due_at", (hid, now.isoformat())).fetchall()


def sweep(conn, h, now) -> None:
    """Expire stale requests, mark overdue, forgive after the grace period. Call inside tx()."""
    iso = now.isoformat()
    conn.execute("UPDATE loans SET status='expired', closed_at=? WHERE status='open' AND expires_at<?", (iso, iso))
    conn.execute("UPDATE loans SET status='overdue' WHERE status='active' AND due_at<?", (iso,))
    grace = (now - datetime.timedelta(days=GRACE_DAYS)).isoformat()
    for loan in conn.execute("SELECT id, borrower, lender FROM loans WHERE status='overdue' AND due_at<?", (grace,)).fetchall():
        conn.execute("UPDATE loans SET status='forgiven', closed_at=? WHERE id=?", (iso, loan["id"]))
        econ.emit(conn, "loan_default", loan["borrower"], {"loan": loan["id"]}, public=False)
        h.add_proto(conn, loan["borrower"], "loanforgiven", {"loan": loan["id"]})
        h.add_proto(conn, loan["lender"], "loanforgiven", {"loan": loan["id"]})


# ── garnishment hooks (called by econ.credit and by mine/factory collection) ──

def garnish_credits(conn, hid, amount, kind) -> None:
    """A sale credited `amount` to an overdue borrower: pass GARNISH_SHARE of it to the lender(s)."""
    if kind not in INCOME_KINDS or amount <= 0:
        return
    now = econ.utcnow()
    budget = int(amount * GARNISH_SHARE)
    for loan in _overdue_loans(conn, hid, now):
        if budget <= 0 or loan["due_at"] < (now - datetime.timedelta(days=GRACE_DAYS)).isoformat():
            continue
        pay = min(budget, total_due(loan) - int(loan["repaid"]))
        if pay > 0:
            _pay(conn, loan, pay, now, kind="loan_garnish")
            budget -= pay


def garnish_output(conn, hid, item_id, qty) -> float:
    """Mining/factory output for an overdue borrower: GARNISH_SHARE of it is sold at the system
    price for the lender(s). Returns the quantity the borrower keeps."""
    price = _prices.get(item_id)
    if qty <= 0 or not price:
        return qty
    now = econ.utcnow()
    loans = _overdue_loans(conn, hid, now)
    if not loans:
        return qty
    take_qty = qty * GARNISH_SHARE
    budget = int(take_qty * price)
    used = 0
    for loan in loans:
        if budget - used <= 0 or loan["due_at"] < (now - datetime.timedelta(days=GRACE_DAYS)).isoformat():
            continue
        pay = min(budget - used, total_due(loan) - int(loan["repaid"]))
        if pay > 0:
            econ.credit(conn, loan["lender"], pay, "loan_garnish_output", loan["id"])
            _settle(conn, loan, pay, now)
            used += pay
    taken = used / price
    return qty - taken


def install(api) -> None:
    h = api.h
    _prices.update(h.SYSTEM_PRICES)
    with h.get_db() as conn:
        init_schema(conn)
    econ.CREDIT_HOOKS.append(garnish_credits)
    h.OUTPUT_HOOKS.append(garnish_output)

    def maybe_sweep(conn, now):
        if econ.due(conn, "loans_sweep", SWEEP_S):
            sweep(conn, h, now)

    def limits(conn, hid, now):
        rating, score, det = rating_of(conn, hid, now)
        row = ladder_row(rating)
        outstanding = conn.execute(
            "SELECT COALESCE(SUM(principal),0) FROM loans WHERE borrower=? AND status IN ('open','active','overdue') "
            "AND repaid < principal+interest", (hid,)).fetchone()[0]
        # economy revamp 2026-10-23: the limit counts the money earned in 30 days AND what the company
        # holds in its warehouse (at the system price), so producers who keep goods can borrow too
        wh_value = sum(_prices.get(r[0], 0) * float(r[1] or 0) for r in conn.execute(
            "SELECT item_id, qty FROM warehouse WHERE hid=? AND qty>0", (hid,)))
        limit = int((LIMIT_SHARE * det["income30d"] + WAREHOUSE_SHARE * wh_value) * row[3]) if row else 0
        reason = None
        balance = econ.credits_of(conn, hid)
        if balance < 0:
            reason = "Your balance is negative. Get back above zero first"
        elif det["ageDays"] < MIN_AGE_DAYS:
            reason = f"Loans unlock after {MIN_AGE_DAYS} days of play"
        elif det["overdue"]:
            reason = "Repay your overdue loans first"
        elif det["resetUntil"]:
            reason = f"Your rating was reset to D after a forgiven loan (until {det['resetUntil'][:10]})"
        elif rating == "NR":
            reason = "Not rated yet: earn money and play longer to get a rating"
        elif not row:
            reason = "You are in default (rating D)"
        elif limit - outstanding < MIN_PRINCIPAL:
            reason = "Your credit limit is used up (it grows with the money you earn)"
        return {"rating": rating, "score": score, "risk": RISK[rating], **det,
                "weeklyRate": row[2] if row else None, "limit": limit, "outstanding": int(outstanding),
                "available": max(0, limit - int(outstanding)), "eligible": reason is None, "reason": reason}

    def view(conn, loan, viewer):
        d = {k: loan[k] for k in ("id", "principal", "interest", "term_days", "rating", "status", "repaid",
                                  "created_at", "expires_at", "funded_at", "due_at", "closed_at")}
        d["total"] = total_due(loan)
        d["outstanding"] = 0 if loan["status"] in ("forgiven", "repaid") else max(0, d["total"] - int(loan["repaid"]))
        d["risk"] = RISK.get(loan["rating"], "")
        # anonymous (owner 2026-10-20): nobody sees who borrowed or who lent — only rating and amounts
        d["borrower"] = None
        d["lender"] = None
        d["isBorrower"] = loan["borrower"] == viewer
        d["isLender"] = loan["lender"] == viewer
        d["schedule"] = [{"due": loan["due_at"], "amount": d["total"]}] if loan["due_at"] else []
        if loan["due_at"]:
            d["forgivenAt"] = (datetime.datetime.fromisoformat(loan["due_at"])
                               + datetime.timedelta(days=GRACE_DAYS)).isoformat()
        return d

    @api.endpoint("/api/v1/loans/status", feature="LOANS")
    def status(conn, hid, form):
        now = econ.utcnow()
        with econ.tx(conn):
            maybe_sweep(conn, now)
        return {"err": 0, **limits(conn, hid, now), "minTerm": MIN_TERM, "maxTerm": MAX_TERM,
                "graceDays": GRACE_DAYS, "garnishShare": GARNISH_SHARE, "minPrincipal": MIN_PRINCIPAL,
                "ladder": [{"rating": n, "minScore": lo, "weeklyRate": r, "risk": RISK[n]} for n, lo, r, _ in LADDER]}

    @api.endpoint("/api/v1/loans/stats", feature="LOANS")
    def stats(conn, hid, form):
        """Global loan market figures (anonymous): owner 2026-10-23."""
        now = econ.utcnow()
        with econ.tx(conn):
            maybe_sweep(conn, now)
        live = conn.execute("SELECT principal, interest, repaid, rating, status FROM loans "
                            "WHERE status IN ('active','overdue')").fetchall()
        outstanding = sum(max(0, int(r[0]) + int(r[1]) - int(r[2])) for r in live)
        funded = [int(r[0]) for r in conn.execute("SELECT principal FROM loans WHERE funded_at IS NOT NULL")]
        forgiven = conn.execute("SELECT COUNT(*), COALESCE(SUM(principal+interest-repaid),0) FROM loans "
                                "WHERE status='forgiven'").fetchone()
        repaid = conn.execute("SELECT COUNT(*) FROM loans WHERE status='repaid'").fetchone()[0]
        open_req = conn.execute("SELECT COUNT(*), COALESCE(SUM(principal),0) FROM loans WHERE status='open'").fetchone()
        scores = {n: lo for n, lo, _, _ in LADDER}
        rated = [scores[r[3]] for r in live if r[3] in scores]
        avg_score = sum(rated) / len(rated) if rated else None
        avg_rating = next((n for n, lo, _, _ in LADDER if avg_score is not None and avg_score >= lo), None)
        srt = sorted(funded)
        median = (srt[len(srt) // 2] if len(srt) % 2 else (srt[len(srt) // 2 - 1] + srt[len(srt) // 2]) / 2) if srt else 0
        return {"err": 0, "activeLoans": len(live), "overdue": sum(1 for r in live if r[4] == "overdue"),
                "outstanding": outstanding, "totalLent": sum(funded), "loansFunded": len(funded),
                "defaults": int(forgiven[0]), "defaultedAmount": int(forgiven[1]), "repaidLoans": int(repaid),
                "openRequests": int(open_req[0]), "requested": int(open_req[1]),
                "averageLoan": round(sum(funded) / len(funded)) if funded else 0, "medianLoan": round(median),
                "averageRating": avg_rating}

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
        live = "status IN ('open','active','overdue')"
        b = conn.execute(f"SELECT * FROM loans WHERE borrower=? AND {live} ORDER BY created_at DESC LIMIT 100", (hid,)).fetchall()
        l = conn.execute(f"SELECT * FROM loans WHERE lender=? AND {live} ORDER BY funded_at DESC LIMIT 100", (hid,)).fetchall()
        return {"err": 0, "borrowed": [view(conn, r, hid) for r in b], "lent": [view(conn, r, hid) for r in l]}

    @api.endpoint("/api/v1/loans/request", feature="LOANS")
    def request_loan(conn, hid, form):
        principal = int_arg(form, "principal", None, MIN_PRINCIPAL, 10**13)
        term = int_arg(form, "termDays", 14, 1, 365)
        if not MIN_TERM <= term <= MAX_TERM:
            raise econ.GameError("bad_input", f"Choose a term of {MIN_TERM} to {MAX_TERM} days")
        now = econ.utcnow()
        with econ.tx(conn):
            maybe_sweep(conn, now)
            if conn.execute("SELECT 1 FROM loans WHERE borrower=? AND status='open'", (hid,)).fetchone():
                raise econ.GameError("duplicate", "You already have an open loan request")
            lim = limits(conn, hid, now)
            if not lim["eligible"]:
                raise econ.GameError("not_eligible", lim["reason"])
            cap = max_for_term(lim["available"], term)
            if principal > cap:
                raise econ.GameError("over_limit", f"For {term} days you can borrow at most {cap:,} credits")
            interest = int(round(principal * lim["weeklyRate"] * term / 7))
            lid = uuid.uuid4().hex
            conn.execute("INSERT INTO loans(id, borrower, principal, interest, term_days, rating, status, created_at, expires_at) "
                         "VALUES(?,?,?,?,?,?,'open',?,?)",
                         (lid, hid, principal, interest, term, lim["rating"], now.isoformat(),
                          (now + datetime.timedelta(hours=REQUEST_HOURS)).isoformat()))
            loan = conn.execute("SELECT * FROM loans WHERE id=?", (lid,)).fetchone()
            h.add_proto(conn, hid, "loanrequested", {"loan": lid, "principal": principal, "termDays": term})
            return {"err": 0, "loan": view(conn, loan, hid)}

    @api.endpoint("/api/v1/loans/cancel", feature="LOANS")
    def cancel(conn, hid, form):
        lid = (form.get("loanID") or "").strip()
        with econ.tx(conn):
            cur = conn.execute("UPDATE loans SET status='cancelled', closed_at=? WHERE id=? AND borrower=? AND status='open'",
                               (econ.utcnow_iso(), lid, hid))
            if cur.rowcount != 1:
                raise econ.GameError("gone", "This request can no longer be cancelled")
            h.add_proto(conn, hid, "loancancelled", {"loan": lid})
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
            h.add_proto(conn, hid, "loanlent", {"loan": lid, "principal": loan["principal"], "total": total_due(loan)})
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
            if not loan or loan["status"] not in ("active", "overdue"):
                raise econ.GameError("gone", "Nothing to repay on this loan")
            outstanding = total_due(loan) - int(loan["repaid"])
            if outstanding <= 0:
                raise econ.GameError("gone", "This loan is already repaid")
            amount = int_arg(form, "amount", outstanding, 1, 10**14)
            amount = min(amount, outstanding)
            res = _pay(conn, loan, amount, now)
            loan = conn.execute("SELECT * FROM loans WHERE id=?", (lid,)).fetchone()
            if res["closed"]:                 # finished loans leave "My loans" and stay in the log
                for who in (loan["borrower"], loan["lender"]):
                    h.add_proto(conn, who, "loanrepaid", {"loan": lid, "total": total_due(loan),
                                                          "borrowed": who == loan["borrower"]})
            return {"err": 0, **res, "loan": view(conn, loan, hid)}
