"""Smoke tests against a throwaway database. Never point these at a real game.db.

Run from server/:  python -m pytest -q
"""
import base64
import json
import os
import sqlite3
import sys
import tempfile
import zlib
from pathlib import Path

import pytest

_TMP = tempfile.mkdtemp(prefix="resources-test-")
os.environ["DB_PATH"] = os.path.join(_TMP, "game.db")
os.environ["LOG_FILE"] = os.path.join(_TMP, "requests.log")
os.environ.pop("UPSTREAM_PROXY_FROM", None)
os.environ.pop("UPSTREAM_PROXY_TO", None)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fastapi.testclient import TestClient  # noqa: E402
import main  # noqa: E402

client = TestClient(main.app)


def sid_for(hid: str) -> str:
    return base64.b64encode(json.dumps({"hID": hid}).encode()).decode().rstrip("=")


def unz(resp):
    return json.loads(zlib.decompress(resp.content).decode("utf-8"))


@pytest.fixture(scope="module")
def hid():
    r = client.post("/flut23/playerNew.php", data={"userEmail": "Test Company"})
    assert r.status_code == 200 and len(r.text) == 32
    return r.text


def test_uses_isolated_database():
    assert main.DB_PATH.startswith(_TMP)
    assert Path(main.DB_PATH).exists()


def test_fresh_schema_created():
    with sqlite3.connect(main.DB_PATH) as conn:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for t in ("players", "mines", "warehouse", "hq", "factories", "market_req", "proto_log"):
        assert t in tables


def test_register_is_idempotent_and_login_finds_player(hid):
    again = client.post("/flut23/playerNew.php", data={"userEmail": "test company"})
    assert again.text == hid
    r = client.post("/flut23/playerLogin.php", data={"userEmail": "Test Company"})
    assert r.json() == [{"hID": hid, "active": 1}]


def test_unknown_login_returns_empty():
    r = client.post("/flut23/playerLogin.php", data={"userEmail": "nobody here"})
    assert r.json() == []


def test_player_data(hid):
    data = unz(client.post("/flut23/playerGetData.php", data={"sid": sid_for(hid)}))
    assert isinstance(data, list) and data
    assert data[0]["hID"] == hid


def test_scan_returns_result(hid):
    r = client.post("/flut23/scannerPayscan.php",
                    data={"sid": sid_for(hid), "lat": "45.8150", "lng": "15.9819"})
    assert r.status_code == 200
    assert isinstance(unz(r), (dict, list))


def test_upstream_proxy_disabled_by_default():
    r = client.get("/some/unimplemented/path")
    assert r.status_code == 404


def test_shop_items():
    r = client.post("/flut23/shopGetData.php", data={})
    assert r.status_code == 200
