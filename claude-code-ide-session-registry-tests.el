;;; claude-code-ide-session-registry-tests.el --- Tests for the session registry  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for `claude-code-ide-session-registry-mode' and for the start
;; spec and lifecycle hooks of the core that it uses.  The file is
;; loaded by claude-code-ide-tests.el, after its mocks, and uses its
;; helpers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-code-ide)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-codex)

(defvar claude-code-ide-session-prepare-functions)

(declare-function claude-code-ide-tests--make-session "claude-code-ide-tests")
(declare-function claude-code-ide-tests--clear-processes "claude-code-ide-tests")

(defmacro claude-code-ide-tests--with-registry (&rest body)
  "Run BODY with an empty session registry in a temporary directory.
BODY can refer to that directory as `registry-dir'."
  (declare (indent 0))
  `(let* ((registry-dir (make-temp-file "cci-registry-" t))
          (claude-code-ide-state-file (expand-file-name "state.json" registry-dir))
          (claude-code-ide-session-registry-report-directory nil)
          (claude-code-ide-session-registry--queue nil)
          (claude-code-ide-session-registry--draining nil)
          (claude-code-ide-session-registry--retry-timer nil)
          (claude-code-ide-session-registry--loaded-from-backup nil)
          (claude-code-ide-session-registry--exiting nil)
          (claude-code-ide-session-registry--start-key nil)
          (claude-code-ide-session-registry--keys
           (make-hash-table :test 'eq :weakness 'key))
          (claude-code-ide-session-registry--started
           (make-hash-table :test 'eq :weakness 'key))
          (claude-code-ide-session-registry--new-native-ids
           (make-hash-table :test 'eq :weakness 'key))
          (claude-code-ide-session-registry--pending
           (make-hash-table :test 'eq :weakness 'key))
          (claude-code-ide-session-registry--restoring
           (make-hash-table :test 'eq :weakness 'key))
          (claude-code-ide-session-registry--pending-timer nil))
     (unwind-protect
         (progn ,@body)
       (when (timerp claude-code-ide-session-registry--retry-timer)
         (cancel-timer claude-code-ide-session-registry--retry-timer))
       (when (timerp claude-code-ide-session-registry--pending-timer)
         (cancel-timer claude-code-ide-session-registry--pending-timer))
       (delete-directory registry-dir t))))

(defun claude-code-ide-tests--registry-entry (key &rest overrides)
  "Return an open registry entry KEY of this Emacs, changed by OVERRIDES."
  (apply #'claude-code-ide-session-registry-entry-create
         (append overrides
                 (list :key key
                       :session-id key
                       :project-dir "/tmp/registry-project/"
                       :state 'open
                       :started-at "2026-11-03T10:00:00Z"
                       :host (system-name)
                       :emacs-pid (emacs-pid)))))

(defun claude-code-ide-tests--registry-add (key)
  "Return a change that appends a new entry KEY."
  (lambda (entries)
    (append entries (list (claude-code-ide-tests--registry-entry key)))))

(defun claude-code-ide-tests--registry-file-keys (&optional file)
  "Return the entry keys in FILE, by default the state file."
  (mapcar #'claude-code-ide-session-registry-entry-key
          (claude-code-ide-session-registry--read-file
           (or file (claude-code-ide-session-registry--state-file)))))

(defun claude-code-ide-tests--registry-get (key)
  "Return the entry KEY of the state file."
  (claude-code-ide-session-registry--find (claude-code-ide-session-registry--load) key))

(defun claude-code-ide-tests--registry-spec (&rest overrides)
  "Return a start spec in the registry test project, changed by OVERRIDES."
  (apply #'claude-code-ide-start-spec-create
         (append overrides
                 (list :directory "/tmp/registry-project/"
                       :extra-flags ""))))

(ert-deftest claude-code-ide-test-registry-queue-reentrant-order ()
  "Changes submitted while the queue drains are written after, in order."
  (claude-code-ide-tests--with-registry
    (let ((real-write (symbol-function 'claude-code-ide-session-registry--write-file))
          (nested nil)
          (writes 0))
      (cl-letf (((symbol-function 'claude-code-ide-session-registry--write-file)
                 (lambda (entries)
                   (cl-incf writes)
                   ;; A timer or hook that fires during the write
                   (unless nested
                     (setq nested t)
                     (claude-code-ide-session-registry--submit
                      "b" (claude-code-ide-tests--registry-add "b"))
                     (claude-code-ide-session-registry--submit
                      "c" (claude-code-ide-tests--registry-add "c")))
                   (funcall real-write entries))))
        (claude-code-ide-session-registry--submit "a" (claude-code-ide-tests--registry-add "a"))
        (should (equal (claude-code-ide-tests--registry-file-keys) '("a" "b" "c")))
        ;; The nested changes were queued, not written inside the first pass
        (should (= writes 2))
        (should-not claude-code-ide-session-registry--queue)
        (should-not claude-code-ide-session-registry--draining)))))

(ert-deftest claude-code-ide-test-registry-queue-reentrant-during-lock-wait ()
  "A change submitted while the drain waits for the lock is in the same write."
  (claude-code-ide-tests--with-registry
    (let ((lock (claude-code-ide-session-registry--lock-directory))
          (waits 0))
      (make-directory lock)
      (cl-letf (((symbol-function 'sleep-for)
                 (lambda (&rest _)
                   (cl-incf waits)
                   (claude-code-ide-session-registry--submit
                    "b" (claude-code-ide-tests--registry-add "b"))
                   ;; The other writer finishes
                   (delete-directory lock))))
        (claude-code-ide-session-registry--submit "a" (claude-code-ide-tests--registry-add "a")))
      (should (= waits 1))
      (should (equal (claude-code-ide-tests--registry-file-keys) '("a" "b")))
      (should-not (file-exists-p lock)))))

(ert-deftest claude-code-ide-test-registry-lock-blocks-then-stale-lock-breaks ()
  "A held lock keeps the change queued; a stale lock is removed."
  (claude-code-ide-tests--with-registry
    (let ((lock (claude-code-ide-session-registry--lock-directory))
          (claude-code-ide-session-registry-lock-wait 0.1)
          (retries 0))
      (make-directory lock)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (&rest _) (cl-incf retries) nil))
                ((symbol-function 'message) #'ignore))
        (claude-code-ide-session-registry--submit "a" (claude-code-ide-tests--registry-add "a"))
        (should-not (file-exists-p claude-code-ide-state-file))
        (should (= (length claude-code-ide-session-registry--queue) 1))
        (should (= retries 1))
        ;; The other writer died long ago
        (set-file-times lock (time-subtract nil 3600))
        (claude-code-ide-session-registry--drain)
        (should (equal (claude-code-ide-tests--registry-file-keys) '("a")))
        (should-not claude-code-ide-session-registry--queue)
        (should-not (file-exists-p lock))))))

(ert-deftest claude-code-ide-test-registry-atomic-write ()
  "A failed write leaves the old file whole; a good one keeps the old as .bak."
  (claude-code-ide-tests--with-registry
    (claude-code-ide-session-registry--submit "a" (claude-code-ide-tests--registry-add "a"))
    (let ((real-rename (symbol-function 'rename-file))
          (file (claude-code-ide-session-registry--state-file)))
      (cl-letf (((symbol-function 'rename-file)
                 (lambda (from to &optional ok)
                   (if (equal (expand-file-name to) file)
                       (error "Simulated crash before the rename")
                     (funcall real-rename from to ok))))
                ((symbol-function 'display-warning) #'ignore))
        (claude-code-ide-session-registry--submit "b" (claude-code-ide-tests--registry-add "b")))
      ;; The old file is complete, no temporary file is left, the change waits
      (should (equal (claude-code-ide-tests--registry-file-keys) '("a")))
      (should (equal (directory-files registry-dir nil "tmp") nil))
      (should (= (length claude-code-ide-session-registry--queue) 1))
      ;; The next drain writes it and keeps the old version as backup
      (claude-code-ide-session-registry--drain)
      (should (equal (claude-code-ide-tests--registry-file-keys) '("a" "b")))
      (should (equal (claude-code-ide-tests--registry-file-keys
                      (claude-code-ide-session-registry--backup-file))
                     '("a"))))))

(ert-deftest claude-code-ide-test-registry-backup-fallback ()
  "An unreadable state file falls back to .bak and is kept aside."
  (claude-code-ide-tests--with-registry
    (claude-code-ide-session-registry--submit "a" (claude-code-ide-tests--registry-add "a"))
    (claude-code-ide-session-registry--submit "b" (claude-code-ide-tests--registry-add "b"))
    (with-temp-file (claude-code-ide-session-registry--state-file)
      (insert "{\"version\": 1, \"sessions\": [{\"key\""))
    (let ((warnings '()))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (should (equal (mapcar #'claude-code-ide-session-registry-entry-key
                               (claude-code-ide-session-registry--entries))
                       '("a")))
        (should (string-match-p "using .*state-v2\\.json\\.bak" (car warnings)))
        (claude-code-ide-session-registry--submit "c" (claude-code-ide-tests--registry-add "c"))))
    (should (equal (claude-code-ide-tests--registry-file-keys) '("a" "c")))
    ;; The good backup survived, and the unreadable file was kept
    (should (equal (claude-code-ide-tests--registry-file-keys
                    (claude-code-ide-session-registry--backup-file))
                   '("a")))
    (should (= 1 (length (directory-files registry-dir nil "\\.corrupt-"))))))

(ert-deftest claude-code-ide-test-registry-state-transitions ()
  "Start, kill, reopen, normal end, Emacs exit, rename, archive, forget."
  (claude-code-ide-tests--with-registry
    (let* ((buffer (generate-new-buffer "*claude-code[registry-project]*"))
           (session (make-claude-code-ide-mcp-session :buffer buffer))
           (args (claude-code-ide-session-registry--cli-args
                  session
                  (claude-code-ide-tests--registry-spec
                   :extra-flags "--model opus --permission-mode plan")))
           (key (gethash session claude-code-ide-session-registry--keys)))
      (unwind-protect
          (progn
            ;; A new conversation gets its own id from Emacs, and the report hook
            (should (equal (car args) "--session-id"))
            (should-not (equal (cadr args) key))
            (should (equal (nth 2 args) "--settings"))
            (should (string-match-p (regexp-quote (concat key ".json")) (nth 3 args)))
            (claude-code-ide-session-registry--on-start
             session (claude-code-ide-tests--registry-spec
                      :extra-flags "--model opus --permission-mode plan"))
            (let ((entry (claude-code-ide-tests--registry-get key)))
              (should (eq (claude-code-ide-session-registry-entry-state entry) 'open))
              (should (equal (claude-code-ide-session-registry-entry-session-id entry)
                             (cadr args)))
              (should (equal (claude-code-ide-session-registry-entry-model entry) "opus"))
              (should (equal (claude-code-ide-session-registry-entry-extra-flags entry)
                             "--permission-mode plan"))
              (should (equal (claude-code-ide-session-registry-entry-permission-mode entry)
                             "plan"))
              (should (equal (claude-code-ide-session-registry-entry-buffer-name entry)
                             (buffer-name buffer))))

            (claude-code-ide-session-registry--on-end session 'killed)
            (let ((entry (claude-code-ide-tests--registry-get key)))
              (should (eq (claude-code-ide-session-registry-entry-state entry) 'closed))
              (should (equal (claude-code-ide-session-registry-entry-closed-by entry) "killed")))

            ;; Reopen: same key, resumed by id, so no --session-id
            (let* ((first-start (claude-code-ide-session-registry-entry-started-at
                                 (claude-code-ide-tests--registry-get key)))
                   (session2 (make-claude-code-ide-mcp-session :buffer buffer))
                   (spec (claude-code-ide-tests--registry-spec :resume-id key))
                   (args2 (let ((claude-code-ide-session-registry--start-key key))
                            (claude-code-ide-session-registry--cli-args session2 spec))))
              (should-not (member "--session-id" args2))
              (claude-code-ide-session-registry--on-start session2 spec)
              (let ((entry (claude-code-ide-tests--registry-get key)))
                (should (eq (claude-code-ide-session-registry-entry-state entry) 'open))
                (should-not (claude-code-ide-session-registry-entry-closed-by entry))
                (should (equal (claude-code-ide-session-registry-entry-started-at entry)
                               first-start)))
              (claude-code-ide-session-registry--on-end session2 'exited)
              (should (equal (claude-code-ide-session-registry-entry-closed-by
                              (claude-code-ide-tests--registry-get key))
                             "exited")))

            ;; Emacs exits normally while the session runs
            (let* ((session3 (make-claude-code-ide-mcp-session :buffer buffer))
                   (spec (claude-code-ide-tests--registry-spec :resume-id key)))
              (let ((claude-code-ide-session-registry--start-key key))
                (claude-code-ide-session-registry--cli-args session3 spec))
              (claude-code-ide-session-registry--on-start session3 spec)
              (setf (claude-code-ide-mcp-session-instance-name session3) "refactor")
              (claude-code-ide-session-registry--on-rename session3)
              (should (equal (claude-code-ide-session-registry-entry-instance-name
                              (claude-code-ide-tests--registry-get key))
                             "refactor"))
              (claude-code-ide-session-registry--on-kill-emacs)
              (should (equal (claude-code-ide-session-registry-entry-closed-by
                              (claude-code-ide-tests--registry-get key))
                             "emacs-exit"))
              ;; The package cleanup that follows does not change it
              (claude-code-ide-session-registry--on-end session3 'killed)
              (should (equal (claude-code-ide-session-registry-entry-closed-by
                              (claude-code-ide-tests--registry-get key))
                             "emacs-exit")))

            (claude-code-ide-archive-session (claude-code-ide-tests--registry-get key))
            (should (eq (claude-code-ide-session-registry-entry-state
                         (claude-code-ide-tests--registry-get key))
                        'archived))
            (claude-code-ide-forget-session (claude-code-ide-tests--registry-get key))
            (should-not (claude-code-ide-tests--registry-get key)))
        (kill-buffer buffer)))))

(ert-deftest claude-code-ide-test-registry-failed-restore-stays-open ()
  "A restore that fails during the start leaves the entry restorable.
The CLI that exits during the startup delay makes the entry `failed'.
A start whose terminal never came up keeps the provisional entry until
the check of pending starts finds that its MCP session is gone."
  (claude-code-ide-tests--with-registry
    (claude-code-ide-session-registry--submit
     "setup" (lambda (_) (list (claude-code-ide-tests--registry-entry "crashed"))))
    (let* ((buffer (generate-new-buffer "*claude-failed*"))
           (failed (make-claude-code-ide-mcp-session :buffer buffer))
           (no-buffer (make-claude-code-ide-mcp-session))
           (spec (claude-code-ide-tests--registry-spec :resume-id "crashed")))
      (unwind-protect
          (progn
            ;; The CLI exits during the startup delay: cleanup, no start
            ;; record.  This start is not one of `--start-entry', so the
            ;; end records the failure.
            (let ((claude-code-ide-session-registry--start-key "crashed"))
              (claude-code-ide-session-registry--cli-args failed spec))
            (should (eq (claude-code-ide-session-registry-entry-state
                         (claude-code-ide-tests--registry-get "crashed"))
                        'pending))
            (claude-code-ide-session-registry--on-end failed 'exited)
            (let ((entry (claude-code-ide-tests--registry-get "crashed")))
              (should (eq (claude-code-ide-session-registry-entry-state entry) 'failed))
              (should (equal (claude-code-ide-session-registry-entry-failure entry)
                             "The CLI ended during its start"))
              (should (equal (claude-code-ide-session-registry-entry-session-id entry) "crashed"))
              (should (claude-code-ide-session-registry--restorable-p entry)))
            ;; The terminal never came up: no buffer, no cleanup at all
            (let ((claude-code-ide-session-registry--start-key "crashed"))
              (claude-code-ide-session-registry--cli-args no-buffer spec))
            ;; It starts now, so a restore leaves it alone
            (should (equal (claude-code-ide-session-registry--live-keys) '("crashed")))
            (should-not (claude-code-ide-session-registry--restorable-p
                         (claude-code-ide-tests--registry-get "crashed")))
            ;; Its MCP session is gone: the check fails the entry
            (claude-code-ide-session-registry--check-pending)
            (should-not (claude-code-ide-session-registry--live-keys))
            (let ((entry (claude-code-ide-tests--registry-get "crashed")))
              (should (eq (claude-code-ide-session-registry-entry-state entry) 'failed))
              (should (claude-code-ide-session-registry--restorable-p entry))))
        (kill-buffer buffer)))))

(ert-deftest claude-code-ide-test-registry-keeps-user-settings ()
  "Flags with their own --settings get no second --settings."
  (claude-code-ide-tests--with-registry
    (let ((args (claude-code-ide-session-registry--cli-args
                 (make-claude-code-ide-mcp-session)
                 (claude-code-ide-tests--registry-spec
                  :extra-flags "--settings /home/me/settings.json"))))
      (should (member "--session-id" args))
      (should-not (member "--settings" args)))))

(ert-deftest claude-code-ide-test-registry-continue-gets-id-from-report ()
  "A continued session gets no --session-id; the hook report gives its id."
  (claude-code-ide-tests--with-registry
    (let* ((session (make-claude-code-ide-mcp-session))
           (spec (claude-code-ide-tests--registry-spec :continue t))
           (args (claude-code-ide-session-registry--cli-args session spec))
           (key (gethash session claude-code-ide-session-registry--keys)))
      (should-not (member "--session-id" args))
      (claude-code-ide-session-registry--on-start session spec)
      (should-not (claude-code-ide-session-registry-entry-session-id
                   (claude-code-ide-tests--registry-get key)))
      ;; What the SessionStart hook writes
      (with-temp-file (claude-code-ide-session-registry--report-file key)
        (insert "{\"session_id\":\"cli-id-1\",\"transcript_path\":\"/x/cli-id-1.jsonl\",\"source\":\"startup\"}"))
      (claude-code-ide-session-registry--submit "report" #'identity)
      (let ((entry (claude-code-ide-tests--registry-get key)))
        (should (equal (claude-code-ide-session-registry-entry-session-id entry) "cli-id-1"))
        (should (equal (claude-code-ide-session-registry-entry-transcript-path entry)
                       "/x/cli-id-1.jsonl"))))))

(ert-deftest claude-code-ide-test-registry-hook-survives-command-split ()
  "The --settings argument reaches the CLI whole through both backend paths."
  (claude-code-ide-tests--with-registry
    (cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) #'ignore))
      (let* ((session (make-claude-code-ide-mcp-session))
             (args (claude-code-ide-session-registry--cli-args
                    session (claude-code-ide-tests--registry-spec)))
             (key (gethash session claude-code-ide-session-registry--keys))
             (claude-code-ide-cli-extra-flags "")
             (parts (claude-code-ide--split-command-line
                     (claude-code-ide--build-claude-command nil nil "sid" args)))
             (settings (claude-code-ide-session-registry--json-decode
                        (cadr (member "--settings" parts))))
             (hook (car (alist-get 'hooks (car (alist-get 'SessionStart
                                                          (alist-get 'hooks settings)))))))
        (should (equal (car parts) claude-code-ide-cli-path))
        (should (equal (cadr (member "--session-id" parts))
                       (gethash session claude-code-ide-session-registry--new-native-ids)))
        (should (equal (alist-get 'command hook)
                       (concat "cat > " (shell-quote-argument
                                         (claude-code-ide-session-registry--report-file key)))))))))

(ert-deftest claude-code-ide-test-split-command-line ()
  "The backend command splitter keeps ;, & and |, and unquotes like a shell."
  (should (equal (claude-code-ide--split-command-line
                  (concat "claude --name "
                          (shell-quote-argument "Add calls; right now they queue")))
                 '("claude" "--name" "Add calls; right now they queue")))
  (should (equal (claude-code-ide--split-command-line "a 'b & c|d' \"e \\\"f\\\" $g\" h\\ i")
                 '("a" "b & c|d" "e \"f\" $g" "h i")))
  (should (equal (claude-code-ide--split-command-line "x '' \"\" y")
                 '("x" "" "" "y")))
  (should (equal (claude-code-ide--split-command-line "  ") '()))
  (should (equal (claude-code-ide--parse-command-string "claude -p 'a;b'")
                 '("claude" "-p" "a;b"))))

(ert-deftest claude-code-ide-test-registry-restore-title-with-separators ()
  "A restore passes a title with ;, & or | whole to the CLI."
  (let* ((claude-code-ide-cli-path "claude")
         (claude-code-ide-cli-extra-flags
          (concat "--model opus --name "
                  (shell-quote-argument "Add support for parallel calls; they queue & wait | now")))
         (parts (cdr (claude-code-ide--parse-command-string
                      (concat claude-code-ide-cli-path " " claude-code-ide-cli-extra-flags)))))
    (should (equal (cadr (member "--name" parts))
                   "Add support for parallel calls; they queue & wait | now"))
    (should (equal (cadr (member "--model" parts)) "opus"))))

(ert-deftest claude-code-ide-test-registry-parse-flags ()
  "Model and session flags are split off; other flags stay, quoted."
  (let ((flags (claude-code-ide-session-registry--parse-flags
                "--model opus --resume abc --append-system-prompt 'two words' --dangerously-skip-permissions")))
    (should (equal (claude-code-ide-session-registry--flags-model flags) "opus"))
    (should (equal (claude-code-ide-session-registry--flags-session-id flags) "abc"))
    (should (claude-code-ide-session-registry--flags-sets-session flags))
    (should (equal (claude-code-ide-session-registry--flags-permission-mode flags)
                   "bypassPermissions"))
    (should (equal (claude-code-ide--split-command-line (claude-code-ide-session-registry--flags-rest flags))
                   '("--append-system-prompt" "two words" "--dangerously-skip-permissions"))))
  ;; A restore sets the name itself, so a stored name is dropped
  (should (equal (claude-code-ide-session-registry--flags-rest
                  (claude-code-ide-session-registry--parse-flags "--name 'Old title' --verbose -n x"))
                 "--verbose"))
  (let ((flags (claude-code-ide-session-registry--parse-flags "-r --fork-session --model=haiku")))
    (should (equal (claude-code-ide-session-registry--flags-model flags) "haiku"))
    (should-not (claude-code-ide-session-registry--flags-session-id flags))
    (should (equal (claude-code-ide-session-registry--flags-rest flags) ""))))

(ert-deftest claude-code-ide-test-registry-restore ()
  "Restore starts only crashed sessions of this host, with their stored setup."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (project (file-name-as-directory (expand-file-name "proj" registry-dir)))
           (transcript-dir (expand-file-name
                            (claude-code-ide-session-registry--project-slug project)
                            (expand-file-name "projects" config-dir)))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir)
                                      process-environment))
           (claude-code-ide-restore-note "Resumed after a crash.")
           (starts '())
           (timers '()))
      (make-directory project t)
      (make-directory transcript-dir t)
      (with-temp-file (expand-file-name "id-crashed.jsonl" transcript-dir)
        (insert "{\"type\":\"custom-title\",\"customTitle\":\"DEAL-1/fix\"}\n"
                "{\"type\":\"user\",\"cwd\":\"x\"}\n"
                "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-old-1\"}}\n"
                "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-new-2\"}}\n"))
      (claude-code-ide-session-registry--submit
       "setup"
       (lambda (_)
         (list (claude-code-ide-tests--registry-entry
                "crashed" :session-id "id-crashed" :project-dir project
                :instance-name "refactor" :model "opus"
                :extra-flags "--permission-mode plan" :emacs-pid 999999999
                :started-at "2026-11-03T09:00:00Z")
               (claude-code-ide-tests--registry-entry
                "other-emacs" :project-dir project :emacs-pid 4242)
               (claude-code-ide-tests--registry-entry
                "closed" :project-dir project :state 'closed)
               (claude-code-ide-tests--registry-entry
                "other-host" :project-dir project :host "elsewhere"))))
      (cl-letf (((symbol-function 'process-attributes)
                 (lambda (pid) (when (eql pid 4242) '((comm . "Emacs")))))
                ((symbol-function 'claude-code-ide--start-session)
                 (lambda (continue resume spec)
                   (push (list continue resume spec claude-code-ide-session-registry--start-key)
                         starts)))
                ;; Each start runs from its own timer: collect them, then run them
                ((symbol-function 'run-with-timer)
                 (lambda (_secs _repeat fn &rest args)
                   (push (cons fn args) timers))))
        (claude-code-ide-restore-sessions)
        (dolist (timer (reverse timers))
          (apply (car timer) (cdr timer))))
      (should (= (length starts) 1))
      (pcase-let ((`(,continue ,resume ,spec ,key) (car starts)))
        (should-not continue)
        (should-not resume)
        (should (equal key "crashed"))
        (should (equal (claude-code-ide-start-spec-directory spec) project))
        (should (equal (claude-code-ide-start-spec-instance-name spec) "refactor"))
        (should (equal (claude-code-ide-start-spec-resume-id spec) "id-crashed"))
        ;; The transcript's last model wins over the stored --model
        (should (equal (claude-code-ide-start-spec-extra-flags spec)
                       "--permission-mode plan --model claude-new-2 --name DEAL-1/fix"))
        (should (equal (claude-code-ide-start-spec-prompt spec) "Resumed after a crash."))))))

(ert-deftest claude-code-ide-test-registry-transcript-title ()
  "The title is the last /rename title of the transcript."
  (claude-code-ide-tests--with-registry
    (let ((file (expand-file-name "t.jsonl" registry-dir)))
      (with-temp-file file
        (insert "{\"type\":\"custom-title\",\"customTitle\":\"first\"}\n"
                "{\"type\":\"user\",\"message\":{\"content\":\"\\\"type\\\":\\\"custom-title\\\"\"}}\n"
                "{\"type\":\"custom-title\",\"customTitle\":\"second, with \\\"quotes\\\"\"}\n"))
      (should (equal (claude-code-ide-session-registry--transcript-title file)
                     "second, with \"quotes\"")))))

(ert-deftest claude-code-ide-test-build-command-extra-args-and-prompt ()
  "Extra arguments are quoted; the prompt comes last, after --."
  (cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) (lambda () t))
            ((symbol-function 'claude-code-ide-mcp-server-get-config)
             (lambda (_) '((mcpServers . ((emacs-tools . ((type . "http"))))))))
            ((symbol-function 'claude-code-ide-mcp-server-get-tool-names)
             (lambda (_) '("mcp__emacs-tools__a"))))
    (let* ((claude-code-ide-cli-path "claude")
           (claude-code-ide-cli-extra-flags "")
           (claude-code-ide-mcp-allowed-tools 'auto)
           (command (claude-code-ide--build-claude-command
                     nil nil "sid" (list "--settings" "{\"a\": 1}") "hello there"))
           (parts (claude-code-ide--split-command-line command)))
      (should (equal (last parts 2) '("--" "hello there")))
      (should (equal (cadr (member "--settings" parts)) "{\"a\": 1}"))
      (should (< (cl-position "--settings" parts :test #'equal)
                 (cl-position "--allowedTools" parts :test #'equal))))))

(ert-deftest claude-code-ide-test-start-session-with-spec ()
  "A spec starts without prompts and passes its id, args and prompt."
  (claude-code-ide-tests--clear-processes)
  (let* ((buffer (generate-new-buffer "*test-spec*"))
         (process (start-process "mock-claude" nil "sleep" "30"))
         (terminal-args nil)
         (started nil)
         (claude-code-ide-cli-args-functions
          (list (lambda (_session _spec) (list "--hooked"))))
         (claude-code-ide-session-start-functions
          (list (lambda (session spec) (setq started (cons session spec))))))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-ide--ensure-cli) (lambda () t))
                  ((symbol-function 'claude-code-ide--terminal-ensure-backend) #'ignore)
                  ((symbol-function 'claude-code-ide--read-instance-name)
                   (lambda (&rest _) (error "Must not prompt")))
                  ((symbol-function 'claude-code-ide-mcp-create-session)
                   (lambda (dir session-id &optional instance-name)
                     (claude-code-ide-tests--make-session
                      dir :session-id session-id :instance-name instance-name :port 12345)))
                  ((symbol-function 'claude-code-ide--create-terminal-session)
                   (lambda (&rest args) (setq terminal-args args) (cons buffer process)))
                  ((symbol-function 'claude-code-ide-mcp-server-session-started) #'ignore)
                  ((symbol-function 'claude-code-ide-mcp-server-update-session-buffer) #'ignore)
                  ((symbol-function 'claude-code-ide--setup-terminal-keybindings) #'ignore)
                  ((symbol-function 'claude-code-ide--display-buffer-in-side-window) #'ignore)
                  ((symbol-function 'claude-code-ide--maybe-install-global-advice) #'ignore)
                  ((symbol-function 'run-with-timer) #'ignore)
                  ((symbol-function 'sleep-for) #'ignore))
          (let ((claude-code-ide-terminal-backend 'ghostel)
                (claude-code-ide-cli-extra-flags "--model global"))
            (claude-code-ide--start-session
             nil nil (claude-code-ide-start-spec-create
                      :directory "/tmp/spec-project/" :instance-name "refactor"
                      :resume-id "cli-id" :extra-flags "--model opus" :prompt "note"))
            (should (equal (nth 1 terminal-args) "/tmp/spec-project/"))
            ;; The provider builds the command from the spec and the args
            (let ((built nil))
              (cl-letf (((symbol-function 'claude-code-ide--build-claude-command)
                         (lambda (&rest args) (setq built args) "claude")))
                (funcall (nth 8 terminal-args)))
              (should (equal (nthcdr 3 built) '(("--resume" "cli-id" "--hooked") "note"))))
            (let ((session (car started))
                  (spec (cdr started)))
              (should (equal (claude-code-ide-mcp-session-instance-name session) "refactor"))
              (should (equal (claude-code-ide-start-spec-extra-flags spec) "--model opus"))
              (should (equal (claude-code-ide-start-spec-resume-id spec) "cli-id")))))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (let ((kill-buffer-hook nil))
          (kill-buffer buffer)))
      (claude-code-ide-tests--clear-processes))))

(ert-deftest claude-code-ide-test-free-instance-name ()
  "A stored name is kept when free and replaced by an auto name when taken."
  (claude-code-ide-tests--clear-processes)
  (unwind-protect
      (progn
        (claude-code-ide-tests--make-session "/tmp/free-name/" :instance-name "refactor")
        (should (equal (claude-code-ide--free-instance-name "/tmp/free-name/" "docs") "docs"))
        (should-not (claude-code-ide--free-instance-name "/tmp/free-name/" "refactor")))
    (claude-code-ide-tests--clear-processes)))

(ert-deftest claude-code-ide-test-cleanup-session-end-reason ()
  "The end hook says `killed' for a live CLI and `exited' for a dead one."
  (claude-code-ide-tests--clear-processes)
  (let* ((reasons '())
         (claude-code-ide-session-end-functions
          (list (lambda (_session reason) (push reason reasons))))
         (live (start-process "mock-live" nil "sleep" "30"))
         (dead (start-process "mock-dead" nil "true")))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-ide-mcp--stop-session) #'ignore)
                  ((symbol-function 'claude-code-ide-mcp-server-session-ended) #'ignore))
          (while (process-live-p dead)
            (accept-process-output dead 0.05))
          (claude-code-ide--cleanup-session
           (claude-code-ide-tests--make-session "/tmp/end-reason/" :process live))
          (claude-code-ide--cleanup-session
           (claude-code-ide-tests--make-session "/tmp/end-reason/" :process dead))
          (should (equal (nreverse reasons) '(killed exited))))
      (when (process-live-p live)
        (delete-process live))
      (claude-code-ide-tests--clear-processes))))

(defun claude-code-ide-tests--cli-session-file (config-dir id &optional name source)
  "Write a CLI session file in CONFIG-DIR for this Emacs's PID with session ID.
NAME and SOURCE are its name and name source.  This Emacs runs, so the
file counts as a running CLI process."
  (make-directory (expand-file-name "sessions" config-dir) t)
  (with-temp-file (expand-file-name (format "sessions/%d.json" (emacs-pid)) config-dir)
    (insert (format "{\"pid\":%d,\"sessionId\":\"%s\",\"cwd\":\"/tmp\",\"name\":\"%s\",\"nameSource\":\"%s\"}"
                    (emacs-pid) id (or name "proj-2d") (or source "derived")))))

(ert-deftest claude-code-ide-test-registry-restore-after-exit ()
  "A restore takes the crashed sessions and those of the last Emacs exit.
Older exits, sessions that the user ended, and sessions whose id a
running CLI has are left alone."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment)))
      (claude-code-ide-tests--cli-session-file config-dir "id-running")
      (claude-code-ide-session-registry--submit
       "setup"
       (lambda (_)
         (list (claude-code-ide-tests--registry-entry
                "old-exit" :session-id "id-old" :state 'closed :closed-by "emacs-exit"
                :closed-at "2026-11-10T10:00:00Z" :emacs-pid 999999991)
               (claude-code-ide-tests--registry-entry
                "last-exit" :session-id "id-last" :state 'closed :closed-by "emacs-exit"
                :closed-at "2026-11-11T18:46:34Z" :emacs-pid 999999992)
               (claude-code-ide-tests--registry-entry
                "last-exit-running" :session-id "id-running" :state 'closed :closed-by "emacs-exit"
                :closed-at "2026-11-11T18:46:34Z" :emacs-pid 999999992)
               (claude-code-ide-tests--registry-entry
                "user-ended" :session-id "id-ended" :state 'closed :closed-by "exited"
                :closed-at "2026-11-11T18:00:00Z" :emacs-pid 999999992)
               (claude-code-ide-tests--registry-entry
                "crashed" :session-id "id-crashed" :emacs-pid 999999993))))
      (should (equal (sort (mapcar #'claude-code-ide-session-registry-entry-key
                                   (claude-code-ide-session-registry--restorable-entries))
                           #'string<)
                     '("crashed" "last-exit"))))))

(ert-deftest claude-code-ide-test-registry-restore-after-a-later-crash ()
  "An exit is not restored again when a later Emacs ran and crashed.
The later Emacs restored that exit's sessions, so each session id comes
back once, from the crashed Emacs's entry."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment)))
      (claude-code-ide-session-registry--submit
       "setup"
       (lambda (_)
         (list (claude-code-ide-tests--registry-entry
                "exit-a" :session-id "id-a" :state 'closed :closed-by "emacs-exit"
                :closed-at "2026-11-11T18:46:34Z" :emacs-pid 999999992)
               (claude-code-ide-tests--registry-entry
                "exit-b" :session-id "id-b" :state 'closed :closed-by "emacs-exit"
                :closed-at "2026-11-11T18:46:34Z" :emacs-pid 999999992)
               (claude-code-ide-tests--registry-entry
                "crashed-a" :session-id "id-a" :started-at "2026-11-11T19:30:00Z"
                :emacs-pid 999999993)
               (claude-code-ide-tests--registry-entry
                "crashed-c" :session-id "id-c" :started-at "2026-11-11T21:00:00Z"
                :emacs-pid 999999993))))
      (should (equal (sort (mapcar #'claude-code-ide-session-registry-entry-key
                                   (claude-code-ide-session-registry--restorable-entries))
                           #'string<)
                     '("crashed-a" "crashed-c"))))))

(ert-deftest claude-code-ide-test-registry-restore-one-entry-per-session ()
  "Two restorable entries with one session id restore once, from the newer."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment)))
      (claude-code-ide-session-registry--submit
       "setup"
       (lambda (_)
         (list (claude-code-ide-tests--registry-entry
                "older" :session-id "id-same" :started-at "2026-11-10T10:00:00Z"
                :emacs-pid 999999991)
               (claude-code-ide-tests--registry-entry
                "newer" :session-id "id-same" :started-at "2026-11-11T10:00:00Z"
                :emacs-pid 999999993))))
      (should (equal (mapcar #'claude-code-ide-session-registry-entry-key
                             (claude-code-ide-session-registry--restorable-entries))
                     '("newer"))))))

(ert-deftest claude-code-ide-test-registry-adopts-running-sessions ()
  "A session that ran before the registry is recorded with its CLI's id."
  (claude-code-ide-tests--clear-processes)
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (claude-code-ide-session-registry--adopted (make-hash-table :test 'eq :weakness 'key))
           (claude-code-ide-session-registry--adopt-timer nil)
           (buffer (generate-new-buffer "*cc-adopt*"))
           (session (claude-code-ide-tests--make-session
                     "/tmp/adopt-project/" :buffer buffer :cli-pid (emacs-pid)
                     :instance-name "docs")))
      (unwind-protect
          (cl-letf (((symbol-function 'run-with-timer) (lambda (&rest _) nil)))
            (claude-code-ide-tests--cli-session-file config-dir "id-adopted")
            (should (= 1 (claude-code-ide-session-registry--adopt-running-sessions)))
            (should (= 0 (claude-code-ide-session-registry--adopt-running-sessions)))
            (let ((entry (car (claude-code-ide-session-registry--load))))
              (should (equal (claude-code-ide-session-registry-entry-session-id entry) "id-adopted"))
              (should (equal (claude-code-ide-session-registry-entry-project-dir entry) "/tmp/adopt-project/"))
              (should (equal (claude-code-ide-session-registry-entry-instance-name entry) "docs"))
              (should (equal (claude-code-ide-session-registry-entry-buffer-name entry) "*cc-adopt*"))
              (should (eq (claude-code-ide-session-registry-entry-state entry) 'open)))
            ;; /clear gives the CLI a new id
            (claude-code-ide-tests--cli-session-file config-dir "id-after-clear")
            (claude-code-ide-session-registry--refresh-adopted-ids)
            (should (equal (claude-code-ide-session-registry-entry-session-id
                            (car (claude-code-ide-session-registry--load)))
                           "id-after-clear"))
            (should (gethash session claude-code-ide-session-registry--keys)))
        (kill-buffer buffer)
        (claude-code-ide-tests--clear-processes)))))

(ert-deftest claude-code-ide-test-cli-environment-unset ()
  "Names in `claude-code-ide-cli-environment-unset' leave the CLI's environment only."
  (let* ((claude-code-ide-cli-environment-unset '("CCI_TEST_SECRET"))
         (claude-code-ide-no-flicker nil)
         (process-environment (cons "CCI_TEST_SECRET=from-emacs" process-environment))
         (env (claude-code-ide--cli-environment 4242)))
    (should (equal (car env) "CCI_TEST_SECRET"))
    (should (member "CLAUDE_CODE_SSE_PORT=4242" env))
    (let ((process-environment (append env process-environment)))
      (should (equal (with-temp-buffer
                       (call-process "sh" nil t nil "-c" "printf %s \"${CCI_TEST_SECRET-unset}\"")
                       (buffer-string))
                     "unset")))
    (should (equal (getenv "CCI_TEST_SECRET") "from-emacs"))))

(ert-deftest claude-code-ide-test-registry-restore-survives-failures ()
  "A quit or an error in one start of a restore does not stop the others."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (entries (mapcar #'claude-code-ide-tests--registry-entry '("a" "b" "c")))
           (timers '())
           (started '())
           (messages '()))
      (claude-code-ide-session-registry--submit "setup" (lambda (_) entries))
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (_secs _repeat fn &rest args) (push (cons fn args) timers)))
                ((symbol-function 'claude-code-ide-session-registry--start-entry)
                 (lambda (entry _prompt)
                   (pcase (claude-code-ide-session-registry-entry-key entry)
                     ("a" (signal 'quit nil))
                     ("b" (error "Directory /x does not exist"))
                     (key (push key started)))))
                ((symbol-function 'message)
                 (lambda (format-string &rest args) (push (apply #'format format-string args) messages))))
        (claude-code-ide-session-registry--start-entries entries "note")
        (should (= 3 (length timers)))
        (dolist (timer (reverse timers))
          (apply (car timer) (cdr timer))))
      (should (equal started '("c")))
      (should (string-match-p "\\`Restored 1 session; failed: .*quit; .*Directory /x does not exist"
                              (car messages))))))

(ert-deftest claude-code-ide-test-registry-hooks-with-shell-characters ()
  "A report directory with ;, & and | in its path still gets the hooks."
  (claude-code-ide-tests--with-registry
    (cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) #'ignore))
      (let* ((claude-code-ide-session-registry-report-directory
              (expand-file-name "a;b&c|d" registry-dir))
             (claude-code-ide-cli-extra-flags "")
             (args (claude-code-ide-session-registry--cli-args
                    (make-claude-code-ide-mcp-session) (claude-code-ide-tests--registry-spec)))
             (settings (cadr (member "--settings" args)))
             (parts (cdr (claude-code-ide--parse-command-string
                          (claude-code-ide--build-claude-command nil nil "sid" args)))))
        (should settings)
        ;; The hook command quotes the path for the shell that runs it
        (let* ((hooks (alist-get 'hooks (claude-code-ide-session-registry--json-decode settings)))
               (command (alist-get 'command
                                   (car (alist-get 'hooks (car (alist-get 'SessionStart hooks)))))))
          (should (string-prefix-p
                   (concat "cat > " (shell-quote-argument
                                     (expand-file-name "a;b&c|d" registry-dir)))
                   command)))
        (should (equal (cadr (member "--settings" parts)) settings))))))

(ert-deftest claude-code-ide-test-registry-track-adopted-session ()
  "An adopted session restarts through the registry; one whose turn runs is refused."
  (claude-code-ide-tests--clear-processes)
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (claude-code-ide-session-registry--adopted (make-hash-table :test 'eq :weakness 'key))
           (claude-code-ide-session-registry--adopt-timer nil)
           (buffer (generate-new-buffer "*cc-track*"))
           (session (claude-code-ide-tests--make-session
                     "/tmp/track-project/" :buffer buffer :cli-pid (emacs-pid)
                     :instance-name "orchestrator"))
           (starts '()))
      (unwind-protect
          (cl-letf (((symbol-function 'run-with-timer) (lambda (&rest _) nil))
                    ((symbol-function 'claude-code-ide-session-registry--wait-for-exit) (lambda (_pid) t))
                    ((symbol-function 'claude-code-ide-session-registry--start-entry)
                     (lambda (entry note)
                       (push (list (claude-code-ide-session-registry-entry-session-id entry)
                                   (claude-code-ide-session-registry-entry-instance-name entry)
                                   note)
                             starts))))
            ;; The CLI reports busy
            (make-directory (expand-file-name "sessions" config-dir) t)
            (with-temp-file (expand-file-name (format "sessions/%d.json" (emacs-pid)) config-dir)
              (insert (format "{\"pid\":%d,\"sessionId\":\"id-orch\",\"cwd\":\"/tmp\",\"status\":\"busy\"}" (emacs-pid))))
            (claude-code-ide-session-registry--adopt-running-sessions)
            (should (equal (claude-code-ide-session-registry--untracked-sessions) (list session)))
            (should-error (claude-code-ide-session-registry--track-session session "note") :type 'user-error)
            (should (buffer-live-p buffer))
            (should-not starts)
            ;; The old buffer ends, and the entry resumes
            ;; At the prompt with a background shell, it restarts without force
            (with-temp-file (expand-file-name (format "sessions/%d.json" (emacs-pid)) config-dir)
              (insert (format "{\"pid\":%d,\"sessionId\":\"id-orch\",\"cwd\":\"/tmp\",\"status\":\"shell\"}" (emacs-pid))))
            (should (claude-code-ide-session-registry--track-session session "note"))
            (should-not (buffer-live-p buffer))
            (should (equal starts '(("id-orch" "orchestrator" "note")))))
        (when (buffer-live-p buffer)
          (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
        (claude-code-ide-tests--clear-processes)))))

;;; Codex records, provisional records, and restore by provider

(defvar claude-code-ide-tests--codex-missing nil
  "Non-nil makes the mocked Codex detection find no Codex CLI.")

(defvar claude-code-ide-tests--registry-launches nil
  "Launches of `claude-code-ide-tests--with-mocked-starts', newest first.
Each is (BUFFER-NAME COMMAND-PLIST).")

(defmacro claude-code-ide-tests--with-mocked-starts (&rest body)
  "Run BODY where `claude-code-ide--start-session' runs with a mocked terminal.
The terminal calls the launch function, as the real one does, and
records (BUFFER-NAME COMMAND) in `claude-code-ide-tests--registry-launches'.
Each start gets a new buffer of that name and a sleep process, which
end at the end without the end functions, as after a crash.  The
registry hooks of the start are on.  Timers go to the list `timers'
and do not run.  Codex is found unless `claude-code-ide-tests--codex-missing'
is non-nil, and its MCP setup is mocked."
  (declare (indent 0))
  `(let ((claude-code-ide-tests--registry-launches nil)
         (cleanup '())
         (timers '())
         (claude-code-ide-cli-args-functions (list #'claude-code-ide-session-registry--cli-args))
         (claude-code-ide-session-start-functions (list #'claude-code-ide-session-registry--on-start))
         (claude-code-ide-session-end-functions (list #'claude-code-ide-session-registry--on-end))
         ;; Run by the start when claude-code-ide.el has the hook
         (claude-code-ide-session-prepare-functions
          (list #'claude-code-ide-session-registry--on-prepare)))
     (let ((claude-code-ide-instance--all nil)
           (claude-code-ide-instance--generations (make-hash-table :test 'equal))
           (claude-code-ide-codex-extra-flags "")
           (claude-code-ide-codex-cli-path "codex"))
       (claude-code-ide-tests--clear-processes)
       (unwind-protect
           (progn
             (cl-letf (((symbol-function 'claude-code-ide--ensure-cli) (lambda () t))
                       ;; No MCP server and no status hooks in the commands
                       ((symbol-function 'claude-code-ide-mcp-server-ensure-server) #'ignore)
                       ((symbol-function 'claude-code-ide-codex--mcp-setup) #'ignore)
                       ((symbol-function 'claude-code-ide-codex-status-hook-args) nil)
                       ((symbol-function 'claude-code-ide-codex-status-hook-env) nil)
                       ((symbol-function 'claude-code-ide-codex--detect)
                        (lambda (&optional _)
                          (list :available (not claude-code-ide-tests--codex-missing)
                                :program "codex" :version 'unknown)))
                       ((symbol-function 'claude-code-ide--terminal-ensure-backend) #'ignore)
                       ((symbol-function 'claude-code-ide--read-instance-name)
                        (lambda (&rest _) (error "Must not prompt")))
                       ((symbol-function 'claude-code-ide-mcp-create-session)
                        (lambda (dir session-id &optional instance-name)
                          (claude-code-ide-tests--make-session
                           dir :session-id session-id :instance-name instance-name :port 12345)))
                       ((symbol-function 'claude-code-ide--create-terminal-session)
                        (lambda (&rest args)
                          (let ((command (funcall (nth 8 args)))
                                (buffer (generate-new-buffer (car args)))
                                (process (start-process "cci-test-registry" nil "sleep" "30")))
                            (push buffer cleanup)
                            (push process cleanup)
                            (push (list (buffer-name buffer) command)
                                  claude-code-ide-tests--registry-launches)
                            (cons buffer process))))
                       ((symbol-function 'claude-code-ide-mcp-server-session-started) #'ignore)
                       ((symbol-function 'claude-code-ide-mcp-server-session-ended) #'ignore)
                       ((symbol-function 'claude-code-ide-mcp--stop-session)
                        (lambda (session)
                          (remhash (claude-code-ide-mcp-session-session-id session)
                                   claude-code-ide-mcp--sessions)))
                       ((symbol-function 'claude-code-ide-mcp-server-update-session-buffer) #'ignore)
                       ((symbol-function 'claude-code-ide--setup-terminal-keybindings) #'ignore)
                       ((symbol-function 'claude-code-ide--display-buffer-in-side-window) #'ignore)
                       ((symbol-function 'claude-code-ide--maybe-install-global-advice) #'ignore)
                       ((symbol-function 'run-with-timer)
                        (lambda (_secs _repeat fn &rest args) (push (cons fn args) timers) nil))
                       ((symbol-function 'sleep-for) #'ignore))
               (let ((claude-code-ide-terminal-backend 'ghostel))
                 ,@body)))
         ;; As after a crash: no cleanup and no end functions run
         (dolist (object cleanup)
           (cond
            ((processp object)
             (set-process-sentinel object #'ignore)
             (when (process-live-p object) (delete-process object)))
            ((buffer-live-p object)
             (with-current-buffer object
               (setq-local kill-buffer-hook nil))
             (let ((kill-buffer-query-functions nil))
               (kill-buffer object)))))
         (claude-code-ide-tests--clear-processes)))))

(defun claude-code-ide-tests--run-restore-timers (timers)
  "Run the restore starts in TIMERS, oldest first; skip the other timers."
  (dolist (timer (reverse timers))
    (unless (symbolp (car timer))
      (apply (car timer) (cdr timer)))))

(defun claude-code-ide-tests--registry-project (dir name)
  "Return the project NAME in DIR, a new Git working tree."
  (let ((project (file-name-as-directory (expand-file-name name dir))))
    (make-directory (expand-file-name ".git" project) t)
    project))

(defun claude-code-ide-tests--launch-words (buffer-name)
  "Return the command words of the mocked launch of BUFFER-NAME."
  (claude-code-ide--split-command-line
   (plist-get (cadr (assoc buffer-name claude-code-ide-tests--registry-launches)) :command)))

(defun claude-code-ide-tests--restore-message (messages)
  "Return the newest restore summary in MESSAGES."
  (cl-find-if (lambda (text) (string-prefix-p "Restored " text)) messages))

(defmacro claude-code-ide-tests--collect-messages (var &rest body)
  "Run BODY and push each message text to the list VAR."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'message)
              (lambda (format-string &rest args)
                (push (apply #'format format-string args) ,var))))
     ,@body))

(ert-deftest claude-code-ide-test-registry-restore-mixed-providers ()
  "CC and Codex records restore with their own command, native ID, name and worktree.
The Codex restore gets no --model and no --name.  A Codex record without
a native ID starts nothing and is reported as unknown."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (cc-dir (claude-code-ide-tests--registry-project registry-dir "cci-test-cc"))
           (codex-dir (claude-code-ide-tests--registry-project registry-dir "cci-test-codex"))
           (transcripts (expand-file-name (claude-code-ide-session-registry--project-slug cc-dir)
                                          (expand-file-name "projects" config-dir)))
           (claude-code-ide-restore-note "cci-test-restored")
           (messages '()))
      (make-directory transcripts t)
      (with-temp-file (expand-file-name "cci-test-cc-native.jsonl" transcripts)
        (insert "{\"type\":\"custom-title\",\"customTitle\":\"cci-test-title\"}\n"
                "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-cci-test-1\"}}\n"))
      (claude-code-ide-session-registry--submit
       "setup"
       (lambda (_)
         (list (claude-code-ide-tests--registry-entry
                "cci-test-cc" :session-id "cci-test-cc-native" :project-dir cc-dir
                :instance-name "review" :buffer-name "*claude-code[cci-test-cc:review]*"
                :worktree cc-dir :generation 3 :emacs-pid 999999991
                :started-at "2026-11-18T09:00:00Z")
               (claude-code-ide-tests--registry-entry
                "cci-test-codex" :provider 'codex :session-id "cci-test-codex-native"
                :project-dir codex-dir :instance-name "fix" :model "gpt-cci-test"
                ;; Claude Code flags that an older start stored: never passed
                :extra-flags "--model claude-only --name old"
                :worktree codex-dir :generation 2 :emacs-pid 999999991
                :started-at "2026-11-18T09:01:00Z")
               (claude-code-ide-tests--registry-entry
                "cci-test-codex-new" :provider 'codex :session-id nil :state 'pending
                :project-dir codex-dir :emacs-pid 999999991
                :started-at "2026-11-18T09:02:00Z"))))
      (should (equal (mapcar #'claude-code-ide-session-registry-entry-key
                             (cdr (claude-code-ide-session-registry--restore-plan)))
                     '("cci-test-codex-new")))
      (claude-code-ide-tests--with-mocked-starts
        (claude-code-ide-tests--collect-messages messages
          (claude-code-ide-restore-sessions)
          (claude-code-ide-tests--run-restore-timers timers))
        (should (= (length claude-code-ide-tests--registry-launches) 2))
        ;; Claude Code: claude --resume ID, with the model and the title
        (let ((words (claude-code-ide-tests--launch-words "*claude-code[cci-test-cc:review]*")))
          (should (equal (car words) claude-code-ide-cli-path))
          (should (equal (cadr (member "--resume" words)) "cci-test-cc-native"))
          (should (equal (cadr (member "--model" words)) "claude-cci-test-1"))
          (should (equal (cadr (member "--name" words)) "cci-test-title")))
        ;; Codex: codex resume ... -- ID PROMPT, and no Claude Code flags
        (let ((words (claude-code-ide-tests--launch-words "*codex[cci-test-codex:fix]*")))
          (should (equal (cl-subseq words 0 2) '("codex" "resume")))
          (should (equal (cdr (member "--" words)) '("cci-test-codex-native" "cci-test-restored")))
          (dolist (flag '("--model" "-m" "--name" "claude-only" "--resume"))
            (should-not (member flag words))))
        ;; The descriptors keep the instance IDs and worktrees, and get the
        ;; next generation
        (let ((cc (claude-code-ide-instance-by-id "cci-test-cc"))
              (codex (claude-code-ide-instance-by-id "cci-test-codex")))
          (should (eq (claude-code-ide-instance-provider cc) 'claude))
          (should (eq (claude-code-ide-instance-provider codex) 'codex))
          (should (= (claude-code-ide-instance-generation cc) 4))
          (should (= (claude-code-ide-instance-generation codex) 3))
          (should (equal (claude-code-ide-instance-native-id codex) "cci-test-codex-native"))
          (should (equal (claude-code-ide-instance-worktree cc) cc-dir))
          (should (equal (claude-code-ide-instance-worktree codex) codex-dir))
          (should-not (claude-code-ide-instance-by-id "cci-test-codex-new")))
        (let ((codex (claude-code-ide-tests--registry-get "cci-test-codex"))
              (new (claude-code-ide-tests--registry-get "cci-test-codex-new")))
          (should (eq (claude-code-ide-session-registry-entry-state
                       (claude-code-ide-tests--registry-get "cci-test-cc"))
                      'open))
          (should (eq (claude-code-ide-session-registry-entry-state codex) 'open))
          (should (equal (claude-code-ide-session-registry-entry-instance-name codex) "fix"))
          (should (equal (claude-code-ide-session-registry-entry-buffer-name codex)
                         "*codex[cci-test-codex:fix]*"))
          (should (equal (claude-code-ide-session-registry-entry-worktree codex) codex-dir))
          (should (equal (claude-code-ide-session-registry-entry-extra-flags codex) ""))
          (should (= (claude-code-ide-session-registry-entry-generation codex) 3))
          (should (integerp (claude-code-ide-session-registry-entry-pid codex)))
          (should (numberp (claude-code-ide-session-registry-entry-process-start-time codex)))
          ;; The record without a conversation did not change
          (should (eq (claude-code-ide-session-registry-entry-state new) 'pending))
          (should-not (claude-code-ide-session-registry-entry-session-id new))
          (should (equal (claude-code-ide-session-registry--list-state new) "unknown"))))
      (should (string-match-p
               "\\`Restored 2 sessions; unknown, no conversation to resume: cci-test-codex-new "
               (claude-code-ide-tests--restore-message messages))))))

(ert-deftest claude-code-ide-test-registry-restart-v1-and-v2-with-failure ()
  "Acceptance check 5: a restart restores v1 and v2 records.
One failed restore leaves the others usable: it marks only its own
record `failed', with the reason, and the next restore tries it again."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (cc-dir (claude-code-ide-tests--registry-project registry-dir "cci-test-v1"))
           (codex-dir (claude-code-ide-tests--registry-project registry-dir "cci-test-v2"))
           (gone (expand-file-name "cci-test-gone/" registry-dir))
           (v1-file (claude-code-ide-session-registry--v1-file))
           (claude-code-ide-restore-note nil)
           (claude-code-ide-tests--codex-missing nil)
           (messages '()))
      ;; An older package wrote only the version 1 file
      (with-temp-file v1-file
        (insert (json-encode
                 `((version . 1)
                   (sessions
                    . [((key . "cci-test-v1-ok") (session_id . "cci-test-v1-native")
                        (project_dir . ,cc-dir) (instance_name . "one") (extra_flags . "")
                        (state . "open") (started_at . "2026-11-18T08:00:00Z")
                        (emacs_pid . 999999991) (host . ,(system-name)))
                       ((key . "cci-test-v1-gone") (session_id . "cci-test-v1-gone-native")
                        (project_dir . ,gone) (extra_flags . "")
                        (state . "open") (started_at . "2026-11-18T08:01:00Z")
                        (emacs_pid . 999999991) (host . ,(system-name)))])))))
      (let ((v1-text (claude-code-ide-session-registry--file-string v1-file)))
        ;; First Emacs of the new package: restore from the version 1 file
        (claude-code-ide-tests--with-mocked-starts
          (claude-code-ide-tests--collect-messages messages
            (claude-code-ide-restore-sessions)
            (claude-code-ide-tests--run-restore-timers timers))
          (should (= (length claude-code-ide-tests--registry-launches) 1))
          (should (equal (cadr (member "--resume" (claude-code-ide-tests--launch-words
                                                   "*claude-code[cci-test-v1:one]*")))
                         "cci-test-v1-native")))
        (should (string-match-p "\\`Restored 1 session; failed: .*cci-test-gone/ does not exist"
                                (claude-code-ide-tests--restore-message messages)))
        (let ((gone-entry (claude-code-ide-tests--registry-get "cci-test-v1-gone")))
          (should (eq (claude-code-ide-session-registry-entry-state gone-entry) 'failed))
          (should (string-match-p "does not exist"
                                  (claude-code-ide-session-registry-entry-failure gone-entry)))
          (should (equal (claude-code-ide-session-registry-entry-session-id gone-entry)
                         "cci-test-v1-gone-native")))
        (should (eq (claude-code-ide-session-registry-entry-state
                     (claude-code-ide-tests--registry-get "cci-test-v1-ok"))
                    'open))
        ;; The version 1 file stays as it was
        (should (equal (claude-code-ide-session-registry--file-string v1-file) v1-text)))
      ;; That Emacs crashed.  It also had started a Codex instance.
      (claude-code-ide-session-registry--submit
       "crash"
       (lambda (entries)
         (append
          (mapcar (lambda (entry)
                    (let ((copy (claude-code-ide-session-registry-entry-copy entry)))
                      (setf (claude-code-ide-session-registry-entry-emacs-pid copy) 999999992
                            (claude-code-ide-session-registry-entry-emacs-start-time copy) nil
                            (claude-code-ide-session-registry-entry-pid copy) nil)
                      copy))
                  entries)
          (list (claude-code-ide-tests--registry-entry
                 "cci-test-v2-codex" :provider 'codex :session-id "cci-test-v2-native"
                 :project-dir codex-dir :instance-name "two" :emacs-pid 999999992
                 :started-at "2026-11-18T08:02:00Z")))))
      (setq claude-code-ide-session-registry--keys (make-hash-table :test 'eq :weakness 'key)
            claude-code-ide-session-registry--started (make-hash-table :test 'eq :weakness 'key)
            messages nil)
      ;; The restart: Codex is missing now
      (let ((claude-code-ide-tests--codex-missing t))
        (claude-code-ide-tests--with-mocked-starts
          (claude-code-ide-tests--collect-messages messages
            (claude-code-ide-restore-sessions)
            (claude-code-ide-tests--run-restore-timers timers))
          (should (equal (mapcar #'car claude-code-ide-tests--registry-launches)
                         '("*claude-code[cci-test-v1:one]*")))))
      (let ((summary (claude-code-ide-tests--restore-message messages)))
        (should (string-match-p "\\`Restored 1 session; failed: " summary))
        (should (string-match-p "cci-test-gone/ does not exist" summary))
        (should (string-match-p "Codex CLI not available" summary)))
      (let ((codex (claude-code-ide-tests--registry-get "cci-test-v2-codex")))
        (should (eq (claude-code-ide-session-registry-entry-state codex) 'failed))
        (should (string-match-p "Codex CLI not available"
                                (claude-code-ide-session-registry-entry-failure codex)))
        (should (equal (claude-code-ide-session-registry-entry-emacs-pid codex) (emacs-pid))))
      ;; Codex is installed again: the next restore tries the failed records
      (setq claude-code-ide-session-registry--keys (make-hash-table :test 'eq :weakness 'key)
            messages nil)
      (claude-code-ide-tests--with-mocked-starts
        (claude-code-ide-tests--collect-messages messages
          (let ((keys (mapcar #'claude-code-ide-session-registry-entry-key
                              (claude-code-ide-session-registry--restorable-entries))))
            (should (member "cci-test-v1-gone" keys))
            (should (member "cci-test-v2-codex" keys)))
          (claude-code-ide-restore-sessions)
          (claude-code-ide-tests--run-restore-timers timers))
        (let ((words (claude-code-ide-tests--launch-words "*codex[cci-test-v2:two]*")))
          (should (equal (cl-subseq words 0 2) '("codex" "resume")))
          (should (equal (cdr (member "--" words)) '("cci-test-v2-native")))))
      (let ((codex (claude-code-ide-tests--registry-get "cci-test-v2-codex")))
        (should (eq (claude-code-ide-session-registry-entry-state codex) 'open))
        (should-not (claude-code-ide-session-registry-entry-failure codex))))))

(ert-deftest claude-code-ide-test-registry-provisional-record ()
  "A CC record is `pending' before the spawn, with the id that Emacs chose.
A new start that fails before its start is recorded removes its record."
  (claude-code-ide-tests--with-registry
    (let ((claude-code-ide-instance--all nil)
          (claude-code-ide-instance--generations (make-hash-table :test 'equal)))
      (let* ((session (claude-code-ide-tests--make-session "/tmp/cci-test-pending/"))
             (instance (claude-code-ide-instance-register
                        (claude-code-ide-instance-create
                         :id "cci-test-pending" :provider 'claude :generation 1
                         :worktree "/tmp/cci-test-pending/" :session session)))
             (spec (claude-code-ide-tests--registry-spec
                    :directory "/tmp/cci-test-pending/" :instance-name "p"
                    :extra-flags "--model opus"))
             (args (claude-code-ide-session-registry--cli-args session spec))
             (native (cadr (member "--session-id" args)))
             (entry (claude-code-ide-tests--registry-get "cci-test-pending")))
        (unwind-protect
            (progn
              ;; Saved before the spawn
              (should (eq (claude-code-ide-session-registry-entry-state entry) 'pending))
              (should (equal (claude-code-ide-session-registry-entry-session-id entry) native))
              (should (equal (claude-code-ide-session-registry-entry-worktree entry)
                             "/tmp/cci-test-pending/"))
              (should (= (claude-code-ide-session-registry-entry-generation entry) 1))
              (should (numberp (claude-code-ide-session-registry-entry-emacs-start-time entry)))
              ;; The prepare hook of a start does not save it twice
              (should-not (claude-code-ide-session-registry--on-prepare session spec))
              ;; After the spawn the descriptor has the process
              (setf (claude-code-ide-instance-pid instance) (emacs-pid)
                    (claude-code-ide-instance-process-start-time instance)
                    (claude-code-ide-session-registry--emacs-start-time))
              (claude-code-ide-session-registry--on-start session spec)
              (setq entry (claude-code-ide-tests--registry-get "cci-test-pending"))
              (should (eq (claude-code-ide-session-registry-entry-state entry) 'open))
              (should (equal (claude-code-ide-session-registry-entry-session-id entry) native))
              (should (equal (claude-code-ide-session-registry-entry-model entry) "opus"))
              (should (= (claude-code-ide-session-registry-entry-pid entry) (emacs-pid)))
              ;; Its process runs, so a restore leaves it alone
              (should (claude-code-ide-session-registry--owner-live-p entry))
              ;; A new start that fails: its provisional record goes away
              (let ((failed (claude-code-ide-tests--make-session "/tmp/cci-test-pending/")))
                (claude-code-ide-session-registry--cli-args
                 failed (claude-code-ide-tests--registry-spec :directory "/tmp/cci-test-pending/"))
                (let ((key (gethash failed claude-code-ide-session-registry--keys)))
                  (should (eq (claude-code-ide-session-registry-entry-state
                               (claude-code-ide-tests--registry-get key))
                              'pending))
                  (should (eq (gethash failed claude-code-ide-session-registry--pending) 'new))
                  (claude-code-ide-session-registry--on-end failed 'exited)
                  (should-not (claude-code-ide-tests--registry-get key))))
              ;; A new start whose terminal never came up goes away at the check
              (let ((failed (claude-code-ide-tests--make-session "/tmp/cci-test-pending/")))
                (claude-code-ide-session-registry--cli-args
                 failed (claude-code-ide-tests--registry-spec :directory "/tmp/cci-test-pending/"))
                (let ((key (gethash failed claude-code-ide-session-registry--keys)))
                  ;; The MCP session still exists: the start runs
                  (claude-code-ide-session-registry--check-pending)
                  (should (claude-code-ide-tests--registry-get key))
                  (remhash (claude-code-ide-mcp-session-session-id failed)
                           claude-code-ide-mcp--sessions)
                  (claude-code-ide-session-registry--check-pending)
                  (should-not (claude-code-ide-tests--registry-get key))))
              (should (equal (claude-code-ide-tests--registry-file-keys) '("cci-test-pending"))))
          (claude-code-ide-tests--clear-processes))))))

(ert-deftest claude-code-ide-test-registry-codex-report ()
  "A Codex record waits for its SessionStart report, which is idempotent.
The provisional record has no native ID, no Claude Code flags and the
descriptor's worktree.  The report fills in the native ID, the
transcript and the model.  The same report twice gives the same file;
a report of a subagent or of an older launch changes nothing."
  (claude-code-ide-tests--with-registry
    (let ((claude-code-ide-instance--all nil)
          (claude-code-ide-instance--generations (make-hash-table :test 'equal)))
      (let* ((session (claude-code-ide-tests--make-session "/tmp/cci-test-cx/"))
             (_instance (claude-code-ide-instance-register
                         (claude-code-ide-instance-create
                          :id "cci-test-cx" :provider 'codex :generation 2
                          :worktree "/tmp/cci-test-cx/" :session session)))
             (spec (claude-code-ide-tests--registry-spec
                    :directory "/tmp/cci-test-cx/" :provider 'codex :instance-name "cx"
                    :extra-flags "--model claude-only"))
             (file (claude-code-ide-session-registry--state-file))
             (event (lambda (generation data)
                      (claude-code-ide-make-event "cci-test-cx" generation 'session-start
                                                  "SessionStart" data))))
        (unwind-protect
            (progn
              ;; No Claude Code arguments for Codex
              (should-not (claude-code-ide-session-registry--cli-args session spec))
              (should-not (claude-code-ide-tests--registry-get "cci-test-cx"))
              (claude-code-ide-session-registry--on-prepare session spec)
              (claude-code-ide-session-registry--on-start session spec)
              (let ((entry (claude-code-ide-tests--registry-get "cci-test-cx")))
                (should (eq (claude-code-ide-session-registry-entry-provider entry) 'codex))
                (should (eq (claude-code-ide-session-registry-entry-state entry) 'pending))
                (should-not (claude-code-ide-session-registry-entry-session-id entry))
                (should (equal (claude-code-ide-session-registry-entry-extra-flags entry) ""))
                (should-not (claude-code-ide-session-registry-entry-model entry))
                (should (equal (claude-code-ide-session-registry-entry-instance-name entry) "cx"))
                (should (equal (claude-code-ide-session-registry-entry-worktree entry)
                               "/tmp/cci-test-cx/")))
              (let ((report (funcall event 2 '((session_id . "cci-test-cx-native")
                                               (transcript_path . "/tmp/cci-test-cx/rollout.jsonl")
                                               (model . "gpt-cci-test")
                                               (source . "startup")))))
                (claude-code-ide-session-registry--on-event report)
                (let ((entry (claude-code-ide-tests--registry-get "cci-test-cx"))
                      (text (claude-code-ide-session-registry--file-string file)))
                  (should (eq (claude-code-ide-session-registry-entry-state entry) 'open))
                  (should (equal (claude-code-ide-session-registry-entry-session-id entry)
                                 "cci-test-cx-native"))
                  (should (equal (claude-code-ide-session-registry-entry-transcript-path entry)
                                 "/tmp/cci-test-cx/rollout.jsonl"))
                  (should (equal (claude-code-ide-session-registry-entry-model entry) "gpt-cci-test"))
                  ;; The same report again: the same file
                  (claude-code-ide-session-registry--on-event report)
                  (should (equal (claude-code-ide-session-registry--file-string file) text))
                  ;; A subagent's SessionStart, one of an older launch, and
                  ;; another event
                  (claude-code-ide-session-registry--on-event
                   (funcall event 2 '((session_id . "cci-test-cx-sub") (agent_id . "a1"))))
                  (claude-code-ide-session-registry--on-event
                   (funcall event 1 '((session_id . "cci-test-cx-old"))))
                  (claude-code-ide-session-registry--on-event
                   (claude-code-ide-make-event "cci-test-cx" 2 'prompt-submit "UserPromptSubmit"
                                               '((session_id . "cci-test-cx-other"))))
                  (should (equal (claude-code-ide-session-registry--file-string file) text))))
              ;; /new in the same terminal: a new conversation, a new ID
              (claude-code-ide-session-registry--on-event
               (funcall event 2 '((session_id . "cci-test-cx-new"))))
              (let ((entry (claude-code-ide-tests--registry-get "cci-test-cx")))
                (should (equal (claude-code-ide-session-registry-entry-session-id entry)
                               "cci-test-cx-new"))
                (should-not (claude-code-ide-session-registry-entry-transcript-path entry))))
          (claude-code-ide-tests--clear-processes))))))

(ert-deftest claude-code-ide-test-registry-codex-without-native-id ()
  "A Codex record that never got a prompt starts nothing at a restore.
It is unknown in the plan and in the message, and stays as it is."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (messages '())
           (starts 0))
      (claude-code-ide-session-registry--submit
       "setup"
       (lambda (_)
         (list (claude-code-ide-tests--registry-entry
                "cci-test-noprompt" :provider 'codex :session-id nil :state 'pending
                :emacs-pid 999999991)
               (claude-code-ide-tests--registry-entry
                "cci-test-noprompt-exit" :provider 'codex :session-id nil :state 'closed
                :closed-by "emacs-exit" :closed-at "2026-11-18T10:00:00Z" :emacs-pid 999999992
                :started-at "2026-11-03T11:00:00Z"))))
      (cl-letf (((symbol-function 'claude-code-ide--start-session)
                 (lambda (&rest _) (cl-incf starts)))
                ((symbol-function 'run-with-timer)
                 (lambda (&rest _) (error "No start may be scheduled"))))
        (claude-code-ide-tests--collect-messages messages
          (claude-code-ide-restore-sessions))
        (should-error (claude-code-ide-session-registry--start-entry
                       (claude-code-ide-tests--registry-get "cci-test-noprompt") nil)
                      :type 'user-error))
      (should (= starts 0))
      (should (string-match-p
               "\\`Restored 0 sessions; unknown, no conversation to resume: cci-test-noprompt .*; cci-test-noprompt-exit "
               (claude-code-ide-tests--restore-message messages)))
      (should (eq (claude-code-ide-session-registry-entry-state
                   (claude-code-ide-tests--registry-get "cci-test-noprompt"))
                  'pending)))))

(ert-deftest claude-code-ide-test-registry-restore-refuses-live-owner ()
  "Restore does not start a record whose process or Emacs still runs.
The process ID and its start time identify the owner, so a reused
process ID with another start time does not block the restore."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (process (start-process "cci-test-owner" nil "sleep" "30"))
           (pid (process-id process))
           (start (claude-code-ide-session-registry--process-start-time pid)))
      (unwind-protect
          (progn
            (should (numberp start))
            (claude-code-ide-session-registry--submit
             "setup"
             (lambda (_)
               (list (claude-code-ide-tests--registry-entry
                      "cci-test-owned" :provider 'codex :pid pid :process-start-time start)
                     (claude-code-ide-tests--registry-entry
                      "cci-test-reused" :pid pid :process-start-time (- start 100))
                     (claude-code-ide-tests--registry-entry
                      "cci-test-other-emacs" :emacs-pid pid :emacs-start-time start)
                     (claude-code-ide-tests--registry-entry
                      "cci-test-dead-emacs" :emacs-pid pid :emacs-start-time (- start 100)))))
            (should (equal (sort (mapcar #'claude-code-ide-session-registry-entry-key
                                         (claude-code-ide-session-registry--restorable-entries))
                                 #'string<)
                           '("cci-test-dead-emacs" "cci-test-reused")))
            (cl-letf (((symbol-function 'claude-code-ide--start-session)
                       (lambda (&rest _) (error "Must not start"))))
              (should-error (claude-code-ide-session-registry--start-entry
                             (claude-code-ide-tests--registry-get "cci-test-owned") nil)
                            :type 'user-error))
            ;; The refusal is not a failure
            (should (eq (claude-code-ide-session-registry-entry-state
                         (claude-code-ide-tests--registry-get "cci-test-owned"))
                        'open))
            ;; The process ended: the record is restorable
            (delete-process process)
            (let ((tries 0))
              (while (and (process-attributes pid) (< tries 100))
                (sleep-for 0.05)
                (cl-incf tries)))
            (should (member "cci-test-owned"
                            (mapcar #'claude-code-ide-session-registry-entry-key
                                    (claude-code-ide-session-registry--restorable-entries)))))
        (when (process-live-p process)
          (delete-process process))))))

(ert-deftest claude-code-ide-test-registry-restore-exit-code-fails ()
  "A restored CLI that exits with an error soon after its start fails the record.
A clean exit, or an exit after the grace time, closes it as before."
  (claude-code-ide-tests--with-registry
    (let ((processes '()))
      (unwind-protect
          (cl-flet ((run (key code started)
                      (let* ((process (start-process "cci-test-exit" nil "sh" "-c"
                                                     (format "exit %d" code)))
                             (session (make-claude-code-ide-mcp-session :process process)))
                        (push process processes)
                        (while (process-live-p process) (accept-process-output process 0.05))
                        (claude-code-ide-session-registry--submit
                         "setup" (claude-code-ide-tests--registry-add key))
                        (puthash session key claude-code-ide-session-registry--keys)
                        (puthash session t claude-code-ide-session-registry--started)
                        (puthash session started claude-code-ide-session-registry--restoring)
                        (claude-code-ide-session-registry--on-end session 'exited)
                        (claude-code-ide-tests--registry-get key))))
            (let ((entry (run "cci-test-bad-id" 1 (float-time))))
              (should (eq (claude-code-ide-session-registry-entry-state entry) 'failed))
              (should (string-match-p "exited with code 1"
                                      (claude-code-ide-session-registry-entry-failure entry))))
            (let ((entry (run "cci-test-clean" 0 (float-time))))
              (should (eq (claude-code-ide-session-registry-entry-state entry) 'closed)))
            (let ((entry (run "cci-test-late" 1 (- (float-time) 3600))))
              (should (eq (claude-code-ide-session-registry-entry-state entry) 'closed))
              (should (equal (claude-code-ide-session-registry-entry-closed-by entry) "exited"))))
        (dolist (process processes)
          (when (process-live-p process) (delete-process process)))))))

(ert-deftest claude-code-ide-test-registry-restore-flags-by-provider ()
  "Each provider gives its own restore flags; a provider without them gets none."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment)))
      (should (equal (claude-code-ide-session-registry--restore-flags
                      (claude-code-ide-tests--registry-entry
                       "cci-test-f1" :model "opus" :extra-flags "--permission-mode plan"))
                     "--permission-mode plan --model opus"))
      (should (equal (claude-code-ide-session-registry--restore-flags
                      (claude-code-ide-tests--registry-entry
                       "cci-test-f2" :provider 'codex :model "gpt-cci-test"
                       :extra-flags "--model x --name y"))
                     "")))))

(ert-deftest claude-code-ide-test-registry-older-v2-records ()
  "A version 2 record of an earlier release, without the new fields, reads.
The new fields are nil, and a field with a wrong type is dropped."
  (claude-code-ide-tests--with-registry
    (with-temp-file (claude-code-ide-session-registry--state-file)
      (insert (json-encode
               `((version . 2)
                 (sessions
                  . [((instance_id . "cci-test-old-v2") (provider . "claude")
                      (native_id . "cci-test-old-native") (generation . 1)
                      (project_dir . "/tmp/cci-test-old/") (state . "open")
                      (pid . "not a number") (failure . 3))])))))
    (let ((entry (claude-code-ide-tests--registry-get "cci-test-old-v2")))
      (should (eq (claude-code-ide-session-registry-entry-state entry) 'open))
      (should-not (claude-code-ide-session-registry-entry-pid entry))
      (should-not (claude-code-ide-session-registry-entry-failure entry))
      (should-not (claude-code-ide-session-registry-entry-worktree entry))
      (should-not (claude-code-ide-session-registry-entry-process-start-time entry)))))

;;; Review fixes

(ert-deftest claude-code-ide-test-registry-restore-skips-running-instance ()
  "A restore skips an instance that runs, and an entry that changed after the plan.
Neither becomes `failed'."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (dir (claude-code-ide-tests--registry-project registry-dir "cci-test-dup"))
           (claude-code-ide-restore-note nil)
           (live-buffer (generate-new-buffer "*cci-test-dup-live*"))
           (messages '()))
      (unwind-protect
          (progn
            (claude-code-ide-session-registry--submit
             "setup"
             (lambda (_)
               (list (claude-code-ide-tests--registry-entry
                      "cci-test-dup" :session-id "cci-test-dup-native" :project-dir dir
                      :emacs-pid 999999991)
                     (claude-code-ide-tests--registry-entry
                      "cci-test-stale" :session-id "cci-test-stale-native" :project-dir dir
                      :emacs-pid 999999991 :started-at "2026-11-03T11:00:00Z"))))
            (claude-code-ide-tests--with-mocked-starts
              ;; The instance runs already, started outside the registry
              (claude-code-ide-instance-register
               (claude-code-ide-instance-create :id "cci-test-dup" :provider 'claude
                                                :buffer live-buffer))
              (claude-code-ide-tests--collect-messages messages
                (claude-code-ide-restore-sessions)
                ;; The user closes the other session before its timer fires
                (claude-code-ide-session-registry--submit
                 "user" (claude-code-ide-session-registry--change-archived "cci-test-stale"))
                (claude-code-ide-tests--run-restore-timers timers))
              (should-not claude-code-ide-tests--registry-launches))
            (let ((dup (claude-code-ide-tests--registry-get "cci-test-dup")))
              (should (eq (claude-code-ide-session-registry-entry-state dup) 'open))
              (should-not (claude-code-ide-session-registry-entry-failure dup)))
            (should (eq (claude-code-ide-session-registry-entry-state
                         (claude-code-ide-tests--registry-get "cci-test-stale"))
                        'archived))
            (should (string-match-p
                     "\\`Restored 0 sessions; skipped, running or changed: cci-test-dup .*; cci-test-stale "
                     (claude-code-ide-tests--restore-message messages))))
        (kill-buffer live-buffer)))))

(ert-deftest claude-code-ide-test-registry-closed-pending-never-returns ()
  "A report moves a pending entry to open, and the end closes a pending entry.
So a session that the user ended never comes back at a restore."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (picker (claude-code-ide-tests--make-session "/tmp/cci-test-picker/"))
           (codex (claude-code-ide-tests--make-session "/tmp/cci-test-noprompt/")))
      (unwind-protect
          (progn
            ;; Claude Code with the picker (-r): the id comes from the report
            (claude-code-ide-session-registry--cli-args
             picker (claude-code-ide-tests--registry-spec :resume t))
            (let ((key (gethash picker claude-code-ide-session-registry--keys)))
              (claude-code-ide-session-registry--on-start
               picker (claude-code-ide-tests--registry-spec :resume t))
              (should (eq (claude-code-ide-session-registry-entry-state
                           (claude-code-ide-tests--registry-get key))
                          'pending))
              (with-temp-file (claude-code-ide-session-registry--report-file key)
                (insert "{\"session_id\":\"cci-test-picked\",\"source\":\"resume\"}"))
              (claude-code-ide-session-registry--submit "report" #'identity)
              (let ((entry (claude-code-ide-tests--registry-get key)))
                (should (equal (claude-code-ide-session-registry-entry-session-id entry)
                               "cci-test-picked"))
                (should (eq (claude-code-ide-session-registry-entry-state entry) 'open))))
            ;; Codex without a prompt: the user kills its buffer
            (let ((spec (claude-code-ide-tests--registry-spec :provider 'codex)))
              (claude-code-ide-session-registry--on-start codex spec)
              (let ((key (gethash codex claude-code-ide-session-registry--keys)))
                (should (eq (claude-code-ide-session-registry-entry-state
                             (claude-code-ide-tests--registry-get key))
                            'pending))
                (claude-code-ide-session-registry--on-end codex 'killed)
                (let ((entry (claude-code-ide-tests--registry-get key)))
                  (should (eq (claude-code-ide-session-registry-entry-state entry) 'closed))
                  (should (equal (claude-code-ide-session-registry-entry-closed-by entry) "killed"))
                  (should-not (claude-code-ide-session-registry--restorable-p entry))))))
        (claude-code-ide-tests--clear-processes)))))

(ert-deftest claude-code-ide-test-registry-prepare-hook ()
  "The mode puts the prepare function into the start's hook and takes it out.
A start that runs the hook saves the provisional entry.  With the fork
slot of the start spec, a fork has no native ID and no --session-id."
  (claude-code-ide-tests--with-registry
    (let ((claude-code-ide-session-prepare-functions nil)
          (claude-code-ide-cli-args-functions nil)
          (claude-code-ide-session-start-functions nil)
          (claude-code-ide-session-end-functions nil)
          (claude-code-ide-session-rename-functions nil)
          (claude-code-ide-event-functions nil)
          (kill-emacs-hook nil)
          (claude-code-ide-session-registry--watch nil)
          (claude-code-ide-session-registry-mode nil)
          (session (claude-code-ide-tests--make-session "/tmp/cci-test-prepare/")))
      (unwind-protect
          (cl-letf (((symbol-function 'claude-code-ide-session-registry--start-watch) #'ignore)
                    ((symbol-function 'claude-code-ide-session-registry--adopt-running-sessions)
                     (lambda () 0))
                    ((symbol-function 'claude-code-ide-session-status--set-tracking) #'ignore))
            (claude-code-ide-session-registry-mode 1)
            (should (memq #'claude-code-ide-session-registry--on-prepare
                          claude-code-ide-session-prepare-functions))
            ;; What the start of claude-code-ide.el does before the spawn
            (run-hook-with-args 'claude-code-ide-session-prepare-functions
                                session (claude-code-ide-tests--registry-spec
                                         :provider 'codex :directory "/tmp/cci-test-prepare/"))
            (let ((key (gethash session claude-code-ide-session-registry--keys)))
              (should (eq (claude-code-ide-session-registry-entry-state
                           (claude-code-ide-tests--registry-get key))
                          'pending)))
            (claude-code-ide-session-registry-mode -1)
            (should-not (memq #'claude-code-ide-session-registry--on-prepare
                              claude-code-ide-session-prepare-functions))
            ;; The fork slot of the start spec, when it exists
            (cl-letf (((symbol-function 'claude-code-ide-start-spec-fork) (lambda (_spec) t)))
              (let ((fork (claude-code-ide-tests--registry-spec :resume-id "cci-test-source")))
                (should-not (claude-code-ide-session-registry--launch-native-id session fork))
                (should-not (member "--session-id"
                                    (claude-code-ide-session-registry--cli-args
                                     (claude-code-ide-tests--make-session "/tmp/cci-test-prepare/")
                                     (claude-code-ide-tests--registry-spec)))))))
        (setq claude-code-ide-session-registry-mode nil)
        (claude-code-ide-tests--clear-processes)))))

(ert-deftest claude-code-ide-test-registry-pending-kind-before-queue ()
  "The kind of a provisional entry is decided before the change is queued.
A change that waits for the lock still gives `new' for a new entry,
and `reopen' for an entry that only a queued change adds."
  (claude-code-ide-tests--with-registry
    (let ((lock (claude-code-ide-session-registry--lock-directory))
          (claude-code-ide-session-registry-lock-wait 0.05)
          (new (claude-code-ide-tests--make-session "/tmp/cci-test-kind/"))
          (queued (claude-code-ide-tests--make-session "/tmp/cci-test-kind/")))
      (unwind-protect
          (cl-letf (((symbol-function 'run-with-timer) (lambda (&rest _) nil))
                    ((symbol-function 'message) #'ignore))
            (make-directory (file-name-directory lock) t)
            (make-directory lock)
            (claude-code-ide-session-registry--cli-args new (claude-code-ide-tests--registry-spec))
            (should claude-code-ide-session-registry--queue)
            (should (eq (gethash new claude-code-ide-session-registry--pending) 'new))
            ;; An entry that a queued change adds
            (claude-code-ide-session-registry--submit
             "setup" (claude-code-ide-tests--registry-add "cci-test-queued"))
            (let ((claude-code-ide-session-registry--start-key nil))
              (puthash queued "cci-test-queued" claude-code-ide-session-registry--keys)
              (claude-code-ide-session-registry--record-pending
               queued (claude-code-ide-tests--registry-spec)))
            (should (eq (gethash queued claude-code-ide-session-registry--pending) 'reopen)))
        (ignore-errors (delete-directory lock))
        (claude-code-ide-tests--clear-processes)))))

(ert-deftest claude-code-ide-test-registry-corrupt-file-write-keeps-state-file ()
  "A write after a load from the backup copies the unreadable file aside.
A crash before the new file is in place still leaves a state file."
  (claude-code-ide-tests--with-registry
    (let ((file (claude-code-ide-session-registry--state-file))
          (real-rename (symbol-function 'rename-file)))
      (with-temp-file file (insert "not json"))
      (with-temp-file (claude-code-ide-session-registry--backup-file)
        (insert "{\"version\":2,\"sessions\":[]}"))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (claude-code-ide-session-registry--load))
      (should claude-code-ide-session-registry--loaded-from-backup)
      (cl-letf (((symbol-function 'rename-file)
                 (lambda (from to &rest args)
                   (if (and (string-suffix-p ".tmp" from) (equal to file))
                       (error "Simulated crash")
                     (apply real-rename from to args)))))
        (should-error (claude-code-ide-session-registry--write-file
                       (list (claude-code-ide-tests--registry-entry "cci-test-corrupt")))))
      (should (file-exists-p file))
      (should (directory-files registry-dir nil "\\.corrupt-")))))

(ert-deftest claude-code-ide-test-registry-strong-session-tables ()
  "The tables of started and pending sessions hold their sessions strongly.
A failed start must not disappear before the pending check sees it."
  (should-not (hash-table-weakness (default-value 'claude-code-ide-session-registry--keys)))
  (should-not (hash-table-weakness (default-value 'claude-code-ide-session-registry--pending))))

(ert-deftest claude-code-ide-test-registry-failed-restore-attempts ()
  "A restore tries a failed entry up to `claude-code-ide-session-registry-restore-attempts' times.
Then the entry stays `failed' and only a reopen by hand starts it; a
start that works counts from zero again."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (gone (expand-file-name "cci-test-gone/" registry-dir))
           (claude-code-ide-session-registry-restore-attempts 3)
           (attempts 0))
      (should (= (default-value 'claude-code-ide-session-registry-restore-attempts) 3))
      (should (= (default-value 'claude-code-ide-session-registry-restore-grace) 60))
      (claude-code-ide-session-registry--submit
       "setup" (lambda (_) (list (claude-code-ide-tests--registry-entry
                                  "cci-test-retry" :project-dir gone :emacs-pid 999999991))))
      (dotimes (_ 4)
        (when (claude-code-ide-session-registry--restorable-p
               (claude-code-ide-tests--registry-get "cci-test-retry"))
          (cl-incf attempts)
          (should-error (claude-code-ide-session-registry--start-entry
                         (claude-code-ide-tests--registry-get "cci-test-retry") nil))))
      (should (= attempts 3))
      (let ((entry (claude-code-ide-tests--registry-get "cci-test-retry")))
        (should (eq (claude-code-ide-session-registry-entry-state entry) 'failed))
        (should (= (claude-code-ide-session-registry-entry-failure-count entry) 3))
        (should-not (car (claude-code-ide-session-registry--restore-plan)))
        (should (claude-code-ide-session-registry--reopenable-p entry)))
      ;; The folder exists again: a reopen by hand starts it
      (make-directory gone t)
      (cl-letf (((symbol-function 'claude-code-ide--start-session)
                 (lambda (_continue _resume spec)
                   (claude-code-ide-session-registry--submit
                    "started"
                    (claude-code-ide-session-registry--change-started
                     (claude-code-ide-tests--registry-entry
                      (claude-code-ide-start-spec-instance-id spec) :project-dir gone))))))
        (claude-code-ide-reopen-session (claude-code-ide-tests--registry-get "cci-test-retry")))
      (let ((entry (claude-code-ide-tests--registry-get "cci-test-retry")))
        (should (eq (claude-code-ide-session-registry-entry-state entry) 'open))
        (should (= (claude-code-ide-session-registry-entry-failure-count entry) 0))))))

(ert-deftest claude-code-ide-test-registry-restore-context-reads-once ()
  "A restore plan reads the live sessions once and each process once."
  (claude-code-ide-tests--with-registry
    (let* ((config-dir (expand-file-name "claude" registry-dir))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config-dir) process-environment))
           (real-attributes (symbol-function 'process-attributes))
           (real-live-keys (symbol-function 'claude-code-ide-session-registry--live-keys))
           (calls 0)
           (live-key-calls 0))
      (claude-code-ide-session-registry--submit
       "setup"
       (lambda (_)
         (mapcar (lambda (n)
                   (claude-code-ide-tests--registry-entry
                    (format "cci-test-ctx-%d" n) :session-id (format "cci-test-ctx-native-%d" n)
                    :emacs-pid 999999991 :pid 999999992 :process-start-time 1.0))
                 '(1 2 3 4 5))))
      (cl-letf (((symbol-function 'process-attributes)
                 (lambda (pid)
                   (when (memql pid '(999999991 999999992)) (cl-incf calls))
                   (funcall real-attributes pid)))
                ((symbol-function 'claude-code-ide-session-registry--live-keys)
                 (lambda () (cl-incf live-key-calls) (funcall real-live-keys))))
        (should (= (length (car (claude-code-ide-session-registry--restore-plan))) 5)))
      (should (<= calls 2))
      (should (= live-key-calls 1)))))

(ert-deftest claude-code-ide-test-registry-fork-gets-no-parent-id ()
  "A fork start with the resume ID P never records P as the fork's ID.
The entry and the descriptor stay without a native ID until the report
of the fork gives its own ID, also when the entry had P before, and
also for a start that saved no provisional entry."
  (claude-code-ide-tests--with-registry
    (let ((claude-code-ide-instance--all nil)
          (claude-code-ide-instance--generations (make-hash-table :test 'equal)))
      (dolist (provider '(claude codex))
        (let* ((key (format "cci-test-fork-%s" provider))
               (session (claude-code-ide-tests--make-session "/tmp/cci-test-fork/"))
               (instance (claude-code-ide-instance-register
                          (claude-code-ide-instance-create
                           :id key :provider provider :generation 2 :session session)))
               (spec (claude-code-ide-tests--registry-spec
                      :provider provider :resume-id "cci-test-parent"
                      :extra-flags "--model opus")))
          ;; The entry held the parent conversation before
          (claude-code-ide-session-registry--submit
           "setup" (lambda (entries)
                     (append entries (list (claude-code-ide-tests--registry-entry
                                            key :provider provider
                                            :session-id "cci-test-parent")))))
          (cl-letf (((symbol-function 'claude-code-ide-start-spec-fork) (lambda (_spec) t)))
            (let ((args (claude-code-ide-session-registry--cli-args session spec)))
              (should-not (member "--session-id" args))
              (should-not (member "cci-test-parent" args)))
            ;; Claude Code saves its provisional entry in the arguments.
            ;; Codex starts here without the prepare hook (a core
            ;; without it): only the start records it.
            (when (eq provider 'claude)
              (should-not (claude-code-ide-session-registry-entry-session-id
                           (claude-code-ide-tests--registry-get key))))
            (claude-code-ide-session-registry--on-start session spec))
          (let ((entry (claude-code-ide-tests--registry-get key)))
            (should-not (claude-code-ide-session-registry-entry-session-id entry))
            (should (eq (claude-code-ide-session-registry-entry-state entry) 'pending)))
          (should-not (equal (claude-code-ide-instance-native-id instance) "cci-test-parent"))
          (claude-code-ide-instance-unregister key)))
      (claude-code-ide-tests--clear-processes))))

(provide 'claude-code-ide-session-registry-tests)

;; Local Variables:
;; no-update-autoloads: t
;; autoload-compute-prefixes: nil
;; End:

;;; claude-code-ide-session-registry-tests.el ends here
