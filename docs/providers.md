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
| `capabilities` | A list of symbols: the operations that the provider supports. It can name extra abilities, for example `continue`. |
| One slot for each operation | A function, or nil when the provider does not support the operation. |

The accessors are `claude-code-ide-provider-<slot>`, for example `claude-code-ide-provider-launch`.

## Operations

Each operation is a slot that holds a function.
The list of operation slots is `claude-code-ide-provider-operations`.

In this table:

- INSTANCE is a `claude-code-ide-instance` descriptor.
- SPEC is a `claude-code-ide-start-spec`.
- ARGS is a list of argument strings from `claude-code-ide-cli-args-functions`.

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
| `transcript` | `(INSTANCE WHAT)` | WHAT is `file`, `title`, or `model`. The result is the value, or `unknown`. |
| `exit-message` | `(EXIT-CODE SPEC PROGRAM)` | A message for a CLI that ended with EXIT-CODE, or nil. PROGRAM is the CLI that ran. |

Rules for each operation:

- **The command** is one shell command line. The terminal backends run it as it is (vterm) or split it into words (eat and ghostel).
- **The environment** is a list of strings. `"NAME=VALUE"` sets a variable. `"NAME"` without `=` removes a variable. The entries go in front of the environment of Emacs.
- **An unknown value** is the symbol `unknown`. An operation never guesses a value.
- **Credentials.** An operation does not copy, print, or store login files, tokens, or API keys.

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
| `claude-code-ide-provider-supports-p` | `(PROVIDER OPERATION)` | Non-nil when PROVIDER has a function for OPERATION. An unknown OPERATION signals an error. |
| `claude-code-ide-provider-unavailable` | `(OPERATION)` | `(:status unavailable :capability OPERATION)`. |
| `claude-code-ide-provider-unavailable-p` | `(RESULT)` | Non-nil when RESULT is the unavailable result. |

**Unsupported operations.** `claude-code-ide-provider-call` returns `(:status unavailable :capability OPERATION)` when the provider has no function for the operation. It does not signal an error, so a caller cannot confuse the result with a failure.

**The default provider.** The option `claude-code-ide-default-provider` (default `claude`) names the provider of a new instance when the start spec names none. Each instance keeps its own provider, so several providers can run in one Emacs and in one project.

## How a start uses the provider

`claude-code-ide--start-session` starts every instance. For the provider of the spec, it does these steps:

1. It calls `detect`. If `:available` is nil, it signals a `user-error` with the display name.
2. It makes the instance descriptor, with a new launch generation.
3. It collects ARGS from `claude-code-ide-cli-args-functions`.
4. It calls `resume` when the spec continues, picks, or resumes. Otherwise it calls `launch`. The terminal runs the `:command` with the `:environment`.
5. When the CLI exits with a code other than 0, it calls `exit-message` and shows the text.

`claude-code-ide-send-prompt` calls `submit-prompt` of the instance's provider.

## The claude provider

The `claude` provider calls the functions that the package used before. A start through the provider gives the same command, environment, and messages.

| Operation | Implementation |
|---|---|
| `detect` | `claude-code-ide--ensure-cli`. With WITH-VERSION, it also runs `claude --version`. |
| `launch`, `resume` | `claude-code-ide--build-claude-command` and `claude-code-ide--cli-environment`. A `resume-id` adds `--resume ID` in front of ARGS. |
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

1. Make a new file, for example `claude-code-ide-codex.el`. The main file loads it with `(require 'claude-code-ide-codex nil t)`, so you do not edit a shared file.
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
     :map-event #'claude-code-ide-codex--map-event
     :capabilities '(detect launch resume map-event)))
   ```

5. To give a state for the instances of the provider, add a function to `claude-code-ide-instance-state-functions`. See [session-schema.md](session-schema.md).
6. Put the values that the frozen descriptor does not have in the descriptor's properties. Use keys that start with the name of your file, for example `:codex-secret`.
7. Write ERT tests in `claude-code-ide-<area>-tests.el`. `claude-code-ide-tests.el` loads every such file.
