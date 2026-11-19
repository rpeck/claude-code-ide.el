;;; claude-code-ide-mcp-server.el --- MCP tools server for Claude Code IDE  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Yoav Orot
;; Keywords: ai, claude, mcp, tools

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

;; This module provides an MCP tools server that exposes Emacs functions
;; to Claude Code.  Unlike the IDE MCP server (which uses WebSocket),
;; this uses HTTP/Streamable HTTP transport and provides access to
;; general Emacs functionality like xref, project navigation, etc.
;;
;; The server lifecycle is managed automatically:
;; - Starts when the first Claude session begins
;; - Stops when the last Claude session ends
;;
;; Each instance gets a secret for each launch generation.  A request
;; for an instance must carry its secret, in the URL path
;; /mcp/<instance-id>/<secret> or in the header
;; `claude-code-ide-mcp-server-secret-header'.  A tool runs in the
;; context of the instance descriptor, not of the selected window.
;; Tools with the scope `coordinator' run only for requests that carry
;; the coordinator credential.  docs/api-mcp.md describes the protocol.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'claude-code-ide-debug)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-instance)

;; Forward declarations
(declare-function ws-process "web-server" (server))
(declare-function claude-code-ide-mcp-http-server-start "claude-code-ide-mcp-http-server" (&optional port))
(declare-function claude-code-ide-mcp-http-server-stop "claude-code-ide-mcp-http-server" (server))
(declare-function claude-code-ide-mcp-session-p "claude-code-ide-mcp" (object))
(declare-function claude-code-ide-mcp-session-session-id "claude-code-ide-mcp" (session))
(declare-function claude-code-ide-mcp--track-active-buffer "claude-code-ide-mcp" ())
(defvar claude-code-ide-mcp--sessions)

;;; Customization

(defgroup claude-code-ide-mcp-server nil
  "MCP tools server settings for Claude Code IDE."
  :group 'claude-code-ide
  :prefix "claude-code-ide-mcp-server-")

(defcustom claude-code-ide-enable-mcp-server nil
  "Enable MCP tools server for exposing Emacs functions to Claude.
When enabled, a separate MCP server will be started to provide
Claude with access to configured Emacs functions."
  :type 'boolean
  :group 'claude-code-ide-mcp-server)

(defcustom claude-code-ide-mcp-server-port nil
  "Port for the MCP tools server.
If nil, a random available port will be selected automatically."
  :type '(choice (const :tag "Auto-select" nil)
                 (integer :tag "Fixed port"))
  :group 'claude-code-ide-mcp-server)

(defcustom claude-code-ide-mcp-server-tools nil
  "Alist of Emacs functions to expose via MCP tools server.
Each entry is (FUNCTION . PLIST) where PLIST contains:
  :description - Human-readable description of the function
  :parameters - List of parameter specifications, each with:
    :name - Parameter name
    :type - Parameter type (string, number, boolean)
    :required - Whether parameter is required
    :description - Parameter description"
  :type '(alist :key-type symbol
                :value-type (plist :key-type keyword
                                   :value-type sexp))
  :group 'claude-code-ide-mcp-server)

(defcustom claude-code-ide-mcp-server-secret-placement 'header
  "Where the generated MCP config puts the secret of an instance.
`header': the URL is /mcp/<instance-id>, and the secret is the value
of the header `claude-code-ide-mcp-server-secret-header'.  The secret
stays out of the argument list of the CLI (what `ps' shows) only for
a provider that passes header values through the environment, as the
Codex provider can.  A provider that puts the whole config on the
command line shows the header too.
`path': the URL is /mcp/<instance-id>/<secret>.  Every local program
that can list processes can then read the secret.
The server accepts the secret in both places, whatever this says."
  :type '(choice (const :tag "In a header" header)
                 (const :tag "In the URL path" path))
  :group 'claude-code-ide-mcp-server)

(defcustom claude-code-ide-mcp-server-extra-headers nil
  "Headers that the generated MCP config adds for every session.
An alist of (NAME . VALUE).  NAME is a string or a symbol.  VALUE is a
string, or a function without arguments that returns the value (for
example one that reads a token file); a nil value drops the header.
`claude-code-ide-mcp-server-get-config' merges these headers with the
secret of the instance into one `headers' entry."
  :type '(alist :key-type (choice string symbol)
                :value-type (choice string function))
  :group 'claude-code-ide-mcp-server)

(defcustom claude-code-ide-mcp-server-coordinator-credential-file nil
  "File that holds the coordinator credential of the MCP tools server.
A request that carries this credential in the header
`claude-code-ide-mcp-server-coordinator-header' can use the tools
with the scope `coordinator'.  The credential is separate from the
secrets of the instances.  Emacs makes the file with mode 0600 when
the server starts and a coordinator tool exists, and accepts it only
while no other user can read it.  This protects against mistakes and
against other local clients, not against an agent that runs as the
same user and reads the file; see docs/api-mcp.md.  An instance with
the role \"coordinator\" gets the credential in its generated MCP
config; no other session does.  The credential stays the same across
Emacs restarts.
nil means the file \"coordinator-credential\" in the report directory
of the session registry (see
`claude-code-ide-session-registry-report-directory')."
  :type '(choice (const :tag "In the report directory" nil) file)
  :group 'claude-code-ide-mcp-server)

(defconst claude-code-ide-mcp-server-secret-header "X-Emacs-MCP-Instance-Secret"
  "The HTTP header that carries the secret of an instance.")

(defconst claude-code-ide-mcp-server-coordinator-header "X-Emacs-MCP-Coordinator"
  "The HTTP header that carries the coordinator credential.")

(defconst claude-code-ide-mcp-server-tool-scopes '(instance coordinator)
  "The values of the :scope key of a tool.")

;;; State Management

(defvar claude-code-ide-mcp-server--server nil
  "The MCP tools server process.")

(defvar claude-code-ide-mcp-server--port nil
  "The port the MCP tools server is running on.")

(defvar claude-code-ide-mcp-server--sessions (make-hash-table :test 'equal)
  "Hash table mapping session IDs to session contexts.
Each entry contains a plist with session information:
  :project-dir - The project directory for the session
  :buffer - The Claude Code buffer
  :last-active-buffer - The last file buffer of its worktree
  :start-time - When the session was started
The session of an instance also has:
  :instance-id - The ID of the instance descriptor
  :generation - The launch generation of the instance
  :secret - The secret that each request must carry")

(defvar claude-code-ide-mcp-server--current-session-id nil
  "The session ID for the current MCP tool request.
This is dynamically bound during tool execution.")

(defvar claude-code-ide-mcp-server--current-instance-id nil
  "The instance ID of the current MCP request, or nil.
This is dynamically bound during tool execution.")

(defvar claude-code-ide-mcp-server--coordinator-request nil
  "Non-nil while a request that carries the coordinator credential runs.")

(defvar claude-code-ide-mcp-server--instance-keys (make-hash-table :test 'equal)
  "Hash table from instance IDs to keys of `claude-code-ide-mcp-server--sessions'.
A request can name a session by its key or by the ID of its instance.")


;;; Tool Definition Functions

(defun claude-code-ide-make-tool (&rest slots)
  "Make a Claude Code IDE tool for MCP use.

The following keyword arguments are available:

NAME: The name of the tool, recommended to be in snake_case.

FUNCTION: The function itself (lambda or symbol) that runs the tool.

DESCRIPTION: A verbose description of what the tool does, how to
call it and what it returns.

ARGS: A list of plists specifying the arguments, or nil for a function that
takes no arguments.  Each plist in ARGS should have the following keys:
- :name - Argument name (string)
- :type - Argument type (symbol: string, number, integer, boolean,
  array, object, null)
- :description - Argument description (string)
- :optional - Whether the argument is optional (boolean, default nil)
- :enum - For enumerated types, a vector of allowed values
- :items - For array types, a plist describing the array items
- :properties - For object types, a plist of property specifications

CATEGORY: A string indicating a category for the tool (optional).

SCOPE: `instance' (the default) or `coordinator'.  A coordinator tool
runs only for a request that carries the coordinator credential (see
`claude-code-ide-mcp-server-coordinator-credential-file').  Other
requests get the result {\"status\": \"unavailable\", \"reason\":
\"coordinator-only\"}, and their tool list does not show the tool.

The tool is automatically added to `claude-code-ide-mcp-server-tools'.
Returns the tool specification for convenience."
  (let ((function (plist-get slots :function))
        (name (plist-get slots :name))
        (description (plist-get slots :description))
        (args (plist-get slots :args))
        (category (plist-get slots :category))
        (scope (plist-get slots :scope)))
    ;; Validate required parameters
    (unless function
      (error "Tool :function is required"))
    (unless name
      (error "Tool :name is required"))
    (unless description
      (error "Tool :description is required"))
    (unless (or (null scope) (memq scope claude-code-ide-mcp-server-tool-scopes))
      (error "Tool :scope must be one of %S, not %S"
             claude-code-ide-mcp-server-tool-scopes scope))

    ;; Build the tool specification
    (let ((spec (list :function function
                      :name name
                      :description description)))
      (when args
        (setq spec (plist-put spec :args args)))
      (when category
        (setq spec (plist-put spec :category category)))
      (when scope
        (setq spec (plist-put spec :scope scope)))
      ;; Add to the tools list
      (add-to-list 'claude-code-ide-mcp-server-tools spec)
      ;; A running server needs the credential file for a new coordinator tool
      (when (and (eq scope 'coordinator) (claude-code-ide-mcp-server-get-port))
        (claude-code-ide-mcp-server-coordinator-credential t))
      ;; Return the spec for convenience
      spec)))

(defun claude-code-ide-mcp-server-tool-scope (tool-spec)
  "Return the scope of TOOL-SPEC: `instance' or `coordinator'.
TOOL-SPEC is a normalized tool specification."
  (or (plist-get tool-spec :scope) 'instance))

;;; Format Detection and Conversion

(defun claude-code-ide--tool-format-p (tool-spec)
  "Determine format of TOOL-SPEC.
Returns `old' for (symbol . plist) format, `new' for plist format."
  (cond
   ;; Old format: (function-symbol :description "..." :parameters ...)
   ((and (consp tool-spec)
         (symbolp (car tool-spec))
         (not (keywordp (car tool-spec))))
    'old)
   ;; New format: (:function fn :name "..." :description "..." :args ...)
   ((and (listp tool-spec)
         (keywordp (car tool-spec)))
    'new)
   (t
    (error "Unknown tool format: %S" tool-spec))))

(defun claude-code-ide--normalize-tool-spec (tool-spec)
  "Convert TOOL-SPEC to normalized format for processing.
Handles both old format: (func :description ... :parameters ...)
and new format: (:function func :name ... :args ...).
Returns a consistent plist format with :args."
  (let ((format (claude-code-ide--tool-format-p tool-spec)))
    (cond
     ((eq format 'old)
      ;; Convert old format to new normalized format with :args
      (let* ((func (car tool-spec))
             (plist (cdr tool-spec))
             (description (plist-get plist :description))
             (parameters (plist-get plist :parameters)))
        ;; Emit deprecation warning
        (message "Warning: Tool '%s' is using deprecated format. Please use `claude-code-ide-make-tool' instead."
                 (symbol-name func))
        (list :function func
              :name (symbol-name func)
              :description description
              :args (claude-code-ide--parameters-to-args parameters))))
     ((eq format 'new)
      ;; New format - already in the right format, just return it
      tool-spec)
     (t
      (error "Cannot normalize tool spec: %S" tool-spec)))))

(defun claude-code-ide--parameters-to-args (parameters)
  "Convert PARAMETERS (old format) to :args (new format).
PARAMETERS is a list of plists with :name, :type, :description, :required.
Returns a list of plists with :name, :type, :description, :optional."
  (mapcar (lambda (param)
            (let ((name (plist-get param :name))
                  (type (plist-get param :type))
                  (description (plist-get param :description))
                  (required (plist-get param :required)))
              ;; Build arg spec
              (let ((arg (list :name name
                               :type (if (stringp type)
                                         (intern type)
                                       type))))
                (when description
                  (setq arg (plist-put arg :description description)))
                (unless required
                  (setq arg (plist-put arg :optional t)))
                ;; Handle additional properties
                (when-let* ((enum (plist-get param :enum)))
                  (setq arg (plist-put arg :enum enum)))
                (when-let* ((items (plist-get param :items)))
                  (setq arg (plist-put arg :items items)))
                (when-let* ((properties (plist-get param :properties)))
                  (setq arg (plist-put arg :properties properties)))
                arg)))
          parameters))

;;; Public Functions

(defun claude-code-ide-mcp-server-ensure-server ()
  "Ensure the MCP tools server is running.
Starts the server if not already running.
Returns the port number on success, nil on failure."
  (when claude-code-ide-enable-mcp-server
    (unless (and claude-code-ide-mcp-server--server
                 claude-code-ide-mcp-server--port
                 (claude-code-ide-mcp-server--server-alive-p))
      (claude-code-ide-mcp-server--start-server))
    claude-code-ide-mcp-server--port))

(defun claude-code-ide-mcp-server-get-port ()
  "Get the port number of the running MCP tools server.
Returns nil if server is not running."
  (when (and claude-code-ide-mcp-server--server
             claude-code-ide-mcp-server--port
             (claude-code-ide-mcp-server--server-alive-p))
    claude-code-ide-mcp-server--port))

(defun claude-code-ide-mcp-server-session-started (&optional session-id project-dir buffer)
  "Notify that a Claude session has started.
If SESSION-ID and PROJECT-DIR are provided, register the session.
BUFFER may be nil when the terminal has not been created yet; use
`claude-code-ide-mcp-server-update-session-buffer' once it exists.
The server lifecycle follows the registered-session table, so an
unbalanced end call cannot stop the server under a live session."
  (when (and session-id project-dir)
    (claude-code-ide-mcp-server-register-session session-id project-dir buffer))
  (claude-code-ide-debug "MCP session started. Count: %d"
                         (hash-table-count claude-code-ide-mcp-server--sessions)))

(defun claude-code-ide-mcp-server-session-ended (&optional session-id)
  "Notify that the Claude session SESSION-ID has ended.
Unregisters the session and stops the server when none remain.
Idempotent: ending an unknown or already-ended session is a no-op."
  (when session-id
    (claude-code-ide-mcp-server-unregister-session session-id))
  (claude-code-ide-debug "MCP session ended. Count: %d"
                         (hash-table-count claude-code-ide-mcp-server--sessions))
  (when (and claude-code-ide-mcp-server--server
             (= 0 (hash-table-count claude-code-ide-mcp-server--sessions)))
    (claude-code-ide-mcp-server--stop-server)))

(defun claude-code-ide-mcp-server-update-session-buffer (session-id buffer)
  "Set the terminal BUFFER of the registered session SESSION-ID."
  (when-let* ((session (gethash session-id claude-code-ide-mcp-server--sessions)))
    ;; Store the result: plist-put only mutates in place when the key
    ;; already exists in the list
    (puthash session-id (plist-put session :buffer buffer)
             claude-code-ide-mcp-server--sessions)))

(defun claude-code-ide-mcp-server-get-config (&optional session-id)
  "Get the MCP configuration for the tools server.
If SESSION-ID is provided, the URL names that session.  For a session
of an instance, the URL names the instance ID and the config carries
the secret of the instance, as `claude-code-ide-mcp-server-secret-placement'
says: in the header `claude-code-ide-mcp-server-secret-header', or as
the last part of the URL path.  Other sessions keep the URL
/mcp/<session-id> and get no secret.
The headers of `claude-code-ide-mcp-server-extra-headers' come first;
the secret header comes last and wins over one of the same name.
An instance whose descriptor has the role \"coordinator\" also gets
the coordinator credential in the header
`claude-code-ide-mcp-server-coordinator-header' (made when missing).
No other session ever gets it.
Returns an alist suitable for JSON encoding."
  (when-let* ((port (claude-code-ide-mcp-server-get-port)))
    (let* ((key (and session-id (claude-code-ide-mcp-server--resolve-key session-id)))
           (entry (and key (gethash key claude-code-ide-mcp-server--sessions)))
           (instance-id (plist-get entry :instance-id))
           (secret (plist-get entry :secret))
           (credential (and (claude-code-ide-mcp-server--coordinator-instance-p entry)
                            (claude-code-ide-mcp-server-coordinator-credential t)))
           (in-path (and secret (eq claude-code-ide-mcp-server-secret-placement 'path)))
           (path (cond
                  ((and instance-id in-path) (format "/mcp/%s/%s" instance-id secret))
                  (instance-id (format "/mcp/%s" instance-id))
                  (session-id (format "/mcp/%s" session-id))
                  (t "/mcp")))
           (url (format "http://localhost:%d%s" port path))
           (headers (claude-code-ide-mcp-server--merge-header-lists
                     (list (claude-code-ide-mcp-server--extra-headers)
                           (and credential
                                `((,(intern claude-code-ide-mcp-server-coordinator-header)
                                   . ,credential)))
                           (and secret (not in-path)
                                `((,(intern claude-code-ide-mcp-server-secret-header)
                                   . ,secret))))))
           (config `((type . "http")
                     (url . ,url))))
      (when headers
        (setq config (append config `((headers . ,headers)))))
      `((mcpServers . ((emacs-tools . ,config)))))))

(defun claude-code-ide-mcp-server--coordinator-instance-p (entry)
  "Return non-nil when the session ENTRY belongs to a coordinator instance.
That is: the descriptor of its launch has the role \"coordinator\"."
  (when-let* ((instance (claude-code-ide-mcp-server--entry-instance entry))
              (role (claude-code-ide-instance-role instance)))
    (equal (format "%s" role) "coordinator")))

(defun claude-code-ide-mcp-server--extra-headers ()
  "Return `claude-code-ide-mcp-server-extra-headers' with the values computed.
A value that is a function is called; a nil result drops the header."
  (delq nil
        (mapcar (lambda (header)
                  (let* ((value (cdr header))
                         (value (if (functionp value) (funcall value) value)))
                    (when value
                      (cons (if (stringp (car header)) (intern (car header)) (car header))
                            (format "%s" value)))))
                claude-code-ide-mcp-server-extra-headers)))

(defun claude-code-ide-mcp-server--merge-header-lists (lists)
  "Merge the header alists of LISTS, in order, into one alist.
A later header with the same name (case does not matter) replaces an
earlier one at its own position."
  (let ((merged nil))
    (dolist (headers lists)
      (dolist (header headers)
        (let ((name (downcase (format "%s" (car header)))))
          (setq merged (cl-remove-if (lambda (old)
                                       (string= (downcase (format "%s" (car old))) name))
                                     merged))
          (setq merged (append merged (list header))))))
    merged))

(defun claude-code-ide-mcp-server--merge-config-headers (config)
  "Return CONFIG with at most one `headers' entry in each server.
Use `claude-code-ide-mcp-server-extra-headers' to add headers.  An
older way is an advice of `claude-code-ide-mcp-server-get-config' that
appends a second `headers' entry, for example a global token.  A JSON
reader keeps only the last of two equal keys, so the secret of the
instance would be lost.  This merges the entries in order; a later
header with the same name wins."
  (if (not (and (consp config) (assq 'mcpServers config)))
      config
    (mapcar
     (lambda (top)
       (if (not (eq (car-safe top) 'mcpServers))
           top
         (cons 'mcpServers
               (mapcar #'claude-code-ide-mcp-server--merge-server-headers (cdr top)))))
     config)))

(defun claude-code-ide-mcp-server--merge-server-headers (server)
  "Return SERVER, a (NAME . ALIST) cell, with one `headers' entry."
  (let* ((alist (and (consp server) (listp (cdr server)) (cdr server)))
         (header-lists (delq nil (mapcar (lambda (cell)
                                           (and (eq (car-safe cell) 'headers)
                                                (cdr cell)))
                                         alist))))
    (if (< (length header-lists) 2)
        server
      (cons (car server)
            (append (cl-remove-if (lambda (cell) (eq (car-safe cell) 'headers)) alist)
                    (list (cons 'headers
                                (claude-code-ide-mcp-server--merge-header-lists
                                 header-lists))))))))

;; Compatibility with user advice that appends a `headers' entry, such as
;; the token advice of rp-emacs-mcp.el.  The body of `get-config' cannot
;; see what an advice adds after it returns, so only an advice can merge
;; it.  This one is the outermost (depth -100): it runs after every other
;; advice, also one that is added later.
(advice-add 'claude-code-ide-mcp-server-get-config :filter-return
            #'claude-code-ide-mcp-server--merge-config-headers
            '((depth . -100)))

(defun claude-code-ide-mcp-server-get-tool-names (&optional prefix)
  "Get a list of all registered MCP tool names.
If PREFIX is provided, prepend it to each tool name.
This is useful for generating --allowedTools lists."
  (mapcar (lambda (tool-spec)
            (let* ((normalized (claude-code-ide--normalize-tool-spec tool-spec))
                   (tool-name (or (plist-get normalized :name)
                                  (symbol-name (plist-get normalized :function)))))
              (if prefix
                  (concat prefix tool-name)
                tool-name)))
          claude-code-ide-mcp-server-tools))

;;; Session Management Functions

(defun claude-code-ide-mcp-server-register-session (session-id project-dir buffer)
  "Register a new session with SESSION-ID, PROJECT-DIR, and BUFFER.
When an instance descriptor belongs to SESSION-ID (its ID, or the ID
of its MCP session), the session records the instance ID and the
launch generation, and gets a new secret.  A request for the session
must then carry that secret."
  (let ((entry (list :project-dir project-dir
                     :buffer buffer
                     :last-active-buffer nil
                     :start-time (current-time)))
        (instance (claude-code-ide-mcp-server--find-instance session-id)))
    (when instance
      (let ((instance-id (claude-code-ide-instance-id instance)))
        (setq entry (append entry
                            (list :instance-id instance-id
                                  :generation (claude-code-ide-instance-generation instance)
                                  :secret (claude-code-ide-mcp-server--new-secret))))
        (puthash instance-id session-id claude-code-ide-mcp-server--instance-keys)))
    (puthash session-id entry claude-code-ide-mcp-server--sessions)
    ;; The one active buffer tracker; it also serves instances without
    ;; an IDE connection
    (when (fboundp 'claude-code-ide-mcp--track-active-buffer)
      (add-hook 'post-command-hook #'claude-code-ide-mcp--track-active-buffer))
    (claude-code-ide-debug "Registered MCP session %s for project %s%s"
                           session-id project-dir
                           (if instance
                               (format " (instance %s)" (claude-code-ide-instance-id instance))
                             ""))))

(defun claude-code-ide-mcp-server-unregister-session (session-id)
  "Unregister the session with SESSION-ID."
  (when-let* ((entry (gethash session-id claude-code-ide-mcp-server--sessions)))
    (remhash session-id claude-code-ide-mcp-server--sessions)
    ;; A newer launch of the instance may own the instance ID already
    (let ((instance-id (plist-get entry :instance-id)))
      (when (and instance-id
                 (equal (gethash instance-id claude-code-ide-mcp-server--instance-keys)
                        session-id))
        (remhash instance-id claude-code-ide-mcp-server--instance-keys)))
    (claude-code-ide-mcp-server--maybe-remove-tracker)
    (claude-code-ide-debug "Unregistered MCP session %s" session-id)))

(defun claude-code-ide-mcp-server--maybe-remove-tracker ()
  "Remove the active buffer tracker when no session of any kind is left.
The tracker also serves the IDE sessions of `claude-code-ide-mcp'."
  (when (and (= 0 (hash-table-count claude-code-ide-mcp-server--sessions))
             (or (not (boundp 'claude-code-ide-mcp--sessions))
                 (= 0 (hash-table-count claude-code-ide-mcp--sessions))))
    (remove-hook 'post-command-hook #'claude-code-ide-mcp--track-active-buffer)))

(defun claude-code-ide-mcp-server-get-session-context (&optional session-id)
  "Get the context for SESSION-ID or the current session.
SESSION-ID is a session key or an instance ID.  Returns a plist with
:project-dir, :buffer and :last-active-buffer, or nil if not found.
For the session of an instance, the descriptor of that launch gives
:project-dir, :worktree, :buffer, :instance-id and :provider; the
selected window plays no part.  The plist never holds the secret."
  (let* ((id (or session-id claude-code-ide-mcp-server--current-session-id))
         (key (and id (claude-code-ide-mcp-server--resolve-key id)))
         (entry (and key (gethash key claude-code-ide-mcp-server--sessions))))
    (when entry
      (let ((context (cl-loop for (k v) on entry by #'cddr
                              unless (eq k :secret) append (list k v)))
            (instance (claude-code-ide-mcp-server--entry-instance entry)))
        (when instance
          (let ((root (claude-code-ide-known-or-nil
                       (claude-code-ide-instance-project-root instance)))
                (buffer (claude-code-ide-instance-buffer instance)))
            (when (stringp root)
              (setq context (plist-put context :project-dir root)))
            (when (buffer-live-p buffer)
              (setq context (plist-put context :buffer buffer)))
            (setq context (plist-put context :worktree
                                     (claude-code-ide-known-or-nil
                                      (claude-code-ide-instance-worktree instance))))
            (setq context (plist-put context :provider
                                     (claude-code-ide-instance-provider instance)))))
        context))))

(defun claude-code-ide-mcp-server-update-last-active-buffer (session-id buffer)
  "Update the last active buffer for SESSION-ID to BUFFER.
This should be called when the user switches to a different buffer
in the project to ensure MCP tools execute in the correct context.
The buffer changes only when BUFFER visits a file inside the worktree
of the instance of SESSION-ID, or inside its project directory when
the worktree is not known.  A buffer of another worktree, also one
nested in this worktree, does not change it.  Return non-nil when the
buffer changed."
  (when-let* ((session (gethash session-id claude-code-ide-mcp-server--sessions)))
    (when (and (buffer-live-p buffer)
               (not (eq buffer (plist-get session :last-active-buffer)))
               (claude-code-ide-mcp-server--buffer-inside-p
                buffer (claude-code-ide-mcp-server--entry-root session)))
      ;; Store the result: plist-put only mutates in place when the key
      ;; already exists in the list
      (puthash session-id (plist-put session :last-active-buffer buffer)
               claude-code-ide-mcp-server--sessions)
      (claude-code-ide-debug "Updated last active buffer for session %s to %s"
                             session-id (buffer-name buffer))
      t)))

(defmacro claude-code-ide-mcp-server-with-session-context (session-id &rest body)
  "Execute BODY with the context of SESSION-ID.
Sets the default-directory to the session's project directory
and makes the session's buffer current if it exists.
Prefers the last active buffer over the registered buffer.
The project directory stays the default directory inside that
buffer too, so relative file names resolve in the caller's project."
  (declare (indent 1))
  `(let* ((context (claude-code-ide-mcp-server-get-session-context ,session-id))
          (project-dir (plist-get context :project-dir))
          (last-active-buffer (plist-get context :last-active-buffer))
          (registered-buffer (plist-get context :buffer))
          ;; Prefer last active buffer, fall back to registered buffer
          (buffer (or (and last-active-buffer
                           (buffer-live-p last-active-buffer)
                           last-active-buffer)
                      (and registered-buffer
                           (buffer-live-p registered-buffer)
                           registered-buffer))))
     (if (not context)
         (error "No session context found for session %s" ,session-id)
       (let ((default-directory (or project-dir default-directory)))
         (if buffer
             (with-current-buffer buffer
               (let ((default-directory (or project-dir default-directory)))
                 ,@body))
           ,@body)))))

(defun claude-code-ide-mcp-request-instance-id ()
  "Return the instance ID of the current MCP request, or nil.
It is nil outside a request, and for a request whose session has no
instance (for example a coordinator request to /mcp)."
  claude-code-ide-mcp-server--current-instance-id)

(defun claude-code-ide-mcp-server-coordinator-request-p ()
  "Return non-nil while a request with the coordinator credential runs."
  claude-code-ide-mcp-server--coordinator-request)

;;; Instances and secrets

(defun claude-code-ide-mcp-server--find-instance (key)
  "Return the instance descriptor of the session KEY, or nil.
KEY is an instance ID, or the session ID of the MCP session of an
instance."
  (or (claude-code-ide-instance-by-id key)
      (cl-find-if (lambda (instance)
                    (let ((session (claude-code-ide-instance-session instance)))
                      (and session
                           (fboundp 'claude-code-ide-mcp-session-p)
                           (claude-code-ide-mcp-session-p session)
                           (equal (claude-code-ide-mcp-session-session-id session) key))))
                  (claude-code-ide-instances))))

(defun claude-code-ide-mcp-server--resolve-key (id)
  "Return the session key that ID names, or nil.
ID is a key of `claude-code-ide-mcp-server--sessions' or the ID of the
instance of a registered session."
  (cond
   ((gethash id claude-code-ide-mcp-server--sessions) id)
   ((when-let* ((key (gethash id claude-code-ide-mcp-server--instance-keys)))
      (and (gethash key claude-code-ide-mcp-server--sessions) key)))))

(defun claude-code-ide-mcp-server--entry-instance (entry)
  "Return the descriptor of the launch of the session ENTRY, or nil.
A descriptor of a later launch of the same instance ID does not count."
  (when-let* ((instance-id (plist-get entry :instance-id))
              (instance (claude-code-ide-instance-by-id instance-id)))
    (and (equal (claude-code-ide-instance-generation instance)
                (plist-get entry :generation))
         instance)))

(defvar claude-code-ide-mcp-server--random-device "/dev/urandom"
  "The file that gives the random bytes of secrets and credentials.")

(defun claude-code-ide-mcp-server--random-bytes (count)
  "Return COUNT bytes from `claude-code-ide-mcp-server--random-device'.
Signal an error when the device cannot give them.  There is no weaker
fallback: a secret that another process can guess protects nothing."
  (let ((device claude-code-ide-mcp-server--random-device))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (condition-case err
          ;; The device cannot seek, so read from its start with a limit
          (insert-file-contents-literally device nil nil count)
        (file-error
         (error "Cannot make an MCP secret: cannot read random bytes from %s: %s"
                device (error-message-string err))))
      (unless (= (buffer-size) count)
        (error "Cannot make an MCP secret: %s gave %d of %d random bytes"
               device (buffer-size) count))
      (buffer-string))))

(defun claude-code-ide-mcp-server--new-secret ()
  "Return a new random secret: 64 hexadecimal characters (32 random bytes).
Signal an error when the system has no random device."
  (mapconcat (lambda (byte) (format "%02x" byte))
             (claude-code-ide-mcp-server--random-bytes 32)
             ""))

(defun claude-code-ide-mcp-server--secret-equal (a b)
  "Return non-nil when the strings A and B are equal.
The time does not depend on where the strings differ."
  (and (stringp a) (stringp b)
       (= (length a) (length b))
       (let ((diff 0))
         (dotimes (i (length a))
           (setq diff (logior diff (logxor (aref a i) (aref b i)))))
         (= diff 0))))

(defun claude-code-ide-mcp-server-check-request (id path-secret header-secret
                                                    &optional coordinator-credential)
  "Check a request for the session ID and return the result as a plist.
ID is the first part of the URL path after /mcp/, or nil.
PATH-SECRET is the rest of the path, HEADER-SECRET the value of
`claude-code-ide-mcp-server-secret-header', and COORDINATOR-CREDENTIAL
the value of `claude-code-ide-mcp-server-coordinator-header'; each is
nil when the request has none.
The result is (:ok t :key KEY :instance-id ID :coordinator BOOL), or
\(:ok nil :reason TEXT).  The rules:
- A coordinator credential, when given, must be right.
- A request without ID needs the coordinator credential.
- The ID must name a registered session.  A session that ended is
  unknown.
- A session with a secret needs it in the path or in the header, and
  a secret in either place must be right.
- A session without a secret (for example one that a user
  configuration registers itself) is reached only by its exact key,
  and the request must carry no secret."
  (let* ((key (and id (claude-code-ide-mcp-server--resolve-key id)))
         (entry (and key (gethash key claude-code-ide-mcp-server--sessions)))
         (secret (plist-get entry :secret))
         (coordinator (and coordinator-credential
                           (claude-code-ide-mcp-server--secret-equal
                            coordinator-credential
                            (claude-code-ide-mcp-server-coordinator-credential)))))
    (cond
     ((and coordinator-credential (not coordinator))
      (list :ok nil :reason "wrong coordinator credential"))
     ((null id)
      (if coordinator
          (list :ok t :key nil :instance-id nil :coordinator t)
        (list :ok nil :reason "missing session ID")))
     ((null entry)
      (list :ok nil :reason "unknown session"))
     ((null secret)
      (cond
       ((not (equal id key))
        (list :ok nil :reason "unknown session"))
       ((or path-secret header-secret)
        (list :ok nil :reason "unexpected instance secret"))
       (t (list :ok t :key key :instance-id nil :coordinator coordinator))))
     ((not (or path-secret header-secret))
      (list :ok nil :reason "missing instance secret"))
     ((and path-secret
           (not (claude-code-ide-mcp-server--secret-equal path-secret secret)))
      (list :ok nil :reason "wrong instance secret"))
     ((and header-secret
           (not (claude-code-ide-mcp-server--secret-equal header-secret secret)))
      (list :ok nil :reason "wrong instance secret"))
     (t (list :ok t
              :key key
              :instance-id (plist-get entry :instance-id)
              :coordinator coordinator)))))

;;; Coordinator credential

(defconst claude-code-ide-mcp-server--default-state-file "~/.emacs-claude-code-ide-state.json"
  "The default of `claude-code-ide-state-file' in the session registry.")

(defun claude-code-ide-mcp-server--report-directory ()
  "Return the report directory of the session registry.
This gives the same folder as
`claude-code-ide-session-registry--report-directory' whether or not
the registry is loaded: it reads the same two options
when they are bound, and uses their defaults when they are not.  So
the server does not need to load the registry and the whole package."
  (file-name-as-directory
   (expand-file-name
    (or (and (boundp 'claude-code-ide-session-registry-report-directory)
             (symbol-value 'claude-code-ide-session-registry-report-directory))
        (concat (file-name-sans-extension
                 (expand-file-name
                  (if (boundp 'claude-code-ide-state-file)
                      (symbol-value 'claude-code-ide-state-file)
                    claude-code-ide-mcp-server--default-state-file)))
                "-reports")))))

(defun claude-code-ide-mcp-server-coordinator-credential-file ()
  "Return the absolute name of the coordinator credential file.
See `claude-code-ide-mcp-server-coordinator-credential-file'.  The
default is in `claude-code-ide-mcp-server--report-directory'."
  (expand-file-name
   (or claude-code-ide-mcp-server-coordinator-credential-file
       (expand-file-name "coordinator-credential"
                         (claude-code-ide-mcp-server--report-directory)))))

(defun claude-code-ide-mcp-server--private-file-p (file)
  "Return non-nil when FILE belongs to this user and only this user can read it."
  (let ((attributes (file-attributes file 'integer)))
    (and attributes
         (eql (file-attribute-user-id attributes) (user-uid))
         (= 0 (logand (file-modes file) #o077)))))

(defun claude-code-ide-mcp-server-coordinator-credential (&optional create)
  "Return the coordinator credential, or nil when there is none.
With CREATE non-nil, make a new credential file when there is none:
mode 0600, in a folder that gets mode 0700 when Emacs makes it.  A file
that another user can read gives nil and a message, because the
credential may be known."
  (let ((file (claude-code-ide-mcp-server-coordinator-credential-file)))
    (cond
     ((file-exists-p file)
      (if (claude-code-ide-mcp-server--private-file-p file)
          (let ((value (string-trim (with-temp-buffer
                                      (insert-file-contents-literally file)
                                      (buffer-string)))))
            (and (not (string-empty-p value)) value))
        (message "claude-code-ide: ignoring the coordinator credential %s: other users can read it"
                 file)
        nil))
     (create
      (let ((value (claude-code-ide-mcp-server--new-secret))
            (dir (file-name-directory file)))
        (unless (file-directory-p dir)
          (with-file-modes #o700
            (make-directory dir t)))
        (with-file-modes #o600
          (write-region value nil file nil 'silent))
        (set-file-modes file #o600)
        value)))))

(defun claude-code-ide-mcp-server-rotate-coordinator-credential ()
  "Replace the coordinator credential with a new one.
Coordinators must read the file again afterwards."
  (interactive)
  (let ((file (claude-code-ide-mcp-server-coordinator-credential-file)))
    (when (file-exists-p file)
      (delete-file file))
    (claude-code-ide-mcp-server-coordinator-credential t)
    (message "New coordinator credential in %s" file)))

(defun claude-code-ide-mcp-server--coordinator-tools-p ()
  "Return non-nil when a registered tool has the scope `coordinator'."
  (cl-some (lambda (spec)
             (eq (claude-code-ide-mcp-server-tool-scope
                  (claude-code-ide--normalize-tool-spec spec))
                 'coordinator))
           claude-code-ide-mcp-server-tools))

;;; The last active buffer

(defun claude-code-ide-mcp-server--entry-root (entry)
  "Return (ROOT . WORKTREE-P) of the session ENTRY.
ROOT is the worktree of its instance when it is known, else the
project directory of ENTRY.  WORKTREE-P is non-nil for a worktree."
  (let ((worktree (when-let* ((instance (claude-code-ide-mcp-server--entry-instance entry)))
                    (claude-code-ide-known-or-nil
                     (claude-code-ide-instance-worktree instance)))))
    (if (stringp worktree)
        (cons worktree t)
      (cons (plist-get entry :project-dir) nil))))

(defun claude-code-ide-mcp-server--buffer-inside-p (buffer root-and-worktree)
  "Return non-nil when BUFFER visits a file inside ROOT-AND-WORKTREE.
ROOT-AND-WORKTREE is a value of `claude-code-ide-mcp-server--entry-root'.
For a worktree, the nearest folder above the file with a .git entry
must be the worktree, so that a nested worktree does not count."
  (let ((file (buffer-file-name buffer))
        (root (car root-and-worktree)))
    (when (and file (stringp root))
      (let ((root (file-name-as-directory (expand-file-name root)))
            (file (expand-file-name file)))
        (and (string-prefix-p root file)
             (or (not (cdr root-and-worktree))
                 (when-let* ((top (locate-dominating-file file ".git")))
                   (string= (file-name-as-directory (expand-file-name top)) root))))))))

(defun claude-code-ide-mcp-server-note-buffer (buffer &optional except)
  "Make BUFFER the last active buffer of each session whose worktree has it.
Sessions of other worktrees keep their last active buffer.  Skip the
session keys in the list EXCEPT, which the caller has already updated.
`claude-code-ide-mcp--track-active-buffer' calls this after each command."
  (when (buffer-file-name buffer)
    (maphash (lambda (key _entry)
               (unless (member key except)
                 (condition-case err
                     (claude-code-ide-mcp-server-update-last-active-buffer key buffer)
                   (error
                    (claude-code-ide-debug "MCP server buffer tracking failed: %s"
                                           (error-message-string err))))))
             claude-code-ide-mcp-server--sessions)))

;;; Internal Functions

(defun claude-code-ide-mcp-server--server-alive-p ()
  "Check if the MCP tools server is still alive."
  (when claude-code-ide-mcp-server--server
    (condition-case nil
        (let ((process (ws-process claude-code-ide-mcp-server--server)))
          (and process (process-live-p process)))
      (error nil))))

(defun claude-code-ide-mcp-server--start-server ()
  "Start the MCP HTTP server."
  (condition-case err
      (progn
        ;; Load the server implementation
        (require 'claude-code-ide-mcp-http-server)
        ;; Check if web-server is available
        (unless (featurep 'web-server)
          (error "The web-server package is required for MCP tools support. Please install it with: M-x package-install RET web-server RET"))
        ;; Start the server
        (let ((result (claude-code-ide-mcp-http-server-start
                       claude-code-ide-mcp-server-port)))
          (setq claude-code-ide-mcp-server--server (car result)
                claude-code-ide-mcp-server--port (cdr result))
          ;; Coordinators read the credential from its file
          (when (claude-code-ide-mcp-server--coordinator-tools-p)
            (claude-code-ide-mcp-server-coordinator-credential t))
          claude-code-ide-mcp-server--port))
    (error
     (claude-code-ide-debug "Failed to start MCP server: %s"
                            (error-message-string err))
     (message "Warning: Failed to start MCP server: %s"
              (error-message-string err))
     nil)))

(defun claude-code-ide-mcp-server--stop-server ()
  "Stop the MCP HTTP server."
  (when claude-code-ide-mcp-server--server
    (condition-case err
        (progn
          (claude-code-ide-mcp-http-server-stop claude-code-ide-mcp-server--server)
          (setq claude-code-ide-mcp-server--server nil
                claude-code-ide-mcp-server--port nil)
          ;; Clear all registered sessions
          (clrhash claude-code-ide-mcp-server--sessions)
          (clrhash claude-code-ide-mcp-server--instance-keys)
          (claude-code-ide-mcp-server--maybe-remove-tracker)
          (claude-code-ide-debug "MCP server stopped"))
      (error
       (claude-code-ide-debug "Error stopping MCP server: %s"
                              (error-message-string err))))))

(provide 'claude-code-ide-mcp-server)
;;; claude-code-ide-mcp-server.el ends here
