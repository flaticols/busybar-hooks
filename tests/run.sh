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
  for _agent_env in ${!CLAUDE_@} ${!CODEX_@}; do
    unset "$_agent_env"
  done
  unset CLAUDE_PLUGIN_OPTION_TOKEN FAKE_KEYCHAIN BUSYBAR_AGENT BUSYBAR_SESSION AGTERM_SESSION_ID BUSYBAR_ICON_DIR BUSYBAR_SOUND BUSYBAR_PRIORITY BUSYBAR_TIMEOUT BUSYBAR_CODEX_DELAY
  export PATH="$WORK/bin:$ORIG_PATH" XDG_STATE_HOME="$WORK/state" BUSYBAR_DRY_RUN="$WORK/calls" BUSYBAR_TOKEN=env-token
  : > "$BUSYBAR_DRY_RUN"
}

# hook CMD [JSON]: run the script the way an agent does. Sets OUT (stdout) and STATUS.
hook() {
  local command=$1
  local in='{}'
  [ $# -ge 2 ] && in=$2
  if [ $# -ge 2 ]; then
    shift 2
  else
    shift
  fi
  OUT=$(printf '%s' "$in" | bash "$SCRIPT" "$command" "$@")
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
  hook 'done' "$(payload s1)"
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
  hook 'done' '{"session_id":"s1","cwd":"/home/user/my project/"}'
  eq trailing-slash "$(q 1 '.elements[2].text')" "my project"
  hook 'done' '{"session_id":"s1","cwd":"/home/user/проект"}'
  eq non-ascii "$(q 2 '.elements[2].text')" "agent"
  hook 'done' 'not json'
  eq bad-json "$(q 3 '.elements[2].text')" "agent"
  eq bad-json-owner "$(cat "$XDG_STATE_HOME/busybar-hooks/owner")" "manual done"
}

test_settings_override_priority_and_timeout() {
  export BUSYBAR_PRIORITY=50 BUSYBAR_TIMEOUT=30
  hook 'done' "$(payload s1)"
  eq priority "$(q 1 .priority)" "50"
  eq timeout "$(q 1 '.elements[0].timeout')" "30"
}

test_invalid_setting_is_ignored_quietly() {
  export BUSYBAR_PRIORITY=high
  hook 'done' "$(payload s1)"
  eq calls "$(ncalls)" "0"
  eq status "$STATUS" "0"
}

test_token_env_wins() {
  export CLAUDE_PLUGIN_OPTION_TOKEN=plugin-token FAKE_KEYCHAIN=kc-token
  hook 'done' "$(payload s1)"
  eq source "$(source_of 1)" "env"
}

test_token_plugin_before_keychain() {
  unset BUSYBAR_TOKEN
  export CLAUDE_PLUGIN_OPTION_TOKEN=plugin-token FAKE_KEYCHAIN=kc-token
  hook 'done' "$(payload s1)"
  eq source "$(source_of 1)" "plugin"
}

test_token_keychain_last() {
  unset BUSYBAR_TOKEN
  export FAKE_KEYCHAIN=kc-token
  hook 'done' "$(payload s1)"
  eq source "$(source_of 1)" "keychain"
}

test_no_token_does_nothing() {
  unset BUSYBAR_TOKEN
  hook 'done' "$(payload s1)"
  eq calls "$(ncalls)" "0"
  eq stdout "$OUT" ""
  eq status "$STATUS" "0"
}

test_test_command_draws_hello() {
  hook test
  eq title "$(q 1 '.elements[1].text')" "HELLO"
  eq timeout "$(q 1 '.elements[1].timeout')" "10"
  eq status "$STATUS" "0"
}

test_test_command_without_token_fails() {
  unset BUSYBAR_TOKEN
  hook test
  eq status "$STATUS" "1"
  eq calls "$(ncalls)" "0"
}

test_test_command_reports_failure() {
  export BUSYBAR_DRY_RUN="$WORK/missing/calls"
  hook test
  eq status "$STATUS" "1"
  eq stdout "$OUT" ""
}

# summary_of TOOL INPUT_JSON: record then approve in one session; prints "title|detail".
summary_of() {
  : > "$BUSYBAR_DRY_RUN"
  hook record "$(payload s1 "$1" "$2")"
  hook approve "$(payload s1)"
  q 1 '.elements[1].text + "|" + .elements[2].text'
}

test_summary_rules() {
  eq git "$(summary_of Bash '{"command":"git push origin main"}')" "AGENT  Bash?|git push"
  eq env-prefix "$(summary_of Bash '{"command":"FOO=1 BAR=2 npm test -- -v"}')" "AGENT  Bash?|npm test"
  eq chain "$(summary_of Bash '{"command":"cd /tmp && rm -rf build"}')" "AGENT  Bash?|cd"
  eq url-arg "$(summary_of Bash '{"command":"curl -s https://example.com/x?token=abc"}')" "AGENT  Bash?|curl"
  eq path "$(summary_of Bash '{"command":"/usr/local/bin/terraform apply -auto-approve"}')" "AGENT  Bash?|terraform apply"
  eq heredoc "$(summary_of Bash '{"command":"cat <<EOF > notes.txt\nsecret\nEOF"}')" "AGENT  Bash?|cat"
  eq codex-argv "$(summary_of Bash '{"command":["bash","-lc","git status --short"]}')" "AGENT  Bash?|git status"
  eq edit "$(summary_of Edit '{"file_path":"/home/user/my-project/src/main.go"}')" "AGENT  Edit?|main.go"
  eq notebook "$(summary_of NotebookEdit '{"notebook_path":"/home/user/n/a.ipynb"}')" "AGENT  Notebook?|a.ipynb"
  eq webfetch "$(summary_of WebFetch '{"url":"https://docs.example.com/a/b?q=1"}')" "AGENT  WebFetch?|docs.example.com"
  eq mcp "$(summary_of mcp__github__create_issue '{"title":"x"}')" "AGENT  MCP?|github create_issue"
  eq patch "$(summary_of apply_patch '{"command":"*** Begin Patch\n*** Update File: src/app.rs\n@@\n-a\n+b\n*** End Patch"}')" "AGENT  Patch?|app.rs"
  eq other "$(summary_of TodoWrite '{"todos":[]}')" "AGENT  TodoWrit?| "
  local long
  long=$(summary_of Edit '{"file_path":"/x/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.txt"}')
  eq cap "${#long}" "53"
}

test_approve_falls_back_to_payload_then_generic() {
  hook approve "$(payload s1 Bash '{"command":"make deploy"}')"
  eq payload-tool "$(q 1 '.elements[1].text + "|" + .elements[2].text')" "AGENT  Bash?|make deploy"
  hook approve '{"session_id":"s2"}'
  eq generic "$(q 3 '.elements[1].text + "|" + .elements[2].text')" "AGENT  APPROVE?| "
}

test_approve_plays_sound_and_takes_ownership() {
  hook approve "$(payload s1 Bash '{"command":"ls"}')"
  eq led "$(q 1 .led_notification_color)" "#FFB000FF"
  eq sound-route "$(route 2)" "POST audio/play"
  eq sound "$(q 2 .stock_path)" "shared/sounds/calendar_event_starts.snd"
  eq owner "$(cat "$XDG_STATE_HOME/busybar-hooks/owner")" "s1 approve"
}

test_sound_off() {
  export BUSYBAR_SOUND=off
  hook approve "$(payload s1 Bash '{"command":"ls"}')"
  eq calls "$(ncalls)" "1"
}

test_input_draws_amber_input_with_sound() {
  hook input "$(payload s1)"
  eq title "$(q 1 '.elements[1].text + "|" + .elements[2].text')" "AGENT  INPUT?|my-project"
  eq led "$(q 1 .led_notification_color)" "#FFB000FF"
  eq sound-route "$(route 2)" "POST audio/play"
  eq owner "$(cat "$XDG_STATE_HOME/busybar-hooks/owner")" "s1 input"
}

test_progress_draws_silently_with_counter_and_title() {
  OUT=$(printf '%s' '{}' | bash "$SCRIPT" progress "3/12" "compose skill dirs")
  STATUS=$?
  eq status "$STATUS" "0"
  eq stdout "$OUT" ""
  eq route "$(route 1)" "POST display/draw"
  eq counter "$(q 1 '.elements[1].text')" "3/12"
  eq title "$(q 1 '.elements[2].text')" "compose skill dirs"
  eq led "$(q 1 .led_notification_color)" "#4C9EFFFF"
  eq calls "$(ncalls)" "1"
}

test_progress_requires_counter() {
  OUT=$(printf '%s' '{}' | bash "$SCRIPT" progress 2>/dev/null)
  STATUS=$?
  eq status "$STATUS" "1"
  eq calls "$(ncalls)" "0"
}

test_agent_prefixes() {
  export BUSYBAR_AGENT=codex
  hook approve "$(payload s1 Bash '{"command":"ls"}')"
  eq env-prefix "$(q 1 '.elements[1].text')" "CODEX  Bash?"
  unset BUSYBAR_AGENT
  : > "$BUSYBAR_DRY_RUN"
  hook input "$(payload s1)" claude
  eq bare-prefix "$(q 1 '.elements[1].text')" "CLAUDE  INPUT?"
}

# A caption is not an agent name. `task-done deploy` used to resolve the agent as
# "deploy" and load icons/deploy.xpm2 from a word that was only ever a label.
test_agent_argument_only_on_approve_and_input() {
  mkdir -p "$WORK/icons"
  printf '%s\n' 'deploy-icon-marker' > "$WORK/icons/deploy.xpm2"
  export BUSYBAR_ICON_DIR="$WORK/icons"
  hook task-done "$(payload s1)" deploy
  eq icon-unchanged "$(q 1 '.elements[0].data' | head -c 6)" "! XPM2"
  eq detail "$(q 1 '.elements[2].text')" "deploy"
  unset BUSYBAR_ICON_DIR
  rm -f "$WORK/icons/deploy.xpm2"
}

# The scrolling line falls back to the session name, never to the raw session id.
test_blank_caption_falls_back_to_session_name() {
  export BUSYBAR_SESSION=named-session
  hook task-done "$(payload s1)" "   "
  eq task-done-detail "$(q 1 '.elements[2].text')" "named-session"
  : > "$BUSYBAR_DRY_RUN"
  hook progress "$(payload s1)" "2/5" "   "
  eq progress-detail "$(q 1 '.elements[2].text')" "named-session"
  unset BUSYBAR_SESSION
}

# `cancel` runs from PostToolUse after every tool call and shows no name, so it must not
# pay for one: an agtermctl that fails the test if called proves the path stays cold.
test_cancel_does_not_resolve_a_session_name() {
  export AGTERM_SESSION_ID=term-1
  cat > "$WORK/bin/agtermctl" <<'EOF'
#!/bin/sh
touch "$AGTERM_CALLED"
printf '%s\n' '{"result":{"tree":{"workspaces":[{"sessions":[{"id":"term-1","name":"term-session"}]}]}}}'
EOF
  chmod +x "$WORK/bin/agtermctl"
  export AGTERM_CALLED=$WORK/agtermctl-called
  rm -f "$AGTERM_CALLED"
  hook cancel "$(payload s1)"
  eq cold "$([ -e "$AGTERM_CALLED" ] && echo called || echo cold)" "cold"
  rm -f "$AGTERM_CALLED"
  hook input "$(payload s1)"
  eq warm "$([ -e "$AGTERM_CALLED" ] && echo called || echo cold)" "called"
  unset AGTERM_SESSION_ID AGTERM_CALLED
}

test_session_name_fallback_chain() {
  export BUSYBAR_SESSION=explicit-session
  hook input "$(payload s1)"
  eq override "$(q 1 '.elements[2].text')" "explicit-session"

  unset BUSYBAR_SESSION
  : > "$BUSYBAR_DRY_RUN"
  cat > "$WORK/bin/agtermctl" <<'EOF'
#!/bin/sh
printf '%s\n' '{"result":{"tree":{"workspaces":[{"sessions":[{"id":"term-1","name":"term-session"}]}]}}}'
EOF
  chmod +x "$WORK/bin/agtermctl"
  export AGTERM_SESSION_ID=term-1
  hook input "$(payload s1)"
  eq agterm "$(q 1 '.elements[2].text')" "term-session"

  rm -f "$WORK/bin/agtermctl"
  : > "$BUSYBAR_DRY_RUN"
  local saved_path=$PATH
  local no_agterm="$WORK/no-agterm-bin"
  mkdir -p "$no_agterm"
  for tool in bash jq dirname tr cat mkdir; do
    ln -s "$(command -v "$tool")" "$no_agterm/$tool"
  done
  ln -s "$WORK/bin/security" "$no_agterm/security"
  PATH=$no_agterm
  hook input "$(payload s1)"
  PATH=$saved_path
  eq agterm-absent-fallback "$(q 1 '.elements[2].text')" "my-project"
}

test_icon_selection_and_embedded_fallback() {
  local icons="$WORK/icons"
  mkdir -p "$icons"
  printf '%s\n' 'custom-codex-icon' > "$icons/codex.xpm2"
  export BUSYBAR_ICON_DIR="$icons" BUSYBAR_AGENT=codex
  hook progress '{}' '1/2' 'first step'
  eq custom-icon "$(q 1 '.elements[0].data')" "custom-codex-icon"
  rm -f "$BUSYBAR_DRY_RUN"
  : > "$BUSYBAR_DRY_RUN"
  rm -f "$icons/codex.xpm2"
  hook progress '{}' '2/2' 'second step'
  eq embedded-default "$(q 1 '.elements[0].data | startswith("! XPM2\n15 15 2 1")')" "true"
}

test_progress_and_task_done() {
  hook progress '{}' '3/12' 'compose skill dirs'
  eq progress-route "$(route 1)" "POST display/draw"
  eq progress-title "$(q 1 '.elements[1].text')" "3/12"
  eq progress-detail "$(q 1 '.elements[2].text')" "compose skill dirs"
  eq progress-color "$(q 1 '.led_notification_color')" "#4C9EFFFF"
  eq progress-silent "$(ncalls)" "1"

  hook task-done '{}' 'probe task'
  eq done-title "$(q 2 '.elements[1].text')" "DONE"
  eq done-detail "$(q 2 '.elements[2].text')" "probe task"
  eq done-color "$(q 2 '.led_notification_color')" "#3FB950FF"
  eq done-silent "$(ncalls)" "2"
}
test_record_is_local_only() {
  hook record "$(payload s1 Bash '{"command":"ls"}')"
  eq calls "$(ncalls)" "0"
  eq stdout "$OUT" ""
  eq pending "$(jq -r .detail "$XDG_STATE_HOME/busybar-hooks/s1.pending")" "ls"
}

test_session_id_cannot_escape_state_dir() {
  hook record '{"session_id":"../../escape","tool_name":"Bash","tool_input":{"command":"ls"}}'
  eq inside "$(ls -A "$XDG_STATE_HOME/busybar-hooks")" "....escape.pending"
  eq outside "$(cd "$WORK" && echo *)" "bin calls state"
}

test_cancel_clears_own_alert_only() {
  hook approve "$(payload s1 Bash '{"command":"ls"}')"
  hook cancel "$(payload s2)"
  eq other-session "$(ncalls)" "2"
  hook cancel "$(payload s1)"
  eq own-session "$(route 3)" "DELETE display/draw"
  eq body "$(q 3 .application_name)" "busybar-hooks"
  eq owner-gone "$(ls -A "$XDG_STATE_HOME/busybar-hooks")" ""
}

test_cancel_leaves_done_alone() {
  hook 'done' "$(payload s1)"
  hook cancel "$(payload s1)"
  eq calls "$(ncalls)" "1"
}

test_clear_only_by_owner() {
  hook 'done' "$(payload s1)"
  hook clear "$(payload s2)"
  eq other-session "$(ncalls)" "1"
  hook clear "$(payload s1)"
  eq own-session "$(route 2)" "DELETE display/draw"
}

test_latest_session_wins() {
  hook approve "$(payload s1 Bash '{"command":"ls"}')"
  hook 'done' "$(payload s2)"
  hook cancel "$(payload s1)"
  eq stale-cancel "$(ncalls)" "3"
  hook clear "$(payload s2)"
  eq owner-clear "$(route 4)" "DELETE display/draw"
}

test_cancel_and_clear_drop_pending() {
  hook record "$(payload s1 Bash '{"command":"ls"}')"
  hook cancel "$(payload s1)"
  eq after-cancel "$(ls -A "$XDG_STATE_HOME/busybar-hooks")" ""
  hook record "$(payload s1 Bash '{"command":"ls"}')"
  hook clear "$(payload s1)"
  eq after-clear "$(ls -A "$XDG_STATE_HOME/busybar-hooks")" ""
}

test_codex_wait_alerts_after_delay() {
  export BUSYBAR_CODEX_DELAY=1
  hook codex-wait "$(payload s1 Bash '{"command":["bash","-lc","git push"]}')"
  eq immediate "$(ncalls)" "0"
  eq stdout "$OUT" ""
  sleep 3
  eq delayed "$(q 1 '.elements[1].text + "|" + .elements[2].text')" "AGENT  Bash?|git push"
}

test_codex_wait_cancelled_before_delay() {
  export BUSYBAR_CODEX_DELAY=1
  hook codex-wait "$(payload s1 Bash '{"command":"git push"}')"
  hook cancel "$(payload s1)"
  sleep 3
  eq calls "$(ncalls)" "0"
}

test_codex_second_request_replaces_first() {
  export BUSYBAR_CODEX_DELAY=1
  hook codex-wait "$(payload s1 Bash '{"command":"git push"}')"
  hook codex-wait "$(payload s1 Bash '{"command":"npm publish"}')"
  sleep 3
  eq one-alert "$(grep -c 'display/draw' "$BUSYBAR_DRY_RUN")" "1"
  eq latest "$(q 1 '.elements[2].text')" "npm publish"
}

test_claude_hooks_use_known_commands() {
  local cmds
  cmds=$(jq -r '.. | .command? // empty' "$ROOT/plugins/busybar/hooks/hooks.json" \
    | sed -E 's/.*busybar\.sh" ([a-z-]+).*/\1/' | sort -u | tr '\n' ' ')
  eq commands "$cmds" "approve cancel clear done input record "
}

test_codex_hooks_use_known_commands() {
  local cmds
  cmds=$(jq -r '.hooks | .. | .command? // empty' "$ROOT/plugins/busybar/.codex-plugin/plugin.json" \
    | sed -E 's/.*busybar\.sh" ([a-z-]+).*/\1/' | sort -u | tr '\n' ' ')
  eq commands "$cmds" "cancel clear codex-wait done "
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  CURRENT=$t
  setup
  "$t"
  rm -rf "$WORK"
done
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
