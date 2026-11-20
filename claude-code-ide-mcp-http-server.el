;;; claude-code-ide-mcp-http-server.el --- HTTP server for MCP tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Yoav Orot
;; Keywords: ai, claude, mcp, http

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This module implements the HTTP server for the MCP tools server.
;; It uses the web-server package to handle HTTP requests and implements
;; the MCP Streamable HTTP transport protocol.
;;
;; Session IDs are passed via URL paths (e.g., /mcp/session-id) to enable
;; context-aware operations for multiple concurrent Claude sessions.
;; The session of an instance also needs the secret of the instance:
;; /mcp/<instance-id>/<secret>, or the header
;; `claude-code-ide-mcp-server-secret-header'.  A notification gets
;; 202 Accepted with no body.  The filter of the connections
;; (`claude-code-ide-mcp-http-server--filter') gives web-server a request
;; only when its whole body (Content-Length bytes) has arrived, and it
;; refuses a bad request before it reads the body.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'url-parse)
(require 'claude-code-ide-debug)
(require 'claude-code-ide-mcp-server)

(defvar claude-code-ide-mcp-server--current-session-id)

;; Require web-server at runtime to avoid batch mode issues
(unless (featurep 'web-server)
  (condition-case err
      (require 'web-server)
    (error
     (claude-code-ide-debug "Failed to load web-server package: %s" (error-message-string err)))))

;; Web-server declarations
(declare-function ws-process "web-server" (server))
(declare-function ws-start "web-server" (handlers port &optional log-buffer &rest network-args))
(declare-function ws-stop "web-server" (server))
(declare-function ws-send-404 "web-server" (proc &optional info))
(declare-function ws-headers "web-server" (request))
(declare-function ws-body "web-server" (request))
(declare-function ws-send "web-server" (proc msg))
(declare-function ws-response-header "web-server" (proc code &rest headers))
(declare-function ws-filter "web-server" (proc string))

(define-error 'json-rpc-error "JSON-RPC error" 'error)

;;; Server State

(defvar claude-code-ide-mcp-http-server--server nil
  "The web-server instance.")


;;; Helper Functions

(defun claude-code-ide-mcp-http-server--request-path (headers)
  "Return the URL path of the request with HEADERS, or nil.
The web-server package stores the URL path in headers with the
HTTP method as the key (e.g., :POST -> \"/mcp/session-id\")."
  (or (cdr (assoc :POST headers))
      (cdr (assoc :GET headers))))

(defun claude-code-ide-mcp-http-server--split-path (path)
  "Return (ID . SECRET) of the URL PATH /mcp/ID or /mcp/ID/SECRET.
SECRET is nil when the path has no part after ID, and holds every
later part otherwise.  Return nil for a path without ID."
  (when (and path (string-match "\\`/mcp/\\([^/?]+\\)\\(?:/\\([^?]*?\\)\\)?/?\\'" path))
    (let ((secret (match-string 2 path)))
      (cons (match-string 1 path)
            (and secret (not (string-empty-p secret)) secret)))))

(defun claude-code-ide-mcp-http-server--extract-session-id-from-path (headers)
  "Extract session ID from URL path in HEADERS.
The web-server package stores the URL path in headers with the
HTTP method as the key (e.g., :POST -> \"/mcp/session-id\").
Returns the session ID or nil if not found.  The log shows the path
without the secret part."
  (let ((parts (claude-code-ide-mcp-http-server--split-path
                (claude-code-ide-mcp-http-server--request-path headers))))
    (claude-code-ide-mcp-http-server--log-path parts)
    (car parts)))

(defun claude-code-ide-mcp-http-server--log-path (parts)
  "Log the path of PARTS, a value of `claude-code-ide-mcp-http-server--split-path'.
The log never shows the secret."
  (when parts
    (claude-code-ide-debug "MCP request URL: /mcp/%s%s"
                           (car parts) (if (cdr parts) "/<secret>" ""))))

(defun claude-code-ide-mcp-http-server--header (headers name)
  "Return the value of the header NAME in the web-server HEADERS, or nil.
web-server keys a header by its name in upper case, as a keyword."
  (cdr (assq (intern (concat ":" (upcase name))) headers)))

(defun claude-code-ide-mcp-http-server--transport-refusal (headers)
  "Return (STATUS . REASON) when the request with HEADERS must be refused.
Return nil when it may be read.  These checks stop a web page in a
browser, which can send a POST to 127.0.0.1:
- A browser adds an Origin header; local MCP clients send none.
- The body must be declared as application/json.  A web page can send
  that type only after a CORS preflight, which this server never
  answers, and the replies carry no CORS header."
  (let ((origin (claude-code-ide-mcp-http-server--header headers "Origin"))
        (type (claude-code-ide-mcp-http-server--header headers "Content-Type")))
    (cond
     (origin '(403 . "Origin header not allowed"))
     ((not (and (stringp type)
                (string-match-p "\\`[ \t]*application/json[ \t]*\\(?:;.*\\)?\\'"
                                (downcase type))))
      '(415 . "Content-Type must be application/json")))))

(defun claude-code-ide-mcp-http-server--content-length (headers)
  "Return the Content-Length of the request with HEADERS as a number, or nil.
Return nil also when the value is not a plain non-negative integer."
  (let ((value (claude-code-ide-mcp-http-server--header headers "Content-Length")))
    (and (stringp value)
         (string-match-p "\\`[ \t]*[0-9]+[ \t]*\\'" value)
         (string-to-number value))))

;;; Reading a whole request before web-server sees it

(defgroup claude-code-ide-mcp-http-server nil
  "The HTTP transport of the MCP tools server."
  :group 'claude-code-ide-mcp-server
  :prefix "claude-code-ide-mcp-http-server-")

(defcustom claude-code-ide-mcp-http-server-max-body-bytes (* 16 1024 1024)
  "The largest request body, in bytes, that the MCP server reads.
A request with a larger Content-Length gets 413 at once."
  :type 'integer
  :group 'claude-code-ide-mcp-http-server)

(defcustom claude-code-ide-mcp-http-server-body-timeout 30
  "Seconds that a connection may take to send its whole request.
When the time passes, the connection gets 408 and is closed."
  :type 'number
  :group 'claude-code-ide-mcp-http-server)

(defconst claude-code-ide-mcp-http-server--max-header-bytes 65536
  "The largest header section that the MCP server reads.")

(defconst claude-code-ide-mcp-http-server--handled-path "\\`/mcp\\(?:/.*\\)?\\'"
  "The URL paths of the MCP handlers.")

(defconst claude-code-ide-mcp-http-server--reasons
  '((400 . "Bad Request") (403 . "Forbidden") (408 . "Request Timeout")
    (411 . "Length Required") (413 . "Content Too Large")
    (415 . "Unsupported Media Type") (431 . "Request Header Fields Too Large"))
  "The reason phrases of the status codes that the reader sends.")

(cl-defstruct (claude-code-ide-mcp-http-server--connection
               (:constructor claude-code-ide-mcp-http-server--make-connection)
               (:copier nil))
  "The state of a connection of the MCP server.
STATE is `headers' while the headers arrive, `body' while the body
arrives, `refused' after an early reply (later data is dropped), and
`passed' when web-server has the request.  HEAD holds the data up to
the end of the headers and the first part of the body; CHUNKS holds
the later parts of the body, newest first, and BYTES counts the body
bytes."
  (state 'headers) (start 0) (head "") (chunks nil) (bytes 0) (expected 0)
  (timer nil))

(defvar claude-code-ide-mcp-http-server--connections (make-hash-table :test 'eq)
  "The connections of the MCP server, a table from process to state.")

(defun claude-code-ide-mcp-http-server--parse-head (head)
  "Return (METHOD PATH HEADERS) of the header section HEAD, or nil.
HEAD is the text before the empty line.  PATH has no query part.
HEADERS is an alist in the form of web-server: the header name in
upper case, as a keyword, and the value with no outer white space.  A
header that comes more than once has more than one entry."
  (let* ((lines (split-string head "\r\n"))
         (request-line (car lines)))
    (when (string-match "\\`\\([A-Z]+\\) \\([^ ]+\\) HTTP/[0-9.]+\\'" request-line)
      (let ((method (match-string 1 request-line))
            (path (car (split-string (match-string 2 request-line) "?")))
            (headers nil))
        (dolist (line (cdr lines))
          (when (string-match "\\`\\([^:[:space:]]+\\):[ \t]*\\(.*?\\)[ \t]*\\'" line)
            (push (cons (intern (concat ":" (upcase (match-string 1 line))))
                        (match-string 2 line))
                  headers)))
        (list method path (nreverse headers))))))

(defun claude-code-ide-mcp-http-server--body-length (method headers)
  "Return the body length of a request with METHOD and HEADERS.
Return (STATUS . REASON) when the request must be refused:
- 411 for Transfer-Encoding (the server reads only Content-Length),
  and for a POST without Content-Length.
- 400 for a Content-Length that is not a plain non-negative integer,
  or for two different values.
- 413 for a body larger than `claude-code-ide-mcp-http-server-max-body-bytes'."
  (let ((values (delete-dups
                 (mapcar #'cdr (cl-remove-if-not
                                (lambda (header) (eq (car header) :CONTENT-LENGTH))
                                headers)))))
    (cond
     ((assq :TRANSFER-ENCODING headers)
      '(411 . "Transfer-Encoding is not supported; send Content-Length"))
     ((null values)
      (if (equal method "POST") '(411 . "Content-Length required") 0))
     ((or (cdr values)
          (not (string-match-p "\\`[0-9]+\\'" (car values))))
      '(400 . "Bad Content-Length"))
     ((> (string-to-number (car values)) claude-code-ide-mcp-http-server-max-body-bytes)
      '(413 . "Request body too large"))
     (t (string-to-number (car values))))))

(defun claude-code-ide-mcp-http-server--early-refusal (method path headers)
  "Return (STATUS . REASON) for a request that is refused before its body.
METHOD, PATH and HEADERS come from
`claude-code-ide-mcp-http-server--parse-head'.  A POST to an MCP path
must pass `claude-code-ide-mcp-http-server--transport-refusal' and
`claude-code-ide-mcp-server-check-request', which read the path and
the headers only.  Then the body length must be acceptable; see
`claude-code-ide-mcp-http-server--body-length'.  Return nil when the
server may read the body."
  (let ((length (claude-code-ide-mcp-http-server--body-length method headers)))
    (or (and (equal method "POST")
             (string-match-p claude-code-ide-mcp-http-server--handled-path path)
             (or (claude-code-ide-mcp-http-server--transport-refusal headers)
                 (let* ((parts (claude-code-ide-mcp-http-server--split-path path))
                        (check (claude-code-ide-mcp-server-check-request
                                (car parts) (cdr parts)
                                (claude-code-ide-mcp-http-server--header
                                 headers claude-code-ide-mcp-server-secret-header)
                                (claude-code-ide-mcp-http-server--header
                                 headers claude-code-ide-mcp-server-coordinator-header))))
                   (unless (plist-get check :ok)
                     (cons 403 (plist-get check :reason))))))
        (and (consp length) length))))

(defun claude-code-ide-mcp-http-server--send-status (process status reason)
  "Send STATUS with a JSON-RPC error that gives REASON to PROCESS.
The id of the error is null: the reader sends this before it has the
request."
  (let ((body (json-encode
               `((jsonrpc . "2.0") (id . nil)
                 (error . ((code . -32000)
                           (message . ,(if (memq status '(403 415))
                                           (format "Forbidden: %s" reason)
                                         reason))))))))
    (process-send-string
     process
     (format (concat "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
                     "Content-Length: %d\r\nConnection: close\r\n\r\n%s")
             status (alist-get status claude-code-ide-mcp-http-server--reasons "Error")
             (string-bytes body) body))))

(defun claude-code-ide-mcp-http-server--close (process)
  "Forget the connection PROCESS, stop its timer and delete it."
  (let ((connection (gethash process claude-code-ide-mcp-http-server--connections)))
    (when connection
      (when (claude-code-ide-mcp-http-server--connection-timer connection)
        (cancel-timer (claude-code-ide-mcp-http-server--connection-timer connection)))
      (remhash process claude-code-ide-mcp-http-server--connections)))
  (when (process-live-p process)
    (delete-process process)))

(defun claude-code-ide-mcp-http-server--refuse (process connection status reason)
  "Answer STATUS and REASON on PROCESS, the connection of CONNECTION.
The reply goes at once.  Then the server ends its side of the
connection and drops the data that still comes: a close with unread
data would reset the connection, and the client could lose the
reply.  The time limit of the connection still closes it."
  (claude-code-ide-debug "MCP request refused before its body: %d %s" status reason)
  (setf (claude-code-ide-mcp-http-server--connection-state connection) 'refused
        (claude-code-ide-mcp-http-server--connection-head connection) ""
        (claude-code-ide-mcp-http-server--connection-chunks connection) nil)
  (condition-case nil
      (progn
        (claude-code-ide-mcp-http-server--send-status process status reason)
        (process-send-eof process))
    (error (claude-code-ide-mcp-http-server--close process))))

(defun claude-code-ide-mcp-http-server--connection (process)
  "Return the state of the connection PROCESS; make it when there is none.
A new state starts the time limit of the connection."
  (or (gethash process claude-code-ide-mcp-http-server--connections)
      (let ((connection (claude-code-ide-mcp-http-server--make-connection
                         :start (float-time))))
        (setf (claude-code-ide-mcp-http-server--connection-timer connection)
              (run-at-time claude-code-ide-mcp-http-server-body-timeout nil
                           #'claude-code-ide-mcp-http-server--check-time-limit process))
        (puthash process connection claude-code-ide-mcp-http-server--connections)
        connection)))

(defun claude-code-ide-mcp-http-server--check-time-limit (process)
  "Close the connection PROCESS when its time limit has passed.
A request that is still incomplete gets 408 first.  Before the limit,
check again when it passes."
  (let ((connection (gethash process claude-code-ide-mcp-http-server--connections)))
    (when (and connection
               (not (eq (claude-code-ide-mcp-http-server--connection-state connection) 'passed)))
      (let ((left (- (+ (claude-code-ide-mcp-http-server--connection-start connection)
                        claude-code-ide-mcp-http-server-body-timeout)
                     (float-time))))
        (if (> left 0)
            (setf (claude-code-ide-mcp-http-server--connection-timer connection)
                  (run-at-time left nil #'claude-code-ide-mcp-http-server--check-time-limit
                               process))
          (unless (eq (claude-code-ide-mcp-http-server--connection-state connection) 'refused)
            (claude-code-ide-debug "MCP request incomplete after %s s"
                                   claude-code-ide-mcp-http-server-body-timeout)
            (ignore-errors
              (claude-code-ide-mcp-http-server--send-status
               process 408 "Request not complete in time")))
          (setf (claude-code-ide-mcp-http-server--connection-timer connection) nil)
          (claude-code-ide-mcp-http-server--close process))))))

(defun claude-code-ide-mcp-http-server--pass (process connection)
  "Give the whole request of CONNECTION on PROCESS to web-server.
The parts of the body are joined once, here."
  (let ((data (apply #'concat
                     (claude-code-ide-mcp-http-server--connection-head connection)
                     (nreverse (claude-code-ide-mcp-http-server--connection-chunks connection)))))
    (when (claude-code-ide-mcp-http-server--connection-timer connection)
      (cancel-timer (claude-code-ide-mcp-http-server--connection-timer connection)))
    (setf (claude-code-ide-mcp-http-server--connection-state connection) 'passed
          (claude-code-ide-mcp-http-server--connection-head connection) ""
          (claude-code-ide-mcp-http-server--connection-chunks connection) nil
          (claude-code-ide-mcp-http-server--connection-timer connection) nil)
    (unwind-protect
        (ws-filter process data)
      (unless (process-live-p process)
        (remhash process claude-code-ide-mcp-http-server--connections)))))

(defun claude-code-ide-mcp-http-server--headers-done (process connection end)
  "Handle the end of the headers, at END of the head of CONNECTION.
PROCESS is the connection.  Refuse the request at once, or wait for
its body, or give it to web-server."
  (let* ((head (claude-code-ide-mcp-http-server--connection-head connection))
         (parsed (claude-code-ide-mcp-http-server--parse-head (substring head 0 end)))
         (received (- (length head) end 4)))
    (if (not parsed)
        (claude-code-ide-mcp-http-server--refuse process connection 400 "Bad request line")
      (pcase-let* ((`(,method ,path ,headers) parsed)
                   (refusal (claude-code-ide-mcp-http-server--early-refusal
                             method path headers)))
        (if refusal
            (claude-code-ide-mcp-http-server--refuse
             process connection (car refusal) (cdr refusal))
          (let ((expected (claude-code-ide-mcp-http-server--body-length method headers)))
            (setf (claude-code-ide-mcp-http-server--connection-state connection) 'body
                  (claude-code-ide-mcp-http-server--connection-expected connection) expected
                  (claude-code-ide-mcp-http-server--connection-bytes connection) received)
            (when (and (> expected 0) (= received 0)
                       (equal (downcase (or (claude-code-ide-mcp-http-server--header
                                             headers "Expect")
                                            ""))
                              "100-continue"))
              (process-send-string process "HTTP/1.1 100 Continue\r\n\r\n"))
            (when (>= received expected)
              (claude-code-ide-mcp-http-server--pass process connection))))))))

(defun claude-code-ide-mcp-http-server--filter (process string)
  "Collect the request on PROCESS, and give it whole to web-server.
STRING is the new data.  This filter replaces `ws-filter' on the
connections of the MCP server.

web-server (tested with version 20210708.2242) calls the handler as
soon as the headers end, with the part of the body that has arrived
until then; it does not read Content-Length.  A client can send the
headers and the body in two writes; Python's http.client always
does.  So this filter keeps the data until the headers and
Content-Length bytes of body are there, and then calls `ws-filter'
once with all of it.  Every handler of the server thus sees whole
requests, and this filter is the one place that depends on how
web-server reads a request.

The filter refuses a request whose path and headers fail the checks
before it reads the body; see
`claude-code-ide-mcp-http-server--early-refusal'.  The time limit
`claude-code-ide-mcp-http-server-body-timeout' closes a connection
that does not complete its request.  Each part of the body is kept as
it comes and joined once, not copied on each read."
  (let ((connection (claude-code-ide-mcp-http-server--connection process)))
    (pcase (claude-code-ide-mcp-http-server--connection-state connection)
      ('passed (ws-filter process string))
      ('refused nil)
      ('headers
       (let ((head (concat (claude-code-ide-mcp-http-server--connection-head connection)
                           string)))
         (setf (claude-code-ide-mcp-http-server--connection-head connection) head)
         (let ((end (string-search "\r\n\r\n" head)))
           (cond
            (end (claude-code-ide-mcp-http-server--headers-done process connection end))
            ((> (length head) claude-code-ide-mcp-http-server--max-header-bytes)
             (claude-code-ide-mcp-http-server--refuse
              process connection 431 "Request header too large"))))))
      ('body
       (push string (claude-code-ide-mcp-http-server--connection-chunks connection))
       (when (>= (cl-incf (claude-code-ide-mcp-http-server--connection-bytes connection)
                          (length string))
                 (claude-code-ide-mcp-http-server--connection-expected connection))
         (claude-code-ide-mcp-http-server--pass process connection))))))

(defun claude-code-ide-mcp-http-server--sentinel (process event)
  "Handle EVENT of PROCESS, the server process or one of its connections.
A new connection starts its time limit; a closed one is forgotten."
  (cond
   ((process-contact process :server)
    (claude-code-ide-debug "MCP server process event: %s" event)
    (when (string-match-p "\\(exited\\|killed\\|terminated\\)" event)
      (claude-code-ide-debug "MCP server died unexpectedly")))
   ((string-prefix-p "open" event)
    (claude-code-ide-mcp-http-server--connection process))
   ((not (process-live-p process))
    (claude-code-ide-mcp-http-server--close process))))

;;; Public Functions

(defun claude-code-ide-mcp-http-server-start (&optional port)
  "Start the MCP HTTP server on PORT.
If PORT is nil, a random available port is selected.
Returns a cons cell of (server . port)."
  (unless (featurep 'web-server)
    (error "web-server package is not available"))
  (claude-code-ide-debug "Attempting to start MCP server on port %s" (or port "auto"))
  (condition-case err
      (let* ((selected-port (or port 0))  ; 0 means auto-select
             (server (ws-start
                      `(((:GET . "^/mcp\\(/.*\\)?$") . ,#'claude-code-ide-mcp-http-server--handle-get)
                        ((:POST . "^/mcp\\(/.*\\)?$") . ,#'claude-code-ide-mcp-http-server--handle-post))
                      selected-port
                      nil  ; log buffer
                      :host "127.0.0.1")))  ; local only
        (setq claude-code-ide-mcp-http-server--server server)
        ;; Get the actual port from the server's process
        (let* ((process (ws-process server))
               (actual-port (process-contact process :service)))
          (claude-code-ide-debug "MCP server started on port %d" actual-port)
          ;; New connections take the filter and the sentinel of the
          ;; server process: the filter reads whole requests, and the
          ;; sentinel detects crashes and closed connections
          (set-process-filter process #'claude-code-ide-mcp-http-server--filter)
          (set-process-sentinel process #'claude-code-ide-mcp-http-server--sentinel)
          (cons server actual-port)))
    (error
     (claude-code-ide-debug "Failed to start web server: %s" (error-message-string err))
     (signal 'error (list (format "Failed to start web server: %s" (error-message-string err)))))))

(defun claude-code-ide-mcp-http-server-stop (server)
  "Stop the MCP HTTP server SERVER."
  (when server
    (ws-stop server)
    ;; The connections whose request web-server does not have yet
    (let ((processes nil))
      (maphash (lambda (process _) (push process processes))
               claude-code-ide-mcp-http-server--connections)
      (mapc #'claude-code-ide-mcp-http-server--close processes))
    (setq claude-code-ide-mcp-http-server--server nil)))

;;; Request Handlers

(defun claude-code-ide-mcp-http-server--handle-get (request)
  "Handle GET request to /mcp endpoint for SSE fallback."
  ;; For now, return 404 as we're implementing Streamable HTTP only
  ;; This could be extended to support SSE for backward compatibility
  (with-slots (process) request
    (ws-send-404 process)))

(defun claude-code-ide-mcp-http-server--handle-post (request)
  "Handle POST request to /mcp/* endpoints.
Extracts session ID from the URL path and processes the request
with the appropriate session context.  A request for the session of
an instance must carry the secret of that instance, in the path or
in the header `claude-code-ide-mcp-server-secret-header'; else it
gets 403.  See `claude-code-ide-mcp-server-check-request'.  A request
with an Origin header gets 403, and one that is not application/json
gets 415, before its body is read; see
`claude-code-ide-mcp-http-server--transport-refusal'.  The filter
`claude-code-ide-mcp-http-server--filter' makes these checks before
it reads the body too, and gives whole requests only; a body that is
shorter than its Content-Length gets 400 here and is never parsed."
  (claude-code-ide-debug "MCP server received POST request")
  (let ((id nil))  ; bound outside the condition-case so error replies can carry it
    (condition-case err
        (let* ((headers (ws-headers request))
               ;; Extract session ID and secret from URL path
               (parts (claude-code-ide-mcp-http-server--split-path
                       (claude-code-ide-mcp-http-server--request-path headers)))
               (url-session-id (car parts))
               (refusal (claude-code-ide-mcp-http-server--transport-refusal headers)))
          (claude-code-ide-mcp-http-server--log-path parts)
          (when refusal
            (claude-code-ide-debug "MCP request refused: %s" (cdr refusal))
            (claude-code-ide-mcp-http-server--send-json-response
             request (car refusal)
             `((jsonrpc . "2.0")
               (id . nil)
               (error . ((code . -32000)
                         (message . ,(format "Forbidden: %s" (cdr refusal))))))))
          ;; Never parse a part of a body
          (let ((expected (claude-code-ide-mcp-http-server--content-length headers)))
            (when (and expected (< (string-bytes (ws-body request)) expected))
              (claude-code-ide-debug "MCP request body incomplete")
              (claude-code-ide-mcp-http-server--send-json-response
               request 400
               '((jsonrpc . "2.0")
                 (id . nil)
                 (error . ((code . -32000)
                           (message . "Incomplete request body")))))))
          (let* ((body (ws-body request))
                 (check (claude-code-ide-mcp-server-check-request
                         url-session-id
                         (cdr parts)
                         (claude-code-ide-mcp-http-server--header
                          headers claude-code-ide-mcp-server-secret-header)
                         (claude-code-ide-mcp-http-server--header
                          headers claude-code-ide-mcp-server-coordinator-header)))
                 (json-object (json-parse-string body :object-type 'alist))
                 (method (alist-get 'method json-object))
                 (params (alist-get 'params json-object)))
            (setq id (alist-get 'id json-object))

            (claude-code-ide-debug "MCP request - method: %s, id: %s, session-id: %s"
                                   method id url-session-id)

            (cond
             ;; A wrong or missing secret ends the request, also a notification
             ((not (plist-get check :ok))
              (claude-code-ide-debug "MCP request rejected: %s" (plist-get check :reason))
              (claude-code-ide-mcp-http-server--send-json-response
               request 403
               `((jsonrpc . "2.0")
                 (id . ,id)
                 (error . ((code . -32000)
                           (message . ,(format "Forbidden: %s" (plist-get check :reason))))))))
             ;; A notification (no id field) gets 202 Accepted with no body
             ((null id)
              (claude-code-ide-debug "Received notification: %s" method)
              (claude-code-ide-mcp-http-server--send-empty-response request))
             (t
              ;; Process the request with session context
              (let* ((claude-code-ide-mcp-server--current-session-id (plist-get check :key))
                     (claude-code-ide-mcp-server--current-instance-id (plist-get check :instance-id))
                     (claude-code-ide-mcp-server--coordinator-request (plist-get check :coordinator))
                     (result (claude-code-ide-mcp-http-server--dispatch method params)))
                (claude-code-ide-debug "MCP response result computed")
                ;; Send response
                (claude-code-ide-mcp-http-server--send-json-response
                 request 200
                 `((jsonrpc . "2.0")
                   (id . ,id)
                   (result . ,result)))
                (claude-code-ide-debug "MCP response sent"))))))

      (json-parse-error
       (claude-code-ide-mcp-http-server--send-json-error
        request nil -32700 "Parse error"))

      (json-rpc-error
       (claude-code-ide-mcp-http-server--send-json-error
        request id (nth 1 err) (nth 2 err)))

      (quit
       (claude-code-ide-debug "Request cancelled by user (C-<escape>)")
       (claude-code-ide-mcp-http-server--send-json-error
        request id -32001 "Operation cancelled by user"))

      (error
       (claude-code-ide-debug "Error handling request: %s"
                              (error-message-string err))
       (claude-code-ide-mcp-http-server--send-json-error
        request id -32603 (format "Internal error: %s" (error-message-string err)))))))

;;; MCP Protocol Implementation

(defun claude-code-ide-mcp-http-server--dispatch (method params)
  "Dispatch MCP method calls.
METHOD is the JSON-RPC method name.
PARAMS is the parameters alist."
  (pcase method
    ("initialize"
     (claude-code-ide-mcp-http-server--handle-initialize params))
    ("tools/list"
     (claude-code-ide-mcp-http-server--handle-tools-list params))
    ("tools/call"
     (claude-code-ide-mcp-http-server--handle-tools-call params))
    (_
     (signal 'json-rpc-error (list -32601 "Method not found")))))

(defun claude-code-ide-mcp-http-server--handle-initialize (_params)
  "Handle the initialize method."
  `((protocolVersion . "2024-11-05")
    (capabilities . ((tools . ((listChanged . :json-false)))
                     (logging . ,(make-hash-table :test 'equal))))
    (serverInfo . ((name . "claude-code-ide-mcp-tools")
                   (version . "0.1.0")))))

(defun claude-code-ide-mcp-http-server--handle-tools-list (_params)
  "Handle the tools/list method.
Coordinator tools show only for a request with the coordinator
credential."
  (let ((tools (delq nil
                     (mapcar (lambda (spec)
                               (let ((normalized (claude-code-ide--normalize-tool-spec spec)))
                                 (when (or (claude-code-ide-mcp-server-coordinator-request-p)
                                           (not (eq (claude-code-ide-mcp-server-tool-scope normalized)
                                                    'coordinator)))
                                   (claude-code-ide-mcp-http-server--tool-to-mcp normalized))))
                             claude-code-ide-mcp-server-tools))))
    (claude-code-ide-debug "MCP server returning %d tools" (length tools))
    (dolist (tool tools)
      (claude-code-ide-debug "  Tool: %s" (alist-get 'name tool)))
    `((tools . ,tools))))

(defun claude-code-ide-mcp-http-server--handle-tools-call (params)
  "Handle the tools/call method with PARAMS."
  (let* ((tool-name (alist-get 'name params))
         (tool-args (alist-get 'arguments params))
         ;; Find the tool spec by name, handling both formats
         (tool-spec (cl-find-if
                     (lambda (spec)
                       (let ((normalized (claude-code-ide--normalize-tool-spec spec)))
                         (string= (or (plist-get normalized :name)
                                      (symbol-name (plist-get normalized :function)))
                                  tool-name)))
                     claude-code-ide-mcp-server-tools)))

    (unless tool-spec
      (signal 'json-rpc-error (list -32602 (format "Unknown tool: %s" tool-name))))

    (let ((normalized (claude-code-ide--normalize-tool-spec tool-spec)))
      (if (and (eq (claude-code-ide-mcp-server-tool-scope normalized) 'coordinator)
               (not (claude-code-ide-mcp-server-coordinator-request-p)))
          ;; An explicit result, not an error that looks like a failure
          `((content . (((type . "text")
                         (text . ,(json-encode '((status . "unavailable")
                                                 (reason . "coordinator-only"))))))))
        ;; Extract function and args
        (let* ((tool-function (plist-get normalized :function))
               (arg-specs (plist-get normalized :args))
               (args (claude-code-ide-mcp-http-server--validate-args tool-args arg-specs))
               ;; Relative file names resolve in the caller's project, also
               ;; in advice that runs before the tool sets up its context
               (default-directory
                (or (plist-get (claude-code-ide-mcp-server-get-session-context) :project-dir)
                    default-directory)))

          ;; Call the function
          (condition-case err
              (let ((result (apply tool-function args)))
                `((content . (((type . "text")
                               (text . ,(claude-code-ide-mcp-http-server--format-result result)))))))
            (quit
             `((content . (((type . "text")
                            (text . "Operation cancelled by user"))))))
            (error
             `((content . (((type . "text")
                            (text . ,(format "Error: %s" (error-message-string err))))))))))))))

;;; Helper Functions

(defun claude-code-ide-mcp-http-server--tool-to-mcp (tool-spec)
  "Convert TOOL-SPEC to MCP tool format.
TOOL-SPEC should already be normalized."
  (let* ((name (or (plist-get tool-spec :name)
                   (symbol-name (plist-get tool-spec :function))))
         (description (plist-get tool-spec :description))
         (args (plist-get tool-spec :args)))
    `((name . ,name)
      (description . ,description)
      (inputSchema . ((type . "object")
                      (properties . ,(claude-code-ide-mcp-http-server--args-to-schema args))
                      (required . ,(claude-code-ide-mcp-http-server--required-args args)))))))

(defun claude-code-ide-mcp-http-server--args-to-schema (args)
  "Convert ARGS list to JSON Schema properties."
  (if args
      (let ((schema '()))
        (dolist (arg args (nreverse schema))
          (let* ((name (plist-get arg :name))
                 (type (plist-get arg :type))
                 (desc (plist-get arg :description))
                 (prop-schema `((type . ,(if (symbolp type)
                                             (symbol-name type)
                                           type)))))
            ;; Only add description if it's non-nil
            (when desc
              (setq prop-schema (append prop-schema `((description . ,desc)))))
            (push (cons (intern name) prop-schema) schema))))
    ;; Return empty hash table for no args (encodes as {} not [])
    (make-hash-table :test 'equal)))

(defun claude-code-ide-mcp-http-server--required-args (args)
  "Extract required argument names from ARGS."
  (let ((required '()))
    (dolist (arg args)
      ;; In new format, args are required unless marked :optional t
      (unless (plist-get arg :optional)
        (push (plist-get arg :name) required)))
    ;; Return as a vector (JSON array) to ensure proper encoding
    (vconcat (nreverse required))))

(defun claude-code-ide-mcp-http-server--validate-args (args arg-specs)
  "Validate and extract ARGS according to ARG-SPECS.
Returns a list of arguments in the correct order."
  (let ((result '()))
    (dolist (spec arg-specs (nreverse result))
      (let* ((name (plist-get spec :name))
             ;; In new format, args are required unless marked :optional t
             (optional (plist-get spec :optional))
             (value (alist-get (intern name) args)))
        (when (and (not optional) (not value))
          (signal 'json-rpc-error
                  (list -32602 (format "Missing required argument: %s" name))))
        (push value result)))))

(defun claude-code-ide-mcp-http-server--format-result (result)
  "Format RESULT for display to Claude."
  (cond
   ((stringp result) result)
   ((listp result)
    (mapconcat (lambda (item)
                 (format "%s" item))
               result "\n"))
   (t (format "%s" result))))

(defun claude-code-ide-mcp-http-server--send-json-response (request status body)
  "Send JSON response to REQUEST with STATUS and BODY."
  (with-slots (process) request
    ;; No CORS header: a web page must not read the replies
    (let ((headers (list (cons "Content-Type" "application/json"))))
      (apply #'ws-response-header process status headers)
      (ws-send process (json-encode body))
      ;; Close the connection after sending response
      (throw 'close-connection nil))))

(defun claude-code-ide-mcp-http-server--send-empty-response (request)
  "Send `202 Accepted' with no body to REQUEST, a notification.
The MCP Streamable HTTP transport requires this reply.  A client
such as Codex drops the connection when a notification gets a 200
reply with a content type."
  (with-slots (process) request
    (ws-response-header process 202
                        (cons "Content-Length" "0"))
    ;; Close the connection
    (throw 'close-connection nil)))

(defun claude-code-ide-mcp-http-server--send-json-error (request id code message)
  "Send JSON-RPC error response."
  (claude-code-ide-mcp-http-server--send-json-response
   request 200
   `((jsonrpc . "2.0")
     (id . ,id)
     (error . ((code . ,code)
               (message . ,message))))))

(provide 'claude-code-ide-mcp-http-server)
;;; claude-code-ide-mcp-http-server.el ends here
