#!/usr/bin/env python3
"""Asset inventory / replacement tool for the Resources project.

Stdlib only. Run from the repository root.

  python tools/assets.py inventory --originals <dir>   rebuild copyrightreplace/manifest.csv
  python tools/assets.py placeholders [--force]          write generated placeholders for every
                                                         asset that has no approved replacement
  python tools/assets.py apply [ASSET_ID ...]            copy files from copyrightreplace/replacements/
                                                         into the app (all, or only the given IDs)
  python tools/assets.py validate [--strict]             check every expected asset exists and that no
                                                         unverified original is present in the tree
  python tools/assets.py branding [--force]              (re)generate the project-owned launcher icon variants

Asset IDs are the asset's path relative to app/ (e.g. "assets/images_res/2x/res13.png").
The app loads assets by path, so replacing a file at the same path never breaks gameplay.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import os
import re
import shutil
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
CR = ROOT / "copyrightreplace"
MANIFEST = CR / "manifest.csv"
REPL = CR / "replacements"

FIELDS = [
    "asset_id", "path", "category", "width", "height", "where_used",
    "source", "license_evidence", "copyright_status", "original_sha256",
    "replacement_path", "replacement_status",
]
# copyright_status: verified | unknown | replacement_needed
# replacement_status: original | placeholder | replaced

ASSET_DIRS = ["assets", "android/app/src/main/res"]
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif"}
MEDIA_EXT = IMAGE_EXT | {".ttf", ".otf", ".mp3", ".ogg", ".wav", ".json", ".riv", ".flr"}


# ── image header parsing ─────────────────────────────────────────────────────

def image_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:2] == b"\xff\xd8":
        i = 2
        while i < len(data) - 9:
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return w, h
            seg = struct.unpack(">H", data[i + 2:i + 4])[0]
            i += 2 + seg
    return 0, 0


# ── placeholder PNG generation ───────────────────────────────────────────────

def _png(width: int, height: int, rows: list[bytes]) -> bytes:
    def chunk(tag: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + r for r in rows)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def _hue_rgb(seed: str) -> tuple[int, int, int]:
    h = int(hashlib.sha1(seed.encode()).hexdigest()[:4], 16) / 0xFFFF
    # HSV(h, 0.55, 0.85) → RGB
    i, f = int(h * 6), h * 6 - int(h * 6)
    v, s = 0.85, 0.55
    p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    r, g, b = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i % 6]
    return int(r * 255), int(g * 255), int(b * 255)


def placeholder_png(width: int, height: int, category: str, seed: str) -> bytes:
    """Generated, copyright-free placeholder: flat shape whose colour is derived from the asset ID."""
    width, height = max(1, width), max(1, height)
    r, g, b = _hue_rgb(seed)
    fg = bytes((r, g, b, 255))
    edge = bytes((r // 2, g // 2, b // 2, 255))
    clear = b"\x00\x00\x00\x00"
    grey = bytes((70, 74, 82, 255))
    rows: list[bytes] = []
    if category in ("background", "flag", "photo"):
        # full-bleed rectangle with a darker 1/16 border
        bw = max(1, min(width, height) // 16)
        border_row = edge * width
        body_row = edge * bw + (grey if category == "background" else fg) * (width - 2 * bw) + edge * bw
        for y in range(height):
            rows.append(border_row if y < bw or y >= height - bw else body_row)
    else:
        # filled circle (resources, mines, buildings, icons) on transparency
        cx, cy = (width - 1) / 2, (height - 1) / 2
        rad = min(width, height) * 0.45
        inner = rad * 0.82
        for y in range(height):
            dy = y - cy
            if abs(dy) > rad:
                rows.append(clear * width)
                continue
            half = (rad * rad - dy * dy) ** 0.5
            x0, x1 = int(round(cx - half)), int(round(cx + half)) + 1
            ihalf = (inner * inner - dy * dy) ** 0.5 if abs(dy) <= inner else -1
            if ihalf < 0:
                mid = edge * (x1 - x0)
            else:
                i0, i1 = int(round(cx - ihalf)), int(round(cx + ihalf)) + 1
                mid = edge * (i0 - x0) + fg * (i1 - i0) + edge * (x1 - i1)
            x0, x1 = max(0, x0), min(width, x1)
            rows.append(clear * x0 + mid[: (x1 - x0) * 4] + clear * (width - x1))
    return _png(width, height, rows)


# ── classification / usage ───────────────────────────────────────────────────

def categorize(rel: str) -> str:
    name = rel.rsplit("/", 1)[-1].lower()
    if rel.startswith("android/"):
        return "launcher_icon"
    if "images_countryflags" in rel:
        return "flag"
    if "images_res" in rel:
        return "resource_item"
    if name.startswith("hq_thumb"):
        return "hq_level"
    if name.startswith("imgartifact") or name.startswith("artifactlvl"):
        return "artifact"
    if name.startswith(("nav_", "icon", "ic_", "but_")):
        return "ui_icon"
    if name.startswith(("rnd", "splash")) or "illu" in name or name.endswith(".jpg"):
        return "photo"
    if "bg" in name or "lochblech" in name:
        return "background"
    if name.endswith((".ttf", ".otf")):
        return "font"
    if name.endswith((".mp3", ".ogg", ".wav")):
        return "sound"
    return "ui_graphic"


def _lib_sources() -> dict[str, str]:
    out = {}
    for p in (APP / "lib").rglob("*.dart"):
        out[p.relative_to(APP).as_posix()] = p.read_text(encoding="utf-8", errors="replace")
    return out


def where_used(rel: str, srcs: dict[str, str]) -> str:
    if rel.startswith("android/"):
        return "AndroidManifest.xml (launcher icon)"
    logical = re.sub(r"/[23]x/", "/", rel)
    hits = [f for f, t in srcs.items() if logical in t or rel in t]
    if hits:
        return "; ".join(sorted(hits))
    name = Path(rel).stem
    if "images_res" in rel:
        return "dynamic: assets/images_res/res<itemId>.png (lib/constants.dart resImagePath, casino, special buildings)"
    if "images_countryflags" in rel:
        return "dynamic: assets/images_countryflags/<cc>.png (game_screen, leaderboard, more_tab)"
    if name.startswith("hq_thumb"):
        return "dynamic: assets/images/hq_thumb_<lvl>[_<sub>].png (headquarters_screen, map_tab)"
    hits = [f for f, t in srcs.items() if name in t]
    return "; ".join(sorted(hits)) if hits else "unreferenced"


def walk_assets(base: Path):
    for d in ASSET_DIRS:
        root = base / d
        if not root.exists():
            continue
        for p in sorted(root.rglob("*")):
            if p.is_file() and p.suffix.lower() in MEDIA_EXT:
                rel = p.relative_to(base).as_posix()
                if rel.startswith("android/") and "mipmap" not in rel:
                    continue  # values/ drawables are XML, not media
                yield rel, p


# ── manifest io ──────────────────────────────────────────────────────────────

def read_manifest() -> list[dict]:
    with MANIFEST.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def write_manifest(rows: list[dict]) -> None:
    with MANIFEST.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


# ── commands ─────────────────────────────────────────────────────────────────

def cmd_inventory(args) -> int:
    """Build the manifest from a PRIVATE copy of the original app (never committed)."""
    originals = Path(args.originals).resolve()
    old = {r["asset_id"]: r for r in read_manifest()} if MANIFEST.exists() else {}
    srcs = _lib_sources()
    rows = []
    for rel, p in walk_assets(originals):
        w, h = image_size(p) if p.suffix.lower() in IMAGE_EXT else (0, 0)
        prev = old.get(rel, {})
        rows.append({
            "asset_id": rel,
            "path": f"app/{rel}",
            "category": categorize(rel),
            "width": w, "height": h,
            "where_used": where_used(rel, srcs),
            "source": prev.get("source") or "unknown (bundled with original commercial game client)",
            "license_evidence": prev.get("license_evidence") or "none",
            "copyright_status": prev.get("copyright_status") or "replacement_needed",
            "original_sha256": sha256(p),
            "replacement_path": f"copyrightreplace/replacements/{rel}",
            "replacement_status": prev.get("replacement_status") or "placeholder",
        })
    seen = {r["asset_id"] for r in rows}
    # keep project-owned assets (generated branding etc.) that have no original
    rows += [r for k, r in old.items() if k not in seen and r["copyright_status"] == "verified"]
    write_manifest(rows)
    print(f"manifest: {len(rows)} assets -> {MANIFEST.relative_to(ROOT)}")
    return 0


DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
LAUNCHER_VARIANTS = {"default": "ic_launcher", "alt1": "ic_launcher_alt1", "alt2": "ic_launcher_alt2"}


def cmd_branding(args) -> int:
    """Generate the project-owned launcher icon variants and their in-app previews."""
    rows = read_manifest()
    by_id = {r["asset_id"]: r for r in rows}

    def put(rel: str, w: int, seed: str, category: str):
        dst = APP / rel
        if dst.exists() and not args.force and rel in by_id and by_id[rel]["replacement_status"] == "replaced":
            return
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(placeholder_png(w, w, "ui_icon", seed))
        if rel not in by_id:
            by_id[rel] = {
                "asset_id": rel, "path": f"app/{rel}", "category": category, "width": w, "height": w,
                "where_used": "AndroidManifest.xml activity-alias" if rel.startswith("android/")
                              else "lib/services/launcher_icon_service.dart (App Icon picker)",
                "source": "generated by tools/assets.py branding", "license_evidence": "project-owned (MIT)",
                "copyright_status": "verified", "original_sha256": "",
                "replacement_path": f"copyrightreplace/replacements/{rel}", "replacement_status": "placeholder",
            }
            rows.append(by_id[rel])

    for variant, name in LAUNCHER_VARIANTS.items():
        seed = f"launcher-{variant}"
        if variant != "default":  # default ic_launcher already comes from the inventory
            for d, px in DENSITIES.items():
                put(f"android/app/src/main/res/mipmap-{d}/{name}.png", px, seed, "launcher_icon")
        put(f"assets/branding/launcher_{variant}.png", 192, seed, "launcher_icon")
    write_manifest(rows)
    print("branding assets generated")
    return 0


def cmd_placeholders(args) -> int:
    n = 0
    for r in read_manifest():
        if r["replacement_status"] == "replaced" or r["copyright_status"] == "verified":
            continue
        dst = APP / r["asset_id"]
        if dst.exists() and not args.force and sha256(dst) != r["original_sha256"]:
            continue
        if Path(r["asset_id"]).suffix.lower() not in IMAGE_EXT:
            print(f"skip non-image (needs manual replacement): {r['asset_id']}")
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        # PNG bytes are written even to .jpg paths: Flutter sniffs the format from content.
        logical = re.sub(r"/[23]x/", "/", r["asset_id"])
        dst.write_bytes(placeholder_png(int(r["width"] or 64), int(r["height"] or 64), r["category"], logical))
        r["replacement_status"] = "placeholder"
        n += 1
    print(f"placeholders written: {n}")
    return 0


def cmd_apply(args) -> int:
    rows = read_manifest()
    want = set(args.ids)
    n = 0
    for r in rows:
        if want and r["asset_id"] not in want:
            continue
        src = ROOT / r["replacement_path"]
        if not src.exists():
            if want:
                print(f"missing replacement: {src.relative_to(ROOT)}")
            continue
        if sha256(src) == r["original_sha256"]:
            print(f"REFUSED (identical to unverified original): {r['asset_id']}")
            continue
        dst = APP / r["asset_id"]
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        r["replacement_status"] = "replaced"
        n += 1
        if src.suffix.lower() in IMAGE_EXT and r["width"] and image_size(src) != (int(r["width"]), int(r["height"])):
            print(f"note: {r['asset_id']} size {image_size(src)} differs from original {r['width']}x{r['height']}")
    write_manifest(rows)
    print(f"replacements applied: {n}")
    return 0


def cmd_validate(args) -> int:
    rows = read_manifest()
    errors, warnings = [], []
    originals = {r["original_sha256"]: r["asset_id"] for r in rows if r["copyright_status"] != "verified"}
    ids = set()
    for r in rows:
        ids.add(r["asset_id"])
        p = APP / r["asset_id"]
        if not p.exists():
            errors.append(f"missing asset: {r['path']}")
            continue
        if r["copyright_status"] != "verified" and sha256(p) == r["original_sha256"]:
            errors.append(f"unverified ORIGINAL present: {r['path']}")
        if p.suffix.lower() in IMAGE_EXT and image_size(p) == (0, 0):
            errors.append(f"unreadable image: {r['path']}")
    # anything in the tree that is not in the manifest, or that matches any original
    for rel, p in walk_assets(APP):
        if rel not in ids:
            warnings.append(f"asset not in manifest: app/{rel}")
        h = sha256(p)
        if h in originals and originals[h] != rel:
            errors.append(f"copy of unverified original {originals[h]} at app/{rel}")
    counts: dict[str, int] = {}
    for r in rows:
        counts[r["replacement_status"]] = counts.get(r["replacement_status"], 0) + 1
    for w in warnings:
        print("WARN ", w)
    for e in errors:
        print("ERROR", e)
    print(f"{len(rows)} assets: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    if errors or (args.strict and warnings):
        print("validation FAILED")
        return 1
    print("validation OK")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("inventory"); p.add_argument("--originals", required=True,
                                                     help="private app directory containing the original assets")
    p = sub.add_parser("placeholders"); p.add_argument("--force", action="store_true")
    p = sub.add_parser("apply"); p.add_argument("ids", nargs="*")
    p = sub.add_parser("validate"); p.add_argument("--strict", action="store_true")
    p = sub.add_parser("branding"); p.add_argument("--force", action="store_true")
    args = ap.parse_args()
    return {"inventory": cmd_inventory, "placeholders": cmd_placeholders, "branding": cmd_branding,
            "apply": cmd_apply, "validate": cmd_validate}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
