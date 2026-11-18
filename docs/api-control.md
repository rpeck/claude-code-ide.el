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
| `handover` | Phase 3 (`feat/handover`) | Unavailable until that file defines it. |
| `track-review` | Phase 3 (`feat/review-tracking`) | Unavailable until that file defines it. |

`claude-code-ide-control-request-status (INSTANCE-ID REQUEST-ID)` gives the current result of a submitted prompt.

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
- `:inbox` lists the requests of the inbox, without their text.
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

- **REQUEST-ID** is a string that the caller chooses. nil makes a new UUID. The result gives it.
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
| `:result` | `delivered`, `queued`, or `rejected`. |
| `:reason` | A symbol that says why, or nil. |
| `:sent-at` | The time when the prompt went to the provider, or nil. |
| `:duplicate` | t when the request ID was known. Only then is the key present. |

- **`delivered`:** a `prompt-submit` event of the instance had the same text.
- **`queued`:** the prompt waits in the inbox. When `:sent-at` is set, the provider has it, and the acknowledgement has not come.
- **`rejected`:** the prompt does not go out. The inbox does not keep its text.

### Reasons

| Reason | Result | Meaning |
|---|---|---|
| `awaiting-acknowledgement` | queued | The provider has the prompt. No `prompt-submit` event with its text came yet. |
| `unacknowledged` | queued | The acknowledgement did not come within `claude-code-ide-control-ack-timeout`. The prompt is never sent again. A late acknowledgement still makes it `delivered`. |
| `working`, `waiting-for-user/approval`, `waiting-for-user/question`, `waiting-for-user/dialog`, `waiting-for-task/...`, `disconnected` | queued or rejected | The state of the instance. |
| `failed/quota-limit`, `failed/exit-code`, `failed/error` | rejected, or queued with QUEUE t | The instance failed. |
| `stopped` | rejected, or queued with QUEUE t | The instance does not run, and the session registry marks it closed or archived. |
| `earlier-prompts-pending` | queued or rejected | The instance is idle, but older prompts wait. They go first. |
| `send-failed` | queued | The provider did not send the prompt. It waits for the next try. |
| `submit-prompt-unavailable` | rejected | The provider has no `submit-prompt`. |
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
  - When the registry has it open (as after a crash of Emacs), or this Emacs launched it before, it is `disconnected`.
  - Else it is unknown.
- **A guessed idle state** (`:guess t`) also sends.

### Duplicates

- A second request with a known request ID returns the result of the first request, with `:duplicate t`.
- It sends nothing, also when its text is different.
- The result is the current one: a queued request that is acknowledged later returns `delivered`.

### Delivery

- **Order.** The prompts of one instance go out oldest first, one at a time.
- **One at a time.** A sent prompt blocks the next one until its acknowledgement comes, or until `claude-code-ide-control-ack-timeout` (default 60 seconds) ends.
- **At most once.** The inbox marks a prompt as sent before it calls the provider. If Emacs stops during the call, the prompt is not sent again.
- **Triggers.** A delivery starts:
  - After each common event of an instance with queued prompts, for example `turn-end` or `session-start`. The delivery runs on a timer with no delay, after the status applied all events that came together.
  - Every `claude-code-ide-control-retry-interval` seconds (default 5), while a running instance has queued prompts. This finds an instance that became idle without an event.
- `claude-code-ide-control-deliver-pending (INSTANCE-ID)` sends the next prompt at once, when the instance can take it.

### Acknowledgement

- The inbox listens on `claude-code-ide-event-functions`.
- A `prompt-submit` event acknowledges the oldest sent prompt of the instance whose text has the same hash.
- The hash is SHA-256 of the text with LF line ends and without white space at the start and the end. `claude-code-ide-control-text-hash` computes it.
- The text comes from the `prompt` field of the event data. For Claude Code and Codex, `UserPromptSubmit` has this field.
- A `prompt-submit` event without prompt text gives one warning for each provider. Then the inbox cannot acknowledge the prompts of that provider.
- After the acknowledgement, the inbox file drops the text, and `claude-code-ide-control-delivered-functions` runs with INSTANCE-ID and REQUEST-ID.

## The inbox

- **Place.** `<report directory>/inbox/<instance-id>/`. The option `claude-code-ide-control-inbox-directory` changes the parent folder.
- **Privacy.** The folders have mode `0700`, and the files mode `0600`, because a prompt can hold private text.
- **Files.** One JSON file for each request. The file name is the first 32 hex digits of the SHA-256 of the request ID, plus `.json`. So any request ID is a safe file name.
- **Atomic writes.** Each write goes to a temporary file in the same folder, which is then renamed over the file.
- **No memory state.** Each operation reads the files. So the inbox survives a reload of the package and a restart of Emacs.
- `claude-code-ide-control-inbox-directory-of (INSTANCE-ID)` returns the folder. A handover can move it (plan §4.8).

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
| `text` | The prompt while it waits. null after a delivery or a rejection. |
| `result` | `queued`, `delivered`, or `rejected`. |
| `reason` | The reason, or null. |
| `created_at`, `updated_at`, `sent_at`, `delivered_at` | ISO 8601 times in UTC, or null. |
| `sent_generation` | The launch generation that got the prompt. |
| `requested_by` | The instance ID of the MCP request, from `claude-code-ide-mcp-request-instance-id`, or null. |

Delivered and rejected files stay, so that a duplicate request ID is always found.

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
- **`:scope` in the spec.** `claude-code-ide-control--make-tool` passes `:scope coordinator` to `claude-code-ide-make-tool`. When `claude-code-ide-make-tool` drops the key, it puts the key on the tool spec in the tools list.

## Phase 3 operations

- `claude-code-ide-control-operations` is an alist of each operation and its function. `handover` and `track-review` have nil.
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
