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
- A start spec with `:provider 'codex` starts Codex from Lisp. Give the spec an `:extra-flags` string; else the start uses `claude-code-ide-cli-extra-flags`, which holds Claude Code flags.

## Options

| Option | Default | Meaning |
|---|---|---|
| `claude-code-ide-codex-cli-path` | `"codex"` | The Codex program. |
| `claude-code-ide-codex-cli-extra-flags` | `""` | More flags for the Codex commands, for example `"--model gpt-5.6-terra"`. |
| `claude-code-ide-codex-remove-openai-api-key` | `t` | Removes `OPENAI_API_KEY` from the Codex environment, so that Codex uses the `codex login` subscription. |
| `claude-code-ide-codex-no-alt-screen` | `t` | Passes `--no-alt-screen`, so that the buffer keeps the earlier output. |
| `claude-code-ide-codex-skip-update-check` | `t` | Passes `-c check_for_update_on_startup=false`. The update dialog selects "Update now" by default. |

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
6. The MCP arguments (see below).
7. The status hook arguments, from `claude-code-ide-codex-status-hook-args` (the `codex-status` part), when that function is defined.
8. The extra flags of the start spec, as they are.
9. The caller's ARGS, shell-quoted.
10. `--`, then the positional words: the conversation ID and the first prompt.

The `--` makes sure that no option takes the prompt as its value, and that a prompt such as "help" is not a subcommand.

| Operation | Spec | Command |
|---|---|---|
| `launch` | no resume | `codex <options> [-- PROMPT]` |
| `resume` | `resume-id` | `codex resume <options> -- ID [PROMPT]` |
| `resume` | `continue` | `codex resume --last <options>` |
| `resume` | `resume` (picker) | `codex resume <options>` |
| `fork` | `resume-id` | `codex fork <options> -- ID [PROMPT]` |

- With `--last` or the picker, a prompt is refused with a `user-error`. Codex would read the prompt as a conversation ID.
- `fork` without a `resume-id` signals an error.

Example (the instructions are shortened):

```
codex --no-daemon --no-alt-screen -c check_for_update_on_startup=false
  -c 'developer_instructions="IMPORTANT: Connected to Emacs ..."'
  -c 'mcp_servers.emacs_tools.url="http://localhost:40001/mcp/claude-proj-..."'
  -c 'mcp_servers.emacs_tools.env_http_headers={"X-Emacs-MCP-Token"="CCI_MCP_HEADER_X_EMACS_MCP_TOKEN"}'
  -c 'shell_environment_policy.exclude=["CCI_MCP_HEADER_X_EMACS_MCP_TOKEN"]'
  -c 'mcp_servers.emacs_tools.default_tools_approval_mode="approve"'
  -c 'mcp_servers.emacs_tools.tools.emacs_eval.approval_mode="prompt"'
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
| Each header NAME | `mcp_servers.emacs_tools.env_http_headers` maps NAME to the variable `CCI_MCP_HEADER_<NAME>` |
| The header variables | `shell_environment_policy.exclude` |

- **Header values are not in the argument list.** `ps` shows the argument list to all local users. The value goes in the variable `CCI_MCP_HEADER_<NAME>` of the terminal environment.
- **The model's shell commands do not get the variables,** because `shell_environment_policy.exclude` lists them.
- **No MCP server** (`claude-code-ide-enable-mcp-server` off): no MCP arguments.
- The server key is `emacs_tools`. Codex names the tools `mcp__emacs_tools__<tool>` in hook events.

### Approvals

| `claude-code-ide-mcp-allowed-tools` | Approved tools |
|---|---|
| `auto` (default) | The result of `claude-code-ide-mcp-server-get-tool-names`, after its advice. The advice of `rp-emacs-mcp` removes `emacs_eval`. |
| A list or a string | The tools that it names. The `mcp__emacs-tools__` prefix is optional. |
| `nil` | None. |

- When some tools are approved: `default_tools_approval_mode="approve"`, and `tools.<tool>.approval_mode="prompt"` for each tool that is not approved.
- When no tool is approved: `default_tools_approval_mode="prompt"`.
- **Fail closed:** when a tool to prompt for has a name that a dotted key cannot hold (a character other than letters, digits, `_`, and `-`), every tool needs an approval.

## Environment

The terminal environment gets these entries in front of the Emacs environment:

- `OPENAI_API_KEY` without a value (removed), when `claude-code-ide-codex-remove-openai-api-key` is on.
- `CODEX_THREAD_ID`, `CODEX_SESSION_ID`, and `CODEX_TOOL_CALL_ID`, removed. Codex sets them for a nested session, and the hook script drops the events of a nested session.
- `CCI_MCP_HEADER_<NAME>=<value>` for each MCP header.
- The entries of `claude-code-ide-codex-status-hook-env` (the `codex-status` part), when that function is defined.

The provider never sets a credential. The Codex commands that Emacs runs itself (`codex --version`, `codex queue`) get the same removals.

## Prompts

`submit-prompt` runs:

```
codex queue --thread <native-id> --message <text>
```

- It never types into the terminal. A typed Return steers a running turn, and in a dialog it approves the selected option.
- Codex delivers the text when the conversation is idle: at once, after the running turn, or after the dialog.
- When no Codex process runs, Codex keeps the text and delivers it at the next resume.
- The result is `(:status queued :thread ID :message-id ID-OR-unknown)`.
- The result is nil when the command fails, or when the instance has no native ID yet. A message in the echo area gives the reason.
- The acknowledgement of delivery is the `UserPromptSubmit` hook event with the same text. `codex queue` does not wait for the delivery.

## Native ID

- A resume knows the conversation ID at the start.
- A new conversation gets its ID from the `session_id` field of the `SessionStart` hook event.
- **Codex sends `SessionStart` only at the first prompt,** also for a resume. Until then, `native-id` is `unknown`, and `submit-prompt` cannot queue a text.
  - So the first prompt of a new conversation goes on the command line (the spec's prompt), or you type it in the terminal.
- Only the first `SessionStart` of each launch generation sets the ID. A later one of the same launch (a nested session) does not change it.
- The listener is `claude-code-ide-codex--note-session-start`, on `claude-code-ide-event-functions`.

## Events

`map-event` maps the Codex hook events to the common events:

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

- `stop` kills the terminal buffer. With `--no-daemon`, that ends Codex and its child processes.
- No `transcript` and no `status-events` yet. The status hooks come from the `codex-status` part.
- No IDE protocol: Codex uses no WebSocket connection, no lock file, and no `openDiff`.

## Known limits

- **The generic start still makes a WebSocket server and a lock file** for each Codex instance, and logs "Claude Code started in ...". `claude-code-ide--start-session` does this for every provider.
- **The MCP connection fails** until the HTTP server replies `202 Accepted` to notifications (`feat/mcp-routing`).
- **Folder trust:** Codex asks for it one time for each new repository root. Emacs never answers it.
