# Usage endpoints (undocumented) and supported sources

Neither Anthropic nor OpenAI documents a subscription-quota API. The app uses the same calls the vendor CLIs
make for their own `/usage` and `/status` screens, read-only, with the profile's own login. They can change
or be restricted at any time; when they fail the app shows the last reading as *stale* and never invents
numbers.

## Claude — `GET https://api.anthropic.com/api/oauth/usage`
* Headers: `Authorization: Bearer <access token from the profile's Keychain item / .credentials.json>`,
  `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`.
* Observed response fields (all optional; decoder tolerates absence):
  ```json
  {"five_hour":{"utilization":23.5,"resets_at":"2025-10-10T12:00:00.123456+00:00"},
   "seven_day":{"utilization":41,"resets_at":"…"},
   "seven_day_opus":{"utilization":12,"resets_at":"…"}, "seven_day_sonnet":{…}, "seven_day_oauth_apps":{…},
   "limits":[{"kind":"session|weekly_all|weekly_scoped","percent":55,"resets_at":"…","scope":{"model":{"display_name":"Opus"}}}],
   "extra_usage":{"is_enabled":true,"monthly_limit":500,"used_credits":314.12,"currency":"USD","out_of_credits":false}}
  ```
  Legacy keys (`monthly_credit_limit`, `spend_limit_amount_cents`, `balance_cents`) are mapped too.
* Failure modes: `401/403` login rejected; `429` with `Retry-After` (sometimes `0`); `null` windows on plans
  without a usage dashboard (free / API-only); HTML bodies from bot protection. Claude Code itself reports
  persistent 429s for this endpoint when polled quickly (anthropic/claude-code issues #31021, #31637), so the
  app enforces ≥ 60 s per account, smart demotion to 10 min, and exponential backoff (60 s → 30 min).
* Token expiry: the access token's `expiresAt` is checked first; when expired the app runs
  `claude auth status` in the profile (which lets Claude Code refresh its own token), then re-reads.
* Claude Code 2.1.314 also uses `?cedar_ember=1&skip_spend=1` / `?at_wall=1` variants; the app uses the plain
  path.

## Claude — status-line `rate_limits` (documented, supported)
Claude Code passes `rate_limits.five_hour / seven_day {used_percentage, resets_at}` (Pro/Max, after the first
response of a session) to the configured status-line command. `Wrapper/aiswitch-statusline.sh` stores that
JSON per profile and forwards it to any previously configured command. The app shows these values as
“observed by Claude Code” whenever they are newer than the API reading. They only update while a session is
running, so they complement rather than replace the endpoint above.

## Codex — `GET https://chatgpt.com/backend-api/wham/usage`
* Headers: `Authorization: Bearer <tokens.access_token from $CODEX_HOME/auth.json>`,
  `chatgpt-account-id: <tokens.account_id>` (the header Codex sends), `Accept: application/json`.
* Observed response:
  ```json
  {"plan_type":"plus","account_id":"…","email":"…",
   "rate_limit":{"allowed":true,"limit_reached":false,
     "primary_window":{"used_percent":12.5,"limit_window_seconds":604800,"reset_after_seconds":3600,"reset_at":1760003600},
     "secondary_window":{…}},
   "credits":{"has_credits":true,"unlimited":false,"overage_limit_reached":false,"balance":"12.50"}}
  ```
  Windows are classified by `limit_window_seconds` (closest to 5 h vs 7 d), not by slot, because the vendor
  has moved windows between slots. `balance` may be a string or a number.
* The Codex source also has a newer path `/api/codex/usage` used with other base URLs; the ChatGPT backend
  path above is what the CLI uses with ChatGPT logins (`codex-rs/backend-client/src/client/rate_limit_resets.rs`).
* Token expiry: the access token JWT `exp` is checked; when expired the app asks you to run `codex` once
  (Codex refreshes tokens itself on use). The app does not call `auth.openai.com`.
* Keyring mode (`cli_auth_credentials_store = "keyring"`): credentials are not readable from a file; the app
  reports *unsupported* instead of guessing.

## Identity sources (no network)
* Claude: `claude auth status` JSON (`email`, `orgName`, `orgId`, `subscriptionType`, `authMethod`,
  `configDirectory`) and `<profile>/.claude.json` → `oauthAccount`.
* Codex: `codex login status` text and `auth.json` → `id_token` claims (`email`,
  `https://api.openai.com/auth.chatgpt_plan_type`, `chatgpt_account_id`).

## Compatibility risks
* Field renames (already happened for extra usage), window keys moving into `limits[]`, Codex windows changing
  slots or disappearing, Cloudflare challenges, aggressive 429s. Decoders are permissive and tested with
  fixtures; a change usually degrades to “no data for this window” rather than an error.
* Reading the Keychain item via `security(1)` relies on Claude Code's current storage scheme (service name
  derived from `CLAUDE_CONFIG_DIR`, account = `$USER`). The app also reads `.credentials.json` when present.
