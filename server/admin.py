#!/usr/bin/env python3
"""Server admin commands. Uses the same DB_PATH as the server.

  python admin.py set-password "<company name>" "<new password>"
  python admin.py list-unprotected        accounts without a password (created in legacy mode)

In Docker:  docker compose exec server python admin.py list-unprotected
"""
import os
import sqlite3
import sys

import auth

DB_PATH = os.environ.get("DB_PATH", "/data/game.db")


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in ("set-password", "list-unprotected"):
        print(__doc__)
        return 2
    conn = sqlite3.connect(DB_PATH)
    auth.init(conn)
    if sys.argv[1] == "list-unprotected":
        rows = conn.execute("SELECT p.company_name FROM players p LEFT JOIN player_auth a "
                            "ON a.hid = p.hID WHERE a.hid IS NULL ORDER BY 1").fetchall()
        for (name,) in rows:
            print(name)
        print(f"{len(rows)} account(s) without a password")
        return 0
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    name, password = sys.argv[2].strip().lower(), sys.argv[3]
    problem = auth.password_problem(password)
    if problem:
        print(problem)
        return 1
    row = conn.execute("SELECT hID FROM players WHERE lower(company_name)=?", (name,)).fetchone()
    if not row:
        print(f"no such company: {name}")
        return 1
    auth.set_password(conn, row[0], password)
    conn.commit()
    print(f"password set for {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
