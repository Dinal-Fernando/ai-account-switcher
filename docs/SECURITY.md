# Security notes

## What the app writes
| Path | Mode | Content |
|---|---|---|
| `~/.aiswitch/` | 0700 | everything below |
| `bin/claude`, `bin/codex`, `bin/aiswitch-statusline` | 0755 | plain shell scripts (readable; identical to `Wrapper/`) |
| `config/<tool>.real` | 0600 | path of the real executable |
| `state/active-<tool>` | 0600 | one line: profile id or `default` (atomic temp+rename) |
| `profiles/<tool>/<id>/` | 0700 | the vendor's own configuration directory for that account |
| `accounts.json` | 0600 | names, provider, profile id, cached identity (email/org/plan), last auth state |
| `usage/`, `history/` | 0600 | usage percentages and reset times; no tokens |
| `backups/<ts>/` | 0600 | copies of rc files taken before editing |
| `tmp/*.command` | 0700 | generated login / terminal scripts (contain the profile path, no secrets; cleaned after a day) |
| `logs/aiswitch.log` | 0600 | redacted log |
| `~/.zshrc` | unchanged mode | one marked block appended (opt-in, reversible) |

## What the app reads (and never writes)
* Claude Code Keychain item for a profile (`Claude Code-credentials[-hash]`) via `/usr/bin/security
  find-generic-password -w` — the same tool Claude Code uses — **only** to obtain the access token for the
  usage request. The refresh token is parsed but discarded; nothing is written back. Fallback:
  `<profile>/.credentials.json`. Opt-out per account (Usage source → Disabled).
* `<profile>/.claude.json` → `oauthAccount` (email, org) for display.
* `<CODEX_HOME>/auth.json` → access token for the usage request, id_token claims (email, plan) for display.
* Vendor CLI status commands (`claude auth status`, `codex login status`) run with a sanitised environment
  (credential override variables removed, profile variable set). They may refresh the vendor's own tokens
  as part of normal operation — that is the vendor doing it, not the app.

## What the app never does
* Never asks for or stores passwords, cookies, refresh tokens or API keys.
* Never copies credentials between profiles, never edits vendor Keychain items, never calls the vendors'
  OAuth token endpoints.
* Never changes a running CLI process; switching affects future launches only.
* Never unsets your `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` in your shell (it warns). The generated *login*
  scripts unset them inside their own subshell so the vendor login flow is not hijacked by an API key.
* Never logs secrets: `SwitcherLog.redact` strips `sk-ant-…`, `sk-…`, JWTs, bearer headers, cookies and
  token fields; the wrapper warning names variables, not values.
* Never silently switches: automatic switching is opt-in, logged, and announced with a notification.

## App-owned secrets
`SecureStorage` (Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, service
`dev.aiswitch.AIAccountSwitcher`) exists for optional future credentials (e.g. a separate web-session token).
The default usage source needs none.

## Network
Only two hosts are contacted, over HTTPS, with ephemeral `URLSession`s (no cookie jar, no disk cache):
`api.anthropic.com` and `chatgpt.com`. Both endpoints are undocumented (see ENDPOINTS.md).

## Organization policies
* Claude Code managed settings (`forceLoginMethod`, `forceLoginOrgUUID`, `allowedProviders`, blocked
  `ANTHROPIC_API_KEY`) apply inside every profile unchanged; Diagnostics surfaces them.
* Codex `requirements.toml`/MDM may pin `cli_auth_credentials_store`; the app does not fight it.

## Concurrency
State writes are atomic renames; readers (wrappers) see old or new, never partial content (shell test
“atomic switching under concurrent reads”, XCTest `testConcurrentWritesNeverProduceTornReads`). Each account's
usage fetch is independent with its own backoff.
