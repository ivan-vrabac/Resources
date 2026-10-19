"""Point the server at a throwaway database before main.py is imported. Never use a real game.db."""
import os
import sys
import tempfile
from pathlib import Path

TMP = tempfile.mkdtemp(prefix="resources-test-")
os.environ["DB_PATH"] = os.path.join(TMP, "game.db")
os.environ["LOG_FILE"] = os.path.join(TMP, "requests.log")
os.environ.pop("UPSTREAM_PROXY_FROM", None)
os.environ.pop("UPSTREAM_PROXY_TO", None)
os.environ.pop("SESSION_SECRET", None)
os.environ["AUTH_MODE"] = "secure"
os.environ["WORLD_EVENTS_THREAD"] = "0"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
