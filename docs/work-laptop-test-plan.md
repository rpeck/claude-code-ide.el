# Work-laptop test plan for release 1.2.0

Use this plan on the work laptop before the 1.2.0 tag.

- Use a fresh Emacs profile when possible.
- Do not run this plan in the Emacs that you use for daily work. Step 1 of "Before you start" tells how.
- The plan checks PRs #20 to #34 of the fork. #34 has the fixes of the Goldfish review (issue #33 lists what stays open).
- For more detail, read [codex.md](codex.md), [status-events.md](status-events.md), [handover.md](handover.md), [live-tests.md](live-tests.md), and [updating.md](updating.md).

Each step has one action. Under the step:

- **Expected:** the result that you must see.
- **If it fails:** what to save for the report.

To find the ID of an instance, evaluate `M-: (claude-code-ide-control-list-instances) RET`. Each instance has an `:instance-id`.

## Before you start

1. Quit the Emacs that you use for daily work, and each Emacs daemon.
   - Two Emacs processes share the registry file, the report directory, and the inbox. The restore of one Emacs can start or claim the instances of the other.
   - On macOS, a start from the Dock only brings a running Emacs to the front.
2. Install Emacs 28.1 or later, Git, `claude`, and `codex`.
3. Install the Emacs packages vterm, eat, ghostel, websocket, web-server, and transient.
   - The package needs websocket 1.12, transient 0.9.0, and web-server 0.1.2 or later.
4. In a normal terminal (not in Emacs), log in to Claude Code with `claude`.
   - **Expected:** `claude` shows its prompt after the login. Exit it.
5. In a normal terminal, log in to Codex with `codex login`.
   - **Expected:** the command reports a successful login.
6. Run `emacs --version`, `git --version`, `claude --version`, and `codex --version`.
   - **Expected:** each command prints a version.
   - Record every version in the results file (step 13).
   - The Codex support is verified with Codex 0.164.0. If the version is different, record it, and look closely at areas 3 and 4.
7. Back up the Emacs init file, for example `cp -p ~/.emacs.d/init.el ~/.emacs.d/init.el.before-cci-1.2.0`.
   - **Expected:** the backup exists.
8. Back up the Codex configuration: `cp -p ~/.codex/config.toml ~/.codex/config.toml.before-cci-1.2.0`.
   - **Expected:** the backup exists.
   - On a fresh machine, the source file may not exist. Then record that fact.
9. Back up the Claude Code configuration: `cp -p ~/.claude.json ~/.claude.json.before-cci-1.2.0`.
   - **Expected:** the backup exists, or you recorded that the source file does not exist.
10. Back up the session registry: `cp -p ~/.emacs-claude-code-ide-state-v4.json ~/.emacs-claude-code-ide-state-v4.json.before-cci-1.2.0`.
    - **Expected:** the backup exists, or you recorded that the source file does not exist.
    - If you set `claude-code-ide-state-file`, back up its `-v4` file instead.
    - Also record whether `~/.emacs-claude-code-ide-state-reports/` exists.
11. Make a plain test repository: `mkdir -p ~/Source/cci-laptop-plain && git -C ~/Source/cci-laptop-plain init`.
    - **Expected:** the folder contains `.git`.
12. Make a test repository with a space in its path: `mkdir -p ~/Source/'cci laptop space' && git -C ~/Source/'cci laptop space' init`.
    - **Expected:** the folder contains `.git`.
13. Make the results file: `touch ~/cci-1.2.0-results.txt`.
    - After each area, write `PASS`, `FAIL`, or `SKIP` and a short note.

## 1. Preparation

The package is not installed yet in this area. So these steps use only Emacs itself.

1. Start Emacs from the Dock, not from a shell.
2. Evaluate `M-: (list (executable-find "claude") (executable-find "codex")) RET`.
   - **Expected:** both values are file names.
   - **If it fails:** Emacs from the Dock does not get the shell `PATH`. Record this. Then set `exec-path`, or use `exec-path-from-shell`, and evaluate again.
3. Evaluate `M-: (mapcar (lambda (name) (cons name (and (getenv name) t))) '("OPENAI_API_KEY" "ANTHROPIC_API_KEY" "CODEX_HOME" "CLAUDE_CONFIG_DIR")) RET`.
   - **Expected:** Emacs shows `t` for each variable that is set.
   - Record only whether each variable is set. Do not copy a secret into the results file.
   - If `ANTHROPIC_API_KEY` is set, record it. Area 2, step 4 sets the option against it.
4. Record the work policies that can change the results:
   - managed Codex hooks or a managed Codex configuration;
   - managed Claude Code settings;
   - local ports that a firewall blocks.

## 2. Install and update on a fresh machine

1. Clone the fork: `git clone <fork URL> ~/Source/claude-code-ide.el`.
2. Check out `main`: `git -C ~/Source/claude-code-ide.el checkout main`.
   - **Expected:** Git reports the branch.
3. Add the `use-package` form of README.org, section "From a local checkout", to the Emacs init file.
   - The form has `:load-path`, `:demand t`, `claude-code-ide-session-registry-mode`, and `claude-code-ide-session-status-mode`.
4. If area 1, step 3 found `ANTHROPIC_API_KEY`, keep the line of the form that sets `claude-code-ide-cli-environment-unset` to `'("ANTHROPIC_API_KEY")`.
   - Else Claude Code bills the API key.
5. Restart Emacs.
   - A short time after the start, Emacs can ask about the trust of the Codex status hooks. Press `C-g`. Area 3 tests this question.
6. Evaluate `M-: (locate-library "claude-code-ide") RET`.
   - **Expected:** the value is in `~/Source/claude-code-ide.el`.
   - **If it fails:** remove an installed copy with `M-x package-delete RET claude-code-ide RET`. Remove `claude-code-ide` from `package-vc-selected-packages`. Restart Emacs. Save `*Messages*`.
7. Evaluate `M-: (list claude-code-ide-session-registry-mode claude-code-ide-session-status-mode) RET`.
   - **Expected:** `(t t)`.
8. Evaluate `M-: claude-code-ide-state-file RET`.
   - **Expected:** the default is `~/.emacs-claude-code-ide-state.json`.
   - The registry file is the same name with `-v4`: `~/.emacs-claude-code-ide-state-v4.json`.
   - The report directory is the same name with `-reports`: `~/.emacs-claude-code-ide-state-reports/`.
9. Run `M-x customize-group RET claude-code-ide RET`.
   - **Expected:** Emacs shows the options. Record each option that is not at its default.
10. Evaluate `M-: (require 'vterm) RET`.
    - **Expected:** the value is `vterm`.
    - On a fresh machine, vterm asks to compile its module. Answer yes. The compile needs `cmake`.
    - **If it fails:** save the output buffer of the compile and `*Messages*`.
11. Evaluate `M-: (require 'eat) RET`.
    - **Expected:** the value is `eat`.
12. Evaluate `M-: (require 'ghostel) RET`.
    - **Expected:** the value is `ghostel`.
13. Evaluate `M-: (locate-file "ghostel-module" load-path '(".dylib")) RET`.
    - **Expected:** the value is the file `ghostel-module.dylib`.
14. Evaluate `M-: (mapcar #'require '(websocket web-server transient)) RET`.
    - **Expected:** the value is `(websocket web-server transient)`.
    - **If it fails:** save `*Messages*` and the version that `M-x describe-package RET <package> RET` shows.
15. Copy the checkout to a path with a space: `cp -R ~/Source/claude-code-ide.el ~/Source/'claude code ide space'`.
16. Compile and test the copy: `cd ~/Source/'claude code ide space' && ./scripts/compile-and-test.sh`.
    - **Expected:** the byte compilation and all tests pass.
    - **If it fails:** save the full output and the name of the first failed test.
17. In the init file, change `my/claude-code-ide-dir` to `~/Source/claude code ide space`.
18. Restart Emacs. If Emacs asks about the Codex status hooks, press `C-g`.
19. Evaluate `M-: (locate-library "claude-code-ide") RET`.
    - **Expected:** the value is in `~/Source/claude code ide space`.
20. Run `M-x load-library RET claude-code-ide-reload RET`.
    - A checkout on `load-path` has no autoloads, so this step is necessary one time.
21. Run `M-x claude-code-ide-reload`.
    - **Expected:** the message starts with `Reloaded`, has no `failed`, and names the restarted modes.
    - **If it fails:** save the full message and `*Messages*`.

## 3. The Codex CLI: detection, first start, and trust

The hook trust of Codex is not per project. One trust record in `~/.codex/config.toml` is valid for all projects. So do the steps of this area in this order.

1. Look for earlier hook trust records: `grep -n 'hooks.state' ~/.codex/config.toml`.
   - **Expected:** no line, or no file.
   - If lines exist, the machine is not fresh for this area. Record the lines.
2. Restart Emacs, and wait some seconds without a key press.
   - **Expected:** Emacs shows the buffer `*Codex status hooks*`, and asks a yes-or-no question about the trust. This is the check after the start of Emacs (`claude-code-ide-codex-events-trust-at-load`).
   - The question comes only when Emacs is idle. It does not come while you type.
   - Press only `y`. **Expected:** the key does not answer. The question needs the typed word, also when your init file makes `yes-or-no-p` an alias of `y-or-n-p`.
   - **If it fails:** save the debug log and `*Messages*`.
3. Type `no`, and press `RET`.
   - **Expected:** Emacs asks nothing more in this Emacs.
4. Open a file in `~/Source/cci-laptop-plain`.
5. Run `M-x claude-code-ide-codex`.
   - **Expected:** Emacs does not ask about the hooks, because you declined in this Emacs. Codex starts in a terminal buffer without status hooks.
6. If Codex shows its folder trust dialog, look at the status buffer first: `M-x claude-code-ide-show-session-status`.
   - **Expected:** the buffer `*Coding Agents Sessions*` opens. The row shows `waiting-for-user/dialog`.
7. Answer the folder trust dialog yourself in the terminal.
   - **Expected:** Emacs does not answer the dialog. The Codex composer appears.
   - **If it fails:** save the terminal screen, `*Messages*`, and `*Coding Agents Sessions*`.
8. Look at the row of the new instance before the first prompt.
   - **Expected:** the state is `disconnected/untracked`. A new Codex session has no native ID before its first prompt.
   - The detail says `Hooks not trusted; M-x claude-code-ide-codex-trust-hooks trusts them`.
9. Send one short prompt, for example `Say hello.`
   - **Expected:** while Codex works, the row shows a `?` and the detail `From rollout: a turn runs`.
10. Wait for the reply.
    - **Expected:** the row shows `idle`, a `?`, and the detail `From rollout: turn ended`.
11. Send a long prompt, for example `Write a 600-word story.` Then press `Esc` in the terminal.
    - **Expected:** the detail becomes `From rollout: interrupted`.
12. Run `C-u M-x claude-code-ide-codex`, and give the instance name `second`.
    - **Expected:** Emacs does not ask about the hooks.
13. Run `M-x claude-code-ide-codex-trust-hooks`.
    - **Expected:** `*Codex status hooks*` lists the hooks, and Emacs asks.
14. Type `yes`, and press `RET`.
    - **Expected:** Emacs reports the result.
15. Run `grep -n -A1 'hooks.state' ~/.codex/config.toml`.
    - **Expected:** each hook has a `[hooks.state."..."]` table with a `trusted_hash` line.
    - **If it fails:** save `*Codex status hooks*`, the debug log, and `*Messages*`.
16. Look at the row of the first instance.
    - **Expected:** the detail has `Hooks were not trusted at the launch: restart to get status`.
17. Stop both instances (area 7 shows how).
18. Open a file in `~/Source/cci laptop space`.
19. Run `M-x claude-code-ide-codex`.
    - **Expected:** Emacs does not ask about the hooks.
20. Answer the folder trust dialog of Codex yourself.
21. Send `Say hello.`, and wait for the reply.
    - **Expected:** the row shows `idle` with no `?`. The state comes from the hooks.
    - **If it fails:** a path with a space can break the hook command. Save the hook command from the debug log and the path of the report directory.
22. Restart Emacs, and wait some seconds.
    - **Expected:** Emacs does not ask about the hooks. They are trusted.
23. Run `M-x claude-code-ide-restore-sessions`.
    - **Expected:** Emacs starts the Codex instance of step 19 again.
    - Emacs asks at most one time about the hook trust for the whole restore. With the trust of step 14, it does not ask.
24. Stop that instance.
25. Set `claude-code-ide-codex-cli-path` to a file that does not exist: `M-: (setq claude-code-ide-codex-cli-path "/nonexistent/codex") RET`.
26. Run `M-x claude-code-ide-codex`.
    - **Expected:** the message says `Codex CLI not available.  Please install it and ensure it's in PATH`. No terminal starts.
27. Make a file that is not executable: `touch ~/cci-codex-noexec`.
28. Evaluate `M-: (setq claude-code-ide-codex-cli-path (expand-file-name "~/cci-codex-noexec")) RET`.
29. Run `M-x claude-code-ide-codex`.
    - **Expected:** the same message as in step 26. The detection finds no executable file.
    - The messages with `exit 127` and `exit 126` come only from a terminal that cannot run a program that the detection found. This plan does not make that case.
    - **If it fails:** save the full message.
30. Evaluate `M-: (custom-reevaluate-setting 'claude-code-ide-codex-cli-path) RET`, and delete `~/cci-codex-noexec`.

## 4. The status of both providers

Use a Codex instance with trusted hooks in `~/Source/cci-laptop-plain` for steps 1 to 9.

1. Run `M-x claude-code-ide-show-session-status`.
   - **Expected:** Emacs shows `*Coding Agents Sessions*`.
2. Start Codex with `M-x claude-code-ide-codex`.
3. Send `Say hello.`
   - **Expected:** the row shows `working`, and then `idle`.
4. Ask Codex to run the shell command `touch ~/cci-approval-test`. A write outside the project needs an approval.
   - **Expected:** the row shows `waiting-for-user/approval`.
   - If Codex does not ask, record the approval policy that `/status` shows in the terminal.
5. Allow the command in the terminal.
   - **Expected:** the approval stays until the tool ends. Then the row shows `working` or `idle`.
6. Delete `~/cci-approval-test`.
7. Send `Ask me one question with two options, and wait for my answer.`
   - **Expected:** the row shows `waiting-for-user/question`.
8. Send `Start a subagent that lists the files of this folder.`
   - **Expected:** the row shows `waiting-for-task/subagent` while the subagent runs.
   - After the reply, send `Say hello.` **Expected:** the row shows `working`, then `idle`. It does not stay `waiting-for-task/subagent`.
9. Kill the terminal buffer with `C-x k RET`.
   - **Expected:** the row shows `disconnected`.
   - No ` [stopped]` copy stays. A kill of the buffer by you makes no copy.
   - **If it fails:** save the debug log, the terminal screen, and `*Coding Agents Sessions*`.
10. Evaluate `M-: (setq claude-code-ide-terminal-backend 'vterm) RET`.
11. Start Codex. Repeat steps 4 and 5.
    - **Expected:** the states are as in steps 4 and 5.
12. Evaluate `M-: (setq claude-code-ide-terminal-backend 'eat) RET`.
13. Start Codex. Repeat steps 4 and 5.
    - **Expected:** the states are as in steps 4 and 5.
14. Evaluate `M-: (setq claude-code-ide-terminal-backend 'ghostel) RET`.
15. Start Codex. Repeat steps 4 and 5.
    - **Expected:** the states are as in steps 4 and 5.
16. Set the backend to eat again. Start Codex, and repeat step 4.
17. While the approval waits, show another buffer in every window of the terminal (`C-x b`).
    - **Expected:** the row stays `waiting-for-user/approval` until the tool ends.
    - **If it fails:** save the end of the terminal buffer, the debug log, `*Messages*`, and `*Coding Agents Sessions*`.
18. Deny the approval in that terminal.
19. Stop all instances of the project: `M-x claude-code-ide-stop-all`, and answer `y`.
20. Turn the registry off: `M-: (claude-code-ide-session-registry-mode -1) RET`.
21. Run `C-u M-x claude-code-ide`, and choose the provider `claude`.
    - `M-x claude-code-ide` without a prefix starts the current provider. That can be Codex now.
22. If Claude Code asks whether you trust the folder, answer yourself.
23. Turn the registry on: `M-: (claude-code-ide-session-registry-mode 1) RET`.
    - **Expected:** the Claude Code row shows `From CLI status: idle (no status hooks)`.
24. Send a long prompt to Claude Code.
    - **Expected:** while it works, the row shows `From CLI status: busy (no status hooks)`.
25. After the reply, put point on the Claude Code row and press `T`.
    - **Expected:** Emacs asks `Restart ... to add status tracking?`.
26. Answer `yes`.
    - **Expected:** Emacs restarts the session. The detail no longer starts with `From CLI status`.
27. Stop all instances of the project again, as in step 19.
28. If a real usage limit occurs, save its exact text.
    - **Expected:** the row shows `failed/quota-limit`.
    - A short rate limit shows `failed/error`.
29. If the Codex account has no Codex plan, start one Codex instance, and send a prompt.
    - **Expected:** the row shows `failed/quota-limit` with `Not included in the plan`.
    - Make sure that no other row waits for you. Else `w` in step 32 goes to that row.
30. In `*Coding Agents Sessions*`, put point on that row, and press `RET`.
    - **Expected:** with `claude-code-ide-codex-events-not-included-action` at its default `ask`, Emacs asks: `c` (continue), `h` (hand over), `s` (stop).
31. Press `c`, and go back to `*Coding Agents Sessions*`.
32. Press `w`. This key goes to the first session that needs you.
    - **Expected:** the same question as in step 30.
33. Press `c`, and go back to `*Coding Agents Sessions*`.
34. Put point on the row, and press `H`.
    - **Expected:** the same question as in step 30. Press `c`.

## 5. The handover

A handover refuses to start while another instance runs in the same worktree (`other-instance`). So stop all instances of the project before each new source: `M-x claude-code-ide-stop-all`, and answer `y`.

1. Add a `[mcp_servers.claude-sessions]` table to `~/.codex/config.toml`. Use the same server as on your other Mac.
2. In `~/Source/cci-laptop-plain`, stop all instances.
3. Start Claude Code with `C-u M-x claude-code-ide`, and choose `claude`.
4. Send one prompt, and wait for the reply.
5. In the Claude Code terminal buffer, run `M-x claude-code-ide-handover`. Choose the target `codex`.
   - **Expected:** Emacs asks `After the handover, should the target go on with the task?`, with `y`, `n`, `a`, and `v`.
6. Answer `n`.
   - **Expected:** the source stops, and a Codex target starts.
   - The source buffer stays as a read-only copy, with ` [stopped]` after its name. It holds the last output of the source.
7. Open the newest `.handover/<id>.md` of the project.
   - **Expected:** the document names `mcp__claude_sessions__get_session_outline`.
8. Wait until the target replies.
   - **Expected:** the target reads the source session, writes its state summary file, and replies `ready`. Then it waits for your prompt.
9. Look at the rollout of the target in `~/.codex/sessions/`.
   - **Expected:** it has a completed call of `mcp__claude_sessions__get_session_outline` or `mcp__claude_sessions__get_messages`, or a read of the transcript file. Codex can choose the file. Record which.
   - **If it fails:** save the handover document, its state summary, the debug log, and `*Coding Agents Sessions*`.
10. Stop all instances.
11. Evaluate `M-: (setq claude-code-ide-handover-session-server nil) RET`.
12. Start a new Claude Code source, and send one prompt. Record its instance ID as SOURCE-A.
13. Hand it over to `codex`, and answer `y` to the continue question.
    - **Expected:** the document names only the transcript file, and the handover commits.
    - After `ready`, the target gets the prompt `The handover is complete. Go on now with the task that your state summary describes ...`, and goes on.
14. Evaluate `M-: (custom-reevaluate-setting 'claude-code-ide-handover-session-server) RET`.
15. In the Codex target of step 13, run `M-x claude-code-ide-handover`, choose the target `claude`, and answer `n`.
    - **Expected:** the document names the Codex rollout file, and the handover commits.
16. Evaluate `M-: (claude-code-ide-session-registry-chain-current "SOURCE-A") RET`.
    - **Expected:** the value is the ID of the Claude Code target of step 15. The chain is claude, codex, claude.
17. Run `M-x claude-code-ide-list-session-registry`.
    - **Expected:** the buffer `*Claude Code Sessions*` shows the three entries of that chain.
18. In `~/Source/cci laptop space`, stop all instances.
19. Start a Claude Code source there, send one prompt, and hand it over to `codex`.
    - **Expected:** the handover commits. The paths in the document are correct.
20. Run `grep -n handover .git/info/exclude` in each test repository.
    - **Expected:** the file has `.handover/`.
21. In `~/Source/cci-laptop-plain`, stop all instances.
22. Make the Codex hooks untrusted: in `~/.codex/config.toml`, delete the `[hooks.state."..."]` tables and their `trusted_hash` lines.
23. Start a Claude Code source with `C-u M-x claude-code-ide`. Send one prompt.
24. Evaluate `M-: (claude-code-ide-handover-session "<source-id>" 'codex) RET`. This is the call of a coordinator.
    - **Expected:** the result has `:reason hooks-not-trusted`. Emacs asks no question. The source keeps running.
25. In the source terminal buffer, run `M-x claude-code-ide-handover`, and choose `codex`.
    - **Expected:** Emacs asks about the hook trust before it starts the target.
26. Answer `yes`, and then `n` to the continue question.
    - **Expected:** the handover commits.
27. Stop all instances.
28. Start a Claude Code source, and send a long prompt, for example `Write a 600-word story.`
29. While it works, evaluate `M-: (claude-code-ide-control-submit "<source-id>" "Say QUEUED-OK." :queue t) RET`.
    - **Expected:** the result has `:result queued`.
30. Run `M-x claude-code-ide-handover` for that source, choose `codex`, and answer `n`.
    - **Expected:** after the commit, the target gets `Say QUEUED-OK.` and answers it.
31. Stop all instances.
32. Start a Claude Code source, and send one prompt.
33. Evaluate `M-: (emacs-pid) RET`, and record the number.
34. Run `M-x claude-code-ide-handover`, choose `codex`, and answer `n`.
35. When the Codex terminal buffer appears, run `kill -9 <pid>` at once in a shell.
    - A normal exit with `C-x C-c` is not a crash. It does not test the recovery.
36. Start Emacs again.
    - **Expected:** the recovery starts or resumes only the target, and the handover commits.
    - The live tests `recovery-1-kill` and `recovery-2-after-kill` check the same case at an exact stage.
    - **If it fails:** save the registry `-v4` file, the report directory, the handover document, and `*Messages*`.

## 6. The MCP tools server

1. Run `M-x claude-code-ide-emacs-tools-setup`.
   - This command also sets `claude-code-ide-enable-mcp-server` to `t`.
2. Start Codex with `M-x claude-code-ide-codex`.
3. In the Codex terminal, type `/mcp`.
   - **Expected:** Codex lists the server `emacs_tools`.
4. Ask Codex to call the tool `claude-code-ide-mcp-project-info` of the server `emacs_tools`.
   - **Expected:** the call `mcp__emacs_tools__claude_code_ide_mcp_project_info` returns the project information.
   - With `claude-code-ide-mcp-allowed-tools` at its default `auto`, the call needs no approval.
   - **If it fails:** save the terminal screen, the debug log, `*Messages*`, and the status buffer.
5. Evaluate `M-: (setq claude-code-ide-mcp-allowed-tools '("claude-code-ide-mcp-project-info")) RET`.
   - Use the registered name, with hyphens. Only registered names count.
6. Start a new Codex instance, and ask it to call `claude-code-ide-mcp-project-info`.
   - **Expected:** the tool runs without an approval.
7. Ask the same instance to call another tool of `emacs_tools`, for example `claude-code-ide-mcp-xref-find-apropos`.
   - **Expected:** Codex asks for an approval.
8. Deny the approval in the terminal.
   - **Expected:** the tool does not run.
9. Evaluate `M-: (setq claude-code-ide-mcp-allowed-tools nil) RET`.
10. Start a new Codex instance, and ask it to call `claude-code-ide-mcp-project-info` two times.
    - **Expected:** Codex asks for each call.
11. Allow the first call, and deny the second call.
    - **Expected:** Codex obeys each answer.
12. Evaluate `M-: (custom-reevaluate-setting 'claude-code-ide-mcp-allowed-tools) RET`.
13. Run `ps -ax -o pid= -o command= | grep '[c]odex'`.
    - **Expected:** the command line has `mcp_servers.emacs_tools.env_http_headers`. Each value in it is a variable name that starts with `CCI_MCP_HEADER_`.
    - The header name `X-Emacs-MCP-Instance-Secret` can show as a key. That is correct.
    - There is no key `mcp_servers.emacs_tools.http_headers`, and no secret value.
14. Ask Codex to run the shell command `env | grep CCI_MCP_HEADER`.
    - **Expected:** the command prints nothing. `shell_environment_policy.exclude` hides the variables.
15. In `~/Source/cci-laptop-plain`, make `.codex/config.toml` with `shell_environment_policy.exclude = ["CCI_USER_SECRET"]`.
16. Start a Codex instance in that project, and look at its command line with `ps`.
    - **Expected:** the exclude list has `CCI_USER_SECRET` and the `CCI_MCP_HEADER_` variables.
    - **If it fails:** save the Codex command line from the debug log and the project configuration.
17. Start a Codex coordinator: `M-: (claude-code-ide-control-launch :directory (expand-file-name "~/Source/cci-laptop-plain") :provider 'codex :role "coordinator") RET`.
18. Ask the coordinator to call `claude-code-ide-control-list-instances`.
    - **Expected:** the tool runs without an approval.
19. Ask the coordinator to call `claude-code-ide-control-handover` for another instance.
    - **Expected:** Codex asks for an approval. Deny it.
20. Stop all instances.

## 7. A stop of an instance in each terminal backend

1. Evaluate `M-: (setq claude-code-ide-terminal-backend 'vterm) RET`.
2. Start Codex with `M-x claude-code-ide-codex`.
3. Evaluate `M-: (claude-code-ide-control-stop "<instance-id>") RET`.
   - **Expected:** the result has `:result stopped` at once. Emacs asks no question.
   - The CLI ends softly, within about 6 seconds. Then the buffer `<name> [stopped]` stays: read-only, with the last output of the CLI.
   - During these seconds, the instance stays in `M-: (claude-code-ide-control-list-instances) RET`.
4. Repeat steps 2 and 3 with the backend `eat`.
   - **Expected:** Emacs does not ask `Buffer has a running process; kill it?`.
5. Repeat steps 2 and 3 with the backend `ghostel`.
   - **Expected:** Emacs asks no question.
6. Repeat steps 1 to 5 with Claude Code. Start it with `C-u M-x claude-code-ide`, and choose `claude`.
   - **Expected:** each stop asks no question.
7. In each backend, start one instance, and stop it with `M-x claude-code-ide-stop` in its terminal buffer.
   - **Expected:** Emacs asks no question.
   - **If it fails:** save the backend name, the terminal screen, `*Messages*`, and `*Coding Agents Sessions*`.
8. Wait 6 seconds after each stop. Then run `ps -ax -o pid= -o command= | grep -E '[c]laude|[c]odex'`.
   - **Expected:** no process of a test project remains.
9. Run `M-x claude-code-ide-kill-stopped-buffers` in a buffer of the test project.
   - **Expected:** the ` [stopped]` buffers of that project close. The ` [stopped]` buffers of other projects stay.
10. Evaluate `M-: (setq claude-code-ide-keep-stopped-buffers nil) RET`. Start Codex, and stop it as in step 3.
    - **Expected:** no ` [stopped]` buffer stays.
11. Evaluate `M-: (custom-reevaluate-setting 'claude-code-ide-keep-stopped-buffers) RET`.
12. Start Codex. Find its `:generation` in `M-: (claude-code-ide-control-list-instances) RET`.
13. Evaluate `M-: (claude-code-ide-control-stop "<instance-id>" :generation 9999) RET`.
    - **Expected:** the result has the reason `generation-changed`. The instance still runs.
14. Evaluate the stop again with the correct generation.
    - **Expected:** `:result stopped`.
15. Start one instance in each backend.
16. Quit Emacs with `C-x C-c`.
    - **Expected:** Emacs asks no question about a running process.
17. Run the `ps` command of step 8 again.
    - **Expected:** no process of a test project remains.

## 8. The reload of the package in a running Emacs

1. Start one Claude Code instance and one Codex instance.
   - **Expected:** both show in `*Coding Agents Sessions*`.
2. Update the checkout that Emacs loads: `git -C ~/Source/'claude code ide space' checkout <other commit>`.
   - **Expected:** Git reports the commit.
3. Run `M-x load-library RET claude-code-ide-reload RET`.
4. Run `M-x claude-code-ide-reload`.
   - **Expected:** the message starts with `Reloaded`, has no `failed`, and names the restarted modes.
   - **If it fails:** save the full message, `*Messages*`, and the debug log.
5. Send one short prompt in each terminal buffer.
   - **Expected:** both CLI processes still run and reply.
6. Run `M-x claude-code-ide-show-session-status`.
   - **Expected:** the status buffer lists both instances.
7. Start a new Codex instance.
   - **Expected:** it starts with no error.
8. Add the line `(error "cci reload test")` at the end of `claude-code-ide-debug.el` in the checkout.
9. Run `M-x claude-code-ide-reload`.
   - **Expected:** the message names `claude-code-ide-debug.el` as failed. The other files load.
10. Remove the line again.
11. Run `M-x claude-code-ide-reload`.
    - **Expected:** the message has no `failed`.
12. Check out `main` again in the checkout.

## 9. The live tests (optional)

The live tests cost quota. Run them only from a shell, in an own daemon.

- `claude-code-ide-live-tests-run` returns at once, and runs its tests from a timer. So wait for `done` in the results file before the next run.
- Give each run its own results file, for example `/abs/path/results-handover-chain.txt`.

1. Find the folder names of the packages: `ls ~/.emacs.d/elpa`.
   - The daemon command needs vterm, eat, ghostel, websocket, web-server, transient, cond-let, llama, and compat.
2. In the checkout, start the daemon with the `emacs -Q --daemon=cci-live` command of [live-tests.md](live-tests.md), section "Start a daemon of your own". Put in the folder names of step 1.
   - **Expected:** the daemon starts, and makes its live folder `tmp/live/`.
   - **If it fails:** save the output of the command, and check each `-L` folder.
3. Run `emacsclient -s cci-live -e '(claude-code-ide-live-tests-run "handover-chain" "/abs/path/results-handover-chain.txt")'`.
4. Wait until the results file ends with `done`.
   - **Expected:** the file has `PASSED` for `handover-chain`.
5. Do steps 3 and 4 for each of `handover-file-reference`, `handover-hooks-not-trusted`, `handover-stray`, and `handover-ghostel-sources-end`. Start a run only after the `done` of the run before it.
   - **Expected:** each test has `PASSED`.
6. Do steps 3 and 4 for each of `stop-asks-nothing-vterm`, `stop-asks-nothing-eat`, and `stop-asks-nothing-ghostel`.
   - **Expected:** each test has `PASSED`.
7. Do steps 3 and 4 for each of `codex-dialogs-vterm`, `codex-dialogs-eat`, `codex-dialogs-ghostel`, and `codex-approval-eat-no-window`.
   - **Expected:** each test has `PASSED`.
8. Stop the daemon: `emacsclient -s cci-live -e '(kill-emacs)'`.
9. Start the daemon again with `CLAUDE_CODE_IDE_LIVE_KILL=target-identified` in the command.
10. Run `recovery-1-kill`, as in step 3.
    - **Expected:** the test kills the daemon at the stage `target-identified`.
11. Start the daemon again, with the same live folder and without `CLAUDE_CODE_IDE_LIVE_KILL`.
12. Run `recovery-2-after-kill`, as in steps 3 and 4.
    - **Expected:** the test has `PASSED`. The recovery started only the target.
    - **If it fails:** save `tmp/live/log.txt`, the results file, and the registry file of the live folder.
13. Run `emacsclient -s cci-live -e '(claude-code-ide-live-tests-show-leftovers)'`.
    - **Expected:** `*Live test leftovers*` lists the Codex trust entries, the Claude Code trust entries, and the Claude Code transcript folders that the tests left.
14. Stop the daemon: `emacsclient -s cci-live -e '(kill-emacs)'`.
15. Remove each listed item by hand, as [live-tests.md](live-tests.md), section "Clean up", tells.
16. In an Emacs that loaded `claude-code-ide-live-tests.el`, evaluate `M-: (claude-code-ide-live-tests-leftovers "<live folder>") RET`.
    - **Expected:** all three lists are empty.

## 10. Clean up

1. Quit Emacs.
2. Restore the init file: `mv ~/.emacs.d/init.el.before-cci-1.2.0 ~/.emacs.d/init.el`.
   - **Expected:** the init file no longer loads `~/Source/claude code ide space`.
3. Delete the test copy: `rm -rf ~/Source/'claude code ide space'`.
4. Restore the Codex configuration: `mv ~/.codex/config.toml.before-cci-1.2.0 ~/.codex/config.toml`.
   - **Expected:** the configuration of before the test is back.
   - If no source file existed, delete `~/.codex/config.toml` instead.
5. Restore the Claude Code configuration: `mv ~/.claude.json.before-cci-1.2.0 ~/.claude.json`.
   - If no source file existed, keep `~/.claude.json`: it holds the login. Remove only the `projects` entries of the test folders.
6. Restore the session registry: `mv ~/.emacs-claude-code-ide-state-v4.json.before-cci-1.2.0 ~/.emacs-claude-code-ide-state-v4.json`.
   - If no source file existed, delete the `-v4` file and its `.bak` file instead.
   - **If it fails:** save the paths of the registry and of the report directory.
7. If `~/.emacs-claude-code-ide-state-reports/` did not exist before the test, delete it.
   - It holds the hook scripts, the inbox, and the coordinator credential of the test.
8. Archive each test Codex conversation: `codex archive <id>` for each rollout whose `cwd` is a test project.
9. Delete the Claude Code transcript folders of the test projects under `~/.claude/projects/`.
   - **Expected:** no folder of a test project remains.
10. Delete the two test repositories, with their `.codex/config.toml` and `.handover/` folders: `rm -rf ~/Source/cci-laptop-plain ~/Source/'cci laptop space'`.
11. Run `ps -ax -o pid= -o command= | grep -E '[c]laude|[c]odex'`.
    - **Expected:** no process of a test project remains.
12. Make one fork issue for each `FAIL`.
    - Put in the versions, a short reproduction, the debug log, `*Messages*`, and `*Coding Agents Sessions*` when they apply.
13. Do not tag 1.2.0 while a `FAIL` is open.

## Report

Copy this table into `~/cci-1.2.0-results.txt`, and fill it in.

- `SKIP` is correct for the optional area 9.
- `SKIP` is also correct for the steps that need a real usage limit or an account without Codex (area 4, steps 28 to 34).

| Area | Result (PASS, FAIL, or SKIP) | Notes |
|---|---|---|
| 1. Preparation |  |  |
| 2. Install and update on a fresh machine |  |  |
| 3. The Codex CLI: detection, first start, and trust |  |  |
| 4. The status of both providers |  |  |
| 5. The handover |  |  |
| 6. The MCP tools server |  |  |
| 7. A stop of an instance in each terminal backend |  |  |
| 8. The reload of the package in a running Emacs |  |  |
| 9. The live tests (optional) |  |  |
| 10. Clean up |  |  |

