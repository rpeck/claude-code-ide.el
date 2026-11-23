;;; claude-code-ide-mcp-routing-tests.el --- Tests for the MCP tools server routing  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the routing of the MCP tools server: the reply to
;; notifications, the secret of each instance and launch generation,
;; the global token advice of a user configuration, the context from
;; the instance descriptor, the last active buffer of each worktree,
;; the coordinator scope and `get_capabilities'.  The file is loaded by
;; claude-code-ide-tests.el, after its mocks.  The web-server package
;; is not needed: the tests mock its request accessors and its reply
;; functions.  All projects, instance IDs and secrets are synthetic.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'claude-code-ide)
(require 'claude-code-ide-mcp)
(require 'claude-code-ide-mcp-server)
(require 'claude-code-ide-mcp-http-server)
(require 'claude-code-ide-emacs-tools)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-handover)

;; The debug macro of compiled files reads these
(defvar claude-code-ide-debug)
(defvar claude-code-ide-debug-buffer)

;;; Mock requests

(cl-defstruct claude-code-ide-mcp-routing-tests--request
  "A stand-in for the request object of web-server."
  process headers body)

(defun claude-code-ide-mcp-routing-tests--post (path body &optional headers)
  "Send a POST of BODY to PATH through the HTTP handler, with HEADERS.
BODY is a string or an alist, which is encoded as JSON.  HEADERS is
an alist of web-server header keys, such as :X-EMACS-MCP-TOKEN, and
values.  The request gets Content-Type application/json unless
HEADERS has its own :CONTENT-TYPE entry (nil for none).  Return a
plist with :status, :headers and :body (the parsed JSON reply, or nil
when no body was sent)."
  (let* ((reply (list :status nil :headers nil :body nil))
         (request (make-claude-code-ide-mcp-routing-tests--request
                   :process 'cci-test-process
                   :headers (cons (cons :POST path)
                                  (append headers
                                          (list (cons :CONTENT-TYPE "application/json"))))
                   :body (if (stringp body) body (json-encode body)))))
    (cl-letf (((symbol-function 'ws-headers)
               #'claude-code-ide-mcp-routing-tests--request-headers)
              ((symbol-function 'ws-body)
               #'claude-code-ide-mcp-routing-tests--request-body)
              ((symbol-function 'ws-response-header)
               (lambda (_process status &rest response-headers)
                 (plist-put reply :status status)
                 (plist-put reply :headers response-headers)))
              ((symbol-function 'ws-send)
               (lambda (_process data)
                 (plist-put reply :body
                            (json-parse-string data :object-type 'alist)))))
      (catch 'close-connection
        (claude-code-ide-mcp-http-server--handle-post request)))
    reply))

(defun claude-code-ide-mcp-routing-tests--secret-header (secret)
  "Return the web-server header alist that carries the instance SECRET."
  (list (cons :X-EMACS-MCP-INSTANCE-SECRET secret)))

(defun claude-code-ide-mcp-routing-tests--call (path tool &optional arguments headers)
  "Call TOOL with ARGUMENTS through PATH and HEADERS.
Return the text of the tool result, or the reply plist when the reply
is not a 200 result."
  (let* ((reply (claude-code-ide-mcp-routing-tests--post
                 path
                 `((jsonrpc . "2.0") (id . 1) (method . "tools/call")
                   (params . ((name . ,tool)
                              (arguments . ,(or arguments (make-hash-table))))))
                 headers))
         (result (alist-get 'result (plist-get reply :body))))
    (if (and (equal (plist-get reply :status) 200) result)
        (alist-get 'text (aref (alist-get 'content result) 0))
      reply)))

(defun claude-code-ide-mcp-routing-tests--tool-names (path &optional headers)
  "Return the tool names that tools/list gives through PATH and HEADERS."
  (let ((reply (claude-code-ide-mcp-routing-tests--post
                path '((jsonrpc . "2.0") (id . 2) (method . "tools/list")) headers)))
    (mapcar (lambda (tool) (alist-get 'name tool))
            (alist-get 'tools (alist-get 'result (plist-get reply :body))))))

;;; State

(defmacro claude-code-ide-mcp-routing-tests--with-state (&rest body)
  "Run BODY with an empty server state, no instances and no tools.
The coordinator credential file is in a new temporary folder, which
BODY can read from the variable `cci-test-dir'."
  (declare (indent 0))
  `(let* ((cci-test-dir (file-name-as-directory (make-temp-file "cci-test-mcp-" t)))
          (claude-code-ide-mcp-server--sessions (make-hash-table :test 'equal))
          (claude-code-ide-mcp-server--instance-keys (make-hash-table :test 'equal))
          (claude-code-ide-mcp--sessions (make-hash-table :test 'equal))
          (claude-code-ide-mcp-server-tools nil)
          (claude-code-ide-mcp-server-extra-headers nil)
          (claude-code-ide-mcp-server-secret-placement 'header)
          (claude-code-ide-mcp-server-coordinator-credential-file
           (expand-file-name "reports/coordinator-credential" cci-test-dir))
          (claude-code-ide-instance--all nil)
          (claude-code-ide-instance--generations (make-hash-table :test 'equal))
          (claude-code-ide-enable-mcp-server nil)
          ;; The synthetic worktrees are no real Git repositories
          (vc-handled-backends nil)
          (post-command-hook nil))
     (ignore cci-test-dir)
     (unwind-protect
         (cl-letf (((symbol-function 'claude-code-ide-mcp-server-get-port)
                    (lambda () 4242)))
           ,@body)
       (dolist (buffer (buffer-list))
         (when (or (string-prefix-p "*cci-test-terminal-" (buffer-name buffer))
                   (and (buffer-file-name buffer)
                        (string-prefix-p cci-test-dir (buffer-file-name buffer))))
           (kill-buffer buffer)))
       (delete-directory cci-test-dir t))))

(defun claude-code-ide-mcp-routing-tests--make-worktree (parent name)
  "Make a synthetic Git worktree NAME in PARENT with the file a.el.
Return the worktree folder, with a final slash."
  (let ((dir (file-name-as-directory (expand-file-name name parent))))
    (make-directory dir t)
    ;; A linked worktree has a .git file, not a folder
    (with-temp-file (expand-file-name ".git" dir)
      (insert "gitdir: /nonexistent/cci-test\n"))
    (with-temp-file (expand-file-name "a.el" dir)
      (insert ";; cci-test file\n"))
    dir))

(defun claude-code-ide-mcp-routing-tests--start (instance-id dir &optional key generation provider)
  "Register an instance INSTANCE-ID in DIR and its MCP session.
KEY is the session key; it defaults to INSTANCE-ID.  When KEY differs,
the descriptor gets an MCP session with that session ID, as a start
of the main file makes it.  Return the descriptor."
  (let* ((buffer (generate-new-buffer (format "*cci-test-terminal-%s*" instance-id)))
         (instance (claude-code-ide-instance-register
                    (claude-code-ide-instance-create
                     :id instance-id
                     :provider (or provider 'claude)
                     :project-root dir
                     :worktree dir
                     :generation (or generation 1)
                     :buffer buffer
                     :session (and key (make-claude-code-ide-mcp-session :session-id key))))))
    (with-current-buffer buffer
      (setq default-directory dir))
    (claude-code-ide-mcp-server-register-session (or key instance-id) dir buffer)
    instance))

(defun claude-code-ide-mcp-routing-tests--secret (id)
  "Return the secret of the session that ID names."
  (plist-get (gethash (claude-code-ide-mcp-server--resolve-key id)
                      claude-code-ide-mcp-server--sessions)
             :secret))

(defun claude-code-ide-mcp-routing-tests--server-config (config)
  "Return the alist of the emacs-tools server in the MCP CONFIG."
  (alist-get 'emacs-tools (alist-get 'mcpServers config)))

(defun claude-code-ide-mcp-routing-tests--context-tool ()
  "Register the tool cci_test_context, which reports its context."
  (claude-code-ide-make-tool
   :function (lambda ()
               (claude-code-ide-mcp-server-with-session-context nil
                 (format "%s|%s|%s" default-directory (buffer-name)
                         (claude-code-ide-mcp-request-instance-id))))
   :name "cci_test_context"
   :description "Report the directory, the buffer and the instance of the request"))

;;; Notifications

(ert-deftest claude-code-ide-mcp-routing-test-notification-accepted ()
  "A notification gets 202 Accepted with no body and no content type."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-session" cci-test-dir nil)
    (let ((reply (claude-code-ide-mcp-routing-tests--post
                  "/mcp/cci-test-session"
                  '((jsonrpc . "2.0") (method . "notifications/initialized")))))
      (should (equal (plist-get reply :status) 202))
      (should-not (plist-get reply :body))
      (should-not (assoc "Content-Type" (plist-get reply :headers)))
      (should (equal (cdr (assoc "Content-Length" (plist-get reply :headers))) "0")))))

(ert-deftest claude-code-ide-mcp-routing-test-request-gets-reply ()
  "A request with an ID gets a 200 JSON-RPC reply with the same ID.
The reply has no CORS header."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-session" cci-test-dir nil)
    (let ((reply (claude-code-ide-mcp-routing-tests--post
                  "/mcp/cci-test-session"
                  '((jsonrpc . "2.0") (id . 7) (method . "initialize")
                    (params . ((protocolVersion . "2024-11-05")))))))
      (should (equal (plist-get reply :status) 200))
      (should (equal (cdr (assoc "Content-Type" (plist-get reply :headers)))
                     "application/json"))
      (should-not (assoc "Access-Control-Allow-Origin" (plist-get reply :headers)))
      (should (equal (alist-get 'id (plist-get reply :body)) 7))
      (should (alist-get 'serverInfo (alist-get 'result (plist-get reply :body)))))))

;;; Requests without a credential, and requests from web pages

(ert-deftest claude-code-ide-mcp-routing-test-unknown-session-refused ()
  "A request without ID, or for an unknown or ended session, gets 403.
A session without a secret is reached only by its exact key and with
no secret.  No tool runs for a refused request."
  (claude-code-ide-mcp-routing-tests--with-state
    (let ((ran nil)
          (body '((jsonrpc . "2.0") (id . 8) (method . "tools/call")
                  (params . ((name . "cci_test_flag") (arguments . ((x . 1))))))))
      (claude-code-ide-make-tool :function (lambda () (setq ran t) "ran")
                                 :name "cci_test_flag" :description "Set a flag")
      (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
      (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir)
      (let ((secret (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a")))
        ;; Ended: the old ID and secret are unknown now
        (claude-code-ide-mcp-server-unregister-session "cci-test-inst-a")
        (dolist (case (list (list "/mcp" nil "missing session ID")
                            (list "/mcp/" nil "missing session ID")
                            (list "/mcp/cci-test-garbage" nil "unknown session")
                            (list "/mcp/cci-test-garbage/anything" nil "unknown session")
                            (list (concat "/mcp/cci-test-inst-a/" secret) nil "unknown session")
                            (list "/mcp/cci-test-inst-a"
                                  (claude-code-ide-mcp-routing-tests--secret-header secret)
                                  "unknown session")
                            (list "/mcp/cci-test-cowork/anything" nil "unexpected instance secret")
                            (list "/mcp/cci-test-cowork"
                                  (claude-code-ide-mcp-routing-tests--secret-header "x")
                                  "unexpected instance secret")))
          (let ((reply (claude-code-ide-mcp-routing-tests--post
                        (nth 0 case) body (nth 1 case))))
            (should (equal (plist-get reply :status) 403))
            (should (string-match-p (nth 2 case)
                                    (alist-get 'message
                                               (alist-get 'error (plist-get reply :body))))))))
      (should-not ran)
      ;; The session without a secret by its exact key
      (should (equal (claude-code-ide-mcp-routing-tests--call "/mcp/cci-test-cowork" "cci_test_flag")
                     "ran")))))

(ert-deftest claude-code-ide-mcp-routing-test-web-page-refused ()
  "A request with an Origin header gets 403, one that is not JSON gets 415.
The body is not read, so no tool runs."
  (claude-code-ide-mcp-routing-tests--with-state
    (let ((ran nil)
          (body '((jsonrpc . "2.0") (id . 9) (method . "tools/call")
                  (params . ((name . "cci_test_flag"))))))
      (claude-code-ide-make-tool :function (lambda () (setq ran t) "ran")
                                 :name "cci_test_flag" :description "Set a flag")
      (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
      (dolist (case (list (list (list (cons :ORIGIN "https://cci-test.example")) 403)
                          (list (list (cons :ORIGIN "null")) 403)
                          (list (list (cons :CONTENT-TYPE "text/plain")) 415)
                          (list (list (cons :CONTENT-TYPE "application/x-www-form-urlencoded")) 415)
                          (list (list (cons :CONTENT-TYPE "application/jsonx")) 415)
                          (list (list (cons :CONTENT-TYPE nil)) 415)))
        (let ((reply (claude-code-ide-mcp-routing-tests--post
                      "/mcp/cci-test-cowork" body (nth 0 case))))
          (should (equal (plist-get reply :status) (nth 1 case)))
          (should-not (assoc "Access-Control-Allow-Origin" (plist-get reply :headers)))))
      (should-not ran)
      ;; A parameter after the type is fine
      (should (equal 200 (plist-get (claude-code-ide-mcp-routing-tests--post
                                     "/mcp/cci-test-cowork" body
                                     (list (cons :CONTENT-TYPE "Application/JSON; charset=utf-8")))
                                    :status)))
      (should ran))))

;;; Random secrets

(ert-deftest claude-code-ide-mcp-routing-test-secret-needs-random-device ()
  "A secret is 32 bytes of the random device; without the device, an error.
The global random generator is not used."
  (cl-letf (((symbol-function 'random)
             (lambda (&rest _) (error "The global random generator must not be used"))))
    (let ((a (claude-code-ide-mcp-server--new-secret))
          (b (claude-code-ide-mcp-server--new-secret)))
      (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" a))
      (should-not (equal a b)))
    (let ((claude-code-ide-mcp-server--random-device "/nonexistent/cci-test-random"))
      (let ((err (should-error (claude-code-ide-mcp-server--new-secret))))
        (should (string-match-p "random bytes from /nonexistent/cci-test-random"
                                (error-message-string err)))))
    ;; A device that gives too few bytes
    (let* ((short (make-temp-file "cci-test-short-"))
           (claude-code-ide-mcp-server--random-device short))
      (unwind-protect
          (progn
            (with-temp-file short (insert "abc"))
            (should (string-match-p "gave 3 of 32"
                                    (error-message-string
                                     (should-error (claude-code-ide-mcp-server--new-secret))))))
        (delete-file short)))))

;;; Paths

(ert-deftest claude-code-ide-mcp-routing-test-split-path ()
  "The path gives the ID and the secret; the log shows no secret."
  (should (equal (claude-code-ide-mcp-http-server--split-path "/mcp/cci-a")
                 '("cci-a")))
  (should (equal (claude-code-ide-mcp-http-server--split-path "/mcp/cci-a/")
                 '("cci-a")))
  (should (equal (claude-code-ide-mcp-http-server--split-path "/mcp/cci-a/s3cr3t")
                 '("cci-a" . "s3cr3t")))
  (should (equal (claude-code-ide-mcp-http-server--split-path "/mcp/cci-a/s3cr3t/")
                 '("cci-a" . "s3cr3t")))
  (should (equal (claude-code-ide-mcp-http-server--split-path "/mcp/cci-a/x/y")
                 '("cci-a" . "x/y")))
  (should-not (claude-code-ide-mcp-http-server--split-path "/mcp"))
  (should-not (claude-code-ide-mcp-http-server--split-path "/mcp/"))
  ;; The test suite mocks the debug macro as a function; compiled files
  ;; keep the macro, which writes to the debug buffer
  (let ((logged nil)
        (claude-code-ide-debug t)
        (claude-code-ide-debug-buffer " *cci-test-debug*"))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'claude-code-ide-debug)
                     (lambda (&rest args) (push (apply #'format args) logged))))
            (should (equal (claude-code-ide-mcp-http-server--extract-session-id-from-path
                            '((:POST . "/mcp/cci-a/s3cr3t")))
                           "cci-a")))
          (when-let* ((buffer (get-buffer claude-code-ide-debug-buffer)))
            (push (with-current-buffer buffer (buffer-string)) logged))
          (should (cl-some (lambda (line) (string-match-p "/mcp/cci-a/<secret>" line)) logged))
          (should-not (cl-some (lambda (line) (string-match-p "s3cr3t" line)) logged)))
      (when (get-buffer claude-code-ide-debug-buffer)
        (kill-buffer claude-code-ide-debug-buffer)))))

;;; Secrets

(ert-deftest claude-code-ide-mcp-routing-test-config-carries-secret ()
  "The config names the instance ID and carries its secret.
The default puts the secret in a header; `path' puts it in the URL.
A session without an instance keeps its old URL and gets no secret."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir "cci-test-key-a")
    (let ((secret (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a")))
      (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" secret))
      ;; Header (the default)
      (let ((server (claude-code-ide-mcp-routing-tests--server-config
                     (claude-code-ide-mcp-server-get-config "cci-test-key-a"))))
        (should (equal (alist-get 'url server) "http://localhost:4242/mcp/cci-test-inst-a"))
        (should (equal (alist-get 'X-Emacs-MCP-Instance-Secret (alist-get 'headers server))
                       secret)))
      ;; Path
      (let* ((claude-code-ide-mcp-server-secret-placement 'path)
             (server (claude-code-ide-mcp-routing-tests--server-config
                      (claude-code-ide-mcp-server-get-config "cci-test-key-a"))))
        (should (equal (alist-get 'url server)
                       (concat "http://localhost:4242/mcp/cci-test-inst-a/" secret)))
        (should-not (alist-get 'headers server))))
    ;; A session without an instance, as a user configuration makes it
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (should-not (claude-code-ide-mcp-routing-tests--secret "cci-test-cowork"))
    (let ((server (claude-code-ide-mcp-routing-tests--server-config
                   (claude-code-ide-mcp-server-get-config "cci-test-cowork"))))
      (should (equal (alist-get 'url server) "http://localhost:4242/mcp/cci-test-cowork"))
      (should-not (alist-get 'headers server)))))

(ert-deftest claude-code-ide-mcp-routing-test-secret-checked ()
  "A request for an instance needs its secret, in the header or the path.
A missing or wrong secret gives 403, also for a notification."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir "cci-test-key-a")
    (claude-code-ide-emacs-tools-setup)
    (let* ((secret (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a"))
           (good (claude-code-ide-mcp-routing-tests--secret-header secret))
           (bad (claude-code-ide-mcp-routing-tests--secret-header (make-string 64 ?0)))
           (list-body '((jsonrpc . "2.0") (id . 3) (method . "tools/list")))
           (note-body '((jsonrpc . "2.0") (method . "notifications/initialized"))))
      ;; The right secret in the header, through the instance ID or the key
      (should (equal 200 (plist-get (claude-code-ide-mcp-routing-tests--post
                                     "/mcp/cci-test-inst-a" list-body good)
                                    :status)))
      (should (equal 200 (plist-get (claude-code-ide-mcp-routing-tests--post
                                     "/mcp/cci-test-key-a" list-body good)
                                    :status)))
      ;; The right secret in the path
      (should (equal 200 (plist-get (claude-code-ide-mcp-routing-tests--post
                                     (concat "/mcp/cci-test-inst-a/" secret) list-body)
                                    :status)))
      (should (equal 202 (plist-get (claude-code-ide-mcp-routing-tests--post
                                     "/mcp/cci-test-inst-a" note-body good)
                                    :status)))
      ;; Missing, wrong in the header, wrong in the path
      (dolist (case (list (list "/mcp/cci-test-inst-a" nil "missing")
                          (list "/mcp/cci-test-key-a" nil "missing")
                          (list "/mcp/cci-test-inst-a" bad "wrong")
                          (list "/mcp/cci-test-inst-a/wrong" nil "wrong")
                          ;; Right in one place does not excuse wrong in the other
                          (list (concat "/mcp/cci-test-inst-a/" secret) bad "wrong")
                          (list "/mcp/cci-test-inst-a/wrong" good "wrong")))
        (let ((reply (claude-code-ide-mcp-routing-tests--post
                      (nth 0 case) list-body (nth 1 case))))
          (should (equal (plist-get reply :status) 403))
          (should (equal (alist-get 'id (plist-get reply :body)) 3))
          (should (string-match-p (nth 2 case)
                                  (alist-get 'message (alist-get 'error (plist-get reply :body)))))
          (should-not (string-match-p secret (format "%S" reply)))))
      (should (equal 403 (plist-get (claude-code-ide-mcp-routing-tests--post
                                     "/mcp/cci-test-inst-a" note-body bad)
                                    :status)))
      ;; A tool call with a wrong secret does not run the tool
      (let ((ran nil))
        (claude-code-ide-make-tool :function (lambda () (setq ran t) "ran")
                                   :name "cci_test_flag" :description "Set a flag")
        (should (equal 403 (plist-get (claude-code-ide-mcp-routing-tests--call
                                       "/mcp/cci-test-inst-a" "cci_test_flag" nil bad)
                                      :status)))
        (should-not ran)
        (should (equal "ran" (claude-code-ide-mcp-routing-tests--call
                              "/mcp/cci-test-inst-a" "cci_test_flag" nil good)))
        (should ran)))))

(ert-deftest claude-code-ide-mcp-routing-test-instance-cannot-use-other-secret ()
  "Instance A cannot use the secret of instance B, and gets its own context."
  (claude-code-ide-mcp-routing-tests--with-state
    (let ((dir-a (claude-code-ide-mcp-routing-tests--make-worktree cci-test-dir "wt-a"))
          (dir-b (claude-code-ide-mcp-routing-tests--make-worktree cci-test-dir "wt-b")))
      (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" dir-a)
      (claude-code-ide-mcp-routing-tests--start "cci-test-inst-b" dir-b)
      (claude-code-ide-mcp-routing-tests--context-tool)
      (let ((secret-a (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a"))
            (secret-b (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-b")))
        (should-not (equal secret-a secret-b))
        ;; B's secret for A, in the header and in the path
        (should (equal 403 (plist-get (claude-code-ide-mcp-routing-tests--call
                                       "/mcp/cci-test-inst-a" "cci_test_context" nil
                                       (claude-code-ide-mcp-routing-tests--secret-header secret-b))
                                      :status)))
        (should (equal 403 (plist-get (claude-code-ide-mcp-routing-tests--call
                                       (concat "/mcp/cci-test-inst-a/" secret-b) "cci_test_context")
                                      :status)))
        ;; Each with its own secret gets its own context
        (should (equal (claude-code-ide-mcp-routing-tests--call
                        "/mcp/cci-test-inst-a" "cci_test_context" nil
                        (claude-code-ide-mcp-routing-tests--secret-header secret-a))
                       (format "%s|*cci-test-terminal-cci-test-inst-a*|cci-test-inst-a" dir-a)))
        (should (equal (claude-code-ide-mcp-routing-tests--call
                        (concat "/mcp/cci-test-inst-b/" secret-b) "cci_test_context")
                       (format "%s|*cci-test-terminal-cci-test-inst-b*|cci-test-inst-b" dir-b))))
      (dolist (instance (claude-code-ide-instances))
        (kill-buffer (claude-code-ide-instance-buffer instance))))))

(ert-deftest claude-code-ide-mcp-routing-test-secret-per-generation ()
  "Each launch generation gets a new secret, and the old secret fails."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir "cci-test-key-1" 1)
    (let ((old (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a"))
          (list-body '((jsonrpc . "2.0") (id . 4) (method . "tools/list"))))
      ;; The resume: a new MCP session, a new generation, the same instance ID
      (claude-code-ide-instance-unregister "cci-test-inst-a")
      (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir "cci-test-key-2" 2)
      (let ((new (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a")))
        (should-not (equal old new))
        (should (equal (claude-code-ide-mcp-server--resolve-key "cci-test-inst-a")
                       "cci-test-key-2"))
        ;; The cleanup of the old launch comes late and keeps the new route
        (claude-code-ide-mcp-server-unregister-session "cci-test-key-1")
        (should (equal (claude-code-ide-mcp-server--resolve-key "cci-test-inst-a")
                       "cci-test-key-2"))
        (should (equal 403 (plist-get (claude-code-ide-mcp-routing-tests--post
                                       (concat "/mcp/cci-test-inst-a/" old) list-body)
                                      :status)))
        (should (equal 200 (plist-get (claude-code-ide-mcp-routing-tests--post
                                       (concat "/mcp/cci-test-inst-a/" new) list-body)
                                      :status)))))
    (dolist (instance (claude-code-ide-instances))
      (kill-buffer (claude-code-ide-instance-buffer instance)))))

;;; The global token of a user configuration

(defvar claude-code-ide-mcp-routing-tests--token "cci-test-global-token"
  "The global token of the stub guard.")

(defun claude-code-ide-mcp-routing-tests--guard (orig request)
  "A copy of the guard advice of a user configuration: check the token.
Call ORIG with REQUEST only when the token header is right."
  (if (equal (alist-get :X-EMACS-MCP-TOKEN (ws-headers request))
             claude-code-ide-mcp-routing-tests--token)
      (funcall orig request)
    (with-slots (process) request
      (ws-response-header process 403 (cons "Content-Type" "text/plain"))
      (ws-send process "\"forbidden\"")
      (throw 'close-connection nil))))

(defun claude-code-ide-mcp-routing-tests--add-auth-header (config)
  "A copy of the config advice of a user configuration: add the token to CONFIG."
  (let ((srv (alist-get 'emacs-tools (alist-get 'mcpServers config))))
    (if (not srv)
        config
      `((mcpServers
         . ((emacs-tools
             . ,(append srv
                        `((headers
                           . ((X-Emacs-MCP-Token . ,claude-code-ide-mcp-routing-tests--token))))))))))))

(ert-deftest claude-code-ide-mcp-routing-test-global-token-still-checked ()
  "The guard advice of the global token still runs before the secret check.
A wrong token fails with a right secret, and a wrong secret fails with
a right token."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir)
    (let* ((secret (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a"))
           (token (cons :X-EMACS-MCP-TOKEN claude-code-ide-mcp-routing-tests--token))
           (bad-token (cons :X-EMACS-MCP-TOKEN "cci-test-wrong"))
           (good-secret (car (claude-code-ide-mcp-routing-tests--secret-header secret)))
           (bad-secret (car (claude-code-ide-mcp-routing-tests--secret-header "cci-test-wrong")))
           (body '((jsonrpc . "2.0") (id . 5) (method . "tools/list"))))
      (advice-add 'claude-code-ide-mcp-http-server--handle-post :around
                  #'claude-code-ide-mcp-routing-tests--guard)
      (unwind-protect
          (progn
            ;; Wrong token, right secret: the guard refuses
            (let ((reply (claude-code-ide-mcp-routing-tests--post
                          "/mcp/cci-test-inst-a" body (list bad-token good-secret))))
              (should (equal (plist-get reply :status) 403))
              (should (equal (plist-get reply :body) "forbidden")))
            ;; No token: the guard refuses
            (should (equal 403 (plist-get (claude-code-ide-mcp-routing-tests--post
                                           "/mcp/cci-test-inst-a" body (list good-secret))
                                          :status)))
            ;; Right token, wrong secret: the secret check refuses
            (let ((reply (claude-code-ide-mcp-routing-tests--post
                          "/mcp/cci-test-inst-a" body (list token bad-secret))))
              (should (equal (plist-get reply :status) 403))
              (should (string-match-p "wrong instance secret"
                                      (alist-get 'message (alist-get 'error (plist-get reply :body))))))
            ;; Both right
            (should (equal 200 (plist-get (claude-code-ide-mcp-routing-tests--post
                                           "/mcp/cci-test-inst-a" body (list token good-secret))
                                          :status))))
        (advice-remove 'claude-code-ide-mcp-http-server--handle-post
                       #'claude-code-ide-mcp-routing-tests--guard)))
    (kill-buffer (claude-code-ide-instance-buffer
                  (claude-code-ide-instance-by-id "cci-test-inst-a")))))

(ert-deftest claude-code-ide-mcp-routing-test-config-advice-keeps-secret ()
  "The token advice of a user configuration keeps the secret header.
The config gets one headers entry with both headers, and its JSON has
one \"headers\" key."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir)
    (advice-add 'claude-code-ide-mcp-server-get-config :filter-return
                #'claude-code-ide-mcp-routing-tests--add-auth-header)
    (unwind-protect
        (let* ((secret (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a"))
               (config (claude-code-ide-mcp-server-get-config "cci-test-inst-a"))
               (server (claude-code-ide-mcp-routing-tests--server-config config))
               (json (json-encode config)))
          (should (= 1 (cl-count 'headers server :key #'car-safe)))
          (should (equal (alist-get 'headers server)
                         `((X-Emacs-MCP-Instance-Secret . ,secret)
                           (X-Emacs-MCP-Token . ,claude-code-ide-mcp-routing-tests--token))))
          (should (= 2 (length (split-string json "\"headers\"")))))
      (advice-remove 'claude-code-ide-mcp-server-get-config
                     #'claude-code-ide-mcp-routing-tests--add-auth-header))
    ;; Without a secret, the advice result stays as it is
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (advice-add 'claude-code-ide-mcp-server-get-config :filter-return
                #'claude-code-ide-mcp-routing-tests--add-auth-header)
    (unwind-protect
        (should (equal (alist-get 'headers (claude-code-ide-mcp-routing-tests--server-config
                                            (claude-code-ide-mcp-server-get-config "cci-test-cowork")))
                       `((X-Emacs-MCP-Token . ,claude-code-ide-mcp-routing-tests--token))))
      (advice-remove 'claude-code-ide-mcp-server-get-config
                     #'claude-code-ide-mcp-routing-tests--add-auth-header))))

(ert-deftest claude-code-ide-mcp-routing-test-merge-headers ()
  "Two headers entries merge in order; a later header of the same name wins."
  (should (equal (claude-code-ide-mcp-server--merge-config-headers
                  '((mcpServers . ((emacs-tools . ((type . "http")
                                                   (headers . ((A . "1") (B . "2")))
                                                   (url . "u")
                                                   (headers . ((b . "3") (C . "4")))))))))
                 '((mcpServers . ((emacs-tools . ((type . "http")
                                                  (url . "u")
                                                  (headers . ((A . "1") (b . "3") (C . "4"))))))))))
  (should (equal (claude-code-ide-mcp-server--merge-config-headers nil) nil))
  (let ((one '((mcpServers . ((emacs-tools . ((url . "u") (headers . ((A . "1"))))))))))
    (should (equal (claude-code-ide-mcp-server--merge-config-headers one) one))))

;;; Context from the descriptor (acceptance check 3)

(ert-deftest claude-code-ide-mcp-routing-test-caller-worktree-not-selected-window ()
  "A caller's MCP operations use its worktree and buffers.
Another window shows a buffer of another worktree, and that buffer
is the current one when the request comes."
  (claude-code-ide-mcp-routing-tests--with-state
    (let* ((dir-a (claude-code-ide-mcp-routing-tests--make-worktree cci-test-dir "wt-a"))
           (dir-b (claude-code-ide-mcp-routing-tests--make-worktree cci-test-dir "wt-b"))
           (file-a (find-file-noselect (expand-file-name "a.el" dir-a)))
           (file-b (find-file-noselect (expand-file-name "a.el" dir-b))))
      ;; Only A has this file, so a lookup in B's folder finds no symbol
      (with-temp-file (expand-file-name "only-a.el" dir-a)
        (insert "(defun cci-test-only-in-a ()\n  t)\n"))
      (cl-letf (((symbol-function 'project-files) (lambda (&rest _) '("a.el"))))
        (progn
          (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" dir-a)
          (claude-code-ide-mcp-routing-tests--start "cci-test-inst-b" dir-b)
          (claude-code-ide-mcp-routing-tests--context-tool)
          (claude-code-ide-emacs-tools-setup)
          (let ((header (claude-code-ide-mcp-routing-tests--secret-header
                         (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a"))))
            ;; The user visits a file of A, then works in a file of B.
            ;; Neither instance has an IDE connection, as for Codex.
            (with-current-buffer file-a
              (claude-code-ide-mcp--track-active-buffer))
            (switch-to-buffer file-b)
            (claude-code-ide-mcp--track-active-buffer)
            (should (eq (window-buffer (selected-window)) file-b))
            ;; A keeps its own buffer; B got its own
            (should (eq (plist-get (claude-code-ide-mcp-server-get-session-context
                                    "cci-test-inst-a")
                                   :last-active-buffer)
                        file-a))
            (should (eq (plist-get (claude-code-ide-mcp-server-get-session-context
                                    "cci-test-inst-b")
                                   :last-active-buffer)
                        file-b))
            ;; The request of A, made while B's buffer is current
            (with-current-buffer file-b
              (should (equal (claude-code-ide-mcp-routing-tests--call
                              "/mcp/cci-test-inst-a" "cci_test_context" nil header)
                             (format "%s|%s|cci-test-inst-a" dir-a (buffer-name file-a))))
              ;; A relative file name resolves in A's worktree
              (should (string-match-p
                       "cci-test-only-in-a"
                       (claude-code-ide-mcp-routing-tests--call
                        "/mcp/cci-test-inst-a" "claude-code-ide-mcp-imenu-list-symbols"
                        '((file_path . "only-a.el")) header)))
              (should (find-buffer-visiting (expand-file-name "only-a.el" dir-a)))
              (should-not (find-buffer-visiting (expand-file-name "only-a.el" dir-b)))
              ;; The project info names A's worktree and instance
              (let ((info (claude-code-ide-mcp-routing-tests--call
                           "/mcp/cci-test-inst-a" "claude-code-ide-mcp-project-info" nil header)))
                (should (string-match-p (concat "Project: " (regexp-quote dir-a)) info))
                (should (string-match-p (concat "Worktree: " (regexp-quote dir-a)) info))
                (should (string-match-p "Instance: cci-test-inst-a" info))
                (should-not (string-match-p (regexp-quote dir-b) info))))))))))

(ert-deftest claude-code-ide-mcp-routing-test-last-active-buffer-worktree ()
  "The last active buffer changes only for a file of the instance's worktree.
A non-file buffer, a file outside, and a file of a nested worktree do
not change it."
  (claude-code-ide-mcp-routing-tests--with-state
    (let* ((dir-a (claude-code-ide-mcp-routing-tests--make-worktree cci-test-dir "wt-a"))
           (nested (claude-code-ide-mcp-routing-tests--make-worktree dir-a "nested"))
           (inside (find-file-noselect (expand-file-name "a.el" dir-a)))
           (in-nested (find-file-noselect (expand-file-name "a.el" nested)))
           (outside (find-file-noselect (expand-file-name "outside.el" cci-test-dir)))
           (scratch (generate-new-buffer "*cci-test-terminal-scratch*")))
      (progn
        (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" dir-a)
        (dolist (buffer (list scratch outside in-nested))
          (should-not (claude-code-ide-mcp-server-update-last-active-buffer
                       "cci-test-inst-a" buffer)))
        (should-not (plist-get (claude-code-ide-mcp-server-get-session-context
                                "cci-test-inst-a")
                               :last-active-buffer))
        (should (claude-code-ide-mcp-server-update-last-active-buffer
                 "cci-test-inst-a" inside))
        (should (eq (plist-get (claude-code-ide-mcp-server-get-session-context
                                "cci-test-inst-a")
                               :last-active-buffer)
                    inside))
        ;; The one tracker is on while a session is registered
        (should (memq #'claude-code-ide-mcp--track-active-buffer post-command-hook))
        (should-not (fboundp 'claude-code-ide-mcp-server--track-buffer))
        (claude-code-ide-mcp-server-unregister-session "cci-test-inst-a")
        (should-not (memq #'claude-code-ide-mcp--track-active-buffer post-command-hook))))))

(ert-deftest claude-code-ide-mcp-routing-test-one-tracker ()
  "The IDE tracker also serves tools server sessions, and stays while one is left.
A connected IDE session is updated once, not twice."
  (claude-code-ide-mcp-routing-tests--with-state
    (let* ((dir-a (claude-code-ide-mcp-routing-tests--make-worktree cci-test-dir "wt-a"))
           (file-a (find-file-noselect (expand-file-name "a.el" dir-a)))
           (updates nil))
      (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" dir-a)
      (claude-code-ide-mcp-server-register-session "cci-test-other" cci-test-dir nil)
      ;; An IDE session of the same key, with a connected client
      (puthash "cci-test-inst-a"
               (make-claude-code-ide-mcp-session :session-id "cci-test-inst-a"
                                                 :project-dir dir-a :client 'cci-test-client)
               claude-code-ide-mcp--sessions)
      (let ((update (symbol-function 'claude-code-ide-mcp-server-update-last-active-buffer)))
        (cl-letf (((symbol-function 'claude-code-ide-mcp--get-buffer-project) (lambda () dir-a))
                  ((symbol-function 'claude-code-ide-mcp-server-update-last-active-buffer)
                   (lambda (key buffer) (push key updates) (funcall update key buffer))))
          (with-current-buffer file-a
            (claude-code-ide-mcp--track-active-buffer))))
      ;; Each session once: the IDE part updates A, the tools part the other
      (should (equal (sort updates #'string<) '("cci-test-inst-a" "cci-test-other")))
      (should (eq (plist-get (claude-code-ide-mcp-server-get-session-context "cci-test-inst-a")
                             :last-active-buffer)
                  file-a))
      ;; The hook stays while the IDE session or a tools session is left
      (claude-code-ide-mcp-server-unregister-session "cci-test-inst-a")
      (claude-code-ide-mcp-server-unregister-session "cci-test-other")
      (should (memq #'claude-code-ide-mcp--track-active-buffer post-command-hook))
      (clrhash claude-code-ide-mcp--sessions)
      (claude-code-ide-mcp-server-register-session "cci-test-other" cci-test-dir nil)
      (claude-code-ide-mcp-server-unregister-session "cci-test-other")
      (should-not (memq #'claude-code-ide-mcp--track-active-buffer post-command-hook)))))

(ert-deftest claude-code-ide-mcp-routing-test-context-from-descriptor ()
  "The context comes from the descriptor of the launch and has no secret.
A descriptor of a later launch of the same ID does not count."
  (claude-code-ide-mcp-routing-tests--with-state
    (let ((dir-a (claude-code-ide-mcp-routing-tests--make-worktree cci-test-dir "wt-a")))
      (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" dir-a "cci-test-key-a" 1)
      (let ((context (claude-code-ide-mcp-server-get-session-context "cci-test-key-a")))
        (should (equal (plist-get context :project-dir) dir-a))
        (should (equal (plist-get context :worktree) dir-a))
        (should (equal (plist-get context :instance-id) "cci-test-inst-a"))
        (should (eq (plist-get context :provider) 'claude))
        (should-not (plist-member context :secret))
        ;; The same through the instance ID
        (should (equal (claude-code-ide-mcp-server-get-session-context "cci-test-inst-a")
                       context)))
      ;; A later generation takes the ID; the old session keeps its own data
      (let ((old-buffer (claude-code-ide-instance-buffer
                         (claude-code-ide-instance-by-id "cci-test-inst-a"))))
        (claude-code-ide-instance-unregister "cci-test-inst-a")
        (claude-code-ide-instance-register
         (claude-code-ide-instance-create :id "cci-test-inst-a" :provider 'claude
                                          :project-root "/nonexistent/cci-test-other/"
                                          :generation 2))
        (let ((context (claude-code-ide-mcp-server-get-session-context "cci-test-key-a")))
          (should (equal (plist-get context :project-dir) dir-a))
          (should (eq (plist-get context :buffer) old-buffer))
          (should-not (plist-member context :worktree)))
        (kill-buffer old-buffer)))))

;;; Coordinator scope

(ert-deftest claude-code-ide-mcp-routing-test-tool-scope ()
  "A tool spec carries :scope; a bad scope is an error."
  (claude-code-ide-mcp-routing-tests--with-state
    (let ((spec (claude-code-ide-make-tool :function #'ignore :name "cci_test_coord"
                                           :description "A coordinator tool"
                                           :scope 'coordinator))
          (plain (claude-code-ide-make-tool :function #'ignore :name "cci_test_plain"
                                            :description "An instance tool")))
      (should (eq (plist-get spec :scope) 'coordinator))
      (should (eq (claude-code-ide-mcp-server-tool-scope spec) 'coordinator))
      (should (eq (claude-code-ide-mcp-server-tool-scope plain) 'instance))
      (should-error (claude-code-ide-make-tool :function #'ignore :name "cci_test_bad"
                                               :description "Bad" :scope 'everyone))
      ;; With the server running, a coordinator tool makes the credential file
      (should (file-exists-p (claude-code-ide-mcp-server-coordinator-credential-file))))))

(ert-deftest claude-code-ide-mcp-routing-test-coordinator-only ()
  "A coordinator tool refuses a plain instance request with an explicit result.
It runs for a request with the coordinator credential; a wrong
credential gives 403."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir)
    (let ((ran nil))
      (claude-code-ide-make-tool :function (lambda (target)
                                             (setq ran target)
                                             (format "%s|%s" target
                                                     (claude-code-ide-mcp-request-instance-id)))
                                 :name "cci_test_coord"
                                 :description "A coordinator tool"
                                 :args '((:name "instance_id" :type string
                                                :description "Target"))
                                 :scope 'coordinator)
      (claude-code-ide-make-tool :function #'ignore :name "cci_test_plain"
                                 :description "An instance tool")
      (let* ((secret (claude-code-ide-mcp-routing-tests--secret-header
                      (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a")))
             (credential (claude-code-ide-mcp-server-coordinator-credential))
             (coordinator (list (cons :X-EMACS-MCP-COORDINATOR credential)))
             (args '((instance_id . "cci-test-inst-b"))))
        (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" credential))
        (should-not (equal credential (cdar secret)))
        ;; A plain instance request: hidden from the list, refused when called
        (should (equal (claude-code-ide-mcp-routing-tests--tool-names "/mcp/cci-test-inst-a" secret)
                       '("cci_test_plain")))
        (should (equal (json-parse-string
                        (claude-code-ide-mcp-routing-tests--call
                         "/mcp/cci-test-inst-a" "cci_test_coord" args secret)
                        :object-type 'alist)
                       '((status . "unavailable") (reason . "coordinator-only"))))
        ;; The refusal also holds without any arguments
        (should (string-match-p "coordinator-only"
                                (claude-code-ide-mcp-routing-tests--call
                                 "/mcp/cci-test-inst-a" "cci_test_coord" nil secret)))
        ;; /mcp without the credential is refused before any tool
        (should (equal 403 (plist-get (claude-code-ide-mcp-routing-tests--call
                                       "/mcp" "cci_test_coord" args)
                                      :status)))
        ;; The instance secret is not a coordinator credential
        (should (equal 403 (plist-get (claude-code-ide-mcp-routing-tests--call
                                       "/mcp" "cci_test_coord" args
                                       (list (cons :X-EMACS-MCP-COORDINATOR (cdar secret))))
                                      :status)))
        (should-not ran)
        ;; A coordinator request to /mcp
        (should (equal (claude-code-ide-mcp-routing-tests--tool-names "/mcp" coordinator)
                       '("cci_test_plain" "cci_test_coord")))
        (should (equal (claude-code-ide-mcp-routing-tests--call
                        "/mcp" "cci_test_coord" args coordinator)
                       "cci-test-inst-b|nil"))
        (should (equal ran "cci-test-inst-b"))
        ;; A coordinator request through an instance path still needs its secret
        (should (equal 403 (plist-get (claude-code-ide-mcp-routing-tests--call
                                       "/mcp/cci-test-inst-a" "cci_test_coord" args coordinator)
                                      :status)))
        (should (equal (claude-code-ide-mcp-routing-tests--call
                        "/mcp/cci-test-inst-a" "cci_test_coord" args
                        (append coordinator secret))
                       "cci-test-inst-b|cci-test-inst-a"))))
    (kill-buffer (claude-code-ide-instance-buffer
                  (claude-code-ide-instance-by-id "cci-test-inst-a")))))

(ert-deftest claude-code-ide-mcp-routing-test-coordinator-credential-file ()
  "The credential file has mode 0600, and a readable file is refused."
  (claude-code-ide-mcp-routing-tests--with-state
    (let ((file (claude-code-ide-mcp-server-coordinator-credential-file)))
      (should (equal file claude-code-ide-mcp-server-coordinator-credential-file))
      (should-not (claude-code-ide-mcp-server-coordinator-credential))
      (should-not (file-exists-p file))
      (let ((value (claude-code-ide-mcp-server-coordinator-credential t)))
        (should (= (file-modes file) #o600))
        (should (= (logand (file-modes (file-name-directory file)) #o077) 0))
        (should (equal (claude-code-ide-mcp-server-coordinator-credential) value))
        ;; Readable by others: refused
        (set-file-modes file #o644)
        (let ((inhibit-message t))
          (should-not (claude-code-ide-mcp-server-coordinator-credential)))
        (should-not (plist-get (claude-code-ide-mcp-server-check-request nil nil nil value) :ok))
        (set-file-modes file #o600)
        ;; Rotation gives a new value
        (let ((inhibit-message t))
          (claude-code-ide-mcp-server-rotate-coordinator-credential))
        (should-not (equal (claude-code-ide-mcp-server-coordinator-credential) value))
        (should (= (file-modes file) #o600))))
    ;; The default is the report directory of the registry
    (let ((claude-code-ide-mcp-server-coordinator-credential-file nil)
          (claude-code-ide-session-registry-report-directory "/nonexistent/cci-test-reports/"))
      (should (equal (claude-code-ide-mcp-server-coordinator-credential-file)
                     "/nonexistent/cci-test-reports/coordinator-credential")))))

(ert-deftest claude-code-ide-mcp-routing-test-credential-path-stable ()
  "The credential path is the same whether or not the registry is loaded.
The server's report directory equals the registry's for the default,
a custom state file and a custom report directory, and keeps the
registry defaults when the registry options are not bound."
  (dolist (settings '((nil nil)
                      ("/nonexistent/cci-test-state.json" nil)
                      ("/nonexistent/cci-test-state" nil)
                      ("/nonexistent/cci-test-state.json" "/nonexistent/cci-test-reports")))
    (let ((claude-code-ide-state-file
           (or (nth 0 settings) (eval (car (get 'claude-code-ide-state-file 'standard-value)) t)))
          (claude-code-ide-session-registry-report-directory (nth 1 settings)))
      (should (equal (claude-code-ide-mcp-server--report-directory)
                     (claude-code-ide-session-registry--report-directory)))))
  ;; The registry not loaded: its options are unbound.  Their defaults
  ;; give the folder of the loaded registry with its default options;
  ;; the test run binds other values.
  (let ((loaded (let ((claude-code-ide-state-file
                       (eval (car (get 'claude-code-ide-state-file 'standard-value)) t))
                      (claude-code-ide-session-registry-report-directory nil))
                  (claude-code-ide-mcp-server--report-directory)))
        (state claude-code-ide-state-file)
        (reports claude-code-ide-session-registry-report-directory))
    (unwind-protect
        (progn
          (makunbound 'claude-code-ide-state-file)
          (makunbound 'claude-code-ide-session-registry-report-directory)
          (should (equal (claude-code-ide-mcp-server--report-directory)
                         (file-name-as-directory
                          (expand-file-name "~/.emacs-claude-code-ide-state-reports"))))
          (should (equal (claude-code-ide-mcp-server--report-directory) loaded)))
      (set-default 'claude-code-ide-state-file state)
      (set-default 'claude-code-ide-session-registry-report-directory reports)))
  ;; The default of the server equals the default of the registry
  (should (equal claude-code-ide-mcp-server--default-state-file
                 (abbreviate-file-name
                  (eval (car (get 'claude-code-ide-state-file 'standard-value)) t)))))

(ert-deftest claude-code-ide-mcp-routing-test-request-instance-id ()
  "The current request has the ID of its instance, or nil without one."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir "cci-test-key-a")
    (claude-code-ide-make-tool :function (lambda ()
                                           (format "%s" (claude-code-ide-mcp-request-instance-id)))
                               :name "cci_test_id" :description "The instance ID")
    (let ((secret (claude-code-ide-mcp-routing-tests--secret-header
                   (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a"))))
      (should (equal (claude-code-ide-mcp-routing-tests--call "/mcp/cci-test-key-a" "cci_test_id"
                                                              nil secret)
                     "cci-test-inst-a"))
      ;; A coordinator request to /mcp has no instance
      (should (equal (claude-code-ide-mcp-routing-tests--call
                      "/mcp" "cci_test_id" nil
                      (list (cons :X-EMACS-MCP-COORDINATOR
                                  (claude-code-ide-mcp-server-coordinator-credential t))))
                     "nil"))
      (should-not (claude-code-ide-mcp-request-instance-id)))
    (kill-buffer (claude-code-ide-instance-buffer
                  (claude-code-ide-instance-by-id "cci-test-inst-a")))))

;;; get_capabilities

(ert-deftest claude-code-ide-mcp-routing-test-get-capabilities ()
  "get_capabilities gives the operations of the calling instance.
A missing operation gives {\"status\": \"unavailable\", \"capability\": ...}."
  (claude-code-ide-mcp-routing-tests--with-state
    (let ((claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry)))
      (claude-code-ide-register-provider
       (claude-code-ide-provider-create :name 'cci-test-stub :display-name "Stub"
                                        :buffer-name-prefix "cci-stub"
                                        :launch #'ignore :stop #'ignore))
      (claude-code-ide-emacs-tools-setup)
      (claude-code-ide-mcp-routing-tests--check-capabilities cci-test-dir))))

(defun claude-code-ide-mcp-routing-tests--check-capabilities (parent)
  "Check get_capabilities for a claude and a stub instance in folders of PARENT."
  (let* ((dir-a (claude-code-ide-mcp-routing-tests--make-worktree parent "wt-a"))
         (dir-s (claude-code-ide-mcp-routing-tests--make-worktree parent "wt-s")))
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" dir-a)
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-s" dir-s nil 3 'cci-test-stub)
    (let ((secret-a (claude-code-ide-mcp-routing-tests--secret-header
                     (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a")))
          (secret-s (claude-code-ide-mcp-routing-tests--secret-header
                     (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-s")))
          (capabilities (lambda (path args headers)
                          (json-parse-string
                           (claude-code-ide-mcp-routing-tests--call
                            path "get_capabilities" args headers)
                           :object-type 'alist :array-type 'list))))
      (should (member "get_capabilities"
                      (claude-code-ide-mcp-routing-tests--tool-names "/mcp/cci-test-inst-a" secret-a)))
      ;; The claude provider has every operation
      (let ((result (funcall capabilities "/mcp/cci-test-inst-a" nil secret-a)))
        (should (equal (alist-get 'instance_id result) "cci-test-inst-a"))
        (should (equal (alist-get 'provider result) "claude"))
        (should (equal (alist-get 'capabilities result)
                       (mapcar #'symbol-name claude-code-ide-provider-operations)))
        (should-not (alist-get 'unavailable result)))
      ;; The stub has two
      (let ((result (funcall capabilities "/mcp/cci-test-inst-s" nil secret-s)))
        (should (equal (alist-get 'provider result) "cci-test-stub"))
        (should (equal (alist-get 'generation result) 3))
        (should (equal (alist-get 'capabilities result) '("launch" "stop")))
        (should (member '((status . "unavailable") (capability . "fork"))
                        (alist-get 'unavailable result)))
        (should (= (length (alist-get 'unavailable result))
                   (- (length claude-code-ide-provider-operations) 2))))
      ;; One operation
      (should (equal (funcall capabilities "/mcp/cci-test-inst-s" '((operation . "fork")) secret-s)
                     '((status . "unavailable") (capability . "fork"))))
      (should (equal (funcall capabilities "/mcp/cci-test-inst-s" '((operation . "stop")) secret-s)
                     '((status . "available") (capability . "stop"))))
      (should (equal (funcall capabilities "/mcp/cci-test-inst-a"
                              '((operation . "submit_prompt")) secret-a)
                     '((status . "available") (capability . "submit_prompt"))))
      (should (equal (funcall capabilities "/mcp/cci-test-inst-a" '((operation . "bogus")) secret-a)
                     '((status . "unavailable") (capability . "bogus"))))
      ;; Another instance needs the coordinator credential
      (should (equal (funcall capabilities "/mcp/cci-test-inst-a"
                              '((instance_id . "cci-test-inst-s")) secret-a)
                     '((status . "unavailable") (reason . "coordinator-only"))))
      (let ((coordinator (list (cons :X-EMACS-MCP-COORDINATOR
                                     (claude-code-ide-mcp-server-coordinator-credential t)))))
        (should (equal (alist-get 'instance_id
                                  (funcall capabilities "/mcp"
                                           '((instance_id . "cci-test-inst-s")) coordinator))
                       "cci-test-inst-s"))
        ;; No instance: a coordinator request to /mcp without instance_id
        (should (equal (funcall capabilities "/mcp" nil coordinator)
                       '((status . "unavailable") (reason . "no-instance")))))
      ;; An operation name that no symbol has is unavailable and makes no symbol
      (should (equal (funcall capabilities "/mcp/cci-test-inst-a"
                              '((operation . "cci-test-never-a-symbol-q7")) secret-a)
                     '((status . "unavailable") (capability . "cci-test-never-a-symbol-q7"))))
      (should-not (intern-soft "cci-test-never-a-symbol-q7")))
    (dolist (instance (claude-code-ide-instances))
      (kill-buffer (claude-code-ide-instance-buffer instance)))))

;;; Extra headers

(ert-deftest claude-code-ide-mcp-routing-test-extra-headers ()
  "get-config merges the extra headers with the secret in one entry.
A function value is called, a nil value drops the header, and the
secret wins over an extra header of the same name."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir)
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let ((claude-code-ide-mcp-server-extra-headers
           `(("X-Emacs-MCP-Token" . "cci-test-token")
             (X-Cci-Test-Lazy . ,(lambda () "cci-test-lazy"))
             (X-Cci-Test-Dropped . ,(lambda () nil))
             ("x-emacs-mcp-instance-secret" . "cci-test-not-the-secret")))
          (secret (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-a")))
      (let ((server (claude-code-ide-mcp-routing-tests--server-config
                     (claude-code-ide-mcp-server-get-config "cci-test-inst-a"))))
        (should (= 1 (cl-count 'headers server :key #'car-safe)))
        (should (equal (alist-get 'headers server)
                       `((X-Emacs-MCP-Token . "cci-test-token")
                         (X-Cci-Test-Lazy . "cci-test-lazy")
                         (X-Emacs-MCP-Instance-Secret . ,secret)))))
      ;; A session without a secret gets the extra headers only
      (let ((claude-code-ide-mcp-server-extra-headers '(("X-Emacs-MCP-Token" . "cci-test-token"))))
        (should (equal (alist-get 'headers (claude-code-ide-mcp-routing-tests--server-config
                                            (claude-code-ide-mcp-server-get-config "cci-test-cowork")))
                       '((X-Emacs-MCP-Token . "cci-test-token")))))
      ;; Path placement: the extra headers stay, the secret goes to the URL
      (let ((claude-code-ide-mcp-server-secret-placement 'path)
            (claude-code-ide-mcp-server-extra-headers '(("X-Emacs-MCP-Token" . "cci-test-token"))))
        (let ((server (claude-code-ide-mcp-routing-tests--server-config
                       (claude-code-ide-mcp-server-get-config "cci-test-inst-a"))))
          (should (equal (alist-get 'headers server) '((X-Emacs-MCP-Token . "cci-test-token"))))
          (should (string-suffix-p secret (alist-get 'url server))))))))

;;; Coordinator instances

(defun claude-code-ide-mcp-routing-tests--config-headers (id)
  "Return the headers alist of the generated config of the session ID."
  (alist-get 'headers (claude-code-ide-mcp-routing-tests--server-config
                       (claude-code-ide-mcp-server-get-config id))))

(defun claude-code-ide-mcp-routing-tests--as-request-headers (headers)
  "Turn the config HEADERS alist into web-server request headers."
  (mapcar (lambda (header)
            (cons (intern (concat ":" (upcase (format "%s" (car header))))) (cdr header)))
          headers))

(ert-deftest claude-code-ide-mcp-routing-test-coordinator-role-gets-credential ()
  "An instance with the role \"coordinator\" gets the coordinator header.
Its generated config can then call a coordinator tool.  An instance
without that role, a session without a descriptor, and an older launch
of a coordinator ID never get the header."
  (claude-code-ide-mcp-routing-tests--with-state
    (let ((dir-c (claude-code-ide-mcp-routing-tests--make-worktree cci-test-dir "wt-c"))
          (dir-w (claude-code-ide-mcp-routing-tests--make-worktree cci-test-dir "wt-w"))
          (coordinator-header 'X-Emacs-MCP-Coordinator))
      (claude-code-ide-make-tool :function (lambda () "coordinated")
                                 :name "cci_test_coord" :description "A coordinator tool"
                                 :scope 'coordinator)
      ;; A coordinator instance and a worker instance
      (setf (claude-code-ide-instance-role
             (claude-code-ide-mcp-routing-tests--start "cci-test-inst-c" dir-c))
            "coordinator")
      (setf (claude-code-ide-instance-role
             (claude-code-ide-mcp-routing-tests--start "cci-test-inst-w" dir-w))
            "worker")
      (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
      ;; The coordinator gets the credential, made when it was missing
      (let ((headers (claude-code-ide-mcp-routing-tests--config-headers "cci-test-inst-c")))
        (should (equal (alist-get coordinator-header headers)
                       (claude-code-ide-mcp-server-coordinator-credential)))
        (should (= (file-modes (claude-code-ide-mcp-server-coordinator-credential-file)) #o600))
        (should (equal (alist-get 'X-Emacs-MCP-Instance-Secret headers)
                       (claude-code-ide-mcp-routing-tests--secret "cci-test-inst-c")))
        ;; With its own config, the coordinator sees and runs the coordinator tool
        (let ((request (claude-code-ide-mcp-routing-tests--as-request-headers headers)))
          (should (member "cci_test_coord"
                          (claude-code-ide-mcp-routing-tests--tool-names "/mcp/cci-test-inst-c" request)))
          (should (equal (claude-code-ide-mcp-routing-tests--call
                          "/mcp/cci-test-inst-c" "cci_test_coord" nil request)
                         "coordinated"))))
      ;; Path placement keeps the coordinator header
      (let ((claude-code-ide-mcp-server-secret-placement 'path))
        (should (alist-get coordinator-header
                           (claude-code-ide-mcp-routing-tests--config-headers "cci-test-inst-c"))))
      ;; The worker and the session without a descriptor never get it
      (let ((headers (claude-code-ide-mcp-routing-tests--config-headers "cci-test-inst-w")))
        (should-not (alist-get coordinator-header headers))
        (should-not (string-match-p "Coordinator" (format "%S" headers)))
        (should (string-match-p
                 "coordinator-only"
                 (claude-code-ide-mcp-routing-tests--call
                  "/mcp/cci-test-inst-w" "cci_test_coord" nil
                  (claude-code-ide-mcp-routing-tests--as-request-headers headers)))))
      (should-not (claude-code-ide-mcp-routing-tests--config-headers "cci-test-cowork"))
      ;; A later launch of the worker ID with the coordinator role does not
      ;; change the config of the older session
      (claude-code-ide-instance-unregister "cci-test-inst-w")
      (claude-code-ide-instance-register
       (claude-code-ide-instance-create :id "cci-test-inst-w" :provider 'claude
                                        :project-root dir-w :generation 2
                                        :role "coordinator"))
      (should-not (alist-get coordinator-header
                             (claude-code-ide-mcp-routing-tests--config-headers "cci-test-inst-w"))))))

(ert-deftest claude-code-ide-mcp-routing-test-no-role-no-credential ()
  "An instance without a role gets no coordinator header, and no file is made."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir)
    (should-not (claude-code-ide-instance-role (claude-code-ide-instance-by-id "cci-test-inst-a")))
    (should-not (alist-get 'X-Emacs-MCP-Coordinator
                           (claude-code-ide-mcp-routing-tests--config-headers "cci-test-inst-a")))
    (should-not (file-exists-p (claude-code-ide-mcp-server-coordinator-credential-file)))))

;;; A body that arrives after the headers

(cl-defstruct claude-code-ide-mcp-routing-tests--parsed-request
  "A stand-in for a web-server request, with the active slot of the parser."
  process headers body (active t))

(defun claude-code-ide-mcp-routing-tests--initialize-body (id)
  "Return the JSON text of an initialize request with ID."
  (json-encode `((jsonrpc . "2.0") (id . ,id) (method . "initialize")
                 (params . ,(make-hash-table)))))

(defun claude-code-ide-mcp-routing-tests--post-parsed (request)
  "Run the HTTP handler on REQUEST, a parsed-request stand-in.
Return a plist: :thrown is the value thrown to `close-connection',
:status and :body describe the reply (nil when none was sent), and
:sent lists the strings that the handler sent to the process
directly, oldest first."
  (let ((reply (list :thrown nil :status nil :body nil :sent nil)))
    (cl-letf (((symbol-function 'ws-headers)
               #'claude-code-ide-mcp-routing-tests--parsed-request-headers)
              ((symbol-function 'ws-body)
               #'claude-code-ide-mcp-routing-tests--parsed-request-body)
              ((symbol-function 'ws-response-header)
               (lambda (_process status &rest _headers)
                 (plist-put reply :status status)))
              ((symbol-function 'ws-send)
               (lambda (_process data)
                 (plist-put reply :body
                            (json-parse-string data :object-type 'alist))))
              ((symbol-function 'process-send-string)
               (lambda (_process string)
                 (plist-put reply :sent
                            (append (plist-get reply :sent) (list string))))))
      (plist-put reply :thrown
                 (catch 'close-connection
                   (claude-code-ide-mcp-http-server--handle-post request)
                   :no-throw)))
    reply))

(ert-deftest claude-code-ide-mcp-routing-test-content-length ()
  "The one Content-Length parser gives a number, or a refusal.
Only plain digits are a length; a GET without the header has none."
  (should (equal 42 (claude-code-ide-mcp-http-server--body-length
                     "POST" '((:CONTENT-LENGTH . "42")))))
  (should (equal 0 (claude-code-ide-mcp-http-server--body-length "GET" nil)))
  (should (equal 411 (car (claude-code-ide-mcp-http-server--body-length "POST" nil))))
  (dolist (value '(" 0 " "12abc" "-1" "+1" "1.0" ""))
    (should (equal 400 (car (claude-code-ide-mcp-http-server--body-length
                             "POST" (list (cons :CONTENT-LENGTH value))))))))

(ert-deftest claude-code-ide-mcp-routing-test-handler-short-body ()
  "The handler never parses a body that is shorter than its Content-Length.
It answers 400 at once, and no tool runs."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let* ((ran nil)
           (claude-code-ide-mcp-server-tools
            (list (list :function (lambda () (setq ran t) "cci-test")
                        :name "cci_test_tool" :description "cci-test" :args nil)))
           (body (json-encode '((jsonrpc . "2.0") (id . 41) (method . "tools/call")
                                (params . ((name . "cci_test_tool"))))))
           (request (make-claude-code-ide-mcp-routing-tests--parsed-request
                     :process 'cci-test-process
                     :headers `((:POST . "/mcp/cci-test-cowork")
                                (:CONTENT-TYPE . "application/json")
                                (:CONTENT-LENGTH . ,(number-to-string (string-bytes body))))
                     :body (substring body 0 10)))
           (reply (claude-code-ide-mcp-routing-tests--post-parsed request)))
      (should (equal 400 (plist-get reply :status)))
      (should-not (eq :keep-alive (plist-get reply :thrown)))
      (should-not ran))))

(ert-deftest claude-code-ide-mcp-routing-test-body-multibyte-length ()
  "Content-Length counts bytes, not characters.
A body with non-ASCII text is complete when it has that many bytes."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let* ((body (encode-coding-string
                  (json-encode '((jsonrpc . "2.0") (id . 43) (method . "initialize")
                                 (params . ((note . "cci-test \u00e9\u2603")))))
                  'utf-8))
           (request (make-claude-code-ide-mcp-routing-tests--parsed-request
                     :process 'cci-test-process
                     :headers `((:POST . "/mcp/cci-test-cowork")
                                (:CONTENT-TYPE . "application/json")
                                (:CONTENT-LENGTH . ,(number-to-string (length body))))
                     :body body))
           (reply (claude-code-ide-mcp-routing-tests--post-parsed request)))
      (should (> (length body) (length (decode-coding-string body 'utf-8))))
      (should (equal 200 (plist-get reply :status)))
      (should (equal 43 (alist-get 'id (plist-get reply :body)))))))

;;; The reader of whole requests

;; These tests use a real local server process with the filter and
;; the sentinel of the MCP server, and a stand-in for `ws-filter' that
;; records each request it gets.  They do not need web-server.

(defvar claude-code-ide-mcp-routing-tests--passed nil
  "The requests that the stand-in for `ws-filter' got, newest first.")

(defun claude-code-ide-mcp-routing-tests--stand-in-ws-filter (process data)
  "Record DATA, answer 200 on PROCESS and close it, as web-server does."
  (push data claude-code-ide-mcp-routing-tests--passed)
  (process-send-string process "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
  (delete-process process))

(defmacro claude-code-ide-mcp-routing-tests--with-reader (&rest body)
  "Run BODY with a server that reads requests with the MCP filter.
BODY can read the port from the variable `cci-test-port'.  The server,
its connections and their timers end after BODY."
  (declare (indent 0))
  `(let* ((claude-code-ide-mcp-http-server--connections (make-hash-table :test 'eq))
          (claude-code-ide-mcp-routing-tests--passed nil)
          (cci-test-server
           (make-network-process
            :name "cci-test-reader" :server t :host "127.0.0.1" :service 0
            :family 'ipv4 :coding 'binary :noquery t
            :filter #'claude-code-ide-mcp-http-server--filter
            :sentinel #'claude-code-ide-mcp-http-server--sentinel))
          (cci-test-port (process-contact cci-test-server :service)))
     (ignore cci-test-port)
     (unwind-protect
         (cl-letf (((symbol-function 'ws-filter)
                    #'claude-code-ide-mcp-routing-tests--stand-in-ws-filter))
           ,@body)
       (delete-process cci-test-server)
       (let ((processes nil))
         (maphash (lambda (process _) (push process processes))
                  claude-code-ide-mcp-http-server--connections)
         (mapc #'claude-code-ide-mcp-http-server--close processes)))))

(defun claude-code-ide-mcp-routing-tests--client (port)
  "Connect to PORT and return the client process.
The data that it receives is in its property `reply'."
  (let ((client (make-network-process
                 :name "cci-test-client" :host "127.0.0.1" :service port
                 :coding 'binary :noquery t
                 :filter (lambda (process string)
                           (process-put process 'reply
                                        (concat (process-get process 'reply) string))))))
    (process-put client 'reply "")
    client))

(defun claude-code-ide-mcp-routing-tests--reply (client)
  "Return the data that CLIENT has received."
  (process-get client 'reply))

(defun claude-code-ide-mcp-routing-tests--wait-reply (client regexp)
  "Wait until the data of CLIENT matches REGEXP; return non-nil when it does."
  (claude-code-ide-tests--wait-until
   (lambda () (string-match-p regexp (claude-code-ide-mcp-routing-tests--reply client)))))

(defun claude-code-ide-mcp-routing-tests--head (path headers)
  "Return the header section of a POST to PATH with the header lines HEADERS."
  (concat "POST " path " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
          (mapconcat (lambda (line) (concat line "\r\n")) headers "")
          "\r\n"))

(defun claude-code-ide-mcp-routing-tests--json-head (path length &rest headers)
  "Return the header section of a JSON POST to PATH with LENGTH and HEADERS."
  (claude-code-ide-mcp-routing-tests--head
   path (append (list "Content-Type: application/json"
                      (format "Content-Length: %d" length))
                headers)))

(defun claude-code-ide-mcp-routing-tests--connection-in (state)
  "Return a connection of the reader in STATE, or nil."
  (let ((found nil))
    (maphash (lambda (process connection)
               (when (eq (claude-code-ide-mcp-http-server--connection-state connection) state)
                 (setq found (cons process connection))))
             claude-code-ide-mcp-http-server--connections)
    found))

(ert-deftest claude-code-ide-mcp-routing-test-reader-split-body ()
  "The reader gives web-server a request only when its whole body is there.
The client sends the headers, then the body in three parts.  web-server
gets one call with the whole request."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (let* ((body (claude-code-ide-mcp-routing-tests--initialize-body 51))
             (head (claude-code-ide-mcp-routing-tests--json-head
                    "/mcp/cci-test-cowork" (string-bytes body)))
             (client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
        (process-send-string client head)
        (should (claude-code-ide-tests--wait-until
                 (lambda () (claude-code-ide-mcp-routing-tests--connection-in 'body))))
        (dolist (part (list (substring body 0 5) (substring body 5 20)))
          (process-send-string client part)
          (let ((size (+ 5 (if (= (length part) 5) 0 15))))
            (should (claude-code-ide-tests--wait-until
                     (lambda ()
                       (= size (claude-code-ide-mcp-http-server--connection-bytes
                                (cdr (claude-code-ide-mcp-routing-tests--connection-in
                                      'body)))))))))
        (should-not claude-code-ide-mcp-routing-tests--passed)
        (should (string-empty-p (claude-code-ide-mcp-routing-tests--reply client)))
        (process-send-string client (substring body 20))
        (should (claude-code-ide-mcp-routing-tests--wait-reply client "ok\\'"))
        (should (equal (list (concat head body)) claude-code-ide-mcp-routing-tests--passed))))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-whole-request-at-once ()
  "A request that comes in one read goes to web-server at once.
A GET gets 405 at once: only a POST is served."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (let* ((body (claude-code-ide-mcp-routing-tests--initialize-body 52))
             (request (concat (claude-code-ide-mcp-routing-tests--json-head
                               "/mcp/cci-test-cowork" (string-bytes body))
                              body))
             (client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
        (process-send-string client request)
        (should (claude-code-ide-mcp-routing-tests--wait-reply client "ok\\'"))
        (should (equal (list request) claude-code-ide-mcp-routing-tests--passed)))
      (setq claude-code-ide-mcp-routing-tests--passed nil)
      (claude-code-ide-mcp-routing-tests--early-reply
       cci-test-port "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" 405))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-100-continue ()
  "A request with Expect: 100-continue and no body yet gets 100 Continue."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (let* ((body (claude-code-ide-mcp-routing-tests--initialize-body 53))
             (client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
        (process-send-string client (claude-code-ide-mcp-routing-tests--json-head
                                     "/mcp/cci-test-cowork" (string-bytes body)
                                     "Expect: 100-continue"))
        (should (claude-code-ide-mcp-routing-tests--wait-reply
                 client "\\`HTTP/1.1 100 Continue\r\n\r\n\\'"))
        (process-send-string client body)
        (should (claude-code-ide-mcp-routing-tests--wait-reply client "ok\\'"))
        (should (= 1 (length claude-code-ide-mcp-routing-tests--passed)))))))

(defun claude-code-ide-mcp-routing-tests--early-reply (port head status)
  "Send HEAD (no body) to the reader on PORT; check that it answers STATUS at once.
The request never reaches web-server, no body is kept, and the reader
closes its side of the connection.  Return the reply."
  (let ((client (claude-code-ide-mcp-routing-tests--client port)))
    (process-send-string client head)
    (should (claude-code-ide-mcp-routing-tests--wait-reply
             client (format "\\`HTTP/1.1 %d [^\0]*}\\'" status)))
    (should-not claude-code-ide-mcp-routing-tests--passed)
    (should (claude-code-ide-tests--wait-until
             (lambda () (not (process-live-p client)))))
    (claude-code-ide-mcp-routing-tests--reply client)))

(ert-deftest claude-code-ide-mcp-routing-test-reader-checks-before-body ()
  "A request that fails the session check gets 403 before its body.
So does a request with an Origin header; one that is not JSON gets
415.  The client never sends the body; the reply comes anyway."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir)
    (claude-code-ide-mcp-routing-tests--with-reader
      (should (string-match-p
               "Forbidden: unknown session"
               (claude-code-ide-mcp-routing-tests--early-reply cci-test-port
                                                               (claude-code-ide-mcp-routing-tests--json-head "/mcp/cci-test-unknown" 1000)
                                                               403)))
      (should (string-match-p
               "Forbidden: wrong instance secret"
               (claude-code-ide-mcp-routing-tests--early-reply cci-test-port
                                                               (claude-code-ide-mcp-routing-tests--json-head
                                                                "/mcp/cci-test-inst-a" 1000
                                                                (concat claude-code-ide-mcp-server-secret-header ": cci-test-wrong"))
                                                               403)))
      (should (string-match-p
               "Forbidden: missing instance secret"
               (claude-code-ide-mcp-routing-tests--early-reply cci-test-port
                                                               (claude-code-ide-mcp-routing-tests--json-head "/mcp/cci-test-inst-a" 1000)
                                                               403)))
      (claude-code-ide-mcp-routing-tests--early-reply cci-test-port
                                                      (claude-code-ide-mcp-routing-tests--json-head
                                                       "/mcp/cci-test-inst-a" 1000 "Origin: http://cci-test.invalid")
                                                      403)
      (claude-code-ide-mcp-routing-tests--early-reply cci-test-port
                                                      (claude-code-ide-mcp-routing-tests--head
                                                       "/mcp/cci-test-inst-a" '("Content-Type: text/plain" "Content-Length: 1000"))
                                                      415))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-body-limit ()
  "A Content-Length above the limit gets 413 at once."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (let ((claude-code-ide-mcp-http-server-max-body-bytes 100))
        (claude-code-ide-mcp-routing-tests--early-reply cci-test-port
                                                        (claude-code-ide-mcp-routing-tests--json-head "/mcp/cci-test-cowork" 101)
                                                        413)
        ;; At the limit the reader waits for the body
        (let ((client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
          (process-send-string client (claude-code-ide-mcp-routing-tests--json-head
                                       "/mcp/cci-test-cowork" 100))
          (should (claude-code-ide-tests--wait-until
                   (lambda () (claude-code-ide-mcp-routing-tests--connection-in 'body))))
          (should (string-empty-p (claude-code-ide-mcp-routing-tests--reply client))))))
    (should (equal 16777216 (default-value 'claude-code-ide-mcp-http-server-max-body-bytes)))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-length-rules ()
  "A request without a usable Content-Length is refused at once.
Transfer-Encoding and a POST without Content-Length get 411.  A value
that is not a plain non-negative integer, or two different values,
get 400."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (dolist (case '(((("Transfer-Encoding: chunked")) . 411)
                      (nil . 411)
                      ((("Content-Length: 12abc")) . 400)
                      ((("Content-Length: -1")) . 400)
                      ((("Content-Length: 1e3")) . 400)
                      ((("Content-Length: 10" "Content-Length: 11")) . 400)))
        (claude-code-ide-mcp-routing-tests--early-reply cci-test-port
                                                        (claude-code-ide-mcp-routing-tests--head
                                                         "/mcp/cci-test-cowork"
                                                         (cons "Content-Type: application/json" (caar case)))
                                                        (cdr case))))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-time-limit ()
  "A connection whose request is not complete in time gets 408 and is closed.
Before the limit it stays.  A connection that sends nothing is closed
too.  The test runs on the virtual clock."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (claude-code-ide-tests--call-with-clock
       (lambda ()
         (let ((client (claude-code-ide-mcp-routing-tests--client cci-test-port))
               (silent (claude-code-ide-mcp-routing-tests--client cci-test-port)))
           (process-send-string client (claude-code-ide-mcp-routing-tests--json-head
                                        "/mcp/cci-test-cowork" 100))
           (should (claude-code-ide-tests--wait-until
                    (lambda () (and (claude-code-ide-mcp-routing-tests--connection-in 'body)
                                    (= 2 (hash-table-count
                                          claude-code-ide-mcp-http-server--connections))))
                    5))
           (let ((processes (hash-table-keys claude-code-ide-mcp-http-server--connections)))
             (claude-code-ide-tests--advance-clock
              (- claude-code-ide-mcp-http-server-body-timeout 5))
             (mapc #'claude-code-ide-mcp-http-server--check-time-limit processes)
             (should (= 2 (hash-table-count claude-code-ide-mcp-http-server--connections)))
             (should (string-empty-p (claude-code-ide-mcp-routing-tests--reply client)))
             (claude-code-ide-tests--advance-clock 6)
             (mapc #'claude-code-ide-mcp-http-server--check-time-limit processes)
             (should (= 0 (hash-table-count claude-code-ide-mcp-http-server--connections)))
             (should-not (cl-some #'process-live-p processes)))
           (should (claude-code-ide-mcp-routing-tests--wait-reply client "\\`HTTP/1.1 408 "))
           (should (string-match-p "\\`HTTP/1.1 408 "
                                   (claude-code-ide-mcp-routing-tests--reply silent)))
           (should-not claude-code-ide-mcp-routing-tests--passed)))))
    (should (equal 30 (default-value 'claude-code-ide-mcp-http-server-body-timeout)))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-forgets-closed ()
  "A connection that the client closes is forgotten, with its timer."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (let ((client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
        (process-send-string client (claude-code-ide-mcp-routing-tests--json-head
                                     "/mcp/cci-test-cowork" 100))
        (let ((entry nil))
          (should (claude-code-ide-tests--wait-until
                   (lambda () (setq entry (claude-code-ide-mcp-routing-tests--connection-in
                                           'body)))))
          (delete-process client)
          (should (claude-code-ide-tests--wait-until
                   (lambda () (= 0 (hash-table-count
                                    claude-code-ide-mcp-http-server--connections)))))
          (should-not (memq (claude-code-ide-mcp-http-server--connection-timer (cdr entry))
                            timer-list)))))))

;;; The reader is the authority on the head (second review)

(ert-deftest claude-code-ide-mcp-routing-test-reader-method-case ()
  "A method that is not all upper case gets 400 at once.
web-server matches the method without case and takes \"post\" as a
POST, so the reader must not let such a head pass its POST checks."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      ;; With an Origin and a wrong Content-Type
      (claude-code-ide-mcp-routing-tests--early-reply
       cci-test-port
       (concat "post /mcp/cci-test-cowork HTTP/1.1\r\nOrigin: http://cci-test.invalid\r\n"
               "Content-Type: text/plain\r\nContent-Length: 3\r\n\r\n")
       400)
      ;; Without Content-Length, then a part of a body
      (let* ((head (concat "post /mcp/cci-test-cowork HTTP/1.1\r\n"
                           "Content-Type: application/json\r\n\r\n"))
             (reply (claude-code-ide-mcp-routing-tests--early-reply
                     cci-test-port (concat head "{\"a\":") 400)))
        (should (string-match-p "method" reply)))
      (let ((head (concat "Post /mcp/cci-test-cowork HTTP/1.1\r\n"
                          "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")))
        (claude-code-ide-mcp-routing-tests--early-reply cci-test-port head 400)))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-lone-line-break ()
  "A head with a lone CR or LF outside CRLF line breaks gets 400 at once.
web-server would read the text after a lone LF as a new line, for
example as a request line \"POST /mcp/…\" that the reader never saw."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (claude-code-ide-mcp-routing-tests--early-reply
       cci-test-port
       (concat "GET /x HTTP/1.1\r\nFoo: bar\nPOST /mcp/cci-test-cowork HTTP/1.1\r\n"
               "Content-Type: application/json\r\n\r\n{\"a\":")
       400)
      (claude-code-ide-mcp-routing-tests--early-reply
       cci-test-port
       (concat "GET /x HTTP/1.1\r\nFoo: bar\rBaz: 1\r\n\r\n")
       400))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-strict-header-lines ()
  "A header line that web-server would read in another way gets 400.
web-server reads only NAME: VALUE with one space; the reader takes
the value as web-server does, so a Content-Length with extra space is
not a plain integer for both."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (dolist (line '("Content-Length:2" "Content-Length:  2" "Content-Length: 2 "
                      "Content-Length : 2" "Bad header"))
        (claude-code-ide-mcp-routing-tests--early-reply
         cci-test-port
         (claude-code-ide-mcp-routing-tests--head
          "/mcp/cci-test-cowork" (list "Content-Type: application/json" line))
         400)))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-form-types ()
  "A multipart or form Content-Type gets 415 at once.
web-server parses such a body in its own way and can wait for more
data that never comes.  (A path that is not served gets 404 first.)"
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (dolist (type '("multipart/form-data; boundary=zz"
                      "application/x-www-form-urlencoded"
                      "Multipart/Mixed; boundary=zz"))
        (should (string-match-p
                 "Multipart and form bodies"
                 (claude-code-ide-mcp-routing-tests--early-reply
                  cci-test-port
                  (concat "POST /mcp/cci-test-cowork HTTP/1.1\r\nContent-Type: " type
                          "\r\nContent-Length: 5\r\n\r\n")
                  415)))))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-closes-unanswered ()
  "A connection that web-server leaves open without a reply is closed.
The client gets 400, and the reader forgets the connection."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (cl-letf (((symbol-function 'ws-filter)
                 (lambda (_process data)
                   (push data claude-code-ide-mcp-routing-tests--passed))))
        (let ((client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
          (process-send-string client (concat (claude-code-ide-mcp-routing-tests--json-head
                                               "/mcp/cci-test-cowork" 2)
                                              "{}"))
          (should (claude-code-ide-mcp-routing-tests--wait-reply client "\\`HTTP/1.1 400 "))
          (should (claude-code-ide-tests--wait-until
                   (lambda () (not (process-live-p client)))))
          (should (= 1 (length claude-code-ide-mcp-routing-tests--passed)))
          (should (claude-code-ide-tests--wait-until
                   (lambda () (= 0 (hash-table-count
                                    claude-code-ide-mcp-http-server--connections))))))))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-pipelined ()
  "web-server gets the head and exactly Content-Length bytes of body.
Bytes after the body (a pipelined request) are dropped, in the same
read and in later reads, and the first request gets its reply."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (let* ((head (claude-code-ide-mcp-routing-tests--json-head "/mcp/cci-test-cowork" 7))
             (extra "POST /mcp/cci-test-cowork HTTP/1.1\r\n\r\n")
             (client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
        (process-send-string client (concat head "{\"a\":1}" extra))
        (should (claude-code-ide-mcp-routing-tests--wait-reply client "ok\\'"))
        (should (equal (list (concat head "{\"a\":1}"))
                       claude-code-ide-mcp-routing-tests--passed)))
      (setq claude-code-ide-mcp-routing-tests--passed nil)
      (let* ((head (claude-code-ide-mcp-routing-tests--json-head "/mcp/cci-test-cowork" 7))
             (client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
        (process-send-string client (concat head "{\"a\""))
        (should (claude-code-ide-tests--wait-until
                 (lambda () (claude-code-ide-mcp-routing-tests--connection-in 'body))))
        (process-send-string client ":1}GET / HTTP/1.1\r\n\r\n")
        (should (claude-code-ide-mcp-routing-tests--wait-reply client "ok\\'"))
        (should (equal (list (concat head "{\"a\":1}"))
                       claude-code-ide-mcp-routing-tests--passed))))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-header-limit-one-read ()
  "The header limit holds also when the whole head comes in one read."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (claude-code-ide-mcp-routing-tests--early-reply
       cci-test-port
       (claude-code-ide-mcp-routing-tests--json-head
        "/mcp/cci-test-cowork" 2
        (concat "X-Cci-Test: " (make-string (* 70 1024) ?a)))
       431))))

(ert-deftest claude-code-ide-mcp-routing-test-handler-length-parser ()
  "The handler reads Content-Length with the parser of the reader.
A value that the reader refuses (here one with a space before the
digits, as web-server stores \"Content-Length:  3\") gets 400 from the
handler too, and the body is not parsed."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (dolist (value '(" 3" "3 " "+3" "3.0"))
      (let* ((request (make-claude-code-ide-mcp-routing-tests--parsed-request
                       :process 'cci-test-process
                       :headers `((:POST . "/mcp/cci-test-cowork")
                                  (:CONTENT-TYPE . "application/json")
                                  (:CONTENT-LENGTH . ,value))
                       :body "abc"))
             (reply (claude-code-ide-mcp-routing-tests--post-parsed request)))
        (should (equal 400 (plist-get reply :status)))
        (should (consp (claude-code-ide-mcp-http-server--body-length
                        "POST" (list (cons :CONTENT-LENGTH value)))))))))

(defun claude-code-ide-mcp-routing-tests--handler-ws-filter (process data)
  "A stand-in for `ws-filter' that runs the real POST handler on DATA.
It parses DATA with the reader, calls the handler with a stand-in
request on PROCESS, sends the reply and closes PROCESS."
  (push data claude-code-ide-mcp-routing-tests--passed)
  (let* ((end (string-search "\r\n\r\n" data))
         (parsed (claude-code-ide-mcp-http-server--parse-head (substring data 0 end)))
         (request (make-claude-code-ide-mcp-routing-tests--parsed-request
                   :process process
                   :headers (cons (cons :POST (nth 1 parsed)) (nth 2 parsed))
                   :body (substring data (+ end 4))))
         (reply (claude-code-ide-mcp-routing-tests--post-parsed request)))
    (process-send-string process (format "HTTP/1.1 %d X\r\n\r\n%s"
                                         (plist-get reply :status)
                                         (json-encode (plist-get reply :body))))
    (delete-process process)))

(ert-deftest claude-code-ide-mcp-routing-test-reader-one-session-check ()
  "A request through the reader runs the session check once.
The handler uses the result of the reader; it does not check, or read
the coordinator credential, a second time."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (let* ((checks 0)
             (real-check (symbol-function 'claude-code-ide-mcp-server-check-request))
             (body (claude-code-ide-mcp-routing-tests--initialize-body 61))
             (client nil))
        (cl-letf (((symbol-function 'ws-filter)
                   #'claude-code-ide-mcp-routing-tests--handler-ws-filter)
                  ((symbol-function 'claude-code-ide-mcp-server-check-request)
                   (lambda (&rest args)
                     (setq checks (1+ checks))
                     (apply real-check args))))
          (setq client (claude-code-ide-mcp-routing-tests--client cci-test-port))
          (process-send-string client (concat (claude-code-ide-mcp-routing-tests--json-head
                                               "/mcp/cci-test-cowork" (string-bytes body))
                                              body))
          (should (claude-code-ide-mcp-routing-tests--wait-reply client "}\\'"))
          (should (string-prefix-p "HTTP/1.1 200" (claude-code-ide-mcp-routing-tests--reply client)))
          (should (string-match-p "\"id\":61" (claude-code-ide-mcp-routing-tests--reply client)))
          (should (= 1 checks)))))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-head-functions ()
  "A function of `claude-code-ide-mcp-http-server-head-functions' can refuse.
It runs on the parsed head before any body is read.  A refusal gives
its status at once; nil lets the request pass; an error refuses with
500."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (let* ((seen nil)
             (claude-code-ide-mcp-http-server-head-functions
              (list (lambda (method path headers)
                      (push (list method path) seen)
                      (unless (equal (cdr (assq :X-CCI-TEST-TOKEN headers)) "cci-test-good")
                        '(403 . "cci-test bad token"))))))
        (should (string-match-p
                 "Forbidden: cci-test bad token"
                 (claude-code-ide-mcp-routing-tests--early-reply
                  cci-test-port
                  (claude-code-ide-mcp-routing-tests--json-head "/mcp/cci-test-cowork" 1000)
                  403)))
        (should (equal '(("POST" "/mcp/cci-test-cowork")) seen))
        (let* ((body (claude-code-ide-mcp-routing-tests--initialize-body 62))
               (client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
          (process-send-string client (concat (claude-code-ide-mcp-routing-tests--json-head
                                               "/mcp/cci-test-cowork" (string-bytes body)
                                               "X-Cci-Test-Token: cci-test-good")
                                              body))
          (should (claude-code-ide-mcp-routing-tests--wait-reply client "ok\\'"))))
      (let ((claude-code-ide-mcp-http-server-head-functions
             (list (lambda (&rest _) (error "cci-test failure")))))
        (setq claude-code-ide-mcp-routing-tests--passed nil)
        (claude-code-ide-mcp-routing-tests--early-reply
         cci-test-port
         (claude-code-ide-mcp-routing-tests--json-head "/mcp/cci-test-cowork" 2)
         500)))))

;;; Resource limits of the reader (gate review)

(defvar claude-code-ide-mcp-http-server-max-connections)

(defun claude-code-ide-mcp-routing-tests--unique-names (count)
  "Return COUNT header names that no code uses, made at run time.
The names are strings; making them interns no symbol."
  (let ((stamp (format "%d%d" (emacs-pid) (random 1000000000))))
    (cl-loop for i below count
             collect (format "X-Cci-Test-Unique-%s-%d" stamp i))))

(defun claude-code-ide-mcp-routing-tests--interned (names)
  "Return the NAMES whose header keyword or name is in the obarray."
  (cl-remove-if-not (lambda (name)
                      (or (intern-soft (concat ":" (upcase name)))
                          (intern-soft (upcase name))
                          (intern-soft name)))
                    names))

(ert-deftest claude-code-ide-mcp-routing-test-reader-no-intern ()
  "The reader interns no header name of the input.
Not for a refused request, and not for one that it passes on."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (let ((refused (claude-code-ide-mcp-routing-tests--unique-names 20))
            (passed (claude-code-ide-mcp-routing-tests--unique-names 20)))
        (claude-code-ide-mcp-routing-tests--early-reply
         cci-test-port
         (apply #'claude-code-ide-mcp-routing-tests--json-head "/mcp/cci-test-unknown" 10
                (mapcar (lambda (name) (concat name ": 1")) refused))
         403)
        (let* ((body (claude-code-ide-mcp-routing-tests--initialize-body 71))
               (client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
          (process-send-string
           client
           (concat (apply #'claude-code-ide-mcp-routing-tests--json-head
                          "/mcp/cci-test-cowork" (string-bytes body)
                          (mapcar (lambda (name) (concat name ": 1")) passed))
                   body))
          (should (claude-code-ide-mcp-routing-tests--wait-reply client "ok\\'")))
        (should-not (claude-code-ide-mcp-routing-tests--interned refused))
        (should-not (claude-code-ide-mcp-routing-tests--interned passed))))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-header-count ()
  "A head with more than 100 header lines gets 431 at once."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (claude-code-ide-mcp-routing-tests--early-reply
       cci-test-port
       (apply #'claude-code-ide-mcp-routing-tests--json-head "/mcp/cci-test-cowork" 2
              (cl-loop for i below 99 collect (format "X-Cci-Test-%d: 1" i)))
       431))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-unhandled-routes ()
  "A path or a method that no handler serves is refused before the body.
A path that is not /mcp gets 404 and a method other than POST gets
405, with or without Content-Length; such a request never collects a
body and never reaches web-server."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (pcase-dolist (`(,line . ,status)
                     '(("GET /x HTTP/1.1" . 404)
                       ("POST /x HTTP/1.1" . 404)
                       ("POST /mcpx HTTP/1.1" . 404)
                       ("GET /mcp HTTP/1.1" . 405)
                       ("PUT /mcp/cci-test-cowork HTTP/1.1" . 405)
                       ("GET /mcp/cci-test-cowork HTTP/1.1" . 405)))
        (claude-code-ide-mcp-routing-tests--early-reply
         cci-test-port
         (concat line "\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n")
         status)
        (should-not (claude-code-ide-mcp-routing-tests--connection-in 'body))))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-405-allow ()
  "A 405 reply names the method that the server serves; other replies do not."
  (let ((sent nil))
    (cl-letf (((symbol-function 'process-send-string)
               (lambda (_process string) (push string sent))))
      (claude-code-ide-mcp-http-server--send-status 'cci-test-process 405 "Method not allowed")
      (claude-code-ide-mcp-http-server--send-status 'cci-test-process 404 "Not found"))
    (should (string-match-p "\\`HTTP/1.1 405 [^\r]*\r\n\\(?:[^\r]+\r\n\\)*Allow: POST\r\n" (cadr sent)))
    (should-not (string-match-p "^Allow:" (car sent)))))

(ert-deftest claude-code-ide-mcp-routing-test-reader-max-connections ()
  "Connections above the limit get 503 at once and are closed.
After the open connections close, new ones are served again."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (claude-code-ide-mcp-routing-tests--with-reader
      (let* ((claude-code-ide-mcp-http-server-max-connections 3)
             (open (cl-loop repeat 3 collect
                            (claude-code-ide-mcp-routing-tests--client cci-test-port))))
        (should (claude-code-ide-tests--wait-until
                 (lambda () (= 3 (hash-table-count claude-code-ide-mcp-http-server--connections)))))
        (let ((extra (claude-code-ide-mcp-routing-tests--client cci-test-port)))
          (should (claude-code-ide-mcp-routing-tests--wait-reply extra "\\`HTTP/1.1 503 "))
          (should (claude-code-ide-tests--wait-until (lambda () (not (process-live-p extra))))))
        (should (= 3 (hash-table-count claude-code-ide-mcp-http-server--connections)))
        (mapc #'delete-process open)
        (should (claude-code-ide-tests--wait-until
                 (lambda () (= 0 (hash-table-count claude-code-ide-mcp-http-server--connections)))))
        (let* ((body (claude-code-ide-mcp-routing-tests--initialize-body 72))
               (client (claude-code-ide-mcp-routing-tests--client cci-test-port)))
          (process-send-string client (concat (claude-code-ide-mcp-routing-tests--json-head
                                               "/mcp/cci-test-cowork" (string-bytes body))
                                              body))
          (should (claude-code-ide-mcp-routing-tests--wait-reply client "ok\\'")))))
    (should (equal 32 (default-value 'claude-code-ide-mcp-http-server-max-connections)))))

;;; The real web-server package

;; These tests run only when the web-server package is on the
;; load-path.  ./scripts/compile-and-test.sh adds the newest
;; ~/.emacs.d/elpa/web-server-* folder when there is one.

(defun claude-code-ide-mcp-routing-tests--web-server-p ()
  "Return non-nil when the real web-server package is loaded or can be."
  (and (require 'web-server nil t)
       (fboundp 'ws-start)
       (fboundp 'ws-filter)))

(ert-deftest claude-code-ide-mcp-routing-test-web-server-split-body ()
  "With the real web-server, a body sent after the headers is read.
The client sends the headers, waits until the reader has them, and
then sends the body.  The reply carries the id of the request and a
result, not a parse error."
  (skip-unless (claude-code-ide-mcp-routing-tests--web-server-p))
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let* ((claude-code-ide-mcp-http-server--connections (make-hash-table :test 'eq))
           (started (claude-code-ide-mcp-http-server-start 0))
           (server (car started))
           (body (claude-code-ide-mcp-routing-tests--initialize-body 44))
           (client nil))
      (unwind-protect
          (progn
            (setq client (claude-code-ide-mcp-routing-tests--client (cdr started)))
            (process-send-string client (claude-code-ide-mcp-routing-tests--json-head
                                         "/mcp/cci-test-cowork" (string-bytes body)))
            (should (claude-code-ide-tests--wait-until
                     (lambda () (claude-code-ide-mcp-routing-tests--connection-in 'body))))
            (should (string-empty-p (claude-code-ide-mcp-routing-tests--reply client)))
            (process-send-string client body)
            (should (claude-code-ide-mcp-routing-tests--wait-reply client "}\\'"))
            (let ((reply (claude-code-ide-mcp-routing-tests--reply client)))
              (should (string-prefix-p "HTTP/1.1 200" reply))
              (let ((json (json-parse-string (substring reply (string-match "{" reply))
                                             :object-type 'alist)))
                (should (equal 44 (alist-get 'id json)))
                (should (alist-get 'result json))))
            ;; web-server closed the connection, and the reader forgot it
            (should (claude-code-ide-tests--wait-until
                     (lambda () (= 0 (hash-table-count
                                      claude-code-ide-mcp-http-server--connections))))))
        (when (process-live-p client)
          (delete-process client))
        (claude-code-ide-mcp-http-server-stop server)))))

(ert-deftest claude-code-ide-mcp-routing-test-web-server-early-403 ()
  "With the real web-server, a wrong session gets 403 before its body."
  (skip-unless (claude-code-ide-mcp-routing-tests--web-server-p))
  (claude-code-ide-mcp-routing-tests--with-state
    (let* ((claude-code-ide-mcp-http-server--connections (make-hash-table :test 'eq))
           (started (claude-code-ide-mcp-http-server-start 0))
           (server (car started))
           (client nil))
      (unwind-protect
          (progn
            (setq client (claude-code-ide-mcp-routing-tests--client (cdr started)))
            (process-send-string client (claude-code-ide-mcp-routing-tests--json-head
                                         "/mcp/cci-test-unknown" 5000))
            (should (claude-code-ide-mcp-routing-tests--wait-reply
                     client "\\`HTTP/1.1 403 [^\0]*unknown session[^\0]*}\\'")))
        (when (process-live-p client)
          (delete-process client))
        (claude-code-ide-mcp-http-server-stop server)))))

(defun claude-code-ide-mcp-routing-tests--web-server-probe (parts)
  "Send PARTS to a real MCP server, one per write; return (REPLY . LIVE).
LIVE is non-nil when the connection is still open after the reply
stops.  The session cci-test-cowork must be registered."
  (let* ((claude-code-ide-mcp-http-server--connections (make-hash-table :test 'eq))
         (started (claude-code-ide-mcp-http-server-start 0))
         (client nil))
    (unwind-protect
        (progn
          (setq client (claude-code-ide-mcp-routing-tests--client (cdr started)))
          ;; A refusal can close the connection before the later parts
          (dolist (part parts)
            (ignore-errors (process-send-string client part))
            (accept-process-output nil 0.1))
          (claude-code-ide-tests--wait-until (lambda () (not (process-live-p client))) 5)
          (cons (claude-code-ide-mcp-routing-tests--reply client) (process-live-p client)))
      (when (process-live-p client)
        (delete-process client))
      (claude-code-ide-mcp-http-server-stop (car started)))))

(ert-deftest claude-code-ide-mcp-routing-test-web-server-review-sequences ()
  "The sequences of the second review, against the real web-server.
A lower-case post, a smuggled request line and a multipart GET are
refused and closed; a pipelined request gets its normal reply."
  (skip-unless (claude-code-ide-mcp-routing-tests--web-server-p))
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let ((handled nil))
      (cl-letf (((symbol-function 'claude-code-ide-mcp-http-server--handle-post)
                 (let ((real (symbol-function 'claude-code-ide-mcp-http-server--handle-post)))
                   (lambda (request)
                     (push (ws-body request) handled)
                     (funcall real request)))))
        (pcase-dolist (`(,parts ,status)
                       `((("post /mcp/cci-test-cowork HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"a\":"
                           "1}")
                          400)
                         (("GET /x HTTP/1.1\r\nFoo: bar\nPOST /mcp/cci-test-cowork HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"a\":"
                           "1}")
                          400)
                         (("post /mcp/cci-test-cowork HTTP/1.1\r\nOrigin: http://evil\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\n"
                           "abc")
                          400)
                         ;; A path that is not served gets 404 before the type check
                         (("GET /x HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=zz\r\n\r\n"
                           "more data that goes to pending")
                          404)))
          (let ((result (claude-code-ide-mcp-routing-tests--web-server-probe parts)))
            (should (string-prefix-p (format "HTTP/1.1 %d " status) (car result)))
            (should-not (cdr result))))
        ;; web-server never sees the head of a refused request, so it
        ;; interns none of its header names
        (let ((names (claude-code-ide-mcp-routing-tests--unique-names 20)))
          (should (string-prefix-p
                   "HTTP/1.1 404 "
                   (car (claude-code-ide-mcp-routing-tests--web-server-probe
                         (list (concat "GET /x HTTP/1.1\r\n"
                                       (mapconcat (lambda (name) (concat name ": 1\r\n"))
                                                  names "")
                                       "\r\n"))))))
          (should-not (claude-code-ide-mcp-routing-tests--interned names)))
        (should-not handled)
        (let ((result (claude-code-ide-mcp-routing-tests--web-server-probe
                       (list (concat "POST /mcp/cci-test-cowork HTTP/1.1\r\n"
                                     "Content-Type: application/json\r\nContent-Length: 7\r\n\r\n"
                                     "{\"a\":1}POST /mcp/cci-test-cowork HTTP/1.1\r\n\r\n")))))
          (should (equal '("{\"a\":1}") handled))
          ;; The normal reply to a notification
          (should (string-prefix-p "HTTP/1.1 202" (car result)))
          (should-not (string-match-p "Parse error" (car result))))))))

;;; JSON false and null in tool arguments

(defun claude-code-ide-mcp-routing-tests--call-raw (tool arguments-json)
  "Call TOOL through the cowork session with the raw JSON text ARGUMENTS-JSON.
The body goes as text, so the server's own JSON parse decodes it.
Return the reply plist."
  (claude-code-ide-mcp-routing-tests--post
   "/mcp/cci-test-cowork"
   (format "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"%s\",\"arguments\":%s}}"
           tool arguments-json)))

(ert-deftest claude-code-ide-mcp-routing-test-json-false-and-null ()
  "Through the real parse, a JSON false reaches a tool as :json-false, a null as nil.
Before, false came as :false and null as :null, which are true values."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let ((seen 'none))
      (claude-code-ide-make-tool :function (lambda (&optional flag text on)
                                             (setq seen (list flag text on))
                                             "cci-test ok")
                                 :name "cci_test_raw" :description "cci-test"
                                 :args '((:name "flag" :type boolean :optional t)
                                         (:name "text" :type string :optional t)
                                         (:name "on" :type boolean :optional t)))
      (let ((reply (claude-code-ide-mcp-routing-tests--call-raw
                    "cci_test_raw" "{\"flag\":false,\"text\":null,\"on\":true}")))
        (should (equal (plist-get reply :status) 200)))
      (should (equal seen '(:json-false nil t))))))

(ert-deftest claude-code-ide-mcp-routing-test-handover-tool-false ()
  "The handover tool reads JSON false as false, and a null optional argument as missing.
`\"force\": false' must never skip the safety checks, and
`\"continue\": false' must keep the target waiting."
  (require 'claude-code-ide-handover)
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let* ((spec (cl-find "claude-code-ide-control-handover" claude-code-ide-control--extra-tool-specs
                          :key (lambda (s) (plist-get s :name)) :test #'equal))
           (calls nil))
      ;; The arguments of the real tool, without the coordinator scope
      (claude-code-ide-make-tool :function #'claude-code-ide-handover--mcp-handover
                                 :name "cci_test_handover" :description "cci-test"
                                 :args (plist-get spec :args))
      (cl-letf (((symbol-function 'claude-code-ide-control-call)
                 (lambda (&rest args) (push args calls) (list :status 'running))))
        (should (equal (plist-get (claude-code-ide-mcp-routing-tests--call-raw
                                   "cci_test_handover"
                                   (concat "{\"instance_id\":\"cci-test-src\",\"target_provider\":\"codex\","
                                           "\"force\":false,\"interrupt\":false,\"continue\":false,"
                                           "\"context\":null,\"request_id\":null,\"method\":null}"))
                                  :status)
                       200))
        (should (equal (plist-get (claude-code-ide-mcp-routing-tests--call-raw
                                   "cci_test_handover"
                                   (concat "{\"instance_id\":\"cci-test-src\",\"target_provider\":\"codex\","
                                           "\"force\":true,\"interrupt\":true,\"continue\":true}"))
                                  :status)
                       200))
        (should (equal (plist-get (claude-code-ide-mcp-routing-tests--call-raw
                                   "cci_test_handover"
                                   "{\"instance_id\":\"cci-test-src\",\"target_provider\":\"codex\",\"continue\":null}")
                                  :status)
                       200))
        (let* ((calls (reverse calls))
               (false (nthcdr 3 (nth 0 calls)))
               (true (nthcdr 3 (nth 1 calls)))
               (null (nthcdr 3 (nth 2 calls))))
          (should (= (length calls) 3))
          (should-not (plist-get false :force))
          (should-not (plist-get false :interrupt))
          (should (plist-member false :continue))
          (should-not (plist-get false :continue))
          (should-not (plist-get false :context))
          (should-not (plist-get false :request-id))
          (should (eq (plist-get false :method) 'fresh))
          (should (eq (plist-get true :force) t))
          (should (eq (plist-get true :interrupt) t))
          (should (eq (plist-get true :continue) t))
          ;; A null continue counts as not given
          (should-not (plist-member null :continue)))))))

(ert-deftest claude-code-ide-mcp-routing-test-treesit-info-false ()
  "The tree-sitter tool reads :json-false (and :false) as false for its flags."
  (let ((formatted nil))
    (cl-letf (((symbol-function 'claude-code-ide-mcp-server-get-session-context)
               (lambda (&rest _) (list :project-dir default-directory)))
              ((symbol-function 'treesit-available-p) (lambda () t))
              ((symbol-function 'find-buffer-visiting) (lambda (&rest _) (current-buffer)))
              ((symbol-function 'treesit-parser-list) (lambda (&rest _) '(cci-test-parser)))
              ((symbol-function 'treesit-parser-root-node) (lambda (_parser) 'cci-test-root))
              ((symbol-function 'claude-code-ide-mcp-treesit--format-tree)
               (lambda (&rest _) (setq formatted t) "cci-test tree"))
              ((symbol-function 'treesit-node-at)
               (lambda (&rest _) (throw 'cci-test-node-at 'position))))
      (with-temp-buffer
        (should (equal (claude-code-ide-mcp-treesit-info "/tmp/cci-test.el" nil nil t)
                       "cci-test tree"))
        (setq formatted nil)
        (dolist (false '(:json-false :false))
          (should (eq (catch 'cci-test-node-at
                        (claude-code-ide-mcp-treesit-info "/tmp/cci-test.el" nil nil false))
                      'position))
          (should-not formatted))))))

(ert-deftest claude-code-ide-mcp-routing-test-null-id ()
  "Only a message without the member id is a notification.
JSON-RPC 2.0 allows \"id\": null in a request (it only discourages it),
so such a request gets its normal result or error, with id null."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    ;; No id: a notification, 202 and no body
    (let ((reply (claude-code-ide-mcp-routing-tests--post
                  "/mcp/cci-test-cowork"
                  "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")))
      (should (equal (plist-get reply :status) 202))
      (should-not (plist-get reply :body)))
    ;; id null and a known method: the result, with id null
    (let* ((reply (claude-code-ide-mcp-routing-tests--post
                   "/mcp/cci-test-cowork"
                   "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"initialize\",\"params\":{}}"))
           (body (plist-get reply :body)))
      (should (equal (plist-get reply :status) 200))
      (should (assq 'id body))
      (should (eq (alist-get 'id body) :null))
      (should (alist-get 'result body)))
    ;; id null and an unknown method: the error, with id null
    (let* ((reply (claude-code-ide-mcp-routing-tests--post
                   "/mcp/cci-test-cowork"
                   "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"cci-test/none\"}"))
           (body (plist-get reply :body)))
      (should (equal (plist-get reply :status) 200))
      (should (assq 'id body))
      (should (eq (alist-get 'id body) :null))
      (should (equal (alist-get 'code (alist-get 'error body)) -32601)))))

;;; The handover tool

(ert-deftest claude-code-ide-test-handover-mcp-allow-others ()
  "The handover tool passes allow_others as :allow-others, and never as :force."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-routing-tests--start "cci-test-inst-a" cci-test-dir)
    (claude-code-ide-control--make-tool
     (cl-find "claude-code-ide-control-handover" claude-code-ide-control--extra-tool-specs
              :key (lambda (spec) (plist-get spec :name)) :test #'equal))
    (let* ((coordinator (list (cons :X-EMACS-MCP-COORDINATOR
                                    (claude-code-ide-mcp-server-coordinator-credential))))
           (calls nil)
           (call (lambda (&rest more)
                   (claude-code-ide-mcp-routing-tests--call
                    "/mcp" "claude-code-ide-control-handover"
                    (append '((instance_id . "cci-test-inst-a") (target_provider . "codex")) more)
                    coordinator)
                   (pop calls))))
      (cl-letf (((symbol-function 'claude-code-ide-control-call)
                 (lambda (&rest args) (push args calls) (list :status 'running))))
        (let ((given (funcall call '(allow_others . t))))
          (should (eq (plist-get (nthcdr 3 given) :allow-others) t))
          (should (plist-member (nthcdr 3 given) :force))
          (should-not (plist-get (nthcdr 3 given) :force)))
        (should-not (plist-get (nthcdr 3 (funcall call '(allow_others . :json-false))) :allow-others))
        (should-not (plist-get (nthcdr 3 (funcall call)) :allow-others))))
    (kill-buffer (claude-code-ide-instance-buffer
                  (claude-code-ide-instance-by-id "cci-test-inst-a")))))

(provide 'claude-code-ide-mcp-routing-tests)
;;; claude-code-ide-mcp-routing-tests.el ends here
