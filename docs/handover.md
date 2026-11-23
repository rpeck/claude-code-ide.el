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
- With `claude-code-ide-handover-continue` at `ask` (the default), the last question is whether the target goes on with the task after the commit (see "The target goes on"). It comes with the other questions, before the handover starts, never later from a timer. The answers: `y` yes, this time; `n` no, this time; `a` always (saved with `customize-save-variable`); `v` never (saved). When the save fails, the value holds in this Emacs.
- In the status buffer `*Coding Agents Sessions*`, the key `H` offers a handover of the session on the line. Without a session on the line, it offers the first session at a quota limit (`failed/quota-limit`).
- Emacs never starts a handover by itself.

### The function

```elisp
(claude-code-ide-handover-session INSTANCE-ID TARGET-PROVIDER
  &key METHOD CONTEXT INTERRUPT FORCE REQUEST-ID INTERACTIVE CONTINUE)
```

| Key | Value |
|---|---|
| `:method` | `fresh` (default): a new conversation. `fork`: fork the latest conversation of the target provider in the chain. Both get the document. |
| `:context` | Text of the coordinator for the document, or nil. It is kept in the private file `.handover/<id>-context.md` (mode 0600), whose path and hash the registry record holds, so that a rewrite of the document after a crash still has it. |
| `:interrupt` | Non-nil: send Escape to a busy source one time. Else wait until the source is idle. |
| `:force` | Non-nil: go on while subagents or background tasks run, and while other instances run in the worktree. |
| `:request-id` | A string that the caller chooses. A second call with a known request ID returns the current result of the first call, with `:duplicate t`, and starts nothing. |
| `:interactive` | Non-nil when a person asks in Emacs. Then Emacs asks that person about stray processes and about the Codex hook trust. A coordinator call gets the status `needs-user`, or the refusal `hooks-not-trusted`, instead. |
| `:continue` | `t`: after the commit, the target gets the continue prompt. `nil`: it gets nothing more. Without the key, `claude-code-ide-handover-continue` decides, and its value `ask` counts as `always`: this function never asks. |

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
| `other-instance` | Preflight: another live instance runs in the worktree: in this Emacs, or in another Emacs that runs (an open or pending registry entry of that Emacs). Give `:force` to go on. |
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

- Every step, also one that a timer, a callback, or an event runs, goes through one guard (`claude-code-ide-handover--guarded`). An error gives `needs-user` with the reason `step-failed` and the error text.
- A busy lock is tried again a second later. A registry entry that is missing (of the source, or of the target for its chain) gives `needs-user` with the reason `registry-entry-missing`, never an endless retry.

| Stage | Step |
|---|---|
| `requested` | The handover is recorded. |
| `quiescing` | The inbox delivery to the source is held (`claude-code-ide-control-hold`): no queued prompt goes to it from now on. When the inbox sent a prompt to the source whose acknowledgement did not come, the status events are drained, and the stop waits up to `claude-code-ide-handover-ack-wait` (10 s) for it. Wait until the source is idle, failed (for example at a quota limit), or waits for an answer to a question. With `:interrupt`, interrupt it one time. Subagents or background tasks cancel the handover, unless it is forced. After `claude-code-ide-handover-quiesce-timeout` (600 s), the handover is cancelled. |
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
- **The acknowledgement** is the `UserPromptSubmit` of the target whose prompt starts with the marker. It counts in every unfinished status: a delivery that comes while the handover waits for a person commits it.
- **The watch.** After the start, Emacs checks the target every `claude-code-ide-handover-watch-interval` (5 s):
  - A target that ends before the delivery gives `needs-user` with the reason `target-exited`.
  - No delivery within `claude-code-ide-handover-delivery-timeout` (600 s) gives `needs-user` with the reason `no-delivery`.
  - Before either, and before a "wait" again, the watch looks for the marker in the transcript of the target: an event can be lost, and the transcript tells.
### The target goes on

- **The `ready` step stays.** The document asks the target to read it, write its state summary, and reply `ready`. The reply confirms the delivery.
- **The continue prompt.** With `:continue` t (see `claude-code-ide-handover-continue`), the commit then sends the target one more prompt:

  ```text
  The handover is complete. Go on now with the task that your state summary describes, from its next step. Do not wait for another prompt.
  ```

  - It goes through `claude-code-ide-control-submit`, with the request ID `handover-continue:<handover-id>` and `:queue t`. So the inbox rules hold: it waits until the target is idle (after its `ready`).
  - The commit sends it after the inbox move and before the final save. A crash in between sends it again at the recovery; the fixed request ID makes that second submit a duplicate, so the target gets it once.
  - A handover that is cancelled, or that waits for a person and never commits, sends nothing.
  - **The commit finishes only after the inbox took the prompt** (the result `queued`, `delivered` or `unacknowledged`, also as a duplicate of the same request). After a submit error or a refusal, the handover stays at the stage `committed` with `needs-user` and the reason `continue-failed`. A retry, or a recovery after a crash, sends it again with the same request ID. Until then, `claude-code-ide-session-registry-chain-current` does not follow the handover yet, as for every commit that is not final.
  - **The record keeps `continue_sent`.** It is saved at once after the inbox took the prompt, in its own registry save, before the final save of the commit (a busy registry runs the step again, as for the stages). A later commit of the same handover (a recovery) checks it first, so it sends nothing again, also after the inbox pruned its done records (`claude-code-ide-control-done-days`). **The rest that cannot be closed:** a crash in the moment between the accept of the inbox and that save, and then a recovery later than the prune of the done record, sends the prompt a second time.
  - **The commit steps** (`claude-code-ide-handover--commit`, each idempotent): enter the stage `committed`; save the chain of the target, and mark it in the record (`chain_saved`); move the inbox; send the continue prompt when it is due (`continue_sent`); finish. The chain save of the target and the mark are two writes, so the mark also counts as set when the saved chain of the target has a leg of this handover that is not pending (`claude-code-ide-handover--sync-chain-saved`; the cancel, the choices and the recovery read it). Before the chain is saved (for example when the target entry is missing: `registry-entry-missing`), a cancel works. After it, the handover cannot be cancelled (`claude-code-ide-handover-cancel` refuses it), because the chain names the target. Every `needs-user` after the chain save offers `retry` (commit again) and `skip` (commit again without the continue prompt). The handover never finishes before the inbox of the source moved to the target: a failed move gives `step-failed` with a message that names the move, also after a skip, so queued prompts and review results always reach the target. When even the record of the source cannot be saved (its entry is gone), skip ends the run in this Emacs, but only after the inbox moved. A missing target entry is different: the handover stays `needs-user` with `registry-entry-missing` and a message that names the target, the record of the source says so too, and skip does not end it.
- **The decision is in the handover record** (`continue`, `continue_sent`, and `chain_saved`), so a recovery keeps it. A record of an older release has no `continue` field and sends nothing.
- **Where the decision comes from:**
  - `M-x claude-code-ide-handover` and `H` in the status buffer: the question, when the option is `ask`; else the option.
  - A coordinator (the operation `handover`, the MCP tool): its `continue` value; without it, the option, with `ask` as `always`.
  - An agent's `request_handover`, after the user's yes: the option, with `ask` as `always`, because the request already means "go on".

- **After a recovery,** a resumed target that lacks the document gets the pointer as the first prompt of its resume (`claude --resume ID -- PROMPT`, `codex resume ID PROMPT`). Only a target that already runs gets it through `claude-code-ide-control-submit`, with the request ID of the handover (or `handover-<id>`) and `:queue t`.

## Stray processes

- The stop reports processes that still run in the worktree (`:status strays`).
  - A process that this Emacs runs (`:emacs-process`, for example a language server) does not count.
  - A process of another live instance of this Emacs (`:instance-id`) does not count. Only a forced handover has such an instance. So `end` never signals its processes.
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
| `no-delivery` | `wait` (look at the transcript, then wait again for the delivery), `cancel` (stop the target). |
| `target-exited` | `retry` (scan the worktree, then start the target again, with the same instance ID and document), `cancel`. |
| `start-failed`, `step-failed` | `retry` (run the stage again; a target that runs and waits for its document is taken up again, never started twice; from the stage `delivered` on, the commit runs again), `cancel`. |
| `registry-entry-missing` | `cancel`. |
| `continue-failed` | The stage is `committed`, but the inbox did not take the continue prompt. `retry` (commit again, which sends the prompt with the same request ID), `skip` (finish without the prompt). No `cancel`. The same two choices hold for every reason after the commit saved the chain (`chain_saved`), because a cancel would stop the target, which the chain names. |

- `end` signals a process only while it runs with the start time of the scan, within the one second of `claude-code-ide-session-registry--same-start-p`. An unknown start time, at the scan or now, never matches.
- **Survivors before any start.** A recovery that resumes or restarts the target, and the retry of a target that ended, first scan the worktree. The target CLI of its registry entry (its PID with its start time) counts as a stray when it runs outside this Emacs.
- `M-x claude-code-ide-handover-resolve` also takes up a handover that this Emacs does not run. One of an Emacs that ended is claimed and recovered. One whose Emacs seems to run needs a yes to a question that names that Emacs (a forced claim).

### Cancel

`M-x claude-code-ide-handover-cancel` cancels an unfinished handover.

- Before `source-stopped`, the source stays current. After the stop, the source stays stopped; `M-x claude-code-ide-reopen-session` starts it again.
- A running handover whose target runs cannot be cancelled. One that needs a person can: `claude-code-ide-process-stop` stops the target.
- A target process that outlived its Emacs is not ended by the cancel. The cancel shows it like a stray: `end` ends it and then cancels, `wait` checks again, and `cancel` cancels and leaves it running.
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

- Each pending record of FROM gets a queued record in the inbox of TO.
  - The record has **the same request ID**, the same text, and the same creation time. Its reason is `handed-over`.
  - So a review result is still delivered one time, and its acknowledgement names its review ID.
  - When TO has another record with that request ID, the copy gets the ID `handover:<handover-id>:<request-id>`. When TO has that ID too, a number follows (`:2`, `:3`, and so on). No record is dropped.
  - The copy names its origin in `moved_from` (`FROM:ID`), and the old record its copy in `moved_to` (`TO:ID`).
- The record of FROM then becomes final: result `rejected`, reason **`handed-over`**. A reader that sees this reason follows the chain to the current owner (`claude-code-ide-session-registry-chain-current`).
- A prompt that FROM received, and whose acknowledgement did not come in the wait of the quiescing:
  - When the transcript of FROM has a user turn with the same text hash at or after the send, FROM got it, and the document holds it. Its record becomes `delivered`, and it does not move.
  - Else it moves too. Its copy has a `note` that it may have reached FROM.
- Until the handover ends, the inbox of FROM is held. A submit to FROM without QUEUE queues also after the stop, and the commit moves it. A recovery holds the inbox of FROM again from the stage `source-stopped` on.
- A second call moves nothing.
- After the commit, a prompt that `claude-code-ide-control-submit` gets for FROM goes to the current instance of the chain, and its result names that `:destination`.

## Recovery

When the registry mode turns on (for example at the start of Emacs), the interrupted handovers continue by themselves (`claude-code-ide-handover-recover-at-start`, default t). `M-x claude-code-ide-handover-recover` and `claude-code-ide-restore-sessions` run the same recovery.

- **The claim.** Before it acts on a handover, the recovery claims it in one registry change: the handover record gets the process ID, the start time, and the host ID of this Emacs. A handover that another Emacs still owns is left alone. So two Emacs never recover the same handover.
  - **The host ID** is a random UUID in the file `host-id` of the report directory (mode 0600), made once. The host name is not used, because it can change.
  - A record with another host ID belongs to another host, and is left alone.
  - An older record has only a host name. Its host counts as unknown: the record can be recovered when no live Emacs on this host has its owner PID with its start time.
- **Never both:** the recovery never starts the source again.

| Stage at the crash | Recovery |
|---|---|
| `requested`, `quiescing` | Cancel. The source stays current. |
| `source-stopped` | Scan the worktree first (the source died with Emacs, but its background work can still run). Then write the document and start the target. |
| `document-written` | Write the document again, then start the target. |
| `target-started` (target not identified) | Scan the worktree first. A target CLI that outlived the crash (the process ID and start time of its registry entry) counts as a stray. Then start the target again with the same instance ID (with `:last-generation`) and the same document. |
| `target-started`, `target-identified`, `delivered` (target identified) | Scan the worktree for writers first, as above. Then resume the target by its native ID. When its transcript lacks the document, the resume gets the pointer as its first prompt. Then wait for the delivery, or commit. Exception: a target that never saved its conversation (see "An unsaved target" below). |
| `committed` (not final) | Commit again: save the chain, move the inbox, and end. |

**An unsaved target.** A crash right after `target-identified` can end a CC target before it saves its first turn. Emacs chose its session ID (`--session-id`), so the ID is known, but `claude --resume ID` fails with "No conversation found with session ID".

- **The check.** It runs after the worktree scan is clean, just before the start. So a target CLI that survived the crash and saves its transcript while the recovery waits for strays is resumed. The scan keeps the stage and the native ID. An identified target before the stage `delivered` that does not run counts as unsaved when its provider finds no transcript file for its native ID. For CC that is the session file of the registry entry (the transcript path of its report, else `<CLAUDE_CONFIG_DIR>/projects/<project slug>/<ID>.jsonl`). For Codex it is the rollout file (the `transcript` operation). A target with a saved conversation is resumed as before.
- **The rule** is the option `claude-code-ide-handover-unsaved-target`:
  - `fresh` (the default): start the target fresh, right after the clean scan, with the same instance ID and the same document as its first prompt. No person is asked. A CC target gets its session ID again (`--session-id ID`, after the flags of `claude-code-ide-cli-extra-flags`). A fork, and a Codex target, get the new ID that the CLI chooses.
  - `ask`: the old order. The recovery resumes the target; the resume fails, and the handover gives `needs-user` with the reason `target-exited`. The choice `retry` starts the target again with the same document.
- **Codex.** Codex chooses its own ID and reports it with the first `SessionStart`, at the first prompt. So a Codex target reaches `target-identified` only after its first prompt, and usually has its rollout file then. Only a Codex target without a rollout file starts fresh.

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
   "context_file": "…/.handover/<id>-context.md", "context_hash": "…", "continuation": null,
   "source_leg": {"provider": "claude", "native_id": "…", "transcript": "…", "end_record": 44},
   "strays": [{"pid": 4242, "start": 1795000000.12, "command": "…", "cwd": "…", "reason": "worktree"}],
   "interactive": false, "emacs_pid": 1234, "emacs_start_time": 1794990000.5,
   "host_id": "…", "host": "…",
   "created_at": "…", "updated_at": "…"}
  ```

  - `emacs_pid`, `emacs_start_time`, and `host_id` name the Emacs that owns the handover; `host` is the host name, for people.
  - `continuation` says what a clean scan does next: `start-target`, `resume-target`, or `cancel`.
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
| `claude-code-ide-control-handover` | `instance_id`, `target_provider`, and optional `method`, `context`, `interrupt`, `force`, `request_id`, `continue` (boolean: the continue prompt after the commit; without it, the user's option, with `ask` as true). It returns at once. |
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
| `claude-code-ide-handover-ack-wait` | 10 | Seconds that the stop waits for the acknowledgement of a prompt that the source got. |
| `claude-code-ide-handover-directory` | `.handover` | Folder in the worktree for the documents and the summaries. |
| `claude-code-ide-handover-session-server-detection` | `auto` | The `:session-server` of the document. |
| `claude-code-ide-handover-budget` | nil | The size budget of the document. |
| `claude-code-ide-handover-recover-at-start` | t | Continue the interrupted handovers when the registry mode turns on. With nil, only the early ones are cancelled then. |
| `claude-code-ide-handover-continue` | `ask` | Whether the target goes on with the task after the commit: `ask` (the interactive handover asks y/n/a/v; a coordinator or Lisp call counts as `always`), `always`, or `never` (the target waits for your prompt). See "The target goes on". |
| `claude-code-ide-handover-unsaved-target` | `fresh` | What the recovery does with an identified target that never saved its conversation: `fresh` starts it fresh with the same IDs and document, `ask` resumes it as before and then asks a person (`target-exited`). See "An unsaved target". |
| `claude-code-ide-handover-enable-request-tool` | t | Give the agents the tool `request_handover`. |

## Limits

- Codex reports no background terminals. So the quiescing cannot see them; the stop ends them through the recorded process groups.
- The interrupt is the Escape key. In a dialog it can deny or close the dialog.
