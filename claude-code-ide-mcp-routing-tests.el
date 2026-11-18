;;; claude-code-ide-mcp-routing-tests.el --- Tests for the MCP tools server routing  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the HTTP transport of the MCP tools server: the reply to
;; notifications.  The file is loaded by claude-code-ide-tests.el,
;; after its mocks.  The web-server package is not needed: the tests
;; mock its request accessors and its reply functions.  All projects,
;; instance IDs and secrets are synthetic.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'claude-code-ide-mcp-server)
(require 'claude-code-ide-mcp-http-server)

;;; Mock requests

(cl-defstruct claude-code-ide-mcp-routing-tests--request
  "A stand-in for the request object of web-server."
  process headers body)

(defun claude-code-ide-mcp-routing-tests--post (path body &optional headers)
  "Send a POST of BODY to PATH through the HTTP handler, with HEADERS.
BODY is a string or an alist, which is encoded as JSON.  HEADERS is
an alist of web-server header keys, such as :X-EMACS-MCP-TOKEN, and
values.  Return a plist with :status, :headers and :body (the parsed
JSON reply, or nil when no body was sent)."
  (let* ((reply (list :status nil :headers nil :body nil))
         (request (make-claude-code-ide-mcp-routing-tests--request
                   :process 'cci-test-process
                   :headers (cons (cons :POST path) headers)
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

;;; Notifications

(ert-deftest claude-code-ide-mcp-routing-test-notification-accepted ()
  "A notification gets 202 Accepted with no body and no content type."
  (let ((reply (claude-code-ide-mcp-routing-tests--post
                "/mcp/cci-test-instance"
                '((jsonrpc . "2.0") (method . "notifications/initialized")))))
    (should (equal (plist-get reply :status) 202))
    (should-not (plist-get reply :body))
    (should-not (assoc "Content-Type" (plist-get reply :headers)))
    (should (equal (cdr (assoc "Content-Length" (plist-get reply :headers))) "0"))))

(ert-deftest claude-code-ide-mcp-routing-test-request-gets-reply ()
  "A request with an ID gets a 200 JSON-RPC reply with the same ID."
  (let ((reply (claude-code-ide-mcp-routing-tests--post
                "/mcp/cci-test-instance"
                '((jsonrpc . "2.0") (id . 7) (method . "initialize")
                  (params . ((protocolVersion . "2024-11-05")))))))
    (should (equal (plist-get reply :status) 200))
    (should (equal (cdr (assoc "Content-Type" (plist-get reply :headers)))
                   "application/json"))
    (should (equal (alist-get 'id (plist-get reply :body)) 7))
    (should (alist-get 'serverInfo (alist-get 'result (plist-get reply :body))))))

(provide 'claude-code-ide-mcp-routing-tests)
;;; claude-code-ide-mcp-routing-tests.el ends here
