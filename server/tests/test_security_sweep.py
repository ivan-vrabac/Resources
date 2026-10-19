"""Phase 11: cross-system checks — every v1 route needs a valid session, and no response leaks
another player's internal id (hID)."""
import json
import zlib

import econ
import main
from helpers import call, client, give, new_player, set_building
from systems import news as N

OPEN_ROUTES = {"/api/v1/auth/session", "/api/v1/auth/status", "/api/v1/auth/claim"}


def _v1_routes():
    return sorted({r.path for r in main.app.routes if getattr(r, "path", "").startswith("/api/v1/")} - OPEN_ROUTES)


def test_every_v1_route_rejects_missing_or_forged_session():
    routes = _v1_routes()
    assert len(routes) > 30
    for path in routes:
        for sid in ("", "forged", "eyJoSUQiOiAieCJ9"):
            r = client.post(path, data={"sid": sid})
            if r.status_code == 405:
                continue
            body = json.loads(zlib.decompress(r.content)) if r.headers.get("content-type", "").startswith(
                "application/octet") or r.content[:1] == b"x" else r.json()
            assert body.get("err") or body.get("error"), (path, sid, body)


def test_no_foreign_hid_in_responses():
    a, a_sid, _ = new_player("sx1", credits=10**10)
    b, b_sid, b_name = new_player("sx2", credits=10**10)
    for h in (a, b):
        with main.get_db() as conn:
            conn.execute("INSERT OR REPLACE INTO hq(hid, lat, lng, level) VALUES(?,?,?,10)", (h, 45.1, 15.1))
            conn.execute("UPDATE players SET created_at='2020-01-01 00:00:00' WHERE hID=?", (h,))
            conn.execute("INSERT INTO ledger(ts, hid, kind, credits) VALUES(?,?,?,?)",
                         (econ.utcnow_iso(), h, "system_sell", 10**8))
            conn.commit()
    mid = main.new_id()
    with main.get_db() as conn:
        conn.execute("INSERT INTO mines(mine_id, owner_hid, lat, lng, item_id, quality, condition) "
                     "VALUES(?,?,?,?,4,100,50)", (mid, b, 45.1, 15.1))
        econ.emit(conn, "casino_jackpot", b, {"amount": 1})
        conn.commit()
    call("/api/v1/loans/request", b_sid, principal=50_000, termDays=7)
    lot = call("/api/v1/auctions", b_sid)["active"][0]
    call("/api/v1/auctions/bid", b_sid, auctionID=lot["id"], amount=lot["minBid"])
    call("/api/v1/chat/send", b_sid, msg="hello")
    with main.get_db() as conn:
        with econ.tx(conn):
            N.digest_events(conn)
    set_building(a, 86, 10)
    give(a, 104, 1)
    responses = [
        call("/api/v1/loans/list", a_sid), call("/api/v1/auctions", a_sid), call("/api/v1/news", a_sid),
        call("/api/v1/social/search", a_sid, q=b_name), call("/api/v1/combat/info", a_sid, mineID=mid),
        call("/api/v1/chat/messages", a_sid), call("/api/v1/market/overview", a_sid),
        call("/api/v1/combat/attack", a_sid, mineID=mid, lat=45.1, lng=15.1, army=1),
        call("/api/v1/loans/mine", a_sid),
    ]
    for r in responses:
        assert b not in json.dumps(r), r
