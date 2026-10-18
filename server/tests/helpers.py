"""Shared helpers for system tests: register players through the real auth endpoint and call
the zlib-JSON system endpoints."""
import json
import zlib

from fastapi.testclient import TestClient

import main

client = TestClient(main.app)
_n = [0]
_PW = "password1"  # test accounts only


def new_player(prefix="p", credits=None, level=None, wh_level=None, password=_PW):
    """Register a fresh player; returns (hid, sid, name)."""
    _n[0] += 1
    name = f"{prefix}{_n[0]:04d}"[:20]
    r = client.post("/api/v1/auth/session", data={"name": name, "password": password, "mode": "register"})
    assert r.status_code == 200, r.text
    hid, sid = r.json()["hID"], r.json()["sid"]
    sets = {"credits": credits, "level": level, "wh_level": wh_level}
    with main.get_db() as conn:
        for col, v in sets.items():
            if v is not None:
                conn.execute(f"UPDATE players SET {col}=? WHERE hID=?", (v, hid))
        conn.commit()
    return hid, sid, name


def call(path, sid, **form):
    r = client.post(path, data={"sid": sid, **{k: str(v) for k, v in form.items()}})
    assert r.status_code == 200, r.text
    return json.loads(zlib.decompress(r.content))


def give(hid, item_id, qty):
    with main.get_db() as conn:
        conn.execute("INSERT INTO warehouse(hid,item_id,qty) VALUES(?,?,?) "
                     "ON CONFLICT(hid,item_id) DO UPDATE SET qty=qty+excluded.qty", (hid, item_id, qty))
        conn.commit()


def qty(hid, item_id):
    with main.get_db() as conn:
        r = conn.execute("SELECT qty FROM warehouse WHERE hid=? AND item_id=?", (hid, item_id)).fetchone()
        return r[0] if r else 0.0


def credits(hid):
    with main.get_db() as conn:
        return conn.execute("SELECT credits FROM players WHERE hID=?", (hid,)).fetchone()[0]


def set_building(hid, item_id, level):
    with main.get_db() as conn:
        conn.execute("DELETE FROM factories WHERE hid=? AND item_id=?", (hid, item_id))
        if level > 0:
            conn.execute("INSERT INTO factories(factory_id, hid, item_id, level) VALUES(?,?,?,?)",
                         (main.new_id(), hid, item_id, level))
        conn.commit()
