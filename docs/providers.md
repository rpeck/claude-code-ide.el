# Coding-agent providers

A provider is a coding-agent CLI, for example `claude` (Claude Code).
This document describes the provider interface of claude-code-ide.el and how to add a provider.

- Code: `claude-code-ide-provider.el`.
- The `claude` provider: `claude-code-ide.el`, section "The claude provider".
- Instances, events, and states: [session-schema.md](session-schema.md).

## The provider struct

`claude-code-ide-provider` is a `cl-defstruct`.
Make one with `claude-code-ide-provider-create` and keyword arguments.

| Slot | Value |
|---|---|
| `name` | A symbol, for example `claude`. It identifies the provider. |
| `display-name` | A name for people, for example `"Claude Code"`. Messages use it. |
| `buffer-name-prefix` | The prefix of terminal buffer names, for example `"claude-code"`. |
| `capabilities` | A list of symbols: exactly the operations that have a function. Leave it nil; registration fills it in. A list that names other operations is refused. |
| One slot for each operation | A function, or nil when the provider does not support the operation. |
| `ide-protocol` | Non-nil when the CLI speaks the IDE WebSocket protocol and reads the lock files in `~/.claude/ide/`. The default is nil. The `claude` provider sets it to t. It is not an operation, so it is not in `capabilities`. |
| `restore-flags` | A function `(ENTRY)` of a session registry record that returns the flag string of the restore start spec, or nil. nil (the default) means no extra flags: the options of the provider give its flags and its model. It is the last slot. It is not an operation, so it is not in `capabilities`. See "Restore flags" below. |

The accessors are `claude-code-ide-provider-<slot>`, for example `claude-code-ide-provider-launch`.

## Operations

Each operation is a slot that holds a function.
The list of operation slots is `claude-code-ide-provider-operations`.

In this table:

- INSTANCE is a `claude-code-ide-instance` descriptor.
- SPEC is a `claude-code-ide-start-spec`.
- ARGS is a list of extra argument strings from the caller. They come after the provider's own arguments. A start passes nil.

| Operation | Arguments | Result |
|---|---|---|
| `detect` | `(&optional WITH-VERSION)` | `(:available BOOL :program STRING :version STRING-OR-unknown)`. Find the CLI. With WITH-VERSION, also read its version. |
| `launch` | `(INSTANCE SPEC ARGS)` | `(:command STRING :environment LIST)`. Build the command line and the environment of a new conversation. |
| `resume` | `(INSTANCE SPEC ARGS)` | Same as `launch`. SPEC asks to continue, to pick, or to resume its `resume-id`. |
| `fork` | `(INSTANCE SPEC ARGS)` | Same as `launch`. Start a new native conversation from the history of SPEC's `resume-id`. |
| `submit-prompt` | `(INSTANCE TEXT)` | Non-nil when the text went to the terminal. |
| `stop` | `(INSTANCE)` | Non-nil when the provider ended the process. |
| `native-id` | `(INSTANCE)` | The native conversation ID, or `unknown`. |
| `status-events` | `(INSTANCE)` | An alist `((EVENT-NAME COMMAND ...) ...)`: the status hooks that the launch gives the CLI. nil means none. |
| `map-event` | `(PROVIDER-EVENT DATA)` | A symbol of `claude-code-ide-event-names`: the common event of a provider event. |
| `mcp-setup` | `(INSTANCE)` | The MCP configuration in the format of the provider, or nil. |
| `transcript` | `(INSTANCE WHAT)` | WHAT is `file`, `title`, or `model`. The result is a string, or `unknown`. A `file` is an absolute path of a readable file. See "The transcript operation" below. |
| `exit-message` | `(EXIT-CODE SPEC PROGRAM)` | A message for a CLI that ended with EXIT-CODE, or nil. PROGRAM is the CLI that ran. |

Rules for each operation:

- **The command** is one shell command line. The terminal backends run it as it is (vterm) or split it into words (eat and ghostel).
- **The environment** is a list of strings. `"NAME=VALUE"` sets a variable. `"NAME"` without `=` removes a variable. The entries go in front of the environment of Emacs.
- **An unknown value** is the symbol `unknown`. An operation never guesses a value.
- **Credentials.** An operation does not copy, print, or store login files, tokens, or API keys.

### The transcript operation

- **The arguments.** `(INSTANCE WHAT)`. INSTANCE is an instance descriptor. It need not be live or registered: a caller that has only a native ID makes a detached descriptor, for example `(claude-code-ide-instance-create :id ID :provider 'codex :native-id NATIVE-ID :project-root DIR)`. WHAT is one of these symbols:
  - `file`: the absolute path of the transcript file of the current native conversation of INSTANCE.
  - `title`: the title of that conversation.
  - `model`: the model of the last turn of that conversation.
- **The result.** A string, or the symbol `unknown` when the value cannot be found (for example, before the CLI writes the file). Use `claude-code-ide-known-or-nil` to get nil in place of `unknown`. Another WHAT signals an error.
- **The cost.** The operation never reads a whole large transcript. Callers can call it often, for example from a status refresh.
- **Through `claude-code-ide-provider-call`.** A provider without the operation gives the unavailable result `(:status unavailable :capability transcript)`. A provider that is not registered (its file is not loaded) signals `user-error`, so check `claude-code-ide-get-provider` first.

| Provider | `file` | `title` | `model` |
|---|---|---|---|
| `claude` | The transcript path of the CLI report, else `<CLAUDE_CONFIG_DIR>/projects/<project slug>/<native ID>.jsonl`. | The `/rename` title, else the summary. | The model of the last assistant message. |
| `codex` | The rollout file of the native ID: `claude-code-ide-codex-rollout-file`. | The last `thread_name` of the native ID in `<CODEX_HOME>/session_index.jsonl`. | The `model` of the last `turn_context` record of the rollout file. |

**Capabilities of Codex instances.** Since 1.2.0 the `codex` provider has `transcript`. So `get_capabilities` and `inspect-instance` list `transcript` for a Codex instance. This is an intended change.

**The Codex rollout file.** `(claude-code-ide-codex-rollout-file NATIVE-ID &optional DIRECTORY)` returns the absolute path of the rollout file of the Codex conversation NATIVE-ID, or nil. DIRECTORY is the working folder of the session, for a relative CODEX_HOME (see "The Codex home"). The `transcript` operation of `codex` calls it with the native ID of INSTANCE and its worktree (else its project root). The rules:

1. **Full IDs only.** NATIVE-ID must be a full UUID (8-4-4-4-12 hex digits). A part of an ID, or another value, gives nil. Codex writes the ID in lower case, so the function uses the ID in lower case: an ID in upper case finds the same file in the day folders and in the full search.
2. **The name.** A rollout file has the name `rollout-<start time>-<NATIVE-ID>.jsonl`, for example `rollout-2026-11-17T14-22-26-<NATIVE-ID>.jsonl`. Of several matching files, the newest by name wins, as Codex can write a new rollout at a resume.
3. **The first lookup.** A lookup of NATIVE-ID without a cache entry searches all of `<CODEX_HOME>/sessions/` one time, and takes the newest match by name. So an older rollout in a day folder never hides a newer one in another folder. Each lookup without a cache entry runs the full search: the first one, and the next one after the entry goes (rule 6). Later full searches follow the recheck rule (rule 4) and the miss rule (rule 5).
4. **The cache and the recheck.** After that, a found file comes from a cache by native ID while it is readable. The entry keeps the time of its last check. After `claude-code-ide-codex-rollout-recheck-seconds` (60 s), a recheck reads these day folders `<CODEX_HOME>/sessions/YYYY/MM/DD/` for a newer file:
   - each day from the day before the last check to today, so that a rollout written just before midnight, or on a day without a lookup, counts;
   - for a UUID version 7, the day before, the day of, and the day after its creation time.

   When more than `claude-code-ide-codex-rollout-recheck-max-days` (7; a value above 366 counts as 366) days passed since the last check, the recheck runs the full search one time instead. The cached file stays a candidate in both cases.
5. **A miss.** A miss of the full search is kept for `claude-code-ide-codex-rollout-miss-seconds` (60 s). In that time, the function checks only the day folders of today and of the creation time. It searches all of `sessions/` again only when the sessions folder or the day folder of today changes. So frequent calls never walk the whole folder each time.
6. **The size of the cache.** Each new entry first removes the misses that expired. Then the oldest entries go, a found file or a miss, until there is room under `claude-code-ide-codex-rollout-cache-limit` (1000). This holds also after the limit went down, or for a cache that was too large before. A limit of 0 or less keeps no entries. So many IDs without a rollout do not grow the cache.

**The Codex home.** `(claude-code-ide-codex-home &optional DIRECTORY)` (in `claude-code-ide-provider.el`) is the one rule for the rollouts, the session index, and the Codex config file of the transcript readers. It reads CODEX_HOME as Codex does:

- Unset or empty: `~/.codex`.
- Absolute: CODEX_HOME as it is.
- Relative: relative to DIRECTORY, the working folder of the Codex session (its worktree or project root), when the caller knows it. Else relative to `default-directory`. The Codex config file of the transcript readers has no session, so it uses `default-directory`.
- A leading `~` is not expanded, because Codex does not expand it: `~/x` is the folder `~/x` in DIRECTORY.

A compressed rollout (`.jsonl.zst`) is not found, because the transcript readers cannot read it.

**The shared transcript helpers.** Both providers read their transcripts with the helpers of the session registry:

- `claude-code-ide-session-registry-grep-lines` and `-grep-last` run grep, so that no transcript is read in full.
- `claude-code-ide-session-registry-line-field` reads one field of a JSON line.
- `claude-code-ide-session-registry-cached` caches a value for each kind and file, until the time or the size of the file changes. A changed file replaces its value, so the cache does not grow with each change.
- The Codex model comes from `grep -n -o`: it reads only short matches, never a whole `turn_context` record.

### Restore flags

`claude-code-ide-restore-sessions` restores a session registry record with a start spec. The flag string of the spec comes from the `restore-flags` slot of the provider of the record:

- The `claude` provider gives the stored flags, the model of the transcript (else the stored model) as `--model`, and the title that the user gave as `--name`.
- The `codex` provider sets the slot to nil: a Codex restore gets no flags. The Codex options give the Codex flags and the model.
- A provider with nil in the slot gets no flags.
- **Deprecated table.** For one release, `claude-code-ide-session-registry-restore-flags-functions` keeps its old default (the `claude` entry) and its old meaning, so a user who changed it gets the same flags as before:
  - An entry of the provider gives its flags, also an entry whose value is nil (no flags).
  - A table set to nil gives no flags to any provider.
  - Only a provider without an entry, in a table that is not nil, gets the flags of its `restore-flags` slot. This is `codex` and each new provider.
  - Set the slot in place of the table. The table goes away in the next release.

### Two operations that §4.1 of the plan does not list

- **`map-event`.** The plan gives `status-events` two jobs: the hook settings and the mapping of events. The interface has one slot for each job.
- **`exit-message`.** The text for an exit code is special to each CLI, so it belongs to the provider.

## Functions

| Function | Arguments | Result |
|---|---|---|
| `claude-code-ide-register-provider` | `(PROVIDER)` | PROVIDER. It is registered under its name. A provider of the same name is replaced. |
| `claude-code-ide-get-provider` | `(NAME)` | The provider NAME, or nil. |
| `claude-code-ide-provider-names` | `()` | The names of the registered providers, oldest first. |
| `claude-code-ide-resolve-provider` | `(&optional NAME)` | The provider NAME. nil gives the default provider. A struct is returned as it is. An unknown name signals `user-error`. |
| `claude-code-ide-provider-call` | `(PROVIDER OPERATION &rest ARGS)` | The result of the operation. PROVIDER is a struct or a name. |
| `claude-code-ide-provider-ide-protocol-p` | `(PROVIDER)` | Non-nil when PROVIDER has `ide-protocol`. PROVIDER is a struct or a name. Only such a provider gets a WebSocket server and a lock file in `~/.claude/ide/` at a start. |
| `claude-code-ide-provider-supports-p` | `(PROVIDER OPERATION)` | Non-nil when PROVIDER has a function for OPERATION. An unknown OPERATION signals an error. |
| `claude-code-ide-provider-unavailable` | `(OPERATION)` | `(:status unavailable :capability OPERATION)`. |
| `claude-code-ide-provider-unavailable-p` | `(RESULT)` | Non-nil when RESULT is the unavailable result. |

**Unsupported operations.** `claude-code-ide-provider-call` returns `(:status unavailable :capability OPERATION)` when the provider has no function for the operation. It does not signal an error, so a caller cannot confuse the result with a failure.

**The default provider.** The option `claude-code-ide-default-provider` (default `claude`) names the provider of a new instance when the start spec names none. Each instance keeps its own provider, so several providers can run in one Emacs and in one project.

## How a start uses the provider

`claude-code-ide--start-session` starts every instance. For the provider of the spec, it does these steps:

1. It calls `detect`. If `:available` is nil, it signals a `user-error` with the display name.
2. It makes the instance descriptor, with a new launch generation.
   - Only a provider with `ide-protocol` gets a WebSocket server and a lock file in `~/.claude/ide/`. Another provider gets only the MCP tools server.
3. It calls `resume` when the spec continues, picks, or resumes. Otherwise it calls `launch`. The terminal runs the `:command` with the `:environment`.
4. When the CLI exits with a code other than 0, it calls `exit-message` with the `:program` that `detect` found, and shows the text.

The start adds nothing that is special to one CLI. Only the `claude` launch runs `claude-code-ide-cli-args-functions`, so only Claude Code gets the `--session-id` and `--settings` arguments of the session registry.

The default buffer name, for example `*claude-code[app]*`, starts with the `buffer-name-prefix` of the instance's provider.

`claude-code-ide-send-prompt` returns the result of `submit-prompt`. When the provider has no `submit-prompt`, the result is the unavailable result. Interactively, that is a `user-error`.

`claude-code-ide-send-prompt` calls `submit-prompt` of the instance's provider.

## The claude provider

The `claude` provider calls the functions that the package used before. A start through the provider gives the same command, environment, and messages.

| Operation | Implementation |
|---|---|
| `detect` | `claude-code-ide--ensure-cli`. With WITH-VERSION, it also runs `claude --version`. |
| `launch`, `resume` | `claude-code-ide--build-claude-command` and `claude-code-ide--cli-environment`. The arguments are `--resume ID` (for a `resume-id`), then those of `claude-code-ide-cli-args-functions`, then ARGS. |
| `fork` | `launch` with `--resume ID` and `--fork-session`. |
| `submit-prompt` | It types the text into the terminal and presses return. |
| `stop` | It kills the terminal buffer. |
| `native-id` | The descriptor's native ID, else the file that the CLI keeps in `~/.claude/sessions`. |
| `status-events` | nil. Claude Code gets its status hooks through the `--settings` argument of the session registry. See `claude-code-ide-session-registry-hook-functions`. |
| `map-event` | The table `claude-code-ide--claude-event-map`. |
| `mcp-setup` | `claude-code-ide-mcp-server-get-config`. |
| `transcript` | The transcript readers of the session registry. |
| `exit-message` | The messages for exit codes 127, 126, and 1 (after a continue or a resume). |

## How to add a provider

1. Make a new file, for example `claude-code-ide-codex.el`. The main file loads it with `(claude-code-ide--require-optional 'claude-code-ide-codex)`, so you do not edit a shared file. A missing file is skipped. An error in the file gives a warning, and the rest of the package still loads.
2. In the file, `(require 'claude-code-ide)`.
3. Write one function for each operation that the CLI supports. Leave the other slots nil.
4. Register the provider:

   ```elisp
   (claude-code-ide-register-provider
    (claude-code-ide-provider-create
     :name 'codex
     :display-name "Codex"
     :buffer-name-prefix "codex"
     :detect #'claude-code-ide-codex--detect
     :launch #'claude-code-ide-codex--launch
     :resume #'claude-code-ide-codex--launch
     :map-event #'claude-code-ide-codex--map-event))
   ```

5. To give a state for the instances of the provider, add a function to `claude-code-ide-instance-state-functions`. See [session-schema.md](session-schema.md).
6. Put the values that the frozen descriptor does not have in the descriptor's properties. Use keys that start with the name of your file, for example `:codex-secret`.
7. Write ERT tests in `claude-code-ide-<area>-tests.el`. `claude-code-ide-tests.el` loads every such file.
