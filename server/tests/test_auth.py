import base64
import json
import zlib

from fastapi.testclient import TestClient

import auth
import main

client = TestClient(main.app)


def signin(name, password):
    return client.post("/api/v1/auth/session", data={"name": name, "password": password})


def forged_sid(hid: str) -> str:
    return base64.b64encode(json.dumps({"hID": hid}).encode()).decode().rstrip("=")


def player_data(sid: str):
    return json.loads(zlib.decompress(
        client.post("/flut23/playerGetData.php", data={"sid": sid}).content))


def test_register_then_login():
    r = signin("Alpha Corp", "hunter22")
    assert r.status_code == 200 and r.json()["created"] is True
    hid = r.json()["hID"]
    r2 = signin("alpha corp", "hunter22")  # names are case-insensitive
    assert r2.status_code == 200 and r2.json()["created"] is False
    assert r2.json()["hID"] == hid
    assert player_data(r2.json()["sid"])[0]["hID"] == hid


def test_wrong_password_rejected():
    signin("Beta Corp", "correct-horse")
    r = signin("Beta Corp", "wrong-horse")
    assert r.status_code == 401
    assert "sid" not in r.json()


def test_weak_password_rejected():
    r = signin("Gamma Corp", "123")
    assert r.json()["error"] == "weak_password"


def test_invalid_name_rejected():
    assert signin("x" * 21, "longenough").json()["error"] == "invalid_name"
    r = signin("<script>", "longenough")
    assert r.json()["error"] == "invalid_name"


def test_forged_unsigned_sid_rejected():
    hid = signin("Delta Corp", "password1").json()["hID"]
    assert player_data(forged_sid(hid)) == []


def test_tampered_signature_rejected():
    sid = signin("Epsilon Corp", "password1").json()["sid"]
    data = json.loads(base64.b64decode(sid + "=" * (-len(sid) % 4)))
    data["hID"] = "0" * 32
    tampered = base64.b64encode(json.dumps(data).encode()).decode().rstrip("=")
    assert auth.hid_from_sid(tampered) == ""


def test_expired_session_rejected(monkeypatch):
    sid = signin("Zeta Corp", "password1").json()["sid"]
    assert auth.hid_from_sid(sid)
    monkeypatch.setattr(auth, "SESSION_TTL_S", -1)
    assert auth.hid_from_sid(sid) == ""


def test_legacy_endpoints_disabled_in_secure_mode():
    signin("Eta Corp", "password1")
    assert client.post("/flut23/playerLogin.php", data={"userEmail": "Eta Corp"}).json() == []
    assert client.post("/flut23/playerNew.php", data={"userEmail": "Theta Corp"}).text == ""


def test_rate_limit_after_repeated_failures():
    signin("Iota Corp", "password1")
    for _ in range(auth.limiter.limit):
        signin("Iota Corp", "nope-nope")
    r = signin("Iota Corp", "password1")  # even the right password is blocked for now
    assert r.status_code == 429
    auth.limiter.reset("name:iota corp", "ip:testclient")


def test_change_password():
    sid = signin("Kappa Corp", "old-password").json()["sid"]
    url = "/api/v1/auth/password"
    assert client.post(url, data={"sid": sid, "old_password": "nope-nope",
                                  "new_password": "new-password"}).status_code == 401
    assert client.post(url, data={"sid": sid, "old_password": "old-password",
                                  "new_password": "x"}).json()["error"] == "weak_password"
    assert client.post(url, data={"sid": forged_sid("whatever"), "old_password": "old-password",
                                  "new_password": "new-password"}).status_code == 401
    r = client.post(url, data={"sid": sid, "old_password": "old-password", "new_password": "new-password"})
    assert r.json() == {"ok": True}
    assert signin("Kappa Corp", "old-password").status_code == 401
    assert signin("Kappa Corp", "new-password").status_code == 200


def test_legacy_mode_accepts_unsigned_sessions(monkeypatch):
    hid = signin("Lambda Corp", "password1").json()["hID"]
    assert auth.hid_from_sid(forged_sid(hid)) == ""
    monkeypatch.setattr(auth, "AUTH_MODE", "legacy")
    assert auth.hid_from_sid(forged_sid(hid)) == hid
    r = client.post("/flut23/playerLogin.php", data={"userEmail": "Lambda Corp"})
    assert r.json() == [{"hID": hid, "active": 1}]


def test_login_and_register_modes():
    r = client.post("/api/v1/auth/session", data={"name": "Mu Corp", "password": "password1", "mode": "login"})
    assert r.json()["error"] == "not_found"
    r = client.post("/api/v1/auth/session", data={"name": "Mu Corp", "password": "password1", "mode": "register"})
    assert r.status_code == 200 and r.json()["created"] is True
    r = client.post("/api/v1/auth/session", data={"name": "mu corp", "password": "other-pass", "mode": "register"})
    assert r.json()["error"] == "name_taken"
    r = client.post("/api/v1/auth/session", data={"name": "Mu Corp", "password": "password1", "mode": "login"})
    assert r.status_code == 200 and r.json()["created"] is False


def test_mixed_mode_keeps_old_clients_and_protects_passwords(monkeypatch):
    monkeypatch.setattr(auth, "AUTH_MODE", "mixed")
    monkeypatch.setattr(auth, "LEGACY_CLAIM", True)
    # an old client registers and plays name-only
    hid = client.post("/flut23/playerNew.php", data={"userEmail": "Nu Corp"}).text
    assert len(hid) == 32
    assert player_data(forged_sid(hid))[0]["hID"] == hid          # unsigned sid accepted
    urlsafe = base64.urlsafe_b64encode(json.dumps({"hID": hid}).encode()).decode().rstrip("=")
    assert auth.hid_from_sid(urlsafe) == hid                      # old app's URL-safe encoding
    assert client.post("/flut23/playerLogin.php", data={"userEmail": "Nu Corp"}).json()[0]["hID"] == hid
    # the player opens the new app and logs in, choosing a password (legacy claim)
    r = signin("Nu Corp", "my-new-pass")
    assert r.status_code == 200 and r.json()["hID"] == hid
    # now the name-only paths no longer open the account
    assert client.post("/flut23/playerLogin.php", data={"userEmail": "Nu Corp"}).json() == []
    assert client.post("/flut23/playerNew.php", data={"userEmail": "Nu Corp"}).text == ""
    assert signin("Nu Corp", "wrong-pass").status_code == 401
    # signed sessions still verified; tampering still rejected
    sid = r.json()["sid"]
    assert auth.hid_from_sid(sid) == hid
    d = json.loads(base64.b64decode(sid + "=" * (-len(sid) % 4)))
    d["hID"] = "0" * 32
    assert auth.hid_from_sid(base64.b64encode(json.dumps(d).encode()).decode()) == ""


def test_mixed_mode_unsigned_sid_rejected_for_password_accounts(monkeypatch):
    monkeypatch.setattr(auth, "AUTH_MODE", "mixed")
    monkeypatch.setattr(auth, "LEGACY_CLAIM", True)
    old_hid = client.post("/flut23/playerNew.php", data={"userEmail": "Xi Corp"}).text
    assert auth.hid_from_sid(forged_sid(old_hid)) == old_hid       # no password yet: still works
    signin("Xi Corp", "now-protected")                              # player sets a password
    assert auth.hid_from_sid(forged_sid(old_hid)) == ""            # unsigned sid no longer opens it
    assert player_data(forged_sid(old_hid)) == []


def test_other_players_internal_ids_not_exposed():
    a = signin("Omicron Corp", "password1").json()
    b = signin("Pi Corp", "password1").json()
    with main.get_db() as conn:
        conn.execute("INSERT INTO mines(mine_id, owner_hid, lat, lng, item_id, quality, last_coll, created_at) "
                     "VALUES('omimine', ?, 10.0, 10.0, 4, 50, '2026-01-01', '2026-01-01')", (a["hID"],))
        conn.execute("INSERT OR REPLACE INTO hq(hid, lat, lng, level) VALUES(?, 10.0, 10.0, 3)", (a["hID"],))
        conn.commit()
    box = {"sid": b["sid"], "lat1": 9.9, "lng1": 9.9, "lat2": 10.1, "lng2": 10.1}
    markers = json.loads(zlib.decompress(client.post("/flut23/mineLoadMarkers.php", data=box).content))
    hqs = json.loads(zlib.decompress(client.post("/flut23/HQGetMarkers.php", data=box).content))
    lb = json.loads(zlib.decompress(client.post("/flut23/leaderboard.php", data={"sid": b["sid"]}).content))
    blob = json.dumps([markers, hqs, lb])
    assert a["hID"] not in blob
    assert any(m["ownerName"] == "omicron corp" for m in markers)
    # the owner still sees their own id (old clients compare it)
    own = json.loads(zlib.decompress(client.post("/flut23/mineLoadMarkers.php",
                                                 data={**box, "sid": a["sid"]}).content))
    assert any(m["ownerHID"] == a["hID"] and m["isMine"] for m in own)


def test_password_hash_roundtrip():
    h = auth.hash_password("s3cret!")
    assert h.startswith("scrypt$") and "s3cret" not in h
    assert auth.verify_password("s3cret!", h)
    assert not auth.verify_password("s3cret?", h)


def test_unprotected_legacy_account_needs_admin(monkeypatch):
    with main.get_db() as conn:
        conn.execute("INSERT INTO players(hID, company_name) VALUES('legacyhid0000000000000000000001', 'old co')")
        conn.commit()
    r = signin("Old Co", "password1")
    assert r.json()["error"] == "no_password"
    monkeypatch.setattr(auth, "LEGACY_CLAIM", True)
    r = signin("Old Co", "password1")
    assert r.status_code == 200 and r.json()["hID"] == "legacyhid0000000000000000000001"
