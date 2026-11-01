#!/bin/bash
# test_wrapper.sh -- executable specification of the aiswitch wrapper, installer and uninstaller.
# Runs on Linux and macOS with only sh/bash/awk. Uses fake `claude`/`codex` binaries that print their
# environment, so nothing here talks to Anthropic or OpenAI.
#
#   bash Tests/Shell/test_wrapper.sh            # run everything
#   WRAPPER_SHELLS="sh bash zsh" bash Tests/Shell/test_wrapper.sh   # also run the wrapper under extra shells
set -u

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WRAPPER="$repo/Wrapper/aiswitch-wrapper.sh"
STATUSLINE="$repo/Wrapper/aiswitch-statusline.sh"
INSTALL="$repo/Scripts/install-shell-integration.sh"
UNINSTALL="$repo/Scripts/uninstall-shell-integration.sh"

pass=0; fail=0; failures=()
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); failures+=("$1"); printf '  FAIL %s\n    %s\n' "$1" "${2:-}"; }
assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not found in: $2" ;; esac
}
assert_not_contains() { # name haystack needle
  case "$2" in *"$3"*) bad "$1" "[$3] unexpectedly found in: $2" ;; *) ok "$1" ;; esac
}
assert_file() { if [ -f "$2" ]; then ok "$1"; else bad "$1" "missing file $2"; fi; }
assert_no_file() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "unexpected file $2"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/aiswitch-test.XXXXXX")
cleanup() { rm -rf "${T:?}"; }
trap cleanup EXIT

export HOME="$T/home"
mkdir -p "$HOME" "$T/fakebin" "$T/work dir"
export AISWITCH_HOME="$HOME/.aiswitch"
# a clean environment for the tool-under-test
unset CLAUDE_CONFIG_DIR CODEX_HOME AISWITCH_CLAUDE_PROFILE AISWITCH_CODEX_PROFILE AISWITCH_QUIET AISWITCH_DEBUG \
      AISWITCH_PRINT_RESOLUTION AISWITCH_NO_ENV_WARN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
      CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN 2>/dev/null || true

for tool in claude codex; do
  cat > "$T/fakebin/$tool" <<'FAKE'
#!/bin/sh
printf 'REAL=%s\n' "$0"
printf 'CLAUDE_CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR:-}"
printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-}"
printf 'PWD=%s\n' "$PWD"
printf 'ARGC=%s\n' "$#"
for a in "$@"; do printf 'ARG=%s\n' "$a"; done
exit "${FAKE_EXIT:-0}"
FAKE
  chmod 755 "$T/fakebin/$tool"
done
BASEPATH="$T/fakebin:/usr/bin:/bin"
export PATH="$BASEPATH"

set_active() { # tool profile  (same atomic technique as the app: temp file + rename)
  mkdir -p "$AISWITCH_HOME/state"
  printf '%s\n' "$2" > "$AISWITCH_HOME/state/.active-$1.tmp.$$"
  mv -f "$AISWITCH_HOME/state/.active-$1.tmp.$$" "$AISWITCH_HOME/state/active-$1"
}
field() { # output key
  printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,""); print; exit}'
}

echo "== installer =="
printf '# my zshrc\nexport FOO=bar\n' > "$HOME/.zshrc"
cp "$HOME/.zshrc" "$T/zshrc.before"
out=$("$INSTALL" --rc "$HOME/.zshrc" --wrapper "$WRAPPER" --statusline "$STATUSLINE" --no-verify 2>&1)
assert_contains "installer finishes" "$out" "done"
assert_file "wrapper claude installed" "$AISWITCH_HOME/bin/claude"
assert_file "wrapper codex installed" "$AISWITCH_HOME/bin/codex"
assert_file "statusline beacon installed" "$AISWITCH_HOME/bin/aiswitch-statusline"
assert_eq "real claude recorded" "$T/fakebin/claude" "$(cat "$AISWITCH_HOME/config/claude.real")"
assert_eq "real codex recorded" "$T/fakebin/codex" "$(cat "$AISWITCH_HOME/config/codex.real")"
assert_eq "config file mode 0600" "600" "$(stat -c %a "$AISWITCH_HOME/config/claude.real" 2>/dev/null || stat -f %Lp "$AISWITCH_HOME/config/claude.real")"
assert_eq "home dir mode 0700" "700" "$(stat -c %a "$AISWITCH_HOME" 2>/dev/null || stat -f %Lp "$AISWITCH_HOME")"
assert_eq "rc block begin present once" "1" "$(grep -c '^# >>> aiswitch >>>$' "$HOME/.zshrc")"
assert_contains "rc keeps user content" "$(cat "$HOME/.zshrc")" "export FOO=bar"
backup=$(cat "$AISWITCH_HOME/config/rc-backup-.zshrc")
assert_file "rc backup exists" "$backup"
if cmp -s "$backup" "$T/zshrc.before"; then ok "rc backup is byte-identical to the original"; else bad "rc backup is byte-identical to the original"; fi
out=$("$INSTALL" --rc "$HOME/.zshrc" --wrapper "$WRAPPER" --statusline "$STATUSLINE" --no-verify --quiet 2>&1)
assert_eq "installer is idempotent (one block after 2 runs)" "1" "$(grep -c '^# >>> aiswitch >>>$' "$HOME/.zshrc")"
# sourcing the rc block must put bin first in PATH (and only once)
pathline=$(bash -c "source '$HOME/.zshrc'; source '$HOME/.zshrc'; printf '%s' \"\$PATH\"")
case "$pathline" in "$AISWITCH_HOME/bin:"*) ok "rc block prepends bin dir" ;; *) bad "rc block prepends bin dir" "$pathline" ;; esac
assert_eq "rc block does not duplicate PATH entry" "1" "$(printf '%s' "$pathline" | tr ':' '\n' | grep -c -x -F "$AISWITCH_HOME/bin")"
# the block also defines claude/codex shell functions that win over any later PATH edit
mkdir -p "$T/laterbin"; cp "$T/fakebin/claude" "$T/laterbin/claude"
printf 'export PATH="%s:$PATH"\n' "$T/laterbin" >> "$HOME/.zshrc"          # simulates Claude Code's installer / nvm appending after our block
fn=$(bash -c "source '$HOME/.zshrc'; type -t claude")
assert_eq "rc block defines a claude function" "function" "$fn"
mkdir -p "$AISWITCH_HOME/profiles/claude/fn-1"; set_active claude fn-1
out=$(bash -c "source '$HOME/.zshrc'; claude ping" 2>/dev/null)
assert_eq "function routes through the wrapper despite a later PATH prepend" "$AISWITCH_HOME/profiles/claude/fn-1" "$(field "$out" CLAUDE_CONFIG_DIR)"
assert_eq "function runs the real binary found by the wrapper" "$T/fakebin/claude" "$(field "$out" REAL)"
assert_contains "function passes arguments" "$out" "ARG=ping"
mv "$AISWITCH_HOME/bin/claude" "$AISWITCH_HOME/bin/claude.off"
out=$(bash -c "source '$HOME/.zshrc'; claude ping" 2>/dev/null)
assert_eq "function falls back to the plain command when the wrapper is missing" "" "$(field "$out" CLAUDE_CONFIG_DIR)"
assert_contains "fallback still runs a real claude" "$out" "REAL="
mv "$AISWITCH_HOME/bin/claude.off" "$AISWITCH_HOME/bin/claude"
# functional probe: the wrapper answers the dry-run flag before exec, the real binary does not
probe=$(bash -c "source '$HOME/.zshrc'; AISWITCH_PRINT_RESOLUTION=1 claude --version")
assert_contains "functional probe sees the wrapper" "$probe" "wrapper_version=1"
assert_eq "functional probe reports the profile" "fn-1" "$(field "$probe" profile)"
set_active claude default
# restore the rc to the installer's output for the remaining tests
"$INSTALL" --rc "$HOME/.zshrc" --wrapper "$WRAPPER" --statusline "$STATUSLINE" --no-verify --quiet >/dev/null 2>&1
printf '# my zshrc\nexport FOO=bar\n' > "$T/zshrc.before.tmp"; awk 'BEGIN{skip=0} /^# >>> aiswitch >>>$/{skip=1; next} /^# <<< aiswitch <<<$/{skip=0; next} !skip{print}' "$HOME/.zshrc" | grep -v "$T/laterbin" > "$T/zshrc.stripped"
printf '%s\n' "$(cat "$T/zshrc.stripped")" > "$HOME/.zshrc"
"$INSTALL" --rc "$HOME/.zshrc" --wrapper "$WRAPPER" --statusline "$STATUSLINE" --no-verify --quiet >/dev/null 2>&1

export PATH="$AISWITCH_HOME/bin:$BASEPATH"
W="$AISWITCH_HOME/bin/claude"
WX="$AISWITCH_HOME/bin/codex"

echo "== default passthrough =="
out=$(cd "$T/work dir" && "$W" foo "bar baz" --flag=1 2>/dev/null)
assert_eq "exec real binary" "$T/fakebin/claude" "$(field "$out" REAL)"
assert_eq "no CLAUDE_CONFIG_DIR for default" "" "$(field "$out" CLAUDE_CONFIG_DIR)"
assert_eq "cwd preserved" "$T/work dir" "$(field "$out" PWD)"
assert_eq "argc preserved" "3" "$(field "$out" ARGC)"
assert_contains "args preserved verbatim" "$out" "ARG=bar baz"
assert_contains "flag args preserved" "$out" "ARG=--flag=1"
( FAKE_EXIT=42 "$W" >/dev/null 2>&1 ); assert_eq "exit code passthrough" "42" "$?"
err=$("$W" 2>&1 >/dev/null); assert_eq "no warnings in the default case" "" "$err"

echo "== managed profiles and switching =="
mkdir -p "$AISWITCH_HOME/profiles/claude/work-1" "$AISWITCH_HOME/profiles/claude/personal-2" \
         "$AISWITCH_HOME/profiles/codex/work-1" "$AISWITCH_HOME/profiles/codex/personal-2"
set_active claude work-1
out=$("$W" 2>/dev/null)
assert_eq "claude work-1 applied" "$AISWITCH_HOME/profiles/claude/work-1" "$(field "$out" CLAUDE_CONFIG_DIR)"
assert_eq "codex untouched by claude profile" "" "$(field "$out" CODEX_HOME)"
set_active claude personal-2
out=$("$W" 2>/dev/null)
assert_eq "switch to personal-2 takes effect on next launch" "$AISWITCH_HOME/profiles/claude/personal-2" "$(field "$out" CLAUDE_CONFIG_DIR)"
set_active claude work-1
out=$("$W" 2>/dev/null)
assert_eq "switch back to work-1 without reinstall" "$AISWITCH_HOME/profiles/claude/work-1" "$(field "$out" CLAUDE_CONFIG_DIR)"
set_active codex work-1
out=$("$WX" 2>/dev/null)
assert_eq "codex work-1 applied via CODEX_HOME" "$AISWITCH_HOME/profiles/codex/work-1" "$(field "$out" CODEX_HOME)"
assert_eq "codex wrapper runs real codex" "$T/fakebin/codex" "$(field "$out" REAL)"
assert_eq "claude untouched by codex profile" "" "$(field "$out" CLAUDE_CONFIG_DIR)"
set_active codex default
out=$("$WX" 2>/dev/null)
assert_eq "codex 'default' sentinel means passthrough" "" "$(field "$out" CODEX_HOME)"
set_active codex work-1

echo "== per-terminal override =="
out=$(AISWITCH_CLAUDE_PROFILE=personal-2 "$W" 2>/dev/null)
assert_eq "env override beats state" "$AISWITCH_HOME/profiles/claude/personal-2" "$(field "$out" CLAUDE_CONFIG_DIR)"
out=$(AISWITCH_CLAUDE_PROFILE=default "$W" 2>/dev/null)
assert_eq "env override 'default' forces passthrough" "" "$(field "$out" CLAUDE_CONFIG_DIR)"
res=$(AISWITCH_CODEX_PROFILE=personal-2 AISWITCH_PRINT_RESOLUTION=1 "$WX")
assert_eq "codex env override reported as source=env" "env" "$(field "$res" profile_source)"

echo "== explicit user environment is respected =="
err=$(CLAUDE_CONFIG_DIR="$T/elsewhere" "$W" 2>&1 >/dev/null)
out=$(CLAUDE_CONFIG_DIR="$T/elsewhere" "$W" 2>/dev/null)
assert_eq "user CLAUDE_CONFIG_DIR not overridden" "$T/elsewhere" "$(field "$out" CLAUDE_CONFIG_DIR)"
assert_contains "warns that the profile was not applied" "$err" "NOT applied"
err=$(CLAUDE_CONFIG_DIR="$AISWITCH_HOME/profiles/claude/work-1" "$W" 2>&1 >/dev/null)
assert_eq "same dir already set: no warning" "" "$err"
res=$(CLAUDE_CONFIG_DIR="$T/elsewhere" AISWITCH_PRINT_RESOLUTION=1 "$W" 2>/dev/null)
assert_eq "resolution reports applied=no" "no" "$(field "$res" applied)"

echo "== credential overrides in the environment =="
err=$(ANTHROPIC_API_KEY=sk-test "$W" 2>&1 >/dev/null)
assert_contains "ANTHROPIC_API_KEY warning" "$err" "ANTHROPIC_API_KEY"
assert_not_contains "warning never prints the secret" "$err" "sk-test"
err=$(ANTHROPIC_API_KEY=sk-test CLAUDE_CODE_OAUTH_TOKEN=tok "$W" 2>&1 >/dev/null)
assert_contains "multiple overrides listed" "$err" "ANTHROPIC_API_KEY,CLAUDE_CODE_OAUTH_TOKEN"
err=$(ANTHROPIC_API_KEY=sk-test AISWITCH_QUIET=1 "$W" 2>&1 >/dev/null)
assert_eq "AISWITCH_QUIET silences warnings" "" "$err"
err=$(ANTHROPIC_API_KEY=sk-test AISWITCH_NO_ENV_WARN=1 "$W" 2>&1 >/dev/null)
assert_eq "AISWITCH_NO_ENV_WARN silences only the env warning" "" "$err"
err=$(OPENAI_API_KEY=sk-x "$WX" 2>&1 >/dev/null)
assert_contains "codex OPENAI_API_KEY warning" "$err" "OPENAI_API_KEY"
err=$(OPENAI_API_KEY=sk-x "$W" 2>&1 >/dev/null)
assert_eq "claude wrapper ignores OPENAI_API_KEY" "" "$err"

echo "== robustness =="
set_active claude ghost-9
out=$("$W" 2>/dev/null); err=$("$W" 2>&1 >/dev/null)
assert_eq "missing profile dir falls back to default" "" "$(field "$out" CLAUDE_CONFIG_DIR)"
assert_contains "missing profile dir warns" "$err" "ghost-9"
set_active claude "../evil"
out=$("$W" 2>/dev/null); err=$("$W" 2>&1 >/dev/null)
assert_eq "path-traversal profile id rejected" "" "$(field "$out" CLAUDE_CONFIG_DIR)"
assert_contains "invalid id warns" "$err" "invalid profile id"
set_active claude work-1
printf 'garbage\0\n' > "$AISWITCH_HOME/state/.x"; rm -f "$AISWITCH_HOME/state/.x"
# recursion guard: recorded real path points at the wrapper itself
cp "$AISWITCH_HOME/config/claude.real" "$T/claude.real.bak"
printf '%s\n' "$W" > "$AISWITCH_HOME/config/claude.real"
out=$("$W" 2>/dev/null); err=$("$W" 2>&1 >/dev/null)
assert_eq "recursion guard finds the real binary via PATH" "$T/fakebin/claude" "$(field "$out" REAL)"
assert_contains "recursion guard warns" "$err" "not usable"
# a symlink to the wrapper elsewhere in PATH must also be skipped
mkdir -p "$T/linkbin"; ln -sf "$W" "$T/linkbin/claude"
out=$(PATH="$T/linkbin:$PATH" "$W" 2>/dev/null)
assert_eq "symlinked wrapper copies are skipped during PATH search" "$T/fakebin/claude" "$(field "$out" REAL)"
printf '%s\n' "$T/nowhere/claude" > "$AISWITCH_HOME/config/claude.real"
( PATH="$AISWITCH_HOME/bin:/usr/bin:/bin" "$W" >/dev/null 2>&1 ); assert_eq "no real binary -> exit 127" "127" "$?"
cp "$T/claude.real.bak" "$AISWITCH_HOME/config/claude.real"
( "$W" >/dev/null 2>&1 ); assert_eq "restored config works again" "0" "$?"
mv "$T/fakebin/claude" "$T/fakebin/claude.off"
( PATH="$AISWITCH_HOME/bin:/usr/bin:/bin" "$W" >/dev/null 2>&1 ); assert_eq "recorded binary vanished and nothing in PATH -> 127" "127" "$?"
mv "$T/fakebin/claude.off" "$T/fakebin/claude"
( HOME= "$W" >/dev/null 2>&1 ); assert_eq "empty HOME fails cleanly" "2" "$?"
cp "$W" "$T/fakebin/notatool"; ( "$T/fakebin/notatool" >/dev/null 2>&1 ); assert_eq "wrong wrapper name fails cleanly" "2" "$?"; rm -f "$T/fakebin/notatool"

echo "== diagnostics mode =="
res=$(AISWITCH_PRINT_RESOLUTION=1 "$W" some args)
assert_eq "print-resolution: tool" "claude" "$(field "$res" tool)"
assert_eq "print-resolution: real" "$T/fakebin/claude" "$(field "$res" real)"
assert_eq "print-resolution: profile" "work-1" "$(field "$res" profile)"
assert_eq "print-resolution: source" "state" "$(field "$res" profile_source)"
assert_eq "print-resolution: config dir" "$AISWITCH_HOME/profiles/claude/work-1" "$(field "$res" config_dir)"
assert_eq "print-resolution: applied" "yes" "$(field "$res" applied)"
assert_not_contains "print-resolution does not run the real binary" "$res" "REAL="
res=$(AISWITCH_PRINT_RESOLUTION=1 ANTHROPIC_API_KEY=k "$W" 2>/dev/null)
assert_eq "print-resolution lists overrides" "ANTHROPIC_API_KEY" "$(field "$res" overrides)"
err=$(AISWITCH_DEBUG=1 "$W" 2>&1 >/dev/null)
assert_contains "debug prints resolution to stderr" "$err" "profile=work-1"
out=$(AISWITCH_DEBUG=1 "$W" 2>/dev/null)
assert_contains "debug still runs the real binary" "$out" "REAL="

echo "== atomic switching under concurrent reads =="
( for i in $(seq 1 150); do
    if [ $((i % 2)) -eq 0 ]; then set_active claude work-1; else set_active claude personal-2; fi
  done ) &
writer=$!
badreads=0; reads=0
while kill -0 "$writer" 2>/dev/null; do
  p=$(AISWITCH_PRINT_RESOLUTION=1 "$W" | awk -F= '$1=="profile"{print $2}')
  reads=$((reads+1))
  case "$p" in work-1|personal-2) ;; *) badreads=$((badreads+1)) ;; esac
done
wait "$writer"
assert_eq "every concurrent read saw a complete profile id ($reads reads)" "0" "$badreads"
set_active claude work-1

echo "== wrapper under other shells =="
for sh_ in ${WRAPPER_SHELLS:-sh bash}; do
  if command -v "$sh_" >/dev/null 2>&1; then
    out=$("$sh_" "$W" 2>/dev/null)
    assert_eq "runs under $sh_" "$AISWITCH_HOME/profiles/claude/work-1" "$(field "$out" CLAUDE_CONFIG_DIR)"
  else
    printf '  skip %s (not installed)\n' "$sh_"
  fi
done

echo "== status-line beacon =="
SL="$AISWITCH_HOME/bin/aiswitch-statusline"
json='{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600}}}'
printf '%s' "$json" | CLAUDE_CONFIG_DIR="$AISWITCH_HOME/profiles/claude/work-1" "$SL"
assert_eq "beacon writes profile-specific file" "$json" "$(cat "$AISWITCH_HOME/usage/claude-work-1.statusline.json")"
printf '%s' "$json" | "$SL"
assert_file "beacon writes default file when no profile" "$AISWITCH_HOME/usage/claude-default.statusline.json"
printf '%s\n' "cat > '$T/chained.json'; printf 'chained-output'" > "$AISWITCH_HOME/config/statusline-chain-work-1"
chained=$(printf '%s' "$json" | CLAUDE_CONFIG_DIR="$AISWITCH_HOME/profiles/claude/work-1" "$SL")
assert_eq "beacon forwards JSON to the previous status line command" "$json" "$(cat "$T/chained.json")"
assert_eq "beacon returns the chained command output" "chained-output" "$chained"

echo "== uninstall =="
out=$("$UNINSTALL" --rc "$HOME/.zshrc" 2>&1)
assert_contains "uninstall removes rc block" "$out" "rc_block_removed"
assert_eq "no block left" "0" "$(grep -c 'aiswitch' "$HOME/.zshrc")"
assert_contains "user rc content survives" "$(cat "$HOME/.zshrc")" "export FOO=bar"
assert_no_file "claude wrapper removed" "$AISWITCH_HOME/bin/claude"
assert_no_file "codex wrapper removed" "$AISWITCH_HOME/bin/codex"
if [ -d "$AISWITCH_HOME/profiles/claude/work-1" ]; then ok "profiles are kept by default"; else bad "profiles are kept by default"; fi
if cmp -s "$HOME/.zshrc" "$T/zshrc.before"; then ok "uninstall leaves rc byte-identical to the original"; else bad "uninstall leaves rc byte-identical to the original" "$(cat "$HOME/.zshrc" | od -c | tail -3)"; fi
out=$(PATH="$BASEPATH" bash -c 'command -v claude')
assert_eq "plain CLI resolves again after uninstall" "$T/fakebin/claude" "$out"
# reinstall then restore the exact pre-install rc
printf 'alias ll="ls -l"\n' >> "$HOME/.zshrc"; cp "$HOME/.zshrc" "$T/zshrc.before2"
"$INSTALL" --rc "$HOME/.zshrc" --wrapper "$WRAPPER" --no-verify --quiet >/dev/null 2>&1
"$UNINSTALL" --rc "$HOME/.zshrc" --restore --quiet >/dev/null 2>&1
if cmp -s "$HOME/.zshrc" "$T/zshrc.before2"; then ok "--restore puts back the byte-identical original rc"; else bad "--restore puts back the byte-identical original rc"; fi
"$INSTALL" --rc "$HOME/.zshrc" --wrapper "$WRAPPER" --no-verify --quiet >/dev/null 2>&1
"$UNINSTALL" --rc "$HOME/.zshrc" --purge --yes --quiet >/dev/null 2>&1
assert_no_file "--purge removes AISWITCH_HOME" "$AISWITCH_HOME"
# rc file that did not exist before install
rm -f "$HOME/.zshrc"
"$INSTALL" --rc "$HOME/.zshrc" --wrapper "$WRAPPER" --no-verify --quiet >/dev/null 2>&1
assert_file "installer creates a missing rc file" "$HOME/.zshrc"
"$UNINSTALL" --rc "$HOME/.zshrc" --restore --quiet >/dev/null 2>&1
assert_no_file "--restore removes an rc file the installer created" "$HOME/.zshrc"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf 'failures:\n'; printf '  - %s\n' "${failures[@]}"
  exit 1
fi
