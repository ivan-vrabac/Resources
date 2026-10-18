# Changelog

## Unreleased: first open-source release candidate

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
