#!/bin/bash
# install-shell-integration.sh -- installs the aiswitch CLI wrappers and (optionally) the PATH block.
#
# The macOS app performs the same steps natively (ShellIntegrationManager); this script is the scriptable /
# manual equivalent and is what the shell test-suite exercises.
#
# Usage:
#   install-shell-integration.sh [--home DIR] [--rc FILE ...] [--no-rc] [--claude PATH] [--codex PATH]
#                                [--wrapper FILE] [--statusline FILE] [--no-verify] [--verify-shell SHELL] [--quiet]
#
# What it does (all reversible with uninstall-shell-integration.sh):
#   1. creates $AISWITCH_HOME (default ~/.aiswitch) with mode 0700 and its sub-directories
#   2. records the canonical path of the real `claude` / `codex` executables in $AISWITCH_HOME/config/<tool>.real
#   3. copies the wrapper to $AISWITCH_HOME/bin/claude and /codex (and the status-line beacon)
#   4. appends a marked PATH block to the rc file(s) (default ~/.zshrc), after backing them up
#   5. verifies, in a fresh login shell, that `command -v claude` now resolves to the wrapper
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AISWITCH_HOME="${AISWITCH_HOME:-${HOME:?}/.aiswitch}"
rc_files=()
no_rc=0
claude_path=""
codex_path=""
wrapper_src="$here/../Wrapper/aiswitch-wrapper.sh"
statusline_src="$here/../Wrapper/aiswitch-statusline.sh"
verify=1
verify_shell=""
quiet=0

while [ $# -gt 0 ]; do
  case "$1" in
    --home) AISWITCH_HOME=$2; shift 2 ;;
    --rc) rc_files+=("$2"); shift 2 ;;
    --no-rc) no_rc=1; shift ;;
    --claude) claude_path=$2; shift 2 ;;
    --codex) codex_path=$2; shift 2 ;;
    --wrapper) wrapper_src=$2; shift 2 ;;
    --statusline) statusline_src=$2; shift 2 ;;
    --no-verify) verify=0; shift ;;
    --verify-shell) verify_shell=$2; shift 2 ;;
    --quiet) quiet=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ ${#rc_files[@]} -eq 0 ] && rc_files=("$HOME/.zshrc")
: "${AISWITCH_HOME:?AISWITCH_HOME must not be empty}"

log() { [ "$quiet" = 1 ] || printf '%s\n' "$*"; }
bindir="$AISWITCH_HOME/bin"

resolve_path() {
  local r
  if command -v realpath >/dev/null 2>&1; then
    r=$(realpath "$1" 2>/dev/null) && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  fi
  r=$(readlink -f "$1" 2>/dev/null) && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  printf '%s\n' "$1"
}

is_wrapper() { [ -f "$1" ] && grep -q 'AISWITCH_WRAPPER_VERSION' "$1" 2>/dev/null; }

# Atomic write of a one-line file with mode 0600 (temp file + rename in the same directory).
write_atomic() { # file content
  local f=$1 tmp
  tmp="$(dirname "$f")/.$(basename "$f").tmp.$$"
  umask 077
  printf '%s\n' "$2" > "$tmp"
  mv -f "$tmp" "$f"
}

find_real() { # tool
  local tool=$1 d cand bindir_r
  bindir_r=$(resolve_path "$bindir")
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || d=.
    cand="$d/$tool"
    [ -x "$cand" ] && [ ! -d "$cand" ] || continue
    [ "$(resolve_path "$d")" = "$bindir_r" ] && continue
    is_wrapper "$cand" && continue
    printf '%s\n' "$cand"; return 0
  done
  unset IFS
  for cand in "$HOME/.local/bin/$tool" "/opt/homebrew/bin/$tool" "/usr/local/bin/$tool" "$HOME/.claude/local/$tool" "$HOME/.npm-global/bin/$tool"; do
    if [ -x "$cand" ] && ! is_wrapper "$cand"; then printf '%s\n' "$cand"; return 0; fi
  done
  return 1
}

[ -f "$wrapper_src" ] || { echo "wrapper source not found: $wrapper_src" >&2; exit 1; }

# 1. layout
umask 077
mkdir -p "$AISWITCH_HOME" "$bindir" "$AISWITCH_HOME/config" "$AISWITCH_HOME/state" \
  "$AISWITCH_HOME/profiles/claude" "$AISWITCH_HOME/profiles/codex" "$AISWITCH_HOME/backups" \
  "$AISWITCH_HOME/usage" "$AISWITCH_HOME/history" "$AISWITCH_HOME/logs" "$AISWITCH_HOME/tmp"
chmod 700 "$AISWITCH_HOME"
chmod 755 "$bindir"   # wrappers must be executable by the user's shells; the parent is 0700 anyway

# 2. real executables
for tool in claude codex; do
  explicit=""
  [ "$tool" = claude ] && explicit=$claude_path
  [ "$tool" = codex ] && explicit=$codex_path
  real=""
  if [ -n "$explicit" ]; then
    real=$explicit
  elif [ -r "$AISWITCH_HOME/config/$tool.real" ]; then
    IFS= read -r real < "$AISWITCH_HOME/config/$tool.real" || real=""
    if [ -n "$real" ] && { [ ! -x "$real" ] || is_wrapper "$real"; }; then real=""; fi
  fi
  if [ -z "$real" ]; then
    real=$(find_real "$tool" || true)
  fi
  if [ -n "$real" ]; then
    if is_wrapper "$real"; then
      echo "refusing to record $real for $tool: it is an aiswitch wrapper" >&2; exit 1
    fi
    write_atomic "$AISWITCH_HOME/config/$tool.real" "$real"
    log "real_$tool=$real"
  else
    log "real_$tool=(not found; the wrapper will search PATH at run time)"
  fi
done

# 3. wrappers (copied, so the tool name is derived from the file name)
for tool in claude codex; do
  tmp="$bindir/.$tool.tmp.$$"
  cp "$wrapper_src" "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$bindir/$tool"
  log "installed_wrapper=$bindir/$tool"
done
if [ -f "$statusline_src" ]; then
  tmp="$bindir/.aiswitch-statusline.tmp.$$"
  cp "$statusline_src" "$tmp"; chmod 755 "$tmp"; mv -f "$tmp" "$bindir/aiswitch-statusline"
  log "installed_statusline=$bindir/aiswitch-statusline"
fi

# 4. PATH block
if [ "$AISWITCH_HOME" = "$HOME/.aiswitch" ]; then
  path_expr='$HOME/.aiswitch/bin'
else
  path_expr=$bindir
fi
block_begin='# >>> aiswitch >>>'
block_end='# <<< aiswitch <<<'
if [ "$no_rc" = 0 ]; then
  ts=$(date +%Y%m%d-%H%M%S)
  for rc in "${rc_files[@]}"; do
    backup_dir="$AISWITCH_HOME/backups/$ts"
    mkdir -p "$backup_dir"
    if [ -f "$rc" ]; then
      cp -p "$rc" "$backup_dir/$(basename "$rc")"
      write_atomic "$AISWITCH_HOME/config/rc-backup-$(basename "$rc")" "$backup_dir/$(basename "$rc")"
    else
      write_atomic "$AISWITCH_HOME/config/rc-backup-$(basename "$rc")" "(none: $rc did not exist before install)"
    fi
    tmp="$rc.aiswitch.tmp.$$"
    {
      if [ -f "$rc" ]; then
        awk -v b="$block_begin" -v e="$block_end" 'BEGIN{skip=0; held=0} { if (skip) { if ($0==e) skip=0; next } if ($0==b) { skip=1; held=0; next } if (held) { print ""; held=0 } if ($0=="") { held=1; next } print } END{ if (held) print "" }' "$rc"
      fi
      printf '\n%s\n' "$block_begin"
      printf '# Added by AI Account Switcher: routes claude/codex through the account-aware wrappers.\n'
      printf '# Remove this block (or run Scripts/uninstall-shell-integration.sh) to restore the plain CLIs.\n'
      printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$path_expr" "$path_expr"
      printf '# Functions win over PATH, so lines added later by other installers (nvm, Claude Code) cannot bypass the wrappers.\n'
      printf 'claude() { if [ -x "%s/claude" ]; then "%s/claude" "$@"; else command claude "$@"; fi; }\n' "$path_expr" "$path_expr"
      printf 'codex() { if [ -x "%s/codex" ]; then "%s/codex" "$@"; else command codex "$@"; fi; }\n' "$path_expr" "$path_expr"
      printf '%s\n' "$block_end"
    } > "$tmp"
    if [ -f "$rc" ]; then chmod --reference="$rc" "$tmp" 2>/dev/null || chmod 644 "$tmp"; else chmod 644 "$tmp"; fi
    mv -f "$tmp" "$rc"
    log "rc_updated=$rc"
    log "rc_backup=$backup_dir/$(basename "$rc")"
  done
fi

# 5. verification in a fresh login shell
if [ "$verify" = 1 ]; then
  shell=${verify_shell:-${SHELL:-/bin/zsh}}
  if [ -x "$shell" ]; then
    for tool in claude codex; do
      got=$("$shell" -lic "command -v $tool" 2>/dev/null | tail -n 1 || true)
      if [ "$got" = "$bindir/$tool" ]; then
        log "verified_$tool=yes"
      else
        log "verified_$tool=no (login shell resolves '$tool' to '${got:-nothing}'; expected $bindir/$tool). Open a new terminal or check PATH order in your rc files."
      fi
    done
  else
    log "verified=skipped (shell $shell not found)"
  fi
else
  log "verified=skipped"
fi
log "done"
