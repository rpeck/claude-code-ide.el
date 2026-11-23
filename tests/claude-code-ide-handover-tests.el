;;; claude-code-ide-handover-tests.el --- Tests for the handover  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the handover of an instance to a new conversation: the
;; stages and their order, the quiescing, the stop and its stray
;; processes, the document, the target, the recovery at each stage,
;; the one writer rule, the inbox move, the chain in the registry, the
;; control state of registry entries, the coordinator approvals, the
;; request tool and the status key.  claude-code-ide-tests.el loads
;; this file after its mocks.
;;
;; The registry, the inbox and the worktree are temporary folders.
;; The providers are stubs, the timers run from a queue, and the
;; process stop and the start of a CLI are stubs.  All projects and IDs
;; are synthetic.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'claude-code-ide)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-control)
(require 'claude-code-ide-transcript)
(require 'claude-code-ide-handover)
(require 'claude-code-ide-session-status)
(require 'claude-code-ide-codex)
(require 'claude-code-ide-process-tests)
(require 'claude-code-ide-session-registry-tests)

(declare-function claude-code-ide-tests--wait-until "claude-code-ide-tests")
(defvar claude-code-ide-session-registry-mode)
(defvar claude-code-ide-handover-tests--states nil
  "Alist of instance ID and the state that the test state function gives.")
(defvar claude-code-ide-handover-tests--timers nil
  "Queue of (FUNCTION . ARGS) that the stubbed `run-at-time' got, oldest first.")
(defvar claude-code-ide-handover-tests--starts nil
  "Start specs that the stubbed start got, newest first.")
(defvar claude-code-ide-handover-tests--stops nil
  "Instance IDs that the stubbed process stop got, newest first.")
(defvar claude-code-ide-handover-tests--stop-result '(:status stopped)
  "Result that the stubbed process stop gives.")
(defvar claude-code-ide-handover-tests--scan-strays nil
  "Strays that the stubbed worktree scan gives.")
(defvar claude-code-ide-handover-tests--scans 0
  "Number of worktree scans.")
(defvar claude-code-ide-handover-tests--sent nil
  "List of (INSTANCE-ID TEXT) that the stub providers submitted, newest first.")
(defvar claude-code-ide-handover-tests--saved nil
  "Stages that the registry saved, oldest first.")
(defvar claude-code-ide-handover-tests--buffers nil
  "Buffers that the tests made.")
(defvar claude-code-ide-handover-tests--transcripts nil
  "Alist of instance ID and its transcript file.")
(defvar claude-code-ide-handover-tests--start-fails nil
  "Non-nil makes the stubbed start signal an error.")
(defvar claude-code-ide-handover-tests--root nil
  "Temporary folder of the current test.")

;;; Fixtures

(defun claude-code-ide-handover-tests--state-function (instance _now)
  "Return the test state of INSTANCE."
  (cdr (assoc (claude-code-ide-instance-id instance) claude-code-ide-handover-tests--states)))

(defun claude-code-ide-handover-tests--set-state (id state &optional reason)
  "Make the test state of ID STATE with REASON."
  (setf (alist-get id claude-code-ide-handover-tests--states nil nil #'equal)
        (claude-code-ide-instance-make-state state reason (float-time))))

(defun claude-code-ide-handover-tests--provider (name)
  "Return a stub provider NAME."
  (claude-code-ide-provider-create
   :name name
   :display-name (format "Stub %s" name)
   :buffer-name-prefix (format "cci-%s" name)
   :detect (lambda (&rest _) (list :available t :program "true" :version 'unknown))
   :launch (lambda (&rest _) (list :command "true"))
   :fork (lambda (&rest _) (list :command "true"))
   :submit-prompt (lambda (instance text)
                    (push (list (claude-code-ide-instance-id instance) text)
                          claude-code-ide-handover-tests--sent)
                    t)
   :stop (lambda (_instance) t)
   :native-id (lambda (instance)
                (claude-code-ide-or-unknown
                 (claude-code-ide-known-or-nil (claude-code-ide-instance-native-id instance))))
   :transcript (lambda (instance what)
                 (if (eq what 'file)
                     (claude-code-ide-or-unknown
                      (cdr (assoc (claude-code-ide-instance-id instance)
                                  claude-code-ide-handover-tests--transcripts)))
                   'unknown))))

(defun claude-code-ide-handover-tests--git (dir &rest args)
  "Run git with ARGS in DIR, without the user's Git configuration."
  (let ((default-directory dir)
        (process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1"
                                       "GIT_AUTHOR_NAME=cci-test" "GIT_AUTHOR_EMAIL=cci-test@example.invalid"
                                       "GIT_COMMITTER_NAME=cci-test"
                                       "GIT_COMMITTER_EMAIL=cci-test@example.invalid")
                                     process-environment)))
    (apply #'call-process "git" nil nil nil args)))

(defun claude-code-ide-handover-tests--registry-add (key provider directory &rest overrides)
  "Add an open registry entry KEY of PROVIDER in DIRECTORY with OVERRIDES."
  (claude-code-ide-session-registry--submit
   "test"
   (claude-code-ide-session-registry--change-started
    (apply #'claude-code-ide-session-registry-entry-create
           (append overrides
                   (list :key key :provider provider :session-id (concat key "-native")
                         :project-dir directory :worktree directory :state 'open
                         :started-at "2026-11-18T10:00:00Z" :host (system-name)
                         :emacs-pid (emacs-pid) :generation 1))))))

(defun claude-code-ide-handover-tests--add (id provider directory &optional state reason native-id)
  "Register a running stub instance ID of PROVIDER in DIRECTORY.
The instance gets a registry entry too.  STATE and REASON give its
state, NATIVE-ID its native ID.  Return the descriptor."
  (let ((buffer (generate-new-buffer (format "*cci-test-handover-%s*" id))))
    (push buffer claude-code-ide-handover-tests--buffers)
    (claude-code-ide-handover-tests--set-state id (or state 'idle) reason)
    (unless (claude-code-ide-session-registry-entry-of id)
      (claude-code-ide-handover-tests--registry-add id provider directory))
    (claude-code-ide-instance-register
     (claude-code-ide-instance-create
      :id id :provider provider :display-name id
      :native-id (or native-id (concat id "-native"))
      :project-root directory :worktree directory :buffer buffer
      :generation (claude-code-ide-instance-candidate-generation id)))))

(defun claude-code-ide-handover-tests--start (_continue _resume spec)
  "Stub of `claude-code-ide--start-session': register the instance of SPEC."
  (when claude-code-ide-handover-tests--start-fails
    (error "cci-test start failed"))
  (push spec claude-code-ide-handover-tests--starts)
  (let* ((id (claude-code-ide-start-spec-instance-id spec))
         (dir (claude-code-ide-start-spec-directory spec))
         (provider (claude-code-ide-start-spec-provider spec)))
    (unless (claude-code-ide-session-registry-entry-of id)
      (claude-code-ide-handover-tests--registry-add id provider dir :session-id nil :state 'pending))
    (claude-code-ide-handover-tests--add
     id provider dir 'working 'starting
     ;; The stub CLI reports its ID only with the first prompt, as Codex
     (or (and (claude-code-ide-start-spec-fork spec) 'unknown)
         (claude-code-ide-start-spec-resume-id spec)
         'unknown))))

(defun claude-code-ide-handover-tests--run-timers (&optional limit keep)
  "Run the queued timer functions, also those that they queue, up to LIMIT.
The timers of the function KEEP stay in the queue, unrun."
  (let ((count 0) (kept nil))
    (while (and claude-code-ide-handover-tests--timers (< count (or limit 200)))
      (let ((item (pop claude-code-ide-handover-tests--timers)))
        (setq count (1+ count))
        (if (and keep (eq (car item) keep))
            (push item kept)
          (apply (car item) (cdr item)))))
    (setq claude-code-ide-handover-tests--timers
          (append (nreverse kept) claude-code-ide-handover-tests--timers))
    count))

(defun claude-code-ide-handover-tests--event (id event &optional data)
  "Dispatch the common EVENT of the current launch of ID with DATA."
  (claude-code-ide-dispatch-event
   (claude-code-ide-make-event id (claude-code-ide-instance-current-generation id)
                               event "cci-test" data)))

(defun claude-code-ide-handover-tests--record (source-id)
  "Return the handover alist of the registry entry SOURCE-ID."
  (claude-code-ide-session-registry-entry-handover
   (claude-code-ide-session-registry-entry-of source-id)))

(defmacro claude-code-ide-handover-tests--with (&rest body)
  "Run BODY with a temporary registry, inbox and Git worktree, and stubs.
BODY can use `worktree', the folder of a Git repository."
  (declare (indent 0))
  `(let* ((root (make-temp-file "cci-test-handover-" t))
          (worktree (file-name-as-directory (expand-file-name "proj" root)))
          (claude-code-ide-state-file (expand-file-name "state.json" root))
          (claude-code-ide-session-registry-report-directory (expand-file-name "report" root))
          (claude-code-ide-session-registry-mode t)
          (claude-code-ide-session-registry--queue nil)
          (claude-code-ide-session-registry--draining nil)
          (claude-code-ide-session-registry--retry-timer nil)
          (claude-code-ide-session-registry--loaded-from-backup nil)
          (claude-code-ide-control-inbox-directory (expand-file-name "inbox" root))
          (claude-code-ide-control-retry-interval nil)
          (claude-code-ide-control--timer nil)
          (claude-code-ide-control--scheduled nil)
          (claude-code-ide-control--index (make-hash-table :test 'equal))
          (claude-code-ide-control--done-keys (make-hash-table :test 'equal))
          (claude-code-ide-control--warned-providers nil)
          (claude-code-ide-control-delivered-functions nil)
          (claude-code-ide-control--held nil)
          (claude-code-ide-instance--all nil)
          (claude-code-ide-instance--generations (make-hash-table :test 'equal))
          ;; No MCP session of another test counts as a live session
          (claude-code-ide-mcp--sessions (make-hash-table :test 'equal))
          (claude-code-ide-instance-state-functions
           (list #'claude-code-ide-handover-tests--state-function))
          (claude-code-ide-event-functions (list #'claude-code-ide-handover--on-event
                                                 #'claude-code-ide-control--on-event))
          (claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry))
          (claude-code-ide-handover--runs (make-hash-table :test 'equal))
          (claude-code-ide-handover--batches (make-hash-table :test 'equal))
          (claude-code-ide-handover--allowed nil)
          (claude-code-ide-handover-session-server-detection nil)
          (claude-code-ide-handover-stray-wait 0)
          ;; Longer than any test; the tests of the limit bind it to 0
          (claude-code-ide-handover-ack-wait 600)
          ;; No continue prompt after the commit, as before the option;
          ;; the tests of the continue prompt bind it or give :continue
          (claude-code-ide-handover-continue 'never)
          (claude-code-ide-handover-tests--states nil)
          (claude-code-ide-handover-tests--timers nil)
          (claude-code-ide-handover-tests--starts nil)
          (claude-code-ide-handover-tests--stops nil)
          (claude-code-ide-handover-tests--stop-result '(:status stopped))
          (claude-code-ide-handover-tests--scan-strays nil)
          (claude-code-ide-handover-tests--scans 0)
          (claude-code-ide-handover-tests--sent nil)
          (claude-code-ide-handover-tests--saved nil)
          (claude-code-ide-handover-tests--buffers nil)
          (claude-code-ide-handover-tests--transcripts nil)
          (claude-code-ide-handover-tests--start-fails nil)
          (claude-code-ide-handover-tests--root root))
     (make-directory worktree t)
     (claude-code-ide-handover-tests--git worktree "init" "-q")
     (claude-code-ide-register-provider (claude-code-ide-handover-tests--provider 'cci-test-a))
     (claude-code-ide-register-provider (claude-code-ide-handover-tests--provider 'cci-test-b))
     (unwind-protect
         (cl-letf (((symbol-function 'run-at-time)
                    (lambda (_time _repeat fn &rest args)
                      (setq claude-code-ide-handover-tests--timers
                            (append claude-code-ide-handover-tests--timers (list (cons fn args))))
                      nil))
                   ((symbol-function 'claude-code-ide--start-session)
                    #'claude-code-ide-handover-tests--start)
                   ((symbol-function 'claude-code-ide-process-stop-later)
                    (lambda (instance &rest args)
                      (push (claude-code-ide-instance-id instance)
                            claude-code-ide-handover-tests--stops)
                      ;; The CLI ends
                      (claude-code-ide-instance-unregister (claude-code-ide-instance-id instance))
                      (funcall (plist-get args :callback)
                               claude-code-ide-handover-tests--stop-result)))
                   ((symbol-function 'claude-code-ide-process-worktree-strays)
                    (lambda (&rest _)
                      (cl-incf claude-code-ide-handover-tests--scans)
                      claude-code-ide-handover-tests--scan-strays)))
           (advice-add 'claude-code-ide-session-registry-save-handover :before
                       #'claude-code-ide-handover-tests--note-save)
           (unwind-protect
               (progn ,@body)
             (advice-remove 'claude-code-ide-session-registry-save-handover
                            #'claude-code-ide-handover-tests--note-save)))
       (mapc #'kill-buffer (cl-remove-if-not #'buffer-live-p claude-code-ide-handover-tests--buffers))
       (delete-directory root t))))

(defun claude-code-ide-handover-tests--worktree ()
  "Return the Git worktree of the current test."
  (file-name-as-directory (expand-file-name "proj" claude-code-ide-handover-tests--root)))

(defun claude-code-ide-handover-tests--other (name)
  "Return a new Git worktree NAME in the folder of the current test."
  (let ((dir (file-name-as-directory (expand-file-name name claude-code-ide-handover-tests--root))))
    (make-directory dir t)
    (claude-code-ide-handover-tests--git dir "init" "-q")
    dir))

(defun claude-code-ide-handover-tests--note-save (_key handover &rest _)
  "Record the stage of each save of HANDOVER, once for each stage."
  (let ((stage (alist-get 'stage handover)))
    (unless (equal stage (car (last claude-code-ide-handover-tests--saved)))
      (setq claude-code-ide-handover-tests--saved
            (append claude-code-ide-handover-tests--saved (list stage))))))

(defun claude-code-ide-handover-tests--deliver (run-result)
  "Send the events of the target of RUN-RESULT: session start, then the document."
  (let* ((status (claude-code-ide-handover-status (plist-get run-result :handover-id)))
         (target (plist-get status :target-id))
         (spec (car claude-code-ide-handover-tests--starts)))
    (claude-code-ide-handover-tests--event target 'session-start
                                           '((session_id . "cci-test-target-native")))
    (claude-code-ide-handover-tests--event
     target 'prompt-submit (list (cons 'prompt (claude-code-ide-start-spec-prompt spec))))
    (claude-code-ide-handover-tests--run-timers)
    target))

;;; The stages

(ert-deftest claude-code-ide-test-handover-stages-in-order ()
  "A handover saves each stage before its step, and commits the target."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((stage-at-stop nil)
           (stage-at-start nil)
           (result (cl-letf* ((stop (symbol-function 'claude-code-ide-process-stop-later))
                              (start (symbol-function 'claude-code-ide--start-session))
                              ((symbol-function 'claude-code-ide-process-stop-later)
                               (lambda (&rest args)
                                 (setq stage-at-stop (alist-get 'stage (claude-code-ide-handover-tests--record
                                                                        "cci-test-src")))
                                 (apply stop args)))
                              ((symbol-function 'claude-code-ide--start-session)
                               (lambda (&rest args)
                                 (let ((record (claude-code-ide-handover-tests--record "cci-test-src")))
                                   (setq stage-at-start (cons (alist-get 'stage record)
                                                              (alist-get 'target_instance_id record))))
                                 (apply start args))))
                     (prog1 (claude-code-ide-handover-session
                             "cci-test-src" 'cci-test-b :context "cci-test-context" :request-id "r1")
                       (claude-code-ide-handover-tests--run-timers)))))
      (should (eq (plist-get result :status) 'running))
      (should (eq (plist-get result :stage) 'requested))
      ;; Saved before the step
      (should (equal stage-at-stop "source-stopped"))
      (should (equal (car stage-at-start) "target-started"))
      (should (stringp (cdr stage-at-start)))
      ;; The target got the document as its first prompt
      (let* ((spec (car claude-code-ide-handover-tests--starts))
             (prompt (claude-code-ide-start-spec-prompt spec))
             (id (plist-get result :handover-id)))
        (should (eq (claude-code-ide-start-spec-provider spec) 'cci-test-b))
        (should (equal (claude-code-ide-start-spec-instance-id spec) (cdr stage-at-start)))
        (should (equal (file-name-as-directory (claude-code-ide-start-spec-directory spec)) worktree))
        (should-not (claude-code-ide-start-spec-fork spec))
        ;; A coordinator handover never asks the user at the target start
        (should-not (claude-code-ide-start-spec-interactive spec))
        (should (equal (claude-code-ide-transcript-document-id prompt) id))
        ;; The document file and its hash; the prompt only points to it
        (let* ((status (claude-code-ide-handover-status id))
               (document (plist-get status :document))
               (text (with-temp-buffer (insert-file-contents document) (buffer-string))))
          (should (eq (plist-get status :stage) 'target-started))
          (should (equal document (expand-file-name (concat ".handover/" id ".md") worktree)))
          (should (equal (plist-get status :document-hash) (secure-hash 'sha256 text)))
          (should (string-match-p "cci-test-context" text))
          (should-not (string-match-p "cci-test-context" prompt))
          (should (string-match-p (regexp-quote document) prompt))
          (should (< (length prompt) 1000))
          (should (equal (claude-code-ide-transcript-document-summary-file prompt)
                         (expand-file-name (concat ".handover/" id "-state.md") worktree))))
        ;; .handover/ is excluded from Git
        (with-temp-buffer
          (insert-file-contents (expand-file-name ".git/info/exclude" worktree))
          (should (member ".handover/" (split-string (buffer-string) "\n"))))
        ;; The events identify the target and deliver the document
        (let ((target (claude-code-ide-handover-tests--deliver result))
              (status (claude-code-ide-handover-status id)))
          (should (eq (plist-get status :status) 'committed))
          (should (eq (plist-get status :stage) 'committed))
          (should (equal claude-code-ide-handover-tests--saved
                         '("requested" "quiescing" "source-stopped" "document-written"
                           "target-started" "target-identified" "delivered" "committed")))
          (should (equal claude-code-ide-handover-tests--stops '("cci-test-src")))
          ;; The chain of the target: the source leg, then its own leg
          (let ((legs (claude-code-ide-session-registry-entry-legs
                       (claude-code-ide-session-registry-entry-of target))))
            (should (= (length legs) 2))
            (should (equal (plist-get (nth 0 legs) :instance-id) "cci-test-src"))
            (should (equal (plist-get (nth 1 legs) :instance-id) target))
            (should (equal (plist-get (nth 1 legs) :handover-id) id))
            (should (equal (plist-get (nth 1 legs) :document-hash)
                           (plist-get (claude-code-ide-handover-status id) :document-hash)))
            (should-not (plist-get (nth 1 legs) :pending)))
          (should (equal (claude-code-ide-session-registry-chain-current "cci-test-src") target))
          ;; A duplicate request returns the current result
          (let ((again (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :request-id "r1")))
            (should (plist-get again :duplicate))
            (should (eq (plist-get again :status) 'committed))))))))

(ert-deftest claude-code-ide-test-handover-quiescing ()
  "The handover waits for an idle source, interrupts only on request, and gives up."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (let ((escapes 0))
      (cl-letf (((symbol-function 'claude-code-ide--terminal-send-escape)
                 (lambda () (cl-incf escapes))))
        ;; Without :interrupt it waits, and sends nothing
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)
                             :handover-id)))
          (claude-code-ide-handover-tests--run-timers 5)
          (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'quiescing))
          (should-not claude-code-ide-handover-tests--stops)
          (should (= escapes 0))
          ;; Idle: the stop runs
          (claude-code-ide-handover-tests--set-state "cci-test-src" 'idle)
          (claude-code-ide-handover-tests--run-timers)
          (should (equal claude-code-ide-handover-tests--stops '("cci-test-src")))))
      ;; With :interrupt: one escape, then it waits
      (claude-code-ide-handover-tests--add "cci-test-src2" 'cci-test-a
                                           (claude-code-ide-handover-tests--other "proj2") 'working)
      (cl-letf (((symbol-function 'claude-code-ide--terminal-send-escape)
                 (lambda () (cl-incf escapes))))
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src2" 'cci-test-b
                                                               :interrupt t)
                             :handover-id)))
          (claude-code-ide-handover-tests--run-timers 5)
          (should (= escapes 1))
          (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'quiescing))
          ;; The time limit cancels it, and the source stays
          (setf (claude-code-ide-handover--run-deadline (gethash id claude-code-ide-handover--runs))
                (- (float-time) 1))
          (claude-code-ide-handover-tests--run-timers 5)
          (let ((status (claude-code-ide-handover-status id)))
            (should (eq (plist-get status :status) 'cancelled))
            (should (eq (plist-get status :reason) 'not-idle)))
          (should (claude-code-ide-instance-by-id "cci-test-src2")))))))

(ert-deftest claude-code-ide-test-handover-busy-and-force ()
  "Subagents or background tasks refuse the handover, unless it is forced."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree
                                         'waiting-for-task 'subagent)
    (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)))
      (should (eq (plist-get result :status) 'error))
      (should (eq (plist-get result :reason) 'busy)))
    (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :force t)))
      (should (eq (plist-get result :status) 'running))
      (claude-code-ide-handover-tests--run-timers)
      (should (equal claude-code-ide-handover-tests--stops '("cci-test-src"))))
    ;; A task that starts while the handover waits cancels it
    (claude-code-ide-handover-tests--add "cci-test-src2" 'cci-test-a
                                         (claude-code-ide-handover-tests--other "proj2") 'working)
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src2" 'cci-test-b)
                         :handover-id)))
      (claude-code-ide-handover-tests--run-timers 3)
      (claude-code-ide-handover-tests--set-state "cci-test-src2" 'waiting-for-task 'background-task)
      (claude-code-ide-handover-tests--run-timers 3)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
      (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'busy)))))

(ert-deftest claude-code-ide-test-handover-refusals ()
  "A handover that cannot start returns an error result and saves nothing."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (cl-flet ((reason (&rest args)
                (let ((result (apply #'claude-code-ide-handover-session args)))
                  (should (eq (plist-get result :status) 'error))
                  (plist-get result :reason))))
      (should (eq (reason "cci-test-none" 'cci-test-b) 'not-running))
      (should (eq (reason "cci-test-src" 'cci-test-none) 'unknown-provider))
      (should (eq (reason "cci-test-src" 'cci-test-b :method 'import) 'invalid-method))
      (should (eq (reason "cci-test-src" 'cci-test-b :method 'fork) 'no-earlier-conversation))
      (let ((claude-code-ide-session-registry-mode nil))
        (should (eq (reason "cci-test-src" 'cci-test-b) 'registry-off)))
      (setf (claude-code-ide-instance-native-id (claude-code-ide-instance-by-id "cci-test-src"))
            'unknown)
      (should (eq (reason "cci-test-src" 'cci-test-b) 'no-conversation))
      (setf (claude-code-ide-instance-native-id (claude-code-ide-instance-by-id "cci-test-src"))
            "cci-test-src-native")
      (should-not claude-code-ide-handover-tests--saved)
      ;; A second handover in the same worktree
      (claude-code-ide-handover-tests--set-state "cci-test-src" 'working)
      (should (eq (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :status)
                  'running))
      (claude-code-ide-handover-tests--add "cci-test-src2" 'cci-test-a worktree 'idle)
      (should (eq (reason "cci-test-src2" 'cci-test-b) 'handover-running)))))

(ert-deftest claude-code-ide-test-handover-fork ()
  "A fork starts from the latest conversation of the target provider in the chain."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-session-registry-save-chain
     "cci-test-src"
     (list (list :provider 'cci-test-b :instance-id "cci-test-l1" :native-id "cci-test-b-old")
           (list :provider 'cci-test-a :instance-id "cci-test-l2" :native-id "cci-test-a-mid")
           (list :provider 'cci-test-b :instance-id "cci-test-l3" :native-id "cci-test-b-new")
           (list :provider 'cci-test-a :instance-id "cci-test-src" :native-id "cci-test-src-native")))
    (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :method 'fork)
    (claude-code-ide-handover-tests--run-timers)
    (let ((spec (car claude-code-ide-handover-tests--starts)))
      (should (claude-code-ide-start-spec-fork spec))
      (should (equal (claude-code-ide-start-spec-resume-id spec) "cci-test-b-new"))
      (should (claude-code-ide-transcript-document-id (claude-code-ide-start-spec-prompt spec))))))

(ert-deftest claude-code-ide-test-handover-target-replaces-source-copy ()
  "The start of the target names its source, whose copy it replaces in its window."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((replaced 'none))
      (cl-letf* ((start (symbol-function 'claude-code-ide--start-session))
                 ((symbol-function 'claude-code-ide--start-session)
                  (lambda (&rest args)
                    (setq replaced claude-code-ide--replace-copy-of)
                    (apply start args))))
        (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)
        (claude-code-ide-handover-tests--run-timers))
      (should (equal replaced "cci-test-src"))
      (should-not claude-code-ide--replace-copy-of))))

;;; Strays

(ert-deftest claude-code-ide-test-handover-strays-coordinator ()
  "Strays give a coordinator `needs-user'; processes of Emacs do not count."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    ;; A process of Emacs (a language server) is not a writer
    (setq claude-code-ide-handover-tests--stop-result
          '(:status strays :strays ((:pid 4242 :command "cci-test-lsp" :cwd "/x" :reason worktree
                                          :emacs-process t))))
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
      (claude-code-ide-handover-tests--run-timers)
      (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started)))
    ;; A real stray
    (claude-code-ide-handover-tests--add "cci-test-src2" 'cci-test-a
                                         (claude-code-ide-handover-tests--other "proj2") 'idle)
    (setq claude-code-ide-handover-tests--stop-result
          '(:status strays :strays ((:pid 4343 :command "sleep 600" :cwd "/x/b" :reason worktree))))
    (let* ((messages nil)
           (id (cl-letf (((symbol-function 'message)
                          (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
                 (prog1 (plist-get (claude-code-ide-handover-session "cci-test-src2" 'cci-test-b)
                                   :handover-id)
                   (claude-code-ide-handover-tests--run-timers))))
           (status (claude-code-ide-handover-status id)))
      (should (eq (plist-get status :status) 'needs-user))
      (should (eq (plist-get status :reason) 'strays))
      (should (equal (mapcar (lambda (s) (plist-get s :pid)) (plist-get status :strays)) '(4343)))
      (should (cl-some (lambda (m) (string-match-p "needs you" m)) messages))
      ;; The registry holds it too
      (should (equal (alist-get 'status (claude-code-ide-handover-tests--record "cci-test-src2"))
                     "needs-user"))
      ;; Wait: the scan finds nothing now, and the handover goes on
      (claude-code-ide-handover-resolve id 'wait)
      (claude-code-ide-handover-tests--run-timers)
      (should (= claude-code-ide-handover-tests--scans 1))
      (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started))
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'running)))))

(ert-deftest claude-code-ide-test-handover-review-processes-stay ()
  "The processes of a review are no strays, and the stop and the scan leave them out."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((stop-args nil) (scan-args nil))
      (cl-letf* ((stop (symbol-function 'claude-code-ide-process-stop-later))
                 ((symbol-function 'claude-code-ide-process-stop-later)
                  (lambda (instance &rest args) (setq stop-args args) (apply stop instance args)))
                 ((symbol-function 'claude-code-ide-process-worktree-strays)
                  (lambda (&rest args) (setq scan-args args) nil))
                 ((symbol-function 'claude-code-ide-review-process-ids) (lambda () '(4747))))
        (setq claude-code-ide-handover-tests--stop-result
              '(:status strays :strays ((:pid 4747 :command "cci-test-review" :cwd "/x"
                                              :reason worktree))))
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)
                             :handover-id)))
          (claude-code-ide-handover-tests--run-timers)
          (should (equal (plist-get stop-args :exclude) '(4747)))
          (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started))
          ;; The scan of a recovery leaves them out too
          (claude-code-ide-handover--scan (gethash id claude-code-ide-handover--runs))
          (should (equal (cadr scan-args) '(4747))))))))

(ert-deftest claude-code-ide-test-handover-strays-interactive ()
  "An interactive handover asks about strays: end them, wait, or cancel."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (setq claude-code-ide-handover-tests--stop-result
          '(:status strays :strays ((:pid 4444 :command "node cci-test-server" :cwd "/x/proj"
                                          :reason worktree))))
    (let ((questions nil)
          (signals nil)
          (answer ?e))
      (cl-letf (((symbol-function 'read-multiple-choice)
                 (lambda (prompt choices &rest _)
                   (push (cons prompt (mapcar #'car choices)) questions)
                   (assq answer choices)))
                ((symbol-function 'signal-process)
                 (lambda (pid signal) (push (list pid signal) signals) 0))
                ((symbol-function 'claude-code-ide-handover--stray-alive-p) (lambda (_) t)))
        ;; End them: SIGTERM, then SIGKILL after the wait, then a new scan
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b
                                                               :interactive t)
                             :handover-id)))
          (claude-code-ide-handover-tests--run-timers)
          (should (= (length questions) 1))
          (should (string-match-p "4444" (car (car questions))))
          (should (string-match-p "node cci-test-server" (car (car questions))))
          (should (string-match-p "/x/proj" (car (car questions))))
          (should (equal (cdr (car questions)) '(?e ?w ?c)))
          (should (equal (reverse signals) '((4444 SIGTERM) (4444 SIGKILL))))
          (should (= claude-code-ide-handover-tests--scans 1))
          (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started))
          ;; The target start of a person's handover may ask, for the hook trust
          (should (claude-code-ide-start-spec-interactive (car claude-code-ide-handover-tests--starts))))
        ;; Cancel: the handover ends, and nothing starts
        (setq answer ?c questions nil claude-code-ide-handover-tests--starts nil)
        (claude-code-ide-handover-tests--add "cci-test-src2" 'cci-test-a
                                             (claude-code-ide-handover-tests--other "proj2") 'idle)
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src2" 'cci-test-b
                                                               :interactive t)
                             :handover-id)))
          (claude-code-ide-handover-tests--run-timers)
          (should (= (length questions) 1))
          (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
          (should-not claude-code-ide-handover-tests--starts))))))

(ert-deftest claude-code-ide-test-handover-source-survives ()
  "A source that survives SIGKILL, or a failed scan, needs a person."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (setq claude-code-ide-handover-tests--stop-result
          '(:status timeout :strays ((:pid 4545 :command "cci-test-cli" :cwd "/x" :reason cli))))
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
      (claude-code-ide-handover-tests--run-timers)
      (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'source-did-not-stop))
      (should-not claude-code-ide-handover-tests--starts)
      (claude-code-ide-handover-cancel id)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled)))
    (claude-code-ide-handover-tests--add "cci-test-src2" 'cci-test-a
                                         (claude-code-ide-handover-tests--other "proj2") 'idle)
    (setq claude-code-ide-handover-tests--stop-result '(:status error :reason "ps failed"))
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src2" 'cci-test-b) :handover-id)))
      (claude-code-ide-handover-tests--run-timers)
      (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'scan-failed))
      (should-error (claude-code-ide-handover-resolve id 'end) :type 'user-error)
      ;; Go on without the check
      (claude-code-ide-handover-resolve id 'go)
      (claude-code-ide-handover-tests--run-timers)
      (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started)))))

(ert-deftest claude-code-ide-test-handover-start-failure ()
  "A target that does not start needs a person; retry starts it again."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (setq claude-code-ide-handover-tests--start-fails t)
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
      (claude-code-ide-handover-tests--run-timers)
      (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'start-failed))
      (setq claude-code-ide-handover-tests--start-fails nil)
      (let ((target (plist-get (claude-code-ide-handover-status id) :target-id)))
        (claude-code-ide-handover-resolve id 'retry)
        (claude-code-ide-handover-tests--run-timers)
        ;; The same target ID, started one time
        (should (= (length claude-code-ide-handover-tests--starts) 1))
        (should (equal (claude-code-ide-start-spec-instance-id (car claude-code-ide-handover-tests--starts))
                       target))))))

;;; One writer for each worktree

(ert-deftest claude-code-ide-test-handover-two-writers ()
  "While a handover runs, a second start in its worktree is refused."
  (should (advice-member-p #'claude-code-ide-handover--guard-start 'claude-code-ide--start-session))
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (let* ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id))
           (started nil)
           (start (lambda (&rest _) (setq started t)))
           (spec (claude-code-ide-start-spec-create :directory worktree))
           (inside (claude-code-ide-start-spec-create
                    :directory (file-name-as-directory (expand-file-name "sub" worktree))))
           (other (claude-code-ide-start-spec-create :directory temporary-file-directory)))
      (make-directory (expand-file-name "sub" worktree) t)
      (should-error (claude-code-ide-handover--guard-start start nil nil spec) :type 'user-error)
      (should-error (claude-code-ide-handover--guard-start start nil nil inside) :type 'user-error)
      (should-not started)
      ;; Another folder starts
      (claude-code-ide-handover--guard-start start nil nil other)
      (should started)
      ;; The handover's own target starts
      (setq started nil)
      (let ((claude-code-ide-handover--allowed id))
        (claude-code-ide-handover--guard-start start nil nil spec))
      (should started)
      ;; A handover of a crashed Emacs, in the registry only, holds it too
      (clrhash claude-code-ide-handover--runs)
      (setq started nil)
      (should-error (claude-code-ide-handover--guard-start start nil nil spec) :type 'user-error)
      ;; After the end of the handover, starts work again
      (claude-code-ide-handover-cancel id)
      (claude-code-ide-handover--guard-start start nil nil spec)
      (should started)
      ;; Another instance in the worktree: refused without a key; with
      ;; :allow-others or :force, the handover runs
      (claude-code-ide-handover-tests--add "cci-test-two" 'cci-test-a worktree 'idle)
      (let ((refused (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)))
        (should (eq (plist-get refused :reason) 'other-instance))
        (should (string-match-p "cci-test-two" (plist-get refused :message))))
      (let ((allowed (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t)))
        (should (eq (plist-get allowed :status) 'running))
        (claude-code-ide-handover-cancel (plist-get allowed :handover-id)))
      (should (eq (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :force t)
                             :status)
                  'running)))))

;;; The inbox

(ert-deftest claude-code-ide-test-handover-inbox-moves ()
  "After the commit, the queued prompts of the source go to the target."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (should (eq (plist-get (claude-code-ide-control-submit "cci-test-src" "cci-test-one"
                                                           :request-id "q1")
                           :result)
                'queued))
    (should (eq (plist-get (claude-code-ide-control-submit "cci-test-src" "cci-test-review"
                                                           :request-id "review-7")
                           :result)
                'queued))
    (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :force t)))
      (claude-code-ide-handover-tests--set-state "cci-test-src" 'idle)
      (claude-code-ide-handover-tests--run-timers)
      (let ((target (claude-code-ide-handover-tests--deliver result)))
        (should (eq (plist-get (claude-code-ide-handover-status (plist-get result :handover-id))
                               :status)
                    'committed))
        ;; The target has them, with the same request IDs and order
        (should (equal (mapcar #'claude-code-ide-control--record-request-id
                               (claude-code-ide-control--pending-records target))
                       '("q1" "review-7")))
        (should (equal (claude-code-ide-control--record-text
                        (car (claude-code-ide-control--pending-records target)))
                       "cci-test-one"))
        ;; The source records are final
        (should-not (claude-code-ide-control--pending-records "cci-test-src"))
        (let ((old (claude-code-ide-control-request-status "cci-test-src" "q1")))
          (should (eq (plist-get old :result) 'rejected))
          (should (eq (plist-get old :reason) 'handed-over)))
        ;; A second move moves nothing
        (should-not (claude-code-ide-control-move-inbox "cci-test-src" target))
        (should (= (length (claude-code-ide-control--pending-records target)) 2))
        ;; The target takes them when it is idle
        (claude-code-ide-handover-tests--set-state target 'idle)
        (claude-code-ide-control-deliver-pending target)
        (should (equal (car claude-code-ide-handover-tests--sent) (list target "cci-test-one")))))))

;;; Recovery

(defun claude-code-ide-handover-tests--interrupted (stage &rest extra)
  "Run a handover of a new source up to STAGE, then forget it as a crash would.
EXTRA is a plist of :target-native to set the target's native ID,
:context for the context of the handover, and :continue, which goes to
the handover only when EXTRA has it.  Return the handover ID."
  (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a (claude-code-ide-handover-tests--worktree) 'idle)
  (let* ((id (plist-get (apply #'claude-code-ide-handover-session "cci-test-src" 'cci-test-b
                               :context (plist-get extra :context)
                               (when (plist-member extra :continue)
                                 (list :continue (plist-get extra :continue))))
                        :handover-id))
         (run (gethash id claude-code-ide-handover--runs)))
    (cl-letf (((symbol-function 'claude-code-ide-handover--step) #'ignore))
      (claude-code-ide-handover-tests--run-timers))
    ;; The run reaches STAGE with the values of that stage
    (setf (claude-code-ide-handover--run-source-leg run)
          (claude-code-ide-handover--source-leg (claude-code-ide-instance-by-id "cci-test-src")))
    (unless (claude-code-ide-handover--stage< stage 'document-written)
      (let ((claude-code-ide-handover--runs (make-hash-table :test 'equal)))
        (cl-letf (((symbol-function 'claude-code-ide-handover--enter)
                   (lambda (run stage) (setf (claude-code-ide-handover--run-stage run) stage) nil)))
          (claude-code-ide-handover--write-document run))))
    (unless (claude-code-ide-handover--stage< stage 'target-started)
      (setf (claude-code-ide-handover--run-target-id run) "cci-test-tgt")
      (claude-code-ide-handover-tests--registry-add
       "cci-test-tgt" 'cci-test-b (claude-code-ide-handover-tests--worktree) :generation 3
       :session-id (plist-get extra :target-native)))
    (when (plist-get extra :target-native)
      (setf (claude-code-ide-handover--run-target-native-id run) (plist-get extra :target-native)))
    (setf (claude-code-ide-handover--run-stage run) stage)
    (claude-code-ide-handover--save run)
    ;; The crash: the CLIs and this Emacs's memory are gone
    (setq claude-code-ide-instance--all nil
          claude-code-ide-handover-tests--starts nil
          claude-code-ide-handover-tests--saved nil)
    (clrhash claude-code-ide-handover--runs)
    id))

(ert-deftest claude-code-ide-test-handover-recovery-before-stop ()
  "Recovery cancels a handover before source-stopped; the source stays current."
  (dolist (stage '(requested quiescing))
    (claude-code-ide-handover-tests--with
      (let ((id (claude-code-ide-handover-tests--interrupted stage)))
        (claude-code-ide-handover-recover)
        (claude-code-ide-handover-tests--run-timers)
        (let ((status (claude-code-ide-handover-status id)))
          (should (eq (plist-get status :status) 'cancelled))
          (should (eq (plist-get status :reason) 'recovered-before-stop)))
        (should-not claude-code-ide-handover-tests--starts)
        ;; The source is restorable again; it is not held
        (should-not (claude-code-ide-session-registry--handover-blocks-p
                     (claude-code-ide-session-registry-entry-of "cci-test-src")))
        ;; EARLY-ONLY cancels early stages too
        (should-not (claude-code-ide-handover-recover t))))))

(ert-deftest claude-code-ide-test-handover-recovery-after-stop ()
  "Recovery between source-stopped and committed starts or resumes the target only."
  ;; source-stopped: scan first, then the document and a new target
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'source-stopped)))
      ;; EARLY-ONLY leaves it alone
      (should-not (claude-code-ide-handover-recover t))
      (should-not claude-code-ide-handover-tests--starts)
      (claude-code-ide-handover-recover)
      (should (= claude-code-ide-handover-tests--scans 1))
      (should (= (length claude-code-ide-handover-tests--starts) 1))
      (let ((spec (car claude-code-ide-handover-tests--starts)))
        (should (eq (claude-code-ide-start-spec-provider spec) 'cci-test-b))
        (should (equal (claude-code-ide-transcript-document-id (claude-code-ide-start-spec-prompt spec))
                       id)))))
  ;; source-stopped with strays: a person decides first
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'source-stopped)))
      (setq claude-code-ide-handover-tests--scan-strays
            '((:pid 4646 :command "sleep 900" :cwd "/x" :reason worktree)))
      (claude-code-ide-handover-recover)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'needs-user))
      (should-not claude-code-ide-handover-tests--starts)))
  ;; document-written: the document is written again, then the target starts
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'document-written)))
      (claude-code-ide-handover-recover)
      (should (= (length claude-code-ide-handover-tests--starts) 1))
      (should (equal (claude-code-ide-transcript-document-id
                      (claude-code-ide-start-spec-prompt (car claude-code-ide-handover-tests--starts)))
                     id))))
  ;; target-started, not identified: the same target again, with the same document
  (claude-code-ide-handover-tests--with
    (let* ((id (claude-code-ide-handover-tests--interrupted 'target-started))
           (document (plist-get (claude-code-ide-handover-status id) :document)))
      (claude-code-ide-handover-recover)
      (should (= (length claude-code-ide-handover-tests--starts) 1))
      (let ((spec (car claude-code-ide-handover-tests--starts)))
        (should (equal (claude-code-ide-start-spec-instance-id spec) "cci-test-tgt"))
        ;; An existing instance ID names its generation (R.md)
        (should (eql (claude-code-ide-start-spec-last-generation spec) 3))
        (should-not (claude-code-ide-start-spec-resume-id spec))
        (should (string-match-p (regexp-quote document) (claude-code-ide-start-spec-prompt spec)))
        (should (equal (plist-get (claude-code-ide-handover-status id) :document) document)))))
  ;; target-identified with a saved conversation: resume the target,
  ;; then give it the document.  (A target whose conversation was never
  ;; saved starts fresh: see -recovery-unsaved-target.)
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'target-identified
                                                           :target-native "cci-test-tgt-native")))
      (claude-code-ide-handover-tests--saved-transcript "cci-test-tgt" "cci-test-tgt-native" worktree)
      (claude-code-ide-handover-recover)
      (should (= (length claude-code-ide-handover-tests--starts) 1))
      ;; The transcript has no document, so the resume gets the pointer
      ;; as its first prompt; nothing is typed, and the inbox stays empty
      (let ((spec (car claude-code-ide-handover-tests--starts)))
        (should (equal (claude-code-ide-start-spec-instance-id spec) "cci-test-tgt"))
        (should (equal (claude-code-ide-start-spec-resume-id spec) "cci-test-tgt-native"))
        (should (equal (claude-code-ide-transcript-document-id (claude-code-ide-start-spec-prompt spec))
                       id))
        (should-not (claude-code-ide-control--pending-records "cci-test-tgt"))
        ;; Its acknowledgement commits the handover
        (claude-code-ide-handover-tests--event
         "cci-test-tgt" 'prompt-submit (list (cons 'prompt (claude-code-ide-start-spec-prompt spec))))
        (claude-code-ide-handover-tests--run-timers 3)
        (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed)))))
  ;; delivered: resume and commit
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'delivered
                                                           :target-native "cci-test-tgt-native")))
      (claude-code-ide-handover-recover)
      (should (= (length claude-code-ide-handover-tests--starts) 1))
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
      (should (equal (claude-code-ide-session-registry-chain-current "cci-test-src") "cci-test-tgt"))))
  ;; In no case does the source start again
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--interrupted 'target-identified :target-native "cci-test-tgt-native")
    (claude-code-ide-handover-recover)
    (should-not (cl-find "cci-test-src" claude-code-ide-handover-tests--starts
                         :key #'claude-code-ide-start-spec-instance-id :test #'equal))))

(defun claude-code-ide-handover-tests--saved-transcript (key native directory)
  "Save a transcript of the conversation NATIVE of the entry KEY in DIRECTORY.
It has one earlier user turn and no handover document.  The registry
gets its path from a SessionStart report, as for a real CLI.  Return
the file."
  (let ((file (expand-file-name (concat key "-saved.jsonl") directory)))
    (with-temp-file file
      (insert (json-encode `((type . "user") (sessionId . ,native)
                             (message . ((role . "user") (content . "cci-test earlier turn"))))))
      (insert "\n"))
    (claude-code-ide-session-registry--submit
     "report" (claude-code-ide-session-registry--change-reported key native file nil 3))
    file))

(ert-deftest claude-code-ide-test-handover-recovery-unsaved-target ()
  "Recovery does not resume a target whose conversation was never saved.
`claude --resume ID' of such an ID exits with \"No conversation found
with session ID\", so the recovery must start the target fresh, with
the same instance ID and the same document."
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'target-identified
                                                           :target-native "cci-test-tgt-native")))
      (should-not (claude-code-ide-session-registry-entry-transcript-path
                   (claude-code-ide-session-registry-entry-of "cci-test-tgt")))
      (claude-code-ide-handover-recover)
      (should (= (length claude-code-ide-handover-tests--starts) 1))
      (let ((spec (car claude-code-ide-handover-tests--starts)))
        (should (equal (claude-code-ide-start-spec-instance-id spec) "cci-test-tgt"))
        (should-not (claude-code-ide-start-spec-resume-id spec))
        (should (equal (claude-code-ide-transcript-document-id (claude-code-ide-start-spec-prompt spec))
                       id))))))

(ert-deftest claude-code-ide-test-handover-recovery-unsaved-target-commits ()
  "The fresh start of an unsaved target goes on to the commit, with no person."
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'target-identified
                                                           :target-native "cci-test-tgt-native")))
      (claude-code-ide-handover-recover)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'running))
      (let ((spec (car claude-code-ide-handover-tests--starts)))
        ;; The fresh target reports its ID and gets the document
        (setf (claude-code-ide-instance-native-id (claude-code-ide-instance-by-id "cci-test-tgt"))
              "cci-test-tgt-native")
        (claude-code-ide-handover-tests--event
         "cci-test-tgt" 'prompt-submit (list (cons 'prompt (claude-code-ide-start-spec-prompt spec))))
        (claude-code-ide-handover-tests--run-timers 3)
        (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
        (should (equal (claude-code-ide-session-registry-chain-current "cci-test-src") "cci-test-tgt"))
        (should-not (cl-find "cci-test-src" claude-code-ide-handover-tests--starts
                             :key #'claude-code-ide-start-spec-instance-id :test #'equal))))))

(ert-deftest claude-code-ide-test-handover-recovery-unsaved-target-ask ()
  "With the option `ask', the recovery keeps the old order.
It resumes the unsaved target; that resume fails, and then a person
decides, with the reason target-exited.  Retry starts the target again."
  (claude-code-ide-handover-tests--with
    (let* ((claude-code-ide-handover-unsaved-target 'ask)
           (id (claude-code-ide-handover-tests--interrupted 'target-identified
                                                            :target-native "cci-test-tgt-native")))
      (claude-code-ide-handover-recover)
      ;; The resume, as before the option
      (should (= (length claude-code-ide-handover-tests--starts) 1))
      (should (equal (claude-code-ide-start-spec-resume-id (car claude-code-ide-handover-tests--starts))
                     "cci-test-tgt-native"))
      ;; The resume fails: the CLI ends at once ("No conversation found")
      (claude-code-ide-instance-unregister "cci-test-tgt")
      (claude-code-ide-handover-tests--run-timers)
      (let ((status (claude-code-ide-handover-status id)))
        (should (eq (plist-get status :status) 'needs-user))
        (should (eq (plist-get status :reason) 'target-exited)))
      (claude-code-ide-handover-resolve id 'retry)
      (should (= (length claude-code-ide-handover-tests--starts) 2))
      (let ((spec (car claude-code-ide-handover-tests--starts)))
        (should (equal (claude-code-ide-start-spec-instance-id spec) "cci-test-tgt"))
        (should-not (claude-code-ide-start-spec-resume-id spec))
        (should (equal (claude-code-ide-transcript-document-id (claude-code-ide-start-spec-prompt spec))
                       id))))))

(ert-deftest claude-code-ide-test-handover-recovery-saved-during-stray-wait ()
  "The decision between a fresh start and a resume comes after the clean scan.
The old target CLI survived the crash, so the scan finds a writer, and
the recovery waits.  Then the CLI saves its transcript and ends.  The
recovery must now resume the target, for Claude Code and for Codex,
with its native ID: a fresh start would reuse a saved session ID (CC),
or lose the saved conversation (Codex)."
  (dolist (provider '(claude codex))
    (claude-code-ide-handover-tests--with
      (let* ((config (expand-file-name "claude" root))
             (codex-home (expand-file-name "codex" root))
             (process-environment (append (list (concat "CLAUDE_CONFIG_DIR=" config)
                                                (concat "CODEX_HOME=" codex-home))
                                          process-environment))
             (native (if (eq provider 'claude)
                         "cc1e5000-0000-4000-8000-0000000000cc"
                       "cc1e5000-0000-4000-8000-0000000000cd"))
             (id (claude-code-ide-handover-tests--interrupted 'target-identified :target-native native))
             (run (cl-find id (claude-code-ide-handover--registry-runs)
                           :key #'claude-code-ide-handover--run-id :test #'equal)))
        ;; The target is of PROVIDER
        (setf (claude-code-ide-handover--run-target-provider run) provider)
        (claude-code-ide-handover-tests--registry-add
         "cci-test-tgt" provider (claude-code-ide-handover-tests--worktree)
         :generation 3 :session-id native)
        ;; The scan finds the surviving CLI
        (setq claude-code-ide-handover-tests--scan-strays
              '((:pid 4646 :command "the old target CLI" :cwd "/x" :reason worktree)))
        (claude-code-ide-handover--recover-run run nil)
        (let ((status (claude-code-ide-handover-status id)))
          (should (eq (plist-get status :status) 'needs-user))
          (should (eq (plist-get status :reason) 'strays))
          ;; The decision waits: the stage and the native ID stay
          (should (eq (plist-get status :stage) 'target-identified)))
        (should (equal (claude-code-ide-handover--run-target-native-id run) native))
        (should-not claude-code-ide-handover-tests--starts)
        ;; While the recovery waits, the CLI saves its transcript and ends
        (let ((file (if (eq provider 'claude)
                        (expand-file-name
                         (concat native ".jsonl")
                         (expand-file-name (claude-code-ide-session-registry--project-slug
                                            (claude-code-ide-handover-tests--worktree))
                                           (expand-file-name "projects" config)))
                      (expand-file-name (concat "sessions/2026/11/20/rollout-2026-11-20T10-00-00-"
                                                native ".jsonl")
                                        codex-home))))
          (make-directory (file-name-directory file) t)
          (write-region "{}\n" nil file nil 'silent))
        (setq claude-code-ide-handover-tests--scan-strays nil)
        (claude-code-ide-handover-resolve id 'wait)
        (claude-code-ide-handover-tests--run-timers 3)
        ;; The clean scan leads to a resume of the saved conversation
        (should (= (length claude-code-ide-handover-tests--starts) 1))
        (let ((spec (car claude-code-ide-handover-tests--starts)))
          (should (equal (claude-code-ide-start-spec-instance-id spec) "cci-test-tgt"))
          (should (equal (claude-code-ide-start-spec-resume-id spec) native))
          ;; A resume, not a fresh start with --session-id
          (should-not (string-match-p "--session-id"
                                      (or (claude-code-ide-start-spec-extra-flags spec) ""))))))))

(ert-deftest claude-code-ide-test-handover-recovery-unsaved-after-stray-wait ()
  "An unsaved target that stays unsaved during the stray wait starts fresh.
The check runs after the clean scan; the fresh start keeps the same
instance ID and document."
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'target-identified
                                                           :target-native "cci-test-tgt-native")))
      (setq claude-code-ide-handover-tests--scan-strays
            '((:pid 4646 :command "sleep 900" :cwd "/x" :reason worktree)))
      (claude-code-ide-handover-recover)
      (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'strays))
      (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-identified))
      (setq claude-code-ide-handover-tests--scan-strays nil)
      (claude-code-ide-handover-resolve id 'wait)
      (claude-code-ide-handover-tests--run-timers 3)
      (should (= (length claude-code-ide-handover-tests--starts) 1))
      (let ((spec (car claude-code-ide-handover-tests--starts)))
        (should (equal (claude-code-ide-start-spec-instance-id spec) "cci-test-tgt"))
        (should-not (claude-code-ide-start-spec-resume-id spec))
        (should (equal (claude-code-ide-transcript-document-id (claude-code-ide-start-spec-prompt spec))
                       id))))))

(ert-deftest claude-code-ide-test-handover-unsaved-target-p-by-provider ()
  "A target is unsaved when its provider finds no transcript file for its native ID.
Claude Code: the session file of the registry entry.  Codex: the rollout
file, which the transcript operation finds."
  (claude-code-ide-handover-tests--with
    (let* ((config (expand-file-name "claude" root))
           (codex-home (expand-file-name "codex" root))
           (process-environment (append (list (concat "CLAUDE_CONFIG_DIR=" config)
                                              (concat "CODEX_HOME=" codex-home))
                                        process-environment))
           (cc-id "cc1e5000-0000-4000-8000-0000000000cc")
           (cx-id "cc1e5000-0000-4000-8000-0000000000cd")
           (run (lambda (key provider native)
                  (claude-code-ide-handover--run-create
                   :id "cci-test-run" :target-id key :target-provider provider
                   :target-native-id native :stage 'target-identified))))
      (claude-code-ide-handover-tests--registry-add "cci-test-cc" 'claude worktree :session-id cc-id)
      (claude-code-ide-handover-tests--registry-add "cci-test-cx" 'codex worktree :session-id cx-id)
      (should (claude-code-ide-handover--unsaved-target-p (funcall run "cci-test-cc" 'claude cc-id)))
      (should (claude-code-ide-handover--unsaved-target-p (funcall run "cci-test-cx" 'codex cx-id)))
      ;; The Claude Code session file, in the folder of the project
      (let ((file (expand-file-name
                   (concat cc-id ".jsonl")
                   (expand-file-name (claude-code-ide-session-registry--project-slug worktree)
                                     (expand-file-name "projects" config)))))
        (make-directory (file-name-directory file) t)
        (write-region "{}\n" nil file nil 'silent)
        (should-not (claude-code-ide-handover--unsaved-target-p (funcall run "cci-test-cc" 'claude cc-id))))
      ;; The Codex rollout file
      (let ((file (expand-file-name (concat "sessions/2026/11/20/rollout-2026-11-20T10-00-00-" cx-id ".jsonl")
                                    codex-home)))
        (make-directory (file-name-directory file) t)
        (write-region "{}\n" nil file nil 'silent)
        (should-not (claude-code-ide-handover--unsaved-target-p (funcall run "cci-test-cx" 'codex cx-id)))))))

(ert-deftest claude-code-ide-test-handover-recovery-codex-target ()
  "A Codex target at target-identified resumes when its rollout exists.
The recovery scans first and keeps the stage and the native ID; the
decision comes after the clean scan.  Without a rollout the target
starts fresh, with no native ID of its own: Codex chooses a new one.
A Claude Code target keeps its ID for --session-id."
  (claude-code-ide-handover-tests--with
    (let* ((codex-home (expand-file-name "codex" root))
           (process-environment (cons (concat "CODEX_HOME=" codex-home) process-environment))
           (cx-id "cc1e5000-0000-4000-8000-0000000000cd")
           (next nil)
           (started nil)
           (resumed nil)
           (run (lambda (provider native)
                  (claude-code-ide-handover--run-create
                   :id "cci-test-run" :target-id "cci-test-cx" :target-provider provider
                   :target-native-id native :stage 'target-identified :status 'running
                   :directory worktree :worktree worktree))))
      (claude-code-ide-handover-tests--registry-add "cci-test-cx" 'codex worktree :session-id cx-id)
      (cl-letf (((symbol-function 'claude-code-ide-handover--scan-then)
                 (lambda (_run continuation) (setq next continuation)))
                ((symbol-function 'claude-code-ide-handover--result) #'ignore)
                ((symbol-function 'claude-code-ide-handover--start-target)
                 (lambda (run) (setq started run)))
                ((symbol-function 'claude-code-ide-handover--resume-saved-target)
                 (lambda (run) (setq resumed run))))
        ;; The recovery scans first, and keeps the stage and the ID
        (let ((codex (funcall run 'codex cx-id)))
          (claude-code-ide-handover--recover-claimed codex nil)
          (should (eq next 'resume-target))
          (should (eq (claude-code-ide-handover--run-stage codex) 'target-identified))
          (should (equal (claude-code-ide-handover--run-target-native-id codex) cx-id))
          ;; After the clean scan, no rollout: a fresh start, and Codex
          ;; chooses the new ID
          (claude-code-ide-handover--resume-target codex)
          (should (eq started codex))
          (should-not resumed)
          (should (eq (claude-code-ide-handover--run-stage codex) 'target-started))
          (should-not (claude-code-ide-handover--run-target-native-id codex)))
        ;; A Claude Code target keeps its ID
        (let ((claude (funcall run 'claude cx-id)))
          (setq started nil)
          (claude-code-ide-handover--resume-target claude)
          (should (eq started claude))
          (should (equal (claude-code-ide-handover--run-target-native-id claude) cx-id)))
        ;; With its rollout: the resume, as before
        (let ((file (expand-file-name (concat "sessions/2026/11/20/rollout-2026-11-20T10-00-00-" cx-id ".jsonl")
                                      codex-home))
              (codex (funcall run 'codex cx-id)))
          (make-directory (file-name-directory file) t)
          (write-region "{}\n" nil file nil 'silent)
          (setq started nil)
          (claude-code-ide-handover--resume-target codex)
          (should (eq resumed codex))
          (should-not started)
          (should (eq (claude-code-ide-handover--run-stage codex) 'target-identified))
          (should (equal (claude-code-ide-handover--run-target-native-id codex) cx-id)))))))

(ert-deftest claude-code-ide-test-handover-fresh-start-spec ()
  "The fresh start of an unsaved Claude Code target names its session ID.
The --session-id flag comes after the user's flags.  Codex chooses its
own ID, so a Codex target gets no such flag."
  (let ((claude-code-ide-cli-extra-flags "--model opus")
        (run (lambda (provider)
               (claude-code-ide-handover--run-create
                :id "cci-test-run" :target-id "cci-test-tgt" :target-provider provider
                :target-native-id "cc1e5000-0000-4000-8000-0000000000cc"
                :directory "/tmp/cci-test-proj/" :stage 'target-started))))
    (cl-letf (((symbol-function 'claude-code-ide-session-registry-entry-of) #'ignore))
      (should (equal (claude-code-ide-start-spec-extra-flags
                      (claude-code-ide-handover--start-spec (funcall run 'claude) "cci-test prompt"))
                     "--model opus --session-id cc1e5000-0000-4000-8000-0000000000cc"))
      (should-not (claude-code-ide-start-spec-extra-flags
                   (claude-code-ide-handover--start-spec (funcall run 'codex) "cci-test prompt")))
      ;; A first start has no native ID yet: the registry chooses one
      (let ((first (funcall run 'claude)))
        (setf (claude-code-ide-handover--run-target-native-id first) nil)
        (should-not (claude-code-ide-start-spec-extra-flags
                     (claude-code-ide-handover--start-spec first "cci-test prompt")))))))

(ert-deftest claude-code-ide-test-handover-recovery-transcript-check ()
  "A resumed target whose transcript holds the document gets it no second time."
  (claude-code-ide-handover-tests--with
    (let* ((id (claude-code-ide-handover-tests--interrupted 'target-identified
                                                            :target-native "cci-test-tgt-native"))
           (file (expand-file-name "cci-test-tgt.jsonl" worktree)))
      (with-temp-file file
        (insert (json-encode `((type . "user") (sessionId . "cci-test-tgt-native")
                               (message . ((role . "user")
                                           (content . ,(format "<!-- claude-code-ide-handover-document id=%s -->\n# Handover" id)))))))
        (insert "\n"))
      ;; The SessionStart report of the target gave the registry its transcript
      (claude-code-ide-session-registry--submit
       "report" (claude-code-ide-session-registry--change-reported
                 "cci-test-tgt" "cci-test-tgt-native" file nil 3))
      (claude-code-ide-handover-recover)
      (claude-code-ide-handover-tests--run-timers 3)
      ;; The resume gets no second pointer
      (should-not (claude-code-ide-start-spec-prompt (car claude-code-ide-handover-tests--starts)))
      (should-not (claude-code-ide-control--pending-records "cci-test-tgt"))
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed)))))

(ert-deftest claude-code-ide-test-handover-restore-skips-chain ()
  "The plain restore leaves out the legs that a handover holds."
  (claude-code-ide-handover-tests--with
    (let ((entry (lambda (handover chain)
                   (claude-code-ide-session-registry-entry-create
                    :key "cci-test-x" :handover handover :chain chain))))
      (should-not (claude-code-ide-session-registry--handover-blocks-p (funcall entry nil nil)))
      (should-not (claude-code-ide-session-registry--handover-blocks-p
                   (funcall entry '((stage . "quiescing") (status . "running")) nil)))
      (should-not (claude-code-ide-session-registry--handover-blocks-p
                   (funcall entry '((stage . "source-stopped") (status . "cancelled")) nil)))
      (should (claude-code-ide-session-registry--handover-blocks-p
               (funcall entry '((stage . "source-stopped") (status . "running")) nil)))
      (should (claude-code-ide-session-registry--handover-blocks-p
               (funcall entry '((stage . "target-started") (status . "needs-user")) nil)))
      (should (claude-code-ide-session-registry--handover-blocks-p
               (funcall entry '((stage . "committed") (status . "committed")) nil)))
      ;; A target whose leg waits for the commit
      (should (claude-code-ide-session-registry--handover-blocks-p
               (funcall entry nil '(((instance_id . "cci-test-x") (pending . t))))))
      (should-not (claude-code-ide-session-registry--handover-blocks-p
                   (funcall entry nil '(((instance_id . "cci-test-x")))))))
    ;; restorable-p uses it: an entry of a crashed Emacs
    (claude-code-ide-handover-tests--registry-add
     "cci-test-crashed" 'cci-test-a worktree :emacs-pid 999999999
     :handover '((stage . "target-started") (status . "running")))
    (claude-code-ide-handover-tests--registry-add "cci-test-plain" 'cci-test-a worktree
                                                  :emacs-pid 999999999)
    (cl-letf (((symbol-function 'claude-code-ide-session-registry--live-cli-sessions) #'ignore))
      (let ((keys (mapcar #'claude-code-ide-session-registry-entry-key
                          (claude-code-ide-session-registry--restorable-entries))))
        (should (member "cci-test-plain" keys))
        (should-not (member "cci-test-crashed" keys))))))

;;; The registry

(ert-deftest claude-code-ide-test-handover-registry-fields ()
  "The chain and the handover survive the state file; wrong types are dropped."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--registry-add "cci-test-e" 'cci-test-a worktree)
    (should (claude-code-ide-session-registry-save-chain
             "cci-test-e" (list (list :provider 'cci-test-a :native-id "n1" :end-record 20)
                                (list :provider 'cci-test-b :instance-id "cci-test-e" :pending t))))
    (should (claude-code-ide-session-registry-save-handover
             "cci-test-e" '((id . "h1") (stage . "quiescing") (status . "running"))))
    (should (eq (claude-code-ide-session-registry-save-handover "cci-test-none" '((id . "h2")))
                :missing))
    (let ((entry (claude-code-ide-session-registry-entry-of "cci-test-e")))
      (should (equal (claude-code-ide-session-registry-entry-legs entry)
                     '((:provider cci-test-a :native-id "n1" :end-record 20)
                       (:provider cci-test-b :instance-id "cci-test-e" :pending t))))
      (should (equal (alist-get 'stage (claude-code-ide-session-registry-entry-handover entry))
                     "quiescing")))
    ;; A new start of a known entry keeps both
    (claude-code-ide-handover-tests--registry-add "cci-test-e" 'cci-test-a worktree :generation 2)
    (let ((entry (claude-code-ide-session-registry-entry-of "cci-test-e")))
      (should (= (claude-code-ide-session-registry-entry-generation entry) 2))
      (should (= (length (claude-code-ide-session-registry-entry-chain entry)) 2))
      (should (claude-code-ide-session-registry-entry-handover entry)))
    ;; Wrong types read as nil
    (let ((entry (claude-code-ide-session-registry--entry-from-alist
                  '((instance_id . "cci-test-w") (chain . "x") (handover . (1 2))))))
      (should-not (claude-code-ide-session-registry-entry-chain entry))
      (should-not (claude-code-ide-session-registry-entry-handover entry)))))

(ert-deftest claude-code-ide-test-handover-chain-current ()
  "The current leg follows the committed handovers; no chain gives nil."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--registry-add
     "cci-test-l1" 'cci-test-a worktree
     :handover '((id . "h1") (status . "committed") (stage . "committed")
                 (target_instance_id . "cci-test-l2")))
    (claude-code-ide-handover-tests--registry-add
     "cci-test-l2" 'cci-test-b worktree
     :chain '(((instance_id . "cci-test-l1")) ((instance_id . "cci-test-l2")))
     :handover '((id . "h2") (status . "committed") (stage . "committed")
                 (target_instance_id . "cci-test-l3")))
    (claude-code-ide-handover-tests--registry-add
     "cci-test-l3" 'cci-test-a worktree
     :chain '(((instance_id . "cci-test-l1")) ((instance_id . "cci-test-l2"))
              ((instance_id . "cci-test-l3"))))
    (dolist (id '("cci-test-l1" "cci-test-l2" "cci-test-l3"))
      (should (equal (claude-code-ide-session-registry-chain-current id) "cci-test-l3")))
    ;; A handover that is not committed does not move the current leg
    (claude-code-ide-handover-tests--registry-add
     "cci-test-l3" 'cci-test-a worktree
     :handover '((id . "h3") (status . "running") (stage . "target-started")
                 (target_instance_id . "cci-test-l4")))
    (should (equal (claude-code-ide-session-registry-chain-current "cci-test-l1") "cci-test-l3"))
    ;; No chain, and an unknown ID
    (claude-code-ide-handover-tests--registry-add "cci-test-alone" 'cci-test-a worktree)
    (should-not (claude-code-ide-session-registry-chain-current "cci-test-alone"))
    (should-not (claude-code-ide-session-registry-chain-current "cci-test-unknown"))))

;;; The control state of registry entries (item 9 of the brief)

(ert-deftest claude-code-ide-test-handover-control-state-of-registry ()
  "A failed registry entry is `failed' with its reason; a pending one is starting."
  (claude-code-ide-handover-tests--with
    (let ((entries nil))
      (cl-letf (((symbol-function 'claude-code-ide-control-registry-entry)
                 (lambda (id) (cdr (assoc id entries)))))
        (push (cons "cci-test-f1" (claude-code-ide-session-registry-entry-create
                                   :key "cci-test-f1" :state 'failed
                                   :failure "The CLI exited with code 1, 2 seconds after the start"))
              entries)
        (push (cons "cci-test-f2" (claude-code-ide-session-registry-entry-create
                                   :key "cci-test-f2" :state 'failed :failure "Directory x does not exist"))
              entries)
        (push (cons "cci-test-p" (claude-code-ide-session-registry-entry-create
                                  :key "cci-test-p" :state 'pending))
              entries)
        (push (cons "cci-test-o" (claude-code-ide-session-registry-entry-create
                                  :key "cci-test-o" :state 'open))
              entries)
        (let ((state (claude-code-ide-control-state-of "cci-test-f1")))
          (should (eq (plist-get state :state) 'failed))
          (should (eq (plist-get state :reason) 'exit-code))
          (should (string-prefix-p "The CLI exited" (plist-get state :detail))))
        (let ((state (claude-code-ide-control-state-of "cci-test-f2")))
          (should (eq (plist-get state :reason) 'error))
          (should (equal (plist-get state :detail) "Directory x does not exist")))
        (let ((state (claude-code-ide-control-state-of "cci-test-p")))
          (should (eq (plist-get state :state) 'working))
          (should (eq (plist-get state :reason) 'starting)))
        (should (eq (plist-get (claude-code-ide-control-state-of "cci-test-o") :state) 'disconnected))
        ;; The submit rules follow: failed rejects, pending queues
        (should (eq (plist-get (claude-code-ide-control-submit "cci-test-f1" "cci-test-x") :result)
                    'rejected))
        (should (eq (plist-get (claude-code-ide-control-submit "cci-test-f1" "cci-test-x") :reason)
                    'failed/exit-code))
        (should (eq (plist-get (claude-code-ide-control-submit "cci-test-p" "cci-test-y") :result)
                    'queued))))))

;;; Coordinator approvals in Codex (item 9a of the brief)

(ert-deftest claude-code-ide-test-handover-codex-approves-request-status ()
  "A Codex coordinator calls request-status without approval, like list and inspect."
  (should (member "claude-code-ide-control-request-status"
                  (default-value 'claude-code-ide-codex-coordinator-approved-tools)))
  (let* ((names '("claude-code-ide-mcp-project-info"
                  "claude-code-ide-control-list-instances"
                  "claude-code-ide-control-request-status"
                  "claude-code-ide-control-handover-status"
                  "claude-code-ide-control-handover"
                  "claude-code-ide-control-stop"))
         (claude-code-ide-mcp-allowed-tools 'auto)
         (claude-code-ide-codex-coordinator-approved-tools
          (default-value 'claude-code-ide-codex-coordinator-approved-tools)))
    (cl-letf (((symbol-function 'claude-code-ide-codex--all-tool-names) (lambda () names))
              ((symbol-function 'claude-code-ide-codex--coordinator-tool-names)
               (lambda () (cdr names)))
              ((symbol-function 'claude-code-ide-mcp-server-get-tool-names) (lambda () names)))
      (let ((coordinator (claude-code-ide-codex--approved-tool-names
                          (claude-code-ide-instance-create :id "c" :role "coordinator")))
            (worker (claude-code-ide-codex--approved-tool-names
                     (claude-code-ide-instance-create :id "w"))))
        (should (member "claude-code-ide-control-request-status" coordinator))
        ;; The status of a handover only reads too (user rule)
        (should (member "claude-code-ide-control-handover-status" coordinator))
        (should (member "claude-code-ide-control-list-instances" coordinator))
        ;; The handover and the stop still ask
        (should-not (member "claude-code-ide-control-handover" coordinator))
        (should-not (member "claude-code-ide-control-stop" coordinator))
        (should (equal worker '("claude-code-ide-mcp-project-info")))))))

;;; The control operation and the tools

(ert-deftest claude-code-ide-test-handover-control-operation ()
  "The handover slot of the control operations and its coordinator tools work."
  (claude-code-ide-handover-tests--with
    (should (eq (alist-get 'handover claude-code-ide-control-operations)
                #'claude-code-ide-handover-session))
    (should (member "claude-code-ide-control-handover" (claude-code-ide-control--tool-names)))
    (should (member "claude-code-ide-control-handover-status" (claude-code-ide-control--tool-names)))
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((json (json-read-from-string
                  (claude-code-ide-handover--mcp-handover "cci-test-src" "cci-test-b" nil "cci-test-why"
                                                          :json-false :json-false "req-9")))
           (id (alist-get 'handover_id json)))
      (should (equal (alist-get 'status json) "running"))
      (should (equal (alist-get 'request_id json) "req-9"))
      (claude-code-ide-handover-tests--run-timers)
      ;; The status tool takes the handover ID or the request ID
      (should (equal (alist-get 'stage (json-read-from-string
                                        (claude-code-ide-handover--mcp-status id)))
                     "target-started"))
      (should (equal (alist-get 'handover_id (json-read-from-string
                                              (claude-code-ide-handover--mcp-status "req-9")))
                     id))
      (should (equal (alist-get 'reason (json-read-from-string
                                         (claude-code-ide-handover--mcp-status "cci-test-none")))
                     "unknown-handover")))))

(ert-deftest claude-code-ide-test-handover-request-tool ()
  "request_handover only saves a request; Emacs asks after the next turn end."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (let ((questions 0) (answer nil) (calls nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf questions) answer))
                ((symbol-function 'claude-code-ide-handover)
                 (lambda (&rest args) (push args calls))))
        (let ((result (json-read-from-string
                       (cl-letf (((symbol-function 'claude-code-ide-mcp-request-instance-id)
                                  (lambda () "cci-test-src")))
                         (claude-code-ide-handover--mcp-request "cci-test-b" nil "cci-test-quota")))))
          (should (equal (alist-get 'status result) "requested"))
          (should (equal (alist-get 'target_provider result) "cci-test-b")))
        ;; Nothing happens before the turn ends
        (claude-code-ide-handover-tests--run-timers)
        (should (= questions 0))
        (claude-code-ide-handover-tests--event "cci-test-src" 'turn-end)
        (claude-code-ide-handover-tests--run-timers)
        (should (= questions 1))
        (should-not calls)
        ;; The request is used once
        (claude-code-ide-handover-tests--event "cci-test-src" 'turn-end)
        (claude-code-ide-handover-tests--run-timers)
        (should (= questions 1))
        ;; A yes starts the handover
        (setq answer t)
        (claude-code-ide-handover-request "cci-test-src" "cci-test-b" "fresh" "cci-test-why")
        (claude-code-ide-handover-tests--event "cci-test-src" 'turn-end)
        (claude-code-ide-handover-tests--run-timers)
        ;; No other session runs in the worktree: no :allow-others
        (should (equal calls '(("cci-test-src" cci-test-b fresh "cci-test-why" nil nil nil nil))))
        ;; A request without a known instance
        (should (eq (plist-get (claude-code-ide-handover-request "cci-test-none" nil) :reason)
                    'not-running))))))

;;; The status key (item 10 of the brief)

(ert-deftest claude-code-ide-test-handover-status-key ()
  "The status buffer key offers the session at point, else the one at a quota limit."
  (should (eq (lookup-key claude-code-ide-session-status-list-mode-map (kbd "H"))
              #'claude-code-ide-session-status-handover))
  (let* ((at-point (claude-code-ide-instance-create :id "cci-test-point"))
         (quota (claude-code-ide-instance-create :id "cci-test-quota"))
         (calls nil))
    ;; `tabulated-list-get-id' is inlined, so the line is real text
    (cl-letf (((symbol-function 'claude-code-ide-session-status--rows)
               (lambda (&rest _) (list (list at-point 'working 0 "" nil)
                                       (list quota 'quota 0 "" nil))))
              ((symbol-function 'claude-code-ide-handover--read-args)
               (lambda (id) (list id 'cci-test-b 'fresh nil nil nil)))
              ((symbol-function 'claude-code-ide-handover)
               (lambda (&rest args) (push args calls))))
      (with-temp-buffer
        ;; No line: the session at the quota limit
        (claude-code-ide-session-status-handover)
        (should (equal (car calls) '("cci-test-quota" cci-test-b fresh nil nil nil)))
        ;; The session on the line
        (insert (propertize "cci-test-point\n" 'tabulated-list-id at-point))
        (goto-char (point-min))
        (claude-code-ide-session-status-handover)
        (should (equal (car (car calls)) "cci-test-point"))
        ;; Nothing at all
        (erase-buffer)
        (cl-letf (((symbol-function 'claude-code-ide-session-status--rows) #'ignore))
          (should-error (claude-code-ide-session-status-handover) :type 'user-error))))))

;;; Helpers

(ert-deftest claude-code-ide-test-handover-exclude-once ()
  "The handover folder goes into the Git exclude file one time."
  (claude-code-ide-handover-tests--with
    (let ((file (claude-code-ide-handover-exclude worktree)))
      (claude-code-ide-handover-exclude worktree)
      (with-temp-buffer
        (insert-file-contents file)
        (should (= (cl-count ".handover/" (split-string (buffer-string) "\n") :test #'equal) 1))))
    ;; Not a Git folder: nothing
    (let ((plain (make-temp-file "cci-test-plain-" t)))
      (unwind-protect
          (let ((default-directory plain)
                (process-environment (cons (concat "GIT_CEILING_DIRECTORIES="
                                                   (file-name-directory (directory-file-name plain)))
                                           process-environment)))
            (should-not (claude-code-ide-handover-exclude plain)))
        (delete-directory plain t)))))

(ert-deftest claude-code-ide-test-handover-codex-rollout ()
  "A Codex leg finds its rollout file by its native ID in the Codex home."
  (let* ((home (make-temp-file "cci-test-codex-home-" t))
         (dir (expand-file-name "sessions/2026/11/18" home))
         (id "cc1e5000-0000-4000-8000-000000000001")
         (file (expand-file-name (concat "rollout-2026-11-18T10-00-00-" id ".jsonl") dir))
         (process-environment (cons (concat "CODEX_HOME=" home) process-environment)))
    (unwind-protect
        (progn
          (make-directory dir t)
          (write-region "{}\n{}\n" nil file nil 'silent)
          (should (equal (claude-code-ide-codex-rollout-file id) file))
          (should-not (claude-code-ide-codex-rollout-file "cc1e5000-0000-4000-8000-000000000002"))
          (should-not (claude-code-ide-codex-rollout-file "../x"))
          (should (equal (claude-code-ide-handover--transcript-file 'codex id) file))
          (should (= (claude-code-ide-handover--line-count file) 2)))
      (delete-directory home t))))

(ert-deftest claude-code-ide-test-handover-transcript-by-provider ()
  "Without a leg file or an entry path, the transcript operation of the provider finds it.
It gets a detached descriptor with the native ID, then the ID of the
entry, and the key and folder of the entry."
  (let* ((dir (make-temp-file "cci-test-handover-transcript-" t))
         (file (expand-file-name "cci-test-found.jsonl" dir))
         (claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry))
         (calls nil)
         (entry (claude-code-ide-session-registry-entry-create
                 :key "cci-test-key" :session-id "cci-test-entry-id" :project-dir dir
                 :provider 'cci-test-p)))
    (unwind-protect
        (progn
          (write-region "{}\n" nil file nil 'silent)
          (claude-code-ide-register-provider
           (claude-code-ide-provider-create
            :name 'cci-test-p
            :transcript (lambda (instance what)
                          (push (list (claude-code-ide-instance-id instance)
                                      (claude-code-ide-instance-native-id instance)
                                      (claude-code-ide-instance-project-root instance)
                                      what)
                                calls)
                          (if (equal (claude-code-ide-instance-native-id instance)
                                     "cci-test-entry-id")
                              file
                            'unknown))))
          (should (equal (claude-code-ide-handover--transcript-file
                          'cci-test-p "cci-test-live-id" entry)
                         file))
          (should (equal (reverse calls)
                         `(("cci-test-key" "cci-test-live-id" ,dir file)
                           ("cci-test-key" "cci-test-entry-id" ,dir file))))
          ;; A provider that is not registered gives nil, not an error
          (should-not (claude-code-ide-handover--transcript-file 'cci-test-none "x" entry))
          ;; The Claude Code operation finds the file from the ID and folder of the entry
          (let* ((config (expand-file-name "claude" dir))
                 (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config) process-environment))
                 (project (expand-file-name "proj" dir))
                 (cc-file (expand-file-name
                           "cci-test-cc-id.jsonl"
                           (expand-file-name (claude-code-ide-session-registry--project-slug project)
                                             (expand-file-name "projects" config))))
                 (cc-entry (claude-code-ide-session-registry-entry-create
                            :key "cci-test-cc-key" :session-id "cci-test-cc-id" :project-dir project
                            :provider 'claude)))
            (make-directory (file-name-directory cc-file) t)
            (write-region "{}\n" nil cc-file nil 'silent)
            (should (equal (claude-code-ide-handover--transcript-file 'claude nil cc-entry)
                           cc-file))
            ;; The session file of the entry comes before the file of
            ;; the live native ID, as before the provider operation
            (write-region "{}\n" nil (expand-file-name "cci-test-cc-live.jsonl"
                                                       (file-name-directory cc-file))
                          nil 'silent)
            (should (equal (claude-code-ide-handover--transcript-file
                            'claude "cci-test-cc-live" cc-entry)
                           cc-file))
            ;; Claude Code has exactly the three old steps: without an
            ;; entry file, the file of the live native ID does not count
            (delete-file cc-file)
            (let ((asked nil))
              (cl-letf (((symbol-function 'claude-code-ide--claude-transcript)
                         (lambda (&rest _) (setq asked t) 'unknown)))
                (should-not (claude-code-ide-handover--transcript-file
                             'claude "cci-test-cc-live" cc-entry))
                (should-not (claude-code-ide-handover--transcript-file 'claude "cci-test-cc-live")))
              (should-not asked))))
      (delete-directory dir t))))

;;; Review fixes

(defun claude-code-ide-handover-tests--saving-unless (predicate)
  "Return a save function that saves a handover unless PREDICATE says no.
PREDICATE gets the handover alist; a non-nil value makes the save fail
as with a busy lock, without a write."
  (let ((save (symbol-function 'claude-code-ide-session-registry-save-handover)))
    (lambda (key handover &rest args)
      (unless (funcall predicate handover)
        (apply save key handover args)))))

(ert-deftest claude-code-ide-test-handover-registry-v4-file-migrates-v3 ()
  "The handover fields go into version 4, in its own file.
While it does not exist, the version 3 file is read and migrated; the
version 3 file is never written."
  (claude-code-ide-handover-tests--with
    (let* ((v3 (claude-code-ide-session-registry--versioned-file 3))
           (v3-text (concat "{\"version\": 3, \"sessions\": [{\"instance_id\": \"cci-test-v3rec\","
                            " \"provider\": \"claude\", \"native_id\": \"cci-test-v3native\","
                            " \"generation\": 2, \"project_dir\": \"/tmp/cci-test-v3/\","
                            " \"extra_flags\": \"\", \"state\": \"closed\"}]}")))
      (should (string-suffix-p "state-v4.json" (claude-code-ide-session-registry--state-file)))
      (with-temp-file v3 (insert v3-text))
      (should (equal (mapcar #'claude-code-ide-session-registry-entry-key
                             (claude-code-ide-session-registry--entries))
                     '("cci-test-v3rec")))
      (should (claude-code-ide-session-registry-save-chain
               "cci-test-v3rec" (list (list :provider 'claude :instance-id "cci-test-v3rec"))))
      (let ((data (claude-code-ide-session-registry--json-decode
                   (claude-code-ide-session-registry--file-string
                    (claude-code-ide-session-registry--state-file)))))
        (should (= (alist-get 'version data) 4))
        (should (alist-get 'chain (car (alist-get 'sessions data)))))
      (should (equal (claude-code-ide-session-registry--file-string v3) v3-text))
      (should-not (file-exists-p (concat v3 ".bak"))))))

(ert-deftest claude-code-ide-test-handover-recovery-claims-run ()
  "Recovery and cancel leave a handover alone that another live Emacs owns.
When that Emacs ends, the recovery claims the run in the registry first."
  (claude-code-ide-handover-tests--with
    (let* ((id (claude-code-ide-handover-tests--interrupted 'target-started))
           (other (start-process "cci-test-other-emacs" nil "sleep" "30"))
           (pid (process-id other))
           (start (float-time (alist-get 'start (process-attributes pid)))))
      (unwind-protect
          (let ((record (copy-alist (claude-code-ide-handover-tests--record "cci-test-src"))))
            (setf (alist-get 'emacs_pid record) pid
                  (alist-get 'emacs_start_time record) start)
            (should (claude-code-ide-session-registry-save-handover "cci-test-src" record))
            ;; Another live Emacs owns it: no recovery, no cancel, no claim
            (should-not (claude-code-ide-handover-recover))
            (should-not claude-code-ide-handover-tests--starts)
            (should-error (claude-code-ide-handover-cancel id) :type 'user-error)
            (should-not (claude-code-ide-session-registry-claim-handover "cci-test-src" id))
            (should (eql (alist-get 'emacs_pid (claude-code-ide-handover-tests--record "cci-test-src"))
                         pid))
            ;; That Emacs ends: this Emacs claims the run, then recovers it
            (delete-process other)
            (should (claude-code-ide-tests--wait-until
                     (lambda () (not (claude-code-ide-session-registry--same-start-p pid start)))))
            (claude-code-ide-handover-recover)
            (should (= (length claude-code-ide-handover-tests--starts) 1))
            (should (eql (alist-get 'emacs_pid (claude-code-ide-handover-tests--record "cci-test-src"))
                         (emacs-pid))))
        (when (process-live-p other) (delete-process other))))))

(ert-deftest claude-code-ide-test-handover-inbox-moves-before-commit ()
  "The inbox moves while the handover is not yet committed in the registry."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((status-at-move nil))
      (cl-letf* ((move (symbol-function 'claude-code-ide-control-move-inbox))
                 ((symbol-function 'claude-code-ide-control-move-inbox)
                  (lambda (from to &rest args)
                    (setq status-at-move
                          (alist-get 'status (claude-code-ide-handover-tests--record "cci-test-src")))
                    (apply move from to args))))
        (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)))
          (claude-code-ide-handover-tests--run-timers 20)
          (claude-code-ide-handover-tests--deliver result)
          (should (equal status-at-move "running"))
          (should (eq (plist-get (claude-code-ide-handover-status (plist-get result :handover-id))
                                 :status)
                      'committed)))))))

(ert-deftest claude-code-ide-test-handover-step-after-busy-registry ()
  "A busy registry at the stage delivered retries the step, which commits."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((failures 1))
      (cl-letf (((symbol-function 'claude-code-ide-session-registry-save-handover)
                 (claude-code-ide-handover-tests--saving-unless
                  (lambda (handover)
                    (and (equal (alist-get 'stage handover) "delivered")
                         (> failures 0)
                         (progn (cl-decf failures) t))))))
        (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)))
          (claude-code-ide-handover-tests--run-timers 20)
          (claude-code-ide-handover-tests--deliver result)
          (should (= failures 0))
          (should (eq (plist-get (claude-code-ide-handover-status (plist-get result :handover-id))
                                 :status)
                      'committed)))))))

(ert-deftest claude-code-ide-test-handover-delivery-watch ()
  "A target without the delivery in time, or one that ends, needs a person.
Then the cancel stops the target and archives its registry entry."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((stopped nil))
      (cl-letf (((symbol-function 'claude-code-ide-process-stop)
                 (lambda (instance &rest _)
                   (push (claude-code-ide-instance-id instance) stopped)
                   (claude-code-ide-instance-unregister (claude-code-ide-instance-id instance))
                   '(:status stopped))))
        ;; No delivery in time
        (let* ((claude-code-ide-handover-delivery-timeout 0)
               (id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)
                              :handover-id)))
          (claude-code-ide-handover-tests--run-timers 20)
          (let* ((status (claude-code-ide-handover-status id))
                 (target (plist-get status :target-id)))
            (should (eq (plist-get status :status) 'needs-user))
            (should (eq (plist-get status :reason) 'no-delivery))
            (claude-code-ide-handover-cancel id)
            (should (equal stopped (list target)))
            (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
            (should (eq (claude-code-ide-session-registry-entry-state
                         (claude-code-ide-session-registry-entry-of target))
                        'archived))))
        ;; The target ends before the delivery
        (claude-code-ide-handover-tests--add "cci-test-src2" 'cci-test-a
                                             (claude-code-ide-handover-tests--other "proj2") 'idle)
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src2" 'cci-test-b)
                             :handover-id)))
          (claude-code-ide-handover-tests--run-timers 20)
          (let ((target (plist-get (claude-code-ide-handover-status id) :target-id)))
            (kill-buffer (claude-code-ide-instance-buffer (claude-code-ide-instance-by-id target))))
          (claude-code-ide-handover-tests--run-timers 3)
          (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'target-exited)))))))

(ert-deftest claude-code-ide-test-handover-holds-source-inbox ()
  "While the handover quiesces, no queued prompt goes to the source."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
      (claude-code-ide-handover-tests--run-timers 2)
      (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'quiescing))
      (claude-code-ide-control-submit "cci-test-src" "cci-test-late" :request-id "late")
      (claude-code-ide-handover-tests--set-state "cci-test-src" 'idle)
      (should-not (claude-code-ide-control-deliver-pending "cci-test-src"))
      (should-not claude-code-ide-handover-tests--sent)
      (should (claude-code-ide-control-held-p "cci-test-src"))
      ;; An idle source with the hold queues a new prompt too
      (should (eq (plist-get (claude-code-ide-control-submit "cci-test-src" "cci-test-later"
                                                             :request-id "later")
                             :reason)
                  'held))
      ;; The cancel releases the hold
      (claude-code-ide-handover-cancel id)
      (should-not (claude-code-ide-control-held-p "cci-test-src"))
      (should (equal (claude-code-ide-control-deliver-pending "cci-test-src") "late")))))

(ert-deftest claude-code-ide-test-handover-reopen-blocked ()
  "A committed source is never reopened or resumed next to its target."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--registry-add
     "cci-test-done" 'cci-test-a worktree :state 'closed :closed-by "killed"
     :handover '((id . "h1") (status . "committed") (stage . "committed")
                 (target_instance_id . "cci-test-next")))
    (let ((entry (claude-code-ide-session-registry-entry-of "cci-test-done")))
      (should-not (claude-code-ide-session-registry--reopenable-p entry))
      (should-error (claude-code-ide-reopen-session entry) :type 'user-error)
      (should-error (claude-code-ide-session-registry--start-entry entry nil) :type 'user-error)
      (should-not claude-code-ide-handover-tests--starts)
      ;; Only the handover itself starts such an entry
      (let ((claude-code-ide-session-registry--handover-start "cci-test-done"))
        (claude-code-ide-session-registry--start-entry entry nil))
      (should (= (length claude-code-ide-handover-tests--starts) 1)))))

(ert-deftest claude-code-ide-test-handover-stray-start-time ()
  "A stray gets a signal only while its process has the start time of the scan."
  (let ((signals nil)
        (start nil))
    (cl-letf (((symbol-function 'process-attributes)
               (lambda (_pid)
                 `((args . "sleep 600") (comm . "sleep")
                   ,@(when start (list (cons 'start (seconds-to-time start)))))))
              ((symbol-function 'signal-process)
               (lambda (pid signal) (push (list pid signal) signals) 0)))
      (let ((stray '(:pid 4848 :command "sleep 600" :start 1000.0)))
        ;; Another process with that ID now
        (setq start 2000)
        (claude-code-ide-handover--end-strays (list stray) 'SIGTERM)
        (should-not signals)
        ;; No start time now
        (setq start nil)
        (claude-code-ide-handover--end-strays (list stray) 'SIGTERM)
        (should-not signals)
        ;; No start time at the scan
        (setq start 1000)
        (claude-code-ide-handover--end-strays '((:pid 4848 :command "sleep 600")) 'SIGTERM)
        (should-not signals)
        ;; The same process
        (claude-code-ide-handover--end-strays (list stray) 'SIGTERM)
        (should (equal signals '((4848 SIGTERM)))))
      ;; The scan records the start time
      (should (= (plist-get (claude-code-ide-handover--with-start
                             '(:pid 4848 :command "sleep 600"))
                            :start)
                 1000.0)))))

(ert-deftest claude-code-ide-test-handover-preflight ()
  "The preflight refuses before anything of the source changes."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (cl-flet ((reason (&rest args)
                (plist-get (apply #'claude-code-ide-handover-session args) :reason)))
      ;; The target CLI is missing
      (claude-code-ide-register-provider
       (claude-code-ide-provider-create
        :name 'cci-test-c :display-name "Stub c" :buffer-name-prefix "cci-c"
        :detect (lambda (&rest _) (list :available nil :program "cci-test-none" :version 'unknown))
        :launch (lambda (&rest _) (list :command "true"))))
      (should (eq (reason "cci-test-src" 'cci-test-c) 'target-unavailable))
      ;; Another live instance in the worktree
      (claude-code-ide-handover-tests--add "cci-test-other" 'cci-test-a worktree 'idle)
      (should (eq (reason "cci-test-src" 'cci-test-b) 'other-instance))
      (should-not claude-code-ide-handover-tests--saved)
      (should-not (claude-code-ide-handover-tests--record "cci-test-src"))
      (claude-code-ide-instance-unregister "cci-test-other")
      ;; A Codex target without trusted hooks
      (let ((checks 0) (asks 0) (trusted nil))
        (cl-letf (((symbol-function 'claude-code-ide-handover--target-available-p) (lambda (_) t))
                  ((symbol-function 'claude-code-ide-codex-events--trust-key) (lambda () "cci-test-key"))
                  ((symbol-function 'claude-code-ide-codex-events--cached-trust)
                   (lambda (_) (and trusted '(:status trusted))))
                  ((symbol-function 'claude-code-ide-codex-events--start-trust-check)
                   (lambda (&rest _) (cl-incf checks) nil))
                  ((symbol-function 'claude-code-ide-codex-events--release-check) #'ignore)
                  ((symbol-function 'claude-code-ide-codex-prepare-trust)
                   (lambda (&rest _) (cl-incf asks) t)))
          (should (eq (reason "cci-test-src" 'codex) 'hooks-not-trusted))
          (should (= checks 1))
          (should (= asks 0))
          (should-not (claude-code-ide-handover-tests--record "cci-test-src"))
          ;; A person's handover asks for the trust
          (should (eq (plist-get (claude-code-ide-handover-session "cci-test-src" 'codex :interactive t)
                                 :status)
                      'running))
          (should (= asks 1)))))))

(ert-deftest claude-code-ide-test-handover-first-save-leaves-nothing ()
  "A first save that waits for the lock is dropped, so no record appears later."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (cl-letf (((symbol-function 'claude-code-ide-session-registry--call-with-lock)
               (lambda (&rest _)
                 (signal 'claude-code-ide-session-registry-lock-busy (list "cci-test-lock")))))
      (should (eq (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :reason)
                  'registry-write-failed)))
    (when (timerp claude-code-ide-session-registry--retry-timer)
      (cancel-timer claude-code-ide-session-registry--retry-timer))
    (should-not claude-code-ide-session-registry--queue)
    (claude-code-ide-session-registry--drain)
    (should-not (claude-code-ide-handover-tests--record "cci-test-src"))))

(ert-deftest claude-code-ide-test-handover-target-saves-checked ()
  "The target starts only after its ID is saved; its pending chain is saved too."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((busy t) (chain-busy t))
      (cl-letf* ((save-chain (symbol-function 'claude-code-ide-session-registry-save-chain))
                 ((symbol-function 'claude-code-ide-session-registry-save-handover)
                  (claude-code-ide-handover-tests--saving-unless
                   (lambda (handover)
                     (and busy (equal (alist-get 'stage handover) "target-started")))))
                 ((symbol-function 'claude-code-ide-session-registry-save-chain)
                  (lambda (&rest args) (unless chain-busy (apply save-chain args)))))
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)
                             :handover-id)))
          (claude-code-ide-handover-tests--run-timers 10)
          (should-not claude-code-ide-handover-tests--starts)
          (setq busy nil)
          (claude-code-ide-handover-tests--run-timers 10)
          (should (= (length claude-code-ide-handover-tests--starts) 1))
          (let ((target (plist-get (claude-code-ide-handover-status id) :target-id)))
            (should-not (claude-code-ide-session-registry-entry-chain
                         (claude-code-ide-session-registry-entry-of target)))
            ;; The chain is saved when the registry takes it again
            (setq chain-busy nil)
            (claude-code-ide-handover-tests--run-timers 10)
            (should (plist-get (car (last (claude-code-ide-session-registry-entry-legs
                                           (claude-code-ide-session-registry-entry-of target))))
                               :pending))))))))

(ert-deftest claude-code-ide-test-handover-recovery-scans-before-restart ()
  "Before a recovery starts the target again, no writer may be left.
A stray in the worktree, or a target CLI that outlived the crash,
needs a person, and nothing starts."
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'target-started)))
      (setq claude-code-ide-handover-tests--scan-strays
            '((:pid 4949 :command "sleep 900" :cwd "/x" :reason worktree)))
      (claude-code-ide-handover-recover)
      (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'strays))
      (should-not claude-code-ide-handover-tests--starts)))
  (claude-code-ide-handover-tests--with
    (let* ((id (claude-code-ide-handover-tests--interrupted 'target-started))
           (survivor (start-process "cci-test-target-cli" nil "sleep" "30"))
           (pid (process-id survivor)))
      (unwind-protect
          (progn
            (claude-code-ide-handover-tests--registry-add
             "cci-test-tgt" 'cci-test-b worktree :generation 3 :session-id nil :pid pid
             :process-start-time (float-time (alist-get 'start (process-attributes pid))))
            (claude-code-ide-handover-recover)
            (let ((status (claude-code-ide-handover-status id)))
              (should (eq (plist-get status :status) 'needs-user))
              (should (memql pid (mapcar (lambda (s) (plist-get s :pid)) (plist-get status :strays)))))
            (should-not claude-code-ide-handover-tests--starts))
        (when (process-live-p survivor) (delete-process survivor))))))

(ert-deftest claude-code-ide-test-handover-recover-at-start-default ()
  "Interrupted handovers continue in full when the registry starts (user answer)."
  (should (eq (default-value 'claude-code-ide-handover-recover-at-start) t))
  (let ((calls nil)
        (claude-code-ide-session-registry-mode t)
        (claude-code-ide-handover-recover-at-start t))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (_secs _repeat fn &rest args) (apply fn args)))
              ((symbol-function 'claude-code-ide-handover-recover)
               (lambda (&rest args) (push args calls) nil)))
      (claude-code-ide-handover--recover-at-start)
      (should (equal calls '((nil)))))))

;;; With the review tracking

(defvar claude-code-ide-review-directory)
(defvar claude-code-ide-review-check-interval)
(defvar claude-code-ide-review--records)
(defvar claude-code-ide-review--processes)
(defvar claude-code-ide-review--loaded)
(defvar claude-code-ide-review--foreign)
(defvar claude-code-ide-review--scan-time)
(defvar claude-code-ide-review--warned)
(defvar claude-code-ide-review--timer)

(defmacro claude-code-ide-handover-tests--with-review (&rest body)
  "Run BODY in `claude-code-ide-handover-tests--with', with an empty review folder."
  (declare (indent 0))
  `(claude-code-ide-handover-tests--with
     (let ((claude-code-ide-review-directory
            (expand-file-name "reviews" claude-code-ide-handover-tests--root))
           (claude-code-ide-review-check-interval nil)
           (claude-code-ide-review--records (make-hash-table :test 'equal))
           (claude-code-ide-review--processes (make-hash-table :test 'equal))
           (claude-code-ide-review--loaded nil)
           (claude-code-ide-review--foreign (make-hash-table :test 'equal))
           (claude-code-ide-review--scan-time nil)
           (claude-code-ide-review--warned nil)
           (claude-code-ide-review--timer nil))
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_id process)
                    (when (process-live-p process) (delete-process process)))
                  claude-code-ide-review--processes)))))

(defun claude-code-ide-handover-tests--wait-for (predicate)
  "Run the process sentinels until PREDICATE is true.
Signal an error after `claude-code-ide-tests--wait-limit' seconds."
  (unless (claude-code-ide-tests--wait-until predicate)
    (error "Timeout in a handover test")))

(ert-deftest claude-code-ide-test-handover-with-review-process ()
  "A real review process in the worktree is left alone by the stop and the scan.
Its result, which arrives after the commit, goes to the target through
`claude-code-ide-session-registry-chain-current'."
  (require 'claude-code-ide-review)
  (claude-code-ide-handover-tests--with-review
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((go (expand-file-name "cci-test-go" worktree))
           (track (claude-code-ide-review-track
                   "cci-test-src"
                   :command (list "sh" "-c"
                                  (format "while [ ! -e %s ]; do sleep 0.1; done; printf '%%s' cci-test-review-result > review.txt"
                                          (shell-quote-argument go)))
                   :directory worktree :result-file "review.txt" :review-id "cci-test-rev"))
           (pid (plist-get track :pid))
           (stop-args nil)
           (scan-args nil))
      (should (eq (plist-get track :status) 'ok))
      (should (member pid (claude-code-ide-review-process-ids)))
      ;; The stop reports the review process as still running in the worktree
      (setq claude-code-ide-handover-tests--stop-result
            `(:status strays :strays ((:pid ,pid :command "sh -c ..." :cwd ,worktree :reason worktree))))
      (cl-letf* ((stop (symbol-function 'claude-code-ide-process-stop-later))
                 ((symbol-function 'claude-code-ide-process-stop-later)
                  (lambda (instance &rest args) (setq stop-args args) (apply stop instance args)))
                 ((symbol-function 'claude-code-ide-process-worktree-strays)
                  (lambda (&rest args) (setq scan-args args) nil)))
        (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b))
               (id (plist-get result :handover-id)))
          (claude-code-ide-handover-tests--run-timers 20)
          ;; (1) Left alone: excluded from the stop, no stray, and it still runs
          (should (memql pid (plist-get stop-args :exclude)))
          (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started))
          (should-not (plist-get (claude-code-ide-handover-status id) :strays))
          (claude-code-ide-handover--scan (gethash id claude-code-ide-handover--runs))
          (should (memql pid (cadr scan-args)))
          (should (process-live-p (gethash "cci-test-rev" claude-code-ide-review--processes)))
          ;; The handover commits
          (let ((target (claude-code-ide-handover-tests--deliver result)))
            (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
            (should (equal (claude-code-ide-session-registry-chain-current "cci-test-src") target))
            ;; (2) The review ends after the commit: its result goes to the target
            (write-region "" nil go nil 'silent)
            (claude-code-ide-handover-tests--wait-for
             (lambda () (not (process-live-p (gethash "cci-test-rev" claude-code-ide-review--processes)))))
            (claude-code-ide-review--tick)
            (should (eq (plist-get (claude-code-ide-control-request-status target "review:cci-test-rev")
                                   :result)
                        'queued))
            (should-not (claude-code-ide-control--pending-records "cci-test-src"))
            (should (string-match-p "cci-test-review-result"
                                    (claude-code-ide-control--record-text
                                     (car (claude-code-ide-control--pending-records target)))))))))))

;;; Second review fixes

(defun claude-code-ide-handover-tests--start-prompt-of (id)
  "Return the start prompt of the handover ID: the prompt of its last start."
  (claude-code-ide-handover-start-prompt (gethash id claude-code-ide-handover--runs)))

(defun claude-code-ide-handover-tests--marker-transcript (file id)
  "Write a CC transcript FILE whose user turn starts with the marker of ID."
  (with-temp-file file
    (insert (json-encode `((type . "user") (sessionId . "cci-test-tgt-native")
                           (message . ((role . "user")
                                       (content . ,(format "<!-- claude-code-ide-handover-document id=%s -->\nRead it." id)))))))
    (insert "\n")))

(ert-deftest claude-code-ide-test-handover-delivery-while-needs-user ()
  "A delivery that comes while the run needs a person still commits it.
The wait for the delivery looks at the transcript of the target first."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((claude-code-ide-handover-delivery-timeout 0)
           (id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
      (claude-code-ide-handover-tests--run-timers 20)
      (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'no-delivery))
      (claude-code-ide-handover-tests--event
       (plist-get (claude-code-ide-handover-status id) :target-id) 'prompt-submit
       (list (cons 'prompt (claude-code-ide-handover-tests--start-prompt-of id))))
      (claude-code-ide-handover-tests--run-timers 3)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))))
  ;; "wait": the transcript has the marker, so the handover commits
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((claude-code-ide-handover-delivery-timeout 0)
           (id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id))
           (file (expand-file-name "cci-test-target.jsonl" claude-code-ide-handover-tests--root)))
      (claude-code-ide-handover-tests--run-timers 20)
      (let ((target (plist-get (claude-code-ide-handover-status id) :target-id)))
        (claude-code-ide-handover-tests--marker-transcript file id)
        (claude-code-ide-session-registry--submit
         "report" (claude-code-ide-session-registry--change-reported target "cci-test-tgt-native" file nil nil))
        (claude-code-ide-handover-resolve id 'wait)
        (claude-code-ide-handover-tests--run-timers 3)
        (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))))))

(ert-deftest claude-code-ide-test-handover-context-survives-recovery ()
  "The coordinator context is kept in a private file, and a rewrite uses it."
  (claude-code-ide-handover-tests--with
    (let* ((id (claude-code-ide-handover-tests--interrupted 'document-written
                                                            :context "cci-test-secret-context"))
           (file (expand-file-name (concat ".handover/" id "-context.md") worktree)))
      (should (file-exists-p file))
      (should (= (file-modes file) #o600))
      (should (equal (alist-get 'context_file (claude-code-ide-handover-tests--record "cci-test-src"))
                     file))
      ;; The recovery writes the document again, with the context
      (claude-code-ide-handover-recover)
      (let ((document (plist-get (claude-code-ide-handover-status id) :document)))
        (should (string-match-p "cci-test-secret-context"
                                (with-temp-buffer (insert-file-contents document) (buffer-string))))))))

(ert-deftest claude-code-ide-test-handover-callback-errors-need-user ()
  "An error in a step that a timer runs gives needs-user, never a lost run."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (cl-letf (((symbol-function 'claude-code-ide-control-move-inbox)
               (lambda (&rest _) (error "cci-test move failed"))))
      (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)))
        (claude-code-ide-handover-tests--run-timers 20)
        (claude-code-ide-handover-tests--deliver result)
        (let ((status (claude-code-ide-handover-status (plist-get result :handover-id))))
          (should (eq (plist-get status :status) 'needs-user))
          (should (eq (plist-get status :reason) 'step-failed))
          (should (string-match-p "cci-test move failed" (plist-get status :message))))))))

(ert-deftest claude-code-ide-test-handover-host-id ()
  "The owner of a handover is checked by a host ID file, not by the host name.
An old record with another host name and a dead owner can be
recovered; a forced claim takes over a live owner after a yes."
  (claude-code-ide-handover-tests--with
    ;; An old record of another host name, with a dead owner: claimable
    (let ((id (claude-code-ide-handover-tests--interrupted 'target-started)))
      (let ((record (copy-alist (claude-code-ide-handover-tests--record "cci-test-src"))))
        (setf (alist-get 'emacs_pid record) 999999999
              (alist-get 'host record) "cci-test-elsewhere")
        (setq record (assq-delete-all 'host_id record))
        (should (claude-code-ide-session-registry-save-handover "cci-test-src" record)))
      (should-not (claude-code-ide-session-registry--handover-owner
                   (claude-code-ide-handover-tests--record "cci-test-src")))
      (claude-code-ide-handover-recover)
      (should (= (length claude-code-ide-handover-tests--starts) 1))
      (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started)))
    ;; The host ID file
    (let* ((host-id (claude-code-ide-session-registry-host-id))
           (file (claude-code-ide-session-registry--host-id-file)))
      (should (string-match-p "\\`[0-9a-f-]\\{36\\}\\'" host-id))
      (should (= (file-modes file) #o600))
      (should (equal (claude-code-ide-session-registry-host-id) host-id))
      ;; Another host ID: another host
      (should (eq (claude-code-ide-session-registry--handover-owner
                   '((emacs_pid . 1) (host_id . "00000000-0000-4000-8000-000000000000")))
                  'other))))
  ;; A forced claim of a live owner, after a yes
  (claude-code-ide-handover-tests--with
    (let* ((id (claude-code-ide-handover-tests--interrupted 'target-started))
           (other (start-process "cci-test-other-emacs" nil "sleep" "30"))
           (pid (process-id other))
           (answers nil))
      (unwind-protect
          (let ((record (copy-alist (claude-code-ide-handover-tests--record "cci-test-src"))))
            (setf (alist-get 'emacs_pid record) pid
                  (alist-get 'emacs_start_time record)
                  (float-time (alist-get 'start (process-attributes pid))))
            (should (claude-code-ide-session-registry-save-handover "cci-test-src" record))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (prompt) (push prompt answers) nil)))
              (should-error (claude-code-ide-handover-resolve id) :type 'user-error))
            (should (string-match-p (number-to-string pid) (car answers)))
            (should-not claude-code-ide-handover-tests--starts)
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
              (claude-code-ide-handover-resolve id))
            (should (eql (alist-get 'emacs_pid (claude-code-ide-handover-tests--record "cci-test-src"))
                         (emacs-pid)))
            (should (= (length claude-code-ide-handover-tests--starts) 1)))
        (when (process-live-p other) (delete-process other))))))

(ert-deftest claude-code-ide-test-handover-survivors-before-any-start ()
  "A resume, a retry of a target that ended, and a cancel check for survivors first."
  ;; Recovery of an identified target whose CLI still runs
  (claude-code-ide-handover-tests--with
    (let* ((id (claude-code-ide-handover-tests--interrupted 'target-identified
                                                            :target-native "cci-test-tgt-native"))
           (survivor (start-process "cci-test-target-cli" nil "sleep" "30"))
           (pid (process-id survivor)))
      (unwind-protect
          (progn
            (claude-code-ide-handover-tests--registry-add
             "cci-test-tgt" 'cci-test-b worktree :generation 3 :session-id "cci-test-tgt-native"
             :pid pid :process-start-time (float-time (alist-get 'start (process-attributes pid))))
            (claude-code-ide-handover-recover)
            (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'strays))
            (should (memql pid (mapcar (lambda (s) (plist-get s :pid))
                                       (plist-get (claude-code-ide-handover-status id) :strays))))
            (should-not claude-code-ide-handover-tests--starts)
            ;; A cancel leaves no start, and asks before it ends the process
            (claude-code-ide-handover-cancel id)
            (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'needs-user))
            (should (process-live-p survivor))
            ;; "end": the process ends, then the cancel finishes
            (claude-code-ide-handover-resolve id 'end)
            (claude-code-ide-handover-tests--wait-for (lambda () (not (process-live-p survivor))))
            (claude-code-ide-handover-tests--run-timers 3)
            (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
            (should-not claude-code-ide-handover-tests--starts))
        (when (process-live-p survivor) (delete-process survivor)))))
  ;; A retry of a target that ended scans first
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
      (claude-code-ide-handover-tests--run-timers 20)
      (let ((target (plist-get (claude-code-ide-handover-status id) :target-id)))
        (kill-buffer (claude-code-ide-instance-buffer (claude-code-ide-instance-by-id target))))
      (claude-code-ide-handover-tests--run-timers 3)
      (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'target-exited))
      (setq claude-code-ide-handover-tests--scan-strays
            '((:pid 5151 :command "sleep 900" :cwd "/x" :reason worktree))
            claude-code-ide-handover-tests--starts nil)
      (claude-code-ide-handover-resolve id 'retry)
      (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'strays))
      (should-not claude-code-ide-handover-tests--starts)
      ;; No writer left: the target starts again
      (setq claude-code-ide-handover-tests--scan-strays nil)
      (claude-code-ide-handover-resolve id 'wait)
      (claude-code-ide-handover-tests--run-timers 3)
      (should (= (length claude-code-ide-handover-tests--starts) 1)))))

(ert-deftest claude-code-ide-test-handover-waits-for-acknowledgements ()
  "The stop waits for the acknowledgement of a prompt that the source got.
A prompt without it moves to the target, with a note."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((drains 0))
      (cl-letf (((symbol-function 'claude-code-ide-session-status--drain)
                 (lambda () (cl-incf drains))))
        (should (claude-code-ide-control--record-sent-at
                 (car (claude-code-ide-control--pending-records
                       (progn (claude-code-ide-control-submit "cci-test-src" "cci-test-sent"
                                                              :request-id "s1")
                              "cci-test-src")))))
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)
                             :handover-id)))
          (claude-code-ide-handover-tests--run-timers 5)
          (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'quiescing))
          (should (> drains 0))
          (should-not claude-code-ide-handover-tests--stops)
          ;; The acknowledgement comes: the stop goes on
          (claude-code-ide-handover-tests--event "cci-test-src" 'prompt-submit
                                                 '((prompt . "cci-test-sent")))
          (claude-code-ide-handover-tests--run-timers 5)
          (should (equal claude-code-ide-handover-tests--stops '("cci-test-src")))))))
  ;; No acknowledgement in time: the prompt moves, with a note
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((claude-code-ide-handover-ack-wait 0))
      (cl-letf (((symbol-function 'claude-code-ide-session-status--drain) #'ignore))
        (claude-code-ide-control-submit "cci-test-src" "cci-test-sent" :request-id "s1")
        (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)))
          (claude-code-ide-handover-tests--run-timers 20)
          (let* ((target (claude-code-ide-handover-tests--deliver result))
                 (moved (car (claude-code-ide-control--pending-records target))))
            (should (equal (claude-code-ide-control--record-request-id moved) "s1"))
            (should (string-match-p "may have reached" (claude-code-ide-control--record-note moved)))
            (should (eq (claude-code-ide-control--record-result moved) 'queued))))))))

(ert-deftest claude-code-ide-test-handover-live-target-after-failure ()
  "A failed start with a live target: retry takes it up again, cancel stops it."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((stopped nil))
      (cl-letf* ((start (symbol-function 'claude-code-ide--start-session))
                 ((symbol-function 'claude-code-ide--start-session)
                  (lambda (&rest args)
                    (apply start args)
                    (error "cci-test start failed after the spawn")))
                 ((symbol-function 'claude-code-ide-process-stop)
                  (lambda (instance &rest _)
                    (push (claude-code-ide-instance-id instance) stopped)
                    (claude-code-ide-instance-unregister (claude-code-ide-instance-id instance))
                    '(:status stopped))))
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
          (claude-code-ide-handover-tests--run-timers 20)
          (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'start-failed))
          ;; Retry: no second start
          (claude-code-ide-handover-resolve id 'retry)
          (claude-code-ide-handover-tests--run-timers 3)
          (should (= (length claude-code-ide-handover-tests--starts) 1))
          (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'running))
          ;; The watch runs again for the target
          (should (claude-code-ide-handover--run-delivery-deadline
                   (gethash id claude-code-ide-handover--runs)))))
      ;; A new failure with a live target: the cancel stops it
      (claude-code-ide-handover-tests--add "cci-test-src2" 'cci-test-a
                                           (claude-code-ide-handover-tests--other "proj2") 'idle)
      (cl-letf* ((start (symbol-function 'claude-code-ide--start-session))
                 ((symbol-function 'claude-code-ide--start-session)
                  (lambda (&rest args)
                    (apply start args)
                    (error "cci-test start failed after the spawn")))
                 ((symbol-function 'claude-code-ide-process-stop)
                  (lambda (instance &rest _)
                    (push (claude-code-ide-instance-id instance) stopped)
                    (claude-code-ide-instance-unregister (claude-code-ide-instance-id instance))
                    '(:status stopped))))
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src2" 'cci-test-b) :handover-id)))
          (claude-code-ide-handover-tests--run-timers 20)
          (let ((target (plist-get (claude-code-ide-handover-status id) :target-id)))
            (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'start-failed))
            (claude-code-ide-handover-cancel id)
            (should (member target stopped))
            (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))))))))

(ert-deftest claude-code-ide-test-handover-stray-start-tolerance ()
  "The start time of a stray matches within the one second of the registry."
  (let ((signals nil))
    (cl-letf (((symbol-function 'process-attributes)
               (lambda (_pid) `((args . "sleep 600") (start . ,(seconds-to-time 1000.5)))))
              ((symbol-function 'signal-process)
               (lambda (pid signal) (push (list pid signal) signals) 0)))
      (claude-code-ide-handover--end-strays '((:pid 5252 :start 1000.0)) 'SIGTERM)
      (should (equal signals '((5252 SIGTERM))))
      (setq signals nil)
      (claude-code-ide-handover--end-strays '((:pid 5252 :start 1002.0)) 'SIGTERM)
      (should-not signals))))

(ert-deftest claude-code-ide-test-handover-inbox-collision-and-redirect ()
  "A request ID that the target has already moves under a new ID; nothing is dropped.
After the commit, a prompt for the source goes to the target."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (claude-code-ide-control-submit "cci-test-src" "cci-test-for-source" :request-id "q1")
    (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :force t)))
      (claude-code-ide-handover-tests--set-state "cci-test-src" 'idle)
      (claude-code-ide-handover-tests--run-timers 20)
      (let* ((id (plist-get result :handover-id))
             (target (plist-get (claude-code-ide-handover-status id) :target-id))
             (renamed (format "handover:%s:q1" id)))
        ;; The target has its own q1 before the commit
        (claude-code-ide-control-submit target "cci-test-for-target" :request-id "q1")
        (claude-code-ide-handover-tests--deliver result)
        (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
        (let ((copy (claude-code-ide-control--find-record target renamed))
              (old (claude-code-ide-control--find-record "cci-test-src" "q1")))
          (should copy)
          (should (equal (claude-code-ide-control--record-text copy) "cci-test-for-source"))
          (should (equal (claude-code-ide-control--record-moved-from copy) "cci-test-src:q1"))
          (should (equal (claude-code-ide-control--record-moved-to old) (concat target ":" renamed)))
          (should (equal (claude-code-ide-control--record-text
                          (claude-code-ide-control--find-record target "q1"))
                         "cci-test-for-target")))
        ;; A second move moves nothing again
        (should-not (claude-code-ide-control-move-inbox "cci-test-src" target id))
        ;; A prompt for the old instance goes to the current one
        (let ((submit (claude-code-ide-control-submit "cci-test-src" "cci-test-late" :request-id "q2")))
          (should (equal (plist-get submit :destination) target))
          (should (claude-code-ide-control--find-record target "q2")))))))

(ert-deftest claude-code-ide-test-handover-missing-entry-needs-user ()
  "A missing registry entry gives needs-user, never an endless retry."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
      (claude-code-ide-session-registry--submit
       "forget" (claude-code-ide-session-registry--change-forgotten "cci-test-src"))
      (should (< (claude-code-ide-handover-tests--run-timers 50) 50))
      (let ((run (gethash id claude-code-ide-handover--runs)))
        (should (eq (claude-code-ide-handover--run-status run) 'needs-user))
        (should (eq (claude-code-ide-handover--run-reason run) 'registry-entry-missing))))))

;;; The target continues after the commit

(defun claude-code-ide-handover-tests--continue-records (target id)
  "Return the inbox records of TARGET with the continue request ID of handover ID.
Pending and final records both count."
  (let ((request-id (concat "handover-continue:" id)))
    (append
     (cl-remove-if-not (lambda (record)
                         (equal (claude-code-ide-control--record-request-id record) request-id))
                       (claude-code-ide-control--pending-records target))
     (let ((status (claude-code-ide-control-request-status target request-id)))
       (and (not (eq (plist-get status :status) 'error))
            (not (eq (plist-get status :result) 'queued))
            (list status))))))

(ert-deftest claude-code-ide-test-handover-continue-coordinator ()
  "A coordinator call never asks.  :continue wins; without it, `ask' counts as `always'."
  (dolist (case '((ask none t) (always none t) (never none nil)
                  (ask nil nil) (ask t t) (always nil nil) (never t t)))
    (claude-code-ide-handover-tests--with
      (let ((claude-code-ide-handover-continue (nth 0 case)))
        (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
        (cl-letf (((symbol-function 'read-multiple-choice)
                   (lambda (&rest _) (error "A coordinator call never asks"))))
          (let* ((result (apply #'claude-code-ide-handover-session "cci-test-src" 'cci-test-b
                                (unless (eq (nth 1 case) 'none) (list :continue (nth 1 case)))))
                 (id (plist-get result :handover-id)))
            (should (eq (plist-get result :status) 'running))
            (should (eq (plist-get (claude-code-ide-handover-status id) :continue) (nth 2 case)))
            ;; The registry record keeps the decision for a recovery
            (should (eq (alist-get 'continue (claude-code-ide-handover-tests--record "cci-test-src"))
                        (nth 2 case)))))))))

(ert-deftest claude-code-ide-test-handover-continue-prompt-at-commit ()
  "With :continue t, the commit sends the target one prompt through its inbox.
With :continue nil, nothing goes to the target after the document."
  (dolist (continue '(t nil))
    (claude-code-ide-handover-tests--with
      (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
      (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue continue))
             (id (plist-get result :handover-id)))
        (claude-code-ide-handover-tests--run-timers)
        ;; Before the commit: no continue prompt
        (let ((target (plist-get (claude-code-ide-handover-status id) :target-id)))
          (should (stringp target))
          (should-not (claude-code-ide-handover-tests--continue-records target id)))
        (let ((target (claude-code-ide-handover-tests--deliver result)))
          (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
          (let ((records (claude-code-ide-handover-tests--continue-records target id)))
            (if (not continue)
                (should-not records)
              (should (= (length records) 1))
              (let ((record (car records)))
                (should (string-match-p "state summary"
                                        (claude-code-ide-control--record-text record)))
                ;; The inbox rules: the target is busy, so the prompt waits
                (should (eq (plist-get (claude-code-ide-control-request-status
                                        target (concat "handover-continue:" id))
                                       :result)
                            'queued))))))))))

(ert-deftest claude-code-ide-test-handover-continue-once-after-recovery ()
  "A recovery that commits sends the continue prompt at most once.
The first Emacs may have sent it before the crash: the fixed request ID
makes the second submit a duplicate."
  (dolist (sent-before '(nil t))
    (claude-code-ide-handover-tests--with
      (let* ((id (claude-code-ide-handover-tests--interrupted 'committed
                                                              :target-native "cci-test-tgt-native"
                                                              :continue t))
             (request-id (concat "handover-continue:" id)))
        (when sent-before
          ;; The first Emacs sent it, and ended before its final save
          (claude-code-ide-control-submit "cci-test-tgt" "cci-test sent before the crash"
                                          :request-id request-id :queue t))
        (claude-code-ide-handover-recover)
        (claude-code-ide-handover-tests--run-timers)
        (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
        (should (= (length (claude-code-ide-handover-tests--continue-records "cci-test-tgt" id)) 1))
        ;; A second recovery has nothing to do, and sends nothing
        (should-not (claude-code-ide-handover-recover))
        (claude-code-ide-handover-tests--run-timers)
        (should (= (length (claude-code-ide-handover-tests--continue-records "cci-test-tgt" id)) 1))))))

(ert-deftest claude-code-ide-test-handover-continue-not-after-failure-or-cancel ()
  "A handover that does not commit sends no continue prompt."
  ;; The target does not start: needs-user, then cancel
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((claude-code-ide-handover-tests--start-fails t)
           (result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
           (id (plist-get result :handover-id)))
      (claude-code-ide-handover-tests--run-timers)
      (let ((status (claude-code-ide-handover-status id)))
        (should (eq (plist-get status :status) 'needs-user))
        (should (eq (plist-get status :reason) 'start-failed))
        (should-not (claude-code-ide-handover-tests--continue-records (plist-get status :target-id) id)))
      (claude-code-ide-handover-cancel id)
      (let ((status (claude-code-ide-handover-status id)))
        (should (eq (plist-get status :status) 'cancelled))
        (should-not (claude-code-ide-handover-tests--continue-records (plist-get status :target-id) id)))))
  ;; Cancelled while it waits for a busy source: no target at all
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
           (id (plist-get result :handover-id)))
      (claude-code-ide-handover-tests--run-timers 5)
      (claude-code-ide-handover-cancel id)
      (claude-code-ide-handover-tests--run-timers)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
      (should-not (plist-get (claude-code-ide-handover-status id) :target-id))
      (should-not claude-code-ide-handover-tests--sent))))

(ert-deftest claude-code-ide-test-handover-method-question ()
  "The method question: RET and f fork, n starts a new conversation.
Any other key is refused, and the question asks again."
  (dolist (case '(("\r" fork) ("f" fork) ("n" fresh) ("xzn" fresh) ("x\r" fork)))
    (let ((unread-command-events (listify-key-sequence (car case))))
      (should (eq (claude-code-ide-handover--read-method 'claude) (nth 1 case)))
      (should-not unread-command-events))))

(ert-deftest claude-code-ide-test-handover-method-question-text ()
  "The method question names the target provider and says what each choice means."
  (let (prompt keys)
    (cl-letf (((symbol-function 'read-multiple-choice)
               (lambda (text choices &rest _)
                 (setq prompt text keys (mapcar #'car choices))
                 (assq ?\r choices))))
      (should (eq (claude-code-ide-handover--read-method 'claude) 'fork)))
    (should (equal keys '(?f ?n ?\r)))
    (should (string-match-p "Claude Code" prompt))
    (should (string-match-p "full history" prompt))
    (should (string-match-p "only the handover document" prompt))))

(ert-deftest claude-code-ide-test-handover-continue-question ()
  "With `ask', the interactive question gives y, n, a or v; a and v save the option.
With `always' or `never', nothing is asked."
  (dolist (case '((?y yes nil) (?n no nil) (?a yes always) (?v no never)))
    (let ((claude-code-ide-handover-continue 'ask)
          (saved nil)
          (asked 0))
      (cl-letf (((symbol-function 'read-multiple-choice)
                 (lambda (_prompt choices &rest _)
                   (setq asked (1+ asked))
                   (should (equal (mapcar #'car choices) '(?y ?n ?a ?v)))
                   (assq (nth 0 case) choices)))
                ((symbol-function 'customize-save-variable)
                 (lambda (symbol value &rest _)
                   (push (list symbol value) saved)
                   (set symbol value))))
        (should (eq (claude-code-ide-handover--read-continue) (nth 1 case)))
        (should (= asked 1))
        (if (nth 2 case)
            (progn
              (should (equal saved `((claude-code-ide-handover-continue ,(nth 2 case)))))
              (should (eq claude-code-ide-handover-continue (nth 2 case))))
          (should-not saved)
          (should (eq claude-code-ide-handover-continue 'ask))))))
  (cl-letf (((symbol-function 'read-multiple-choice)
             (lambda (&rest _) (error "No question expected")))
            ((symbol-function 'customize-save-variable)
             (lambda (&rest _) (error "No save expected"))))
    (let ((claude-code-ide-handover-continue 'always))
      (should (eq (claude-code-ide-handover--read-continue) 'yes)))
    (let ((claude-code-ide-handover-continue 'never))
      (should (eq (claude-code-ide-handover--read-continue) 'no))))
  ;; A save that fails still keeps the answer in this Emacs
  (let ((claude-code-ide-handover-continue 'ask))
    (cl-letf (((symbol-function 'read-multiple-choice)
               (lambda (_prompt choices &rest _) (assq ?a choices)))
              ((symbol-function 'customize-save-variable)
               (lambda (&rest _) (error "cci-test: no custom file")))
              ((symbol-function 'message) #'ignore))
      (should (eq (claude-code-ide-handover--read-continue) 'yes))
      (should (eq claude-code-ide-handover-continue 'always)))))

(ert-deftest claude-code-ide-test-handover-continue-interactive ()
  "The interactive handover asks with its other questions, and passes the answer.
The command gives :continue t for `yes', nil for `no', and no key when
its CONTINUE is nil (a call from Lisp, such as an agent's request)."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((questions nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt &rest _) (push prompt questions) "cci-test-b"))
                ((symbol-function 'read-string)
                 (lambda (prompt &rest _) (push prompt questions) ""))
                ((symbol-function 'claude-code-ide-handover--read-continue)
                 (lambda () (push 'continue questions) 'no)))
        (let ((args (claude-code-ide-handover--read-args "cci-test-src")))
          ;; CONTINUE, before ALLOW-OTHERS
          (should (eq (nth 6 args) 'no))
          ;; The question comes with the others, before the handover starts
          (should (memq 'continue questions))
          (should (= (hash-table-count claude-code-ide-handover--runs) 0))))))
  (let ((calls nil))
    (cl-letf (((symbol-function 'claude-code-ide-handover-session)
               (lambda (&rest args) (push args calls) (list :status 'running :handover-id "h")))
              ((symbol-function 'message) #'ignore))
      (claude-code-ide-handover "cci-test-src" 'cci-test-b 'fresh nil nil nil 'yes)
      (claude-code-ide-handover "cci-test-src" 'cci-test-b 'fresh nil nil nil 'no)
      (claude-code-ide-handover "cci-test-src" 'cci-test-b)
      (let ((calls (reverse calls)))
        (should (eq (plist-get (nthcdr 2 (nth 0 calls)) :continue) t))
        (should (plist-member (nthcdr 2 (nth 1 calls)) :continue))
        (should-not (plist-get (nthcdr 2 (nth 1 calls)) :continue))
        (should-not (plist-member (nthcdr 2 (nth 2 calls)) :continue))
        (should (plist-get (nthcdr 2 (nth 0 calls)) :interactive))))))

(ert-deftest claude-code-ide-test-handover-continue-mcp-tool ()
  "The MCP handover tool passes continue only when it is given; the schema has it."
  (let ((calls nil))
    (cl-letf (((symbol-function 'claude-code-ide-control-call)
               (lambda (&rest args) (push args calls) (list :status 'running))))
      (claude-code-ide-handover--mcp-handover "cci-test-src" "codex")
      (claude-code-ide-handover--mcp-handover "cci-test-src" "codex" nil nil nil nil nil t)
      (claude-code-ide-handover--mcp-handover "cci-test-src" "codex" nil nil nil nil nil :json-false)
      ;; The default false of `json-parse-string' counts as false too
      (should-not (claude-code-ide-handover--flag :false))
      (should-not (claude-code-ide-handover--flag :json-false))
      (should (claude-code-ide-handover--flag t))
      (let ((calls (reverse calls)))
        (should-not (plist-member (nthcdr 3 (nth 0 calls)) :continue))
        (should (eq (plist-get (nthcdr 3 (nth 1 calls)) :continue) t))
        (should (plist-member (nthcdr 3 (nth 2 calls)) :continue))
        (should-not (plist-get (nthcdr 3 (nth 2 calls)) :continue)))))
  (let* ((spec (cl-find "claude-code-ide-control-handover" claude-code-ide-control--extra-tool-specs
                        :key (lambda (s) (plist-get s :name)) :test #'equal))
         (arg (cl-find "continue" (plist-get spec :args)
                       :key (lambda (a) (plist-get a :name)) :test #'equal)))
    (should arg)
    (should (eq (plist-get arg :type) 'boolean))
    (should (plist-get arg :optional))))

(ert-deftest claude-code-ide-test-handover-continue-submit-fails ()
  "A continue prompt that the inbox does not accept keeps the handover recoverable.
A submit that signals an error, and one that the inbox rejects, both
leave the stage committed with the status needs-user and the reason
continue-failed.  A retry, or a recovery after a crash, then sends the
prompt with the same request ID, and the handover finishes."
  (dolist (failure '(error rejected))
    (dolist (repair '(retry recovery))
      (claude-code-ide-handover-tests--with
        (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
        (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
               (id (plist-get result :handover-id))
               (submit (symbol-function 'claude-code-ide-control-submit))
               target)
          (claude-code-ide-handover-tests--run-timers)
          (cl-letf (((symbol-function 'claude-code-ide-control-submit)
                     (lambda (instance-id text &rest keys)
                       (if (string-prefix-p "handover-continue:" (or (plist-get keys :request-id) ""))
                           (if (eq failure 'error)
                               (error "cci-test: the inbox cannot be written")
                             (list :destination instance-id :request-id (plist-get keys :request-id)
                                   :result 'rejected :reason 'cci-test-refused))
                         (apply submit instance-id text keys)))))
            (setq target (claude-code-ide-handover-tests--deliver result)))
          (let ((status (claude-code-ide-handover-status id)))
            (should (eq (plist-get status :status) 'needs-user))
            (should (eq (plist-get status :reason) 'continue-failed))
            (should (eq (plist-get status :stage) 'committed))
            (should (plist-get status :message)))
          ;; The chain of the target is saved, but the handover is not
          ;; final, so `chain-current' does not follow it yet
          (should-not (plist-get (car (last (claude-code-ide-session-registry-entry-legs
                                             (claude-code-ide-session-registry-entry-of target))))
                                 :pending))
          (should-not (claude-code-ide-session-registry-chain-current "cci-test-src"))
          (should-not (claude-code-ide-handover-tests--continue-records target id))
          (pcase repair
            ('retry (claude-code-ide-handover-resolve id 'retry))
            ('recovery
             ;; The crash: this Emacs forgets the run
             (clrhash claude-code-ide-handover--runs)
             (claude-code-ide-handover-recover)))
          (claude-code-ide-handover-tests--run-timers)
          (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
          (should (equal (claude-code-ide-session-registry-chain-current "cci-test-src") target))
          (should (= (length (claude-code-ide-handover-tests--continue-records target id)) 1)))))))

(ert-deftest claude-code-ide-test-handover-continue-failed-choices ()
  "A handover whose continue prompt failed offers retry and skip, never a cancel.
The chain is committed, so a cancel would stop the new current instance.
Skip finishes without the prompt."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
           (id (plist-get result :handover-id))
           (submit (symbol-function 'claude-code-ide-control-submit))
           target)
      (claude-code-ide-handover-tests--run-timers)
      (cl-letf (((symbol-function 'claude-code-ide-control-submit)
                 (lambda (instance-id text &rest keys)
                   (if (string-prefix-p "handover-continue:" (or (plist-get keys :request-id) ""))
                       (error "cci-test: the inbox cannot be written")
                     (apply submit instance-id text keys)))))
        (setq target (claude-code-ide-handover-tests--deliver result)))
      (let ((run (gethash id claude-code-ide-handover--runs)))
        (should (equal (mapcar #'cadr (claude-code-ide-handover--choices run)) '(retry skip))))
      (should-error (claude-code-ide-handover-resolve id 'cancel) :type 'user-error)
      (should-error (claude-code-ide-handover-cancel id) :type 'user-error)
      (claude-code-ide-handover-resolve id 'skip)
      (let ((status (claude-code-ide-handover-status id)))
        (should (eq (plist-get status :status) 'committed))
        (should-not (plist-get status :continue)))
      (should-not (claude-code-ide-handover-tests--continue-records target id))
      (should (claude-code-ide-instance-by-id target)))))

(ert-deftest claude-code-ide-test-handover-continue-sent-flag ()
  "After the inbox accepts the continue prompt, the record says so (continue_sent).
A later commit (for example a recovery after the inbox pruned its done
records) sends nothing again."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
           (id (plist-get result :handover-id)))
      (claude-code-ide-handover-tests--run-timers)
      (let ((target (claude-code-ide-handover-tests--deliver result)))
        (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
        (should (eq (alist-get 'continue_sent (claude-code-ide-handover-tests--record "cci-test-src")) t))
        ;; The record gives the flag back
        (let ((run (cl-find id (claude-code-ide-handover--registry-runs)
                            :key #'claude-code-ide-handover--run-id :test #'equal)))
          (should (claude-code-ide-handover--run-continue-sent run))
          ;; The inbox forgot the request (pruned); a commit of this run
          ;; again, as a recovery would do, sends nothing
          (delete-directory (claude-code-ide-control-inbox-directory-of target) t)
          (clrhash claude-code-ide-control--index)
          (setf (claude-code-ide-handover--run-status run) 'running)
          (cl-letf (((symbol-function 'claude-code-ide-control-submit)
                     (lambda (&rest _) (error "No second continue prompt expected"))))
            (claude-code-ide-handover--commit run))
          (should (eq (claude-code-ide-handover--run-status run) 'committed)))))))

(ert-deftest claude-code-ide-test-handover-continue-sent-saved-before-finish ()
  "continue_sent is saved right after the inbox takes the prompt, before the final save.
A crash between the two, then a prune of the inbox, then a recovery of
the interrupted handover: no second prompt."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
           (id (plist-get result :handover-id))
           target)
      (claude-code-ide-handover-tests--run-timers)
      (setq target (plist-get (claude-code-ide-handover-status id) :target-id))
      ;; The crash comes right before the final save of the commit
      (cl-letf (((symbol-function 'claude-code-ide-handover--finish)
                 (lambda (&rest _) (throw 'cci-test-crash t))))
        (should (catch 'cci-test-crash (claude-code-ide-handover-tests--deliver result) nil)))
      (let ((record (claude-code-ide-handover-tests--record "cci-test-src")))
        (should (equal (alist-get 'stage record) "committed"))
        (should (equal (alist-get 'status record) "running"))
        (should (eq (alist-get 'continue_sent record) t)))
      ;; This Emacs ends; later the inbox prunes the done record
      (clrhash claude-code-ide-handover--runs)
      (delete-directory (claude-code-ide-control-inbox-directory-of target) t)
      (clrhash claude-code-ide-control--index)
      (cl-letf (((symbol-function 'claude-code-ide-control-submit)
                 (lambda (&rest _) (error "No second continue prompt expected"))))
        (claude-code-ide-handover-recover)
        (claude-code-ide-handover-tests--run-timers))
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed)))))

(ert-deftest claude-code-ide-test-handover-commit-target-entry-missing ()
  "A missing target entry at the chain save leaves the chain unsaved; cancel works.
The commit tells apart the stage committed and the saved chain of the
target, so a cancel is refused only after the chain is saved."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
           (id (plist-get result :handover-id))
           target)
      (claude-code-ide-handover-tests--run-timers)
      (setq target (plist-get (claude-code-ide-handover-status id) :target-id))
      ;; The target entry is gone when the commit saves its chain
      (cl-letf (((symbol-function 'claude-code-ide-session-registry-save-chain)
                 (lambda (&rest _) :missing)))
        (claude-code-ide-handover-tests--deliver result))
      (let ((status (claude-code-ide-handover-status id)))
        (should (eq (plist-get status :status) 'needs-user))
        (should (eq (plist-get status :reason) 'registry-entry-missing))
        (should (eq (plist-get status :stage) 'committed)))
      (let ((run (gethash id claude-code-ide-handover--runs)))
        (should (equal (mapcar #'cadr (claude-code-ide-handover--choices run)) '(cancel)))
        (should-not (claude-code-ide-handover-tests--continue-records target id))
        ;; The one choice works
        (claude-code-ide-handover-resolve id 'cancel)
        (claude-code-ide-handover-tests--run-timers)
        (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
        (should-not (claude-code-ide-handover-tests--continue-records target id))
        (should-not (claude-code-ide-handover--run-chain-saved run))))))

(ert-deftest claude-code-ide-test-handover-commit-failed-after-chain ()
  "A step that fails after the chain save offers retry and skip, and both work."
  (dolist (choice '(retry skip))
    (claude-code-ide-handover-tests--with
      (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
      (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
             (id (plist-get result :handover-id))
             target)
        (claude-code-ide-handover-tests--run-timers)
        (setq target (plist-get (claude-code-ide-handover-status id) :target-id))
        ;; The inbox move fails once, after the chain save
        (cl-letf (((symbol-function 'claude-code-ide-control-move-inbox)
                   (lambda (&rest _) (error "cci-test: the move failed"))))
          (claude-code-ide-handover-tests--deliver result))
        (let ((run (gethash id claude-code-ide-handover--runs))
              (status (claude-code-ide-handover-status id)))
          (should (eq (plist-get status :status) 'needs-user))
          (should (eq (plist-get status :reason) 'step-failed))
          (should (eq (plist-get status :stage) 'committed))
          ;; The chain is saved: retry and skip, no cancel
          (should (equal (mapcar #'cadr (claude-code-ide-handover--choices run)) '(retry skip)))
          (should-error (claude-code-ide-handover-cancel id) :type 'user-error)
          (should (claude-code-ide-handover--run-chain-saved run)))
        (claude-code-ide-handover-resolve id choice)
        (claude-code-ide-handover-tests--run-timers)
        (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
        (should (equal (claude-code-ide-session-registry-chain-current "cci-test-src") target))
        (should (= (length (claude-code-ide-handover-tests--continue-records target id))
                   (if (eq choice 'retry) 1 0)))))))

(ert-deftest claude-code-ide-test-handover-skip-without-source-entry ()
  "After the chain save, skip works even when the record cannot be saved any more.
The source entry is gone, so each save gives registry-entry-missing;
skip then ends the run in this Emacs as committed."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
           (id (plist-get result :handover-id)))
      (claude-code-ide-handover-tests--run-timers)
      (cl-letf (((symbol-function 'claude-code-ide-control-move-inbox)
                 (lambda (&rest _) (error "cci-test: the move failed"))))
        (claude-code-ide-handover-tests--deliver result))
      (let ((run (gethash id claude-code-ide-handover--runs)))
        (should (claude-code-ide-handover--run-chain-saved run))
        (cl-letf (((symbol-function 'claude-code-ide-session-registry-save-handover)
                   (lambda (&rest _) :missing))
                  ((symbol-function 'message) #'ignore))
          ;; Retry cannot save; the choices stay retry and skip
          (claude-code-ide-handover-resolve id 'retry)
          (should (eq (claude-code-ide-handover--run-status run) 'needs-user))
          (should (eq (claude-code-ide-handover--run-reason run) 'registry-entry-missing))
          (should (equal (mapcar #'cadr (claude-code-ide-handover--choices run)) '(retry skip)))
          ;; Skip while the inbox cannot move: no end, the queued
          ;; prompts would stay in the source inbox
          (cl-letf (((symbol-function 'claude-code-ide-control-move-inbox)
                     (lambda (&rest _) (error "cci-test: the move failed"))))
            (claude-code-ide-handover-resolve id 'skip))
          (should (claude-code-ide-handover--unfinished-p run))
          ;; Skip ends it in this Emacs once the inbox moved
          (claude-code-ide-handover-resolve id 'skip)
          (should (eq (claude-code-ide-handover--run-status run) 'committed)))))))

(ert-deftest claude-code-ide-test-handover-cancel-after-chain-save-crash ()
  "A crash right after the chain save, before the chain_saved flag: a cancel is refused.
The target already has its final chain with this handover, so a direct
cancel must not stop it or archive its entry.  The choices and the
recovery read the saved chain too."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
           (id (plist-get result :handover-id))
           target)
      (claude-code-ide-handover-tests--run-timers)
      (setq target (plist-get (claude-code-ide-handover-status id) :target-id))
      ;; The crash comes right after the chain save, before its flag
      (cl-letf (((symbol-function 'claude-code-ide-handover--mark-chain-saved)
                 (lambda (&rest _) (throw 'cci-test-crash t))))
        (should (catch 'cci-test-crash (claude-code-ide-handover-tests--deliver result) nil)))
      (should-not (alist-get 'chain_saved (claude-code-ide-handover-tests--record "cci-test-src")))
      (let ((leg (car (last (claude-code-ide-session-registry-entry-legs
                             (claude-code-ide-session-registry-entry-of target))))))
        (should (equal (plist-get leg :handover-id) id))
        (should-not (plist-get leg :pending)))
      ;; This Emacs ends; the target CLI ends with it
      (clrhash claude-code-ide-handover--runs)
      (claude-code-ide-instance-unregister target)
      (setq claude-code-ide-handover-tests--stops nil)
      (should-error (claude-code-ide-handover-cancel id) :type 'user-error)
      (should-not claude-code-ide-handover-tests--stops)
      (should-not (eq (claude-code-ide-session-registry-entry-state
                       (claude-code-ide-session-registry-entry-of target))
                      'archived))
      (should-not (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
      ;; The choices see the saved chain
      (let ((run (claude-code-ide-handover--find id)))
        (should (equal (mapcar #'cadr (claude-code-ide-handover--choices run)) '(retry skip))))
      ;; The recovery finishes the commit
      (clrhash claude-code-ide-handover--runs)
      (claude-code-ide-handover-recover)
      (claude-code-ide-handover-tests--run-timers)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
      (should (equal (claude-code-ide-session-registry-chain-current "cci-test-src") target)))))

(ert-deftest claude-code-ide-test-handover-skip-waits-for-inbox-move ()
  "Skip turns off only the continue prompt: the run finishes only after the inbox moved.
A queued prompt of the source must reach the target, so a skip while
the move fails keeps the handover waiting for a person."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (should (eq (plist-get (claude-code-ide-control-submit "cci-test-src" "cci-test-one"
                                                           :request-id "q1")
                           :result)
                'queued))
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :force t :continue t))
           (id (plist-get result :handover-id))
           target)
      (claude-code-ide-handover-tests--set-state "cci-test-src" 'idle)
      (claude-code-ide-handover-tests--run-timers)
      (setq target (plist-get (claude-code-ide-handover-status id) :target-id))
      (cl-letf (((symbol-function 'claude-code-ide-control-move-inbox)
                 (lambda (&rest _) (error "cci-test: the move failed"))))
        (claude-code-ide-handover-tests--deliver result)
        (let ((status (claude-code-ide-handover-status id)))
          (should (eq (plist-get status :status) 'needs-user))
          (should (eq (plist-get status :reason) 'step-failed))
          (should (string-match-p "did not move to the target" (plist-get status :message)))
          (should (eq (plist-get status :stage) 'committed)))
        ;; Skip while the move still fails: no finish
        (claude-code-ide-handover-resolve id 'skip)
        (claude-code-ide-handover-tests--run-timers)
        (let ((status (claude-code-ide-handover-status id)))
          (should (eq (plist-get status :status) 'needs-user))
          (should (eq (plist-get status :reason) 'step-failed))
          (should (string-match-p "did not move to the target" (plist-get status :message)))
          (should (string-match-p "cci-test: the move failed" (plist-get status :message))))
        (should (equal (mapcar #'claude-code-ide-control--record-request-id
                               (claude-code-ide-control--pending-records "cci-test-src"))
                       '("q1"))))
      ;; The move works again: skip finishes, and the prompt is in the target inbox
      (claude-code-ide-handover-resolve id 'skip)
      (claude-code-ide-handover-tests--run-timers)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
      (should (equal (mapcar #'claude-code-ide-control--record-request-id
                             (claude-code-ide-control--pending-records target))
                     '("q1")))
      (should-not (claude-code-ide-control--pending-records "cci-test-src")))))

(ert-deftest claude-code-ide-test-handover-skip-target-entry-missing ()
  "A missing target entry after the chain save stays recoverable; skip does not end it.
The fallback of skip that ends a run in this Emacs is only for a source
record that cannot be saved.  With the source entry there, the record
says needs-user, its message names the target, and this Emacs counts
the run unfinished too, so the worktree hold and the record agree."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :continue t))
           (id (plist-get result :handover-id))
           target)
      (claude-code-ide-handover-tests--run-timers)
      (setq target (plist-get (claude-code-ide-handover-status id) :target-id))
      ;; The chain saves, then the inbox move fails
      (cl-letf (((symbol-function 'claude-code-ide-control-move-inbox)
                 (lambda (&rest _) (error "cci-test: the move failed"))))
        (claude-code-ide-handover-tests--deliver result))
      (let ((run (gethash id claude-code-ide-handover--runs)))
        (should (claude-code-ide-handover--run-chain-saved run))
        ;; The target entry is gone now; the source entry stays
        (cl-letf (((symbol-function 'claude-code-ide-session-registry-save-chain)
                   (lambda (&rest _) :missing)))
          (claude-code-ide-handover-resolve id 'skip))
        (claude-code-ide-handover-tests--run-timers)
        (should (claude-code-ide-session-registry-entry-of "cci-test-src"))
        ;; Not ended in memory only
        (should (claude-code-ide-handover--unfinished-p run))
        (should (eq (claude-code-ide-handover--run-status run) 'needs-user))
        (should (eq (claude-code-ide-handover--run-reason run) 'registry-entry-missing))
        (should (string-match-p (regexp-quote target) (claude-code-ide-handover--run-message run)))
        (should-not (string-match-p "entry of the source" (claude-code-ide-handover--run-message run)))
        ;; The record agrees: unfinished, so the hold of the worktree is
        ;; one that this Emacs counts as unfinished too
        (should (equal (alist-get 'status (claude-code-ide-handover-tests--record "cci-test-src"))
                       "needs-user"))
        (should (eq (claude-code-ide-handover--holding-run worktree) run))
        ;; The queued prompts of the source did not move by the skip
        (should-not (claude-code-ide-handover--run-continue-sent run))))))

(ert-deftest claude-code-ide-test-handover-retry-commit-before-chain-save ()
  "A step failure at the commit before the chain save: retry runs the commit again.
The target runs and the stage is committed.  The delivery watch does
nothing at that stage, so a retry that only watches never commits."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b))
           (id (plist-get result :handover-id))
           target)
      (claude-code-ide-handover-tests--run-timers)
      (setq target (plist-get (claude-code-ide-handover-status id) :target-id))
      (cl-letf (((symbol-function 'claude-code-ide-session-registry-save-chain)
                 (lambda (&rest _) (error "cci-test: the chain save failed"))))
        (claude-code-ide-handover-tests--deliver result))
      (let ((run (gethash id claude-code-ide-handover--runs))
            (status (claude-code-ide-handover-status id)))
        (should (eq (plist-get status :status) 'needs-user))
        (should (eq (plist-get status :reason) 'step-failed))
        (should (eq (plist-get status :stage) 'committed))
        (should-not (claude-code-ide-handover--sync-chain-saved run))
        (should (claude-code-ide-handover--live-target run)))
      (claude-code-ide-handover-resolve id 'retry)
      (claude-code-ide-handover-tests--run-timers)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
      (should (equal (claude-code-ide-session-registry-chain-current "cci-test-src") target)))))

(defun claude-code-ide-handover-tests--close-entry (key)
  "Close the registry entry KEY, as the end of its CLI does."
  (claude-code-ide-session-registry--submit
   "test" (claude-code-ide-session-registry--change-closed (list key) 'cci-test)))

(ert-deftest claude-code-ide-test-handover-submit-to-stopped-source-queues ()
  "A default submit to the stopped source of an unfinished handover queues.
The commit then moves it to the target.  A recovery holds the source
again, so a submit after a restart of Emacs queues too."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((result (cl-letf* ((stop (symbol-function 'claude-code-ide-process-stop-later))
                              ((symbol-function 'claude-code-ide-process-stop-later)
                               (lambda (instance &rest args)
                                 (claude-code-ide-handover-tests--close-entry
                                  (claude-code-ide-instance-id instance))
                                 (apply stop instance args))))
                     (prog1 (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)
                       (claude-code-ide-handover-tests--run-timers))))
           (id (plist-get result :handover-id)))
      (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started))
      (should (eq (claude-code-ide-control-state-of "cci-test-src") 'stopped))
      (let ((submit (claude-code-ide-control-submit "cci-test-src" "cci-test-late"
                                                    :request-id "late")))
        (should (eq (plist-get submit :result) 'queued))
        (should (eq (plist-get submit :reason) 'held)))
      ;; QUEUE nil still rejects
      (should (eq (plist-get (claude-code-ide-control-submit "cci-test-src" "cci-test-never"
                                                             :request-id "never" :queue nil)
                             :result)
                  'rejected))
      (let ((target (claude-code-ide-handover-tests--deliver result)))
        (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
        (should (equal (mapcar #'claude-code-ide-control--record-request-id
                               (claude-code-ide-control--pending-records target))
                       '("late"))))))
  ;; After a crash: the recovery holds the source again
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'target-started)))
      (claude-code-ide-handover-tests--close-entry "cci-test-src")
      (setq claude-code-ide-control--held nil)
      (claude-code-ide-handover-recover)
      (should (claude-code-ide-handover--unfinished-p (claude-code-ide-handover--find id)))
      (should (claude-code-ide-control-held-p "cci-test-src"))
      (should (eq (plist-get (claude-code-ide-control-submit "cci-test-src" "cci-test-late"
                                                             :request-id "late")
                             :result)
                  'queued)))))

(defun claude-code-ide-handover-tests--user-turn-transcript (file text time)
  "Write a CC transcript FILE with one user turn TEXT at the ISO 8601 TIME."
  (with-temp-file file
    (insert (json-encode `((type . "user") (sessionId . "cci-test-src-native")
                           (timestamp . ,time)
                           (message . ((role . "user") (content . ,text))))))
    (insert "\n")))

(ert-deftest claude-code-ide-test-handover-sent-prompt-in-source-transcript ()
  "A sent prompt that the source transcript holds is delivered, not moved.
Only a user turn with the same text after the send counts."
  (dolist (case '((after . delivered) (before . moved)))
    (claude-code-ide-handover-tests--with
      (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
      (let ((claude-code-ide-handover-ack-wait 0)
            (file (expand-file-name "src.jsonl" claude-code-ide-handover-tests--root)))
        (cl-letf (((symbol-function 'claude-code-ide-session-status--drain) #'ignore))
          (claude-code-ide-control-submit "cci-test-src" "cci-test-sent" :request-id "s1")
          (claude-code-ide-handover-tests--user-turn-transcript
           file "cci-test-sent"
           (format-time-string "%Y-%m-%dT%H:%M:%S.%3NZ"
                               (if (eq (car case) 'after)
                                   (time-add nil 1)
                                 (time-subtract nil 3600))
                               t))
          (push (cons "cci-test-src" file) claude-code-ide-handover-tests--transcripts)
          (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b))
                 (_ (claude-code-ide-handover-tests--run-timers 20))
                 (target (claude-code-ide-handover-tests--deliver result))
                 (old (claude-code-ide-control-request-status "cci-test-src" "s1")))
            (should (eq (plist-get (claude-code-ide-handover-status (plist-get result :handover-id))
                                   :status)
                        'committed))
            (if (eq (cdr case) 'delivered)
                (progn
                  (should (eq (plist-get old :result) 'delivered))
                  (should-not (claude-code-ide-control--pending-records target)))
              (should (eq (plist-get old :reason) 'handed-over))
              (should (equal (mapcar #'claude-code-ide-control--record-request-id
                                     (claude-code-ide-control--pending-records target))
                             '("s1"))))))))))

(ert-deftest claude-code-ide-test-handover-strays-of-other-instances ()
  "A process of another live instance in the worktree is not a stray of the source.
A handover with :allow-others or :force has such an instance; `end'
must never signal its processes.  The other stray is the source's (the
stop proved it: :own)."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--add "cci-test-other" 'cci-test-a worktree 'idle)
    (let ((claude-code-ide-handover-tests--scan-strays
           (list (list :pid 99991 :command "cci-test-other-cli" :cwd worktree :reason 'worktree
                       :instance-id "cci-test-other" :start 1.0)
                 (list :pid 99992 :command "cci-test-stray" :cwd worktree :reason 'worktree
                       :start 1.0 :own t)))
          (signals nil))
      (setq claude-code-ide-handover-tests--stop-result
            (list :status 'strays :strays claude-code-ide-handover-tests--scan-strays))
      (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :force t))
             (id (plist-get result :handover-id)))
        (claude-code-ide-handover-tests--run-timers)
        (let ((status (claude-code-ide-handover-status id)))
          (should (eq (plist-get status :status) 'needs-user))
          (should (equal (mapcar (lambda (s) (plist-get s :pid)) (plist-get status :strays))
                         '(99992))))
        (cl-letf (((symbol-function 'claude-code-ide-handover--stray-alive-p) (lambda (_) t))
                  ((symbol-function 'signal-process)
                   (lambda (pid signal) (push (cons pid signal) signals) 0)))
          (setq claude-code-ide-handover-tests--scan-strays
                (list (car claude-code-ide-handover-tests--scan-strays)))
          (claude-code-ide-handover-resolve id 'end)
          (claude-code-ide-handover-tests--run-timers))
        (should-not (assq 99991 signals))
        (should (assq 99992 signals))
        (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started))))))

(ert-deftest claude-code-ide-test-handover-other-emacs-instance ()
  "The preflight sees a live instance of another Emacs in the worktree."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--registry-add "cci-test-far" 'cci-test-a worktree)
    (cl-letf (((symbol-function 'claude-code-ide-session-registry-other-emacs-p)
               (lambda (entry &rest _)
                 (equal (claude-code-ide-session-registry-entry-key entry) "cci-test-far"))))
      (let ((refused (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)))
        (should (eq (plist-get refused :reason) 'other-instance))
        (should (string-match-p "cci-test-far" (plist-get refused :message))))
      (should-not (claude-code-ide-handover-tests--record "cci-test-src"))
      ;; A closed entry of that Emacs does not count
      (claude-code-ide-handover-tests--close-entry "cci-test-far")
      (should (eq (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :status)
                  'running)))))

(ert-deftest claude-code-ide-test-handover-original-task-through-pointer ()
  "A first leg that a pointer to a document started: the original task is in that file."
  (claude-code-ide-handover-tests--with
    (let ((document (expand-file-name ".handover/cci-test-h0.md" worktree))
          (file (expand-file-name "leg.jsonl" claude-code-ide-handover-tests--root)))
      (make-directory (file-name-directory document) t)
      (with-temp-file document
        (insert "<!-- claude-code-ide-handover-document id=cci-test-h0 -->\n# Handover document\n\n"
                "## History of the chain\n\n"
                "### Original task (the first user prompt of the chain; it can be out of date)\n\n"
                "> cci-test-original: add mean_of to stats.py.\n\n### User prompts\n\nNone.\n"))
      (claude-code-ide-handover-tests--user-turn-transcript
       file
       (format "<!-- claude-code-ide-handover-document id=cci-test-h0 -->\nRead the handover document at %s fully, and follow its instructions.\n- State summary file: `%s`"
               document (expand-file-name ".handover/cci-test-h0-state.md" worktree))
       "2026-11-18T10:00:00.000Z")
      (let ((doc (claude-code-ide-transcript-handover-document
                  :source (list :provider 'claude :transcript file :worktree worktree)
                  :handover-id "cci-test-h1" :session-server nil)))
        (should (equal (claude-code-ide-transcript-document-original-task doc)
                       "cci-test-original: add mean_of to stats.py."))))))
;;; The source must end before the handover goes on

(defconst claude-code-ide-handover-tests--pid-unknown
  '(:status error :reason "the process ID of the CLI is unknown, so the stop could not end or check it"
            :strays nil :ended nil :escalated nil)
  "The stop result of a live terminal whose CLI process ID is unknown.")

(defmacro claude-code-ide-handover-tests--with-live-stop (result &rest body)
  "Run BODY with a process-tree stop that gives RESULT and leaves the source live.
The stop calls are counted in `stop-calls'."
  (declare (indent 1))
  `(let ((stop-calls 0))
     (cl-letf (((symbol-function 'claude-code-ide-process-stop-later)
                (lambda (_instance &rest args)
                  (setq stop-calls (1+ stop-calls))
                  (funcall (plist-get args :callback) ,result))))
       ,@body)))

(defun claude-code-ide-handover-tests--ending-provider-stop (name)
  "Make the stop of the stub provider NAME end the instance, as a buffer kill does."
  (setf (claude-code-ide-provider-stop (claude-code-ide-get-provider name))
        (lambda (instance)
          (push (claude-code-ide-instance-id instance) claude-code-ide-handover-tests--stops)
          (claude-code-ide-instance-unregister (claude-code-ide-instance-id instance))
          t)))

(ert-deftest claude-code-ide-test-handover-source-pid-unknown ()
  "A stop that cannot end or check the source CLI (its PID is unknown) needs a person.
The reason says that the source may still run; the choices are end, wait
and cancel; nothing goes past source-stopped."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--with-live-stop claude-code-ide-handover-tests--pid-unknown
      (let* ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
        (claude-code-ide-handover-tests--run-timers)
        (let ((status (claude-code-ide-handover-status id)))
          (should (eq (plist-get status :status) 'needs-user))
          (should (eq (plist-get status :reason) 'source-pid-unknown))
          (should (eq (plist-get status :stage) 'source-stopped))
          (should (string-match-p "may still run" (plist-get status :message))))
        (should (equal (mapcar #'cadr (claude-code-ide-handover--choices
                                       (gethash id claude-code-ide-handover--runs)))
                       '(end wait cancel)))
        (should-not claude-code-ide-handover-tests--starts)
        (should (claude-code-ide-instance-by-id "cci-test-src"))))))

(ert-deftest claude-code-ide-test-handover-source-still-running-after-stop ()
  "A stop that says stopped while the source instance still runs is no stop.
The handover needs a person with the reason source-still-running and
never writes the document or starts the target."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--with-live-stop '(:status stopped :strays nil)
      (let* ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
        (claude-code-ide-handover-tests--run-timers)
        (let ((status (claude-code-ide-handover-status id)))
          (should (eq (plist-get status :status) 'needs-user))
          (should (eq (plist-get status :reason) 'source-still-running))
          (should (eq (plist-get status :stage) 'source-stopped))
          (should-not (plist-get status :document)))
        (should (equal (mapcar #'cadr (claude-code-ide-handover--choices
                                       (gethash id claude-code-ide-handover--runs)))
                       '(end wait cancel)))
        (should-not claude-code-ide-handover-tests--starts)))))

(ert-deftest claude-code-ide-test-handover-source-alive-choices ()
  "End kills the source as the control stop does and goes on; wait stops again; cancel cancels."
  (dolist (choice '(end wait cancel))
    (claude-code-ide-handover-tests--with
      (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
      (claude-code-ide-handover-tests--ending-provider-stop 'cci-test-a)
      (let ((result-of-stop claude-code-ide-handover-tests--pid-unknown)
            (stop-calls 0)
            id)
        (cl-letf (((symbol-function 'claude-code-ide-process-stop-later)
                   (lambda (_instance &rest args)
                     (setq stop-calls (1+ stop-calls))
                     (funcall (plist-get args :callback) result-of-stop))))
          (setq id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id))
          (claude-code-ide-handover-tests--run-timers)
          (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'source-pid-unknown))
          (should (= stop-calls 1))
          (pcase choice
            ('end
             (claude-code-ide-handover-resolve id 'end)
             (claude-code-ide-handover-tests--run-timers)
             ;; The provider stop ended the source, then the scan ran
             (should (member "cci-test-src" claude-code-ide-handover-tests--stops))
             (should-not (claude-code-ide-instance-by-id "cci-test-src"))
             (should (= (length claude-code-ide-handover-tests--starts) 1))
             (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started)))
            ('wait
             ;; The next stop still cannot end it: a person again
             (claude-code-ide-handover-resolve id 'wait)
             (claude-code-ide-handover-tests--run-timers)
             (should (= stop-calls 2))
             (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'source-pid-unknown))
             (should-not claude-code-ide-handover-tests--starts)
             ;; Then the CLI ends, and the stop after the wait goes on
             (claude-code-ide-instance-unregister "cci-test-src")
             (setq result-of-stop '(:status stopped :strays nil))
             (claude-code-ide-handover-resolve id 'wait)
             (claude-code-ide-handover-tests--run-timers)
             (should (= (length claude-code-ide-handover-tests--starts) 1)))
            ('cancel
             (claude-code-ide-handover-resolve id 'cancel)
             (claude-code-ide-handover-tests--run-timers)
             (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
             (should-not claude-code-ide-handover-tests--starts))))))))

(ert-deftest claude-code-ide-test-handover-source-alive-cancel-message ()
  "A cancel while the source still runs never says that the source is stopped."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--with-live-stop claude-code-ide-handover-tests--pid-unknown
      (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id)))
        (claude-code-ide-handover-tests--run-timers)
        (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'source-pid-unknown))
        (claude-code-ide-handover-resolve id 'cancel)
        (let ((message (plist-get (claude-code-ide-handover-status id) :message)))
          (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
          (should-not (string-match-p "source is stopped" message))
          (should (string-match-p "still runs" message)))))))

(ert-deftest claude-code-ide-test-handover-source-alive-end-waits-for-soft-stop ()
  "After end, the rescan waits at least as long as the soft stop of the source.
A shorter wait finds the source still live, and asks again."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--with-live-stop claude-code-ide-handover-tests--pid-unknown
      (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b) :handover-id))
            (delays nil)
            (original (symbol-function 'run-at-time)))
        (claude-code-ide-handover-tests--run-timers)
        (cl-letf (((symbol-function 'claude-code-ide--soft-stop-limit) (lambda () 7))
                  ((symbol-function 'claude-code-ide-control-stop) (lambda (_id) '(:status ok)))
                  ((symbol-function 'run-at-time)
                   (lambda (time &rest args)
                     (push time delays)
                     (apply original time args))))
          (let ((claude-code-ide-handover-stray-wait 2))
            (claude-code-ide-handover-resolve id 'end)))
        (should (member 7 delays))))))

(ert-deftest claude-code-ide-test-handover-recovery-live-source ()
  "A recovery never starts a target next to a live source.
The source runs again in this Emacs (for example after a restore), so
the recovery needs a person; end stops the source, and then the target
starts."
  (dolist (stage '(document-written target-started))
    (claude-code-ide-handover-tests--with
      (let ((id (claude-code-ide-handover-tests--interrupted stage)))
        ;; The source runs again
        (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a
                                             (claude-code-ide-handover-tests--worktree) 'idle)
        (claude-code-ide-handover-tests--ending-provider-stop 'cci-test-a)
        (claude-code-ide-handover-recover)
        (claude-code-ide-handover-tests--run-timers)
        (let ((status (claude-code-ide-handover-status id)))
          (should (eq (plist-get status :status) 'needs-user))
          (should (eq (plist-get status :reason) 'source-still-running)))
        (should-not claude-code-ide-handover-tests--starts)
        (claude-code-ide-handover-resolve id 'end)
        (claude-code-ide-handover-tests--run-timers)
        (should-not (claude-code-ide-instance-by-id "cci-test-src"))
        (should (= (length claude-code-ide-handover-tests--starts) 1))
        (should (equal (claude-code-ide-start-spec-instance-id (car claude-code-ide-handover-tests--starts))
                       (plist-get (claude-code-ide-handover-status id) :target-id)))))))

(ert-deftest claude-code-ide-test-handover-normal-stop-unchanged ()
  "A stop that ends the source goes on as before, with no question."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b))
           (id (plist-get result :handover-id)))
      (claude-code-ide-handover-tests--run-timers)
      (should (equal claude-code-ide-handover-tests--stops '("cci-test-src")))
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'running))
      (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started))
      (claude-code-ide-handover-tests--deliver result)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed)))))

;;; Other sessions in the working tree

(defun claude-code-ide-handover-tests--session (id directory &optional cleanup-done)
  "Add a live MCP session ID in DIRECTORY without an instance descriptor.
CLEANUP-DONE non-nil makes it a session after its cleanup.  Return it."
  (let ((buffer (generate-new-buffer (format "*cci-test-session-%s*" id)))
        (session nil))
    (push buffer claude-code-ide-handover-tests--buffers)
    (setq session (make-claude-code-ide-mcp-session
                   :session-id id :buffer buffer :project-dir directory
                   :cleanup-done cleanup-done))
    (puthash id session claude-code-ide-mcp--sessions)
    session))

(defun claude-code-ide-handover-tests--preflight-reason (id &optional force)
  "Return the preflight reason of a handover of ID to cci-test-b, or nil.
FORCE is the :force of the handover."
  (plist-get (claude-code-ide-handover--preflight
              (claude-code-ide-instance-by-id id) 'cci-test-b force nil nil)
             :reason))

(ert-deftest claude-code-ide-test-handover-other-session-in-same-tree ()
  "The `other-instance' check sees live sessions and instances in a subfolder.
A subfolder without its own repository is the same working tree.  A
live MCP session without a descriptor counts there too; :force goes on."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (let ((sub (file-name-as-directory (expand-file-name "src/module" worktree))))
      (make-directory sub t)
      (claude-code-ide-handover-tests--session "cci-test-old" sub)
      (let ((refused (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)))
        (should (eq (plist-get refused :reason) 'other-instance))
        (should (string-match-p "cci-test-old" (plist-get refused :message))))
      (should-not (claude-code-ide-handover-tests--preflight-reason "cci-test-src" t))
      (remhash "cci-test-old" claude-code-ide-mcp--sessions)
      ;; A live instance in the subfolder
      (claude-code-ide-handover-tests--add "cci-test-sub" 'cci-test-a sub 'idle)
      (should (eq (claude-code-ide-handover-tests--preflight-reason "cci-test-src")
                  'other-instance)))))

(ert-deftest claude-code-ide-test-handover-strays-of-other-sessions ()
  "A process of another live MCP session of this Emacs is never a stray.
The scan tags it with :session-id; the session has no descriptor, as
one that an older version of the package started.  A process of the
source's own session, or of a session after its cleanup, stays a stray."
  (claude-code-ide-handover-tests--with
    (let* ((source (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle))
           (own (make-claude-code-ide-mcp-session :session-id "cci-test-own"
                                                  :buffer (claude-code-ide-instance-buffer source)
                                                  :project-dir worktree))
           (elsewhere (claude-code-ide-handover-tests--other "elsewhere"))
           (signals nil))
      (setf (claude-code-ide-instance-session source) own)
      (puthash "cci-test-own" own claude-code-ide-mcp--sessions)
      (claude-code-ide-handover-tests--session "cci-test-old" elsewhere)
      (claude-code-ide-handover-tests--session "cci-test-done" elsewhere t)
      (let ((claude-code-ide-handover-tests--scan-strays
             (list (list :pid 99981 :command "cci-test-old-cli" :cwd worktree :reason 'worktree
                         :session-id "cci-test-old" :start 1.0)
                   (list :pid 99982 :command "cci-test-own-child" :cwd worktree :reason 'worktree
                         :session-id "cci-test-own" :start 1.0)
                   (list :pid 99983 :command "cci-test-done-child" :cwd worktree :reason 'worktree
                         :session-id "cci-test-done" :start 1.0)
                   (list :pid 99984 :command "cci-test-stray" :cwd worktree :reason 'worktree
                         :start 1.0))))
        (setq claude-code-ide-handover-tests--stop-result
              (list :status 'strays :strays claude-code-ide-handover-tests--scan-strays))
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)
                             :handover-id)))
          (claude-code-ide-handover-tests--run-timers)
          (let ((status (claude-code-ide-handover-status id)))
            (should (eq (plist-get status :status) 'needs-user))
            (should (equal (mapcar (lambda (s) (plist-get s :pid)) (plist-get status :strays))
                           '(99982 99983 99984))))
          (cl-letf (((symbol-function 'claude-code-ide-handover--stray-alive-p) (lambda (_) t))
                    ((symbol-function 'signal-process)
                     (lambda (pid signal) (push (cons pid signal) signals) 0)))
            (setq claude-code-ide-handover-tests--scan-strays
                  (list (car claude-code-ide-handover-tests--scan-strays)))
            (claude-code-ide-handover-resolve id 'end)
            (claude-code-ide-handover-tests--run-timers))
          (should-not (assq 99981 signals))
          (should (assq 99984 signals))
          (should (eq (plist-get (claude-code-ide-handover-status id) :stage) 'target-started)))))))

;;; Strays of unknown owner

(defun claude-code-ide-handover-tests--end-signals (others)
  "Return the PIDs that `end' signals, with OTHERS: another instance runs too.
The stop gives a stray of the source (:own) and an untagged one."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (when others
      (claude-code-ide-handover-tests--add "cci-test-two" 'cci-test-a worktree 'idle))
    (let ((strays (list (list :pid 99993 :command "cci-test-own" :cwd worktree :reason 'worktree
                              :start 1.0 :own t)
                        (list :pid 99994 :command "cci-test-unknown" :cwd worktree :reason 'worktree
                              :start 1.0)))
          (signals nil))
      (setq claude-code-ide-handover-tests--stop-result (list :status 'strays :strays strays))
      (let* ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t)
                            :handover-id))
             (run (gethash id claude-code-ide-handover--runs)))
        (claude-code-ide-handover-tests--run-timers)
        (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'strays))
        (should (equal (mapcar (lambda (s) (plist-get s :pid)) (plist-get (claude-code-ide-handover-status id) :strays))
                       '(99993 99994)))
        (let ((unknown (string-match-p "owner unknown" (claude-code-ide-handover--run-message run)))
              (end (nth 2 (assq ?e (claude-code-ide-handover--choices run)))))
          (if others
              (progn (should unknown)
                     (should (string-match-p "owner unknown" end)))
            (should-not unknown)
            (should-not (string-match-p "owner unknown" end))))
        ;; A wait: the scan finds both again, without the mark of the
        ;; stop; the source's stray keeps its proof (PID and start time)
        (setq claude-code-ide-handover-tests--scan-strays
              (mapcar (lambda (s) (cl-subseq s 0 10)) strays))
        (claude-code-ide-handover-resolve id 'wait)
        (claude-code-ide-handover-tests--run-timers)
        (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'strays))
        (cl-letf (((symbol-function 'claude-code-ide-handover--stray-alive-p) (lambda (_) t))
                  ((symbol-function 'signal-process)
                   (lambda (pid signal) (push (cons pid signal) signals) 0)))
          (setq claude-code-ide-handover-tests--scan-strays nil)
          (claude-code-ide-handover-resolve id 'end)
          (claude-code-ide-handover-tests--run-timers))
        (delete-dups (mapcar #'car signals))))))

(ert-deftest claude-code-ide-test-handover-end-spares-unknown-owner ()
  "With another session in the worktree, `end' signals only the strays of the source.
A stray of unknown owner is listed as such, and left alone."
  (should (equal (claude-code-ide-handover-tests--end-signals t) '(99993))))

(ert-deftest claude-code-ide-test-handover-reused-pid-loses-own ()
  "A PID that another process took after the proof of the stop is no stray of the source.
The stop proved the process with the start time of its snapshot.  When
the handover reads the start time, the PID runs with another one: the
new process is of unknown owner, and `end' does not signal it."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--add "cci-test-two" 'cci-test-a worktree 'idle)
    (setq claude-code-ide-handover-tests--stop-result
          (list :status 'strays
                :strays (list (list :pid 99995 :command "cci-test-proven" :cwd worktree
                                    :reason 'worktree :start 1000.0 :own t))))
    (let ((signals nil))
      (cl-letf (((symbol-function 'claude-code-ide-session-registry--process-start-time)
                 (lambda (pid &rest _) (and (eql pid 99995) 2000.0)))
                ((symbol-function 'signal-process)
                 (lambda (pid signal) (push (cons pid signal) signals) 0)))
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t)
                             :handover-id)))
          (claude-code-ide-handover-tests--run-timers)
          (let ((stray (car (plist-get (claude-code-ide-handover-status id) :strays))))
            (should (eql (plist-get stray :pid) 99995))
            (should-not (plist-get stray :own)))
          (claude-code-ide-handover-resolve id 'end)
          (claude-code-ide-handover-tests--run-timers 3)))
      (should-not signals))))

(ert-deftest claude-code-ide-test-handover-end-alone-unchanged ()
  "Without another session in the worktree, `end' signals every stray, as before."
  (should (equal (sort (claude-code-ide-handover-tests--end-signals nil) #'<) '(99993 99994))))

;;; Linked Git worktrees

(defun claude-code-ide-handover-tests--linked-repo (repo worktrees)
  "Make the Git repository REPO with one commit and the linked WORKTREES.
Each of WORKTREES is (FOLDER . BRANCH); `git worktree add' makes it."
  (make-directory repo t)
  (should (eql 0 (claude-code-ide-handover-tests--git repo "init" "-q")))
  (should (eql 0 (claude-code-ide-handover-tests--git
                  repo "-c" "user.name=cci-test" "-c" "user.email=cci-test@example.invalid"
                  "commit" "-q" "--allow-empty" "-m" "cci-test")))
  (dolist (worktree worktrees)
    (should (eql 0 (claude-code-ide-handover-tests--git
                    repo "worktree" "add" "-q" "-b" (cdr worktree) (car worktree))))))

(defun claude-code-ide-handover-tests--strays-of-source (directory folders)
  "Return the FOLDERS with a stray process for a source in DIRECTORY.
The scan covers the worktree of a handover of DIRECTORY
\(`claude-code-ide-handover--directory-key').  One process runs in each
of FOLDERS, which are absolute and get their true names, as lsof
gives them."
  (dolist (folder folders)
    (make-directory folder t))
  (let* ((pids (number-sequence 800 (+ 799 (length folders))))
         (strays (claude-code-ide-process-tests--stray-pids
                  (claude-code-ide-handover--directory-key directory)
                  (cl-mapcar (lambda (pid folder) (cons pid (file-truename folder)))
                             pids folders))))
    (cl-loop for pid in pids for folder in folders
             when (memql pid strays) collect folder)))

(defmacro claude-code-ide-handover-tests--with-tmp (&rest body)
  "Run BODY with `tmp', a new temporary folder that a link reaches.
The folder is the link, as macOS reaches /private/var through /var."
  (declare (indent 0))
  `(let* ((real (make-temp-file "cci-test-linked-" t))
          (tmp (concat real "-link")))
     (unwind-protect
         (progn (make-symbolic-link real tmp) ,@body)
       (ignore-errors (delete-file tmp))
       (delete-directory real t))))

(ert-deftest claude-code-ide-test-handover-linked-worktrees-inside ()
  "Worktrees inside the repository (layout A): each tree keeps its own strays.
A source in the main checkout does not get the processes of
.worktrees/feat-x or .worktrees/fix/y; a source in feat-x gets only
those of feat-x.  The root of feat-x is feat-x, whose .git is a file."
  (skip-unless (executable-find "git"))
  (claude-code-ide-handover-tests--with-tmp
    (let* ((repo (expand-file-name "repo" tmp))
           (feat (expand-file-name ".worktrees/feat-x" repo))
           (fix (expand-file-name ".worktrees/fix/y" repo)))
      (claude-code-ide-handover-tests--linked-repo repo `((,feat . "feat-x") (,fix . "fix/y")))
      (should (file-regular-p (expand-file-name ".git" feat)))
      (should (equal (claude-code-ide--worktree-root feat) (file-name-as-directory feat)))
      (should (equal (claude-code-ide--worktree-root (expand-file-name "sub" feat))
                     (file-name-as-directory feat)))
      (let ((src (expand-file-name "src" repo))
            (feat-sub (expand-file-name "sub" feat))
            (fix-sub (expand-file-name "a/b" fix)))
        (should (equal (claude-code-ide-handover-tests--strays-of-source
                        repo (list feat feat-sub fix fix-sub src repo))
                       (list src repo)))
        (should (equal (claude-code-ide-handover-tests--strays-of-source
                        feat (list feat-sub feat repo src fix))
                       (list feat-sub feat)))))))

(ert-deftest claude-code-ide-test-handover-linked-worktrees-outside ()
  "Worktrees outside the repository (layout B): each tree keeps its own strays.
A source in worktrees/repo/feat-x gets only the processes there.  A
source in worktrees/repo itself, which is no repository, does not get
the processes of feat-x or fix/y, but gets those of a plain subfolder."
  (skip-unless (executable-find "git"))
  (claude-code-ide-handover-tests--with-tmp
    (let* ((source (expand-file-name "Source" tmp))
           (repo (expand-file-name "repo" source))
           (holder (expand-file-name "worktrees/repo" source))
           (feat (expand-file-name "feat-x" holder))
           (fix (expand-file-name "fix/y" holder))
           (notes (expand-file-name "notes" holder)))
      (claude-code-ide-handover-tests--linked-repo repo `((,feat . "feat-x") (,fix . "fix/y")))
      (should (equal (claude-code-ide-handover-tests--strays-of-source
                      feat (list (expand-file-name "lib" feat) fix repo))
                     (list (expand-file-name "lib" feat))))
      (should (eq (claude-code-ide--worktree-root holder) 'unknown))
      (should (equal (claude-code-ide-handover-tests--strays-of-source
                      holder (list feat (expand-file-name "lib" feat) fix notes holder))
                     (list notes holder))))))

(ert-deftest claude-code-ide-test-handover-linked-worktrees-other-instance ()
  "A live session in a linked worktree does not block a handover in the main checkout.
The reverse holds too: each linked worktree is a working tree of its own."
  (skip-unless (executable-find "git"))
  (claude-code-ide-handover-tests--with
    (let* ((repo (expand-file-name "repo" claude-code-ide-handover-tests--root))
           (feat (file-name-as-directory (expand-file-name ".worktrees/feat-x" repo))))
      (claude-code-ide-handover-tests--linked-repo repo `((,feat . "feat-x")))
      (claude-code-ide-handover-tests--add "cci-test-main" 'cci-test-a repo 'idle)
      (claude-code-ide-handover-tests--session "cci-test-feat-session" feat)
      (should-not (claude-code-ide-handover-tests--preflight-reason "cci-test-main"))
      (remhash "cci-test-feat-session" claude-code-ide-mcp--sessions)
      (claude-code-ide-handover-tests--add "cci-test-feat" 'cci-test-a feat 'idle)
      (should-not (claude-code-ide-handover-tests--preflight-reason "cci-test-main"))
      (should-not (claude-code-ide-handover-tests--preflight-reason "cci-test-feat"))
      (claude-code-ide-handover-tests--session "cci-test-main-session" (expand-file-name "src" repo))
      (should-not (claude-code-ide-handover-tests--preflight-reason "cci-test-feat"))
      ;; A second session in feat-x does block
      (claude-code-ide-handover-tests--session "cci-test-feat-2" (expand-file-name "sub" feat))
      (should (eq (claude-code-ide-handover-tests--preflight-reason "cci-test-feat")
                  'other-instance)))))

;;; Other sessions: the question and :allow-others

(defmacro claude-code-ide-handover-tests--with-questions (answers &rest body)
  "Run BODY with stubs of the question functions, and `questions'.
Each stub pushes (FUNCTION . PROMPT) on `questions'.  ANSWERS is an
alist of (FUNCTION . ANSWER); ANSWER is a value, or a function of the
prompt.  The defaults: `y-or-n-p' and `yes-or-no-p' t, `read-string'
\"\", `completing-read' \"cci-test-b\", `completing-read-multiple' nil,
`read-multiple-choice' the key ?f."
  (declare (indent 1))
  `(let* ((questions nil)
          (answers ,answers)
          (answer (lambda (function prompt default)
                    (push (cons function prompt) questions)
                    (let ((value (alist-get function answers default)))
                      (if (functionp value) (funcall value prompt) value)))))
     (cl-letf (((symbol-function 'y-or-n-p)
                (lambda (prompt) (funcall answer 'y-or-n-p prompt t)))
               ((symbol-function 'yes-or-no-p)
                (lambda (prompt) (funcall answer 'yes-or-no-p prompt t)))
               ((symbol-function 'read-string)
                (lambda (prompt &rest _) (funcall answer 'read-string prompt "")))
               ((symbol-function 'completing-read)
                (lambda (prompt &rest _) (funcall answer 'completing-read prompt "cci-test-b")))
               ((symbol-function 'completing-read-multiple)
                (lambda (prompt &rest _) (funcall answer 'completing-read-multiple prompt nil)))
               ((symbol-function 'read-multiple-choice)
                (lambda (prompt choices &rest _)
                  (assq (funcall answer 'read-multiple-choice prompt ?f) choices))))
       ,@body)))

(defun claude-code-ide-handover-tests--asked (questions function)
  "Return the prompts of FUNCTION in QUESTIONS, oldest first."
  (nreverse (delq nil (mapcar (lambda (q) (and (eq (car q) function) (cdr q))) questions))))

(ert-deftest claude-code-ide-test-handover-asks-about-other-instances ()
  "The handover asks about the other sessions of the worktree, as its first question.
The prompt names each with its label and state; after y, the handover
runs.  Without another session, no such question comes."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--with-questions nil
      (should-not (nth 7 (claude-code-ide-handover--read-args "cci-test-src")))
      (should-not (claude-code-ide-handover-tests--asked questions 'y-or-n-p)))
    (claude-code-ide-handover-tests--add "cci-test-plan" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--with-questions nil
      (let ((args (claude-code-ide-handover--read-args "cci-test-src"))
            (prompt (car (claude-code-ide-handover-tests--asked questions 'y-or-n-p))))
        (should (eq (car (car (last questions))) 'y-or-n-p))
        (should (string-match-p "1 other session runs in the worktree" prompt))
        (should (string-match-p (regexp-quote "cci-test-plan (cci-test-a, cci-test-plan): idle") prompt))
        (should (string-match-p "does not stop them" prompt))
        (should (equal (nth 7 args) '("cci-test-plan")))
        (cl-letf (((symbol-function 'message) #'ignore))
          (should (eq (plist-get (apply #'claude-code-ide-handover args) :status) 'running)))))))

(ert-deftest claude-code-ide-test-handover-confirmed-ids-only ()
  "The question confirms the sessions that it listed, and no other.
A session that starts between the question and the start refuses the
handover; :allow-others t still allows all sessions of this Emacs."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--add "cci-test-plan" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--with-questions nil
      (let ((args (claude-code-ide-handover--read-args "cci-test-src")))
        (claude-code-ide-handover-tests--add "cci-test-late" 'cci-test-a worktree 'idle)
        (let ((err (should-error (apply #'claude-code-ide-handover args) :type 'user-error)))
          (should (string-match-p "other-instance" (cadr err)))
          (should (string-match-p "cci-test-late" (cadr err)))
          (should-not (string-match-p "cci-test-plan" (cadr err))))
        (should (= (hash-table-count claude-code-ide-handover--runs) 0))))
    (should (eq (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t)
                           :status)
                'running))))

(ert-deftest claude-code-ide-test-handover-other-instances-no ()
  "After n to the question about other sessions, nothing starts and nothing more is asked."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--add "cci-test-plan" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--with-questions '((y-or-n-p . nil))
      (should-error (claude-code-ide-handover--read-args "cci-test-src") :type 'user-error)
      (should (= (length questions) 1)))
    (should (= (hash-table-count claude-code-ide-handover--runs) 0))
    (should-not (claude-code-ide-handover-tests--record "cci-test-src"))))

(ert-deftest claude-code-ide-test-handover-prefix-skips-other-question ()
  "With a prefix argument, the question about other sessions does not come."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--add "cci-test-plan" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--with-questions nil
      (let* ((current-prefix-arg '(4))
             (args (claude-code-ide-handover--read-args "cci-test-src")))
        (should-not (claude-code-ide-handover-tests--asked questions 'y-or-n-p))
        (should (equal (nth 7 args) '("cci-test-plan")))
        (cl-letf (((symbol-function 'message) #'ignore))
          (should (eq (plist-get (apply #'claude-code-ide-handover args) :status) 'running)))))))

(ert-deftest claude-code-ide-test-handover-other-emacs-refused ()
  "A live instance of another Emacs in the worktree refuses also :allow-others.
Only :force goes past it."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--registry-add "cci-test-far" 'cci-test-a worktree :emacs-pid 4711)
    (cl-letf (((symbol-function 'claude-code-ide-session-registry-other-emacs-p)
               (lambda (entry &rest _)
                 (equal (claude-code-ide-session-registry-entry-key entry) "cci-test-far"))))
      (let ((refused (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t)))
        (should (eq (plist-get refused :reason) 'other-instance))
        (should (string-match-p "cci-test-far" (plist-get refused :message)))
        (should (string-match-p "4711" (plist-get refused :message))))
      (should-not (claude-code-ide-handover-tests--record "cci-test-src"))
      (should (eq (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :force t)
                             :status)
                  'running)))))

(ert-deftest claude-code-ide-test-handover-writer-lines ()
  "Each kind of writer in the worktree gets its own line."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-coder" 'cci-test-b worktree 'failed 'quota-limit)
    (claude-code-ide-handover-tests--session "cci-test-old" worktree)
    (claude-code-ide-handover-tests--registry-add "cci-test-far" 'cci-test-a worktree
                                                  :instance-name "far" :emacs-pid 4711)
    (should (equal (claude-code-ide-handover--writer-lines
                    '("cci-test-coder" "cci-test-old" "cci-test-far"))
                   '("cci-test-coder (cci-test-b, cci-test-coder): failed/quota-limit"
                     "cci-test-old: an MCP session without an instance descriptor"
                     "far (cci-test-a, cci-test-far): an instance of the Emacs with process 4711")))))

(ert-deftest claude-code-ide-test-handover-allow-others-keeps-busy ()
  ":allow-others does not let the handover past subagents or background tasks."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'waiting-for-task 'subagent)
    (claude-code-ide-handover-tests--add "cci-test-two" 'cci-test-a worktree 'idle)
    (should (eq (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t)
                           :reason)
                'busy))
    (claude-code-ide-handover-tests--set-state "cci-test-src" 'working)
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t)
                         :handover-id)))
      (claude-code-ide-handover-tests--run-timers 3)
      (claude-code-ide-handover-tests--set-state "cci-test-src" 'waiting-for-task 'background-task)
      (claude-code-ide-handover-tests--run-timers 3)
      (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
      (should (eq (plist-get (claude-code-ide-handover-status id) :reason) 'busy))
      (should-not claude-code-ide-handover-tests--stops))))

(ert-deftest claude-code-ide-test-handover-request-asks-about-others ()
  "The request of an agent asks both questions; n to the second starts nothing."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--add "cci-test-plan" 'cci-test-a worktree 'idle)
    (cl-letf (((symbol-function 'message) #'ignore))
      (claude-code-ide-handover-tests--with-questions
          `((y-or-n-p . ,(lambda (prompt) (not (string-match-p "other session" prompt)))))
        (claude-code-ide-handover-request "cci-test-src" "cci-test-b")
        (claude-code-ide-handover-tests--event "cci-test-src" 'turn-end)
        (should-error (claude-code-ide-handover-tests--run-timers) :type 'user-error)
        (should (= (length (claude-code-ide-handover-tests--asked questions 'y-or-n-p)) 2))
        (should (= (hash-table-count claude-code-ide-handover--runs) 0)))
      (claude-code-ide-handover-tests--with-questions nil
        (claude-code-ide-handover-request "cci-test-src" "cci-test-b")
        (claude-code-ide-handover-tests--event "cci-test-src" 'turn-end)
        (claude-code-ide-handover-tests--run-timers)
        (let ((asked (claude-code-ide-handover-tests--asked questions 'y-or-n-p)))
          (should (= (length asked) 2))
          (should (string-match-p "asks for a handover" (nth 0 asked)))
          (should (string-match-p "cci-test-plan" (nth 1 asked))))
        (should (= (hash-table-count claude-code-ide-handover--runs) 1))))))

(ert-deftest claude-code-ide-test-handover-checks-before-questions ()
  "A held worktree, and a live instance of another Emacs, refuse before any question."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (claude-code-ide-handover-tests--add "cci-test-plan" 'cci-test-a worktree 'idle)
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t)
                         :handover-id)))
      (claude-code-ide-handover-tests--with-questions nil
        (let ((err (should-error (claude-code-ide-handover--read-args "cci-test-plan")
                                 :type 'user-error)))
          (should (string-match-p (regexp-quote id) (cadr err))))
        (should-error (claude-code-ide-handover--read-batch-args) :type 'user-error)
        (should-not questions))
      (claude-code-ide-handover-cancel id))
    (claude-code-ide-handover-tests--registry-add "cci-test-far" 'cci-test-a worktree :emacs-pid 4711)
    (cl-letf (((symbol-function 'claude-code-ide-session-registry-other-emacs-p)
               (lambda (entry &rest _)
                 (equal (claude-code-ide-session-registry-entry-key entry) "cci-test-far"))))
      (claude-code-ide-handover-tests--with-questions nil
        (let ((err (should-error (claude-code-ide-handover--read-args "cci-test-src")
                                 :type 'user-error)))
          (should (string-match-p "cci-test-far" (cadr err)))
          (should (string-match-p "4711" (cadr err))))
        (should-error (claude-code-ide-handover--read-batch-args) :type 'user-error)
        (should-not questions)))))

;;; One handover at a time, and the lock

(ert-deftest claude-code-ide-test-handover-second-request-names-holder ()
  "A second handover in a held worktree gives handover-running with the ID of the first."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (claude-code-ide-handover-tests--add "cci-test-two" 'cci-test-a worktree 'idle)
    (let* ((first (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t))
           (second (claude-code-ide-handover-session "cci-test-two" 'cci-test-b :allow-others t)))
      (should (eq (plist-get second :reason) 'handover-running))
      (should (equal (plist-get second :handover-id) (plist-get first :handover-id)))
      (claude-code-ide-handover-tests--set-state "cci-test-src" 'idle)
      (claude-code-ide-handover-tests--run-timers)
      (claude-code-ide-handover-tests--deliver first)
      (should (eq (plist-get (claude-code-ide-handover-status (plist-get first :handover-id)) :status)
                  'committed))
      (should (eq (plist-get (claude-code-ide-handover-session "cci-test-two" 'cci-test-b :allow-others t)
                             :status)
                  'running)))))

(ert-deftest claude-code-ide-test-handover-others-keep-their-inbox ()
  "Another instance of the worktree is not held, and its inbox gets nothing of the handover."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
    (claude-code-ide-handover-tests--add "cci-test-two" 'cci-test-a worktree 'idle)
    (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b
                                                    :allow-others t :continue t)))
      (claude-code-ide-handover-tests--run-timers 3)
      (should (member "cci-test-src" claude-code-ide-control--held))
      (should-not (member "cci-test-two" claude-code-ide-control--held))
      ;; It goes out at once; the acknowledgement comes later
      (claude-code-ide-control-submit "cci-test-two" "cci-test-hello" :request-id "b1")
      (should (equal (car claude-code-ide-handover-tests--sent) '("cci-test-two" "cci-test-hello")))
      (claude-code-ide-handover-tests--set-state "cci-test-src" 'idle)
      (claude-code-ide-handover-tests--run-timers)
      (claude-code-ide-handover-tests--deliver result)
      (should (eq (plist-get (claude-code-ide-handover-status (plist-get result :handover-id)) :status)
                  'committed))
      ;; The only record of the other instance is its own prompt
      (should (equal (mapcar #'claude-code-ide-control--record-request-id
                             (mapcar #'claude-code-ide-control--read-record
                                     (directory-files-recursively
                                      (claude-code-ide-control-inbox-directory-of "cci-test-two")
                                      "\\.json\\'")))
                     '("b1"))))))

(ert-deftest claude-code-ide-test-handover-launch-names-holder ()
  "A launch or a resume in a held worktree gives handover-running with the handover ID."
  (claude-code-ide-handover-tests--with
    (cl-letf (((symbol-function 'claude-code-ide--start-session)
               (lambda (&rest args)
                 (apply #'claude-code-ide-handover--guard-start
                        #'claude-code-ide-handover-tests--start args))))
      (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'working)
      (claude-code-ide-handover-tests--registry-add "cci-test-old" 'cci-test-a worktree)
      (claude-code-ide-handover-tests--close-entry "cci-test-old")
      (let* ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b))
             (id (plist-get result :handover-id)))
        (dolist (refused (list (claude-code-ide-control-launch :directory worktree :provider 'cci-test-a)
                               (claude-code-ide-control-resume "cci-test-old")))
          (should (eq (plist-get refused :status) 'error))
          (should (eq (plist-get refused :reason) 'handover-running))
          (should (equal (plist-get refused :handover-id) id))
          (should (string-match-p (regexp-quote id) (plist-get refused :message))))
        (should-not claude-code-ide-handover-tests--starts)
        (should-error (claude-code-ide--start-session
                       nil nil (claude-code-ide-start-spec-create :directory worktree))
                      :type 'user-error)
        (claude-code-ide-handover-tests--set-state "cci-test-src" 'idle)
        (claude-code-ide-handover-tests--run-timers)
        (claude-code-ide-handover-tests--deliver result)
        (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed))
        (let ((launch (claude-code-ide-control-launch :directory worktree :provider 'cci-test-a)))
          (should (eq (plist-get launch :status) 'ok))
          (should (claude-code-ide-instance-by-id (plist-get launch :instance-id))))))))

;;; The notice in the document

(defun claude-code-ide-handover-tests--others-part (id)
  "Return the part about other sessions of the document of handover ID, or nil."
  (let ((text (with-temp-buffer
                (insert-file-contents (plist-get (claude-code-ide-handover-status id) :document))
                (buffer-string))))
    (when-let* ((start (string-search "## Other sessions in this worktree" text)))
      (substring text start (string-match "^## " text (1+ start))))))

(ert-deftest claude-code-ide-test-handover-document-names-others ()
  "The document names the other instances of the worktree, not the source or the target."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--add "cci-test-two" 'cci-test-a worktree 'idle)
    (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t)
                         :handover-id)))
      (claude-code-ide-handover-tests--run-timers)
      (let ((part (claude-code-ide-handover-tests--others-part id))
            (target (plist-get (claude-code-ide-handover-status id) :target-id)))
        (should (string-search "- cci-test-two (cci-test-a, cci-test-two): idle" part))
        (should-not (string-search "cci-test-src" part))
        (should-not (string-search target part))))))

(ert-deftest claude-code-ide-test-handover-run-writers-after-stop ()
  "The writers of a run are known without the source descriptor; a recovery lists them again."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
    (claude-code-ide-handover-tests--add "cci-test-two" 'cci-test-a worktree 'idle)
    (let* ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b :allow-others t)
                          :handover-id))
           (run (gethash id claude-code-ide-handover--runs)))
      (claude-code-ide-handover-tests--run-timers)
      (should-not (claude-code-ide-instance-by-id "cci-test-src"))
      (should (claude-code-ide-handover--live-target run))
      (should (equal (claude-code-ide-handover--run-writers run) '("cci-test-two")))))
  ;; A recovery at document-written writes the list of the instances that run then
  (claude-code-ide-handover-tests--with
    (let ((id (claude-code-ide-handover-tests--interrupted 'document-written)))
      (should-not (claude-code-ide-handover-tests--others-part id))
      (claude-code-ide-handover-tests--add "cci-test-three" 'cci-test-a worktree 'idle)
      (claude-code-ide-handover-recover)
      (should (string-search "- cci-test-three (cci-test-a, cci-test-three): idle"
                             (claude-code-ide-handover-tests--others-part id))))))

;;; The batch of a worktree

(defun claude-code-ide-handover-tests--sources (count &optional state)
  "Add COUNT stub instances cci-test-s1, cci-test-s2, ... in the test worktree.
They have the provider cci-test-a and STATE (default idle).  Return
their IDs."
  (mapcar (lambda (n)
            (let ((id (format "cci-test-s%d" n)))
              (claude-code-ide-handover-tests--add
               id 'cci-test-a (claude-code-ide-handover-tests--worktree) (or state 'idle))
              id))
          (number-sequence 1 count)))

(defun claude-code-ide-handover-tests--batch ()
  "Return the batch of the test worktree, or nil."
  (gethash (claude-code-ide-handover--directory-key (claude-code-ide-handover-tests--worktree))
           claude-code-ide-handover--batches))

(defun claude-code-ide-handover-tests--current ()
  "Return the ID of the current handover of the batch of the test worktree."
  (claude-code-ide-handover--batch-current (claude-code-ide-handover-tests--batch)))

(defun claude-code-ide-handover-tests--deliver-current ()
  "Run the timers, then deliver the document of the current handover of the batch.
Return its handover ID."
  (claude-code-ide-handover-tests--run-timers)
  (let ((id (claude-code-ide-handover-tests--current)))
    (claude-code-ide-handover-tests--deliver (list :handover-id id))
    id))

(defun claude-code-ide-handover-tests--unfinished ()
  "Return the number of unfinished handovers of this Emacs."
  (cl-count-if #'claude-code-ide-handover--unfinished-p
               (hash-table-values claude-code-ide-handover--runs)))

(defun claude-code-ide-handover-tests--live-of (provider)
  "Return the IDs of the live instances of PROVIDER in the test worktree."
  (mapcar #'claude-code-ide-instance-id
          (cl-remove-if-not
           (lambda (instance)
             (and (claude-code-ide-instance-live-p instance)
                  (equal (claude-code-ide-handover--instance-key instance)
                         (claude-code-ide-handover--directory-key
                          (claude-code-ide-handover-tests--worktree)))))
           (claude-code-ide-instances provider))))

(defun claude-code-ide-handover-tests--label (id)
  "Return the label of the stub instance ID of the provider cci-test-a."
  (format "%s (cci-test-a, %s)" id id))

(ert-deftest claude-code-ide-test-handover-worktree-three ()
  "A batch hands over three sources one after the other, each with its own context."
  (claude-code-ide-handover-tests--with
    (let* ((ids (claude-code-ide-handover-tests--sources 3))
           (result (cl-letf (((symbol-function 'message) #'ignore))
                     (claude-code-ide-handover-worktree
                      ids 'cci-test-b 'fresh
                      (mapcar (lambda (id) (cons id (concat id "-context"))) ids) nil 'no nil))))
      (should (eq (plist-get result :status) 'running))
      (cl-letf (((symbol-function 'message) #'ignore))
        (cl-loop for source in ids
                 for n from 1
                 do (claude-code-ide-handover-tests--run-timers)
                 (let* ((id (claude-code-ide-handover-tests--current))
                        (status (claude-code-ide-handover-status id))
                        (text (with-temp-buffer
                                (insert-file-contents (plist-get status :document))
                                (buffer-string))))
                   ;; One unfinished handover; the earlier ones committed
                   (should (= (hash-table-count claude-code-ide-handover--runs) n))
                   (should (= (claude-code-ide-handover-tests--unfinished) 1))
                   (should (equal (plist-get status :source-id) source))
                   (should (string-search (concat source "-context") text))
                   (dolist (other (remove source ids))
                     (should-not (string-search (concat other "-context") text)))
                   (claude-code-ide-handover-tests--deliver (list :handover-id id))
                   (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'committed)))))
      (should-not (claude-code-ide-handover-tests--batch))
      (should-not (claude-code-ide-handover-tests--live-of 'cci-test-a))
      (should (= (length (claude-code-ide-handover-tests--live-of 'cci-test-b)) 3)))))

(ert-deftest claude-code-ide-test-handover-worktree-stops-at-user-cancel ()
  "A cancel of the person stops the batch; the end message lists all three kinds."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 3))
          (messages nil))
      (claude-code-ide-handover-tests--set-state "cci-test-s2" 'working)
      (claude-code-ide-tests--collect-messages messages
        (claude-code-ide-handover-worktree ids 'cci-test-b 'fresh nil nil 'no nil)
        (let* ((first (claude-code-ide-handover-tests--deliver-current))
               (target (plist-get (claude-code-ide-handover-status first) :target-id))
               (second (claude-code-ide-handover-tests--current)))
          (should-not (equal first second))
          (claude-code-ide-handover-cancel second)
          (claude-code-ide-handover-tests--run-timers 3)
          (should (= (hash-table-count claude-code-ide-handover--runs) 2))
          (should-not (claude-code-ide-handover-tests--batch))
          (should (claude-code-ide-instance-by-id "cci-test-s3"))
          (let ((end (cl-find-if (lambda (m) (string-match-p "Handover batch in .* ended" m)) messages)))
            (should (string-search (format "Handed over: %s -> %s"
                                           (claude-code-ide-handover-tests--label "cci-test-s1") target)
                                   end))
            (should (string-search (format "Stopped at, and not started: %s (user-cancelled); %s"
                                           (claude-code-ide-handover-tests--label "cci-test-s2")
                                           (claude-code-ide-handover-tests--label "cci-test-s3"))
                                   end))
            (should (string-search "M-x claude-code-ide-handover-worktree hands over the rest" end))))))))

(ert-deftest claude-code-ide-test-handover-worktree-skips-automatic ()
  "An automatic cancel and a not-running source are skipped; the batch goes on."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 4))
          (messages nil))
      (claude-code-ide-handover-tests--set-state "cci-test-s2" 'working)
      (claude-code-ide-tests--collect-messages messages
        (claude-code-ide-handover-worktree ids 'cci-test-b 'fresh nil nil 'no nil)
        (claude-code-ide-instance-unregister "cci-test-s3")
        (claude-code-ide-handover-tests--deliver-current)
        ;; The second waits for an idle source, then gets a background task
        (let ((second (claude-code-ide-handover-tests--current)))
          (claude-code-ide-handover-tests--set-state "cci-test-s2" 'waiting-for-task 'background-task)
          (claude-code-ide-handover-tests--run-timers 3)
          (should (eq (plist-get (claude-code-ide-handover-status second) :reason) 'busy)))
        ;; The fourth runs now
        (let ((fourth (claude-code-ide-handover-tests--deliver-current)))
          (should (equal (plist-get (claude-code-ide-handover-status fourth) :source-id) "cci-test-s4"))
          (should (eq (plist-get (claude-code-ide-handover-status fourth) :status) 'committed)))
        (should-not (claude-code-ide-handover-tests--batch))
        (let ((end (cl-find-if (lambda (m) (string-match-p "Handover batch in .* ended" m)) messages)))
          (should (string-search (format "Skipped: %s (busy), %s (not-running)"
                                         (claude-code-ide-handover-tests--label "cci-test-s2")
                                         (claude-code-ide-handover-tests--label "cci-test-s3"))
                                 end)))))))

(ert-deftest claude-code-ide-test-handover-worktree-waits-for-person ()
  "The batch waits at needs-user, says so once, and goes on after the person resolves it."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 2))
          (messages nil)
          (stray '((:pid 4949 :command "sleep 600" :cwd "/x" :reason worktree))))
      (setq claude-code-ide-handover-tests--stop-result (list :status 'strays :strays stray)
            claude-code-ide-handover-tests--scan-strays stray)
      (cl-letf (((symbol-function 'claude-code-ide-handover--stray-alive-p) (lambda (_) t))
                ((symbol-function 'signal-process) (lambda (&rest _) 0)))
        (claude-code-ide-tests--collect-messages messages
          (claude-code-ide-handover-worktree ids 'cci-test-b 'fresh nil nil 'no nil)
          (claude-code-ide-handover-tests--run-timers)
          (let ((first (claude-code-ide-handover-tests--current))
                (waits (lambda () (cl-count-if (lambda (m) (string-prefix-p "Handover batch waits at" m))
                                               messages))))
            (should (eq (plist-get (claude-code-ide-handover-status first) :status) 'needs-user))
            (should (= (funcall waits) 1))
            (should (string-search (format "waits at %s: strays"
                                           (claude-code-ide-handover-tests--label "cci-test-s1"))
                                   (cl-find-if (lambda (m) (string-prefix-p "Handover batch waits" m))
                                               messages)))
            ;; A second needs-user of the same handover: no second message
            (claude-code-ide-handover-resolve first 'wait)
            (claude-code-ide-handover-tests--run-timers)
            (should (eq (plist-get (claude-code-ide-handover-status first) :status) 'needs-user))
            (should (= (funcall waits) 1))
            (should (= (hash-table-count claude-code-ide-handover--runs) 1))
            ;; End the strays: the first commits, and the second starts
            (setq claude-code-ide-handover-tests--scan-strays nil
                  claude-code-ide-handover-tests--stop-result '(:status stopped))
            (claude-code-ide-handover-resolve first 'end)
            (claude-code-ide-handover-tests--run-timers)
            (claude-code-ide-handover-tests--deliver (list :handover-id first))
            (should (eq (plist-get (claude-code-ide-handover-status first) :status) 'committed))
            (should (= (hash-table-count claude-code-ide-handover--runs) 2))
            (should (equal (plist-get (claude-code-ide-handover-status
                                       (claude-code-ide-handover-tests--current))
                                      :source-id)
                           "cci-test-s2"))))))))

(ert-deftest claude-code-ide-test-handover-worktree-needs-ended ()
  "A late needs-user step after a failed final save does not advance the batch.
The run is committed in memory, but its end never reached the status
functions (`ended' is nil), so the batch waits."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 2))
          (messages nil)
          (stray '((:pid 4949 :command "sleep 600" :cwd "/x" :reason worktree))))
      (setq claude-code-ide-handover-tests--stop-result (list :status 'strays :strays stray))
      (claude-code-ide-tests--collect-messages messages
        (claude-code-ide-handover-worktree ids 'cci-test-b 'fresh nil nil 'no nil)
        ;; The step of the needs-user notification waits in the queue
        (claude-code-ide-handover-tests--run-timers nil #'claude-code-ide-handover--batch-step)
        (let* ((batch (claude-code-ide-handover-tests--batch))
               (first (claude-code-ide-handover-tests--current))
               (run (gethash first claude-code-ide-handover--runs)))
          (should (eq (claude-code-ide-handover--run-status run) 'needs-user))
          (cl-letf (((symbol-function 'claude-code-ide-handover--save) #'ignore))
            (claude-code-ide-handover--finish run 'committed nil "cci-test"))
          (should-not (claude-code-ide-handover--run-ended run))
          (claude-code-ide-handover-tests--run-timers)
          (should (eq (claude-code-ide-handover-tests--batch) batch))
          (should (equal (claude-code-ide-handover-tests--current) first))
          (should (equal (claude-code-ide-handover--batch-sources batch) '("cci-test-s2")))
          (should-not (claude-code-ide-handover--batch-done batch))
          (should (= (hash-table-count claude-code-ide-handover--runs) 1)))))))

;; The end message of the batch of the test worktree
(defun claude-code-ide-handover-tests--end-message (messages)
  "Return the end message of a batch in MESSAGES, or nil."
  (cl-find-if (lambda (m) (string-match-p "Handover batch in .* ended" m)) messages))

(ert-deftest claude-code-ide-test-handover-worktree-start-error ()
  "An error at the start of a source ends the batch with the usual report.
The handover that ran before it stays committed."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 2))
          (messages nil)
          (session (symbol-function 'claude-code-ide-handover-session)))
      (cl-letf (((symbol-function 'claude-code-ide-handover-session)
                 (lambda (source &rest args)
                   (if (equal source "cci-test-s2")
                       (error "cci-test-start-broke")
                     (apply session source args)))))
        (claude-code-ide-tests--collect-messages messages
          (claude-code-ide-handover-worktree ids 'cci-test-b 'fresh nil nil 'no nil)
          (let ((first (claude-code-ide-handover-tests--deliver-current)))
            (should (eq (plist-get (claude-code-ide-handover-status first) :status) 'committed)))))
      (should-not (claude-code-ide-handover-tests--batch))
      (should (= (hash-table-count claude-code-ide-handover--runs) 1))
      (should (string-search (format "Stopped at, and not started: %s (error: cci-test-start-broke)"
                                     (claude-code-ide-handover-tests--label "cci-test-s2"))
                             (claude-code-ide-handover-tests--end-message messages))))))

(ert-deftest claude-code-ide-test-handover-worktree-one-tree ()
  "A live source in another working tree refuses the batch before any change."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--sources 1)
    (claude-code-ide-handover-tests--add "cci-test-far" 'cci-test-a
                                         (claude-code-ide-handover-tests--other "proj2") 'idle)
    (let ((err (should-error (claude-code-ide-handover-worktree '("cci-test-s1" "cci-test-far") 'cci-test-b)
                             :type 'user-error)))
      (should (string-match-p "cci-test-far" (cadr err))))
    (should-not (claude-code-ide-handover-tests--batch))
    (should (= (hash-table-count claude-code-ide-handover--runs) 0))))

(ert-deftest claude-code-ide-test-handover-worktree-stop-after-end ()
  "A stop or a drop between the end of a handover and the next step records it.
The report and the drop message list that source, and nothing more starts."
  (dolist (how '(stop drop))
    (claude-code-ide-handover-tests--with
      (let ((messages nil))
        (claude-code-ide-handover-tests--sources 3)
        (claude-code-ide-tests--collect-messages messages
          (claude-code-ide-handover-worktree '("cci-test-s1" "cci-test-s2") 'cci-test-b 'fresh nil nil 'no
                                             '("cci-test-s3"))
          (claude-code-ide-handover-tests--run-timers)
          (let* ((spec (car claude-code-ide-handover-tests--starts))
                 (target (claude-code-ide-start-spec-instance-id spec)))
            (claude-code-ide-handover-tests--event
             target 'prompt-submit (list (cons 'prompt (claude-code-ide-start-spec-prompt spec))))
            (claude-code-ide-handover-tests--run-timers nil #'claude-code-ide-handover--batch-step)
            (if (eq how 'stop)
                (claude-code-ide-handover-worktree-stop (claude-code-ide-handover--directory-key worktree))
              (claude-code-ide-handover-worktree '("cci-test-s3") 'cci-test-b 'fresh nil nil 'no
                                                 (list target "cci-test-s2"))
              (should (cl-some (lambda (m)
                                 (string-search (format "dropped at %s"
                                                        (claude-code-ide-handover-tests--label "cci-test-s1"))
                                                m))
                               messages)))
            (claude-code-ide-handover-tests--run-timers 3)
            (should (string-search (format "Handed over: %s -> %s"
                                           (claude-code-ide-handover-tests--label "cci-test-s1") target)
                                   (claude-code-ide-handover-tests--end-message messages)))
            (should (string-search (format "not started: %s"
                                           (claude-code-ide-handover-tests--label "cci-test-s2"))
                                   (claude-code-ide-handover-tests--end-message messages)))
            ;; No handover of cci-test-s2
            (should-not (cl-some (lambda (run) (equal (claude-code-ide-handover--run-source-id run) "cci-test-s2"))
                                 (hash-table-values claude-code-ide-handover--runs)))))))))

(ert-deftest claude-code-ide-test-handover-worktree-entry-missing ()
  "A missing registry entry makes the batch wait with its message; the stop ends it.
The run stays at needs-user for `claude-code-ide-handover-resolve'."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 2))
          (messages nil))
      (claude-code-ide-tests--collect-messages messages
        (claude-code-ide-handover-worktree ids 'cci-test-b 'fresh nil nil 'no nil)
        (claude-code-ide-session-registry--submit
         "forget" (claude-code-ide-session-registry--change-forgotten "cci-test-s1"))
        (claude-code-ide-handover-tests--run-timers 50)
        (let ((first (claude-code-ide-handover-tests--current)))
          (should (eq (plist-get (claude-code-ide-handover-status first) :reason) 'registry-entry-missing))
          (should (cl-some (lambda (m)
                             (string-search (format "waits at %s: registry-entry-missing"
                                                    (claude-code-ide-handover-tests--label "cci-test-s1"))
                                            m))
                           messages))
          (claude-code-ide-handover-worktree-stop (claude-code-ide-handover--directory-key worktree))
          (claude-code-ide-handover-tests--run-timers)
          (should-not (claude-code-ide-handover-tests--batch))
          (should (eq (plist-get (claude-code-ide-handover-status first) :status) 'needs-user))
          (should (= (hash-table-count claude-code-ide-handover--runs) 1))
          (should (string-search (format "Stopped at, and not started: %s (handover %s needs-user); %s"
                                         (claude-code-ide-handover-tests--label "cci-test-s1") first
                                         (claude-code-ide-handover-tests--label "cci-test-s2"))
                                 (claude-code-ide-handover-tests--end-message messages))))))))

(ert-deftest claude-code-ide-test-handover-worktree-codex-untrusted ()
  "A source that the Codex hook trust refuses waits for the retry; the batch goes on."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 2))
          (checks 0))
      (cl-letf (((symbol-function 'claude-code-ide-handover--target-available-p) (lambda (_) t))
                ;; The trust of the first check ran out
                ((symbol-function 'claude-code-ide-handover--codex-trusted-p)
                 (lambda (_directory interactive)
                   (should-not interactive)
                   (> (cl-incf checks) 1)))
                ((symbol-function 'message) #'ignore))
        (claude-code-ide-handover-worktree ids 'codex 'fresh nil nil 'no nil))
      (let ((batch (claude-code-ide-handover-tests--batch)))
        (should-not (claude-code-ide-handover--batch-skipped batch))
        (should (equal (claude-code-ide-handover--batch-retry batch) '("cci-test-s1")))
        (should (equal (claude-code-ide-handover--batch-current-source batch) "cci-test-s2"))))))

(defvar claude-code-ide-handover-tests--untrusted nil
  "Source IDs whose preflight gives hooks-not-trusted, in the retry tests.")

(defun claude-code-ide-handover-tests--retry-batch (sources &optional before after)
  "Run a batch of SOURCES, with some sources of unknown hook trust.
The sources in `claude-code-ide-handover-tests--untrusted' get
hooks-not-trusted from the preflight.  Deliver each handover that
starts.  BEFORE runs before the first delivery, AFTER after it.  Return
the messages, newest first, and the source IDs of the handover calls,
oldest first, as (MESSAGES . CALLS)."
  (let ((messages nil)
        (calls nil)
        (preflight (symbol-function 'claude-code-ide-handover--preflight))
        (session (symbol-function 'claude-code-ide-handover-session)))
    (cl-letf (((symbol-function 'claude-code-ide-handover--preflight)
               (lambda (instance &rest args)
                 (if (member (claude-code-ide-instance-id instance)
                             claude-code-ide-handover-tests--untrusted)
                     (claude-code-ide-handover--error
                      'hooks-not-trusted "cci-test: not trusted" (claude-code-ide-instance-id instance))
                   (apply preflight instance args))))
              ((symbol-function 'claude-code-ide-handover-session)
               (lambda (source &rest args)
                 (setq calls (append calls (list source)))
                 (apply session source args))))
      (claude-code-ide-tests--collect-messages messages
        (claude-code-ide-handover-worktree sources 'cci-test-b 'fresh nil nil 'no nil)
        (when before (funcall before))
        (claude-code-ide-handover-tests--deliver-current)
        (when after (funcall after))
        (while (and (claude-code-ide-handover-tests--batch)
                    (claude-code-ide-handover-tests--current)
                    (claude-code-ide-handover--unfinished-p
                     (gethash (claude-code-ide-handover-tests--current) claude-code-ide-handover--runs)))
          (claude-code-ide-handover-tests--deliver-current))))
    (cons messages calls)))

(ert-deftest claude-code-ide-test-handover-worktree-retry-trusted ()
  "A source refused with hooks-not-trusted is tried once more at the end, and hands over."
  (claude-code-ide-handover-tests--with
    (let* ((ids (claude-code-ide-handover-tests--sources 2))
           (claude-code-ide-handover-tests--untrusted '("cci-test-s1"))
           (out (claude-code-ide-handover-tests--retry-batch
                 ids (lambda () (setq claude-code-ide-handover-tests--untrusted nil))))
           (end (claude-code-ide-handover-tests--end-message (car out))))
      (should (equal (cdr out) '("cci-test-s1" "cci-test-s2" "cci-test-s1")))
      (should-not (claude-code-ide-handover-tests--batch))
      (should-not (claude-code-ide-handover-tests--live-of 'cci-test-a))
      (should (string-match-p (format "%s -> [^,]+ (in the retry)"
                                      (regexp-quote (claude-code-ide-handover-tests--label "cci-test-s1")))
                              end))
      (should (string-search "Skipped: none" end)))))

(ert-deftest claude-code-ide-test-handover-worktree-retry-refused-again ()
  "A source refused again in the retry is skipped with the reason, and the batch ends."
  (claude-code-ide-handover-tests--with
    (let* ((ids (claude-code-ide-handover-tests--sources 2))
           (claude-code-ide-handover-tests--untrusted '("cci-test-s1"))
           (out (claude-code-ide-handover-tests--retry-batch ids))
           (end (claude-code-ide-handover-tests--end-message (car out))))
      (should (equal (cdr out) '("cci-test-s1" "cci-test-s2" "cci-test-s1")))
      (should-not (claude-code-ide-handover-tests--batch))
      (should (claude-code-ide-instance-by-id "cci-test-s1"))
      (should (string-search (format "Skipped: %s (hooks-not-trusted)"
                                     (claude-code-ide-handover-tests--label "cci-test-s1"))
                             end)))))

(ert-deftest claude-code-ide-test-handover-worktree-retry-only-trust ()
  "A source skipped for another reason is not tried again."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 2)))
      (claude-code-ide-handover-tests--set-state "cci-test-s1" 'waiting-for-task 'subagent)
      (let* ((out (claude-code-ide-handover-tests--retry-batch ids))
             (end (claude-code-ide-handover-tests--end-message (car out))))
        (should (equal (cdr out) '("cci-test-s1" "cci-test-s2")))
        (should-not (claude-code-ide-handover-tests--batch))
        (should (string-search (format "Skipped: %s (busy)"
                                       (claude-code-ide-handover-tests--label "cci-test-s1"))
                               end))))))

(ert-deftest claude-code-ide-test-handover-worktree-retry-stop ()
  "A stop in the retry starts nothing more; the rest of the retry is not started."
  (claude-code-ide-handover-tests--with
    (let* ((ids (claude-code-ide-handover-tests--sources 3))
           (claude-code-ide-handover-tests--untrusted '("cci-test-s1" "cci-test-s3"))
           (out (claude-code-ide-handover-tests--retry-batch
                 ids (lambda () (setq claude-code-ide-handover-tests--untrusted '("cci-test-s3")))
                 (lambda ()
                   ;; The retry runs s1 now; stop, then trust s3 too
                   (should (equal (plist-get (claude-code-ide-handover-status
                                              (claude-code-ide-handover-tests--current))
                                             :source-id)
                                  "cci-test-s1"))
                   (claude-code-ide-handover-worktree-stop
                    (claude-code-ide-handover--directory-key (claude-code-ide-handover-tests--worktree)))
                   (setq claude-code-ide-handover-tests--untrusted nil))))
           (end (claude-code-ide-handover-tests--end-message (car out))))
      (should (equal (cdr out) '("cci-test-s1" "cci-test-s2" "cci-test-s3" "cci-test-s1")))
      (should-not (claude-code-ide-handover-tests--batch))
      (should (claude-code-ide-instance-by-id "cci-test-s3"))
      (should (string-search (format "not started: %s" (claude-code-ide-handover-tests--label "cci-test-s3"))
                             end)))))

(ert-deftest claude-code-ide-test-handover-worktree-method-per-chain ()
  "With fork, a source whose chain has a conversation of the target forks; another starts fresh."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 2)))
      (claude-code-ide-session-registry-save-chain
       "cci-test-s1"
       (list (list :provider 'cci-test-b :instance-id "cci-test-l1" :native-id "cci-test-b-old")
             (list :provider 'cci-test-a :instance-id "cci-test-s1" :native-id "cci-test-s1-native")))
      (cl-letf (((symbol-function 'message) #'ignore))
        (claude-code-ide-handover-worktree ids 'cci-test-b 'fork nil nil 'no nil)
        (claude-code-ide-handover-tests--deliver-current)
        (claude-code-ide-handover-tests--deliver-current))
      (let ((specs (reverse claude-code-ide-handover-tests--starts)))
        (should (= (length specs) 2))
        (should (claude-code-ide-start-spec-fork (nth 0 specs)))
        (should (equal (claude-code-ide-start-spec-resume-id (nth 0 specs)) "cci-test-b-old"))
        (should-not (claude-code-ide-start-spec-fork (nth 1 specs)))))))

(ert-deftest claude-code-ide-test-handover-worktree-questions-once ()
  "The batch asks each question once, before the first handover; its handovers ask nothing."
  (claude-code-ide-handover-tests--with
    (let ((claude-code-ide-handover-continue 'ask))
      (claude-code-ide-handover-tests--sources 2)
      (claude-code-ide-handover-tests--set-state "cci-test-s1" 'working)
      (claude-code-ide-handover-tests--add "cci-test-plan" 'cci-test-b worktree 'idle)
      (claude-code-ide-session-registry-save-chain
       "cci-test-s1"
       (list (list :provider 'cci-test-b :instance-id "cci-test-l1" :native-id "cci-test-b-old")
             (list :provider 'cci-test-a :instance-id "cci-test-s1" :native-id "cci-test-s1-native")))
      (claude-code-ide-handover-tests--with-questions
          `((read-multiple-choice . ,(lambda (prompt) (if (string-prefix-p "How should" prompt) ?n ?y))))
        (let ((args (claude-code-ide-handover--read-batch-args)))
          (should (= (length (claude-code-ide-handover-tests--asked questions 'completing-read)) 1))
          (should (= (length (claude-code-ide-handover-tests--asked questions 'completing-read-multiple))
                     1))
          (should (equal (claude-code-ide-handover-tests--asked questions 'read-string)
                         (mapcar (lambda (id) (format "Context for %s (empty for none): "
                                                      (claude-code-ide-handover-tests--label id)))
                                 '("cci-test-s1" "cci-test-s2"))))
          (should (= (length (claude-code-ide-handover-tests--asked questions 'read-multiple-choice)) 2))
          (let ((asked (claude-code-ide-handover-tests--asked questions 'y-or-n-p)))
            (should (= (length asked) 2))
            ;; The others question lists only the sessions outside the batch
            (should (string-search "cci-test-plan" (nth 0 asked)))
            (should-not (string-search "cci-test-s2 (" (nth 0 asked)))
            (should (string-search "The targets of the batch also run here." (nth 0 asked)))
            (should (string-prefix-p "Interrupt a busy session" (nth 1 asked))))
          (should (equal args '(("cci-test-s1" "cci-test-s2") cci-test-b fresh nil t yes
                                ("cci-test-plan"))))
          ;; The handovers of the batch ask nothing
          (setq questions nil)
          (claude-code-ide-handover-tests--set-state "cci-test-s1" 'idle)
          (cl-letf (((symbol-function 'message) #'ignore))
            (apply #'claude-code-ide-handover-worktree args)
            (claude-code-ide-handover-tests--deliver-current)
            (claude-code-ide-handover-tests--deliver-current))
          (should (= (hash-table-count claude-code-ide-handover--runs) 2))
          (should-not questions))))
    ;; Idle sources: no interrupt question.  C-u: no others question,
    ;; and the sessions that it would list are confirmed
    (claude-code-ide-handover-tests--with
      (claude-code-ide-handover-tests--sources 2)
      (claude-code-ide-handover-tests--add "cci-test-plan" 'cci-test-b worktree 'idle)
      (claude-code-ide-handover-tests--with-questions nil
        (let* ((current-prefix-arg '(4))
               (args (claude-code-ide-handover--read-batch-args)))
          (should-not (claude-code-ide-handover-tests--asked questions 'y-or-n-p))
          (should (equal (nth 6 args) '("cci-test-plan"))))))
    ;; A Codex target: the hook trust is settled once, with the question
    (claude-code-ide-handover-tests--with
      (claude-code-ide-handover-tests--sources 2)
      (let ((trust nil))
        (cl-letf (((symbol-function 'claude-code-ide-handover--codex-trusted-p)
                   (lambda (directory interactive) (push (list directory interactive) trust) t)))
          (claude-code-ide-handover-tests--with-questions '((completing-read . "codex"))
            (should (eq (nth 1 (claude-code-ide-handover--read-batch-args)) 'codex))))
        (should (equal trust (list (list (claude-code-ide-handover--directory-key worktree) t))))))))

(ert-deftest claude-code-ide-test-handover-worktree-rest-only ()
  "After a stop, the command offers only the live sources that are not of the target provider."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 3))
          (offered nil))
      (cl-letf (((symbol-function 'message) #'ignore))
        (claude-code-ide-handover-worktree ids 'cci-test-b 'fresh nil nil 'no nil)
        (claude-code-ide-handover-worktree-stop
         (claude-code-ide-handover--directory-key worktree))
        (claude-code-ide-handover-tests--deliver-current))
      (should-not (claude-code-ide-handover-tests--batch))
      (claude-code-ide-handover-tests--with-questions nil
        (cl-letf (((symbol-function 'completing-read-multiple)
                   (lambda (_prompt collection &rest _)
                     (setq offered (mapcar #'car collection))
                     nil)))
          (should (equal (car (claude-code-ide-handover--read-batch-args))
                         '("cci-test-s2" "cci-test-s3")))))
      (should (equal offered (mapcar #'claude-code-ide-handover-tests--label
                                     '("cci-test-s2" "cci-test-s3")))))))

(ert-deftest claude-code-ide-test-handover-worktree-one-per-worktree ()
  "A second batch in the worktree is refused; a stale batch is dropped."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--sources 4 'working)
    (cl-letf (((symbol-function 'message) #'ignore))
      (let* ((start (lambda (source)
                      ;; The other sources are confirmed, as the question does
                      (claude-code-ide-handover-worktree
                       (list source) 'cci-test-b 'fresh nil nil 'no
                       (remove source '("cci-test-s1" "cci-test-s2" "cci-test-s3" "cci-test-s4")))))
             (quiet-cancel (lambda (id)
                             ;; A final run whose end reached no batch
                             (let ((claude-code-ide-handover--status-functions nil))
                               (claude-code-ide-handover-cancel id)))))
        (funcall start "cci-test-s1")
        (let ((a (claude-code-ide-handover-tests--batch)))
          (should-error (funcall start "cci-test-s2")
                        :type 'user-error)
          (should (eq (claude-code-ide-handover-tests--batch) a))
          ;; Final
          (funcall quiet-cancel (claude-code-ide-handover-tests--current))
          (funcall start "cci-test-s2")
          (let ((b (claude-code-ide-handover-tests--batch)))
            (should (claude-code-ide-handover--batch-dead a))
            (should-not (eq b a))
            (should (equal (plist-get (claude-code-ide-handover-status (claude-code-ide-handover-tests--current))
                                      :source-id)
                           "cci-test-s2"))
            ;; Gone
            (funcall quiet-cancel (claude-code-ide-handover-tests--current))
            (setf (claude-code-ide-handover--batch-current b) "cci-test-gone")
            (funcall start "cci-test-s3")
            (let ((c (claude-code-ide-handover-tests--batch)))
              (should (claude-code-ide-handover--batch-dead b))
              (should-not (eq c b))
              ;; Owned by another Emacs, which claimed the run
              (cl-letf (((symbol-function 'claude-code-ide-session-registry--handover-owner)
                         (lambda (_) 'other)))
                (funcall start "cci-test-s4"))
              (should (claude-code-ide-handover--batch-dead c)))))))))

(ert-deftest claude-code-ide-test-handover-worktree-stale-timer ()
  "An old timer of a dropped or stopped batch never moves the new batch."
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--sources 3)
    (cl-letf (((symbol-function 'message) #'ignore))
      (claude-code-ide-handover-worktree '("cci-test-s1" "cci-test-s2") 'cci-test-b 'fresh nil nil 'no
                                         '("cci-test-s3"))
      (claude-code-ide-handover-tests--run-timers)
      (let ((a (claude-code-ide-handover-tests--batch))
            (first (claude-code-ide-handover-tests--current))
            (spec (car claude-code-ide-handover-tests--starts)))
        ;; The commit queues the advance of A, which does not run yet
        (claude-code-ide-handover-tests--event
         (claude-code-ide-start-spec-instance-id spec) 'prompt-submit
         (list (cons 'prompt (claude-code-ide-start-spec-prompt spec))))
        (claude-code-ide-handover-tests--run-timers nil #'claude-code-ide-handover--batch-step)
        (should (eq (plist-get (claude-code-ide-handover-status first) :status) 'committed))
        (let ((old (cl-find #'claude-code-ide-handover--batch-step claude-code-ide-handover-tests--timers
                            :key #'car)))
          (should old)
          (setq claude-code-ide-handover-tests--timers (remq old claude-code-ide-handover-tests--timers))
          ;; The command drops A, and starts B
          (claude-code-ide-handover-worktree '("cci-test-s2" "cci-test-s3") 'cci-test-b 'fresh nil nil 'no
                                             (list (plist-get (claude-code-ide-handover-status first)
                                                              :target-id)))
          (let* ((b (claude-code-ide-handover-tests--batch))
                 (current (claude-code-ide-handover--batch-current b)))
            (should-not (eq a b))
            ;; B's run is final, so its source could start again, and A
            ;; still names its first handover: only the `eq' and `dead'
            ;; guards keep the old timer from moving A
            (let ((claude-code-ide-handover--status-functions nil))
              (claude-code-ide-handover-cancel current))
            (setf (claude-code-ide-handover--batch-current a) first
                  (claude-code-ide-handover--batch-stop a) nil)
            (dotimes (_ 2)
              (apply (car old) (cdr old))
              (should (eq (claude-code-ide-handover-tests--batch) b))
              (should (equal (claude-code-ide-handover--batch-current b) current))
              (should (equal (claude-code-ide-handover--batch-sources b) '("cci-test-s3")))
              (should (= (hash-table-count claude-code-ide-handover--runs) 2))))))))
  ;; The stop command before the old timer runs
  (claude-code-ide-handover-tests--with
    (claude-code-ide-handover-tests--sources 2)
    (cl-letf (((symbol-function 'message) #'ignore))
      (claude-code-ide-handover-worktree '("cci-test-s1" "cci-test-s2") 'cci-test-b 'fresh nil nil 'no nil)
      (claude-code-ide-handover-tests--run-timers)
      (let ((spec (car claude-code-ide-handover-tests--starts)))
        (claude-code-ide-handover-tests--event
         (claude-code-ide-start-spec-instance-id spec) 'prompt-submit
         (list (cons 'prompt (claude-code-ide-start-spec-prompt spec))))
        (claude-code-ide-handover-tests--run-timers nil #'claude-code-ide-handover--batch-step)
        (claude-code-ide-handover-worktree-stop (claude-code-ide-handover--directory-key worktree))
        (should-not (claude-code-ide-handover-tests--batch))
        (claude-code-ide-handover-tests--run-timers)
        (should-not (claude-code-ide-handover-tests--batch))
        (should (= (hash-table-count claude-code-ide-handover--runs) 1))))))

(ert-deftest claude-code-ide-test-handover-worktree-stop-command ()
  "The stop command lets the current handover end, and starts no other one."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 3))
          (messages nil))
      (claude-code-ide-tests--collect-messages messages
        (claude-code-ide-handover-worktree ids 'cci-test-b 'fresh nil nil 'no nil)
        (claude-code-ide-handover-tests--run-timers)
        (claude-code-ide-handover-worktree-stop (claude-code-ide-handover--directory-key worktree))
        (should (claude-code-ide-handover-tests--batch))
        (let ((first (claude-code-ide-handover-tests--deliver-current)))
          (should (eq (plist-get (claude-code-ide-handover-status first) :status) 'committed)))
        (should (= (hash-table-count claude-code-ide-handover--runs) 1))
        (should-not (claude-code-ide-handover-tests--batch))
        (should (string-search (format "Stopped at, and not started: %s, %s"
                                       (claude-code-ide-handover-tests--label "cci-test-s2")
                                       (claude-code-ide-handover-tests--label "cci-test-s3"))
                               (cl-find-if (lambda (m) (string-match-p "Handover batch in .* ended" m))
                                           messages)))))))

(ert-deftest claude-code-ide-test-handover-worktree-new-session-stops ()
  "A session that starts after the questions stops the batch before the next handover.
The confirmed sessions and the targets of the batch do not stop it."
  (dolist (new '(nil t))
    (claude-code-ide-handover-tests--with
      (let ((ids (claude-code-ide-handover-tests--sources 2))
            (messages nil))
        (claude-code-ide-handover-tests--add "cci-test-plan" 'cci-test-b worktree 'idle)
        (claude-code-ide-tests--collect-messages messages
          (claude-code-ide-handover-worktree ids 'cci-test-b 'fresh nil nil 'no '("cci-test-plan"))
          (when new
            (claude-code-ide-handover-tests--add "cci-test-new" 'cci-test-b worktree 'idle))
          (claude-code-ide-handover-tests--deliver-current)
          (if (not new)
              (progn
                (claude-code-ide-handover-tests--deliver-current)
                (should (= (hash-table-count claude-code-ide-handover--runs) 2))
                (should-not (claude-code-ide-handover-tests--live-of 'cci-test-a)))
            (should (= (hash-table-count claude-code-ide-handover--runs) 1))
            (should-not (claude-code-ide-handover-tests--batch))
            (should (claude-code-ide-instance-by-id "cci-test-s2"))
            (should (string-search "cci-test-new (cci-test-b, cci-test-new)"
                                   (cl-find-if (lambda (m) (string-match-p "Handover batch in .* ended" m))
                                               messages)))))))))

(ert-deftest claude-code-ide-test-handover-worktree-document-names-next ()
  "The document of the first handover marks the sources that the batch hands over next."
  (claude-code-ide-handover-tests--with
    (let ((ids (claude-code-ide-handover-tests--sources 3)))
      (cl-letf (((symbol-function 'message) #'ignore))
        (claude-code-ide-handover-worktree ids 'cci-test-b 'fresh nil nil 'no nil)
        (claude-code-ide-handover-tests--run-timers))
      (let ((part (claude-code-ide-handover-tests--others-part (claude-code-ide-handover-tests--current))))
        (dolist (id '("cci-test-s2" "cci-test-s3"))
          (should (string-search (format "- %s: idle; handed over by this batch next"
                                         (claude-code-ide-handover-tests--label id))
                                 part)))))))

;;; The status hook

(defun claude-code-ide-handover-tests--hook-call (run)
  "Return (STATUS SAVED-STATUS HELD) of RUN for a call of the status hook.
They are the status of RUN, the status in its registry record, and
whether its source is held."
  (let ((source (claude-code-ide-handover--run-source-id run)))
    (list (claude-code-ide-handover--run-status run)
          (alist-get 'status (claude-code-ide-handover-tests--record source))
          (and (member source claude-code-ide-control--held) t))))

(ert-deftest claude-code-ide-test-handover-status-hook-once ()
  "The status hook runs once at the end of each run, after the save and the release.
It runs for a commit, a cancel and the skip of a source without a
registry entry, never after a final save that fails, and at each entry
into needs-user."
  (claude-code-ide-handover-tests--with
    (let* ((calls nil)
           (messages nil)
           (claude-code-ide-handover--status-functions
            (list (lambda (run) (push (claude-code-ide-handover-tests--hook-call run) calls)))))
      (claude-code-ide-tests--collect-messages messages
        ;; A commit
        (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
        (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)))
          (claude-code-ide-handover-tests--run-timers)
          (should-not calls)
          (claude-code-ide-handover-tests--deliver result)
          (should (equal calls '((committed "committed" nil))))
          ;; Nothing ends it twice
          (claude-code-ide-handover--finish
           (gethash (plist-get result :handover-id) claude-code-ide-handover--runs) 'committed nil)
          (should (= (length calls) 1)))
        ;; A cancel
        (setq calls nil)
        (claude-code-ide-handover-tests--add "cci-test-src2" 'cci-test-a
                                             (claude-code-ide-handover-tests--other "proj2") 'working)
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src2" 'cci-test-b) :handover-id)))
          (claude-code-ide-handover-tests--run-timers 3)
          (claude-code-ide-handover-cancel id)
          (should (equal calls '((cancelled "cancelled" nil)))))
        ;; A final save that fails runs no hook; a later end runs it
        (setq calls nil)
        (claude-code-ide-handover-tests--add "cci-test-src3" 'cci-test-a
                                             (claude-code-ide-handover-tests--other "proj3") 'working)
        (let* ((id (plist-get (claude-code-ide-handover-session "cci-test-src3" 'cci-test-b) :handover-id))
               (run (gethash id claude-code-ide-handover--runs)))
          (claude-code-ide-handover-tests--run-timers 3)
          (cl-letf (((symbol-function 'claude-code-ide-handover--save) #'ignore))
            (claude-code-ide-handover--finish run 'cancelled 'user-cancelled "cci-test"))
          (should-not calls)
          (claude-code-ide-handover--finish run 'cancelled 'user-cancelled "cci-test")
          (should (= (length calls) 1)))
        ;; Each entry into needs-user
        (setq calls nil)
        (claude-code-ide-handover-tests--add "cci-test-src4" 'cci-test-a
                                             (claude-code-ide-handover-tests--other "proj4") 'idle)
        (setq claude-code-ide-handover-tests--stop-result
              '(:status strays :strays ((:pid 4848 :command "sleep 600" :cwd "/x" :reason worktree)))
              claude-code-ide-handover-tests--scan-strays
              '((:pid 4848 :command "sleep 600" :cwd "/x" :reason worktree)))
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src4" 'cci-test-b) :handover-id)))
          (claude-code-ide-handover-tests--run-timers)
          (should (equal calls '((needs-user "needs-user" t))))
          (claude-code-ide-handover-resolve id 'wait)
          (claude-code-ide-handover-tests--run-timers)
          (should (equal (mapcar #'car calls) '(needs-user needs-user))))
        ;; The skip of a source without a registry entry: once, after the
        ;; inbox move and the release
        (setq claude-code-ide-handover-tests--stop-result '(:status stopped)
              claude-code-ide-handover-tests--scan-strays nil)
        (claude-code-ide-handover-tests--add "cci-test-src5" 'cci-test-a
                                             (claude-code-ide-handover-tests--other "proj5") 'idle)
        (let* ((result (claude-code-ide-handover-session "cci-test-src5" 'cci-test-b))
               (id (plist-get result :handover-id))
               (run (gethash id claude-code-ide-handover--runs)))
          (claude-code-ide-handover-tests--run-timers)
          (cl-letf (((symbol-function 'claude-code-ide-control-move-inbox)
                     (lambda (&rest _) (error "cci-test: the move failed"))))
            (claude-code-ide-handover-tests--deliver result))
          (setq calls nil)
          (cl-letf (((symbol-function 'claude-code-ide-session-registry-save-handover)
                     (lambda (&rest _) :missing)))
            (claude-code-ide-handover-resolve id 'skip))
          (should (eq (claude-code-ide-handover--run-status run) 'committed))
          ;; The missing entry notifies needs-user first; the skip ends it once
          (should (equal (mapcar #'car calls) '(committed needs-user)))
          (should-not (nth 2 (car calls)))
          (should (cl-some (lambda (m) (string-match-p "committed: in this Emacs only" m)) messages)))))))

(ert-deftest claude-code-ide-test-handover-status-hook-error ()
  "A status function that signals changes no run, and the next function still runs."
  (claude-code-ide-handover-tests--with
    (let* ((calls nil)
           (messages nil)
           (claude-code-ide-handover--status-functions
            (list (lambda (_run) (error "cci-test-hook-broke"))
                  (lambda (run) (push (claude-code-ide-handover-tests--hook-call run) calls)))))
      (claude-code-ide-tests--collect-messages messages
        (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a worktree 'idle)
        (let ((result (claude-code-ide-handover-session "cci-test-src" 'cci-test-b)))
          (claude-code-ide-handover-tests--run-timers)
          (claude-code-ide-handover-tests--deliver result)
          (should (eq (plist-get (claude-code-ide-handover-status (plist-get result :handover-id)) :status)
                      'committed))
          (should (equal (mapcar #'car calls) '(committed)))
          (should (cl-some (lambda (m) (string-match-p "cci-test-hook-broke" m)) messages)))
        (claude-code-ide-handover-tests--add "cci-test-src2" 'cci-test-a
                                             (claude-code-ide-handover-tests--other "proj2") 'working)
        (let ((id (plist-get (claude-code-ide-handover-session "cci-test-src2" 'cci-test-b) :handover-id)))
          (claude-code-ide-handover-tests--run-timers 3)
          (claude-code-ide-handover-cancel id)
          (should (eq (plist-get (claude-code-ide-handover-status id) :status) 'cancelled))
          (should (equal (mapcar #'car calls) '(cancelled committed))))))))

(provide 'claude-code-ide-handover-tests)

;;; claude-code-ide-handover-tests.el ends here
