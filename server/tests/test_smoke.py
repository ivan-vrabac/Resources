"""Smoke tests against a throwaway database (see conftest.py).

Run from server/:  python -m pytest -q
"""
import json
import sqlite3
import zlib
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from conftest import TMP
import main

client = TestClient(main.app)


def unz(resp):
    return json.loads(zlib.decompress(resp.content).decode("utf-8"))


@pytest.fixture(scope="module")
def session():
    r = client.post("/api/v1/auth/session", data={"name": "Test Company", "password": "secret123"})
    assert r.status_code == 200, r.text
    return r.json()


def test_uses_isolated_database():
    assert main.DB_PATH.startswith(TMP)
    assert Path(main.DB_PATH).exists()


def test_fresh_schema_created():
    with sqlite3.connect(main.DB_PATH) as conn:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for t in ("players", "mines", "warehouse", "hq", "factories", "market_req", "proto_log",
              "player_auth", "server_secrets"):
        assert t in tables


def test_player_data(session):
    data = unz(client.post("/flut23/playerGetData.php", data={"sid": session["sid"]}))
    assert isinstance(data, list) and data
    assert data[0]["hID"] == session["hID"]


def test_scan_returns_result(session):
    r = client.post("/flut23/scannerPayscan.php",
                    data={"sid": session["sid"], "lat": "45.8150", "lng": "15.9819"})
    assert r.status_code == 200
    assert isinstance(unz(r), (dict, list))


def test_upstream_proxy_disabled_by_default():
    r = client.get("/some/unimplemented/path")
    assert r.status_code == 404


def test_shop_items():
    r = client.post("/flut23/shopGetData.php", data={})
    assert r.status_code == 200
