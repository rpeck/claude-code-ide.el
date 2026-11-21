# Status events of Codex instances

This document describes how Emacs gets the status of a Codex instance:

- The hook script.
- The hook arguments and the environment of a launch.
- The hook trust: the check at each launch and the trust command.
- The event files.
- The mapping of each Codex event to the common events and the common states.
- The startup dialogs.
- The states of Claude Code and Codex sessions without status hooks.

Code: `claude-code-ide-codex-events.el`. The common events and states are in [session-schema.md](session-schema.md). The status snapshot is in [status-schema.md](status-schema.md).

Facts from tests T1 and T2 on Codex 0.164.0.

## Overview

1. The Codex launch adds the hook arguments of `claude-code-ide-codex-status-hook-args` to the command, and the environment of `claude-code-ide-codex-status-hook-env` to the terminal. It calls them only when they are bound, so the launch also works without this file.
2. Codex runs the hook script at each hook event. The script writes one event file.
3. Emacs reads the event files in order, checks the launch identity, and changes the status of the instance.
4. Emacs passes each current event to `claude-code-ide-dispatch-event`.
5. The status buffer and the status snapshot show the common state.

## The hook script

- **File:** `<report directory>/codex-hooks/claude-code-ide-codex-status-hook.sh`.
- **Folder:** private, mode `0700`. Emacs sets the mode again when it differs. Emacs refuses a folder that is a symbolic link.
- **Install:** Emacs writes the script to a temporary file in the same folder, sets mode `0700`, and renames it. So Codex never runs a part of the script.
- **Check:** at each launch, Emacs compares the content with the script in the package. A different content, or a mode that lets others write, makes Emacs write the script again.
- **Why:** Codex trusts the hook command, not the script. A person who can write the script can run code in each tracked session.

The script does these steps:

1. It sends its output to `/dev/null`, and it always exits with 0. So it never changes what Codex does.
2. It exits at once when `CODEX_THREAD_ID` is set, or when `CCI_INSTANCE_ID` is not set. It reads its input first, so that Codex can write it.
   - A nested Codex session (started by the agent) has `CODEX_THREAD_ID`. A top-level session does not.
3. It exits when a value does not fit a file name:
   - `CCI_INSTANCE_ID` must have only letters, digits, and `-`.
   - `CCI_GENERATION` must have only digits.
   - The event name must have only letters.
   - `CCI_EVENTS_DIR` must be a folder.
4. It writes the record to a temporary file: `{"event": EVENT, "instance_id": ID, "generation": "N", "input": STDIN}`.
5. It takes a lock for the launch, increments the counter of the launch, and renames the file to its final name.

### The time limit of the lock

The Claude Code hook script and the Codex hook script share one lock section. Emacs writes it into both scripts when it installs them (`claude-code-ide-session-status--lock-loop`).

- **Real time.** The section reads the time with `date +%s` at each try. `%s` is a common extension of `date` (macOS, GNU, and BSD have it), not POSIX. It gives up when more than `claude-code-ide-session-status-hook-time-limit` seconds (default 10) have passed, however slow the machine is. The real wait is between the limit and the limit plus one second.
- **Without a good clock.** The section counts from the first `date` that gives a number. A clock that steps back counts as the end of the wait. When `date` never gives a number, the number of tries stands in for the seconds (20 a second).
- **A cap of tries.** The section also gives up after 20 tries for each second of the limit (200 at 10 s). That backstop needs no clock, for example when the clock does not move.
- **Few processes.** A try runs `mkdir`, one `date`, and one `sleep 0.05`. The `pid` of the holder is read once a second at most.
- **Giving up.** The hook removes its temporary file, drops its event, and exits with 0. So it never fails the tool call of the CLI. It writes one line to `hook-errors.log` in the events folder. At 64 KiB the log moves to `hook-errors.log.1` (one old generation) first.
- **The status buffer shows dropped events.** When the logs (of Claude Code and Codex, with their `.1` files) have lines that you did not look at, the first line of the status buffer says how many events were dropped. RET on that line shows the log and clears the notice.
- **A dead holder.** From 2 seconds of waiting on (earlier for a limit under 3 seconds), once a second, the hook reads the PID of the holder. When that process is gone, the hook tries to get the break token `<lock>.break` (an atomic `mkdir`). Only the waiter with the token breaks the lock, and only if the PID is still the one it saw dead; then it removes the token. A waiter without the token waits on. Emacs removes locks and tokens older than 3 seconds too.
- **The true holder.** A child `sh` holds the lock and numbers the event. It writes its own PID into the lock, so a waiter sees the process that really holds the lock.
- **The CLI timeout.** Claude Code and Codex stop a hook at its timeout. Both get the limit plus 5 seconds (15 s at the default), so the script always gives up first.
- **One value for each report directory.** The limit is a defcustom. Emacs writes it into the scripts (`limit=10`), and the content check at each launch rewrites a script with another value. A change applies to the next start.
  - The scripts are in the report directory, which every Emacs with the same `claude-code-ide-state-file` shares. The last start writes the limit for all of them. There are no scripts for each Emacs.
- **A new limit needs a new Codex trust.** The Codex hook definition holds the timeout, so another limit changes the definition and its trust hash. The next interactive Codex start asks you once to trust the hooks again (see "Hook trust"). The hook command stays the same.

## Hook arguments and environment

`(claude-code-ide-codex-status-hook-args INSTANCE)` returns the list `("-c" "hooks.SessionStart=[...]" "-c" "hooks.SessionEnd=[...]" ...)`.

- The events, in this order: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`, `Interrupt`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PostModelRequest`, `SubagentStart`, `SubagentStop`.
- Each value is `hooks.<Event>=[{hooks=[{type="command",command="sh <script> <Event>",timeout=15}]}]`. The timeout is `claude-code-ide-session-status-hook-time-limit` plus 5 seconds (see "The time limit of the lock").
- The command is a TOML basic string.
- The list is the same for each instance and each launch. One trust covers all launches.
- **Never change a definition or its position.** Codex keeps the trust under the key `<source>:<event>:<group>:<handler>`. A changed definition gets a new hash, and the user must trust it again.
- The script path is part of the command. A new report directory therefore needs a new trust.

`(claude-code-ide-codex-status-hook-env INSTANCE)` returns:

```
("CCI_INSTANCE_ID=<instance id>" "CCI_GENERATION=<generation>" "CCI_EVENTS_DIR=<events folder>")
```

- The events folder is `<report directory>/events-<emacs pid>/codex`, mode `0700`.
- Both functions start to track the current launch of INSTANCE. A second call for the same launch does nothing more.
- Both functions return nil when `claude-code-ide-session-status-tracking` is nil, or when the script cannot be installed. The launch then adds nothing, and the instance has no status events.

## Hook trust

Codex runs a hook only after the user trusts it. `codex exec` and the terminal UI skip an untrusted hook without a message.

### The trust at each start

Emacs settles the trust before a Codex instance spawns, so that the user never needs to remember a trust command.

1. **The interactive flag.** The start spec has the slot `interactive` (the last slot of `claude-code-ide-start-spec`). It is non-nil only for a start that the user asked for now.
   - `claude-code-ide`, `claude-code-ide-continue`, `claude-code-ide-resume` (also from the menu), `claude-code-ide-codex`, `claude-code-ide-codex-continue`, and `claude-code-ide-codex-resume` pass `called-interactively-p` as the 4th argument INTERACTIVE of `claude-code-ide--start-session`. The start puts it in the slot of the launch spec. A spec whose slot is set wins over the argument.
   - The Codex launch, resume, and fork operations pass the slot to `claude-code-ide-codex-status-hook-args`, as its optional 2nd argument.
   - Other starts (a restore at Emacs start, a coordinator launch, a timer, a call from Lisp) have nil.
2. **The cache.** The key holds three parts:
   - A SHA-256 hash of the hook definitions (the hook arguments, which contain the script path).
   - The path of the Codex config file: `claude-code-ide-transcript--codex-config-file`, which gives `config.toml` in `CODEX_HOME`, else in `$HOME/.codex`.
   - The Codex program: the true path of `claude-code-ide-codex-events-program`, with the modification time and the size of that file. An update of Codex changes them. No process runs for it.

   A cached result is valid as follows:
   - A `trusted` result stores the exact `hooks.state` key and the `currentHash` that `hooks/list` reported for each of our hooks. A start reads `config.toml` (read only, with the tolerant TOML reader of `claude-code-ide-transcript.el`), and the entry is valid while each key has `trusted_hash` equal to its stored hash and no `enabled = false`. Other writes do not matter: a Codex terminal writes the file at each start (`[tui]` keys).
   - The file is read with `claude-code-ide-transcript--codex-config-entries`, the one reader of the Codex config entries.
   - Each record needs a non-empty key and a non-empty hash. An empty list of records never makes an entry valid. A trusted result with a trusted hook that has no key or no hash is not cached.
   - Managed hooks have no record in `config.toml`. A trusted result with managed hooks is valid for 60 seconds after its check, so `hooks/list` checks it again at most once a minute.
   - The entry is invalid when a key is missing, a hash differs, a hook is disabled, or the file is missing, unreadable, or has a TOML form that the reader does not know. No error comes from it. Then an interactive start checks again (and asks if needed), and another start gets no hooks and starts the background check.
   - An `untrusted` or `disabled` result holds only while `config.toml` keeps the modification time and the size of the check, because `/hooks` in a terminal can trust or enable the hooks.
   - Other hook definitions (a new package version), another `CODEX_HOME`, or another Codex give another key. They miss the cache, and the next interactive start asks again.
3. **The check.** On a cache miss, Emacs starts `codex app-server` with the hook arguments, over stdio, in the project folder, and sends `initialize`, `initialized`, and `hooks/list` with the project folder in `cwds`.
   - Starts of the same key share one running check and one app-server.
   - The status hooks of the package are the hooks with `source` `sessionFlags` whose command runs the script.
   - A hook counts as trusted when `trustStatus` is `trusted` or `managed`, and `enabled` is not false.
   - Results: `trusted`; `untrusted` (some hooks are enabled and not trusted); `disabled` (the hooks that Codex does not run are all disabled with `/hooks`); `error`.
   - The check ends with its answer, or after 30 seconds. Its result goes to the cache and to the launches without hooks.
4. **The wait.**
   - An interactive start waits for the check at most `claude-code-ide-codex-events-trust-timeout` seconds (5). A C-g in the wait or in the question still frees the check, so its app-server ends.
   - After a yes, the trust write and the second `hooks/list` each get the full limit again.
   - Another start never waits. On a cache miss it starts without hooks at once, and the check fills the cache for the next start.
5. **The decision.** A launch gets hooks only when the trust is confirmed:

| Result | Interactive start | Other start |
|---|---|---|
| Trusted (cache or check) | Hooks. | Hooks. |
| Not trusted | Emacs shows the hooks and asks. It uses the result of the check and the app-server of the check. Yes: the trust is written, and the instance starts with its trusted hooks. No: no hooks, and no start asks again in this Emacs. C-g: no hooks, and the next start asks again. | No question. No hooks. Detail "Hooks not trusted; the next interactive start asks". |
| Declined before in this Emacs | No question. No hooks. Detail "Hooks not trusted; M-x claude-code-ide-codex-trust-hooks trusts them". | The same. |
| Disabled with `/hooks` | No question. No hooks. Detail "Hooks disabled in Codex (/hooks)". | The same. |
| Not known in time | No question. No hooks. Detail "Hook trust unknown: no answer in 5 s; the check goes on for the next start". | No hooks. Detail "Hook trust not known at the start; a check runs for the next start". |
| Error (for example no Codex program) | No hooks. Detail "Hook trust unknown: ...". | The same. |

- **No hooks** means no hook arguments and no hook environment. So Codex shows no "Hooks need review" dialog for them.
- **A launch without hooks** has no status events. Its state is `disconnected/untracked`, whatever a later check says. When a later check finds the hooks trusted, its detail becomes "Hooks were not trusted at the launch: restart to get status".
- **A launch with hooks** keeps them. Codex read the trust at its start.
- **Never without a yes.** Emacs writes the trust only after the yes of `yes-or-no-p`.

### A restore of the user

`M-x claude-code-ide-restore-sessions` asks at most one time for the whole restore. The automatic restore at Emacs start never asks.

- When it starts at least one Codex instance, the restore command calls `(claude-code-ide-codex-prepare-trust DIRECTORY)` one time, before it schedules the starts.
  - It returns non-nil when the hooks are trusted: from the cache, or after one question and a yes.
  - It returns nil at once, with no app-server, when the user declined in this Emacs.
- The starts run from timers, and they are never interactive. So no start asks and no start waits.
  - After a yes, the trusted result is in the cache, and each start gets its hooks on the cache hit.
  - After a no, the starts get no hooks.

### The trust command

`M-x claude-code-ide-codex-trust-hooks` trusts the hooks by hand, for example after a no. It lists the hooks in the home folder. An interactive start and `claude-code-ide-codex-prepare-trust` use the same steps, with the result of their check:

1. It starts the app-server with the hook arguments and calls `hooks/list`.
2. It shows the hooks that Codex does not run yet, with their event, command, trust status, and key, in the buffer `*Codex status hooks*`.
3. It asks with `yes-or-no-p`.
4. It calls `config/batchWrite`. Each edit has `keyPath` `hooks.state`, `mergeStrategy` `upsert`, and the value `{KEY: {trusted_hash: CURRENT-HASH}}`, with the hash that `hooks/list` gave.
5. It calls `hooks/list` again and reports the result.

- The app-server has no method only for hook trust. `config/batchWrite` is the method that the terminal UI uses. It writes the same records as `/hooks`:
  ```toml
  [hooks.state."/<session-flags>/config.toml:stop:0:0"]
  trusted_hash = "sha256:..."
  ```
- The upsert merges the keys. Other keys in `hooks.state` stay, for example `enabled = false`.
- A hook that `/hooks` disabled stays disabled. The command says so.
- If `config/batchWrite` fails, the command tells the user to run `/hooks` in a Codex terminal. In a start, the failure gives no hooks and that text in the detail.
- After a yes, a start does not count as declined any more, also after an earlier no.
- Instances that run already get status only after a restart.

## Event files

- **Folder:** `CCI_EVENTS_DIR`.
- **Name:** `<instance id>.<generation>.<sequence>.<Event>.json`. The sequence has 8 digits and counts the events of one launch.
- **Content:** `{"event": "Stop", "instance_id": "...", "generation": "3", "input": {...}}`. `input` is the stdin JSON of the hook.

Emacs reads the files at a file notification, and every 2 seconds. For each file:

1. The instance ID must have a launch record, and the generation must be the generation of that record. The record exists only for the current launch of a running instance.
2. The content must name the same event, instance ID, and generation as the file name.
3. The common event must be current (`claude-code-ide-event-current-p`).
4. The `session_id` of the input must be the conversation of the launch. The first `session_id` that comes sets it.
   - A `SessionStart` of the main agent with another `session_id` moves the launch to that conversation. This happens after `/new`, or after a switch to another thread in the terminal. The descriptor gets the new native ID.
   - Another event with an unknown `session_id` is dropped. A nested session has its own `session_id`; its `SessionStart` never comes, because the script drops it (`CODEX_THREAD_ID`).
5. Emacs applies the event, notes the `model` and the native ID in the descriptor, and dispatches the common event.

Emacs deletes each file, also a file that it does not apply. Locks older than 3 seconds are deleted.

So an event of an earlier launch (for example before a resume) changes nothing, and nothing is dispatched for it.

## Event mapping

| Codex event | Common event | Change of the status |
|---|---|---|
| `SessionStart` | `session-start` | `idle` "Ready". Clears tools, blockers, subagents, and a failure. |
| `UserPromptSubmit` | `prompt-submit` | `working`. Clears the blockers of the main agent and a failure. |
| `PreToolUse` | `tool-start` | Records the tool. Main agent: `working`. `request_user_input`: `waiting-for-user/question`, not a guess. |
| `PermissionRequest` | `approval-request` | `waiting-for-user/approval` for its tool (see "Matching an approval to its tool"). |
| `PostToolUse` | `tool-end` | Ends the tool and its blockers. Main agent: `working`. |
| `Interrupt` | `interrupt` | `idle` "Interrupted". Ends the tools and blockers of the main agent. |
| `Stop` | `turn-end` | `idle`, with the first line of `last_assistant_message`. A line that matches `claude-code-ide-session-status-ask-regexps` gives `waiting-for-user/question` as a guess. |
| `PostModelRequest`, `status: "failed"` | `turn-failed` | `failed/error`, or `failed/quota-limit` when the error is a usage limit (see "Quota limits"). No `Stop` follows. |
| `PostModelRequest`, other | `other` | Main agent after a failure or at the start: `working`. Codex retries a failed request, so a later answer ends the failure. |
| `SubagentStart` | `subagent-start` | `waiting-for-task/subagent` while the agent runs. |
| `SubagentStop` | `subagent-end` | Ends the agent, its tools, and its blockers. |
| `SessionEnd` | `session-end` | `disconnected` "Session ended". |

Rules:

- **Subagents.** An event with `agent_id` belongs to a subagent. It never changes the turn of the main agent. A subagent's approval or question waits for the user too.
- **Deny and Esc.** Both give only `Interrupt`. Emacs cannot tell them apart.
- **Allow.** No event shows it. The approval stays until the `PostToolUse` of the tool, a `Stop`, an `Interrupt`, or the end of the session. Without a screen read that confirms the dialog, the approval is a guess after `claude-code-ide-codex-events-approval-guess-time` (10 seconds). The result of a screen read belongs to each approval of the main agent, so the end of a subagent does not change it.
- **A screen read without the dialog.** `claude-code-ide-codex-events-approval-end` decides whether it ends the wait for an approval:

| Value | A read without the dialog ends the wait | Use |
|---|---|---|
| `window` (default) | Only when a window of a display shows the terminal | An eat buffer without a window keeps only the last lines of a dialog, so the read can miss it. Then only an event ends the wait. |
| `event` | Never | A long tool run after an allow shows as `waiting-for-user/approval` (a guess after 10 s) until its `PostToolUse`. |
| `screen` | Always | The rule before 1.2.0. In an eat buffer without a window, an open dialog can show as `working`. |

- **Which window counts.** `claude-code-ide-codex-screen-window` gives a window of the terminal buffer on a frame of a display, visible or not. VERIFIED in an `emacs -Q` daemon:
  - The initial frame of a daemon (and the frame of batch Emacs) is on the terminal `initial_terminal`. It says that it is visible (`frame-visible-p` is t), but nobody sees it. Its window does not count.
  - A frame that is not visible, on a display (`(make-frame '((window-system . ns) (visibility . nil)))`), counts. `get-buffer-window` with ALL-FRAMES t finds its window; `visible` and 0 do not. L's live test showed that the terminal in such a window keeps the whole dialog.
  - A daemon without a client frame has no window that counts. Its eat buffers keep the tail of a dialog only (L's bug 3: "Field 1/1", "› 1. Allow  Run the tool and", "option 1/2 | enter to submit | esc").
- **Automatic review.** It gives the same events as a user dialog.
- **Background terminals** give no events. So Codex never shows `waiting-for-task/background-task`.
- **A killed terminal buffer** gives no `SessionEnd`. The process check of `claude-code-ide-instance-state` gives `disconnected`.
### Matching an approval to its tool

- A `PermissionRequest` with a `tool_use_id` of a tool in flight belongs to that tool.
- Codex 0.164.0 sends no `tool_use_id`. Then the request belongs to the newest tool in flight with the same agent and the same tool name, whose `tool_input` fields all have the same values in the request, and that has no approval yet.
- The request input has fields that the tool input lacks, for example `description`. They do not count.
- So with parallel tools, the `PostToolUse` of one tool does not end the approval of another tool.

### Quota limits

Two regexps decide whether an error text reports the usage limit of the account. Both are matched without case.

- `claude-code-ide-session-status-quota-regexp` matches texts such as "usage limit", "plan limit", "quota", "credits depleted", "out of credits", "hit your limit", "spend cap", "usage not included", and "5-hour limit" or "weekly limit".
- `claude-code-ide-session-status-transient-regexp` matches the texts of short limits: "per minute", "tokens per min", RPM or TPM, "retry after", and "try again in" a number of seconds. A text that matches it is never a usage limit, also when it says "quota". Examples: the Gemini text "Quota exceeded for quota metric '... requests per minute'", and the Azure text "... Please retry after 6 seconds".
- "Try again at" a time does not match the second regexp. Codex says so at a usage limit.

For Codex, the error kind decides first:

- `claude-code-ide-codex-events-error-kind-states` maps each kind (`codex_error_info` of the rollout, in snake case) to `quota-limit` or `error`.
  - The defaults: `usage_limit_exceeded`, `session_budget_exceeded`, and `usage_not_included` give `quota-limit`.
  - `rate_limit_exceeded`, `server_overloaded`, `response_too_many_failed_attempts`, the connection kinds, and the other kinds of the schema give `error`.
- A kind that is not in the list, such as `other`, and no kind leave it to the text. The hooks give no kind, only the text.
- **A plan without Codex.** The kind `usage_not_included`, or a text that matches `claude-code-ide-codex-events-not-included-regexp` ("usage not included", "with your ChatGPT plan, upgrade to"), is `failed/quota-limit` with the detail "Not included in the plan: ...". The state plist has `:not-included t`. See "A plan without Codex".

| Provider | Event | State | Detail |
|---|---|---|---|
| Claude Code | `StopFailure`, `error: "billing_error"` | `failed/quota-limit` | "Quota limit: <text>" |
| Claude Code | `StopFailure`, `error: "rate_limit"`, and `error_details` matches the regexp | `failed/quota-limit` | "Quota limit: <text>" |
| Claude Code | `StopFailure`, `error: "rate_limit"`, a blank `error_details`, and `last_assistant_message` matches the regexp (the limit message of the CLI) | `failed/quota-limit` | "Quota limit: <text>" |
| Claude Code | `StopFailure`, `error: "rate_limit"`, other | `failed/error` | "Error: rate limit", plus `error_details` when it has text |
| Claude Code | `StopFailure`, other | `failed/error` | "Error: <error>" |
| Codex | `PostModelRequest`, `status: "failed"`, and `error` says that the plan does not include Codex | `failed/quota-limit` | "Not included in the plan: <error>" |
| Codex | `PostModelRequest`, `status: "failed"`, and `error` is a usage limit by the regexps | `failed/quota-limit` | "Quota limit: <error>" |
| Codex | `PostModelRequest`, `status: "failed"`, other | `failed/error` | "Error: <error>" |
| Codex, without hooks | rollout `task_complete` with a kind of `quota-limit` in the alist | `failed/quota-limit` | "From rollout: Quota limit: <message>" |
| Codex, without hooks | rollout `task_complete` with a kind of `error` in the alist | `failed/error` | "From rollout: Error: <message>" |
| Codex, without hooks | rollout `task_complete` with another kind, or none | by the text, as for the hooks | "From rollout: ..." |

- `<text>` is `error_details`, else `last_assistant_message`, else `error`.
- `<message>` is `error.message`, else the kind, else "unknown error".

#### The Codex 0.164.0 usage limit

No usage-limit record exists on this machine, so no live run shows one. These facts come from the binary (`strings`) and from `codex app-server generate-json-schema`:

- **VERIFIED: the hook has only a text.** A failed `PostModelRequest` has `status`, `error` (a string), and `token_usage` (null). It has no error kind. Its `status` is `completed`, `failed`, or `cancelled`.
- **VERIFIED: the rollout has the kind.** A failed turn ends with `task_complete`, whose `error` is `{message, codex_error_info}`. In a real run (an unknown model), `error.message` was the same text as the hook `error`, and `codex_error_info` was `other`.
- **VERIFIED: the error kinds.** `CodexErrorInfo` of the app-server schema: `contextWindowExceeded`, `sessionBudgetExceeded`, `usageLimitExceeded`, `rateLimitExceeded`, `flexUnavailable`, `serverOverloaded`, `cyberPolicy`, `misalignmentPolicyViolation`, `tooManyDenials`, `internalServerError`, `unauthorized`, `badRequest`, `threadRollbackFailed`, `sandboxError`, `other`. With an HTTP status: `httpConnectionFailed`, `responseStreamConnectionFailed`, `responseStreamDisconnected`, `responseTooManyFailedAttempts`. The rollout writes them in snake case (`usage_limit_exceeded`), and an object kind as `{"http_connection_failed": {"http_status_code": 429}}`.
- **VERIFIED: the texts in the binary.** Each of these is `failed/quota-limit`:
  - "You’ve hit your usage limit." with a hint, for example "Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus)," and " or try again at ". The apostrophe is U+2019.
  - "Quota exceeded. Check your plan and billing details."
  - "To use Codex with your ChatGPT plan, upgrade to Plus: https://chatgpt.com/explore/plus." (the kind `usage_not_included`).
  - "Your workspace is out of credits. ..." and "You hit your spend cap ...".
  - "Usage limit reached. ..." and "Your included usage is exhausted. ..." (texts of the terminal UI).
- **VERIFIED: the texts of short limits.** Each of these is `failed/error`: "exceeded retry limit, last status: ...", "Selected model is at capacity. Please try a different model.", and "We’re currently experiencing high demand, which may cause temporary errors.".
- **NOT VERIFIED: a per-minute rate limit.** The text "exceeded retry limit" shows that Codex retries a failed request. So a short rate limit probably fails the turn only after the retries, with that text or the kind `rate_limit_exceeded`. Both are `failed/error`.
- **NOT VERIFIED: which text a usage limit gives in the hook.** The display text ("You’ve hit your usage limit ...") is the most likely, because Codex turns the server answer `usage_limit_reached` into its own error. A raw server body with `usage_limit_reached`, `usage_not_included`, or `insufficient_quota` also matches the regexp.
- **NOT VERIFIED: the kind of `Quota exceeded` and `usage not included`.** `CodexErrorInfo` has no own value for them. Emacs uses the text for them, and the kind `usage_not_included` in case a rollout has it.

The tests use these texts as fixtures (`claude-code-ide-codex-events-tests--quota-texts` and `--transient-texts`).

### The order of the states

`claude-code-ide-codex-events--state` takes the first rule that applies:

1. `SessionEnd` came: `disconnected`.
2. A failed model request: `failed/error` or `failed/quota-limit`.
3. An open question: `waiting-for-user/question`.
4. An open approval:
   - The screen shows the approval dialog, also only its tail: `waiting-for-user/approval`, not a guess.
   - A read found no dialog, and the rule of `claude-code-ide-codex-events-approval-end` lets that end the wait (by default: a window of a display shows the terminal): `working`, a guess ("Approved, runs?").
   - Else: `waiting-for-user/approval`, a guess after 10 seconds.
5. A startup dialog on the screen: `waiting-for-user/dialog`.
6. A subagent runs: `waiting-for-task/subagent`.
7. No event yet. Codex sends `SessionStart` only with the first prompt:
   - The hooks were not trusted at the launch: `disconnected/untracked`.
   - In the first `claude-code-ide-codex-events-startup-grace` seconds (3): `working/starting` "Starting", a guess.
   - The screen read found no dialog: `idle`, a guess. The composer waits for the first prompt.
   - No screen read: `working/starting` "Starting: no event yet", a guess.
8. The turn ended: `idle`, or `waiting-for-user/question` as a guess.
9. Else `working`.

## Startup dialogs

The Codex launch defines `(claude-code-ide-codex-screen-dialog BUFFER)`. It returns nil, or `folder-trust`, `update`, `hooks-review`, `approval`, or `other`. It reads only the visible text of the terminal BUFFER, and it never sends keys.

- Emacs calls it through `fboundp`, every 2 seconds, in two cases:
  - No event came yet, after the startup grace time.
  - An approval of the main agent is open, 1.5 seconds after its `PermissionRequest`. Codex draws the dialog after the event.
- The result stays until the next event of the main agent.
- Without the function, no screen is read.

## Claude Code sessions without status hooks

A Claude Code CLI reads its hooks only at its start. A session that started before the status tracking was on has no hooks, and a restart would stop its work. Its state comes from the file that each CLI process keeps about itself: `<config>/sessions/<pid>.json`. `<config>` is `CLAUDE_CONFIG_DIR` when that is an absolute folder; an empty, relative, or missing value counts as unset, and then it is `~/.claude`.

- **Which sessions.** Only a Claude Code session without a status record uses the file, and only while its terminal process runs. A session with hooks always uses its hooks.
- **Which file.** The file of the session's CLI PID: `claude-code-ide-mcp-session-cli-pid`, which `ide_connected` sets (only an integer counts), else the PID of the terminal process.
- **Which process.** When Emacs first sees the PID of a session, it records the start time of that process. The file counts only when:
  - it names that PID;
  - its start time is within 1 second of the recorded start (`procStart`, a UTC text such as "Tue Nov 17 22:25:15 2026"; when that does not parse, `startedAt` in milliseconds);
  - the process that holds the PID now has the recorded start too.

  So a reused PID never gives the state of another process. The registry reads the file (`claude-code-ide-session-registry--read-cli-session`) and compares the starts (`--same-start-p`, one tolerance of 1 second).
- **The states:**

| The file | Common state | Status buffer | Detail |
|---|---|---|---|
| `status` `busy` | `working` | WORKING | "From CLI status: busy" |
| `status` `idle` | `idle` | WAITS FOR YOU | "From CLI status: idle" |
| `status` `shell` | `idle` | WAITS FOR YOU | "From CLI status: idle, a background shell runs" |
| another status, or none | `disconnected/untracked` | UNTRACKED | "CLI status X is not known" |
| no file | `disconnected/untracked` | UNTRACKED | "no CLI status file" |
| a file that cannot be read, or with no start time | `disconnected/untracked` | UNTRACKED | "CLI status file not readable" |
| a file of another process | `disconnected/untracked` | UNTRACKED | "the CLI status file is of another process" |

- A background shell is `idle`, as with the hooks: the agent waits for you while the shell runs. So `w` visits such a session, and a handover needs no force.
- UNTRACKED is not urgent. NO SIGNAL is only for a session with hooks that sent no event.
- The CLI reports `busy` and `idle` itself, so `:guess` is nil. The state plist has the extra key `:source` with the value `cli-file`. An UNTRACKED state has no `:source`.
- The state starts at `statusUpdatedAt` (milliseconds), else at `updatedAt`. So the status buffer shows its age.
- `claude-code-ide-instance-state`, the status snapshot, and the control operations use the same state.
- **Cheap polling.** The state of a session is computed once for each refresh (one NOW), and the start of each process is asked once for each refresh. The file is read only when its modification time changed. The cache is keyed by session and weak, so it goes with the session. Emacs never writes the file.
- `T` in the status buffer still restarts such a session with hooks.

## Codex sessions without status hooks

Codex keeps no status file for each process. But it appends each turn to the rollout file of the conversation, `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<time>-<native id>.jsonl`. For a Codex instance without status hooks, the last turn record of that file gives the state, as a guess.

- **Which instances.** A Codex instance without a launch record, or whose launch has no hooks (the hooks were not trusted at the launch). A launch with hooks always uses its hooks. A launch without hooks whose screen shows a startup dialog shows the dialog (`:source` `screen`).
- **Which file.** The `transcript` operation of the Codex provider finds it: `(claude-code-ide-provider-call 'codex 'transcript INSTANCE 'file)`. See [providers.md](providers.md), section "The transcript operation".
  - Without a known native ID, the provider is not asked. A new Codex session has no native ID until its first prompt, so it stays UNTRACKED. A resumed session has its native ID.
  - Without the `codex` provider, without its `transcript` operation, or on an error, no file is known. The release without that operation gives no rollout state.
- **Which conversation.** The session record of the file (`session_meta`, read by `claude-code-ide-transcript-codex-meta`) must have the native ID of the instance as its `payload.id`.
  - Another ID: UNTRACKED, detail "the rollout file is of another conversation".
  - No whole session record yet: UNTRACKED, detail "rollout file not readable yet". Emacs checks again at the next change of the file. The first line must be the `session_meta` record and end with its newline; a line without its newline is still being written, also when it is valid JSON already. (All 55 local rollouts start with `session_meta`.)
- **The turn records.** Each is an `event_msg` record, parsed by `claude-code-ide-transcript--parse-line`. Only lines that end with a newline count, because Codex can be in the middle of a line.

| The last turn record | Common state | Detail |
|---|---|---|
| `task_started` | `working`, since `started_at` | "From rollout: a turn runs" |
| `task_started` before the start of the launch | `idle` | "From rollout: a turn of an earlier run did not end" |
| `task_complete` without `error` | `idle`, since `completed_at` | "From rollout: turn ended" |
| `task_complete` with `error` | `failed/quota-limit` or `failed/error` (see "Quota limits") | "From rollout: Quota limit: ...", "From rollout: Not included in the plan: ...", or "From rollout: Error: ..." |
| `turn_aborted` | `idle` | "From rollout: interrupted" |
| none | `idle` | "From rollout: no turn yet" |
| a file that is not there or cannot be read | `disconnected/untracked` | "rollout file not readable" |
| a file without a whole session record | `disconnected/untracked` | "rollout file not readable yet" |
| a file of another conversation | `disconnected/untracked` | "the rollout file is of another conversation" |

- **Each rollout state is a guess** (`:guess t`, a `?` in the status buffer). The state plist has `:source` `rollout`. An UNTRACKED state has no `:source`.
- **The detail** says once that the hooks are missing: the trust problem of the launch, else "No status hooks". A state from the rollout ends with " · <problem>"; an UNTRACKED state starts with "<problem>; ".
- **The start of the launch.** The time when Emacs tracked the launch, else the start of the terminal process. A `task_started` more than 1 second before it is of a process that was killed in a turn (`started_at` has whole seconds).
- **The keys of the terminal do not count.** Emacs does not watch the terminal. A RET, an empty prompt, a slash command such as `/status`, or the answer to an approval changes no state; only the rollout file does.
- **Limits.**
  - **After `/new` or a fork in a terminal without hooks, the status follows the old conversation until Emacs learns the new native ID.** The instance keeps its old native ID, and Codex writes the new conversation to another rollout file. So the state is a guess of the old conversation: it is often `idle` while the new conversation works. A restart of the instance with hooks ends this: the hook `SessionStart` of the new conversation moves the launch (see "Event files").
  - An approval or a question waits inside a running turn. The rollout has no record of them, so they show as `working`.
- **Later work.** A better signal of a switch: for example the session ID that the Codex `/status` screen shows, read from the terminal. Release 1.2.0 has no detection of `/new`: a detection from new rollout files in the day folders gave false UNTRACKED states (a later session in the same folder, a scan before the session record was written), so the user dropped it (2026-11-21).
- **Cheap polling.** The state of an instance is computed once for each refresh (one NOW), by the helper `claude-code-ide-session-status--once-per-refresh`, which the CLI file of Claude Code uses too. A change of the launch record or the native ID counts as a new refresh. The provider caches the path. Emacs reads the file only when its modification time, size, inode, or device changed:
  - The first read goes backward from the end, 64 KiB at a time, until it finds a turn record. A line longer than 8 MiB is skipped.
  - A file of the conversation that grew, with the same inode, is read only from the end of the last read on.
  - Any other change checks the session record again and reads the file again from the end backward: a new time with the same or a smaller size (a rewrite in place), a new inode or device (a rename over the file), or a file whose session record did not match or was not whole.
- The cache is keyed by instance and weak. Emacs never writes the file.
- Facts of Codex 0.164.0, from 43 local rollout files (record types only): each turn has one `task_started` and then one `task_complete` or `turn_aborted` (`reason` `interrupted`). No turn starts inside another one.
- **Why not the app-server.** Its thread status (`ThreadStatus` in the schema) has the value `notLoaded` for a thread that the app-server did not load itself. So a second app-server cannot see the turn of the terminal (from the schema; not tried live).

## A plan without Codex

A failure whose plan does not include Codex (see "Quota limits") is `failed/quota-limit` with the detail "Not included in the plan: ...". A handover is one way out; a wait does not help.

- When you act on such a session, `claude-code-ide-codex-events-not-included-action` decides what Emacs does. The actions: RET or a click on its row, `w` or `M-x claude-code-ide-visit-waiting-session`, and the handover key `H` of the status buffer.

| Value | What Emacs does |
|---|---|
| `ask` (default) | It asks with `read-multiple-choice`: c (continue), h (hand over), s (stop). |
| `continue` | It keeps the session and sends nothing. A visit shows the terminal; the handover key does nothing. |
| `handover` | It starts `claude-code-ide-handover` for the instance. The handover asks for the target. |
| `stop` | It ends the session with `claude-code-ide-control-stop`, and says the result. |

- A coordinator never gets the question. It reads the state, the reason (`quota-limit`), and the detail of the snapshot.
- Another file can take over such actions too: `claude-code-ide-session-status-act-functions` gets the instance and `visit` or `handover`.

## Tracking

- A launch record exists for the current launch of each tracked Codex instance.
- A new launch of the same instance ID replaces the record and deletes the files of the old launch.
- Every 2 seconds, Emacs deletes the records whose instance does not run that launch any more, and their files.
- The timers stop when no record is left.
- `claude-code-ide-codex-events--instance-state` is a function of `claude-code-ide-instance-state-functions` for the provider `codex`. An instance without a record gets its state from its rollout file (see "Codex sessions without status hooks"), else it has the state `disconnected/untracked`, detail "No status hooks".
- The state plist has `:source`: `hooks` for a launch with hooks, `screen` for a dialog of a launch without hooks, `rollout` for the rollout file. An UNTRACKED state has none. The status snapshot shows it as `source`.
- `claude-code-ide-codex-events-map-event` maps the events. The Codex provider can use it as its `map-event` operation.

## Options

| Option | Default | Use |
|---|---|---|
| `claude-code-ide-session-status-tracking` | t | Off: no hooks for new launches (both providers). |
| `claude-code-ide-codex-events-program` | `"codex"` | The program for the app-server. |
| `claude-code-ide-codex-events-trust-timeout` | 5 | Seconds that a start waits for the trust check. |
| `claude-code-ide-codex-events-startup-grace` | 3 | Seconds before the first screen read of a launch. |
| `claude-code-ide-codex-events-approval-guess-time` | 10 | Seconds after which an unconfirmed approval is a guess. |
| `claude-code-ide-codex-events-approval-end` | `window` | When a screen read without the dialog ends the wait for an approval: `window`, `event`, or `screen`. |
| `claude-code-ide-session-status-quota-regexp` | see "Quota limits" | The usage-limit pattern of both providers. |
| `claude-code-ide-session-status-transient-regexp` | see "Quota limits" | Texts of short limits, which are never a usage limit (both providers). |
| `claude-code-ide-codex-events-error-kind-states` | see "Quota limits" | The state of each Codex error kind: `quota-limit` or `error`. |
| `claude-code-ide-codex-events-not-included-regexp` | see "Quota limits" | Texts that say that the plan does not include Codex. |
| `claude-code-ide-codex-events-not-included-action` | `ask` | What a visit or the handover key does on a session whose plan lacks Codex. |
