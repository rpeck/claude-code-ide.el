;;; claude-code-ide-session-status-tests.el --- Tests for the session status  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for `claude-code-ide-session-status-mode': the hook script, the
;; event files, the state machine and the status buffer.  The event
;; sequences come from hook traces of a real CLI session.  The file is
;; loaded by claude-code-ide-tests.el, after its mocks, and uses its
;; helpers and those of the registry tests.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-code-ide)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-session-status)
(require 'claude-code-ide-session-registry-tests)

(declare-function claude-code-ide-tests--make-session "claude-code-ide-tests")
(declare-function claude-code-ide-tests--clear-processes "claude-code-ide-tests")
(declare-function claude-code-ide-tests--wait-until "claude-code-ide-tests")

(defmacro claude-code-ide-tests--with-status (&rest body)
  "Run BODY with an empty registry and no tracked sessions.
Timers and file watches are not started."
  (declare (indent 0))
  `(claude-code-ide-tests--with-registry
     (let ((claude-code-ide-session-status--by-nonce (make-hash-table :test 'equal))
           (claude-code-ide-session-status--by-session (make-hash-table :test 'eq :weakness 'key))
           (claude-code-ide-session-status--urgent-count 0))
       (cl-letf (((symbol-function 'claude-code-ide-session-status--ensure-timers) #'ignore))
         ,@body))))

(defun claude-code-ide-tests--status (&optional now)
  "Return a new status record created at NOW."
  (let ((now (or now 0.0)))
    (claude-code-ide-session-status-create :nonce "abc" :since now :registered now :last-event now)))

(defun claude-code-ide-tests--feed (status events)
  "Apply EVENTS to STATUS.  Each is (EVENT JSON-TEXT); times count from 1."
  (let ((now 0.0))
    (dolist (event events)
      (claude-code-ide-session-status--apply
       status (car event)
       (claude-code-ide-session-registry--json-decode (cadr event))
       (cl-incf now)))
    status))

(defun claude-code-ide-tests--state (status)
  "Return the state and detail of STATUS at time 100."
  (let ((state (claude-code-ide-session-status--state status 100.0)))
    (list state (claude-code-ide-session-status--detail status state))))

(defconst claude-code-ide-tests--bash-input
  "{\"command\":\"touch made-by-test.txt\",\"description\":\"Create a file\"}")

(defun claude-code-ide-tests--tool (event id &optional input agent name)
  "Return a tool EVENT for tool use ID with INPUT, AGENT and NAME."
  (list event
        (format "{%s\"tool_name\":\"%s\",\"tool_use_id\":\"%s\",\"tool_input\":%s}"
                (if agent (format "\"agent_id\":\"%s\"," agent) "")
                (or name "Bash") id (or input claude-code-ide-tests--bash-input))))

(defun claude-code-ide-tests--permission (&optional input agent name)
  "Return a PermissionRequest for INPUT, AGENT and NAME (no tool use id)."
  (list "PermissionRequest"
        (format "{%s\"tool_name\":\"%s\",\"tool_input\":%s}"
                (if agent (format "\"agent_id\":\"%s\"," agent) "")
                (or name "Bash") (or input claude-code-ide-tests--bash-input))))

(ert-deftest claude-code-ide-test-status-permission-flow ()
  "Prompt, permission dialog, approval, end of turn (traced sequence)."
  (let ((status (claude-code-ide-tests--status)))
    (claude-code-ide-tests--feed status '(("SessionStart" "{\"source\":\"startup\"}")))
    (should (equal (claude-code-ide-tests--state status) '(idle "Ready")))
    (claude-code-ide-tests--feed
     status (list '("UserPromptSubmit" "{\"prompt\":\"run it\"}")
                  (claude-code-ide-tests--tool "PreToolUse" "t1")
                  (claude-code-ide-tests--permission)))
    (should (equal (claude-code-ide-tests--state status)
                   '(waiting "Bash: touch made-by-test.txt")))
    ;; The notification 6 s later adds nothing
    (claude-code-ide-tests--feed
     status '(("Notification" "{\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission\"}")))
    (should (= 1 (length (claude-code-ide-session-status-blockers status))))
    (claude-code-ide-tests--feed status (list (claude-code-ide-tests--tool "PostToolUse" "t1")))
    (should (eq (car (claude-code-ide-tests--state status)) 'working))
    (claude-code-ide-tests--feed
     status '(("Stop" "{\"last_assistant_message\":\"\\nThe command ran.\\nMore text\"}")))
    (should (equal (claude-code-ide-tests--state status) '(idle "The command ran.")))))

(ert-deftest claude-code-ide-test-status-question-menu ()
  "An AskUserQuestion menu waits with its question until the answer."
  (let* ((input "{\"questions\":[{\"question\":\"Which color do you choose?\",\"header\":\"Color\"}]}")
         (status (claude-code-ide-tests--feed
                  (claude-code-ide-tests--status)
                  (list '("UserPromptSubmit" "{}")
                        (claude-code-ide-tests--tool "PreToolUse" "q1" input nil "AskUserQuestion")
                        (claude-code-ide-tests--permission input nil "AskUserQuestion")))))
    (should (equal (claude-code-ide-tests--state status)
                   '(waiting "Question: Which color do you choose?")))
    (claude-code-ide-tests--feed
     status (list (claude-code-ide-tests--tool "PostToolUse" "q1" input nil "AskUserQuestion")))
    (should (eq (car (claude-code-ide-tests--state status)) 'working))))

(ert-deftest claude-code-ide-test-status-esc-denial ()
  "A denial with Esc fires no hook: the session waits until idle_prompt."
  (let ((status (claude-code-ide-tests--feed
                 (claude-code-ide-tests--status)
                 (list '("UserPromptSubmit" "{}")
                       (claude-code-ide-tests--tool "PreToolUse" "t1")
                       (claude-code-ide-tests--permission)))))
    (should (eq (car (claude-code-ide-tests--state status)) 'waiting))
    (claude-code-ide-tests--feed
     status '(("Notification" "{\"notification_type\":\"idle_prompt\",\"message\":\"Claude is waiting for your input\"}")))
    (should (equal (claude-code-ide-tests--state status) '(idle "Waiting for your input")))))

(ert-deftest claude-code-ide-test-status-two-dialogs ()
  "Each dialog ends only with its own tool, whatever the order of events."
  (let ((input-a "{\"command\":\"a\"}")
        (input-b "{\"command\":\"b\"}"))
    ;; Two requests; the second one is answered first
    (let ((status (claude-code-ide-tests--feed
                   (claude-code-ide-tests--status)
                   (list '("UserPromptSubmit" "{}")
                         (claude-code-ide-tests--tool "PreToolUse" "a" input-a)
                         (claude-code-ide-tests--tool "PreToolUse" "b" input-b)
                         (claude-code-ide-tests--permission input-a)
                         (claude-code-ide-tests--permission input-b)
                         (claude-code-ide-tests--tool "PostToolUse" "b" input-b)))))
      (should (equal (claude-code-ide-tests--state status) '(waiting "Bash: a")))
      (claude-code-ide-tests--feed status (list (claude-code-ide-tests--tool "PostToolUse" "a" input-a)))
      (should (eq (car (claude-code-ide-tests--state status)) 'working)))
    ;; A later PreToolUse does not take over the request of an earlier tool
    (let ((status (claude-code-ide-tests--feed
                   (claude-code-ide-tests--status)
                   (list '("UserPromptSubmit" "{}")
                         (claude-code-ide-tests--tool "PreToolUse" "a" input-a)
                         (claude-code-ide-tests--tool "PreToolUse" "b" input-b)
                         (claude-code-ide-tests--permission input-a)
                         (claude-code-ide-tests--tool "PostToolUse" "b" input-b)))))
      (should (eq (car (claude-code-ide-tests--state status)) 'waiting))
      (claude-code-ide-tests--feed status (list (claude-code-ide-tests--tool "PostToolUse" "a" input-a)))
      (should (eq (car (claude-code-ide-tests--state status)) 'working)))))

(ert-deftest claude-code-ide-test-status-elicitation ()
  "An elicitation waits through other tool events until its result."
  (let ((status (claude-code-ide-tests--feed
                 (claude-code-ide-tests--status)
                 (list '("UserPromptSubmit" "{}")
                       '("Elicitation" "{\"mcp_server_name\":\"jira\",\"message\":\"Pick a project\"}")
                       (claude-code-ide-tests--tool "PostToolUse" "x")))))
    (should (equal (claude-code-ide-tests--state status)
                   '(waiting "Input for jira: Pick a project")))
    (claude-code-ide-tests--feed status '(("ElicitationResult" "{}")))
    (should (eq (car (claude-code-ide-tests--state status)) 'working))))

(ert-deftest claude-code-ide-test-status-subagent-dialog-outlives-stop ()
  "A subagent's dialog keeps the session waiting after the main Stop."
  (let ((status (claude-code-ide-tests--feed
                 (claude-code-ide-tests--status)
                 (list '("UserPromptSubmit" "{}")
                       (claude-code-ide-tests--tool "PreToolUse" "s1" nil "agent-7")
                       (claude-code-ide-tests--permission nil "agent-7")
                       '("Stop" "{\"last_assistant_message\":\"Started a helper\"}")))))
    (should (eq (car (claude-code-ide-tests--state status)) 'waiting))
    (claude-code-ide-tests--feed status (list (claude-code-ide-tests--tool "PostToolUse" "s1" nil "agent-7")))
    ;; The turn had ended: the session is idle, not working
    (should (equal (claude-code-ide-tests--state status) '(idle "Started a helper")))))

(ert-deftest claude-code-ide-test-status-unmatched-notification-waits ()
  "A waiting notification without a known dialog still marks the session."
  (dolist (type '("worker_permission_prompt" "agent_needs_input" "elicitation_url_dialog"))
    (let ((status (claude-code-ide-tests--feed
                   (claude-code-ide-tests--status)
                   (list '("UserPromptSubmit" "{}")
                         (list "Notification"
                               (format "{\"notification_type\":\"%s\",\"message\":\"Help\"}" type))))))
      (should (equal (claude-code-ide-tests--state status) '(waiting "Help"))))))

(ert-deftest claude-code-ide-test-status-compact-clear-and-late-events ()
  "Compaction keeps the phase; /clear resets; subagent tool events keep idle."
  (let ((status (claude-code-ide-tests--feed
                 (claude-code-ide-tests--status)
                 (list '("UserPromptSubmit" "{}")
                       '("SessionStart" "{\"source\":\"compact\"}")))))
    (should (eq (car (claude-code-ide-tests--state status)) 'working))
    (claude-code-ide-tests--feed
     status (list (claude-code-ide-tests--tool "PreToolUse" "t1")
                  (claude-code-ide-tests--permission)
                  '("SessionStart" "{\"source\":\"clear\"}")))
    (should (equal (claude-code-ide-tests--state status) '(idle "Ready")))
    ;; Late tool events of a subagent keep the session idle
    (claude-code-ide-tests--feed
     status (list '("UserPromptSubmit" "{}")
                  '("Stop" "{\"last_assistant_message\":\"Done\"}")
                  (claude-code-ide-tests--tool "PreToolUse" "late" nil "agent-3")
                  (claude-code-ide-tests--tool "PostToolUse" "late" nil "agent-3")))
    (should (equal (claude-code-ide-tests--state status) '(idle "Done")))
    ;; A rate limit without a usage-limit text is a short limit
    (claude-code-ide-tests--feed status '(("StopFailure" "{\"error\":\"rate_limit\"}")))
    (should (equal (claude-code-ide-tests--state status) '(error "Error: rate limit")))))

(ert-deftest claude-code-ide-test-status-stop-failure-with-dialog ()
  "An API error ends the main turn: its dialog closes and the state is error."
  (let ((status (claude-code-ide-tests--feed
                 (claude-code-ide-tests--status)
                 (list '("UserPromptSubmit" "{}")
                       (claude-code-ide-tests--tool "PreToolUse" "t1")
                       (claude-code-ide-tests--permission)
                       '("StopFailure" "{\"error\":\"overloaded\"}")))))
    (should (equal (claude-code-ide-tests--state status) '(error "Error: overloaded")))
    (should (zerop (hash-table-count (claude-code-ide-session-status-inflight status))))))

(ert-deftest claude-code-ide-test-status-tracking-off-and-registry-off ()
  "Tracking off starts no tracking; an ended session is forgotten in any case."
  (claude-code-ide-tests--with-status
    (let ((claude-code-ide-session-end-functions nil)
          (claude-code-ide-session-registry-hook-functions nil))
      (claude-code-ide-session-status--set-tracking t)
      (let ((session (make-claude-code-ide-mcp-session)))
        (let ((claude-code-ide-session-status-tracking nil))
          (should-not (claude-code-ide-session-status--hooks session "k0"))
          (should-not (gethash session claude-code-ide-session-status--by-session)))
        (should (claude-code-ide-session-status--hooks session "k1"))
        ;; The registry mode is turned off while the session runs
        (claude-code-ide-session-status--set-tracking nil)
        (should-not claude-code-ide-session-registry-hook-functions)
        (run-hook-with-args 'claude-code-ide-session-end-functions session 'exited)
        (should (zerop (hash-table-count claude-code-ide-session-status--by-nonce)))))))

(ert-deftest claude-code-ide-test-status-drain-survives-bad-files-and-locks ()
  "An unreadable event file is deleted; an old lock is removed."
  (claude-code-ide-tests--with-status
    (let* ((session (make-claude-code-ide-mcp-session))
           (_hooks (claude-code-ide-session-status--hooks session "k1"))
           (status (gethash session claude-code-ide-session-status--by-session))
           (nonce (claude-code-ide-session-status-nonce status))
           (dir (claude-code-ide-session-status--events-directory))
           (bad (expand-file-name (format "%s-00000001-Stop.json" nonce) dir))
           (lock (expand-file-name (format ".%s.lock" nonce) dir)))
      (make-directory dir t)
      (with-temp-file bad (insert "{\"last_assistant_message\":"))
      (make-directory lock)
      (set-file-times lock (time-subtract nil 60))
      (claude-code-ide-session-status--drain)
      (should-not (file-exists-p bad))
      (should-not (file-exists-p lock))
      (should (eq (claude-code-ide-session-status-phase status) 'starting)))))

(ert-deftest claude-code-ide-test-status-hook-script-dead-lock-holder ()
  "The script breaks the lock of a holder that died, and numbers on."
  (claude-code-ide-tests--with-status
    (claude-code-ide-session-status--install-script)
    (let* ((script (claude-code-ide-session-status--script-file))
           (dir (expand-file-name "events" registry-dir))
           (lock (expand-file-name ".n3.lock" dir)))
      (make-directory lock t)
      ;; A PID that is not running
      (with-temp-file (expand-file-name "pid" lock) (insert "999999\n"))
      (with-temp-buffer
        (should (= 0 (call-process "sh" nil t nil "-c"
                                   (format "echo '{}' | sh %s %s n3 Stop"
                                           (shell-quote-argument script)
                                           (shell-quote-argument dir)))))
        (should (equal (buffer-string) "")))
      (should (equal (directory-files dir nil "\\`n3-") '("n3-00000001-Stop.json")))
      (should-not (file-exists-p lock)))))

;;; Background tasks (shapes from traces of CLI 2.1.317)

(defun claude-code-ide-tests--feed-at (status events)
  "Apply EVENTS to STATUS.  Each is (TIME EVENT JSON-TEXT)."
  (dolist (event events status)
    (claude-code-ide-session-status--apply
     status (nth 1 event)
     (claude-code-ide-session-registry--json-decode (nth 2 event))
     (float (car event)))))

(defun claude-code-ide-tests--state-at (status now)
  "Return the state and detail of STATUS at NOW."
  (let ((state (claude-code-ide-session-status--state status (float now))))
    (list state (claude-code-ide-session-status--detail status state (float now)))))

(defun claude-code-ide-tests--agent-task (id &optional description)
  "Return the background_tasks JSON item of the subagent ID."
  (format "{\"id\":\"%s\",\"type\":\"subagent\",\"status\":\"running\",\"description\":\"%s\",\"agent_type\":\"general-purpose\"}"
          id (or description (concat "Task " id))))

(defun claude-code-ide-tests--shell-task (id &optional description)
  "Return the background_tasks JSON item of the shell ID."
  (format "{\"id\":\"%s\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"%s\",\"command\":\"pytest\"}"
          id (or description "Run tests")))

(defun claude-code-ide-tests--stop (reply &rest tasks)
  "Return a Stop event text with REPLY and the background TASKS items."
  (format "{\"last_assistant_message\":\"%s\",\"background_tasks\":[%s],\"session_crons\":[]}"
          reply (string-join tasks ",")))

(defun claude-code-ide-tests--subagent (event id &optional type)
  "Return the text of a SubagentStart or SubagentStop EVENT for agent ID.
TYPE is the agent type; the CLI's own helper agents have \"\"."
  (format "{\"agent_id\":\"%s\",\"agent_type\":\"%s\"%s}"
          id (or type "general-purpose")
          (if (equal event "SubagentStop") ",\"background_tasks\":[]" "")))

(defun claude-code-ide-tests--agent-tool (_event agent id)
  "Return the text of a tool event of subagent AGENT for tool use ID.
The event name is only for the reader; the text is the same."
  (format "{\"agent_id\":\"%s\",\"agent_type\":\"general-purpose\",\"tool_name\":\"Bash\",\"tool_use_id\":\"%s\",\"tool_input\":{\"command\":\"ls\"}}"
          agent id))

(ert-deftest claude-code-ide-test-status-tasks-shell-idle-prompt ()
  "A background shell leaves the session waiting for the user; the detail names it."
  (let ((status (claude-code-ide-tests--feed-at
                 (claude-code-ide-tests--status)
                 `((1 "UserPromptSubmit" "{}")
                   (4 "Stop" ,(claude-code-ide-tests--stop
                               "Started the tests" (claude-code-ide-tests--shell-task "b1")))))))
    ;; A shell does not keep the agent from the user
    (should (equal (claude-code-ide-tests--state-at status 10)
                   '(idle "Started the tests · 1 shell running")))
    ;; F6: idle_prompt fires while the shell runs
    (claude-code-ide-tests--feed-at
     status '((64 "Notification" "{\"notification_type\":\"idle_prompt\",\"message\":\"Claude is waiting for your input\"}")))
    (should (eq (car (claude-code-ide-tests--state-at status 70)) 'idle))
    (should (equal (claude-code-ide-session-status-detail status) "Started the tests"))
    ;; The shell ends: the CLI wakes the agent, which reports
    (claude-code-ide-tests--feed-at
     status `((100 "UserPromptSubmit" "{}")
              (102 "Stop" ,(claude-code-ide-tests--stop "Tests passed"))))
    (should (equal (claude-code-ide-tests--state-at status 110) '(idle "Tests passed")))
    ;; idle_prompt keeps the reply
    (claude-code-ide-tests--feed-at
     status '((162 "Notification" "{\"notification_type\":\"idle_prompt\"}")))
    (should (equal (claude-code-ide-tests--state-at status 170) '(idle "Tests passed")))))

(ert-deftest claude-code-ide-test-status-tasks-subagent-lifecycle ()
  "A background subagent: start, internal helper stops, wake, stop."
  (let ((status (claude-code-ide-tests--feed-at
                 (claude-code-ide-tests--status)
                 `((1 "UserPromptSubmit" "{}")
                   (2 "PreToolUse" "{\"tool_name\":\"Agent\",\"tool_use_id\":\"m1\",\"tool_input\":{}}")
                   (3 "PostToolUse" "{\"tool_name\":\"Agent\",\"tool_use_id\":\"m1\",\"tool_input\":{}}")
                   (3 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a1"))
                   (4 "Stop" ,(claude-code-ide-tests--stop "Started an agent"
                                                           (claude-code-ide-tests--agent-task "a1" "Scan the repo")))
                   (5 "SubagentStop" ,(claude-code-ide-tests--subagent "SubagentStop" "zz" ""))
                   (6 "PreToolUse" ,(claude-code-ide-tests--agent-tool "PreToolUse" "a1" "s1"))))))
    (should (equal (claude-code-ide-tests--state-at status 10) '(tasks "1 agent: Scan the repo")))
    (claude-code-ide-tests--feed-at
     status `((40 "PostToolUse" ,(claude-code-ide-tests--agent-tool "PostToolUse" "a1" "s1"))
              (41 "UserPromptSubmit" "{}")
              (41 "SubagentStop" ,(claude-code-ide-tests--subagent "SubagentStop" "a1"))))
    (should (eq (car (claude-code-ide-tests--state-at status 42)) 'working))
    (claude-code-ide-tests--feed-at
     status `((43 "Stop" ,(claude-code-ide-tests--stop "The agent found 3 files"))))
    (should (equal (claude-code-ide-tests--state-at status 50) '(idle "The agent found 3 files")))))

(ert-deftest claude-code-ide-test-status-tasks-subagent-turns ()
  "A subagent that waits on its own subagents ends turns, not its life.
The main agent waits on it until its next Stop lists it no more."
  (let ((status (claude-code-ide-tests--feed-at
                 (claude-code-ide-tests--status)
                 `((1 "UserPromptSubmit" "{}")
                   (2 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a1"))
                   (3 "Stop" ,(claude-code-ide-tests--stop "The review agent runs"
                                                           (claude-code-ide-tests--agent-task "a1" "rp-review")))
                   ;; a1 starts a child and ends its turn to wait for it
                   (10 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "c1"))
                   (11 "SubagentStop" ,(claude-code-ide-tests--subagent "SubagentStop" "a1"))
                   (40 "SubagentStop" ,(claude-code-ide-tests--subagent "SubagentStop" "c1"))))))
    (should (equal (claude-code-ide-tests--state-at status 41) '(tasks "1 agent: rp-review")))
    ;; The child's report wakes a1, which works again
    (claude-code-ide-tests--feed-at
     status `((45 "PreToolUse" ,(claude-code-ide-tests--agent-tool "PreToolUse" "a1" "s1"))))
    (should (equal (claude-code-ide-tests--state-at status 50) '(tasks "1 agent: rp-review")))
    ;; a1 ends: the CLI wakes the main agent, whose Stop lists no task
    (claude-code-ide-tests--feed-at
     status `((90 "SubagentStop" ,(claude-code-ide-tests--subagent "SubagentStop" "a1"))
              (91 "UserPromptSubmit" "{}")
              (93 "Stop" ,(claude-code-ide-tests--stop "The review found 2 issues"))))
    (should (equal (claude-code-ide-tests--state-at status 95) '(idle "The review found 2 issues")))))

(ert-deftest claude-code-ide-test-status-tasks-snapshot-drops-killed ()
  "A Stop list without an agent drops that task; an open dialog stays.
The dialog may belong to a subagent of a subagent, which the list never
holds; idle_prompt clears it when no dialog is open."
  (let ((status (claude-code-ide-tests--feed-at
                 (claude-code-ide-tests--status)
                 `((1 "UserPromptSubmit" "{}")
                   (2 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a1"))
                   (2 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a2"))
                   (3 "PreToolUse" ,(claude-code-ide-tests--agent-tool "PreToolUse" "a2" "s2"))
                   (4 "PermissionRequest" "{\"agent_id\":\"a2\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}")
                   (5 "Stop" ,(claude-code-ide-tests--stop "Waiting" (claude-code-ide-tests--agent-task "a1")))))))
    (should (equal (mapcar #'claude-code-ide-session-status--task-id
                           (claude-code-ide-session-status--running-tasks status))
                   '("a1")))
    (should (eq (car (claude-code-ide-tests--state-at status 10)) 'waiting))
    (claude-code-ide-tests--feed-at
     status '((65 "Notification" "{\"notification_type\":\"idle_prompt\"}")))
    (should (eq (car (claude-code-ide-tests--state-at status 66)) 'tasks))))

(ert-deftest claude-code-ide-test-status-tasks-dialogs-and-wakes ()
  "A wake is no answer to a subagent's dialog; a user prompt ends a main one."
  (let ((status (claude-code-ide-tests--feed-at
                 (claude-code-ide-tests--status)
                 `((1 "UserPromptSubmit" "{}")
                   (2 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a1"))
                   (3 "Stop" ,(claude-code-ide-tests--stop "Started" (claude-code-ide-tests--agent-task "a1")))
                   (4 "PreToolUse" ,(claude-code-ide-tests--agent-tool "PreToolUse" "a1" "s1"))
                   (5 "PermissionRequest" "{\"agent_id\":\"a1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}")
                   (6 "UserPromptSubmit" "{}")
                   (7 "Stop" ,(claude-code-ide-tests--stop "Still waiting" (claude-code-ide-tests--agent-task "a1")))))))
    (should (equal (claude-code-ide-tests--state-at status 10) '(waiting "Bash: ls")))
    (claude-code-ide-tests--feed-at
     status `((20 "PostToolUse" ,(claude-code-ide-tests--agent-tool "PostToolUse" "a1" "s1"))))
    (should (eq (car (claude-code-ide-tests--state-at status 21)) 'tasks)))
  ;; Esc denial of a main dialog fires nothing; the next prompt ends it
  (let ((status (claude-code-ide-tests--feed
                 (claude-code-ide-tests--status)
                 (list '("UserPromptSubmit" "{}")
                       (claude-code-ide-tests--tool "PreToolUse" "t1")
                       (claude-code-ide-tests--permission)
                       '("UserPromptSubmit" "{\"prompt\":\"do something else\"}")))))
    (should (eq (car (claude-code-ide-tests--state status)) 'working))))

(ert-deftest claude-code-ide-test-status-tasks-unmatched-permission ()
  "A subagent dialog without a known tool survives the main Stop."
  (let ((status (claude-code-ide-tests--feed-at
                 (claude-code-ide-tests--status)
                 `((1 "UserPromptSubmit" "{}")
                   (2 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a1"))
                   (3 "PermissionRequest" "{\"agent_id\":\"a1\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/x\"}}")
                   (4 "Stop" ,(claude-code-ide-tests--stop "Started" (claude-code-ide-tests--agent-task "a1")))))))
    (should (eq (car (claude-code-ide-tests--state-at status 10)) 'waiting))
    (claude-code-ide-tests--feed-at
     status `((30 "SubagentStop" ,(claude-code-ide-tests--subagent "SubagentStop" "a1"))))
    ;; Its turn ended, so its dialog closed; the main agent still waits on it
    (should (eq (car (claude-code-ide-tests--state-at status 31)) 'tasks))))

(ert-deftest claude-code-ide-test-status-tasks-quiet-boundaries ()
  "Subagents are quiet after 600 s without any subagent event, or 900 s
inside one tool call.  A shell never makes the session quiet."
  (let ((claude-code-ide-session-status-agent-quiet-time 600)
        (claude-code-ide-session-status-task-quiet-time 900))
    ;; A subagent that runs no tool: 600 s
    (let ((status (claude-code-ide-tests--feed-at
                   (claude-code-ide-tests--status)
                   `((1 "UserPromptSubmit" "{}")
                     (10 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a1"))
                     (11 "Stop" ,(claude-code-ide-tests--stop "Started" (claude-code-ide-tests--agent-task "a1")))))))
      ;; The clock starts when the Stop lists the task (second 11)
      (should (eq (car (claude-code-ide-tests--state-at status 611)) 'tasks))
      (should (equal (claude-code-ide-tests--state-at status 612)
                     '(tasks-quiet "No activity for 10m: Task a1"))))
    ;; A subagent in one long tool call: 900 s
    (let ((status (claude-code-ide-tests--feed-at
                   (claude-code-ide-tests--status)
                   `((1 "UserPromptSubmit" "{}")
                     (10 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a1"))
                     (11 "Stop" ,(claude-code-ide-tests--stop "Started" (claude-code-ide-tests--agent-task "a1")))
                     (20 "PreToolUse" ,(claude-code-ide-tests--agent-tool "PreToolUse" "a1" "s1"))))))
      (should (eq (car (claude-code-ide-tests--state-at status 919)) 'tasks))
      (should (eq (car (claude-code-ide-tests--state-at status 921)) 'tasks-quiet)))
    ;; A shell never makes the session quiet; only the subagent's clock counts
    (let ((status (claude-code-ide-tests--feed-at
                   (claude-code-ide-tests--status)
                   `((1 "UserPromptSubmit" "{}")
                     (10 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a2"))
                     (11 "Stop" ,(claude-code-ide-tests--stop "Started"
                                                              (claude-code-ide-tests--shell-task "b1")
                                                              (claude-code-ide-tests--agent-task "a2")))
                     (905 "PreToolUse" ,(claude-code-ide-tests--agent-tool "PreToolUse" "a2" "s2"))))))
      (should (eq (car (claude-code-ide-tests--state-at status 1500)) 'tasks))
      (should (eq (car (claude-code-ide-tests--state-at status 1806)) 'tasks-quiet))
      (should (claude-code-ide-session-status--urgent-p 'tasks-quiet)))))

(ert-deftest claude-code-ide-test-status-tasks-snapshot-keeps-age ()
  "A later Stop keeps a task's first time; a wake is no subagent activity."
  (let ((claude-code-ide-session-status-agent-quiet-time 600)
        (status (claude-code-ide-tests--feed-at
                 (claude-code-ide-tests--status)
                 `((1 "UserPromptSubmit" "{}")
                   (10 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a1"))
                   (11 "Stop" ,(claude-code-ide-tests--stop "Started" (claude-code-ide-tests--agent-task "a1")))
                   (300 "UserPromptSubmit" "{}")
                   (301 "Stop" ,(claude-code-ide-tests--stop "Still running" (claude-code-ide-tests--agent-task "a1")))))))
    (should (= 11.0 (claude-code-ide-session-status--task-first-seen
                     (car (claude-code-ide-session-status--running-tasks status)))))
    (should (eq (car (claude-code-ide-tests--state-at status 611)) 'tasks))
    (should (eq (car (claude-code-ide-tests--state-at status 612)) 'tasks-quiet))))

(ert-deftest claude-code-ide-test-status-tasks-reset-and-compact ()
  "Compaction keeps the tasks; /clear drops them."
  (let ((status (claude-code-ide-tests--feed-at
                 (claude-code-ide-tests--status)
                 `((1 "UserPromptSubmit" "{}")
                   (2 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a1"))
                   (3 "Stop" ,(claude-code-ide-tests--stop "Started" (claude-code-ide-tests--agent-task "a1")))
                   (4 "SessionStart" "{\"source\":\"compact\"}")))))
    (should (eq (car (claude-code-ide-tests--state-at status 10)) 'tasks))
    (claude-code-ide-tests--feed-at status '((20 "SessionStart" "{\"source\":\"clear\"}")))
    (should (equal (claude-code-ide-tests--state-at status 21) '(idle "Ready")))))

(ert-deftest claude-code-ide-test-status-tasks-interrupt-with-busy-subagent ()
  "Subagent events do not hide an interrupt of the main agent."
  (claude-code-ide-tests--with-status
    (let* ((claude-code-ide-session-status-quiet-time 5)
           (terminal (generate-new-buffer "*cc-terminal*"))
           (status (claude-code-ide-tests--status)))
      (unwind-protect
          (progn
            (setf (claude-code-ide-session-status-session status)
                  (make-claude-code-ide-mcp-session :buffer terminal))
            (with-current-buffer terminal
              (insert "  ⎿  Interrupted · What should Claude do instead?\n> \n"))
            (claude-code-ide-tests--feed-at
             status `((0 "SubagentStart" ,(claude-code-ide-tests--subagent "SubagentStart" "a1"))
                      (0 "Stop" ,(claude-code-ide-tests--stop "Started" (claude-code-ide-tests--agent-task "a1")))
                      (1 "UserPromptSubmit" "{}")
                      (8 "PreToolUse" ,(claude-code-ide-tests--agent-tool "PreToolUse" "a1" "s1"))
                      (9 "PostToolUse" ,(claude-code-ide-tests--agent-tool "PostToolUse" "a1" "s1"))))
            (should (claude-code-ide-session-status--check-interrupt status 10.0))
            ;; The guess stands against further subagent tool events
            (claude-code-ide-tests--feed-at
             status `((11 "PreToolUse" ,(claude-code-ide-tests--agent-tool "PreToolUse" "a1" "s2"))))
            (should (claude-code-ide-session-status-guessed status))
            (should (eq (car (claude-code-ide-tests--state-at status 12)) 'tasks)))
        (kill-buffer terminal)))))

(ert-deftest claude-code-ide-test-status-tasks-labels-and-order ()
  "The labels say who waits for whom; quiet tasks rank above a finished turn."
  (should (equal (mapcar (lambda (state)
                           (car (alist-get state claude-code-ide-session-status--labels)))
                         '(waiting asks error unobserved tasks-quiet idle tasks starting working untracked))
                 '("NEEDS ANSWER" "ASKS YOU" "FAILED" "NO SIGNAL" "TASKS QUIET" "WAITS FOR YOU"
                   "WAITS ON TASKS" "STARTING" "WORKING" "UNTRACKED")))
  (should (< (alist-get 'tasks-quiet claude-code-ide-session-status--rank)
             (alist-get 'idle claude-code-ide-session-status--rank)
             (alist-get 'tasks claude-code-ide-session-status--rank)))
  (should-not (claude-code-ide-session-status--urgent-p 'tasks))
  (should-not (claude-code-ide-session-status--urgent-p 'idle))
  ;; The Status column fits every label
  (with-temp-buffer
    (claude-code-ide-session-status-list-mode)
    (let ((width (nth 1 (aref tabulated-list-format 0))))
      (dolist (entry claude-code-ide-session-status--labels)
        (should (<= (string-width (nth 1 entry)) width))))))

(ert-deftest claude-code-ide-test-status-turn-without-prompt-hook ()
  "A main-agent tool event while idle starts a turn that fired no prompt hook.
A queued prompt, a cross-session message or a task notification starts
a turn without UserPromptSubmit."
  (let ((status (claude-code-ide-tests--feed
                 (claude-code-ide-tests--status)
                 (list '("UserPromptSubmit" "{}")
                       '("Stop" "{\"last_assistant_message\":\"Done\"}")))))
    (should (eq (car (claude-code-ide-tests--state status)) 'idle))
    (claude-code-ide-tests--feed status (list (claude-code-ide-tests--tool "PreToolUse" "t5")))
    (should (equal (claude-code-ide-tests--state status) '(working "Working: Bash")))))

(defun claude-code-ide-tests--user-record (content &rest fields)
  "Return a transcript line of a user record with CONTENT and FIELDS.
CONTENT is a JSON value as text; FIELDS are extra \"key\":value texts."
  (format "{\"type\":\"user\"%s,\"message\":{\"role\":\"user\",\"content\":%s}}\n"
          (mapconcat (lambda (field) (concat "," field)) fields "")
          content))

(ert-deftest claude-code-ide-test-status-prompt-records ()
  "Records that start a turn make an idle session work; others do not."
  (should (claude-code-ide-session-status--prompt-record-p
           (claude-code-ide-tests--user-record
            "\"Another Claude session sent a message: please rebase\"" "\"isMeta\":true")))
  (should (claude-code-ide-session-status--prompt-record-p
           (claude-code-ide-tests--user-record
            "\"<task-notification>\\n<task-id>b1</task-id>\\n</task-notification>\"")))
  (should (claude-code-ide-session-status--prompt-record-p
           (claude-code-ide-tests--user-record "[{\"type\":\"text\",\"text\":\"Queued: next step\"}]")))
  (dolist (record (list
                   ;; /rename and its caveat
                   (claude-code-ide-tests--user-record
                    "\"<command-name>/rename</command-name>\\n<command-args>x</command-args>\"")
                   (claude-code-ide-tests--user-record
                    "\"<local-command-stdout>Session renamed to: x</local-command-stdout>\"")
                   (claude-code-ide-tests--user-record
                    "\"<local-command-caveat>Caveat: local commands</local-command-caveat>\"" "\"isMeta\":true")
                   ;; A shell command typed with !
                   (claude-code-ide-tests--user-record "\"<bash-input>ls</bash-input>\"")
                   (claude-code-ide-tests--user-record "\"<bash-stdout>a.txt</bash-stdout><bash-stderr></bash-stderr>\"")
                   ;; A manual /compact
                   (claude-code-ide-tests--user-record "\"Summary of the conversation\"" "\"isCompactSummary\":true")
                   ;; A tool result and the interrupt record
                   (claude-code-ide-tests--user-record
                    "[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"ok\"}]")
                   (claude-code-ide-tests--user-record
                    "[{\"type\":\"text\",\"text\":\"[Request interrupted by user]\"}]")))
    (should-not (claude-code-ide-session-status--prompt-record-p record))))

(ert-deftest claude-code-ide-test-status-idle-session-sees-new-turn ()
  "An idle session whose transcript gains a cross-session message works."
  (claude-code-ide-tests--with-status
    (let* ((transcript (expand-file-name "t.jsonl" registry-dir))
           (status (claude-code-ide-tests--status)))
      (with-temp-file transcript (insert "{\"type\":\"system\"}\n"))
      (claude-code-ide-tests--feed
       status (list (list "SessionStart" (format "{\"source\":\"startup\",\"transcript_path\":\"%s\"}"
                                                 transcript))
                    '("UserPromptSubmit" "{}")
                    '("Stop" "{\"last_assistant_message\":\"Done\"}")))
      ;; /rename while idle: still idle
      (write-region (claude-code-ide-tests--user-record
                     "\"<command-name>/rename</command-name>\\n<command-args>x</command-args>\"")
                    nil transcript t 'silent)
      (should-not (claude-code-ide-session-status--check-interrupt status 20.0))
      (should (eq (car (claude-code-ide-tests--state status)) 'idle))
      ;; A message from another session starts a turn
      (write-region (claude-code-ide-tests--user-record
                     "\"Another Claude session sent a message: please rebase\"" "\"isMeta\":true")
                    nil transcript t 'silent)
      (should (claude-code-ide-session-status--check-interrupt status 30.0))
      (should (eq (car (claude-code-ide-tests--state status)) 'working)))))

(ert-deftest claude-code-ide-test-status-reply-questions ()
  "Questions are lines that end with a question mark, outside code blocks."
  (should (equal (claude-code-ide-session-status--questions
                  (concat "Round 6 was clean.\n\n"
                          "1. **Should I force-push the rebased branch?**\n"
                          "- Or do you want a new PR?\n"
                          "```python\nif x is None:  # why?\n```\n"
                          "The tests run in the background (see `pytest`).\n"
                          "Do you agree (yes/no)?"))
                 '("Should I force-push the rebased branch?"
                   "Or do you want a new PR?"
                   "Do you agree (yes/no)?")))
  (should-not (claude-code-ide-session-status--questions "Done. The file is fixed."))
  (should-not (claude-code-ide-session-status--questions nil)))

(ert-deftest claude-code-ide-test-status-asks-you-with-tasks ()
  "A reply with questions waits for the user, even while a shell runs."
  (let ((status (claude-code-ide-tests--feed-at
                 (claude-code-ide-tests--status)
                 `((1 "UserPromptSubmit" "{}")
                   (4 "Stop" ,(claude-code-ide-tests--stop
                               "Round 6 was clean.\\nShould I force-push?\\nOr open a new PR?"
                               (claude-code-ide-tests--shell-task "b1" "Run the broad set")))))))
    (should (equal (claude-code-ide-tests--state-at status 2000)
                   '(asks "Asks 2 questions: Should I force-push? · 1 shell running")))
    (should (claude-code-ide-session-status--urgent-p 'asks))
    ;; idle_prompt keeps the questions; the user's answer ends them
    (claude-code-ide-tests--feed-at status '((64 "Notification" "{\"notification_type\":\"idle_prompt\"}")))
    (should (eq (car (claude-code-ide-tests--state-at status 70)) 'asks))
    (claude-code-ide-tests--feed-at status '((80 "UserPromptSubmit" "{}")))
    (should (eq (car (claude-code-ide-tests--state-at status 81)) 'working))
    ;; A reply without questions while the shell runs
    (claude-code-ide-tests--feed-at
     status `((90 "Stop" ,(claude-code-ide-tests--stop
                           "Force-pushed. I wait for the tests."
                           (claude-code-ide-tests--shell-task "b1" "Run the broad set")))))
    (should (equal (claude-code-ide-tests--state-at status 95)
                   '(idle "Force-pushed. I wait for the tests. · 1 shell running")))
    ;; A custom regexp: the user's own closing line asks for an answer
    (let ((claude-code-ide-session-status-ask-regexps '("\\?\\'" "\\`Next for Raymond:")))
      (should (equal (claude-code-ide-session-status--questions
                      "Three decisions in the tab.\n**Next for Raymond:** answer in the tab and press Send.")
                     '("Next for Raymond:** answer in the tab and press Send."))))))

(ert-deftest claude-code-ide-test-status-session-label ()
  "A row shows the instance name, else the user's title, else the project."
  (claude-code-ide-tests--with-status
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (claude-code-ide-session-status--title-cache (make-hash-table :test 'eql))
           (named (make-claude-code-ide-mcp-session
                   :project-dir "/tmp/k-and-e-transaction-management-platform/"
                   :instance-name "Azure block storage events" :cli-pid (emacs-pid)))
           (titled (make-claude-code-ide-mcp-session :project-dir "/tmp/proj/" :cli-pid (emacs-pid)))
           (plain (make-claude-code-ide-mcp-session :project-dir "/tmp/proj/")))
      (claude-code-ide-tests--cli-session-file config-dir "id1" "DEAL-1/fix" "user")
      (should (equal (claude-code-ide-session-status--session-label named) "Azure block storage events"))
      (should (equal (claude-code-ide-session-status--session-label titled) "DEAL-1/fix"))
      (should (equal (claude-code-ide-session-status--session-label plain) "proj"))
      ;; A name that the CLI derived is no title
      (claude-code-ide-tests--cli-session-file config-dir "id1" "proj-2d" "derived")
      (clrhash claude-code-ide-session-status--title-cache)
      (should (equal (claude-code-ide-session-status--session-label titled) "proj")))))

(ert-deftest claude-code-ide-test-status-unobserved-and-untracked ()
  "A session without events is unobserved after the timeout."
  (let ((status (claude-code-ide-tests--status 0.0))
        (claude-code-ide-session-status-start-timeout 15))
    (should (eq (claude-code-ide-session-status--state status 10.0) 'starting))
    (should (eq (claude-code-ide-session-status--state status 20.0) 'unobserved))
    (should (eq (claude-code-ide-session-status--state nil 20.0) 'untracked))))

(ert-deftest claude-code-ide-test-status-interrupt-from-transcript ()
  "A quiet working session reads only new transcript text for an interrupt."
  (claude-code-ide-tests--with-status
    (let* ((transcript (expand-file-name "t.jsonl" registry-dir))
           (claude-code-ide-session-status-quiet-time 5)
           (terminal (generate-new-buffer "*cc-terminal*"))
           (status (claude-code-ide-tests--status)))
      (unwind-protect
          (progn
            (setf (claude-code-ide-session-status-session status)
                  (make-claude-code-ide-mcp-session :buffer terminal))
            (with-current-buffer terminal
              (insert "⏺ Reading the files\n\n✢ Misting… (12s · ↓ 330 tokens)\n\n> \n"))
            (with-temp-file transcript
              (insert "{\"text\":\"[Request interrupted by user] from an old turn\"}\n"))
            (claude-code-ide-tests--feed
             status (list (list "SessionStart" (format "{\"source\":\"startup\",\"transcript_path\":\"%s\"}"
                                                       transcript))
                          '("UserPromptSubmit" "{}")))
            ;; Not quiet long enough; then quiet, but the spinner shows work
            ;; and the old marker is before the offset
            (should-not (claude-code-ide-session-status--check-interrupt status 3.0))
            (should-not (claude-code-ide-session-status--check-interrupt status 20.0))
            (should (eq (claude-code-ide-session-status-phase status) 'working))
            ;; The marker inside a tool result (a file Claude read) does not count
            (write-region (concat "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":"
                                  "[{\"type\":\"tool_result\",\"content\":\"[Request interrupted by user] in a file\"}]}}\n")
                          nil transcript t 'silent)
            (should-not (claude-code-ide-session-status--check-interrupt status 25.0))
            ;; An interrupt during a tool writes the CLI's record (measured shape)
            (write-region (concat "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":"
                                  "[{\"type\":\"text\",\"text\":\"[Request interrupted by user for tool use]\"}]}}\n")
                          nil transcript t 'silent)
            (should (claude-code-ide-session-status--check-interrupt status 30.0))
            (should (equal (claude-code-ide-tests--state status) '(idle "Interrupted")))
            ;; An interrupt during an answer leaves no record: the spinner is gone
            (claude-code-ide-tests--feed status '(("UserPromptSubmit" "{}")))
            (should-not (claude-code-ide-session-status--check-interrupt status 40.0))
            (with-current-buffer terminal
              (erase-buffer)
              (insert "⏺ Partial answer\n  ⎿  Interrupted · What should Claude do instead?\n\n> \n"))
            (should (claude-code-ide-session-status--check-interrupt status 50.0))
            (should (equal (claude-code-ide-tests--state status) '(idle "Interrupted?")))
            ;; The guess ends when the spinner shows again, even below many
            ;; blank rows, or when a tool event arrives
            (with-current-buffer terminal
              (insert "✳ Whisking… (3s · thinking)\n" (make-string 45 ?\n)))
            (should (claude-code-ide-session-status--check-interrupt status 52.0))
            (should (eq (car (claude-code-ide-tests--state status)) 'working))
            (with-current-buffer terminal (erase-buffer))
            (should (claude-code-ide-session-status--check-interrupt status 60.0))
            (claude-code-ide-tests--feed status (list (claude-code-ide-tests--tool "PreToolUse" "t9")))
            (should (eq (car (claude-code-ide-tests--state status)) 'working)))
        (kill-buffer terminal)))))

(ert-deftest claude-code-ide-test-status-hook-script ()
  "The script numbers parallel events without gaps, prints nothing, exits 0."
  (claude-code-ide-tests--with-status
    (claude-code-ide-session-status--install-script)
    (let* ((script (claude-code-ide-session-status--script-file))
           (dir (expand-file-name "events" registry-dir))
           ;; The script gives up after a time limit.  Here `sleep'
           ;; returns only when the lock is free, so each writer tries
           ;; once per release, however slow the machine is.
           (bin (expand-file-name "bin" registry-dir))
           (process-environment
            (progn
              (make-directory bin t)
              (with-temp-file (expand-file-name "sleep" bin)
                (insert "#!/bin/sh\n"
                        "i=0\n"
                        "while [ -d " (shell-quote-argument (expand-file-name ".n1.lock" dir))
                        " ] && [ $i -lt 6000 ]; do /bin/sleep 0.01; i=$((i + 1)); done\n"))
              (set-file-modes (expand-file-name "sleep" bin) #o700)
              (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment)))
           (output
            (with-temp-buffer
              (list (call-process
                     "sh" nil t nil "-c"
                     (format "i=0; while [ $i -lt 20 ]; do echo '{\"n\":1}' | sh %s %s n1 Stop & i=$((i+1)); done; wait"
                             (shell-quote-argument script) (shell-quote-argument dir)))
                    (buffer-string))))
           (files (directory-files dir nil "\\`n1-[0-9]+-Stop\\.json\\'")))
      (should (equal output '(0 "")))
      (should (equal (mapcar (lambda (file) (string-to-number (substring file 3 11))) files)
                     (number-sequence 1 20)))
      (should (equal (claude-code-ide-session-status--read-event (expand-file-name (car files) dir))
                     '((n . 1))))
      ;; A directory that cannot be made: still no output and exit 0
      (with-temp-buffer
        (should (= 0 (call-process "sh" nil t nil "-c"
                                   (format "echo '{}' | sh %s /dev/null/x n2 Stop"
                                           (shell-quote-argument script)))))
        (should (equal (buffer-string) ""))))))

(defconst claude-code-ide-tests--script-writers 20
  "Parallel writers that a hook script must serve without a lost event.")

(defconst claude-code-ide-tests--script-hold 0.1
  "Seconds that one writer holds the lock of a hook script at most.
It runs echo, cat, two mv and rm; that takes a few milliseconds on an
idle machine.")

(defun claude-code-ide-tests--script-lock-budget (script)
  "Check the lock section of the hook SCRIPT text.
It waits by real time and by a cap of tries, reads the clock at each
try of 50 ms, breaks a dead lock only with the break token, lets a
child sh hold the lock with its own PID, and rotates its error log.
The limit must also outlast the time that all other writers hold the
lock."
  (let ((number (lambda (name)
                  (and (string-match (format "^  %s=\\([0-9]+\\)$" name) script)
                       (string-to-number (match-string 1 script)))))
        (limit (claude-code-ide-session-status--hook-limit)))
    (should (equal (funcall number "limit") limit))
    (should (equal (funcall number "cap") (* 20 limit)))
    (should (< (funcall number "brk") limit))
    (dolist (part '("start=$(date +%s)" "now=$(date +%s)" "-gt \"$limit\" ] || [ \"$tries\" -ge \"$cap\""
                    "if [ \"$waited\" -lt 0 ]; then waited=$((limit + 1)); fi"
                    "if [ -z \"$start\" ] && [ -n \"$now\" ]; then start=$now; fi"
                    "mkdir \"$lock.break\"" "rmdir \"$lock.break\""
                    "sh -c 'echo $$ > \"$1/pid\"" "mv -f \"$log\" \"$log.1\"" "sleep 0.05"))
      (should (string-search part script)))
    (should (>= limit (* (1- claude-code-ide-tests--script-writers)
                         claude-code-ide-tests--script-hold)))))

(ert-deftest claude-code-ide-test-status-hook-script-lock-budget ()
  "The time limit of the status hook script gives 20 parallel writers enough time.
The parallel test above makes the waits independent of the speed of
the machine; this test checks the numbers of the real loop."
  (claude-code-ide-tests--script-lock-budget (claude-code-ide-session-status--script-text)))

(ert-deftest claude-code-ide-test-status-drain-applies-in-order ()
  "Events are applied in sequence order; unknown launches are deleted."
  (claude-code-ide-tests--with-status
    (let* ((session (make-claude-code-ide-mcp-session))
           (hooks (claude-code-ide-session-status--hooks session "key-1"))
           (status (gethash session claude-code-ide-session-status--by-session))
           (nonce (claude-code-ide-session-status-nonce status))
           (dir (claude-code-ide-session-status--events-directory)))
      (should (equal (mapcar #'car hooks) claude-code-ide-session-status--events))
      (should (string-match-p (regexp-quote nonce) (cadr (assoc "Stop" hooks))))
      (make-directory dir t)
      (dolist (event `((2 "PermissionRequest" ,(cadr (claude-code-ide-tests--permission)))
                       (1 "PreToolUse" ,(cadr (claude-code-ide-tests--tool "PreToolUse" "t1")))
                       (3 "Stop" "{\"last_assistant_message\":\"Done\"}")))
        (with-temp-file (expand-file-name (format "%s-%08d-%s.json" nonce (car event) (cadr event)) dir)
          (insert (nth 2 event))))
      (with-temp-file (expand-file-name "ffffffffffff-00000001-Stop.json" dir)
        (insert "{}"))
      (claude-code-ide-session-status--drain)
      ;; The request matched the tool, so Stop closed it: idle
      (should (equal (claude-code-ide-tests--state status) '(idle "Done")))
      (should-not (directory-files dir nil "\\.json\\'"))
      ;; The end of the session removes it and its files
      (with-temp-file (expand-file-name (format ".%s.seq" nonce) dir) (insert "3"))
      (claude-code-ide-session-status--on-end session 'exited)
      (should-not (gethash nonce claude-code-ide-session-status--by-nonce))
      (should-not (directory-files dir nil (regexp-quote nonce))))))

(ert-deftest claude-code-ide-test-status-settings-argument ()
  "Tracking adds every status hook, with a timeout, to the one --settings."
  (claude-code-ide-tests--with-status
    (let ((claude-code-ide-session-registry-hook-functions
           (list #'claude-code-ide-session-status--hooks))
          (claude-code-ide-cli-extra-flags ""))
      (cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) #'ignore))
        (let* ((session (make-claude-code-ide-mcp-session))
               (args (claude-code-ide-session-registry--cli-args
                      session (claude-code-ide-tests--registry-spec)))
               (parts (claude-code-ide--split-command-line
                       (claude-code-ide--build-claude-command nil nil "sid" args)))
               (hooks (alist-get 'hooks (claude-code-ide-session-registry--json-decode
                                         (cadr (member "--settings" parts))))))
          (should (= 1 (cl-count "--settings" parts :test #'equal)))
          (dolist (event claude-code-ide-session-status--events)
            (let ((commands (alist-get 'hooks (car (alist-get (intern event) hooks)))))
              (should commands)
              (dolist (command commands)
                (should (equal (alist-get 'timeout command)
                               (claude-code-ide-session-status--hook-cli-timeout)))
                (should (> (alist-get 'timeout command)
                           claude-code-ide-session-status-hook-time-limit)))))
          ;; SessionStart has the id report and the status event
          (should (= 2 (length (alist-get 'hooks (car (alist-get 'SessionStart hooks))))))
          (should (gethash session claude-code-ide-session-status--by-session)))))))

(ert-deftest claude-code-ide-test-status-buffer-order-and-visit ()
  "Sessions are grouped by project, the most urgent project first.
RET goes to the session on the line, or to the first session of a
project line."
  (claude-code-ide-tests--clear-processes)
  (claude-code-ide-tests--with-status
    (let* ((buffers (list (generate-new-buffer "*cc-work*")
                          (generate-new-buffer "*cc-wait*")
                          (generate-new-buffer "*cc-plain*")
                          (generate-new-buffer "*cc-wait-2*")))
           (working (claude-code-ide-tests--make-session "/tmp/status-a/" :buffer (nth 0 buffers)))
           (waiting (claude-code-ide-tests--make-session "/tmp/status-b/" :buffer (nth 1 buffers)))
           (plain (claude-code-ide-tests--make-session "/tmp/status-c/" :buffer (nth 2 buffers)))
           (sibling (claude-code-ide-tests--make-session "/tmp/status-b/" :buffer (nth 3 buffers)
                                                         :instance-name "docs"))
           (visited nil))
      (unwind-protect
          (progn
            (claude-code-ide-session-status--hooks working "k1")
            (claude-code-ide-session-status--hooks waiting "k2")
            (claude-code-ide-tests--feed (gethash working claude-code-ide-session-status--by-session)
                                         '(("UserPromptSubmit" "{}")))
            (claude-code-ide-tests--feed (gethash waiting claude-code-ide-session-status--by-session)
                                         (list '("UserPromptSubmit" "{}")
                                               (claude-code-ide-tests--tool "PreToolUse" "t1")
                                               (claude-code-ide-tests--permission)))
            ;; The two untracked sessions have no time, so their order is open
            (let ((rows (mapcar (lambda (row) (list (car row) (nth 1 row)))
                                (claude-code-ide-session-status--rows))))
              (should (equal (cl-subseq rows 0 2)
                             (list (list waiting 'waiting) (list working 'working))))
              (should-not (cl-set-exclusive-or (cl-subseq rows 2)
                                               (list (list plain 'untracked) (list sibling 'untracked))
                                               :test #'equal)))
            (cl-letf (((symbol-function 'claude-code-ide--display-buffer-in-side-window)
                       (lambda (buffer) (setq visited buffer) (selected-window)))
                      ((symbol-function 'display-buffer) #'ignore))
              (claude-code-ide-show-session-status)
              (should (= claude-code-ide-session-status--urgent-count 1))
              (should (string-match-p "1 need you" (claude-code-ide-session-status--lighter)))
              (with-current-buffer claude-code-ide-session-status--buffer-name
                ;; One header per project, then its sessions
                (goto-char (point-min))
                (let ((ids nil))
                  (while (not (eobp))
                    (push (tabulated-list-get-id) ids)
                    (forward-line 1))
                  (setq ids (nreverse ids))
                  (should (equal (mapcar (lambda (id)
                                           (if (claude-code-ide-session-status--group-p id)
                                               (claude-code-ide-session-status--group-directory id)
                                             id))
                                         ids)
                                 (list "/tmp/status-b/" waiting sibling
                                       "/tmp/status-a/" working
                                       "/tmp/status-c/" plain))))
                ;; Session lines are indented under their project line
                (goto-char (point-min))
                (forward-line 1)
                (should (looking-at-p "  NEEDS ANSWER"))
                (goto-char (point-min))
                (should (string-prefix-p "status-b  2 sessions"
                                         (buffer-substring-no-properties
                                          (point) (line-end-position))))
                ;; RET on the project line goes to its first session
                (claude-code-ide-session-status-visit))
              (should (eq visited (nth 1 buffers)))
              (setq visited nil)
              ;; Visiting selects a window, which changes the current buffer
              (with-current-buffer claude-code-ide-session-status--buffer-name
                (goto-char (point-min))
                (forward-line 2)
                (should (eq (tabulated-list-get-id) sibling))
                (claude-code-ide-session-status-visit))
              (should (eq visited (nth 3 buffers)))
              ;; A click on a status label goes to the session of its line
              (setq visited nil)
              (with-current-buffer claude-code-ide-session-status--buffer-name
                (goto-char (point-min))
                (forward-line 1)
                (let ((label-pos (+ (point) claude-code-ide-session-status-indent)))
                  (should (eq (get-text-property label-pos 'mouse-face) 'highlight))
                  (should (eq (lookup-key (get-text-property label-pos 'keymap) [mouse-1])
                              #'claude-code-ide-session-status-visit-click))
                  (goto-char (point-max))
                  (cl-letf (((symbol-function 'mouse-set-point)
                             (lambda (_event) (goto-char label-pos))))
                    (claude-code-ide-session-status-visit-click '(mouse-1 nil)))))
              (should (eq visited (nth 1 buffers)))
              (setq visited nil)
              (claude-code-ide-visit-waiting-session)
              (should (eq visited (nth 1 buffers)))))
        (when claude-code-ide-session-status-mode
          (cl-letf (((symbol-function 'claude-code-ide-session-status--stop-timers) #'ignore))
            (claude-code-ide-session-status-mode -1)))
        (when claude-code-ide-session-registry-mode
          (claude-code-ide-session-registry-mode -1))
        (mapc #'kill-buffer buffers)
        (claude-code-ide-tests--clear-processes)))))

;;; The time limit of the hook scripts

(defun claude-code-ide-tests--held-lock-run (script args lock environment)
  "Run the hook SCRIPT with ARGS while a live process holds LOCK.
ENVIRONMENT holds more \"NAME=VALUE\" entries.  The holder is this
Emacs, which runs.  Return (EXIT OUTPUT SECONDS) of the run."
  (make-directory lock t)
  (with-temp-file (expand-file-name "pid" lock) (insert (format "%d\n" (emacs-pid))))
  (let ((process-environment (append environment process-environment))
        (start (float-time)))
    (with-temp-buffer
      (insert "{\"session_id\":\"cci-test-held\"}")
      (let ((exit (apply #'call-process-region (point-min) (point-max) "/bin/sh" t t nil
                         script args)))
        (list exit (buffer-string) (- (float-time) start))))))

(ert-deftest claude-code-ide-test-status-hook-script-time-limit ()
  "A hook whose lock stays held gives up after about the time limit, and exits 0.
The script is a shell process, so the virtual clock of the tests cannot
drive it; the check uses real time with a generous bound.  The hook
drops its event, removes its temporary file, and writes one line to
hook-errors.log in the events folder."
  (claude-code-ide-tests--with-status
    (let ((claude-code-ide-session-status-hook-time-limit 1))
      (claude-code-ide-session-status--install-script)
      (let* ((script (claude-code-ide-session-status--script-file))
             (dir (expand-file-name "events" registry-dir))
             (result (claude-code-ide-tests--held-lock-run
                      script (list dir "n4" "Stop") (expand-file-name ".n4.lock" dir) nil)))
        (should (equal (butlast result) '(0 "")))
        ;; More than the limit, and far less than a count of tries on a slow machine
        (should (>= (nth 2 result) 0.9))
        (should (< (nth 2 result) 20))
        (should-not (directory-files dir nil "\\`n4-"))
        (should-not (directory-files dir nil "\\`\\.n4\\.in\\."))
        (let ((log (claude-code-ide-session-registry--file-string
                    (expand-file-name "hook-errors.log" dir))))
          (should (string-match-p "Stop: no lock after [0-9]+ s .*\\.n4\\.lock); event dropped\n\\'" log))
          (should (= 1 (length (split-string log "\n" t)))))))))

(ert-deftest claude-code-ide-test-status-hook-script-holds-the-limit ()
  "Emacs writes the time limit into the installed script, and the launch check sees it."
  (claude-code-ide-tests--with-status
    (let ((file (claude-code-ide-session-status--script-file)))
      (let ((claude-code-ide-session-status-hook-time-limit 7))
        (claude-code-ide-session-status--install-script)
        (should (string-match-p "^  limit=7$" (claude-code-ide-session-registry--file-string file)))
        (claude-code-ide-tests--script-lock-budget (claude-code-ide-session-status--script-text)))
      ;; Another value: the next install writes it
      (let ((claude-code-ide-session-status-hook-time-limit 10))
        (claude-code-ide-session-status--install-script)
        (should (equal (claude-code-ide-session-registry--file-string file)
                       (claude-code-ide-session-status--script-text)))
        (should (string-match-p "^  limit=10$" (claude-code-ide-session-registry--file-string file))))
      ;; The default is 10 seconds, and the hook command has no limit in it
      (should (= (default-value 'claude-code-ide-session-status-hook-time-limit) 10))
      (should-not (string-match-p "limit" (claude-code-ide-session-status--command "n5" "Stop"))))))

;;; Review fixes of the hook time limit

(defun claude-code-ide-tests--shim-bin (dir &rest programs)
  "Write shell PROGRAMS into DIR/bin, and return the PATH entry for them.
Each element of PROGRAMS is (NAME . BODY), BODY a shell text after #!/bin/sh."
  (let ((bin (expand-file-name "bin" dir)))
    (make-directory bin t)
    (dolist (program programs)
      (let ((file (expand-file-name (car program) bin)))
        (with-temp-file file (insert "#!/bin/sh\n" (cdr program)))
        (set-file-modes file #o700)))
    (concat "PATH=" bin ":" (getenv "PATH"))))

(defun claude-code-ide-tests--run-guarded (shell script args environment &optional seconds)
  "Run SCRIPT with ARGS under SHELL, with ENVIRONMENT, at most SECONDS (15).
A script that does not end in time is killed.  Return (ENDED EXIT
SECONDS)."
  (let* ((process-environment (append environment process-environment))
         (start (float-time))
         (process (make-process :name "cci-test-hook" :command (append (list shell script) args)
                                :connection-type 'pipe :noquery t :buffer nil)))
    (process-send-string process "{}")
    (process-send-eof process)
    (let ((ended (claude-code-ide-tests--wait-until
                  (lambda () (not (process-live-p process))) (or seconds 15))))
      (unless ended (delete-process process))
      (list (and ended t) (and ended (process-exit-status process)) (- (float-time) start)))))

(defmacro claude-code-ide-tests--with-hook-dir (&rest body)
  "Run BODY with the CC hook script installed for a limit of 1 s.
BODY sees `script', the events folder `dir', and `registry-dir'."
  (declare (indent 0))
  `(claude-code-ide-tests--with-status
     (let ((claude-code-ide-session-status-hook-time-limit 1))
       (claude-code-ide-session-status--install-script)
       (let ((script (claude-code-ide-session-status--script-file))
             (dir (expand-file-name "events" registry-dir)))
         (make-directory dir t)
         ,@body))))

(ert-deftest claude-code-ide-test-status-hook-cli-timeout-outlasts-limit ()
  "The CLIs of both providers give a hook more time than the script limit.
So a script always gives up before the CLI stops it."
  (dolist (limit '(1 10 30))
    (let ((claude-code-ide-session-status-hook-time-limit limit))
      (should (> (claude-code-ide-session-status--hook-cli-timeout) limit))
      (should (> (claude-code-ide-session-registry--hook-timeout) limit)))))

(ert-deftest claude-code-ide-test-registry-hook-timeout-follows-limit ()
  "Each hook of the CC --settings argument carries the timeout of the limit."
  (claude-code-ide-tests--with-status
    (let ((claude-code-ide-session-status-hook-time-limit 3)
          (claude-code-ide-session-registry-hook-functions
           (list (lambda (_session _key) '(("Stop" "true")))))
          (session (make-claude-code-ide-mcp-session)))
      (let ((hooks (alist-get 'hooks (json-read-from-string
                                      (claude-code-ide-session-registry--hook-settings session "k8")))))
        (should hooks)
        (dolist (event hooks)
          (dolist (group (append (cdr event) nil))
            (dolist (command (append (alist-get 'hooks group) nil))
              (should (= (alist-get 'timeout command) 8)))))))))

(ert-deftest claude-code-ide-test-status-hook-break-needs-the-token ()
  "A waiter breaks a dead lock only with the break token.
While another waiter holds the token, the dead lock stays, and the hook
gives up at its limit."
  (claude-code-ide-tests--with-hook-dir
    (let ((lock (expand-file-name ".n6.lock" dir)))
      (make-directory lock t)
      (with-temp-file (expand-file-name "pid" lock) (insert "999999\n"))
      (make-directory (concat lock ".break"))
      (pcase-let ((`(,ended ,exit ,seconds)
                   (claude-code-ide-tests--run-guarded "/bin/sh" script (list dir "n6" "Stop") nil)))
        (should ended)
        (should (= exit 0))
        (should (>= seconds 0.9)))
      (should (file-exists-p lock))
      (should-not (directory-files dir nil "\\`n6-")))))

(ert-deftest claude-code-ide-test-status-hook-dead-lock-race ()
  "Waiters that race to break one dead lock each write one event, with its own number."
  (claude-code-ide-tests--with-status
    (claude-code-ide-session-status--install-script)
    (let ((script (claude-code-ide-session-status--script-file)))
      (dolist (shell '("/bin/sh" "/bin/dash"))
        (when (file-executable-p shell)
          (let* ((dir (expand-file-name (concat "race-" (file-name-nondirectory shell)) registry-dir))
                 (lock (expand-file-name ".n7.lock" dir)))
            (make-directory lock t)
            (with-temp-file (expand-file-name "pid" lock) (insert "999999\n"))
            (with-temp-buffer
              (should (zerop (call-process
                              shell nil t nil "-c"
                              (format "i=0; while [ $i -lt 5 ]; do echo '{}' | %s %s %s n7 Stop & i=$((i+1)); done; wait"
                                      shell (shell-quote-argument script) (shell-quote-argument dir))))))
            (should (equal (mapcar (lambda (file) (string-to-number (substring file 3 11)))
                                   (directory-files dir nil "\\`n7-[0-9]+-Stop\\.json\\'"))
                           '(1 2 3 4 5)))))))))

(ert-deftest claude-code-ide-test-status-hook-clock-steps-back ()
  "A clock that steps back counts as the end of the wait."
  (claude-code-ide-tests--with-hook-dir
    (let* ((count (expand-file-name "dates" registry-dir))
           (path (claude-code-ide-tests--shim-bin
                  registry-dir
                  (cons "date" (concat "echo x >> " (shell-quote-argument count) "\n"
                                       "if [ \"$(wc -l < " (shell-quote-argument count)
                                       " | tr -d ' ')\" -le 1 ]; then echo 2000000000; else echo 1000000000; fi\n")))))
      (make-directory (expand-file-name ".n8.lock" dir) t)
      (with-temp-file (expand-file-name ".n8.lock/pid" dir) (insert (format "%d\n" (emacs-pid))))
      (pcase-let ((`(,ended ,exit ,_seconds)
                   (claude-code-ide-tests--run-guarded "/bin/sh" script (list dir "n8" "Stop") (list path))))
        (should ended)
        (should (= exit 0)))
      (should-not (directory-files dir nil "\\`n8-")))))

(ert-deftest claude-code-ide-test-status-hook-frozen-clock-cap ()
  "A clock that does not move ends the wait by the cap of tries."
  (claude-code-ide-tests--with-hook-dir
    (let ((path (claude-code-ide-tests--shim-bin registry-dir (cons "date" "echo 1500000000\n"))))
      (make-directory (expand-file-name ".n9.lock" dir) t)
      (with-temp-file (expand-file-name ".n9.lock/pid" dir) (insert (format "%d\n" (emacs-pid))))
      (pcase-let ((`(,ended ,exit ,_seconds)
                   (claude-code-ide-tests--run-guarded "/bin/sh" script (list dir "n9" "Stop") (list path))))
        (should ended)
        (should (= exit 0)))
      (should (string-match-p "and 20 tries"
                              (claude-code-ide-session-registry--file-string
                               (expand-file-name "hook-errors.log" dir)))))))

(ert-deftest claude-code-ide-test-status-hook-first-date-fails ()
  "When the first `date' fails, the wait counts from the first good one."
  (claude-code-ide-tests--with-hook-dir
    (let* ((count (expand-file-name "dates" registry-dir))
           (path (claude-code-ide-tests--shim-bin
                  registry-dir
                  (cons "date" (concat "echo x >> " (shell-quote-argument count) "\n"
                                       "if [ \"$(wc -l < " (shell-quote-argument count)
                                       " | tr -d ' ')\" -le 1 ]; then exit 1; fi\n"
                                       "exec /bin/date \"$@\"\n")))))
      (make-directory (expand-file-name ".n10.lock" dir) t)
      (with-temp-file (expand-file-name ".n10.lock/pid" dir) (insert (format "%d\n" (emacs-pid))))
      (pcase-let ((`(,ended ,exit ,seconds)
                   (claude-code-ide-tests--run-guarded "/bin/sh" script (list dir "n10" "Stop") (list path))))
        (should ended)
        (should (= exit 0))
        (should (>= seconds 0.9))))))

(ert-deftest claude-code-ide-test-status-hook-holder-pid ()
  "The PID in the lock is that of the process that holds the lock."
  (claude-code-ide-tests--with-status
    (claude-code-ide-session-status--install-script)
    (let ((script (claude-code-ide-session-status--script-file)))
      (dolist (shell '("/bin/sh" "/bin/dash"))
        (when (file-executable-p shell)
          (let* ((dir (expand-file-name (concat "pid-" (file-name-nondirectory shell)) registry-dir))
                 (log (expand-file-name (concat "mv-" (file-name-nondirectory shell)) registry-dir))
                 (pid (expand-file-name ".n11.lock/pid" dir))
                 (path (claude-code-ide-tests--shim-bin
                        dir (cons "mv" (concat "if [ -f " (shell-quote-argument pid) " ]; then "
                                               "echo \"$(cat " (shell-quote-argument pid) ") $PPID\" >> "
                                               (shell-quote-argument log) "; fi\n"
                                               "exec /bin/mv \"$@\"\n")))))
            (make-directory dir t)
            (pcase-let ((`(,ended ,exit ,_seconds)
                         (claude-code-ide-tests--run-guarded shell script (list dir "n11" "Stop") (list path))))
              (should ended)
              (should (= exit 0)))
            (should (directory-files dir nil "\\`n11-00000001-Stop\\.json\\'"))
            ;; Each mv under the lock: the PID in the lock is its parent, the holder
            (let ((lines (split-string (claude-code-ide-session-registry--file-string log) "\n" t)))
              (should lines)
              (dolist (line lines)
                (let ((parts (split-string line " ")))
                  (should (equal (car parts) (cadr parts))))))))))))

(ert-deftest claude-code-ide-test-status-hook-few-clock-reads ()
  "A waiting hook sleeps 50 ms between tries and reads the clock once a try.
That keeps the forks of a waiting hook low on a loaded machine."
  (claude-code-ide-tests--with-hook-dir
    (let* ((dates (expand-file-name "dates" registry-dir))
           (sleeps (expand-file-name "sleeps" registry-dir))
           (path (claude-code-ide-tests--shim-bin
                  registry-dir
                  (cons "date" (concat "echo x >> " (shell-quote-argument dates) "\n"
                                       "exec /bin/date \"$@\"\n"))
                  (cons "sleep" (concat "echo \"$1\" >> " (shell-quote-argument sleeps) "\n"
                                        "exec /bin/sleep \"$@\"\n")))))
      (make-directory (expand-file-name ".n12.lock" dir) t)
      (with-temp-file (expand-file-name ".n12.lock/pid" dir) (insert (format "%d\n" (emacs-pid))))
      (pcase-let ((`(,ended ,_exit ,_seconds)
                   (claude-code-ide-tests--run-guarded "/bin/sh" script (list dir "n12" "Stop") (list path))))
        (should ended))
      (let ((pauses (split-string (claude-code-ide-session-registry--file-string sleeps) "\n" t))
            (reads (length (split-string (claude-code-ide-session-registry--file-string dates) "\n" t))))
        (should pauses)
        (dolist (pause pauses)
          (should (>= (string-to-number pause) 0.05)))
        ;; The start, one read a try (the last try has no sleep), and the log line
        (should (<= reads (+ (length pauses) 3)))))))

(ert-deftest claude-code-ide-test-status-hook-log-rotates ()
  "At 64 KiB the error log moves to hook-errors.log.1, and the new line starts a new log."
  (claude-code-ide-tests--with-hook-dir
    (let ((log (expand-file-name "hook-errors.log" dir)))
      (with-temp-file log (insert (make-string 65536 ?x)))
      (claude-code-ide-tests--held-lock-run script (list dir "n13" "Stop")
                                            (expand-file-name ".n13.lock" dir) nil)
      (should (= (file-attribute-size (file-attributes (concat log ".1"))) 65536))
      (should (= 1 (length (split-string (claude-code-ide-session-registry--file-string log) "\n" t)))))))

(ert-deftest claude-code-ide-test-status-buffer-dropped-notice ()
  "The status buffer tells of new dropped hook events until the user looks."
  (claude-code-ide-tests--with-status
    (let ((claude-code-ide-session-status--dropped-seen 0)
          (claude-code-ide-session-status--dropped-cache nil)
          (dir (claude-code-ide-session-status--events-directory)))
      (should-not (claude-code-ide-session-status--dropped-entry))
      (make-directory (expand-file-name "codex" dir) t)
      (with-temp-file (expand-file-name "hook-errors.log" dir) (insert "a\nb\n"))
      (with-temp-file (expand-file-name "codex/hook-errors.log.1" dir) (insert "c\n"))
      (let ((entry (claude-code-ide-session-status--dropped-entry)))
        (should (eq (car entry) claude-code-ide-session-status--dropped-id))
        (should (string-prefix-p "3 status events dropped" (aref (cadr entry) 0))))
      ;; The user looks: no notice
      (cl-letf (((symbol-function 'display-buffer) #'ignore))
        (claude-code-ide-session-status-show-dropped))
      (should-not (claude-code-ide-session-status--dropped-entry))
      ;; A new line: the notice comes back with it
      (with-temp-file (expand-file-name "hook-errors.log" dir) (insert "a\nb\nd\n"))
      (should (string-prefix-p "1 status event dropped"
                               (aref (cadr (claude-code-ide-session-status--dropped-entry)) 0)))
      (dolist (buffer (buffer-list))
        (when (and (buffer-file-name buffer) (string-prefix-p dir (buffer-file-name buffer)))
          (kill-buffer buffer))))))

;;; The CLI status file of a session without hooks

(defvar claude-code-ide-tests--cli-now 2000.0
  "The NOW of the last state call of the CLI file tests.
Each call takes a new one, because a state is computed once for each NOW.")

(defun claude-code-ide-tests--cli-next-now ()
  "Return a new NOW for a state call."
  (setq claude-code-ide-tests--cli-now (+ claude-code-ide-tests--cli-now 1.0)))

(defmacro claude-code-ide-tests--with-cli-file (&rest body)
  "Run BODY with an untracked CC session whose CLI process is this Emacs.
The session has a live terminal process.  CLAUDE_CONFIG_DIR is a folder
of the test, so the real ~/.claude is never read.  BODY sees
`session', `instance', `file' (the CLI session file of the session) and
`start' (the start time of this Emacs)."
  (declare (indent 0))
  `(claude-code-ide-tests--with-status
     (claude-code-ide-tests--clear-processes)
     (let* ((config (make-temp-file "cci-test-claude-config-" t))
            (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config) process-environment))
            (claude-code-ide-session-status--cli-cache (make-hash-table :test 'eq :weakness 'key))
            (claude-code-ide-session-status--process-cache nil)
            (claude-code-ide-instance--all nil)
            (claude-code-ide-instance--generations (make-hash-table :test 'equal))
            (buffer (generate-new-buffer "*cci-test-cli-file*"))
            (terminal (start-process "cci-test-cli-terminal" nil "sleep" "60"))
            (session (claude-code-ide-tests--make-session "/tmp/cci-test-cli/" :buffer buffer
                                                          :cli-pid (emacs-pid) :process terminal))
            (instance (claude-code-ide-instance-register
                       (claude-code-ide-instance-create :id "cci-test-cli" :provider 'claude
                                                        :session session :buffer buffer)))
            (file (claude-code-ide-session-registry--cli-session-file (emacs-pid)))
            (start (claude-code-ide-session-registry--process-start-time (emacs-pid))))
       (ignore instance start)
       (set-process-query-on-exit-flag terminal nil)
       (make-directory (file-name-directory file) t)
       (unwind-protect
           (progn ,@body)
         (when (process-live-p terminal) (delete-process terminal))
         (let ((kill-buffer-hook nil))
           (kill-buffer buffer))
         (delete-directory config t)
         (claude-code-ide-tests--clear-processes)))))

(defun claude-code-ide-tests--write-cli-file (file &rest fields)
  "Write the CLI session FILE with FIELDS, a plist of JSON keys and values.
The defaults are this Emacs as the process, its start time as
procStart (in UTC, as the CLI writes it), and statusUpdatedAt 1000 s.
A value of :absent removes the key.  The file gets a new time."
  (let* ((start (claude-code-ide-session-registry--process-start-time (emacs-pid)))
         (data `((pid . ,(emacs-pid))
                 (sessionId . "cci-test-native")
                 (cwd . "/tmp/cci-test-cli/")
                 (procStart . ,(format-time-string "%a %b %e %H:%M:%S %Y" start t))
                 (status . "idle")
                 (statusUpdatedAt . 1000000)
                 (updatedAt . 1000000))))
    (while fields
      (let ((key (intern (substring (symbol-name (pop fields)) 1)))
            (value (pop fields)))
        (if (eq value :absent)
            (setq data (assq-delete-all key data))
          (setf (alist-get key data) value))))
    (with-temp-file file (insert (json-encode data)))
    (set-file-times file (time-add nil (random 100000)))))

(defun claude-code-ide-tests--cli-state (session)
  "Return (STATE REASON GUESS SOURCE SINCE) of SESSION from `--session-state'."
  (let ((common (nth 1 (claude-code-ide-session-status--session-state
                        session (claude-code-ide-tests--cli-next-now)))))
    (list (plist-get common :state) (plist-get common :reason) (plist-get common :guess)
          (plist-get common :source) (plist-get common :since))))

(defun claude-code-ide-tests--cli-detail (session)
  "Return the detail of SESSION from `--session-state'."
  (nth 2 (claude-code-ide-session-status--session-state session (claude-code-ide-tests--cli-next-now))))

(ert-deftest claude-code-ide-test-status-cli-file-states ()
  "Each status of the CLI file of an untracked session gives its common state.
A background shell is idle, as with the hooks."
  (claude-code-ide-tests--with-cli-file
    (dolist (case '(("busy" working working "From CLI status: busy")
                    ("idle" idle idle "From CLI status: idle")
                    ("shell" idle idle "From CLI status: idle, a background shell runs")))
      (claude-code-ide-tests--write-cli-file file :status (car case))
      (should (equal (claude-code-ide-tests--cli-state session)
                     (list (nth 1 case) nil nil 'cli-file 1000.0)))
      (let ((now (claude-code-ide-tests--cli-next-now)))
        (pcase-let ((`(,state ,_common ,detail ,since)
                     (claude-code-ide-session-status--session-state session now)))
          (should (eq state (nth 2 case)))
          (should (string-prefix-p (nth 3 case) detail))
          (should (= since 1000.0))))
      ;; The instance state, the row and the snapshot say the same
      (let ((now (claude-code-ide-tests--cli-next-now)))
        (should (eq (plist-get (claude-code-ide-instance-state instance now) :state) (nth 1 case)))
        (should (= (plist-get (claude-code-ide-instance-state instance now) :age) (- now 1000.0)))
        (let ((row (assq session (claude-code-ide-session-status--rows now))))
          (should (eq (nth 1 row) (nth 2 case)))
          (should (= (nth 2 row) 1000.0)))
        (let ((record (claude-code-ide-session-status--snapshot-instance instance now)))
          (should (equal (alist-get 'state record) (symbol-name (nth 1 case))))
          (should (string-prefix-p (nth 3 case) (alist-get 'detail record))))))
    ;; A session with a background shell is one that w visits
    (claude-code-ide-tests--write-cli-file file :status "shell")
    (let ((visited nil))
      (cl-letf (((symbol-function 'claude-code-ide-session-status--visit-session)
                 (lambda (item) (setq visited item))))
        (claude-code-ide-visit-waiting-session))
      (should (eq visited session)))
    ;; A handover needs no force for it: no subagent or task holds it
    (when (require 'claude-code-ide-handover nil t)
      (should-not (funcall 'claude-code-ide-handover--busy-state-p
                           (claude-code-ide-instance-state instance (claude-code-ide-tests--cli-next-now)))))))

(ert-deftest claude-code-ide-test-status-cli-file-fallbacks-untracked ()
  "No file, an unknown status, no status, or a file of another process is UNTRACKED.
NO SIGNAL stays for sessions with hooks that send no event."
  (claude-code-ide-tests--with-cli-file
    (should-not (file-exists-p file))
    (should (equal (seq-take (claude-code-ide-tests--cli-state session) 2) '(disconnected untracked)))
    (should (string-match-p "no CLI status file" (claude-code-ide-tests--cli-detail session)))
    (should (eq (car (claude-code-ide-session-status--session-state
                      session (claude-code-ide-tests--cli-next-now)))
                'untracked))
    (dolist (fields '((:status "compacting") (:status :absent) (:pid 1)))
      (apply #'claude-code-ide-tests--write-cli-file file fields)
      ;; No source gives an UNTRACKED state
      (should (equal (seq-take (claude-code-ide-tests--cli-state session) 4)
                     '(disconnected untracked nil nil))))
    (should-not (claude-code-ide-session-status--urgent-p 'untracked))))

(ert-deftest claude-code-ide-test-status-cli-file-pid-reuse ()
  "The file counts only for the process whose start Emacs recorded for the PID.
A process that holds the PID now with another start, and a file of
such a process, give no state.  A session whose terminal ended gives
none either."
  (claude-code-ide-tests--with-cli-file
    (claude-code-ide-tests--write-cli-file file :status "busy")
    (should (eq (car (claude-code-ide-tests--cli-state session)) 'working))
    ;; The PID now belongs to a process that started later, and the file is of it
    (let ((later (+ start 100)))
      (cl-letf (((symbol-function 'claude-code-ide-session-registry--process-start-time)
                 (lambda (&rest _) later)))
        (claude-code-ide-tests--write-cli-file
         file :status "busy" :procStart (format-time-string "%a %b %e %H:%M:%S %Y" later t))
        (should (equal (seq-take (claude-code-ide-tests--cli-state session) 2)
                       '(disconnected untracked)))
        (should (string-match-p "of another process" (claude-code-ide-tests--cli-detail session)))))
    ;; The terminal of the session ended: the file is not used
    (claude-code-ide-tests--write-cli-file file :status "busy")
    (delete-process (claude-code-ide-mcp-session-process session))
    (should-not (claude-code-ide-session-status--cli-state session (claude-code-ide-tests--cli-next-now)))))

(ert-deftest claude-code-ide-test-status-cli-file-start-fallback ()
  "When procStart does not parse, startedAt gives the start; without both, not readable."
  (claude-code-ide-tests--with-cli-file
    (claude-code-ide-tests--write-cli-file file :status "busy" :procStart "garbled"
                                           :startedAt (round (* 1000 start)))
    (should (eq (car (claude-code-ide-tests--cli-state session)) 'working))
    (claude-code-ide-tests--write-cli-file file :status "busy" :procStart "garbled")
    (should (equal (seq-take (claude-code-ide-tests--cli-state session) 2) '(disconnected untracked)))
    (should (string-match-p "not readable" (claude-code-ide-tests--cli-detail session)))
    (should-not (string-match-p "another process" (claude-code-ide-tests--cli-detail session)))))

(ert-deftest claude-code-ide-test-status-cli-file-read-once ()
  "The file is read only when its time changed; the state once for each refresh.
The process start is asked once per PID for each refresh, and the file
is never written."
  (claude-code-ide-tests--with-cli-file
    (claude-code-ide-tests--write-cli-file file :status "busy")
    (let ((reads 0)
          (starts 0)
          (read (symbol-function 'claude-code-ide-session-registry--read-cli-session))
          (attributes (symbol-function 'claude-code-ide-session-registry--process-attributes))
          (before (file-attribute-modification-time (file-attributes file))))
      (cl-letf (((symbol-function 'claude-code-ide-session-registry--read-cli-session)
                 (lambda (path) (cl-incf reads) (funcall read path)))
                ((symbol-function 'claude-code-ide-session-registry--process-attributes)
                 (lambda (pid &optional cache)
                   (unless (and cache (not (eq (gethash pid cache 'none) 'none)))
                     (cl-incf starts))
                   (funcall attributes pid cache))))
        ;; One refresh: many state calls with the same NOW
        (let ((now (claude-code-ide-tests--cli-next-now)))
          (dotimes (_ 5)
            (claude-code-ide-session-status--session-state session now)
            (claude-code-ide-instance-state instance now)
            (claude-code-ide-session-status--rows now)))
        (should (= reads 1))
        (should (<= starts 2))
        ;; Later refreshes: no read without a new time
        (dotimes (_ 3) (claude-code-ide-tests--cli-state session))
        (should (= reads 1))
        (should (equal (file-attribute-modification-time (file-attributes file)) before))
        (claude-code-ide-tests--write-cli-file file :status "idle")
        (should (eq (car (claude-code-ide-tests--cli-state session)) 'idle))
        (should (= reads 2))))))

(ert-deftest claude-code-ide-test-status-cli-file-cache-is-weak ()
  "The cache of the CLI files is keyed by session and weak, so ended sessions leave it."
  (should (eq (hash-table-weakness claude-code-ide-session-status--cli-cache) 'key))
  (should (eq (hash-table-test claude-code-ide-session-status--cli-cache) 'eq))
  (claude-code-ide-tests--with-cli-file
    (claude-code-ide-tests--write-cli-file file :status "busy")
    (claude-code-ide-tests--cli-state session)
    (should (gethash session claude-code-ide-session-status--cli-cache))
    (should (= (hash-table-count claude-code-ide-session-status--cli-cache) 1))))

(ert-deftest claude-code-ide-test-status-cli-file-hooks-first ()
  "A session with status hooks uses its hooks; the CLI file is only the fallback."
  (claude-code-ide-tests--with-cli-file
    (claude-code-ide-tests--write-cli-file file :status "idle")
    (claude-code-ide-session-status--hooks session "k-cli")
    (claude-code-ide-tests--feed (gethash session claude-code-ide-session-status--by-session)
                                 '(("UserPromptSubmit" "{}")))
    (let ((common (nth 1 (claude-code-ide-session-status--session-state
                          session (claude-code-ide-tests--cli-next-now)))))
      (should (eq (plist-get common :state) 'working))
      (should (eq (plist-get common :source) 'hooks)))
    (should (eq (plist-get (claude-code-ide-instance-state instance (claude-code-ide-tests--cli-next-now))
                           :state)
                'working))))

(ert-deftest claude-code-ide-test-registry-cli-session-fields ()
  "The CLI session of the registry holds the start and the status time.
The start tolerance is one argument of `--same-start-p'."
  (claude-code-ide-tests--with-cli-file
    (claude-code-ide-tests--write-cli-file file :status "shell")
    (let ((cli (claude-code-ide-session-registry--read-cli-session file)))
      (should (equal (claude-code-ide-session-registry--cli-session-status cli) "shell"))
      (should (< (abs (- (claude-code-ide-session-registry--cli-session-proc-start cli) start)) 1.0))
      (should (= (claude-code-ide-session-registry--cli-session-status-time cli) 1000.0)))
    (should (claude-code-ide-session-registry--same-start-p (emacs-pid) (+ start 0.5)))
    (should-not (claude-code-ide-session-registry--same-start-p (emacs-pid) (+ start 0.5) nil 0.1))
    (should (claude-code-ide-session-registry--same-start-p (emacs-pid) (+ start 3) nil 5))))

(ert-deftest claude-code-ide-test-registry-claude-config-directory ()
  "An empty, relative or missing CLAUDE_CONFIG_DIR counts as unset."
  (let ((home (expand-file-name "~/.claude")))
    (dolist (value '("" "relative/dir" "/nonexistent/cci-test-config"))
      (let ((process-environment (cons (concat "CLAUDE_CONFIG_DIR=" value) process-environment)))
        (should (equal (claude-code-ide-session-registry--claude-config-directory) home))
        (should (equal (claude-code-ide-session-registry--cli-session-file 7)
                       (expand-file-name "sessions/7.json" home)))))
    (let* ((dir (make-temp-file "cci-test-config-" t))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" dir) process-environment)))
      (unwind-protect
          (should (equal (claude-code-ide-session-registry--claude-config-directory) dir))
        (delete-directory dir t)))))

(ert-deftest claude-code-ide-test-status-cli-pid-must-be-integer ()
  "Only an integer PID of ide_connected counts as the CLI PID."
  (require 'claude-code-ide-mcp)
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (let ((session (claude-code-ide-tests--make-session "/tmp/cci-test-pid/" :port 12347)))
        (claude-code-ide-mcp--handle-message '((method . "ide_connected") (params . ((pid . "42"))))
                                             session)
        (should-not (claude-code-ide-mcp-session-cli-pid session))
        (claude-code-ide-mcp--handle-message '((method . "ide_connected") (params . ((pid . 42.5))))
                                             session)
        (should-not (claude-code-ide-mcp-session-cli-pid session))
        (claude-code-ide-mcp--handle-message '((method . "ide_connected") (params . ((pid . 42))))
                                             session)
        (should (= (claude-code-ide-mcp-session-cli-pid session) 42))
        ;; A value that is not an integer, set some other way, is no PID either
        (setf (claude-code-ide-mcp-session-cli-pid session) "42")
        (should-not (claude-code-ide-session-registry--session-pid session)))
    (claude-code-ide-tests--clear-processes)))

;;; The display of the status buffer

(defmacro claude-code-ide-tests--with-status-display (&rest body)
  "Run BODY with the status modes off at the end, and one window in the frame."
  (declare (indent 0))
  `(claude-code-ide-tests--with-status
     (claude-code-ide-tests--clear-processes)
     (save-window-excursion
       (delete-other-windows)
       (unwind-protect
           (progn ,@body)
         (when claude-code-ide-session-status-mode
           (cl-letf (((symbol-function 'claude-code-ide-session-status--stop-timers) #'ignore))
             (claude-code-ide-session-status-mode -1)))
         (when claude-code-ide-session-registry-mode
           (claude-code-ide-session-registry-mode -1))
         (when (get-buffer claude-code-ide-session-status--buffer-name)
           (kill-buffer claude-code-ide-session-status--buffer-name))
         (claude-code-ide-tests--clear-processes)))))

(ert-deftest claude-code-ide-test-status-mode-displays-nothing ()
  "Turning the status mode on creates the buffer but displays nothing."
  (claude-code-ide-tests--with-status-display
    (let ((shown 0)
          (display (symbol-function 'display-buffer)))
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (&rest args) (cl-incf shown) (apply display args))))
        (claude-code-ide-session-status-mode 1)
        (should (get-buffer claude-code-ide-session-status--buffer-name))
        (should (= shown 0))
        (should-not (get-buffer-window claude-code-ide-session-status--buffer-name t))
        ;; The command shows it
        (claude-code-ide-show-session-status)
        (should (= shown 1))
        (should (get-buffer-window claude-code-ide-session-status--buffer-name t))))))

(ert-deftest claude-code-ide-test-status-buffer-normal-window ()
  "By default the status buffer shows in the selected window, not in a side window.
Turning the mode off kills it and leaves the window."
  (should (equal (default-value 'claude-code-ide-session-status-display-action)
                 '((display-buffer-reuse-window display-buffer-same-window))))
  (claude-code-ide-tests--with-status-display
    (let ((window (selected-window)))
      (claude-code-ide-show-session-status)
      (should (eq (window-buffer window) (get-buffer claude-code-ide-session-status--buffer-name)))
      (should-not (window-parameter window 'window-side))
      (should (= (length (window-list)) 1))
      (claude-code-ide-session-status-mode -1)
      (should (window-live-p window))
      (should-not (get-buffer claude-code-ide-session-status--buffer-name)))))

(ert-deftest claude-code-ide-test-status-buffer-side-window-action ()
  "A side-window action of the user still works, and the mode off closes that window."
  (claude-code-ide-tests--with-status-display
    (let ((claude-code-ide-session-status-display-action
           '((display-buffer-in-side-window) (side . top) (slot . 0))))
      (claude-code-ide-show-session-status)
      (let ((window (get-buffer-window claude-code-ide-session-status--buffer-name)))
        (should window)
        (should (eq (window-parameter window 'window-side) 'top))
        (claude-code-ide-session-status-mode -1)
        (should-not (window-live-p window))))))

(ert-deftest claude-code-ide-test-status-buffer-quit-restores-windows ()
  "The mode off gives each window back what it showed before the status buffer.
A window made for the buffer goes; a reused window shows its old buffer."
  (claude-code-ide-tests--with-status-display
    (let ((claude-code-ide-session-status-display-action '((display-buffer-pop-up-window)))
          (old (get-buffer-create "*cci-test-old*")))
      (switch-to-buffer old)
      (claude-code-ide-show-session-status)
      (should (= (length (window-list)) 2))
      (claude-code-ide-session-status-mode -1)
      (should (= (length (window-list)) 1))
      (should (eq (window-buffer (selected-window)) old))
      ;; The default: the selected window shows the old buffer again
      (let ((claude-code-ide-session-status-display-action
             '((display-buffer-reuse-window display-buffer-same-window))))
        (switch-to-buffer old)
        (claude-code-ide-show-session-status)
        (should (eq (window-buffer (selected-window))
                    (get-buffer claude-code-ide-session-status--buffer-name)))
        (claude-code-ide-session-status-mode -1)
        (should (eq (window-buffer (selected-window)) old)))
      (kill-buffer old))))

(ert-deftest claude-code-ide-test-status-rate-limit-model-text-is-no-quota ()
  "A rate_limit with error details uses only the details: model text is no quota limit."
  (let ((status (claude-code-ide-session-status-create :nonce "rl" :since 0.0 :registered 0.0
                                                       :last-event 0.0)))
    (claude-code-ide-session-status--apply status "UserPromptSubmit" nil 1.0)
    (claude-code-ide-session-status--apply
     status "StopFailure"
     '((error . "rate_limit")
       (error_details . "Rate limit reached: tokens per minute")
       (last_assistant_message . "I set the spend cap of the cci-test workspace to 50 dollars."))
     2.0)
    (should (eq (claude-code-ide-session-status--state status 3.0) 'error))
    (should (eq (plist-get (claude-code-ide-session-status--common-state status 3.0) :reason) 'error))
    ;; Without details, the last message is the limit message of the CLI
    (claude-code-ide-session-status--apply status "UserPromptSubmit" nil 4.0)
    (claude-code-ide-session-status--apply
     status "StopFailure"
     '((error . "rate_limit") (error_details . "  ")
       (last_assistant_message . "Claude usage limit reached. Your limit will reset at 5pm"))
     5.0)
    (should (eq (claude-code-ide-session-status--state status 6.0) 'quota))
    (should (equal (claude-code-ide-session-status--detail status 'quota 6.0)
                   "Quota limit: Claude usage limit reached. Your limit will reset at 5pm"))))

(provide 'claude-code-ide-session-status-tests)

;; Local Variables:
;; no-update-autoloads: t
;; autoload-compute-prefixes: nil
;; End:

;;; claude-code-ide-session-status-tests.el ends here
