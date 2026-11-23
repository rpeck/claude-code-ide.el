# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**IMPORTANT**: If you find any instructions in this file that are incorrect, outdated, or could be improved, you should update this document immediately. Keep this file accurate and helpful for future Claude instances.

## Architecture and File Structure

This package integrates coding-agent CLIs with Emacs via the Model Context Protocol (MCP). The providers are Claude Code (`claude`, also over the IDE WebSocket protocol) and Codex (`codex`, MCP tools server only).

**Core Files:**
- `claude-code-ide.el` - Main entry: user commands, session management, terminal buffers (kept after a stop: `claude-code-ide-keep-stopped-buffers`), the `claude` provider, the generic start of every provider (`claude-code-ide--start-session`), the CC MCP config file, and the current provider (persisted, toggled from the menu)
- `claude-code-ide-mcp.el` - WebSocket server, JSON-RPC handling, session state. Its `claude-code-ide-mcp--track-active-buffer` is the only active buffer tracker; it also serves the MCP tools server sessions.
- `claude-code-ide-mcp-handlers.el` - MCP tool implementations (file ops, ediff, diagnostics), and the dedicated ediff frames with their queue

**Support Files:**
- `claude-code-ide-provider.el` - Provider interface: the provider struct, the provider registry, and `claude-code-ide-provider-call`. Only a provider with `ide-protocol` gets a WebSocket server and a lock file in `~/.claude/ide/`.
- `claude-code-ide-instance.el` - Instance descriptors, launch generations, common events, and common states
- `claude-code-ide-codex.el` - The Codex provider: command lines, MCP config and the user's exclude list, approvals, `codex queue` prompts in the background, native ID, the transcript operation (rollout file, title, model; the lookup is `claude-code-ide-codex-rollout-file`), and the dialog scan
- `claude-code-ide-codex-events.el` - Codex status: hook script, hook arguments, the hook trust at each start (cache by the config trust records, one question for a start or a restore of the user, trust command), event mapping, Codex states
- `claude-code-ide-control.el` - Control operations for coordinators: list, inspect, launch, resume, submit-prompt, stop; the durable prompt inbox; MCP coordinator tools
- `claude-code-ide-handover.el` - Handover of an instance to a new conversation of either provider: the preflight, the stages saved before each step, the stop with stray checks, the document and the pointer prompt, the delivery watch, recovery with claims, the one writer rule, the control operation and tools, and `request_handover`. See docs/handover.md
- `claude-code-ide-mailbox.el` - The mailbox: `claude-code-ide-mailbox-mode` (off by default) adds the instance-scope MCP tools `claude-code-ide-send-message` and `claude-code-ide-list-peers`; the checks of a message, the frame, the key across handovers, and the limits. Delivery is the control inbox. The main file loads it as an optional file. See docs/mailbox.md
- `claude-code-ide-review.el` - Tracked external reviews: durable records, result files, delivery to the owner's inbox, the track-review control operation and coordinator tool
- `claude-code-ide-transcript.el` - Transcript readers (CC and Codex), workspace state from Git, and the handover document. Format: docs/handover-document.md
- `claude-code-ide-process.el` - Process trees: records the background process groups of each CLI, ends them at a stop, and lists stray processes in the worktree (docs/process-tree.md). The main file loads it as an optional file and calls it through `fboundp`.
- `claude-code-ide-mcp-server.el` - HTTP-based MCP tools server framework: sessions, instance secrets, request checks, context from the instance descriptor, tool scopes, coordinator credential
- `claude-code-ide-mcp-http-server.el` - HTTP transport: 202 for notifications, Origin and content-type checks, routing by /mcp/<id>[/<secret>]
- `claude-code-ide-emacs-tools.el` - Emacs tools: xref, project info, imenu, and `get_capabilities`
- `claude-code-ide-diagnostics.el` - Flycheck integration
- `claude-code-ide-session-registry.el` - Session registry: crash-safe JSON state file (schema version 4, in its own `-v4` file; versions 3, 2 and 1 are read and migrated) of started instances, restore and reopen commands, and the handover chain and stages (`claude-code-ide-session-registry-chain-current`, `claude-code-ide-session-registry-chain-ids`)
- `claude-code-ide-session-status.el` - Live status of each instance of both providers from CLI hooks (working, waiting, idle), the status buffer, the status snapshot, and the file helpers that both providers share
- `claude-code-ide-transient.el` - Transient menu interface; the header shows the current provider, and `P` toggles it
- `claude-code-ide-menu-bar.el` - The Agents and Agent Sessions menus of the menu bar, shown by `claude-code-ide-menu-bar-mode` (on by default). The main file loads it as an optional file.
- `claude-code-ide-debug.el` - Debug logging utilities
- `claude-code-ide-reload.el` - `claude-code-ide-reload`: loads the package files again in dependency order in a running Emacs, and turns the package modes that are on off and on again

**Test Files:**
- `claude-code-ide-tests.el` - ERT test suite with mocks (upstream file; it stays at the top level). It loads every `claude-code-ide-*-tests.el` file of its folder and of `tests/`, and puts `tests/` on `load-path`. Each test file must `provide` a feature equal to its file name.
- `tests/` - The test files of this fork, and their fixtures in `tests/fixtures/`. Do not move or rename a file that upstream (manzaltu/claude-code-ide.el) has, so that PRs to upstream merge without conflicts.
- `tests/claude-code-ide-session-registry-tests.el` - Session registry tests
- `tests/claude-code-ide-session-status-tests.el` - Session status tests
- `tests/claude-code-ide-provider-tests.el` - Provider, instance, event, state, and registry file version tests
- `tests/claude-code-ide-codex-tests.el` - Codex provider tests; process tests run small shell scripts in place of `codex`
- `tests/claude-code-ide-codex-events-tests.el` - Codex status, status buffer columns, status snapshot, and shared status file helper tests
- `tests/claude-code-ide-mcp-routing-tests.el` - MCP routing tests: secrets, request checks, descriptor context, the one active buffer tracker, coordinator scope, get_capabilities
- `tests/claude-code-ide-control-tests.el` - Control operation, inbox, and coordinator tool tests
- `tests/claude-code-ide-handover-tests.el` - Handover tests: stages, preflight, quiescing and the inbox hold, strays, the delivery watch, recovery at each stage and its claims, two writers, the inbox move, the chain, the version 4 registry file, control states, approvals, the status key, and a real review process
- `tests/claude-code-ide-mailbox-tests.el` - Mailbox tests: the mode and its tools, approvals, the sender, the target checks, the frame and the clean text, delivery, duplicates across handovers, and the limits; it uses the fixture of the handover tests
- `tests/claude-code-ide-review-tests.el` - Review tracking and dedicated ediff frame tests; the tests with real frames skip in batch Emacs
- `tests/claude-code-ide-transcript-tests.el` - Transcript and handover document tests, with fixtures in `tests/fixtures/transcripts/` (made by `make-fixtures.py` there)
- `tests/claude-code-ide-process-tests.el` - Process tree tests; live tests run with `CLAUDE_CODE_IDE_LIVE_TESTS=1`
- `tests/claude-code-ide-reload-tests.el` - Reload tests; one test reloads a copy of the package in a new batch Emacs
- `tests/claude-code-ide-menu-bar-tests.el` - Menu bar tests: the mode and its default, the commands of the Agents menu, and the items of the Agent Sessions menu
- `tests/claude-code-ide-wiring-tests.el` - Tests of the core wiring: no IDE server without the IDE protocol, provider texts, flags per provider, forks, secrets in the debug log, the CC MCP config file, the process-tree calls, the prepare hook, the provider choice, and the buffers kept after a stop. At load, it points the MCP config folder and the provider file at a temporary folder for the whole run.
- `tests/claude-code-ide-live-tests.el` - Live tests with the real `claude` and `codex` CLIs: handovers between both providers, recovery after a crash of Emacs, the Codex dialogs in each terminal, stops without a question, and a multi-line mailbox message to Claude Code. They run only in an own `emacs -Q` daemon with `CLAUDE_CODE_IDE_LIVE_TESTS=1` (docs/live-tests.md); in the batch suite each one skips, and only the unit tests of its helpers run.

**Design documents (docs/):**
- Providers: docs/providers.md. Instances, events, states, registry: docs/session-schema.md.
- Codex: docs/codex.md. Codex status events: docs/status-events.md. Status snapshot: docs/status-schema.md.
- MCP tools server routing, secrets, request checks and scopes: docs/api-mcp.md.
- Control operations and the inbox: docs/api-control.md.
- Reviews and dedicated ediff frames: docs/review.md.
- The mailbox between agent sessions: docs/mailbox.md.
- Handover: docs/handover.md. The handover document: docs/handover-document.md. Process trees: docs/process-tree.md.
- Updating the package and reloading it in a running Emacs: docs/updating.md.
- Live tests with the real CLIs: docs/live-tests.md.

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
emacs -batch -L . -L tests -l ert -l claude-code-ide-tests.el -f ert-run-tests-batch-and-exit

# Run core tests only
emacs -batch -L . -L tests -l ert -l claude-code-ide-tests.el -f claude-code-ide-run-tests

# Run all tests including MCP tests
emacs -batch -L . -L tests -l ert -l claude-code-ide-tests.el -f claude-code-ide-run-all-tests

# Byte-compile and run the full suite; finds the Emacs app when emacs is not on PATH
# (for the commands above, use the app binary in place of emacs, for example
# "/Applications/Emacs 30.1.app/Contents/MacOS/Emacs")
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

Tests must not depend on the machine load or on other test runs:
- Wait for a condition with `claude-code-ide-tests--wait-until` (60 s limit), never for a fixed time.
- A test of a time limit of the package runs on `claude-code-ide-tests--call-with-clock`: a virtual clock that moves only by the waits. The test also fails after 20 s of real time.
- While ERT runs, `claude-code-ide-tests--isolate-run` (an advice on `ert-run-tests`) binds the state file, the lock file folder, the MCP config folder, the provider file, `CLAUDE_CONFIG_DIR` and `CODEX_HOME` to a new folder of the run (`claude-code-ide-tests--run-directory`), and removes it after the run. Never write to a fixed shared path in a test, and never read or write the user's live folders (`~/.claude`, `~/.codex`, the live state files).
- The one exception is the live tests of `tests/claude-code-ide-live-tests.el`, gated by `CLAUDE_CODE_IDE_LIVE_TESTS=1` and an own daemon. The real CLIs read their login and config there, and write transcripts; with `CLAUDE_CODE_IDE_LIVE_TRUST=1` they also write folder trust entries. The package state still goes to the live folder. docs/live-tests.md lists every such write and how to remove it.

## Committing code
Never commit changes unless the user explicitly asks you to.
