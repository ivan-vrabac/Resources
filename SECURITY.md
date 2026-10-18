# Security policy

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting
(Security → Report a vulnerability) on this repository. You should get a reply
within 7 days.

## Known weaknesses (by design of the legacy protocol, to be fixed)

| Issue | Impact | Status |
|---|---|---|
| Sign-in uses only the company name, with no password | Anyone who knows or guesses a company name can take over that account | **Open: blocks public deployment** |
| Session ID (`sid`) is unsigned base64 of `{"hID": ...}` | Anyone who learns a player's hID can act as that player | Open |
| No rate limiting | Brute force, scraping | Open; put a rate-limiting reverse proxy in front |
| `FORWARDED_ALLOW_IPS` | If set to `*` while port 8000 is publicly reachable, clients can spoof their IP | Defaults to `127.0.0.1` |

Until the first two are fixed, run the server only for trusted players (private
network, VPN, or an authenticating reverse proxy).

## Secrets handling

- Never commit `.env`, `key.properties`, `*.jks`/`*.keystore`, `google-services.json`,
  Firebase service-account JSON, or any `*.db` file. `.gitignore` covers them and
  `python tools/check_repo.py` fails if one is staged.
- Server secrets come from environment variables / Docker secrets (`deploy/.env.example`).
- Android release signing reads `android/key.properties` or `RELEASE_*` env vars.
