# Instances, events, states, and the registry

This document describes the data that all providers share:

- The instance descriptor.
- The launch generation.
- The common event.
- The common states.
- The session registry file, version 2, and the migration of version 1.

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
4. The session registry sets `native-id` when it knows the CLI session id. That happens at the start, after a SessionStart report, and for an adopted session.
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

- `working/starting`: the CLI starts and has not yet reported that it is ready.
- `disconnected/untracked`: the process runs, but it has no status hooks (for example, it started before the status hooks existed).
- `disconnected/no-signal`: the process runs and has hooks, but no event came.
| `failed` | `quota-limit`, `exit-code`, `error` |

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
| `error` | FAILED | `failed` | `error` | no |
| `unobserved` | NO SIGNAL | `disconnected` | none | no |
| `tasks-quiet` | TASKS QUIET | `waiting-for-task` | `subagent` | no |
| `tasks` | WAITS ON TASKS | `waiting-for-task` | `subagent` | no |
| `idle` | WAITS FOR YOU | `idle` | none | yes after the interrupt check |
| `starting` | STARTING | `working` | none | no |
| `working` | WORKING | `working` | none | no |
| `untracked` | UNTRACKED | `disconnected` | none | no |

Notes on the mapping:

- **`starting` has no common state.** It maps to `working`, because the CLI does not take a prompt yet.
- **`tasks-quiet`** loses its urgency in the common state. Only the status buffer shows it.
- **`failed/quota-limit`** is not set yet. The fields of a Claude Code rate-limit `StopFailure` are not verified (test S6).
- **Without the session registry**, Claude Code instances have no status hooks. Their state is `disconnected`.

## The registry file

The session registry has two files:

| File | Name (default) | Use |
|---|---|---|
| Version 2 | `claude-code-ide-state-file` with `-v2` before the extension: `~/.emacs-claude-code-ide-state-v2.json` | Emacs reads and writes it. Its backup is `<v2 file>.bak` and its lock is `<v2 file>.lock`. |
| Version 1 | `claude-code-ide-state-file`: `~/.emacs-claude-code-ide-state.json` | Emacs reads it only while the version 2 file does not exist. Emacs never writes or moves it. |

The report directory stays `<version 1 name without extension>-reports`, so both versions of the package use the same reports.

### Version 2

```json
{
  "version": 2,
  "sessions": [
    {
      "instance_id": "5afe576e-88a4-4ecf-b317-1cd4b509ca6d",
      "provider": "claude",
      "native_id": "5afe576e-88a4-4ecf-b317-1cd4b509ca6d",
      "generation": 1,
      "role": null,
      "transcript_path": "/home/me/.claude/projects/-home-me-src-app/5afe576e-88a4-4ecf-b317-1cd4b509ca6d.jsonl",
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
      "host": "laptop"
    }
  ]
}
```

These fields are new or have a new name in version 2:

| Field | Struct slot | Value |
|---|---|---|
| `instance_id` | `key` | The instance ID. It was `key` in version 1. |
| `provider` | `provider` | The provider name, a string. |
| `native_id` | `session-id` | The native conversation ID. It was `session_id` in version 1. |
| `generation` | `generation` | The launch generation of the last launch. |
| `role` | `role` | The optional role, or null. |

The other fields keep their version 1 meaning:

- **`model`** is the `--model` of the start flags. null means that the model is not known. The file does not use the string `"unknown"`, because a restore passes the value to `--model`.
- **`state`** is `open`, `closed`, or `archived`.
- **`closed_by`** is `exited`, `killed`, or `emacs-exit`.

The struct slots `key` and `session-id` keep their names, so the code that uses them does not change. The accessors are `claude-code-ide-session-registry-entry-<slot>`.

### Migration of version 1

A version 1 file holds only Claude Code records. When Emacs reads it, it migrates each record in memory:

1. `key` becomes `instance_id`.
2. `session_id` becomes `native_id`.
3. `provider` becomes `"claude"`.
4. `generation` becomes 0.
5. `role` stays null.

The next write makes the version 2 file. The version 1 file stays as it is. From then on, Emacs reads only the version 2 file.

When the version 1 file is unreadable, Emacs reads its `.bak` file. It does not move the unreadable version 1 file.

A version 2 file of another version is unreadable. Then the registry uses the version 2 backup, and moves the unreadable version 2 file aside on the next write.

**Older packages.** An older package reads and writes only the version 1 file. It never sees the version 2 file, so it cannot overwrite version 2 records.

The cost of two files:

- After the first version 2 write, a session that an older package starts goes only to the version 1 file. A restore in the new package does not see it.
- A session of the new package goes only to the version 2 file. A restore in an older package does not see it.
- To start again from the version 1 file, delete the version 2 file. The next read migrates the version 1 file again.

### Records and descriptors

- The entry key is the instance ID.
- A new Claude Code conversation gets a new UUID as its `--session-id`. The record stores it as `native_id`. It is never the instance ID, so a new conversation of an existing instance never reuses a native ID.
- A start records the provider, the generation, and the role of the descriptor.
- A restore starts each record with a start spec that has its `instance_id`, its `provider`, its `generation` as `last-generation`, and its `role`. So the restored instance keeps its instance ID and gets the next generation.
- A record of a provider that is not registered fails to restore with a `user-error`. The other records restore normally.
