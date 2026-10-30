#!/bin/sh
# aiswitch-statusline.sh -- optional "usage beacon" for Claude Code status lines.
#
# Claude Code pipes a JSON document to the configured statusLine command on every update. For Pro/Max
# logins that JSON carries `rate_limits.five_hour` / `rate_limits.seven_day` (used_percentage, resets_at).
# This script stores that document (atomically) under $AISWITCH_HOME/usage/ so the app can show the latest
# values Claude Code itself observed, with no network call and no credential access. It then forwards the
# JSON to the status-line command that was configured before (if any) so your existing status line keeps working.
#
# Install per profile with the app (Settings > Usage beacon) or by setting in <profile>/settings.json:
#   "statusLine": { "type": "command", "command": "~/.aiswitch/bin/aiswitch-statusline" }
AISWITCH_HOME="${AISWITCH_HOME:-$HOME/.aiswitch}"
profile=default
case "${CLAUDE_CONFIG_DIR:-}" in
  "$AISWITCH_HOME"/profiles/claude/*) profile=${CLAUDE_CONFIG_DIR#"$AISWITCH_HOME"/profiles/claude/}; profile=${profile%%/*} ;;
esac
input=$(cat)
dir="$AISWITCH_HOME/usage"
mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null
tmp="$dir/.claude-$profile.statusline.$$"
if printf '%s\n' "$input" > "$tmp" 2>/dev/null; then
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$dir/claude-$profile.statusline.json" 2>/dev/null || rm -f "$tmp"
fi
chain="$AISWITCH_HOME/config/statusline-chain-$profile"
if [ -r "$chain" ]; then
  IFS= read -r prev < "$chain" || prev=""
  if [ -n "$prev" ]; then
    printf '%s' "$input" | sh -c "$prev"
    exit $?
  fi
fi
exit 0
