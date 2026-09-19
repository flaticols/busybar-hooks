#!/usr/bin/env bash
# Dry-run tests for busybar.sh. Usage: bash tests/run.sh
# shellcheck disable=SC2016
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/plugins/busybar/skills/busybar/scripts/busybar.sh
ORIG_PATH=$PATH
PASS=0
FAIL=0

# Fresh state, a fake `security`, and a call log for every test.
setup() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/security" <<'EOF'
#!/bin/sh
if [ "$1" = find-generic-password ] && [ -n "${FAKE_KEYCHAIN:-}" ]; then
  echo "$FAKE_KEYCHAIN"
  exit 0
fi
exit 44
EOF
  chmod +x "$WORK/bin/security"
  unset CLAUDE_PLUGIN_OPTION_TOKEN FAKE_KEYCHAIN BUSYBAR_SOUND BUSYBAR_PRIORITY BUSYBAR_TIMEOUT BUSYBAR_CODEX_DELAY
  export PATH="$WORK/bin:$ORIG_PATH" XDG_STATE_HOME="$WORK/state" BUSYBAR_DRY_RUN="$WORK/calls" BUSYBAR_TOKEN=env-token
  : > "$BUSYBAR_DRY_RUN"
}

# hook CMD [JSON]: run the script the way an agent does. Sets OUT (stdout) and STATUS.
hook() {
  local in='{}'
  [ $# -ge 2 ] && in=$2
  OUT=$(printf '%s' "$in" | bash "$SCRIPT" "$1")
  STATUS=$?
}

# payload SESSION [TOOL] [INPUT_JSON]: hook JSON for /home/user/my-project.
payload() {
  jq -nc --arg s "$1" --arg t "${2:-}" --argjson i "${3:-null}" \
    '{session_id: $s, cwd: "/home/user/my-project"} + (if $t == "" then {} else {tool_name: $t, tool_input: $i} end)'
}

ncalls() { grep -c . "$BUSYBAR_DRY_RUN"; }
call() { sed -n "${1}p" "$BUSYBAR_DRY_RUN"; }
route() { call "$1" | cut -d' ' -f1,2; }
source_of() { call "$1" | cut -d' ' -f3; }
q() { call "$1" | cut -d' ' -f4- | jq -r "$2"; }

eq() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s: %s\n  expected: %s\n  actual:   %s\n' "$CURRENT" "$1" "$3" "$2"
  fi
}

test_done_draws_green_done_with_project() {
  hook done "$(payload s1)"
  eq route "$(route 1)" "POST display/draw"
  eq app "$(q 1 .application_name)" "busybar-hooks"
  eq priority "$(q 1 .priority)" "100"
  eq led "$(q 1 .led_notification_color)" "#3FB950FF"
  eq ids "$(q 1 '[.elements[].id] | join(",")')" "icon,title,detail"
  eq title "$(q 1 '.elements[1].text')" "DONE"
  eq detail "$(q 1 '.elements[2].text')" "my-project"
  eq timeout "$(q 1 '.elements[2].timeout')" "600"
  eq owner "$(cat "$XDG_STATE_HOME/busybar-hooks/owner")" "s1 done"
  eq calls "$(ncalls)" "1"
  eq stdout "$OUT" ""
  eq status "$STATUS" "0"
}

test_done_project_name_edge_cases() {
  hook done '{"session_id":"s1","cwd":"/home/user/my project/"}'
  eq trailing-slash "$(q 1 '.elements[2].text')" "my project"
  hook done '{"session_id":"s1","cwd":"/home/user/проект"}'
  eq non-ascii "$(q 2 '.elements[2].text')" "agent"
  hook done 'not json'
  eq bad-json "$(q 3 '.elements[2].text')" "agent"
  eq bad-json-owner "$(cat "$XDG_STATE_HOME/busybar-hooks/owner")" "manual done"
}

test_settings_override_priority_and_timeout() {
  export BUSYBAR_PRIORITY=50 BUSYBAR_TIMEOUT=30
  hook done "$(payload s1)"
  eq priority "$(q 1 .priority)" "50"
  eq timeout "$(q 1 '.elements[0].timeout')" "30"
}

test_invalid_setting_is_ignored_quietly() {
  export BUSYBAR_PRIORITY=high
  hook done "$(payload s1)"
  eq calls "$(ncalls)" "0"
  eq status "$STATUS" "0"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  CURRENT=$t
  setup
  "$t"
  rm -rf "$WORK"
done
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
