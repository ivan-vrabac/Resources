"""Accounts and sessions.

AUTH_MODE=secure (default): players sign in with company name + password through
/api/v1/auth/session and receive a signed session token (`sid`). Unsigned or forged
sids are rejected. The legacy name-only endpoints are disabled.

AUTH_MODE=mixed: transition mode. Password sign-in and signed sessions work as in
secure mode, but old clients keep working: the name-only endpoints stay enabled and
unsigned sids are accepted. Accounts that have set a password can no longer be opened
through the name-only login. Combine with AUTH_LEGACY_CLAIM=1 so existing players choose
their password at their first password sign-in.

AUTH_MODE=legacy: original protocol (name-only login, unsigned sid). Only for private
servers with trusted players and old clients.

The sid stays base64(JSON) with an "hID" field, so it remains wire-compatible; secure
mode adds "iat" and an HMAC "sig".
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import threading
import time

AUTH_MODE = os.environ.get("AUTH_MODE", "secure").strip().lower()
SESSION_TTL_S = int(os.environ.get("SESSION_TTL_DAYS", "90")) * 86400
# Accounts created before passwords existed have no hash. With AUTH_LEGACY_CLAIM=1 the
# first successful sign-in sets one (trust on first use). Otherwise an admin must set
# it with `python admin.py set-password`.
LEGACY_CLAIM = os.environ.get("AUTH_LEGACY_CLAIM", "0") == "1"
MIN_PASSWORD_LEN = 6
MAX_PASSWORD_LEN = 128

_secret: bytes = b""
_db_connect = None  # set by init(): opens a DB connection (for password lookups)


def _has_password(hid: str) -> bool:
    if _db_connect is None:
        return False
    conn = _db_connect()
    try:
        return conn.execute("SELECT 1 FROM player_auth WHERE hid=?", (hid,)).fetchone() is not None
    finally:
        conn.close()


def secure() -> bool:
    """Sessions are signed (secure and mixed)."""
    return AUTH_MODE != "legacy"


def legacy_allowed() -> bool:
    """Name-only endpoints and unsigned sids are accepted (legacy and mixed)."""
    return AUTH_MODE in ("legacy", "mixed")


def init(conn, db_connect=None) -> None:
    """Create auth tables and load the signing secret (env SESSION_SECRET, else stored in the DB).
    db_connect: callable returning a new connection (used to check for passwords per request)."""
    global _secret, _db_connect
    if db_connect is not None:
        _db_connect = db_connect
    conn.execute("""CREATE TABLE IF NOT EXISTS player_auth (
        hid        TEXT PRIMARY KEY,
        pw_hash    TEXT NOT NULL,
        updated_at INTEGER NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS server_secrets (
        name  TEXT PRIMARY KEY,
        value TEXT NOT NULL)""")
    env = os.environ.get("SESSION_SECRET", "")
    if env:
        _secret = env.encode()
    else:
        row = conn.execute("SELECT value FROM server_secrets WHERE name='session'").fetchone()
        if row:
            _secret = row[0].encode()
        else:
            value = secrets.token_urlsafe(48)
            conn.execute("INSERT INTO server_secrets(name, value) VALUES('session', ?)", (value,))
            _secret = value.encode()
    conn.commit()


# ── passwords ────────────────────────────────────────────────────────────────

_N, _R, _P = 2 ** 14, 8, 1


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def _unb64(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(password.encode(), salt=salt, n=_N, r=_R, p=_P, dklen=32)
    return f"scrypt${_N}${_R}${_P}${_b64(salt)}${_b64(dk)}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, n, r, p, salt, dk = stored.split("$")
        if algo != "scrypt":
            return False
        got = hashlib.scrypt(password.encode(), salt=_unb64(salt), n=int(n), r=int(r), p=int(p),
                             dklen=len(_unb64(dk)))
        return hmac.compare_digest(got, _unb64(dk))
    except Exception:
        return False


def password_problem(password: str) -> str | None:
    if len(password) < MIN_PASSWORD_LEN:
        return f"Password must be at least {MIN_PASSWORD_LEN} characters"
    if len(password) > MAX_PASSWORD_LEN:
        return "Password is too long"
    return None


def set_password(conn, hid: str, password: str) -> None:
    conn.execute("INSERT INTO player_auth(hid, pw_hash, updated_at) VALUES(?,?,?) "
                 "ON CONFLICT(hid) DO UPDATE SET pw_hash=excluded.pw_hash, updated_at=excluded.updated_at",
                 (hid, hash_password(password), int(time.time())))


def get_hash(conn, hid: str) -> str | None:
    row = conn.execute("SELECT pw_hash FROM player_auth WHERE hid=?", (hid,)).fetchone()
    return row[0] if row else None


# ── sessions ─────────────────────────────────────────────────────────────────

def _sig(hid: str, iat: int) -> str:
    return _b64(hmac.new(_secret, f"{hid}.{iat}".encode(), hashlib.sha256).digest())


def make_session(hid: str) -> str:
    payload = {"hID": hid}
    if secure():
        iat = int(time.time())
        payload.update(iat=iat, sig=_sig(hid, iat))
    return base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("=")


def hid_from_sid(sid: str) -> str:
    """Return the player ID for a session, or "" if it is missing, malformed, forged or expired."""
    try:
        padded = sid + "=" * (-len(sid) % 4)
        # Older clients encode with the URL-safe alphabet.
        raw = (base64.urlsafe_b64decode(padded) if ("-" in sid or "_" in sid)
               else base64.b64decode(padded))
        data = json.loads(raw.decode())
        hid = data.get("hID", "")
    except Exception:
        return ""
    if not isinstance(hid, str) or not hid:
        return ""
    if not secure():
        return hid
    iat, sig = data.get("iat"), data.get("sig")
    if iat is None and sig is None and legacy_allowed():
        # Unsigned session from an old client (mixed mode) — only for accounts that have
        # not set a password yet; a password-protected account needs a signed session.
        if AUTH_MODE == "mixed" and _has_password(hid):
            return ""
        return hid
    if not isinstance(iat, int) or not isinstance(sig, str):
        return ""
    if iat + SESSION_TTL_S < time.time() or iat > time.time() + 300:
        return ""
    return hid if hmac.compare_digest(sig, _sig(hid, iat)) else ""


# ── brute-force protection ───────────────────────────────────────────────────

class FailureLimiter:
    """Blocks a key after `limit` failures within `window` seconds."""

    def __init__(self, limit: int = 10, window: int = 900):
        self.limit, self.window = limit, window
        self._fails: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def _recent(self, key: str, now: float) -> list[float]:
        lst = [t for t in self._fails.get(key, []) if now - t < self.window]
        if lst:
            self._fails[key] = lst
        else:
            self._fails.pop(key, None)
        return lst

    def blocked(self, *keys: str) -> bool:
        now = time.time()
        with self._lock:
            return any(len(self._recent(k, now)) >= self.limit for k in keys)

    def fail(self, *keys: str) -> None:
        now = time.time()
        with self._lock:
            for k in keys:
                self._recent(k, now)
                self._fails.setdefault(k, []).append(now)

    def reset(self, *keys: str) -> None:
        with self._lock:
            for k in keys:
                self._fails.pop(k, None)


limiter = FailureLimiter()
