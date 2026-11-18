# The status snapshot

Each Emacs process writes the status of its instances to one JSON file, for coordinators and other programs outside Emacs. This document describes the file, the schema `claude-code-ide-status/v1`, and the rules for freshness.

Code: `claude-code-ide-session-status.el`, section "Status snapshot". The common states are in [session-schema.md](session-schema.md).

## The file

- **Path:** `<report directory>/status/<emacs pid>.json`.
  - The report directory is `claude-code-ide-session-registry-report-directory`. Its default is the version 1 state file name without its extension, plus `-reports`, for example `~/.emacs-claude-code-ide-state-reports/`.
  - The `status` folder has mode `0700` when Emacs creates it.
- **Producer:** only the Emacs process with that process ID writes the file.
- **Atomic write:** Emacs writes the content to a temporary file in the same folder (a name that starts with `.`), and renames it to the final name. A reader sees the old file or the new file, never a part of a file.
- **When:**
  - At each change of a status, if the content without the ages changed.
  - At least every `claude-code-ide-session-status-snapshot-interval` seconds (default 10), also without a change.
  - The writes happen while an instance runs, a launch is tracked, or `claude-code-ide-session-status-mode` or `claude-code-ide-session-registry-mode` is on.
- **Removal:** Emacs deletes the file when it has nothing more to report, and when Emacs exits normally. After a crash, the file stays, and goes stale.
- **Off:** set `claude-code-ide-session-status-snapshot` to nil. Emacs then writes no file.

## Schema `claude-code-ide-status/v1`

```json
{
  "schema": "claude-code-ide-status/v1",
  "generated_at": "2026-11-18T21:30:05.123Z",
  "producer_pid": 41022,
  "host": "laptop",
  "interval_seconds": 10,
  "stale_after_seconds": 30,
  "instances": [
    {
      "instance_id": "5afe576e-88a4-4ecf-b317-1cd4b509ca6d",
      "provider": "codex",
      "native_id": "01a1eb92-1fa5-77e0-9973-c5abf025eb49",
      "display_name": "app:refactor",
      "project_root": "/home/me/src/app/",
      "worktree": "/home/me/src/app/",
      "model": "gpt-5.6-terra",
      "role": null,
      "generation": 2,
      "pid": 51230,
      "buffer": "*codex[app:refactor]*",
      "state": "waiting-for-user",
      "reason": "approval",
      "guess": false,
      "since": "2026-11-18T21:29:51.004Z",
      "age_seconds": 14,
      "detail": "Bash: make test"
    }
  ]
}
```

### Top-level fields

| Field | Type | Value |
|---|---|---|
| `schema` | string | Always `"claude-code-ide-status/v1"`. A reader refuses another value. |
| `generated_at` | string | The time of the write, ISO 8601 in UTC, with milliseconds. |
| `producer_pid` | integer | The process ID of the Emacs that wrote the file. It is the same as the number in the file name. |
| `host` | string | The host name of that Emacs. |
| `interval_seconds` | number | The longest time between two writes. |
| `stale_after_seconds` | integer | The age after which a reader treats the file as stale: 30. |
| `instances` | array | One record for each instance that runs in that Emacs, oldest first. It is `[]` when none runs. |

### Instance fields

| Field | Type | Value |
|---|---|---|
| `instance_id` | string | The instance ID. It does not change. Use it for control operations. |
| `provider` | string | `"claude"`, `"codex"`, or `"unknown"`. |
| `native_id` | string | The native conversation ID, or `"unknown"`. A new Codex session has `"unknown"` until its first prompt. |
| `display_name` | string | The name for people, or `"unknown"`. Two instances can have the same name. |
| `project_root` | string | The folder that the instance runs in, or `"unknown"`. |
| `worktree` | string | The top folder of the Git working tree, or `"unknown"`. |
| `model` | string | The model, or `"unknown"`. Codex reports the model in each hook event. For Claude Code, it is the `--model` of the start flags. |
| `role` | string or null | The optional role. null means no role. |
| `generation` | integer | The launch generation of the current launch. |
| `pid` | integer or string | The process ID of the terminal process, or `"unknown"`. |
| `buffer` | string | The name of the terminal buffer, or `"unknown"`. |
| `state` | string | A common state: `working`, `idle`, `waiting-for-user`, `waiting-for-task`, `disconnected`, or `failed`. |
| `reason` | string or null | The reason of the state, or null. See the table below. |
| `guess` | boolean | true when Emacs infers the state and no event reports it. |
| `since` | string or null | The time when the state started, ISO 8601 in UTC, or null when it is not known. |
| `age_seconds` | integer or null | The seconds from `since` to `generated_at`, or null. |
| `detail` | string | One line for people, for example the command that waits for an approval. Do not parse it. |

`"unknown"` means that Emacs does not know the value. null means that the field has no value, for example a state without a reason.

### States and reasons

| State | Reasons | Meaning |
|---|---|---|
| `working` | none | The agent works, or starts. |
| `idle` | none | The turn ended. The agent waits for the next prompt. |
| `waiting-for-user` | `approval`, `question`, `dialog` | The agent waits for an answer. Do not type into the terminal. |
| `waiting-for-task` | `subagent`, `background-task`, `other-instance` | The agent waits for its own background work. |
| `disconnected` | none | The process is gone, the session ended, or no event comes (no status hooks, or Codex hooks that are not trusted). |
| `failed` | `quota-limit`, `exit-code`, `error` | The last turn failed. `quota-limit`: the account reached its usage limit. |

- Claude Code: `StopFailure` with `error: "rate_limit"` gives `failed/quota-limit`. Another `StopFailure` gives `failed/error`.
- Codex: a failed `PostModelRequest` gives `failed/error`, or `failed/quota-limit` when the error text matches the usage-limit pattern. See [status-events.md](status-events.md).
- A guess is not an event. Examples: a reply that ends with a question (`waiting-for-user/question`, guess), and a Codex approval after 10 seconds without a screen check.

## Freshness rules for readers

A reader must check each file before it uses the data:

1. Parse the JSON. A file that does not parse is unusable. (This cannot happen during a write, because the write is atomic.)
2. `schema` must be `"claude-code-ide-status/v1"`.
3. The file is **stale** when one of these is true:
   - `generated_at` is older than `stale_after_seconds` (30) seconds.
   - No process with the ID `producer_pid` runs on `host`.
4. Treat the instances of a stale file as unknown. Do not treat them as idle or stopped.
5. A missing file means that the Emacs process reports no instances.

Several Emacs processes can write their own files in the same folder. Read each `*.json` file in the folder. Ignore files whose name starts with `.`; they are temporary.

## Version rules

- A new field can come in v1. A reader ignores the fields that it does not know.
- A change of the meaning or the type of a field, or a removed field, gives a new schema name, for example `claude-code-ide-status/v2`.
