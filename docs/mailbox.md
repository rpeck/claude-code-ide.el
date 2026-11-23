# Mailbox

The mailbox lets an agent session of any provider send a message to another session of the same Emacs.
The sender calls an MCP tool of the package. Emacs gives the text to the receiver as a prompt, through the control inbox.
The tools have the instance scope, so no tool approval stops an unattended run.

- Issue: rpeck/claude-code-ide.el#41.
- Code: `claude-code-ide-mailbox.el` (new, optional).
- Tests: `tests/claude-code-ide-mailbox-tests.el` (new).
- The delivery engine: the prompt inbox of [api-control.md](api-control.md).
- Request identity and tool scopes: [api-mcp.md](api-mcp.md).
- The chain after a handover: [handover.md](handover.md).

Status: implemented. The live test `claude-code-ide-live-test-mailbox-multi-line-claude` has not run yet. The places where the code differs from the first design are marked "Changed in the implementation".

## The decisions

| Part | Decision | Rejected options |
|---|---|---|
| Transport | Two MCP tools of the instance scope: `claude-code-ide-send-message` and `claude-code-ide-list-peers`. | A file drop: it needs write grants outside the worktree, and it cannot know the sender. |
| Sender | The instance of the MCP request (`claude-code-ide-mcp-request-instance-id`). The caller cannot name a sender. | A `From` argument or header. |
| Target | An instance ID of this Emacs. | Display names: they can be equal, nil, or change. |
| Delivery | One call of `claude-code-ide-control-submit` for each message, with `:queue t` and a new key `:defer t`. | A second queue in the mailbox; a send inside the MCP request. |
| Idempotence | A new `key` field of the control record: `mailbox:<root of the sender chain>:<request_id>`. A handover keeps it. The duplicate check finds the key in each instance of the target chain. | A record file for each message; rules for the forms of renamed request IDs. |
| Instructions | The tool descriptions. | A new instruction hook and a roster file. |
| Clean text | One cleaner, `claude-code-ide-control-clean-text`. In the first version, only the mailbox frame uses it. | A private cleaner in the mailbox; the cleaner for every prompt now. |
| Line feeds | The submit path of today, as for multi-line review results. A live test checks it. | A bracketed paste now. |
| Floods | A cap of mailbox prompts for each receiver. For each pair of chain roots: 30 messages an hour, and 200 in total until a reset. | No limit in the first version; an hourly limit alone. |
| Default | The mode is off. Every instance of this Emacs can receive. | On by default. |
| No MCP tools server (D41-3) | A new session waits: while the mode is on and the server is off or does not start, a new session does not start without the tools. A start by the user asks to turn the server on; another start is refused. | A warning when the mode turns on (the first version). |

## The tools

The mode registers both tools with `claude-code-ide-make-tool`, without `:scope`, so they have the instance scope. They are on the `emacs-tools` server with all other tools of the package.

### claude-code-ide-send-message

| Argument | Type | Meaning |
|---|---|---|
| `to` | string | The instance ID of the receiver, from `claude-code-ide-list-peers`. |
| `summary` | string | One line, at most 200 characters after the cleaner. |
| `text` | string | The message, at most 16,000 characters after the cleaner. |
| `request_id` | string, optional | An ID that the sender chooses, valid for `claude-code-ide-control-valid-id-p`. A second call with the same ID sends nothing and returns the current result. |

The result is the result of `claude-code-ide-control-submit`, as JSON (`claude-code-ide-control-json`):

| Key | Value |
|---|---|
| `destination` | The instance that gets the message: `to`, or the current instance of its chain. |
| `request_id` | The request ID of the control record. The control inbox makes it (a new UUID), so that no record of another caller can have it. The key of the record finds a retry. |
| `result` | `queued`, `delivered`, `unacknowledged`, or `rejected`. |
| `reason` | Why, or null. A new message to an idle receiver with nothing pending gets `queued` with the reason `deferred`. Else the reason is that of the state rules, for example `working`, `stopped`, `held`, `guessed-idle`, or `earlier-prompts-pending`. |
| `duplicate` | true for a retry with a known request ID. |
| `retry_after` | Seconds, only for the reasons `receiver-busy` and `rate-limited`. |

Refusals of the mailbox use the same keys, with `result` `rejected`. No inbox file is made for them.

| Reason | Cause |
|---|---|
| `mode-off` | `claude-code-ide-mailbox-mode` is off. The mode removes the tools when it turns off; this reason covers a call that a tool spec of an earlier load gets. |
| `no-caller` | The request has no instance ID: a session without a secret, or a coordinator request to `/mcp`. |
| `invalid-instance-id` | `to` is not a valid ID (`claude-code-ide-control-valid-id-p`). |
| `invalid-request-id` | `request_id` is not a valid ID. The same function checks it. |
| `self` | `to`, after the chain, is in the chain of the caller, or the caller is in the chain of `to`. This holds also during a handover, before its commit moves the chain. |
| `archived` | The registry entry of the receiver is archived. The control inbox counts an archived instance as stopped, so the mailbox checks this first. |
| `other-emacs` | The receiver does not run in this Emacs, and another Emacs that runs owns its registry entry. |
| `not-a-receiver` | `claude-code-ide-mailbox-receivers` names neither the role nor an ID of the chain of the receiver. |
| `empty-text` | After the cleaner, `text` has only white space (`claude-code-ide-control-blank-text-p`). |
| `summary-too-long`, `text-too-long` | Over the limits above. The mailbox never cuts a message. |
| `receiver-busy` | The receiver has `claude-code-ide-mailbox-max-pending` mailbox prompts that wait. |
| `rate-limited` | The pair has used its hourly budget. `retry_after` says when a message can pass. With a budget of 0, every message gets this reason, without `retry_after`. |
| `budget-spent` | The pair has used its total budget. Time does not refill it. The message of the result says: run `M-x claude-code-ide-mailbox-reset-budgets`. |
| `unknown-instance` | From the control inbox: neither this Emacs nor the registry knows the receiver. |
| Other control reasons | For example `no-submit`. See api-control.md. |

### claude-code-ide-list-peers

- No arguments.
- The result is `(:status ok :instances LIST)`, as for `claude-code-ide-control-list-instances`. With the mode off, it is `(:status error :reason mode-off)`.
- The instances are those of `claude-code-ide-control-list-instances` (the instances that run in this Emacs, with `claude-code-ide-control--describe`), less the caller, less the instances that `claude-code-ide-mailbox-receivers` excludes (by role, or by an ID of their chain).
- Each element has `instance_id`, `display_name`, `provider`, `role`, `state`, `state_reason`, and `queued`.
- A stopped instance is not in the list. A message to its ID still waits in its inbox until it runs again.

### The tool descriptions

- The descriptions are the instructions of the sender. `claude-code-ide-mailbox--tool-specs` owns them; read the text there.
- They tell the sender how to get the IDs, that Emacs adds the sender, how a `request_id` makes a retry safe, and to send only messages that give information.
- Changed in the implementation: the description of `claude-code-ide-send-message` says nothing to the receiver. The frame tells the receiver what the message is (see "The frame").

## The sender

- **The sender is the instance of the request.** `claude-code-ide-mcp-server-check-request` binds it from the instance secret in the URL path or the header. `claude-code-ide-mcp-request-instance-id` gives it to the tool.
- **No caller, no message.** A request without an instance ID gets `no-caller`.
- **The sender after a handover** is a new instance with a new ID. The key uses the root of the sender chain, not the current ID. So a retry of the new instance with the same `request_id` is still a duplicate.
- **What "verified" means.** The check stops honest mistakes, and a message text that claims a false sender. It does not stop a process of the same user: such a process can read the secret of another session (the MCP config file of Claude Code, or the `CCI_MCP_HEADER_*` variables of a Codex process) and call the tool as that session.

## The target

`claude-code-ide-mailbox--check` does these steps, in this order. The first failure is the result.

Before the steps, the summary and the text go through `claude-code-ide-control-clean-text` one time. All later checks and the frame use the clean values.

1. The mode is on, else `mode-off`.
2. The caller exists, else `no-caller`.
3. `to` and `request_id` are valid, else `invalid-instance-id` or `invalid-request-id`.
4. `target` is `(claude-code-ide-control-chain-current to)`. The chains of the caller and of `target` come from `claude-code-ide-session-registry-chain-ids`, one time for each send. When `target` is in the chain of the caller, or the caller is in the chain of `target`, the result is `self`.
5. A retry: `(claude-code-ide-control-find-key-in-chain target KEY)` finds the key in an instance of the chain. Then return its current result with `:duplicate t`, without the other checks and without a submit. See "Duplicates across a handover".
   - Changed in the implementation: the retry comes before the checks of the receiver and of the text. So a retry gets its result also after the receiver was archived or left the receivers option.
6. The registry entry of `target` (`claude-code-ide-control-registry-entry`) is archived: `archived`.
7. `target` does not run in this Emacs, and `(claude-code-ide-session-registry-other-emacs-p ENTRY)`: `other-emacs`.
   - Reason: the control inbox keeps an index in memory for each Emacs. A prompt that this Emacs queues for an instance of another Emacs can stay unseen there.
8. `claude-code-ide-mailbox-receivers` excludes `target`: `not-a-receiver`.
9. The size checks on the clean values: `empty-text`, `summary-too-long`, `text-too-long`.
10. The limits, in this order: `receiver-busy`, `budget-spent`, `rate-limited` (see "Limits").
    - Changed in the implementation: `budget-spent` comes before `rate-limited`. When both apply, no wait helps, so a `retry_after` would only invite a retry that fails.
11. The submit (see "Delivery").

- A stopped instance of this Emacs passes these steps. The control inbox queues the message (`:queue t`), and the resume delivers it.
- An unknown ID passes them too. The submit returns `unknown-instance`.
- **ID only.** The tool does not take a display name. `list-peers` gives the IDs, and a name can match two instances.

## Delivery

```elisp
(claude-code-ide-control-submit TARGET FRAME
  :key KEY
  :queue t
  :defer t)
```

- **KEY** is `mailbox:<root of the sender chain>:<request_id>`. A call without `request_id` gets a new one from `claude-code-ide-instance-new-id`. `claude-code-ide-mailbox--key` owns this form.
- **`:key`** is a new keyword of `claude-code-ide-control-submit` (see "The key of a record"). A handover can rename the request ID; the key never changes.
- **No `:request-id`.** Changed in the implementation: the control inbox makes a new request ID. With the key as the request ID, an unrelated record with that ID (without the key) was a duplicate for the inbox: the message was never queued, and the budget was used.
- **`:queue t`** keeps the message also for a receiver that is stopped or `failed`, for example at a quota limit. A later resume delivers it, and a later handover moves it.
- **The control inbox does the rest:** the chain, one prompt at a time for each instance, the state rules, the guessed idle rule, `codex queue` for Codex, the terminal for Claude Code, the acknowledgement, at most one send, the hold of a handover, and the files on disk across a restart.
- **A retry without `request_id`** gets a new key, and can send the message a second time. The tool description says so.

### Chains

- **The owner of a chain:** the registry. `claude-code-ide-session-registry-chain-current` gives the current instance. `claude-code-ide-session-registry-entry-legs` gives the legs of an entry, oldest first, each with `:instance-id`. The target of a handover saves all earlier legs and its own leg, so the entry of the current instance has the whole chain. The handover reads the chain the same way.
- **A new public helper reuses them:** `claude-code-ide-session-registry-chain-ids (INSTANCE-ID)`. It returns the instance IDs of the chain of INSTANCE-ID, oldest first: the `:instance-id` of each leg of the entry of `(claude-code-ide-session-registry-chain-current INSTANCE-ID)`. An instance without a chain gives the list of its own ID.
- **The root** of a chain is the first ID of that list. A handover never changes it.

### The key of a record

- **The problem:** a handover can give a moved record a new request ID. When the target has a record with the same ID, the copy gets `handover:<handover-id>:<id>`, and a second handover can rename that again (`handover:<h2>:handover:<h1>:<id>`). A rule of ID forms cannot follow every rename.
- **The fix, one new field:** each inbox record gets `key` (a string, or nil; JSON `key`).
  - `claude-code-ide-control-submit` takes `:key` and stores it.
  - `claude-code-ide-control-move-inbox` builds each copy field by field. It copies `key` unchanged, also when it renames the request ID.
  - A record file without `key` (written before this change) reads as nil. The file version stays 1, because the field only adds data.
- **The implementation must also document the field** in docs/api-control.md: the field table of "The file", the keyword of `submit-prompt`, and the two new helpers below.

### Duplicates across a handover

- `claude-code-ide-control-submit` looks for a known request ID only in the inbox of the current instance. A handover moves only the queued prompts. A final record, for example a `delivered` one, stays in the inbox of the source.
- So after a handover from B to C, a retry to B of a message that B got could reach C as a new prompt.
- **Fix:** a new public helper of the control file, `claude-code-ide-control-find-key-in-chain (INSTANCE-ID KEY)`:
  1. Take the IDs of `claude-code-ide-session-registry-chain-ids`, newest first.
  2. In the inbox of each ID, take the records whose `key` is KEY, pending and final.
  3. Return the result of the first record that is not `rejected` with the reason `handed-over`: that is the copy that survives. When only such records exist, return the newest of them. When none exists, return nil.
- The chain is that of `claude-code-ide-session-registry-chain-ids` only while `claude-code-ide-session-registry-mode` is on, as for `claude-code-ide-control-chain-current`; else it is INSTANCE-ID alone. The result has no `:duplicate`; the mailbox adds it.
- The pending records are in the index of each inbox already. For the final records, the helper reads the files of `done/` of each leg one time, and keeps a table from key to record file in memory. Each write of a record with a key updates the table.
- The mailbox calls the helper before the limits (step 9). A coordinator retry has the same gap today; the coordinator tool can use the helper in a later change.

### Outside the MCP request

- A tool runs inside the process filter of the HTTP server (`claude-code-ide-mcp-http-server--filter`).
- When the receiver is idle, `claude-code-ide-control-submit` sends at once. For Claude Code, the send types into the terminal and calls `(sit-for 0.1)`. Inside a filter, `sit-for` can run timers and the output of other processes, also other MCP requests.
- The coordinator tool `claude-code-ide-control-submit-prompt` has this problem today: `claude-code-ide-control--mcp-submit` calls `claude-code-ide-control-submit` in the filter.
- **Decision:** a new key `:defer t` of `claude-code-ide-control-submit`. With it, a prompt that the rules send at once is queued with the reason `deferred` instead, and `claude-code-ide-control--schedule-delivery` sends it from a timer with no delay. The other rules do not change.
- So the tool never returns `delivered` for a new message. To an idle receiver with nothing pending, it returns `queued` with the reason `deferred`; to another receiver, `queued` with the reason of the state rules. That is the truth at the time of the return. A retry with the same `request_id` gives the later result.
- Recommendation: the coordinator tool uses `:defer t` too. That change is outside this feature (open question 6).

## The frame

`claude-code-ide-mailbox--frame` owns the text; read it there. The test `claude-code-ide-test-mailbox-frame` has the exact frame of a known sender. It is the same for both providers.

- **The first line** names the sender: it starts with `claude-code-ide-mailbox-frame-prefix` ("[Message from agent session"), then the display name, the ID, and the provider.
- **The sender line** comes from the descriptor of the caller: `claude-code-ide-instance-display-name`, the ID, and the provider. Nothing in it comes from the arguments. A caller without a display name gets only the ID and the provider.
- **Then** the summary, and the rules for the receiver: the text comes from another agent session, not from the user; it is a request from a colleague; it ranks below the instructions of the user and the permissions; how to reply; reply only with information.
- **The first character is `[`.** So Claude Code never reads the prompt as a slash command (`/`), a shell command (`!`), or a memory note (`#`).
- **The marker** around the text has a random nonce of 6 hex digits for each message (from `claude-code-ide-instance-new-id`). The text cannot close the block with a false end marker. When the text contains the marker, the frame takes a new nonce.
- The text and the summary are clean already (see "The target"). The frame calls `claude-code-ide-control-clean-text` on the display name and the provider name. The mailbox has no cleaner of its own.
- Changed in the implementation: in the display name, the provider name and the summary, each LF also becomes a space. Each of them is one line of the frame, so a value cannot add a line, for example a false marker or a false instruction.

## Clean text

- **One owner:** `claude-code-ide-control-clean-text (TEXT)`, a new public helper of the control file.
- **What it does:**
  1. CR LF and a lone CR become LF.
  2. TAB becomes four spaces. In the Claude Code terminal, TAB is a key.
  3. It removes the other C0 controls (U+0000 to U+001F, except LF), DEL (U+007F), the C1 controls (U+0080 to U+009F), and the bidi controls (U+202A to U+202E, U+2066 to U+2069).
- **Who uses it in the first version:** only the mailbox: `claude-code-ide-mailbox--check` for the summary and the text, and `claude-code-ide-mailbox--frame` for the names. The frame is clean before it reaches `claude-code-ide-control-submit`.
- **The empty text** has one owner too: `claude-code-ide-control-blank-text-p`. The submit and the mailbox call it.
- **What does not change:** `claude-code-ide-control--line-ends`, `claude-code-ide-control-text-hash`, and every other prompt path (coordinator prompts, review results, handover prompts). Their text and their hash stay as they are.
- The acknowledgement of a mailbox prompt still matches: the inbox stores the clean frame, hashes it, and the CLI reports the same clean text.

## Multi-line prompts in Claude Code

- **The path:** the mailbox uses the submit path that the multi-line review results use today. `claude-code-ide--claude-submit-prompt` calls `claude-code-ide--terminal-submit`, which sends the text with `claude-code-ide--terminal-send-string` and then Return.
  - vterm: `vterm-send-string` without PASTE-P. Each LF goes to the terminal as the key Ctrl-J.
  - eat: `eat-term-send-string`, the raw text.
  - ghostel: `ghostel-send-string`, the raw text.
- **No path uses bracketed paste.** One prompt with all its lines depends on how Claude Code reads a raw Ctrl-J. No test of the package covers it now.
- **Unverified.** That a multi-line mailbox message reaches Claude Code as one prompt is not verified until the live test `claude-code-ide-live-test-mailbox-multi-line-claude` runs (see "Test plan").
- The cleaner removes ESC and CR from the frame. So the text cannot send an Escape or an early Return.

## Limits

| Limit | Rule | Default |
|---|---|---|
| Prompts that wait for a receiver | The pending records of the receiver (after the chain) whose `key` starts with `mailbox:`, whatever their request ID became. At the cap, the reason is `receiver-busy` and `retry_after` is 60. | `claude-code-ide-mailbox-max-pending` = 10 |
| Hourly budget of a pair | Accepted messages from one sender to one receiver in the last 3,600 seconds. At the budget, the reason is `rate-limited`, and `retry_after` is the time until the oldest of those messages leaves the window. | `claude-code-ide-mailbox-pair-budget` = 30 |
| Total budget of a pair | Accepted messages from one sender to one receiver since the last reset. Time does not refill it. At the budget, the reason is `budget-spent`, and the message names the reset command. | `claude-code-ide-mailbox-pair-total` = 200 |

- The pending count comes from a new helper, `claude-code-ide-control-pending-keys (INSTANCE-ID)`: the keys of the records of `claude-code-ide-control-refresh`. A record without a key is left out.
- **The key of a pair** is the root of the sender chain and the root of the receiver chain (`claude-code-ide-session-registry-chain-ids`). A handover of the sender or of the receiver does not change the key, so it does not refill a budget.
- **The reset:** `M-x claude-code-ide-mailbox-reset-budgets` clears both budgets of all pairs. Nothing else clears them, also not a turn of the mode off and on: `claude-code-ide-reload` turns the mode off and on, and a reload must not refill a budget.
- The budgets are in memory. A restart of Emacs starts them again.
- Only a new record that the control inbox queued uses a budget. A refusal of the mailbox, a rejection of the control inbox (for example `unknown-instance`), and a duplicate do not.
- A budget of 0 refuses every message (`rate-limited` without `retry_after`, or `budget-spent`). `claude-code-ide-mailbox-max-pending` 0 refuses with `receiver-busy`.
- `claude-code-ide-mailbox--limit` owns the three limits.
- Why these defaults: the total of 200 stops an exchange of two agents that never ends, also one that keeps below the hourly budget; a long night of real work for one pair stays below it. A real exchange (one message every two minutes in each direction) stays below 30 an hour. An endless exchange of two agents stops within an hour. Ten unread messages are more than a session can use.

## Receivers

- `claude-code-ide-mailbox-receivers` nil: every instance of this Emacs can get a message.
- A list of strings: an instance gets a message only when its role, or an instance ID of its chain (`claude-code-ide-session-registry-chain-ids`), is in the list. So an ID still names the session after a handover.
- `claude-code-ide-mailbox--receiver-p` owns the rule. The check and `list-peers` both call it.
- Default: nil. The mode itself is off by default, and a user who turns it on chooses the feature.

## Approvals

- **Only coordinator tools ask for approval.** The mailbox tools have the instance scope.
- **Claude Code:** with `claude-code-ide-mcp-allowed-tools` at `auto`, `claude-code-ide--build-claude-command` gives `--allowedTools` all registered tools, also the two mailbox tools.
- **Codex:** `claude-code-ide-codex--approval-args` gives `approval_mode "approve"` to each tool of `claude-code-ide-codex--approved-tool-names` that is not a coordinator tool.
- **Both lists are made at launch.** So the mode must be on before a session starts.
  - When the mode turns on while sessions run, it shows a warning with their number: they get the tools, without an approval, only after their next launch.
- **A list in `claude-code-ide-mcp-allowed-tools`:** the user must add `mcp__emacs-tools__claude-code-ide-send-message` and `mcp__emacs-tools__claude-code-ide-list-peers`. Else each call asks.

## The mode

`claude-code-ide-mailbox-mode` is a global minor mode. Default: off.

- The file loads at the load points of `claude-code-ide.el`: `(claude-code-ide--require-optional 'claude-code-ide-mailbox)`, after `claude-code-ide-review`. The load registers nothing.
- **On:**
  1. Add the server check to each new start (see "No MCP tools server").
     - Changed by decision D41-3: the first version only warned when `claude-code-ide-enable-mcp-server` was nil. Now a new session waits for the server, so the warning is gone.
  2. Turn on `claude-code-ide-session-registry-mode` when it is off, as `claude-code-ide-session-status-mode` does. The status hooks of the registry give the idle states and the acknowledgements, and the registry gives the chain, the archived state, and the owner Emacs.
  3. Register the two tools.
  4. Warn about the sessions that run (see "Approvals").
     - Changed in the implementation: the warning counts only the sessions that started while the mode was off. When the mode turns off, it notes the sessions that run with the tools; when it turns on, the others get the warning. So the off and on of a reload warns about nothing.
- **Off:** remove the two tools with `claude-code-ide-mcp-server-remove-tools`, and remove the server check. The prompts that the control inbox has already still go out.

### No MCP tools server

`claude-code-ide-mailbox--check-server` owns the rule. The mode adds it as a `:before` advice of `claude-code-ide--start-session`, the generic start of every provider.

- **Why an advice:** `claude-code-ide-session-prepare-functions` reports the errors of its functions and goes on, so it cannot stop a start. The advice keeps the main file unchanged, and runs before the start makes anything.
- **The check:** `claude-code-ide-mcp-server-ensure-server` gives a port. Then the start goes on, without a question.
- **Server off, start by the user** (the `interactive` slot of the start spec, or the INTERACTIVE argument; the start commands and the menu set it): one `y-or-n-p` question, "The mailbox mode needs the MCP tools server, which is off. Enable it now?".
  - Yes: `claude-code-ide-enable-mcp-server` becomes t for this Emacs (as `claude-code-ide-emacs-tools-setup` sets it), and `claude-code-ide-mcp-server-ensure-server` starts the server. The start goes on.
  - No: the start stops with the `user-error` `claude-code-ide-mailbox-needs-mcp-server`. Its message says how to turn the server on.
- **Server off, another start** (a coordinator `launch` or `resume`, the restore at the start of Emacs, a handover target, a timer): no question; the same error. `claude-code-ide-control--start` gives the result `(:status error :reason mailbox-needs-mcp-server :message TEXT)`.
- **Server on, but it does not start** (for example without the web-server package): the same error, also for a start by the user. A question would not help.
- The sessions that run are never touched. With the mode off, no start checks the server.

### Options

| Option | Default | Meaning |
|---|---|---|
| `claude-code-ide-mailbox-receivers` | nil | The roles and instance IDs that can get messages. nil: all. |
| `claude-code-ide-mailbox-max-pending` | 10 | Mailbox prompts that can wait for one receiver. |
| `claude-code-ide-mailbox-pair-budget` | 30 | Messages from one sender to one receiver in one hour. |
| `claude-code-ide-mailbox-pair-total` | 200 | Messages from one sender to one receiver until `claude-code-ide-mailbox-reset-budgets`. |

- The size limits are constants: `claude-code-ide-mailbox--max-summary` (200) and `claude-code-ide-mailbox--max-text` (16,000). The text limit keeps the `codex queue` command line far below the limit of one argument (128 KiB on Linux).
- The age of the final records is `claude-code-ide-control-done-days`, as for every inbox record.

### Interactions

- **Reload.** `claude-code-ide-reload` turns the mode off and on. The tool names stay the same, so the approvals of the sessions that run stay valid.
- **`claude-code-ide-control-enable-mcp-tools`.** No interaction. The coordinator tools stay the path with approvals and the coordinator credential. The mailbox is the path without them, inside the limits above.
- **Handover.** No hook is necessary. The hold and the inbox move cover the queued messages. The chain covers a later message to the old ID.
- **Restart.** The queued messages are files of the control inbox. The tools come back when the mode turns on.

## Trust

- All sessions run as the same user. A process of the user can already prompt a session: with `codex queue`, or with `emacsclient --eval` when the Emacs server runs.
- **What the mode adds:** each session of this Emacs can prompt each receiver of this Emacs without an approval. That is the purpose of the feature.
- **The guards:** the sender is the authenticated instance; the frame tells the receiver that the text comes from a colleague and ranks below the user; the receivers option limits who can get messages; the limits stop loops and floods; the clean frame and the marker stop terminal keys and a false frame.
- **What no guard stops:** a receiver with broad permissions (for example `--dangerously-skip-permissions`) can act on a harmful request. The frame is advice, not a security boundary. Turn the mode on only when you trust each session of this Emacs.
- The mailbox never runs a command, and never evaluates a part of a message.

## Changes in other files

| File | Change |
|---|---|
| `claude-code-ide.el` | The load point. |
| `claude-code-ide-control.el` | The new helpers `claude-code-ide-control-clean-text` and `claude-code-ide-control-blank-text-p` (the submit uses it too); `claude-code-ide-control--line-ends` does not change. The key `:defer` and the reason `deferred`. The public names `claude-code-ide-control-chain-current` (for `claude-code-ide-control--chain-current`) and `claude-code-ide-control-pending-keys`. The field `key`, the keyword `:key`, its copy in `claude-code-ide-control-move-inbox`, and the helper `claude-code-ide-control-find-key-in-chain`. |
| `claude-code-ide-mcp-server.el` | `claude-code-ide-mcp-server-remove-tools (NAMES)`, out of `claude-code-ide-control-remove-mcp-tools`, which then calls it. |
| `claude-code-ide-session-registry.el` | The public name `claude-code-ide-session-registry-other-emacs-p` for `claude-code-ide-session-registry--other-emacs-p`. The helper `claude-code-ide-session-registry-chain-ids`. |
| `docs/api-control.md` | `:defer`, `deferred`, `:key` and the field `key`, the cleaner, and the new helpers. |
| `claude-code-ide-handover.el`, `tests/claude-code-ide-handover-tests.el` | The calls of `claude-code-ide-session-registry-other-emacs-p` under its public name. |
| `tests/claude-code-ide-live-tests.el` | The live test `claude-code-ide-live-test-mailbox-multi-line-claude`. |
| `tests/claude-code-ide-provider-tests.el` | The load point of the mailbox in the test of the load points. |
| `docs/live-tests.md` | The row of the live test. |
| `README.org` | The section "Mailbox", the feature list, and the package layout. |
| `CLAUDE.md` | The file map and the link to this document. |

## The owner of each rule

| Rule | The one owner | New or reused |
|---|---|---|
| Who the sender is | `claude-code-ide-mcp-request-instance-id` | Reused |
| Valid instance IDs and request IDs | `claude-code-ide-control-valid-id-p` | Reused |
| The current instance of a chain | `claude-code-ide-control-chain-current` | Reused, made public |
| Another Emacs owns an entry | `claude-code-ide-session-registry-other-emacs-p` | Reused, made public |
| The instances of a chain and its root | `claude-code-ide-session-registry-chain-ids` | New, on `claude-code-ide-session-registry-entry-legs`; `claude-code-ide-mailbox--root` takes its first ID |
| A known message in a chain | `claude-code-ide-control-find-key-in-chain` | New, in the control file |
| The key of a record across handovers | The field `key` of the control record | New |
| The checks before a send | `claude-code-ide-mailbox--check` | New |
| The form of the key | `claude-code-ide-mailbox--key` | New |
| Receivers | `claude-code-ide-mailbox--receiver-p` | New |
| The limits | `claude-code-ide-mailbox--limit` | New |
| The frame | `claude-code-ide-mailbox--frame` | New |
| The agent instructions | `claude-code-ide-mailbox--tool-specs` | New |
| A new session needs the MCP tools server | `claude-code-ide-mailbox--check-server` | New, a `:before` advice of `claude-code-ide--start-session` |
| Clean text | `claude-code-ide-control-clean-text` | New, in the control file |
| An empty prompt text | `claude-code-ide-control-blank-text-p` | New, in the control file; the submit calls it too |
| The start of a mailbox prompt | `claude-code-ide-mailbox-frame-prefix` | New |
| Multi-line prompts in Claude Code | `claude-code-ide--claude-submit-prompt` | Reused, not changed |
| The peer list | `claude-code-ide-control-list-instances` | Reused |
| Results as JSON | `claude-code-ide-control-json` | Reused |
| Delivery, state rules, acknowledgement, handover move | `claude-code-ide-control-submit` | Reused |

## Test plan

All tests are in `tests/claude-code-ide-mailbox-tests.el`, which provides `claude-code-ide-mailbox-tests`. The tests of the changed helpers go into the test files of their own files.

- The run isolation of `claude-code-ide-tests--isolate-run` holds. No test touches `~/.claude`, `~/.codex`, or the live state files.
- A test waits with `claude-code-ide-tests--wait-until`, never for a fixed time.
- The budget test runs on `claude-code-ide-tests--call-with-clock`.
- A test calls a tool as an instance with the request instance bound dynamically, as the tests of the MCP routes do. The test of the sender calls it through `claude-code-ide-mcp-server-check-request` with the secret.
- The Codex delivery test runs a small shell script in place of `codex` (`claude-code-ide-codex-cli-path`), as the Codex process tests do.

| Test | It asserts |
|---|---|
| `claude-code-ide-test-mailbox-approval-claude` | With the mode on before the launch and `allowed-tools` at `auto`, the Claude Code command has both tools in `--allowedTools`. With a list that does not name them, it does not. |
| `claude-code-ide-test-mailbox-approval-codex` | With the mode on before the launch, the Codex command has `approval_mode "approve"` for both tools, also for an instance without the coordinator role. |
| `claude-code-ide-test-mailbox-mode-off` | With the mode off, neither tool is in `claude-code-ide-mcp-server-tools`. A direct call of the tool function gives `mode-off`. |
| `claude-code-ide-test-mailbox-no-caller` | A call without a request instance gives `no-caller` and makes no inbox file. |
| `claude-code-ide-test-mailbox-sender-from-request` | Through `check-request` with the secret of instance A, the frame names A. The tool has no argument for a sender. |
| `claude-code-ide-test-mailbox-self` | `to` = the caller gives `self`. `to` = an old ID whose chain ends at the caller gives `self` too. |
| `claude-code-ide-test-mailbox-invalid-ids` | An invalid `to` and an invalid `request_id` give their reasons. |
| `claude-code-ide-test-mailbox-unknown-target` | An ID that nobody knows gives `unknown-instance` and no inbox file. |
| `claude-code-ide-test-mailbox-archived-target` | An archived target gives `archived` and no inbox file. |
| `claude-code-ide-test-mailbox-other-emacs-target` | A target with an open entry of another Emacs that runs gives `other-emacs`. |
| `claude-code-ide-test-mailbox-stopped-target-queued` | A closed target of this Emacs gives `queued`. Its resume delivers the message one time. |
| `claude-code-ide-test-mailbox-handover-chain` | After a committed chain from B to C, a message to B has `destination` C. |
| `claude-code-ide-test-mailbox-deferred` | To an idle receiver: the tool returns `queued` with `deferred`. No provider call happens inside the tool call. One call happens after the timer. |
| `claude-code-ide-test-mailbox-codex-delivery` | A message to an idle Codex instance gives one `codex queue` call with the frame. After the `prompt-submit` event, the result is `delivered`. |
| `claude-code-ide-test-mailbox-claude-busy-waits` | A Claude Code receiver in `working` gets nothing. After `turn-end` and an idle state, it gets the frame one time. |
| `claude-code-ide-test-mailbox-idempotent-retry` | A second call with the same `request_id` gives `duplicate` true and the current result, makes no second provider call, and does not use the budget. Two calls without `request_id` give two request IDs. |
| `claude-code-ide-test-mailbox-frame` | The exact frame for a known sender. The text starts with `[`. A text that contains the marker gets another nonce. |
| `claude-code-ide-test-mailbox-clean-text` | In the frame, for the text, the summary, and a display name: TAB becomes four spaces; CR LF and CR become LF; NUL, ESC, Ctrl-C, DEL, U+0085, U+202E, and U+2067 go. A text without these characters does not change. A `prompt-submit` event with the clean frame acknowledges the message. |
| `claude-code-ide-test-mailbox-other-prompts-unchanged` | A coordinator prompt with a TAB and an ESC reaches the provider without a change, and its text hash is the same as before the mailbox. |
| `claude-code-ide-test-mailbox-multi-line-claude-path` | With a fake terminal backend, a three-line message to Claude Code goes through `claude-code-ide--claude-submit-prompt`: the frame text as it is, then one Return. |
| `claude-code-ide-test-mailbox-size-caps` | A summary of 201 characters, a text of 16,001 characters, and an empty text each give their reason. The limits themselves pass. |
| `claude-code-ide-test-mailbox-receiver-cap` | With 10 mailbox prompts that wait, the next one gives `receiver-busy` with `retry_after` 60. A prompt of a coordinator does not count. After one delivery, a message passes. |
| `claude-code-ide-test-mailbox-pair-budget` | On the virtual clock: message 31 within an hour gives `rate-limited`, and `retry_after` is the time until the first one leaves the window. After that time, a message passes. Another pair is not affected. |
| `claude-code-ide-test-mailbox-budget-across-handovers` | Use up the hourly budget of A to B. After a committed handover of the sender (A to A2), A2 to B gives `rate-limited`. After a committed handover of the receiver (B to B2), A2 to B2 gives `rate-limited` too. The same for the total budget with `budget-spent`. |
| `claude-code-ide-test-mailbox-total-budget` | With `pair-total` 3 and a high hourly budget: message 4 gives `budget-spent`, and the result names the reset command. On the virtual clock, after 2 hours, message 4 still gives `budget-spent`. A turn of the mode off and on does not clear it. After `claude-code-ide-mailbox-reset-budgets`, a message passes. |
| `claude-code-ide-test-mailbox-retry-after-handover` | A message from A to B with `request_id` r1 becomes `delivered` at B. After a committed handover B to C, a retry to B with r1 gives `duplicate` true and `delivered`, C gets no prompt, and C's inbox has no record. The same for a message that was queued at B and moved to C. |
| `claude-code-ide-test-mailbox-retry-after-sender-handover` | A sends r1 to B. After a committed handover A to A2, A2 sends r1 to B: `duplicate` true, no second prompt. |
| `claude-code-ide-test-control-find-key-in-chain` | In the control tests: the helper finds a key in an earlier leg and in the current leg, pending and final; it returns the copy, not the `handed-over` record; an unknown key gives nil. |
| `claude-code-ide-test-control-key-survives-move` | In the control tests: `claude-code-ide-control-move-inbox` keeps `key` on the copy, also when it renames the request ID. A record file without `key` reads as nil, and a submit without `:key` stores nil. |
| `claude-code-ide-test-mailbox-retry-after-two-renames` | A message queued at B with key K. C and D each have another record with the same request ID. After committed handovers B to C and C to D, the copy at D has a request ID of the form `handover:<h2>:handover:<h1>:...`. A retry to B with the same `request_id` returns the result of the copy at D with `duplicate` true, and no instance gets a new prompt. |
| `claude-code-ide-test-mailbox-cap-counts-renamed` | Ten mailbox records that wait at C, each moved there by a handover under a `handover:...` request ID: the next message to C gives `receiver-busy`. |
| `claude-code-ide-test-session-registry-chain-ids` | In the registry tests: the IDs of a chain of three legs, oldest first, from each of its three instances; an instance without a chain gives its own ID. |
| `claude-code-ide-test-mailbox-receivers-option` | With the option nil, all instances get messages. With a role and an ID in the list, only those instances get them; the others give `not-a-receiver` and are not in `list-peers`. |
| `claude-code-ide-test-mailbox-list-peers` | The list has the fields of the table, the instances that run in this Emacs, not the caller, and no prompt text. |
| `claude-code-ide-test-mailbox-mode-on-warnings` | With a session that runs, the mode shows the restart warning with the number. With the MCP server off, it shows no server warning. |
| `claude-code-ide-test-mailbox-start-asks-for-server` | With the server off, a start by the user asks one time; yes turns the server on, and the instance starts. |
| `claude-code-ide-test-mailbox-start-no-stops` | No gives a `user-error` that names `claude-code-ide-enable-mcp-server`, and nothing starts. |
| `claude-code-ide-test-mailbox-start-non-interactive-refused` | A coordinator launch gives `mailbox-needs-mcp-server` without a question; a start without the user is refused; a server that is on but does not start refuses a start by the user too. |
| `claude-code-ide-test-mailbox-start-without-check` | With the server on, a start asks nothing; with the mode off, no start checks the server. |
| `claude-code-ide-test-mailbox-registry-on` | The mode turns `claude-code-ide-session-registry-mode` on. |
| `claude-code-ide-test-mailbox-reload` | Off and on two times: each tool is in the tool list one time, with the same name. |
| `claude-code-ide-test-mailbox-request-id-collision` | An unrelated record with the request ID `mailbox:ROOT:RID` and no key does not stop the message: it is queued with its key. Two `unknown-instance` results of the control inbox use no budget. |
| `claude-code-ide-test-mailbox-receivers-after-handover` | With an instance ID in the receivers option, a message to it after a handover goes to the new instance, and `list-peers` lists the new instance. |
| `claude-code-ide-test-mailbox-empty-after-clean` | A text of control characters only gives `empty-text`; the size limit counts the clean text. |
| `claude-code-ide-test-mailbox-retry-before-other-checks` | A retry gets its result also when the receiver left the receivers option, or was archived. |
| `claude-code-ide-test-mailbox-self-during-handover` | Before the commit of A to A2, a message from A2 to A, and from A to A2, gives `self`. |
| `claude-code-ide-test-mailbox-pair-budget-zero` | With a pair budget of 0, a message gives `rate-limited` without `retry_after`. |
| `claude-code-ide-test-mailbox-retry-refreshes` | On the virtual clock: a retry to a stopped receiver gives `unacknowledged` after the time limit of the acknowledgement. |
| `claude-code-ide-test-mailbox-total-before-hourly` | When both budgets are spent, the reason is `budget-spent`. |
| `claude-code-ide-test-mailbox-deferred-survives-restart` | A deferred record is still pending after the index is cleared, and goes out. |
| `claude-code-ide-test-control-defer-key` | In the control tests: `:defer t` queues a prompt for an idle instance with `deferred` and sends it from the timer. Without the key, the behaviour does not change. |

One live test goes into `tests/claude-code-ide-live-tests.el`:

| Test | It asserts |
|---|---|
| `claude-code-ide-live-test-mailbox-multi-line-claude` | Gated like the other live tests (`claude-code-ide-live-tests--live`, `CLAUDE_CODE_IDE_LIVE_TESTS=1`, an own `emacs -Q` daemon). A Codex or Claude Code sender calls `claude-code-ide-send-message` with a text of three lines to a real Claude Code instance. The `prompt` of its one `UserPromptSubmit` event equals the full frame, and the request becomes `delivered`. |

## Left out

- **The file drop.** A later front end for senders outside Emacs (shell scripts, cron, another Emacs). It can use the same frame, the same checks, and the same limits.
- **Delivery across Emacs processes.** The control index is per Emacs. The reason `other-emacs` makes the limit visible.
- **Display names as targets.** They can be equal, nil, or change. `list-peers` gives the IDs.
- **`claude-code-ide-mailbox-allowed-senders`.** With a verified sender, the receivers option covers the lateral risk.
- **A roster file and an instruction hook.** The tool descriptions and `list-peers` do the same work.
- **Notices to the sender** after the return. A retry with the same `request_id` gives the current result.
- **The queue depth in the status snapshot.** `list-peers` has `queued`. Add it when a coordinator outside Emacs needs it.
- **A pointer to a file for long messages.** The text limit keeps each message inline.
- **The cleaner for every prompt.** A later change. It changes the text and the hash of coordinator prompts, review results, and handover prompts, so it needs a live check of the acknowledgement hash first.
- **Bracketed paste for Claude Code.** A later change, if the live test shows that raw line feeds break a prompt. Risk: Claude Code can show a long paste as "[Pasted text #1]". When the `UserPromptSubmit` hook gets that short form, the acknowledgement never matches.

## Open questions

Each question has a recommendation. "Design" marks the answer that this document follows.

1. **The default of the mode.** Recommendation: off. Design: off.
2. **The cleaner for every prompt.** Recommendation: later, after a live check of the acknowledgement hash. Design: only the mailbox frame uses it.
3. **Bracketed paste for Claude Code.** Recommendation: not now; keep the submit path of today and run the live test. Design: no bracketed paste.
4. **The limits.** Recommendation: 10 prompts that wait for each receiver; for each pair of chain roots, 30 messages an hour and 200 in total until `claude-code-ide-mailbox-reset-budgets`. Design: these defaults.
5. **The receivers default.** Recommendation: nil (all instances), because the mode is off by default. Design: nil.
6. **`:defer t` for the coordinator tool `submit-prompt` too.** Recommendation: yes, in a separate change, because it sends inside the filter today. Design: only the mailbox uses `:defer t`.
7. **ID only, or also a unique display name as `to`.** Recommendation: ID only. Design: ID only.
