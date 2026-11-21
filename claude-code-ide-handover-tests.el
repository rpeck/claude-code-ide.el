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

(defun claude-code-ide-handover-tests--run-timers (&optional limit)
  "Run the queued timer functions, also those that they queue, up to LIMIT."
  (let ((count 0))
    (while (and claude-code-ide-handover-tests--timers (< count (or limit 200)))
      (let ((item (pop claude-code-ide-handover-tests--timers)))
        (setq count (1+ count))
        (apply (car item) (cdr item))))
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
          (claude-code-ide-control--warned-providers nil)
          (claude-code-ide-control-delivered-functions nil)
          (claude-code-ide-control--held nil)
          (claude-code-ide-instance--all nil)
          (claude-code-ide-instance--generations (make-hash-table :test 'equal))
          (claude-code-ide-instance-state-functions
           (list #'claude-code-ide-handover-tests--state-function))
          (claude-code-ide-event-functions (list #'claude-code-ide-handover--on-event
                                                 #'claude-code-ide-control--on-event))
          (claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry))
          (claude-code-ide-handover--runs (make-hash-table :test 'equal))
          (claude-code-ide-handover--allowed nil)
          (claude-code-ide-handover-session-server-detection nil)
          (claude-code-ide-handover-stray-wait 0)
          ;; Longer than any test; the tests of the limit bind it to 0
          (claude-code-ide-handover-ack-wait 600)
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
      (should started))))

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
EXTRA is a plist of :target-native to set the target's native ID, and
:context for the context of the handover.  Return the handover ID."
  (claude-code-ide-handover-tests--add "cci-test-src" 'cci-test-a (claude-code-ide-handover-tests--worktree) 'idle)
  (let* ((id (plist-get (claude-code-ide-handover-session "cci-test-src" 'cci-test-b
                                                          :context (plist-get extra :context))
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
  "With the option `ask', an unsaved target waits for a person; retry starts it fresh."
  (claude-code-ide-handover-tests--with
    (let* ((claude-code-ide-handover-unsaved-target 'ask)
           (id (claude-code-ide-handover-tests--interrupted 'target-identified
                                                            :target-native "cci-test-tgt-native")))
      (claude-code-ide-handover-recover)
      (should-not claude-code-ide-handover-tests--starts)
      (let ((status (claude-code-ide-handover-status id)))
        (should (eq (plist-get status :status) 'needs-user))
        (should (eq (plist-get status :reason) 'unsaved-target))
        (should (eq (plist-get status :stage) 'target-identified)))
      (claude-code-ide-handover-resolve id 'retry)
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
Without a rollout it starts fresh, with no native ID of its own: Codex
chooses a new one.  A Claude Code target keeps its ID for --session-id."
  (claude-code-ide-handover-tests--with
    (let* ((codex-home (expand-file-name "codex" root))
           (process-environment (cons (concat "CODEX_HOME=" codex-home) process-environment))
           (cx-id "cc1e5000-0000-4000-8000-0000000000cd")
           (next nil)
           (run (lambda (provider native)
                  (claude-code-ide-handover--run-create
                   :id "cci-test-run" :target-id "cci-test-cx" :target-provider provider
                   :target-native-id native :stage 'target-identified :status 'running
                   :directory worktree :worktree worktree))))
      (claude-code-ide-handover-tests--registry-add "cci-test-cx" 'codex worktree :session-id cx-id)
      (cl-letf (((symbol-function 'claude-code-ide-handover--scan-then)
                 (lambda (_run continuation) (setq next continuation)))
                ((symbol-function 'claude-code-ide-handover--result) #'ignore))
        ;; No rollout: a fresh start, and Codex chooses the new ID
        (let ((codex (funcall run 'codex cx-id)))
          (claude-code-ide-handover--recover-claimed codex nil)
          (should (eq next 'start-target))
          (should (eq (claude-code-ide-handover--run-stage codex) 'target-started))
          (should-not (claude-code-ide-handover--run-target-native-id codex)))
        ;; A Claude Code target keeps its ID
        (let ((claude (funcall run 'claude cx-id)))
          (setq next nil)
          (claude-code-ide-handover--recover-claimed claude nil)
          (should (eq next 'start-target))
          (should (equal (claude-code-ide-handover--run-target-native-id claude) cx-id)))
        ;; With its rollout: the resume, as before
        (let ((file (expand-file-name (concat "sessions/2026/11/20/rollout-2026-11-20T10-00-00-" cx-id ".jsonl")
                                      codex-home))
              (codex (funcall run 'codex cx-id)))
          (make-directory (file-name-directory file) t)
          (write-region "{}\n" nil file nil 'silent)
          (setq next nil)
          (claude-code-ide-handover--recover-claimed codex nil)
          (should (eq next 'resume-target))
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
        (should (equal calls '(("cci-test-src" cci-test-b fresh "cci-test-why"))))
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

(provide 'claude-code-ide-handover-tests)

;;; claude-code-ide-handover-tests.el ends here
