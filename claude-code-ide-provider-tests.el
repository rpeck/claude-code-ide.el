;;; claude-code-ide-provider-tests.el --- Tests for the provider contracts  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the provider interface, the `claude' provider, the instance
;; descriptor, the launch generation, the common event, the common
;; states, the registry schema version 2 and the provider column of the
;; status buffer.  The file is loaded by claude-code-ide-tests.el, after
;; its mocks, and uses its helpers and those of the registry and status
;; tests.  All projects and conversation IDs are synthetic.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-code-ide)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-session-status)
(require 'claude-code-ide-session-registry-tests)
(require 'claude-code-ide-session-status-tests)

(declare-function claude-code-ide-tests--make-session "claude-code-ide-tests")
(declare-function claude-code-ide-tests--clear-processes "claude-code-ide-tests")

(defmacro claude-code-ide-tests--with-instances (&rest body)
  "Run BODY with no running instances and no known generations."
  (declare (indent 0))
  `(let ((claude-code-ide-instance--all nil)
         (claude-code-ide-instance--generations (make-hash-table :test 'equal)))
     ,@body))

(defvar claude-code-ide-tests--terminal-args nil
  "Arguments of the last mocked `claude-code-ide--create-terminal-session'.")

(defun claude-code-ide-tests--start-mocked (spec &optional state)
  "Start an instance as SPEC says, with the terminal and the MCP server mocked.
Return (SESSION . LAUNCH-FN): the new session, and the function that
the start gave the terminal for its command.  STATE is a plist that
collects the buffers and processes to remove; it is returned in the
cdr of its :cleanup key."
  (let* ((buffer (generate-new-buffer "*cci-test-provider*"))
         (process (start-process "cci-test-claude" nil "sleep" "30"))
         (launch-fn nil)
         (started nil)
         (claude-code-ide-session-start-functions
          (list (lambda (session _spec) (setq started session)))))
    (when state
      (plist-put state :cleanup (append (plist-get state :cleanup) (list buffer process))))
    (cl-letf (((symbol-function 'claude-code-ide--ensure-cli) (lambda () t))
              ((symbol-function 'claude-code-ide--terminal-ensure-backend) #'ignore)
              ((symbol-function 'claude-code-ide--read-instance-name)
               (lambda (&rest _) (error "Must not prompt")))
              ((symbol-function 'claude-code-ide-mcp-create-session)
               (lambda (dir session-id &optional instance-name)
                 (claude-code-ide-tests--make-session
                  dir :session-id session-id :instance-name instance-name :port 12345)))
              ((symbol-function 'claude-code-ide--create-terminal-session)
               (lambda (&rest args)
                 (setq launch-fn (nth 8 args)
                       claude-code-ide-tests--terminal-args args)
                 (cons buffer process)))
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
              ((symbol-function 'run-with-timer) #'ignore)
              ((symbol-function 'sleep-for) #'ignore))
      (let ((claude-code-ide-terminal-backend 'ghostel)
            (claude-code-ide-cli-extra-flags ""))
        (claude-code-ide--start-session nil nil spec)))
    (cons started launch-fn)))

(defun claude-code-ide-tests--cleanup-mocked (state)
  "Remove the buffers and processes that STATE collected."
  (dolist (object (plist-get state :cleanup))
    (cond
     ((processp object) (when (process-live-p object) (delete-process object)))
     ((bufferp object)
      (when (buffer-live-p object)
        (let ((kill-buffer-hook nil))
          (kill-buffer object))))))
  (claude-code-ide-tests--clear-processes))

;;; Provider registry

(ert-deftest claude-code-ide-test-provider-registry ()
  "Providers register by name; the default resolves; a missing op is unavailable."
  (let ((claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry))
        (claude-code-ide-default-provider 'claude))
    (should (memq 'claude (claude-code-ide-provider-names)))
    (should (eq (claude-code-ide-resolve-provider) claude-code-ide--claude-provider))
    (should (eq (claude-code-ide-resolve-provider 'claude) claude-code-ide--claude-provider))
    (should-error (claude-code-ide-resolve-provider 'cci-test-none) :type 'user-error)
    (let ((fake (claude-code-ide-provider-create
                 :name 'cci-test-fake :display-name "Fake" :buffer-name-prefix "fake"
                 :detect (lambda (&optional _) '(:available t :program "fake" :version unknown)))))
      (claude-code-ide-register-provider fake)
      (should (eq (claude-code-ide-get-provider 'cci-test-fake) fake))
      (should (eq (car (last (claude-code-ide-provider-names))) 'cci-test-fake))
      (should (plist-get (claude-code-ide-provider-call fake 'detect) :available))
      (let ((result (claude-code-ide-provider-call 'cci-test-fake 'fork nil nil nil)))
        (should (claude-code-ide-provider-unavailable-p result))
        (should (equal result '(:status unavailable :capability fork))))
      (should-not (claude-code-ide-provider-supports-p fake 'launch))
      (should-error (claude-code-ide-provider-supports-p fake 'no-such-op))
      ;; A provider of the same name replaces the old one, in its place
      (let ((again (claude-code-ide-provider-create :name 'cci-test-fake)))
        (claude-code-ide-register-provider again)
        (should (eq (claude-code-ide-get-provider 'cci-test-fake) again))
        (should (= 1 (cl-count 'cci-test-fake (claude-code-ide-provider-names))))
        (let ((claude-code-ide-default-provider 'cci-test-fake))
          (should (eq (claude-code-ide-resolve-provider) again)))))
    (should-error (claude-code-ide-register-provider 'not-a-provider))
    (should-error (claude-code-ide-register-provider (claude-code-ide-provider-create)))))

(ert-deftest claude-code-ide-test-provider-claude-struct ()
  "The claude provider names itself and has every operation."
  (let ((provider (claude-code-ide-get-provider 'claude)))
    (should (equal (claude-code-ide-provider-display-name provider) "Claude Code"))
    (should (equal (claude-code-ide-provider-buffer-name-prefix provider) "claude-code"))
    (dolist (operation claude-code-ide-provider-operations)
      (should (claude-code-ide-provider-supports-p provider operation)))
    ;; Every registered provider names exactly its operations
    (dolist (name (claude-code-ide-provider-names))
      (let ((provider (claude-code-ide-get-provider name)))
        (should (equal (claude-code-ide-provider-capabilities provider)
                       (cl-remove-if-not (lambda (operation)
                                           (claude-code-ide-provider-supports-p provider operation))
                                         claude-code-ide-provider-operations)))))
    (should (equal (claude-code-ide-provider-capabilities provider)
                   claude-code-ide-provider-operations))))

(ert-deftest claude-code-ide-test-provider-capabilities-checked ()
  "Registration derives the capabilities, and refuses ones that disagree."
  (let ((claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry)))
    (should (equal (claude-code-ide-provider-capabilities
                    (claude-code-ide-register-provider
                     (claude-code-ide-provider-create :name 'cci-test-cap :launch #'ignore
                                                      :stop #'ignore)))
                   '(launch stop)))
    (should-error (claude-code-ide-register-provider
                   (claude-code-ide-provider-create :name 'cci-test-cap :launch #'ignore
                                                    :capabilities '(launch continue))))
    (should-error (claude-code-ide-register-provider
                   (claude-code-ide-provider-create :name 'cci-test-cap :launch #'ignore
                                                    :stop #'ignore :capabilities '(launch))))))

(ert-deftest claude-code-ide-test-provider-claude-command-unchanged ()
  "The claude launch gives the command and the environment of the old code."
  (cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) (lambda () t))
            ((symbol-function 'claude-code-ide-mcp-server-get-config)
             (lambda (id) `((mcpServers . ((emacs-tools . ((type . "http") (url . ,id))))))))
            ((symbol-function 'claude-code-ide-mcp-server-get-tool-names)
             (lambda (_) '("mcp__emacs-tools__a"))))
    (let* ((claude-code-ide-cli-path "claude")
           (claude-code-ide-cli-args-functions nil)
           (claude-code-ide-cli-extra-flags "--model opus")
           (claude-code-ide-cli-debug t)
           (claude-code-ide-mcp-allowed-tools 'auto)
           (session (make-claude-code-ide-mcp-session :session-id "sid-1" :port 4321))
           (instance (claude-code-ide-instance-create :id "cci-test-i1" :provider 'claude
                                                      :session session))
           (args '("--settings" "{\"a\": 1}")))
      ;; A new conversation
      (let ((spec (claude-code-ide-start-spec-create :directory "/tmp/p/" :prompt "hi")))
        (should (equal (claude-code-ide-provider-call 'claude 'launch instance spec args)
                       (list :command (claude-code-ide--build-claude-command
                                       nil nil "sid-1" args "hi")
                             :environment (claude-code-ide--cli-environment 4321)))))
      ;; Continue, the picker, and a resume by ID
      (let ((spec (claude-code-ide-start-spec-create :directory "/tmp/p/" :continue t)))
        (should (equal (plist-get (claude-code-ide-provider-call 'claude 'resume instance spec args)
                                  :command)
                       (claude-code-ide--build-claude-command t nil "sid-1" args nil))))
      (let ((spec (claude-code-ide-start-spec-create :directory "/tmp/p/" :resume t)))
        (should (equal (plist-get (claude-code-ide-provider-call 'claude 'resume instance spec args)
                                  :command)
                       (claude-code-ide--build-claude-command nil t "sid-1" args nil))))
      (let ((spec (claude-code-ide-start-spec-create :directory "/tmp/p/"
                                                     :resume-id "cci-test-native")))
        (should (equal (plist-get (claude-code-ide-provider-call 'claude 'resume instance spec args)
                                  :command)
                       (claude-code-ide--build-claude-command
                        nil nil "sid-1" (append '("--resume" "cci-test-native") args) nil)))
        ;; A fork resumes with --fork-session, which gives a new native ID
        (should (string-match-p
                 "--resume cci-test-native .*--fork-session"
                 (plist-get (claude-code-ide-provider-call 'claude 'fork instance spec args)
                            :command))))
      (should-error (claude-code-ide-provider-call
                     'claude 'fork instance
                     (claude-code-ide-start-spec-create :directory "/tmp/p/") args)))))

(ert-deftest claude-code-ide-test-provider-claude-start-command ()
  "A start sends the same arguments to the command builder as before."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--clear-processes)
    (let ((state (list :cleanup nil))
          (claude-code-ide-cli-args-functions (list (lambda (_session _spec) (list "--hooked")))))
      (unwind-protect
          (let* ((started (claude-code-ide-tests--start-mocked
                           (claude-code-ide-start-spec-create
                            :directory "/tmp/cci-test-start/" :resume-id "cci-test-native"
                            :extra-flags "--model opus" :prompt "note")
                           state))
                 (built nil))
            (cl-letf (((symbol-function 'claude-code-ide--build-claude-command)
                       (lambda (&rest args) (setq built args) "claude")))
              (should (equal (funcall (cdr started))
                             (list :command "claude"
                                   :environment (claude-code-ide--cli-environment 12345)))))
            (should (equal built (list nil nil (claude-code-ide-mcp-session-session-id (car started))
                                       '("--resume" "cci-test-native" "--hooked") "note"))))
        (claude-code-ide-tests--cleanup-mocked state)))))

(ert-deftest claude-code-ide-test-provider-claude-exit-messages ()
  "The exit messages are the ones that the sentinel showed before."
  (let ((plain (claude-code-ide-start-spec-create :directory "/tmp/p/"))
        (continued (claude-code-ide-start-spec-create :directory "/tmp/p/" :continue t))
        (resumed (claude-code-ide-start-spec-create :directory "/tmp/p/" :resume t)))
    (should (string-prefix-p "Claude Code CLI not found (exit 127).  Ensure '/x/claude' is in"
                             (claude-code-ide-provider-call 'claude 'exit-message 127 plain "/x/claude")))
    (should (string-prefix-p "Claude Code CLI '/x/claude' was found but is not executable"
                             (claude-code-ide-provider-call 'claude 'exit-message 126 plain "/x/claude")))
    (should (string-prefix-p "Claude could not continue (exit 1)."
                             (claude-code-ide-provider-call 'claude 'exit-message 1 continued "c")))
    (should (string-prefix-p "Claude could not resume (exit 1)."
                             (claude-code-ide-provider-call 'claude 'exit-message 1 resumed "c")))
    (should (equal (claude-code-ide-provider-call 'claude 'exit-message 1 plain "c")
                   "Claude exited with error code 1"))))

(ert-deftest claude-code-ide-test-provider-claude-detect-and-events ()
  "Detect reports the CLI; the hook events map to the common events."
  (cl-letf (((symbol-function 'claude-code-ide--ensure-cli) (lambda () t))
            ((symbol-function 'call-process)
             (lambda (&rest _) (insert "9.9.9 (Claude Code)\n") 0)))
    (let ((claude-code-ide-cli-path "/x/claude"))
      (should (equal (claude-code-ide-provider-call 'claude 'detect)
                     '(:available t :program "/x/claude" :version unknown)))
      (should (equal (claude-code-ide-provider-call 'claude 'detect t)
                     '(:available t :program "/x/claude" :version "9.9.9 (Claude Code)")))))
  (cl-letf (((symbol-function 'claude-code-ide--ensure-cli) (lambda () nil)))
    (should-not (plist-get (claude-code-ide-provider-call 'claude 'detect t) :available)))
  (should (eq (claude-code-ide-provider-call 'claude 'map-event "PermissionRequest" nil)
              'approval-request))
  (should (eq (claude-code-ide-provider-call 'claude 'map-event "Stop" nil) 'turn-end))
  (should (eq (claude-code-ide-provider-call 'claude 'map-event "PreCompact" nil) 'other))
  (dolist (pair claude-code-ide--claude-event-map)
    (should (memq (cdr pair) claude-code-ide-event-names)))
  (should-not (claude-code-ide-provider-call 'claude 'status-events nil)))

(ert-deftest claude-code-ide-test-provider-claude-submit-and-stop ()
  "Submit types the text and return; stop kills the terminal buffer."
  (claude-code-ide-tests--clear-processes)
  (let* ((buffer (generate-new-buffer "*cci-test-submit*"))
         (session (claude-code-ide-tests--make-session "/tmp/cci-test-submit/" :buffer buffer))
         (instance (claude-code-ide-instance-create :id "cci-test-s" :provider 'claude
                                                    :buffer buffer :session session))
         (sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-ide--terminal-send-string)
                   (lambda (text) (push text sent)))
                  ((symbol-function 'claude-code-ide--terminal-send-return)
                   (lambda () (push 'return sent)))
                  ((symbol-function 'sit-for) #'ignore))
          (should (claude-code-ide-provider-call 'claude 'submit-prompt instance "cci-test-hello"))
          (should (equal (reverse sent) '("cci-test-hello" return)))
          (let ((kill-buffer-hook nil))
            (should (claude-code-ide-provider-call 'claude 'stop instance)))
          (should-not (buffer-live-p buffer))
          (should-not (claude-code-ide-provider-call 'claude 'submit-prompt instance "late")))
      (when (buffer-live-p buffer)
        (let ((kill-buffer-hook nil))
          (kill-buffer buffer)))
      (claude-code-ide-tests--clear-processes))))

;;; Instance descriptor

(ert-deftest claude-code-ide-test-instance-same-display-name ()
  "Two instances with one display name are found each by its instance ID."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--clear-processes)
    (let ((state (list :cleanup nil)))
      (unwind-protect
          (let* ((a (car (claude-code-ide-tests--start-mocked
                          (claude-code-ide-start-spec-create :directory "/tmp/cci-test-a/proj/")
                          state)))
                 (b (car (claude-code-ide-tests--start-mocked
                          (claude-code-ide-start-spec-create :directory "/tmp/cci-test-b/proj/")
                          state)))
                 (ia (claude-code-ide-instance-of-session a))
                 (ib (claude-code-ide-instance-of-session b)))
            (should (and ia ib))
            (should (equal (claude-code-ide-instance-display-name ia) "proj"))
            (should (equal (claude-code-ide-instance-display-name ib) "proj"))
            (should-not (equal (claude-code-ide-instance-id ia) (claude-code-ide-instance-id ib)))
            (should (eq (claude-code-ide-instance-by-id (claude-code-ide-instance-id ia)) ia))
            (should (eq (claude-code-ide-instance-by-id (claude-code-ide-instance-id ib)) ib))
            (should (eq (claude-code-ide-instance-session
                         (claude-code-ide-instance-by-id (claude-code-ide-instance-id ib)))
                        b))
            (should (equal (claude-code-ide-instances) (list ia ib)))
            (should (equal (claude-code-ide-instances 'claude) (list ia ib)))
            (should-not (claude-code-ide-instances 'codex))
            ;; The instance ID is not the native ID nor the display name
            (should (claude-code-ide-unknown-p (claude-code-ide-instance-native-id ia)))
            (should (eq (claude-code-ide-instance-provider ia) 'claude))
            (should (equal (claude-code-ide-instance-project-root ia) "/tmp/cci-test-a/proj/"))
            (should (claude-code-ide-unknown-p (claude-code-ide-instance-worktree ia)))
            (should (integerp (claude-code-ide-instance-pid ia)))
            (should (floatp (claude-code-ide-instance-process-start-time ia)))
            (should (eq (claude-code-ide-instance-buffer ia)
                        (claude-code-ide-mcp-session-buffer a)))
            (should (= (claude-code-ide-instance-generation ia) 1))
            ;; The end of an instance removes its descriptor and keeps its generation
            (let ((id (claude-code-ide-instance-id ia)))
              (claude-code-ide--cleanup-session a)
              (should-not (claude-code-ide-instance-by-id id))
              (should (eq (claude-code-ide-instance-by-id (claude-code-ide-instance-id ib)) ib))
              (should (= (claude-code-ide-instance-current-generation id) 1))))
        (claude-code-ide-tests--cleanup-mocked state)))))

(ert-deftest claude-code-ide-test-instance-unknown-model ()
  "A start without --model has the model `unknown', shown as \"unknown\"."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--clear-processes)
    (let ((state (list :cleanup nil)))
      (unwind-protect
          (let ((plain (claude-code-ide-instance-of-session
                        (car (claude-code-ide-tests--start-mocked
                              (claude-code-ide-start-spec-create :directory "/tmp/cci-test-m1/")
                              state))))
                (opus (claude-code-ide-instance-of-session
                       (car (claude-code-ide-tests--start-mocked
                             (claude-code-ide-start-spec-create
                              :directory "/tmp/cci-test-m2/" :extra-flags "--model opus")
                             state)))))
            (should (eq (claude-code-ide-instance-model plain) 'unknown))
            (should (equal (claude-code-ide-format-value (claude-code-ide-instance-model plain))
                           "unknown"))
            (should (equal (claude-code-ide-instance-model opus) "opus"))
            ;; No transcript exists for a synthetic conversation
            (cl-letf (((symbol-function 'claude-code-ide-session-registry--read-report) #'ignore))
              (should (eq (claude-code-ide-provider-call 'claude 'transcript plain 'model) 'unknown))
              (should (eq (claude-code-ide-provider-call 'claude 'transcript plain 'title) 'unknown))))
        (claude-code-ide-tests--cleanup-mocked state)))))

(ert-deftest claude-code-ide-test-instance-generation ()
  "Each launch of an instance ID gets a higher generation, also after a record."
  (claude-code-ide-tests--with-instances
    (should-not (claude-code-ide-instance-current-generation "cci-test-g"))
    (should (= (claude-code-ide-instance-next-generation "cci-test-g") 1))
    (should (= (claude-code-ide-instance-next-generation "cci-test-g") 2))
    ;; A saved record of a higher generation wins
    (should (= (claude-code-ide-instance-next-generation "cci-test-g" 7) 8))
    (should (= (claude-code-ide-instance-next-generation "cci-test-g" 3) 9))
    (should (= (claude-code-ide-instance-current-generation "cci-test-g") 9))
    ;; A restore through the start spec continues the count
    (claude-code-ide-tests--clear-processes)
    (let ((state (list :cleanup nil)))
      (unwind-protect
          (let ((instance (claude-code-ide-instance-of-session
                           (car (claude-code-ide-tests--start-mocked
                                 (claude-code-ide-start-spec-create
                                  :directory "/tmp/cci-test-gen/" :instance-id "cci-test-restored"
                                  :resume-id "cci-test-native" :last-generation 4
                                  :role "cci-test-worker")
                                 state)))))
            (should (equal (claude-code-ide-instance-id instance) "cci-test-restored"))
            (should (= (claude-code-ide-instance-generation instance) 5))
            (should (equal (claude-code-ide-instance-native-id instance) "cci-test-native"))
            (should (equal (claude-code-ide-instance-role instance) "cci-test-worker"))
            ;; A live instance ID cannot start twice
            (should-error (claude-code-ide-instance-register
                           (claude-code-ide-instance-create :id "cci-test-restored"))))
        (claude-code-ide-tests--cleanup-mocked state)))))

(ert-deftest claude-code-ide-test-instance-values-and-properties ()
  "Unknown values are explicit; other files keep values in the properties."
  (should (claude-code-ide-unknown-p 'unknown))
  (should-not (claude-code-ide-unknown-p nil))
  (should (eq (claude-code-ide-or-unknown nil) 'unknown))
  (should (equal (claude-code-ide-or-unknown "x") "x"))
  (should-not (claude-code-ide-known-or-nil 'unknown))
  (should (equal (claude-code-ide-format-value nil) ""))
  (should (equal (claude-code-ide-format-value 'claude) "claude"))
  (let ((instance (claude-code-ide-instance-create :id "cci-test-p")))
    (dolist (slot '(native-id display-name project-root worktree pid process-start-time model))
      (should (eq (cl-struct-slot-value 'claude-code-ide-instance slot instance) 'unknown)))
    (should-not (claude-code-ide-instance-role instance))
    (should (= (claude-code-ide-instance-generation instance) 0))
    (should (equal (claude-code-ide-instance-set-property instance :cci-test-secret "s") "s"))
    (should (equal (claude-code-ide-instance-property instance :cci-test-secret) "s")))
  (should (string-match-p "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'"
                          (claude-code-ide-instance-new-id))))

;;; Common events

(ert-deftest claude-code-ide-test-event-generation ()
  "An event of an earlier generation is not current and is not dispatched."
  (claude-code-ide-tests--with-instances
    (let* ((seen nil)
           (claude-code-ide-event-functions (list (lambda (event) (push event seen)))))
      (claude-code-ide-instance-next-generation "cci-test-e")
      (let ((old (claude-code-ide-make-event "cci-test-e" 1 'turn-end "Stop" '((a . 1)) 10.0)))
        (should (equal old '(:instance-id "cci-test-e" :generation 1 :time 10.0 :event turn-end
                                          :provider-event "Stop" :data ((a . 1)))))
        (should (claude-code-ide-event-current-p old))
        ;; A resume
        (claude-code-ide-instance-next-generation "cci-test-e")
        (should-not (claude-code-ide-event-current-p old))
        (should-not (claude-code-ide-dispatch-event old))
        (should-not seen)
        (let ((new (claude-code-ide-make-event "cci-test-e" 2 'prompt-submit "UserPromptSubmit" nil)))
          (should (floatp (plist-get new :time)))
          (should (claude-code-ide-dispatch-event new))
          (should (equal seen (list new)))))
      ;; An instance that this Emacs never launched
      (should-not (claude-code-ide-event-current-p
                   (claude-code-ide-make-event "cci-test-none" 1 'other "X" nil)))
      (should-error (claude-code-ide-make-event "cci-test-e" 2 'no-such-event "X" nil)))))

(ert-deftest claude-code-ide-test-status-ignores-old-generation ()
  "Events of an earlier launch of the instance do not change the status."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--with-status
      (let* ((session (make-claude-code-ide-mcp-session))
             (seen nil)
             (claude-code-ide-event-functions (list (lambda (event) (push event seen))))
             (instance (claude-code-ide-instance-register
                        (claude-code-ide-instance-create
                         :id "cci-test-old" :provider 'claude :session session
                         :generation (claude-code-ide-instance-next-generation "cci-test-old"))))
             (_hooks (claude-code-ide-session-status--hooks session "key-old"))
             (status (gethash session claude-code-ide-session-status--by-session))
             (nonce (claude-code-ide-session-status-nonce status))
             (dir (claude-code-ide-session-status--events-directory)))
        (should (equal (claude-code-ide-session-status-instance-id status) "cci-test-old"))
        (should (= (claude-code-ide-session-status-generation status) 1))
        (make-directory dir t)
        (cl-flet ((write (seq event text)
                    (with-temp-file (expand-file-name (format "%s-%08d-%s.json" nonce seq event) dir)
                      (insert text))))
          (write 1 "SessionStart" "{\"source\":\"startup\"}")
          (claude-code-ide-session-status--drain)
          (should (equal (claude-code-ide-tests--state status) '(idle "Ready")))
          ;; The event functions got the common event, mapped by the provider
          (should (= (length seen) 1))
          (should (equal (plist-get (car seen) :instance-id) "cci-test-old"))
          (should (= (plist-get (car seen) :generation) 1))
          (should (eq (plist-get (car seen) :event) 'session-start))
          (should (equal (plist-get (car seen) :provider-event) "SessionStart"))
          (should (equal (plist-get (car seen) :data) '((source . "startup"))))
          ;; The instance launches again; the old launch still writes
          (setf (claude-code-ide-instance-generation instance)
                (claude-code-ide-instance-next-generation "cci-test-old"))
          (write 2 "UserPromptSubmit" "{\"prompt\":\"late\"}")
          (claude-code-ide-session-status--drain)
          (should (equal (claude-code-ide-tests--state status) '(idle "Ready")))
          ;; The event functions did not get the old event
          (should (= (length seen) 1))
          ;; The file is gone all the same
          (should-not (directory-files dir nil "\\.json\\'"))
          ;; A record of the current launch takes events
          (setf (claude-code-ide-session-status-generation status) 2)
          (write 3 "UserPromptSubmit" "{\"prompt\":\"now\"}")
          (claude-code-ide-session-status--drain)
          (should (eq (car (claude-code-ide-tests--state status)) 'working))
          (should (= (length seen) 2))
          (should (eq (plist-get (car seen) :event) 'prompt-submit))
          (should (= (plist-get (car seen) :generation) 2)))))))

;;; Common states

(ert-deftest claude-code-ide-test-instance-state ()
  "The Claude Code states map to the common states, with reason and age."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--with-status
      (claude-code-ide-tests--clear-processes)
      (let* ((buffer (generate-new-buffer "*cci-test-state*"))
             (session (claude-code-ide-tests--make-session "/tmp/cci-test-state/" :buffer buffer))
             (instance (claude-code-ide-instance-register
                        (claude-code-ide-instance-create
                         :id "cci-test-st" :provider 'claude :session session :buffer buffer
                         :generation (claude-code-ide-instance-next-generation "cci-test-st")))))
        (unwind-protect
            (progn
              ;; No status hooks: no event comes
              (should (equal (claude-code-ide-instance-state "cci-test-st" 50.0)
                             '(:state disconnected :reason nil :since nil :guess nil :age nil)))
              (claude-code-ide-session-status--hooks session "key-st")
              (let ((status (gethash session claude-code-ide-session-status--by-session)))
                (setf (claude-code-ide-session-status-registered status) 0.0
                      (claude-code-ide-session-status-since status) 0.0)
                ;; Starting, before the CLI takes a prompt
                (should (eq (plist-get (claude-code-ide-instance-state instance 1.0) :state) 'working))
                (claude-code-ide-tests--feed
                 status (list '("SessionStart" "{\"source\":\"startup\"}")
                              '("UserPromptSubmit" "{\"prompt\":\"run it\"}")
                              (claude-code-ide-tests--tool "PreToolUse" "t1")
                              (claude-code-ide-tests--permission)))
                (let ((state (claude-code-ide-instance-state instance 10.0)))
                  (should (eq (plist-get state :state) 'waiting-for-user))
                  (should (eq (plist-get state :reason) 'approval))
                  (should (= (plist-get state :since) 4.0))
                  (should (= (plist-get state :age) 6.0))
                  (should-not (plist-get state :guess)))
                (claude-code-ide-tests--feed
                 status (list (claude-code-ide-tests--tool "PostToolUse" "t1")
                              '("Stop" "{\"last_assistant_message\":\"Shall I go on?\"}")))
                (let ((state (claude-code-ide-instance-state instance 10.0)))
                  (should (eq (plist-get state :state) 'waiting-for-user))
                  (should (eq (plist-get state :reason) 'question))
                  (should (plist-get state :guess)))
                (claude-code-ide-tests--feed
                 status (list '("UserPromptSubmit" "{}")
                              (claude-code-ide-tests--tool "PreToolUse" "q1" "{\"questions\":[]}"
                                                           nil "AskUserQuestion")
                              (claude-code-ide-tests--permission "{\"questions\":[]}" nil
                                                                 "AskUserQuestion")))
                (should (eq (plist-get (claude-code-ide-instance-state instance 20.0) :reason)
                            'question))
                (claude-code-ide-tests--feed status '(("StopFailure" "{\"error\":\"overloaded\"}")))
                (should (equal (cl-subseq (claude-code-ide-instance-state instance 20.0) 0 4)
                               '(:state failed :reason error)))
                (claude-code-ide-tests--feed status '(("Stop" "{\"last_assistant_message\":\"Done.\"}")))
                (should (eq (plist-get (claude-code-ide-instance-state instance 20.0) :state) 'idle)))
              ;; The process is gone
              (let ((kill-buffer-hook nil))
                (kill-buffer buffer))
              (should (eq (plist-get (claude-code-ide-instance-state instance) :state) 'disconnected))
              ;; An ID that ended, and one that never ran
              (claude-code-ide-instance-unregister "cci-test-st")
              (should (eq (plist-get (claude-code-ide-instance-state "cci-test-st") :state)
                          'disconnected))
              (should-not (claude-code-ide-instance-state "cci-test-never")))
          (when (buffer-live-p buffer)
            (let ((kill-buffer-hook nil))
              (kill-buffer buffer)))
          (claude-code-ide-tests--clear-processes))))))

(ert-deftest claude-code-ide-test-instance-make-state-checks ()
  "Only the states and reasons of the common lists are accepted."
  (should (equal (claude-code-ide-instance-make-state 'failed 'quota-limit 5.0)
                 '(:state failed :reason quota-limit :since 5.0 :guess nil)))
  (should-error (claude-code-ide-instance-make-state 'starting))
  (should-error (claude-code-ide-instance-make-state 'idle 'approval))
  (should-error (claude-code-ide-instance-make-state 'waiting-for-task 'approval)))

(ert-deftest claude-code-ide-test-instance-make-state-start-and-signal-reasons ()
  "A start is working/starting; a session without events is disconnected."
  (should (eq (plist-get (claude-code-ide-instance-make-state 'working 'starting) :reason)
              'starting))
  (should (eq (plist-get (claude-code-ide-instance-make-state 'disconnected 'untracked) :reason)
              'untracked))
  (should (eq (plist-get (claude-code-ide-instance-make-state 'disconnected 'no-signal) :reason)
              'no-signal))
  (should-error (claude-code-ide-instance-make-state 'idle 'starting))
  (should-error (claude-code-ide-instance-make-state 'working 'untracked)))

;;; Registry schema

(ert-deftest claude-code-ide-test-registry-v1-and-v2-files ()
  "Version 2 goes to its own file; the version 1 file is read once and never written."
  (claude-code-ide-tests--with-registry
    (let ((v1 (claude-code-ide-session-registry--v1-file))
          (v2 (expand-file-name "other-v2.json" registry-dir))
          (v1-text (concat "{\"version\": 1, \"sessions\": [{\"key\": \"cci-test-k1\","
                           " \"session_id\": \"cci-test-n1\", \"project_dir\": \"/tmp/cci-test-v1/\","
                           " \"model\": null, \"extra_flags\": \"\", \"state\": \"open\", \"host\": \"h\"}]}")))
      ;; The two file names, and the report directory of version 1
      (should (equal v1 (expand-file-name "state.json" registry-dir)))
      (should (equal (claude-code-ide-session-registry--state-file)
                     (expand-file-name "state-v2.json" registry-dir)))
      (should (equal (claude-code-ide-session-registry--report-directory)
                     (file-name-as-directory (expand-file-name "state-reports" registry-dir))))
      ;; A version 2 record reads with all its fields
      (with-temp-file v2
        (insert "{\"version\": 2, \"sessions\": [{\"instance_id\": \"cci-test-k2\", \"provider\": \"codex\","
                " \"native_id\": \"cci-test-n2\", \"generation\": 3, \"role\": \"cci-test-reviewer\","
                " \"project_dir\": \"/tmp/cci-test-v2/\", \"model\": \"gpt-x\", \"extra_flags\": \"\","
                " \"state\": \"closed\"}]}"))
      (let ((new (car (claude-code-ide-session-registry--read-file v2))))
        (should (equal (claude-code-ide-session-registry-entry-key new) "cci-test-k2"))
        (should (eq (claude-code-ide-session-registry-entry-provider new) 'codex))
        (should (equal (claude-code-ide-session-registry-entry-session-id new) "cci-test-n2"))
        (should (= (claude-code-ide-session-registry-entry-generation new) 3))
        (should (equal (claude-code-ide-session-registry-entry-role new) "cci-test-reviewer"))
        (should (equal (claude-code-ide-session-registry-entry-model new) "gpt-x")))
      ;; Without a version 2 file, the version 1 file is read and migrated
      (with-temp-file v1 (insert v1-text))
      (let ((old (car (claude-code-ide-session-registry--entries))))
        (should (equal (claude-code-ide-session-registry-entry-key old) "cci-test-k1"))
        (should (equal (claude-code-ide-session-registry-entry-session-id old) "cci-test-n1"))
        (should (eq (claude-code-ide-session-registry-entry-provider old) 'claude))
        (should (= (claude-code-ide-session-registry-entry-generation old) 0))
        (should-not (claude-code-ide-session-registry-entry-role old))
        (should (eq (claude-code-ide-session-registry-entry-state old) 'open)))
      ;; The first write makes the version 2 file and leaves version 1 alone
      (claude-code-ide-session-registry--submit "noop" #'identity)
      (should (equal (claude-code-ide-session-registry--file-string v1) v1-text))
      (should-not (file-exists-p (concat v1 ".bak")))
      (let ((data (claude-code-ide-session-registry--json-decode
                   (claude-code-ide-session-registry--file-string
                    (claude-code-ide-session-registry--state-file)))))
        (should (= (alist-get 'version data) 2))
        (let ((record (car (alist-get 'sessions data))))
          (should (equal (alist-get 'instance_id record) "cci-test-k1"))
          (should (equal (alist-get 'native_id record) "cci-test-n1"))
          (should (equal (alist-get 'provider record) "claude"))
          (should (= (alist-get 'generation record) 0))
          (should-not (assq 'key record))
          (should-not (assq 'session_id record))))
      ;; An older Emacs that writes the version 1 file does not change version 2
      (with-temp-file v1 (insert (replace-regexp-in-string "cci-test-k1" "cci-test-k9" v1-text)))
      (should (equal (claude-code-ide-tests--registry-file-keys) '("cci-test-k1")))
      (claude-code-ide-session-registry--submit "b" (claude-code-ide-tests--registry-add "b"))
      (should (equal (claude-code-ide-tests--registry-file-keys) '("cci-test-k1" "b")))
      (should (string-match-p "cci-test-k9" (claude-code-ide-session-registry--file-string v1)))
      (should (= 1 (length (directory-files registry-dir nil "\\`state\\.json"))))
      ;; An unknown version is refused
      (with-temp-file v2 (insert "{\"version\": 3, \"sessions\": []}"))
      (should-error (claude-code-ide-session-registry--read-file v2)
                    :type 'claude-code-ide-session-registry-error))))

(ert-deftest claude-code-ide-test-registry-unreadable-v1-file ()
  "An unreadable version 1 file falls back to its backup and is not moved."
  (claude-code-ide-tests--with-registry
    (let ((v1 (claude-code-ide-session-registry--v1-file)))
      (with-temp-file v1 (insert "{\"version\": 1, \"sessions\": [{\"key\""))
      (with-temp-file (concat v1 ".bak")
        (insert "{\"version\": 1, \"sessions\": [{\"key\": \"cci-test-bak\", \"project_dir\": \"/tmp/\"}]}"))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (should (equal (claude-code-ide-tests--registry-file-keys
                        (concat v1 ".bak"))
                       '("cci-test-bak")))
        (should (equal (mapcar #'claude-code-ide-session-registry-entry-key
                               (claude-code-ide-session-registry--entries))
                       '("cci-test-bak")))
        (claude-code-ide-session-registry--submit "noop" #'identity))
      (should (equal (claude-code-ide-tests--registry-file-keys) '("cci-test-bak")))
      (should (file-exists-p v1))
      (should-not (directory-files registry-dir nil "\\.corrupt-")))))

(ert-deftest claude-code-ide-test-registry-records-descriptor ()
  "A start records the instance ID, the provider, the generation and the role."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--with-registry
      (let* ((session (make-claude-code-ide-mcp-session :buffer (current-buffer)))
             (instance (claude-code-ide-instance-register
                        (claude-code-ide-instance-create
                         :id "cci-test-rec" :provider 'claude :session session
                         :generation (claude-code-ide-instance-next-generation "cci-test-rec" 2))))
             (spec (claude-code-ide-tests--registry-spec :provider 'claude :role "cci-test-lead"))
             (args (claude-code-ide-session-registry--cli-args session spec))
             (native (cadr args)))
        ;; The entry key is the instance ID; the new conversation has its own id
        (should (equal (gethash session claude-code-ide-session-registry--keys) "cci-test-rec"))
        (should (equal (car args) "--session-id"))
        (should (string-match-p "\\`[0-9a-f]\\{8\\}-" native))
        (should-not (equal native "cci-test-rec"))
        (claude-code-ide-session-registry--on-start session spec)
        (let ((entry (claude-code-ide-tests--registry-get "cci-test-rec")))
          (should (eq (claude-code-ide-session-registry-entry-provider entry) 'claude))
          (should (= (claude-code-ide-session-registry-entry-generation entry) 3))
          (should (equal (claude-code-ide-session-registry-entry-role entry) "cci-test-lead"))
          (should (equal (claude-code-ide-session-registry-entry-session-id entry) native)))
        (should (equal (claude-code-ide-instance-native-id instance) native))
        ;; A report of a new CLI session id reaches the descriptor
        (with-temp-file (claude-code-ide-session-registry--report-file "cci-test-rec")
          (insert "{\"session_id\":\"cci-test-cleared\",\"transcript_path\":\"/x/t.jsonl\"}"))
        (claude-code-ide-session-registry--on-report-change
         (list nil 'changed (claude-code-ide-session-registry--report-file "cci-test-rec")))
        (should (equal (claude-code-ide-instance-native-id instance) "cci-test-cleared"))
        (should (equal (claude-code-ide-session-registry-entry-session-id
                        (claude-code-ide-tests--registry-get "cci-test-rec"))
                       "cci-test-cleared"))))))

(ert-deftest claude-code-ide-test-registry-fresh-conversation-in-existing-instance ()
  "A new conversation of an existing instance gets a new native ID, not a taken one."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--with-registry
      (let* ((spec (claude-code-ide-tests--registry-spec :provider 'claude))
             (first (make-claude-code-ide-mcp-session :buffer (current-buffer)))
             (_one (claude-code-ide-instance-register
                    (claude-code-ide-instance-create
                     :id "cci-test-fresh" :provider 'claude :session first
                     :generation (claude-code-ide-instance-next-generation "cci-test-fresh"))))
             (native1 (cadr (claude-code-ide-session-registry--cli-args first spec))))
        (claude-code-ide-session-registry--on-start first spec)
        (claude-code-ide-session-registry--on-end first 'exited)
        (claude-code-ide-instance-unregister "cci-test-fresh")
        ;; The same instance starts again, without a resume
        (let* ((second (make-claude-code-ide-mcp-session :buffer (current-buffer)))
               (two (claude-code-ide-instance-register
                     (claude-code-ide-instance-create
                      :id "cci-test-fresh" :provider 'claude :session second
                      :generation (claude-code-ide-instance-next-generation "cci-test-fresh"))))
               (args (claude-code-ide-session-registry--cli-args second spec))
               (native2 (cadr args)))
          (should (equal (car args) "--session-id"))
          (should-not (equal native2 native1))
          (should-not (equal native2 "cci-test-fresh"))
          (claude-code-ide-session-registry--on-start second spec)
          (let ((entry (claude-code-ide-tests--registry-get "cci-test-fresh")))
            (should (equal (claude-code-ide-session-registry-entry-session-id entry) native2))
            (should (= (claude-code-ide-session-registry-entry-generation entry) 2)))
          (should (equal (claude-code-ide-instance-native-id two) native2))
          ;; One entry, for the one instance
          (should (equal (claude-code-ide-tests--registry-file-keys) '("cci-test-fresh"))))))))

(ert-deftest claude-code-ide-test-registry-restore-passes-identity ()
  "A restore starts the record with its instance ID, provider, generation and role."
  (claude-code-ide-tests--with-registry
    (let ((spec nil))
      (cl-letf (((symbol-function 'claude-code-ide--start-session)
                 (lambda (_continue _resume start-spec) (setq spec start-spec)))
                ((symbol-function 'claude-code-ide-session-registry--model) #'ignore)
                ((symbol-function 'claude-code-ide-session-registry--custom-title) #'ignore))
        (claude-code-ide-session-registry--start-entry
         (claude-code-ide-tests--registry-entry
          "cci-test-back" :session-id "cci-test-native" :generation 6 :role "cci-test-r"
          :project-dir temporary-file-directory)
         nil))
      (should (equal (claude-code-ide-start-spec-instance-id spec) "cci-test-back"))
      (should (eq (claude-code-ide-start-spec-provider spec) 'claude))
      (should (= (claude-code-ide-start-spec-last-generation spec) 6))
      (should (equal (claude-code-ide-start-spec-role spec) "cci-test-r"))
      (should (equal (claude-code-ide-start-spec-resume-id spec) "cci-test-native")))))

;;; Status buffer

(ert-deftest claude-code-ide-test-status-buffer-provider-column ()
  "The status buffer has its new name and a Provider column."
  (should (equal claude-code-ide-session-status--buffer-name "*Coding Agents Sessions*"))
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--with-status
      (claude-code-ide-tests--clear-processes)
      (let* ((buffer (generate-new-buffer "*cci-test-column*"))
             (session (claude-code-ide-tests--make-session "/tmp/cci-test-col/" :buffer buffer))
             (bare (claude-code-ide-tests--make-session "/tmp/cci-test-col2/"
                                                        :buffer (generate-new-buffer "*cci-test-bare*"))))
        (claude-code-ide-instance-register
         (claude-code-ide-instance-create :id "cci-test-col" :provider 'claude :session session
                                          :buffer buffer))
        (unwind-protect
            (let ((entries (claude-code-ide-session-status--entries
                            (claude-code-ide-session-status--rows 10.0) 10.0)))
              (should (equal (claude-code-ide-session-status--provider-label session) "claude"))
              (should (equal (claude-code-ide-session-status--provider-label bare) "unknown"))
              (dolist (entry entries)
                (should (= (length (cadr entry)) 5)))
              (should (equal (aref (cadr (assq session entries)) 2) "claude"))
              (with-temp-buffer
                (claude-code-ide-session-status-list-mode)
                (should (equal (mapcar #'car (append tabulated-list-format nil))
                               '("Status" "Session" "Provider" "For" "Detail")))))
          (dolist (b (list buffer (claude-code-ide-mcp-session-buffer bare)))
            (let ((kill-buffer-hook nil))
              (kill-buffer b)))
          (claude-code-ide-tests--clear-processes))))))

;;; Load points

(ert-deftest claude-code-ide-test-load-points ()
  "The main file loads each optional file, and survives a broken one."
  (let ((source (with-temp-buffer
                  (insert-file-contents (locate-library "claude-code-ide.el" t))
                  (buffer-string))))
    (dolist (feature '("codex" "control" "transcript" "handover" "review"))
      (should (string-match-p
               (regexp-quote (format "(claude-code-ide--require-optional 'claude-code-ide-%s)" feature))
               source))))
  (should (featurep 'claude-code-ide-provider-tests))
  ;; A missing file loads nothing and says nothing
  (let ((warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings))))
      (should-not (claude-code-ide--require-optional 'claude-code-ide-cci-test-missing))
      (should-not warnings)))
  ;; A broken file gives a warning and no error
  (let* ((dir (make-temp-file "cci-test-broken-" t))
         (load-path (cons dir load-path))
         (warnings nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "claude-code-ide-cci-test-broken.el" dir)
            (insert "(error \"cci-test broken file\")\n"))
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (_type message &rest _) (push message warnings))))
            (should-not (claude-code-ide--require-optional 'claude-code-ide-cci-test-broken)))
          (should (string-match-p "cci-test broken file" (car warnings)))
          (should-not (featurep 'claude-code-ide-cci-test-broken)))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-test-load-with-broken-optional-file ()
  "The package loads in a new Emacs while an optional file signals an error."
  (let* ((dir (make-temp-file "cci-test-broken-" t))
         (emacs (expand-file-name invocation-name invocation-directory))
         (package-dir (file-name-directory (locate-library "claude-code-ide.el" t))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "claude-code-ide-codex.el" dir)
            (insert "(error \"cci-test broken codex\")\n"))
          (with-temp-buffer
            (let ((status (apply #'call-process emacs nil t nil "-Q" "-batch" "-L" dir "-L" package-dir
                                 (append (mapcan (lambda (path) (list "-L" path))
                                                 (cl-remove-if-not #'stringp load-path))
                                         (list "--eval"
                                               (concat "(progn (require 'claude-code-ide)"
                                                       " (princ (format \"cci-loaded=%s codex=%s\""
                                                       " (featurep 'claude-code-ide)"
                                                       " (featurep 'claude-code-ide-codex))))"))))))
              (should (eq status 0))
              (should (string-match-p "cci-loaded=t codex=nil" (buffer-string)))
              (should (string-match-p "cci-test broken codex" (buffer-string))))))
      (delete-directory dir t))))

;;; Review fixes

(ert-deftest claude-code-ide-test-instance-duplicate-start-keeps-live-instance ()
  "A second start of a live instance ID fails and leaves the live one intact."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--with-status
      (claude-code-ide-tests--clear-processes)
      (let ((state (list :cleanup nil)))
        (unwind-protect
            (let* ((session (car (claude-code-ide-tests--start-mocked
                                  (claude-code-ide-start-spec-create
                                   :directory "/tmp/cci-test-dup1/" :instance-id "cci-test-dup")
                                  state)))
                   (instance (claude-code-ide-instance-of-session session))
                   (_hooks (claude-code-ide-session-status--hooks session "key-dup"))
                   (status (gethash session claude-code-ide-session-status--by-session))
                   (dir (claude-code-ide-session-status--events-directory)))
              (should (= (claude-code-ide-instance-generation instance) 1))
              (should-error (claude-code-ide-tests--start-mocked
                             (claude-code-ide-start-spec-create
                              :directory "/tmp/cci-test-dup2/" :instance-id "cci-test-dup")
                             state))
              ;; Nothing changed for the live instance
              (should (= (claude-code-ide-instance-current-generation "cci-test-dup") 1))
              (should (eq (claude-code-ide-instance-by-id "cci-test-dup") instance))
              (should (= 1 (hash-table-count claude-code-ide-mcp--sessions)))
              ;; It still takes its events
              (make-directory dir t)
              (with-temp-file (expand-file-name
                               (format "%s-%08d-SessionStart.json"
                                       (claude-code-ide-session-status-nonce status) 1)
                               dir)
                (insert "{\"source\":\"startup\"}"))
              (claude-code-ide-session-status--drain)
              (should (equal (claude-code-ide-tests--state status) '(idle "Ready"))))
          (claude-code-ide-tests--cleanup-mocked state))))))

(defun claude-code-ide-tests--stub-provider (&rest overrides)
  "Return a stub provider named `cci-test-stub', changed by OVERRIDES."
  (apply #'claude-code-ide-provider-create
         (append overrides
                 (list :name 'cci-test-stub :display-name "Stub" :buffer-name-prefix "cci-stub"
                       :detect (lambda (&optional _)
                                 '(:available t :program "/x/cci-stub" :version unknown))))))

(ert-deftest claude-code-ide-test-provider-stub-gets-no-claude-parts ()
  "Another provider gets no CC arguments, its own buffer prefix and its own program."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--with-registry
      (claude-code-ide-tests--clear-processes)
      (let* ((claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry))
             (launch-args 'none)
             (exit-args nil)
             (claude-code-ide-cli-args-functions (list #'claude-code-ide-session-registry--cli-args))
             (state (list :cleanup nil)))
        (claude-code-ide-register-provider
         (claude-code-ide-tests--stub-provider
          :launch (lambda (_instance _spec args)
                    (setq launch-args args)
                    (list :command "cci-stub" :environment nil))
          :exit-message (lambda (code spec program)
                          (setq exit-args (list code spec program))
                          (format "%s ended with %d" program code))))
        (unwind-protect
            (let* ((started (claude-code-ide-tests--start-mocked
                             (claude-code-ide-start-spec-create
                              :directory "/tmp/cci-test-stub/proj/" :provider 'cci-test-stub)
                             state))
                   (session (car started))
                   (instance (claude-code-ide-instance-of-session session)))
              (should (eq (claude-code-ide-instance-provider instance) 'cci-test-stub))
              ;; The buffer name has the stub's prefix
              (should (equal (car claude-code-ide-tests--terminal-args) "*cci-stub[proj]*"))
              ;; The launch gets no --session-id and no --settings
              (should (equal (funcall (cdr started)) '(:command "cci-stub" :environment nil)))
              (should-not (member "--session-id" launch-args))
              (should-not (member "--settings" launch-args))
              (should-not (gethash session claude-code-ide-session-registry--keys))
              (should-not (claude-code-ide-session-registry--cli-args
                           session (claude-code-ide-start-spec-create
                                    :directory "/tmp/" :provider 'cci-test-stub)))
              ;; The exit message names the program that detect found
              (cl-letf (((symbol-function 'message) #'ignore))
                (funcall (process-sentinel (claude-code-ide-mcp-session-process session))
                         (claude-code-ide-mcp-session-process session)
                         "exited abnormally with code 3\n"))
              (should (equal (car exit-args) 3))
              (should (equal (nth 2 exit-args) "/x/cci-stub")))
          (claude-code-ide-tests--cleanup-mocked state))))))

(ert-deftest claude-code-ide-test-provider-buffer-name-prefix ()
  "The default buffer name uses the provider's prefix; CC names stay the same."
  (let ((claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry))
        (claude-code-ide-default-provider 'claude))
    (should (equal (claude-code-ide--default-buffer-name "/tmp/cci-test-proj/")
                   "*claude-code[cci-test-proj]*"))
    (should (equal (claude-code-ide--instance-buffer-name "/tmp/cci-test-proj/" "docs")
                   "*claude-code[cci-test-proj:docs]*"))
    (let ((claude-code-ide--naming-provider
           (claude-code-ide-register-provider (claude-code-ide-tests--stub-provider))))
      (should (equal (claude-code-ide--default-buffer-name "/tmp/cci-test-proj/")
                     "*cci-stub[cci-test-proj]*")))))

(ert-deftest claude-code-ide-test-status-blocker-reasons ()
  "A permission notification asks for an approval; an unmatched AskUserQuestion asks a question."
  (let ((status (claude-code-ide-tests--status)))
    (claude-code-ide-tests--feed
     status '(("SessionStart" "{\"source\":\"startup\"}")
              ("UserPromptSubmit" "{}")
              ("Notification" "{\"notification_type\":\"permission_prompt\",\"message\":\"Allow?\"}")))
    (should (equal (cl-subseq (claude-code-ide-session-status--common-state status 10.0) 0 4)
                   '(:state waiting-for-user :reason approval))))
  (let ((status (claude-code-ide-tests--status)))
    (claude-code-ide-tests--feed
     status '(("UserPromptSubmit" "{}")
              ("Notification" "{\"notification_type\":\"worker_permission_prompt\"}")))
    (should (eq (plist-get (claude-code-ide-session-status--common-state status 10.0) :reason)
                'approval)))
  (let ((status (claude-code-ide-tests--status)))
    (claude-code-ide-tests--feed
     status '(("UserPromptSubmit" "{}")
              ("Notification" "{\"notification_type\":\"elicitation_dialog\"}")))
    (should (eq (plist-get (claude-code-ide-session-status--common-state status 10.0) :reason)
                'dialog)))
  ;; No PreToolUse came first, so no tool in flight matches the request
  (let ((status (claude-code-ide-tests--status)))
    (claude-code-ide-tests--feed
     status (list '("UserPromptSubmit" "{}")
                  (claude-code-ide-tests--permission "{\"questions\":[]}" nil "AskUserQuestion")))
    (should (equal (cl-subseq (claude-code-ide-session-status--common-state status 10.0) 0 4)
                   '(:state waiting-for-user :reason question)))))

(ert-deftest claude-code-ide-test-send-prompt-unavailable ()
  "A provider without submit-prompt gives its result from Lisp and an error interactively."
  (claude-code-ide-tests--with-instances
    (claude-code-ide-tests--clear-processes)
    (let* ((claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry))
           (buffer (generate-new-buffer "*cci-test-send*"))
           (session (claude-code-ide-tests--make-session "/tmp/cci-test-send/" :buffer buffer))
           (logged nil))
      (claude-code-ide-register-provider (claude-code-ide-tests--stub-provider))
      (claude-code-ide-instance-register
       (claude-code-ide-instance-create :id "cci-test-send" :provider 'cci-test-stub
                                        :session session :buffer buffer))
      (unwind-protect
          (cl-letf (((symbol-function 'claude-code-ide-debug)
                     (lambda (&rest args) (push args logged))))
            (should (equal (claude-code-ide-send-prompt "cci-test-hello" session)
                           '(:status unavailable :capability submit-prompt)))
            (should-not logged)
            (with-current-buffer buffer
              (setq-local claude-code-ide--session session)
              (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "cci-test-typed")))
                (should-error (call-interactively #'claude-code-ide-send-prompt)
                              :type 'user-error)))
            (should-not logged))
        (let ((kill-buffer-hook nil))
          (kill-buffer buffer))
        (claude-code-ide-tests--clear-processes)))))

(provide 'claude-code-ide-provider-tests)

;; Local Variables:
;; no-update-autoloads: t
;; autoload-compute-prefixes: nil
;; End:

;;; claude-code-ide-provider-tests.el ends here
