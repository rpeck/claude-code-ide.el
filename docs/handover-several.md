# Handovers of several instances in one worktree

This document is the design of issue #42: a handover in a worktree where other instances run, and a handover of all instances of a worktree in one command.

- Status: implemented, after a council review of the design (approve with changes, 3 of 3). The notes "Changed in the implementation" mark where the code differs from the design.
- Base: `main` at 4b00d39 (after PR #37).
- The handover: [handover.md](handover.md). The document: [handover-document.md](handover-document.md).
- The process scan: [process-tree.md](process-tree.md). The control operations: [api-control.md](api-control.md).

## The problem

- A coordinator often runs several instances in one worktree, for example a plan session and a code session on the same branch.
- To move them all to the other provider, each instance needs a handover.
- Today the preflight refuses with `other-instance` while another live instance runs in the worktree (`claude-code-ide-handover--preflight`, through `claude-code-ide-handover--other-writers`).
- After the first handover, its target runs in the worktree. So the second handover is refused too.
- Only the `:force` key of the control API goes past the refusal. `M-x claude-code-ide-handover` gives `:force` only after the question about subagents or an unknown state.

## Safety rules that stay

The design never weakens these rules:

1. No two agents write the same files without the knowledge of the person.
2. No stray scan lists or ends a process of another session.
3. No handover starts a target next to its live source (`claude-code-ide-handover--source-gone-p`).

Rule 3 also means that a handover never adds a writer to the worktree. The source ends before the target starts. One writer goes, one writer comes.

## Scope of v1: the sessions of this Emacs

- The question and `:allow-others` cover only the instances and MCP sessions of **this** Emacs.
- A live registry entry of **another** Emacs in the worktree stays a hard `other-instance` refusal, also with `:allow-others`. Only `:force` goes past it, as today.
- **Why:** the stray scan of this Emacs cannot see the process tree of an instance of another Emacs. A safe scan needs more than a tag (see "Left out"). Without it, `end` can signal that tree, which breaks rule 2.

## The decisions

| Item of the issue | Decision | New code |
|---|---|---|
| 1. Ask, do not refuse | A y/n question with the list of the other sessions of this Emacs. `C-u` skips it. A new key `:allow-others`, also in the MCP tool (`allow_others`). `:force` does not change. | Small |
| 2. Serialize with a queue | No queue in v1. The second request gets `handover-running` with the ID of the first. The batch command orders its own handovers. | One key in a result |
| 3. Batch command | `M-x claude-code-ide-handover-worktree`, one batch per worktree, and `M-x claude-code-ide-handover-worktree-stop`. Questions once. Skip after automatic cancels, stop after a cancel of the person, wait at `needs-user`. | Medium |
| 4. Stray scan | PR #37 covers this Emacs. Another Emacs stays a refusal (see "Scope of v1"). | None |
| 5. Lock during a handover | Other instances get no prompt from the handover already. Every start path reports `handover-running` with the handover ID, not `start-failed`. No wait. | One clause |
| 6. Edit-clash notice | A new part "Other sessions in this worktree" in the document. `git status --porcelain` is in the workspace state already. | Small |

## The rules today and their owners

Each rule has one owner function. The design calls these functions and adds no second copy of a rule.

| Rule | Owner |
|---|---|
| The worktree of a folder | `claude-code-ide-handover--directory-key` (through `claude-code-ide--worktree-root`) |
| The other writers in a worktree | `claude-code-ide-handover--other-writers`, from `claude-code-ide-handover--other-instances`, `claude-code-ide-handover--other-sessions` and `claude-code-ide-handover--other-emacs-entries`. Changed in the implementation: the combination of the three is `claude-code-ide-handover--writers (KEY EXCLUDE)`; `--other-writers` and `--run-writers` call it. |
| A live registry entry of another Emacs | `claude-code-ide-session-registry-other-emacs-p` |
| One unfinished handover per worktree | `claude-code-ide-handover--holding-run` |
| No start in a held worktree | `claude-code-ide-handover--guard-start` (an `:around` advice of `claude-code-ide--start-session`) |
| The strays that count | `claude-code-ide-handover--relevant-strays` |
| The inbox hold of the source | `claude-code-ide-control-hold`, `claude-code-ide-control-release` |
| The end of a run in this Emacs | `claude-code-ide-handover--finish` |
| A run that needs a person | `claude-code-ide-handover--needs-user` |
| The Git state of the worktree | `claude-code-ide-transcript-workspace-state` |
| The state name of an instance | `claude-code-ide-control--state-reason` on `claude-code-ide-control-state-of` |
| A label of an instance | `claude-code-ide-handover--instance-label` |
| The questions of a handover | `claude-code-ide-handover--read-method`, `claude-code-ide-handover--read-continue` |
| The Codex hook trust | `claude-code-ide-handover--codex-trusted-p` |

## 1. The question in place of the refusal

### What the question protects against

- The `other-instance` refusal guards two risks. Each risk has its own fix for the sessions of this Emacs:

  | Risk | Fix |
  |---|---|
  | The stray scan lists, and `end` signals, a process of another session. | The owner tags of the scan (`:instance-id`, `:session-id`), from PR #37. |
  | Two agents edit the same files at the same time. | The handover does not add a writer (rule 3). The person already runs these agents together. The document tells the target about the others (item 6). |

- So the question protects against one thing only: a person who does not know that other sessions run in the worktree.
- **Is the question enough?** For the sessions of this Emacs, yes, together with item 6. Without item 6, the target can take the uncommitted changes of another agent for its own work. So item 1 ships with item 6. For another Emacs, no: that case stays a refusal.

### The order of the checks

`claude-code-ide-handover--read-args` checks these first, before any question:

1. `claude-code-ide-handover--holding-run`: a handover holds the worktree. `user-error` with its ID.
2. `claude-code-ide-handover--other-emacs-entries`: an instance of another Emacs runs in the worktree. `user-error` with its key and the PID of its Emacs.

Then it asks the question below, and then the other questions.

### The question

The question comes when the instances and sessions of this Emacs (`--other-instances`, `--other-sessions`) are not empty.

```text
2 other sessions run in the worktree /Users/me/src/app/:
  plan (claude, 5afe576e-...): idle
  coder (codex, 01a1eb92-...): failed/quota-limit
They go on with their work. The handover does not stop them or their processes.
The target gets this list.
Hand over anyway? (y or n)
```

- **The list.** One new function, `claude-code-ide-handover--writer-lines (IDS)`, turns each ID of `--other-writers` into one line. Changed in the implementation: it takes an optional second argument NEXT, the IDs whose line gets the batch note (item 6).

  | The ID is | The line |
  |---|---|
  | A live instance of this Emacs | `claude-code-ide-handover--instance-label`, then the state from `claude-code-ide-control--state-reason` (`idle`, `working`, `failed/quota-limit`, ...) |
  | A live MCP session without a descriptor | The session ID and "an MCP session without an instance descriptor" |
  | A live registry entry of another Emacs | Its instance name, provider, key, and the PID of its Emacs. Only a document of a handover with `:force` can have this line. |

- **The keys: `y` and `n`** (`y-or-n-p`).
  - `y`: the handover goes on, with `:allow-others t`.
  - `n`: `user-error` "Handover not started". No other question comes, and the registry gets no record.
- **`C-u`** before `M-x claude-code-ide-handover` skips the question and gives `:allow-others t`. `H` in the status buffer reads `current-prefix-arg` the same way, because it calls `--read-args`.
  - Changed in the implementation: `--confirm-others` reads the prefix argument itself, and lists `--writers`. `:allow-others` also takes a list of IDs, and the preflight refuses `other-instance` for any writer outside it. `--read-args` gives the IDs that the question showed (`C-u`: the IDs that it would show; without other sessions, nil), so that a session that starts later still gets the refusal. `t` keeps its meaning for the control API and the MCP tool.
- **One helper asks it:** `claude-code-ide-handover--confirm-others (INSTANCE &optional EXCLUDE)`. It returns the list of IDs that the person confirmed (possibly empty), or signals `user-error` after `n`. EXCLUDE is a list of IDs that the question leaves out (the batch uses it).
- **Three callers:**
  1. `claude-code-ide-handover--read-args` (`M-x claude-code-ide-handover` and `H`).
  2. `claude-code-ide-handover--offer-request` (the `request_handover` tool of an agent), after its own y/n. Today this path gives the refusal as a `user-error`.
  3. The batch command (item 3).

| Option | Decision | Why |
|---|---|---|
| Keys `y` / `n` / `l` (list) | Rejected | The list is short and is always in the question. |
| `yes-or-no-p` | Rejected | Nothing ends or changes because of this yes. The busy question keeps `yes-or-no-p`, because there background tasks end. |
| The list in a separate buffer | Rejected | A buffer stays open after the answer. The stray question also shows its list in the prompt (`claude-code-ide-handover--ask`). |

### The new key `:allow-others`

- `claude-code-ide-handover-session` gets the key `:allow-others`. It allows the other instances and MCP sessions of this Emacs in the worktree, and nothing more.
- The preflight gets one more argument: `(claude-code-ide-handover--preflight INSTANCE TARGET-PROVIDER FORCE ALLOW-OTHERS INTERACTIVE)`.
  - `--other-emacs-entries` not empty, without FORCE: `other-instance`, with a message that names the other Emacs.
  - `--other-instances` or `--other-sessions` not empty, without FORCE or ALLOW-OTHERS: `other-instance`, as today.
- `:force` keeps both effects: it allows all other writers, and subagents or background tasks.
- **Why a new key, and not `:force`:** `:force` also lets the quiescing stop a source in `waiting-for-task` (`claude-code-ide-handover--quiesce`). A source that is `working` at the yes can reach `waiting-for-task` later. With `:force`, the stop then ends its background tasks without a question. A yes to "other sessions run here" must not have that effect.
- The run does not keep the key. The preflight runs only at the start, and the recovery never runs the preflight. So the registry record does not change.
- `claude-code-ide-handover` (the command) gets an eighth optional argument, `ALLOW-OTHERS`, after `CONTINUE`.

### The MCP tool

- The tool `claude-code-ide-control-handover` gets the optional boolean argument `allow_others`: "Hand over while other instances of this Emacs run in the working tree. Unlike force, it does not stop subagents or background tasks."
- `claude-code-ide-handover--mcp-handover` gets the argument `allow-others` after `continue`, and passes `:allow-others (claude-code-ide-handover--flag allow-others)`.
- `force` does not change.

## 2. One handover at a time per worktree, without a queue

### Decision: no queue in v1

- The rule "one unfinished handover per worktree" stays (`claude-code-ide-handover--holding-run`).
- A second request in the same worktree gets the refusal `handover-running` as today. The result gets one more key, `:handover-id`, with the ID of the handover that holds the worktree. The message names it already.
- `claude-code-ide-handover-status` does not change.

### Why no queue

| User of a queue | What it does without a queue |
|---|---|
| The batch command | It starts the next handover after the previous one ends (item 3). That is the only user that needs an order. |
| A person, a second `M-x claude-code-ide-handover` | `--read-args` refuses before the first question, and names the handover that runs. |
| A coordinator | It polls `claude-code-ide-handover-status` with the `:handover-id` of the refusal, then calls again. It does this already for `needs-user`. |

| Option | Decision | Why |
|---|---|---|
| A queue in memory | Rejected | A crash loses it without a trace. A coordinator then waits for a request that never starts. |
| A queue in the registry | Rejected | It needs a new field in schema version 4, a recovery rule for each queued request, a cancel for a queued request, and a status for it. That is much code for one user, the batch. |
| No queue; the refusal gives the ID that holds the worktree | Chosen | One key in a result. The batch orders itself. |

## 3. The batch command

### The command

`M-x claude-code-ide-handover-worktree` hands over the live instances of one worktree to one target provider, one after the other.

```elisp
(claude-code-ide-handover-worktree INSTANCE-IDS TARGET-PROVIDER
  METHOD CONTEXTS INTERRUPT CONTINUE CONFIRMED)
```

| Argument | Value |
|---|---|
| `INSTANCE-IDS` | The sources, in order. |
| `TARGET-PROVIDER` | One provider for all. |
| `METHOD` | `fork` or `fresh`. With `fork`, each source forks when its chain has a conversation of the target provider (`claude-code-ide-handover--fork-id`), else it starts fresh. |
| `CONTEXTS` | An alist `(INSTANCE-ID . TEXT)`. A source without an entry gets no context. |
| `INTERRUPT` | Non-nil: interrupt a busy source one time. One policy for all. |
| `CONTINUE` | `yes` or `no`, as for `claude-code-ide-handover`. |
| `CONFIRMED` | The IDs of the sessions outside the batch that the person confirmed (from `--confirm-others`). |

### The checks and the questions

The interactive spec (`claude-code-ide-handover--read-batch-args`) does all checks and asks each question one time, before the first handover starts. No question of the batch comes later from a timer.

1. **The worktree.** The worktree of the instance of the current buffer. Without one, `completing-read` over the worktrees (`claude-code-ide-handover--directory-key`) of the live instances. Changed in the implementation: one worktree needs no question (`claude-code-ide-handover--read-worktree`, as `claude-code-ide-handover--read-unfinished` does).
2. **The checks, before any question:**
   - A batch of this Emacs runs in the worktree: `user-error` with "M-x claude-code-ide-handover-worktree-stop" (see "One batch per worktree").
   - `claude-code-ide-handover--holding-run`: `user-error` with the handover ID.
   - `claude-code-ide-handover--other-emacs-entries`: `user-error` with the key of the entry and the PID of its Emacs.
3. **The target provider.** `completing-read`, default: a provider other than that of the current instance, as in `--read-args`.
4. **The Codex hook trust**, for a Codex target only: `(claude-code-ide-handover--codex-trusted-p WORKTREE t)` one time. Without the trust, `user-error`. The handovers of the batch then find the cached trust.
5. **The sources.** `completing-read-multiple` over the labels of the live instances of this Emacs in the worktree whose provider is not the target provider. Empty input selects all. The order is the order of `claude-code-ide-instances`.
6. **The other sessions.** `claude-code-ide-handover--confirm-others` with the selected sources as EXCLUDE. It lists only the sessions outside the batch, and adds the line "The targets of the batch also run here." `C-u` skips it; then CONFIRMED is the list of IDs that the question shows without `C-u`.
7. **The method.** `claude-code-ide-handover--read-method`, only when at least one source can fork.
8. **The interrupt policy.** `y-or-n-p` "Interrupt a busy session (else wait until it is idle)? ", only when a selected source is `working` or `waiting-for-user` and not quiet (`claude-code-ide-handover--quiet-state-p`), as in `--read-args`. Else INTERRUPT is nil.
9. **The context note.** One `read-string` for each source: "Context for LABEL (empty for none): ".
10. **Continue.** `claude-code-ide-handover--read-continue`, last.

- The batch never gives `:force`. A source with subagents or background tasks gets `busy`, and the batch skips it (see "The rules after each handover").
- The handovers of the batch run with `:interactive nil`. So no question comes from a timer: a stray or another problem gives `needs-user`, and the person answers with `M-x claude-code-ide-handover-resolve`.

### One batch per worktree

- `claude-code-ide-handover--batches` is a hash table in memory, from the worktree key to the batch plist (changed in the implementation: a `cl-defstruct`, `claude-code-ide-handover--batch`, so that the object that a timer captures stays the same object): the target provider, the answers, CONFIRMED, the sources that are left, the current handover ID, the targets, the results, the flags `stop`, `dead` and `told`, and the pending timer.
- A second batch command in the same worktree is refused, while the current run of the batch is unfinished and owned by this Emacs.
- **A stale batch is dropped** when the command runs again: its current run is gone (`claude-code-ide-handover--find` gives nil), is final, or has the owner `other` (another Emacs claimed it). The drop marks the old batch `dead` and cancels its pending timer (see "Stale timers"). The command shows one message about the drop, and goes on.
- **`M-x claude-code-ide-handover-worktree-stop`** sets `stop` on the batch of the worktree of the current buffer (or a chosen one). The batch starts no new handover. The current handover goes on to its end as usual; cancel it with `M-x claude-code-ide-handover-cancel` when necessary. The final message comes at its end. A batch without a current run ends at once. Changed in the implementation: also a batch whose current run is final or claimed (a stale batch, for example a commit whose advance timer did not run yet) ends at once.

### The status hook

- A new abnormal hook, `claude-code-ide-handover--status-functions`, gets the run.
- **One end function.** `claude-code-ide-handover--finish` gets an optional argument NO-SAVE. The skip in `claude-code-ide-handover-resolve` for a source without a registry entry calls `(claude-code-ide-handover--finish run 'committed nil TEXT t)` after the inbox move, in place of its own `setf`, release and message.
- **The order in `--finish`:**
  1. Cancel the timers. Set the status, the reason and the message.
  2. Save the run, unless NO-SAVE.
  3. Release the inbox hold of the source (`claude-code-ide-control-release`).
  4. Show the message.
  5. Only when the save succeeded (or NO-SAVE), and only one time for each run: run the hook. A new in-memory slot of the run, `ended`, records that the hook ran.
- **`--needs-user`** runs the hook too, after its save, each time the run enters `needs-user`.
- **Each hook function runs in its own `condition-case`.** An error goes to a message. It never turns a committed or cancelled run back into `needs-user`, and it never stops the other hook functions.
- **The batch function on the hook** (`claude-code-ide-handover--batch-on-status`) only finds the batch of the run and schedules a timer with no delay. All work of the batch runs in that timer, outside the stack of the handover.

### Stale timers

A handover can end and schedule the advance of its batch. Then, before that timer runs, the batch can be dropped and replaced (the command runs again) or stopped. The old timer must never advance or remove the new batch.

1. When the hook function schedules the advance, it captures the batch object itself and the expected handover ID (the ID of the run): `(run-at-time 0 nil #'claude-code-ide-handover--batch-step BATCH HANDOVER-ID)`. It keeps the timer in the batch.
2. `claude-code-ide-handover--batch-step` acts only when all three are true. Else it does nothing, and returns.
   - The worktree still maps to that exact batch: `(eq (gethash KEY claude-code-ide-handover--batches) BATCH)`.
   - The batch is not `dead`.
   - The current handover ID of the batch is still HANDOVER-ID.
3. The step clears the current handover ID before it starts the next source, and sets the new ID after the start. So a second callback for the same handover (a duplicate hook call, or two timers) finds another ID, and does nothing.
4. A drop, the end of the batch, and `claude-code-ide-handover-worktree-stop` (when the batch ends at once) mark the batch `dead`, cancel its pending timer, and remove it from the table only when the table still maps the worktree to it (`eq`). So an old batch never removes a new one.
- A final save that fails (for example a busy lock) does not run the hook. The batch then waits. `claude-code-ide-handover-worktree-stop`, or the next command in the worktree (a stale batch), ends it.

### The rules after each handover

The timer of the batch (`claude-code-ide-handover--batch-step`) decides from the status and the reason:

| Status and reason | Action |
|---|---|
| `committed` | Record the target. Start the next source. |
| `cancelled` with `busy`, `not-idle` or `recovered-before-stop` (an automatic cancel before the stop; the source stays current) | Record the source as skipped, with the reason. Start the next source. |
| `cancelled` with `user-cancelled` | Stop the batch. |
| `needs-user` | Wait. Show one message, one time for each handover: "Handover batch waits at LABEL: REASON; M-x claude-code-ide-handover-resolve". |

- The code never sets the status `failed`. An error in a step gives `needs-user` with the reason `step-failed` (`claude-code-ide-handover--guarded`), so the batch waits there too.
- **The start of the next source:**
  1. Stop when `stop` is set.
  2. **The confirmed set.** (Changed in the implementation: no separate check. Step 3 gives `:allow-others` the list CONFIRMED plus the sources and the targets of the batch, so the preflight is the one owner, and a new session gives the refusal `other-instance`, which stops the batch with its message.) Compute `--other-writers` of the source, without the sources and the targets of the batch. Stop when it has an ID that is not in CONFIRMED. The message names that session. The person runs the command again, and sees the new session in the question.
  3. Call `claude-code-ide-handover-session` with `:method`, `:context`, `:interrupt`, `:continue`, `:allow-others t`, `:interactive nil`, and `:batch-next` (the sources after this one; see item 6).
  4. A refusal with `busy` or `not-running`: record the source as skipped, and start the next source. Any other refusal: stop the batch.

| Option | Decision | Why |
|---|---|---|
| Stop at every cancel | Rejected | An automatic cancel (`busy`, `not-idle`) leaves the source current and safe. The other sources do not depend on it. |
| Skip at every cancel | Rejected | A cancel of the person usually means "stop". |
| Skip at automatic cancels, stop at `user-cancelled` | Chosen | The batch goes as far as it safely can, and the person keeps the brake. |
| Wait at `needs-user` | Chosen | The run is not finished. The worktree stays held, so the next handover cannot start anyway. |

### The result

- One message for each start: "Handover batch in WORKTREE: 2 of 3: LABEL -> TARGET-PROVIDER (handover ID)".
- One message at the end, with three lists:
  - Handed over: SOURCE -> TARGET, ...
  - Skipped: LABEL (REASON), ...
  - Stopped at, and not started: LABEL (REASON); LABEL, ...
- The end message of a batch with skipped or not-started sources adds: "M-x claude-code-ide-handover-worktree hands over the rest."
- The command returns the result of the first `claude-code-ide-handover-session`.
- Each handover has its own status (`claude-code-ide-handover-status`).

### Recovery after a crash

The batch lives in memory. A crash loses it. The person does these steps, in this order:

1. `M-x claude-code-ide-handover-recover` continues the handover that ran. It runs by itself when the registry mode turns on (`claude-code-ide-handover-recover-at-start`).
2. `M-x claude-code-ide-restore-sessions` starts the other sources again. The restore leaves out the entries that a handover holds.
3. `M-x claude-code-ide-handover-worktree` hands over the rest. It offers only the live instances that are not of the target provider.

- A source whose handover was cancelled after its stop is stopped, not live. The batch does not offer it. Start it again with `M-x claude-code-ide-reopen-session` first.

## 4. The stray scan with other sessions

- PR #37 covers the sessions of this Emacs:
  - The scan tags a process in the CLI tree of a live instance of this Emacs with `:instance-id` (`claude-code-ide-process--instance-trees`).
  - It tags a process in the CLI tree of a live MCP session of this Emacs with `:session-id`, also for a session without a descriptor (`claude-code-ide-process--session-trees`).
  - `claude-code-ide-handover--relevant-strays` drops both tags, except for the source and the target of the run.
  - A process whose folder has its own `.git` below the worktree is no stray (`claude-code-ide-process--own-tree-p`).
  - `other-instance` counts live MCP sessions without a descriptor, and instances and sessions in plain subfolders.
- With the targets of a batch: each target is a live instance of this Emacs, so its processes have `:instance-id`, and no later handover of the batch lists them.
- Another Emacs: v1 changes no code in the scan. The preflight refuses (see "Scope of v1").

## 5. The lock while a handover runs

| Rule of the issue | The code today | Design |
|---|---|---|
| The other instances get no queued prompt from the handover. | True. The hold is only for the source (`claude-code-ide-control-hold` in `claude-code-ide-handover--quiesce` and in the recovery). `claude-code-ide-control-move-inbox` moves only source to target. The continue prompt and the recovery pointer go only to the target. | No change. A test guards it. |
| The inbox of the other instances works during the handover. | True. `claude-code-ide-control--submit-new` holds only an instance in `claude-code-ide-control--held`. | No change. The same test guards it. |
| A launch during the handover waits. | `claude-code-ide-control-launch` and `claude-code-ide-control-resume` call `claude-code-ide--start-session`. `claude-code-ide-handover--guard-start` signals `user-error`. `claude-code-ide-control--start` turns it into `start-failed`. | Every start path reports `handover-running` with the handover ID. No wait. |

### The launch result

- One small change:
  - `claude-code-ide-control.el` defines `claude-code-ide-worktree-held`, a child of `user-error`, with the data `(HANDOVER-ID WORKTREE STAGE)`.
  - `claude-code-ide-handover--guard-start` signals it in place of its `user-error`.
  - Changed in the implementation: the error message is "A handover holds the working tree; no other instance starts there until it ends". An `M-x` start shows it with the data, for example `...until it ends: "6e34...", "/x/app/", target-started`. `claude-code-ide-control--start` builds its own `:message` from the data.
  - `claude-code-ide-control--start` gets one clause before `(error quit)`: `(:status error :reason handover-running :instance-id ID :handover-id HANDOVER-ID :message TEXT)`.
- So every start path through `claude-code-ide-control--start` (launch, resume) gives the same result. `M-x` starts show a plain error, because the parent is `user-error`.
- A coordinator polls `claude-code-ide-handover-status` with that ID, and launches again after the end.

| Option | Decision | Why |
|---|---|---|
| The launch waits in memory, and starts after the commit | Rejected for v1 | It needs a new result status, a list of deferred starts, a cancel, and a rule for a crash, which loses the start without a trace. |
| The launch waits in the registry | Rejected | It is a queue in the registry (item 2) for launches. |
| A distinct refusal with the handover ID | Chosen | One clause. The coordinator knows that the refusal is temporary, and what to poll. |

## 6. The edit-clash notice

### What the workspace state has already

`claude-code-ide-transcript-workspace-state` gives the document `git status --porcelain`, the diff stat since the start commit of the source, the untracked files, and the log. These are the changed files of the issue. The design reuses them and adds no Git call.

### The new part

- A new key `:others` of `claude-code-ide-transcript-handover-document`: a list of strings, one line for each other session.
- A new `claude-code-ide-transcript--render-others (LINES)` renders the part. It is in the fixed part right after the workspace state, so the budget never cuts it.
- Without lines, the document has no such part. The documents of a worktree with one instance stay as they are.

```text
## Other sessions in this worktree

These sessions ran in this worktree when Emacs wrote this document. They can change files at the same time as you.

- plan (claude, 5afe576e-...): idle; handed over by this batch next
- coder (codex, 01a1eb92-...): working

The owner of each change in the workspace state above is not known. It can be yours (the earlier conversation), or the work of one of these sessions.
Before you write a file that another session can also write, and before you revert or commit a change that you did not make, coordinate with that session or ask the user.
```

- **Where the lines come from:** `claude-code-ide-handover--document-text` calls `claude-code-ide-handover--writer-lines` on `claude-code-ide-handover--run-writers (RUN)`.
- **The batch note.** A new key `:batch-next` of `claude-code-ide-handover-session` (a list of instance IDs) goes to a new in-memory slot of the run. Each line of such an ID ends with "; handed over by this batch next". The registry does not keep it: after a crash the batch is gone, and a rewrite of the document lists those sources as plain sessions.
- **`--run-writers`** is the same rule as `--other-writers`, for a run. At the document step the source descriptor no longer exists, so the rule cannot take an instance.
  - The three helpers (`--other-instances`, `--other-sessions`, `--other-emacs-entries`) change to take a worktree key and a list of IDs to leave out, in place of an instance.
  - `--other-writers (INSTANCE)` passes the key and the IDs of INSTANCE (its instance ID and its session ID).
  - `--run-writers (RUN)` passes the worktree of the run, and the source ID, the target ID and the source session ID of the run.
- The list is computed when Emacs writes the document, also at a recovery that writes it again.

## Changes by file

| File | Change |
|---|---|
| `claude-code-ide-handover.el` | (Changed in the implementation: small helpers keep each rule and text in one place: `--instance-key`, `--own-ids`, `--writers`, `--check-worktree`, `--check-no-batch`, `--read-worktree`, `--read-target`, `--instance-fork-id`, `--interruptible-p`, `--read-context-note`, `--continue-key`, `--untrusted-message`.) `:allow-others` and `:batch-next`; the preflight argument and the separate refusal for another Emacs; `--confirm-others`; `--writer-lines`; `--run-writers` and the three helpers with a key; `:others` in `--document-text`; `:handover-id` in the `handover-running` result; the new error in `--guard-start`; NO-SAVE, the slot `ended` and `--status-functions` in `--finish`; the skip of `claude-code-ide-handover-resolve` through `--finish`; the hook in `--needs-user`; the eighth argument of `claude-code-ide-handover`; the checks, `C-u` and the question in `--read-args`; the question in `--offer-request`; `allow_others` in `--mcp-handover` and the tool spec; the batch command, `--read-batch-args`, `--batches`, `--batch-on-status`, `--batch-step`, and `claude-code-ide-handover-worktree-stop`. |
| `claude-code-ide-transcript.el` | `:others` of `claude-code-ide-transcript-handover-document`; `--render-others`. |
| `claude-code-ide-control.el` | `claude-code-ide-worktree-held`; one clause in `claude-code-ide-control--start`. |
| docs | handover.md (the command, the checks, the question, `:allow-others`, the refusal table, "One writer for each worktree", the batch, the coordinator tools); handover-document.md (the new part); api-control.md (`handover-running` of launch and resume). |

## Overlap with feat/mailbox (issue #41)

- The mailbox branch adds a `key` field to the control records, the keys `:key` and `:defer` of `claude-code-ide-control-submit`, and `claude-code-ide-control-find-key-in-chain`. This design uses none of them.
- **The same file, other functions:** this design changes `claude-code-ide-control--start` and adds `claude-code-ide-worktree-held` near it. The mailbox changes `claude-code-ide-control-submit`, `claude-code-ide-control--submit-new`, the record struct and `claude-code-ide-control-move-inbox`. A merge conflict is unlikely; the second branch to merge rebases.
- **The same behavior:** a mailbox message to the source of a handover queues under the hold, and the commit moves it with its `key`. A message to another instance of the worktree goes out as usual during the handover. The test of item 5 checks that with `claude-code-ide-control-submit` without `:key`, so it does not depend on the mailbox.
- `api-control.md`: both branches edit it. The mailbox edits the record fields and `submit-prompt`; this design edits the reasons of `launch` and `resume`.

## Test plan

- The tests follow CLAUDE.md:
  - No fixed sleeps. The handover tests run the stub timers with `claude-code-ide-handover-tests--run-timers`. A test with a real process waits with `claude-code-ide-tests--wait-until`.
  - Every test runs in the isolated folder of `claude-code-ide-tests--isolate-run`, and inside `claude-code-ide-handover-tests--with`, which gives the worktree and the stub providers `cci-test-a` and `cci-test-b`.
  - Questions are stubs of `y-or-n-p`, `read-multiple-choice`, `read-string`, `completing-read` and `completing-read-multiple` with `cl-letf`. Each stub records its prompt.
- The file is `tests/claude-code-ide-handover-tests.el`, except where the table says otherwise.

### Item 1: the question and the key

| Test | Asserts |
|---|---|
| `claude-code-ide-test-handover-asks-about-other-instances` | A source and another idle instance in the worktree. `--read-args` asks the question; its prompt has the label, the provider and `idle` of the other instance. After `y`, the handover runs. Without the other instance, no such question comes. (Issue test 1.) |
| `claude-code-ide-test-handover-other-instances-no` | After `n`: `user-error`, no handover record in the registry, and no question after this one. |
| `claude-code-ide-test-handover-prefix-skips-other-question` | With `current-prefix-arg` `(4)`, the question does not come, and the handover runs. (Issue test 2.) |
| `claude-code-ide-test-handover-checks-before-questions` | A worktree that a handover holds, and a worktree with a live entry of another Emacs: `--read-args` and `--read-batch-args` signal `user-error` before any question stub is called. |
| `claude-code-ide-test-handover-other-emacs-refused` | A live entry of another Emacs in the worktree (`claude-code-ide-session-registry-other-emacs-p` stubbed): `other-instance` with `:allow-others t`; the handover runs with `:force t`. |
| `claude-code-ide-test-handover-writer-lines` | One line for an instance of this Emacs with `failed/quota-limit`, one for an MCP session without a descriptor (`claude-code-ide-handover-tests--session`), and one for a registry entry of another Emacs, with its Emacs PID. |
| `claude-code-ide-test-handover-allow-others-keeps-busy` | `:allow-others t`: a source in `waiting-for-task` is refused with `busy`. A source that reaches `waiting-for-task` in the quiescing is cancelled with `busy`, and the stop does not run. |
| `claude-code-ide-test-handover-request-asks-about-others` | `claude-code-ide-handover--offer-request` with another instance in the worktree asks both questions. Yes to both starts the handover; `n` to the second starts nothing. |
| `claude-code-ide-test-handover-mcp-allow-others` (`tests/claude-code-ide-mcp-routing-tests.el`) | The tool `claude-code-ide-control-handover` with `allow_others` true calls the operation with `:allow-others t` and `:force nil`; with `allow_others` false or absent, `:allow-others nil`. |
| `claude-code-ide-test-handover-two-writers` (changed) | Also: without a key, another instance gives `other-instance`; with `:allow-others t` or `:force t`, the handover runs. |

### Item 2: one at a time

| Test | Asserts |
|---|---|
| `claude-code-ide-test-handover-second-request-names-holder` | A second `claude-code-ide-handover-session` in the worktree (with `:allow-others t`) gives `handover-running` with the `:handover-id` of the first. After the first commits, the same call runs. (Replaces issue test 3.) |

### Item 3: the batch

| Test | Asserts |
|---|---|
| `claude-code-ide-test-handover-worktree-three` | Three idle `cci-test-a` instances, a batch to `cci-test-b`. At each point, at most one handover is unfinished. Each starts only after the previous one commits. At the end, no live `cci-test-a` instance is in the worktree, and three `cci-test-b` targets run. Each document has the context note of its own source. (Issue test 4.) |
| `claude-code-ide-test-handover-worktree-stops-at-user-cancel` | The person cancels the second handover (`user-cancelled`). The third never starts. The end message lists the handed-over source, the stop with its reason, and the source that was not started. |
| `claude-code-ide-test-handover-worktree-skips-automatic` | The second source is cancelled with `busy` in its quiescing, and the third is refused with `not-running`: the batch skips both and hands over the fourth. The end message lists the two skipped sources with their reasons. |
| `claude-code-ide-test-handover-worktree-waits-for-person` | The first handover gets `needs-user` (strays). The second does not start. The wait message comes one time, also after a second `needs-user` of the same handover. After `claude-code-ide-handover-resolve` with `end`, the first commits, and the second starts. |
| `claude-code-ide-test-handover-worktree-method-per-chain` | With `fork`: a source whose chain has a `cci-test-b` leg forks; a source without one starts fresh. |
| `claude-code-ide-test-handover-worktree-questions-once` | `--read-batch-args` asks the target, the sources, the method, continue and the Codex trust one time each, and the context one time for each source. The interrupt question comes only when a selected source is `working`. The others question lists only the sessions outside the batch. No handover of the batch calls a question stub. |
| `claude-code-ide-test-handover-worktree-rest-only` | After a stop, the sources of the command are only the live instances of the worktree that are not of the target provider. |
| `claude-code-ide-test-handover-worktree-one-per-worktree` | A second batch command in the same worktree is refused. A batch whose current run is gone, final, or owned by another Emacs is dropped, and the new batch starts. |
| `claude-code-ide-test-handover-worktree-stale-timer` | The first handover commits, and the stub timer list holds the advance of batch A. Before that timer runs, the command drops A and starts batch B in the worktree. Then the old timer runs: B keeps its current handover ID and its sources, the table still maps the worktree to B, and no extra handover starts. A second run of the same old callback also does nothing. The stop command before the old timer runs gives the same result. |
| `claude-code-ide-test-handover-worktree-stop-command` | `claude-code-ide-handover-worktree-stop` during the first handover: that handover commits as usual, and no other handover starts. The end message lists the rest as not started. |
| `claude-code-ide-test-handover-worktree-new-session-stops` | A new instance starts in the worktree after the questions. Before the next handover, the batch stops, and the message names the new session. The confirmed sessions and the targets of the batch do not stop it. |
| `claude-code-ide-test-handover-worktree-document-names-next` | The document of the first handover marks the second and the third source with "handed over by this batch next". |

### The status hook

| Test | Asserts |
|---|---|
| `claude-code-ide-test-handover-status-hook-once` | The hook runs one time for a commit, one time for a cancel, and one time for the skip of a source without a registry entry (through `--finish` with NO-SAVE). It runs after the save and after the release (the stub sees the saved status and no hold). It does not run when the final save fails. It runs at each entry into `needs-user`. |
| `claude-code-ide-test-handover-status-hook-error` | A hook function that signals: the run stays `committed` (and `cancelled` in a second run), the next hook function still runs, and a message names the error. |

### Item 5: the lock

| Test | Asserts |
|---|---|
| `claude-code-ide-test-handover-others-keep-their-inbox` | Another idle instance B in the worktree. During the quiescing, B is not held, and a submit to B goes out at once. After the commit, the inbox of B has no record of the handover (no `handed-over` record, no `handover-continue:` record). |
| `claude-code-ide-test-handover-launch-names-holder` | `claude-code-ide-control-launch` in the held worktree gives `handover-running` with the `:handover-id`, and nothing starts. `claude-code-ide-control-resume` of an entry there gives the same. A direct start signals a `user-error`. After the commit, the launch starts. (Replaces issue test 6.) |

### Item 6: the notice

| Test | File | Asserts |
|---|---|---|
| `claude-code-ide-test-transcript-document-other-sessions` | `tests/claude-code-ide-transcript-tests.el` | With `:others`, the part comes right after the workspace state, with each line and the text about unknown owners. A small budget does not cut it. Without `:others`, the document has no such part. |
| `claude-code-ide-test-handover-document-names-others` | handover tests | A handover with `:allow-others t` and another instance B: the document file has the line of B. It does not list the source or the target. |
| `claude-code-ide-test-handover-run-writers-after-stop` | handover tests | `--run-writers` works after the source descriptor is unregistered, and a recovery at `document-written` writes the list again from the instances that run then. |

**The count:** 29 new tests: 9 for item 1 (1 in the MCP routing tests), 1 for item 2, 12 for item 3, 2 for the status hook, 2 for item 5, and 3 for item 6 (1 in the transcript tests). One test of today changes: `claude-code-ide-test-handover-two-writers`. It stays green otherwise, because the new error is a `user-error`.

Changed in the implementation:

- Two more tests of today change, because the command gets its eighth argument: `claude-code-ide-test-handover-continue-interactive` reads CONTINUE with `nth 6` (it was the last element), and `claude-code-ide-test-handover-request-tool` expects the four new nil arguments of the call.
- The test helper `claude-code-ide-handover-tests--preflight-reason` passes the new preflight argument, and `claude-code-ide-handover-tests--with` binds `claude-code-ide-handover--batches` to a new table.
- The skip of a source without a registry entry is part of `claude-code-ide-test-handover-status-hook-once`.

## Changes after the code reviews

Changed in the implementation, after three code reviews:

- **Detached work of other sessions.** The scan tags a process with `:instance-id` also when it left the CLI tree (a `nohup ... &` re-parents to PID 1): its group is in the recorded groups of a live instance, or it is a recorded member with the same start time (`claude-code-ide-process--instance-trees`). So `end` never signals it.
- **The final save before the advance.** `--batch-step` takes a committed or cancelled run only when its `ended` flag is set. A notification of `needs-user` only waits.
- **Errors in the start.** An error at the start of a source ends the batch with the usual report; the source gets the error text.
- **One worktree.** Every live source must be in the worktree of the first one; else the command refuses before any change.
- **A stop or a drop between the end of a handover and the next step** records that handover through `--batch-step` (`--batch-close`), and starts nothing. The report and the drop message name that source.
- **A missing registry entry** runs the status hook as `--needs-user` does, so the batch shows its wait message. The stop command also ends a batch whose current handover waits at `needs-user`; that handover stays for `claude-code-ide-handover-resolve`.
- **The Codex hook trust.** A trust of the managed hooks holds 60 s, and a trusted result without `:cache` is not stored. So a later source of the batch can get `hooks-not-trusted`. The batch skips such a source with that reason (fail safe), and goes on. The trust check is not weakened.
  - Changed after the user review: the batch keeps such a source in a retry list. When no other source is left, it tries each one again, one time, in order, through the same step (same answers, no question, the same trust check). The background trust check that a cache miss starts may have an answer then. A second refusal skips the source with `hooks-not-trusted`; no other reason gets a retry. The stop command and the stale-timer guards also hold in the retry, and the end message marks the sources that the retry handed over.
- **One owner for each text:** `claude-code-ide-control-held-message` (a handover holds the worktree) and `claude-code-ide-handover--other-emacs-message`.

## Left out

| Part | Why |
|---|---|
| Handovers next to instances of another Emacs (the old item 4) | A safe scan needs three things: an atomic reservation of the worktree across Emacs processes, the identity of each root process with its start time, and a rule for a CLI whose owner Emacs cannot be confirmed. A tag of the CLI tree of each entry is not enough. Until then, the preflight refuses, and only `:force` goes past it, as today. |
| A queue of handover requests (item 2) | The batch is its only real user, and orders itself. A queue in the registry costs a schema field, recovery rules and a cancel. |
| A launch that waits (item 5) | A distinct refusal with the handover ID lets the coordinator wait. A waited start needs its own queue and crash rule. |
| The key `l` (list) of the question | The list is always in the question. |
| The state of an instance in another Emacs | That case is a refusal in v1. |
| `:force` in the batch | It ends background tasks. Such a source is skipped, and handed over alone, with the busy question. |
| A status command of the batch | Each handover has its status. The messages of the batch say where it is. |
| A batch that survives a crash | The current handover recovers. A second run of the command hands over the rest (see "Recovery after a crash"). |
| A check of every source before the batch starts | Each handover runs its own checks at its turn. A dry run copies the checks of `claude-code-ide-handover-session`. |
| A new Git call for the notice | `claude-code-ide-transcript-workspace-state` has `git status --porcelain` already. |

## Open questions

| # | Question | Recommendation |
|---|---|---|
| 1 | Must a launch during a handover wait and start after the commit, as the issue says, or is the refusal `handover-running` with the handover ID enough? | The refusal. Add a wait only when a coordinator cannot poll. |
| 2 | Is a queue for single handover requests needed outside the batch? | No, not for v1. |
| 3 | The sources of the batch: in the order of `claude-code-ide-instances`, or the idle ones first? | The order of `claude-code-ide-instances`, also when the person chooses some of them in the list. |
| 4 | When must handovers next to instances of another Emacs come (the reservation, the root identity, and the unconfirmed owners)? | After v1, in its own issue, when a coordinator runs two Emacs on one worktree. |
