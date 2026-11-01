# AI Account Switcher

A native macOS app (Swift / SwiftUI / AppKit) that **switches which authenticated account the real `claude`
and `codex` command-line tools use**, and shows the quota of every connected account in one dashboard and in
the menu bar.

```
┌─ AI Account Switcher ────────────────────────────────────────────────┐
│ Claude Code                                   Active: Claude Work    │
│  ┌ Claude Personal ───────────┐  ┌ Claude Work ─────── ACTIVE ✓ ──┐  │
│  │ jane@home · Max            │  │ jane@corp · Team               │  │
│  │ (5h 23%) (week 41%) Opus…  │  │ (5h 61%) (week 12%)            │  │
│  │ ● updated 2 min ago        │  │ ● updated 2 min ago            │  │
│  │ [Set Active] [Open Terminal]  │ [Open Terminal]                │  │
│  └────────────────────────────┘  └────────────────────────────────┘  │
│ Codex                                        Active: Codex Personal  │
│  …                                                                   │
└──────────────────────────────────────────────────────────────────────┘
```

Click **Set Active** on *Claude Work*, type `claude` in any terminal, and Claude Code starts with the
*Claude Work* login. Click *Claude Personal* → the next `claude` uses *Claude Personal*. Same for `codex`.
Switching back needs no new login while the stored login is valid. The selection survives terminal,
app and machine restarts. Sessions that are already running are never touched.

## How the switch actually works

1. Every account is an isolated vendor configuration directory:
   `~/.aiswitch/profiles/claude/<id>` used as **`CLAUDE_CONFIG_DIR`**, or
   `~/.aiswitch/profiles/codex/<id>` used as **`CODEX_HOME`**. Both variables are documented by the vendors
   and move settings, sessions *and credentials* with the directory. Your existing `~/.claude` and `~/.codex`
   logins appear as the *default* accounts and keep working with no re-login.
2. Sign-in runs through the vendor's own CLI (`claude auth login`, `codex login`) in a Terminal window that
   has the profile variable set. The app never asks for passwords, never copies tokens between accounts,
   and never writes vendor Keychain items.
3. **Set Active** atomically writes the profile id to `~/.aiswitch/state/active-claude` (or `-codex`).
4. `~/.aiswitch/bin/claude` and `~/.aiswitch/bin/codex` are small POSIX-sh wrappers. One marked block in
   `~/.zshrc` (backed up, reversible) puts them first in PATH and defines `claude()`/`codex()` shell functions
   that call them, so later PATH lines from other installers cannot bypass them. On *every* launch they read
   the state file, export exactly one variable, and `exec` the real binary with your arguments and working
   directory. No recursion, no daemon, no edits to your rc file per switch.
5. The card only shows **ACTIVE** after the vendor CLI (`claude auth status`, `codex login status`) confirmed
   inside that profile that it is signed in, and after a fresh login shell confirmed it resolves `claude` to
   the wrapper.

### Verified vendor behaviour (October 2026)

| | Claude Code 2.1.314 | Codex CLI 0.166.0 |
|---|---|---|
| Isolation variable | `CLAUDE_CONFIG_DIR` | `CODEX_HOME` |
| Credential storage | macOS Keychain item **`Claude Code-credentials-<sha256(dir)[0:8]>`** (no suffix for `~/.claude`); `.credentials.json` fallback | `$CODEX_HOME/auth.json` (`cli_auth_credentials_store = "file"`, the default) or keyring entry `Codex Auth` / `cli\|<sha256(dir)[0:16]>` |
| Status command | `claude auth status` (JSON, exit 0/1, `configDirectory` since 2.1.268) | `codex login status` |
| Login command | `claude auth login [--claudeai\|--console\|--sso]` | `codex login`, `codex login --device-auth` |
| Known limitation | Keyless *Console* sign-ins are stored outside the config dir and are **not** isolated (the app warns) | `requirements.toml`/MDM can pin the credential store; usage reading needs `file` mode |

The Keychain naming was read from the Claude Code 2.1.314 binary and matches the official authentication
docs ("keys the macOS Keychain entry to that directory"). The app's **Diagnostics** show the exact service
name expected for each profile so you can check Keychain Access yourself.

## Features

* Phase 1 – **Real CLI switching**: isolated profiles, atomic selection, PATH wrappers with recursion guard,
  per-terminal override (`Open Terminal` with an account), API-key/override detection, `aiswitch` CLI,
  full uninstall/restore.
* Phase 2 – **Unified usage dashboard**: 5-hour / weekly / per-model weekly (Claude), extra usage, Codex
  credits, reset countdowns, rings or pace graph, stale/offline/rate-limited states, per-account isolation of
  failures, usage history sparkline.
* Phase 3 – **Menu bar + notifications**: the menu bar label shows *every* account as a short label with its
  weekly (or 5-hour) usage, colored by threshold, with a dot on the active one (`● WK 12%  PER 41%  ● CX 8%`;
  compact and active-only modes available); the popover lists each provider's accounts with a *real* switch
  menu; threshold alerts carry a **Switch account** action that changes the CLI selection.
* Phase 4 – Opt-in automatic switching when the active account is exhausted; Claude status-line *beacon*
  (supported data source: values Claude Code itself reports) as a complement to the undocumented endpoints.
* **Live numbers (optional)**: a Claude card's menu has *Live usage from status line*. It points that profile's
  status line at the bundled beacon script (any existing status line keeps working behind it); Claude Code then
  reports its own quota numbers after every response and the card updates within a second, marked LIVE. This is
  a documented Claude Code mechanism, Pro/Max only, and only while a session in that account is running.
* **Continue a conversation under another account**: each card's *Sessions…* lists that account's stored
  conversations (local transcript files, readable even when the quota is exhausted). *Duplicate to <account>*
  copies the one transcript into the other profile and opens a Terminal there running `claude --resume <id>`
  (`codex resume <id>`), so the same context continues on the other login. Nothing is shared permanently.
  CLI: `aiswitch sessions`, `aiswitch copy-session`, `aiswitch resume`.

## Quick start

```bash
git clone <this repo> && cd ai-account-switcher
Scripts/build-app.sh --open --link   # SwiftPM build + ad-hoc signed bundle in build/AIAccountSwitcher.app,
                                     # launched, with ~/.local/bin/aiswitch linked to the bundled CLI
```
or open `Xcode/AIAccountSwitcher.xcodeproj` (Xcode 16+) and press Run. No paid developer account needed.

Then follow the onboarding: detect CLIs → install the wrappers → verify → add accounts → **Set Active**.

Command line equivalent:

```bash
aiswitch install-shell               # (after --link; otherwise build/AIAccountSwitcher.app/Contents/MacOS/aiswitch)
aiswitch add claude "Claude Work" && aiswitch login claude "Claude Work"
aiswitch use claude "Claude Work"
aiswitch which claude          # prints binary, profile, config dir, identity
aiswitch usage                 # quota for every account
aiswitch doctor                # full diagnostics
```

## Usage data: what is and is not official

* **Claude**: `GET https://api.anthropic.com/api/oauth/usage` with the profile's own OAuth *access* token
  (read-only; the same call Claude Code's `/usage` makes). Undocumented, rate-limited aggressively; the app
  polls at most once per minute per account with exponential backoff. The status-line `rate_limits` JSON
  (documented) is used as a second source when the beacon is installed.
* **Codex**: `GET https://chatgpt.com/backend-api/wham/usage` with the profile's `auth.json` access token
  (the call Codex's `/status` makes). Undocumented.
* The app never manufactures numbers: when a fetch fails you see the last reading marked *stale* with its age.

Details, fields and risks: [docs/ENDPOINTS.md](docs/ENDPOINTS.md).

## Documentation

* [docs/BUILD.md](docs/BUILD.md) – building with Xcode, SwiftPM, or the bundle script; running tests
* [docs/TESTING.md](docs/TESTING.md) – automated tests and the **manual end-to-end acceptance plan**
* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) – modules, on-disk layout, wrapper contract
* [docs/SECURITY.md](docs/SECURITY.md) – what is read, what is never written or logged
* [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
* [docs/ENDPOINTS.md](docs/ENDPOINTS.md)

## Honest status

* The wrapper, installer, uninstaller and atomic switching are covered by an executable shell
  specification (`Tests/Shell/test_wrapper.sh`, 86 checks) that **was run** while building this project.
* The Swift code (core library, CLI, app) and its XCTest suite were written and statically reviewed but
  **could not be compiled in the environment this project was authored in** (Linux, no Swift toolchain).
  Run `swift test` and `Scripts/build-app.sh` on your Mac; see BUILD.md for what to do if something fails.
* Real-account switching with two Claude and two Codex logins requires your credentials and your Mac.
  `docs/TESTING.md` lists the exact steps and expected outputs; nothing in this repository claims that
  those steps were executed.
