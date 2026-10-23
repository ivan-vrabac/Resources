"""Phase 1 — public player profiles, contacts (friends / enemies / blacklist / watchlist),
player search and chat (history, ordering, rate limiting, server-side blocking).

Players are identified to other players only by a random public id (`pid`), never by their
internal hID: in AUTH_MODE=mixed an hID still works like a password for accounts without one.

Public profile fields (deliberately limited): company name, level, HQ level, current mine
count, total mines ever built, total production per hour, country, member since, rankings
(by XP and by mine count), achievements. Never: credits, inventory, coordinates.
"""
from __future__ import annotations

import datetime

import secrets

import econ
from . import int_arg

CONTACT_KINDS = ("friend", "enemy", "blacklist", "watch")
# Adding a contact of one kind removes conflicting kinds for the same player.
_CONFLICTS = {"friend": ("enemy", "blacklist"), "enemy": ("friend",), "blacklist": ("friend",), "watch": ()}

chat_limit_burst = econ.RateLimit(5, 10)    # max 5 messages / 10 s
chat_limit_minute = econ.RateLimit(20, 60)  # max 20 messages / minute
CHAT_MAX_LEN = 500


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS player_public (
            hid TEXT PRIMARY KEY,
            pid TEXT UNIQUE NOT NULL
        );
        CREATE TABLE IF NOT EXISTS contacts (
            owner_hid  TEXT NOT NULL,
            target_hid TEXT NOT NULL,
            kind       TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (owner_hid, target_hid, kind)
        );
        CREATE INDEX IF NOT EXISTS idx_contacts_target ON contacts(target_hid, kind);
        CREATE TABLE IF NOT EXISTS achievements (
            hid   TEXT NOT NULL,
            code  TEXT NOT NULL,
            title TEXT NOT NULL,
            ts    TEXT NOT NULL,
            PRIMARY KEY (hid, code)
        );
        CREATE INDEX IF NOT EXISTS idx_chat_id ON chat_messages(id);
    """)
    conn.commit()


# ── public ids ───────────────────────────────────────────────────────────────

def pid_of(conn, hid: str) -> str:
    r = conn.execute("SELECT pid FROM player_public WHERE hid=?", (hid,)).fetchone()
    if r:
        return r[0]
    pid = secrets.token_hex(8)
    conn.execute("INSERT OR IGNORE INTO player_public(hid, pid) VALUES(?,?)", (hid, pid))
    return conn.execute("SELECT pid FROM player_public WHERE hid=?", (hid,)).fetchone()[0]


def hid_of(conn, pid: str) -> str:
    r = conn.execute("SELECT hid FROM player_public WHERE pid=?", ((pid or "").strip(),)).fetchone()
    if not r:
        raise econ.GameError("no_player", "Player not found")
    return r[0]


def blocked_by(conn, viewer_hid: str) -> set:
    return {r[0] for r in conn.execute(
        "SELECT target_hid FROM contacts WHERE owner_hid=? AND kind='blacklist'", (viewer_hid,))}


# ── profile ──────────────────────────────────────────────────────────────────

def _rank(conn, value, sql) -> int:
    return conn.execute(sql, (value,)).fetchone()[0] + 1


def public_profile(conn, h, viewer_hid: str, target_hid: str) -> dict:
    p = conn.execute("SELECT * FROM players WHERE hID=?", (target_hid,)).fetchone()
    if not p:
        raise econ.GameError("no_player", "Player not found")
    hq = conn.execute("SELECT level FROM hq WHERE hid=?", (target_hid,)).fetchone()
    mines = conn.execute("SELECT COUNT(*) FROM mines WHERE owner_hid=?", (target_hid,)).fetchone()[0]
    ever = conn.execute("SELECT COUNT(*) FROM game_events WHERE hid=? AND type='mine_built'",
                        (target_hid,)).fetchone()[0]
    stats = h.mine_stats(conn, target_hid) if hasattr(h, "mine_stats") else {}
    xp = p["xp"] or 0
    rank_xp = _rank(conn, xp, "SELECT COUNT(*) FROM players WHERE COALESCE(xp,0) > ?")
    rank_mines = _rank(conn, mines,
                       "SELECT COUNT(*) FROM (SELECT owner_hid, COUNT(*) c FROM mines GROUP BY owner_hid) WHERE c > ?")
    rel = {r[0] for r in conn.execute("SELECT kind FROM contacts WHERE owner_hid=? AND target_hid=?",
                                      (viewer_hid, target_hid))}
    ach = [{"code": r[0], "title": r[1], "ts": r[2]} for r in conn.execute(
        "SELECT code, title, ts FROM achievements WHERE hid=? ORDER BY ts DESC LIMIT 50", (target_hid,))]
    out = {
        "pid": pid_of(conn, target_hid),
        "name": p["company_name"],
        "level": p["level"] or 1,
        "hqLevel": hq[0] if hq else 0,
        "mines": mines,
        "minesEverBuilt": max(ever, mines),
        "productionPerHour": round(stats.get("totalRateHr", 0.0)),
        "country": p["country_code"] if "country_code" in p.keys() else None,
        "memberSince": (p["created_at"] or "")[:10],
        "rankXp": rank_xp,
        "rankMines": rank_mines,
        "achievements": ach,
        "isMe": viewer_hid == target_hid,
        "relations": sorted(rel),
    }
    # public company sheet: age, mines by type, factories, special buildings, luxury, combat
    try:
        created = datetime.datetime.fromisoformat(p["created_at"])
        out["ageDays"] = max(0, (econ.utcnow() - created).days)
    except (TypeError, ValueError):
        out["ageDays"] = None
    out["minesByType"] = [{"itemID": r[0], "count": r[1]} for r in conn.execute(
        "SELECT item_id, COUNT(*) FROM mines WHERE owner_hid=? GROUP BY item_id ORDER BY COUNT(*) DESC", (target_hid,))]
    special = set(getattr(h, "SPECIAL_BUILDINGS", {}) or {})
    facs = conn.execute("SELECT item_id, level FROM factories WHERE hid=? ORDER BY item_id", (target_hid,)).fetchall()
    out["factories"] = [{"itemID": r[0], "level": r[1]} for r in facs if r[0] not in special]
    out["specialBuildings"] = [{"itemID": r[0], "level": r[1]} for r in facs if r[0] in special]
    lux = conn.execute("SELECT points FROM luxury_points WHERE hid=?", (target_hid,)).fetchone() \
        if _has_table(conn, "luxury_points") else None
    out["luxuryPoints"] = int(lux[0]) if lux else 0
    out["luxuryItems"] = [{"itemID": r[0], "qty": int(r[1])} for r in conn.execute(
        "SELECT item_id, qty FROM luxury_items WHERE hid=? AND qty>=1 ORDER BY item_id", (target_hid,))] \
        if _has_table(conn, "luxury_items") else []
    out["artifacts"] = int(conn.execute(
        "SELECT COALESCE(SUM(qty),0) FROM warehouse WHERE hid=? AND item_id BETWEEN 172 AND 177", (target_hid,)).fetchone()[0])
    if _has_table(conn, "attacks"):
        a = conn.execute("SELECT COALESCE(SUM(success),0), COUNT(*) FROM attacks WHERE attacker_hid=?", (target_hid,)).fetchone()
        d = conn.execute("SELECT COALESCE(SUM(1-success),0), COUNT(*) FROM attacks WHERE defender_hid=?", (target_hid,)).fetchone()
        out["combat"] = {"attacksWon": a[0], "attacks": a[1], "defencesWon": d[0], "defences": d[1]}
    if viewer_hid == target_hid:  # private extras only for yourself
        out["xp"] = xp
        out["credits"] = p["credits"]
    return out


MESSAGE_KEEP_DAYS = 7     # owner 2026-10-20: chat and private messages are kept one week


def purge_old_messages(conn) -> None:
    """Delete chat and private messages older than MESSAGE_KEEP_DAYS (inside the caller's tx)."""
    cutoff = (econ.utcnow() - datetime.timedelta(days=MESSAGE_KEEP_DAYS)).isoformat()
    conn.execute("DELETE FROM chat_messages WHERE ts < ?", (cutoff,))
    if _has_table(conn, "private_messages"):
        conn.execute("DELETE FROM private_messages WHERE ts < ?", (cutoff,))


def _has_table(conn, name) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _summary(conn, hid) -> dict:
    p = conn.execute("SELECT company_name, level FROM players WHERE hID=?", (hid,)).fetchone()
    hq = conn.execute("SELECT level FROM hq WHERE hid=?", (hid,)).fetchone()
    return {"pid": pid_of(conn, hid), "name": p[0] if p else "?", "level": (p[1] if p else 1) or 1,
            "hqLevel": hq[0] if hq else 0}


def public_ref(conn, hid) -> dict:
    """Public reference to a player for other systems (no internal id)."""
    return _summary(conn, hid)


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)

    @api.endpoint("/api/v1/social/profile", feature="SOCIAL")
    def profile(conn, hid, form):
        """Profile of `pid`, or the caller's own profile when pid is empty."""
        pid = (form.get("pid") or "").strip()
        target = hid_of(conn, pid) if pid else hid
        out = public_profile(conn, h, hid, target)
        return {"err": 0, "profile": out}

    @api.endpoint("/api/v1/social/search", feature="SOCIAL")
    def search(conn, hid, form):
        q = (form.get("q") or "").strip().lower()
        if len(q) < 2:
            raise econ.GameError("bad_input", "Type at least 2 characters")
        like = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        rows = conn.execute("SELECT hID FROM players WHERE company_name LIKE ? ESCAPE '\\' "
                            "ORDER BY company_name LIMIT 25", (like,)).fetchall()
        return {"err": 0, "players": [_summary(conn, r[0]) for r in rows]}

    @api.endpoint("/api/v1/social/contacts", feature="SOCIAL")
    def contacts(conn, hid, form):
        out = {k: [] for k in CONTACT_KINDS}
        unread = {}
        if _has_table(conn, "private_messages"):
            unread = dict(conn.execute("SELECT from_hid, COUNT(*) FROM private_messages WHERE to_hid=? "
                                       "AND read_at IS NULL GROUP BY from_hid", (hid,)).fetchall())
        for r in conn.execute("SELECT target_hid, kind, created_at FROM contacts WHERE owner_hid=? "
                              "ORDER BY created_at DESC", (hid,)):
            if conn.execute("SELECT 1 FROM players WHERE hID=?", (r[0],)).fetchone():
                out[r[1]].append({**_summary(conn, r[0]), "since": r[2], "unread": int(unread.get(r[0], 0))})
        return {"err": 0, "contacts": out}

    @api.endpoint("/api/v1/social/contact", feature="SOCIAL")
    def contact(conn, hid, form):
        """action=add|remove, kind=friend|enemy|blacklist|watch, pid=<player>"""
        kind, action = form.get("kind", ""), form.get("action", "add")
        if kind not in CONTACT_KINDS or action not in ("add", "remove"):
            raise econ.GameError("bad_input", "Invalid contact action")
        target = hid_of(conn, form.get("pid", ""))
        if target == hid:
            raise econ.GameError("bad_input", "You can't add yourself")
        with econ.tx(conn):
            if action == "add":
                n = conn.execute("SELECT COUNT(*) FROM contacts WHERE owner_hid=? AND kind=?",
                                 (hid, kind)).fetchone()[0]
                if n >= 500:
                    raise econ.GameError("limit", "Contact list is full (500)")
                for other in _CONFLICTS[kind]:
                    conn.execute("DELETE FROM contacts WHERE owner_hid=? AND target_hid=? AND kind=?",
                                 (hid, target, other))
                conn.execute("INSERT OR IGNORE INTO contacts(owner_hid, target_hid, kind, created_at) "
                             "VALUES(?,?,?,?)", (hid, target, kind, econ.utcnow_iso()))
            else:
                conn.execute("DELETE FROM contacts WHERE owner_hid=? AND target_hid=? AND kind=?",
                             (hid, target, kind))
        rel = sorted(r[0] for r in conn.execute(
            "SELECT kind FROM contacts WHERE owner_hid=? AND target_hid=?", (hid, target)))
        return {"err": 0, "relations": rel}

    # ── chat ────────────────────────────────────────────────────────────────

    def _messages(conn, hid, where, args, limit):
        hidden = blocked_by(conn, hid)
        rows = conn.execute(f"SELECT id, hid, name, msg, ts FROM chat_messages WHERE {where} "
                            f"ORDER BY id DESC LIMIT ?", args + (limit,)).fetchall()
        out = []
        for r in reversed(rows):  # oldest first; ids give a total order
            if r[1] in hidden:
                continue
            out.append({"id": r[0], "pid": pid_of(conn, r[1]), "name": r[2], "msg": r[3],
                        "ts": r[4], "isMe": r[1] == hid})
        return out

    @api.endpoint("/api/v1/chat/messages", feature="SOCIAL")
    def chat_messages(conn, hid, form):
        """after=<id>: newer messages (polling). before=<id>: older history page. Neither: latest."""
        limit = int_arg(form, "limit", 50, 1, 100)
        after, before = form.get("after"), form.get("before")
        if after not in (None, ""):
            msgs = _messages(conn, hid, "id > ?", (int_arg(form, "after", 0, 0),), limit)
        elif before not in (None, ""):
            msgs = _messages(conn, hid, "id < ?", (int_arg(form, "before", 0, 0),), limit)
        else:
            msgs = _messages(conn, hid, "1=1", (), limit)
        latest = conn.execute("SELECT COALESCE(MAX(id),0) FROM chat_messages").fetchone()[0]
        conn.commit()  # pid_of may have created ids
        return {"err": 0, "messages": msgs, "latestId": latest}

    @api.endpoint("/api/v1/chat/unread", feature="SOCIAL")
    def chat_unread(conn, hid, form):
        """Messages after `seen` from other, non-blocked players (capped at 99)."""
        seen = int_arg(form, "seen", 0, 0)
        hidden = blocked_by(conn, hid) | {hid}
        rows = conn.execute("SELECT hid FROM chat_messages WHERE id > ? ORDER BY id DESC LIMIT 500",
                            (seen,)).fetchall()
        count = sum(1 for r in rows if r[0] not in hidden)
        latest = conn.execute("SELECT COALESCE(MAX(id),0) FROM chat_messages").fetchone()[0]
        return {"err": 0, "unread": min(count, 99), "latestId": latest}

    @api.endpoint("/api/v1/chat/send", feature="SOCIAL")
    def chat_send(conn, hid, form):
        msg = " ".join((form.get("msg") or "").split())
        if not msg:
            raise econ.GameError("bad_input", "Message is empty")
        if len(msg) > CHAT_MAX_LEN:
            raise econ.GameError("bad_input", f"Message is too long (max {CHAT_MAX_LEN})")
        if not (chat_limit_burst.allow(hid) and chat_limit_minute.allow(hid)):
            raise econ.GameError("rate_limited", "You're sending messages too fast")
        last = conn.execute("SELECT msg FROM chat_messages WHERE hid=? ORDER BY id DESC LIMIT 1",
                            (hid,)).fetchone()
        if last and last[0] == msg:
            raise econ.GameError("duplicate", "You just sent that message")
        name = conn.execute("SELECT company_name FROM players WHERE hID=?", (hid,)).fetchone()[0]
        with econ.tx(conn):
            cur = conn.execute("INSERT INTO chat_messages(hid, name, msg, ts) VALUES(?,?,?,?)",
                               (hid, name, msg, econ.utcnow_iso()))
            new_id = cur.lastrowid
            conn.execute("DELETE FROM chat_messages WHERE id <= ?", (new_id - 5000,))
            purge_old_messages(conn)
        return {"err": 0, "id": new_id}

    # ── private messages (owner 2026-10-19) ──────────────────────────────────
    with h.get_db() as c0:
        c0.executescript("""
            CREATE TABLE IF NOT EXISTS private_messages (
                id       INTEGER PRIMARY KEY AUTOINCREMENT,
                from_hid TEXT NOT NULL,
                to_hid   TEXT NOT NULL,
                msg      TEXT NOT NULL,
                ts       TEXT NOT NULL,
                read_at  TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_pm_to ON private_messages(to_hid, id);
            CREATE INDEX IF NOT EXISTS idx_pm_from ON private_messages(from_hid, id);
        """)
        c0.commit()

    @api.endpoint("/api/v1/chat/dm/send", feature="SOCIAL")
    def dm_send(conn, hid, form):
        """Send a private message to a player (by public id). Blocked senders are refused."""
        target = hid_of(conn, form.get("pid"))
        if target == hid:
            raise econ.GameError("bad_input", "You can't message yourself")
        msg = " ".join((form.get("msg") or "").split())
        if not msg:
            raise econ.GameError("bad_input", "Message is empty")
        if len(msg) > CHAT_MAX_LEN:
            raise econ.GameError("bad_input", f"Message is too long (max {CHAT_MAX_LEN})")
        if hid in blocked_by(conn, target):
            raise econ.GameError("blocked", "This player doesn't accept your messages")
        if not (chat_limit_burst.allow(hid) and chat_limit_minute.allow(hid)):
            raise econ.GameError("rate_limited", "You're sending messages too fast")
        with econ.tx(conn):
            cur = conn.execute("INSERT INTO private_messages(from_hid, to_hid, msg, ts) VALUES(?,?,?,?)",
                               (hid, target, msg, econ.utcnow_iso()))
            purge_old_messages(conn)
        try:
            with h.get_db() as c2:
                name = c2.execute("SELECT company_name FROM players WHERE hID=?", (hid,)).fetchone()[0]
                h.push(c2, target, f"Message from {name}", msg[:120])
        except Exception:
            pass
        return {"err": 0, "id": cur.lastrowid}

    @api.endpoint("/api/v1/chat/dm/threads", feature="SOCIAL")
    def dm_threads(conn, hid, form):
        """Your conversations: other player, last message, unread count (newest first)."""
        rows = conn.execute("""
            SELECT other, MAX(id) AS last_id, SUM(unread) AS unread FROM (
                SELECT to_hid AS other, id, 0 AS unread FROM private_messages WHERE from_hid=?
                UNION ALL
                SELECT from_hid AS other, id, CASE WHEN read_at IS NULL THEN 1 ELSE 0 END FROM private_messages WHERE to_hid=?
            ) GROUP BY other ORDER BY last_id DESC LIMIT 100""", (hid, hid)).fetchall()
        hidden = blocked_by(conn, hid)
        out = []
        for r in rows:
            if r[0] in hidden:
                continue
            last = conn.execute("SELECT msg, ts, from_hid FROM private_messages WHERE id=?", (r[1],)).fetchone()
            out.append({**_summary(conn, r[0]), "last": last[0], "ts": last[1], "lastFromMe": last[2] == hid,
                        "unread": int(r[2] or 0)})
        conn.commit()
        return {"err": 0, "threads": out, "unread": sum(t["unread"] for t in out)}

    @api.endpoint("/api/v1/chat/dm/messages", feature="SOCIAL")
    def dm_messages(conn, hid, form):
        """Conversation with one player (marks their messages to you as read). before=<id> pages back."""
        other = hid_of(conn, form.get("pid"))
        before = int_arg(form, "before", 0, 0)
        q = ("SELECT id, from_hid, msg, ts FROM private_messages WHERE "
             "((from_hid=? AND to_hid=?) OR (from_hid=? AND to_hid=?))" + (" AND id < ?" if before else "")
             + " ORDER BY id DESC LIMIT 50")
        args = (hid, other, other, hid) + ((before,) if before else ())
        rows = conn.execute(q, args).fetchall()
        with econ.tx(conn):
            conn.execute("UPDATE private_messages SET read_at=? WHERE to_hid=? AND from_hid=? AND read_at IS NULL",
                         (econ.utcnow_iso(), hid, other))
        return {"err": 0, "with": _summary(conn, other),
                "messages": [{"id": r[0], "isMe": r[1] == hid, "msg": r[2], "ts": r[3]} for r in reversed(rows)]}

