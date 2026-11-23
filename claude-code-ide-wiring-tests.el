;;; claude-code-ide-wiring-tests.el --- Tests for the core wiring of the providers  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the wiring in claude-code-ide.el that the providers need:
;; no IDE server for a CLI without the IDE protocol, provider texts,
;; flags and model of each provider, forks, secrets in the debug log,
;; the MCP config file of Claude Code, the process tree calls, the
;; prepare hook, the provider choice of the commands and the menu, and
;; the terminal buffers that stay after a stop.
;; The file is loaded by claude-code-ide-tests.el, after its mocks.
;; All projects and conversation IDs are synthetic.
;;
;; At load, this file points the MCP config folder and the provider
;; file at a temporary folder, for the whole test run, so that no test
;; writes them in the real places.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'claude-code-ide)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-transient)
(require 'claude-code-ide-provider-tests)

(declare-function claude-code-ide-tests--make-session "claude-code-ide-tests")
(declare-function claude-code-ide-tests--clear-processes "claude-code-ide-tests")
(declare-function claude-code-ide-tests--wait-until "claude-code-ide-tests")

;; Options of files that may not be loaded; the tests bind them
(defvar claude-code-ide-process-quit-timeout)
(defvar claude-code-ide-debug-buffer)
(defvar eat-kill-buffer-on-exit)
(defvar claude-code-ide-tests--stopped-copies)
(defvar claude-code-ide-control--held)
(defvar ghostel--pending-redraw)

(declare-function claude-code-ide-control-hold "claude-code-ide-control" (instance-id))
(declare-function claude-code-ide-control-held-p "claude-code-ide-control" (instance-id))
(declare-function claude-code-ide-tests--isolate-run "claude-code-ide-tests" (run &rest args))
(declare-function claude-code-ide-tests--record-stopped-copy "claude-code-ide-tests" (copy))

;; The MCP config folder and the provider file of a test run are in
;; the folder of the run; see `claude-code-ide-tests--isolate-run'.

;;; Helpers

(defvar claude-code-ide-wiring-tests--objects nil
  "Buffers and processes that a test made; `--cleanup' removes them.")

(defun claude-code-ide-wiring-tests--cleanup ()
  "Remove the buffers and processes of the test, and the session state."
  (dolist (object claude-code-ide-wiring-tests--objects)
    (cond
     ((processp object) (when (process-live-p object) (delete-process object)))
     ((bufferp object)
      (when (buffer-live-p object)
        (let ((kill-buffer-hook nil)
              (kill-buffer-query-functions nil))
          (kill-buffer object))))))
  (setq claude-code-ide-wiring-tests--objects nil)
  (claude-code-ide-tests--clear-processes))

(defmacro claude-code-ide-wiring-tests--with-clean (&rest body)
  "Run BODY with no instances and no sessions, and clean up after it."
  (declare (indent 0))
  `(claude-code-ide-tests--with-instances
     (claude-code-ide-tests--clear-processes)
     (let ((claude-code-ide-wiring-tests--objects nil)
           (claude-code-ide-cli-args-functions nil)
           (claude-code-ide-session-prepare-functions nil))
       (unwind-protect
           (progn ,@body)
         (claude-code-ide-wiring-tests--cleanup)))))

(defmacro claude-code-ide-wiring-tests--with-provider-file (&rest body)
  "Run BODY with an empty provider file in a new folder, not yet read."
  (declare (indent 0))
  `(let* ((provider-root (make-temp-file "cci-test-provider-" t))
          (claude-code-ide-provider-file (expand-file-name "sub/current-provider" provider-root))
          (claude-code-ide--current-provider nil)
          (claude-code-ide--current-provider-read nil)
          (claude-code-ide-default-provider 'claude))
     (unwind-protect
         (progn ,@body)
       (delete-directory provider-root t))))

(defmacro claude-code-ide-wiring-tests--quiet (&rest body)
  "Run BODY with `message' silenced."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'message) #'ignore))
     ,@body))

(defvar claude-code-ide-wiring-tests--steps nil
  "Steps of the current mocked start, newest first.
A function on a hook can push its own step here.")

(cl-defun claude-code-ide-wiring-tests--start (spec &key process call run-launch terminal-error)
  "Start an instance as SPEC says, with the terminal mocked.
PROCESS is the process of the terminal; the default is a new `sleep'.
CALL, when non-nil, is a function without arguments that runs in place
of the start, for example a command.
RUN-LAUNCH non-nil makes the mocked terminal call the launch function,
as the real terminal does.  TERMINAL-ERROR non-nil makes it then
signal an error, as a terminal backend that fails.
Return a plist: :session, :launch (the start spec of the launch),
:launch-fn (the function that gives the command), :buffer, :process,
:logs (the `claude-code-ide-log' texts, oldest first) and :order (the
steps of the start, oldest first)."
  (let* ((buffer (generate-new-buffer "*cci-test-wiring*"))
         (process (or process (start-process "cci-test-wiring" nil "sleep" "30")))
         (session nil) (launch nil) (launch-fn nil) (logs nil)
         (claude-code-ide-wiring-tests--steps nil)
         (claude-code-ide-session-start-functions
          (list (lambda (started spec)
                  (setq session started launch spec)))))
    (push buffer claude-code-ide-wiring-tests--objects)
    (push process claude-code-ide-wiring-tests--objects)
    (cl-letf (((symbol-function 'claude-code-ide--ensure-cli) (lambda () t))
              ((symbol-function 'claude-code-ide-codex--detect)
               (lambda (&optional _) '(:available t :program "codex" :version unknown)))
              ((symbol-function 'claude-code-ide--terminal-ensure-backend) #'ignore)
              ((symbol-function 'claude-code-ide-mcp-create-session)
               (lambda (dir session-id &optional instance-name no-ide-server)
                 (if no-ide-server
                     ;; The real session without an IDE server
                     (claude-code-ide-mcp--create-plain-session dir session-id instance-name)
                   (push 'ide-server claude-code-ide-wiring-tests--steps)
                   (claude-code-ide-tests--make-session
                    dir :session-id session-id :instance-name instance-name :port 12345))))
              ((symbol-function 'claude-code-ide--create-terminal-session)
               (lambda (&rest args)
                 (push 'spawn claude-code-ide-wiring-tests--steps)
                 (setq launch-fn (nth 8 args))
                 (when (or run-launch terminal-error)
                   (funcall launch-fn))
                 (when terminal-error
                   (error "cci-test terminal failed"))
                 (cons buffer process)))
              ((symbol-function 'claude-code-ide-mcp-server-session-started)
               (lambda (&rest _) (push 'tools-server claude-code-ide-wiring-tests--steps)))
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
              ((symbol-function 'sleep-for) #'ignore)
              ((symbol-function 'claude-code-ide-log)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) logs))))
      (let ((claude-code-ide-terminal-backend 'ghostel))
        (if call
            (funcall call)
          (claude-code-ide--start-session nil nil spec))))
    (list :session session :launch launch :launch-fn launch-fn
          :buffer buffer :process process
          :logs (nreverse logs) :order (reverse claude-code-ide-wiring-tests--steps))))

(defun claude-code-ide-wiring-tests--spec (&rest args)
  "Return a start spec in the synthetic project, with ARGS."
  (apply #'claude-code-ide-start-spec-create :directory "/tmp/cci-test-wiring/proj/" args))

(defmacro claude-code-ide-wiring-tests--with-config (config &rest body)
  "Run BODY with a running mocked MCP server whose config is CONFIG."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) (lambda () 40001))
             ((symbol-function 'claude-code-ide-mcp-server-get-port) (lambda () 40001))
             ((symbol-function 'claude-code-ide-mcp-server-get-config) (lambda (&rest _) ,config))
             ((symbol-function 'claude-code-ide-mcp-server-get-tool-names)
              (lambda (&rest _) '("mcp__emacs-tools__cci_test"))))
     ,@body))

(defconst claude-code-ide-wiring-tests--secret "cci-test-secret-0123456789abcdef"
  "Synthetic instance secret.")

(defconst claude-code-ide-wiring-tests--token "cci-test-token-'quote\"-$x"
  "Synthetic header token with characters that shell quoting changes.")

(defun claude-code-ide-wiring-tests--config (&optional path-secret)
  "Return a synthetic MCP config with header secrets.
With PATH-SECRET, the URL path also carries a secret."
  `((mcpServers
     . ((emacs-tools
         . ((type . "http")
            (url . ,(if path-secret
                        (format "http://localhost:40001/mcp/cci-test-id/%s" path-secret)
                      "http://localhost:40001/mcp/cci-test-id"))
            (headers . ((X-Emacs-MCP-Token . ,claude-code-ide-wiring-tests--token)
                        (X-Emacs-MCP-Instance-Secret
                         . ,claude-code-ide-wiring-tests--secret)))))))))

;;; 1. No IDE protocol for a provider without it

(ert-deftest claude-code-ide-test-wiring-ide-protocol-slot ()
  "Only the claude provider speaks the IDE protocol, and it is no capability."
  (should (claude-code-ide-provider-ide-protocol-p 'claude))
  (should-not (claude-code-ide-provider-ide-protocol-p 'codex))
  (should-not (claude-code-ide-provider-ide-protocol-p (claude-code-ide-tests--stub-provider)))
  (dolist (name (claude-code-ide-provider-names))
    (should-not (memq 'ide-protocol (claude-code-ide-provider-capabilities
                                     (claude-code-ide-get-provider name)))))
  ;; Registration still accepts a provider with the slot set
  (let ((claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry)))
    (should (claude-code-ide-register-provider
             (claude-code-ide-tests--stub-provider :ide-protocol t)))
    (should (claude-code-ide-provider-ide-protocol-p 'cci-test-stub))))

(ert-deftest claude-code-ide-test-wiring-codex-start-has-no-ide-server ()
  "A Codex start makes no WebSocket server and no lock file; CC gets both."
  (claude-code-ide-wiring-tests--with-clean
    (let* ((lock-dir (make-temp-file "cci-test-lock-" t))
           (websockets 0))
      (unwind-protect
          (cl-letf (((symbol-function 'claude-code-ide-mcp--lockfile-directory)
                     (lambda () (file-name-as-directory lock-dir)))
                    ((symbol-function 'websocket-server)
                     (lambda (&rest _) (cl-incf websockets) (error "No WebSocket server here"))))
            (let* ((started (claude-code-ide-wiring-tests--start
                             (claude-code-ide-wiring-tests--spec :provider 'codex)))
                   (session (plist-get started :session)))
              (should session)
              (should-not (memq 'ide-server (plist-get started :order)))
              (should (= websockets 0))
              (should-not (claude-code-ide-mcp-session-port session))
              (should-not (claude-code-ide-mcp-session-server session))
              (should (eq (gethash (claude-code-ide-mcp-session-session-id session)
                                   claude-code-ide-mcp--sessions)
                          session))
              (should (memq #'claude-code-ide-mcp--track-active-buffer post-command-hook))
              (should-not (directory-files lock-dir nil "\\.lock\\'"))
              ;; The start log names no port
              (should (cl-some (lambda (text) (string-match-p "\\`Codex started in proj\\'" text))
                               (plist-get started :logs))))
            ;; A CC start asks for the IDE server
            (let ((started (claude-code-ide-wiring-tests--start (claude-code-ide-wiring-tests--spec))))
              (should (memq 'ide-server (plist-get started :order)))
              (should (cl-some (lambda (text)
                                 (string-match-p "\\`Claude Code started in proj.* with MCP on port 12345"
                                                 text))
                               (plist-get started :logs)))))
        (delete-directory lock-dir t)))))

(ert-deftest claude-code-ide-test-wiring-plain-session-lifecycle ()
  "The plain session of a Codex instance ends cleanly, and CC gets a real lock file."
  (claude-code-ide-wiring-tests--with-clean
    (let ((lock-dir (make-temp-file "cci-test-lock-" t)))
      (unwind-protect
          (cl-letf (((symbol-function 'claude-code-ide-mcp--lockfile-directory)
                     (lambda () (file-name-as-directory lock-dir))))
            ;; Without the IDE protocol: no server, and the stop works
            (let ((plain (claude-code-ide-mcp-create-session "/tmp/cci-test-wiring/proj/"
                                                             "cci-test-plain" nil 'no-ide-server)))
              (should-not (claude-code-ide-mcp-session-port plain))
              (should-not (claude-code-ide-mcp-session-server plain))
              (should (eq (claude-code-ide-mcp--get-session-by-id "cci-test-plain") plain))
              (claude-code-ide-mcp--stop-session plain)
              (should-not (claude-code-ide-mcp--get-session-by-id "cci-test-plain"))
              (should-not (directory-files lock-dir nil "\\.lock\\'")))
            ;; With it: a real WebSocket server on a random port and a lock file
            (let ((ide (claude-code-ide-mcp-create-session "/tmp/cci-test-wiring/proj/"
                                                           "cci-test-ide")))
              (unwind-protect
                  (progn
                    (should (claude-code-ide-mcp-session-port ide))
                    (should (/= 8765 (claude-code-ide-mcp-session-port ide)))
                    (should (= 1 (length (directory-files lock-dir nil "\\.lock\\'")))))
                (claude-code-ide-mcp--stop-session ide))
              (should-not (directory-files lock-dir nil "\\.lock\\'"))))
        (delete-directory lock-dir t)))))

(ert-deftest claude-code-ide-test-wiring-codex-events-load-with-status ()
  "In a new Emacs, the Codex status adapter loads with the status file."
  (let ((emacs (expand-file-name invocation-name invocation-directory))
        (package-dir (file-name-directory (locate-library "claude-code-ide.el" t))))
    (with-temp-buffer
      (let ((status (apply #'call-process emacs nil t nil "-Q" "-batch" "-L" package-dir
                           (append (mapcan (lambda (path) (list "-L" path))
                                           (cl-remove-if-not #'stringp load-path))
                                   (list "--eval"
                                         (concat "(progn (require 'claude-code-ide)"
                                                 " (princ (format \"before=%s \""
                                                 " (featurep 'claude-code-ide-codex-events)))"
                                                 " (require 'claude-code-ide-session-status)"
                                                 " (princ (format \"after=%s hook-args=%s\""
                                                 " (featurep 'claude-code-ide-codex-events)"
                                                 " (fboundp 'claude-code-ide-codex-status-hook-args))))"))))))
        (should (eq status 0))
        (should (string-match-p "before=nil after=t hook-args=t" (buffer-string)))))))

;;; 2. Provider texts

(ert-deftest claude-code-ide-test-wiring-early-exit-names-provider ()
  "An early exit names the provider and its program, not the CC variable."
  (claude-code-ide-wiring-tests--with-clean
    (let ((process (start-process "cci-test-dead" nil "sleep" "30")))
      (push process claude-code-ide-wiring-tests--objects)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) nil)))
        (let ((err (should-error (claude-code-ide-wiring-tests--start
                                  (claude-code-ide-wiring-tests--spec :provider 'codex)
                                  :process process))))
          (should (string-match-p "\\`Codex exited immediately after startup"
                                  (error-message-string err)))
          (should (string-match-p "(codex)" (error-message-string err)))
          (should-not (string-match-p "claude-code-ide-cli-path" (error-message-string err))))))))

(ert-deftest claude-code-ide-test-wiring-session-provider-name ()
  "The cleanup texts name the provider of the session."
  (claude-code-ide-wiring-tests--with-clean
    (let ((codex (plist-get (claude-code-ide-wiring-tests--start
                             (claude-code-ide-wiring-tests--spec :provider 'codex))
                            :session))
          (cc (plist-get (claude-code-ide-wiring-tests--start
                          (claude-code-ide-wiring-tests--spec :instance-name "cc"))
                         :session)))
      (should (equal (claude-code-ide--session-provider-name codex) "Codex"))
      (should (equal (claude-code-ide--session-provider-name cc) "Claude Code"))
      (should (equal (claude-code-ide--session-provider-name
                      (make-claude-code-ide-mcp-session :session-id "cci-test-none"))
                     "Claude Code")))))

;;; 3. Flags and model for each provider

(ert-deftest claude-code-ide-test-wiring-flags-and-model-per-provider ()
  "Codex never gets the Claude Code flags or model; CC keeps them."
  (claude-code-ide-wiring-tests--with-clean
    (let ((claude-code-ide-cli-extra-flags "--model cci-test-opus --cc-only"))
      (let* ((codex (claude-code-ide-wiring-tests--start
                     (claude-code-ide-wiring-tests--spec :provider 'codex)))
             (instance (claude-code-ide-instance-of-session (plist-get codex :session))))
        (should-not (claude-code-ide-start-spec-extra-flags (plist-get codex :launch)))
        (should (eq (claude-code-ide-instance-model instance) 'unknown)))
      ;; Flags that a spec gives itself pass through for another provider
      (let ((codex (claude-code-ide-wiring-tests--start
                    (claude-code-ide-wiring-tests--spec :provider 'codex :instance-name "own"
                                                        :extra-flags "-m cci-test-gpt"))))
        (should (equal (claude-code-ide-start-spec-extra-flags (plist-get codex :launch))
                       "-m cci-test-gpt")))
      ;; The claude launch reads its own flags and model; the start
      ;; passes only the flags of the spec
      (cl-letf (((symbol-function 'claude-code-ide-mcp-server-ensure-server) #'ignore))
        (let* ((cc (claude-code-ide-wiring-tests--start
                    (claude-code-ide-wiring-tests--spec :instance-name "cc") :run-launch t))
               (instance (claude-code-ide-instance-of-session (plist-get cc :session)))
               (command (plist-get (funcall (plist-get cc :launch-fn)) :command)))
          (should (equal (claude-code-ide-start-spec-extra-flags (plist-get cc :launch))
                         "--model cci-test-opus --cc-only"))
          (should (equal (claude-code-ide-instance-model instance) "cci-test-opus"))
          (should (string-search " --model cci-test-opus --cc-only" command))
          (should-not (cl-some (lambda (text) (string-search "debug mode" text))
                               (plist-get cc :logs))))
        ;; A spec's own flags win; the debug mode shows in the start text
        (let* ((claude-code-ide-cli-debug t)
               (cc (claude-code-ide-wiring-tests--start
                    (claude-code-ide-wiring-tests--spec :instance-name "own-cc"
                                                        :extra-flags "--model cci-test-sonnet")
                    :run-launch t))
               (instance (claude-code-ide-instance-of-session (plist-get cc :session))))
          (should (equal (claude-code-ide-instance-model instance) "cci-test-sonnet"))
          (should (cl-some (lambda (text)
                             (string-match-p "\\`Claude Code started in proj:own-cc.* (debug mode enabled)\\'"
                                             text))
                           (plist-get cc :logs))))))))

;;; 4. Fork

(ert-deftest claude-code-ide-test-wiring-fork ()
  "A fork calls the fork operation, and its native ID starts as unknown."
  (claude-code-ide-wiring-tests--with-clean
    (let* ((claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry))
           (calls nil)
           (record (lambda (operation)
                     (lambda (instance spec _args)
                       (push (list operation (claude-code-ide-instance-native-id instance)
                                   (claude-code-ide-start-spec-resume-id spec))
                             calls)
                       (list :command "cci-stub" :environment nil)))))
      (claude-code-ide-register-provider
       (claude-code-ide-tests--stub-provider :launch (funcall record 'launch)
                                             :resume (funcall record 'resume)
                                             :fork (funcall record 'fork)))
      ;; Old callers: no :fork slot, a resume of the ID
      (let* ((spec (claude-code-ide-wiring-tests--spec :provider 'cci-test-stub
                                                       :resume-id "cci-test-native-1"))
             (started (claude-code-ide-wiring-tests--start spec))
             (instance (claude-code-ide-instance-of-session (plist-get started :session))))
        (should-not (claude-code-ide-start-spec-fork spec))
        (should (equal (claude-code-ide-instance-native-id instance) "cci-test-native-1"))
        (funcall (plist-get started :launch-fn))
        (should (equal (car calls) '(resume "cci-test-native-1" "cci-test-native-1"))))
      ;; A fork
      (let* ((started (claude-code-ide-wiring-tests--start
                       (claude-code-ide-wiring-tests--spec :provider 'cci-test-stub
                                                           :instance-name "fork"
                                                           :resume-id "cci-test-native-1"
                                                           :fork t)))
             (instance (claude-code-ide-instance-of-session (plist-get started :session))))
        (should (eq (claude-code-ide-instance-native-id instance) 'unknown))
        (should (claude-code-ide-start-spec-fork (plist-get started :launch)))
        (funcall (plist-get started :launch-fn))
        (should (equal (car calls) '(fork unknown "cci-test-native-1")))
        ;; Without the session registry (no start function of it runs
        ;; here), nothing sets the resume ID as the native ID later
        (should-not (memq #'claude-code-ide-session-registry--on-start
                          claude-code-ide-session-start-functions))
        (should (eq (claude-code-ide-instance-native-id instance) 'unknown))
        (should (cl-some (lambda (text) (string-match-p "\\`Stub forked and started" text))
                         (plist-get started :logs))))
      ;; A fork without the ID to fork
      (should-error (claude-code-ide-wiring-tests--start
                     (claude-code-ide-wiring-tests--spec :provider 'cci-test-stub :fork t))
                    :type 'user-error))))

;;; 5. No secret in the debug log

(ert-deftest claude-code-ide-test-wiring-config-secrets ()
  "The secrets of a config are its header values and the path secret."
  (let ((secrets (claude-code-ide--config-secrets
                  (claude-code-ide-wiring-tests--config "cci-test-path-secret-99"))))
    (should (member claude-code-ide-wiring-tests--secret secrets))
    (should (member claude-code-ide-wiring-tests--token secrets))
    (should (member "cci-test-path-secret-99" secrets))
    (should (= 3 (length secrets))))
  (should-not (claude-code-ide--config-secrets
               '((mcpServers . ((emacs-tools . ((type . "http")
                                                (url . "http://localhost:1/mcp/cci-test-id"))))))))
  (should-not (claude-code-ide--config-secrets nil)))

(ert-deftest claude-code-ide-test-wiring-redact-command ()
  "A logged command has no secret, also when the shell quoting changed it."
  (let* ((secrets (claude-code-ide--config-secrets (claude-code-ide-wiring-tests--config)))
         (command (mapconcat #'shell-quote-argument
                             (list "codex" "-c"
                                   (format "mcp_servers.emacs_tools.http_headers={\"X\"=\"%s\"}"
                                           claude-code-ide-wiring-tests--token)
                                   "--" (format "say %s" claude-code-ide-wiring-tests--secret))
                             " "))
         (logged (claude-code-ide--redact-command command secrets)))
    ;; The quoting really changed the token in the command
    (should-not (string-search claude-code-ide-wiring-tests--token command))
    (should-not (string-search claude-code-ide-wiring-tests--token logged))
    (should-not (string-search claude-code-ide-wiring-tests--secret logged))
    (should-not (string-search "quote" logged))
    (should (string-search claude-code-ide--redacted logged))
    (should (string-prefix-p "codex -c " logged))
    ;; No secret: the command stays as it is
    (should (equal (claude-code-ide--redact-command command nil) command))))

(ert-deftest claude-code-ide-test-wiring-debug-log-has-no-secret ()
  "With debugging on, the CC command build and the terminal start log no secret."
  (let ((claude-code-ide-debug t)
        (claude-code-ide-debug-buffer " *cci-test-debug*")
        (claude-code-ide-cli-extra-flags "")
        (claude-code-ide-cli-path "claude")
        (config (claude-code-ide-wiring-tests--config "cci-test-path-secret-99")))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-ide-debug)
                   ;; The test loader replaces the macro with a function
                   ;; that drops the text; compiled code has the macro
                   (if (macrop 'claude-code-ide-debug)
                       (symbol-function 'claude-code-ide-debug)
                     (lambda (format-string &rest args)
                       (with-current-buffer (get-buffer-create claude-code-ide-debug-buffer)
                         (goto-char (point-max))
                         (insert (apply #'format format-string args) "\n"))))))
          (claude-code-ide-wiring-tests--with-config config
            (claude-code-ide--build-claude-command nil nil "cci-test-sid")
            ;; The start path of another provider puts the config on its
            ;; command line; the terminal start logs it
            (cl-letf (((symbol-function 'claude-code-ide--terminal-ensure-backend) #'ignore)
                      ((symbol-function 'vterm) (lambda (&rest _) (error "cci-test stop here"))))
              (let ((claude-code-ide-terminal-backend 'vterm))
                (ignore-errors
                  (claude-code-ide--create-terminal-session
                   "*cci-test-never*" "/tmp/" nil nil nil "cci-test-sid" nil nil
                   (lambda ()
                     (list :command (mapconcat
                                     #'shell-quote-argument
                                     (list "codex" "-c"
                                           (format "x={\"T\"=\"%s\"}" claude-code-ide-wiring-tests--token)
                                           "-c" (format "url=\"/mcp/cci-test-id/%s\""
                                                        "cci-test-path-secret-99"))
                                     " ")
                           :environment nil))))))
            (let ((log (with-current-buffer claude-code-ide-debug-buffer (buffer-string))))
              (should (string-search "MCP tools config in " log))
              (should (string-search "Starting the CLI with command: codex" log))
              (should-not (string-search claude-code-ide-wiring-tests--secret log))
              (should-not (string-search claude-code-ide-wiring-tests--token log))
              (should-not (string-search "cci-test-path-secret-99" log))
              (should (string-search claude-code-ide--redacted log)))))
      (when (get-buffer " *cci-test-debug*")
        (kill-buffer " *cci-test-debug*"))
      (claude-code-ide--delete-mcp-config-file "cci-test-sid"))))

;;; 6. CC MCP config in a file

(ert-deftest claude-code-ide-test-wiring-mcp-config-file ()
  "CC gets --mcp-config FILE: mode 0600 in a 0700 folder, no secret on the line."
  (let ((claude-code-ide-cli-extra-flags "")
        (claude-code-ide-cli-path "claude")
        (config (claude-code-ide-wiring-tests--config)))
    (unwind-protect
        (claude-code-ide-wiring-tests--with-config config
          (let* ((command (claude-code-ide--build-claude-command nil nil "cci-test-sid-file"))
                 (words (claude-code-ide--split-command-line command))
                 (file (cadr (member "--mcp-config" words))))
            (should file)
            (should (file-name-absolute-p file))
            (should (equal file (claude-code-ide--mcp-config-file "cci-test-sid-file")))
            (should (string-prefix-p (claude-code-ide--mcp-config-directory) file))
            (should (= (file-modes file) #o600))
            (should (= (file-modes (directory-file-name (claude-code-ide--mcp-config-directory)))
                       #o700))
            (should (equal (json-read-file file) (json-read-from-string (json-encode config))))
            ;; No secret and no JSON on the command line
            (should-not (string-search claude-code-ide-wiring-tests--secret command))
            (should-not (string-search "cci-test-token" command))
            (should-not (string-search "mcpServers" command))
            ;; A second build of the same session gives the same file, and
            ;; no temporary file stays
            (should (equal (cadr (member "--mcp-config"
                                         (claude-code-ide--split-command-line
                                          (claude-code-ide--build-claude-command
                                           nil nil "cci-test-sid-file"))))
                           file))
            (should-not (directory-files (claude-code-ide--mcp-config-directory) nil "\\.tmp\\'"))))
      (claude-code-ide--delete-mcp-config-file "cci-test-sid-file"))
    (should-not (file-exists-p (claude-code-ide--mcp-config-file "cci-test-sid-file")))))

(ert-deftest claude-code-ide-test-wiring-mcp-config-file-cleanup ()
  "The config file goes at the end of its session and at Emacs quit."
  (claude-code-ide-wiring-tests--with-clean
    (let ((claude-code-ide-cli-extra-flags "")
          (claude-code-ide--mcp-config-files nil))
      (claude-code-ide-wiring-tests--with-config (claude-code-ide-wiring-tests--config)
        (let* ((started (claude-code-ide-wiring-tests--start (claude-code-ide-wiring-tests--spec)))
               (session (plist-get started :session))
               (session-id (claude-code-ide-mcp-session-session-id session))
               (command (plist-get (funcall (plist-get started :launch-fn)) :command))
               (file (cadr (member "--mcp-config" (claude-code-ide--split-command-line command)))))
          (should (equal file (claude-code-ide--mcp-config-file session-id)))
          (should (file-exists-p file))
          (cl-letf (((symbol-function 'claude-code-ide-mcp-server-session-ended) #'ignore)
                    ((symbol-function 'claude-code-ide-mcp--stop-session) #'ignore))
            (claude-code-ide--cleanup-session session))
          (should-not (file-exists-p file))
          (should-not claude-code-ide--mcp-config-files))
        ;; Emacs quit: also a file whose session is gone
        (let ((file (claude-code-ide--write-mcp-config-file "cci-test-orphan" "{}")))
          (should (file-exists-p file))
          (claude-code-ide--cleanup-all-sessions)
          (should-not (file-exists-p file))
          (should-not claude-code-ide--mcp-config-files))))))

(ert-deftest claude-code-ide-test-wiring-private-directory ()
  "The config folder is made 0700; a link or an open folder is handled."
  (let ((root (make-temp-file "cci-test-private-" t)))
    (unwind-protect
        (let ((new (expand-file-name "a/b" root))
              (open (expand-file-name "open" root))
              (link (expand-file-name "link" root)))
          (claude-code-ide--ensure-private-directory new)
          (should (= (file-modes new) #o700))
          (make-directory open)
          (set-file-modes open #o755)
          (claude-code-ide--ensure-private-directory open)
          (should (= (file-modes open) #o700))
          (make-symbolic-link open link)
          (should-error (claude-code-ide--ensure-private-directory link))
          ;; A link as the folder: the file goes to a new private folder
          (let* ((claude-code-ide-mcp-config-directory link)
                 (claude-code-ide--mcp-config-fallback-directory nil)
                 (claude-code-ide--mcp-config-files nil)
                 (file (claude-code-ide-wiring-tests--quiet
                         (claude-code-ide--write-mcp-config-file "cci-test-link" "{}")))
                 (dir (file-name-directory file)))
            (unwind-protect
                (progn
                  (should-not (string-prefix-p (file-name-as-directory link) file))
                  (should (= (file-modes (directory-file-name dir)) #o700))
                  (should (= (file-modes file) #o600)))
              (claude-code-ide--delete-all-mcp-config-files)
              (delete-directory dir t)))
          (should-not (directory-files open nil "\\.json\\'")))
      (delete-directory root t))))

(ert-deftest claude-code-ide-test-wiring-mcp-config-other-user ()
  "A config folder of another user does not stop the start: a new folder is used."
  (let* ((root (make-temp-file "cci-test-other-" t))
         (claude-code-ide-mcp-config-directory root)
         (claude-code-ide--mcp-config-fallback-directory nil)
         (claude-code-ide--mcp-config-files nil)
         (real-uid (user-uid))
         (messages nil))
    (unwind-protect
        (let ((file (cl-letf (((symbol-function 'file-attributes)
                               (let ((original (symbol-function 'file-attributes)))
                                 (lambda (name &rest args)
                                   (let ((attributes (apply original name args)))
                                     ;; The usual folder belongs to another user
                                     (if (equal (directory-file-name (expand-file-name name))
                                                (directory-file-name root))
                                         (append (list (nth 0 attributes) (nth 1 attributes)
                                                       (1+ real-uid))
                                                 (nthcdr 3 attributes))
                                       attributes)))))
                              ((symbol-function 'message)
                               (lambda (format-string &rest args)
                                 (push (apply #'format format-string args) messages))))
                      (claude-code-ide--write-mcp-config-file "cci-test-other" "{\"a\":1}"))))
          (should (file-exists-p file))
          (should-not (string-prefix-p (file-name-as-directory root) file))
          (should (equal (file-name-directory file) claude-code-ide--mcp-config-fallback-directory))
          (should (= (file-modes (directory-file-name (file-name-directory file))) #o700))
          (should (= (file-modes file) #o600))
          (should (cl-some (lambda (text) (string-search "belongs to another user" text)) messages))
          ;; The delete finds the file in the new folder
          (claude-code-ide--delete-mcp-config-file "cci-test-other")
          (should-not (file-exists-p file)))
      (when claude-code-ide--mcp-config-fallback-directory
        (delete-directory claude-code-ide--mcp-config-fallback-directory t))
      (delete-directory root t))))

(ert-deftest claude-code-ide-test-wiring-mcp-config-delete-written-path ()
  "The delete uses the file that was written, also after the folder option changed."
  (let* ((root (make-temp-file "cci-test-moved-" t))
         (first (expand-file-name "first" root))
         (second (expand-file-name "second" root))
         (claude-code-ide--mcp-config-files nil)
         (file (let ((claude-code-ide-mcp-config-directory first))
                 (claude-code-ide--write-mcp-config-file "cci-test-moved" "{}"))))
    (unwind-protect
        (let ((claude-code-ide-mcp-config-directory second))
          (should (string-prefix-p (file-name-as-directory first) file))
          ;; A second write of the same session keeps its file
          (should (equal (claude-code-ide--write-mcp-config-file "cci-test-moved" "{\"b\":2}") file))
          (should (equal (claude-code-ide--mcp-config-file "cci-test-moved") file))
          (claude-code-ide--delete-mcp-config-file "cci-test-moved")
          (should-not (file-exists-p file))
          (should-not claude-code-ide--mcp-config-files)
          (should-not (file-exists-p second)))
      (delete-directory root t))))

(defun claude-code-ide-wiring-tests--dead-pid ()
  "Return a process ID that no process has now."
  (let ((pid 99990))
    (while (process-attributes pid)
      (cl-decf pid))
    pid))

(ert-deftest claude-code-ide-test-wiring-mcp-config-sweep ()
  "The first write deletes the files of Emacs processes that no longer run."
  (let* ((root (make-temp-file "cci-test-sweep-" t))
         (claude-code-ide-mcp-config-directory root)
         (claude-code-ide--mcp-config-files nil)
         (claude-code-ide--mcp-config-swept nil)
         (other (start-process "cci-test-not-emacs" nil "sleep" "30"))
         (dead (expand-file-name (format "mcp-%d-0123456789abcdef.json"
                                         (claude-code-ide-wiring-tests--dead-pid))
                                 root))
         (not-emacs (expand-file-name (format "mcp-%d-0123456789abcdef.json" (process-id other))
                                      root))
         (own (expand-file-name (format "mcp-%d-fedcba9876543210.json" (emacs-pid)) root))
         (unrelated (expand-file-name "notes.json" root)))
    (unwind-protect
        (progn
          (dolist (file (list dead not-emacs own unrelated))
            (with-temp-file file (insert "{}")))
          (claude-code-ide--write-mcp-config-file "cci-test-sweep" "{}")
          (should-not (file-exists-p dead))
          (should-not (file-exists-p not-emacs))
          (should (file-exists-p own))
          (should (file-exists-p unrelated))
          ;; The folder is swept once in this Emacs
          (with-temp-file dead (insert "{}"))
          (claude-code-ide--write-mcp-config-file "cci-test-sweep-2" "{}")
          (should (file-exists-p dead)))
      (when (process-live-p other) (delete-process other))
      (claude-code-ide--delete-all-mcp-config-files)
      (delete-directory root t))))

(ert-deftest claude-code-ide-test-wiring-mcp-config-failed-start ()
  "A start whose terminal fails deletes the MCP config file that its launch wrote."
  (claude-code-ide-wiring-tests--with-clean
    (let ((claude-code-ide-cli-extra-flags "")
          (claude-code-ide--mcp-config-files nil))
      (claude-code-ide-wiring-tests--with-config (claude-code-ide-wiring-tests--config)
        (let ((written nil))
          (cl-letf* ((original (symbol-function 'claude-code-ide--write-mcp-config-file))
                     ((symbol-function 'claude-code-ide--write-mcp-config-file)
                      (lambda (&rest args)
                        (setq written (apply original args)))))
            (should-error (claude-code-ide-wiring-tests--start
                           (claude-code-ide-wiring-tests--spec) :terminal-error t)))
          (should written)
          (should-not (file-exists-p written))
          (should-not claude-code-ide--mcp-config-files)
          (should (= 0 (hash-table-count claude-code-ide-mcp--sessions))))))))

;;; 7. Process-tree calls

(ert-deftest claude-code-ide-test-wiring-process-track-at-launch ()
  "The launch records the PID, its start time and the process tree."
  (claude-code-ide-wiring-tests--with-clean
    (let ((tracked nil))
      (cl-letf (((symbol-function 'claude-code-ide-process-track)
                 (lambda (instance process)
                   ;; The process file accepts PROCESS only when it is the
                   ;; process of the descriptor's buffer, or has its PID,
                   ;; so both are known at this call
                   (push (list instance process
                               (claude-code-ide-instance-buffer instance)
                               (claude-code-ide-instance-pid instance))
                         tracked))))
        (let* ((started (claude-code-ide-wiring-tests--start
                         (claude-code-ide-wiring-tests--spec :provider 'codex)))
               (instance (claude-code-ide-instance-of-session (plist-get started :session)))
               (process (plist-get started :process)))
          (should (equal tracked (list (list instance process
                                             (plist-get started :buffer)
                                             (process-id process)))))
          (should (equal (claude-code-ide-instance-pid instance)
                         (process-id (plist-get started :process))))
          (should (floatp (claude-code-ide-instance-process-start-time instance))))))
    ;; A failing tracker does not stop the start
    (cl-letf (((symbol-function 'claude-code-ide-process-track)
               (lambda (&rest _) (error "cci-test track failed"))))
      (should (plist-get (claude-code-ide-wiring-tests--start
                          (claude-code-ide-wiring-tests--spec :instance-name "failing"))
                         :session)))
    (should (plist-get (claude-code-ide-wiring-tests--start
                        (claude-code-ide-wiring-tests--spec :instance-name "untracked"))
                       :session))))

(ert-deftest claude-code-ide-test-wiring-ghostel-pid ()
  "The descriptor gets the native PID of a ghostel pipe, with its start time."
  (claude-code-ide-wiring-tests--with-clean
    (let* ((child (start-process "cci-test-native" nil "sleep" "30"))
           (pipe (make-pipe-process :name "cci-test-pipe" :noquery t)))
      (push child claude-code-ide-wiring-tests--objects)
      (push pipe claude-code-ide-wiring-tests--objects)
      (process-put pipe 'ghostel--native-pid (process-id child))
      (should (equal (claude-code-ide--process-pid pipe) (process-id child)))
      (should (equal (claude-code-ide--process-pid child) (process-id child)))
      (should-not (claude-code-ide--process-pid nil))
      (let* ((started (claude-code-ide-wiring-tests--start
                       (claude-code-ide-wiring-tests--spec) :process pipe))
             (instance (claude-code-ide-instance-of-session (plist-get started :session))))
        (should (equal (claude-code-ide-instance-pid instance) (process-id child)))
        (should (floatp (claude-code-ide-instance-process-start-time instance)))))))

(defvar ghostel--pid)

(ert-deftest claude-code-ide-test-wiring-ghostel-native-child-pid ()
  "The descriptor gets the PID of the native child of a newer ghostel.
ghostel 20261111 keeps the child handle in the process property
`ghostel--native-child', and gives its PID through
`ghostel--native-child-pid'; it sets no `ghostel--native-pid'.  The
start must record the PID for each provider, so that a stop can end
the CLI."
  (dolist (provider '(claude codex))
    (claude-code-ide-wiring-tests--with-clean
      (let* ((child (start-process "cci-test-native" nil "sleep" "30"))
             (pipe (make-pipe-process :name "cci-test-pipe" :noquery t)))
        (push child claude-code-ide-wiring-tests--objects)
        (push pipe claude-code-ide-wiring-tests--objects)
        (process-put pipe 'ghostel--native-child 'cci-test-child-handle)
        (cl-letf (((symbol-function 'ghostel--native-child-pid)
                   (lambda (handle)
                     (and (eq handle 'cci-test-child-handle) (process-id child)))))
          (should (equal (claude-code-ide--process-pid pipe) (process-id child)))
          (let* ((started (claude-code-ide-wiring-tests--start
                           (claude-code-ide-wiring-tests--spec :provider provider) :process pipe))
                 (instance (claude-code-ide-instance-of-session (plist-get started :session))))
            (should (equal (list provider (claude-code-ide-instance-pid instance))
                           (list provider (process-id child))))
            (should (floatp (claude-code-ide-instance-process-start-time instance)))))))))

(ert-deftest claude-code-ide-test-wiring-ghostel-buffer-pid ()
  "Without a child handle, the buffer-local `ghostel--pid' gives the PID."
  (claude-code-ide-wiring-tests--with-clean
    (let* ((buffer (generate-new-buffer " *cci-test-ghostel*"))
           (pipe (make-pipe-process :name "cci-test-pipe" :buffer buffer :noquery t)))
      (push pipe claude-code-ide-wiring-tests--objects)
      (unwind-protect
          (progn
            (should-not (claude-code-ide--process-pid pipe))
            (with-current-buffer buffer (setq-local ghostel--pid 4343))
            (should (eql (claude-code-ide--process-pid pipe) 4343))
            ;; A handle whose function fails falls back to the buffer
            (process-put pipe 'ghostel--native-child 'cci-test-broken)
            (cl-letf (((symbol-function 'ghostel--native-child-pid)
                       (lambda (_) (error "cci-test: no child"))))
              (should (eql (claude-code-ide--process-pid pipe) 4343))))
        (delete-process pipe)
        (kill-buffer buffer)))))

(defmacro claude-code-ide-wiring-tests--with-process-stubs (calls &rest body)
  "Run BODY with the process-tree functions stubbed; they push to CALLS."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'claude-code-ide-process-stop)
              (lambda (instance &rest args) (push (list 'stop instance args) ,calls)
                '(:status stopped :strays nil)))
             ((symbol-function 'claude-code-ide-process-stop-later)
              (lambda (instance &rest args) (push (list 'stop-later instance args) ,calls)))
             ((symbol-function 'claude-code-ide-process-untrack)
              (lambda (instance) (push (list 'untrack instance) ,calls)))
             ((symbol-function 'claude-code-ide-process-stop-many)
              (lambda (instances &rest args) (push (list 'stop-many instances args) ,calls)))
             ((symbol-function 'claude-code-ide-mcp-server-session-ended) #'ignore)
             ((symbol-function 'claude-code-ide-mcp--stop-session)
              (lambda (session)
                (remhash (claude-code-ide-mcp-session-session-id session)
                         claude-code-ide-mcp--sessions))))
     ,@body))

(ert-deftest claude-code-ide-test-wiring-cleanup-stop-cases ()
  "The cleanup stops a live CLI, stops it later in the kill hook, forgets a dead one.
This is the cleanup with `claude-code-ide-keep-stopped-buffers' nil."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers nil))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        ;; A live CLI: the stop, with the process, before the buffer goes
        (let* ((started (claude-code-ide-wiring-tests--start (claude-code-ide-wiring-tests--spec)))
               (session (plist-get started :session))
               (instance (claude-code-ide-instance-of-session session)))
          (claude-code-ide--cleanup-session session)
          (should (equal (car calls)
                         (list 'stop instance (list :process (plist-get started :process) :scan nil)))))
        ;; Inside kill-buffer-hook: the stop from timers
        (let* ((started (claude-code-ide-wiring-tests--start
                         (claude-code-ide-wiring-tests--spec :instance-name "dying")))
               (session (plist-get started :session))
               (instance (claude-code-ide-instance-of-session session)))
          (claude-code-ide--cleanup-session session 'buffer-dying)
          (should (equal (car calls)
                         (list 'stop-later instance
                               (list :process (plist-get started :process) :scan nil)))))
        ;; The CLI ended by itself: forget its records only
        (let* ((started (claude-code-ide-wiring-tests--start
                         (claude-code-ide-wiring-tests--spec :instance-name "dead")))
               (session (plist-get started :session))
               (instance (claude-code-ide-instance-of-session session)))
          (delete-process (plist-get started :process))
          (claude-code-ide--cleanup-session session)
          (should (equal (car calls) (list 'untrack instance))))
        (should (= 3 (length calls)))))))

(ert-deftest claude-code-ide-test-wiring-cleanup-stop-error ()
  "An error of the process stop does not stop the cleanup."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (claude-code-ide-keep-stopped-buffers nil))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (cl-letf (((symbol-function 'claude-code-ide-process-stop)
                   (lambda (&rest _) (error "cci-test stop failed"))))
          (let* ((started (claude-code-ide-wiring-tests--start (claude-code-ide-wiring-tests--spec)))
                 (session (plist-get started :session)))
            (claude-code-ide--cleanup-session session)
            (should (claude-code-ide-mcp-session-cleanup-done session))
            (should-not (claude-code-ide-instance-of-session session))
            (should-not (buffer-live-p (plist-get started :buffer)))))))))

(ert-deftest claude-code-ide-test-wiring-quit-stops-all-first ()
  "At Emacs quit, one stop of all CLIs with the quit budget comes before any cleanup.
The cleanup of each session then runs no second stop: that stop would
wait without the budget for a CLI that still runs."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (claude-code-ide-process-quit-timeout 1.5))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((a (plist-get (claude-code-ide-wiring-tests--start
                              (claude-code-ide-wiring-tests--spec))
                             :session))
               (b (plist-get (claude-code-ide-wiring-tests--start
                              (claude-code-ide-wiring-tests--spec :provider 'codex))
                             :session))
               (instances (list (claude-code-ide-instance-of-session a)
                                (claude-code-ide-instance-of-session b))))
          (claude-code-ide--cleanup-all-sessions)
          (let ((order (reverse calls)))
            (should (eq (car (car order)) 'stop-many))
            (should-not (cl-set-exclusive-or (nth 1 (car order)) instances))
            (should (= 2 (length (nth 1 (car order)))))
            (should (equal (nth 2 (car order))
                           '(:budget 1.5 :timeout 1 :kill-wait 0.25 :scan nil)))
            ;; Then each cleanup, without a second stop
            (should-not (cdr order))
            (should-not (claude-code-ide-instance-of-session a))
            (should-not (claude-code-ide-instance-of-session b))))))
    (should (memq #'claude-code-ide--cleanup-all-sessions kill-emacs-hook))))

(defun claude-code-ide-wiring-tests--ghostel-like ()
  "Stand-in for ghostel's quit hook, at depth 0."
  nil)

(ert-deftest claude-code-ide-test-wiring-quit-hook-order ()
  "At quit, the registry hook runs first, then the cleanup, then ghostel's.
The order holds also after the files are evaluated again."
  (let ((kill-emacs-hook nil)
        (position (lambda (fn) (cl-position fn kill-emacs-hook))))
    (should (< -50 claude-code-ide--quit-hook-depth 0))
    ;; In the order of a normal start: the main file, then the registry
    ;; mode, then ghostel
    (claude-code-ide--install-quit-hook)
    (add-hook 'kill-emacs-hook #'claude-code-ide-session-registry--on-kill-emacs -50)
    (add-hook 'kill-emacs-hook #'claude-code-ide-wiring-tests--ghostel-like)
    (dotimes (_ 2)
      (should (< (funcall position #'claude-code-ide-session-registry--on-kill-emacs)
                 (funcall position #'claude-code-ide--cleanup-all-sessions)
                 (funcall position #'claude-code-ide-wiring-tests--ghostel-like)))
      ;; A reload evaluates both files again
      (claude-code-ide--install-quit-hook)
      (remove-hook 'kill-emacs-hook #'claude-code-ide-session-registry--on-kill-emacs)
      (add-hook 'kill-emacs-hook #'claude-code-ide-session-registry--on-kill-emacs -50))
    (should (= 1 (cl-count #'claude-code-ide--cleanup-all-sessions kill-emacs-hook)))))

;;; The prepare hook (contract addition for the session registry)

(ert-deftest claude-code-ide-test-wiring-prepare-hook ()
  "The prepare hook runs once per start, before the spawn, for both providers."
  (claude-code-ide-wiring-tests--with-clean
    (dolist (provider '(claude codex))
      (let* ((calls nil)
             (claude-code-ide-session-prepare-functions
              (list (lambda (session launch)
                      (push (list session launch
                                  (claude-code-ide-instance-of-session session))
                            calls))))
             (started (claude-code-ide-wiring-tests--start
                       (claude-code-ide-wiring-tests--spec :provider provider
                                                           :instance-name (symbol-name provider))))
             (session (plist-get started :session)))
        (should (= 1 (length calls)))
        (should (eq (nth 0 (car calls)) session))
        (should (eq (claude-code-ide-start-spec-provider (nth 1 (car calls))) provider))
        ;; The descriptor exists at the call
        (should (claude-code-ide-instance-p (nth 2 (car calls))))))
    ;; Before the spawn, after the tools server registration
    (let* ((claude-code-ide-session-prepare-functions
            (list (lambda (&rest _) (push 'prepare claude-code-ide-wiring-tests--steps))))
           (started (claude-code-ide-wiring-tests--start
                     (claude-code-ide-wiring-tests--spec :instance-name "order"))))
      (should (equal (plist-get started :order) '(ide-server tools-server prepare spawn))))
    ;; An error is reported, and the start goes on
    (let* ((messages nil)
           (claude-code-ide-session-prepare-functions
            (list (lambda (&rest _) (error "cci-test prepare failed")))))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (should (plist-get (claude-code-ide-wiring-tests--start
                            (claude-code-ide-wiring-tests--spec :instance-name "error"))
                           :session)))
      (should (cl-some (lambda (text) (string-match-p "cci-test prepare failed" text)) messages)))))

;;; Codex approvals of coordinator tools

(ert-deftest claude-code-ide-test-wiring-codex-coordinator-approvals ()
  "A Codex coordinator gets list and inspect approved; the others always ask."
  (let ((claude-code-ide-mcp-server-tools
         (list (list :function #'ignore :name "claude-code-ide-mcp-project-info"
                     :description "cci-test")
               (list :function #'ignore :name "claude-code-ide-control-list-instances"
                     :description "cci-test" :scope 'coordinator)
               (list :function #'ignore :name "claude-code-ide-control-inspect-instance"
                     :description "cci-test" :scope 'coordinator)
               (list :function #'ignore :name "claude-code-ide-control-launch"
                     :description "cci-test" :scope 'coordinator)
               (list :function #'ignore :name "claude-code-ide-control-stop"
                     :description "cci-test" :scope 'coordinator)
               (list :function #'ignore :name "claude-code-ide-control-submit-prompt"
                     :description "cci-test" :scope 'coordinator)))
        (claude-code-ide-mcp-allowed-tools 'auto)
        (approved (lambda (role)
                    (let ((args (claude-code-ide-codex--approval-args
                                 "mcp_servers.emacs_tools"
                                 (claude-code-ide-instance-create :id "cci-test-coord" :role role))))
                      (delq nil
                            (mapcar (lambda (arg)
                                      (when (string-match
                                             "\\`mcp_servers\\.emacs_tools\\.tools\\.\\(.+\\)\\.approval_mode=\"approve\"\\'"
                                             arg)
                                        (match-string 1 arg)))
                                    args))))))
    (cl-letf (((symbol-function 'claude-code-ide-mcp-server-get-tool-names)
               (lambda (&optional prefix)
                 (mapcar (lambda (tool) (concat (or prefix "") (plist-get tool :name)))
                         claude-code-ide-mcp-server-tools))))
      (should (equal (funcall approved "coordinator")
                     '("claude-code-ide-mcp-project-info"
                       "claude-code-ide-control-list-instances"
                       "claude-code-ide-control-inspect-instance")))
      ;; Another role, no role, and no instance: no coordinator tool
      (dolist (role '("worker" nil))
        (should (equal (funcall approved role) '("claude-code-ide-mcp-project-info"))))
      (should (equal (claude-code-ide-codex--approved-tool-names)
                     '("claude-code-ide-mcp-project-info")))
      ;; The default is "prompt", so the other coordinator tools ask
      (should (member "mcp_servers.emacs_tools.default_tools_approval_mode=\"prompt\""
                      (claude-code-ide-codex--approval-args
                       "mcp_servers.emacs_tools"
                       (claude-code-ide-instance-create :id "cci-test-c2" :role "coordinator"))))
      ;; With approvals off, nothing is approved, also for a coordinator
      (let ((claude-code-ide-mcp-allowed-tools nil))
        (should-not (funcall approved "coordinator"))))))

(ert-deftest claude-code-ide-test-wiring-codex-command-sets-provider ()
  "M-x claude-code-ide-codex makes Codex the current provider."
  (claude-code-ide-wiring-tests--with-provider-file
    (cl-letf (((symbol-function 'claude-code-ide--start-session) #'ignore))
      (should (eq (claude-code-ide-current-provider) 'claude))
      (call-interactively #'claude-code-ide-codex)
      (should (eq (claude-code-ide-current-provider) 'codex))
      (should (equal (with-temp-buffer
                       (insert-file-contents claude-code-ide-provider-file)
                       (buffer-string))
                     "codex\n")))))

;;; 8. Provider choice

(ert-deftest claude-code-ide-test-wiring-provider-toggle-cycles ()
  "The toggle cycles through the registered providers, in order."
  (claude-code-ide-wiring-tests--with-provider-file
    (let ((claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry)))
      (claude-code-ide-register-provider (claude-code-ide-tests--stub-provider))
      (should (equal (claude-code-ide-provider-names) '(claude codex cci-test-stub)))
      (should (eq (claude-code-ide-current-provider) 'claude))
      (should (eq (claude-code-ide-toggle-provider) 'codex))
      (should (eq (claude-code-ide-current-provider) 'codex))
      (should (eq (claude-code-ide-toggle-provider) 'cci-test-stub))
      (should (eq (claude-code-ide-toggle-provider) 'claude))
      (should (eq (claude-code-ide--next-provider 'cci-test-unknown) 'claude)))))

(ert-deftest claude-code-ide-test-wiring-provider-persists ()
  "The current provider is written atomically and read again after a restart."
  (claude-code-ide-wiring-tests--with-provider-file
    (should-not (file-exists-p claude-code-ide-provider-file))
    (claude-code-ide-set-current-provider 'codex)
    (should (equal (with-temp-buffer
                     (insert-file-contents claude-code-ide-provider-file)
                     (buffer-string))
                   "codex\n"))
    (should-not (directory-files (file-name-directory claude-code-ide-provider-file)
                                 nil "\\.tmp\\'"))
    ;; A new Emacs reads the file
    (setq claude-code-ide--current-provider nil
          claude-code-ide--current-provider-read nil)
    (should (eq (claude-code-ide-current-provider) 'codex))
    ;; An unknown provider is refused and changes nothing
    (should-error (claude-code-ide-set-current-provider 'cci-test-unknown) :type 'user-error)
    (should (eq (claude-code-ide-current-provider) 'codex))))

(ert-deftest claude-code-ide-test-wiring-provider-file-broken ()
  "A missing, broken, or unknown provider file gives the default provider."
  (claude-code-ide-wiring-tests--with-provider-file
    (let ((claude-code-ide-default-provider 'codex))
      (should (eq (claude-code-ide-current-provider) 'codex)))
    (make-directory (file-name-directory claude-code-ide-provider-file) t)
    (dolist (text '("" "((garbage" "cci-test-never-registered\n" "\0\1\2" "codex extra words"))
      (with-temp-file claude-code-ide-provider-file (insert text))
      (setq claude-code-ide--current-provider nil
            claude-code-ide--current-provider-read nil)
      (should (eq (claude-code-ide-current-provider) 'claude)))
    ;; A folder in place of the file
    (delete-file claude-code-ide-provider-file)
    (make-directory claude-code-ide-provider-file)
    (setq claude-code-ide--current-provider nil
          claude-code-ide--current-provider-read nil)
    (should (eq (claude-code-ide-current-provider) 'claude))
    ;; The write fails with a message; the choice holds in this Emacs
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (should (eq (claude-code-ide-set-current-provider 'codex) 'codex)))
      (should (cl-some (lambda (text) (string-prefix-p "Cannot save the current provider" text))
                       messages))
      (should (eq (claude-code-ide-current-provider) 'codex)))))

(ert-deftest claude-code-ide-test-wiring-commands-use-current-provider ()
  "Start, Continue and Resume use the current provider; a spec never does."
  (claude-code-ide-wiring-tests--with-provider-file
    (claude-code-ide-wiring-tests--with-clean
      (claude-code-ide-set-current-provider 'codex)
      (let ((started nil))
        (cl-letf (((symbol-function 'claude-code-ide--start-session)
                   (lambda (&optional continue resume spec _interactive)
                     (push (list claude-code-ide-default-provider continue resume spec) started))))
          (let ((current-prefix-arg nil))
            (call-interactively #'claude-code-ide)
            (call-interactively #'claude-code-ide-continue)
            (call-interactively #'claude-code-ide-resume)))
        (should (equal (reverse started)
                       '((codex nil nil nil) (codex t nil nil) (codex nil t nil)))))
      ;; A restore names its provider in the spec; without one, the start
      ;; uses the default provider, never the current one
      (let* ((started (claude-code-ide-wiring-tests--start (claude-code-ide-wiring-tests--spec)))
             (instance (claude-code-ide-instance-of-session (plist-get started :session))))
        (should (eq (claude-code-ide-instance-provider instance) 'claude))))))

(ert-deftest claude-code-ide-test-wiring-prefix-asks-provider-then-name ()
  "With C-u, the command asks for the provider, then for the instance name."
  (claude-code-ide-wiring-tests--with-provider-file
    (claude-code-ide-wiring-tests--with-clean
      (let ((asked nil))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt collection &rest args)
                     (push (list 'provider prompt collection (nth 4 args)) asked)
                     "codex"))
                  ((symbol-function 'claude-code-ide--read-instance-name)
                   (lambda (&rest _) (push (list 'name) asked) "cci-test-name")))
          (let* ((current-prefix-arg '(4))
                 (started (cl-letf (((symbol-function 'claude-code-ide--get-working-directory)
                                     (lambda () "/tmp/cci-test-wiring/proj/")))
                            (claude-code-ide-wiring-tests--start
                             nil :call (lambda () (call-interactively #'claude-code-ide))))))
            (let ((order (reverse asked)))
              (should (equal (mapcar #'car order) '(provider name)))
              ;; The provider prompt offers every provider, with the current one first
              (should (equal (nth 2 (car order)) '("claude" "codex")))
              (should (equal (nth 3 (car order)) "claude")))
            (let ((instance (claude-code-ide-instance-of-session (plist-get started :session))))
              (should (eq (claude-code-ide-instance-provider instance) 'codex))
              (should (equal (claude-code-ide-mcp-session-instance-name (plist-get started :session))
                             "cci-test-name")))
            ;; The choice is now the current provider
            (should (eq (claude-code-ide-current-provider) 'codex))))))))

(ert-deftest claude-code-ide-test-wiring-menu-provider ()
  "The menu shows the current provider and toggles it with one key."
  (claude-code-ide-wiring-tests--with-provider-file
    (claude-code-ide-wiring-tests--with-clean
      (let* ((suffix (transient-get-suffix 'claude-code-ide-menu "P"))
             ;; (LEVEL CLASS PLIST) or (CLASS . PLIST), by transient version
             (plist (if (keywordp (nth 1 suffix)) (cdr suffix) (nth 2 suffix))))
        (should (eq (plist-get plist :command) #'claude-code-ide-toggle-provider))
        (should (plist-get plist :transient)))
      (cl-letf (((symbol-function 'claude-code-ide--get-working-directory)
                 (lambda () "/tmp/cci-test-wiring/proj/")))
        (should (string-match-p "Provider for new instances: Claude Code"
                                (claude-code-ide--session-status)))
        (should (equal (claude-code-ide--start-description) "Start new Claude Code instance"))
        (claude-code-ide-toggle-provider)
        (should (string-match-p "Provider for new instances: Codex"
                                (claude-code-ide--session-status)))
        (should (equal (claude-code-ide--start-description) "Start new Codex instance"))
        (should (equal (claude-code-ide--continue-description) "Continue in new Codex instance"))
        (should (equal (claude-code-ide--resume-description) "Resume in new Codex instance"))
        (should (equal (substring-no-properties (claude-code-ide--provider-description))
                       "Provider: Claude Code | Codex"))
        ;; With a session in the project, the header is still first
        (claude-code-ide-wiring-tests--start (claude-code-ide-wiring-tests--spec :provider 'codex))
        (let ((status (claude-code-ide--session-status)))
          (should (string-prefix-p "Provider for new instances: Codex\nproj" status))
          (should (string-match-p "port -" status)))))))

;;; Stopped buffers

(defun claude-code-ide-wiring-tests--stopped-start (&rest spec-args)
  "Start an instance with SPEC-ARGS, and return the plist of the start.
The plist also has :name, the name of the terminal buffer at the start."
  (let ((started (claude-code-ide-wiring-tests--start
                  (apply #'claude-code-ide-wiring-tests--spec spec-args))))
    (append started (list :name (buffer-name (plist-get started :buffer))))))

(defun claude-code-ide-wiring-tests--kept (name)
  "Return the read-only buffer that the stop of the terminal NAME left, or nil."
  (let ((buffer (get-buffer (concat name " [stopped]"))))
    (and buffer
         (with-current-buffer buffer
           (and (derived-mode-p 'claude-code-ide-stopped-mode)
                buffer-read-only
                (string-prefix-p "Stopped at " header-line-format)))
         buffer)))

(ert-deftest claude-code-ide-test-wiring-keep-stopped-buffers-default ()
  "By default, a stopped instance keeps its terminal buffer."
  (should (eq t (eval (car (get 'claude-code-ide-keep-stopped-buffers 'standard-value)) t))))

(ert-deftest claude-code-ide-test-wiring-cleanup-keeps-buffer ()
  "The cleanup leaves a read-only copy of the terminal, and kills the terminal as before."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (instance (claude-code-ide-instance-of-session session))
               (buffer (plist-get started :buffer))
               (name (plist-get started :name)))
          (with-current-buffer buffer
            (setq default-directory "/tmp/cci-test-wiring/proj/")
            (insert "cci-test last screen"))
          (setq claude-code-ide--last-accessed-buffer buffer)
          (claude-code-ide--cleanup-session session)
          ;; The stop is the one of before
          (should (equal (car calls)
                         (list 'stop instance (list :process (plist-get started :process) :scan nil))))
          (should-not (process-live-p (plist-get started :process)))
          (should-not (claude-code-ide-instance-of-session session))
          (should-not (buffer-live-p buffer))
          ;; The copy has the text, the folder, and the project, and no session
          (let ((kept (claude-code-ide-wiring-tests--kept name)))
            (should kept)
            (should-not (get-buffer name))
            (should-not (claude-code-ide--session-buffer-p kept))
            (should (equal (claude-code-ide--claude-buffer-project kept)
                           (claude-code-ide-mcp-session-project-dir session)))
            (should (eq kept (claude-code-ide--stopped-buffer-of session)))
            (should-not (eq claude-code-ide--last-accessed-buffer kept))
            (with-current-buffer kept
              (should (equal (buffer-string) "cci-test last screen"))
              (should (equal default-directory "/tmp/cci-test-wiring/proj/")))))))))

(ert-deftest claude-code-ide-test-wiring-keep-stopped-buffer-once ()
  "A second keep of a session returns the copy of the first one."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (buffer (plist-get started :buffer))
               (first (claude-code-ide--keep-stopped-buffer buffer session)))
          (should (bufferp first))
          (should (eq first (claude-code-ide--keep-stopped-buffer buffer session)))
          (should (eq first (claude-code-ide--stopped-buffer-of session)))
          (should-not (get-buffer (concat (plist-get started :name) " [stopped]<2>"))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-drops-actions ()
  "The copy keeps the faces of the text, and drops the properties that act."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (map (make-sparse-keymap)))
          (with-current-buffer (plist-get started :buffer)
            (insert (propertize "link" 'face 'bold 'keymap map 'mouse-face 'highlight
                                'help-echo "open" 'read-only t
                                'modification-hooks (list #'ignore)
                                'cursor-sensor-functions (list #'ignore)
                                'pointer 'hand)))
          (claude-code-ide--cleanup-session (plist-get started :session))
          (with-current-buffer (claude-code-ide-wiring-tests--kept (plist-get started :name))
            (should (eq 'bold (get-text-property 1 'face)))
            (should-not (get-text-property 1 'keymap))
            (should-not (get-text-property 1 'mouse-face))
            (should-not (get-text-property 1 'help-echo))
            (should-not (get-text-property 1 'read-only))
            (should-not (get-text-property 1 'modification-hooks))
            (should-not (get-text-property 1 'cursor-sensor-functions))
            (should-not (get-text-property 1 'pointer))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-error-goes-on ()
  "An error in the copy leaves no copy, and the stop goes on."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t)
          (claude-code-ide-stopped-mode-hook
           (list (lambda () (error "cci-test hook failed")))))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session)))
          (cl-letf (((symbol-function 'message) #'ignore))
            (claude-code-ide--cleanup-session session))
          (should-not (buffer-live-p (plist-get started :buffer)))
          (should-not (claude-code-ide-instance-of-session session))
          (should-not (claude-code-ide--stopped-buffer-of session))
          (should-not (get-buffer (concat (plist-get started :name) " [stopped]"))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-refused-kill ()
  "A refused kill of the terminal drops the copy, and the terminal shows again.
Only a stop without the process file kills the buffer at once."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (buffer (plist-get started :buffer)))
          (cl-letf (((symbol-function 'claude-code-ide-process-stop-later) nil))
            (save-window-excursion
              (let ((window (display-buffer-in-side-window buffer '((side . right))))
                    (kill-buffer-query-functions (list (lambda () nil))))
                (claude-code-ide--stop-session session)
                (should (buffer-live-p buffer))
                (should (eq (window-buffer window) buffer))
                (should-not (claude-code-ide--stopped-buffer-of session))
                (should-not (get-buffer (concat (plist-get started :name) " [stopped]")))
                (should-not (claude-code-ide-mcp-session-cleanup-done session))))))))))

(ert-deftest claude-code-ide-test-wiring-quit-keeps-no-buffer ()
  "The quit of Emacs leaves no copy, also from the sentinels of its wait."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t)
          (claude-code-ide-process-quit-timeout 1.5))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((a (claude-code-ide-wiring-tests--stopped-start))
               (b (claude-code-ide-wiring-tests--stopped-start :instance-name "b")))
          ;; The wait of the quit ends a CLI, and its sentinel cleans up
          (cl-letf (((symbol-function 'claude-code-ide-process-stop-many)
                     (lambda (&rest _)
                       (delete-process (plist-get a :process))
                       (accept-process-output nil 0.05))))
            (claude-code-ide--cleanup-all-sessions))
          (dolist (started (list a b))
            (should (claude-code-ide-mcp-session-cleanup-done (plist-get started :session)))
            (should-not (claude-code-ide--stopped-buffer-of (plist-get started :session)))
            (should-not (get-buffer (concat (plist-get started :name) " [stopped]")))))))))

(ert-deftest claude-code-ide-test-wiring-aborted-start-keeps-no-buffer ()
  "A start that fails after its terminal exists leaves no copy."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t)
          (name nil))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (should-error
         (claude-code-ide-wiring-tests--start
          (claude-code-ide-wiring-tests--spec)
          :call (lambda ()
                  (cl-letf (((symbol-function 'claude-code-ide--display-buffer-in-side-window)
                             (lambda (buffer)
                               (setq name (buffer-name buffer))
                               (error "cci-test display failed"))))
                    (claude-code-ide--start-session
                     nil nil (claude-code-ide-wiring-tests--spec))))))
        (should name)
        (should-not (get-buffer name))
        (should-not (get-buffer (concat name " [stopped]")))))))

(ert-deftest claude-code-ide-test-wiring-toggle-hides-stopped-windows ()
  "The toggle commands close the windows of stopped buffers too."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (dir (claude-code-ide-mcp-session-project-dir (plist-get started :session))))
          (claude-code-ide--cleanup-session (plist-get started :session))
          (let ((kept (claude-code-ide-wiring-tests--kept (plist-get started :name))))
            (save-window-excursion
              ;; The project has no instance now, only the stopped buffer
              (let ((window (display-buffer-in-side-window kept '((side . right)))))
                (cl-letf (((symbol-function 'claude-code-ide--get-working-directory)
                           (lambda () dir)))
                  (claude-code-ide-toggle))
                (should-not (window-live-p window)))
              (let ((window (display-buffer-in-side-window kept '((side . right)))))
                (cl-letf (((symbol-function 'message) #'ignore))
                  (claude-code-ide-toggle-recent))
                (should-not (window-live-p window))))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-has-no-terminal-keys ()
  "A kept buffer has the keys of its own mode, not those of the terminal."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (buffer (plist-get started :buffer)))
          (with-current-buffer buffer
            (local-set-key (kbd "C-<escape>") #'claude-code-ide-send-escape))
          (claude-code-ide--cleanup-session (plist-get started :session))
          (with-current-buffer (claude-code-ide-wiring-tests--kept (plist-get started :name))
            (should (eq (current-local-map) claude-code-ide-stopped-mode-map))
            (should-not (eq (key-binding (kbd "C-<escape>")) #'claude-code-ide-send-escape))))))))

(ert-deftest claude-code-ide-test-wiring-cleanup-kills-buffer-when-off ()
  "With `claude-code-ide-keep-stopped-buffers' nil, the cleanup leaves no copy."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers nil))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session)))
          (claude-code-ide--cleanup-session session)
          (should-not (buffer-live-p (plist-get started :buffer)))
          (should-not (claude-code-ide--stopped-buffer-of session))
          (should-not (get-buffer (concat (plist-get started :name) " [stopped]"))))))))

(ert-deftest claude-code-ide-test-wiring-cli-exit-keeps-buffer ()
  "A CLI that ends by itself leaves a copy, through the sentinel."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (instance (claude-code-ide-instance-of-session session)))
          (delete-process (plist-get started :process))
          (should (claude-code-ide-tests--wait-until
                   (lambda () (claude-code-ide-mcp-session-cleanup-done session))))
          (should (equal (car calls) (list 'untrack instance)))
          (should-not (buffer-live-p (plist-get started :buffer)))
          (should (claude-code-ide-wiring-tests--kept (plist-get started :name))))))))

(ert-deftest claude-code-ide-test-wiring-buffer-kill-still-kills ()
  "A kill of the terminal buffer of a running instance ends it, and leaves no copy."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (instance (claude-code-ide-instance-of-session session))
               (buffer (plist-get started :buffer)))
          (kill-buffer buffer)
          (should (claude-code-ide-mcp-session-cleanup-done session))
          (should-not (buffer-live-p buffer))
          (should-not (claude-code-ide--stopped-buffer-of session))
          (should (equal (car calls)
                         (list 'stop-later instance
                               (list :process (plist-get started :process) :scan nil)))))))))

(ert-deftest claude-code-ide-test-wiring-stop-session-keeps-buffer ()
  "The stop ends the CLI softly first; its exit leaves the copy, with all output."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let ((claude-code-ide-keep-stopped-buffers t))
          (let* ((started (claude-code-ide-wiring-tests--stopped-start))
                 (session (plist-get started :session))
                 (instance (claude-code-ide-instance-of-session session))
                 (buffer (plist-get started :buffer))
                 (process (plist-get started :process)))
            (should (claude-code-ide--claude-stop instance))
            ;; The soft end of the provider, from timers; the buffer stays
            ;; a terminal of its session until the CLI exits
            (let ((call (car calls)))
              (should (eq 'stop-later (nth 0 call)))
              (should (eq instance (nth 1 call)))
              (should (eq process (plist-get (nth 2 call) :process)))
              (should (plist-member (nth 2 call) :soft-end))
              (should-not (plist-get (nth 2 call) :soft-end))
              (should (functionp (plist-get (nth 2 call) :callback))))
            (should (eq session (claude-code-ide--buffer-session buffer)))
            (should (claude-code-ide-instance-of-session session))
            (should-not (claude-code-ide--stopped-buffer-of session))
            ;; A second stop while the first one runs starts no other stop
            (claude-code-ide--stop-session session)
            (should (= 1 (cl-count 'stop-later (mapcar #'car calls))))
            ;; The output after the soft end is in the copy
            (with-current-buffer buffer (insert "cci-test last words"))
            (delete-process process)
            (should (claude-code-ide-tests--wait-until
                     (lambda () (claude-code-ide-mcp-session-cleanup-done session))))
            (should-not (buffer-live-p buffer))
            (should-not (claude-code-ide-instance-of-session session))
            (with-current-buffer (claude-code-ide-wiring-tests--kept (plist-get started :name))
              (should (string-match-p "cci-test last words" (buffer-string))))))
        (let ((claude-code-ide-keep-stopped-buffers nil))
          (let* ((started (claude-code-ide-wiring-tests--stopped-start :instance-name "off"))
                 (session (plist-get started :session)))
            (claude-code-ide--stop-session session)
            (should-not (buffer-live-p (plist-get started :buffer)))
            (should-not (claude-code-ide--stopped-buffer-of session))))))))

(ert-deftest claude-code-ide-test-wiring-stop-all-keeps-buffers ()
  "`claude-code-ide-stop-all' leaves a copy of each buffer, as each other stop does."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((a (claude-code-ide-wiring-tests--stopped-start))
               (b (claude-code-ide-wiring-tests--stopped-start :instance-name "b")))
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                    ((symbol-function 'claude-code-ide-log) #'ignore))
            (claude-code-ide-stop-all t))
          (should (equal '(stop-later stop-later) (mapcar #'car calls)))
          (dolist (started (list a b))
            (delete-process (plist-get started :process)))
          (dolist (started (list a b))
            (should (claude-code-ide-tests--wait-until
                     (lambda () (claude-code-ide-mcp-session-cleanup-done (plist-get started :session)))))
            (should (claude-code-ide--stopped-buffer-of (plist-get started :session)))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-names ()
  "Two stopped buffers of one name get two names; the old name is free."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((first (claude-code-ide-wiring-tests--stopped-start))
               (name (plist-get first :name)))
          (claude-code-ide--cleanup-session (plist-get first :session))
          ;; A second buffer of the same name, as a new start makes it
          (let ((second (claude-code-ide-wiring-tests--stopped-start :instance-name "two")))
            (with-current-buffer (plist-get second :buffer) (rename-buffer name))
            (claude-code-ide--cleanup-session (plist-get second :session))
            (let ((one (claude-code-ide--stopped-buffer-of (plist-get first :session)))
                  (two (claude-code-ide--stopped-buffer-of (plist-get second :session))))
              (should (buffer-live-p one))
              (should (buffer-live-p two))
              (should-not (equal (buffer-name one) (buffer-name two))))
            (should-not (get-buffer name))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-takes-windows ()
  "The copy takes the windows of the terminal, and keeps their dedicated flag."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (buffer (plist-get started :buffer)))
          (save-window-excursion
            (let ((window (display-buffer-in-side-window buffer '((side . right)))))
              (set-window-dedicated-p window t)
              (claude-code-ide--cleanup-session (plist-get started :session))
              (should (window-live-p window))
              (should (eq (window-buffer window)
                          (claude-code-ide-wiring-tests--kept (plist-get started :name))))
              (should (eq t (window-dedicated-p window))))))))))

(ert-deftest claude-code-ide-test-wiring-failed-start-names-kept-buffer ()
  "A CLI that ends at once after its start leaves its output in a named buffer."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t)
          (dead (start-process "cci-test-dead" nil "true")))
      (push dead claude-code-ide-wiring-tests--objects)
      (should (claude-code-ide-tests--wait-until (lambda () (not (process-live-p dead)))))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let ((err (should-error (claude-code-ide-wiring-tests--start
                                  (claude-code-ide-wiring-tests--spec) :process dead))))
          (should (string-match "Its output is in the buffer \\(.*\\)\\'"
                                (error-message-string err)))
          (let ((buffer (get-buffer (match-string 1 (error-message-string err)))))
            (should (buffer-live-p buffer))
            (should (eq (buffer-local-value 'major-mode buffer) 'claude-code-ide-stopped-mode))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-side-windows ()
  "The project scope and a new tab treat a kept buffer as a buffer of its project."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (dir (claude-code-ide-mcp-session-project-dir (plist-get started :session))))
          (claude-code-ide--cleanup-session (plist-get started :session))
          (let ((kept (claude-code-ide-wiring-tests--kept (plist-get started :name))))
            (save-window-excursion
              ;; Another project: its scope removes the side window
              (let ((window (display-buffer-in-side-window kept '((side . right)))))
                (should (window-live-p window))
                (claude-code-ide--hide-foreign-side-windows "/tmp/cci-test-wiring/other/")
                (should-not (window-live-p window)))
              ;; Its own project: the window stays
              (let ((window (display-buffer-in-side-window kept '((side . right)))))
                (claude-code-ide--hide-foreign-side-windows dir)
                (should (window-live-p window))
                ;; A new tab removes it, as a window of a running instance
                (claude-code-ide--strip-new-tab-claude-windows)
                (should-not (window-live-p window))))))))))

(ert-deftest claude-code-ide-test-wiring-kill-stopped-buffers ()
  "`claude-code-ide-kill-stopped-buffers' kills the stopped buffers of a project."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((here (claude-code-ide-wiring-tests--stopped-start))
               (running (claude-code-ide-wiring-tests--stopped-start :instance-name "run"))
               (other (claude-code-ide-wiring-tests--start
                       (claude-code-ide-start-spec-create :directory "/tmp/cci-test-wiring/other/")))
               (dir (claude-code-ide-mcp-session-project-dir (plist-get here :session))))
          (claude-code-ide--cleanup-session (plist-get here :session))
          (claude-code-ide--cleanup-session (plist-get other :session))
          (let ((here-kept (claude-code-ide--stopped-buffer-of (plist-get here :session)))
                (other-kept (claude-code-ide--stopped-buffer-of (plist-get other :session))))
            ;; Only the stopped buffers of the project go; a running one stays
            (should (= 1 (claude-code-ide-kill-stopped-buffers dir)))
            (should-not (buffer-live-p here-kept))
            (should (buffer-live-p (plist-get running :buffer)))
            (should (buffer-live-p other-kept))
            ;; All projects, among the buffers of this test only, so that
            ;; a run in a working Emacs kills none of its stopped buffers
            (cl-letf (((symbol-function 'buffer-list)
                       (let ((mine (list other-kept (plist-get running :buffer))))
                         (lambda (&rest _) mine))))
              (should (= 1 (claude-code-ide-kill-stopped-buffers nil t))))
            (should-not (buffer-live-p other-kept))
            (should (buffer-live-p (plist-get running :buffer)))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-flushes-output ()
  "The copy has the output that the backends and the render queue had not drawn."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (drawn nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (buffer (plist-get started :buffer))
               (draw (lambda (text)
                       (lambda (&rest _)
                         (push text drawn)
                         (with-current-buffer buffer
                           (let ((inhibit-read-only t))
                             (goto-char (point-max))
                             (insert text)))))))
          (with-current-buffer buffer
            ;; Each backend has output that waits for a timer
            (set (make-local-variable 'claude-code-ide--vterm-render-flush)
                 (funcall draw "queue;"))
            (set (make-local-variable 'vterm--redraw-timer) (run-at-time 3600 nil #'ignore))
            (set (make-local-variable 'eat--pending-output-chunks) (list "chunk"))
            (set (make-local-variable 'ghostel--redraw-timer) (run-at-time 3600 nil #'ignore)))
          (cl-letf (((symbol-function 'vterm--delayed-redraw) (funcall draw "vterm;"))
                    ((symbol-function 'eat--process-output-queue) (funcall draw "eat;"))
                    ((symbol-function 'ghostel--redraw-now) (funcall draw "ghostel;")))
            (claude-code-ide--cleanup-session (plist-get started :session)))
          (should (equal (reverse drawn) '("queue;" "vterm;" "eat;" "ghostel;")))
          (with-current-buffer (claude-code-ide-wiring-tests--kept (plist-get started :name))
            (should (equal (buffer-string) "queue;vterm;eat;ghostel;"))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-flush-error-goes-on ()
  "An error of a backend in the flush still leaves a copy."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let ((started (claude-code-ide-wiring-tests--stopped-start)))
          (with-current-buffer (plist-get started :buffer)
            (set (make-local-variable 'vterm--redraw-timer) (run-at-time 3600 nil #'ignore)))
          (cl-letf (((symbol-function 'vterm--delayed-redraw)
                     (lambda (&rest _) (error "cci-test redraw failed"))))
            (claude-code-ide--cleanup-session (plist-get started :session)))
          (should (claude-code-ide-wiring-tests--kept (plist-get started :name))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-revert ()
  "A revert of a kept buffer gives a message, not an error."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (said nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let ((started (claude-code-ide-wiring-tests--stopped-start)))
          (claude-code-ide--cleanup-session (plist-get started :session))
          (with-current-buffer (claude-code-ide-wiring-tests--kept (plist-get started :name))
            (should (eq (key-binding (kbd "g")) #'revert-buffer))
            (cl-letf (((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (setq said (apply #'format format-string args)))))
              (revert-buffer))
            (should (string-match-p "stopped instance" said))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-other-mode ()
  "A kept buffer in another major mode stays a buffer of its project."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (dir (claude-code-ide-mcp-session-project-dir (plist-get started :session))))
          (claude-code-ide--cleanup-session (plist-get started :session))
          (let ((kept (claude-code-ide-wiring-tests--kept (plist-get started :name))))
            (with-current-buffer kept
              (text-mode)
              (should (equal claude-code-ide--stopped-project dir)))
            (should (= 1 (claude-code-ide-kill-stopped-buffers dir)))
            (should-not (buffer-live-p kept))))))))

(ert-deftest claude-code-ide-test-wiring-kill-stopped-buffers-message ()
  "The kill command reports its count when it is called interactively."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (said nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (dir (claude-code-ide-mcp-session-project-dir (plist-get started :session))))
          (claude-code-ide--cleanup-session (plist-get started :session))
          (cl-letf (((symbol-function 'claude-code-ide--get-working-directory) (lambda () dir))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (setq said (apply #'format format-string args)))))
            (call-interactively #'claude-code-ide-kill-stopped-buffers))
          (should (equal said "Killed 1 stopped buffer"))
          (should-not (claude-code-ide--stopped-buffer-of (plist-get started :session))))))))

(ert-deftest claude-code-ide-test-wiring-toggle-without-instances ()
  "The toggle refuses without an instance, and the pick without one too."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (dir (claude-code-ide-mcp-session-project-dir (plist-get started :session))))
          (claude-code-ide--cleanup-session (plist-get started :session))
          (cl-letf (((symbol-function 'claude-code-ide--get-working-directory) (lambda () dir)))
            (save-window-excursion
              ;; No instance and no visible stopped buffer
              (delete-other-windows)
              (switch-to-buffer (get-buffer-create "*scratch*"))
              (should-error (claude-code-ide-toggle) :type 'user-error)
              ;; A visible stopped buffer: the pick still needs an instance
              (display-buffer-in-side-window
               (claude-code-ide-wiring-tests--kept (plist-get started :name)) '((side . right)))
              (should-error (claude-code-ide-toggle t) :type 'user-error))))))))

(ert-deftest claude-code-ide-test-wiring-eat-exit-setting-off ()
  "An eat terminal gets no kill at its exit from eat; the cleanup decides."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (started nil))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (setq started
              (claude-code-ide-wiring-tests--start
               (claude-code-ide-wiring-tests--spec)
               :call (lambda ()
                       (let ((claude-code-ide-terminal-backend 'eat))
                         (claude-code-ide--start-session
                          nil nil (claude-code-ide-wiring-tests--spec))))))
        (with-current-buffer (plist-get started :buffer)
          (should (local-variable-p 'eat-kill-buffer-on-exit))
          (should-not eat-kill-buffer-on-exit))))))

(ert-deftest claude-code-ide-test-wiring-stop-message-first ()
  "`claude-code-ide-stop' reports the stop before it stops."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (order nil)
          (kill-buffer-query-functions nil))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let ((started (claude-code-ide-wiring-tests--stopped-start)))
          (cl-letf (((symbol-function 'claude-code-ide--resolve-session)
                     (lambda (&rest _) (plist-get started :session)))
                    ((symbol-function 'claude-code-ide-log)
                     (lambda (&rest _) (push 'log order)))
                    ((symbol-function 'claude-code-ide--stop-session)
                     (lambda (_session) (push 'stop order))))
            (claude-code-ide-stop))
          (should (equal (reverse order) '(log stop))))))))

(ert-deftest claude-code-ide-test-wiring-failed-start-without-keep ()
  "With the option nil, a CLI that ends at once leaves no copy, and the message names none."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers nil)
          (dead (start-process "cci-test-dead" nil "true")))
      (push dead claude-code-ide-wiring-tests--objects)
      (should (claude-code-ide-tests--wait-until (lambda () (not (process-live-p dead)))))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let ((err (should-error (claude-code-ide-wiring-tests--start
                                  (claude-code-ide-wiring-tests--spec) :process dead))))
          (should (string-match-p "exited immediately" (error-message-string err)))
          (should-not (string-match-p "Its output" (error-message-string err)))
          (should-not (cl-find-if (lambda (b)
                                    (string-suffix-p " [stopped]" (buffer-name b)))
                                  claude-code-ide-tests--stopped-copies)))))))

(ert-deftest claude-code-ide-test-wiring-claude-buffer-project ()
  "The project of a terminal buffer comes from its session, of a kept buffer from its marker."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (dir (claude-code-ide-mcp-session-project-dir session)))
          (should (equal (claude-code-ide--claude-buffer-project (plist-get started :buffer)) dir))
          (with-temp-buffer
            (should-not (claude-code-ide--claude-buffer-project (current-buffer))))
          (claude-code-ide--cleanup-session session)
          (should-not (claude-code-ide--claude-buffer-project (plist-get started :buffer)))
          (should (equal (claude-code-ide--claude-buffer-project
                          (claude-code-ide--stopped-buffer-of session))
                         dir))
          ;; A drop without a copy does nothing
          (setf (claude-code-ide-mcp-session-stopped-buffer session) nil)
          (should-not (claude-code-ide--drop-stopped-buffer (plist-get started :buffer) session)))))))

(ert-deftest claude-code-ide-test-wiring-soft-stop-end-without-exit ()
  "When the stop ends and the CLI still runs, the stop kills the terminal, with a copy."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session)))
          (claude-code-ide--stop-session session)
          (funcall (plist-get (nth 2 (car calls)) :callback) '(:status timeout))
          (should (claude-code-ide-mcp-session-cleanup-done session))
          (should-not (buffer-live-p (plist-get started :buffer)))
          (should (claude-code-ide-wiring-tests--kept (plist-get started :name))))))))

(ert-deftest claude-code-ide-test-wiring-stop-without-process-file-kills ()
  "Without the process file, the stop makes the copy, and kills the terminal at once."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session)))
          (cl-letf (((symbol-function 'claude-code-ide-process-stop-later) nil)
                    ((symbol-function 'claude-code-ide-process-stop) nil))
            (claude-code-ide--stop-session session))
          (should (claude-code-ide-mcp-session-cleanup-done session))
          (should-not (buffer-live-p (plist-get started :buffer)))
          (should (claude-code-ide-wiring-tests--kept (plist-get started :name))))))))

(ert-deftest claude-code-ide-test-wiring-vterm-queue-after-exit ()
  "The queued vterm output reaches the terminal also after the exit of its process."
  (let ((buffer (generate-new-buffer "*cci-test-queue*"))
        (process nil)
        (drawn nil)
        (claude-code-ide-vterm-anti-flicker t)
        (claude-code-ide-vterm-render-delay 3600))
    (unwind-protect
        (progn
          (setq process (start-process "cci-test-queue" buffer "sleep" "30"))
          (set-process-query-on-exit-flag process nil)
          (with-current-buffer buffer
            (setq-local claude-code-ide--session 'cci-test-session))
          ;; A full redraw goes to the queue
          (claude-code-ide--vterm-smart-renderer
           (lambda (proc data) (push (list proc data) drawn))
           process "\033[2A\033[Kone\033[2A\033[Ktwo")
          (should-not drawn)
          ;; The process exits: Emacs removes it before its sentinel runs
          (delete-process process)
          (should-not (get-buffer-process buffer))
          (claude-code-ide--flush-terminal-output buffer)
          (should (equal drawn (list (list process "\033[2A\033[Kone\033[2A\033[Ktwo"))))
          (with-current-buffer buffer
            (should-not claude-code-ide--vterm-render-queue)
            (should-not claude-code-ide--vterm-render-timer)))
      (when (process-live-p process) (delete-process process))
      (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-old-session-layout ()
  "A session of the layout before the copy slot gets no copy, and its stop goes on."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (size (length (cl-struct-slot-info 'claude-code-ide-mcp-session)))
               (old (apply #'record (aref session 0)
                           (cl-loop for i from 1 below (1- size) collect (aref session i)))))
          ;; As after a reload: the running session has the old layout
          (should-error (claude-code-ide-mcp-session-stopped-buffer old))
          (cl-letf (((symbol-function 'message) #'ignore))
            (should-not (claude-code-ide--keep-stopped-buffer (plist-get started :buffer) old))
            (should-not (claude-code-ide--stopped-buffer-of old))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-keeps-its-slot ()
  "A visible copy keeps its side-window slot; a new instance takes the next one."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (dir (claude-code-ide-mcp-session-project-dir session)))
          (setf (claude-code-ide-mcp-session-window-slot session) 0)
          (save-window-excursion
            (display-buffer-in-side-window (plist-get started :buffer) '((side . right) (slot . 0)))
            (claude-code-ide--cleanup-session session)
            (should (get-buffer-window (claude-code-ide--stopped-buffer-of session)))
            (let ((claude-code-ide-side-window-scope 'project))
              (should (= 1 (claude-code-ide--assign-window-slot dir))))
            (let ((claude-code-ide-side-window-scope 'all))
              (should (= 1 (claude-code-ide--assign-window-slot dir))))
            ;; A copy that no window shows frees its slot
            (delete-window (get-buffer-window (claude-code-ide--stopped-buffer-of session)))
            (let ((claude-code-ide-side-window-scope 'project))
              (should (= 0 (claude-code-ide--assign-window-slot dir))))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-keeps-tab-hook ()
  "After the last stop, a copy keeps the hook that cleans up new tabs."
  (skip-unless (boundp 'tab-bar-tab-post-open-functions))
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (tab-bar-tab-post-open-functions nil))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let ((claude-code-ide-keep-stopped-buffers t)
              (started (claude-code-ide-wiring-tests--stopped-start)))
          (add-hook 'tab-bar-tab-post-open-functions #'claude-code-ide--strip-new-tab-claude-windows)
          (claude-code-ide--cleanup-session (plist-get started :session))
          (should (memq #'claude-code-ide--strip-new-tab-claude-windows
                        tab-bar-tab-post-open-functions)))
        ;; Without a copy, the last stop removes it, as before.  The
        ;; buffers of this stop only, so that the copy above, and those
        ;; of a working Emacs, stay
        (let ((claude-code-ide-keep-stopped-buffers nil)
              (started (claude-code-ide-wiring-tests--stopped-start :instance-name "two")))
          (add-hook 'tab-bar-tab-post-open-functions #'claude-code-ide--strip-new-tab-claude-windows)
          (cl-letf (((symbol-function 'buffer-list)
                     (let ((mine (list (plist-get started :buffer))))
                       (lambda (&rest _) mine))))
            (claude-code-ide--cleanup-session (plist-get started :session)))
          (should-not (memq #'claude-code-ide--strip-new-tab-claude-windows
                            tab-bar-tab-post-open-functions)))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-flush-error-logged ()
  "A failed flush step goes to the debug log."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t)
          (claude-code-ide-debug t)
          (claude-code-ide-debug-buffer " *cci-test-flush-debug*"))
      (unwind-protect
          (claude-code-ide-wiring-tests--with-process-stubs calls
            (let ((started (claude-code-ide-wiring-tests--stopped-start)))
              (with-current-buffer (plist-get started :buffer)
                (set (make-local-variable 'vterm--redraw-timer) (run-at-time 3600 nil #'ignore)))
              (cl-letf (((symbol-function 'vterm--delayed-redraw)
                         (lambda (&rest _) (error "cci-test redraw failed")))
                        ((symbol-function 'claude-code-ide-debug)
                         ;; The test loader replaces the macro with a function
                         ;; that drops the text; compiled code has the macro
                         (if (macrop 'claude-code-ide-debug)
                             (symbol-function 'claude-code-ide-debug)
                           (lambda (format-string &rest args)
                             (with-current-buffer (get-buffer-create claude-code-ide-debug-buffer)
                               (goto-char (point-max))
                               (insert (apply #'format format-string args) "\n"))))))
                (claude-code-ide--cleanup-session (plist-get started :session)))
              (should (string-match-p "cci-test redraw failed"
                                      (with-current-buffer (get-buffer-create claude-code-ide-debug-buffer)
                                        (buffer-string))))
              (should (claude-code-ide-wiring-tests--kept (plist-get started :name)))))
        (when (get-buffer claude-code-ide-debug-buffer)
          (kill-buffer claude-code-ide-debug-buffer))))))

(ert-deftest claude-code-ide-test-wiring-soft-stop-has-a-limit ()
  "A soft stop whose CLI does not exit in time kills the terminal, with a copy."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (timers nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session)))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (time _repeat function &rest args)
                       (push (list time function args) timers))))
            (claude-code-ide--stop-session session))
          ;; The stop job never ends here; the limit is one timer
          (should (eq 'stop-later (car (car calls))))
          (should (= 1 (length timers)))
          (should (<= (nth 0 (car timers)) 10))
          (should-not (claude-code-ide-mcp-session-cleanup-done session))
          (apply (nth 1 (car timers)) (nth 2 (car timers)))
          (should (claude-code-ide-mcp-session-cleanup-done session))
          (should-not (buffer-live-p (plist-get started :buffer)))
          (should (claude-code-ide-wiring-tests--kept (plist-get started :name))))))))

(ert-deftest claude-code-ide-test-wiring-soft-stop-undone-by-refused-kill ()
  "A refused kill at the end of a soft stop undoes the stop: a later stop works.
A second stop while the first one runs logs that the instance is already stopping."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (timers nil)
          (logs nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (buffer (plist-get started :buffer))
               (process (plist-get started :process)))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (time _repeat function &rest args)
                       (push (list time function args) timers)
                       'cci-test-timer))
                    ((symbol-function 'claude-code-ide-log)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) logs))))
            (claude-code-ide--stop-session session)
            (claude-code-ide--stop-session session)
            (should (= 1 (cl-count 'stop-later (mapcar #'car calls))))
            (should (cl-some (lambda (text) (string-match-p "already stopping" text)) logs))
            ;; The limit comes; the kill of the terminal is refused
            (let ((kill-buffer-query-functions (list (lambda () nil))))
              (apply (nth 1 (car timers)) (nth 2 (car timers))))
            (should (buffer-live-p buffer))
            (should-not (claude-code-ide-mcp-session-cleanup-done session))
            (should-not (process-get process 'claude-code-ide--stopping))
            ;; The end of the stop job does not ask again
            (let ((kill-buffer-query-functions
                   (list (lambda () (error "cci-test asked again")))))
              (funcall (plist-get (nth 2 (car calls)) :callback) '(:status timeout)))
            ;; A new stop starts a new soft stop
            (claude-code-ide--stop-session session)
            (should (= 2 (cl-count 'stop-later (mapcar #'car calls))))))))))

(ert-deftest claude-code-ide-test-wiring-soft-stop-job-error ()
  "An error of the stop job falls back to the kill of the terminal, with a copy."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session)))
          (cl-letf (((symbol-function 'claude-code-ide-process-stop-later)
                     (lambda (&rest _) (error "cci-test stop job failed")))
                    ((symbol-function 'message) #'ignore))
            (claude-code-ide--stop-session session))
          (should (claude-code-ide-mcp-session-cleanup-done session))
          (should-not (buffer-live-p (plist-get started :buffer)))
          (should (claude-code-ide-wiring-tests--kept (plist-get started :name))))))))

(ert-deftest claude-code-ide-test-wiring-soft-stop-reports-killed ()
  "A CLI that exits during a soft stop ends as `killed', without its exit message."
  (claude-code-ide-wiring-tests--with-clean
    (let* ((calls nil)
           (reasons nil)
           (exit-messages nil)
           (kill-buffer-query-functions nil)
           (claude-code-ide-keep-stopped-buffers t)
           (claude-code-ide-session-end-functions
            (list (lambda (_session reason) (push reason reasons))))
           (process-connection-type nil)
           (process (start-process "cci-test-exit-3" nil "sh" "-c" "read x; exit 3"))
           (provider-call (symbol-function 'claude-code-ide-provider-call)))
      (set-process-query-on-exit-flag process nil)
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (cl-letf (((symbol-function 'claude-code-ide-provider-call)
                   (lambda (provider operation &rest args)
                     (if (eq operation 'exit-message)
                         (progn (push (car args) exit-messages) "cci-test exit message")
                       (apply provider-call provider operation args)))))
          (let* ((started (claude-code-ide-wiring-tests--start
                           (claude-code-ide-wiring-tests--spec) :process process))
                 (session (plist-get started :session)))
            (claude-code-ide--stop-session session)
            ;; The CLI exits with an error after its soft end
            (process-send-eof process)
            (should (claude-code-ide-tests--wait-until
                     (lambda () (claude-code-ide-mcp-session-cleanup-done session))))
            (should (equal reasons '(killed)))
            (should-not exit-messages)))))))

(ert-deftest claude-code-ide-test-wiring-soft-stop-holds-inbox ()
  "A soft stop holds the inbox delivery until the CLI exits, or the stop is undone.
A hold of another owner, such as a handover, stays."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (timers nil)
          (claude-code-ide-control--held nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        ;; The CLI exits: the hold ends
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (id (claude-code-ide-instance-id (claude-code-ide-instance-of-session session)))
               (kill-buffer-query-functions nil))
          (claude-code-ide--stop-session session)
          (should (claude-code-ide-control-held-p id))
          (delete-process (plist-get started :process))
          (should (claude-code-ide-tests--wait-until
                   (lambda () (claude-code-ide-mcp-session-cleanup-done session))))
          (should-not (claude-code-ide-control-held-p id)))
        ;; A refused kill undoes the stop: the hold ends
        (let* ((started (claude-code-ide-wiring-tests--stopped-start :instance-name "refused"))
               (session (plist-get started :session))
               (id (claude-code-ide-instance-id (claude-code-ide-instance-of-session session))))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (time _repeat function &rest args)
                       (push (list time function args) timers)
                       'cci-test-timer)))
            (claude-code-ide--stop-session session)
            (should (claude-code-ide-control-held-p id))
            (let ((kill-buffer-query-functions (list (lambda () nil))))
              (apply (nth 1 (car timers)) (nth 2 (car timers))))
            (should-not (claude-code-ide-mcp-session-cleanup-done session))
            (should-not (claude-code-ide-control-held-p id))))
        ;; The hold of a handover stays after the stop
        (let* ((started (claude-code-ide-wiring-tests--stopped-start :instance-name "handover"))
               (session (plist-get started :session))
               (id (claude-code-ide-instance-id (claude-code-ide-instance-of-session session)))
               (kill-buffer-query-functions nil))
          (claude-code-ide-control-hold id)
          (claude-code-ide--stop-session session)
          (delete-process (plist-get started :process))
          (should (claude-code-ide-tests--wait-until
                   (lambda () (claude-code-ide-mcp-session-cleanup-done session))))
          (should (claude-code-ide-control-held-p id)))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-tab-hook-every-path ()
  "A copy keeps the hook that cleans up new tabs, also when the copy comes first.
That is the kill of the terminal, and a CLI that exits within the start delay."
  (skip-unless (boundp 'tab-bar-tab-post-open-functions))
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t)
          (tab-bar-tab-post-open-functions nil))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        ;; The stop without the process file kills the terminal after a copy
        (let ((started (claude-code-ide-wiring-tests--stopped-start)))
          (add-hook 'tab-bar-tab-post-open-functions #'claude-code-ide--strip-new-tab-claude-windows)
          (cl-letf (((symbol-function 'claude-code-ide-process-stop-later) nil))
            (claude-code-ide--stop-session (plist-get started :session)))
          (should (claude-code-ide-wiring-tests--kept (plist-get started :name)))
          (should (memq #'claude-code-ide--strip-new-tab-claude-windows
                        tab-bar-tab-post-open-functions)))
        ;; A CLI that exits within the start delay
        (claude-code-ide-tests--clear-processes)
        (setq tab-bar-tab-post-open-functions nil)
        (let ((dead (start-process "cci-test-dead" nil "true")))
          (push dead claude-code-ide-wiring-tests--objects)
          (should (claude-code-ide-tests--wait-until (lambda () (not (process-live-p dead)))))
          (add-hook 'tab-bar-tab-post-open-functions #'claude-code-ide--strip-new-tab-claude-windows)
          (should-error (claude-code-ide-wiring-tests--start
                         (claude-code-ide-wiring-tests--spec) :process dead))
          (should (memq #'claude-code-ide--strip-new-tab-claude-windows
                        tab-bar-tab-post-open-functions)))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-ghostel-hidden ()
  "The header of a copy of a ghostel terminal with output not drawn says so."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (dolist (case '((t . t) (nil . nil)))
          (let* ((started (claude-code-ide-wiring-tests--stopped-start
                           :instance-name (if (car case) "hidden" "drawn")))
                 (session (plist-get started :session)))
            (with-current-buffer (plist-get started :buffer)
              (setq major-mode 'ghostel-mode)
              (set (make-local-variable 'ghostel--pending-redraw) (car case)))
            (claude-code-ide--cleanup-session session)
            (with-current-buffer (claude-code-ide--stopped-buffer-of session)
              (should (string-prefix-p "Stopped at " header-line-format))
              (should (eq (cdr case)
                          (and (string-match-p "incomplete" header-line-format) t))))))))))

(ert-deftest claude-code-ide-test-wiring-stopped-buffer-slot-to-its-heir ()
  "A new instance that replaces the copy of an instance takes its slot and window.
The target of a handover binds `claude-code-ide--replace-copy-of' to its source."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil)
          (claude-code-ide-keep-stopped-buffers t))
      (claude-code-ide-wiring-tests--with-process-stubs calls
        (let* ((started (claude-code-ide-wiring-tests--stopped-start))
               (session (plist-get started :session))
               (id (claude-code-ide-instance-id (claude-code-ide-instance-of-session session)))
               (dir (claude-code-ide-mcp-session-project-dir session))
               (heir (generate-new-buffer "*cci-test-heir*")))
          (push heir claude-code-ide-wiring-tests--objects)
          (setf (claude-code-ide-mcp-session-window-slot session) 2)
          (save-window-excursion
            (display-buffer-in-side-window (plist-get started :buffer) '((side . right) (slot . 2)))
            (claude-code-ide--cleanup-session session)
            (let ((window (get-buffer-window (claude-code-ide--stopped-buffer-of session))))
              (should window)
              (dolist (scope '(project all))
                (let ((claude-code-ide-side-window-scope scope))
                  ;; Another instance keeps off the slot of the copy
                  (should (= 0 (claude-code-ide--assign-window-slot dir)))
                  (let ((claude-code-ide--replace-copy-of "cci-test-other"))
                    (should (= 0 (claude-code-ide--assign-window-slot dir))))
                  ;; The heir takes it, but not in another project
                  (let ((claude-code-ide--replace-copy-of id))
                    (should (= 2 (claude-code-ide--assign-window-slot dir)))
                    (should-not (= 2 (claude-code-ide--assign-window-slot
                                      "/tmp/cci-test-wiring/other/"))))))
              ;; The side window of that slot then shows the heir
              (display-buffer-in-side-window heir '((side . right) (slot . 2)))
              (should (eq heir (window-buffer window))))))))))

(ert-deftest claude-code-ide-test-tests-advice-only-in-run ()
  "The test run records the copies only while it runs."
  (let ((function #'claude-code-ide-tests--record-stopped-copy))
    (should (advice-member-p function 'claude-code-ide--keep-stopped-buffer))
    (unwind-protect
        (let ((inside nil))
          (advice-remove 'claude-code-ide--keep-stopped-buffer function)
          (claude-code-ide-tests--isolate-run
           (lambda () (setq inside (advice-member-p function 'claude-code-ide--keep-stopped-buffer))))
          (should inside)
          (should-not (advice-member-p function 'claude-code-ide--keep-stopped-buffer)))
      (advice-add 'claude-code-ide--keep-stopped-buffer :filter-return function))))

(provide 'claude-code-ide-wiring-tests)

;;; claude-code-ide-wiring-tests.el ends here
