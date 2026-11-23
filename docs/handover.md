# Handover

A handover moves the work of one instance (the source) to a new native conversation (the target) of the same provider or of the other provider (plan §4.7).
The usual reason is a quota limit of the source. So the source never runs one more turn: the target gets the handover document, and writes a state summary in its first turn.

- Code: `claude-code-ide-handover.el`.
- Tests: `tests/claude-code-ide-handover-tests.el`.
- The document: [handover-document.md](handover-document.md).
- The control operations and the inbox: [api-control.md](api-control.md).
- The registry: [session-schema.md](session-schema.md).
- The process stop: [process-tree.md](process-tree.md).

## Start a handover

### The command

- `M-x claude-code-ide-handover` hands over the instance of the current buffer, or an instance that you choose.
- **The checks come before any question** (`claude-code-ide-handover--check-worktree`): a handover that holds the worktree gives a `user-error` with its ID, and a live instance of another Emacs in the worktree gives a `user-error` with its key and the process ID of its Emacs.
- **The question about other sessions** comes first, when other live instances or MCP sessions of this Emacs run in the worktree (`claude-code-ide-handover--confirm-others`):

  ```text
  2 other sessions run in the worktree /Users/me/src/app/:
    plan (claude, 5afe576e-...): idle
    coder (codex, 01a1eb92-...): failed/quota-limit
  They go on with their work. The handover does not stop them or their processes.
  The target gets this list.
  Hand over anyway? (y or n)
  ```

  - `y`: the handover goes on with `:allow-others` set to the IDs that the question showed. A session that starts after the question still refuses the handover (`other-instance`). `n`: `user-error` "Handover not started"; no other question comes, and the registry gets no record.
  - **`C-u M-x claude-code-ide-handover`** skips the question. When other sessions run, it gives `:allow-others` with their IDs; without them, nil. `H` in the status buffer reads the prefix argument the same way.
- Then it asks for the target provider (default: another provider), the method, and optional context text for the target.
- **The method question** comes only when a fork is possible: the chain has a conversation of the target provider (`claude-code-ide-handover--read-method`).
  - `fork` (the default: `RET` or `f`): the target goes on from the last conversation of its provider in the chain, with its full history, and gets the document. For example, a handover back to Claude Code continues the earlier Claude Code conversation.
  - `new` (`n`): a new conversation that knows only the document. This is the method `fresh`.
  - Any other key is refused, and the question asks again. `?` shows the choices.
  - A fork gets a new conversation ID. The earlier conversation stays unchanged.
- When the source is busy, it asks whether to interrupt it. Else the handover waits until the source is idle.
- When subagents or background tasks run, or the state of the source is unknown (`disconnected`), it asks for a confirmation (`yes-or-no-p`, because background tasks end). That yes gives `:force`.
- For a Codex target whose status hooks are not trusted, it asks for the trust (`claude-code-ide-codex-prepare-trust`).
- With `claude-code-ide-handover-continue` at `ask` (the default), the last question is whether the target goes on with the task after the commit (see "The target goes on"). It comes with the other questions, before the handover starts, never later from a timer. The answers: `y` yes, this time; `n` no, this time; `a` always (saved with `customize-save-variable`); `v` never (saved). When the save fails, the value holds in this Emacs.
- In the status buffer `*Coding Agents Sessions*`, the key `H` offers a handover of the session on the line. Without a session on the line, it offers the first session at a quota limit (`failed/quota-limit`).
- Emacs never starts a handover by itself.
- `claude-code-ide-handover` takes `ALLOW-OTHERS` as its eighth optional argument, after `CONTINUE`.
- To hand over all instances of a worktree, see "Several instances in one worktree".

### The function

```elisp
(claude-code-ide-handover-session INSTANCE-ID TARGET-PROVIDER
  &key METHOD CONTEXT INTERRUPT FORCE ALLOW-OTHERS REQUEST-ID INTERACTIVE CONTINUE BATCH-NEXT)
```

| Key | Value |
|---|---|
| `:method` | `fresh` (default): a new conversation. `fork`: fork the latest conversation of the target provider in the chain. Both get the document. The default of this operation stays `fresh`, so that a coordinator chooses a fork explicitly; the question of `M-x claude-code-ide-handover` has `fork` as its default. |
| `:context` | Text of the coordinator for the document, or nil. It is kept in the private file `.handover/<id>-context.md` (mode 0600), whose path and hash the registry record holds, so that a rewrite of the document after a crash still has it. |
| `:interrupt` | Non-nil: send Escape to a busy source one time. Else wait until the source is idle. |
| `:force` | Non-nil: go on while subagents or background tasks run, and while other instances run in the worktree (also of another Emacs). |
| `:allow-others` | `t`: go on while other live instances or MCP sessions of **this** Emacs run in the worktree, and nothing more. A list of IDs allows only those writers; any other one gives `other-instance`. The command and the batch give a list; the control API and the MCP tool (`allow_others`) give `t`. Subagents or background tasks still give `busy`, and an instance of another Emacs still gives `other-instance`. It is a separate key because `:force` also lets the quiescing stop a source that reaches `waiting-for-task`, which ends its background tasks. The run does not keep it: only the preflight reads it. |
| `:request-id` | A string that the caller chooses. A second call with a known request ID returns the current result of the first call, with `:duplicate t`, and starts nothing. |
| `:interactive` | Non-nil when a person asks in Emacs. Then Emacs asks that person about stray processes and about the Codex hook trust. A coordinator call gets the status `needs-user`, or the refusal `hooks-not-trusted`, instead. |
| `:continue` | `t`: after the commit, the target gets the continue prompt. `nil`: it gets nothing more. Without the key, `claude-code-ide-handover-continue` decides, and its value `ask` counts as `always`: this function never asks. |
| `:batch-next` | The instance IDs that a batch hands over after this one. The document marks them (see "The document"). The registry does not keep it. |

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
| `handover-running` | Another handover holds the worktree of the source. The result also has `:handover-id`, the ID of that handover. There is no queue: poll `claude-code-ide-handover-status` with that ID, and call again after its end. |
| `target-unavailable` | Preflight: the `detect` operation of the target provider does not find its CLI. |
| `other-instance` | Preflight, two cases. (1) A live instance of another Emacs that runs is in the worktree (an open or pending registry entry of that Emacs); the message names it and the process ID of its Emacs. Only `:force` goes on, also with `:allow-others`: the stray scan of this Emacs cannot see the process tree of that instance. (2) Another live instance of this Emacs runs in the worktree, or a live MCP session of this Emacs without an instance descriptor. Give `:allow-others` or `:force` to go on. In both cases, an instance or a session in a subfolder counts when the subfolder is no worktree of its own. |
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
| `quiescing` | The inbox delivery to the source is held (`claude-code-ide-control-hold`): no queued prompt goes to it from now on. When the inbox sent a prompt to the source whose acknowledgement did not come, the status events are drained, and the stop waits up to `claude-code-ide-handover-ack-wait` (10 s) for it. Wait until the source is idle, failed (for example at a quota limit), or waits for an answer to a question. With `:interrupt`, interrupt it one time. Subagents or background tasks cancel the handover, unless it is forced. After `claude-code-ide-handover-quiesce-timeout` (600 s), the handover is cancelled. When the source is quiet, the handover reads its screen for an unsent draft (see "An unsent draft" below) before the stop. |
| `source-stopped` | `claude-code-ide-process-stop-later` ends the source and its process tree, with the soft end of its provider, and then scans the worktree. The handover goes past this stage only when the source no longer runs in this Emacs (see "The source must end" below), whatever the stop result says. |
| `document-written` | `claude-code-ide-transcript-handover-document` makes the document. Emacs writes it to `<worktree>/.handover/<id>.md` (mode 0600) and records its hash. Emacs adds `.handover/` to the Git exclude file of the worktree. |
| `target-started` | Never while the source still runs in this Emacs, also not at a recovery. The target ID is saved first; while the registry is busy, the start waits. The target starts with the provider's launch, or its fork, with the start prompt (below). Its chain is saved with its own leg pending; while the registry is busy, that save is tried again every second. |
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
  - `:others`: one line for each other writer in the worktree (`claude-code-ide-handover--writer-lines` on `claude-code-ide-handover--run-writers`): the other instances and MCP sessions of this Emacs, and with `:force` the instances of another Emacs. The source, its session and the target do not count. The list is made when Emacs writes the document, also at a recovery that writes it again. A line of a source in `:batch-next` ends with "; handed over by this batch next". Without other writers, the document has no such part.
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

## An unsent draft

The user may have typed a prompt into the source without sending it. The stop would lose it, and the document would not carry it.

- **The check.** In the quiescing, when the source is quiet and before the stop, the handover reads the terminal screen of the source (`claude-code-ide-handover--source-draft`). It uses the screen read of the Codex dialogs, which knows the terminal size of vterm, eat and ghostel. It runs once; its result is kept in the run.
  - **Claude Code:** the text in the input box, after the prompt marker `❯` (or `>` in the older box). The reader finds the box by its geometry, not by the last two rule lines:
    - The bottom rule is the last rule at the left edge of the screen. The rows under it are the status lines.
    - The top rule is the rule at the left edge above it. It can hold the session title, as in `──── my title ─`. The older box has `╭─╮` over `╰─╯`.
    - The rows of a draft never start at the left edge: Claude Code indents its wrapped and new lines, and the older box has `│` in front. So a divider line (`────`) in the draft is the user's text, not a rule of the box.
    - Only the older box has the side borders `│`, so only its rows lose them. In the borderless box, a `│` of the user's text stays.
    - A sent prompt with `❯` above the box, and the status lines under it, are no part of it.
    - **The IDE context chip** that Claude Code puts in front of the draft, such as `[⧉ In foo.el]` for the file that is open in Emacs, is not the user's text. It is left out, and kept as information (`draft_context`; the note "(written while foo.el was open)").
  - **Codex:** the text of the composer. The reader finds the bottom of the composer first:
    - The last row of the screen is the footer row (the model and the folder), with an empty row above it.
    - The composer starts at the last row above it that starts with `›`. Every row up to the empty row belongs to it, also its empty rows.
    - The wrapped and new lines of the composer are indented. A row at the left edge between the `›` row and the footer is part of the conversation, so that `›` row is a sent request: the read is unsure, and it does not search further back.
    - Without the empty row and the footer row under it, the read is unsure.
  - **Dialogs.** A dialog on the screen gives unsure, for both CLIs. The reader knows a dialog by its structure, not by the text of a choice:
    - the selection marker (`❯` or `›`) on a numbered choice row;
    - another numbered row in its list;
    - at the bottom of the screen, the control row of the dialog (such as `Esc to cancel`, `Press enter to confirm or esc to cancel`, `enter continue · esc quit`, `option 1/2 | enter to submit`) or the choice list itself.
    - So a draft that starts with `1. ` is a draft: under the input box or the composer, the bottom rows are the status lines or the footer row.
  - **Paragraphs and wraps.** An empty row in the input ends a paragraph, and the paragraphs join with an empty line. The rows of a paragraph join with one space, for both CLIs: a screen cannot tell a soft wrap at its width from a new line that the user typed, and the indents of the wraps differ (2 and 4 spaces on a real Claude Code screen).
  - **Placeholders** of an empty box are no draft (`claude-code-ide-handover-draft-placeholders`): Claude Code's `Try "..."` suggestions, and Codex's "Ask Codex to do anything" and its other suggestions.
  - **Unsure.** A screen without an input box, a dialog, a box without the prompt marker, a source without a terminal buffer, or a provider without a reader is unsure. The record says so (`draft_decision` `unsure`, with `draft_unsure`).
  - **Maybe a draft.** An unsure read can still find the input region: a box without the prompt marker, a box whose top is above the screen (a long draft), or a composer without the footer row. When that region has text that is not a placeholder, the read gives it as raw text (`:raw`).
    - With `ask`, the handover does not go on. It asks the person, and shows the raw text, labelled as maybe a draft. A coordinator call gets `needs-user` / `unsent-draft`, with the raw text in `:draft` and `:draft-maybe` t. The choices are the same: carry, drop, cancel.
    - With `carry`, `drop` or `refuse`, the handover goes on as with no draft (`draft_decision` `unsure`), and the record keeps the raw text (`draft_raw`).
    - An unsure read without raw text goes on as with no draft, with every value of the option.
- **The option `claude-code-ide-handover-unsent-draft`:**
  - `ask` (the default): an interactive handover shows the draft and asks before the stop. A coordinator call gets `needs-user` with the reason `unsent-draft`, the stage `quiescing`, and `:draft` in its status. The choices: `carry`, `drop`, `cancel` (see the table below).
  - `carry`: the document gets the part "The user's unsent prompt (not sent to the source)", with the draft quoted as data, and the instruction to treat it as the user's next request after the state summary. With the continue prompt, the target takes it up.
  - `drop`: go on without it. The record keeps its text (`draft_text`, `draft_decision` `drop`), so nothing is lost for good.
  - `refuse`: cancel the handover with the reason `unsent-draft`; the source keeps running with its draft.
- **The record** keeps `draft_text`, `draft_decision` (`none`, `unsure`, `carry` or `drop`), `draft_unsure`, `draft_context`, `draft_raw` (the raw text of an unsure read) and `draft_maybe` (true when the draft is that raw text). The status has `:draft`, `:draft-decision`, `:draft-context`, `:draft-raw` and `:draft-maybe`, and the question shows the note of the chip. A crash while the decision waits is a crash before the stop: the recovery cancels the handover (`recovered-before-stop`), and the record and the status keep the draft.

## Stray processes

### The source must end

- **The live check.** The source counts as running when its descriptor is live and its terminal process runs. The terminal process is the one that a process-tree stop knows (`claude-code-ide-process--terminal-process`: the process of its buffer, else the one that its MCP session keeps). A live descriptor without a known terminal process counts as running, because nothing shows that its CLI ended.
- **When it runs.** The check runs after each clean scan (also after the stop), before the document step enters `target-started`, and before each start of the target. So a recovery never starts a target next to a live source, for example after the source was restored.
- **The reasons:**
  - `source-pid-unknown`: the process-tree stop could not end or check the source CLI, because its process ID is unknown (the stop gives `error` with "the process ID of the CLI is unknown"). The message says that the source CLI may still run.
  - `source-still-running`: the source still runs after the stop or the scan. The result of the stop or the scan can be clean or an `error` (for example, `ps` or `lsof` failed). A failed scan of a live source gives this reason, not `scan-failed`, so `go` is not offered. The handover never goes on silently.
- Both stop the handover at its stage, with its next step kept, until a person chooses `end`, `wait` or `cancel` (the table below).


- The stop reports processes that still run in the worktree (`:status strays`).
  - A process in another repository or linked worktree below the worktree does not count. The scan leaves it out (see "Worktrees" below, and "Worktree scan" in docs/process-tree.md). So `end` never signals it.
  - A process that this Emacs runs (`:emacs-process`, for example a language server) does not count.
  - A process of another live instance of this Emacs (`:instance-id`) does not count, also its detached work (a recorded group or member that left the CLI tree). Only a handover with `:allow-others` or `:force` has such an instance (for example the targets of a batch). So `end` never signals its processes.
  - A process in the CLI tree of another live MCP session of this Emacs (`:session-id`) does not count. A session without an instance descriptor counts as such a session, for example one that an older version of the package started. The sessions of the source and of the target do not count as other sessions. The run keeps the session ID of the source in memory for this, also after the source descriptor ends. A session after its cleanup is no live session, so its processes stay strays.
  - A review process (`claude-code-ide-review-process-ids`) does not count. The stop and the scan also leave it out. Its result goes to the target after the commit.
- Each stray gets the start time of its process right after the scan (`:start`).
- **Strays of unknown owner.** When other writers run in the worktree (`claude-code-ide-handover--run-writers`, for example with `:allow-others`), a stray is of the source only when the stop proved it (`:own`: the CLI tree of the source, a recorded member with its start time, or a proven recorded group; see docs/process-tree.md). A command that detached before any record saw it has no proof.
  - Every other stray is listed with "owner unknown", and the message says how many there are.
  - `end` signals only the strays of the source. It leaves the others alone. Check them by hand, then choose `wait` or `cancel`.
  - A later scan cannot prove an owner again, because the records of the source end with the stop. So a stray keeps its `:own` from an earlier result of the same run when its process ID and start time are the same. The registry record keeps `own` too.
  - **The proof holds the start time of its snapshot.** Each stray of the process file has the `:start` of the snapshot that proved it. When the handover reads the start time later and the process ID runs with another one, another process took that ID: the stray gets the new start time and loses `:own`. A start time that the handover reads later is never paired with a proof.
  - When no other writer runs in the worktree, every stray is of the source, and `end` signals all of them, as before.
- A handover with strays, a source that survived SIGKILL (`source-did-not-stop`), a source that may still run (`source-pid-unknown`, `source-still-running`), or a failed scan (`scan-failed`) gets the status `needs-user`.
  - An interactive handover asks at once. It shows the process ID, the command, and the folder of each stray.
  - A coordinator sees `needs-user` in the status, and Emacs shows a message.
- `M-x claude-code-ide-handover-resolve` answers. The choices:

| Reason | Choices |
|---|---|
| `strays`, `source-did-not-stop` | `end`: SIGTERM, then SIGKILL after `claude-code-ide-handover-stray-wait` (10 s), then scan again. With other writers in the worktree, `end` signals only the strays of the source (see "Strays of unknown owner"). `wait`: scan again after that time. `cancel`. |
| `source-pid-unknown`, `source-still-running` | `end`: end the source as `claude-code-ide-control-stop` does (the stop of its provider kills its terminal buffer, which ends the CLI), then scan the worktree. The scan waits `claude-code-ide-handover-stray-wait`, but at least the limit of the soft stop of the kept buffers (6 s by default). `wait`: after a refusal of the stop or the scan, try the stop again after `claude-code-ide-handover-stray-wait`. After a refusal in the document step or the target start (for example, in a recovery with a restored source), `wait` runs that step again and checks again; it does not stop the source. `cancel`: the message says whether the source still runs. There is no `go`: the handover never goes on while the source may run. |
| `scan-failed` | `wait` (scan again), `go` (go on without the check), `cancel`. |
| `no-delivery` | `wait` (look at the transcript, then wait again for the delivery), `cancel` (stop the target). |
| `target-exited` | `retry` (scan the worktree, then start the target again, with the same instance ID and document), `cancel`. |
| `start-failed`, `step-failed` | `retry` (run the stage again; a target that runs and waits for its document is taken up again, never started twice; from the stage `delivered` on, the commit runs again), `cancel`. |
| `registry-entry-missing` | `cancel`. |
| `unsent-draft` | `carry` (the document carries the draft as the user's next request), `drop` (go on; the record keeps the text), `cancel` (the source keeps running with its draft). |
| `continue-failed` | The stage is `committed`, but the inbox did not take the continue prompt. `retry` (commit again, which sends the prompt with the same request ID), `skip` (finish without the prompt). No `cancel`. The same two choices hold for every reason after the commit saved the chain (`chain_saved`), because a cancel would stop the target, which the chain names. |

- `end` signals a process only while it runs with the start time of the scan, within the one second of `claude-code-ide-session-registry--same-start-p`. An unknown start time, at the scan or now, never matches.
- **Survivors before any start.** A recovery that resumes or restarts the target, and the retry of a target that ended, first scan the worktree. The target CLI of its registry entry (its PID with its start time) counts as a stray when it runs outside this Emacs.
- `M-x claude-code-ide-handover-resolve` also takes up a handover that this Emacs does not run. One of an Emacs that ended is claimed and recovered. One whose Emacs seems to run needs a yes to a question that names that Emacs (a forced claim).

### Worktrees

The worktree of the source is the nearest folder at or above its project folder that has a `.git`. That `.git` can be a folder (a main checkout) or a file (a linked worktree). Without a `.git` above it, the worktree is the project folder itself.

The scan looks at each process whose working folder is inside the worktree. It finds the nearest folder at or above that working folder with a `.git`. The process is a stray only when that folder is the worktree itself. A process in a folder below the worktree with its own `.git` belongs to another repository or linked worktree, and the scan leaves it out.

- **Worktrees inside the repository** (`repo` and `repo/.worktrees/feat-x`, `repo/.worktrees/fix/y`):
  - A source in `repo`: a process in `repo/src` is a stray. A process in `repo/.worktrees/feat-x`, in `repo/.worktrees/fix/y`, or in a subfolder of them is not.
  - A source in `repo/.worktrees/feat-x`: its worktree is `feat-x`. A process in `feat-x/sub` is a stray. A process in `repo` or in `repo/.worktrees/fix/y` is not.
- **Worktrees outside the repository** (`Source/repo` and `Source/worktrees/repo/feat-x`, `Source/worktrees/repo/fix/y`):
  - A source in `Source/worktrees/repo/feat-x`: a process in it is a stray. A process in `fix/y` or in `Source/repo` is not.
  - A source in `Source/worktrees/repo`, which is no repository: a process in `feat-x` or `fix/y` is not a stray. A process in a plain subfolder, for example `notes`, is a stray.
- **An accidental `.git`.** An empty `git init` in `~/Source` makes `~/Source` the worktree of each project in it without its own `.git`. The scan still leaves out the processes of the projects with their own `.git`.
- **Links.** The scan compares true names, with the links resolved (on macOS, `/var` is a link to `/private/var`).
- **The `other-instance` check.** A live session in a linked worktree does not block a handover in the main checkout, and the reverse. Each linked worktree is a worktree of its own.

### Cancel

`M-x claude-code-ide-handover-cancel` cancels an unfinished handover.

- Before `source-stopped`, the source stays current. After the stop, the source stays stopped; `M-x claude-code-ide-reopen-session` starts it again.
- A running handover whose target runs cannot be cancelled. One that needs a person can: `claude-code-ide-process-stop` stops the target.
- A target process that outlived its Emacs is not ended by the cancel. The cancel shows it like a stray: `end` ends it and then cancels, `wait` checks again, and `cancel` cancels and leaves it running.
- After the start of the target, the cancel archives the registry entry of the target, so that no restore starts it.
- The cancel releases the inbox hold of the source.
- A handover that another live Emacs owns cannot be cancelled. A handover of an Emacs that ended is claimed first (see "Recovery").

## One writer for each worktree

- While a handover is unfinished, Emacs refuses to start another instance in its worktree. Only the start of its own target goes through.
- An unfinished handover in the registry, for example of an Emacs that crashed, holds the worktree too, until a recovery or a cancel ends it.
- The check is an `:around` advice of `claude-code-ide--start-session` (`claude-code-ide-handover--guard-start`). It signals `claude-code-ide-worktree-held`, a child of `user-error`, with the data `(HANDOVER-ID WORKTREE STAGE)`. So an `M-x` start shows a plain error.
- **Every start through `claude-code-ide-control--start`** (the control operations `launch` and `resume`) gives `(:status error :reason handover-running :instance-id ID :handover-id HANDOVER-ID :message TEXT)`, not `start-failed`. Nothing starts, and nothing waits: a coordinator polls `claude-code-ide-handover-status` with that ID, and launches again after the end.
- The other instances of the worktree get no prompt from the handover: the hold is only for the source, the inbox moves only from the source to the target, and the continue prompt and the recovery pointer go only to the target. Their own inboxes work as usual during the handover.
- The preflight refuses a handover while other instances or MCP sessions run in the worktree, unless `:allow-others` (this Emacs only) or `:force` is given.
- **A handover never adds a writer.** The source ends before the target starts (`claude-code-ide-handover--source-gone-p`): one writer goes, one writer comes. The question about other sessions protects only against a person who does not know that they run; the document tells the target about them.

## Several instances in one worktree

The design and its decisions: [handover-several.md](handover-several.md).

### The batch command

`M-x claude-code-ide-handover-worktree` hands over the live instances of one worktree to one target provider, one after the other.

```elisp
(claude-code-ide-handover-worktree INSTANCE-IDS TARGET-PROVIDER
  &optional METHOD CONTEXTS INTERRUPT CONTINUE CONFIRMED)
```

| Argument | Value |
|---|---|
| `INSTANCE-IDS` | The sources, in order. |
| `TARGET-PROVIDER` | One provider for all. |
| `METHOD` | `fork` or `fresh`. With `fork`, a source forks when its chain has a conversation of the target provider, else it starts fresh. |
| `CONTEXTS` | An alist `(INSTANCE-ID . TEXT)`. A source without an entry gets no context. |
| `INTERRUPT` | Non-nil: interrupt a busy source one time. One policy for all. |
| `CONTINUE` | `yes`, `no` or nil, as for `claude-code-ide-handover`. |
| `CONFIRMED` | The IDs of the sessions outside the batch that you confirmed. |

- It returns the result of the first `claude-code-ide-handover-session`.
- **The questions**, each one time, before the first handover (`claude-code-ide-handover--read-batch-args`):
  1. The worktree: that of the instance of the current buffer, else one that you choose (one worktree needs no question).
  2. The checks, before any question: a batch of this Emacs runs there, a handover holds the worktree, or an instance of another Emacs runs there. Each gives a `user-error`.
  3. The target provider.
  4. For a Codex target, the hook trust, one time. The handovers then find the cached trust.
  5. The sources: the live instances of this Emacs in the worktree whose provider is not the target provider (`completing-read-multiple`; empty input selects all). The order is that of `claude-code-ide-instances`.
  6. The other sessions: the question of `claude-code-ide-handover` for the sessions outside the batch, with the line "The targets of the batch also run here." `C-u` skips it; then the sessions that it would list count as confirmed.
  7. The method, only when a source can fork.
  8. "Interrupt a busy session (else wait until it is idle)?", only when a source is busy.
  9. A context note for each source.
  10. Continue, last.
- Every live source must be in the worktree of the first one; else the command refuses before any change.
- **The handovers** run with `:allow-others` set to the confirmed sessions, the sources and the targets of the batch, with `:interactive nil`, and never with `:force`. A session that starts after the questions refuses the next handover (`other-instance`), and the batch stops with that message. So no question comes later from a timer: a stray or another problem gives `needs-user`, and you answer with `M-x claude-code-ide-handover-resolve`.

### The rules after each handover

| Status and reason | Action |
|---|---|
| `committed` | Record the target. Start the next source. |
| `cancelled` with `busy`, `not-idle` or `recovered-before-stop` (an automatic cancel; the source stays current) | Skip the source, with the reason. Start the next source. |
| `cancelled` with `user-cancelled` | Stop the batch. |
| `needs-user` | Wait. One message for each handover: "Handover batch waits at LABEL: REASON; M-x claude-code-ide-handover-resolve". |

- **Before each next source,** the batch stops when its stop flag is set.
- A refusal with `busy` or `not-running` skips the source (fail safe: it stays current, and the rest goes on). Any other refusal, except `hooks-not-trusted`, stops the batch, with its message (for example `other-instance` names the new session).
- **The retry at the end.** `hooks-not-trusted` comes when the trust of the Codex status hooks ran out: a trust of the managed hooks holds 60 s, and the trust check is never weakened.
  - A source with this refusal waits in the retry list. It is not reported as skipped yet.
  - When no other source is left, the batch tries each source of the retry list one more time, in order. It uses the same answers and the same steps, without a question. By then, the background trust check that a cache miss starts may have an answer.
  - A second `hooks-not-trusted` skips the source with that reason. No other reason gets a retry.
  - The stop command and the guards of the stale timers also hold in the retry. A source that waits for the retry when the batch stops is reported as skipped with `hooks-not-trusted`.
  - The end message marks each source that the retry handed over with "(in the retry)".
- An error at the start of a source ends the batch with the usual report; the source gets the error text. A handover that started earlier is not touched.
- A committed or cancelled handover counts only after its final save (the slot `ended`). A notification of `needs-user` only waits.
- **The messages:** one for each start ("Handover batch in WORKTREE: 2 of 3: LABEL -> TARGET-PROVIDER (ID)"), and one at the end with three lists: handed over (`SOURCE -> TARGET`), skipped (`LABEL (REASON)`), and stopped at, and not started (`LABEL (REASON); LABEL, ...`). When a source is left, it adds "M-x claude-code-ide-handover-worktree hands over the rest."

### One batch for each worktree

- The batches live in memory (`claude-code-ide-handover--batches`, by worktree).
- A second batch command in the same worktree is refused while the current handover of the batch is unfinished and owned by this Emacs.
- **A stale batch is dropped** when the command runs again: its current handover is gone, final, or claimed by another Emacs. The drop marks it dead and cancels its pending timer.
- **`M-x claude-code-ide-handover-worktree-stop`** stops the batch of the worktree of the current buffer (or one that you choose). It starts no new handover. A running handover goes on to its end; `M-x claude-code-ide-handover-cancel` cancels it.
- **The stop ends the batch at once** when its current handover ended, is gone, or waits for a person (`claude-code-ide-handover--batch-close`). A handover that ended and whose end was saved is recorded first, as the next step would. Else its source is listed as stopped at, with the state of its handover. A handover that waits stays for `M-x claude-code-ide-handover-resolve`. A drop of a stale batch works the same way, and its message names that source.

### The status hook and the timers

- `claude-code-ide-handover--status-functions` is an abnormal hook that gets the run.
  - `claude-code-ide-handover--finish` runs it one time for each run (the in-memory slot `ended`), after the final save and the release of the inbox hold, and only when the save succeeded. The skip of `claude-code-ide-handover-resolve` for a source without a registry entry ends the run through `--finish` with NO-SAVE.
  - `claude-code-ide-handover--needs-user` runs it after each save of `needs-user`, and so does a missing registry entry (`registry-entry-missing`).
  - Each function runs in its own `condition-case`. An error gives a message, changes no run, and does not stop the other functions.
- The batch function on the hook only schedules `claude-code-ide-handover--batch-step` with no delay, with the batch object and the handover ID. The step acts only while the table still maps the worktree to that batch, the batch is not dead, and its current handover is still that ID. So an old timer never moves or removes a newer batch, and a second call for the same handover does nothing.
- A final save that fails runs no hook, so the batch waits. The stop command, or the next command in the worktree (a stale batch), ends it.

### Recovery after a crash

The batch lives in memory, so a crash ends it. Do these steps in this order:

1. `M-x claude-code-ide-handover-recover` continues the handover that ran (it also runs by itself when the registry mode turns on).
2. `M-x claude-code-ide-restore-sessions` starts the other sources again.
3. `M-x claude-code-ide-handover-worktree` hands over the rest. It offers only the live instances that are not of the target provider.

- A source whose handover was cancelled after its stop is stopped, not live. Start it again with `M-x claude-code-ide-reopen-session` first.

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
- After the next `turn-end` of that instance, Emacs asks you (`y-or-n-p`). After a yes, the question about other sessions comes too, when they run in the worktree. Two yes answers start `claude-code-ide-handover` with the reason as the context (and `ALLOW-OTHERS` after the second one). The request is used one time.
- `claude-code-ide-handover-enable-request-tool` (default t) turns the tool off.

## Coordinator tools

| Tool | Arguments |
|---|---|
| `claude-code-ide-control-handover` | `instance_id`, `target_provider`, and optional `method`, `context`, `interrupt`, `force`, `request_id`, `continue` (boolean: the continue prompt after the commit; without it, the user's option, with `ask` as true), `allow_others` (boolean: go on while other instances of this Emacs run in the worktree; unlike `force`, it does not stop subagents or background tasks). It returns at once. |
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
| `claude-code-ide-handover-unsent-draft` | `ask` | What the handover does with an unsent prompt in the input box of the source: `ask`, `carry`, `drop` or `refuse`. See "An unsent draft". |
| `claude-code-ide-handover-draft-placeholders` | (list) | Regexps of the placeholder texts of an empty input box, which are no draft. |
| `claude-code-ide-handover-unsaved-target` | `fresh` | What the recovery does with an identified target that never saved its conversation: `fresh` starts it fresh with the same IDs and document, `ask` resumes it as before and then asks a person (`target-exited`). See "An unsaved target". |
| `claude-code-ide-handover-enable-request-tool` | t | Give the agents the tool `request_handover`. |

## Limits

- Codex reports no background terminals. So the quiescing cannot see them; the stop ends them through the recorded process groups.
- The interrupt is the Escape key. In a dialog it can deny or close the dialog.
