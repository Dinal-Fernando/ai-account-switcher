#!/bin/bash
# uninstall-shell-integration.sh -- removes the aiswitch wrappers and PATH block; optionally restores the rc
# backups taken at install time or purges all aiswitch data (profiles included).
#
# Usage: uninstall-shell-integration.sh [--home DIR] [--rc FILE ...] [--restore] [--purge --yes] [--quiet]
#   (default)  remove the PATH block from the rc file(s) and delete the wrappers; profiles/accounts are kept
#   --restore  instead of editing the rc file, put back the backup taken at install time (loses later edits!)
#   --purge    additionally delete $AISWITCH_HOME entirely (all profiles and logins created by the app)
set -euo pipefail
AISWITCH_HOME="${AISWITCH_HOME:-${HOME:?}/.aiswitch}"
rc_files=(); restore=0; purge=0; yes=0; quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --home) AISWITCH_HOME=$2; shift 2 ;;
    --rc) rc_files+=("$2"); shift 2 ;;
    --restore) restore=1; shift ;;
    --purge) purge=1; shift ;;
    --yes) yes=1; shift ;;
    --quiet) quiet=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ ${#rc_files[@]} -eq 0 ] && rc_files=("$HOME/.zshrc")
: "${AISWITCH_HOME:?AISWITCH_HOME must not be empty}"
case "$AISWITCH_HOME" in
  /|/*/..|"$HOME"|"${HOME:?}/") echo "refusing to operate on $AISWITCH_HOME" >&2; exit 2 ;;
esac
log() { [ "$quiet" = 1 ] || printf '%s\n' "$*"; }
bindir="${AISWITCH_HOME:?}/bin"
block_begin='# >>> aiswitch >>>'
block_end='# <<< aiswitch <<<'

for rc in "${rc_files[@]}"; do
  [ -f "$rc" ] || { log "rc_missing=$rc"; continue; }
  if [ "$restore" = 1 ] && [ -r "$AISWITCH_HOME/config/rc-backup-$(basename "$rc")" ]; then
    IFS= read -r backup < "$AISWITCH_HOME/config/rc-backup-$(basename "$rc")" || backup=""
    if [ -f "$backup" ]; then
      cp -p "$backup" "$rc.aiswitch.tmp.$$" && mv -f "$rc.aiswitch.tmp.$$" "$rc"
      log "rc_restored=$rc (from $backup)"
      continue
    elif [ "${backup#\(none}" != "$backup" ]; then
      rm -f "${rc:?}"; log "rc_removed=$rc (did not exist before install)"; continue
    fi
  fi
  if grep -qxF "$block_begin" "$rc"; then
    tmp="$rc.aiswitch.tmp.$$"
    awk -v b="$block_begin" -v e="$block_end" 'BEGIN{skip=0; held=0} { if (skip) { if ($0==e) skip=0; next } if ($0==b) { skip=1; held=0; next } if (held) { print ""; held=0 } if ($0=="") { held=1; next } print } END{ if (held) print "" }' "$rc" > "$tmp"
    chmod --reference="$rc" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$rc"
    log "rc_block_removed=$rc"
  else
    log "rc_block_absent=$rc"
  fi
done

for f in claude codex aiswitch-statusline; do
  target="${bindir:?}/${f:?}"
  if [ -f "$target" ] && grep -q 'aiswitch' "$target" 2>/dev/null; then
    rm -f "$target"; log "wrapper_removed=$target"
  fi
done

if [ "$purge" = 1 ]; then
  if [ "$yes" != 1 ]; then
    printf 'This deletes %s including every account profile and login created by the app. Type "purge" to confirm: ' "$AISWITCH_HOME"
    read -r answer
    [ "$answer" = purge ] || { echo "aborted"; exit 1; }
  fi
  rm -rf "${AISWITCH_HOME:?}"
  log "purged=$AISWITCH_HOME"
fi
log "done"
