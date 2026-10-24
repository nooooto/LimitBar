#!/bin/bash
# Claude Code hook for LimitBar: marks a session as busy while Claude is working, so LimitBar
# turns Claude's menu bar icon orange.
#
#   claude-activity.sh working   on UserPromptSubmit and PreToolUse (also keeps long turns fresh)
#   claude-activity.sh idle      on Stop and Notification (done, or waiting for you)
#   claude-activity.sh end       on SessionEnd
#
# When a busy session stops, claude-last-stop says why (the hook's event: Stop or Notification)
# and in which folder, for LimitBar's "Claude ha finito" / "Claude ti aspetta" alert.
#
# Claude Code pipes the hook's JSON on stdin. Hooks must stay silent (a prompt hook's output
# reaches Claude's context) and must never fail, so errors are swallowed.
support="$HOME/Library/Application Support/LimitBar"
dir="$support/claude-activity"
input=$(cat)
session=$(/usr/bin/jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
session=${session//[^A-Za-z0-9_-]/}
[[ -n "$session" ]] || exit 0

case "$1" in
    working) mkdir -p "$dir" && : >"$dir/$session" ;;
    idle)
        # Only a turn that was going counts; Claude Code also notifies about a session left idle.
        if [[ -f "$dir/$session" ]]; then
            /usr/bin/jq -c '{event: .hook_event_name, cwd: .cwd}' <<<"$input" >"$support/claude-last-stop.tmp" &&
                mv -f "$support/claude-last-stop.tmp" "$support/claude-last-stop"
        fi
        rm -f "$dir/$session"
        ;;
    end) rm -f "$dir/$session" ;;
esac 2>/dev/null
exit 0
