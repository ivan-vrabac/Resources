# Changelog

## Unreleased: first open-source release candidate

### Performance (large mine counts)
- Mine production is collected with a few set-based SQL statements instead of ~6 queries
  per mine (same formulas and warehouse fill order; verified against the per-mine code).
  A player with 10,000 mines loads in ~0.15–0.3 s instead of ~20 s.
- Lite player data (`playerGetData` with `lite=1`): mine aggregates (`mineStats`) instead
  of the full list. New endpoints `mineList` (sortable/paged), `minesNear`,
  `mineBulkRepair` (one request instead of one per mine) and `mineDots`.
- Heavy endpoints run in a thread pool, so one large player no longer blocks everyone.
- Hourly disease spread uses a spatial grid instead of comparing every mine pair;
  index on `mines(owner_hid)`.

### Accounts
- Login screen with separate **Log in** and **Register** tabs (register asks for the
  password twice); `POST /api/v1/auth/session` takes `mode=login|register`.
- `AUTH_MODE=mixed` for upgrading live servers: old name-only apps keep working, players
  pick a password at their next login, and from then on name-only login can't open
  their account. Old clients' URL-safe session encoding is accepted.
- `deploy/import_db.py` moves an existing `game.db` into the Docker volume.

### Changed
- Map clouds: one smoke puff per mine (GPU sprite batch) that merges smoothly when
  zooming out, instead of zoom-bucketed cluster blobs that jumped between levels.
- Tech upgrades from the map use the same sheet as the Mines tab (stays open,
  "TUx: installed n items").

### Added
- Accounts with passwords (scrypt) and server-signed, expiring session tokens
  (`AUTH_MODE=secure`, default). `AUTH_MODE=legacy` keeps the original name-only protocol.
- Sign-in rate limiting (10 failures / 15 min per name and per IP).
- Change password in Settings → Account; `server/admin.py` for admins
  (`set-password`, `list-unprotected`).
- Build-time branding: app name, title, application ID, server URL, theme colour, logo
  (`app/config/*.json`, see `docs/BRANDING.md`).
- In-app launcher icon picker (Settings → App → App Icon) with prepackaged variants.
- Asset replacement system (`copyrightreplace/`, `tools/assets.py`) with generated,
  labelled placeholder art for every original asset.
- OpenStreetMap attribution on map views.
- Docker Compose dev template with isolated named volumes; non-root server image.
- Tests: server (pytest), app (flutter test), client↔server end-to-end; GitHub Actions CI;
  repository safety check (`tools/check_repo.py`) as CI job and pre-commit hook.

### Changed
- Server paths, upstream proxy and identifiers come from environment variables; the
  legacy upstream proxy is disabled by default.
- Cleartext HTTP is only allowed in builds whose `API_BASE_URL` is `http://`.
- Python dependencies pinned.

### Removed
- All original third-party artwork, player data, logs, signing material and
  deployment-specific configuration (never part of this repository's history).
