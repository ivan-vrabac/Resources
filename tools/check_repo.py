#!/usr/bin/env python3
"""Pre-commit / CI safety check: fails if anything that must never be published is tracked or staged.

  python tools/check_repo.py            check files git would commit (tracked + staged + untracked-not-ignored)
  python tools/check_repo.py --all      scan every file under the repo, ignoring .gitignore

Checks: forbidden file types (databases, keystores, env files, APKs, service accounts),
secret-looking content (private keys, API tokens, password assignments), personal
identifiers listed in tools/denylist.txt (optional, gitignored), and asset validation.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FORBIDDEN_NAMES = re.compile(
    r"(\.(db|sqlite3?|jks|keystore|p12|pem|key|apk|aab|ipa|log|bak)$)"
    r"|(^|/)\.env$|(^|/)key\.properties$|(^|/)local\.properties$"
    r"|google-services\.json$|service-account.*\.json$|firebase-adminsdk.*\.json$"
    r"|\.local\.json$",
    re.I,
)
SECRET_PATTERNS = {
    "private key": re.compile(r"-----BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY-----"),
    "Google API key": re.compile(r"AIza[0-9A-Za-z_\-]{35}"),
    "Mapbox token": re.compile(r"pk\.eyJ[0-9A-Za-z_\-]{20,}\.[0-9A-Za-z_\-]{10,}"),
    "GitHub token": re.compile(r"gh[pousr]_[0-9A-Za-z]{30,}"),
    "AWS key": re.compile(r"AKIA[0-9A-Z]{16}"),
    # literal values only: `password=hunter2`, `password: "hunter2"`; not `password = getenv(...)`
    "password assignment": re.compile(
        r"(?im)\w*password\w*\s*[=:]\s*(['\"][^'\"\s]{4,}['\"]|[A-Za-z0-9!@#%^&*._\-]{4,}\s*$)"),
}
TEXT_EXT = {".dart", ".py", ".kt", ".kts", ".gradle", ".xml", ".json", ".yaml", ".yml", ".md",
            ".txt", ".properties", ".toml", ".cfg", ".ini", ".sh", ".ps1", ".html", ".js", ".csv", ""}
ALLOW_SECRET_IN = {"tools/check_repo.py", "SECURITY.md", "docs/INSTALL.md"}


MOJIBAKE = re.compile("\u00e2\u20ac|\u00c3[\u00a2\u00a9\u00a8\u00b6\u00bc]|\u00ea\u017e|\u00e2\u201d")


def candidate_files(scan_all: bool) -> list[str]:
    if scan_all:
        return [p.relative_to(ROOT).as_posix() for p in ROOT.rglob("*")
                if p.is_file() and ".git" not in p.parts]
    out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"],
                         cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [l for l in out.splitlines() if l]


def main() -> int:
    scan_all = "--all" in sys.argv
    files = candidate_files(scan_all)
    deny_file = ROOT / "tools" / "denylist.txt"
    deny = [l.strip() for l in deny_file.read_text(encoding="utf-8").splitlines()
            if l.strip() and not l.startswith("#")] if deny_file.exists() else []
    problems = []
    for rel in files:
        if rel == "tools/denylist.txt":
            continue
        if FORBIDDEN_NAMES.search(rel):
            problems.append(f"forbidden file: {rel}")
            continue
        p = ROOT / rel
        if p.suffix.lower() not in TEXT_EXT or p.stat().st_size > 5_000_000:
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        if rel not in ALLOW_SECRET_IN:
            for name, rx in SECRET_PATTERNS.items():
                m = rx.search(text)
                if m:
                    line = text.count("\n", 0, m.start()) + 1
                    problems.append(f"{name}: {rel}:{line}")
        # text saved with the wrong encoding (UTF-8 read as cp1252), e.g. "â€¢" for "•"
        m = MOJIBAKE.search(text)
        if m and rel != "tools/check_repo.py":
            line = text.count("\n", 0, m.start()) + 1
            problems.append(f"garbled text (wrong encoding) '{m.group(0)}': {rel}:{line}")
        for term in deny:
            if term.lower() in text.lower():
                problems.append(f"denylisted term '{term}': {rel}")
    # every server module must be in the Docker image (round 12: economy.py was missing → crash loop)
    dockerfile = (ROOT / "server" / "Dockerfile").read_text(encoding="utf-8")
    for py in sorted((ROOT / "server").glob("*.py")):
        if py.name not in dockerfile:
            problems.append(f"server/{py.name} is not copied in server/Dockerfile")
    for msg in problems:
        print("ERROR", msg)
    print(f"checked {len(files)} files")
    rc = subprocess.run([sys.executable, str(ROOT / "tools" / "assets.py"), "validate"], cwd=ROOT).returncode
    if problems or rc:
        print("check FAILED")
        return 1
    print("check OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
