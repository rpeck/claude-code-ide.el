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
(require 'json)
(require 'claude-code-ide)
(require 'claude-code-ide-mcp)
(require 'claude-code-ide-mcp-server)
(require 'claude-code-ide-mcp-http-server)
(require 'claude-code-ide-emacs-tools)
(require 'claude-code-ide-session-registry)

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
  "The Content-Length header gives a number, or nil when it is absent or bad."
  (should (equal 42 (claude-code-ide-mcp-http-server--content-length
                     '((:CONTENT-LENGTH . "42")))))
  (should (equal 0 (claude-code-ide-mcp-http-server--content-length
                    '((:CONTENT-LENGTH . " 0 ")))))
  (should-not (claude-code-ide-mcp-http-server--content-length nil))
  (should-not (claude-code-ide-mcp-http-server--content-length
               '((:CONTENT-LENGTH . "12abc"))))
  (should-not (claude-code-ide-mcp-http-server--content-length
               '((:CONTENT-LENGTH . "-1")))))

(ert-deftest claude-code-ide-mcp-routing-test-body-after-headers ()
  "A request whose body is not complete waits for the rest of the body.
web-server calls the handler when the headers end, with the part of
the body that has arrived.  The handler then sends no reply, keeps
the connection, and clears the active slot, so that web-server calls
it again with more of the body.  With the whole body, it answers the
request with its own id."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let* ((body (claude-code-ide-mcp-routing-tests--initialize-body 41))
           (headers `((:POST . "/mcp/cci-test-cowork")
                      (:CONTENT-TYPE . "application/json")
                      (:CONTENT-LENGTH . ,(number-to-string (string-bytes body)))))
           (request (make-claude-code-ide-mcp-routing-tests--parsed-request
                     :process 'cci-test-process :headers headers :body "")))
      ;; No body yet, then half of it
      (dolist (part (list "" (substring body 0 (/ (length body) 2))))
        (setf (claude-code-ide-mcp-routing-tests--parsed-request-body request) part
              (claude-code-ide-mcp-routing-tests--parsed-request-active request) t)
        (let ((reply (claude-code-ide-mcp-routing-tests--post-parsed request)))
          (should (eq :keep-alive (plist-get reply :thrown)))
          (should-not (plist-get reply :status))
          (should-not (plist-get reply :sent))
          (should-not (claude-code-ide-mcp-routing-tests--parsed-request-active request))))
      ;; The whole body
      (setf (claude-code-ide-mcp-routing-tests--parsed-request-body request) body)
      (let ((reply (claude-code-ide-mcp-routing-tests--post-parsed request)))
        (should (equal 200 (plist-get reply :status)))
        (should (equal 41 (alist-get 'id (plist-get reply :body))))
        (should (alist-get 'protocolVersion
                           (alist-get 'result (plist-get reply :body))))))))

(ert-deftest claude-code-ide-mcp-routing-test-body-multibyte-length ()
  "Content-Length counts bytes, not characters.
A body with non-ASCII text is complete when it has that many bytes."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let* ((body (encode-coding-string
                  (json-encode '((jsonrpc . "2.0") (id . 43) (method . "initialize")
                                 (params . ((note . "cci-test é☃")))))
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

(ert-deftest claude-code-ide-mcp-routing-test-expect-100-continue ()
  "A request with Expect: 100-continue and no body yet gets 100 Continue.
The reply goes once, before the body: a part of the body gets none."
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let* ((body (claude-code-ide-mcp-routing-tests--initialize-body 42))
           (request (make-claude-code-ide-mcp-routing-tests--parsed-request
                     :process 'cci-test-process
                     :headers `((:POST . "/mcp/cci-test-cowork")
                                (:CONTENT-TYPE . "application/json")
                                (:EXPECT . "100-Continue")
                                (:CONTENT-LENGTH . ,(number-to-string (string-bytes body))))
                     :body "")))
      (let ((reply (claude-code-ide-mcp-routing-tests--post-parsed request)))
        (should (eq :keep-alive (plist-get reply :thrown)))
        (should (equal '("HTTP/1.1 100 Continue\r\n\r\n") (plist-get reply :sent))))
      (setf (claude-code-ide-mcp-routing-tests--parsed-request-body request) (substring body 0 5))
      (should-not (plist-get (claude-code-ide-mcp-routing-tests--post-parsed request) :sent))
      (setf (claude-code-ide-mcp-routing-tests--parsed-request-body request) body)
      (let ((reply (claude-code-ide-mcp-routing-tests--post-parsed request)))
        (should-not (plist-get reply :sent))
        (should (equal 42 (alist-get 'id (plist-get reply :body))))))))

(ert-deftest claude-code-ide-mcp-routing-test-refusal-before-body ()
  "A refused request gets its 403 at once; it does not wait for its body."
  (claude-code-ide-mcp-routing-tests--with-state
    (let* ((request (make-claude-code-ide-mcp-routing-tests--parsed-request
                     :process 'cci-test-process
                     :headers '((:POST . "/mcp/cci-test-cowork")
                                (:ORIGIN . "http://cci-test.invalid")
                                (:CONTENT-TYPE . "application/json")
                                (:CONTENT-LENGTH . "100"))
                     :body ""))
           (reply (claude-code-ide-mcp-routing-tests--post-parsed request)))
      (should (equal 403 (plist-get reply :status)))
      (should-not (eq :keep-alive (plist-get reply :thrown))))))

;;; The real web-server package

;; These tests run only when the web-server package is on the
;; load-path, for example:
;;   emacs -batch -L . -L ~/.emacs.d/elpa/web-server-<version> -l ert \
;;     -l claude-code-ide-tests.el -f ert-run-tests-batch-and-exit
;; or ./scripts/compile-and-test.sh with EMACSLOADPATH set to that
;; folder followed by a colon.

(declare-function ws-requests "web-server" (server))
(declare-function ws-active "web-server" (request))

(defun claude-code-ide-mcp-routing-tests--web-server-p ()
  "Return non-nil when the real web-server package is loaded or can be."
  (and (require 'web-server nil t)
       (fboundp 'ws-start)
       (fboundp 'ws-requests)))

(ert-deftest claude-code-ide-mcp-routing-test-web-server-split-body ()
  "With the real web-server, a body sent after the headers is read.
The client sends the headers, waits until the handler has run on
them, and then sends the body.  The reply carries the id of the
request and a result, not a parse error."
  (skip-unless (claude-code-ide-mcp-routing-tests--web-server-p))
  (claude-code-ide-mcp-routing-tests--with-state
    (claude-code-ide-mcp-server-register-session "cci-test-cowork" cci-test-dir nil)
    (let* ((started (claude-code-ide-mcp-http-server-start 0))
           (server (car started))
           (body (claude-code-ide-mcp-routing-tests--initialize-body 44))
           (reply "")
           (client nil))
      (unwind-protect
          (progn
            (setq client (make-network-process
                          :name "cci-test-client" :host "127.0.0.1" :service (cdr started)
                          :coding 'binary :noquery t
                          :filter (lambda (_process string)
                                    (setq reply (concat reply string)))))
            (process-send-string
             client
             (format (concat "POST /mcp/cci-test-cowork HTTP/1.1\r\n"
                             "Host: 127.0.0.1\r\n"
                             "Content-Type: application/json\r\n"
                             "Content-Length: %d\r\n\r\n")
                     (string-bytes body)))
            ;; The handler has seen the headers when the request is no
            ;; longer active, or when it has answered
            (should (claude-code-ide-tests--wait-until
                     (lambda ()
                       (or (not (string-empty-p reply))
                           (cl-some (lambda (request)
                                      (and (assq :POST (ws-headers request))
                                           (not (ws-active request))))
                                    (ws-requests server))))))
            (should (string-empty-p reply))
            (process-send-string client body)
            (should (claude-code-ide-tests--wait-until
                     (lambda () (string-match-p "}\\'" reply))))
            (should (string-prefix-p "HTTP/1.1 200" reply))
            (let ((json (json-parse-string
                         (substring reply (string-match "{" reply))
                         :object-type 'alist)))
              (should (equal 44 (alist-get 'id json)))
              (should (alist-get 'result json))))
        (when (process-live-p client)
          (delete-process client))
        (claude-code-ide-mcp-http-server-stop server)))))

(provide 'claude-code-ide-mcp-routing-tests)
;;; claude-code-ide-mcp-routing-tests.el ends here
