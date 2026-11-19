;;; claude-code-ide-wiring-tests.el --- Tests for the core wiring of the providers  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the wiring in claude-code-ide.el that the providers need:
;; no IDE server for a CLI without the IDE protocol, provider texts,
;; flags and model of each provider, forks, secrets in the debug log,
;; the MCP config file of Claude Code, the process tree calls, the
;; prepare hook, and the provider choice of the commands and the menu.
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

;; Options of files that may not be loaded; the tests bind them
(defvar claude-code-ide-process-quit-timeout)
(defvar claude-code-ide-debug-buffer)

;;; Temporary folders for the whole test run

(defvar claude-code-ide-wiring-tests--root (make-temp-file "cci-test-wiring-" t)
  "Temporary folder of this test run.")

(setq claude-code-ide-mcp-config-directory
      (expand-file-name "mcp-config" claude-code-ide-wiring-tests--root)
      claude-code-ide-provider-file
      (expand-file-name "current-provider" claude-code-ide-wiring-tests--root))

(add-hook 'kill-emacs-hook
          (lambda ()
            (ignore-errors (delete-directory claude-code-ide-wiring-tests--root t))))

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
  "The cleanup stops a live CLI, stops it later in the kill hook, forgets a dead one."
  (claude-code-ide-wiring-tests--with-clean
    (let ((calls nil)
          (kill-buffer-query-functions nil))
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
    (let ((calls nil))
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
  "At Emacs quit, one stop of all CLIs with the quit budget comes before any cleanup."
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
            ;; Then each cleanup
            (should (= 2 (cl-count 'stop (mapcar #'car (cdr order)))))))))
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
                   (lambda (&optional continue resume spec)
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

(provide 'claude-code-ide-wiring-tests)

;;; claude-code-ide-wiring-tests.el ends here
