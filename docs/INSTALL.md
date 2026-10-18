# Installation

## Requirements

| Component | Version |
|---|---|
| Flutter SDK | 3.44 (Dart ≥ 3.3) |
| JDK | 17 (Temurin recommended); set `JAVA_HOME` |
| Android SDK | API 36 platform + build-tools (via Android Studio or `sdkmanager`) |
| Docker + Compose v2 | for the server (or Python 3.12 without Docker) |
| Python | 3.10+ for `tools/` scripts (stdlib only) |

## Server

### With Docker (recommended)

```bash
cd deploy
cp .env.example .env          # edit as needed
docker compose up -d --build
curl -X POST http://127.0.0.1:8000/flut23/ping.php     # → 1
```

The template uses its own named volumes (`resources-dev-data`, `resources-dev-logs`).
It never mounts host paths, so it cannot touch another deployment's database.
`docker compose down -v` deletes the dev database.

### Without Docker

```bash
cd server
python -m venv .venv && . .venv/bin/activate     # Windows: .venv\Scripts\activate
pip install -r requirements.txt
DB_PATH=./dev-data/game.db LOG_FILE=./dev-data/requests.log uvicorn main:app --port 8000
```

### Configuration

All settings are environment variables; see `deploy/.env.example`.

| Variable | Default | Purpose |
|---|---|---|
| `DB_PATH` | `/data/game.db` | SQLite database file |
| `LOG_FILE` | `/logs/requests.log` | JSON-lines request log (contains player names: treat as personal data) |
| `FORWARDED_ALLOW_IPS` | `127.0.0.1` | Proxies whose `X-Forwarded-*` headers are trusted |
| `SERVER_MID` | generic | Server identifier for legacy clients |
| `UPSTREAM_PROXY_FROM` / `UPSTREAM_PROXY_TO` | empty (disabled) | Legacy pass-through of unimplemented endpoints |
| `FIREBASE_PROJECT_ID`, `GOOGLE_APPLICATION_CREDENTIALS` | empty | Optional push, see FIREBASE.md |

### Database initialization and migrations

On startup the server creates any missing tables (`CREATE TABLE IF NOT EXISTS`) and
adds missing columns (idempotent `ALTER TABLE … ADD COLUMN`). A fresh `DB_PATH` gives
an empty, working game. Upgrading in place keeps existing data. **Back up `game.db`
before upgrading** (stop the server, copy the file).

### Production

- Put the server behind a TLS reverse proxy (`deploy/Caddyfile.example`) and keep
  port 8000 bound to `127.0.0.1`.
- Read the known weaknesses in `SECURITY.md` first. Name-only login is not safe on a
  public server.
- Use a separate compose project/volume for production; never reuse the dev template's volumes.

## Android app

```bash
cd app
flutter pub get
# debug on emulator/device
flutter run --dart-define-from-file=config/branding.default.json
# release APK
flutter build apk --release --dart-define-from-file=config/branding.local.json
```

Release signing: create `app/android/key.properties` (gitignored):

```properties
storeFile=/absolute/path/to/your.jks
storePassword=...
keyAlias=...
keyPassword=...
```

or set `RELEASE_STORE_FILE`, `RELEASE_STORE_PASSWORD`, `RELEASE_KEY_ALIAS`,
`RELEASE_KEY_PASSWORD`. Without either, release builds are signed with the debug key
(fine for testing, not for distribution).

## Development vs production configuration

| | Development | Production |
|---|---|---|
| App config | `config/branding.default.json` (emulator → `10.0.2.2:8000`) | `config/branding.local.json` (gitignored) with your HTTPS URL and application ID |
| Server | `deploy/docker-compose.yml`, named volumes | your own compose file / volumes, TLS proxy |
| Signing | debug key | your release keystore, kept outside the repo |

## Running tests

```bash
cd server && pip install -r requirements-dev.txt && python -m pytest -q   # uses a temp DB
cd app && flutter test
python tools/assets.py validate
python tools/check_repo.py
```

## Replacing images and branding

See `copyrightreplace/README.md` and `docs/BRANDING.md`.
