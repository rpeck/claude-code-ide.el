import json, os, sys
# Write the synthetic transcript fixtures of claude-code-ide-transcript-tests.el.
# Usage: python3 tests/fixtures/transcripts/make-fixtures.py tests/fixtures/transcripts
# All text is made up and uses the cci-test- prefix.  The record shapes
# follow CC 2.1 transcripts and Codex 0.164 rollouts.
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
ROOT = "/tmp/cci-test-proj"

def write(name, records):
    with open(os.path.join(out, name), "w") as f:
        for r in records:
            f.write(r if isinstance(r, str) else json.dumps(r, separators=(",", ":")))
            f.write("\n")

def cc(kind, n, extra, session):
    r = {"parentUuid": None, "isSidechain": False, "userType": "external",
         "cwd": ROOT, "sessionId": session, "version": "2.1.280",
         "gitBranch": "cci-test-branch", "type": kind,
         "uuid": "cci-test-uuid-%s-%02d" % (session[-4:], n),
         "timestamp": "2026-11-17T10:%02d:00.000Z" % n}
    r.update(extra)
    return r

def user(n, content, session, **flags):
    return cc("user", n, dict({"message": {"role": "user", "content": content}}, **flags), session)

def assistant(n, blocks, session, **flags):
    return cc("assistant", n, dict({"message": {
        "model": "claude-sonnet-cci-test", "id": "msg_cci_test_%02d" % n, "type": "message",
        "role": "assistant", "content": blocks, "stop_reason": None,
        "usage": {"input_tokens": 1, "output_tokens": 1}}}, **flags), session)

def tool_result(n, tool_id, session):
    return user(n, [{"tool_use_id": tool_id, "type": "tool_result",
                     "content": "cci-test tool output", "is_error": False}],
                session, toolUseResult={"stdout": "cci-test tool output"})

S1 = "cci-test-0000-0000-0000-000000000001"
write("claude-leg1.jsonl", [
    {"type": "queue-operation", "operation": "enqueue", "timestamp": "2026-11-17T10:00:00.000Z",
     "sessionId": S1, "content": "cci-test-chain: add mean_of and fmt_report to stats.py."},
    user(1, "cci-test-chain: add mean_of and fmt_report to stats.py.", S1,
         promptSource="typed", turnOrigin="human"),
    cc("attachment", 2, {"attachment": {"type": "environment", "snapshot": {"workingDirectory": ROOT}}}, S1),
    assistant(3, [{"type": "thinking", "thinking": "cci-test-thinking-text", "signature": "cci-test"}], S1),
    assistant(4, [{"type": "text", "text": "cci-test: I look at the project first."}], S1),
    assistant(5, [{"type": "tool_use", "id": "toolu_cci_test_1", "name": "Bash",
                   "input": {"command": "cd \"%s\" && git status" % ROOT,
                             "description": "cci-test status"}}], S1),
    tool_result(6, "toolu_cci_test_1", S1),
    assistant(7, [{"type": "tool_use", "id": "toolu_cci_test_2", "name": "Edit",
                   "input": {"file_path": ROOT + "/stats.py", "old_string": "cci-test-old",
                             "new_string": "cci-test-new", "replace_all": False}}], S1),
    tool_result(8, "toolu_cci_test_2", S1),
    '{"type":"user","message":{"role":"user","content":"cci-test-broken-line',
    {"type": "cci-test-unknown-record", "sessionId": S1, "data": {"type": "user", "text": "cci-test-unknown-text"}},
    assistant(9, [{"type": "text", "text": "cci-test: Done. mean_of and fmt_report are in stats.py."}], S1),
    user(10, "<local-command-caveat>cci-test caveat</local-command-caveat>", S1, isMeta=True),
    user(11, "<command-name>/model</command-name>\n<command-message>model</command-message>\n"
             "<command-args>cci-test-model</command-args>", S1),
    user(12, "<local-command-stdout>cci-test model set</local-command-stdout>", S1),
    user(13, [{"type": "text", "text": "cci-test-chain: also add clamp to util.py."},
              {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AAAA"}}],
         S1, promptSource="typed"),
    assistant(14, [{"type": "text", "text": "cci-test-sidechain-text"}], S1, isSidechain=True),
    assistant(15, [{"type": "tool_use", "id": "toolu_cci_test_3", "name": "Write",
                    "input": {"file_path": ROOT + "/util.py", "content": "cci-test content"}}], S1),
    tool_result(16, "toolu_cci_test_3", S1),
    assistant(17, [{"type": "text", "text": "cci-test: clamp is in util.py."}], S1),
    user(18, "<task-notification>cci-test task done</task-notification>", S1, promptSource="system"),
    cc("system", 19, {"subtype": "turn_duration", "durationMs": 10}, S1),
    {"type": "ai-title", "sessionId": S1, "aiTitle": "cci-test title"},
])

def doc(hid, nested):
    return ("<!-- claude-code-ide-handover-document id=%s -->\n# Handover document\n\n"
            "- Handover ID: %s\n- State summary file: `.handover/%s-state.md`\n\n"
            "## History of the chain\n\n"
            "### Original task (the first user prompt of the chain; it can be out of date)\n\n"
            "> cci-test-chain: add mean_of and fmt_report to stats.py.\n\n"
            "### Latest turns, oldest first\n\n#### User, leg 1 (claude)\n\n> %s\n\n"
            "## Instructions\n\n- cci-test-old-instruction-%s\n") % (hid, hid, hid, nested, hid)

def codex(n, kind, payload):
    return {"timestamp": "2026-11-17T11:%02d:00.000Z" % n, "type": kind,
            "ordinal": n, "payload": payload}

def item(n, it):
    return codex(n, "event_msg", {"type": "item_completed", "thread_id": "cci-test-codex-0002",
                                  "turn_id": "cci-test-turn", "started_at_ms": 1,
                                  "completed_at_ms": 2, "item": it})

write("codex-leg2.jsonl", [
    codex(0, "session_meta", {"id": "cci-test-codex-0002", "timestamp": "2026-11-17T11:00:00.000Z",
                              "cwd": ROOT, "originator": "cci-test", "cli_version": "0.164.0",
                              "source": "exec", "history_mode": "paginated",
                              "git": {"commit_hash": "0123456789abcdef0123456789abcdef01234567",
                                      "branch": "cci-test-branch"}}),
    codex(1, "event_msg", {"type": "task_started", "turn_id": "cci-test-turn"}),
    codex(2, "response_item", {"type": "message", "role": "user",
                               "content": [{"type": "input_text", "text": "cci-test-response-item-text"}]}),
    item(3, {"type": "UserMessage", "id": "cci-test-i3",
             "content": [{"type": "text", "text": doc("cci-test-h1", "cci-test-nested-text-h1"),
                          "text_elements": []}]}),
    item(4, {"type": "Reasoning", "id": "cci-test-i4", "summary_text": ["cci-test-reasoning-text"],
             "raw_content": []}),
    item(5, {"type": "FileChange", "id": "cci-test-i5", "status": "completed", "stdout": "", "stderr": "",
             "changes": {ROOT + "/.handover/cci-test-h1-state.md": {"type": "add", "content": "cci-test"}}}),
    item(6, {"type": "AgentMessage", "id": "cci-test-i6", "phase": "final_answer",
             "content": [{"type": "Text", "text": "ready cci-test-bootstrap-h1"}]}),
    codex(7, "event_msg", {"type": "task_complete", "turn_id": "cci-test-turn",
                           "last_agent_message": "ready cci-test-bootstrap-h1"}),
    '{"timestamp":"2026-11-17T11:08:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"text":"cci-test-broken',
    {"timestamp": "2026-11-17T11:09:00.000Z", "type": "cci-test-unknown",
     "payload": {"type": "item_completed", "item": {"type": "UserMessage",
                                                   "content": [{"type": "text", "text": "cci-test-unknown-text"}]}}},
    item(10, {"type": "UserMessage", "id": "cci-test-i10",
              "content": [{"type": "text", "text": "cci-test-chain: rename fmt_report to format_summary with JSON output.",
                           "text_elements": []}]}),
    item(11, {"type": "AgentMessage", "id": "cci-test-i11", "phase": "commentary",
              "content": [{"type": "Text", "text": "cci-test: I change stats.py."}]}),
    item(12, {"type": "CommandExecution", "id": "cci-test-i12", "status": "completed",
              "command": ["/bin/zsh", "-lc", "cd %s && python3 -m pytest -q" % ROOT],
              "cwd": ROOT, "exit_code": 1, "aggregated_output": "cci-test output",
              "parsed_cmd": [{"type": "unknown", "cmd": "python3 -m pytest -q"}]}),
    item(13, {"type": "FileChange", "id": "cci-test-i13", "status": "completed", "stdout": "", "stderr": "",
              "changes": {ROOT + "/stats.py": {"type": "update", "unified_diff": "cci-test diff",
                                               "move_path": None}}}),
    item(14, {"type": "McpToolCall", "id": "cci-test-i14", "server": "emacs-tools",
              "tool": "getDiagnostics", "status": "completed", "arguments": {}, "result": {}}),
    item(15, {"type": "cci-test-UnknownItem", "id": "cci-test-i15", "text": "cci-test-unknown-item-text"}),
    codex(16, "response_item", {"type": "custom_tool_call", "name": "exec", "call_id": "cci-test-c16",
                                "input": "tools.exec_command('cci-test')", "status": "completed"}),
    item(17, {"type": "AgentMessage", "id": "cci-test-i17", "phase": "final_answer",
              "content": [{"type": "Text", "text": "cci-test: format_summary returns JSON now."}]}),
])

S3 = "cci-test-0000-0000-0000-000000000003"
write("claude-leg3.jsonl", [
    user(1, doc("cci-test-h2", "cci-test-nested-text-h2"), S3, promptSource="sdk"),
    assistant(2, [{"type": "tool_use", "id": "toolu_cci_test_4", "name": "Write",
                   "input": {"file_path": ROOT + "/.handover/cci-test-h2-state.md",
                             "content": "cci-test summary"}}], S3),
    tool_result(3, "toolu_cci_test_4", S3),
    assistant(4, [{"type": "text", "text": "ready cci-test-bootstrap-h2"}], S3),
    user(5, "cci-test-chain: revert the clamp change from the first session.", S3, promptSource="sdk"),
    assistant(6, [{"type": "tool_use", "id": "toolu_cci_test_5", "name": "Bash",
                   "input": {"command": "git revert --no-commit HEAD~1"}}], S3),
    tool_result(7, "toolu_cci_test_5", S3),
    assistant(8, [{"type": "text", "text": "cci-test: The clamp change is reverted."}], S3),
])

write("codex-legacy.jsonl", [
    codex(0, "session_meta", {"id": "cci-test-codex-0004", "cwd": ROOT, "source": "vscode",
                              "history_mode": "legacy", "timestamp": "2026-11-17T12:00:00.000Z",
                              "git": {"commit_hash": "fedcba9876543210fedcba9876543210fedcba98",
                                      "branch": "cci-test-branch"}}),
    codex(1, "event_msg", {"type": "user_message", "message": "cci-test-import: read README.md",
                           "text_elements": [], "local_images": []}),
    codex(2, "response_item", {"type": "message", "role": "user",
                               "content": [{"type": "input_text", "text": "cci-test-response-item-text"}]}),
    codex(3, "event_msg", {"type": "agent_message", "phase": None, "memory_citation": None,
                           "message": "[external_agent_tool_call: Read]\nfile: %s/README.md\n[/external_agent_tool_call]" % ROOT}),
    codex(4, "event_msg", {"type": "agent_message", "phase": None, "memory_citation": None,
                           "message": "[external_agent_tool_result]\ncci-test-result-text\n[/external_agent_tool_result]"}),
    codex(5, "event_msg", {"type": "agent_message", "phase": None, "memory_citation": None,
                           "message": "cci-test: The README names the project."}),
    codex(6, "event_msg", {"type": "agent_message", "phase": None, "memory_citation": None,
                           "message": "<EXTERNAL SESSION IMPORTED>"}),
])
