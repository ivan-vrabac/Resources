# Resources

An open-source, self-hostable GPS resource-mining game. You walk around the real
world, scan for deposits, build mines, run factories, and trade on a player market.

- **`app/`**: Flutter client (Android)
- **`server/`**: FastAPI + SQLite game server
- **`deploy/`**: Docker Compose template and reverse-proxy example
- **`copyrightreplace/`**: asset inventory and replacement workflow
- **`tools/`**: asset and repository checks

> **Artwork notice**: the repository ships with generated placeholder art (flat
> coloured shapes). See [COPYRIGHT.md](COPYRIGHT.md) and
> [copyrightreplace/README.md](copyrightreplace/README.md) to add your own.

## Quick start

```bash
# Server
cd deploy
cp .env.example .env
docker compose up -d --build        # http://127.0.0.1:8000, fresh database in a named volume

# App (Android emulator reaches the host at 10.0.2.2)
cd ../app
flutter pub get
flutter run --dart-define-from-file=config/branding.default.json
```

For a phone on your LAN, set `BIND_ADDRESS=0.0.0.0` in `deploy/.env`, then copy
`config/branding.default.json` to `config/branding.local.json` with
`"API_BASE_URL": "http://<your-pc-ip>:8000"` and build with that file.

## Documentation

- [docs/INSTALL.md](docs/INSTALL.md): requirements, building, server setup, database, dev vs production
- [docs/BRANDING.md](docs/BRANDING.md): app name, icon, theme, application ID, launcher icon variants
- [docs/FIREBASE.md](docs/FIREBASE.md): optional push notifications
- [copyrightreplace/README.md](copyrightreplace/README.md): replacing images
- [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md)

## Tests

```bash
cd server && pip install -r requirements-dev.txt && python -m pytest -q
cd app && flutter test
python tools/assets.py validate
python tools/check_repo.py          # secrets / player data / forbidden files
```

## Known limitations

- **Accounts have no passwords.** Signing in only needs the company name. Do not run
  a public server with this login flow; see [SECURITY.md](SECURITY.md).
- The map uses OpenStreetMap's public tile server; read its usage policy before
  deploying for many users.

## License

Source code: MIT ([LICENSE](LICENSE)). Third-party components:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Assets: [COPYRIGHT.md](COPYRIGHT.md).
