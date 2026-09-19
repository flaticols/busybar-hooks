#!/usr/bin/env bash
# Shows coding-agent status on a BUSY Bar through the BUSY cloud API.
# Usage: busybar.sh <command>, with the agent's hook JSON on stdin.
# Commands, settings and setup are described in ../SKILL.md.
# shellcheck disable=SC2016
set -u

API=https://api.busy.app/busybar
APP=busybar-hooks
PRIORITY=${BUSYBAR_PRIORITY:-100}
TIMEOUT=${BUSYBAR_TIMEOUT:-600}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/busybar-hooks
GREEN='#3FB950FF'

# 15x15 spark drawn left of the text.
ICON='! XPM2
15 15 2 1
. c none
# c #D97757
.......#.......
.......#.......
.......#.......
.....#.#.#.....
..#..#.#.#..#..
...##.###.##...
.....#####.....
.############..
.....#####.....
...##.###.##...
.##..#.#.#..##.
.....#.#.#.....
.......#.......
.......#.......
...............
'

# Sets TOKEN and TOKEN_SOURCE; fails when no token is configured.
load_token() {
  TOKEN=${BUSYBAR_TOKEN:-}
  TOKEN_SOURCE=env
  [ -n "$TOKEN" ]
}

# api METHOD PATH [BODY]: one call to the bar. In dry-run mode the call is appended to the
# file named by BUSYBAR_DRY_RUN as "METHOD PATH SOURCE BODY" instead of being sent.
api() {
  load_token || return 1
  if [ -n "${BUSYBAR_DRY_RUN:-}" ]; then
    printf '%s %s %s %s\n' "$1" "$2" "$TOKEN_SOURCE" "${3:-}" >> "$BUSYBAR_DRY_RUN"
    return 0
  fi
  API_STATUS=$(printf '%s' "${3:-}" | curl -sS --max-time 8 -o /dev/null -w '%{http_code}' \
    -X "$1" -H @<(printf 'Authorization: Bearer %s\n' "$TOKEN") \
    -H 'Content-Type: application/json' --data-binary @- "$API/$2")
  case $API_STATUS in 2*) return 0 ;; esac
  echo "busybar: $1 $2 -> HTTP $API_STATUS" >&2
  return 1
}

set_owner() {
  mkdir -p "$STATE_DIR" && printf '%s %s\n' "$SESSION" "$1" > "$STATE_DIR/owner"
}

# draw STATE TITLE DETAIL COLOR: replace what the bar shows and take ownership of it.
draw() {
  local body
  body=$(jq -nc --arg app "$APP" --argjson prio "$PRIORITY" --argjson ttl "$TIMEOUT" \
    --arg icon "$ICON" --arg title "$2" --arg detail "$3" --arg color "$4" '
    {application_name: $app, priority: $prio, led_notification_color: $color,
     elements: [
       {id: "icon", type: "xpmbitmap", data: $icon, align: "top_left", x: 0, y: 0, timeout: $ttl},
       {id: "title", type: "text", text: $title, font: "small", color: $color,
        align: "top_left", x: 18, y: 0, timeout: $ttl},
       {id: "detail", type: "text", text: ($detail | if . == "" then " " else . end),
        font: "small", color: "#FFFFFFFF", align: "bottom_left", x: 18, y: 16, width: 54,
        scroll_rate: 1200, scroll_start_delay: 1000, scroll_repeat_delay: 2000, timeout: $ttl}
     ]}' 2>/dev/null) || return 0
  api POST display/draw "$body" || return 0
  set_owner "$1"
}

cmd_done() {
  draw done DONE "$PROJECT" "$GREEN"
}

command -v jq >/dev/null 2>&1 || { echo "busybar: jq is required" >&2; exit 0; }

INPUT=
[ -t 0 ] || INPUT=$(cat)
if [ -z "$INPUT" ] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$INPUT"; then
  INPUT='{}'
fi
SESSION=$(jq -r '.session_id // ""' <<<"$INPUT" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
[ -n "$SESSION" ] || SESSION=manual
PROJECT=$(jq -r '.cwd // "" | rtrimstr("/") | sub(".*/"; "") | gsub("[^ -~]"; "")' <<<"$INPUT")
[ -n "$PROJECT" ] || PROJECT=agent

case ${1:-} in
  done) cmd_done ;;
  *)
    echo "usage: busybar.sh done|record|approve|input|cancel|clear|codex-wait|login|test" >&2
    exit 64
    ;;
esac
exit 0
