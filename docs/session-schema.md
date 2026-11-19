# Instances, events, states, and the registry

This document describes the data that all providers share:

- The instance descriptor.
- The launch generation.
- The common event.
- The common states.
- The session registry file, version 4, and the migration of versions 3, 2 and 1.
- The states of a record, provisional records, Codex records, and the restore of both providers.

Code: `claude-code-ide-instance.el` and `claude-code-ide-session-registry.el`.
The provider interface is in [providers.md](providers.md).

## Terms

- **Instance:** one terminal session that Emacs runs.
- **Instance ID:** an ID that Emacs gives an instance. It does not change, also after a resume or a restore. It is a random UUID.
- **Native conversation ID:** the ID that the provider gives the conversation. For Claude Code, it is the CLI session id.
- **Display name:** the name that people see. Two instances can have the same display name.
- **Launch generation:** a number that increases at each launch, resume, and restore of an instance.

The instance ID, the native ID, and the display name are three separate values. Control operations find an instance by its instance ID only.

## Unknown values

A value that Emacs does not know is the symbol `unknown`. It is never a guess.

| Function | Arguments | Result |
|---|---|---|
| `claude-code-ide-unknown-p` | `(VALUE)` | Non-nil when VALUE is `unknown`. |
| `claude-code-ide-or-unknown` | `(VALUE)` | VALUE, or `unknown` when VALUE is nil. |
| `claude-code-ide-known-or-nil` | `(VALUE)` | VALUE, or nil when VALUE is `unknown`. |
| `claude-code-ide-format-value` | `(VALUE)` | Text for people. `unknown` gives `"unknown"`. nil gives `""`. |

## The instance descriptor

`claude-code-ide-instance` is a `cl-defstruct`.
Make one with `claude-code-ide-instance-create` and keyword arguments.
The accessors are `claude-code-ide-instance-<slot>`, and `setf` works on them.

| Slot | Default | Value |
|---|---|---|
| `id` | nil | The instance ID, a string. |
| `provider` | nil | The provider name, for example `claude`. |
| `native-id` | `unknown` | The native conversation ID. |
| `display-name` | `unknown` | The name that people see, for example `"app:refactor"`. |
| `project-root` | `unknown` | The directory that the instance runs in. |
| `worktree` | `unknown` | The top directory of the Git working tree of the project root. |
| `buffer` | nil | The terminal buffer. |
| `pid` | `unknown` | The process ID of the terminal process. |
| `process-start-time` | `unknown` | The start time of that process, as a float time. |
| `generation` | 0 | The launch generation of the current launch. |
| `model` | `unknown` | The model of the conversation. |
| `role` | nil | An optional role string. nil means that the instance has no role. |
| `session` | nil | The `claude-code-ide-mcp-session` of the instance. |
| `properties` | nil | A plist for the values of other files. |

### Why a separate struct

The descriptor is a separate struct. It is not a set of new slots in `claude-code-ide-mcp-session`, for these reasons:

- `claude-code-ide-mcp.el` belongs to another branch (`mcp-routing`). Phase 1 does not edit it.
- The descriptor must not depend on the MCP transport. A provider can have another transport.
- The descriptor points to its MCP session in the slot `session`. `claude-code-ide-instance-of-session` finds the descriptor of a session.

### Properties

A later branch can need a value that the frozen descriptor does not have, for example the MCP secret of a launch. It keeps the value in the properties, with a key that starts with its own name:

- `claude-code-ide-instance-property (INSTANCE KEY)` returns the value.
- `claude-code-ide-instance-set-property (INSTANCE KEY VALUE)` sets the value and returns it.

### Functions

| Function | Arguments | Result |
|---|---|---|
| `claude-code-ide-instance-new-id` | `()` | A new instance ID. |
| `claude-code-ide-instance-register` | `(INSTANCE)` | INSTANCE. It becomes a running instance. A live instance with the same ID signals an error. |
| `claude-code-ide-instance-unregister` | `(INSTANCE-ID)` | It removes the instance. Its last generation stays known. |
| `claude-code-ide-instance-by-id` | `(INSTANCE-ID)` | The descriptor of the running instance, or nil. |
| `claude-code-ide-instance-of-session` | `(SESSION)` | The descriptor of an MCP session, or nil. |
| `claude-code-ide-instances` | `(&optional PROVIDER)` | The running descriptors, oldest first. PROVIDER keeps only the instances of that provider. |
| `claude-code-ide-instance-live-p` | `(INSTANCE)` | Non-nil when the terminal buffer is live and its process is live or not yet known. |

### Life of a descriptor

1. `claude-code-ide--start-session` makes the descriptor after it makes the MCP session, and before the provider builds the command. So `claude-code-ide-cli-args-functions` can find the instance. A second start of an instance ID that runs fails at the registration, and leaves the running instance and its generation as they are.
2. After the terminal starts, the start sets `buffer`, `pid`, and `process-start-time`.
3. A rename updates `display-name`.
4. The native ID is set when it is known. For Claude Code, the session registry sets it at the start, after a SessionStart report, and for an adopted session. For Codex, the provider sets it from the first `session-start` event of each conversation (`claude-code-ide-codex--note-session-start`).
5. `claude-code-ide--cleanup-session` removes the descriptor at the end, after the end functions ran.

The start spec (`claude-code-ide-start-spec`) has four new slots:

| Slot | Value |
|---|---|
| `provider` | The provider name. nil means `claude-code-ide-default-provider`. |
| `instance-id` | The instance ID to start again. nil makes a new instance ID. |
| `last-generation` | The generation that a saved record holds, or nil. |
| `role` | The optional role. |

For Claude Code, the model comes from `--model` in the start flags. Without `--model`, the model is `unknown`.

## Launch generations

| Function | Arguments | Result |
|---|---|---|
| `claude-code-ide-instance-candidate-generation` | `(INSTANCE-ID &optional LAST)` | The generation of a new launch: one more than the highest of LAST and the last generation in this Emacs. It is not recorded. |
| `claude-code-ide-instance-next-generation` | `(INSTANCE-ID &optional LAST)` | The same value, and it is recorded at once. |
| `claude-code-ide-instance-current-generation` | `(INSTANCE-ID)` | The last generation of INSTANCE-ID, or nil when this Emacs never launched it. |

- A new instance gets generation 1.
- A start uses the candidate. `claude-code-ide-instance-register` records it only when the registration succeeds.
- A restore passes the generation of the registry record as LAST. So the count continues after an Emacs restart.

## The common event

A common event is a plist:

```elisp
(:instance-id STRING
 :generation INTEGER
 :time FLOAT
 :event SYMBOL
 :provider-event STRING
 :data ALIST)
```

| Key | Value |
|---|---|
| `:instance-id` | The instance ID of the launch that sent the event. |
| `:generation` | The launch generation of that launch. |
| `:time` | The float time when Emacs read the event. |
| `:event` | The common event, a symbol of `claude-code-ide-event-names`. |
| `:provider-event` | The name of the event in the provider, for example `"PermissionRequest"`. |
| `:data` | The input of the event, as the provider gave it. |

The common events are `session-start`, `session-end`, `prompt-submit`, `tool-start`, `tool-end`, `approval-request`, `dialog-open`, `dialog-close`, `notification`, `turn-end`, `turn-failed`, `interrupt`, `subagent-start`, `subagent-end`, and `other`. The `map-event` operation of a provider maps its events to them.

| Function | Arguments | Result |
|---|---|---|
| `claude-code-ide-make-event` | `(INSTANCE-ID GENERATION EVENT PROVIDER-EVENT DATA &optional TIME)` | The plist. An unknown EVENT signals an error. |
| `claude-code-ide-event-current-p` | `(EVENT)` | Non-nil when the generation of EVENT is not lower than the current generation of its instance. An instance that this Emacs never launched gives nil. |
| `claude-code-ide-dispatch-event` | `(EVENT)` | When EVENT is current, it calls `claude-code-ide-event-functions` with EVENT and returns t. Otherwise it returns nil. |

The status drain builds one common event for each event file. The `map-event` operation of the instance's provider gives `:event`. The drain applies the event to the status, and then passes it to `claude-code-ide-dispatch-event`. An event of an older generation is neither applied nor dispatched. An error in an event function gives a message and does not stop the drain.

### The Claude Code launch nonce

- Each Claude Code launch with status hooks has a nonce. The hook command contains the nonce, and each event file name starts with it.
- The status record of the nonce holds the instance ID and the generation of that launch.
- The drain makes a common event of each file and checks `claude-code-ide-event-current-p`. It deletes the file of an older launch without applying or dispatching it.
- The hook command does not contain the generation. So the command, and the CLI behavior, do not change.

## The common states

`claude-code-ide-instance-states` lists the states and their reasons:

| State | Reasons |
|---|---|
| `working` | `starting` |
| `idle` | none |
| `waiting-for-user` | `approval`, `question`, `dialog` |
| `waiting-for-task` | `subagent`, `background-task`, `other-instance` |
| `disconnected` | `untracked`, `no-signal` |
| `failed` | `quota-limit`, `exit-code`, `error` |

- `working/starting`: the CLI starts and has not yet reported that it is ready.
- `disconnected/untracked`: the process runs, but it has no status hooks (for example, it started before the status hooks existed).
- `disconnected/no-signal`: the process runs and has hooks, but no event came.

### The state accessor

`claude-code-ide-instance-state (INSTANCE &optional NOW)` returns a plist:

```elisp
(:state SYMBOL :reason SYMBOL-OR-NIL :since FLOAT-OR-NIL :guess BOOL :age SECONDS-OR-NIL)
```

- INSTANCE is a descriptor or an instance ID. NOW is a float time. The default is now.
- `:since` is the time when the state started. `:age` is the number of seconds from `:since` to NOW.
- `:guess` is non-nil when Emacs infers the state and no event reports it.
- The result is nil for an ID that this Emacs never launched.

The accessor decides the state in this order:

1. The instance is not running, or its process is gone: `disconnected`.
2. The first function of `claude-code-ide-instance-state-functions` that returns a state: that state. Each function gets INSTANCE and NOW, and returns a plist from `claude-code-ide-instance-make-state`, or nil.
3. No function knows the instance: `disconnected`, because no event comes.

`claude-code-ide-instance-make-state (STATE &optional REASON SINCE GUESS)` makes the plist. It signals an error for a state or a reason that is not in the lists.

### The Claude Code states

`claude-code-ide-session-status.el` adds a state function for the `claude` provider. It maps the states of the status buffer as follows:

| Status buffer state | Label | Common state | Reason | Guess |
|---|---|---|---|---|
| `waiting`, a permission dialog | NEEDS ANSWER | `waiting-for-user` | `approval` | no |
| `waiting`, a notification `permission_prompt` or `worker_permission_prompt` | NEEDS ANSWER | `waiting-for-user` | `approval` | no |
| `waiting`, a dialog of AskUserQuestion (tool name from the PermissionRequest, else from the tool in flight) | NEEDS ANSWER | `waiting-for-user` | `question` | no |
| `waiting`, an elicitation or another waiting notification | NEEDS ANSWER | `waiting-for-user` | `dialog` | no |
| `asks` | ASKS YOU | `waiting-for-user` | `question` | yes |
| `error`, a `StopFailure` of another error, or `rate_limit` without a usage-limit text | FAILED | `failed` | `error` | no |
| `error`, a `StopFailure` with `billing_error` | QUOTA LIMIT | `failed` | `quota-limit` | no |
| `error`, a `StopFailure` with `rate_limit` whose `error_details` or `last_assistant_message` matches `claude-code-ide-session-status-quota-regexp` | QUOTA LIMIT | `failed` | `quota-limit` | no |
| `unobserved` | NO SIGNAL | `disconnected` | `no-signal` | no |
| `tasks-quiet` | TASKS QUIET | `waiting-for-task` | `subagent` | no |
| `tasks` | WAITS ON TASKS | `waiting-for-task` | `subagent` | no |
| `idle` | WAITS FOR YOU | `idle` | none | yes after the interrupt check |
| `starting` | STARTING | `working` | `starting` | no |
| `working` | WORKING | `working` | none | no |
| `untracked` | UNTRACKED | `disconnected` | `untracked` | no |

Notes on the mapping:

- **`starting`** maps to `working/starting`, because the CLI does not take a prompt yet.
- **`tasks-quiet`** loses its urgency in the common state. Only the status buffer shows it.
- **A short rate limit** ("Rate limit reached ... try again in 1.2s") stays `failed/error`, with the detail "Error: rate limit". Only a usage limit or a plan limit is `failed/quota-limit`. The regexp is one option for both providers; `docs/status-events.md` describes it.
- **Without the session registry**, Claude Code instances have no status hooks. Their state is `disconnected/untracked`.
- **Codex** has its own state function and event mapping. `docs/status-events.md` describes them.

## The registry file

The session registry has four files, one for each version:

| File | Name (default) | Use |
|---|---|---|
| Version 4 | `claude-code-ide-state-file` with `-v4` before the extension: `~/.emacs-claude-code-ide-state-v4.json` | Emacs reads and writes it. Its backup is `<v4 file>.bak` and its lock is `<v4 file>.lock`. |
| Version 3 | `claude-code-ide-state-file` with `-v3` before the extension: `~/.emacs-claude-code-ide-state-v3.json` | Emacs reads it only while the version 4 file does not exist. Emacs never writes or moves it. |
| Version 2 | `claude-code-ide-state-file` with `-v2` before the extension: `~/.emacs-claude-code-ide-state-v2.json` | Emacs reads it only while neither the version 4 nor the version 3 file exists. Emacs never writes or moves it. |
| Version 1 | `claude-code-ide-state-file`: `~/.emacs-claude-code-ide-state.json` | Emacs reads it only while no newer file exists. Emacs never writes or moves it. |

**Why version 4 (decision D3 of the orchestrator).** Version 4 adds the handover fields `chain` and `handover` of each record ([handover.md](handover.md), "The registry"). A package that knows only version 3 would drop them when it writes. So version 4 has its own file. A version 3 record reads as a version 4 record without these fields. The rest of this document describes the fields of version 3, which version 4 keeps.

The report directory stays `<version 1 name without extension>-reports`, so all versions of the package use the same reports.

**Why version 3 (decision D1 of the orchestrator).** Version 3 adds the states `pending` and `failed` and the fields from `worktree` on. A package that knows only version 2 would read `pending` and `failed` as `closed`, and would drop the new fields when it writes. So version 3 has its own file, as version 2 did. A package of version 2 keeps working with the version 2 file.

### Version 3

```json
{
  "version": 3,
  "sessions": [
    {
      "instance_id": "5afe576e-88a4-4ecf-b317-1cd4b509ca6d",
      "provider": "claude",
      "native_id": "0c9d2f61-3a3e-4b8e-9f7e-2b1d6f0e4a11",
      "generation": 1,
      "role": null,
      "transcript_path": "/home/me/.claude/projects/-home-me-src-app/0c9d2f61-3a3e-4b8e-9f7e-2b1d6f0e4a11.jsonl",
      "project_dir": "/home/me/src/app/",
      "buffer_name": "*claude-code[app:refactor]*",
      "instance_name": "refactor",
      "model": "opus",
      "extra_flags": "--permission-mode plan",
      "permission_mode": "plan",
      "state": "open",
      "started_at": "2026-11-03T09:12:44Z",
      "last_seen_at": "2026-11-03T09:12:44Z",
      "closed_at": null,
      "closed_by": null,
      "emacs_pid": 41022,
      "host": "laptop",
      "worktree": "/home/me/src/app/",
      "pid": 41388,
      "process_start_time": 1794201164.0,
      "emacs_start_time": 1794190002.0,
      "failure": null,
      "failure_count": 0,
      "failed_at": null,
      "native_id_generation": null
    }
  ]
}
```

These fields are new or have a new name since version 1 (the first five came with version 2, the others with version 3):

| Field | Struct slot | Value |
|---|---|---|
| `instance_id` | `key` | The instance ID. It was `key` in version 1. |
| `provider` | `provider` | The provider name, a string: `"claude"` or `"codex"`. |
| `native_id` | `session-id` | The native conversation ID. It was `session_id` in version 1. null means that the ID is not known yet. |
| `generation` | `generation` | The launch generation of the last launch. |
| `role` | `role` | The optional role, or null. |
| `worktree` | `worktree` | The top directory of the Git working tree of the project, from the descriptor, or null. |
| `pid` | `pid` | The process ID of the terminal process of the last launch, or null. |
| `process_start_time` | `process-start-time` | The start time of that process, as seconds since the epoch (a float), or null. |
| `emacs_start_time` | `emacs-start-time` | The start time of the Emacs process `emacs_pid`, or null. |
| `failure` | `failure` | Why the last restore or reopen failed, or null. |
| `failure_count` | `failure-count` | The restores or reopens that failed in a row since the last start that was confirmed good. |
| `failed_at` | `failed-at` | When it failed, or null. |
| `native_id_generation` | `native-id-generation` | The launch generation whose SessionStart report set `native_id`, or null. |

A version 2 record reads as a version 3 record whose new fields are null (and `failure_count` 0). A value of a wrong type also reads as null.

The other fields keep their version 1 meaning:

- **`model`** is the `--model` of the Claude Code start flags. For Codex, it is the model that the SessionStart report gives. null means that the model is not known. The file does not use the string `"unknown"`, because a Claude Code restore passes the value to `--model`.
- **`extra_flags`** holds the Claude Code start flags without the model and the session flags. A Codex record stores `""`: the Codex flags come from `claude-code-ide-codex-extra-flags` at each launch.
- **`closed_by`** is `exited`, `killed`, or `emacs-exit`.

### States of a record

| State | Meaning | Restore |
|---|---|---|
| `pending` | Emacs starts the instance, or the instance runs and its native ID is not known yet. | Yes, when the Emacs that owns it ended. Without a native ID, the restore starts nothing and shows it as unknown. |
| `open` | The instance runs, or it ran when its Emacs crashed. | Yes, when the Emacs that owns it ended. |
| `closed` | The instance ended, or Emacs exited normally. | Only the records that the last Emacs closed at its exit (`closed_by` = `emacs-exit`). |
| `failed` | The last restore or reopen failed. `failure` says why. | Yes, until it failed `claude-code-ide-session-registry-restore-attempts` (3) times in a row. Then only a reopen by hand starts it. |
| `archived` | The instance is done. | Never. |

The transitions:

1. **Before the spawn**, a start saves the provisional record with the state `pending`. A crash during the start therefore leaves a record.
2. **After the spawn**, the record becomes `open` when the native ID is known. A Codex record of a new conversation stays `pending` (see below).
3. **The SessionStart report** gives the native ID. A `pending` record becomes `open`. This holds for the Codex event and for the Claude Code report file (a start with `-c` or the picker `-r`).
4. **The end** of the CLI makes the record `closed`, also a `pending` one. A normal exit of Emacs closes the records of its running instances with `emacs-exit`. So a session that ended never comes back at a restore. A `pending` record without a native ID that the last Emacs closed at its exit shows as unknown at the next restore, and stays until you archive or forget it.
5. **A failed start** removes the provisional record of a new instance. A restore or a reopen that fails makes its record `failed`, with the reason.

### Provisional records

- The record holds the descriptor: the instance ID, the provider, the generation, the role, the project directory, the worktree, the instance name, the Emacs process ID, and the Emacs start time.
- A Claude Code start saves it in `claude-code-ide-session-registry--cli-args`, which runs before the CLI starts. The record has the native ID that Emacs chooses (`--session-id`), or the ID that the start resumes.
- Every provider: `claude-code-ide--start-session` runs `claude-code-ide-session-prepare-functions` before the spawn, and `claude-code-ide-session-registry--on-prepare` saves the record there. A start that does not run the hook saves the record at the session start, after the spawn.
- **Flags and model come later.** The provisional record sees only the flags of the start spec (none for a start without a spec) and no model. The Claude Code launch writes the flags that it uses (`claude-code-ide-cli-extra-flags`) back into the launch spec. The start record then takes those flags, their model, and their permission mode. A Codex record takes the model of the descriptor, which the Codex launch sets from `claude-code-ide-codex-extra-flags`.
- A start saves the record one time. A second call does nothing.
- **The key** is the instance ID of the start spec, else the instance ID of the descriptor. Nothing else gives it, so a start inside another start (for example, from a hook of a restore) never takes the other start's key.
- **A failed start** resolves its record through the hook `claude-code-ide-session-start-failed-functions` (SESSION LAUNCH ERR). `claude-code-ide--start-session` runs it in its error handler, for every start whose prepare hook ran, also when no terminal buffer exists, and before its cleanup. The registry adds `claude-code-ide-session-registry--on-start-failed` to it. No timer polls the records.
  - **A new instance** loses its record.
  - **A known record** (a restore or a reopen) becomes `failed` with the error. Its native ID and names stay.
  - **One failed start counts one time.** The end functions of a start that failed change nothing. When `claude-code-ide-session-registry--start-entry` runs the start, it records only a failure that came before the provisional record (for example, a missing CLI or folder).
  - **A reload** turns the mode off and on. The provisional records stay in memory, and the hook still resolves them.
- **The kind of the record** (`new` or `reopen`) comes from the start, not from the file: a start of a saved record passes its generation as `last-generation`, and an instance that ran before in this Emacs has a launch generation above 1. A start that names an existing instance ID must pass `last-generation`; else a failed start of it removes the record.
- **The tables** of started and pending sessions hold their sessions strongly. The start, the end, or the start-failed hook removes them.

### Codex records

- **The native ID comes late.** Codex sends `SessionStart` only at the first prompt, also for `codex resume`. So a new Codex conversation has no native ID at the start, and its record stays `pending`.
- **The report.** The registry adds `claude-code-ide-session-registry--on-event` to `claude-code-ide-event-functions`. For a `session-start` event of an instance of another provider than `claude`, it sets:
  - `native_id` from `session_id`.
  - `transcript_path` from `transcript_path`. A new native ID without a transcript path clears the old one.
  - `model` from `model`, when the event has one.
  - The state `open`, when the record was `pending`.
- **The report is idempotent.** It sets no time stamp, so the same report twice gives the same record and the same file.
- **Reports that change nothing:** a `SessionStart` of a subagent (with `agent_id`), a report of an older launch generation than the record's, and every other event.
- **A new conversation in the same terminal** (`/new`) gives a new `session_id`. The record follows it.
- **No prompt, no conversation.** A Codex record that never got a prompt has no native ID. A restore starts nothing for it, and the restore message and the list show it as `unknown`. The record does not change. Archive or forget it by hand.
- **Claude Code** gets its native ID from its own report file (written by the registry's SessionStart hook), not from the event.

### Restore

`claude-code-ide-restore-sessions` starts the restorable records again. A record is restorable when all of these are true:

- It is `open`, `pending`, or `failed`, on this host, of an Emacs that no longer runs. Or the last Emacs closed it at its exit.
- It does not run in this Emacs.
- Its owner process does not run: no process has the ID `pid` and the start time `process_start_time`.
- No running Claude Code CLI has its native ID (the files in `~/.claude/sessions`).

Each record restores alone:

- **The provider of the record**, never the default provider and never the menu toggle, starts it. A record of a provider that is not loaded fails with a reason.
- **The native ID of the record** is resumed:
  - Claude Code: `claude --resume ID`, with the stored flags, the model of the transcript (else `model`) as `--model`, and the title of the transcript as `--name`.
  - Codex: `codex resume … -- ID PROMPT`. It gets no `--model` and no `--name`. The Codex options give the Codex flags and the model.
- **The flags of each provider** come from `claude-code-ide-session-registry-restore-flags-functions`, an alist of a provider name and a function of the record. A provider without an entry gets no flags. The provider struct has no slot for restore flags, so the registry keeps this table.
- **The start spec** has the record's `instance_id`, `provider`, `generation` as `last-generation`, `role`, `project_dir`, and `instance_name`. So the instance keeps its instance ID, its name, its buffer name, and its worktree, and gets the next generation.
- **Each start runs from its own timer.** An error or a quit in one start does not stop the others.
- **Each timer reads its record again.** A record that changed since the plan (its state, its close, its Emacs, its generation, or its native ID; for example, you closed or archived it), or that runs now, is skipped. An instance whose ID runs already in this Emacs is skipped too. A skip is not a failure, and the record does not change. The check uses a context of that record alone; it does not rebuild the context of all records.
- **A failure marks only its own record `failed`**, with the reason:
  - The provider CLI is missing (for example "Codex CLI not available").
  - The directory is missing.
  - The start signals an error.
  - The CLI exits with an error within `claude-code-ide-session-registry-restore-grace` seconds (default 60) of its start, for example for a conversation ID that the CLI does not know. The reason gives the exit code.
- **The exit code** comes from one helper for all terminal backends: the exit status of the process for vterm and eat, and the `ghostel--exit-status` property of the event pipe for ghostel.
- **A failed record restores again** at the next restore, up to `claude-code-ide-session-registry-restore-attempts` (default 3) failures in a row. Then it stays `failed` and a restore no longer tries it. `claude-code-ide-reopen-session` still starts it by hand. The Emacs that marks a record owns it, so another running Emacs leaves it alone.
- **The failures stay across a restart** of the same record. A start does not clear `failure` and `failure_count`. Only a start that is confirmed good clears them:
  - the CLI still runs after the grace time (`claude-code-ide-session-registry-restore-grace`), or
  - a SessionStart report of the current launch generation arrives.
  So a CLI that exits with an error after each start reaches the limit.
- **Only some records become `failed`:** a record that is `open`, `pending`, or `failed`, or that the last Emacs closed at its exit, and whose launch generation is the generation of the start that failed. An archived record, and a record that you closed, never become `failed`.
- **Refusals are not failures.** A record without a native ID, or whose owner process still runs, is refused and does not change.
- **The message** names the number of started sessions, each failure with its reason, each skipped record, and each unknown record.
- **The restore context** reads the live sessions of this Emacs, the running Claude Code CLIs, and each process ID one time for all records.

`claude-code-ide-reopen-session` starts one record in the same way, with the same failure handling.

### Migration of versions 1 and 2

A version 1 file holds only Claude Code records. When Emacs reads it, it migrates each record in memory:

1. `key` becomes `instance_id`.
2. `session_id` becomes `native_id`.
3. `provider` becomes `"claude"`.
4. `generation` becomes 0.
5. `role` stays null.

A version 1 record goes through version 2 to version 3. The next write makes the version 3 file. The version 1 and version 2 files stay as they are. From then on, Emacs reads only the version 3 file.

When the version 1 file is unreadable, Emacs reads its `.bak` file. It does not move the unreadable version 1 file.

When the version 2 file is unreadable (and no version 3 file exists), Emacs reads its `.bak` file. It does not move the unreadable version 2 file.

A version 3 file with an unknown version is unreadable. Then the registry uses the version 3 backup. On the next write, it copies the unreadable version 3 file aside (`.corrupt-<time>`) and then renames the new file over it.

**Older packages.** A package of version 1 reads and writes only the version 1 file, and a package of version 2 only the version 2 file. Neither sees the version 3 file, so neither can overwrite version 3 records.

The cost of two files:

- After the first version 3 write, a session that an older package starts goes only to its own file. A restore in the new package does not see it.
- A session of the new package goes only to the version 3 file. A restore in an older package does not see it.
- To start again from the version 2 file, delete the version 3 file. Without both, the next read migrates the version 1 file again.

### Records and descriptors

- The entry key is the instance ID.
- A new Claude Code conversation gets a new UUID as its `--session-id`. The record stores it as `native_id`. It is never the instance ID, so a new conversation of an existing instance never reuses a native ID.
- A fork gets no `--session-id`, and its record has no native ID until the report. The record never takes the native ID of the parent conversation, also when it had that ID before. A native ID that a report of the fork's own launch generation set before the start was recorded stays (`native_id_generation`). The start spec's `fork` slot tells a fork; the CLI flag (`--fork-session`) is in the launch arguments, not in the stored flags.
- A start records the provider, the generation, the role, the worktree, and the process of the descriptor.
- The list buffer (`M-x claude-code-ide-list-session-registry`) shows the provider of each record. The state is `live` for a record that runs in this Emacs, and `unknown` for a record without a native ID. For a `failed` record, the Title column shows the reason.
