#!/bin/bash
# run-tests.sh -- runs everything that can run on this machine:
#   * shell test-suite (Linux or macOS; needs only sh/bash/awk)
#   * `swift test` for SwitcherCore when a Swift toolchain is present (macOS)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
echo "== shell tests =="
WRAPPER_SHELLS="sh bash zsh" bash Tests/Shell/test_wrapper.sh
echo
echo "== script syntax =="
for f in Wrapper/*.sh Scripts/*.sh Tests/Shell/*.sh; do sh -n "$f" 2>/dev/null || bash -n "$f"; done && echo "ok"
if command -v shellcheck >/dev/null 2>&1; then shellcheck -S warning Wrapper/*.sh Scripts/*.sh Tests/Shell/*.sh && echo "shellcheck ok"; fi
echo
if command -v swift >/dev/null 2>&1; then
  echo "== swift test =="
  swift test "$@"
else
  echo "swift toolchain not found: skipping swift test (run this on macOS with Xcode / Command Line Tools)"
fi
