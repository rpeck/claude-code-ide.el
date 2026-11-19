# Handover

A handover moves the work of one instance (the source) to a new native conversation (the target) of the same provider or of the other provider (plan §4.7).
The usual reason is a quota limit of the source. So the source never runs one more turn: the target gets the handover document, and writes a state summary in its first turn.

- Code: `claude-code-ide-handover.el`.
- Tests: `claude-code-ide-handover-tests.el`.
- The document: [handover-document.md](handover-document.md).
- The control operations and the inbox: [api-control.md](api-control.md).
- The registry: [session-schema.md](session-schema.md).
- The process stop: [process-tree.md](process-tree.md).

## Start a handover

### The command

- `M-x claude-code-ide-handover` hands over the instance of the current buffer, or an instance that you choose.
- It asks for the target provider (default: another provider), the method, and optional context text for the target.
- When the source is busy, it asks whether to interrupt it. Else the handover waits until the source is idle.
- When subagents or background tasks run, or the state of the source is unknown (`disconnected`), it asks for a confirmation. The same yes lets the handover go on while other instances run in the worktree.
- For a Codex target whose status hooks are not trusted, it asks for the trust (`claude-code-ide-codex-prepare-trust`).
- In the status buffer `*Coding Agents Sessions*`, the key `H` offers a handover of the session on the line. Without a session on the line, it offers the first session at a quota limit (`failed/quota-limit`).
- Emacs never starts a handover by itself.

### The function

```elisp
(claude-code-ide-handover-session INSTANCE-ID TARGET-PROVIDER
  &key METHOD CONTEXT INTERRUPT FORCE REQUEST-ID INTERACTIVE)
```

| Key | Value |
|---|---|
| `:method` | `fresh` (default): a new conversation. `fork`: fork the latest conversation of the target provider in the chain. Both get the document. |
| `:context` | Text of the coordinator for the document, or nil. |
| `:interrupt` | Non-nil: send Escape to a busy source one time. Else wait until the source is idle. |
| `:force` | Non-nil: go on while subagents or background tasks run, and while other instances run in the worktree. |
| `:request-id` | A string that the caller chooses. A second call with a known request ID returns the current result of the first call, with `:duplicate t`, and starts nothing. |
| `:interactive` | Non-nil when a person asks in Emacs. Then Emacs asks that person about stray processes and about the Codex hook trust. A coordinator call gets the status `needs-user`, or the refusal `hooks-not-trusted`, instead. |

- The handover runs from timers and events. The function returns at once.
- The control operation `handover` is this function (`claude-code-ide-control-call 'handover ...`).

### Refusals and the preflight

A refusal is a result, not a signal: `(:status error :reason REASON :message TEXT)`. Nothing of the source changes, and the registry gets no record.

| Reason | Meaning |
|---|---|
| `registry-off` | `claude-code-ide-session-registry-mode` is off. The handover saves its stages in the registry. |
| `not-running` | The source does not run in this Emacs. |
| `unknown-provider` | The target provider is not registered. |
| `invalid-method` | The method is not `fresh` or `fork`. |
| `no-conversation` | The source has no native ID yet, so it has no conversation to hand over. |
| `no-registry-entry` | The registry has no entry of the source. |
| `handover-running` | Another handover holds the worktree of the source. |
| `target-unavailable` | Preflight: the `detect` operation of the target provider does not find its CLI. |
| `other-instance` | Preflight: another live instance runs in the worktree. Give `:force` to go on. |
| `hooks-not-trusted` | Preflight: the target is Codex, and its status hooks are not trusted. Without them, the handover cannot see the delivery. A coordinator call checks only the cached trust; on a cache miss, a check starts in the background, so a later call knows the answer. |
| `busy` | Subagents or background tasks run. Give `:force` to go on. |
| `no-earlier-conversation` | `fork`, but the chain has no conversation of the target provider. |
| `unavailable` | A needed function is missing, or the target provider cannot fork. |
| `registry-write-failed` | The registry could not save the first stage (for example, its lock stayed busy). The change is dropped, so no record appears later. |

## Status

`(claude-code-ide-handover-status ID)` takes the handover ID or the request ID. The result has these keys:

| Key | Value |
|---|---|
| `:status` | `running`, `needs-user`, `committed`, `cancelled`, or `failed`. |
| `:handover-id`, `:request-id` | The IDs. |
| `:stage` | The stage (below). |
| `:source-id`, `:target-id` | The instance IDs. The target ID is nil before the stage `target-started`. |
| `:target-provider`, `:method` | As given. |
| `:reason`, `:message` | Why the status is what it is, or nil. |
| `:document`, `:document-hash` | The file of the document and its SHA-256. |
| `:strays` | Stray processes: plists with `:pid`, `:command`, `:cwd`, and `:reason`. |

An unknown ID gives `(:status error :reason unknown-handover)`.

## The stages

Emacs saves each stage in the registry entry of the source **before** the step of that stage runs. Each stage has a step, so that a retry after a busy registry, or a person's retry, always goes on.

| Stage | Step |
|---|---|
| `requested` | The handover is recorded. |
| `quiescing` | The inbox delivery to the source is held (`claude-code-ide-control-hold`): no queued prompt goes to it from now on. Wait until the source is idle, failed (for example at a quota limit), or waits for an answer to a question. With `:interrupt`, interrupt it one time. Subagents or background tasks cancel the handover, unless it is forced. After `claude-code-ide-handover-quiesce-timeout` (600 s), the handover is cancelled. |
| `source-stopped` | `claude-code-ide-process-stop-later` ends the source and its process tree, with the soft end of its provider, and then scans the worktree. |
| `document-written` | `claude-code-ide-transcript-handover-document` makes the document. Emacs writes it to `<worktree>/.handover/<id>.md` (mode 0600) and records its hash. Emacs adds `.handover/` to the Git exclude file of the worktree. |
| `target-started` | The target ID is saved first; while the registry is busy, the start waits. The target starts with the provider's launch, or its fork, with the start prompt (below). Its chain is saved with its own leg pending; while the registry is busy, that save is tried again every second. |
| `target-identified` | The native ID of the target is known: at the start for CC (Emacs chooses it), from the first `SessionStart` for Codex. |
| `delivered` | A `prompt-submit` event of the target starts with the marker of this handover ID. |
| `committed` | The final chain of the target is saved. Then the inbox of the source moves to the target, and then the handover is committed. A crash in between moves the inbox again at the recovery; the move is idempotent. |

### The document

- The document has the parts of [handover-document.md](handover-document.md).
- The handover passes these values:
  - `:source`: the leg of the source, captured at the end of the quiescing, with `:end-record`, the number of lines of its transcript after the stop. Records that the file gets later are not part of the chain.
  - `:chain`: the legs of the registry entry of the source. Its own leg holds the handover ID, the document hash, and the summary file of the handover that started it.
  - `:context`, `:handover-id`, `:target-provider`.
  - `:summary-file`: `<worktree>/.handover/<id>-state.md`.
  - `:session-server`: `claude-code-ide-handover-session-server-detection` (default `auto`).
  - `:budget`: `claude-code-ide-handover-budget` (nil: the transcript default, 100000 characters).
- The Codex provider has no `transcript` operation. So the leg of a Codex source takes its rollout from the registry (the `transcript_path` of its `SessionStart`), else from a search for `rollout-*-<native-id>.jsonl` in `$CODEX_HOME/sessions` (default `~/.codex/sessions`).

### The delivery

- **The document never goes on the command line.** The command line has a size limit, and `ps` shows it.
- **The start prompt** of both providers (`claude ... -- PROMPT`, `codex ... -- PROMPT`) is a short pointer, from `claude-code-ide-handover-start-prompt`:

  ```text
  <!-- claude-code-ide-handover-document id=ID -->
  Read the handover document at <worktree>/.handover/ID.md fully, and follow its instructions.
  - State summary file: `<worktree>/.handover/ID-state.md`
  ```

  - A new Codex conversation has no native ID before its first prompt, and `codex queue` needs that ID. The start prompt needs none.
  - The first line is the marker. So the transcript readers treat the turn as the start of a leg (its bootstrap), and they find the summary file in it.
  - The start checks the hash of the document file first.
- **The acknowledgement** is the `UserPromptSubmit` of the target whose prompt starts with the marker.
- **The watch.** After the start, Emacs checks the target every `claude-code-ide-handover-watch-interval` (5 s):
  - A target that ends before the delivery gives `needs-user` with the reason `target-exited`.
  - No delivery within `claude-code-ide-handover-delivery-timeout` (600 s) gives `needs-user` with the reason `no-delivery`.
- **After a recovery,** a resumed target that lacks the document gets the pointer as the first prompt of its resume (`claude --resume ID -- PROMPT`, `codex resume ID PROMPT`). Only a target that already runs gets it through `claude-code-ide-control-submit`, with the request ID of the handover (or `handover-<id>`) and `:queue t`.

## Stray processes

- The stop reports processes that still run in the worktree (`:status strays`).
  - A process that this Emacs runs (`:emacs-process`, for example a language server) does not count.
  - A review process (`claude-code-ide-review-process-ids`) does not count. The stop and the scan also leave it out. Its result goes to the target after the commit.
- Each stray gets the start time of its process right after the scan (`:start`).
- A handover with strays, a source that survived SIGKILL (`source-did-not-stop`), or a failed scan (`scan-failed`) gets the status `needs-user`.
  - An interactive handover asks at once. It shows the process ID, the command, and the folder of each stray.
  - A coordinator sees `needs-user` in the status, and Emacs shows a message.
- `M-x claude-code-ide-handover-resolve` answers. The choices:

| Reason | Choices |
|---|---|
| `strays`, `source-did-not-stop` | `end`: SIGTERM, then SIGKILL after `claude-code-ide-handover-stray-wait` (10 s), then scan again. `wait`: scan again after that time. `cancel`. |
| `scan-failed` | `wait` (scan again), `go` (go on without the check), `cancel`. |
| `no-delivery` | `wait` (wait again for the delivery), `cancel` (stop the target). |
| `target-exited` | `retry` (start the target again, with the same instance ID and document), `cancel`. |
| `start-failed`, `step-failed` | `retry` (run the stage again), `cancel`. |

- `end` signals a process only while it runs with the start time of the scan. An unknown start time, at the scan or now, never matches.

### Cancel

`M-x claude-code-ide-handover-cancel` cancels an unfinished handover.

- Before `source-stopped`, the source stays current. After the stop, the source stays stopped; `M-x claude-code-ide-reopen-session` starts it again.
- A handover whose target runs can be cancelled only with the reason `no-delivery` or `target-exited`. Then `claude-code-ide-process-stop` stops the target.
- After the start of the target, the cancel archives the registry entry of the target, so that no restore starts it.
- The cancel releases the inbox hold of the source.
- A handover that another live Emacs owns cannot be cancelled. A handover of an Emacs that ended is claimed first (see "Recovery").

## One writer for each worktree

- While a handover is unfinished, Emacs refuses to start another instance in its worktree (`user-error`). Only the start of its own target goes through.
- An unfinished handover in the registry, for example of an Emacs that crashed, holds the worktree too, until a recovery or a cancel ends it.
- The check is an `:around` advice of `claude-code-ide--start-session` (`claude-code-ide-handover--guard-start`).
- The preflight refuses a handover while other instances run in the worktree, unless it is forced.

## The inbox moves to the target

`(claude-code-ide-control-move-inbox FROM TO)` runs at the commit, before the commit is final.

- Each prompt that FROM has not received yet gets a queued record in the inbox of TO.
  - The record has **the same request ID**, the same text, and the same creation time. Its reason is `handed-over`.
  - So a review result is still delivered one time, and its acknowledgement names its review ID.
- The record of FROM then becomes final: result `rejected`, reason **`handed-over`**. A reader that sees this reason follows the chain to the current owner (`claude-code-ide-session-registry-chain-current`).
- A prompt that FROM received, and that waits for its acknowledgement, stays. It becomes `unacknowledged` in time.
- A request ID that TO knows already is not moved again. A second call moves nothing.

## Recovery

When the registry mode turns on (for example at the start of Emacs), the interrupted handovers continue by themselves (`claude-code-ide-handover-recover-at-start`, default t). `M-x claude-code-ide-handover-recover` and `claude-code-ide-restore-sessions` run the same recovery.

- **The claim.** Before it acts on a handover, the recovery claims it in one registry change: the handover record gets the process ID and the start time of this Emacs. A handover that another Emacs still owns (its process ID with its start time, or an Emacs of another host) is left alone. So two Emacs never recover the same handover.
- **Never both:** the recovery never starts the source again.

| Stage at the crash | Recovery |
|---|---|
| `requested`, `quiescing` | Cancel. The source stays current. |
| `source-stopped` | Scan the worktree first (the source died with Emacs, but its background work can still run). Then write the document and start the target. |
| `document-written` | Write the document again, then start the target. |
| `target-started` (target not identified) | Scan the worktree first. A target CLI that outlived the crash (the process ID and start time of its registry entry) counts as a stray. Then start the target again with the same instance ID (with `:last-generation`) and the same document. |
| `target-started`, `target-identified`, `delivered` (target identified) | Resume the target by its native ID. When its transcript lacks the document, the resume gets the pointer as its first prompt. Then wait for the delivery, or commit. |
| `committed` (not final) | Commit again: save the chain, move the inbox, and end. |

- The plain restore and the reopen leave out the entries that a handover holds (`claude-code-ide-session-registry--handover-blocks-p`):
  - a source whose handover is committed, or is unfinished after `quiescing`;
  - a target whose own leg is still `pending`.
- `claude-code-ide-session-registry--start-entry` refuses such an entry with a `user-error`, also for `claude-code-ide-reopen-session` and the control operation `resume`. Only the recovery starts it (`claude-code-ide-session-registry--handover-start`).
- A committed source stays a normal `closed` entry. It is never restored or reopened while the chain goes on.

## The registry

The handover fields are in schema version 4, in its own file (`claude-code-ide-state-file` with `-v4`). The registry reads and migrates the version 3, 2, and 1 files, and never writes or moves them.

- `handover`: the last handover with this entry as its source, as a JSON object:

  ```json
  {"id": "…", "request_id": "…", "stage": "target-started", "status": "running",
   "reason": null, "message": null, "method": "fresh", "fork_id": null,
   "source_instance_id": "…", "source_provider": "claude", "target_provider": "codex",
   "target_instance_id": "…", "target_native_id": null,
   "worktree": "…/", "directory": "…/", "instance_name": null, "role": null,
   "document": "…/.handover/<id>.md", "document_hash": "…", "summary_file": "…",
   "source_leg": {"provider": "claude", "native_id": "…", "transcript": "…", "end_record": 44},
   "strays": [{"pid": 4242, "start": 1795000000.12, "command": "…", "cwd": "…", "reason": "worktree"}],
   "interactive": false, "emacs_pid": 1234, "emacs_start_time": 1794990000.5, "host": "…",
   "created_at": "…", "updated_at": "…"}
  ```

  - `emacs_pid`, `emacs_start_time`, and `host` name the Emacs that owns the handover.
- `chain`: the legs of the chain that ends with this entry, oldest first, with this entry's own leg last. Each leg has the keys `provider`, `instance_id`, `native_id`, `transcript`, `worktree`, `handover_id`, `document_hash`, `summary_file`, `start_commit`, `end_record`, and `pending` (true until the commit).
- `(claude-code-ide-session-registry-chain-current INSTANCE-ID)` returns the instance ID of the current leg: it follows each committed handover from its source to its target. An instance without a chain gives nil.
- A new start of a known entry keeps both fields.

## The request of an agent

- The MCP tool `request_handover` (instance scope) takes `target_provider`, `method`, and `reason`, all optional.
- It only saves the request on the instance and returns at once: `{"status": "requested", ...}`.
- After the next `turn-end` of that instance, Emacs asks you (`y-or-n-p`). A yes starts `claude-code-ide-handover` with the reason as the context. The request is used one time.
- `claude-code-ide-handover-enable-request-tool` (default t) turns the tool off.

## Coordinator tools

| Tool | Arguments |
|---|---|
| `claude-code-ide-control-handover` | `instance_id`, `target_provider`, and optional `method`, `context`, `interrupt`, `force`, `request_id`. It returns at once. |
| `claude-code-ide-control-handover-status` | `handover_id` (the handover ID or the request ID). |

- Both have the coordinator scope.
- In a Codex coordinator, `handover` asks for the approval of the user. That approval is the user's confirmation; Emacs does not ask again. `handover-status` only reads, so it runs without approval, like `list-instances`, `inspect-instance`, and `request-status` (`claude-code-ide-codex-coordinator-approved-tools`).

## Options

| Option | Default | Meaning |
|---|---|---|
| `claude-code-ide-handover-quiesce-timeout` | 600 | Seconds to wait for an idle source. |
| `claude-code-ide-handover-poll-interval` | 1 | Seconds between two checks of the state of the source. |
| `claude-code-ide-handover-stray-wait` | 10 | Seconds before the worktree is scanned again. |
| `claude-code-ide-handover-delivery-timeout` | 600 | Seconds that a started target has to get the document. |
| `claude-code-ide-handover-watch-interval` | 5 | Seconds between two checks of a target that waits for its document. |
| `claude-code-ide-handover-directory` | `.handover` | Folder in the worktree for the documents and the summaries. |
| `claude-code-ide-handover-session-server-detection` | `auto` | The `:session-server` of the document. |
| `claude-code-ide-handover-budget` | nil | The size budget of the document. |
| `claude-code-ide-handover-recover-at-start` | t | Continue the interrupted handovers when the registry mode turns on. With nil, only the early ones are cancelled then. |
| `claude-code-ide-handover-enable-request-tool` | t | Give the agents the tool `request_handover`. |

## Limits

- Codex reports no background terminals. So the quiescing cannot see them; the stop ends them through the recorded process groups.
- The interrupt is the Escape key. In a dialog it can deny or close the dialog.
