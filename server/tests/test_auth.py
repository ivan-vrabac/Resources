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
