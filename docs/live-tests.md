# Live tests

The live tests start the real `claude` and `codex` CLIs in real Emacs terminals.
They check what the unit tests cannot: the handover between real conversations, and the dialogs of the Codex terminal.

- Code: `claude-code-ide-live-tests.el`.
- The handover: [handover.md](handover.md). Codex: [codex.md](codex.md).
- The process tests have their own live tests in `claude-code-ide-process-tests.el`. They run in batch Emacs.

## When they run

- Each live test (`claude-code-ide-live-test-…`) skips unless all of these are true:
  - `CLAUDE_CODE_IDE_LIVE_TESTS=1` is set.
  - Emacs is a daemon (`daemonp`), not in batch mode. The CLIs need real terminals, and a person's Emacs must never run them.
  - The mocks of `claude-code-ide-tests.el` are not loaded.
- The gate is part of the macro `claude-code-ide-live-tests--live`, which holds the body of each live test. So a live test cannot leave it out.
- `./scripts/compile-and-test.sh` loads the file. Its live tests skip, and the unit tests of its helpers (`claude-code-ide-live-tests-test-…`) run. One of them runs each live test and checks that it skips.
- The tests cost quota: each one runs one or more turns of each CLI. Keep the selector small, and run one CC and one Codex conversation at a time.

## Before you start

- **Codex needs the `claude-sessions` MCP server** for the test `handover-chain`. It reads past Claude Code sessions. The user's Codex config must have a `[mcp_servers.claude-sessions]` table. Without it, the document has no session tools, and the test fails.
- **One live folder for each daemon.** Two daemons must not share one live folder: they would share the registry, the inbox, and the hooks. The setup claims the folder in the file `owner` (the process ID and the start time of the Emacs). It refuses a folder that a live Emacs holds; use `CLAUDE_CODE_IDE_LIVE_DIR` for a second daemon. A claim of an Emacs that ended counts as old, so the recovery test can start its second daemon.

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

- **The environment of the CLIs.** The setup adds `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, and `CLAUDE_CODE_ENTRYPOINT` to `claude-code-ide-cli-environment-unset`, so the Claude Code CLI never gets them. It also turns on `claude-code-ide-codex-remove-openai-api-key`.
  - An API key would bill the API instead of the subscription.
  - A Claude Code that inherits `CLAUDE_CODE_CHILD_SESSION` saves no transcript, and a handover needs the transcript.
  - `CLAUDE_CODE_SSE_PORT` is not in the list: the package sets it for each CLI, and the list would remove that value too.
  - The `env -u` of the command above also keeps them from Emacs itself.
- Use a ghostel version that has its compiled module (`ghostel-module.dylib`).

Run tests from the shell. The call returns at once; the results go to the file:

```sh
emacsclient -s cci-live -e '(claude-code-ide-live-tests-run "handover-chain" "/abs/path/results.txt")'
```

- The file gets one line for each test (`PASSED`, `FAILED` with the condition, or `SKIPPED`), and `done` at the end.
- The live folder gets `log.txt`, with each step of each test.
- Each test stops all instances before and after its body, also after a failure, and deletes its codeword files (`note-*.txt`).
- Stop the daemon at the end: `emacsclient -s cci-live -e '(kill-emacs)'`.

## The live folder

`claude-code-ide-live-tests-setup` points the package at the live folder: `CLAUDE_CODE_IDE_LIVE_DIR`, default `tmp/live/` next to the test file. `tmp/` is in `.gitignore`.

- The folder (mode 0700) holds the registry, the report folder with the hook scripts and the events, the inbox, the MCP config files, the coordinator credential, the provider file, the IDE lock files (through an advice of `claude-code-ide-mcp--lockfile-directory`), and the test projects.
- The test projects are Git repositories: `projA`, `projB`, `projC`, and `dialogs-untrusted-<backend>`.
- The setup turns on `claude-code-ide-session-registry-mode` and the MCP tools server (random port), and registers the Emacs tools (`claude-code-ide-emacs-tools-setup`).
- It logs each stage that a handover saves, and each start (`starts.txt`), so that a test after a restart of Emacs sees the starts before it.
- The CLIs keep their own login and configuration (`~/.claude`, `~/.codex`).

## Variables

| Variable | Effect |
|---|---|
| `CLAUDE_CODE_IDE_LIVE_TESTS=1` | The tests run. |
| `CLAUDE_CODE_IDE_LIVE_TRUST=1` | A test may answer the folder trust dialog of a CLI for a test project, as a person. Without it, a test whose project gets the question skips. |
| `CLAUDE_CODE_IDE_LIVE_KILL=<stage>` | The recovery test part 1 runs, and kills its Emacs at that stage. |
| `CLAUDE_CODE_IDE_LIVE_DIR` | The live folder. |
| `CLAUDE_CODE_IDE_LIVE_CLAUDE_FLAGS` | Replaces the Claude Code flags (below). |
| `CLAUDE_CODE_IDE_LIVE_CODEX_FLAGS` | Replaces the Codex flags (default: low reasoning effort, and no approval for the tools of `claude-sessions`). |

## Permissions of the CLIs

- **Claude Code** gets `--model sonnet --add-dir ~/.codex/sessions --disallowedTools Bash --allowedTools 'Read,Glob,Grep,Edit(.handover/**),Write(.handover/**)'`.
  - It reads with Read, Glob, and Grep without a question, also the Codex rollouts.
  - It writes only the files of the handover folder (the state summary) without a question.
  - It has no Bash. So it runs no command, and it reads the transcripts with the read tools.
  - There is no `acceptEdits` and no bypass mode.
- **The test approves only read tools.** When a CLI asks for an approval, `claude-code-ide-live-tests--approve-while` reads the tool name of the `PermissionRequest` event.
  - Read, Glob, Grep, and the tools of `claude-sessions` get "1. Yes", as a person would answer. The log has the tool and the screen.
  - Any other tool fails the test. The test never allows a write or a command.

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

### Folder trust

- A trust check reads the config file of each CLI: `claude-code-ide-transcript--claude-config-file` (in `CLAUDE_CONFIG_DIR` when it is set) and `claude-code-ide-transcript--codex-config-file` (in `CODEX_HOME`). The key is the true name of the folder (`file-truename`), as the CLIs write it.
- A folder without an entry gets one start of the CLI:
  - When the CLI reaches its prompt without the question, the folder counts as trusted (for example through a trusted parent folder). For Claude Code that is its session start: it runs no hook in a folder that it does not trust. For Codex it is the composer ("Ask Codex to do anything").
  - When the CLI asks, the test answers as a person with `CLAUDE_CODE_IDE_LIVE_TRUST=1`, and skips without it.

### The codeword

- Each handover test writes a codeword file in the project, for example `MARMOT-731`.
- The source reads it with a tool and replies only "done". Then the test deletes the file.
- So the codeword is only in a tool result of the source. The handover document leaves tool results out; the test checks that the document does not have the codeword.
- The question to the target does not have the codeword either. A right answer shows that the target read the earlier session.

### Turns, request IDs and prompts

- **The turn of a prompt.** The test submits each prompt with a request ID, and waits until its request status is `delivered`. The turn that answers it is the first turn end after the `prompt-submit` event with that text. An earlier turn end, for example of the first turn of a target, does not count.
- Each handover gets a new request ID (`<label>-<time>`): a known request ID returns the result of the earlier handover.
- The prompts do not call the codeword a secret, and do not forbid to repeat it. With such a prompt, the Claude Code target refused to say it later ("I will not do this").

### The chain

1. Leg 1 (CC) reads codeword 1. The handover to Codex commits.
2. The document has the `claude-sessions` tool names. The question asks leg 2 to use them, because the document offers the tools or the file, and Codex chose the file without the hint. Leg 2 answers codeword 1. Its rollout exists and has calls of `mcp__claude_sessions__get_session_outline` or `get_messages` (tool call records only, not the text of the document).
3. Leg 2 reads codeword 2. The handover to CC commits.
4. The document of leg 3 has the first prompt of leg 1 one time, its own marker one time, and not codeword 2. (Codeword 1 is in it: leg 2 said it in its answer.) The registry chain of leg 3 is `claude, codex, claude`, with no pending leg. `chain-current` of legs 1 and 2 gives leg 3.
5. Leg 3 answers codeword 2 from the Codex rollout (file reference).

In `handover-file-reference`, the rollout of the target must exist before the test checks that it has no `claude-sessions` call.

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
- After the approval, the queued prompt is delivered, and its own turn (the first turn end after its delivery) answers it.

ghostel draws only in a window of a real frame. The test makes an invisible GUI frame in the daemon (`(make-frame '((window-system . ns) (visibility . nil)))`) and shows each terminal of the dialog tests there, for all backends, as a person sees it. An eat terminal that no window shows keeps only the end of the approval dialog, so the screen reader misses it (bug 3 of the report L.md).

- The test logs the screen text of each dialog to `log.txt`.
- The approval prompt names the tool as Codex shows it (`mcp__emacs_tools__claude_code_ide_mcp_project_info`). With the name `claude-code-ide-mcp-project-info`, Codex found no tool and replied without a call.
- The tests `stop-asks-nothing` check that a stop asks no question such as "Buffer has a running process; kill it?". An eat terminal asked it before `fix/eat-stop` (PR #22). The stops of the other tests still bind `kill-buffer-query-functions` to nil, so that an older package cannot block the daemon.

## What the tests write outside the live folder

- **Folder trust, only with `CLAUDE_CODE_IDE_LIVE_TRUST=1`:**
  - The Codex config (`~/.codex/config.toml`): `[projects."<project>"] trust_level = "trusted"`, written by Codex when the test answers its dialog.
  - The Claude Code config (`~/.claude.json`): the project entry with `hasTrustDialogAccepted`, written by Claude Code.
- **Conversations:** Claude Code transcripts in `~/.claude/projects/<folder name>/`, and Codex rollouts in `~/.codex/sessions/`. Each first prompt starts with `cci-test-`, or with the handover marker.
- Each Claude Code start can add a project entry to `~/.claude.json`, and each Codex terminal start can write `[tui]` keys to `~/.codex/config.toml`.

### Clean up

1. Stop the daemon, and make sure that no `claude` or `codex` process runs in the live folder (`lsof -d cwd`). A CLI that runs writes its config file again.
2. List what the tests left: `emacsclient -s cci-live -e '(claude-code-ide-live-tests-show-leftovers)'` in a live daemon, or `(claude-code-ide-live-tests-leftovers "<live folder>")` in any Emacs that loaded the file. It only reads, and it lists:
   - the `[projects."…"]` tables of the Codex config for folders in the live folder;
   - the `projects` entries with `hasTrustDialogAccepted` of the Claude Code config for those folders;
   - the Claude Code transcript folders of those folders.
3. Remove them by hand:
   - **Codex config:** make a backup copy of `~/.codex/config.toml`, then delete each listed table: its `[projects."…"]` line and its `trust_level` line.
   - **Claude Code config:** make a backup copy of `~/.claude.json`, then delete each listed key under `projects`, for example with `jq 'del(.projects["<folder>"])' ~/.claude.json` written to a new file that you check and then move over the old one.
   - **Transcripts:** delete each listed folder under `~/.claude/projects/`.
   - **Codex conversations:** `codex archive <id>` for each rollout whose `cwd` is in the live folder.
4. Run `claude-code-ide-live-tests-leftovers` again: all three lists are empty.
