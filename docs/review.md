# Reviews and ediff frames

This document describes two parts of plan §4.8, "Human review attached to its instance":

- **Tracked reviews** (`claude-code-ide-review.el`): the result of an external review goes to the instance that owns it, one time, with an acknowledgement.
- **Dedicated ediff frames** (`claude-code-ide-mcp-handlers.el`): a launch, a resume, a restore, or a handover never closes, moves, or reuses an open review frame or its queue.

The package knows no review tool. A workflow gives the command or the process, and the result file.

## Tracked reviews

### The function

```elisp
(claude-code-ide-review-track OWNER-INSTANCE-ID
  :command '("my-review-tool" "plan.md")   ; or :process PROCESS-OR-PID
  :result-file "plan.review.md"
  :label "Plan of ticket 12"
  :review-id "plan-12-r1")                 ; optional
```

- **OWNER-INSTANCE-ID:** the instance that gets the result. It must be an instance that this Emacs or the session registry knows.
- **`:command`:** a list of strings. Emacs starts it in `:directory`, or else in the worktree of the owner.
- **`:process`:** an Emacs process object, or the process ID of a process that runs already. Give `:command` or `:process`, not both.
- **`:result-file`:** the file that the review writes. A relative name is relative to the directory.
- **`:label`:** a name for people. The default is "review".
- **`:review-id`:** a string that the caller chooses. Without it, Emacs makes one.
  - A second call with a known review ID starts nothing. It returns the state of the first review, with `:duplicate t`.

The function never signals. It returns one of these:

- `(:status ok :review-id ID :owner OWNER :state running :pid PID)`.
- `(:status error :reason R ...)`. The reasons are `invalid-instance-id`, `unknown-instance`, `no-process`, `process-and-command`, `invalid-process`, `invalid-command`, `no-result-file`, `no-directory`, and `start-failed`.

`(claude-code-ide-review-status REVIEW-ID)` returns the current state of a review.

### The control operation and the coordinator tool

- The operation `track-review` of `claude-code-ide-control-operations` is `claude-code-ide-review-track`. So `(claude-code-ide-control-call 'track-review OWNER ...)` works.
- The MCP coordinator tool is `track_review`. Its arguments are `instance_id`, `result_file`, and the optional `label`, `review_id`, `pid`, `command` (an array of strings), and `directory`.
  - It has the coordinator scope, like the other control tools (`docs/api-control.md`).
  - It returns the result of the function as a JSON object with `_` keys.

### States

| State | Meaning |
|---|---|
| `running` | The review process runs. |
| `ended` | The process ended. The record holds the result text. The owner's inbox does not have it yet, for example because the owner is not known after a restart. |
| `submitted` | The result is in the inbox of the destination. The inbox decides when it goes out. |
| `delivered` | The CLI of the destination reported the result prompt (the `prompt-submit` event with the same text hash). Final. |
| `unacknowledged` | The inbox sent the result, but no acknowledgement came in time. Final. The inbox never sends it again. |
| `rejected` | The inbox cannot take the result, for example because the provider has no `submit-prompt`. Final. |

- **The end of a process is not a delivery.** Only the acknowledgement makes a result `delivered`.
- **A final state that is not `delivered`** gives a warning with the review ID, the result file, and the record file. The record keeps the result text. So a result is never lost without a word.

### Delivery

1. When the process ends, Emacs reads the result file and makes the prompt text.
2. Emacs saves the text in the record, so that a crash cannot lose it.
3. Emacs calls `(claude-code-ide-control-submit DESTINATION TEXT :request-id REVIEW-ID :queue t)`.
   - The review ID is the request ID. A second submit of the same review sends nothing.
   - `:queue t` keeps the result also for an owner that is failed or stopped. The result waits until the owner runs again.
4. The state rules of plan §4.6 then apply. The inbox sends the result only when the destination is idle and has no older prompts.
5. `claude-code-ide-control-delivered-functions` reports the acknowledgement. The review becomes `delivered`, and the record drops the text.

A check runs every `claude-code-ide-review-check-interval` seconds (default 5) while a review of this Emacs is not final:

- It finds the end of a review that Emacs knows only by its process ID.
- It submits the `ended` results again.
- It compares the `submitted` results with the inbox. So it finds an acknowledgement that no hook reported, and a result that a handover moved.
- A submitted result that no inbox knows is submitted again, with the same review ID.

A result whose owner is not known waits in the state `ended`. The start of an instance with that ID (`claude-code-ide-session-start-functions`) submits it at once.

### After a handover

- At each submit and each check, Emacs looks up the current owner with `(claude-code-ide-session-registry-chain-current OWNER)`, when that function exists. It returns the instance ID of the current leg of the chain, or nil.
  - The handover (`feat/handover`) provides the function. Without it, the result goes to the owner.
- The handover moves the queued prompts of the inbox to the new instance. The check then finds the result in the inbox of the current owner, and changes the destination of the record.
- `(claude-code-ide-review-process-ids)` returns the process IDs of the reviews that run. A review command runs in the worktree of its owner, so a stray scan of that worktree finds it. A handover leaves these processes alone.

### Restarts

- **A review that ends while Emacs does not run** is found at the next start. Emacs runs `claude-code-ide-review-recover` 2 seconds after the package loads. A batch Emacs does not run it.
  - This works for a review that Emacs knows by its process ID: the process does not belong to Emacs, so it outlives Emacs.
- **A command that Emacs started ends at the Emacs quit.** Emacs ends its child processes at the quit; a test showed that `trap '' HUP` does not keep them alive.
  - `kill-emacs-hook` marks such a review `interrupted`.
  - At the next start, Emacs reads the result file. If the file does not exist, the owner gets the error result `interrupted`.
- **Two Emacs processes:** a review whose record names another Emacs that still runs stays with that Emacs. A record of an Emacs that is gone is taken over.

### Result files

Emacs reads the result file as UTF-8 text. A file that cannot be used gives the owner an explicit error result:

| Reason | Cause |
|---|---|
| `missing` | The file does not exist. |
| `interrupted` | The file does not exist, and Emacs ended the review at its quit. |
| `not-a-file` | The name is a folder. |
| `unreadable` | Emacs cannot read the file. |
| `too-large` | The file has more than 8 MB. |
| `not-text` | The file has a NUL byte, or it is not UTF-8. |
| `empty` | The file has only white space. |
| `invalid-json` | The name ends with `.json`, and the text is not valid JSON. |

- The error result has the review, the result file, the exit status, the error, and the end of the command output (for a command that Emacs started).
- A result longer than `claude-code-ide-review-max-result-chars` (default 50,000) is cut. The prompt says that it is cut, and where the full result is.
- `claude-code-ide-review-format-function` makes the prompt text. The default text has a header (the label, the review ID, the result file, and the exit status), then the result. It has no instructions of a workflow.

### The record file

- Path: `<report directory>/reviews/<hash>.json`, where `<hash>` is the first 32 hex digits of the SHA-256 of the review ID. `claude-code-ide-review-directory` changes the folder.
- The folder has mode 0700 and each file mode 0600, because the result text can be private.
- Each write goes to a temporary file in the same folder, then `rename-file`.
- Final records are deleted after `claude-code-ide-review-done-days` days (default 7). Until then, the review ID is a duplicate.

The fields (version 1):

| Field | Value |
|---|---|
| `version` | 1 |
| `review_id`, `owner`, `label` | Strings. |
| `command`, `directory` | The command that Emacs started, and its folder; or null. |
| `pid`, `pid_start` | The process ID and its start time (a float time). A process with the same ID and another start time is a new process. |
| `managed` | true when Emacs started the process. |
| `interrupted` | true when Emacs quit while its process ran. |
| `emacs_pid` | The Emacs that tracks the review. |
| `result_file` | The full path of the result file. |
| `state` | See "States". |
| `exit_status` | The exit status, or null when it is not known (a process ID only). |
| `error` | The reason of an error result, or null. |
| `text` | The prompt text until the result is delivered. |
| `destination` | The instance whose inbox got the result. |
| `submit_result`, `submit_reason` | The last result and reason of the inbox. |
| `created_at`, `ended_at`, `submitted_at`, `delivered_at`, `updated_at` | ISO 8601 times in UTC. |

## Dedicated ediff frames

These rules hold for the frames of `claude-code-ide-ediff-files-in-frame` and for the frames of `claude-code-ide-ediff-frame`.

- **A new terminal window never goes into a dedicated diff frame.** `claude-code-ide--display-buffer-in-side-window` runs through `claude-code-ide-mcp-call-outside-ediff-frame`.
  - When the selected frame is a dedicated diff frame, the window goes to another frame. A visible frame comes first. Without another frame, Emacs makes one.
  - The diff frame stays selected, so the review keeps the focus.
  - This covers each launch, resume, restore, and handover target, and each other display of a terminal buffer.
  - When no other frame can be made, the buffer is not shown, and a message says so.
- **An open ediff keeps its frame.** A frame has an open ediff while one of its ediff control buffers lives, also while the ediff is suspended and its windows show other buffers.
  - The frame cleanup (`claude-code-ide-mcp--maybe-delete-ediff-frame`) keeps such a frame, and a frame with waiting diffs. So the end of another instance, for example the source of a handover, never deletes it.
- **The queue of a frame.** A call of `claude-code-ide-ediff-files-in-frame` for a label whose frame has an open ediff does not replace that ediff. The diff waits in the queue of the label.
  - When the open ediff ends (its control buffer dies), the oldest waiting diff opens in the frame, after 0.3 seconds.
  - The queue belongs to the label, not to the frame. If you delete the frame, the next diff opens in a new frame with the same label.
- **`openDiff` never takes a frame with an open ediff.** With `claude-code-ide-ediff-frame` on, the diff of an instance goes to the frame of its project. While that frame has an open ediff or waiting diffs, the diff goes to the frame "ediff LABEL <2>" (or `<3>`, and so on).
  - A CLI waits for the verdict of its diff, so the diff does not wait in a queue.
- **Without `claude-code-ide-ediff-frame`,** `openDiff` uses the selected frame. When that frame is a dedicated diff frame, the diff goes to another frame.
- **The diffs of an instance that ends** are closed, because their verdict can no longer reach a CLI. That does not change. The frames of other instances and of `claude-code-ide-ediff-files-in-frame` stay.

`(claude-code-ide-mcp-ediff-frame-p FRAME)` tells whether FRAME is a dedicated diff frame. Each such frame has the frame parameter `claude-code-ide-ediff` with its label.
