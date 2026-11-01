# Troubleshooting

Run `aiswitch doctor` (or Settings → Diagnostics) first. It prints, per CLI: wrapper status, recorded real
executable, what a fresh login shell resolves `claude`/`codex` to, the selected profile, a wrapper dry-run,
environment overrides, the expected Keychain item, CLI version, compatibility warnings and a live sign-in check.

## Banner says shell integration “is not in effect”
The app literally runs `claude --version` in a fresh login shell with the wrapper's dry-run flag and checks
whether the wrapper answered. The usual cause when wrappers are installed: another installer appended its own
PATH line to `~/.zshrc` *after* the aiswitch block (Claude Code's installer re-adds `~/.local/bin` on every
update; nvm prepends its node folder), so the real binary came first. Click **Repair**: the block is re-added at
the end of the rc file and now also defines `claude()`/`codex()` shell functions, which win over PATH order no
matter what gets appended later (if the wrapper file is missing they fall back to the plain command). Then open a
new terminal. `which claude` showing a function is expected; use `aiswitch which claude` for the full resolution.
If the probe cannot run at all (slow or interactive rc file, unusual shell), the banner says so and **Re-check**
retries.

## “Set Active” does nothing in Terminal
* Diagnostics says *Login shell resolves `claude` to /opt/homebrew/bin/claude* → the PATH block is not in
  effect. Open a **new** terminal; if it persists, something later in `~/.zshrc` (or `~/.zprofile`,
  `~/.zshenv`, oh-my-zsh, Homebrew shellenv) rewrites PATH. Move the `# >>> aiswitch >>>` block to the end of
  the file, or add `export PATH="$HOME/.aiswitch/bin:$PATH"` after those lines.
* You use bash/fish: add the same export to `~/.bashrc` / `config.fish` (`fish_add_path ~/.aiswitch/bin`).
* The card says *SELECTED · WRAPPER OFF*: same cause.

## `claude` ignores the selected account
* The wrapper printed `ANTHROPIC_API_KEY … takes precedence`: unset it (`unset ANTHROPIC_API_KEY`) or run
  `AISWITCH_NO_ENV_WARN=1` to silence if you really want the key. Same for `ANTHROPIC_AUTH_TOKEN`,
  `CLAUDE_CODE_OAUTH_TOKEN`, Bedrock/Vertex/Foundry variables, `OPENAI_API_KEY`, `CODEX_API_KEY`,
  `CODEX_ACCESS_TOKEN`.
* `CLAUDE_CONFIG_DIR is already set to … NOT applied`: you export that variable yourself; the wrapper never
  overrides an explicit user value. Remove the export.
* A settings file `env` block sets a credential (user `~/.claude/settings.json` or managed settings):
  Diagnostics lists it. Settings `env` wins over the shell.
* Claude *Console* keyless sign-in (`authMethod: api_key`): Claude Code keeps it outside the config dir, so
  it cannot be isolated. Use claude.ai subscription logins for switching.

## Badge stuck on SELECTED (not ACTIVE)
`claude auth status` / `codex login status` did not confirm a login in that profile. Click **Sign in** on the
card. For Claude ≥ 2.1.268 the JSON must contain `configDirectory` equal to the profile path; older versions
get a warning and should be updated (`claude update`).

## Keychain prompts
Claude Code stores logins with `/usr/bin/security`; the app reads them the same way (read-only) for usage
monitoring. macOS may ask once to allow access — choose *Always Allow* — or disable usage monitoring for
that account (card menu → Usage source → Disabled). Switching never needs Keychain access.

## “Usage paused · last reading 3 h ago”
The account is signed in; only the usage monitor's copy of its access token lapsed because the account was
idle (tokens last about eight hours and Claude Code renews them when the account is used). The last numbers
stay visible. Click **Refresh now** on the card: the app runs the vendor's own status command inside that
profile, which renews the token on Claude Code 2.1.301 and newer (Diagnostics warns on older builds; run
`claude update`). Otherwise use the account once (Open Terminal, run `claude`, quit) and the reading resumes
within a few minutes. Codex renews only when used.

## Usage shows “Stale”, “Rate limited”, “Sign-in needed”
* *Rate limited*: the Anthropic endpoint answers bursts with 429. The app backs off (1 → 30 min, honouring
  `Retry-After`). Do not run several monitoring tools against the same account.
* *Login needed*: the stored access token expired or was rejected. Run `claude` / `codex` once in that profile
  (Open Terminal on the card) so the vendor CLI refreshes it; or re-authenticate.
* *Blocked by bot protection*: an HTML page came back. Wait; a VPN/proxy makes it more likely.
* Codex *keyring* mode: usage cannot be read; set `cli_auth_credentials_store = "file"` in the profile's
  `config.toml` (the app writes this by default) unless an admin `requirements.toml` forbids it.
* Codex API-key profile: no ChatGPT quota exists for API keys.

## Login window closes immediately / port in use
`claude auth login` and `codex login` need a free localhost port (Codex: 1455). Close other login attempts.
Codex: use *Sign in with device code…* from the card menu.

## “could not find the real 'claude' executable”
The recorded path in `~/.aiswitch/config/claude.real` is gone (CLI reinstalled elsewhere). Reinstall shell
integration (Settings → Shell → Install / repair) or `aiswitch install-shell`.

## Two profiles show the same account
* Both were logged in with the same browser session by accident: re-authenticate one of them in a private
  browser window.
* Claude Code older than the hashed-Keychain scheme: update Claude Code; Diagnostics shows the version.

## Uninstall / rollback
Settings → Shell → Uninstall, or `Scripts/uninstall-shell-integration.sh [--restore] [--purge --yes]`.
`--restore` puts back the exact rc file saved at install time. Profiles stay unless you purge.

## Menu bar label too wide / hard to read
Settings → General → Menu bar: switch to *Compact* (`WK12 PER41 CX8`), turn off the mini rings, or use
*Active accounts only*. Short labels are edited per account with Rename… (up to 4 characters). The label is
rendered as an image so its threshold colors survive both light and dark menu bars.

## Live usage does not appear / LIVE badge missing
* The beacon only receives numbers from claude.ai Pro and Max logins, and only while a `claude` session in that
  account is running and after its first response. Idle accounts fall back to the polled numbers.
* Sessions that were already open when you turned the toggle on keep their old status line. Start a new
  `claude` session; the first LIVE reading arrives after its first response.
* Codex has no status-line hook, so `aiswitch beacon codex …` only prints a note; Codex numbers stay polled.
* Check the switch: `aiswitch beacon claude <account> status` prints whether the profile's settings.json points at
  the beacon, the chained previous status line (if any), and the file the app watches
  (`~/.aiswitch/usage/claude-<profile>.statusline.json`); its timestamp should move while you chat.
* A settings.json that is not valid JSON is never modified; the toggle reports the problem instead.
* Turning the toggle off restores your previous status line command exactly.

## Resume says the session was not found
* Claude Code looks for `<id>.jsonl` under `projects/<folder-for-the-current-directory>/`. The app resumes in
  the conversation's original folder for that reason; if you moved or renamed the project, run
  `claude --resume <id>` from the old path or copy the transcript folder by hand.
* The duplicate only exists in the target profile after *Duplicate to…* (or `aiswitch copy-session`).
  `aiswitch sessions <provider>` shows which accounts hold which ids.
* Codex: newer versions keep a thread index next to the rollout files; a copied rollout may not appear in the
  picker. Try `codex resume <id>` directly, then `codex resume --last` in the target profile.

## Logs
`~/.aiswitch/logs/aiswitch.log` (secrets redacted). The wrapper prints its resolution with
`AISWITCH_DEBUG=1 claude --version`.
