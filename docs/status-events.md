# Status events of Codex instances

This document describes how Emacs gets the status of a Codex instance:

- The hook script.
- The hook arguments and the environment of a launch.
- The hook trust: the check at each launch and the trust command.
- The event files.
- The mapping of each Codex event to the common events and the common states.
- The startup dialogs.

Code: `claude-code-ide-codex-events.el`. The common events and states are in [session-schema.md](session-schema.md). The status snapshot is in [status-schema.md](status-schema.md).

Facts from tests T1 and T2 on Codex 0.164.0.

## Overview

1. The Codex launch adds the hook arguments of `claude-code-ide-codex-status-hook-args` to the command, and the environment of `claude-code-ide-codex-status-hook-env` to the terminal. It calls them only when they are bound, so the launch also works without this file.
2. Codex runs the hook script at each hook event. The script writes one event file.
3. Emacs reads the event files in order, checks the launch identity, and changes the status of the instance.
4. Emacs passes each current event to `claude-code-ide-dispatch-event`.
5. The status buffer and the status snapshot show the common state.

## The hook script

- **File:** `<report directory>/codex-hooks/claude-code-ide-codex-status-hook.sh`.
- **Folder:** private, mode `0700`. Emacs sets the mode again when it differs. Emacs refuses a folder that is a symbolic link.
- **Install:** Emacs writes the script to a temporary file in the same folder, sets mode `0700`, and renames it. So Codex never runs a part of the script.
- **Check:** at each launch, Emacs compares the content with the script in the package. A different content, or a mode that lets others write, makes Emacs write the script again.
- **Why:** Codex trusts the hook command, not the script. A person who can write the script can run code in each tracked session.

The script does these steps:

1. It sends its output to `/dev/null`, and it always exits with 0. So it never changes what Codex does.
2. It exits at once when `CODEX_THREAD_ID` is set, or when `CCI_INSTANCE_ID` is not set. It reads its input first, so that Codex can write it.
   - A nested Codex session (started by the agent) has `CODEX_THREAD_ID`. A top-level session does not.
3. It exits when a value does not fit a file name:
   - `CCI_INSTANCE_ID` must have only letters, digits, and `-`.
   - `CCI_GENERATION` must have only digits.
   - The event name must have only letters.
   - `CCI_EVENTS_DIR` must be a folder.
4. It writes the record to a temporary file: `{"event": EVENT, "instance_id": ID, "generation": "N", "input": STDIN}`.
5. It takes a lock for the launch, increments the counter of the launch, and renames the file to its final name.

## Hook arguments and environment

`(claude-code-ide-codex-status-hook-args INSTANCE)` returns the list `("-c" "hooks.SessionStart=[...]" "-c" "hooks.SessionEnd=[...]" ...)`.

- The events, in this order: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `Interrupt`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PostModelRequest`, `SubagentStart`, `SubagentStop`.
- Each value is `hooks.<Event>=[{hooks=[{type="command",command="sh <script> <Event>",timeout=5}]}]`.
- The command is a TOML basic string.
- The list is the same for each instance and each launch. One trust covers all launches.
- **Never change a definition or its position.** Codex keeps the trust under the key `<source>:<event>:<group>:<handler>`. A changed definition gets a new hash, and the user must trust it again.
- The script path is part of the command. A new report directory therefore needs a new trust.

`(claude-code-ide-codex-status-hook-env INSTANCE)` returns:

```
("CCI_INSTANCE_ID=<instance id>" "CCI_GENERATION=<generation>" "CCI_EVENTS_DIR=<events folder>")
```

- The events folder is `<report directory>/events-<emacs pid>/codex`, mode `0700`.
- Both functions start to track the current launch of INSTANCE. A second call for the same launch does nothing more.
- Both functions return nil when `claude-code-ide-session-status-tracking` is nil, or when the script cannot be installed. The launch then adds nothing, and the instance has no status events.

## Hook trust

Codex runs a hook only after the user trusts it. `codex exec` and the terminal UI skip an untrusted hook without a message.

### The check at each launch

- The tracking of a launch starts `codex app-server` with the hook arguments, over stdio, in the background. The launch does not wait.
- Emacs sends `initialize`, then `initialized`, then `hooks/list` with the project folder in `cwds`.
- The status hooks of the package are the hooks with `source` `sessionFlags` whose command runs the script.
- A hook counts as trusted when `trustStatus` is `trusted` or `managed`, and `enabled` is not false.
- The time limit is `claude-code-ide-codex-events-trust-timeout` (10 seconds).
- Emacs keeps the last result. The next launch uses it without a process, while the hook arguments and the time of `config.toml` are the same, and the result was `trusted`.

| Result | Status of an instance without events |
|---|---|
| All hooks trusted | Normal (see below). |
| Some hooks not trusted or disabled | `disconnected/untracked`, detail "N of 11 Codex status hooks not trusted: M-x claude-code-ide-codex-trust-hooks". |
| No answer, or no Codex program | Normal, and the detail adds "Hook trust unknown: ...". |

When events come, a trust problem is added to the detail only.

A trust does not change a launch that started while its hooks were not trusted. That launch stays `disconnected/untracked`, with the detail "Hooks were not trusted at the launch: restart to get status". A launch that waited for the running check gets its result. A later launch uses the trusted result.

### The trust command

`M-x claude-code-ide-codex-trust-hooks`:

1. It starts the app-server with the hook arguments and calls `hooks/list`.
2. It shows the hooks that Codex does not run yet, with their event, command, trust status, and key, in the buffer `*Codex status hooks*`.
3. It asks with `yes-or-no-p`.
4. It calls `config/batchWrite`. Each edit has `keyPath` `hooks.state`, `mergeStrategy` `upsert`, and the value `{KEY: {trusted_hash: CURRENT-HASH}}`, with the hash that `hooks/list` gave.
5. It calls `hooks/list` again and reports the result.

- The app-server has no method only for hook trust. `config/batchWrite` is the method that the terminal UI uses. It writes the same records as `/hooks`:
  ```toml
  [hooks.state."/<session-flags>/config.toml:stop:0:0"]
  trusted_hash = "sha256:..."
  ```
- The upsert merges the keys. Other keys in `hooks.state` stay, for example `enabled = false`.
- A hook that `/hooks` disabled stays disabled. The command says so.
- If `config/batchWrite` fails, the command tells the user to run `/hooks` in a Codex terminal.

## Event files

- **Folder:** `CCI_EVENTS_DIR`.
- **Name:** `<instance id>.<generation>.<sequence>.<Event>.json`. The sequence has 8 digits and counts the events of one launch.
- **Content:** `{"event": "Stop", "instance_id": "...", "generation": "3", "input": {...}}`. `input` is the stdin JSON of the hook.

Emacs reads the files at a file notification, and every 2 seconds. For each file:

1. The instance ID must have a launch record, and the generation must be the generation of that record. The record exists only for the current launch of a running instance.
2. The content must name the same event, instance ID, and generation as the file name.
3. The common event must be current (`claude-code-ide-event-current-p`).
4. The `session_id` of the input must be the conversation of the launch. The first `session_id` that comes sets it.
   - A `SessionStart` of the main agent with another `session_id` moves the launch to that conversation. This happens after `/new`, or after a switch to another thread in the terminal. The descriptor gets the new native ID.
   - Another event with an unknown `session_id` is dropped. A nested session has its own `session_id`; its `SessionStart` never comes, because the script drops it (`CODEX_THREAD_ID`).
5. Emacs applies the event, notes the `model` and the native ID in the descriptor, and dispatches the common event.

Emacs deletes each file, also a file that it does not apply. Locks older than 3 seconds are deleted.

So an event of an earlier launch (for example before a resume) changes nothing, and nothing is dispatched for it.

## Event mapping

| Codex event | Common event | Change of the status |
|---|---|---|
| `SessionStart` | `session-start` | `idle` "Ready". Clears tools, blockers, subagents, and a failure. |
| `UserPromptSubmit` | `prompt-submit` | `working`. Clears the blockers of the main agent and a failure. |
| `PreToolUse` | `tool-start` | Records the tool. Main agent: `working`. `request_user_input`: `waiting-for-user/question`, not a guess. |
| `PermissionRequest` | `approval-request` | `waiting-for-user/approval` for its tool (see "Matching an approval to its tool"). |
| `PostToolUse` | `tool-end` | Ends the tool and its blockers. Main agent: `working`. |
| `Interrupt` | `interrupt` | `idle` "Interrupted". Ends the tools and blockers of the main agent. |
| `Stop` | `turn-end` | `idle`, with the first line of `last_assistant_message`. A line that matches `claude-code-ide-session-status-ask-regexps` gives `waiting-for-user/question` as a guess. |
| `PostModelRequest`, `status: "failed"` | `turn-failed` | `failed/error`, or `failed/quota-limit` when the error is a usage limit (see "Quota limits"). No `Stop` follows. |
| `PostModelRequest`, other | `other` | Main agent after a failure or at the start: `working`. Codex retries a failed request, so a later answer ends the failure. |
| `SubagentStart` | `subagent-start` | `waiting-for-task/subagent` while the agent runs. |
| `SubagentStop` | `subagent-end` | Ends the agent, its tools, and its blockers. |
| `SessionEnd` | `session-end` | `disconnected` "Session ended". |

Rules:

- **Subagents.** An event with `agent_id` belongs to a subagent. It never changes the turn of the main agent. A subagent's approval or question waits for the user too.
- **Deny and Esc.** Both give only `Interrupt`. Emacs cannot tell them apart.
- **Allow.** No event shows it. The approval stays until the `PostToolUse` of the tool. Without a screen read, the approval is a guess after `claude-code-ide-codex-events-approval-guess-time` (10 seconds). The result of a screen read belongs to each approval of the main agent, so the end of a subagent does not change it.
- **Automatic review.** It gives the same events as a user dialog.
- **Background terminals** give no events. So Codex never shows `waiting-for-task/background-task`.
- **A killed terminal buffer** gives no `SessionEnd`. The process check of `claude-code-ide-instance-state` gives `disconnected`.
### Matching an approval to its tool

- A `PermissionRequest` with a `tool_use_id` of a tool in flight belongs to that tool.
- Codex 0.164.0 sends no `tool_use_id`. Then the request belongs to the newest tool in flight with the same agent and the same tool name, whose `tool_input` fields all have the same values in the request, and that has no approval yet.
- The request input has fields that the tool input lacks, for example `description`. They do not count.
- So with parallel tools, the `PostToolUse` of one tool does not end the approval of another tool.

### Quota limits

`claude-code-ide-session-status-quota-regexp` decides whether an error text reports the usage limit of the account. It is matched without case. It matches texts such as "usage limit", "plan limit", "quota", "credits depleted", "out of credits", "hit your limit", and "5-hour limit" or "weekly limit". It does not match a short rate limit such as "Rate limit reached ... tokens per min ... try again in 1.2s".

| Provider | Event | State | Detail |
|---|---|---|---|
| Claude Code | `StopFailure`, `error: "billing_error"` | `failed/quota-limit` | "Quota limit: <text>" |
| Claude Code | `StopFailure`, `error: "rate_limit"`, and `error_details` or `last_assistant_message` matches the regexp | `failed/quota-limit` | "Quota limit: <text>" |
| Claude Code | `StopFailure`, `error: "rate_limit"`, other | `failed/error` | "Error: rate limit", plus `error_details` when it has text |
| Claude Code | `StopFailure`, other | `failed/error` | "Error: <error>" |
| Codex | `PostModelRequest`, `status: "failed"`, and `error` matches the regexp | `failed/quota-limit` | "Quota limit: <error>" |
| Codex | `PostModelRequest`, `status: "failed"`, other | `failed/error` | "Error: <error>" |

The real Codex usage-limit text is not yet known (T1). `<text>` is `error_details`, else `last_assistant_message`, else `error`.

### The order of the states

`claude-code-ide-codex-events--state` takes the first rule that applies:

1. `SessionEnd` came: `disconnected`.
2. A failed model request: `failed/error` or `failed/quota-limit`.
3. An open question: `waiting-for-user/question`.
4. An open approval:
   - The screen shows the approval dialog: `waiting-for-user/approval`, not a guess.
   - The screen shows no dialog: `working`, a guess ("Approved, runs?").
   - No screen read: `waiting-for-user/approval`, a guess after 10 seconds.
5. A startup dialog on the screen: `waiting-for-user/dialog`.
6. A subagent runs: `waiting-for-task/subagent`.
7. No event yet. Codex sends `SessionStart` only with the first prompt:
   - The hooks were not trusted at the launch: `disconnected/untracked`.
   - In the first `claude-code-ide-codex-events-startup-grace` seconds (3): `working/starting` "Starting", a guess.
   - The screen read found no dialog: `idle`, a guess. The composer waits for the first prompt.
   - No screen read: `working/starting` "Starting: no event yet", a guess.
8. The turn ended: `idle`, or `waiting-for-user/question` as a guess.
9. Else `working`.

## Startup dialogs

The Codex launch defines `(claude-code-ide-codex-screen-dialog BUFFER)`. It returns nil, or `folder-trust`, `update`, `hooks-review`, `approval`, or `other`. It reads only the visible text of the terminal BUFFER, and it never sends keys.

- Emacs calls it through `fboundp`, every 2 seconds, in two cases:
  - No event came yet, after the startup grace time.
  - An approval of the main agent is open, 1.5 seconds after its `PermissionRequest`. Codex draws the dialog after the event.
- The result stays until the next event of the main agent.
- Without the function, no screen is read.

## Tracking

- A launch record exists for the current launch of each tracked Codex instance.
- A new launch of the same instance ID replaces the record and deletes the files of the old launch.
- Every 2 seconds, Emacs deletes the records whose instance does not run that launch any more, and their files.
- The timers stop when no record is left.
- `claude-code-ide-codex-events--instance-state` is a function of `claude-code-ide-instance-state-functions` for the provider `codex`. An instance without a record has the state `disconnected/untracked`, detail "No status hooks".
- `claude-code-ide-codex-events-map-event` maps the events. The Codex provider can use it as its `map-event` operation.

## Options

| Option | Default | Use |
|---|---|---|
| `claude-code-ide-session-status-tracking` | t | Off: no hooks for new launches (both providers). |
| `claude-code-ide-codex-events-program` | `"codex"` | The program for the app-server. |
| `claude-code-ide-codex-events-trust-timeout` | 10 | Seconds that a trust check waits. |
| `claude-code-ide-codex-events-startup-grace` | 3 | Seconds before the first screen read of a launch. |
| `claude-code-ide-codex-events-approval-guess-time` | 10 | Seconds after which an unconfirmed approval is a guess. |
| `claude-code-ide-session-status-quota-regexp` | see above | The usage-limit pattern of both providers. |
