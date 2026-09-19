#!/usr/bin/env bash
# Shows coding-agent status on a BUSY Bar through the BUSY cloud API.
# Usage: busybar.sh <command>, with the agent's hook JSON on stdin.
# Commands, settings and setup are described in ../SKILL.md.
# shellcheck disable=SC2016
set -u

API=https://api.busy.app/busybar
APP=busybar-hooks
KEYCHAIN_SERVICE=busybar-hooks
PRIORITY=${BUSYBAR_PRIORITY:-100}
TIMEOUT=${BUSYBAR_TIMEOUT:-600}
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/busybar-hooks
GREEN='#3FB950FF'
AMBER='#FFB000FF'
SOUND=${BUSYBAR_SOUND:-calendar_event_starts}

# Hook JSON -> {title, detail} for an approval alert. The detail names the program, file,
# host or MCP tool only, never full command lines.
SUMMARY_JQ='
def base: sub(".*/"; "");
def clean: gsub("[^ -~]"; "") | .[:40];
def shell:
  (if type == "array" then
     (if length >= 3 and (.[1] | test("^-l?c$")) then .[2] else join(" ") end)
   else . end)
  | split("\n")[0] | split("&&")[0] | split("||")[0] | split(";")[0] | split("|")[0]
  | [splits("\\s+") | select(length > 0)]
  | until(length == 0 or (.[0] | test("^[A-Za-z_][A-Za-z0-9_]*=") | not); .[1:])
  | if length == 0 then ""
    else (.[0] | base) + (if ((.[1] // "") | test("^[a-z][a-z0-9-]*$")) then " " + .[1] else "" end)
    end;
(.tool_name // "") as $t | (.tool_input // {}) as $in
| if $t == "" then {title: "APPROVE?", detail: ""}
  elif ($t | startswith("mcp__")) then
    {title: "MCP?", detail: ($t | ltrimstr("mcp__") | split("__") | .[0] + " " + (.[1:] | join("__")))}
  elif $t == "apply_patch" then
    {title: "Patch?", detail: ((($in.command // "") | tostring
      | capture("\\*\\*\\* (Add|Update|Delete) File: (?<p>[^\\n]+)") | .p | base) // "")}
  elif $t == "Bash" then {title: "Bash?", detail: (($in.command // "") | shell)}
  elif ($t == "Edit" or $t == "Write" or $t == "Read" or $t == "NotebookEdit") then
    {title: (($t | .[:8]) + "?"), detail: (($in.file_path // $in.notebook_path // "") | base)}
  elif $t == "WebFetch" then
    {title: "WebFetch?", detail: ((($in.url // "")
      | capture("^[A-Za-z][A-Za-z0-9+.-]*://(?<h>[^/:?#]+)") | .h) // "")}
  else {title: (($t | .[:8]) + "?"), detail: ""}
  end
| .title |= clean | .detail |= clean
'

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

# Sets TOKEN and TOKEN_SOURCE: BUSYBAR_TOKEN, then the Claude plugin setting, then the
# macOS Keychain. Fails when no token is configured.
load_token() {
  TOKEN=${BUSYBAR_TOKEN:-}
  TOKEN_SOURCE=env
  if [ -z "$TOKEN" ]; then
    TOKEN=${CLAUDE_PLUGIN_OPTION_TOKEN:-}
    TOKEN_SOURCE=plugin
  fi
  if [ -z "$TOKEN" ]; then
    TOKEN=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "${USER:-$(id -un)}" -w 2>/dev/null)
    TOKEN_SOURCE=keychain
  fi
  [ -n "$TOKEN" ]
}

# api METHOD PATH [BODY]: one call to the bar. In dry-run mode the call is appended to the
# file named by BUSYBAR_DRY_RUN as "METHOD PATH SOURCE BODY" instead of being sent.
api() {
  load_token || return 1
  if [ -n "${BUSYBAR_DRY_RUN:-}" ]; then
    printf '%s %s %s %s\n' "$1" "$2" "$TOKEN_SOURCE" "${3:-}" >> "$BUSYBAR_DRY_RUN"
    return
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

owner() {
  cat "$STATE_DIR/owner" 2>/dev/null
}

clear_bar() {
  api DELETE display/draw "{\"application_name\":\"$APP\"}" && rm -f "$STATE_DIR/owner"
}

play_sound() {
  [ "$SOUND" = off ] && return 0
  api POST audio/play "$(jq -nc --arg app "$APP" --arg s "shared/sounds/$SOUND.snd" \
    '{application_name: $app, stock_path: $s}')"
}

# draw STATE TITLE DETAIL COLOR: replace what the bar shows and take ownership of it.
# Fails when the bar did not accept the message.
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
     ]}' 2>/dev/null) || return 1
  api POST display/draw "$body" || return 1
  set_owner "$1"
  case $1 in approve|input) play_sound ;; esac
}

cmd_done() {
  rm -f "$PENDING"
  draw done DONE "$PROJECT" "$GREEN"
}

# record ID: save this request's summary for a later alert. Local only, returns at once.
record() {
  mkdir -p "$STATE_DIR" || return 1
  jq -c --arg id "$1" "$SUMMARY_JQ | .id = \$id" <<<"$INPUT" > "$PENDING.tmp" 2>/dev/null \
    && mv "$PENDING.tmp" "$PENDING"
}

# Alert from the saved request, else from the tool fields in this payload, else generic.
cmd_approve() {
  local s
  s=$(cat "$PENDING" 2>/dev/null)
  [ -n "$s" ] || s=$(jq -c "$SUMMARY_JQ" <<<"$INPUT")
  draw approve "$(jq -r .title <<<"$s")" "$(jq -r .detail <<<"$s")" "$AMBER"
}

cmd_input() {
  draw input 'INPUT?' "$PROJECT" "$AMBER"
}

# The approved tool ran or the turn was interrupted: take down this session's alert only.
cmd_cancel() {
  rm -f "$PENDING"
  case $(owner) in "$SESSION approve" | "$SESSION input") clear_bar ;; esac
}

# The user sent a prompt: take down whatever this session put on the bar.
cmd_clear() {
  rm -f "$PENDING"
  case $(owner) in "$SESSION "*) clear_bar ;; esac
}

# Stores the token in the macOS Keychain; `security` prompts for it twice without echo.
cmd_login() {
  if ! command -v security >/dev/null 2>&1; then
    echo "No macOS Keychain here. Set BUSYBAR_TOKEN in your environment instead." >&2
    return 1
  fi
  echo "Paste your BUSY Bar API token when asked (twice, input hidden)." >&2
  security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "${USER:-$(id -un)}" \
    -l "BUSY Bar API token (busybar-hooks)" -w
}

# Draws a short-lived test message and reports the HTTP status.
cmd_test() {
  if ! load_token; then
    echo "No token. Run 'busybar.sh login' or set BUSYBAR_TOKEN." >&2
    return 1
  fi
  TIMEOUT=10
  if draw done HELLO busybar-hooks "$GREEN"; then
    echo "Sent (HTTP ${API_STATUS:-dry run}). Look at the bar."
  else
    echo "The bar did not accept the test message (HTTP ${API_STATUS:-none})." >&2
    return 1
  fi
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
PENDING=$STATE_DIR/$SESSION.pending

case ${1:-} in
  done) cmd_done ;;
  record) record "$$.$RANDOM" ;;
  approve) cmd_approve ;;
  input) cmd_input ;;
  cancel) cmd_cancel ;;
  clear) cmd_clear ;;
  login) cmd_login; exit $? ;;
  test) cmd_test; exit $? ;;
  *)
    echo "usage: busybar.sh done|record|approve|input|cancel|clear|codex-wait|login|test" >&2
    exit 64
    ;;
esac
exit 0
