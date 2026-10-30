# Architecture

```
Sources/
  SwitcherCore/        Foundation-only logic (also compiles on Linux in principle)
    Models/            Provider, Account, AccountKey, AuthStatus, UsageSnapshot/UsageWindow, SyncStatus
    Storage/           SwitcherPaths (on-disk contract), AccountStore (accounts.json), UsageCache (+history)
    Managers/          ActiveAccountManager (atomic state file)  ← the switch
                       CLIProfileManager (profile dirs, seeding, vendor key derivation)
                       AccountManager (CRUD, default accounts)
    Shell/             EmbeddedScripts (generated from Wrapper/), RCFileEditor, LoginShell,
                       ShellIntegrationManager (install/uninstall/verify/dry-run)
    Auth/              ClaudeAuthStatusParser, CodexAuthParser, JWT
    Providers/         ProviderAdapter protocol + ProviderContext, ClaudeProvider, CodexProvider,
                       ClaudeUsageDecoder, CodexUsageDecoder, HTTPClient (+fakes)
    Usage/             BackoffPolicy, SmartRefreshPolicy + RefreshScheduler, NotificationDecisionEngine,
                       RecommendationEngine, UsageMonitor (actor)
    Diagnostics/       EnvOverrideDetector, Doctor
    Support/           SHA256, AtomicFile, ProcessRunner (+fake), TimeSource, SwitcherLog, VersionNumber
  SwitcherMac/         SecureStorage (Keychain), TerminalLauncher (.command files), LaunchAtLogin, SwitcherRuntime
  aiswitch/            CLI (status, list, use, which, add, login, auth, usage, rename, remove, doctor, install/uninstall-shell)
  AIAccountSwitcherApp/ SwiftUI: AppModel (@MainActor @Observable), Dashboard/cards/rings/pace/history,
                       MenuBarExtra, Onboarding, AddAccount, Settings, Diagnostics, NotificationManager,
                       sleep/wake + network observers, menu bar icon renderer
Wrapper/               aiswitch-wrapper.sh (installed as bin/claude + bin/codex), aiswitch-statusline.sh
Scripts/               install/uninstall-shell-integration.sh, build-app.sh, run-tests.sh, sync-embedded-scripts.py
Tests/Shell/           executable specification of the wrapper layer
Tests/SwitcherCoreTests XCTest
Xcode/                 AIAccountSwitcher.xcodeproj (+ XcodeGen project.yml), Info.plist
```

## The switch, end to end
1. `AppModel.setActive(account)` → `SwitcherRuntime.setActive` → `ActiveAccountManager.setActive`:
   validates id + directory, writes `state/active-<provider>` via temp file + `rename(2)`.
2. Then `ProviderAdapter.checkAuth` runs `claude auth status` / `codex login status` **inside the profile**
   (`ProviderContext.cliEnvironment`: override variables stripped, `CLAUDE_CONFIG_DIR`/`CODEX_HOME` set).
   The result and identity are cached on the account; the card shows ACTIVE only if authenticated and the
   login shell resolves the command to the wrapper (`ShellIntegrationManager.verify`).
3. Every `claude`/`codex` launch: the wrapper reads the state file (or the per-terminal override variable),
   exports the one variable, warns about overrides, `exec`s the recorded real binary.

## Wrapper contract (`Wrapper/aiswitch-wrapper.sh`)
* Inputs: `$0` basename (tool), `AISWITCH_HOME`, `AISWITCH_<TOOL>_PROFILE`, `state/active-<tool>`,
  `config/<tool>.real`, `profiles/<tool>/<id>/`.
* Outputs: `exec real "$@"` with cwd preserved; stderr warnings (`AISWITCH_QUIET=1` silences);
  `AISWITCH_PRINT_RESOLUTION=1` prints `key=value` lines and exits 0 (used by Doctor and tests).
* Guarantees: never re-executes itself (resolved-path comparison), never overrides a user-set
  `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, never fails the user's command because of a missing profile (falls back to
  default with a warning), exit codes/signals pass through.

## Usage pipeline
`UsageMonitor.refreshAll` → per account `refresh` (TaskGroup) → `ProviderAdapter.fetchUsage` → decoder →
`UsageCache.saveSnapshot` (+history) → `AccountUsageState` (snapshot, beacon, status, backoff). The app's
`RefreshScheduler` decides the next interval (smart/fixed/manual); `NotificationDecisionEngine` and
`RecommendationEngine` run after each round; opt-in auto-switch calls the same `setActive`.

## Extension points
* `UsageSource` enum + `ProviderAdapter.fetchUsage`: add a web-session source (claude.ai cookie) without
  touching the switch.
* `ProviderAdapter`: a third CLI only needs a `Provider` case, an adapter, and the wrapper's `case` table.
