# Asset replacement system

The app loads every image by its **path** (e.g. `assets/images_res/res13.png` is the
icon for item 13, Iron Ore). The path is the asset ID. Replacing a file at the same path
never changes gameplay, so artwork can be swapped one file at a time.

```
copyrightreplace/
  README.md        this file
  manifest.csv     one row per asset (1,159 rows)
  replacements/    your replacement files, mirroring app/ paths
```

## manifest.csv columns

| Column | Meaning |
|---|---|
| `asset_id` | Path relative to `app/`; this is what the code references |
| `path` | Path relative to the repository root |
| `category` | resource_item, hq_level, flag, ui_icon, ui_graphic, photo, background, artifact, launcher_icon |
| `width`,`height` | Pixel size of the original; replacements should match it |
| `where_used` | Source files referencing it (`dynamic:` = path built from an ID at runtime; `unreferenced` = not used by current code) |
| `source` | Creator or origin |
| `license_evidence` | License name plus URL, or the file in this repo that proves permission |
| `copyright_status` | `verified` (cleared), `unknown`, `replacement_needed` |
| `original_sha256` | Hash of the original private file; used to block originals from being committed |
| `replacement_path` | Where to put your replacement |
| `replacement_status` | `original`, `placeholder` (generated stand-in), `replaced` |

Resolution variants (`2x/`, `3x/`) are separate rows. Supply all three, or at least
the 1x file and delete the others: Flutter falls back to the 1x image.

## Replacing an asset

```bash
# 1. Put your file at the mirrored path
cp my-iron-ore.png copyrightreplace/replacements/assets/images_res/res13.png

# 2. Record source + license in manifest.csv for that row and set copyright_status=verified

# 3. Copy it into the app (one ID, several, or all)
python tools/assets.py apply assets/images_res/res13.png
python tools/assets.py apply            # every file present under replacements/

# 4. Check
python tools/assets.py validate
```

`apply` refuses a file whose hash matches an unverified original.

## Commands

| Command | What it does |
|---|---|
| `python tools/assets.py validate [--strict]` | Every manifest asset exists and is a readable image; no unverified original (by hash) anywhere under `app/`. `--strict` also fails on assets missing from the manifest. Run it in CI. |
| `python tools/assets.py placeholders [--force]` | Regenerate placeholders for rows not yet replaced |
| `python tools/assets.py branding [--force]` | Regenerate the launcher icon variants |
| `python tools/assets.py inventory --originals <private app dir>` | Maintainers only: rebuild the manifest from a private copy of the original app. Keeps existing source/license/status values. |

## Private builds with the original art

If you own a license to the original art, keep it **outside this repository** and copy
it over `app/assets` locally before building. Never commit it; `validate` will flag it.
