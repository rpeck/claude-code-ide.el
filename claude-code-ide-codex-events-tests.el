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
(require 'claude-code-ide-codex)
(require 'claude-code-ide-session-registry-tests)

(defvar claude-code-ide-codex--rollout-cache)

(declare-function claude-code-ide-tests--make-session "claude-code-ide-tests")
(declare-function claude-code-ide-tests--clear-processes "claude-code-ide-tests")
(declare-function claude-code-ide-tests--wait-until "claude-code-ide-tests")
(declare-function claude-code-ide-tests--call-with-clock "claude-code-ide-tests")
(declare-function claude-code-ide-tests--advance-clock "claude-code-ide-tests")
(defvar claude-code-ide-tests--wait-limit)

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

(defun claude-code-ide-codex-events-tests--trust-pairs ()
  "Return the (STATE-KEY . HASH) of the status hooks of the fake app-server."
  (cl-loop for event in claude-code-ide-codex-events--events
           for index from 0
           collect (cons (format "/<session-flags>/config.toml:%s:0:0" (downcase event))
                         (format "sha256:hash%d" index))))

(defun claude-code-ide-codex-events-tests--trust-toml (&optional pairs)
  "Return the config.toml records that trust PAIRS (default: all status hooks)."
  (mapconcat (lambda (pair)
               (format "[hooks.state.\"%s\"]\ntrusted_hash = \"%s\"\n\n" (car pair) (cdr pair)))
             (or pairs (claude-code-ide-codex-events-tests--trust-pairs))
             ""))

(defun claude-code-ide-codex-events-tests--trusted-result (&optional pairs)
  "Return a trusted result of `hooks/list' with the trust records PAIRS."
  (list :status 'trusted :message nil
        :trust (or pairs (claude-code-ide-codex-events-tests--trust-pairs))
        :cache 'records))

(defun claude-code-ide-codex-events-tests--write-config (text)
  "Write TEXT as the config.toml of the test CODEX_HOME."
  (let ((file (claude-code-ide-transcript--codex-config-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))))

(defmacro claude-code-ide-codex-events-tests--with-codex (&rest body)
  "Run BODY with no instances, no Codex launches and a temporary report folder.
Timers and file watches are not started, and the trust check does not
run a program.  CODEX_HOME is a folder in the report folder, so nothing
reads or writes the real ~/.codex.  The cache says that the current
hook definitions are trusted; tests of the trust clear it.  BODY can
refer to the report folder as `registry-dir'."
  (declare (indent 0))
  `(claude-code-ide-tests--with-registry
     (let ((process-environment (cons (concat "CODEX_HOME=" (expand-file-name "codex-home" registry-dir))
                                      process-environment))
           (claude-code-ide-instance--all nil)
           (claude-code-ide-instance--generations (make-hash-table :test 'equal))
           (claude-code-ide-codex-events--launches (make-hash-table :test 'equal))
           (claude-code-ide-codex-events--trust-cache (make-hash-table :test 'equal))
           (claude-code-ide-codex-events--checks (make-hash-table :test 'equal))
           (claude-code-ide-codex-events--declined nil)
           (claude-code-ide-session-status--by-nonce (make-hash-table :test 'equal))
           (claude-code-ide-session-status--by-session (make-hash-table :test 'eq :weakness 'key))
           (claude-code-ide-session-status--snapshot-timer nil)
           (claude-code-ide-session-status--snapshot-last nil)
           (claude-code-ide-session-status-tracking t))
       (cl-letf (((symbol-function 'claude-code-ide-codex-events--ensure-timers) #'ignore)
                 ((symbol-function 'claude-code-ide-session-status--ensure-timers) #'ignore)
                 ((symbol-function 'claude-code-ide-codex-events--start-trust-check) #'ignore))
         (claude-code-ide-codex-events-tests--write-config
          (concat "[tui]\nscreen_reader_detection_done = true\n\n"
                  (claude-code-ide-codex-events-tests--trust-toml)))
         (claude-code-ide-codex-events--remember-trust
          (claude-code-ide-codex-events--trust-key)
          (claude-code-ide-codex-events-tests--trusted-result))
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
              "  printf '%s\\n' \"$line\" >> " (shell-quote-argument (expand-file-name "requests.log" dir)) "\n"
              "  id=$(printf '%s' \"$line\" | sed -n 's/.*\"id\":\\([0-9]*\\).*/\\1/p')\n"
              "  case $line in\n"
              "    *'\"initialize\"'*) printf '{\"id\":%s,\"result\":{\"userAgent\":\"cci-test\"}}\\n' \"$id\" ;;\n"
              "    *'\"hooks/list\"'*) printf '{\"id\":%s,\"result\":%s}\\n' \"$id\" \"$(cat \"$list\")\" ;;\n"
              "    *'\"config/batchWrite\"'*)\n"
              "      printf '%s\\n' \"$line\" >> " (shell-quote-argument (expand-file-name "writes.log" dir)) "\n"
              (if refuse-write
                  "      printf '{\"id\":%s,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}\\n' \"$id\" ;;\n"
                (concat "      cat " (shell-quote-argument (expand-file-name "trusted.toml" dir))
                        " >> \"$CODEX_HOME/config.toml\"\n"
                        "      list=\"$list.trusted\"; printf '{\"id\":%s,\"result\":{\"status\":\"ok\"}}\\n' \"$id\" ;;\n"))
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
                     (claude-code-ide-codex-events--script-text)))
      ;; No temporary file stays
      (should (equal (directory-files dir nil "\\`[^.]") (list (file-name-nondirectory file))))
      ;; A changed script is replaced at the next launch
      (with-temp-file file (insert "#!/bin/sh\necho changed\n"))
      (claude-code-ide-codex-events--install-script)
      (should (equal (claude-code-ide-session-registry--file-string file)
                     (claude-code-ide-codex-events--script-text)))
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
\(WENT-ON FILES): WENT-ON is non-nil when the script went on after its
checks, to the temporary file of the record, and FILES are the event
files in DIR.  A `mktemp' first in PATH notes its calls; so the result
does not depend on the speed of the machine, as a time would."
  (let* ((bin (make-temp-file "cci-test-bin-" t))
         (mark (expand-file-name "mktemp-called" bin))
         (process-environment (append env
                                      (list (concat "PATH=" bin ":" (getenv "PATH")))
                                      '("CCI_INSTANCE_ID" "CCI_GENERATION" "CCI_EVENTS_DIR"
                                        "CODEX_THREAD_ID")
                                      process-environment)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "mktemp" bin)
            (insert "#!/bin/sh\n"
                    "echo x >> " (shell-quote-argument mark) "\n"
                    "exec " (shell-quote-argument (executable-find "mktemp")) " \"$@\"\n"))
          (set-file-modes (expand-file-name "mktemp" bin) #o700)
          (with-temp-buffer
            (insert (or input "{\"session_id\":\"cci-test-s\",\"hook_event_name\":\"Stop\"}"))
            (should (zerop (call-process-region (point-min) (point-max) "sh" nil nil nil
                                                (claude-code-ide-codex-events--script-file)
                                                "Stop"))))
          (list (file-exists-p mark)
                (directory-files dir nil claude-code-ide-codex-events--file-regexp)))
      (delete-directory bin t))))

(declare-function claude-code-ide-tests--script-lock-budget "claude-code-ide-session-status-tests")

(ert-deftest claude-code-ide-codex-events-test-script-lock-budget ()
  "The time limit of the Codex hook script gives 20 parallel writers enough time."
  (claude-code-ide-tests--script-lock-budget (claude-code-ide-codex-events--script-text)))

(ert-deftest claude-code-ide-codex-events-test-script-exits-without-identity ()
  "The script records nothing without CCI_INSTANCE_ID or with CODEX_THREAD_ID."
  (claude-code-ide-codex-events-tests--with-codex
    (claude-code-ide-codex-events--install-script)
    (let* ((dir (claude-code-ide-codex-events--private-directory
                 (claude-code-ide-codex-events--events-directory)))
           (events-dir (concat "CCI_EVENTS_DIR=" dir)))
      ;; No instance ID: it exits at once and writes nothing
      (pcase-let ((`(,went-on ,files)
                   (claude-code-ide-codex-events-tests--run-script
                    dir (list events-dir "CCI_GENERATION=1"))))
        (should-not went-on)
        (should-not files))
      ;; A nested Codex session: the same
      (pcase-let ((`(,went-on ,files)
                   (claude-code-ide-codex-events-tests--run-script
                    dir (list events-dir "CCI_INSTANCE_ID=cci-test-a" "CCI_GENERATION=1"
                              "CODEX_THREAD_ID=cci-test-parent"))))
        (should-not went-on)
        (should-not files))
      ;; Values that do not fit a file name
      (should-not (cadr (claude-code-ide-codex-events-tests--run-script
                         dir (list events-dir "CCI_INSTANCE_ID=../x" "CCI_GENERATION=1"))))
      (should-not (cadr (claude-code-ide-codex-events-tests--run-script
                         dir (list events-dir "CCI_INSTANCE_ID=cci-test-a" "CCI_GENERATION=1x"))))
      (should-not (directory-files dir nil "\\`[^.]"))
      ;; With the identity it writes one record, which Emacs reads
      (pcase-let ((`(,went-on ,files)
                   (claude-code-ide-codex-events-tests--run-script
                    dir (list events-dir "CCI_INSTANCE_ID=cci-test-a" "CCI_GENERATION=12"))))
        (should went-on)
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
                     do (should (string-suffix-p (format " %s\",timeout=%d}]}]" event
                                                         (claude-code-ide-session-status--hook-cli-timeout)) value)))
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
              (unless (and nested (equal event "SessionStart"))
                ;; The script drops the SessionStart of the nested session, as
                ;; it has CODEX_THREAD_ID; the adapter would take it for /new
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
                  ;; Each approval belongs to its tool, though the request
                  ;; input has a description that the tool input lacks
                  (when (equal event "PermissionRequest")
                    (let* ((launch (claude-code-ide-codex-events--launch-of instance))
                           (blocker (car (last (claude-code-ide-codex-events--launch-blockers launch)))))
                      (should (string-prefix-p
                               "exec-" (cdr (claude-code-ide-codex-events--blocker-tool blocker))))))
                  (when-let* ((expected (alist-get index claude-code-ide-codex-events-tests--t1-expected)))
                    (should (equal (list index (claude-code-ide-codex-events-tests--state instance (+ now 1)))
                                   (list index expected))))))))
          ;; The other records of the nested session have an unknown conversation ID
          (should (equal (sort dropped #'<) '(31 32 33 34)))
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
          (should (claude-code-ide-codex-events--quota-error-p "You've hit your usage limit"))
          (should (claude-code-ide-codex-events--quota-error-p "{\"code\":\"insufficient_quota\"}"))
          ;; A per-minute limit ends in seconds: no quota limit
          (should-not (claude-code-ide-codex-events--quota-error-p
                       "Rate limit reached for gpt-5.6-terra in organization org-cci on tokens per min (TPM): Limit 30000, Used 29500. Please try again in 1.2s."))
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
  "The screen read sets the startup dialog and confirms or ends an approval.
A window shows the terminal, so a read without a dialog ends the wait."
  (claude-code-ide-codex-events-tests--with-codex
    (let ((screen 'folder-trust)
          (reads 0))
      (cl-letf (((symbol-function 'claude-code-ide-codex-screen-dialog)
                 (lambda (buffer)
                   (should (bufferp buffer))
                   (cl-incf reads)
                   screen))
                ((symbol-function 'claude-code-ide-codex-screen-whole-p) (lambda (_buffer) t)))
        (unwind-protect
            (let* ((instance (claude-code-ide-codex-events-tests--instance "cci-test-dialog" 1))
                   (launch (claude-code-ide-codex-events--track instance))
                   (start (claude-code-ide-codex-events--launch-registered launch)))
              ;; Within the grace time: starting, and no read
              (should-not (claude-code-ide-codex-events--read-screen launch instance (+ start 1)))
              (should (= reads 0))
              (should (equal (claude-code-ide-codex-events-tests--state instance (+ start 1))
                             '(working starting t)))
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

(defvar claude-code-ide-codex-events-approval-end)

(defun claude-code-ide-codex-events-tests--approval-read (rule window &optional events)
  "Return the state after an approval and a screen read without a dialog.
RULE is the value of `claude-code-ide-codex-events-approval-end';
WINDOW non-nil means that a window of a display shows the terminal.
EVENTS, each (EVENT JSON), come after the read.  The result is
\(STATE REASON GUESS) 3 seconds after the read, before the approval
is a guess by time."
  (claude-code-ide-codex-events-tests--with-codex
    (let ((claude-code-ide-codex-events-approval-end rule))
      (cl-letf (((symbol-function 'claude-code-ide-codex-screen-dialog) (lambda (_buffer) nil))
                ((symbol-function 'claude-code-ide-codex-screen-whole-p)
                 (lambda (_buffer) (and window t))))
        (unwind-protect
            (let* ((instance (claude-code-ide-codex-events-tests--instance "cci-test-end" 1))
                   (launch (claude-code-ide-codex-events--track instance))
                   (start (claude-code-ide-codex-events--launch-registered launch)))
              (claude-code-ide-codex-events-tests--feed
               "cci-test-end" 1
               '(("SessionStart" "{}") ("UserPromptSubmit" "{}")
                 ("PreToolUse" "{\"tool_name\":\"mcp__emacs_tools__claude_code_ide_mcp_project_info\",\"tool_use_id\":\"t1\",\"tool_input\":{}}")
                 ("PermissionRequest" "{\"tool_name\":\"mcp__emacs_tools__claude_code_ide_mcp_project_info\",\"tool_input\":{}}"))
               (+ start 10))
              ;; The request came at start + 14; the read is 2 s later
              (claude-code-ide-codex-events--read-screen launch instance (+ start 16))
              (when events
                (claude-code-ide-codex-events-tests--feed "cci-test-end" 1 events (+ start 16)))
              (claude-code-ide-codex-events-tests--state instance (+ start 19)))
          (claude-code-ide-codex-events-tests--kill-instances))))))

(ert-deftest claude-code-ide-codex-events-test-approval-end-window ()
  "The default rule: a read without a dialog ends the wait only with a window."
  (should (eq (default-value 'claude-code-ide-codex-events-approval-end) 'window))
  ;; No window (an eat buffer in a daemon): the read cannot see the whole dialog
  (should (equal (claude-code-ide-codex-events-tests--approval-read 'window nil)
                 '(waiting-for-user approval nil)))
  ;; A window shows the whole screen: no dialog means that the user answered
  (should (equal (claude-code-ide-codex-events-tests--approval-read 'window t)
                 '(working nil t))))

(ert-deftest claude-code-ide-codex-events-test-approval-end-unsure-screen ()
  "A window, but a screen of an unsure size (two windows of other heights): the wait stays."
  (claude-code-ide-codex-events-tests--with-codex
    (cl-letf (((symbol-function 'claude-code-ide-codex-screen-dialog) (lambda (_buffer) nil))
              ((symbol-function 'claude-code-ide-codex-screen-window)
               (lambda (_buffer) (selected-window)))
              ((symbol-function 'claude-code-ide-codex-screen-whole-p) (lambda (_buffer) nil)))
      (unwind-protect
          (let* ((instance (claude-code-ide-codex-events-tests--instance "cci-test-unsure" 1))
                 (launch (claude-code-ide-codex-events--track instance))
                 (start (claude-code-ide-codex-events--launch-registered launch)))
            (claude-code-ide-codex-events-tests--feed
             "cci-test-unsure" 1
             '(("SessionStart" "{}") ("UserPromptSubmit" "{}")
               ("PreToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"make\"}}")
               ("PermissionRequest" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make\"}}"))
             (+ start 10))
            (claude-code-ide-codex-events--read-screen launch instance (+ start 16))
            (should (equal (claude-code-ide-codex-events-tests--state instance (+ start 19))
                           '(waiting-for-user approval nil))))
        (claude-code-ide-codex-events-tests--kill-instances)))))

(ert-deftest claude-code-ide-codex-events-test-approval-end-event ()
  "The rule `event': only an event ends the wait, also with a window."
  (should (equal (claude-code-ide-codex-events-tests--approval-read 'event t)
                 '(waiting-for-user approval nil)))
  (should (equal (claude-code-ide-codex-events-tests--approval-read 'event nil)
                 '(waiting-for-user approval nil))))

(ert-deftest claude-code-ide-codex-events-test-approval-end-screen ()
  "The rule `screen' (the old rule): any read without a dialog ends the wait."
  (should (equal (claude-code-ide-codex-events-tests--approval-read 'screen nil)
                 '(working nil t)))
  (should (equal (claude-code-ide-codex-events-tests--approval-read 'screen t)
                 '(working nil t))))

(ert-deftest claude-code-ide-codex-events-test-approval-end-events-without-window ()
  "Without a window, PostToolUse, Stop or Interrupt ends the wait."
  (should (equal (claude-code-ide-codex-events-tests--approval-read
                  'window nil
                  '(("PostToolUse" "{\"tool_name\":\"mcp__emacs_tools__claude_code_ide_mcp_project_info\",\"tool_use_id\":\"t1\",\"tool_input\":{},\"tool_response\":\"ok\"}")))
                 '(working nil nil)))
  (should (equal (car (claude-code-ide-codex-events-tests--approval-read
                       'window nil '(("Stop" "{\"last_assistant_message\":\"done\"}"))))
                 'idle))
  (should (equal (car (claude-code-ide-codex-events-tests--approval-read
                       'window nil '(("Interrupt" "{}"))))
                 'idle)))

(ert-deftest claude-code-ide-codex-events-test-approval-tail-in-eat-without-window ()
  "The tail of the MCP approval dialog, in a buffer without a window, is a sure approval."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let* ((instance (claude-code-ide-codex-events-tests--instance "cci-test-tail" 1))
               (launch (claude-code-ide-codex-events--track instance))
               (start (claude-code-ide-codex-events--launch-registered launch)))
          (with-current-buffer (claude-code-ide-instance-buffer instance)
            (insert "\n  Field 1/1\n  › 1. Allow  Run the tool and\n"
                    "  option 1/2 | enter to submit | esc\n\n"))
          (should-not (claude-code-ide-codex-screen-window (claude-code-ide-instance-buffer instance)))
          (claude-code-ide-codex-events-tests--feed
           "cci-test-tail" 1
           '(("SessionStart" "{}") ("UserPromptSubmit" "{}")
             ("PreToolUse" "{\"tool_name\":\"mcp__emacs_tools__claude_code_ide_mcp_project_info\",\"tool_use_id\":\"t1\",\"tool_input\":{}}")
             ("PermissionRequest" "{\"tool_name\":\"mcp__emacs_tools__claude_code_ide_mcp_project_info\",\"tool_input\":{}}"))
           (+ start 10))
          (claude-code-ide-codex-events--read-screen launch instance (+ start 16))
          ;; Sure, also after the guess time
          (should (equal (claude-code-ide-codex-events-tests--state instance (+ start 60))
                         '(waiting-for-user approval nil))))
      (claude-code-ide-codex-events-tests--kill-instances))))

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
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(disconnected untracked nil)))
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
      ;; Hooks that /hooks disabled are their own result
      (let ((result (funcall parse (claude-code-ide-codex-events-tests--hooks-json "trusted" 'disabled))))
        (should (eq (plist-get result :status) 'disabled))
        (should (equal (plist-get result :message) "Hooks disabled in Codex (/hooks)"))
        (should (= (length (plist-get result :hooks)) 1)))
      ;; Untrusted hooks next to a disabled one: untrusted
      (let ((result (funcall parse (claude-code-ide-codex-events-tests--hooks-json "untrusted" 'disabled))))
        (should (eq (plist-get result :status) 'untrusted)))
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
             (with-temp-file (expand-file-name "trusted.toml" ,dir)
               (insert (claude-code-ide-codex-events-tests--trust-toml)))
             ;; The config file has the trust records when the hooks are trusted
             (claude-code-ide-codex-events-tests--write-config
              (concat "[tui]\nscreen_reader_detection_done = true\n\n"
                      (if (equal ,trust "trusted") (claude-code-ide-codex-events-tests--trust-toml) "")))
             (let ((claude-code-ide-codex-events-program
                    (claude-code-ide-codex-events-tests--fake-server ,dir hooks-file ,refuse))
                   ;; A loaded machine can answer slowly; tests of the
                   ;; limit bind it themselves
                   (claude-code-ide-codex-events-trust-timeout claude-code-ide-tests--wait-limit))
               ,@body))
         (delete-directory ,dir t)))))

(defmacro claude-code-ide-codex-events-tests--with-lazy-trust (spec &rest body)
  "Run BODY with a fake Codex app-server, the real trust check and no cache.
SPEC is (DIR TRUST), as for
`claude-code-ide-codex-events-tests--with-fake-codex'.  In BODY,
`asked' counts the questions, `answer' is the answer of `yes-or-no-p',
and `servers' counts the app-server starts.  No question changes the
real ~/.codex: the fake writes to DIR only."
  (declare (indent 1))
  `(claude-code-ide-codex-events-tests--with-codex
     (clrhash claude-code-ide-codex-events--trust-cache)
     (claude-code-ide-codex-events-tests--with-fake-codex ,spec
       (let ((asked 0)
             (answer t)
             (servers 0)
             (start-server (symbol-function 'claude-code-ide-codex-events--server-start)))
         (cl-letf (((symbol-function 'claude-code-ide-codex-events--start-trust-check)
                    claude-code-ide-codex-events-tests--real-trust-check)
                   ((symbol-function 'claude-code-ide-codex-events--server-start)
                    (lambda (&rest args) (cl-incf servers) (apply start-server args)))
                   ((symbol-function 'yes-or-no-p) (lambda (_prompt) (cl-incf asked) answer))
                   ((symbol-function 'display-buffer) #'ignore)
                   ((symbol-function 'message) #'ignore))
           (unwind-protect
               (progn ,@body)
             (claude-code-ide-codex-events-tests--end-checks)
             (claude-code-ide-codex-events-tests--kill-instances)
             (when (get-buffer "*Codex status hooks*")
               (kill-buffer "*Codex status hooks*"))))))))

(defun claude-code-ide-codex-events-tests--end-checks ()
  "Stop the running trust checks and their app-servers."
  (maphash (lambda (_key check)
             (when (timerp (claude-code-ide-codex-events--check-timer check))
               (cancel-timer (claude-code-ide-codex-events--check-timer check)))
             (claude-code-ide-codex-events--server-stop (claude-code-ide-codex-events--check-server check)))
           claude-code-ide-codex-events--checks)
  (clrhash claude-code-ide-codex-events--checks))

(defun claude-code-ide-codex-events-tests--wait-checks ()
  "Wait until no trust check runs, at most `claude-code-ide-tests--wait-limit' s."
  (claude-code-ide-tests--wait-until
   (lambda () (zerop (hash-table-count claude-code-ide-codex-events--checks)))))

(defun claude-code-ide-codex-events-tests--writes (dir)
  "Return the number of trust writes that the fake app-server in DIR got."
  (let ((file (expand-file-name "writes.log" dir)))
    (if (file-exists-p file)
        (length (split-string (claude-code-ide-session-registry--file-string file) "\n" t))
      0)))

(defun claude-code-ide-codex-events-tests--start (id &optional interactive project)
  "Start the Codex launch ID as a start does; INTERACTIVE as the spec slot.
PROJECT is the project root of the instance.  Return (ARGS ENV LAUNCH)."
  (let* ((instance (claude-code-ide-codex-events-tests--instance id 1)))
    (when project
      (setf (claude-code-ide-instance-project-root instance) project))
    (let* ((args (claude-code-ide-codex-status-hook-args instance interactive))
           (env (claude-code-ide-codex-status-hook-env instance)))
      (list args env (claude-code-ide-codex-events--launch-of instance)))))

(defun claude-code-ide-codex-events-tests--silent-server (dir)
  "Write a fake `codex' in DIR that answers initialize only, and return it."
  (let ((program (expand-file-name "codex" dir)))
    (with-temp-file program
      (insert "#!/bin/sh\n"
              "while IFS= read -r line; do\n"
              "  case $line in\n"
              "    *'\"initialize\"'*) printf '{\"id\":1,\"result\":{}}\\n' ;;\n"
              "  esac\n"
              "done\n"))
    (set-file-modes program #o700)
    program))

(ert-deftest claude-code-ide-codex-events-test-lazy-trust-not-interactive ()
  "A start that the user did not ask for never asks and never waits.
On a cache miss it starts without hooks at once, and a check in the
background fills the cache for the next start."
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (pcase-let ((`(,args ,env ,launch) (claude-code-ide-codex-events-tests--start "cci-test-bg")))
      (should (= asked 0))
      (should-not args)
      (should-not env)
      (should-not (claude-code-ide-codex-events--launch-hooks launch))
      (let* ((instance (claude-code-ide-instance-by-id "cci-test-bg"))
             (now (+ (claude-code-ide-codex-events--launch-registered launch) 30)))
        (should (equal (claude-code-ide-codex-events-tests--state instance now)
                       '(disconnected untracked nil)))
        (should (string-match-p "a check runs for the next start"
                                (claude-code-ide-codex-events--instance-detail instance now)))
        ;; The background check fills the cache and the detail
        (claude-code-ide-codex-events-tests--wait-checks)
        (should (string-match-p "the next interactive start asks"
                                (claude-code-ide-codex-events--instance-detail instance now)))))
    ;; A second start without a user uses the cached untrusted result
    (let ((before servers))
      (should-not (car (claude-code-ide-codex-events-tests--start "cci-test-bg2")))
      (should (= servers before)))
    (should (= (claude-code-ide-codex-events-tests--writes dir) 0))
    ;; The next interactive start asks
    (should (car (claude-code-ide-codex-events-tests--start "cci-test-user" t)))
    (should (= asked 1))))

(ert-deftest claude-code-ide-codex-events-test-lazy-trust-never-waits ()
  "A start that the user did not ask for does not wait for a slow app-server.
Then a trusted result of the background check gives the next one its hooks."
  (claude-code-ide-codex-events-tests--with-codex
    (clrhash claude-code-ide-codex-events--trust-cache)
    (let* ((dir (make-temp-file "cci-test-codex-" t))
           (claude-code-ide-codex-events-program (claude-code-ide-codex-events-tests--silent-server dir))
           (claude-code-ide-codex-events-trust-timeout claude-code-ide-tests--wait-limit))
      (cl-letf (((symbol-function 'claude-code-ide-codex-events--start-trust-check)
                 claude-code-ide-codex-events-tests--real-trust-check))
        (unwind-protect
            (pcase-let ((`(,args ,_env ,launch)
                         ;; On the virtual clock, only a wait takes time
                         (claude-code-ide-tests--call-with-clock
                          (lambda ()
                            (let ((start (float-time)))
                              (prog1 (claude-code-ide-codex-events-tests--start "cci-test-nowait")
                                (should (< (- (float-time) start) 1))))))))
              (should-not args)
              (should-not (claude-code-ide-codex-events--launch-hooks launch))
              ;; The check of that start answers trusted later
              (let ((check (gethash (claude-code-ide-codex-events--trust-key)
                                    claude-code-ide-codex-events--checks)))
                (should check)
                (claude-code-ide-codex-events--finish-check
                 check (claude-code-ide-codex-events-tests--trusted-result)))
              (should (car (claude-code-ide-codex-events-tests--start "cci-test-after"))))
          (claude-code-ide-codex-events-tests--end-checks)
          (claude-code-ide-codex-events-tests--kill-instances)
          (delete-directory dir t))))))

(ert-deftest claude-code-ide-codex-events-test-lazy-trust-shared-check ()
  "Starts of the same key share one running check and one app-server.
An interactive start waits for the shared check within its limit."
  (claude-code-ide-codex-events-tests--with-codex
    (clrhash claude-code-ide-codex-events--trust-cache)
    (let* ((dir (make-temp-file "cci-test-codex-" t))
           (claude-code-ide-codex-events-program (claude-code-ide-codex-events-tests--silent-server dir))
           (claude-code-ide-codex-events-trust-timeout 0.3)
           (servers 0)
           (start-server (symbol-function 'claude-code-ide-codex-events--server-start)))
      (cl-letf (((symbol-function 'claude-code-ide-codex-events--start-trust-check)
                 claude-code-ide-codex-events-tests--real-trust-check)
                ((symbol-function 'claude-code-ide-codex-events--server-start)
                 (lambda (&rest args) (cl-incf servers) (apply start-server args))))
        (unwind-protect
            (progn
              (claude-code-ide-codex-events-tests--start "cci-test-a")
              (claude-code-ide-codex-events-tests--start "cci-test-b")
              (let ((start (float-time)))
                (claude-code-ide-codex-events-tests--start "cci-test-c" t)
                (should (>= (- (float-time) start) 0.25)))
              (should (= servers 1))
              (should (= (hash-table-count claude-code-ide-codex-events--checks) 1)))
          (claude-code-ide-codex-events-tests--end-checks)
          (claude-code-ide-codex-events-tests--kill-instances)
          (delete-directory dir t))))))

(ert-deftest claude-code-ide-codex-events-test-lazy-trust-interactive-yes ()
  "An interactive start with untrusted hooks asks once; after yes it gets trusted hooks.
The question uses the result of the check: one app-server lists, writes
and checks, all in the project folder."
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (let ((project (file-name-as-directory (expand-file-name "proj" dir))))
      (make-directory project)
      (pcase-let ((`(,args ,env ,launch)
                   (claude-code-ide-codex-events-tests--start "cci-test-yes" t project)))
        (should (= asked 1))
        (should (= servers 1))
        (should (= (claude-code-ide-codex-events-tests--writes dir) 1))
        (should args)
        (should env)
        (should (eq (claude-code-ide-codex-events--launch-trust launch) 'trusted))
        (should-not (claude-code-ide-codex-events--launch-trust-detail launch)))
      ;; Two lists, each in the project folder
      (let ((lists (cl-remove-if-not (lambda (line) (string-search "\"hooks/list\"" line))
                                     (split-string (claude-code-ide-session-registry--file-string
                                                    (expand-file-name "requests.log" dir))
                                                   "\n" t))))
        (should (= (length lists) 2))
        (dolist (line lists)
          (should (string-search (json-encode-string project) line)))))
    (should (eq (plist-get (gethash (claude-code-ide-codex-events--trust-key)
                                    claude-code-ide-codex-events--trust-cache)
                           :status)
                'trusted))
    ;; The next start needs no question and no app-server
    (let ((before servers))
      (should (car (claude-code-ide-codex-events-tests--start "cci-test-yes2" t)))
      (should (car (claude-code-ide-codex-events-tests--start "cci-test-yes3")))
      (should (= servers before))
      (should (= asked 1)))))

(ert-deftest claude-code-ide-codex-events-test-lazy-trust-interactive-no ()
  "After a no, the start goes on without status, and no start asks again.
The trust command still trusts the hooks."
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (setq answer nil)
    (pcase-let ((`(,args ,env ,launch) (claude-code-ide-codex-events-tests--start "cci-test-no" t)))
      (should (= asked 1))
      (should-not args)
      (should-not env)
      (should (eq (claude-code-ide-codex-events--launch-trust launch) 'untrusted))
      (should (string-match-p "claude-code-ide-codex-trust-hooks trusts them"
                              (claude-code-ide-codex-events--launch-trust-detail launch))))
    (should (= (claude-code-ide-codex-events-tests--writes dir) 0))
    ;; Not asked again in this Emacs
    (should-not (car (claude-code-ide-codex-events-tests--start "cci-test-no2" t)))
    (should (= asked 1))
    ;; The command asks, and trusts after yes
    (setq answer t)
    (claude-code-ide-codex-trust-hooks)
    (should (= asked 2))
    (should (= (claude-code-ide-codex-events-tests--writes dir) 1))
    (should-not claude-code-ide-codex-events--declined)
    (should (car (claude-code-ide-codex-events-tests--start "cci-test-no3" t)))
    (should (= asked 2))
    ;; The launch that started without hooks keeps no status until its restart
    (let ((old (gethash "cci-test-no" claude-code-ide-codex-events--launches)))
      (should (string-match-p "restart to get status"
                              (claude-code-ide-codex-events--launch-trust-detail old)))
      (should (equal (claude-code-ide-codex-events-tests--state
                      (claude-code-ide-instance-by-id "cci-test-no")
                      (+ (claude-code-ide-codex-events--launch-registered old) 30))
                     '(disconnected untracked nil))))))

(ert-deftest claude-code-ide-codex-events-test-lazy-trust-quit ()
  "C-g at the question starts without hooks and asks again at the next start."
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) (cl-incf asked) (signal 'quit nil))))
      (should-not (car (claude-code-ide-codex-events-tests--start "cci-test-quit" t)))
      (should-not claude-code-ide-codex-events--declined)
      (should-not (car (claude-code-ide-codex-events-tests--start "cci-test-quit2" t)))
      (should (= asked 2)))
    (should (= (claude-code-ide-codex-events-tests--writes dir) 0))))

(ert-deftest claude-code-ide-codex-events-test-lazy-trust-disabled ()
  "Hooks that the user disabled with /hooks give no hooks and no question.
The result is cached like an untrusted one."
  (claude-code-ide-codex-events-tests--with-codex
    (clrhash claude-code-ide-codex-events--trust-cache)
    (claude-code-ide-codex-events-tests--with-fake-codex (dir "trusted")
      (with-temp-file (expand-file-name "hooks.json" dir)
        (insert (claude-code-ide-codex-events-tests--hooks-json "trusted" 'disabled)))
      (let ((asked 0)
            (servers 0)
            (start-server (symbol-function 'claude-code-ide-codex-events--server-start)))
        (cl-letf (((symbol-function 'claude-code-ide-codex-events--start-trust-check)
                   claude-code-ide-codex-events-tests--real-trust-check)
                  ((symbol-function 'claude-code-ide-codex-events--server-start)
                   (lambda (&rest args) (cl-incf servers) (apply start-server args)))
                  ((symbol-function 'yes-or-no-p) (lambda (_prompt) (cl-incf asked) t)))
          (unwind-protect
              (pcase-let ((`(,args ,_env ,launch) (claude-code-ide-codex-events-tests--start "cci-test-off" t)))
                (should-not args)
                (should (= asked 0))
                (should (eq (claude-code-ide-codex-events--launch-trust launch) 'disabled))
                (should (equal (claude-code-ide-codex-events--launch-trust-detail launch)
                               "Hooks disabled in Codex (/hooks)"))
                (should-not (car (claude-code-ide-codex-events-tests--start "cci-test-off2" t)))
                (should (= servers 1))
                (should (= asked 0)))
            (claude-code-ide-codex-events-tests--kill-instances)))))))

(ert-deftest claude-code-ide-codex-events-test-lazy-trust-cache ()
  "A trusted cache entry holds while config.toml still has its trust records.
The key holds the hook definitions and the Codex config path.  Other
writes to config.toml keep the entry; a changed or removed
trusted_hash, a disabled hook, or a broken file end it, without an
error."
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (let* ((key (claude-code-ide-codex-events--trust-key))
           (config (claude-code-ide-transcript--codex-config-file))
           (pairs (claude-code-ide-codex-events-tests--trust-pairs))
           (trusted (claude-code-ide-codex-events-tests--trust-toml pairs))
           (remember (lambda ()
                       (claude-code-ide-codex-events--remember-trust
                        key (claude-code-ide-codex-events-tests--trusted-result pairs))))
           (valid (lambda (text)
                    (claude-code-ide-codex-events-tests--write-config text)
                    (funcall remember)
                    (and (claude-code-ide-codex-events--cached-trust key) t))))
      (should (string-prefix-p (expand-file-name "codex-home" registry-dir) config))
      (should (string-search (concat "|" config "|") key))
      (claude-code-ide-codex-events-tests--write-config trusted)
      (funcall remember)
      (pcase-let ((`(,args ,_env ,launch) (claude-code-ide-codex-events-tests--start "cci-test-cache" t)))
        (should args)
        (should (eq (claude-code-ide-codex-events--launch-trust launch) 'trusted)))
      (should (= servers 0))
      (should (= asked 0))
      ;; A write that a Codex terminal makes at its start keeps the entry
      (claude-code-ide-codex-events-tests--write-config
       (concat "[tui]\nscreen_reader_detection_done = true\n\n[tui.model_availability_nux]\n\"gpt-6.1-sol\" = 5\n\n"
               trusted "[projects.\"/tmp/cci-test\"]\ntrust_level = \"trusted\"\n"))
      (should (claude-code-ide-codex-events--cached-trust key))
      (should (car (claude-code-ide-codex-events-tests--start "cci-test-cache2")))
      (should (= servers 0))
      ;; A changed trusted_hash, a removed one, a disabled hook, a broken file
      (should-not (funcall valid (replace-regexp-in-string "sha256:hash3\"" "sha256:other\"" trusted)))
      (should-not (funcall valid (claude-code-ide-codex-events-tests--trust-toml (cdr pairs))))
      (should-not (funcall valid (concat trusted "[hooks.state.\"" (car (nth 2 pairs)) "\"]\nenabled = false\n")))
      (should-not (funcall valid (concat trusted "[[[ broken\n")))
      (should-not (funcall valid ""))
      (delete-file config)
      (funcall remember)
      (should-not (claude-code-ide-codex-events--cached-trust key))
      ;; The invalid entry left the cache; a start without a user gets no hooks
      (should-not (gethash key claude-code-ide-codex-events--trust-cache))
      (should-not (car (claude-code-ide-codex-events-tests--start "cci-test-cache3")))
      ;; The same records as dotted keys in one table count too
      (should (funcall valid (concat "[hooks]\n"
                                     (mapconcat (lambda (pair)
                                                  (format "state.\"%s\".trusted_hash = \"%s\"\n"
                                                          (car pair) (cdr pair)))
                                                pairs ""))))
      ;; Another CODEX_HOME is another key
      (let ((process-environment (cons (concat "CODEX_HOME=" (expand-file-name "other" registry-dir))
                                       process-environment)))
        (should-not (equal (claude-code-ide-codex-events--trust-key) key))))))

(ert-deftest claude-code-ide-codex-events-test-lazy-trust-changed-definitions ()
  "Other hook definitions miss the cache and the next interactive start asks again."
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (setq answer nil)
    (claude-code-ide-codex-events-tests--start "cci-test-v1" t)
    (should (= asked 1))
    (let ((old-key (claude-code-ide-codex-events--trust-key))
          (claude-code-ide-codex-events--events '("SessionStart" "Stop")))
      (should-not (equal (claude-code-ide-codex-events--trust-key) old-key))
      (claude-code-ide-codex-events-tests--start "cci-test-v2" t)
      (should (= asked 2)))
    ;; A trusted result of the old definitions does not count either
    (claude-code-ide-codex-events--remember-trust
     (claude-code-ide-codex-events--trust-key) '(:status trusted :message nil))
    (let ((claude-code-ide-codex-events--events '("SessionStart")))
      (should-not (claude-code-ide-codex-events--cached-trust (claude-code-ide-codex-events--trust-key))))))

(ert-deftest claude-code-ide-codex-events-test-lazy-trust-timeout ()
  "An app-server that does not answer in time does not hold an interactive start.
The start gets no hooks, the detail says that the trust is unknown,
and nothing asks the user."
  (claude-code-ide-codex-events-tests--with-codex
    (clrhash claude-code-ide-codex-events--trust-cache)
    (let* ((dir (make-temp-file "cci-test-codex-" t))
           (asked 0))
      (unwind-protect
          (let ((claude-code-ide-codex-events-program (claude-code-ide-codex-events-tests--silent-server dir))
                (claude-code-ide-codex-events-trust-timeout 0.3)
                ;; The limit of the check runs on a real timer: no pause
                ;; of a loaded machine reaches it during the wait
                (claude-code-ide-codex-events--background-limit claude-code-ide-tests--wait-limit))
            (cl-letf (((symbol-function 'claude-code-ide-codex-events--start-trust-check)
                       claude-code-ide-codex-events-tests--real-trust-check)
                      ((symbol-function 'yes-or-no-p) (lambda (_prompt) (cl-incf asked) t)))
              (pcase-let ((`(,args ,_env ,launch)
                           ;; On the virtual clock, only the wait for the
                           ;; answer takes time, however slow the machine is
                           (claude-code-ide-tests--call-with-clock
                            (lambda ()
                              (let ((start (float-time)))
                                (prog1 (claude-code-ide-codex-events-tests--start "cci-test-slow" t)
                                  (should (< (- (float-time) start) 2))))))))
                (should-not args)
                (should (= asked 0))
                (should (string-match-p "Hook trust unknown: no answer"
                                        (claude-code-ide-codex-events--launch-trust-detail launch)))
                ;; The background check ends by itself at its limit; the
                ;; test moves the timer of the limit to now
                (let ((timer (claude-code-ide-codex-events--check-timer
                              (gethash (claude-code-ide-codex-events--trust-key)
                                       claude-code-ide-codex-events--checks))))
                  (should (timerp timer))
                  ;; The package activated it
                  (should (memq timer timer-list))
                  (should (< 0 (- (timer-until timer nil))
                             (1+ claude-code-ide-codex-events--background-limit)))
                  (cancel-timer timer)
                  (timer-set-time timer (current-time))
                  (timer-activate timer))
                (claude-code-ide-codex-events-tests--wait-checks)
                (should (zerop (hash-table-count claude-code-ide-codex-events--checks)))
                (should (string-match-p "Hook trust unknown"
                                        (claude-code-ide-codex-events--launch-trust-detail launch))))))
        (claude-code-ide-codex-events-tests--end-checks)
        (claude-code-ide-codex-events-tests--kill-instances)
        (delete-directory dir t)))))

(ert-deftest claude-code-ide-codex-events-test-hooks-only-when-confirmed ()
  "A launch record has no hooks until the trust is confirmed.
A later trust result does not give hooks to a launch without them."
  (should-not (claude-code-ide-codex-events--launch-hooks
               (claude-code-ide-codex-events--launch-create)))
  (claude-code-ide-codex-events-tests--with-codex
    (clrhash claude-code-ide-codex-events--trust-cache)
    (unwind-protect
        (pcase-let ((`(,args ,_env ,launch) (claude-code-ide-codex-events-tests--start "cci-test-late")))
          (should-not args)
          (setf (claude-code-ide-codex-events--launch-trust launch) 'error)
          (claude-code-ide-codex-events--set-trust (claude-code-ide-codex-events--trust-key)
                                                   '(:status trusted :message nil))
          (should-not (claude-code-ide-codex-events--launch-hooks launch))
          (let ((now (+ (claude-code-ide-codex-events--launch-registered launch) 30)))
            (should (equal (claude-code-ide-codex-events-tests--state
                            (claude-code-ide-instance-by-id "cci-test-late") now)
                           '(disconnected untracked nil)))
            (should (string-match-p "restart to get status"
                                    (claude-code-ide-codex-events--instance-detail
                                     (claude-code-ide-instance-by-id "cci-test-late") now)))))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-prepare-trust-for-a-restore ()
  "A restore of the user asks at most one time for all its starts."
  ;; Yes: one question, and the starts of the restore get trusted hooks
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (let ((interactive (claude-code-ide-codex-prepare-trust)))
      (should (eq interactive t))
      (should (= asked 1))
      (dolist (id '("cci-test-r1" "cci-test-r2" "cci-test-r3"))
        (should (car (claude-code-ide-codex-events-tests--start id interactive))))
      (should (= asked 1))
      ;; Trusted in the cache: no app-server and no question
      (let ((before servers))
        (should (eq (claude-code-ide-codex-prepare-trust) t))
        (should (= servers before)))))
  ;; No: one question, the starts get no hooks and ask nothing
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (setq answer nil)
    (let ((interactive (claude-code-ide-codex-prepare-trust)))
      (should-not interactive)
      (dolist (id '("cci-test-n1" "cci-test-n2"))
        (should-not (car (claude-code-ide-codex-events-tests--start id interactive))))
      (should (= asked 1))
      ;; Declined: a second restore asks nothing
      (should-not (claude-code-ide-codex-prepare-trust))
      (should (= asked 1)))))

(ert-deftest claude-code-ide-codex-events-test-trust-check-without-codex ()
  "Without a Codex program the trust is unknown: no hooks, and the detail says why."
  (claude-code-ide-codex-events-tests--with-codex
    (clrhash claude-code-ide-codex-events--trust-cache)
    (cl-letf (((symbol-function 'claude-code-ide-codex-events--start-trust-check)
               claude-code-ide-codex-events-tests--real-trust-check))
      (unwind-protect
          (let* ((claude-code-ide-codex-events-program "/nonexistent/cci-test-codex")
                 (instance (claude-code-ide-codex-events-tests--instance "cci-test-nocodex" 1)))
            (should-not (claude-code-ide-codex-status-hook-args instance t))
            (let ((launch (claude-code-ide-codex-events--launch-of instance)))
              (should (eq (claude-code-ide-codex-events--launch-trust launch) 'error))
              (should (string-match-p "Hook trust unknown"
                                      (claude-code-ide-codex-events--launch-trust-detail launch)))
              ;; No hooks: untracked, and the detail tells why
              (let ((now (+ (claude-code-ide-codex-events--launch-registered launch) 30)))
                (should (equal (claude-code-ide-codex-events-tests--state instance now)
                               '(disconnected untracked nil)))
                (should (string-match-p "Hook trust unknown"
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
        (should (eq (plist-get (gethash (claude-code-ide-codex-events--trust-key)
                                        claude-code-ide-codex-events--trust-cache)
                               :status)
                    'trusted))))))

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
        (let* ((now nil)
               (instance (claude-code-ide-codex-events-tests--instance "cci-test-row" 1))
               (cc-buffer (generate-new-buffer "*cci-test-cc-row*"))
               (cc-session (claude-code-ide-tests--make-session "/tmp/cci-test-cc-row/" :buffer cc-buffer)))
          (claude-code-ide-instance-register
           (claude-code-ide-instance-create :id "cci-test-cc-row" :provider 'claude
                                            :session cc-session :buffer cc-buffer))
          (claude-code-ide-codex-events--track instance)
          ;; One time for the events and the rows: a slow machine
          ;; does not age the events
          (setq now (float-time))
          (claude-code-ide-codex-events-tests--feed
           "cci-test-row" 1
           '(("UserPromptSubmit" "{}")
             ("PreToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"make\"}}")
             ("PermissionRequest" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make\"}}"))
           (- now 3))
          (let* ((rows (claude-code-ide-session-status--rows now))
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
            (should (equal (aref cc-entry 4) "disconnected/untracked"))
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
                   (disconnected untracked nil untracked) (disconnected no-signal nil unobserved)
                   (idle nil nil idle) (working nil nil working) (working starting t starting)))
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
    (should (eq (plist-get (claude-code-ide-session-status--common-state status 6.0) :reason) 'error))
    ;; No credits: a quota limit
    (claude-code-ide-session-status--apply status "UserPromptSubmit" nil 7.0)
    (claude-code-ide-session-status--apply status "StopFailure" '((error . "billing_error")) 8.0)
    (should (eq (claude-code-ide-session-status--state status 9.0) 'quota))
    ;; A short rate limit is an error, with its text
    (dolist (case '((((error . "rate_limit")) . "Error: rate limit")
                    (((error . "rate_limit") (error_details . "Too many requests, retry in 3s"))
                     . "Error: rate limit: Too many requests, retry in 3s")
                    (((error . "rate_limit")
                      (error_details . "Rate limit reached for requests per min. Try again in 2s"))
                     . "Error: rate limit: Rate limit reached for requests per min. Try again in 2s")))
      (claude-code-ide-session-status--apply status "UserPromptSubmit" nil 10.0)
      (claude-code-ide-session-status--apply status "StopFailure" (car case) 11.0)
      (should (equal (list (claude-code-ide-session-status--state status 12.0)
                           (claude-code-ide-session-status--detail status 'error 12.0))
                     (list 'error (cdr case)))))
    ;; The limit in the last message counts too
    (claude-code-ide-session-status--apply status "UserPromptSubmit" nil 13.0)
    (claude-code-ide-session-status--apply
     status "StopFailure"
     '((error . "rate_limit") (last_assistant_message . "Claude usage limit reached. Your limit will reset at 5pm")) 14.0)
    (should (eq (claude-code-ide-session-status--state status 15.0) 'quota))))

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
            (should (equal (alist-get 'source record) "hooks"))
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

;;; Review fixes

(ert-deftest claude-code-ide-codex-events-test-parallel-tool-approval ()
  "An approval belongs to its own tool, also among parallel tools.
The request input has a description that the tool input lacks."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let ((instance (claude-code-ide-codex-events-tests--instance "cci-test-par" 1)))
          (claude-code-ide-codex-events--track instance)
          (claude-code-ide-codex-events-tests--feed
           "cci-test-par" 1
           '(("UserPromptSubmit" "{}")
             ("PreToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"a\",\"tool_input\":{\"command\":\"ls a\"}}")
             ("PreToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"b\",\"tool_input\":{\"command\":\"rm b\"}}")
             ("PermissionRequest" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm b\",\"description\":\"Allow rm?\"}}")))
          (let ((launch (claude-code-ide-codex-events--launch-of instance)))
            (should (equal (claude-code-ide-codex-events--blocker-tool
                            (car (claude-code-ide-codex-events--launch-blockers launch)))
                           '(nil . "b"))))
          ;; The end of tool a leaves the approval of tool b
          (claude-code-ide-codex-events-tests--feed
           "cci-test-par" 1
           '(("PostToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"a\",\"tool_input\":{\"command\":\"ls a\"}}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance 906.0)
                         '(waiting-for-user approval nil)))
          (should (equal (claude-code-ide-codex-events--instance-detail instance 906.0) "Bash: rm b"))
          (claude-code-ide-codex-events-tests--feed
           "cci-test-par" 1
           '(("PostToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"b\",\"tool_input\":{\"command\":\"rm b\"}}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(working nil nil)))
          ;; A request with a tool use id names its tool
          (claude-code-ide-codex-events-tests--feed
           "cci-test-par" 1
           '(("PreToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"c\",\"tool_input\":{\"command\":\"x\"}}")
             ("PreToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"d\",\"tool_input\":{\"command\":\"x\"}}")
             ("PermissionRequest" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"c\",\"tool_input\":{\"command\":\"x\"}}")))
          (should (equal (claude-code-ide-codex-events--blocker-tool
                          (car (claude-code-ide-codex-events--launch-blockers
                                (claude-code-ide-codex-events--launch-of instance))))
                         '(nil . "c")))
          (should (claude-code-ide-codex-events--input-matches-p
                   '((command . "x") (description . "y")) '((command . "x"))))
          (should-not (claude-code-ide-codex-events--input-matches-p
                       '((command . "x")) '((command . "x") (cwd . "/tmp"))))
          (should (claude-code-ide-codex-events--input-matches-p nil nil)))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-new-conversation-in-launch ()
  "A SessionStart with a new conversation ID moves the launch to it.
After /new or a thread switch the events of the new conversation count;
other events with an unknown conversation ID still drop."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let ((instance (claude-code-ide-codex-events-tests--instance "cci-test-new" 1)))
          (claude-code-ide-codex-events--track instance)
          (claude-code-ide-codex-events-tests--feed
           "cci-test-new" 1 '(("SessionStart" "{\"session_id\":\"cci-test-s1\"}")
                              ("UserPromptSubmit" "{\"session_id\":\"cci-test-s1\"}")
                              ("Stop" "{\"session_id\":\"cci-test-s1\"}")))
          (should (equal (claude-code-ide-instance-native-id instance) "cci-test-s1"))
          ;; An event of an unknown conversation without its SessionStart drops
          (should-not (car (claude-code-ide-codex-events-tests--feed
                            "cci-test-new" 1 '(("UserPromptSubmit" "{\"session_id\":\"cci-test-s9\"}")))))
          ;; A subagent's SessionStart does not move the launch
          (should-not (car (claude-code-ide-codex-events-tests--feed
                            "cci-test-new" 1 '(("SessionStart" "{\"session_id\":\"cci-test-s8\",\"agent_id\":\"a1\"}")))))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(idle nil nil)))
          ;; /new: a SessionStart of a new conversation
          (should (car (claude-code-ide-codex-events-tests--feed
                        "cci-test-new" 1 '(("SessionStart" "{\"session_id\":\"cci-test-s2\",\"source\":\"startup\"}")))))
          (should (equal (claude-code-ide-codex-events--launch-session-id
                          (claude-code-ide-codex-events--launch-of instance))
                         "cci-test-s2"))
          (should (equal (claude-code-ide-instance-native-id instance) "cci-test-s2"))
          (should (car (claude-code-ide-codex-events-tests--feed
                        "cci-test-new" 1 '(("UserPromptSubmit" "{\"session_id\":\"cci-test-s2\"}")))))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(working nil nil)))
          ;; The old conversation is unknown now
          (should-not (car (claude-code-ide-codex-events-tests--feed
                            "cci-test-new" 1 '(("Stop" "{\"session_id\":\"cci-test-s1\"}")))))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(working nil nil))))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-retry-after-failure ()
  "A successful model request after a failed one ends the failure."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let ((instance (claude-code-ide-codex-events-tests--instance "cci-test-retry" 1)))
          (claude-code-ide-codex-events--track instance)
          (claude-code-ide-codex-events-tests--feed
           "cci-test-retry" 1
           '(("UserPromptSubmit" "{}")
             ("PostModelRequest" "{\"status\":\"failed\",\"error\":\"stream disconnected\"}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(failed error nil)))
          (claude-code-ide-codex-events-tests--feed
           "cci-test-retry" 1 '(("PostModelRequest" "{\"status\":\"completed\",\"error\":null}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(working nil nil)))
          (should-not (claude-code-ide-codex-events--launch-failure
                       (claude-code-ide-codex-events--launch-of instance)))
          ;; A subagent's answer does not end a failure of the main turn
          (claude-code-ide-codex-events-tests--feed
           "cci-test-retry" 1
           '(("PostModelRequest" "{\"status\":\"failed\",\"error\":\"stream disconnected\"}")
             ("PostModelRequest" "{\"agent_id\":\"a1\",\"status\":\"completed\"}")))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(failed error nil))))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-json-without-native-json ()
  "The app-server answers and the event files parse also without native JSON."
  (claude-code-ide-codex-events-tests--with-codex
    (cl-letf (((symbol-function 'json-available-p) (lambda () nil)))
      (should (equal (claude-code-ide-session-status--parse-json "{\"a\":false,\"b\":null,\"c\":[1]}" :false)
                     '((a . :false) (b) (c 1))))
      (let* ((server (claude-code-ide-codex-events--server-create))
             (answer nil))
        (puthash 2 (lambda (result error) (setq answer (list result error)))
                 (claude-code-ide-codex-events--server-pending server))
        (claude-code-ide-codex-events--server-filter
         server (concat "{\"method\":\"remoteControl/status/changed\",\"params\":{}}\n{\"id\":2,\"result\":"))
        (should-not answer)
        (claude-code-ide-codex-events--server-filter
         server (concat (claude-code-ide-codex-events-tests--hooks-json "trusted" 'disabled) "}\n"))
        (should answer)
        (let ((result (claude-code-ide-codex-events--trust-result (list :result (car answer)))))
          (should (eq (plist-get result :status) 'disabled))
          (should (= (length (plist-get result :hooks)) 1))))
      (let ((file (expand-file-name "cci-test.json" registry-dir)))
        (with-temp-file file (insert "{\"event\":\"Stop\",\"input\":{\"x\":false}}"))
        (should (equal (claude-code-ide-codex-events--read-file file)
                       '((event . "Stop") (input (x)))))))))

(ert-deftest claude-code-ide-codex-events-test-answered-per-blocker ()
  "The end of a subagent leaves the screen check of the main approval.
A window shows the terminal, so a read without a dialog ends the wait."
  (claude-code-ide-codex-events-tests--with-codex
    (cl-letf (((symbol-function 'claude-code-ide-codex-screen-dialog) (lambda (_buffer) nil))
              ((symbol-function 'claude-code-ide-codex-screen-whole-p) (lambda (_buffer) t)))
      (unwind-protect
          (let* ((instance (claude-code-ide-codex-events-tests--instance "cci-test-ans" 1))
                 (launch (claude-code-ide-codex-events--track instance)))
            (claude-code-ide-codex-events-tests--feed
             "cci-test-ans" 1
             '(("UserPromptSubmit" "{}")
               ("SubagentStart" "{\"agent_id\":\"a1\",\"agent_type\":\"default\"}")
               ("PreToolUse" "{\"tool_name\":\"Bash\",\"tool_use_id\":\"t1\",\"tool_input\":{\"command\":\"make\"}}")
               ("PermissionRequest" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make\",\"description\":\"d\"}}"))
             100.0)
            ;; The screen shows no dialog: the main approval was answered
            (should (claude-code-ide-codex-events--read-screen launch instance 110.0))
            (should (equal (claude-code-ide-codex-events-tests--state instance 111.0) '(working nil t)))
            ;; The subagent ends: the main approval keeps its answer
            (claude-code-ide-codex-events-tests--feed
             "cci-test-ans" 1 '(("SubagentStop" "{\"agent_id\":\"a1\",\"agent_type\":\"default\"}")) 111.0)
            (should (equal (claude-code-ide-codex-events-tests--state instance 113.0) '(working nil t))))
        (claude-code-ide-codex-events-tests--kill-instances)))))

(ert-deftest claude-code-ide-codex-events-test-trust-after-launch ()
  "A launch that started without hooks stays untracked after the trust.
Its detail asks for a restart; a new launch is trusted."
  (claude-code-ide-codex-events-tests--with-codex
    (clrhash claude-code-ide-codex-events--trust-cache)
    (unwind-protect
        (let* ((key (claude-code-ide-codex-events--trust-key))
               (old (claude-code-ide-codex-events-tests--instance "cci-test-old" 1))
               (launch (claude-code-ide-codex-events--track old)))
          (should-not (claude-code-ide-codex-events--launch-hooks launch))
          (claude-code-ide-codex-events--set-trust key '(:status untrusted :message "1 of 11 not trusted"))
          (should (eq (claude-code-ide-codex-events--launch-trust launch) 'untrusted))
          (should (string-match-p "the next interactive start asks"
                                  (claude-code-ide-codex-events--launch-trust-detail launch)))
          ;; The trust command trusts the hooks
          (claude-code-ide-codex-events--remember-trust key (claude-code-ide-codex-events-tests--trusted-result))
          (claude-code-ide-codex-events--set-trust key '(:status trusted :message nil))
          (let ((now (+ (claude-code-ide-codex-events--launch-registered launch) 30)))
            (should (equal (claude-code-ide-codex-events-tests--state old now) '(disconnected untracked nil)))
            (should (string-match-p "restart to get status"
                                    (claude-code-ide-codex-events--instance-detail old now))))
          ;; A launch after the trust uses the trusted result
          (let* ((new (claude-code-ide-codex-events-tests--instance "cci-test-new-launch" 1))
                 (fresh (claude-code-ide-codex-events--track new)))
            (should (eq (claude-code-ide-codex-events--launch-trust fresh) 'trusted))
            (should (claude-code-ide-codex-events--launch-hooks fresh)))
          ;; A launch with hooks keeps them whatever a later check says
          (let ((fresh (gethash "cci-test-new-launch" claude-code-ide-codex-events--launches)))
            (claude-code-ide-codex-events--set-trust key '(:status untrusted :message "x"))
            (should (claude-code-ide-codex-events--launch-hooks fresh))
            (should (eq (claude-code-ide-codex-events--launch-trust fresh) 'trusted))))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-shared-file-helpers ()
  "One helper writes files atomically, one deletes launch files, one old locks."
  (claude-code-ide-codex-events-tests--with-codex
    (let* ((dir (expand-file-name "cci-test-helpers/sub/" registry-dir))
           (file (expand-file-name "x.sh" dir)))
      (claude-code-ide-session-status--write-file-atomically file "echo x\n" #o700 #o700)
      (should (= (file-modes dir) #o700))
      (should (= (file-modes file) #o700))
      (should (equal (claude-code-ide-session-registry--file-string file) "echo x\n"))
      (should (equal (directory-files dir nil "\\`[^.]") '("x.sh")))
      (should-not (directory-files dir nil "\\`\\.[^.]"))
      ;; Launch files and their dot files
      (dolist (name '("l1.2.00000001.Stop.json" ".l1.2.seq" "l1.20.00000001.Stop.json" "other.json"))
        (with-temp-file (expand-file-name name dir) (insert "{}")))
      (make-directory (expand-file-name ".l1.2.lock" dir))
      (claude-code-ide-session-status--delete-matching-files dir (concat "\\`\\.?" (regexp-quote "l1.2.")))
      (should (equal (directory-files dir nil "json\\'\\|seq\\'\\|lock\\'")
                     '("l1.20.00000001.Stop.json" "other.json")))
      ;; Only old locks go
      (let ((old (expand-file-name ".a.lock" dir))
            (young (expand-file-name ".b.lock" dir)))
        (make-directory old)
        (make-directory young)
        (set-file-times old (time-subtract nil 10))
        (claude-code-ide-session-status--remove-old-locks dir "\\`\\..+\\.lock\\'")
        (should-not (file-exists-p old))
        (should (file-exists-p young))))))

;;; The restore of the user

(declare-function claude-code-ide-tests--registry-entry "claude-code-ide-session-registry-tests")
(declare-function claude-code-ide-tests--registry-project "claude-code-ide-session-registry-tests")
(declare-function claude-code-ide-tests--run-restore-timers "claude-code-ide-session-registry-tests")

(defmacro claude-code-ide-codex-events-tests--restore (answer-value)
  "Run M-x claude-code-ide-restore-sessions of two Codex entries.
It expands inside `claude-code-ide-codex-events-tests--with-lazy-trust',
whose `registry-dir', `answer' and `asked' it uses.  The user answers
ANSWER-VALUE to the trust question.  Each start
builds the Codex hook arguments from the `interactive' slot of its
spec, as the Codex launch does.  Return (QUESTIONS SLOTS HOOKS) with
the number of questions, the slot of each start, and whether each
start got hooks."
  `(let* ((config-dir (expand-file-name "claude" registry-dir))
          (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
          (dir (claude-code-ide-tests--registry-project registry-dir "cci-test-restore-proj"))
          (slots nil)
          (hooks nil)
          (timers nil))
     (setq answer ,answer-value)
     (claude-code-ide-session-registry--submit
      "setup"
      (lambda (_)
        (list (claude-code-ide-tests--registry-entry
               "cci-test-restore-cx1" :provider 'codex :session-id "cci-test-restore-n1"
               :project-dir dir :emacs-pid 999999991)
              (claude-code-ide-tests--registry-entry
               "cci-test-restore-cx2" :provider 'codex :session-id "cci-test-restore-n2"
               :project-dir dir :emacs-pid 999999991 :started-at "2026-11-03T10:01:00Z"))))
     (cl-letf (((symbol-function 'run-with-timer)
                (lambda (_secs _repeat fn &rest args) (push (cons fn args) timers)))
               ((symbol-function 'claude-code-ide--start-session)
                (lambda (_continue _resume spec &optional _interactive)
                  (let* ((slot (claude-code-ide-start-spec-interactive spec))
                         (instance (claude-code-ide-codex-events-tests--instance
                                    (claude-code-ide-start-spec-instance-id spec) 1)))
                    (setf (claude-code-ide-instance-project-root instance) dir)
                    (push slot slots)
                    (push (and (claude-code-ide-codex-status-hook-args instance slot) t) hooks)))))
       (call-interactively #'claude-code-ide-restore-sessions)
       (claude-code-ide-tests--run-restore-timers timers))
     (list asked (reverse slots) (reverse hooks))))

(ert-deftest claude-code-ide-codex-events-test-restore-asks-once ()
  "M-x claude-code-ide-restore-sessions asks the hook trust one time, before its starts.
The registry's call meets `claude-code-ide-codex-prepare-trust'.  The
starts run from timers and are never interactive: they never ask and
never wait.  After a yes, they find the trusted result in the cache and
get their hooks.  After a no, none gets hooks; a second restore asks
nothing."
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (let ((waits 0)
          (wait (symbol-function 'claude-code-ide-codex-events--wait-check)))
      (cl-letf (((symbol-function 'claude-code-ide-codex-events--wait-check)
                 (lambda (&rest args) (cl-incf waits) (apply wait args))))
        (should (equal (claude-code-ide-codex-events-tests--restore t)
                       '(1 (nil nil) (t t)))))
      (should (= waits 0)))
    (should (= (claude-code-ide-codex-events-tests--writes dir) 1)))
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (should (equal (claude-code-ide-codex-events-tests--restore nil)
                   '(1 (nil nil) (nil nil))))
    (should (= (claude-code-ide-codex-events-tests--writes dir) 0))
    (should (equal (car (claude-code-ide-codex-events-tests--restore nil)) 1))))

;;; Second review fixes

(ert-deftest claude-code-ide-codex-events-test-quit-in-wait-frees-check ()
  "A C-g while an interactive start waits for the check frees its app-server."
  (claude-code-ide-codex-events-tests--with-codex
    (clrhash claude-code-ide-codex-events--trust-cache)
    (let* ((dir (make-temp-file "cci-test-codex-" t))
           (claude-code-ide-codex-events-program (claude-code-ide-codex-events-tests--silent-server dir))
           (claude-code-ide-codex-events-trust-timeout 5))
      (cl-letf (((symbol-function 'claude-code-ide-codex-events--start-trust-check)
                 claude-code-ide-codex-events-tests--real-trust-check)
                ((symbol-function 'claude-code-ide-codex-events--wait-check)
                 (lambda (_check _deadline) (signal 'quit nil))))
        (unwind-protect
            (progn
              (should (eq (car (condition-case nil
                                   (progn (claude-code-ide-codex-events-tests--start "cci-test-cg" t) nil)
                                 (quit '(quit))))
                          'quit))
              (let ((check (gethash (claude-code-ide-codex-events--trust-key)
                                    claude-code-ide-codex-events--checks)))
                (should check)
                (should-not (claude-code-ide-codex-events--check-keep check))
                ;; Its end now stops the app-server
                (claude-code-ide-codex-events--finish-check check '(:status error :message "x"))
                (should-not (process-live-p (claude-code-ide-codex-events--server-process
                                             (claude-code-ide-codex-events--check-server check))))))
          (claude-code-ide-codex-events-tests--end-checks)
          (claude-code-ide-codex-events-tests--kill-instances)
          (delete-directory dir t))))))

(ert-deftest claude-code-ide-codex-events-test-trust-pairs-must-be-whole ()
  "Trust records need a key and a hash; an empty list never validates."
  (claude-code-ide-codex-events-tests--with-codex
    (claude-code-ide-codex-events-tests--write-config "[tui]\nx = 1\n")
    (should-not (claude-code-ide-codex-events--config-trusts-p nil))
    (should-not (claude-code-ide-codex-events--config-trusts-p '((nil . nil))))
    (should-not (claude-code-ide-codex-events--config-trusts-p '(("k" . ""))))
    ;; A trusted hook without its hash: the result is not cached as trusted
    (let* ((json (replace-regexp-in-string
                  "\"currentHash\":\"sha256:hash2\"," ""
                  (claude-code-ide-codex-events-tests--hooks-json "trusted")))
           (result (claude-code-ide-codex-events--trust-result
                    (list :result (claude-code-ide-session-status--parse-json json :false))))
           (key (claude-code-ide-codex-events--trust-key)))
      (should (eq (plist-get result :status) 'trusted))
      (should-not (plist-get result :cache))
      (clrhash claude-code-ide-codex-events--trust-cache)
      (claude-code-ide-codex-events--remember-trust key result)
      (should-not (gethash key claude-code-ide-codex-events--trust-cache)))))

(ert-deftest claude-code-ide-codex-events-test-key-holds-the-program ()
  "Another Codex program, or a new version of it, gives another cache key."
  (claude-code-ide-codex-events-tests--with-codex
    (let* ((dir (make-temp-file "cci-test-codex-" t))
           (a (claude-code-ide-codex-events-tests--silent-server
               (progn (make-directory (expand-file-name "a" dir)) (expand-file-name "a" dir))))
           (b (claude-code-ide-codex-events-tests--silent-server
               (progn (make-directory (expand-file-name "b" dir)) (expand-file-name "b" dir)))))
      (unwind-protect
          (let ((key-a (let ((claude-code-ide-codex-events-program a))
                         (claude-code-ide-codex-events--trust-key)))
                (key-b (let ((claude-code-ide-codex-events-program b))
                         (claude-code-ide-codex-events--trust-key))))
            (should-not (equal key-a key-b))
            (should (string-search (file-truename a) key-a))
            ;; An update of the program changes its time
            (set-file-times a (time-add nil 100))
            (should-not (equal key-a (let ((claude-code-ide-codex-events-program a))
                                       (claude-code-ide-codex-events--trust-key))))
            (let ((claude-code-ide-codex-events-program "/nonexistent/cci-test-codex"))
              (should (string-search "@missing" (claude-code-ide-codex-events--trust-key)))))
        (delete-directory dir t)))))

(ert-deftest claude-code-ide-codex-events-test-managed-hooks-expire ()
  "A trusted result with managed hooks, which have no records, holds one minute."
  (claude-code-ide-codex-events-tests--with-codex
    (let* ((json (replace-regexp-in-string
                  "\"trustStatus\":\"trusted\"" "\"trustStatus\":\"managed\""
                  (claude-code-ide-codex-events-tests--hooks-json "trusted")))
           (result (claude-code-ide-codex-events--trust-result
                    (list :result (claude-code-ide-session-status--parse-json json :false))))
           (key (claude-code-ide-codex-events--trust-key)))
      (should (eq (plist-get result :status) 'trusted))
      (should-not (plist-get result :trust))
      (should (eq (plist-get result :cache) 'ttl))
      (clrhash claude-code-ide-codex-events--trust-cache)
      (claude-code-ide-codex-events--remember-trust key result)
      (should (claude-code-ide-codex-events--cached-trust key))
      ;; A minute later it is checked again
      (setf (plist-get (gethash key claude-code-ide-codex-events--trust-cache) :checked-at)
            (- (float-time) 61))
      (should-not (claude-code-ide-codex-events--cached-trust key))
      ;; An empty list of records never validates by itself
      (puthash key (list :status 'trusted :trust nil :cache 'records)
               claude-code-ide-codex-events--trust-cache)
      (should-not (claude-code-ide-codex-events--cached-trust key)))))

(ert-deftest claude-code-ide-codex-events-test-write-gets-full-time ()
  "After the question, the write and the re-check each get the full time limit.
A slow check that used up the limit before the question does not cut them."
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (let ((limit claude-code-ide-codex-events-trust-timeout)
          (timeouts nil)
          (call (symbol-function 'claude-code-ide-codex-events--server-call))
          (wait (symbol-function 'claude-code-ide-codex-events--wait-check)))
      ;; The check uses up the whole limit on the virtual clock
      (cl-letf (((symbol-function 'claude-code-ide-codex-events--wait-check)
                 (lambda (&rest args)
                   (prog1 (apply wait args) (claude-code-ide-tests--advance-clock limit))))
                ((symbol-function 'claude-code-ide-codex-events--server-call)
                 (lambda (server method params &optional timeout)
                   (push (cons method timeout) timeouts)
                   (funcall call server method params timeout))))
        (should (car (claude-code-ide-tests--call-with-clock
                      (lambda ()
                        (claude-code-ide-codex-events-tests--start "cci-test-slow-yes" t))))))
      (should (= asked 1))
      (should (equal (reverse timeouts)
                     (list (cons "config/batchWrite" limit) (cons "hooks/list" limit)))))))

(ert-deftest claude-code-ide-codex-events-test-prepare-trust-after-no ()
  "After a no in this Emacs, `claude-code-ide-codex-prepare-trust' starts nothing."
  (claude-code-ide-codex-events-tests--with-lazy-trust (dir "untrusted")
    (setq claude-code-ide-codex-events--declined (list (claude-code-ide-codex-events--trust-key)))
    (should-not (claude-code-ide-codex-prepare-trust))
    (should (= servers 0))
    (should (= asked 0))))

(ert-deftest claude-code-ide-codex-events-test-one-codex-config-reader ()
  "The Codex config path and its reader are the shared ones of the transcript file.
The reader gives nil for a missing, unreadable or unparsable file, and
the entries of a good one."
  (should-not (fboundp 'claude-code-ide-codex-events--config-file))
  (claude-code-ide-codex-events-tests--with-codex
    (let ((file (claude-code-ide-transcript--codex-config-file)))
      (should (string-prefix-p (expand-file-name "codex-home" registry-dir) file))
      (delete-file file)
      (should-not (claude-code-ide-transcript--codex-config-entries))
      (claude-code-ide-codex-events-tests--write-config "[[[ broken\n")
      (should-not (claude-code-ide-transcript--codex-config-entries))
      (claude-code-ide-codex-events-tests--write-config
       "[hooks.state.\"/<session-flags>/config.toml:stop:0:0\"]\ntrusted_hash = \"sha256:x\"\n")
      (should (equal (cdr (assoc '("hooks" "state" "/<session-flags>/config.toml:stop:0:0" "trusted_hash")
                                 (claude-code-ide-transcript--codex-config-entries)))
                     "sha256:x"))
      (set-file-modes file #o000)
      (unwind-protect
          (unless (file-readable-p file)
            (should-not (claude-code-ide-transcript--codex-config-entries)))
        (set-file-modes file #o600)))))

;;; The time limit of the hook script

(declare-function claude-code-ide-tests--held-lock-run "claude-code-ide-session-status-tests")

(defun claude-code-ide-codex-events-tests--script-env (dir id generation)
  "Return the environment of a Codex hook for the launch ID GENERATION in DIR."
  (list (concat "CCI_EVENTS_DIR=" dir) (concat "CCI_INSTANCE_ID=" id)
        (format "CCI_GENERATION=%d" generation) "CODEX_THREAD_ID"))

(ert-deftest claude-code-ide-codex-events-test-script-time-limit ()
  "A Codex hook whose lock stays held gives up after about the time limit.
Real time with a generous bound: the script is a shell process."
  (claude-code-ide-codex-events-tests--with-codex
    (let ((claude-code-ide-session-status-hook-time-limit 1))
      (claude-code-ide-codex-events--install-script)
      (let* ((dir (claude-code-ide-codex-events--private-directory
                   (claude-code-ide-codex-events--events-directory)))
             (result (claude-code-ide-tests--held-lock-run
                      (claude-code-ide-codex-events--script-file) '("Stop")
                      (expand-file-name ".cci-test-held.1.lock" dir)
                      (claude-code-ide-codex-events-tests--script-env dir "cci-test-held" 1))))
        (should (equal (butlast result) '(0 "")))
        (should (>= (nth 2 result) 0.9))
        (should (< (nth 2 result) 20))
        (should-not (directory-files dir nil claude-code-ide-codex-events--file-regexp))
        (should-not (directory-files dir nil "\\.in\\."))
        (should (string-match-p "Stop: no lock after"
                                (claude-code-ide-session-registry--file-string
                                 (expand-file-name "hook-errors.log" dir))))))))

(ert-deftest claude-code-ide-codex-events-test-script-dead-holder-and-writers ()
  "The Codex hook breaks the lock of a dead holder, and serves 20 parallel writers."
  (claude-code-ide-codex-events-tests--with-codex
    (claude-code-ide-codex-events--install-script)
    (let* ((dir (claude-code-ide-codex-events--private-directory
                 (claude-code-ide-codex-events--events-directory)))
           (script (claude-code-ide-codex-events--script-file))
           (lock (expand-file-name ".cci-test-dead.1.lock" dir)))
      ;; A holder that is not running
      (make-directory lock t)
      (with-temp-file (expand-file-name "pid" lock) (insert "999999\n"))
      (let ((process-environment (append (claude-code-ide-codex-events-tests--script-env
                                          dir "cci-test-dead" 1)
                                         process-environment)))
        (with-temp-buffer
          (insert "{}")
          (should (zerop (call-process-region (point-min) (point-max) "/bin/sh" nil nil nil
                                              script "Stop")))))
      (should (equal (directory-files dir nil "\\`cci-test-dead\\.")
                     '("cci-test-dead.1.00000001.Stop.json")))
      (should-not (file-exists-p lock))
      ;; 20 writers at the same time: all events, numbered without gaps
      (let ((process-environment (append (claude-code-ide-codex-events-tests--script-env
                                          dir "cci-test-many" 2)
                                         process-environment)))
        (with-temp-buffer
          (should (zerop (call-process
                          "/bin/sh" nil t nil "-c"
                          (format "i=0; while [ $i -lt 20 ]; do echo '{}' | /bin/sh %s Stop & i=$((i+1)); done; wait"
                                  (shell-quote-argument script)))))
          (should (equal (buffer-string) ""))))
      (should (equal (mapcar (lambda (file) (string-to-number (nth 2 (split-string file "\\."))))
                             (directory-files dir nil "\\`cci-test-many\\.2\\.[0-9]+\\.Stop\\.json\\'"))
                     (number-sequence 1 20))))))

(ert-deftest claude-code-ide-codex-events-test-script-limit-and-trust ()
  "The Codex hook definition carries the CLI timeout of the limit.
The command stays the same, but the timeout is limit + 5, so a new
limit changes the definition and its trust: the next interactive start
asks again.  The installed script holds the limit."
  (claude-code-ide-codex-events-tests--with-codex
    (let ((short (let ((claude-code-ide-session-status-hook-time-limit 3))
                   (list (claude-code-ide-codex-events--hook-args)
                         (claude-code-ide-codex-events--trust-key))))
          (long (let ((claude-code-ide-session-status-hook-time-limit 10))
                  (list (claude-code-ide-codex-events--hook-args)
                        (claude-code-ide-codex-events--trust-key)))))
      (should (cl-every (lambda (value) (string-suffix-p ",timeout=8}]}]" value))
                        (cl-remove "-c" (car short) :test #'equal)))
      (should (cl-every (lambda (value) (string-suffix-p ",timeout=15}]}]" value))
                        (cl-remove "-c" (car long) :test #'equal)))
      ;; The command is the same; the definition and the key are not
      (should (equal (mapcar (lambda (value) (replace-regexp-in-string ",timeout=[0-9]+" "" value))
                             (car short))
                     (mapcar (lambda (value) (replace-regexp-in-string ",timeout=[0-9]+" "" value))
                             (car long))))
      (should-not (equal (cadr short) (cadr long)))
      (let ((claude-code-ide-session-status-hook-time-limit 4))
        (let ((file (claude-code-ide-codex-events--install-script)))
          (should (string-match-p "^  limit=4$" (claude-code-ide-session-registry--file-string file)))
          (let ((claude-code-ide-session-status-hook-time-limit 10))
            (should-not (claude-code-ide-codex-events--script-ok-p file))
            (claude-code-ide-codex-events--install-script)
            (should (claude-code-ide-codex-events--script-ok-p file))))))))

;;; Usage limits of Codex 0.164.0

(defconst claude-code-ide-codex-events-tests--quota-texts
  '(;; The display texts of a usage limit in the Codex 0.164.0 binary;
    ;; the time after "try again at" is made up
    "You’ve hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at 3:05 PM."
    "You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 21st, 2026 9:00 AM."
    "You’ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at 9:00 AM."
    "You’ve hit your usage limit. To get more access now, send a request to your admin or try again at 9:00 AM."
    "Usage limit reached. You've reached your usage limit. Increase your limits to continue using codex."
    "Quota exceeded. Check your plan and billing details."
    "To use Codex with your ChatGPT plan, upgrade to Plus: https://chatgpt.com/explore/plus."
    "Your workspace is out of credits. Add credits to continue."
    "Your workspace is out of credits. Ask your workspace owner to refill in order to continue."
    "You hit your spend cap set in your workspace. Increase your spend cap to continue."
    "Your included usage is exhausted. Choose an option below to continue."
    ;; The server body of a usage limit, in case the hook gets it raw
    "{\"error\":{\"type\":\"usage_limit_reached\",\"message\":\"The usage limit has been reached\",\"plan_type\":\"plus\",\"resets_at\":1794960000}}"
    "{\"error\":{\"type\":\"usage_not_included\",\"message\":\"cci-test\"}}"
    "{\"rate_limit_reached_type\":\"workspace_member_usage_limit_reached\"}"
    "{\"rate_limit_reached_type\":\"workspace_owner_credits_depleted\"}")
  "Error texts of a Codex usage limit: each is `failed/quota-limit'.")

(defconst claude-code-ide-codex-events-tests--transient-texts
  '(;; Display texts of short limits and server trouble in the binary
    "exceeded retry limit, last status: 429 Too Many Requests"
    "Selected model is at capacity. Please try a different model."
    "We’re currently experiencing high demand, which may cause temporary errors."
    "Flex capacity unavailable."
    "{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'cci-test-no-such-model' model is not supported when using Codex with a ChatGPT account.\",\"code\":\"model_not_found\"}}"
    "{\"error\":{\"type\":\"rate_limit_exceeded\",\"message\":\"Rate limit reached for gpt-5.6-terra on tokens per min (TPM): Limit 30000, Used 29500. Please try again in 1.2s.\"}}"
    "{\"rate_limit_reached_type\":\"rate_limit_reached\"}")
  "Error texts of Codex that are `failed/error', not a quota limit.")

(ert-deftest claude-code-ide-codex-events-test-quota-texts-0164 ()
  "The usage-limit texts of Codex 0.164.0 are quota limits; short limits are not."
  (dolist (text claude-code-ide-codex-events-tests--quota-texts)
    (should (claude-code-ide-codex-events--quota-error-p text)))
  (dolist (text claude-code-ide-codex-events-tests--transient-texts)
    (should-not (claude-code-ide-codex-events--quota-error-p text)))
  ;; A failed model request of the hooks with the real text
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let ((instance (claude-code-ide-codex-events-tests--instance "cci-test-quota-0164" 1)))
          (claude-code-ide-codex-events--track instance)
          (claude-code-ide-codex-events-tests--feed
           "cci-test-quota-0164" 1
           (list '("UserPromptSubmit" "{}")
                 (list "PostModelRequest"
                       (json-encode `((status . "failed") (token_usage . nil)
                                      (error . ,(car claude-code-ide-codex-events-tests--quota-texts)))))))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(failed quota-limit nil)))
          (should (string-prefix-p "Quota limit: You’ve hit your usage limit"
                                   (claude-code-ide-codex-events--instance-detail instance 1000.0)))
          (claude-code-ide-codex-events-tests--feed
           "cci-test-quota-0164" 1
           (list '("UserPromptSubmit" "{}")
                 (list "PostModelRequest"
                       (json-encode `((status . "failed")
                                      (error . ,(car claude-code-ide-codex-events-tests--transient-texts)))))))
          (should (equal (claude-code-ide-codex-events-tests--state instance) '(failed error nil))))
      (claude-code-ide-codex-events-tests--kill-instances))))

(ert-deftest claude-code-ide-codex-events-test-error-kinds ()
  "The kinds of the alist decide; another kind, or none, leaves it to the text."
  (should (equal (claude-code-ide-codex-events--error-kind "usage_limit_exceeded") "usage_limit_exceeded"))
  (should (equal (claude-code-ide-codex-events--error-kind '((http_connection_failed (http_status_code . 429))))
                 "http_connection_failed"))
  (should-not (claude-code-ide-codex-events--error-kind nil))
  (should-not (claude-code-ide-codex-events--error-kind ""))
  (should-not (claude-code-ide-codex-events--error-kind 42))
  (should (eq (claude-code-ide-codex-events--quota-failure-p "usage_limit_exceeded" "") t))
  ;; The user's answer: a session budget is a quota limit
  (should (eq (claude-code-ide-codex-events--failure-kind "session_budget_exceeded" nil) 'quota-limit))
  (should (eq (claude-code-ide-codex-events--failure-kind "usage_not_included" nil) 'not-included))
  ;; The rollout writes snake case only
  (should-not (claude-code-ide-codex-events--quota-failure-p "usageLimitExceeded" nil))
  (should-not (claude-code-ide-codex-events--quota-failure-p
               "rate_limit_exceeded" "exceeded retry limit, last status: 429 Too Many Requests"))
  (should-not (claude-code-ide-codex-events--quota-failure-p
               '((response_too_many_failed_attempts (http_status_code . 429))) "exceeded retry limit"))
  (should-not (claude-code-ide-codex-events--quota-failure-p "server_overloaded" nil))
  ;; A known short kind wins over a quota text
  (should-not (claude-code-ide-codex-events--quota-failure-p
               "rate_limit_exceeded" (car claude-code-ide-codex-events-tests--quota-texts)))
  (should-not (claude-code-ide-codex-events--quota-failure-p
               "server_overloaded" "You exceeded your current quota"))
  ;; Another kind: the text decides
  (should (claude-code-ide-codex-events--quota-failure-p
           "other" "Quota exceeded. Check your plan and billing details."))
  (should-not (claude-code-ide-codex-events--quota-failure-p "other" "model_not_found")))

(ert-deftest claude-code-ide-codex-events-test-error-kind-states-option ()
  "`claude-code-ide-codex-events-error-kind-states' maps each kind to its state."
  (let ((claude-code-ide-codex-events-error-kind-states
         '(("rate_limit_exceeded" . quota-limit) ("usage_limit_exceeded" . error))))
    (should (eq (claude-code-ide-codex-events--failure-kind "rate_limit_exceeded" "cci-test") 'quota-limit))
    (should (eq (claude-code-ide-codex-events--failure-kind "usage_limit_exceeded"
                                                            (car claude-code-ide-codex-events-tests--quota-texts))
                'error))
    ;; A kind that is no longer in the list: the text decides
    (should (eq (claude-code-ide-codex-events--failure-kind "server_overloaded" "cci-test") 'error))
    (should (eq (claude-code-ide-codex-events--failure-kind
                 "server_overloaded" (car claude-code-ide-codex-events-tests--quota-texts))
                'quota-limit)))
  (let ((claude-code-ide-codex-events-not-included-regexp "cci-test-not-included"))
    (should (eq (claude-code-ide-codex-events--failure-kind nil "cci-test-not-included") 'not-included))
    (should (eq (claude-code-ide-codex-events--failure-kind
                 nil "To use Codex with your ChatGPT plan, upgrade to Plus: https://chatgpt.com/explore/plus.")
                'quota-limit))))

(ert-deftest claude-code-ide-codex-events-test-short-limits-are-no-quota ()
  "Texts of per-minute limits from other providers are never a quota limit."
  (dolist (text '(;; Gemini
                  "Quota exceeded for quota metric 'Generate Content API requests per minute' and limit 'GenerateContent request limit per minute' of service 'generativelanguage.googleapis.com' for consumer 'project_number:000000'."
                  "429 RESOURCE_EXHAUSTED. Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 15, model: gemini-2.0-flash. Please retry in 41.2s."
                  ;; Azure OpenAI
                  "Requests to the ChatCompletions_Create Operation under Azure OpenAI API version 2024-02-01 have exceeded token rate limit of your current OpenAI S0 pricing tier. Please retry after 6 seconds."
                  "Your quota for this deployment is exhausted for now (RPM). Try again in 3 seconds."
                  ;; OpenAI
                  "Rate limit reached for gpt-5.6-terra in organization org-cci on tokens per min (TPM): Limit 30000, Used 29500. Please try again in 1.2s."))
    (should-not (claude-code-ide-session-status--quota-text-p text))
    (should-not (claude-code-ide-codex-events--quota-failure-p "other" text)))
  ;; A daily quota and a usage limit with a time stay quota limits
  (should (claude-code-ide-session-status--quota-text-p
           "Quota exceeded for quota metric 'Generate Content API requests per day'"))
  (should (claude-code-ide-session-status--quota-text-p
           "You exceeded your current quota, please check your plan and billing details."))
  (should (claude-code-ide-session-status--quota-text-p
           "You’ve hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at 3:05 PM.")))

;;; The rollout file of an instance without hooks

(defconst claude-code-ide-codex-events-tests--native "cci-test-0011-0000-4000-8000-000000000000"
  "The synthetic conversation ID of the rollout tests.")

(defun claude-code-ide-codex-events-tests--rollout-record (type payload)
  "Return one line of a rollout file: a record of TYPE with PAYLOAD."
  (concat (json-encode `((timestamp . "2026-11-20T10:00:00.000Z") (type . ,type) (payload . ,payload)))
          "\n"))

(defun claude-code-ide-codex-events-tests--meta (&optional native)
  "Return the `session_meta' line of the conversation NATIVE."
  (claude-code-ide-codex-events-tests--rollout-record
   "session_meta" `((id . ,(or native claude-code-ide-codex-events-tests--native))
                    (cwd . "/tmp/cci-test-codex-proj/") (cli_version . "0.164.0"))))

(defun claude-code-ide-codex-events-tests--started (turn time)
  "Return the `task_started' line of TURN at TIME."
  (claude-code-ide-codex-events-tests--rollout-record
   "event_msg" `((type . "task_started") (turn_id . ,turn) (started_at . ,time)
                 (model_context_window . 258400) (collaboration_mode_kind . "default"))))

(defun claude-code-ide-codex-events-tests--complete (turn time &optional error)
  "Return the `task_complete' line of TURN at TIME, with the turn ERROR."
  (claude-code-ide-codex-events-tests--rollout-record
   "event_msg" `((type . "task_complete") (turn_id . ,turn) (last_agent_message . "cci-test reply")
                 (error . ,error) (completed_at . ,time) (duration_ms . 2537))))

(defun claude-code-ide-codex-events-tests--aborted (turn time)
  "Return the `turn_aborted' line of TURN at TIME."
  (claude-code-ide-codex-events-tests--rollout-record
   "event_msg" `((type . "turn_aborted") (turn_id . ,turn) (reason . "interrupted")
                 (completed_at . ,time))))

(defun claude-code-ide-codex-events-tests--append (file &rest lines)
  "Append LINES to the rollout FILE."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (apply #'concat lines) nil file t 'silent)))

(defmacro claude-code-ide-codex-events-tests--with-rollout (&rest body)
  "Run BODY with the Codex instance `instance' without hooks, and `file'.
`file' is the rollout file of the instance.  A fake Codex provider
gives `file' as the transcript of the native ID of the tests, and
`unknown' for another; `calls' counts its calls.  The file is in the
report folder; BODY writes it."
  (declare (indent 0))
  `(claude-code-ide-codex-events-tests--with-codex
     (let* ((native claude-code-ide-codex-events-tests--native)
            (file (expand-file-name (format "rollout-2026-11-20T10-00-00-%s.jsonl" native) registry-dir))
            (calls 0)
            (claude-code-ide-codex-events--rollout-cache (make-hash-table :test 'eq :weakness 'key))
            (claude-code-ide-codex-events--state-cache (make-hash-table :test 'eq :weakness 'key))
            (claude-code-ide-provider--registry
             (list (cons 'codex
                         (claude-code-ide-provider-create
                          :name 'codex
                          :transcript (lambda (instance what)
                                        (cl-incf calls)
                                        (should (eq what 'file))
                                        (if (equal (claude-code-ide-instance-native-id instance) native)
                                            file
                                          'unknown))))))
            (instance (claude-code-ide-codex-events-tests--instance "cci-test-rollout" 1)))
       (setf (claude-code-ide-instance-native-id instance) native)
       (ignore calls)
       (unwind-protect
           (progn ,@body)
         (claude-code-ide-codex-events-tests--kill-instances)))))

(defvar claude-code-ide-codex-events-tests--now 2000.0
  "The time of the last state call of the rollout tests.")

(defun claude-code-ide-codex-events-tests--full-state (instance)
  "Return (STATE REASON GUESS SOURCE SINCE) of INSTANCE at a new time."
  (let ((state (claude-code-ide-instance-state
                instance (cl-incf claude-code-ide-codex-events-tests--now))))
    (list (plist-get state :state) (plist-get state :reason) (plist-get state :guess)
          (plist-get state :source) (plist-get state :since))))

(defun claude-code-ide-codex-events-tests--detail (instance)
  "Return the detail of INSTANCE at a new time."
  (claude-code-ide-codex-events--instance-detail
   instance (cl-incf claude-code-ide-codex-events-tests--now)))

(defun claude-code-ide-codex-events-tests--touch (file seconds)
  "Set the modification time of FILE to SECONDS (a float time)."
  (set-file-times file (seconds-to-time seconds)))

(ert-deftest claude-code-ide-codex-events-test-rollout-states ()
  "The last turn record of the rollout gives the state, always as a guess."
  (claude-code-ide-codex-events-tests--with-rollout
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--meta))
    ;; No turn yet
    (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(idle nil t rollout nil)))
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--started "t1" 1000))
    (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(working nil t rollout 1000.0)))
    (should (equal (claude-code-ide-codex-events-tests--detail instance)
                   "From rollout: a turn runs · No status hooks"))
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--complete "t1" 1010))
    (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(idle nil t rollout 1010.0)))
    ;; An interrupt
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--started "t2" 1020)
                                                (claude-code-ide-codex-events-tests--aborted "t2" 1025))
    (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(idle nil t rollout 1025.0)))
    (should (string-prefix-p "From rollout: interrupted" (claude-code-ide-codex-events-tests--detail instance)))
    ;; A usage limit, by its error kind
    (claude-code-ide-codex-events-tests--append
     file (claude-code-ide-codex-events-tests--started "t3" 1030)
     (claude-code-ide-codex-events-tests--complete
      "t3" 1031 `((message . ,(car claude-code-ide-codex-events-tests--quota-texts))
                  (codex_error_info . "usage_limit_exceeded"))))
    (should (equal (claude-code-ide-codex-events-tests--full-state instance)
                   '(failed quota-limit t rollout 1031.0)))
    (should (string-prefix-p "From rollout: Quota limit: You’ve hit your usage limit"
                             (claude-code-ide-codex-events-tests--detail instance)))
    ;; A session budget is a quota limit too (the user's answer)
    (claude-code-ide-codex-events-tests--append
     file (claude-code-ide-codex-events-tests--started "t3b" 1032)
     (claude-code-ide-codex-events-tests--complete
      "t3b" 1033 '((message . "cci-test budget") (codex_error_info . "session_budget_exceeded"))))
    (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 2) '(failed quota-limit)))
    ;; A rate limit after the retries: an error
    (claude-code-ide-codex-events-tests--append
     file (claude-code-ide-codex-events-tests--started "t4" 1040)
     (claude-code-ide-codex-events-tests--complete
      "t4" 1041 '((message . "exceeded retry limit, last status: 429 Too Many Requests")
                  (codex_error_info (response_too_many_failed_attempts (http_status_code . 429))))))
    (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(failed error t rollout 1041.0)))
    (should (string-match-p "Error: exceeded retry limit" (claude-code-ide-codex-events-tests--detail instance)))
    ;; The model_not_found record of a real Codex 0.164.0 run
    (claude-code-ide-codex-events-tests--append
     file (claude-code-ide-codex-events-tests--started "t5" 1050)
     (claude-code-ide-codex-events-tests--complete
      "t5" 1051 `((message . ,(nth 4 claude-code-ide-codex-events-tests--transient-texts))
                  (codex_error_info . "other"))))
    (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 2) '(failed error)))
    ;; The next prompt starts a turn
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--started "t6" 1060))
    (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(working nil t rollout 1060.0)))
    (should (= (hash-table-count claude-code-ide-codex-events--rollout-cache) 1))))

(ert-deftest claude-code-ide-codex-events-test-rollout-error-without-text ()
  "A turn error without a kind and a message is \"unknown error\"; a kind alone shows."
  (claude-code-ide-codex-events-tests--with-rollout
    (claude-code-ide-codex-events-tests--append
     file (claude-code-ide-codex-events-tests--meta)
     (claude-code-ide-codex-events-tests--started "t1" 1000)
     (claude-code-ide-codex-events-tests--complete "t1" 1001 '((message . "") (codex_error_info . nil))))
    (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 2) '(failed error)))
    (should (equal (claude-code-ide-codex-events-tests--detail instance)
                   "From rollout: Error: unknown error · No status hooks"))
    (claude-code-ide-codex-events-tests--append
     file (claude-code-ide-codex-events-tests--started "t2" 1010)
     (claude-code-ide-codex-events-tests--complete "t2" 1011 '((message . " ") (codex_error_info . "server_overloaded"))))
    (should (string-prefix-p "From rollout: Error: server_overloaded"
                             (claude-code-ide-codex-events-tests--detail instance)))))

(ert-deftest claude-code-ide-codex-events-test-rollout-turn-of-a-killed-process ()
  "A turn that started before the launch did not end: it is no running turn."
  (claude-code-ide-codex-events-tests--with-rollout
    (setf (claude-code-ide-instance-process-start-time instance) 1500.0)
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--meta)
                                                (claude-code-ide-codex-events-tests--started "t1" 1000))
    (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(idle nil t rollout nil)))
    (should (string-prefix-p "From rollout: a turn of an earlier run did not end"
                             (claude-code-ide-codex-events-tests--detail instance)))
    ;; A turn of this launch runs
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--started "t2" 1500))
    (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(working nil t rollout 1500.0)))
    ;; With a launch record, its time counts
    (let ((launch (claude-code-ide-codex-events--track instance)))
      (setf (claude-code-ide-codex-events--launch-hooks launch) nil
            (claude-code-ide-codex-events--launch-registered launch) 1600.0)
      (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'idle)))))

(defun claude-code-ide-codex-events-tests--ret (buffer)
  "Run the command hooks of a RET in the terminal BUFFER, as a key there does."
  (with-current-buffer buffer
    (let ((last-command-event ?\r))
      (run-hooks 'post-command-hook))))

(defun claude-code-ide-codex-events-tests--rollout-name (time native)
  "Return the name of the rollout of NATIVE that Codex makes at the float TIME."
  (format "rollout-%s-%s.jsonl" (format-time-string "%Y-%m-%dT%H-%M-%S" (seconds-to-time time)) native))

(defun claude-code-ide-codex-events-tests--package-hooks (buffer)
  "Return the functions of this package in the local `post-command-hook' of BUFFER."
  (with-current-buffer buffer
    (cl-remove-if-not (lambda (fn)
                        (and (symbolp fn) (string-prefix-p "claude-code-ide-" (symbol-name fn))))
                      post-command-hook)))

(ert-deftest claude-code-ide-codex-events-test-rollout-input-without-record ()
  "A RET that Codex answers without a rollout record changes nothing.
This is a RET on an empty prompt, a slash command such as /status, or
the answer to an approval while the tool runs for a long time.  Emacs
does not watch the keys of the terminal."
  (claude-code-ide-codex-events-tests--with-rollout
    (let* ((buffer (claude-code-ide-instance-buffer instance))
           (now (float-time)))
      (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--meta)
                                                  (claude-code-ide-codex-events-tests--complete "t1" 1000))
      (claude-code-ide-codex-events-tests--touch file (- now 100))
      (should (eq (plist-get (claude-code-ide-instance-state instance now) :state) 'idle))
      (claude-code-ide-codex-events-tests--ret buffer)
      ;; A minute later, no record came: the rollout state stays
      (let ((state (claude-code-ide-instance-state instance (+ now 60))))
        (should (equal (list (plist-get state :state) (plist-get state :guess) (plist-get state :source))
                       '(idle t rollout))))
      (should-not (claude-code-ide-codex-events-tests--package-hooks buffer)))))

(ert-deftest claude-code-ide-codex-events-test-rollout-follows-known-conversation ()
  "Without hooks, the state follows the rollout of the known native ID, also after /new.
This is a limit of 1.2.0: after /new or a fork in the terminal, Codex
makes a rollout of another conversation, but the native ID of the
instance stays.  The state then comes from the old conversation, as a
guess, until Emacs learns the new native ID."
  (claude-code-ide-codex-events-tests--with-rollout
    (let* ((buffer (claude-code-ide-instance-buffer instance))
           (now (float-time))
           (new-id "cci-test-0033-0000-4000-8000-000000000000"))
      (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--meta)
                                                  (claude-code-ide-codex-events-tests--complete "t1" 1000))
      (claude-code-ide-codex-events-tests--touch file (- now 100))
      (should (eq (plist-get (claude-code-ide-instance-state instance now) :state) 'idle))
      ;; /new and RET: Codex starts a rollout of another conversation in the same folder
      (claude-code-ide-codex-events-tests--ret buffer)
      (claude-code-ide-codex-events-tests--append
       (expand-file-name (claude-code-ide-codex-events-tests--rollout-name (+ now 1) new-id) registry-dir)
       (claude-code-ide-codex-events-tests--meta new-id)
       (claude-code-ide-codex-events-tests--started "n1" 1500))
      (let ((state (claude-code-ide-instance-state instance (+ now 2))))
        (should (equal (list (plist-get state :state) (plist-get state :reason)
                             (plist-get state :guess) (plist-get state :source))
                       '(idle nil t rollout))))
      (should (equal (claude-code-ide-codex-events--instance-detail instance (+ now 3))
                     "From rollout: turn ended · No status hooks")))))

(ert-deftest claude-code-ide-codex-events-test-rollout-session-record-without-newline ()
  "A whole session record at the end of the file, without its newline, is not used yet."
  (claude-code-ide-codex-events-tests--with-rollout
    (let ((meta (claude-code-ide-codex-events-tests--meta)))
      ;; The JSON is complete, but Codex has not written the newline yet
      (claude-code-ide-codex-events-tests--append file (substring meta 0 -1))
      (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 4)
                     '(disconnected untracked nil nil)))
      (should (equal (claude-code-ide-codex-events-tests--detail instance)
                     "No status hooks; rollout file not readable yet"))
      ;; The newline and a turn come
      (claude-code-ide-codex-events-tests--append file "\n" (claude-code-ide-codex-events-tests--started "t1" 1000))
      (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(working nil t rollout 1000.0))))))

(ert-deftest claude-code-ide-codex-events-test-rollout-read-on-change ()
  "The rollout is read only when it changes, from the end of the last read, never written."
  (claude-code-ide-codex-events-tests--with-rollout
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--meta)
                                                (claude-code-ide-codex-events-tests--started "t1" 1000))
    (let ((reads nil)
          (original (symbol-function 'insert-file-contents-literally)))
      (cl-letf (((symbol-function 'insert-file-contents-literally)
                 (lambda (name &optional visit beg end replace)
                   (when (equal name file) (push (cons beg end) reads))
                   (funcall original name visit beg end replace))))
        (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'working))
        (should reads)
        (let ((size (file-attribute-size (file-attributes file)))
              (time (file-attribute-modification-time (file-attributes file))))
          ;; No change: no read
          (setq reads nil)
          (dotimes (_ 3)
            (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'working)))
          (should-not reads)
          ;; The file grows: only the new bytes are read
          (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--complete "t1" 1010))
          (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'idle))
          (should reads)
          (should (cl-every (lambda (read) (>= (car read) size)) reads))
          ;; Emacs never writes the file
          (setq size (file-attribute-size (file-attributes file))
                time (file-attribute-modification-time (file-attributes file)))
          (dotimes (_ 3) (claude-code-ide-codex-events-tests--full-state instance))
          (should (= size (file-attribute-size (file-attributes file))))
          (should (equal time (file-attribute-modification-time (file-attributes file))))
          ;; A file that shrank is read again from the start
          (setq reads nil)
          (delete-file file)
          (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--meta)
                                                      (claude-code-ide-codex-events-tests--started "t9" 1100))
          (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(working nil t rollout 1100.0)))
          (should (assq 0 reads)))))))

(defun claude-code-ide-codex-events-tests--same-size-line (line size)
  "Return LINE, a JSON record and its newline, padded to SIZE bytes."
  (let ((pad (- size (string-bytes line))))
    (should (>= pad 0))
    (concat (substring line 0 -2) (make-string pad ? ) "}\n")))

(ert-deftest claude-code-ide-codex-events-test-rollout-rewritten-in-place ()
  "A new time with the same size, or a new inode, checks the owner and reads again."
  (claude-code-ide-codex-events-tests--with-rollout
    (let* ((started (claude-code-ide-codex-events-tests--started "t1" 1000))
           (complete (claude-code-ide-codex-events-tests--complete "t1" 1010))
           (size (max (string-bytes started) (string-bytes complete))))
      (claude-code-ide-codex-events-tests--append
       file (claude-code-ide-codex-events-tests--meta)
       (claude-code-ide-codex-events-tests--same-size-line started size))
      (claude-code-ide-codex-events-tests--touch file 1000.0)
      (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'working))
      ;; The same size, another last record, a new time
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-buffer
          (insert (claude-code-ide-codex-events-tests--meta)
                  (claude-code-ide-codex-events-tests--same-size-line complete size))
          (write-region nil nil file nil 'silent)))
      (claude-code-ide-codex-events-tests--touch file 1001.0)
      (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(idle nil t rollout 1010.0)))
      ;; The same size again, now of another conversation
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-buffer
          (insert (claude-code-ide-codex-events-tests--meta "cci-test-0012-0000-4000-8000-000000000000")
                  (claude-code-ide-codex-events-tests--same-size-line complete size))
          (write-region nil nil file nil 'silent)))
      (claude-code-ide-codex-events-tests--touch file 1002.0)
      (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 2)
                     '(disconnected untracked)))
      ;; A larger file of the conversation with a new inode: read from the start
      (let ((new (concat file ".new")))
        (let ((coding-system-for-write 'utf-8-unix))
          (with-temp-file new
            (insert (claude-code-ide-codex-events-tests--meta)
                    (claude-code-ide-codex-events-tests--started "t7" 1070)
                    (claude-code-ide-codex-events-tests--rollout-record
                     "response_item" '((type . "message") (text . "cci-test padding padding padding"))))))
        (rename-file new file t))
      (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(working nil t rollout 1070.0)))
      ;; A larger file of another conversation with a new inode
      (let ((new (concat file ".new")))
        (let ((coding-system-for-write 'utf-8-unix))
          (with-temp-file new
            (insert (claude-code-ide-codex-events-tests--meta "cci-test-0012-0000-4000-8000-000000000000")
                    (claude-code-ide-codex-events-tests--started "t8" 1080)
                    (claude-code-ide-codex-events-tests--rollout-record
                     "response_item" `((type . "message") (text . ,(make-string 300 ?p)))))))
        (rename-file new file t))
      (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 2)
                     '(disconnected untracked))))))

(ert-deftest claude-code-ide-codex-events-test-rollout-partial-line ()
  "A line that Codex still writes counts only when its newline is there."
  (claude-code-ide-codex-events-tests--with-rollout
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--meta)
                                                (claude-code-ide-codex-events-tests--started "t1" 1000)
                                                (claude-code-ide-codex-events-tests--complete "t1" 1010))
    (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'idle))
    (let ((line (claude-code-ide-codex-events-tests--started "t2" 1020)))
      (claude-code-ide-codex-events-tests--append file (substring line 0 40))
      (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'idle))
      (claude-code-ide-codex-events-tests--append file (substring line 40 -1))
      (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'idle))
      (claude-code-ide-codex-events-tests--append file "\n")
      (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(working nil t rollout 1020.0))))))

(ert-deftest claude-code-ide-codex-events-test-rollout-partial-session-record ()
  "A session record without its newline yet is \"not readable yet\", not another conversation."
  (claude-code-ide-codex-events-tests--with-rollout
    (let ((meta (claude-code-ide-codex-events-tests--meta)))
      (claude-code-ide-codex-events-tests--append file (substring meta 0 30))
      (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 4)
                     '(disconnected untracked nil nil)))
      (should (equal (claude-code-ide-codex-events-tests--detail instance)
                     "No status hooks; rollout file not readable yet"))
      (should-not (plist-get (gethash instance claude-code-ide-codex-events--rollout-cache) :owner))
      ;; Codex ends the line: the file is of the conversation
      (claude-code-ide-codex-events-tests--append file (substring meta 30)
                                                  (claude-code-ide-codex-events-tests--started "t1" 1000))
      (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(working nil t rollout 1000.0))))))

(ert-deftest claude-code-ide-codex-events-test-rollout-small-chunks ()
  "Lines longer than a chunk, look-alike records and over-long lines are handled."
  (claude-code-ide-codex-events-tests--with-rollout
    (let ((claude-code-ide-codex-events--rollout-chunk 37)
          (claude-code-ide-codex-events--rollout-line-limit 300)
          (text (make-string 200 ?x)))
      (claude-code-ide-codex-events-tests--append
       file (claude-code-ide-codex-events-tests--meta)
       (claude-code-ide-codex-events-tests--started "t1" 1000)
       ;; The text of a message holds a look-alike, escaped in its string
       (claude-code-ide-codex-events-tests--rollout-record
        "response_item" `((type . "message") (text . ,(concat "\"type\":\"task_complete\" é " text))))
       ;; Another record type with a turn payload type is no turn record
       (claude-code-ide-codex-events-tests--rollout-record
        "response_item" `((type . "task_complete") (text . ,text))))
      (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(working nil t rollout 1000.0)))
      ;; A line above the limit is skipped; the record before it counts
      (claude-code-ide-codex-events-tests--append
       file (claude-code-ide-codex-events-tests--complete "t1" 1010)
       (claude-code-ide-codex-events-tests--rollout-record
        "response_item" `((type . "message") (text . ,(make-string 2000 ?y)))))
      (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(idle nil t rollout 1010.0))))))

(ert-deftest claude-code-ide-codex-events-test-rollout-of-this-conversation-only ()
  "Only the rollout of the conversation of the instance gives a state."
  (claude-code-ide-codex-events-tests--with-rollout
    ;; The file is not there yet; the detail says once that hooks are missing
    (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 4)
                   '(disconnected untracked nil nil)))
    (should (equal (claude-code-ide-codex-events-tests--detail instance)
                   "No status hooks; rollout file not readable"))
    ;; A file whose session record is of another conversation
    (claude-code-ide-codex-events-tests--append
     file (claude-code-ide-codex-events-tests--meta "cci-test-0012-0000-4000-8000-000000000000")
     (claude-code-ide-codex-events-tests--started "t1" 1000))
    (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 4)
                   '(disconnected untracked nil nil)))
    (should (equal (claude-code-ide-codex-events-tests--detail instance)
                   "No status hooks; the rollout file is of another conversation"))
    (delete-file file)
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--meta)
                                                (claude-code-ide-codex-events-tests--started "t1" 1000))
    (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'working))
    ;; Another conversation of the instance (no rollout known): no state of the old one
    (setf (claude-code-ide-instance-native-id instance) "cci-test-0013-0000-4000-8000-000000000000")
    (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(disconnected untracked nil nil nil)))
    (should (equal (claude-code-ide-codex-events-tests--detail instance) "No status hooks"))
    ;; An unknown conversation: the provider is not asked
    (setf (claude-code-ide-instance-native-id instance) 'unknown)
    (setq calls 0)
    (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 2) '(disconnected untracked)))
    (should (= calls 0))
    (setf (claude-code-ide-instance-native-id instance) native)
    (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'working))
    ;; No transcript operation, no provider, or an error
    (dolist (registry (list (list (cons 'codex (claude-code-ide-provider-create :name 'codex)))
                            nil
                            (list (cons 'codex (claude-code-ide-provider-create
                                                :name 'codex
                                                :transcript (lambda (&rest _) (error "cci-test failure")))))))
      (let ((claude-code-ide-provider--registry registry))
        (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 4)
                       '(disconnected untracked nil nil)))))))

(ert-deftest claude-code-ide-codex-events-test-rollout-after-hooks-and-screen ()
  "Hooks come first, then a dialog on the screen, then the rollout; each names its source."
  (claude-code-ide-codex-events-tests--with-rollout
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--meta)
                                                (claude-code-ide-codex-events-tests--started "t1" 1000))
    (let ((launch (claude-code-ide-codex-events--track instance)))
      (should (claude-code-ide-codex-events--launch-hooks launch))
      (claude-code-ide-codex-events-tests--feed "cci-test-rollout" 1 '(("SessionStart" "{}") ("Stop" "{}")))
      (setq calls 0)
      (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 4) '(idle nil nil hooks)))
      (should (= calls 0))
      ;; A launch without hooks: the rollout, with the trust problem in the detail
      (setf (claude-code-ide-codex-events--launch-hooks launch) nil
            (claude-code-ide-codex-events--launch-registered launch) 900.0
            (claude-code-ide-codex-events--launch-trust-detail launch) "cci-test: hooks not trusted")
      (should (equal (claude-code-ide-codex-events-tests--full-state instance) '(working nil t rollout 1000.0)))
      (should (equal (claude-code-ide-codex-events-tests--detail instance)
                     "From rollout: a turn runs · cci-test: hooks not trusted"))
      ;; A dialog on the screen of a launch without hooks
      (setf (claude-code-ide-codex-events--launch-dialog launch) 'folder-trust)
      (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 4)
                     '(waiting-for-user dialog nil screen)))
      ;; The snapshot names the source
      (setf (claude-code-ide-codex-events--launch-dialog launch) nil)
      (should (claude-code-ide-session-status--write-snapshot t (cl-incf claude-code-ide-codex-events-tests--now)))
      (let ((record (car (alist-get 'instances (claude-code-ide-codex-events-tests--read-snapshot)))))
        (should (equal (alist-get 'source record) "rollout"))
        (should (equal (alist-get 'state record) "working"))
        (should (eq (alist-get 'guess record) t)))
      ;; No launch record and no known conversation: UNTRACKED, without a source
      (remhash "cci-test-rollout" claude-code-ide-codex-events--launches)
      (setf (claude-code-ide-instance-native-id instance) 'unknown)
      (should (claude-code-ide-session-status--write-snapshot t (cl-incf claude-code-ide-codex-events-tests--now)))
      (let ((record (car (alist-get 'instances (claude-code-ide-codex-events-tests--read-snapshot)))))
        (should (assq 'source record))
        (should (null (alist-get 'source record)))
        (should (equal (alist-get 'reason record) "untracked"))
        (should (equal (alist-get 'detail record) "No status hooks"))))))

(ert-deftest claude-code-ide-codex-events-test-rollout-through-the-codex-provider ()
  "The transcript operation of the real Codex provider finds the rollout of the fallback."
  (claude-code-ide-codex-events-tests--with-codex
    (let* ((claude-code-ide-codex--rollout-cache (make-hash-table :test 'equal))
           (claude-code-ide-codex-events--rollout-cache (make-hash-table :test 'eq :weakness 'key))
           (claude-code-ide-codex-events--state-cache (make-hash-table :test 'eq :weakness 'key))
           (native "cc1e7e57-0000-4000-8000-0000000000a1")
           (home (getenv "CODEX_HOME"))
           (dir (expand-file-name "sessions/2026/11/20/" home))
           (file (expand-file-name (format "rollout-2026-11-20T10-00-00-%s.jsonl" native) dir))
           (instance (claude-code-ide-codex-events-tests--instance "cci-test-provider" 1)))
      (unwind-protect
          (progn
            ;; The Codex home of the test, never ~/.codex
            (should (string-prefix-p (file-name-as-directory (expand-file-name registry-dir))
                                     (expand-file-name home)))
            (should (claude-code-ide-provider-supports-p (claude-code-ide-get-provider 'codex) 'transcript))
            (setf (claude-code-ide-instance-native-id instance) native)
            ;; No rollout yet: no state from it
            (should (equal (claude-code-ide-codex-events-tests--full-state instance)
                           '(disconnected untracked nil nil nil)))
            (make-directory dir t)
            (claude-code-ide-codex-events-tests--append
             file (claude-code-ide-codex-events-tests--meta native)
             (claude-code-ide-codex-events-tests--started "t1" 1000))
            ;; The provider keeps a miss for some seconds
            (clrhash claude-code-ide-codex--rollout-cache)
            (should (equal (claude-code-ide-provider-call 'codex 'transcript instance 'file) file))
            (should (equal (claude-code-ide-codex-events-tests--full-state instance)
                           '(working nil t rollout 1000.0)))
            (claude-code-ide-codex-events-tests--append
             file (claude-code-ide-codex-events-tests--complete
                   "t1" 1010 `((message . ,(car claude-code-ide-codex-events-tests--quota-texts))
                               (codex_error_info . "usage_limit_exceeded"))))
            (should (equal (claude-code-ide-codex-events-tests--full-state instance)
                           '(failed quota-limit t rollout 1010.0)))
            ;; Another conversation of the instance has no rollout: no state of the old one
            (setf (claude-code-ide-instance-native-id instance) "cc1e7e57-0000-4000-8000-0000000000a2")
            (should (equal (seq-take (claude-code-ide-codex-events-tests--full-state instance) 4)
                           '(disconnected untracked nil nil))))
        (claude-code-ide-codex-events-tests--kill-instances)))))

(ert-deftest claude-code-ide-codex-events-test-rollout-relative-codex-home ()
  "A relative CODEX_HOME is found from the folder of the instance, as Codex finds it."
  (claude-code-ide-codex-events-tests--with-codex
    (let* ((claude-code-ide-codex--rollout-cache (make-hash-table :test 'equal))
           (claude-code-ide-codex-events--rollout-cache (make-hash-table :test 'eq :weakness 'key))
           (claude-code-ide-codex-events--state-cache (make-hash-table :test 'eq :weakness 'key))
           (project (file-name-as-directory (expand-file-name "cci-test-project" registry-dir)))
           (process-environment (cons "CODEX_HOME=cci-test-codex-home" process-environment))
           (native "cc1e7e57-0000-4000-8000-0000000000b1")
           (dir (expand-file-name "cci-test-codex-home/sessions/2026/11/20/" project))
           (file (expand-file-name (format "rollout-2026-11-20T10-00-00-%s.jsonl" native) dir))
           (instance (claude-code-ide-codex-events-tests--instance "cci-test-relative" 1)))
      (unwind-protect
          (progn
            (make-directory dir t)
            (claude-code-ide-codex-events-tests--append
             file (claude-code-ide-codex-events-tests--meta native)
             (claude-code-ide-codex-events-tests--started "t1" 1000))
            (setf (claude-code-ide-instance-native-id instance) native
                  (claude-code-ide-instance-project-root instance) project)
            (should (equal (claude-code-ide-codex-events-tests--full-state instance)
                           '(working nil t rollout 1000.0))))
        (claude-code-ide-codex-events-tests--kill-instances)))))

(ert-deftest claude-code-ide-codex-events-test-shared-helpers ()
  "The rollout reader uses the transcript parsers; both fallbacks share one memo helper."
  (claude-code-ide-codex-events-tests--with-rollout
    (claude-code-ide-codex-events-tests--append file (claude-code-ide-codex-events-tests--meta)
                                                (claude-code-ide-codex-events-tests--started "t1" 1000))
    (let ((meta 0) (parse 0) (memo nil)
          (original-meta (symbol-function 'claude-code-ide-transcript-codex-meta))
          (original-parse (symbol-function 'claude-code-ide-transcript--parse-line))
          (original-memo (symbol-function 'claude-code-ide-session-status--once-per-refresh)))
      (cl-letf (((symbol-function 'claude-code-ide-transcript-codex-meta)
                 (lambda (name) (cl-incf meta) (funcall original-meta name)))
                ((symbol-function 'claude-code-ide-transcript--parse-line)
                 (lambda (line) (cl-incf parse) (funcall original-parse line)))
                ((symbol-function 'claude-code-ide-session-status--once-per-refresh)
                 (lambda (table key now compute &optional stamp)
                   (push table memo)
                   (funcall original-memo table key now compute stamp))))
        (should (eq (car (claude-code-ide-codex-events-tests--full-state instance)) 'working))
        (should (= meta 1))
        (should (> parse 0))
        (should (memq claude-code-ide-codex-events--state-cache memo))
        (setq memo nil)
        (claude-code-ide-session-status--cli-state (claude-code-ide-tests--make-session "/tmp/cci-test-memo/") 5.0)
        (should (memq claude-code-ide-session-status--cli-cache memo))))))

(ert-deftest claude-code-ide-codex-events-test-state-once-per-refresh ()
  "The state of a row is computed once for each refresh; a change counts as a new one."
  (claude-code-ide-codex-events-tests--with-codex
    (unwind-protect
        (let* ((claude-code-ide-codex-events--state-cache (make-hash-table :test 'eq :weakness 'key))
               (instance (claude-code-ide-codex-events-tests--instance "cci-test-once" 1))
               (count 0)
               (original (symbol-function 'claude-code-ide-codex-events--state)))
          (claude-code-ide-codex-events--track instance)
          (claude-code-ide-codex-events-tests--feed "cci-test-once" 1 '(("SessionStart" "{}") ("UserPromptSubmit" "{}")))
          (cl-letf (((symbol-function 'claude-code-ide-codex-events--state)
                     (lambda (launch now) (cl-incf count) (funcall original launch now))))
            (should (eq (plist-get (claude-code-ide-instance-state instance 1000.0) :state) 'working))
            (should (equal (claude-code-ide-codex-events--instance-detail instance 1000.0) "Working"))
            (claude-code-ide-session-status--snapshot-instance instance 1000.0)
            (should (= count 1))
            ;; An event at the same time is a change
            (claude-code-ide-codex-events-tests--feed "cci-test-once" 1 '(("Stop" "{\"last_assistant_message\":\"done\"}")))
            (should (eq (plist-get (claude-code-ide-instance-state instance 1000.0) :state) 'idle))
            (should (= count 2))
            ;; A new refresh
            (claude-code-ide-codex-events--instance-detail instance 1001.0)
            (should (= count 3))))
      (claude-code-ide-codex-events-tests--kill-instances))))

;;; A plan without Codex

(defconst claude-code-ide-codex-events-tests--not-included
  "To use Codex with your ChatGPT plan, upgrade to Plus: https://chatgpt.com/explore/plus."
  "The Codex 0.164.0 text of `usage_not_included'.")

(defmacro claude-code-ide-codex-events-tests--with-not-included (&rest body)
  "Run BODY with `instance', a Codex instance whose plan does not include Codex.
The stubs record `visits', `handovers' and `stops'; `choices' are the
answers of `read-multiple-choice', and `asked' counts its calls."
  (declare (indent 0))
  `(claude-code-ide-codex-events-tests--with-codex
     (require 'claude-code-ide-handover)
     (require 'claude-code-ide-control)
     (let ((claude-code-ide-codex-events--state-cache (make-hash-table :test 'eq :weakness 'key))
           (instance (claude-code-ide-codex-events-tests--instance "cci-test-plan" 1))
           (visits 0) (handovers nil) (stops nil) (choices nil) (asked 0))
       (unwind-protect
           (cl-letf (((symbol-function 'claude-code-ide-session-status--visit-session)
                      (lambda (_item) (cl-incf visits)))
                     ((symbol-function 'claude-code-ide-handover--read-args)
                      (lambda (&optional id) (list id 'claude)))
                     ((symbol-function 'claude-code-ide-handover)
                      (lambda (id target &rest _) (push (list id target) handovers)))
                     ((symbol-function 'claude-code-ide-control-stop)
                      (lambda (id) (push id stops) (list :status 'ok :instance-id id :result 'stopped)))
                     ((symbol-function 'read-multiple-choice)
                      (lambda (_prompt options &rest _)
                        (cl-incf asked)
                        (assq (pop choices) options))))
             (claude-code-ide-codex-events--track instance)
             (claude-code-ide-codex-events-tests--feed
              "cci-test-plan" 1
              (list '("UserPromptSubmit" "{}")
                    (list "PostModelRequest"
                          (json-encode `((status . "failed")
                                         (error . ,claude-code-ide-codex-events-tests--not-included))))))
             ,@body)
         (claude-code-ide-codex-events-tests--kill-instances)))))

(ert-deftest claude-code-ide-codex-events-test-not-included-state ()
  "A plan without Codex is failed/quota-limit, with its own detail and mark."
  (claude-code-ide-codex-events-tests--with-not-included
    (let ((state (claude-code-ide-instance-state instance 1000.0)))
      (should (equal (list (plist-get state :state) (plist-get state :reason) (plist-get state :not-included))
                     '(failed quota-limit t))))
    (should (string-prefix-p "Not included in the plan: To use Codex"
                             (claude-code-ide-codex-events--instance-detail instance 1000.0)))
    ;; The snapshot of a coordinator has the state, the reason and the detail
    (let ((record (claude-code-ide-session-status--snapshot-instance instance 1000.0)))
      (should (equal (alist-get 'reason record) "quota-limit"))
      (should (string-prefix-p "Not included in the plan" (alist-get 'detail record))))
    ;; A usage limit has no such mark
    (claude-code-ide-codex-events-tests--feed
     "cci-test-plan" 1
     (list '("UserPromptSubmit" "{}")
           (list "PostModelRequest"
                 (json-encode `((status . "failed") (error . ,(car claude-code-ide-codex-events-tests--quota-texts)))))))
    (should-not (plist-get (claude-code-ide-instance-state instance 1001.0) :not-included))
    (should (eq (claude-code-ide-codex-events--failure-kind "usage_not_included" "cci-test") 'not-included))))

(ert-deftest claude-code-ide-codex-events-test-not-included-ask ()
  "With `ask', the visit and the handover key ask: c continues, h hands over, s stops."
  (claude-code-ide-codex-events-tests--with-not-included
    (should (eq claude-code-ide-codex-events-not-included-action 'ask))
    ;; c on a visit: the terminal shows, nothing else
    (setq choices '(?c))
    (claude-code-ide-session-status--visit-item instance)
    (should (equal (list asked visits handovers stops) '(1 1 nil nil)))
    ;; c on the handover key: nothing
    (setq choices '(?c))
    (cl-letf (((symbol-function 'claude-code-ide-session-status--handover-instance) (lambda () instance)))
      (claude-code-ide-session-status-handover))
    (should (equal (list asked visits handovers stops) '(2 1 nil nil)))
    ;; h: a handover of this instance, once
    (setq choices '(?h))
    (claude-code-ide-session-status--visit-item instance)
    (should (equal handovers '(("cci-test-plan" claude))))
    (setq choices '(?h))
    (cl-letf (((symbol-function 'claude-code-ide-session-status--handover-instance) (lambda () instance)))
      (claude-code-ide-session-status-handover))
    (should (= (length handovers) 2))
    (should (= visits 1))
    ;; s: the stop of this instance
    (setq choices '(?s))
    (claude-code-ide-session-status--visit-item instance)
    (should (equal stops '("cci-test-plan")))
    (should (= visits 1))
    ;; Another state asks nothing
    (claude-code-ide-codex-events-tests--feed "cci-test-plan" 1 '(("UserPromptSubmit" "{}")))
    (setq asked 0)
    (claude-code-ide-session-status--visit-item instance)
    (should (= asked 0))
    (should (= visits 2))))

(ert-deftest claude-code-ide-codex-events-test-not-included-action-values ()
  "Each value of `claude-code-ide-codex-events-not-included-action' acts without a question."
  (claude-code-ide-codex-events-tests--with-not-included
    (let ((claude-code-ide-codex-events-not-included-action 'continue))
      (claude-code-ide-session-status--visit-item instance)
      (cl-letf (((symbol-function 'claude-code-ide-session-status--handover-instance) (lambda () instance)))
        (claude-code-ide-session-status-handover))
      (should (equal (list asked visits handovers stops) '(0 1 nil nil))))
    (let ((claude-code-ide-codex-events-not-included-action 'handover))
      (claude-code-ide-session-status--visit-item instance)
      (should (equal (list asked visits handovers stops) '(0 1 (("cci-test-plan" claude)) nil))))
    (let ((claude-code-ide-codex-events-not-included-action 'stop))
      (claude-code-ide-session-status--visit-item instance)
      (should (equal (list asked visits (length handovers) stops) '(0 1 1 ("cci-test-plan")))))
    ;; `claude-code-ide-visit-waiting-session' acts on the row too
    (let ((claude-code-ide-codex-events-not-included-action 'stop))
      (cl-letf (((symbol-function 'claude-code-ide-session-status--rows)
                 (lambda (&rest _) (list (list instance 'quota 1000.0 "cci-test" nil)))))
        (claude-code-ide-visit-waiting-session))
      (should (= (length stops) 2)))))

(provide 'claude-code-ide-codex-events-tests)

;; Local Variables:
;; no-update-autoloads: t
;; autoload-compute-prefixes: nil
;; End:

;;; claude-code-ide-codex-events-tests.el ends here
