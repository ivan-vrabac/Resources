# Contributing

Thanks for helping! A few ground rules:

1. **Gameplay balance is intentional.** Do not change production rates, costs, mine
   placement or formulas in a general PR. Open an issue to discuss first.
2. **Artwork**: submit only work you own or that has a redistribution-compatible
   license, and record source + license in `copyrightreplace/manifest.csv`. Never
   submit files taken from the original commercial game. See `COPYRIGHT.md`.
3. **No secrets or data**: no databases, logs, keystores, `.env` files or credentials.
   Run `python tools/check_repo.py` before pushing.
4. **Tests**: `python -m pytest -q` in `server/`, `flutter test` in `app/`, and
   `python tools/assets.py validate` must pass.
5. **Style**: follow the surrounding code. `flutter analyze` must report no errors.
6. **License**: by contributing you agree your code is released under the MIT license.

## Development setup

See [docs/INSTALL.md](docs/INSTALL.md).
