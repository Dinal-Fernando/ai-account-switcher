# Testing

## 1. Automated

| Suite | Runs where | Command | What it proves |
|---|---|---|---|
| `Tests/Shell/test_wrapper.sh` (86 checks) | Linux + macOS | `bash Tests/Shell/test_wrapper.sh` | wrapper routing, atomic switching under concurrent reads, per-terminal override, user-env precedence, API-key warnings, recursion guard, missing-binary handling, diagnostics mode, status-line beacon, installer idempotence + backups, uninstall + byte-identical restore, purge |
| `Tests/SwitcherCoreTests` (XCTest) | macOS | `swift test` | SHA-256 + vendor key derivation, `ActiveAccountManager` (atomic file, persistence, validation, torn-read check), `CLIProfileManager` (0700 dirs, Codex config merging, no credential copying), `AccountManager`, `RCFileEditor` ↔ bash installer parity, embedded-script parity, wrapper exec through `ShellIntegrationManager`, auth parsers (all `authMethod` values, warnings), JWT identity, usage decoders (Claude null windows, scoped models, extra usage; Codex duration classification, balance types; status-line beacon), backoff, smart refresh, scheduler debounce, notification de-dup/re-arm, recommendations, `UsageMonitor` isolation/backoff/offline/stale/session-expired, provider adapters with fake process + HTTP (headers, 401/429 mapping, expired tokens, keyring mode), env-override detector, Doctor, ProcessRunner timeout |

Status at authoring time: the shell suite **passed (86/86)** on Linux. The XCTest suite was not executed
because no Swift toolchain was available; run it on macOS before relying on it.

## 2. Manual end-to-end acceptance plan (requires two Claude and two Codex accounts)

Preconditions: the app is built (BUILD.md), onboarding completed, shell integration **verified** (Settings →
Shell shows “login shell → ~/.aiswitch/bin/claude”). Open a **new** terminal for every step that runs a CLI.
`aiswitch` below means `build/AIAccountSwitcher.app/Contents/MacOS/aiswitch` (or your symlink).

Expected outputs use `A`/`B` for the two accounts of a provider.

### Step 1 – Authenticate two Claude accounts
1. Dashboard → *Add Claude Code account…* → name `Claude A` → **Create & Sign in**. A Terminal window runs
   `claude auth login` with `CLAUDE_CONFIG_DIR=~/.aiswitch/profiles/claude/claude-a-xxxx`. Log in with account A.
2. The sheet turns green (“Signed in as a@…”). Repeat for `Claude B` with account B.
3. Verify isolation: `ls ~/.aiswitch/profiles/claude/` shows two directories; Keychain Access (login keychain)
   shows two items `Claude Code-credentials-<hash>` whose hashes match Diagnostics → “Expected Keychain item”.
   Expected: two distinct items; the default `Claude Code-credentials` item (if any) is untouched.

### Step 2 – Authenticate two Codex accounts
Same with *Add Codex account…* (`Codex A`, `Codex B`). Verify `~/.aiswitch/profiles/codex/*/auth.json` exist
(mode 0600) and differ.

### Step 3 – Set Claude A active
Click **Set Active** on `Claude A`. Badge becomes **ACTIVE ✓** (only after `claude auth status` succeeded in
that profile). `cat ~/.aiswitch/state/active-claude` prints the profile id.

### Step 4 – `claude` uses A
```bash
claude auth status
```
Expected JSON: `"loggedIn": true`, `"email": "<A>"`, `"configDirectory": "/Users/you/.aiswitch/profiles/claude/claude-a-…"`.
Then `claude` → `/status` shows account A. `aiswitch which claude` prints `profile=claude-a-…`, `applied=yes`.

### Step 5 – Switch to Claude B in the GUI
Click **Set Active** on `Claude B`.

### Step 6 – `claude` uses B
Run `claude auth status` again in the same (already open) terminal window: email is now `<B>` and
`configDirectory` is B's profile. No login prompt.

### Step 7 – Switch back without login
Set Active `Claude A` → `claude auth status` shows A, no login prompt (credentials still valid in A's
Keychain item). Also test from the menu bar: *Switch account* → `Claude B` → `claude auth status` shows B.

### Step 8 – Repeat for Codex
Set Active `Codex A` → `codex login status` prints `Logged in using ChatGPT`; `aiswitch which codex` shows
`config_dir=…/profiles/codex/codex-a-…`; inside `codex`, `/status` shows account A's email/plan.
Switch to `Codex B` → `codex login status` + `/status` show B. Switch back → A, no login.

### Step 9 – Running sessions are not reassigned
Start `claude` (A active) and keep it open. Switch to B in the GUI. The running session still shows A in
`/status`; a *new* `claude` in another terminal shows B. Same for `codex`.

### Step 10 – Persistence
Quit the app (menu bar → Quit), close all terminals, open a new terminal: `claude auth status` still
reports the last selected account. Reboot the Mac: same result; the app (if launch-at-login is on) shows the
same ACTIVE badges.

### Step 11 – Token refresh keeps isolation
Wait for an access-token refresh (Claude tokens refresh within hours; or leave the Mac overnight), then run
`claude auth status` in each profile via `aiswitch auth claude`. Each profile still reports its own email.
Keychain Access still shows separate items per hash. For Codex, `auth.json` `last_refresh` changes only in
the profile that was used.

### Step 12 – Monitoring continues for inactive accounts
With A active, the cards of B (and of both Codex accounts) keep updating (“Updated n min ago”). Use account
B's quota elsewhere (e.g. claude.ai) and watch its card move while A stays active. `aiswitch usage` lists
every account.

### Step 13 – Uninstall restores ordinary behaviour
Settings → Shell → **Uninstall…** → *Remove PATH block and wrappers*. New terminal:
`command -v claude` prints the vendor path (e.g. `~/.local/bin/claude`), `claude auth status` reports the
login stored in `~/.claude` (`configDirectory` = `~/.claude`). `~/.zshrc` no longer contains the aiswitch
block; a backup exists in `~/.aiswitch/backups/`. Re-install from Settings and confirm switching works again.

### Step 14 – Continue a conversation under another account
1. With `Claude A` active, run `claude` in a project folder, ask something memorable, exit.
2. Dashboard → card `Claude A` → ⋯ → *Sessions…*. The conversation is listed with your prompt as title.
3. ⋯ on the row → *Duplicate to Claude B…* → the alert offers *Resume in Claude B*. Click it.
   Expected: a Terminal opens in the same project folder, runs `claude --resume <id>` under B
   (`claude auth status` in that window shows B), and the earlier conversation is visible.
4. `aiswitch sessions claude` lists the session for both accounts; the two files are independent copies.
5. Codex: same flow with `codex`. Record whether `codex resume <id>` finds the copied rollout; if it does not
   (newer Codex versions index threads in a database), note it in TROUBLESHOOTING and use `codex resume`
   (picker) or `--last` in the target profile.

### Extra checks
* With `ANTHROPIC_API_KEY` exported, `claude` prints the wrapper warning naming the variable, and
  Diagnostics lists it as an override. `claude auth status` reports `authMethod: api_key`; the card shows the
  warning instead of ACTIVE.
* Open Terminal with account (card → *Open Terminal*) while another account is active: in that window
  `claude auth status` shows the card's account; other windows are unaffected.
* Notifications: lower the 5-hour threshold to 50 % in Settings when an account is above it; a notification
  appears with **Switch account** when another signed-in account has ≥15 % more capacity; clicking it changes
  `~/.aiswitch/state/active-<provider>`.
* Opt-in auto switch: enable for Claude with threshold 95 %; when the active account crosses it, the selection
  changes and a notification explains it. Running sessions are untouched.

Record the actual outputs next to each step; nothing above has been executed by the authors of this repository.
