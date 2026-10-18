# Security policy

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting
(Security → Report a vulnerability) on this repository. You should get a reply
within 7 days.

## Authentication model (`AUTH_MODE=secure`, the default)

- Accounts are company name + password. Passwords are hashed with scrypt
  (N=2^14, r=8, p=1, 16-byte salt) in the `player_auth` table.
- Sign-in (`POST /api/v1/auth/session`) returns a session token: base64 JSON
  `{hID, iat, sig}`, where `sig` is HMAC-SHA256 under `SESSION_SECRET`. Every game
  endpoint verifies the signature and expiry (`SESSION_TTL_DAYS`). Knowing a player's
  hID (visible to other players, e.g. in chat) is not enough to act as them.
- 10 failed sign-ins within 15 minutes block that company name and that client IP
  for the rest of the window.
- The original name-only endpoints (`playerLogin.php`, `playerNew.php`) are disabled.

`AUTH_MODE=legacy` restores the original protocol: no passwords, unsigned sessions.
Use it only on a private server for trusted players running old clients.

## Known weaknesses

| Issue | Impact | Status |
|---|---|---|
| Rate limiting covers sign-in only | Scraping and spam on other endpoints | Open; use a rate-limiting reverse proxy |
| No password reset or change in the app | Players need the admin (`admin.py set-password`) | Open |
| Sessions cannot be revoked one by one | A stolen token works until it expires | Rotate `SESSION_SECRET` to sign everyone out |
| Plain HTTP in development | Passwords sent in clear text | Always use HTTPS in production (`deploy/Caddyfile.example`) |
| `FORWARDED_ALLOW_IPS` | If `*` while port 8000 is publicly reachable, clients can spoof their IP and dodge the limiter | Defaults to `127.0.0.1` |

## Secrets handling

- Never commit `.env`, `key.properties`, `*.jks`/`*.keystore`, `google-services.json`,
  Firebase service-account JSON, or any `*.db` file. `.gitignore` covers them and
  `python tools/check_repo.py` fails if one is staged.
- Server secrets come from environment variables / Docker secrets (`deploy/.env.example`).
- Android release signing reads `android/key.properties` or `RELEASE_*` env vars.
