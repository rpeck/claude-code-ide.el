;;; claude-code-ide-codex-events-tests.el --- Tests for the Codex status events  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the Codex event adapter (claude-code-ide-codex-events.el)
;; and for the parts of the status view that serve both providers: the
;; Model and State columns, the status snapshot and the Claude Code
;; quota limit.  The event sequences are the hook records of a real
;; Codex 0.164.0 session, with synthetic instance IDs, conversation IDs
;; and paths.  claude-code-ide-tests.el loads this file.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'iso8601)
(require 'claude-code-ide)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-session-status)
(require 'claude-code-ide-codex-events)
(require 'claude-code-ide-session-registry-tests)

(declare-function claude-code-ide-tests--make-session "claude-code-ide-tests")
(declare-function claude-code-ide-tests--clear-processes "claude-code-ide-tests")

;;; Fixtures

(defconst claude-code-ide-codex-events-tests--t1-records
  '(
    (0 "SessionStart" "cci-test-inst-b" 1 "{\"session_id\":\"cci-test-0001-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0002-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"source\":\"startup\"}")
    (1 "UserPromptSubmit" "cci-test-inst-b" 1 "{\"session_id\":\"cci-test-0001-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb94-2ddc-7b71-8204-ff2f6967b4dd\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0002-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s1-tui1: reply with the single word ok\"}")
    (2 "PostModelRequest" "cci-test-inst-b" 1 "{\"session_id\":\"cci-test-0001-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb94-2ddc-7b71-8204-ff2f6967b4dd\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0002-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":18140,\"cached_input_tokens\":7936,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":18145}}")
    (3 "Stop" "cci-test-inst-b" 1 "{\"session_id\":\"cci-test-0001-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb94-2ddc-7b71-8204-ff2f6967b4dd\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0002-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"ok\"}")
    (4 "SessionEnd" "cci-test-inst-b" 1 "{\"session_id\":\"cci-test-0001-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0002-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}")
    (5 "SessionStart" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"source\":\"startup\"}")
    (6 "UserPromptSubmit" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb95-5d85-7672-9518-e79032da6716\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s1-tui2: reply with the single word ok\"}")
    (7 "PostModelRequest" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb95-5d85-7672-9518-e79032da6716\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":18140,\"cached_input_tokens\":6912,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":18145}}")
    (8 "Stop" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb95-5d85-7672-9518-e79032da6716\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"ok\"}")
    (9 "UserPromptSubmit" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb95-b04b-7ca0-904c-592342d3d5d4\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s1-tui2b: reply with the single word ok\"}")
    (10 "PostModelRequest" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb95-b04b-7ca0-904c-592342d3d5d4\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":18166,\"cached_input_tokens\":17152,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":18171}}")
    (11 "Stop" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb95-b04b-7ca0-904c-592342d3d5d4\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"ok\"}")
    (12 "UserPromptSubmit" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb95-fb02-7fc3-b0b8-34caa58b80ff\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s1-tui2c: reply with the single word ok\"}")
    (13 "PostModelRequest" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb95-fb02-7fc3-b0b8-34caa58b80ff\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":18192,\"cached_input_tokens\":17152,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":18197}}")
    (14 "Stop" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb95-fb02-7fc3-b0b8-34caa58b80ff\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"ok\"}")
    (15 "SessionEnd" "cci-test-inst-c" 7 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}")
    (16 "SessionStart" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"source\":\"startup\"}")
    (17 "UserPromptSubmit" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb96-9d2b-7fa3-86d6-577a3b9cd3b9\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s1-tui3: reply with the single word ok\"}")
    (18 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb96-9d2b-7fa3-86d6-577a3b9cd3b9\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":18140,\"cached_input_tokens\":7936,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":18145}}")
    (19 "Stop" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb96-9d2b-7fa3-86d6-577a3b9cd3b9\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"ok\"}")
    (20 "UserPromptSubmit" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-269c-7b10-a66e-d7522f2fc507\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s1-env: run the shell command: env | grep ^CCI_ . Then reply with its output only.\"}")
    (21 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-269c-7b10-a66e-d7522f2fc507\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":18176,\"cached_input_tokens\":17152,\"cache_write_input_tokens\":0,\"output_tokens\":159,\"reasoning_output_tokens\":36,\"total_tokens\":18335}}")
    (22 "PreToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-269c-7b10-a66e-d7522f2fc507\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PreToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"env | grep ^CCI_\"},\"tool_use_id\":\"exec-297dc55f-21a0-4a72-b907-b6785d19fb6b\"}")
    (23 "PostToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-269c-7b10-a66e-d7522f2fc507\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PostToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"env | grep ^CCI_\"},\"tool_response\":\"CCI_GENERATION=3\\nCCI_INSTANCE_ID=inst-D\\n\",\"tool_use_id\":\"exec-297dc55f-21a0-4a72-b907-b6785d19fb6b\"}")
    (24 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-269c-7b10-a66e-d7522f2fc507\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":18371,\"cached_input_tokens\":17152,\"cache_write_input_tokens\":0,\"output_tokens\":16,\"reasoning_output_tokens\":0,\"total_tokens\":18387}}")
    (25 "Stop" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-269c-7b10-a66e-d7522f2fc507\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"CCI_GENERATION=3\\nCCI_INSTANCE_ID=inst-D\"}")
    (26 "UserPromptSubmit" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-97f3-74f1-abdb-2dba5aafa347\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s1-nested-a: run exactly this shell command, outside the sandbox (it needs ~/.codex write access): /tmp/cci-test-t1/tmp/cx exec --skip-git-repo-check -s read-only 'cci-test-s1-nested-a-child: reply with the single word ok' </dev/nu\"}")
    (27 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-97f3-74f1-abdb-2dba5aafa347\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":18516,\"cached_input_tokens\":18176,\"cache_write_input_tokens\":0,\"output_tokens\":327,\"reasoning_output_tokens\":14,\"total_tokens\":18843}}")
    (28 "PreToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-97f3-74f1-abdb-2dba5aafa347\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PreToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"/tmp/cci-test-t1/tmp/cx exec --skip-git-repo-check -s read-only 'cci-test-s1-nested-a-child: reply with the single word ok' </dev/null\"},\"tool_use_id\":\"exec-3d31d240-9d6f-40fe-b3b6-a3bd37f82964\"}")
    (29 "PermissionRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-97f3-74f1-abdb-2dba5aafa347\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PermissionRequest\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"/tmp/cci-test-t1/tmp/cx exec --skip-git-repo-check -s read-only 'cci-test-s1-nested-a-child: reply with the single word ok' </dev/null\",\"description\":\"Do you want to allow the exact nested Codex command to run with access to write its state under ~/.codex?\"}}")
    (30 "SessionStart" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0007-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0008-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"bypassPermissions\",\"source\":\"startup\"}" t)
    (31 "UserPromptSubmit" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0007-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb98-27ae-78f3-beca-72bc3b997094\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0008-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"bypassPermissions\",\"prompt\":\"cci-test-s1-nested-a-child: reply with the single word ok\"}" t)
    (32 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0007-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb98-27ae-78f3-beca-72bc3b997094\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0008-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":17124,\"cached_input_tokens\":7936,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":17129}}" t)
    (33 "Stop" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0007-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb98-27ae-78f3-beca-72bc3b997094\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0008-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"bypassPermissions\",\"stop_hook_active\":false,\"last_assistant_message\":\"ok\"}" t)
    (34 "SessionEnd" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0007-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0008-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}" t)
    (35 "PostToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-97f3-74f1-abdb-2dba5aafa347\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PostToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"/tmp/cci-test-t1/tmp/cx exec --skip-git-repo-check -s read-only 'cci-test-s1-nested-a-child: reply with the single word ok' </dev/null\"},\"tool_response\":\"Reading additional input from stdin...\\nOpenAI Codex v0.164.0\\n--------\\nworkdir: /tmp/cci-test-t1/tmp/proj\\nmodel: gpt-5.6-terra\\nprovider: openai\\napproval: never\\nsandbox: read-only\\nreasoning effort: high\\nreasoning summaries: detailed\\nsession i\",\"tool_use_id\":\"exec-3d31d240-9d6f-40fe-b3b6-a3bd37f82964\"}")
    (36 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-97f3-74f1-abdb-2dba5aafa347\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":19276,\"cached_input_tokens\":18176,\"cache_write_input_tokens\":0,\"output_tokens\":87,\"reasoning_output_tokens\":78,\"total_tokens\":19363}}")
    (37 "Stop" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb97-97f3-74f1-abdb-2dba5aafa347\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"9,193\"}")
    (42 "SessionStart" "cci-test-inst-e" 1 "{\"session_id\":\"cci-test-0009-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0010-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionStart\",\"model\":\"cci-test-no-such-model\",\"permission_mode\":\"bypassPermissions\",\"source\":\"startup\"}")
    (43 "UserPromptSubmit" "cci-test-inst-e" 1 "{\"session_id\":\"cci-test-0009-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb99-57bf-74c0-9bbc-0fc67fa349ad\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0010-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"cci-test-no-such-model\",\"permission_mode\":\"bypassPermissions\",\"prompt\":\"cci-test-s6-failed-model: reply ok\"}")
    (44 "PostModelRequest" "cci-test-inst-e" 1 "{\"session_id\":\"cci-test-0009-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb99-57bf-74c0-9bbc-0fc67fa349ad\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0010-0000-4000-8000-000000000000.jsonl\",\"model\":\"cci-test-no-such-model\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"failed\",\"error\":\"{\\\"type\\\":\\\"error\\\",\\\"status\\\":400,\\\"error\\\":{\\\"type\\\":\\\"invalid_request_error\\\",\\\"message\\\":\\\"The 'cci-test-no-such-model' model is not supported when using Codex with a ChatGPT account.\\\",\\\"code\\\":\\\"model_not_found\\\"}}\",\"token_usage\":null}")
    (45 "SessionEnd" "cci-test-inst-e" 1 "{\"session_id\":\"cci-test-0009-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0010-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}")
    (46 "UserPromptSubmit" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb99-858b-72d2-b748-d61e3b3c1e7f\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s6-deny: run exactly this shell command outside the sandbox, ask for approval: touch /home/cci-test/cci-test-deny-marker . If it is denied, reply DENIED and stop.\"}")
    (47 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb99-858b-72d2-b748-d61e3b3c1e7f\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":19413,\"cached_input_tokens\":18176,\"cache_write_input_tokens\":0,\"output_tokens\":178,\"reasoning_output_tokens\":20,\"total_tokens\":19591}}")
    (48 "PreToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb99-858b-72d2-b748-d61e3b3c1e7f\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PreToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch /home/cci-test/cci-test-deny-marker\"},\"tool_use_id\":\"exec-309c403a-7dc9-427f-9124-81860d6ba635\"}")
    (49 "PermissionRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb99-858b-72d2-b748-d61e3b3c1e7f\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PermissionRequest\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch /home/cci-test/cci-test-deny-marker\",\"description\":\"Do you want to allow creation of the specified marker file outside the sandbox?\"}}")
    (50 "Interrupt" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb99-858b-72d2-b748-d61e3b3c1e7f\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Interrupt\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\"}")
    (51 "SessionStart" "cci-test-inst-f" 1 "{\"session_id\":\"cci-test-0011-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0012-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"source\":\"startup\"}")
    (52 "UserPromptSubmit" "cci-test-inst-f" 1 "{\"session_id\":\"cci-test-0011-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9a-b5a1-7961-aa07-21348dddfbf7\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0012-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s6-auto: run exactly this shell command outside the sandbox (it writes one marker file in the parent test folder): touch /tmp/cci-test-t1/tmp/auto-review-marker . Then reply done.\"}")
    (53 "PostModelRequest" "cci-test-inst-f" 1 "{\"session_id\":\"cci-test-0011-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9a-b5a1-7961-aa07-21348dddfbf7\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0012-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":18490,\"cached_input_tokens\":12032,\"cache_write_input_tokens\":0,\"output_tokens\":156,\"reasoning_output_tokens\":25,\"total_tokens\":18646}}")
    (54 "PreToolUse" "cci-test-inst-f" 1 "{\"session_id\":\"cci-test-0011-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9a-b5a1-7961-aa07-21348dddfbf7\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0012-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PreToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch /tmp/cci-test-t1/tmp/auto-review-marker\"},\"tool_use_id\":\"exec-cd68c017-79af-4684-b74d-c6def96f433d\"}")
    (55 "PermissionRequest" "cci-test-inst-f" 1 "{\"session_id\":\"cci-test-0011-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9a-b5a1-7961-aa07-21348dddfbf7\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0012-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PermissionRequest\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch /tmp/cci-test-t1/tmp/auto-review-marker\",\"description\":\"Do you want to allow creating the requested marker file outside the sandbox?\"}}")
    (56 "PostToolUse" "cci-test-inst-f" 1 "{\"session_id\":\"cci-test-0011-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9a-b5a1-7961-aa07-21348dddfbf7\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0012-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PostToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"touch /tmp/cci-test-t1/tmp/auto-review-marker\"},\"tool_response\":\"\",\"tool_use_id\":\"exec-cd68c017-79af-4684-b74d-c6def96f433d\"}")
    (57 "PostModelRequest" "cci-test-inst-f" 1 "{\"session_id\":\"cci-test-0011-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9a-b5a1-7961-aa07-21348dddfbf7\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0012-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":18669,\"cached_input_tokens\":18176,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":18674}}")
    (58 "Stop" "cci-test-inst-f" 1 "{\"session_id\":\"cci-test-0011-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9a-b5a1-7961-aa07-21348dddfbf7\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0012-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"done\"}")
    (59 "SessionEnd" "cci-test-inst-f" 1 "{\"session_id\":\"cci-test-0011-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0012-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}")
    (60 "UserPromptSubmit" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9b-0be3-7ea2-ae8d-0dce0d7a4835\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s6-question: ask me one short question: which color do I prefer, red or blue? Then stop. Do not run tools.\"}")
    (61 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9b-0be3-7ea2-ae8d-0dce0d7a4835\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":19839,\"cached_input_tokens\":19200,\"cache_write_input_tokens\":0,\"output_tokens\":30,\"reasoning_output_tokens\":14,\"total_tokens\":19869}}")
    (62 "Stop" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9b-0be3-7ea2-ae8d-0dce0d7a4835\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"Which color do you prefer: red or blue?\"}")
    (63 "UserPromptSubmit" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9b-ec8a-7402-8c06-f8f4271310fa\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s6-userinput: use your structured question tool (request_user_input) to ask me one multiple-choice question: red or blue. Do nothing else.\"}")
    (64 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9b-ec8a-7402-8c06-f8f4271310fa\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":21709,\"cached_input_tokens\":7936,\"cache_write_input_tokens\":0,\"output_tokens\":78,\"reasoning_output_tokens\":13,\"total_tokens\":21787}}")
    (65 "PreToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9b-ec8a-7402-8c06-f8f4271310fa\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PreToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"request_user_input\",\"tool_input\":{\"questions\":[{\"id\":\"color\",\"header\":\"Color\",\"question\":\"Which color do you prefer?\",\"options\":[{\"label\":\"Red (Recommended)\",\"description\":\"Choose red.\"},{\"label\":\"Blue\",\"description\":\"Choose blue.\"}]}]},\"tool_use_id\":\"call_d4c465fe86294a878ea45cc845fd71a7\"}")
    (66 "PostToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9b-ec8a-7402-8c06-f8f4271310fa\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PostToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"request_user_input\",\"tool_input\":{\"questions\":[{\"id\":\"color\",\"header\":\"Color\",\"question\":\"Which color do you prefer?\",\"options\":[{\"label\":\"Red (Recommended)\",\"description\":\"Choose red.\"},{\"label\":\"Blue\",\"description\":\"Choose blue.\"}]}]},\"tool_response\":\"{\\\"answers\\\":{\\\"color\\\":{\\\"answers\\\":[\\\"Blue\\\"]}}}\",\"tool_use_id\":\"call_d4c465fe86294a878ea45cc845fd71a7\"}")
    (67 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9b-ec8a-7402-8c06-f8f4271310fa\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":21810,\"cached_input_tokens\":21248,\"cache_write_input_tokens\":0,\"output_tokens\":58,\"reasoning_output_tokens\":52,\"total_tokens\":21868}}")
    (68 "Stop" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9b-ec8a-7402-8c06-f8f4271310fa\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":null}")
    (69 "UserPromptSubmit" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9d-1061-71e3-8c42-246cd760eacb\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s6-interrupt: run the shell command: sleep 60 . Then reply done.\"}")
    (70 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9d-1061-71e3-8c42-246cd760eacb\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":22003,\"cached_input_tokens\":19200,\"cache_write_input_tokens\":0,\"output_tokens\":202,\"reasoning_output_tokens\":78,\"total_tokens\":22205}}")
    (71 "PreToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9d-1061-71e3-8c42-246cd760eacb\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PreToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sleep 60\"},\"tool_use_id\":\"exec-2d7af759-5149-4f18-9f5f-6f84453d89e4\"}")
    (72 "Interrupt" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9d-1061-71e3-8c42-246cd760eacb\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Interrupt\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\"}")
    (73 "SessionStart" "cci-test-inst-c" 8 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"bypassPermissions\",\"source\":\"resume\"}")
    (74 "UserPromptSubmit" "cci-test-inst-c" 8 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-6c31-7110-8bd6-f189156f2cb9\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"bypassPermissions\",\"prompt\":\"cci-test-s6-resume: reply with the single word ok\"}")
    (75 "PostModelRequest" "cci-test-inst-c" 8 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-6c31-7110-8bd6-f189156f2cb9\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":27029,\"cached_input_tokens\":17152,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":27034}}")
    (76 "Stop" "cci-test-inst-c" 8 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-6c31-7110-8bd6-f189156f2cb9\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"bypassPermissions\",\"stop_hook_active\":false,\"last_assistant_message\":\"ok\"}")
    (77 "SessionEnd" "cci-test-inst-c" 8 "{\"session_id\":\"cci-test-0003-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0004-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}")
    (78 "UserPromptSubmit" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-b4a8-76b2-8a5b-16ea464cd672\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s6-subagent: spawn exactly one subagent with your agent-spawn tool. Tell it: reply with the single word ok. Wait for it, then reply done. If you have no such tool, reply NOTOOL.\"}")
    (79 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-b4a8-76b2-8a5b-16ea464cd672\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":22326,\"cached_input_tokens\":21248,\"cache_write_input_tokens\":0,\"output_tokens\":80,\"reasoning_output_tokens\":21,\"total_tokens\":22406}}")
    (80 "PreToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-b4a8-76b2-8a5b-16ea464cd672\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PreToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"collaborationspawn_agent\",\"tool_input\":{\"task_name\":\"confirmation\",\"fork_turns\":\"all\",\"message\":\"cci-test-encrypted\"},\"tool_use_id\":\"call_0a431c29d1544dbd9bb2c29f42454cd9\"}")
    (81 "PostToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-b4a8-76b2-8a5b-16ea464cd672\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PostToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"collaborationspawn_agent\",\"tool_input\":{\"task_name\":\"confirmation\",\"fork_turns\":\"all\",\"message\":\"cci-test-encrypted\"},\"tool_response\":\"{\\\"task_name\\\":\\\"/root/confirmation\\\"}\",\"tool_use_id\":\"call_0a431c29d1544dbd9bb2c29f42454cd9\"}")
    (82 "SubagentStart" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-c202-7240-86b8-578a06ba0539\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0013-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SubagentStart\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"agent_id\":\"cci-test-0014-0000-4000-8000-000000000000\",\"agent_type\":\"default\"}")
    (83 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-b4a8-76b2-8a5b-16ea464cd672\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":22427,\"cached_input_tokens\":21248,\"cache_write_input_tokens\":0,\"output_tokens\":21,\"reasoning_output_tokens\":0,\"total_tokens\":22448}}")
    (84 "PreToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-b4a8-76b2-8a5b-16ea464cd672\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PreToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"collaborationwait_agent\",\"tool_input\":{\"timeout_ms\":60000},\"tool_use_id\":\"call_c491f28570bc42dc8a8e6a28857c1145\"}")
    (85 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-c202-7240-86b8-578a06ba0539\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0013-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"agent_id\":\"cci-test-0014-0000-4000-8000-000000000000\",\"agent_type\":\"default\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":29582,\"cached_input_tokens\":22272,\"cache_write_input_tokens\":0,\"output_tokens\":23,\"reasoning_output_tokens\":16,\"total_tokens\":29605}}")
    (86 "SubagentStop" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-c202-7240-86b8-578a06ba0539\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"agent_transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0013-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SubagentStop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"agent_id\":\"cci-test-0014-0000-4000-8000-000000000000\",\"agent_type\":\"default\",\"last_assistant_message\":\"ok\"}")
    (87 "PostToolUse" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-b4a8-76b2-8a5b-16ea464cd672\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"PostToolUse\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"tool_name\":\"collaborationwait_agent\",\"tool_input\":{\"timeout_ms\":60000},\"tool_response\":\"{\\\"message\\\":\\\"Wait completed.\\\",\\\"timed_out\\\":false}\",\"tool_use_id\":\"call_c491f28570bc42dc8a8e6a28857c1145\"}")
    (88 "PostModelRequest" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-b4a8-76b2-8a5b-16ea464cd672\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":22508,\"cached_input_tokens\":21248,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":22513}}")
    (89 "Stop" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eb9e-b4a8-76b2-8a5b-16ea464cd672\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"done\"}")
    (90 "SessionEnd" "cci-test-inst-d" 3 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}")
    (91 "SessionStart" "cci-test-inst-d" 4 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"source\":\"resume\"}")
    (92 "UserPromptSubmit" "cci-test-inst-d" 4 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eba0-7aa4-7dc2-a7a1-0f516d4c67cc\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"UserPromptSubmit\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"prompt\":\"cci-test-s6-resume-tui: reply with the single word ok\"}")
    (93 "PostModelRequest" "cci-test-inst-d" 4 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eba0-7aa4-7dc2-a7a1-0f516d4c67cc\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"model\":\"gpt-5.6-terra\",\"hook_event_name\":\"PostModelRequest\",\"status\":\"completed\",\"error\":null,\"token_usage\":{\"input_tokens\":22534,\"cached_input_tokens\":22272,\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0,\"total_tokens\":22539}}")
    (94 "Stop" "cci-test-inst-d" 4 "{\"session_id\":\"cci-test-0005-0000-4000-8000-000000000000\",\"turn_id\":\"01a1eba0-7aa4-7dc2-a7a1-0f516d4c67cc\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0006-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"Stop\",\"model\":\"gpt-5.6-terra\",\"permission_mode\":\"default\",\"stop_hook_active\":false,\"last_assistant_message\":\"ok\"}")
    (95 "SessionEnd" "cci-test-inst-g" 1 "{\"session_id\":\"cci-test-0015-0000-4000-8000-000000000000\",\"transcript_path\":\"/tmp/cci-test-codex/rollout-cci-test-0016-0000-4000-8000-000000000000.jsonl\",\"cwd\":\"/tmp/cci-test-t1/tmp/proj\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}")
    )
  "Codex hook records of test T1: (INDEX EVENT INSTANCE GENERATION JSON NESTED).
NESTED is t for a record of a nested `codex exec' that inherited the
variables of its parent.  The instance IDs, conversation IDs and paths
are synthetic.")

(defconst claude-code-ide-codex-events-tests--real-trust-check
  (symbol-function 'claude-code-ide-codex-events--start-trust-check)
  "The real trust check.
`claude-code-ide-codex-events-tests--with-codex' replaces it.")

(defmacro claude-code-ide-codex-events-tests--with-codex (&rest body)
  "Run BODY with no instances, no Codex launches and a temporary report folder.
Timers and file watches are not started, and the trust check does not
run a program.  BODY can refer to the folder as `registry-dir'."
  (declare (indent 0))
  `(claude-code-ide-tests--with-registry
     (let ((claude-code-ide-instance--all nil)
           (claude-code-ide-instance--generations (make-hash-table :test 'equal))
           (claude-code-ide-codex-events--launches (make-hash-table :test 'equal))
           (claude-code-ide-codex-events--trust-cache nil)
           (claude-code-ide-codex-events--trust-check nil)
           (claude-code-ide-session-status--by-nonce (make-hash-table :test 'equal))
           (claude-code-ide-session-status--by-session (make-hash-table :test 'eq :weakness 'key))
           (claude-code-ide-session-status--snapshot-timer nil)
           (claude-code-ide-session-status--snapshot-last nil)
           (claude-code-ide-session-status-tracking t))
       (cl-letf (((symbol-function 'claude-code-ide-codex-events--ensure-timers) #'ignore)
                 ((symbol-function 'claude-code-ide-session-status--ensure-timers) #'ignore)
                 ((symbol-function 'claude-code-ide-codex-events--start-trust-check) #'ignore))
         ,@body))))

(defun claude-code-ide-codex-events-tests--instance (id generation &optional buffer)
  "Register a running Codex instance ID at GENERATION, with BUFFER or a new one."
  (let ((buffer (or buffer (generate-new-buffer (format "*cci-test-codex-%s*" id)))))
    (when-let* ((old (claude-code-ide-instance-by-id id)))
      (claude-code-ide-instance-unregister id))
    (claude-code-ide-instance-register
     (claude-code-ide-instance-create :id id :provider 'codex :generation generation
                                      :buffer buffer :project-root "/tmp/cci-test-codex-proj/"
                                      :display-name "cci-test-codex-proj"))))

(defun claude-code-ide-codex-events-tests--kill-instances ()
  "Kill the buffers of the registered instances."
  (dolist (instance (claude-code-ide-instances))
    (let ((buffer (claude-code-ide-instance-buffer instance))
          (kill-buffer-hook nil))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun claude-code-ide-codex-events-tests--state (instance &optional now)
  "Return (STATE REASON GUESS) of INSTANCE at NOW (default 1000)."
  (let ((state (claude-code-ide-instance-state instance (or now 1000.0))))
    (list (plist-get state :state) (plist-get state :reason) (plist-get state :guess))))

(defun claude-code-ide-codex-events-tests--feed (id generation events &optional start)
  "Pass EVENTS, each (EVENT JSON), to the launch ID GENERATION.
The times count from START (default 900) in steps of one second.
Return the list of the results of `claude-code-ide-codex-events--handle'."
  (let ((now (or start 900.0)))
    (mapcar (lambda (event)
              (claude-code-ide-codex-events--handle
               id generation (car event)
               (json-parse-string (cadr event) :object-type 'alist :array-type 'list
                                  :null-object nil :false-object nil)
               (cl-incf now)))
            events)))

(defun claude-code-ide-codex-events-tests--fake-server (dir hooks-file &optional refuse-write)
  "Write a fake `codex' program in DIR and return its file.
It answers initialize, answers hooks/list with the content of
HOOKS-FILE, and logs each config/batchWrite request to DIR/writes.log
and then answers hooks/list from HOOKS-FILE.trusted.  With
REFUSE-WRITE, config/batchWrite gets a method error."
  (let ((file (expand-file-name "codex" dir)))
    (with-temp-file file
      (insert "#!/bin/sh\n"
              "[ \"$1\" = app-server ] || exit 2\n"
              "list=" (shell-quote-argument hooks-file) "\n"
              "while IFS= read -r line; do\n"
              "  id=$(printf '%s' \"$line\" | sed -n 's/.*\"id\":\\([0-9]*\\).*/\\1/p')\n"
              "  case $line in\n"
              "    *'\"initialize\"'*) printf '{\"id\":%s,\"result\":{\"userAgent\":\"cci-test\"}}\\n' \"$id\" ;;\n"
              "    *'\"hooks/list\"'*) printf '{\"id\":%s,\"result\":%s}\\n' \"$id\" \"$(cat \"$list\")\" ;;\n"
              "    *'\"config/batchWrite\"'*)\n"
              "      printf '%s\\n' \"$line\" >> " (shell-quote-argument (expand-file-name "writes.log" dir)) "\n"
              (if refuse-write
                  "      printf '{\"id\":%s,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}\\n' \"$id\" ;;\n"
                "      list=\"$list.trusted\"; printf '{\"id\":%s,\"result\":{\"status\":\"ok\"}}\\n' \"$id\" ;;\n")
              "  esac\n"
              "done\n"))
    (set-file-modes file #o700)
    file))

(defun claude-code-ide-codex-events-tests--hooks-json (trust &optional enabled)
  "Return a `hooks/list' result with the status hooks, each with TRUST.
ENABLED `disabled' disables the first status hook.  A hook of another
source is listed too, and must not count."
  (let ((other '((key . "/home/x/.codex/hooks.json:pre_tool_use:0:0")
                 (eventName . "preToolUse") (source . "user")
                 (command . "dcg") (trustStatus . "untrusted")
                 (currentHash . "sha256:other") (enabled . t)))
        (ours (cl-loop
               for event in claude-code-ide-codex-events--events
               for index from 0
               collect (list (cons 'key (format "/<session-flags>/config.toml:%s:0:0"
                                                (downcase event)))
                             (cons 'eventName event)
                             (cons 'source "sessionFlags")
                             (cons 'sourcePath "/<session-flags>/config.toml")
                             (cons 'command (claude-code-ide-codex-events--command event))
                             (cons 'trustStatus trust)
                             (cons 'currentHash (format "sha256:hash%d" index))
                             (cons 'enabled (if (and (eq enabled 'disabled) (= index 0))
                                                :json-false
                                              t))))))
    (json-encode
     (list (cons 'data
                 (vector (list (cons 'cwd "/tmp")
                               (cons 'errors [])
                               (cons 'warnings [])
                               (cons 'hooks (vconcat (cons other ours))))))))))

;;; Hook script

(ert-deftest claude-code-ide-codex-events-test-script-install ()
  "The hook script is written atomically into a private folder and checked."
  (claude-code-ide-codex-events-tests--with-codex
    (let* ((file (claude-code-ide-codex-events--install-script))
           (dir (file-name-directory file)))
      (should (equal file (claude-code-ide-codex-events--script-file)))
      (should (= (file-modes dir) #o700))
      (should (zerop (logand (file-modes file) #o022)))
      (should (equal (claude-code-ide-session-registry--file-string file)
                     claude-code-ide-codex-events--script))
      ;; No temporary file stays
      (should (equal (directory-files dir nil "\\`[^.]") (list (file-name-nondirectory file))))
      ;; A changed script is replaced at the next launch
      (with-temp-file file (insert "#!/bin/sh\necho changed\n"))
      (claude-code-ide-codex-events--install-script)
      (should (equal (claude-code-ide-session-registry--file-string file)
                     claude-code-ide-codex-events--script))
      ;; A folder that others can use gets the private mode again
      (set-file-modes dir #o755)
      (claude-code-ide-codex-events--install-script)
      (should (= (file-modes dir) #o700))
      ;; A script that others can write is replaced
      (set-file-modes file #o777)
      (should-not (claude-code-ide-codex-events--script-ok-p file))
      (claude-code-ide-codex-events--install-script)
      (should (claude-code-ide-codex-events--script-ok-p file)))))

(defun claude-code-ide-codex-events-tests--run-script (dir env &optional input)
  "Run the hook script for Stop with the environment ENV and INPUT.
ENV is a list of \"NAME=VALUE\" or \"NAME\" (removed) entries.  Return
the seconds that it ran and the event files in DIR."
  (let ((process-environment (append env
                                     '("CCI_INSTANCE_ID" "CCI_GENERATION" "CCI_EVENTS_DIR"
                                       "CODEX_THREAD_ID")
                                     process-environment))
        (start (float-time)))
    (with-temp-buffer
      (insert (or input "{\"session_id\":\"cci-test-s\",\"hook_event_name\":\"Stop\"}"))
      (should (zerop (call-process-region (point-min) (point-max) "sh" nil nil nil
                                          (claude-code-ide-codex-events--script-file)
                                          "Stop"))))
    (list (- (float-time) start)
          (directory-files dir nil claude-code-ide-codex-events--file-regexp))))

(ert-deftest claude-code-ide-codex-events-test-script-exits-without-identity ()
  "The script records nothing without CCI_INSTANCE_ID or with CODEX_THREAD_ID."
  (claude-code-ide-codex-events-tests--with-codex
    (claude-code-ide-codex-events--install-script)
    (let* ((dir (claude-code-ide-codex-events--private-directory
                 (claude-code-ide-codex-events--events-directory)))
           (events-dir (concat "CCI_EVENTS_DIR=" dir)))
      ;; No instance ID: it exits at once and writes nothing
      (pcase-let ((`(,seconds ,files)
                   (claude-code-ide-codex-events-tests--run-script
                    dir (list events-dir "CCI_GENERATION=1"))))
        (should (< seconds 2))
        (should-not files))
      ;; A nested Codex session: the same
      (pcase-let ((`(,seconds ,files)
                   (claude-code-ide-codex-events-tests--run-script
                    dir (list events-dir "CCI_INSTANCE_ID=cci-test-a" "CCI_GENERATION=1"
                              "CODEX_THREAD_ID=cci-test-parent"))))
        (should (< seconds 2))
        (should-not files))
      ;; Values that do not fit a file name
      (should-not (cadr (claude-code-ide-codex-events-tests--run-script
                         dir (list events-dir "CCI_INSTANCE_ID=../x" "CCI_GENERATION=1"))))
      (should-not (cadr (claude-code-ide-codex-events-tests--run-script
                         dir (list events-dir "CCI_INSTANCE_ID=cci-test-a" "CCI_GENERATION=1x"))))
      (should-not (directory-files dir nil "\\`[^.]"))
      ;; With the identity it writes one record, which Emacs reads
      (pcase-let ((`(,_seconds ,files)
                   (claude-code-ide-codex-events-tests--run-script
                    dir (list events-dir "CCI_INSTANCE_ID=cci-test-a" "CCI_GENERATION=12"))))
        (should (equal files '("cci-test-a.12.00000001.Stop.json")))
        (let ((record (claude-code-ide-codex-events--read-file (expand-file-name (car files) dir))))
          (should (equal (alist-get 'event record) "Stop"))
          (should (equal (alist-get 'instance_id record) "cci-test-a"))
          (should (equal (alist-get 'generation record) "12"))
          (should (equal (alist-get 'session_id (alist-get 'input record)) "cci-test-s"))))
      ;; The next event of the launch gets the next number
      (should (member "cci-test-a.12.00000002.Stop.json"
                      (cadr (claude-code-ide-codex-events-tests--run-script
                             dir (list events-dir "CCI_INSTANCE_ID=cci-test-a"
                                       "CCI_GENERATION=12"))))))))

;;; Hook arguments

(ert-deftest claude-code-ide-codex-events-test-hook-args-and-env ()
  "The hook arguments are fixed and in order; the environment has the identity."
  (claude-code-ide-codex-events-tests--with-codex
    (let* ((a (claude-code-ide-codex-events-tests--instance "cci-test-args-a" 1))
           (b (claude-code-ide-codex-events-tests--instance "cci-test-args-b" 7))
           (args (claude-code-ide-codex-status-hook-args a)))
      (unwind-protect
          (progn
            (should (= (length args) (* 2 (length claude-code-ide-codex-events--events))))
            ;; "-c" then one definition per event, in the fixed order
            (cl-loop for (flag value) on args by #'cddr
                     for event in claude-code-ide-codex-events--events
                     do (should (equal flag "-c"))
                     do (should (string-prefix-p (format "hooks.%s=[{hooks=[{type=\"command\",command=\"sh " event)
                                                 value))
                     do (should (string-suffix-p (format " %s\",timeout=5}]}]" event) value)))
            ;; The same for each instance and each call: one trust covers all
            (should (equal args (claude-code-ide-codex-status-hook-args b)))
            (should (equal args (claude-code-ide-codex-status-hook-args a)))
            (should-not (string-match-p "cci-test-args" (string-join args " ")))
            (should (equal (claude-code-ide-codex-status-hook-env b)
                           (list "CCI_INSTANCE_ID=cci-test-args-b" "CCI_GENERATION=7"
                                 (concat "CCI_EVENTS_DIR="
                                         (directory-file-name
                                          (claude-code-ide-codex-events--events-directory))))))
            ;; Each call tracks the current launch once
            (should (= 2 (hash-table-count claude-code-ide-codex-events--launches)))
            (should (eq (claude-code-ide-codex-events--launch-of a)
                        (gethash "cci-test-args-a" claude-code-ide-codex-events--launches)))
            ;; Without status tracking there are no hooks
            (let ((claude-code-ide-session-status-tracking nil))
              (should-not (claude-code-ide-codex-status-hook-args a))
              (should-not (claude-code-ide-codex-status-hook-env a))))
        (claude-code-ide-codex-events-tests--kill-instances)))))

(ert-deftest claude-code-ide-codex-events-test-hook-args-survive-errors ()
  "A failure to install the script gives no hooks, and no error for the launch."
  (claude-code-ide-codex-events-tests--with-codex
    (let ((a (claude-code-ide-codex-events-tests--instance "cci-test-fail" 1)))
      (unwind-protect
          (cl-letf (((symbol-function 'claude-code-ide-codex-events--install-script)
                     (lambda () (error "cci-test disk full")))
                    ((symbol-function 'message) #'ignore))
            (should-not (claude-code-ide-codex-status-hook-args a))
            (should-not (claude-code-ide-codex-status-hook-env a)))
        (claude-code-ide-codex-events-tests--kill-instances)))))

(ert-deftest claude-code-ide-codex-events-test-map-event ()
  "Codex events map to the common events."
  (should (eq (claude-code-ide-codex-events-map-event "SessionStart" nil) 'session-start))
  (should (eq (claude-code-ide-codex-events-map-event "Interrupt" nil) 'interrupt))
  (should (eq (claude-code-ide-codex-events-map-event "PermissionRequest" nil) 'approval-request))
  (should (eq (claude-code-ide-codex-events-map-event "PostModelRequest" '((status . "failed")))
              'turn-failed))
  (should (eq (claude-code-ide-codex-events-map-event "PostModelRequest" '((status . "completed")))
              'other))
  (should (eq (claude-code-ide-codex-events-map-event "PreCompact" nil) 'other))
  (dolist (event claude-code-ide-codex-events--events)
    (should (memq (claude-code-ide-codex-events-map-event event nil) claude-code-ide-event-names))))

;;; Replay of the T1 records

(defconst claude-code-ide-codex-events-tests--t1-expected
  '((0 idle nil nil) (1 working nil nil) (2 working nil nil) (3 idle nil nil)
    (4 disconnected nil nil)
    (8 idle nil nil) (15 disconnected nil nil)
    (22 working nil nil) (23 working nil nil) (25 idle nil nil)
    ;; Approval, a nested session during it, the allow, the end
    (28 working nil nil) (29 waiting-for-user approval nil)
    (30 waiting-for-user approval nil) (34 waiting-for-user approval nil)
    (35 working nil nil) (37 idle nil nil)
    ;; A failed model request: no Stop follows
    (43 working nil nil) (44 failed error nil) (45 disconnected nil nil)
    ;; Approval, then a denial: only Interrupt
    (49 waiting-for-user approval nil) (50 idle nil nil)
    ;; An automatic review gives the same events as an allow
    (55 waiting-for-user approval nil) (56 working nil nil) (58 idle nil nil)
    ;; A question in the reply is a guess; a structured question is not
    (62 waiting-for-user question t)
    (65 waiting-for-user question nil) (66 working nil nil) (68 idle nil nil)
    ;; Esc during a tool
    (71 working nil nil) (72 idle nil nil)
    ;; A resume: a new generation
    (73 idle nil nil) (76 idle nil nil) (77 disconnected nil nil)
    ;; A subagent
    (81 working nil nil) (82 waiting-for-task subagent nil) (85 waiting-for-task subagent nil)
    (86 working nil nil) (89 idle nil nil) (90 disconnected nil nil)
    (91 idle nil nil) (94 idle nil nil)
    ;; A terminal UI that got no prompt sends only SessionEnd
    (95 disconnected nil nil))
  "State (STATE REASON GUESS) of the instance of each T1 record after it.")

(ert-deftest claude-code-ide-codex-events-test-replay-t1 ()
  "The real Codex records of T1 give the states that the terminal showed.
Each instance and generation is launched when its first record comes.
The records of a nested session, which has another conversation ID,
change nothing."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let ((now 1000.0)
              (applied 0)
              (dropped nil))
          (dolist (record claude-code-ide-codex-events-tests--t1-records)
            (pcase-let ((`(,index ,event ,id ,generation ,json ,nested) record))
              (let ((instance (claude-code-ide-instance-by-id id)))
                (unless (and instance (= (claude-code-ide-instance-generation instance) generation))
                  (setq instance (claude-code-ide-codex-events-tests--instance id generation))
                  (claude-code-ide-codex-events--track instance))
                (let ((result (claude-code-ide-codex-events--handle
                               id generation event
                               (json-parse-string json :object-type 'alist :array-type 'list
                                                  :null-object nil :false-object nil)
                               (cl-incf now))))
                  (if result
                      (progn
                        (cl-incf applied)
                        (should (equal (plist-get result :provider-event) event))
                        (should (memq (plist-get result :event) claude-code-ide-event-names))
                        (should-not nested))
                    (push index dropped)))
                (when-let* ((expected (alist-get index claude-code-ide-codex-events-tests--t1-expected)))
                  (should (equal (list index (claude-code-ide-codex-events-tests--state instance (+ now 1)))
                                 (list index expected)))))))
          ;; Only the five records of the nested session are dropped
          (should (equal (sort dropped #'<) '(30 31 32 33 34)))
          (should (= applied (- (length claude-code-ide-codex-events-tests--t1-records) 5)))
          ;; The events tell the model and the conversation ID
          (let ((instance (claude-code-ide-instance-by-id "cci-test-inst-d")))
            (should (equal (claude-code-ide-instance-model instance) "gpt-5.6-terra"))
            (should (string-prefix-p "cci-test-" (claude-code-ide-instance-native-id instance)))))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-old-event-after-resume ()
  "An event of the launch before a resume does not change the status.
The drain reads it from its file, deletes it, applies nothing and
dispatches nothing (acceptance check 4)."
  (claude-code-ide-codex-events-tests--with-codex
    (let ((dispatched nil)
          (claude-code-ide-event-functions nil))
      (add-hook 'claude-code-ide-event-functions (lambda (event) (push event dispatched)))
      (unwind-protect
          (let* ((old (claude-code-ide-codex-events-tests--instance "cci-test-resume" 3))
                 (dir nil))
            (claude-code-ide-codex-status-hook-args old)
            (setq dir (claude-code-ide-codex-events--events-directory))
            (claude-code-ide-codex-events-tests--feed
             "cci-test-resume" 3 '(("SessionStart" "{\"session_id\":\"cci-test-s3\"}")
                                   ("UserPromptSubmit" "{\"session_id\":\"cci-test-s3\"}")))
            ;; The resume: generation 4 of the same instance
            (let ((new (claude-code-ide-codex-events-tests--instance
                        "cci-test-resume" 4 (claude-code-ide-instance-buffer old))))
              (claude-code-ide-codex-status-hook-args new)
              (claude-code-ide-codex-events-tests--feed
               "cci-test-resume" 4 '(("SessionStart" "{\"session_id\":\"cci-test-s3\",\"source\":\"resume\"}")))
              (should (equal (claude-code-ide-codex-events-tests--state new) '(idle nil nil)))
              (setq dispatched nil)
              ;; A late PermissionRequest of generation 3 arrives as a file
              (with-temp-file (expand-file-name "cci-test-resume.3.00000003.PermissionRequest.json" dir)
                (insert "{\"event\":\"PermissionRequest\",\"instance_id\":\"cci-test-resume\","
                        "\"generation\":\"3\",\"input\":{\"session_id\":\"cci-test-s3\","
                        "\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}}\n"))
              (claude-code-ide-codex-events--drain)
              (should (equal (claude-code-ide-codex-events-tests--state new) '(idle nil nil)))
              (should-not dispatched)
              (should-not (directory-files dir nil claude-code-ide-codex-events--file-regexp))
              ;; The same event of generation 4 counts
              (with-temp-file (expand-file-name "cci-test-resume.4.00000001.UserPromptSubmit.json" dir)
                (insert "{\"event\":\"UserPromptSubmit\",\"instance_id\":\"cci-test-resume\","
                        "\"generation\":\"4\",\"input\":{\"session_id\":\"cci-test-s3\"}}\n"))
              (claude-code-ide-codex-events--drain)
              (should (equal (claude-code-ide-codex-events-tests--state new) '(working nil nil)))
              (should (equal (mapcar (lambda (event) (plist-get event :event)) dispatched)
                             '(prompt-submit)))
              (should (= (plist-get (car dispatched) :generation) 4))
              ;; A file whose content names another launch than its name is dropped
              (with-temp-file (expand-file-name "cci-test-resume.4.00000002.Stop.json" dir)
                (insert "{\"event\":\"Stop\",\"instance_id\":\"cci-test-resume\","
                        "\"generation\":\"3\",\"input\":{\"session_id\":\"cci-test-s3\"}}\n"))
              (claude-code-ide-codex-events--drain)
              (should (equal (claude-code-ide-codex-events-tests--state new) '(working nil nil)))))
        (claude-code-ide-codex-events-tests--kill-instances)))))

;;; States

(ert-deftest claude-code-ide-codex-events-test-quota-limit ()
  "A failed model request is failed/error, or failed/quota-limit for a usage limit."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let ((instance (claude-code-ide-codex-events-tests--instance "cci-test-quota" 1)))
          (claude-code-ide-codex-events--track instance)
          (claude-code-ide-codex-events-tests--feed
           "cci-test-quota" 1
           '(("UserPromptSubmit" "{}")
             ("PostModelRequest" "{\"status\":\"failed\",\"error\":\"{\\\"error\\\":{\\\"code\\\":\\\"usage_limit_exceeded\\\",\\\"message\\\":\\\"You've hit your usage limit.\\\"}}\"}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(failed quota-limit nil)))
          (should (string-prefix-p "Quota limit: "
                                   (claude-code-ide-codex-events--instance-detail instance 1000.0)))
          ;; The next prompt ends the failure
          (claude-code-ide-codex-events-tests--feed "cci-test-quota" 1 '(("UserPromptSubmit" "{}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(working nil nil)))
          ;; A subagent's failed request does not fail the main turn
          (claude-code-ide-codex-events-tests--feed
           "cci-test-quota" 1 '(("PostModelRequest" "{\"agent_id\":\"cci-test-agent\",\"status\":\"failed\",\"error\":\"usage limit\"}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(working nil nil)))
          ;; Another error is no quota limit
          (claude-code-ide-codex-events-tests--feed
           "cci-test-quota" 1 '(("PostModelRequest" "{\"status\":\"failed\",\"error\":\"model_not_found\"}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(failed error nil)))
          (should-not (claude-code-ide-codex-events--quota-error-p nil))
          (should (claude-code-ide-codex-events--quota-error-p "Rate limit reached for requests"))
          (should-not (claude-code-ide-codex-events--quota-error-p "rate limited, retry")))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-approval-guess ()
  "Without a screen read, a pending approval becomes a guess after 10 seconds."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let ((instance (claude-code-ide-codex-events-tests--instance "cci-test-approve" 1)))
          (claude-code-ide-codex-events--track instance)
          (claude-code-ide-codex-events-tests--feed
           "cci-test-approve" 1
           '(("UserPromptSubmit" "{}")
             ("PreToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"make\"}}")
             ("PermissionRequest" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make\"}}"))
           100.0)
          (should (equal (claude-code-ide-codex-events-tests--state instance 105.0)
                         '(waiting-for-user approval nil)))
          (should (equal (claude-code-ide-codex-events--instance-detail instance 105.0) "Bash: make"))
          (should (equal (claude-code-ide-codex-events-tests--state instance 120.0)
                         '(waiting-for-user approval t)))
          ;; The PostToolUse of the same tool ends it
          (claude-code-ide-codex-events-tests--feed
           "cci-test-approve" 1
           '(("PostToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"make\"}}"))
           120.0)
          (should (equal (claude-code-ide-codex-events-tests--state instance 122.0) '(working nil nil))))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-screen-dialogs ()
  "The screen read sets the startup dialog and confirms or ends an approval."
  (claude-code-ide-codex-events-tests--with-codex
    (let ((screen 'folder-trust)
          (reads 0))
      (cl-letf (((symbol-function 'claude-code-ide-codex-screen-dialog)
                 (lambda (buffer)
                   (should (bufferp buffer))
                   (cl-incf reads)
                   screen)))
        (unwind-protect
            (let* ((instance (claude-code-ide-codex-events-tests--instance "cci-test-dialog" 1))
                   (launch (claude-code-ide-codex-events--track instance))
                   (start (claude-code-ide-codex-events--launch-registered launch)))
              ;; Within the grace time: starting, and no read
              (should-not (claude-code-ide-codex-events--read-screen launch instance (+ start 1)))
              (should (= reads 0))
              (should (equal (claude-code-ide-codex-events-tests--state instance (+ start 1))
                             '(working nil t)))
              ;; A startup dialog before any event
              (should (claude-code-ide-codex-events--read-screen launch instance (+ start 4)))
              (should (equal (claude-code-ide-codex-events-tests--state instance (+ start 4))
                             '(waiting-for-user dialog nil)))
              (should (string-match-p "trust this folder"
                                      (claude-code-ide-codex-events--instance-detail instance (+ start 4))))
              ;; The dialog is answered: the composer waits for the first prompt
              (setq screen nil)
              (should (claude-code-ide-codex-events--read-screen launch instance (+ start 6)))
              (should (equal (claude-code-ide-codex-events-tests--state instance (+ start 6))
                             '(idle nil t)))
              ;; After the first event the screen is not read while working
              (claude-code-ide-codex-events-tests--feed
               "cci-test-dialog" 1
               '(("SessionStart" "{}") ("UserPromptSubmit" "{}")
                 ("PreToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"rm x\"}}")
                 ("PermissionRequest" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm x\"}}"))
               (+ start 10))
              (setq reads 0)
              ;; Too soon after the request: Codex draws the dialog after the event
              (should-not (claude-code-ide-codex-events--read-screen launch instance (+ start 14.5)))
              (should (= reads 0))
              ;; The dialog shows: the approval is sure, also after 10 seconds
              (setq screen 'approval)
              (claude-code-ide-codex-events--read-screen launch instance (+ start 16))
              (should (equal (claude-code-ide-codex-events-tests--state instance (+ start 40))
                             '(waiting-for-user approval nil)))
              ;; The dialog is gone without an event: approved, the command runs
              (setq screen nil)
              (should (claude-code-ide-codex-events--read-screen launch instance (+ start 41)))
              (should (equal (claude-code-ide-codex-events-tests--state instance (+ start 42))
                             '(working nil t)))
              ;; The PostToolUse ends the approval
              (claude-code-ide-codex-events-tests--feed
               "cci-test-dialog" 1
               '(("PostToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"rm x\"}}"))
               (+ start 50))
              (should (equal (claude-code-ide-codex-events-tests--state instance (+ start 52))
                             '(working nil nil)))
              (setq reads 0)
              (should-not (claude-code-ide-codex-events--read-screen launch instance (+ start 60)))
              (should (= reads 0)))
          (claude-code-ide-codex-events-tests--kill-instances))))))

(ert-deftest claude-code-ide-codex-events-test-subagent-approval ()
  "A subagent's approval waits for the user; its other events leave the main turn."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let ((instance (claude-code-ide-codex-events-tests--instance "cci-test-sub" 1)))
          (claude-code-ide-codex-events--track instance)
          (claude-code-ide-codex-events-tests--feed
           "cci-test-sub" 1
           '(("UserPromptSubmit" "{}")
             ("SubagentStart" "{\"agent_id\":\"a1\",\"agent_type\":\"default\"}")
             ("PreToolUse" "{\"agent_id\":\"a1\",\"tool_name\":\"Bash\",\"tool_use_id\":\"s1\",\"tool_input\":{\"command\":\"ls\"}}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(waiting-for-task subagent nil)))
          (claude-code-ide-codex-events-tests--feed
           "cci-test-sub" 1
           '(("PermissionRequest" "{\"agent_id\":\"a1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance 910.0) '(waiting-for-user approval nil)))
          ;; The end of the subagent ends its dialog
          (claude-code-ide-codex-events-tests--feed
           "cci-test-sub" 1 '(("SubagentStop" "{\"agent_id\":\"a1\",\"agent_type\":\"default\"}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(working nil nil))))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-no-launch-record ()
  "A Codex instance without status hooks, or of another launch, is disconnected."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let ((instance (claude-code-ide-codex-events-tests--instance "cci-test-bare" 2)))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(disconnected nil nil)))
          (should (equal (claude-code-ide-codex-events--instance-detail instance 1.0) "No status hooks"))
          ;; Events of an instance that is not tracked are not applied
          (should-not (car (claude-code-ide-codex-events-tests--feed "cci-test-bare" 2 '(("Stop" "{}")))))
          ;; A Claude Code instance is not for this adapter
          (should-not (claude-code-ide-codex-events--instance-state
                       (claude-code-ide-instance-create :id "cci-test-cc" :provider 'claude) 1.0)))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-prune ()
  "The launch of an instance that ended is forgotten, with its files."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let* ((instance (claude-code-ide-codex-events-tests--instance "cci-test-gone" 1))
               (launch (claude-code-ide-codex-events--track instance))
               (file (expand-file-name "cci-test-gone.1.00000001.Stop.json"
                                       (claude-code-ide-codex-events--events-directory))))
          (should launch)
          (with-temp-file file (insert "{}"))
          (claude-code-ide-instance-unregister "cci-test-gone")
          (should (claude-code-ide-codex-events--prune))
          (should-not (gethash "cci-test-gone" claude-code-ide-codex-events--launches))
          (should-not (file-exists-p file)))
      (claude-code-ide-codex-events-tests--kill-instances))))

;;; Hook trust

(ert-deftest claude-code-ide-codex-events-test-trust-result ()
  "Only the status hooks of the session flags count, enabled and trusted."
  (claude-code-ide-codex-events-tests--with-codex
    (let ((parse (lambda (json)
                   (claude-code-ide-codex-events--trust-result
                    (list :result (json-parse-string json :object-type 'alist :array-type 'list
                                                     :null-object nil :false-object :false))))))
      (should (eq (plist-get (funcall parse (claude-code-ide-codex-events-tests--hooks-json "trusted"))
                             :status)
                  'trusted))
      (let ((result (funcall parse (claude-code-ide-codex-events-tests--hooks-json "untrusted"))))
        (should (eq (plist-get result :status) 'untrusted))
        (should (= (length (plist-get result :hooks)) (length claude-code-ide-codex-events--events)))
        (should (string-match-p "not trusted: M-x claude-code-ide-codex-trust-hooks"
                                (plist-get result :message))))
      (let ((result (funcall parse (claude-code-ide-codex-events-tests--hooks-json "trusted" 'disabled))))
        (should (eq (plist-get result :status) 'untrusted))
        (should (= (length (plist-get result :hooks)) 1)))
      (should (eq (plist-get (funcall parse (claude-code-ide-codex-events-tests--hooks-json "modified"))
                             :status)
                  'untrusted))
      (should (eq (plist-get (funcall parse "{\"data\":[]}") :status) 'error))
      (should (eq (plist-get (claude-code-ide-codex-events--trust-result '(:error "cci-test")) :status)
                  'error)))))

(defmacro claude-code-ide-codex-events-tests--with-fake-codex (spec &rest body)
  "Run BODY with a fake Codex app-server.
SPEC is (DIR TRUST &optional REFUSE-WRITE): DIR is bound to the
folder of the fake, which lists the hooks with TRUST at first and as
trusted after a write."
  (declare (indent 1))
  (let ((dir (nth 0 spec)) (trust (nth 1 spec)) (refuse (nth 2 spec)))
    `(let* ((,dir (make-temp-file "cci-test-codex-" t))
            (hooks-file (expand-file-name "hooks.json" ,dir)))
       (unwind-protect
           (progn
             (claude-code-ide-codex-events--install-script)
             (with-temp-file hooks-file
               (insert (claude-code-ide-codex-events-tests--hooks-json ,trust)))
             (with-temp-file (concat hooks-file ".trusted")
               (insert (claude-code-ide-codex-events-tests--hooks-json "trusted")))
             (let ((claude-code-ide-codex-events-program
                    (claude-code-ide-codex-events-tests--fake-server ,dir hooks-file ,refuse))
                   (claude-code-ide-codex-events-trust-timeout 5))
               ,@body))
         (delete-directory ,dir t)))))

(ert-deftest claude-code-ide-codex-events-test-trust-check-at-launch ()
  "The launch check runs hooks/list in the background and shows untrusted hooks."
  (claude-code-ide-codex-events-tests--with-codex
    (claude-code-ide-codex-events-tests--with-fake-codex (dir "untrusted")
      (ignore dir)
      (cl-letf (((symbol-function 'claude-code-ide-codex-events--start-trust-check)
                 claude-code-ide-codex-events-tests--real-trust-check))
        (unwind-protect
            (let* ((instance (claude-code-ide-codex-events-tests--instance "cci-test-trust" 1))
                   (args (claude-code-ide-codex-status-hook-args instance))
                   (launch (claude-code-ide-codex-events--launch-of instance))
                   (deadline (+ (float-time) 5)))
              ;; The launch does not wait for the check
              (should args)
              (should (eq (claude-code-ide-codex-events--launch-trust launch) 'checking))
              (while (and (eq (claude-code-ide-codex-events--launch-trust launch) 'checking)
                          (< (float-time) deadline))
                (accept-process-output nil 0.05))
              (should (eq (claude-code-ide-codex-events--launch-trust launch) 'untrusted))
              (should-not claude-code-ide-codex-events--trust-check)
              ;; No event comes from untrusted hooks: disconnected, with the reason
              (let ((now (+ (claude-code-ide-codex-events--launch-registered launch) 30)))
                (should (equal (claude-code-ide-codex-events-tests--state instance now)
                               '(disconnected nil nil)))
                (should (string-match-p "status hooks not trusted"
                                        (claude-code-ide-codex-events--instance-detail instance now)))))
          (claude-code-ide-codex-events-tests--kill-instances))))))

(ert-deftest claude-code-ide-codex-events-test-trust-check-without-codex ()
  "Without a Codex program the trust is unknown and the launch still gets hooks."
  (claude-code-ide-codex-events-tests--with-codex
    (cl-letf (((symbol-function 'claude-code-ide-codex-events--start-trust-check)
               claude-code-ide-codex-events-tests--real-trust-check))
      (unwind-protect
          (let* ((claude-code-ide-codex-events-program "/nonexistent/cci-test-codex")
                 (instance (claude-code-ide-codex-events-tests--instance "cci-test-nocodex" 1)))
            (should (claude-code-ide-codex-status-hook-args instance))
            (let ((launch (claude-code-ide-codex-events--launch-of instance)))
              (should (eq (claude-code-ide-codex-events--launch-trust launch) 'error))
              (should (string-match-p "Hook trust unknown"
                                      (claude-code-ide-codex-events--launch-trust-detail launch)))
              ;; An unknown trust is no reason for disconnected; the detail tells it
              (let ((now (+ (claude-code-ide-codex-events--launch-registered launch) 30)))
                (should (equal (claude-code-ide-codex-events-tests--state instance now)
                               '(working nil t)))
                (should (string-match-p "Starting: no event yet · Hook trust unknown"
                                        (claude-code-ide-codex-events--instance-detail instance now))))))
        (claude-code-ide-codex-events-tests--kill-instances)))))

(ert-deftest claude-code-ide-codex-events-test-trust-command ()
  "The trust command shows the hooks, asks, and writes the trust through the app-server."
  (claude-code-ide-codex-events-tests--with-codex
    (claude-code-ide-codex-events-tests--with-fake-codex (dir "untrusted")
      (let ((asked nil))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (setq asked prompt) t))
                  ((symbol-function 'display-buffer) #'ignore))
          (claude-code-ide-codex-trust-hooks))
        (should (string-match-p (format "Trust these %d hook commands"
                                        (length claude-code-ide-codex-events--events))
                                asked))
        ;; The buffer shows each command
        (with-current-buffer "*Codex status hooks*"
          (should (string-search (claude-code-ide-codex-events--command "Stop") (buffer-string))))
        (kill-buffer "*Codex status hooks*")
        ;; One batch write: each edit merges the key and its hash into hooks.state
        (let* ((lines (split-string (with-temp-buffer
                                      (insert-file-contents (expand-file-name "writes.log" dir))
                                      (buffer-string))
                                    "\n" t))
               (request (json-parse-string (car lines) :object-type 'alist :array-type 'list))
               (edits (alist-get 'edits (alist-get 'params request))))
          (should (= (length lines) 1))
          (should (= (length edits) (length claude-code-ide-codex-events--events)))
          (dolist (edit edits)
            (should (equal (alist-get 'keyPath edit) "hooks.state"))
            (should (equal (alist-get 'mergeStrategy edit) "upsert")))
          (should (equal (alist-get 'value (car edits))
                         (list (cons (intern "/<session-flags>/config.toml:sessionstart:0:0")
                                     '((trusted_hash . "sha256:hash0")))))))
        ;; The check after the write is cached as trusted
        (should (eq (plist-get (cdr claude-code-ide-codex-events--trust-cache) :status) 'trusted))))))

(ert-deftest claude-code-ide-codex-events-test-trust-command-declined-and-refused ()
  "A no writes nothing; a refused write tells the user to run /hooks."
  (claude-code-ide-codex-events-tests--with-codex
    (claude-code-ide-codex-events-tests--with-fake-codex (dir "untrusted")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) nil))
                ((symbol-function 'display-buffer) #'ignore))
        (claude-code-ide-codex-trust-hooks))
      (should-not (file-exists-p (expand-file-name "writes.log" dir)))))
  (claude-code-ide-codex-events-tests--with-codex
    (claude-code-ide-codex-events-tests--with-fake-codex (dir "untrusted" t)
      (ignore dir)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) t))
                ((symbol-function 'display-buffer) #'ignore))
        (let ((err (should-error (claude-code-ide-codex-trust-hooks) :type 'user-error)))
          (should (string-match-p "run /hooks" (cadr err)))))))
  (claude-code-ide-codex-events-tests--with-codex
    (claude-code-ide-codex-events-tests--with-fake-codex (dir "trusted")
      (ignore dir)
      (let ((messages nil))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) (error "No question expected")))
                  ((symbol-function 'message)
                   (lambda (format &rest args) (push (apply #'format format args) messages))))
          (claude-code-ide-codex-trust-hooks))
        (should (string-match-p "are trusted" (car messages)))))))

;;; Status view

(ert-deftest claude-code-ide-codex-events-test-status-buffer-rows ()
  "A Codex instance has a row with its provider, model, state and detail.
A model that is not known shows unknown (acceptance check 9)."
  (claude-code-ide-codex-events-tests--with-codex
    (claude-code-ide-tests--clear-processes)
    (unwind-protect
        (let* ((instance (claude-code-ide-codex-events-tests--instance "cci-test-row" 1))
               (cc-buffer (generate-new-buffer "*cci-test-cc-row*"))
               (cc-session (claude-code-ide-tests--make-session "/tmp/cci-test-cc-row/" :buffer cc-buffer)))
          (claude-code-ide-instance-register
           (claude-code-ide-instance-create :id "cci-test-cc-row" :provider 'claude
                                            :session cc-session :buffer cc-buffer))
          (claude-code-ide-codex-events--track instance)
          (claude-code-ide-codex-events-tests--feed
           "cci-test-row" 1
           '(("UserPromptSubmit" "{}")
             ("PreToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"make\"}}")
             ("PermissionRequest" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make\"}}"))
           (- (float-time) 3))
          (let* ((now (float-time))
                 (rows (claude-code-ide-session-status--rows now))
                 (entries (claude-code-ide-session-status--entries rows now))
                 (codex-row (assq instance rows))
                 (codex-entry (cadr (assq instance entries)))
                 (cc-entry (cadr (assq cc-session entries))))
            (should codex-row)
            (should (eq (nth 1 codex-row) 'waiting))
            ;; The waiting Codex instance comes first
            (should (eq (car (car rows)) instance))
            (should (= (length codex-entry) 7))
            (should (string-match-p "NEEDS ANSWER" (aref codex-entry 0)))
            (should (string-match-p "cci-test-codex-proj" (aref codex-entry 1)))
            (should (equal (aref codex-entry 2) "codex"))
            (should (equal (aref codex-entry 3) "unknown"))
            (should (equal (aref codex-entry 4) "waiting-for-user/approval"))
            (should (equal (aref codex-entry 6) "Bash: make"))
            ;; A Claude Code session without a known model shows unknown too
            (should (equal (aref cc-entry 2) "claude"))
            (should (equal (aref cc-entry 3) "unknown"))
            (should (equal (aref cc-entry 4) "disconnected"))
            ;; The model of the events shows when it is known
            (claude-code-ide-codex-events-tests--feed
             "cci-test-row" 1 '(("PostToolUse" "{\"model\":\"gpt-5.6-terra\",\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"make\"}}")))
            (let ((entry (cadr (assq instance (claude-code-ide-session-status--entries
                                               (claude-code-ide-session-status--rows) (float-time))))))
              (should (equal (aref entry 3) "gpt-5.6-terra"))
              (should (equal (aref entry 4) "working"))))
          (with-temp-buffer
            (claude-code-ide-session-status-list-mode)
            (should (equal (mapcar #'car (append tabulated-list-format nil))
                           '("Status" "Session" "Provider" "Model" "State" "For" "Detail"))))
          (kill-buffer cc-buffer))
      (claude-code-ide-codex-events-tests--kill-instances)
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-codex-events-test-format-state ()
  "The State column shows the state, its reason, and a mark for a guess."
  (should (equal (claude-code-ide-session-status--format-state
                  (claude-code-ide-instance-make-state 'waiting-for-user 'question nil t))
                 "waiting-for-user/question?"))
  (should (equal (claude-code-ide-session-status--format-state
                  (claude-code-ide-instance-make-state 'idle))
                 "idle"))
  (should (equal (claude-code-ide-session-status--format-state nil) "unknown"))
  (dolist (state '((waiting-for-user approval nil waiting) (waiting-for-user question t asks)
                   (failed quota-limit nil quota) (failed exit-code nil error)
                   (waiting-for-task subagent nil tasks) (disconnected nil nil disconnected)
                   (idle nil nil idle) (working nil nil working)))
    (should (eq (claude-code-ide-session-status--common-label-key
                 (claude-code-ide-instance-make-state (nth 0 state) (nth 1 state) nil (nth 2 state)))
                (nth 3 state)))))

(ert-deftest claude-code-ide-codex-events-test-claude-quota-limit ()
  "A Claude Code StopFailure with the error rate_limit is failed/quota-limit."
  (let ((status (claude-code-ide-session-status-create :nonce "abc" :since 0.0 :registered 0.0
                                                       :last-event 0.0)))
    (claude-code-ide-session-status--apply status "UserPromptSubmit" nil 1.0)
    (claude-code-ide-session-status--apply
     status "StopFailure"
     '((error . "rate_limit") (error_details . "You've hit your limit · resets 5pm")) 2.0)
    (should (eq (claude-code-ide-session-status--state status 3.0) 'quota))
    (should (equal (claude-code-ide-session-status--detail status 'quota 3.0)
                   "Quota limit: You've hit your limit · resets 5pm"))
    (let ((common (claude-code-ide-session-status--common-state status 3.0)))
      (should (eq (plist-get common :state) 'failed))
      (should (eq (plist-get common :reason) 'quota-limit)))
    (should (claude-code-ide-session-status--urgent-p 'quota))
    ;; Another error stays failed/error
    (claude-code-ide-session-status--apply status "UserPromptSubmit" nil 4.0)
    (claude-code-ide-session-status--apply status "StopFailure" '((error . "server_error")) 5.0)
    (should (eq (claude-code-ide-session-status--state status 6.0) 'error))
    (should (eq (plist-get (claude-code-ide-session-status--common-state status 6.0) :reason) 'error))))

;;; Status snapshot

(defun claude-code-ide-codex-events-tests--read-snapshot ()
  "Return the status snapshot of this Emacs as an alist."
  (json-parse-string (claude-code-ide-session-registry--file-string
                      (claude-code-ide-session-status--snapshot-file))
                     :object-type 'alist :array-type 'list :null-object nil :false-object :false))

(ert-deftest claude-code-ide-codex-events-test-snapshot ()
  "The snapshot has the schema, the freshness fields and one record per instance."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let* ((instance (claude-code-ide-codex-events-tests--instance "cci-test-snap" 2))
               (file (claude-code-ide-session-status--snapshot-file))
               (now (float-time)))
          (should (string-prefix-p (expand-file-name registry-dir) file))
          (should (string-suffix-p (format "/status/%d.json" (emacs-pid)) file))
          (claude-code-ide-codex-events--track instance)
          (claude-code-ide-codex-events-tests--feed
           "cci-test-snap" 2 '(("SessionStart" "{\"session_id\":\"cci-test-native\"}")
                               ("UserPromptSubmit" "{}"))
           (- now 5))
          (should (claude-code-ide-session-status--write-snapshot nil now))
          (let* ((data (claude-code-ide-codex-events-tests--read-snapshot))
                 (record (car (alist-get 'instances data))))
            (should (equal (alist-get 'schema data) "claude-code-ide-status/v1"))
            (should (= (alist-get 'producer_pid data) (emacs-pid)))
            (should (= (alist-get 'stale_after_seconds data) 30))
            (should (= (alist-get 'interval_seconds data) 10))
            (let ((generated (float-time (encode-time (iso8601-parse (alist-get 'generated_at data))))))
              (should (< (abs (- generated now)) 1.0)))
            (should (= (length (alist-get 'instances data)) 1))
            (should (equal (alist-get 'instance_id record) "cci-test-snap"))
            (should (equal (alist-get 'provider record) "codex"))
            (should (equal (alist-get 'native_id record) "cci-test-native"))
            (should (equal (alist-get 'model record) "unknown"))
            (should (equal (alist-get 'worktree record) "unknown"))
            (should (null (alist-get 'role record)))
            (should (= (alist-get 'generation record) 2))
            (should (equal (alist-get 'state record) "working"))
            (should (null (alist-get 'reason record)))
            (should (eq (alist-get 'guess record) :false))
            (should (= (alist-get 'age_seconds record) 3))
            (should (equal (alist-get 'detail record) "Working")))
          ;; No change within the interval: no write
          (should-not (claude-code-ide-session-status--write-snapshot nil (+ now 3)))
          ;; A change: a write at once
          (claude-code-ide-codex-events-tests--feed "cci-test-snap" 2 '(("Stop" "{\"last_assistant_message\":\"done\"}"))
                                                    (+ now 3))
          (should (claude-code-ide-session-status--write-snapshot nil (+ now 5)))
          (should (equal (alist-get 'state (car (alist-get 'instances (claude-code-ide-codex-events-tests--read-snapshot))))
                         "idle"))
          ;; No change, but the interval passed: a write
          (should (claude-code-ide-session-status--write-snapshot nil (+ now 15)))
          ;; Only the snapshot file is in its folder: no temporary file stays
          (should (equal (directory-files (file-name-directory file) nil "\\`[^.]")
                         (list (file-name-nondirectory file))))
          (should-not (directory-files (file-name-directory file) nil "\\`\\.[^.]"))
          (should (= (file-modes (file-name-directory file)) #o700))
          ;; Without instances and modes, the tick stops and removes the file
          (setq claude-code-ide-session-status--snapshot-timer (run-with-timer 1000 nil #'ignore))
          (claude-code-ide-codex-events-tests--kill-instances)
          (claude-code-ide-instance-unregister "cci-test-snap")
          (let ((claude-code-ide-session-status-mode nil)
                (claude-code-ide-session-registry-mode nil))
            (claude-code-ide-session-status--snapshot-tick))
          (should-not claude-code-ide-session-status--snapshot-timer)
          (should-not (file-exists-p file)))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-snapshot-atomic ()
  "The snapshot is written to a temporary file in its folder, then renamed."
  (claude-code-ide-codex-events-tests--with-codex
    (let* ((file (claude-code-ide-session-status--snapshot-file))
           (renames nil)
           (rename (symbol-function 'rename-file)))
      (cl-letf (((symbol-function 'rename-file)
                 (lambda (from to &optional ok)
                   ;; The new content is whole before the rename
                   (push (list from to (claude-code-ide-session-registry--file-string from)
                               (file-exists-p to))
                         renames)
                   (funcall rename from to ok))))
        (should (claude-code-ide-session-status--write-snapshot t))
        (should (claude-code-ide-session-status--write-snapshot t)))
      (should (= (length renames) 2))
      (pcase-let ((`(,from ,to ,text ,existed) (car renames)))
        (should (equal to file))
        (should (equal (file-name-directory from) (file-name-directory file)))
        (should (json-parse-string text))
        (should existed))
      ;; A failed write leaves the old file and gives a message
      (let ((messages nil))
        (cl-letf (((symbol-function 'write-region) (lambda (&rest _) (error "cci-test disk full")))
                  ((symbol-function 'message)
                   (lambda (format &rest args) (push (apply #'format format args) messages))))
          (should-not (claude-code-ide-session-status--write-snapshot t)))
        (should (string-match-p "snapshot could not be written" (car messages)))
        (should (json-parse-string (claude-code-ide-session-registry--file-string file)))))))

(provide 'claude-code-ide-codex-events-tests)

;; Local Variables:
;; no-update-autoloads: t
;; autoload-compute-prefixes: nil
;; End:

;;; claude-code-ide-codex-events-tests.el ends here
