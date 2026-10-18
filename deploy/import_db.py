"""Import an existing game.db into the server's Docker volume (consistent SQLite backup).

Stop the server first, then run (adjust the source folder and volume name):

  docker run --rm -u 0 \
    -v /path/to/old/data:/src:ro -v <volume>:/data -v "$PWD/deploy:/m:ro" \
    <server-image> python /m/import_db.py

The source is opened read-only; an existing /data/game.db is never overwritten unless
--force is given. Files are handed to the server's non-root user (uid 10001).
"""
import os
import sqlite3
import sys

src_path, dst_path = "/src/game.db", "/data/game.db"
if not os.path.exists(src_path):
    sys.exit(f"{src_path} not found")
if os.path.exists(dst_path) and "--force" not in sys.argv:
    sys.exit(f"{dst_path} already exists; refusing to overwrite (pass --force)")
src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
dst = sqlite3.connect(dst_path)
src.backup(dst)
counts = {t: dst.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
          for t in ("players", "mines", "warehouse", "factories")}
ok = dst.execute("PRAGMA integrity_check").fetchone()[0]
dst.close()
src.close()
os.chown(dst_path, 10001, 10001)
os.chown(os.path.dirname(dst_path), 10001, 10001)
print("imported", counts, "integrity:", ok)
