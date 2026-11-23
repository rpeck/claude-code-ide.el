# Process trees of the agent CLIs

A coding-agent CLI can start background work that runs after the CLI ends.
This document describes how claude-code-ide.el records that work, ends it at a stop, and reports the processes that are left.

- Code: `claude-code-ide-process.el`.
- Tests: `claude-code-ide-process-tests.el`.
- Instances: [session-schema.md](session-schema.md).

## Why the CLI's own process group is not enough

- **Each background command has its own session and process group.** Claude Code and Codex start each background command with `setsid`. So its process ID, process group ID, and session ID are the same number.
- **A kill of the CLI does not reach it.** After the CLI ends, the command gets the parent process 1. A scan of the CLI's children then does not find it.
- **Claude Code ends its background shells at a soft end:** SIGHUP, SIGTERM, a normal buffer kill, or `/exit` with "Exit and stop tasks". The shells survive SIGKILL.
- **Codex 0.164.0 ends its background terminals only at `/quit`.** At SIGHUP and SIGTERM, Codex exits without that cleanup.
  - A terminal with a tty dies anyway, because its pty closes.
  - A terminal without a tty keeps running.
- **macOS `ps -o sess` always shows 0.** So the records use the parent chain and the process group ID.
- **A double fork with `setsid` escapes every record.** Only a scan of working folders finds it.

## What the code does

### Tracking

`(claude-code-ide-process-track INSTANCE PROCESS)` starts the records of one instance.

- PROCESS is the terminal process. For the ghostel backend it is a pipe; the code reads the process ID of the CLI from its `ghostel--native-pid` property.
- A timer runs `ps` without a wait, every `claude-code-ide-process-track-interval` seconds (default 2).
  - One `ps -A -o pid=,ppid=,pgid=,uid=,lstart=` serves all instances. It takes about 60 ms for 2,500 processes.
  - Emacs `process-attributes` for all processes takes about 0.7 s, so the code does not use it for the table.
- Each record follows the parent chain from the CLI. A process that started before the CLI, or whose start time is unknown, is not a descendant, and the walk does not go through it. A real descendant never starts before the CLI. On macOS a debugger that attaches to a process (`lldb -p X`) becomes its parent, so without this rule the walk would reach X and its children, which can be any process, also Emacs itself.
- Each record keeps:
  - each process group of a descendant, with the start time of its leader and the leader's command;
  - each descendant process ID with its start time.
- A common event `prompt-submit`, `tool-start`, `tool-end`, `turn-end`, `subagent-start`, or `subagent-end` of the instance also starts a record, at most one per second. The file adds itself to `claude-code-ide-event-functions` for this.
- Groups and processes that are gone are dropped at each record. A process group cannot get new members after its last member is gone.
- The group of Emacs, and the groups of Emacs's ancestors, are never recorded.
- Each `ps` run builds one snapshot: the table, a PID index, the children of each PID, and the protected set (see "Safety"). All records of that run use it.
- The timer stops when no tracked CLI runs now. The check uses the current records, so a `ps` run that started before a new CLI existed does not stop the timer.
- The records stay until a stop or `claude-code-ide-process-untrack`.
- A new launch of the instance, for example a resume, keeps the groups of the earlier records. After a stop that ended `timeout` or `error`, a later stop then still ends them.
- The asynchronous `ps` of the timer has a limit of 10 s. After it, the timer ends `ps`, and the next tick runs a new one.

Other functions:

- `(claude-code-ide-process-refresh INSTANCE)`: record now, with a wait for `ps`.
- `(claude-code-ide-process-groups INSTANCE)`: the recorded groups, as plists `(:pgid :leader-start :first-seen :command)`.
- `(claude-code-ide-process-untrack INSTANCE)`: forget the records.

### Stop

`(claude-code-ide-process-stop INSTANCE &rest ARGS)` does these steps:

1. **Record one last time,** while the CLI still runs.
2. **Send the soft end of the provider.** `claude-code-ide-process-soft-end` gives it for each provider. The default is SIGHUP to the process group of the CLI for both providers, which is what a buffer kill sends.
3. **Wait for the CLI to exit,** up to `:timeout` seconds (`claude-code-ide-process-stop-timeout`, default 5).
   - If the CLI still runs, send SIGTERM to its group. Wait `:kill-wait` seconds (`claude-code-ide-process-kill-wait`, default 2). Then send SIGKILL, and wait up to the smaller of `:kill-wait` and 1 s.
   - With `:escalate nil`, skip this. A CLI that still runs then keeps its groups, and the result is `timeout`.
4. **End the recorded groups that still run:** SIGTERM to the group, then SIGKILL after the kill wait, then a wait of up to the smaller of `:kill-wait` and 1 s. Up to three rounds catch members that start during a round.
   - The groups of the spared processes get no signal: the process IDs of `:exclude`, and the review processes that run (`claude-code-ide-review-process-ids`, see [review.md](review.md)). A review outlives a stop of its owner.
5. **Scan the worktree** (unless `:scan nil`): list the processes whose working folder is inside it (`lsof -n -P -w -a -u UID -d cwd -Fpcn`).
   - The full scan runs only when a worktree of the stop exists as a folder.
   - It takes about 0.6 s on an idle Mac, and 20 to 30 s under heavy load (load average 23, measured). `claude-code-ide-process-lsof-timeout` (default 30 s) limits it; then the result is `error`.
   - The working folders of the strays that the records found come from one `lsof -p PID,PID,...` call for all instances.

`ps` runs have a limit of 10 s. If `ps` fails in a step, the stop sends nothing more, keeps the records, and returns `error`. One exception: when `ps` fails in the escalation of step 3, the CLI still gets its signal, but alone, because its group cannot be checked.

With `:budget`, the `ps` and `lsof` runs count toward the budget too. A run gets at most the time that is left, but at least 0.5 s, so that the steps after the end of the budget still send their signals.

The keys of ARGS:

| Key | Value |
|---|---|
| `:timeout` | Seconds for step 3. |
| `:kill-wait` | Seconds between SIGTERM and SIGKILL. The wait after SIGKILL is the smaller of this and 1 s. |
| `:budget` | Seconds for all waits and all `ps` and `lsof` runs together, or nil for no limit. A wait that has no time left is skipped, but its signals still go out. |
| `:soft-end` | A signal symbol, a function of `(INSTANCE PROCESS)`, or `none` when the caller already did the soft end. Default: the provider's. |
| `:escalate` | nil skips SIGTERM and SIGKILL of the CLI. Default t. |
| `:scan` | nil skips step 5. Default t. |
| `:worktree` | The folder for step 5. Default: the descriptor's worktree, else its project root. |
| `:process` | The terminal process. Default: the process of the descriptor's buffer, else the descriptor's `pid`. A process that is neither the process of the instance's buffer nor has the descriptor's PID is ignored, with a debug message. The same rule holds for `claude-code-ide-process-track`. |
| `:exclude` | Process IDs that the stop spares: step 4 does not signal their groups, and step 5 leaves them out. The stop adds the review processes that run. |

The result is a plist:

| Key | Value |
|---|---|
| `:status` | `stopped`: nothing is left. `strays`: only processes that the stop did not end are left (step 5, or unproven groups). `error`: `ps` or the scan failed, and `:reason` says why; the records stay. `timeout`: the CLI or a recorded process survived SIGKILL, or the CLI still runs after `:escalate nil`. |
| `:strays` | A list of plists `(:pid :command :cwd :reason ...)`. |
| `:ended` | The group IDs that got a signal in step 4. |
| `:escalated` | nil, `SIGTERM`, or `SIGKILL`: the last signal to the CLI in step 3. |

Each stray has a `:reason`:

- `cli`: the CLI itself still runs.
- `survivor`: a process of a recorded group survived SIGKILL.
- `unverified`: a process is in a recorded group, but no recorded process proves that it is the same group (see "Safety"). Or the CLI has no known start time and its PID runs. It got no signal.
- `worktree`: step 5 found it.

A stray can also have `:pgid`, `:ppid`, `:instance-id` (it belongs to the tree of another running instance), and `:emacs-process` (Emacs runs it, for example a shell buffer).

After `stopped` or `strays`, the records of the instance are dropped. After `timeout` or `error`, they stay, so that a later stop can end what is left.

When `:process` has another PID than the records (a new launch of the instance), the new records take over the old ones, so the stop also ends the groups of the old CLI. A `:process` without a PID keeps the records.

### Stop of several instances

`(claude-code-ide-process-stop-many INSTANCES &rest ARGS)` stops each instance with one shared wait: all soft ends first, then one wait, then the escalation and the group ends.
It returns an alist `(INSTANCE-ID . RESULT)` in the order of INSTANCES.
The quit of Emacs uses it with `:budget`, so that N instances wait once and not N times, and all waits together stay within the budget.

### Stop from kill-buffer-hook

`(claude-code-ide-process-stop-later INSTANCE &rest ARGS)` starts the last record at once, with a `ps` without a wait. After that record, it runs the stop from timers with `:soft-end none`. The key `:callback` gives a function that gets the result.

- The stop is a chain of steps. Each wait is a poll every 0.05 s from a new timer, so the command loop runs between the steps. One step takes about one `ps` run (60 ms on an idle Mac).

- A wait inside `kill-buffer-hook` is unsafe: a sentinel that runs during the wait can kill the buffer again while its hooks still run.
- The buffer kill itself sends SIGHUP to the CLI after the hook. That is the soft end.

### Worktree scan

`(claude-code-ide-process-worktree-strays WORKTREE &optional EXCLUDE)` returns the processes whose working folder is inside WORKTREE.

- Links are resolved, so `/tmp/x` and `/private/tmp/x` match.
- A folder with the same name prefix (`wt-other` for `wt`) does not match.
- Emacs itself, and the process IDs in EXCLUDE, are left out.
- It only reports. It never ends a process.

## Safety

The stop sends signals only to processes that it can prove are the work of the CLI.

- **The CLI.** Its process ID must run with the recorded start time.
  - The start time comes from the descriptor (`process-start-time`) when the descriptor holds the same PID.
  - Else it comes from the live process only when the process object is the real child: a live process object of this Emacs whose own process ID is that PID. Emacs has not reaped it, so the PID cannot belong to another process.
  - A ghostel pipe is not the real child. ghostel's native thread reaps the child before the pipe closes, so the PID of a live pipe can belong to an unrelated process. For ghostel, the launch must record the native PID and its start time in the descriptor.
  - A live process with another start time never replaces the recorded one: the CLI is then gone, and its PID belongs to another process.
  - Without a known start time, the CLI cannot be verified. It gets no signal, and its descendants are not recorded.
  - The CLI's whole group gets the signal only when the CLI leads it, the group is not protected, and every member of the group has the user ID of Emacs. Else the CLI gets the signal alone. Example: a child that runs `sudo` (effective user ID 0) never gets the signal of the group.
- **A recorded group.** It gets a signal only when one of its live processes is the recorded leader with the same start time, or a recorded process with the same start time.
  - `ps` gives whole seconds, so start times within 1.5 seconds count as the same.
  - So a group ID that the system gave again to an unrelated process gets no signal.
  - Only processes that a record saw before the stop prove a group. The proof does not grow during a stop, because a later member could be a reused PID within the 1.5 seconds.
  - SIGKILL comes from a new check. Right before SIGKILL, a fresh `ps` table checks each group again in full: a proving process, no protected process or group, and the user ID of Emacs for every member. Between SIGTERM and SIGKILL the group can end and its ID can go to an unrelated group.
  - A nil start time never matches in a check that leads to a signal. Only the end of a wait counts a nil start time as "still there", so that a wait does not end too early.
- **Never:**
  - process 0 or 1, Emacs, any ancestor of Emacs, or their process groups. The protected set comes from the full `ps` table of the snapshot. A CLI in a protected group gets a signal alone, never its group;
  - a group with a process of another user;
  - the tree of another running instance.
- **Strays are never ended.** The worktree scan, and processes of unproven groups, only go into the result.

## Limits

- A child that starts after the last record, and calls `setsid` before the stop, is not recorded. The worktree scan finds it when its working folder is in the worktree.
- A process that changes its working folder out of the worktree, and writes through an absolute path, escapes both checks.
- Work that a long-lived server starts for the agent escapes both checks. Examples: the user's Emacs through MCP `emacs_eval`, tmux, `launchctl`, `open`, Docker, ssh, the Codex daemon, and the Claude Code daemon after "Move to background and exit".
- Codex must run with `--no-daemon`. In daemon mode the background terminals are children of the app-server, not of the terminal UI.

## Verified behavior

Claude Code 2.1.280, codex-cli 0.164.0, Emacs 30.1, macOS 15, vterm.

| Case | Result |
|---|---|
| Codex `--no-daemon`, background terminal `sleep 600` with `tty:false`, then a normal buffer kill | Codex and its children (`node_repl`, `codex-code-mode-host`) ended. `sleep 600` kept running with parent 1. A stop with `:soft-end none` then ended its group: `(:status stopped :ended (PGID))`. |
| Codex `--no-daemon`, the same background terminal, then `claude-code-ide-process-stop` while Codex runs | SIGHUP ended Codex in 0.9 s without escalation. The stop ended the `sleep 600` group: `(:status stopped :ended (PGID))`. |
| Claude Code, background Bash `sleep 600` (`/bin/zsh -c ...` in its own group), then `claude-code-ide-process-stop` while CC runs | SIGHUP ended CC in 1.2 s. CC ended its shell itself: `(:status stopped :ended nil)`. |
| A shell on a pty starts `sleep` in a new session (live ERT test) | The stop ended the group of `sleep`: `stopped`. |
| A double fork with `setsid` in the worktree (live ERT test) | `strays`, with the process and the reason `worktree`. The stop did not end it. |

The live ERT tests run only with `CLAUDE_CODE_IDE_LIVE_TESTS=1`.

## Calls from claude-code-ide.el

The orchestrator adds these calls. Each call checks `fboundp`, so the package works without this file.

- **Load point:** `(claude-code-ide--require-optional 'claude-code-ide-process)` with the other load points.
- **Launch:** `(claude-code-ide-process-track instance process)` right after the start records the process ID of the instance.
- **`claude-code-ide--cleanup-session`:** before the buffer kill:
  - The CLI ended by itself: `claude-code-ide-process-untrack`. What it left running was its own choice, for example "Move to background and exit".
  - Called from `kill-buffer-hook` (BUFFER-DYING): `claude-code-ide-process-stop-later` with `:scan nil`.
  - Else: `claude-code-ide-process-stop` with `:scan nil`, and then the buffer kill.
- **`kill-emacs-hook`:** `claude-code-ide-process-stop-many` for all instances with `:budget claude-code-ide-process-quit-timeout` (1.5 s for all waits together), `:timeout 1`, `:kill-wait 0.25`, and `:scan nil`, before the cleanup of each session. The cleanup of each session then runs no second stop, because that stop would wait without the budget. The hook must run before the ghostel hook, which sends SIGKILL to its native children.
