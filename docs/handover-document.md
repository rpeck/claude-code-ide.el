# The handover document

A handover moves the work of one instance to a new native conversation (plan §4.7).
The first prompt of the new conversation is the handover document.
This document describes how Emacs reads the transcripts and writes the handover document.

- Code: `claude-code-ide-transcript.el`.
- Tests: `claude-code-ide-transcript-tests.el`, with the synthetic transcripts in `test-fixtures/transcripts/`.
- Instances and providers: [session-schema.md](session-schema.md) and [providers.md](providers.md).

## Turns

A reader turns a transcript into a list of turns, oldest first.
Each turn is a plist:

| Key | Value |
|---|---|
| `:role` | `user` or `assistant`. |
| `:text` | The text, or nil when the turn has only tool calls. |
| `:tools` | A list of strings. Each string is one tool call on one line, for example `"Bash: git status"`. |
| `:time` | The time stamp string of the transcript, or nil. |

Rules for all readers:

- Consecutive assistant records join one assistant turn.
- Thinking and reasoning are left out.
- Tool results are left out.
- A tool line is at most `claude-code-ide-transcript-tool-line-limit` characters.
- With a ROOT folder, a path inside ROOT becomes relative, and a leading `cd DIR &&` is removed from a command.
  - ROOT counts only as a whole path, with case: for ROOT `/a/proj`, the paths `/a/proj-other`, `/a/proj.bak`, and `/b/a/proj` do not change.
- A broken line, a line that is not a JSON object, and a record of an unknown type are skipped. The read continues.
- A record whose handling signals an error is skipped. One bad record cannot stop the read.
- Markers in large texts are found with string positions, not with one large regexp. A tool result of 1 MB does not overflow the regexp stack.

## The readers

| Function | Transcript |
|---|---|
| `(claude-code-ide-transcript-read FILE &optional FORMAT ROOT)` | Any. FORMAT is `claude` or `codex`, or nil to find it from the file. A missing file or an unknown format gives nil. |
| `(claude-code-ide-transcript-read-claude FILE &optional ROOT)` | A CC transcript in `~/.claude/projects/`. |
| `(claude-code-ide-transcript-read-codex FILE &optional ROOT)` | A Codex rollout in `~/.codex/sessions/`. |
| `(claude-code-ide-transcript-format FILE)` | Returns `claude`, `codex`, or nil, from the first records. |
| `(claude-code-ide-transcript-codex-meta FILE)` | Returns `(:id :cwd :commit :branch :time)` from the `session_meta` record of a rollout. It reads only the start of the file. |

`claude-code-ide-transcript-readers` maps a format to its reader. A new provider can add its reader there.

### CC transcripts

- A turn comes from a record of type `user` or `assistant`.
- A `user` record is a prompt only when a person wrote it. These records are skipped:
  - `isMeta`, `isSidechain`, or `isCompactSummary` is true.
  - The record has `toolUseResult` (a tool result).
  - `promptSource` is `"system"` (for example a task notification).
- Each text block of a prompt is cleaned on its own. A block of the CLI drops only itself, and the text of the person stays. A block is from the CLI when:
  - It starts with a tag that the CLI writes, for example `<local-command-stdout>` or `<system-reminder>`.
  - It is an interrupt marker, for example `[Request interrupted by user]` or `[Request interrupted by user for tool use]`.
- A slash command becomes `/NAME ARGS`. A shell escape (`<bash-input>`) becomes `! COMMAND`.
- An image in a prompt becomes `[image]`.
- In an `assistant` record, `text` blocks give the text, and `tool_use` blocks give the tool lines. `thinking` blocks are left out.
- Tool lines name the main input: the command for Bash, the file for Read, Edit, and Write, the pattern for Grep and Glob, and the description for Task and Agent. Other tools show their first string input.

### Codex rollouts

- The turns come from the `event_msg` records of type `item_completed` (test T3).
  - `UserMessage` gives a user turn. `AgentMessage` gives assistant text.
  - `CommandExecution` gives `exec: COMMAND`, with `(exit N)` when the exit code is not 0.
  - `FileChange` gives one `apply_patch: KIND PATH` line for each changed file.
  - `McpToolCall` gives `mcp: SERVER/TOOL`. `CollabAgentToolCall` and `SubAgentActivity` give `agent:` and `subagent:` lines.
  - `Reasoning` and unknown item types are left out.
- `response_item` records are not read. Their `custom_tool_call` "exec" records hold code-mode wrappers, not the commands.
- An imported rollout (`history_mode: legacy`) has its history only in the `user_message` and `agent_message` events.
  - The events give the turns up to the turn with the first `item_completed` record (its `task_started` record, else the first item). From there on, only the items give turns, because a resume can write an event and an item for the same message.
  - The first item is left out when it repeats the last event turn.
  - A rollout without `item_completed` records gives all its turns from the events. A legacy rollout that `codex exec resume` continued is such a rollout.
  - `[external_agent_tool_call: NAME] ... [/external_agent_tool_call]` text becomes a tool line.
  - `[external_agent_tool_result] ...` text and the `<EXTERNAL SESSION IMPORTED>` marker are left out.

### Speed

- A reader reads the whole file. It parses only the lines that can hold a turn.
- The document reads each transcript one time. The Codex reader returns the session metadata from the same read.
- The document renders each turn one time. Only a user turn whose prompt the budget left out of the prompt list is rendered again, with its text.
- Measured on Emacs 30.1: a 400 MB CC transcript takes about 8 seconds. Transcripts below 1 MB take less than 0.1 seconds.

## Workspace state

`(claude-code-ide-transcript-workspace-state DIR &optional SINCE)` returns a plist:

| Key | Value |
|---|---|
| `:worktree` | The top folder of the working tree. |
| `:git` | nil when DIR is not in a Git working tree. Then no other key follows. |
| `:branch` | The branch, or `detached`. |
| `:head`, `:head-subject` | The full commit ID and its subject, or `unknown` before the first commit. |
| `:status` | The lines of `git status --porcelain`. |
| `:since` | The full ID of SINCE, or nil when SINCE is not a commit. |
| `:diff-stat` | The lines of `git diff --stat SINCE`: the commits since SINCE and the changes that are not committed. |
| `:untracked` | The lines of `git ls-files --others --exclude-standard`. |
| `:log` | The lines of `git log --oneline -n 20`. |

- Each listing has at most `claude-code-ide-transcript-git-line-limit` lines. A cut listing ends with `... (N more lines)`.
- Git runs with `GIT_OPTIONAL_LOCKS=0`, so the status does not lock the index.
- `(claude-code-ide-transcript-commit-at DIR TIME)` returns the last commit of HEAD before the ISO 8601 time TIME.

## Legs of a chain

A chain is the list of native conversations that handovers connect. Each conversation is a leg.
A leg is a plist, or an instance descriptor that becomes a plist:

| Key | Value |
|---|---|
| `:provider` | The provider name, for example `claude` or `codex`. |
| `:instance-id` | The instance ID, or nil. |
| `:native-id` | The native conversation ID, or nil. |
| `:transcript` | The transcript file, or nil. |
| `:worktree` | The working tree, or nil. |
| `:handover-id` | The ID of the handover document that started the leg. nil for the first leg. |
| `:document-hash` | The SHA-256 of that document, or nil. |
| `:summary-file` | The state summary file that the leg wrote in its first turn, or nil. |
| `:start-commit` | HEAD when the leg started, or nil. |

- `(claude-code-ide-transcript-instance-leg INSTANCE)` makes the leg of the current conversation of INSTANCE. Its transcript file comes from the `transcript` operation of the provider, with WHAT `file`.
- The record of the source leg: when a leg of CHAIN has the same native ID or the same transcript file as the source, it is the source. Its values fill in the values that the source lacks, for example `:handover-id` and `:summary-file`. It does not show as a separate leg.

## The document

```elisp
(claude-code-ide-transcript-handover-document
 :source SOURCE :chain CHAIN :context CONTEXT :budget BUDGET
 :handover-id ID :target-provider PROVIDER :summary-file FILE :time TIME
 :session-server SERVER)
```

- `:source`, `:chain`, `:context`, and `:budget` are the keys of PHASE2-CONTRACTS §6.
  - SOURCE is an instance descriptor. A leg plist also works.
  - CHAIN is the list of the earlier legs, oldest first.
  - CONTEXT is text from the coordinator, or nil.
  - BUDGET is the size budget in characters. nil uses `claude-code-ide-transcript-budget` (100000).
- These keys are optional:
  - `:handover-id`: the ID of the new handover. nil makes a new UUID.
  - `:target-provider`: the provider of the target. nil shows `unknown`.
  - `:summary-file`: the file for the state summary of the target. nil gives `.handover/<ID>-state.md` in the worktree (`claude-code-ide-transcript-summary-file-format`).
  - `:time`: a Lisp time for the header. nil is now.
  - `:session-server`: whether the target has the session server (see "Source sessions"). `t`, nil, or `auto` (the default) to read the configuration of the target provider.
- The result is the text. The caller records its hash, for example with `(secure-hash 'sha256 TEXT)`.

### Parts, in this order

1. **Header.** The first line is the marker `<!-- claude-code-ide-handover-document id=ID -->`. Then: the handover ID, the source, the target provider, the time, the worktree, the state summary file of the target, and each leg of the chain with its handover ID and document hash.
2. **Workspace state.** The branch, HEAD, `git status --porcelain`, the diff stat since the start of the source, the untracked files, and `git log --oneline -n 20`.
   - The start of the source is its `:start-commit`. Else it is the commit in the Codex session metadata. Else it is the last commit before the first turn of the source.
3. **Context from the coordinator**, when CONTEXT is given.
4. **Source sessions:** how to read the full source sessions, and one entry for each leg (see "Source sessions" below).
5. **History of the chain:** a short extract.
   - **Original task:** the first user prompt of the first leg, marked "it can be out of date". When a handover document started the first leg, the original task of that document is used.
     - When no original task is found, the part says "Not found in the transcripts.". The next document reads this as no original task, not as a prompt. The prompt list then starts at P1.
   - **State summary of the previous target:** the summary file of the source, verbatim. The file comes from `:summary-file`, or from the document that started the source. The part is left out when no handover started the source.
   - **User prompts of the chain:** every other user prompt, oldest first, with the numbers P2, P3, and so on. P1 is the original task. Each prompt is cut to `claude-code-ide-transcript-prompt-limit` characters.
   - **Latest turns:** the turns of all legs, oldest first. Each turn text is cut to `claude-code-ide-transcript-turn-limit` characters. A user turn whose prompt is already in the document shows only its number, for example "(P5 in the list of user prompts above.)".
6. **Not carried over:** background tasks and subagents that still run, the permission mode, and the plan mode.
7. **Instructions to the target:**
   - The workspace state and the coordinator context have priority over older history.
   - A newer user prompt replaces an older one.
   - The instructions of earlier handover documents do not apply.
   - Read each file again before you edit it.
   - First turn: write a short state summary to the given file. Do not commit it.
   - Then reply `ready` and wait.

All transcript text (prompts, turns, and the state summary) is in Markdown block quotes, so that it cannot add headings to the document.

### Source sessions

The document does not hold every detail. It refers to the source sessions, so that the target reads a detail when it needs it.

- **One entry for each leg of the chain**, oldest first. The entry of the source has "(the source: this leg just ended)". Each entry has:
  - The provider and the native conversation ID. The ID is the `:native-id` of the leg, else the ID in the Codex session metadata, else the file name of a CC transcript.
  - The absolute transcript path and its format.
  - The start and end time of the leg: the times of its first and last turn.
  - The end record: the number of lines of the file when the document was written. Later records are not part of the chain.
  - How to read it: with the session server, or the file.
- **The session server.** `claude-code-ide-handover-session-server` names an MCP server that reads past sessions. The default is `"claude-sessions"`. nil turns the server references off.
  - `(claude-code-ide-transcript-session-server-p PROVIDER &optional WORKTREE)` says whether the target provider has the server. It only reads the files, and a missing or broken file gives nil:
    - `claude`: `mcpServers` of `.claude.json` (in `CLAUDE_CONFIG_DIR`, else HOME), the `mcpServers` of the project entry of WORKTREE in that file, and `WORKTREE/.mcp.json` (unless the project entry lists the server in `disabledMcpjsonServers`).
    - `codex`: a table `[mcp_servers.NAME]` (the name can be quoted) without `enabled = false`, or a key `mcp_servers.NAME = ...`, in `config.toml` of `CODEX_HOME`, else `HOME/.codex`.
    - Another provider gives nil.
  - A caller can give the answer with `:session-server` (`t` or nil). The default `auto` uses this function for the target provider. An unknown target provider never uses the server.
  - `claude-code-ide-handover-session-server-providers` lists the providers whose sessions the server reads. The default is `(claude)`, because claude-sessions reads Claude Code sessions only. A leg of another provider gets the file reference.
- **The server instructions**, when the target has the server and a leg can use it:
  - They are phrased as the request of the user, because the tools of claude-sessions say "only call when the user explicitly asks".
  - First `get_session_outline` with the conversation ID, in pages of 100 (`limit` 100, then `start_position` from `next_position`). Then `get_messages` with only the `positions` that the target needs. Never the whole session at once.
  - `(claude-code-ide-transcript-session-tool PROVIDER TOOL)` gives the tool name in the form of the target: `mcp__claude-sessions__get_messages` for Claude Code, and `mcp__claude_sessions__get_messages` for Codex, which changes hyphens to underscores.
- **The file reference** is always present, as the fallback:
  - It says that a file can be very large and must never be read whole.
  - It gives safe commands: `grep -n -o` with a short context, `head -n N | tail -n 40 | cut -c1-400`, and a short `jq` filter for each format in the chain (CC records of type `user` and `assistant`; Codex `item_completed` records).
- The budget never cuts this part. The latest turns fill the rest of the budget after it.

### No nested documents

Test S7 showed that a document that copies the previous document doubles in size at each leg, and that it carries old instructions.

- A user turn whose first line is the marker of a handover document is a document turn. A marker in a later line, for example in a quoted text, does not count.
- A document turn and the assistant turns after it, up to the next user turn, are the bootstrap of a leg. The bootstrap is left out of the prompts and of the latest turns. This also leaves out the turn that wrote the state summary and the "ready" reply.
- The document names each earlier document only by its handover ID and hash, in the header.
- `(claude-code-ide-transcript-document-id TEXT)`, `(claude-code-ide-transcript-document-summary-file TEXT)`, and `(claude-code-ide-transcript-document-original-task TEXT)` read these values from a document.

### The size budget

- The budget never cuts the header, the workspace state, the coordinator context, the "Source sessions" part, the original task, the "not carried over" list, or the instructions. When these parts are larger than the budget, the document is larger than the budget.
- The rest of the budget goes to the other parts, in this order:
  1. The state summary. It is cut at the end when it does not fit, and its last line is `> [... cut]`. The size counts the `> ` of each quoted line.
  2. The user prompts. They get half of the rest, or more when the latest turns need less. The oldest prompts are left out first.
  3. The latest turns. They get what remains. The oldest turns are left out first.
- A note counts what is left out, for example "(84 earlier prompts are left out because of the size budget.)".
- When the fixed parts fit in the budget, the document is never larger than the budget.

## Limits

- The diff stat uses the commits of the current branch. A start commit on another branch gives a diff against that commit.
- The default state summary file is inside the worktree. `git status` shows it as untracked, and the instructions tell the target not to commit it.
- The readers do not read subagent transcripts.
