# Live tests

The live tests start the real `claude` and `codex` CLIs in real Emacs terminals.
They check what the unit tests cannot: the handover between real conversations, and the dialogs of the Codex terminal.

- Code: `claude-code-ide-live-tests.el`.
- The handover: [handover.md](handover.md). Codex: [codex.md](codex.md).
- The process tests have their own live tests in `claude-code-ide-process-tests.el`. They run in batch Emacs.

## When they run

- Each test skips unless all of these are true:
  - `CLAUDE_CODE_IDE_LIVE_TESTS=1` is set.
  - Emacs is not in batch mode. The CLIs need real terminals.
  - The mocks of `claude-code-ide-tests.el` are not loaded.
- So `./scripts/compile-and-test.sh` loads the file and skips its tests.
- The tests cost quota: each one runs one or more turns of each CLI. Keep the selector small.

## Start a daemon of your own

Never run the tests in the Emacs that you work in. Start a new daemon with `emacs -Q`:

```sh
cd <this repository>
env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_CHILD_SESSION \
    CLAUDE_CODE_IDE_LIVE_TESTS=1 CLAUDE_CODE_IDE_LIVE_TRUST=1 \
  emacs -Q --daemon=cci-live -L . \
    -L ~/.emacs.d/elpa/vterm-<version> -L ~/.emacs.d/elpa/eat-<version> \
    -L ~/.emacs.d/elpa/ghostel-<version> -L ~/.emacs.d/elpa/websocket-<version> \
    -L ~/.emacs.d/elpa/web-server-<version> -L ~/.emacs.d/elpa/transient-<version> \
    -L ~/.emacs.d/elpa/cond-let-<version> -L ~/.emacs.d/elpa/llama-<version> \
    -L ~/.emacs.d/elpa/compat-<version> \
    -l claude-code-ide-live-tests.el --eval '(claude-code-ide-live-tests-setup)'
```

- **Unset the variables of a parent CLI.** A Claude Code that starts below a Claude Code session inherits `CLAUDE_CODE_CHILD_SESSION`, and then it saves no transcript. A handover needs the transcript.
- **Unset the API keys,** so that both CLIs use the subscription login.
- Use a ghostel version that has its compiled module (`ghostel-module.dylib`).

Run tests from the shell. The call returns at once; the results go to the file:

```sh
emacsclient -s cci-live -e '(claude-code-ide-live-tests-run "handover-chain" "/abs/path/results.txt")'
```

- The file gets one line for each test (`PASSED`, `FAILED` with the condition, or `SKIPPED`), and `done` at the end.
- The live folder gets `log.txt`, with each step of each test.
- Stop the daemon at the end: `emacsclient -s cci-live -e '(kill-emacs)'`.

## The live folder

`claude-code-ide-live-tests-setup` points the package at the live folder: `CLAUDE_CODE_IDE_LIVE_DIR`, default `tmp/live/` next to the test file.

- The folder holds the registry, the report folder with the hook scripts and the events, the inbox, the MCP config files, the provider file, the IDE lock files (through an advice of `claude-code-ide-mcp--lockfile-directory`), and the test projects.
- The test projects are Git repositories: `projA`, `projB`, `projC`, and `dialogs-untrusted-<backend>`.
- The setup turns on `claude-code-ide-session-registry-mode` and the MCP tools server (random port), and registers the Emacs tools (`claude-code-ide-emacs-tools-setup`).
- It logs each stage that a handover saves, and each start (`starts.txt`), so that a test after a restart of Emacs sees the starts before it.
- The CLIs keep their own login and configuration (`~/.claude`, `~/.codex`).

## Variables

| Variable | Effect |
|---|---|
| `CLAUDE_CODE_IDE_LIVE_TESTS=1` | The tests run. |
| `CLAUDE_CODE_IDE_LIVE_TRUST=1` | A test may answer the folder trust dialog of a CLI for a test project, as a person. Without it, a test whose project has no trust skips. |
| `CLAUDE_CODE_IDE_LIVE_KILL=<stage>` | The recovery test part 1 runs, and kills its Emacs at that stage. |
| `CLAUDE_CODE_IDE_LIVE_DIR` | The live folder. |
| `CLAUDE_CODE_IDE_LIVE_CLAUDE_FLAGS` | Replaces the Claude Code flags (default: `--model sonnet --permission-mode acceptEdits --add-dir ~/.codex/sessions`). |
| `CLAUDE_CODE_IDE_LIVE_CODEX_FLAGS` | Replaces the Codex flags (default: low reasoning effort, and no approval for the tools of `claude-sessions`). |

## Hook trust of Codex

- The hook script is in the live folder, so the Codex config has no trust record for it. The tests never write one.
- So the tests pass `--dangerously-bypass-hook-trust` to Codex, and an advice of `claude-code-ide-codex-events--cached-trust` reports `trusted`.
- The test `handover-hooks-not-trusted` turns the advice off and uses the real check.
- The hooks review dialog test leaves out the bypass flag, so that Codex shows the dialog.

## The tests

| Test | What it checks |
|---|---|
| `handover-chain` | CC → Codex with `claude-sessions`, Codex → CC, and the chain of three legs. |
| `handover-file-reference` | CC → Codex with `claude-code-ide-handover-session-server` nil. |
| `handover-hooks-not-trusted` | A coordinator handover to Codex without trusted hooks gets `hooks-not-trusted`, twice: before and after the real check. |
| `handover-stray` | A process in the worktree gives `needs-user/strays`; `end` ends it, and the handover commits. |
| `stop-asks-nothing-vterm`, `-eat`, `-ghostel` | `claude-code-ide-control-stop` ends a Codex instance without a question such as "Buffer has a running process; kill it?". |
| `recovery-1-kill`, `recovery-2-after-kill` | A crash of Emacs between `source-stopped` and `committed`; the next Emacs starts only the target. |
| `codex-dialogs-vterm`, `-eat`, `-ghostel` | The folder trust, hooks review, and approval dialogs of Codex in each terminal. |

### The codeword

- Each handover test writes a codeword file in the project, for example `MARMOT-731`.
- The source reads it with a tool and replies only "done". Then the test deletes the file.
- So the codeword is only in a tool result of the source. The handover document leaves tool results out; the test checks that the document does not have the codeword.
- The question to the target does not have the codeword either. A right answer shows that the target read the earlier session.

### Approvals and request IDs

- A question to a target needs reads only. While the target answers it, and while it runs its first turn, the test approves each tool call as a person ("1. Yes"), and logs the screen of each approval. Claude Code asks before it reads a file outside the project, for example the Codex rollout.
- Each handover gets a new request ID (`<label>-<time>`): a known request ID returns the result of the earlier handover.
- The prompts do not call the codeword a secret, and do not forbid to repeat it. With such a prompt, the Claude Code target refused to say it later ("I will not do this").

### The chain

1. Leg 1 (CC) reads codeword 1. The handover to Codex commits.
2. The document has the `claude-sessions` tool names. The question asks leg 2 to use them, because the document offers the tools or the file, and Codex chose the file without the hint. Leg 2 answers codeword 1, and its rollout has calls of `mcp__claude_sessions__get_session_outline` or `get_messages` (tool call records only, not the text of the document).
3. Leg 2 reads codeword 2. The handover to CC commits.
4. The document of leg 3 has the first prompt of leg 1 one time, its own marker one time, and not codeword 2. (Codeword 1 is in it: leg 2 said it in its answer.) The registry chain of leg 3 is `claude, codex, claude`, with no pending leg. `chain-current` of legs 1 and 2 gives leg 3.
5. Leg 3 answers codeword 2 from the Codex rollout (file reference).

### The recovery

1. Start the daemon with `CLAUDE_CODE_IDE_LIVE_KILL=target-identified` (or another stage after `source-stopped`), and run `recovery-1-kill`.
2. At the save of that stage, an advice writes `recovery.eld` to the live folder and sends SIGKILL to Emacs.
3. Start a new daemon with the same live folder, without the kill variable. The registry mode turns on at its start, and its recovery runs in the first idle moment.
4. Run `recovery-2-after-kill`. It checks:
   - the handover commits with the same target ID;
   - this Emacs started only the target (`starts.txt` of the live folder);
   - no CLI process runs with the conversation ID of the source;
   - `chain-current` of the source gives the target;
   - the target answers the codeword of the source.

### The dialogs

For each backend:

1. **Folder trust:** Codex in a new repository. The state is `waiting-for-user/dialog`. Nobody answers, so no trust is saved.
2. **Hooks review:** Codex with the hooks and without the bypass flag. The state is `waiting-for-user/dialog`. Nobody answers.
3. **Approval:** Codex calls an MCP tool of `emacs_tools` that needs an approval (`claude-code-ide-mcp-allowed-tools` nil). The state is `waiting-for-user/approval`. Then the test answers Return (allow), as a person.

In each dialog, the test submits a prompt with `claude-code-ide-control-submit`:

- The result is `queued`.
- The terminal does not show the text, and the dialog stays.
- After the approval, the queued prompt is delivered.

ghostel draws only in a window of a real frame. The test makes an invisible GUI frame in the daemon (`(make-frame '((window-system . ns) (visibility . nil)))`) and shows each terminal of the dialog tests there, for all backends, as a person sees it.

- The test logs the screen text of each dialog to `log.txt`.
- The approval prompt names the tool as Codex shows it (`mcp__emacs_tools__claude_code_ide_mcp_project_info`). With the name `claude-code-ide-mcp-project-info`, Codex found no tool and replied without a call.
- The stops of the tests bind `kill-buffer-query-functions` to nil, because an eat terminal asks before its buffer is killed. The tests `stop-asks-nothing` check that question.

## What the tests write outside the live folder

- **Folder trust, only with `CLAUDE_CODE_IDE_LIVE_TRUST=1`:**
  - `~/.codex/config.toml`: `[projects."<project>"] trust_level = "trusted"`, written by Codex when the test answers its dialog.
  - `~/.claude.json`: the project entry with `hasTrustDialogAccepted`, written by Claude Code.
- **Conversations:** Claude Code transcripts in `~/.claude/projects/`, and Codex rollouts in `~/.codex/sessions/`. Each first prompt starts with `cci-test-`. Archive the Codex ones with `codex archive <id>`.
- Each Claude Code start can add a project entry to `~/.claude.json`, and each Codex terminal start can write `[tui]` keys to `~/.codex/config.toml`.
