"""Names keep their capitals (owner 2026-10-24) but sign-in and uniqueness ignore case."""
import json
import zlib

from helpers import client, call

PW = "Secret-pass-123"


def session(name, mode=""):
    r = client.post("/api/v1/auth/session", data={"name": name, "password": PW, "mode": mode})
    return r.json()


def test_name_keeps_capitals_but_is_case_insensitive():
    a = session("BigMine Co", "register")
    assert a.get("created") is True
    data = json.loads(zlib.decompress(client.post("/flut23/playerGetData.php", data={"sid": a["sid"]}).content))
    assert data[0]["pN"] == "BigMine Co"
    assert session("bigmine co", "login")["hID"] == a["hID"]            # any case signs in
    assert session("BIGMINE CO", "register")["error"] == "name_taken"  # no second account in other case
    r = call("/api/v1/account/rename", a["sid"], name="BIGMINE CO")    # only the capitals: free
    assert r["err"] == 0 and r["name"] == "BIGMINE CO" and r["costGD"] == 0