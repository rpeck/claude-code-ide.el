# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**IMPORTANT**: If you find any instructions in this file that are incorrect, outdated, or could be improved, you should update this document immediately. Keep this file accurate and helpful for future Claude instances.

## Architecture and File Structure

This package integrates coding-agent CLIs with Emacs via the Model Context Protocol (MCP). The providers are Claude Code (`claude`, also over the IDE WebSocket protocol) and Codex (`codex`, MCP tools server only).

**Core Files:**
- `claude-code-ide.el` - Main entry: user commands, session management, terminal buffers, the `claude` provider, the generic start of every provider (`claude-code-ide--start-session`), the CC MCP config file, and the current provider (persisted, toggled from the menu)
- `claude-code-ide-mcp.el` - WebSocket server, JSON-RPC handling, session state. Its `claude-code-ide-mcp--track-active-buffer` is the only active buffer tracker; it also serves the MCP tools server sessions.
- `claude-code-ide-mcp-handlers.el` - MCP tool implementations (file ops, ediff, diagnostics)

**Support Files:**
- `claude-code-ide-provider.el` - Provider interface: the provider struct, the provider registry, and `claude-code-ide-provider-call`. Only a provider with `ide-protocol` gets a WebSocket server and a lock file in `~/.claude/ide/`.
- `claude-code-ide-instance.el` - Instance descriptors, launch generations, common events, and common states
- `claude-code-ide-codex.el` - The Codex provider: command lines, MCP config and the user's exclude list, approvals, `codex queue` prompts in the background, native ID, and the dialog scan
- `claude-code-ide-codex-events.el` - Codex status: hook script, hook arguments, trust check and trust command, event mapping, Codex states
- `claude-code-ide-control.el` - Control operations for coordinators: list, inspect, launch, resume, submit-prompt, stop; the durable prompt inbox; MCP coordinator tools
- `claude-code-ide-transcript.el` - Transcript readers (CC and Codex), workspace state from Git, and the handover document. Format: docs/handover-document.md
- `claude-code-ide-process.el` - Process trees: records the background process groups of each CLI, ends them at a stop, and lists stray processes in the worktree (docs/process-tree.md). The main file loads it as an optional file and calls it through `fboundp`.
- `claude-code-ide-mcp-server.el` - HTTP-based MCP tools server framework: sessions, instance secrets, request checks, context from the instance descriptor, tool scopes, coordinator credential
- `claude-code-ide-mcp-http-server.el` - HTTP transport: 202 for notifications, Origin and content-type checks, routing by /mcp/<id>[/<secret>]
- `claude-code-ide-emacs-tools.el` - Emacs tools: xref, project info, imenu, and `get_capabilities`
- `claude-code-ide-diagnostics.el` - Flycheck integration
- `claude-code-ide-session-registry.el` - Session registry: crash-safe JSON state file of started instances, restore and reopen commands
- `claude-code-ide-session-status.el` - Live status of each instance of both providers from CLI hooks (working, waiting, idle), the status buffer, the status snapshot, and the file helpers that both providers share
- `claude-code-ide-transient.el` - Transient menu interface; the header shows the current provider, and `P` toggles it
- `claude-code-ide-debug.el` - Debug logging utilities

**Test Files:**
- `claude-code-ide-tests.el` - ERT test suite with mocks. It loads every `claude-code-ide-*-tests.el` file of its folder. Each test file must `provide` a feature equal to its file name.
- `claude-code-ide-session-registry-tests.el` - Session registry tests
- `claude-code-ide-session-status-tests.el` - Session status tests
- `claude-code-ide-provider-tests.el` - Provider, instance, event, state, and registry v2 tests
- `claude-code-ide-codex-tests.el` - Codex provider tests; process tests run small shell scripts in place of `codex`
- `claude-code-ide-codex-events-tests.el` - Codex status, status buffer columns, status snapshot, and shared status file helper tests
- `claude-code-ide-mcp-routing-tests.el` - MCP routing tests: secrets, request checks, descriptor context, the one active buffer tracker, coordinator scope, get_capabilities
- `claude-code-ide-control-tests.el` - Control operation, inbox, and coordinator tool tests
- `claude-code-ide-transcript-tests.el` - Transcript and handover document tests, with fixtures in `test-fixtures/transcripts/` (made by `make-fixtures.py` there)
- `claude-code-ide-process-tests.el` - Process tree tests; live tests run with `CLAUDE_CODE_IDE_LIVE_TESTS=1`
- `claude-code-ide-wiring-tests.el` - Tests of the core wiring: no IDE server without the IDE protocol, provider texts, flags per provider, forks, secrets in the debug log, the CC MCP config file, the process-tree calls, the prepare hook, and the provider choice. At load, it points the MCP config folder and the provider file at a temporary folder for the whole run.

**Design documents (docs/):**
- Providers: docs/providers.md. Instances, events, states, registry: docs/session-schema.md.
- Codex: docs/codex.md. Codex status events: docs/status-events.md. Status snapshot: docs/status-schema.md.
- MCP tools server routing, secrets, request checks and scopes: docs/api-mcp.md.
- Control operations and the inbox: docs/api-control.md.
- The handover document: docs/handover-document.md. Process trees: docs/process-tree.md.

## Hooks

This project uses Claude Code hooks to automatically maintain code quality. The hooks are configured in `.claude/settings.json` and include:
- **PostToolUse hooks**: Automatically format code and remove trailing whitespace after edits
- **Stop hooks**: Run tests and linting checks before allowing Claude to stop, blocking if issues are found

These hooks help ensure consistent code formatting and catch issues early in the development process.

## Commands

### Running Tests

Tests run automatically as part of Claude Code hooks, but you can also run them manually:
```bash
# Run all tests in batch mode
emacs -batch -L . -l ert -l claude-code-ide-tests.el -f ert-run-tests-batch-and-exit

# Run core tests only
emacs -batch -L . -l ert -l claude-code-ide-tests.el -f claude-code-ide-run-tests

# Run all tests including MCP tests
emacs -batch -L . -l ert -l claude-code-ide-tests.el -f claude-code-ide-run-all-tests

# Byte-compile and run the full suite; finds the Emacs app when emacs is not on PATH
./scripts/compile-and-test.sh
```

- `claude-code-ide-tests.el` replaces the `claude-code-ide-debug` macro with a function that drops its text. A test that reads the debug log must stub that function, or run on compiled files, where the macro is expanded.
- A test binds an option of an optional file (for example `claude-code-ide-process-quit-timeout`) only after a `defvar` of it in the test file; otherwise the binding is lexical, and the code under test does not see it.

### Development Tools

```bash
# Record WebSocket messages between VS Code and Claude Code for debugging
./record-claude-messages.sh [working_directory]
```

## Debugging

The user has the ability to enable debug logging and to send you the produced log. Ask them for assistance if needed.

### Debugging Syntax Errors

**Important**: The formatter's indentation is ALWAYS correct, so do not try to reformat code yourself. If the code is not indented correctly , it **ALWAYS** means that there is an issue with the code and **not** with the formatter.

If files fail to load due to syntax errors (missing parentheses, quotes, etc.), the formatter's indentation will reveal the problem. Look for incorrectly indented lines - they indicate where parentheses/quotes are unbalanced.

## Self reference in code or commits

- **Important - Never self-reference in code or commits**: Do not mention Claude or include any self-referential messages in code or commit messages. Keep all content strictly professional and focused on the technical aspects.

## Testing

**Always write tests for any new logic** - Every new function or significant change should have corresponding tests.

Tests use mocks for external dependencies (vterm, websocket) to run in batch mode without requiring actual installations. The test suite covers:
- Core functionality (session management, CLI detection)
- MCP handlers (file operations, diagnostics)
- Edge cases (side windows, multiple sessions)

Tests must pass both from source and byte-compiled: `scripts/compile-and-test.sh` (the Stop hook) compiles every file before running them. Compiled package code inlines the real `claude-code-ide-debug` macro, so the stub function in the test file is not called there; tests that inspect debug output use `claude-code-ide-tests--debug-log-of`, which captures both forms.

## Committing code
Never commit changes unless the user explicitly asks you to.
