# Troubleshooting

Run `aiswitch doctor` (or Settings → Diagnostics) first. It prints, per CLI: wrapper status, recorded real
executable, what a fresh login shell resolves `claude`/`codex` to, the selected profile, a wrapper dry-run,
environment overrides, the expected Keychain item, CLI version, compatibility warnings and a live sign-in check.

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

## Usage shows “Stale”, “Rate limited”, “Login needed”
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

## Logs
`~/.aiswitch/logs/aiswitch.log` (secrets redacted). The wrapper prints its resolution with
`AISWITCH_DEBUG=1 claude --version`.
