# Build and run

Requirements: macOS 14 (Sonoma) or newer, Xcode 16+ **or** the Command Line Tools with Swift 5.10+.
No Apple Developer membership: the app is ad-hoc signed and runs locally (Gatekeeper is not involved for
apps you build yourself).

## Option A — bundle script (SwiftPM, no Xcode project needed)

```bash
Scripts/build-app.sh            # release build → build/AIAccountSwitcher.app
Scripts/build-app.sh --debug
Scripts/build-app.sh --open     # and launch it
```

What it does: `swift build -c release` for the `AIAccountSwitcherApp` and `aiswitch` products, assembles
`build/AIAccountSwitcher.app` (Info.plist from `Xcode/Info.plist`, both executables in `Contents/MacOS`),
and runs `codesign --force --deep --sign -`. The CLI lives at
`build/AIAccountSwitcher.app/Contents/MacOS/aiswitch`; symlink it into your PATH if you want it everywhere:

```bash
ln -sf "$PWD/build/AIAccountSwitcher.app/Contents/MacOS/aiswitch" ~/.local/bin/aiswitch
```

## Option B — Xcode project

```bash
open Xcode/AIAccountSwitcher.xcodeproj
```

The project (object version 77, Xcode 16 synchronized folder) contains one app target that links the
`SwitcherCore` and `SwitcherMac` products of the Swift package in the repository root. Select the
*AIAccountSwitcher* scheme and Run. Signing is set to ad-hoc (`-`), no team required.

If Xcode refuses the hand-written project file, regenerate it with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd Xcode && xcodegen generate
```

or simply use option A / C.

## Option C — open the package

`open Package.swift` opens the package in Xcode; the `AIAccountSwitcherApp` executable scheme runs the UI
without a bundle (fine for development; notifications and launch-at-login need the bundle from A or B).

## Tests

```bash
Scripts/run-tests.sh      # shell test-suite, script syntax, then `swift test`
swift test                # XCTest only (SwitcherCore)
bash Tests/Shell/test_wrapper.sh
```

The shell suite exercises the wrapper, installer and uninstaller with fake `claude`/`codex` binaries and runs
on Linux too. The XCTest suite covers profile isolation, atomic switching, decoders, scheduling, notifications,
recommendations, the monitor, parsers and diagnostics (see TESTING.md).

## If the build fails

This project was authored on a machine without a Swift toolchain, so the first `swift build` on a Mac is
the first real compile. Typical fixes are one-liners (an API label or an availability annotation). Please
open an issue with the compiler output, or fix it and send a PR. The shell layer (`Wrapper/`, `Scripts/`)
works independently of the Swift build: you can already switch accounts with

```bash
Scripts/install-shell-integration.sh
mkdir -p ~/.aiswitch/profiles/claude/work && CLAUDE_CONFIG_DIR=~/.aiswitch/profiles/claude/work claude auth login
printf 'work\n' > ~/.aiswitch/state/.tmp && mv ~/.aiswitch/state/.tmp ~/.aiswitch/state/active-claude
claude auth status      # → configDirectory = ~/.aiswitch/profiles/claude/work
```

## Regenerating the embedded scripts

The wrapper is embedded in `SwitcherCore` so the app and the installer cannot drift. After editing
`Wrapper/*.sh` run `Scripts/sync-embedded-scripts.py`; a unit test fails otherwise.
