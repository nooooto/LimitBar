#!/bin/bash
# Claude Code status line that also hands the account's usage limits to LimitBar.
# Claude Code pipes its session JSON on stdin; only `rate_limits` is kept, in
# ~/Library/Application Support/LimitBar/claude-status.json, so LimitBar can skip
# polling Anthropic's usage endpoint while Claude is being used from the terminal.
dir="$HOME/Library/Application Support/LimitBar"
input=$(cat)

limits=$(jq -c '.rate_limits // empty' <<<"$input" 2>/dev/null)
if [[ -n "$limits" && "$limits" != "{}" ]]; then
    mkdir -p "$dir"
    tmp="$dir/claude-status.json.$$"
    jq -n --argjson r "$limits" '{rate_limits: $r, updated_at: now}' >"$tmp" \
        && mv -f "$tmp" "$dir/claude-status.json"
fi

jq -r '
    [ (.model.display_name // empty),
      (.rate_limits.five_hour.used_percentage // empty | "5 ore \(round)%"),
      (.rate_limits.seven_day.used_percentage // empty | "settimana \(round)%") ]
    | join(" · ")' <<<"$input" 2>/dev/null
