"""collect_mines_bulk() must give the same result as collect_mine() per mine, much faster."""
import datetime
import random
import shutil
import sqlite3
import time

import main


def _seed(db_path, n_mines, seed=1):
    rng = random.Random(seed)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    hid = "bulk" + "0" * 28
    conn.execute("DELETE FROM mines WHERE owner_hid=?", (hid,))
    conn.execute("DELETE FROM warehouse WHERE hid=?", (hid,))
    conn.execute("INSERT OR IGNORE INTO players(hID, company_name, wh_level) VALUES(?,?,?)",
                 (hid, "bulk test co", 3))
    conn.execute("INSERT OR REPLACE INTO hq(hid, lat, lng, level) VALUES(?,?,?,?)", (hid, 45.8, 15.97, 5))
    now = datetime.datetime.utcnow()
    types = list(main.MINE_TYPES)
    for i in range(n_mines):
        near = i % 10 == 0  # some inside the HQ boost radius
        lat = 45.8 + (rng.uniform(-0.0005, 0.0005) if near else rng.uniform(-1, 1))
        lng = 15.97 + (rng.uniform(-0.0005, 0.0005) if near else rng.uniform(-1, 1))
        last = now - datetime.timedelta(hours=rng.uniform(0, 30))
        sick = (now + datetime.timedelta(days=1)).isoformat() if i % 7 == 0 else None
        conn.execute(
            "INSERT INTO mines(mine_id, owner_hid, lat, lng, item_id, quality, condition, level, "
            "last_coll, created_at, tu1, tu3, sick_until) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (f"bulkmine{i:07d}", hid, lat, lng, rng.choice(types), rng.randint(20, 100),
             rng.choice([100, 60, 24, 21, 19]), rng.randint(1, 5), last.isoformat(), now.isoformat(),
             rng.randint(0, 1), rng.randint(0, 1), sick))
    conn.commit()
    conn.close()
    return hid


def _state(conn, hid):
    wh = {r[0]: round(r[1], 6) for r in conn.execute("SELECT item_id, qty FROM warehouse WHERE hid=?", (hid,))}
    mines = {r[0]: round(r[1], 2) for r in conn.execute("SELECT mine_id, condition FROM mines WHERE owner_hid=?", (hid,))}
    return wh, mines


def _open(path):
    c = sqlite3.connect(path)
    c.row_factory = sqlite3.Row
    return c


def test_bulk_matches_per_mine(tmp_path):
    a, b = tmp_path / "a.db", tmp_path / "b.db"
    shutil.copy(main.DB_PATH, a)
    hid = _seed(a, 600)
    shutil.copy(a, b)

    ca = _open(a)
    for m in ca.execute("SELECT * FROM mines WHERE owner_hid=?", (hid,)).fetchall():
        main.collect_mine(ca, m)
    ca.commit()

    cb = _open(b)
    main.collect_mines_bulk(cb, hid)

    wh_a, mines_a = _state(ca, hid)
    wh_b, mines_b = _state(cb, hid)
    assert mines_a.keys() == mines_b.keys()          # same mines destroyed
    assert mines_a == mines_b                        # same conditions
    assert wh_a.keys() == wh_b.keys()
    for k in wh_a:  # same warehouse; collect_mine reads the clock per mine, so allow ms of drift
        assert abs(wh_a[k] - wh_b[k]) < 1e-4 * max(1.0, wh_a[k])


def test_bulk_is_fast_with_10k_mines(tmp_path):
    p = tmp_path / "big.db"
    shutil.copy(main.DB_PATH, p)
    hid = _seed(p, 11_400, seed=2)
    conn = _open(p)
    t = time.perf_counter()
    main.collect_mines_bulk(conn, hid)
    bulk_s = time.perf_counter() - t
    row = conn.execute("SELECT * FROM players WHERE hID=?", (hid,)).fetchone()
    t = time.perf_counter()
    data = main.build_player_data(conn, row)
    full_s = time.perf_counter() - t
    print(f"\n  11,400 mines: collect_mines_bulk {bulk_s*1000:.0f} ms, build_player_data {full_s*1000:.0f} ms")
    assert len(data["mines"]) > 0
    assert full_s < 3.0
