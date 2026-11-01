#!/bin/bash
# build-app.sh -- builds AIAccountSwitcher.app without Xcode project files (SwiftPM + manual bundling) or,
# with --xcode, through xcodebuild. No paid Apple Developer account is needed: the bundle is ad-hoc signed.
#
# Usage: Scripts/build-app.sh [--xcode] [--debug] [--open] [--link]
#   --link   also symlink ~/.local/bin/aiswitch to the bundled CLI (and tell you if ~/.local/bin is not on PATH)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
use_xcode=0; config=release; open_after=0; link_cli=0
for a in "$@"; do
  case "$a" in
    --xcode) use_xcode=1 ;;
    --debug) config=debug ;;
    --open) open_after=1 ;;
    --link) link_cli=1 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done
out="build"
app="$out/AIAccountSwitcher.app"
mkdir -p "$out"

if [ "$use_xcode" = 1 ]; then
  command -v xcodebuild >/dev/null || { echo "xcodebuild not found (install Xcode)"; exit 1; }
  xcconfig=$([ "$config" = release ] && echo Release || echo Debug)
  xcodebuild -project Xcode/AIAccountSwitcher.xcodeproj -scheme AIAccountSwitcher -configuration "$xcconfig" \
    -derivedDataPath "$out/DerivedData" CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build
  rm -rf "${app:?}"
  cp -R "$out/DerivedData/Build/Products/$xcconfig/AIAccountSwitcher.app" "$app"
else
  command -v swift >/dev/null || { echo "swift not found (install Xcode or the Command Line Tools)"; exit 1; }
  swift build -c "$config" --product AIAccountSwitcherApp
  swift build -c "$config" --product aiswitch
  bin=$(swift build -c "$config" --show-bin-path)
  rm -rf "${app:?}"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin/AIAccountSwitcherApp" "$app/Contents/MacOS/AIAccountSwitcher"
  cp "$bin/aiswitch" "$app/Contents/MacOS/aiswitch"
  cp Xcode/Info.plist "$app/Contents/Info.plist"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  if [ -f build/AppIcon.icns ]; then
    cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist" 2>/dev/null || true
  fi
fi

codesign --force --deep --sign - "$app"
echo "built $app"
cli="$PWD/$app/Contents/MacOS/aiswitch"
if [ "$link_cli" = 1 ]; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$cli" "$HOME/.local/bin/aiswitch"
  echo "linked ~/.local/bin/aiswitch -> $cli"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: ~/.local/bin is not on your PATH; add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to ~/.zshrc" ;; esac
else
  echo "CLI: $cli"
  echo "     run again with --link to install it as ~/.local/bin/aiswitch"
fi
if [ "$open_after" = 1 ]; then
  # relaunch so a running copy picks up the new build
  osascript -e 'tell application "AIAccountSwitcher" to quit' >/dev/null 2>&1 || true
  sleep 1
  open "$app"
fi
