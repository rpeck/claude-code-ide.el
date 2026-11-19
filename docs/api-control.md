# Control operations for coordinators

A coordinator is a program or an agent session that controls other instances.
This document describes the control operations of claude-code-ide.el, the prompt inbox, and the MCP coordinator tools.

- Code: `claude-code-ide-control.el`.
- Tests: `claude-code-ide-control-tests.el`.
- Instances, events, and states: [session-schema.md](session-schema.md).
- Providers: [providers.md](providers.md).

## Rules for all operations

- **Instance IDs only.** Each operation takes or returns instance IDs. It never takes a display name. Two instances can have the same display name.
- **Results, not errors.** An operation returns a plist. A failure is a result, not a signal:

  ```elisp
  (:status error :reason REASON :instance-id ID :message TEXT)
  ```

- **Unavailable operations.** An operation without a function returns `(:status unavailable :capability OPERATION)`. A provider operation that the provider does not have returns the same result.
- **Valid instance IDs.** An instance ID has 1 to 128 characters: letters, digits, `.`, `_`, and `-`. The first character is a letter or a digit. Other IDs never reach the file system.

## Operations

| Operation | Elisp function | Result |
|---|---|---|
| `list-instances` | `(claude-code-ide-control-list-instances &optional PROVIDER)` | `(:status ok :instances LIST)`. |
| `inspect-instance` | `(claude-code-ide-control-inspect-instance INSTANCE-ID)` | The details of one running instance. |
| `launch` | `(claude-code-ide-control-launch &key DIRECTORY PROVIDER NAME PROMPT ROLE EXTRA-FLAGS)` | `(:status ok :instance-id ID ...)`. |
| `resume` | `(claude-code-ide-control-resume INSTANCE-ID &key PROMPT DIRECTORY NATIVE-ID PROVIDER)` | The same as `launch`. |
| `submit-prompt` | `(claude-code-ide-control-submit INSTANCE-ID TEXT &key REQUEST-ID QUEUE)` | `(:destination :request-id :result :reason ...)`. |
| `stop` | `(claude-code-ide-control-stop INSTANCE-ID)` | `(:status ok :instance-id ID :result stopped)`. |
| `handover` | `(claude-code-ide-handover-session INSTANCE-ID TARGET-PROVIDER &key METHOD CONTEXT INTERRUPT FORCE REQUEST-ID)` | Defined by `claude-code-ide-handover.el`; see [handover.md](handover.md). It returns at once. |
| `track-review` | Phase 3 (`feat/review-tracking`) | Unavailable until that file defines it. |

`claude-code-ide-control-request-status (INSTANCE-ID REQUEST-ID)` gives the current result of a submitted prompt. REQUEST-ID is a string or a number, as for `submit-prompt`.

### list-instances

- The result lists the instances that run in this Emacs, oldest first.
- PROVIDER, a provider name such as `claude`, keeps only the instances of that provider.
- Each element is a plist with these keys:

| Key | Value |
|---|---|
| `:instance-id` | The instance ID. |
| `:provider` | The provider name. |
| `:native-id` | The native conversation ID, or `unknown`. |
| `:display-name` | The name that people see. |
| `:project-root`, `:worktree` | The directories of the instance, or `unknown`. |
| `:generation` | The launch generation. |
| `:model` | The model, or `unknown`. |
| `:role` | The role, or nil. |
| `:live` | Non-nil when the terminal runs. |
| `:state`, `:state-reason`, `:state-age`, `:state-guess` | The common state from `claude-code-ide-instance-state`. |
| `:queued` | The number of prompts that wait in the inbox. |

### inspect-instance

- The result has `:status ok` and the keys of `list-instances`.
- It also has `:buffer` (the buffer name), `:pid`, `:process-start-time`, `:capabilities` (the operations of the provider), and `:inbox`.
- `:inbox` lists the requests that wait in the inbox, without their text. Final requests are not in it.
- An instance that does not run gives the reason `not-running`.

### launch

- `:directory` is required. It must exist.
- `:provider` is a provider name. nil means `claude-code-ide-default-provider`.
- `:name` is the instance name, `:prompt` the first message, and `:role` the optional role.
- `:extra-flags` replaces `claude-code-ide-cli-extra-flags` for this start. The MCP tool does not have this argument.
- The operation makes the instance ID before the start, and the start uses it. So the result always names the instance that started.
- The result has `:instance-id`, `:provider`, `:generation`, `:display-name`, and `:native-id`.
- Error reasons: `no-directory`, `unknown-provider`, `start-failed` (with the message of the start).

### resume

- It starts a stopped instance again, with the same instance ID and the next launch generation.
- The session registry gives the directory, the provider, and the native ID. The registry is read only while `claude-code-ide-session-registry-mode` is on.
- Without a registry entry, the caller gives `:directory` and `:native-id`, and optionally `:provider`.
- `:prompt` is the first message after the resume.
- Error reasons: `invalid-instance-id`, `already-running`, `archived`, `unknown-instance`, `no-directory`, `unknown-provider`, `start-failed`.

### stop

- It calls the `stop` operation of the instance's provider.
- The prompts in the inbox of the instance stay there.
- Error reasons: `not-running`, `stop-failed`.
- The stop does not wait for the process tree. `feat/process-tree` owns that part.

## submit-prompt

```elisp
(claude-code-ide-control-submit INSTANCE-ID TEXT &key REQUEST-ID QUEUE)
```

- **REQUEST-ID** is a string or a number that the caller chooses. A number becomes its decimal text. nil makes a new UUID. The result gives it.
- **TEXT** goes out with LF line ends: each CR LF and each lone CR becomes LF before the send.
- **QUEUE** says what happens when the instance cannot take the text now:

| QUEUE | Effect |
|---|---|
| Key not given | The rules of each state (below). |
| `t` (or `always`) | Queue in every state that is not idle, also `failed` and stopped. |
| `nil` (or `never`) | Reject in every state that is not idle. |
| `auto` | The same as no key. |

### The result

| Key | Value |
|---|---|
| `:destination` | INSTANCE-ID. |
| `:request-id` | The request ID. |
| `:result` | `delivered`, `queued`, `unacknowledged`, or `rejected`. |
| `:reason` | A symbol that says why, or nil. |
| `:sent-at` | The time when the prompt went to the provider, or nil. |
| `:duplicate` | t when the request ID was known. Only then is the key present. |

- **`delivered`:** a `prompt-submit` event of the instance had the same text.
- **`queued`:** the prompt waits in the inbox. When `:sent-at` is set, the provider has it, and the acknowledgement has not come.
- **`unacknowledged`:** the provider got the prompt, but no acknowledgement came in time. This is final: the prompt is never sent again, and it no longer blocks the queue.
- **`rejected`:** the prompt does not go out. The inbox does not keep its text.
- `delivered`, `unacknowledged`, and `rejected` are final. `queued` is the only result that can change.

### Reasons

| Reason | Result | Meaning |
|---|---|---|
| `awaiting-acknowledgement` | queued | The provider has the prompt. No `prompt-submit` event with its text came yet. |
| `no-acknowledgement` | unacknowledged | The acknowledgement did not come within `claude-code-ide-control-ack-timeout`, or a later launch of the instance runs. The events of the launch that got the prompt are dropped, so it can never be acknowledged. |
| `working`, `waiting-for-user/approval`, `waiting-for-user/question`, `waiting-for-user/dialog`, `waiting-for-task/...`, `disconnected` | queued or rejected | The state of the instance. |
| `failed/quota-limit`, `failed/exit-code`, `failed/error` | rejected, or queued with QUEUE t | The instance failed. |
| `stopped` | rejected, or queued with QUEUE t | The instance does not run, and the session registry marks it closed or archived. |
| `earlier-prompts-pending` | queued or rejected | The instance is idle, but older prompts wait. They go first. |
| `send-failed` | queued | The provider did not send the prompt. It waits for the next try. |
| `no-submit` | rejected | The provider has no `submit-prompt`. Queued prompts of such an instance also become final with this reason. |
| `handed-over` | rejected, or queued | A handover moved the prompt to its target (`claude-code-ide-control-move-inbox`). The old record is `rejected` with this reason. The target has a `queued` copy with the same request ID and this reason. Follow the chain with `claude-code-ide-session-registry-chain-current`. |
| `unknown-instance` | rejected | Neither this Emacs nor the registry knows the ID. |
| `invalid-instance-id`, `empty-text` | rejected | The request is not valid. |

The results `unknown-instance`, `invalid-instance-id`, and `empty-text` make no inbox file.

### Rules for each state

The state comes from `claude-code-ide-instance-state`.

| State | Without QUEUE | QUEUE t | QUEUE nil |
|---|---|---|---|
| `idle` | Send at once. | Send at once. | Send at once. |
| `working` | Queue. Send after the next `turn-end`. | Queue. | Reject. |
| `waiting-for-user` (all reasons) | Queue. Never send into a dialog. | Queue. | Reject. |
| `waiting-for-task` | Queue. | Queue. | Reject. |
| `disconnected` | Queue until the instance runs again. | Queue. | Reject. |
| `failed` | Reject. | Queue. | Reject. |
| Stopped (registry: closed or archived) | Reject. | Queue. | Reject. |

- **Only `idle` sends.** Every other state queues, because a provider does not yet report each of its dialogs reliably (plan §10).
- **An instance that does not run** in this Emacs:
  - When the session registry marks it closed or archived, it is stopped.
  - When the registry marks it `failed`, it is `failed`, with the reason `exit-code` (the CLI exited with an error code) or `error`. The state plist has the failure text as `:detail`.
  - When the registry marks it `pending`, it is `working` with the reason `starting`.
  - When the registry has it open (as after a crash of Emacs), or this Emacs launched it before, it is `disconnected`.
  - Else it is unknown.
- **A guessed idle state** (`:guess t`) also sends. The inbox file records it in `sent_guess`.

### Duplicates

- A second request with a known request ID returns the result of the first request, with `:duplicate t`.
- It sends nothing, also when its text is different.
- The result is the current one: a queued request that is acknowledged later returns `delivered`.
- Final requests stay in the `done` folder for `claude-code-ide-control-done-days` (default 7). After that, the request ID is new again.

### Delivery

- **Order.** The prompts of one instance go out oldest first, one at a time.
- **One at a time.** A sent prompt blocks the next one until its acknowledgement comes, or until `claude-code-ide-control-ack-timeout` (default 60 seconds) ends. Then it becomes `unacknowledged`.
- **Earlier launches.** A sent prompt of an earlier launch generation becomes `unacknowledged` at once, because the events of that launch are dropped.
- **At most once.** The inbox marks a prompt as sent before it calls the provider. If Emacs stops during the call, the prompt is not sent again.
- **Triggers.** A delivery starts:
  - After each common event of an instance with queued prompts, for example `turn-end` or `session-start`. The delivery runs on a timer with no delay, after the status applied all events that came together.
  - Every `claude-code-ide-control-retry-interval` seconds (default 5), while a running instance has pending prompts. This finds an instance that became idle without an event. The timer stops when no running instance has a pending prompt.
- `claude-code-ide-control-deliver-pending (INSTANCE-ID)` sends the next prompt at once, when the instance can take it.

### Acknowledgement

- The inbox listens on `claude-code-ide-event-functions`.
- A `prompt-submit` event acknowledges the oldest sent prompt of the instance whose text has the same hash.
- The hash is SHA-256 of the text with LF line ends and without white space at the start and the end. `claude-code-ide-control-text-hash` computes it.
- The text comes from the `prompt` field of the event data. For Claude Code and Codex, `UserPromptSubmit` has this field.
- A `prompt-submit` event without prompt text gives one warning for each provider. Then the inbox cannot acknowledge the prompts of that provider.
- After the acknowledgement, the record moves to `done` without its text, and `claude-code-ide-control-delivered-functions` runs with INSTANCE-ID and REQUEST-ID.

## The inbox

- **Place.** `<report directory>/inbox/<instance-id>/`. The option `claude-code-ide-control-inbox-directory` changes the parent folder.
- **Privacy.** The folders have mode `0700`, and the files mode `0600`, because a prompt can hold private text.
- **Files.** One JSON file for each request. The file name is the first 32 hex digits of the SHA-256 of the request ID, plus `.json`. So any request ID is a safe file name.
- **Pending and final.** A pending request (`queued`) is a file in `<instance-id>/`. A final request moves at once to `<instance-id>/done/`. The move writes the final copy first and then deletes the pending file. A pending file whose final copy exists is a left-over of an interrupted move, and the next read deletes it.
- **Clean-up.** Each move deletes the files in `done/` that are older than `claude-code-ide-control-done-days`.
- **Atomic writes.** Each write goes to a temporary file in the same folder, which is then renamed over the file.
- **Index.** The pending records of each inbox folder are in memory. The first use of a folder reads its pending files. After that, events and submits read no files, and each write updates the index. A duplicate check of a final request reads one file in `done/`.
- **Reload.** Loading the package reads no inbox file. The index fills from disk at the first use of each instance, so the inbox survives a reload of the package and a restart of Emacs.
- **Old Emacs.** The files are read with the native JSON parser when Emacs has one, else with json.el.
- `claude-code-ide-control-inbox-directory-of (INSTANCE-ID)` returns the folder.
- `(claude-code-ide-control-move-inbox FROM TO)` moves the queued prompts of FROM to TO after a handover (plan §4.8). Each keeps its request ID; see the reason `handed-over`.

### The file

```json
{
  "version": 1,
  "request_id": "review-42",
  "instance_id": "5afe576e-88a4-4ecf-b317-1cd4b509ca6d",
  "seq": 3,
  "text_hash": "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
  "text": "Run the tests again.",
  "result": "queued",
  "reason": "awaiting-acknowledgement",
  "created_at": "2026-11-18T09:12:44Z",
  "updated_at": "2026-11-18T09:13:02Z",
  "sent_at": "2026-11-18T09:13:02Z",
  "sent_generation": 2,
  "sent_guess": false,
  "delivered_at": null,
  "requested_by": null
}
```

| Field | Value |
|---|---|
| `version` | 1. A file of another version is skipped. |
| `request_id` | The request ID. |
| `instance_id` | The destination. |
| `seq` | The order in the inbox. |
| `text_hash` | The hash of the acknowledgement. |
| `text` | The prompt while it waits, with LF line ends. null in a final record. |
| `result` | `queued`, `delivered`, `unacknowledged`, or `rejected`. |
| `reason` | The reason, or null. |
| `created_at`, `updated_at`, `sent_at`, `delivered_at` | ISO 8601 times in UTC, or null. |
| `sent_generation` | The launch generation that got the prompt. |
| `sent_guess` | true when the idle state at the send was a guess. |
| `requested_by` | The instance ID of the MCP request, from `claude-code-ide-mcp-request-instance-id`, or null. |


## MCP coordinator tools

Each operation is also an MCP tool with `:scope coordinator`. Only a request with the coordinator credential can run it (`feat/mcp-routing`).

| Tool | Arguments |
|---|---|
| `claude-code-ide-control-list-instances` | `provider` (optional) |
| `claude-code-ide-control-inspect-instance` | `instance_id` |
| `claude-code-ide-control-launch` | `directory`, `provider`, `name`, `prompt`, `role` (all but `directory` optional) |
| `claude-code-ide-control-resume` | `instance_id`, `prompt` (optional) |
| `claude-code-ide-control-submit-prompt` | `instance_id`, `text`, `request_id` (optional), `queue` (optional: `auto`, `always`, or `never`) |
| `claude-code-ide-control-request-status` | `instance_id`, `request_id` |
| `claude-code-ide-control-stop` | `instance_id` |

- **Results.** Each tool returns the result plist as a JSON object. Keys use `_`, for example `instance_id`. Symbols become strings.
- **Off without the scope check.** The tools go into `claude-code-ide-mcp-server-tools` only when the MCP server enforces the coordinator scope. The sign of that is the function `claude-code-ide-mcp-request-instance-id`. Without it, any instance could launch, prompt, and stop the others.
  - At load, the file adds the tools when the server enforces the scope and `claude-code-ide-control-enable-mcp-tools` is non-nil.
  - `M-x claude-code-ide-control-setup-mcp-tools` adds them later. Without the scope check, it signals a `user-error`. With a prefix argument (FORCE), it adds them anyway.
  - `claude-code-ide-control-remove-mcp-tools` removes them.
- **`:scope` in the spec.** `claude-code-ide-control--make-tool` passes `:scope coordinator` to `claude-code-ide-make-tool`. The current `claude-code-ide-make-tool` drops the key, so the file puts it on the tool spec in the tools list. It does that only when the key is missing. The workaround goes away after `feat/mcp-routing` is merged, because that branch makes `claude-code-ide-make-tool` keep `:scope`.

## Phase 3 operations

- `claude-code-ide-control-operations` is an alist of each operation and its function. `claude-code-ide-handover.el` fills `handover`, and the review file fills `track-review`.
- `(claude-code-ide-control-define-operation OPERATION FUNCTION)` gives an operation its function.
- `(claude-code-ide-control-call OPERATION &rest ARGS)` calls the operation, or returns the unavailable result.
- `(claude-code-ide-control-define-tool &rest SPEC)` adds a coordinator tool. SPEC has the arguments of `claude-code-ide-make-tool`. The tool gets `:scope coordinator`.
- A review result goes into the owner's inbox with `claude-code-ide-control-submit`, with the review ID as the request ID (plan §4.8). So the owner gets it one time, and only when it can take it.

## Options

| Option | Default | Meaning |
|---|---|---|
| `claude-code-ide-control-inbox-directory` | nil | The parent folder of the inboxes. nil means `inbox` in the report directory. |
| `claude-code-ide-control-ack-timeout` | 60 | Seconds that a sent prompt blocks the next one. |
| `claude-code-ide-control-retry-interval` | 5 | Seconds between two checks of the queued prompts. nil turns the check off. |
| `claude-code-ide-control-enable-mcp-tools` | t | Add the MCP coordinator tools at load, when the server enforces the scope. |
| `claude-code-ide-control-done-days` | 7 | Days that a final record stays in `done/`. |
