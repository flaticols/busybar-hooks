# busybar-hooks

Shows what your coding agent is doing on a [BUSY Bar](https://busy.app): a turn finished, it
needs your approval, or it asked you a question. Works with Claude Code and Codex, and as a
plain skill for any agent through [skills.sh](https://skills.sh).

| State | Bar shows | Sound |
|---|---|---|
| turn finished | green `DONE` and the project name | no |
| approval needed | amber `Bash?`, `Edit?`, … and the program or file name | yes |
| question asked | amber `INPUT?` and the project name | yes |

Only the program or file name is shown, never a full command line: the text travels through the
BUSY cloud and shows on a display other people can see.

## Install

**Claude Code**

```
/plugin marketplace add flaticols/busybar-hooks
/plugin install busybar@busybar-hooks
```

**Codex**

```sh
codex plugin marketplace add flaticols/busybar-hooks
codex plugin add busybar@busybar-hooks
```

Then open Codex, run `/hooks`, and trust the busybar hooks.

**Any agent (skills.sh)**

```sh
npx skills add flaticols/busybar-hooks
```

This installs the skill and script only. Ask your agent to use the `busybar` skill to wire the
hooks.

## Token

Create a BAR-scope API token in the BUSY app. The hooks look for it in this order:

1. `BUSYBAR_TOKEN` environment variable
2. the Claude plugin's `token` setting
3. the macOS Keychain, stored with `bash <path-to>/busybar.sh login`

Check the setup with `bash <path-to>/busybar.sh test`.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `BUSYBAR_PRIORITY` | `100` | draw priority; a BUSY session runs at 90, so the default shows over it |
| `BUSYBAR_TIMEOUT` | `600` | seconds a message stays up |
| `BUSYBAR_SOUND` | `calendar_event_starts` | stock sound name, or `off` |
| `BUSYBAR_CODEX_DELAY` | `10` | seconds before a Codex approval alert |

## How it behaves

- One message at a time. The latest session to report wins, and only that session can take its
  message down.
- Approval alerts clear once the approved tool runs; `DONE` clears when you send the next prompt.
- Claude Code alerts when a permission prompt has waited about 6 seconds, so prompts you answer
  right away stay quiet.
- Codex calls its hooks before its auto-reviewer decides, so the alert waits
  `BUSYBAR_CODEX_DELAY` seconds and fires only if the request is still pending. A slow review
  can still alert.
- A slow or offline bar never slows the agent: every hook exits 0 and network calls give up
  after 8 seconds.

Requirements: `bash`, `curl`, `jq`.

## Development

```sh
bash tests/run.sh                  # dry-run tests, no device needed
BUSYBAR_DRY_RUN=/dev/stdout bash plugins/busybar/skills/busybar/scripts/busybar.sh done <<< '{}'
```

## License

MIT
