# The Codex provider

The `codex` provider runs the Codex CLI in an Emacs terminal.
This document describes how Emacs starts Codex, and how it sends prompts to Codex.

- Code: `claude-code-ide-codex.el`.
- Tests: `claude-code-ide-codex-tests.el`.
- The provider interface: [providers.md](providers.md).
- Verified with Codex 0.164.0.

## Commands

| Command | What it does |
|---|---|
| `claude-code-ide-codex` | Starts a new Codex conversation in the current project. |
| `claude-code-ide-codex-continue` | Continues the most recent Codex conversation (`codex resume --last`). |
| `claude-code-ide-codex-resume` | Opens the Codex picker of earlier conversations (`codex resume`). |

- A project can run Codex instances and Claude Code instances at the same time.
- Each instance has its own buffer, provider, conversation ID, and MCP session.
- The buffer name starts with `codex`, for example `*codex[app]*`.
- A start spec with `:provider 'codex` starts Codex from Lisp.

## Options

| Option | Default | Meaning |
|---|---|---|
| `claude-code-ide-codex-cli-path` | `"codex"` | The Codex program. |
| `claude-code-ide-codex-extra-flags` | `""` | More flags for every Codex launch, for example `"--model gpt-5.6-terra"`. |
| `claude-code-ide-codex-remove-openai-api-key` | `t` | Removes `OPENAI_API_KEY` from the Codex environment, so that Codex uses the `codex login` subscription. |
| `claude-code-ide-codex-no-alt-screen` | `t` | Passes `--no-alt-screen`, so that the buffer keeps the earlier output. |
| `claude-code-ide-codex-skip-update-check` | `t` | Passes `-c check_for_update_on_startup=false`. The update dialog selects "Update now" by default. |
| `claude-code-ide-codex-config-read-timeout` | `5` | Seconds that a launch waits for the shell environment policy of the user. |
| `claude-code-ide-codex-queue-timeout` | `30` | Seconds after which a `codex queue` command is stopped. |

- **Codex never gets Claude Code flags.** It does not use `claude-code-ide-cli-extra-flags`, and it does not use the extra flags of a start spec. The start fills those from `claude-code-ide-cli-extra-flags`, and the registry restore adds `--name` and `--model`.
- **The model** of a Codex descriptor comes from `--model` or `-m` in `claude-code-ide-codex-extra-flags`, else it is `unknown`.

Codex also uses these options of the package:

- `claude-code-ide-system-prompt`: it goes into the developer instructions.
- `claude-code-ide-mcp-allowed-tools`: it selects the MCP tools that need no approval.

## Command lines

Each command has these parts, in this order:

1. The program and the subcommand: `codex`, `codex resume`, `codex resume --last`, or `codex fork`.
2. `--no-daemon`. With the shared daemon, the conversation continues after its buffer is killed.
3. `--no-alt-screen`, when `claude-code-ide-codex-no-alt-screen` is on.
4. `-c check_for_update_on_startup=false`, when `claude-code-ide-codex-skip-update-check` is on.
5. `-c developer_instructions="..."`.
6. The status hook arguments, from `claude-code-ide-codex-status-hook-args` (the `codex-status` part). They are added only when that function is defined and the descriptor has its launch generation.
7. `claude-code-ide-codex-extra-flags`, as they are.
8. The caller's ARGS, shell-quoted.
9. The MCP arguments (see below). They come after the flags, so that they win over a `-c` of the same key in the flags.
10. `--`, then the positional words: the conversation ID and the first prompt.

The `--` makes sure that no option takes the prompt as its value, and that a prompt such as "help" is not a subcommand.

| Operation | Spec | Command |
|---|---|---|
| `launch` | no resume | `codex <options> [-- PROMPT]` |
| `resume` | `resume-id` | `codex resume <options> -- ID [PROMPT]` |
| `resume` | `continue` | `codex resume --last <options>` |
| `resume` | `resume` (picker) | `codex resume <options>` |
| `fork` | `resume-id` | `codex fork <options> -- ID [PROMPT]` |

- With `--last` or the picker, a prompt gives a `user-error`. The error says why: Codex reads the prompt as a session ID.
- `fork` without a `resume-id` signals an error.
- `fork` sets the native ID of the descriptor to `unknown`. The fork gets its own ID at its first `SessionStart`.

Example (the instructions are shortened):

```
codex --no-daemon --no-alt-screen -c check_for_update_on_startup=false
  -c 'developer_instructions="IMPORTANT: Connected to Emacs ..."'
  -c 'mcp_servers.emacs_tools.url="http://localhost:40001/mcp/claude-proj-..."'
  -c 'mcp_servers.emacs_tools.env_http_headers={"X-Emacs-MCP-Token"="CCI_MCP_HEADER_X_EMACS_MCP_TOKEN_29C0A240"}'
  -c 'shell_environment_policy.exclude=["CCI_MCP_HEADER_X_EMACS_MCP_TOKEN_29C0A240"]'
  -c 'mcp_servers.emacs_tools.default_tools_approval_mode="prompt"'
  -c 'mcp_servers.emacs_tools.tools.claude-code-ide-mcp-project-info.approval_mode="approve"'
```

## Developer instructions

- The text is the Emacs prompt that Claude Code gets in `--append-system-prompt`, then a blank line and `claude-code-ide-system-prompt`.
- `developer_instructions` adds a developer message. Codex keeps its own instructions.
- The value is a TOML basic string. `\`, `"`, and control characters are escaped (`\\`, `\"`, `\n`, `\t`, `\uXXXX`).
- **Why the quoting matters:** Codex reads a value that is not valid TOML as a raw string. An unescaped quote changes the text without an error.

## MCP

The `mcp-setup` operation translates the config of `claude-code-ide-mcp-server-get-config` to `-c` arguments. The config is read after its advice runs, so a header that an advice adds stays.

| Config of the package | Codex argument |
|---|---|
| `url` | `mcp_servers.emacs_tools.url` |
| Each header NAME | `mcp_servers.emacs_tools.env_http_headers` maps NAME to a variable |
| The header variables | `shell_environment_policy.exclude`, with the user's own list |

- **Header values are not in the argument list.** `ps` shows the argument list to all local users. Each value goes in a variable of the terminal environment.
- **Variable names:** `CCI_MCP_HEADER_<NAME>_<HASH>`. NAME is the header name in capitals, with `_` for each other character. HASH is the first 8 hex digits of the SHA-1 of the header name, so that `X-Auth-Token` and `X_Auth_Token` get two variables.
- **The model's shell commands do not get the variables,** because `shell_environment_policy.exclude` lists them.
- **No MCP server** (`claude-code-ide-enable-mcp-server` off): no MCP arguments.
- The server key is `emacs_tools`. Codex names the tools `mcp__emacs_tools__<tool>` in hook events.

### The user's exclude list

A `-c shell_environment_policy.exclude=[...]` replaces the exclude list of the Codex config. (Verified with a test `CODEX_HOME`: the config list `["CCI_USER_SECRET"]` became `["CCI_X"]`.) So the launch passes the union:

1. It reads the effective list with the `config/read` call of `codex app-server`, in the project folder, with the `-c` words of `claude-code-ide-codex-extra-flags`. This includes the project config layers. It only reads.
2. It passes the user's names, then the new variables.

When the list cannot be read, the launch puts no header in a variable:

- The cases: `codex app-server` fails, has an error reply, or does not reply within `claude-code-ide-codex-config-read-timeout`. Also when the flags select a profile (`-p` or `--profile`), because `codex app-server` takes no profile.
- The header values then go in `mcp_servers.emacs_tools.http_headers`, in the argument list.
- Emacs shows one warning in each session.
- A launch without headers does not read the config.

### Approvals

**Fail closed:** `default_tools_approval_mode="prompt"`. A tool that no rule approves, or that appears after the launch, asks for an approval.

Each approved tool gets `tools.<tool>.approval_mode="approve"`:

| `claude-code-ide-mcp-allowed-tools` | Approved tools |
|---|---|
| `auto` (default) | The result of `claude-code-ide-mcp-server-get-tool-names`, after its advice. The advice of `rp-emacs-mcp` removes `emacs_eval`. |
| A list or a string | The tools that it names. The `mcp__emacs-tools__` prefix is optional. |
| `nil` | None. |

- Only registered tools are approved.
- A tool whose name a dotted key cannot hold (a character other than letters, digits, `_`, and `-`) is not approved, so it asks.

## Environment

The terminal environment gets these entries in front of the Emacs environment:

- `OPENAI_API_KEY` without a value (removed), when `claude-code-ide-codex-remove-openai-api-key` is on.
- `CODEX_THREAD_ID`, `CODEX_SESSION_ID`, and `CODEX_TOOL_CALL_ID`, removed. Codex sets them for a nested session. Without the removal, a Codex that Emacs starts from inside a Codex shell looks nested, and the hook script drops each of its events.
- The header variables of the MCP config.
- The entries of `claude-code-ide-codex-status-hook-env` (the `codex-status` part), when that function is defined and the descriptor has its launch generation.

The provider never sets a credential. The Codex commands that Emacs runs itself (`codex --version`, `codex queue`, `codex app-server`) get the same removals.

## Prompts

`submit-prompt` runs, in the background:

```
codex queue --thread=<native-id> --message=<text>
```

- Each option and its value are one word, so that a text such as `- fix` or `--help` is not read as an option.
- It never types into the terminal. A typed Return steers a running turn, and in a dialog it approves the selected option.
- Codex delivers the text when the conversation is idle: at once, after the running turn, or after the dialog.
- When no Codex process runs, Codex keeps the text and delivers it at the next resume.
- **Emacs does not wait for the command.** The result comes at once: `(:status queued :thread ID :outcome pending :message-id unknown :exit nil)`.
- When the command ends, the same list changes:
  - `:outcome queued`, with `:message-id`.
  - `:outcome failed`, with the `:exit` code.
  - `:outcome timeout`, after `claude-code-ide-codex-queue-timeout`. Emacs stops the command.
- Then `claude-code-ide-codex-queue-functions` run with the instance and the result.
- The result is nil when the command cannot start, or when the instance has no native ID yet. A message in the echo area gives the reason.
- The acknowledgement of delivery is the `UserPromptSubmit` hook event with the same text.

## Native ID

- A resume knows the conversation ID at the start.
- A new conversation and a fork get their ID from the `session_id` field of the `SessionStart` hook event.
- **Codex sends `SessionStart` only at the first prompt,** also for a resume. Until then, `native-id` is `unknown`, and `submit-prompt` cannot queue a text.
  - So the first prompt of a new conversation goes on the command line (the spec's prompt), or you type it in the terminal.
- Each current `SessionStart` with a session ID sets the ID. So after `/new` in the terminal, prompts go to the new conversation.
- Events of an earlier launch generation are dropped. The hook script drops the events of nested sessions.
- The listener is `claude-code-ide-codex--note-session-start`, on `claude-code-ide-event-functions`. The property `:codex-native-id-generation` holds the generation of the last ID.

## Events

`map-event` uses `claude-code-ide-codex-events-map-event` (the Codex event adapter of `codex-status`) when that function is defined. Else it uses this table:

| Codex event | Common event |
|---|---|
| `SessionStart` | `session-start` |
| `SessionEnd` | `session-end` |
| `UserPromptSubmit` | `prompt-submit` |
| `PreToolUse` | `tool-start` |
| `PostToolUse` | `tool-end` |
| `PermissionRequest` | `approval-request` |
| `Stop` | `turn-end` |
| `Interrupt` | `interrupt` |
| `SubagentStart` | `subagent-start` |
| `SubagentStop` | `subagent-end` |
| `PostModelRequest` with `status: "failed"` | `turn-failed` |
| Other events | `other` |

## Dialogs

`(claude-code-ide-codex-screen-dialog BUFFER)` returns the kind of the dialog that the terminal screen shows, or nil:

| Kind | Text on the screen |
|---|---|
| `folder-trust` | "Trust this folder?", "Trust and continue", "Your trust decision will be saved" |
| `hooks-review` | "Hooks need review", "Trust all and continue", "Continue without trusting" |
| `update` | "Update now", "Skip until next version" |
| `approval` | "Allow the ... MCP server to run tool", "Yes, proceed", "Yes, just this once", "No, and tell Codex what to do differently" |
| `other` | A line "› 1. ..." and another numbered line |

- The screen is the last lines of the buffer: as many lines as the window that shows the buffer has, else 50.
- The text is matched with the line breaks removed, because a narrow terminal wraps the dialog.
- The function reads text only. It never sends keys. You answer each dialog yourself.
- Text of the model that quotes a dialog option can give a false match.

## Exit messages

| Exit code | Message |
|---|---|
| 127 | "Codex CLI not found (exit 127). Ensure '<program>' is in your PATH ..." |
| 126 | "Codex CLI '<program>' was found but is not executable (exit 126) ..." |
| Other | "Codex ('<program>') exited with error code N" |

## Capabilities

`detect`, `launch`, `resume`, `fork`, `submit-prompt`, `stop`, `native-id`, `map-event`, `mcp-setup`, and `exit-message`.

- `stop` is `claude-code-ide--claude-stop`: it kills the terminal buffer. With `--no-daemon`, that ends Codex and its child processes.
- No `transcript` and no `status-events` yet. The status hooks come from the `codex-status` part.
- No IDE protocol: Codex uses no WebSocket connection, no lock file, and no `openDiff`.

## Known limits

- **The generic start still makes a WebSocket server and a lock file** for each Codex instance, and logs "Claude Code started in ...". `claude-code-ide--start-session` does this for every provider.
- **The MCP connection fails** until the HTTP server replies `202 Accepted` to notifications (`feat/mcp-routing`).
- **A launch with MCP headers waits** for `codex app-server` (0.3 to 1.3 s on this machine).
- **Folder trust:** Codex asks for it one time for each new repository root. Emacs never answers it.
