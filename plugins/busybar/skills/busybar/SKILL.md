---
name: busybar
description: Set up and test BUSY Bar status hooks for coding agents, or wire them into an agent by hand. Use when the user mentions their BUSY Bar, wants agent status or approval alerts on it, needs to store the BUSY Bar API token, or installed this skill through skills.sh and wants the hooks working.
---

# BUSY Bar status hooks

`scripts/busybar.sh` in this skill's directory shows agent status on a BUSY Bar:

| State | Bar shows | Sound |
|---|---|---|
| turn finished | green `DONE` and the project name | no |
| approval needed | amber `Bash?`, `Edit?`, … and the program or file name | yes |
| question asked | amber `INPUT?` and the project name | yes |
| task progress | white `N/M` and the task title | no |
| task finished | green `DONE` and the supplied task name | no |

## Custom icons

The script looks for `${BUSYBAR_ICON_DIR:-<skill-dir>/icons}/<agent>.xpm2` and uses the
embedded Claude spark when the file is absent. An icon is a 15x15 XPM2 bitmap with two
colour definitions and one character per pixel:

```text
! XPM2
15 15 2 1
. c none
# c #2F80ED
...............
```

Use 15 pixel rows after the colour definitions. `.` is transparent and `#` is the
coloured pixel; adding `<agent>.xpm2` makes the icon available without changing the
script.

`task-done <text>` draws a silent green completion message, and `progress <N/M> <text>`
draws a silent white progress message. The existing `done` command remains unchanged.

## Token

The script reads the token from, in order: `BUSYBAR_TOKEN`, the Claude plugin's `token` setting,
the macOS Keychain entry `busybar-hooks`. To create the Keychain entry, ask the user to run this
in their terminal (it prompts for the token, so it cannot run inside an agent tool call):

```sh
bash <skill-dir>/scripts/busybar.sh login
```

On other systems, set `BUSYBAR_TOKEN` in the environment the agent starts from.

## Test

```sh
bash <skill-dir>/scripts/busybar.sh test
```

Prints the HTTP status and shows `HELLO` on the bar for 10 seconds.

## Wiring hooks by hand

Installed as a Claude Code or Codex plugin, the hooks are already registered. After a skills.sh
install they are not; add them to the agent's hook settings with the absolute path of
`scripts/busybar.sh`. Each hook runs `bash <path> <command>` with the hook JSON on stdin.

| Claude Code event | Matcher | Command | async |
|---|---|---|---|
| `Stop` | | `done` | yes |
| `PermissionRequest` | | `record` | no |
| `Notification` | `permission_prompt` | `approve` | yes |
| `Notification` | `elicitation_dialog` | `input` | yes |
| `PreToolUse` | `AskUserQuestion` | `input` | yes |
| `PostToolUse` | | `cancel` | yes |
| `UserPromptSubmit` | | `clear` | yes |

| Codex event | Command |
|---|---|
| `Stop` | `done` |
| `PermissionRequest` | `codex-wait` |
| `PostToolUse` | `cancel` |
| `Interrupt` | `cancel` |
| `UserPromptSubmit` | `clear` |

Codex runs a new hook only after the user trusts it in `/hooks`.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `BUSYBAR_PRIORITY` | `100` | draw priority; a BUSY session runs at 90 |
| `BUSYBAR_TIMEOUT` | `600` | seconds a message stays up |
| `BUSYBAR_SOUND` | `calendar_event_starts` | stock sound name, or `off` |
| `BUSYBAR_CODEX_DELAY` | `10` | seconds before a Codex approval alert |
