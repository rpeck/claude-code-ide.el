;;; claude-code-ide-codex.el --- The Codex provider  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Raymond Peck
;; Keywords: ai, tools

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

;; The `codex' provider runs the Codex CLI in an Emacs terminal.
;;
;; - Each launch runs `codex --no-daemon', so that a kill of the
;;   terminal buffer ends the conversation and its child processes.
;; - The Emacs instructions go in `-c developer_instructions=...'.
;; - The MCP tools server of the package goes in `-c mcp_servers.*'
;;   keys.  Header values go through environment variables, which the
;;   shell commands of the model do not get.
;; - Every MCP tool needs an approval, except the tools that
;;   `claude-code-ide-mcp-allowed-tools' approves.
;; - Prompts go through `codex queue', never through keys in the
;;   terminal: a typed Return can steer a turn or approve a dialog.
;; - `claude-code-ide-codex-screen-dialog' finds the startup dialogs
;;   and the approval dialogs on the terminal screen.
;;
;; The commands `claude-code-ide-codex', `claude-code-ide-codex-continue'
;; and `claude-code-ide-codex-resume' start an instance.  docs/codex.md
;; describes the command lines.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'claude-code-ide)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-mcp-server)

;;; Options

(defgroup claude-code-ide-codex nil
  "The Codex CLI in claude-code-ide."
  :group 'claude-code-ide
  :prefix "claude-code-ide-codex-")

(defcustom claude-code-ide-codex-cli-path "codex"
  "Path to the Codex CLI executable."
  :type 'string
  :group 'claude-code-ide-codex)

(defcustom claude-code-ide-codex-extra-flags ""
  "Additional flags for the Codex CLI, as one string.
For example \"--model gpt-5.6-terra\".  Every Codex launch gets them.
Codex never gets `claude-code-ide-cli-extra-flags', which holds
Claude Code flags, nor the extra flags of a start spec."
  :type 'string
  :group 'claude-code-ide-codex)

(defcustom claude-code-ide-codex-remove-openai-api-key t
  "When non-nil, remove OPENAI_API_KEY from the Codex environment.
Codex then uses the login of `codex login' (the ChatGPT subscription)
instead of an API key that the Emacs environment holds.  Only the
environment of the CLI changes."
  :type 'boolean
  :group 'claude-code-ide-codex)

(defcustom claude-code-ide-codex-no-alt-screen t
  "When non-nil, run Codex with --no-alt-screen.
Codex then draws in the normal screen, so the terminal buffer keeps
the earlier output.  Without it, the buffer shows only the current
screen.  Both display correctly."
  :type 'boolean
  :group 'claude-code-ide-codex)

(defcustom claude-code-ide-codex-skip-update-check t
  "When non-nil, Codex does not look for updates at startup.
The update dialog of Codex selects \"Update now\" by default.  This
option passes `-c check_for_update_on_startup=false'."
  :type 'boolean
  :group 'claude-code-ide-codex)

(defcustom claude-code-ide-codex-config-read-timeout 5
  "Seconds that a launch waits for the Codex config.
A launch reads the shell environment policy of the user through
`codex app-server' before it adds its own excluded variables."
  :type 'number
  :group 'claude-code-ide-codex)

(defcustom claude-code-ide-codex-queue-timeout 30
  "Seconds after which a `codex queue' command is stopped."
  :type 'number
  :group 'claude-code-ide-codex)

(defcustom claude-code-ide-codex-coordinator-approved-tools
  '("claude-code-ide-control-list-instances"
    "claude-code-ide-control-inspect-instance"
    "claude-code-ide-control-request-status"
    "claude-code-ide-control-handover-status")
  "Coordinator tools that a Codex coordinator may call without approval.
Only a Codex instance with the role \"coordinator\" gets coordinator
tools, and these only read.  Every other coordinator tool, such as
launch, resume, stop, submit-prompt and handover, asks for approval.
An instance without that role gets no approval for any coordinator
tool."
  :type '(repeat string)
  :group 'claude-code-ide-codex)

(defvar claude-code-ide-codex-queue-functions nil
  "Functions called when a `codex queue' command of a prompt ends.
Each function is called with INSTANCE and RESULT, the plist that
`submit-prompt' returned, whose :outcome is now `queued', `failed' or
`timeout'.")

;;; Constants

(defconst claude-code-ide-codex--emacs-prompt
  "IMPORTANT: Connected to Emacs via claude-code-ide.el integration. Emacs uses mixed coordinates: Lines: 1-based (line 1 = first line), Columns: 0-based (column 0 = first column). Example: First character in file is at line 1, column 0. Available: xref (LSP), tree-sitter, imenu, project.el, flycheck/flymake diagnostics. Context-aware with automatic project/file/selection tracking."
  "The Emacs part of the developer instructions.
It is the same text that Claude Code gets in --append-system-prompt.")

(defconst claude-code-ide-codex--mcp-server-name "emacs_tools"
  "Name of the MCP tools server of the package in the Codex config.")

(defconst claude-code-ide-codex--nested-variables
  '("CODEX_THREAD_ID" "CODEX_SESSION_ID" "CODEX_TOOL_CALL_ID")
  "Variables that Codex sets for a nested session.
The launch removes them.  Else a Codex that Emacs starts from inside a
Codex tool shell looks nested, and the hook script drops its events.")

(defconst claude-code-ide-codex--header-variable-prefix "CCI_MCP_HEADER_"
  "Prefix of the variables that hold the MCP header values.")

(defconst claude-code-ide-codex--event-map
  '(("SessionStart" . session-start)
    ("SessionEnd" . session-end)
    ("UserPromptSubmit" . prompt-submit)
    ("PreToolUse" . tool-start)
    ("PostToolUse" . tool-end)
    ("PermissionRequest" . approval-request)
    ("Stop" . turn-end)
    ("Interrupt" . interrupt)
    ("SubagentStart" . subagent-start)
    ("SubagentStop" . subagent-end))
  "Common event of each Codex hook event.
PostModelRequest is `turn-failed' when its status is \"failed\".
The other events are `other'.")

(defconst claude-code-ide-codex--dialog-patterns
  '((folder-trust "Trust this folder\\?" "Trust and continue"
                  "Your trust decision will be saved")
    (hooks-review "Hooks need review" "Trust all and continue"
                  "Continue without trusting")
    (update "Update now" "Skip until next version")
    (approval "Allow the [^ ]+ MCP server to run tool" "Yes, proceed"
              "Yes, just this once" "No, and tell Codex what to do differently"
              ;; The tail of the MCP approval dialog, which is all that an
              ;; eat buffer without a window keeps: the selected choice
              ;; "› 1. Allow  Run the tool and" and, below it, the control
              ;; line "option 1/2 | enter to submit | esc" (white space is
              ;; one space here).  A reply that lists such a choice has
              ;; neither the marker nor the control line.
              "› [0-9]+\\. Allow Run the tool.\\{0,300\\}option [0-9]+/[0-9]+ | enter to submit"))
  "Text patterns of the Codex dialogs, as (KIND REGEXP...).
The first kind with a matching regexp wins.  The regexps match the
screen text with each run of white space as one space.  The texts are
those of Codex 0.164.0.")

(defvar claude-code-ide-codex--screen-lines 50
  "Lines of a terminal screen when no window shows the terminal buffer.")

;;; Values

(defun claude-code-ide-codex--get (data key)
  "Return the value of KEY (a string) in the hook DATA, or nil.
DATA is an alist with symbol or string keys, a plist, or a hash table."
  (cond
   ((hash-table-p data)
    (or (gethash key data) (gethash (intern key) data)))
   ((and (consp data) (keywordp (car data)))
    (plist-get data (intern (concat ":" key))))
   ((consp data)
    (cdr (or (assq (intern key) data) (assoc key data))))))

(defun claude-code-ide-codex--toml-string (string)
  "Return STRING as a TOML basic string, with its quotes.
Backslashes, double quotes and control characters are escaped, so
that Codex reads the same text back.  Codex takes a value that is not
valid TOML as a raw string, so an unescaped quote would change the
text without an error."
  (concat "\""
          (mapconcat
           (lambda (char)
             (pcase char
               (?\\ "\\\\")
               (?\" "\\\"")
               (?\b "\\b")
               (?\t "\\t")
               (?\n "\\n")
               (?\f "\\f")
               (?\r "\\r")
               ((guard (or (< char #x20) (= char #x7f))) (format "\\u%04X" char))
               (_ (char-to-string char))))
           string "")
          "\""))

(defun claude-code-ide-codex--toml-array (strings)
  "Return STRINGS as a TOML array of basic strings."
  (concat "[" (mapconcat #'claude-code-ide-codex--toml-string strings ",") "]"))

(defun claude-code-ide-codex--toml-table (pairs)
  "Return PAIRS, a list of (KEY . STRING), as a TOML inline table."
  (concat "{"
          (mapconcat (lambda (pair)
                       (concat (claude-code-ide-codex--toml-string (car pair))
                               "="
                               (claude-code-ide-codex--toml-string (cdr pair))))
                     pairs ",")
          "}"))

(defun claude-code-ide-codex--config-arg (key value)
  "Return the arguments that set the config KEY to the TOML text VALUE."
  (list "-c" (concat key "=" value)))

(defun claude-code-ide-codex--bare-key-p (name)
  "Return non-nil when NAME can be one part of a dotted -c key."
  (string-match-p "\\`[A-Za-z0-9_-]+\\'" name))

(defun claude-code-ide-codex--flag-words ()
  "Return the words of `claude-code-ide-codex-extra-flags'."
  (claude-code-ide--split-command-line (or claude-code-ide-codex-extra-flags "")))

(defun claude-code-ide-codex--flags-model ()
  "Return the model that `claude-code-ide-codex-extra-flags' selects, or nil."
  (let ((words (claude-code-ide-codex--flag-words))
        (model nil))
    (while words
      (let ((word (pop words)))
        (cond
         ((member word '("-m" "--model")) (setq model (pop words)))
         ((string-prefix-p "--model=" word) (setq model (substring word 8))))))
    model))

;;; Instructions

(defun claude-code-ide-codex--developer-instructions ()
  "Return the developer instructions: the Emacs prompt and the user's prompt.
The user's prompt is `claude-code-ide-system-prompt', as for Claude Code."
  (if claude-code-ide-system-prompt
      (concat claude-code-ide-codex--emacs-prompt "\n\n" claude-code-ide-system-prompt)
    claude-code-ide-codex--emacs-prompt))

;;; The shell environment policy of the user

(defun claude-code-ide-codex--config-overrides ()
  "Return the -c words of `claude-code-ide-codex-extra-flags', or `unknown'.
The result is `unknown' when the flags select a profile, because
`codex app-server' cannot read the config of a profile."
  (let ((words (claude-code-ide-codex--flag-words))
        (overrides nil)
        (profile nil))
    (while words
      (let ((word (pop words)))
        (cond
         ((member word '("-c" "--config"))
          (when words (setq overrides (append overrides (list "-c" (pop words))))))
         ((string-prefix-p "--config=" word)
          (setq overrides (append overrides (list "-c" (substring word 9)))))
         ((or (member word '("-p" "--profile"))
              (string-prefix-p "--profile=" word)
              (string-match-p "\\`-p." word))
          (setq profile t)))))
    (if profile 'unknown overrides)))

(defun claude-code-ide-codex--config-read-response (output)
  "Return the result of the config/read reply in OUTPUT, or nil.
OUTPUT is the text that `codex app-server' wrote so far, one JSON
message on each line.  The result is (exclude . LIST) for a reply,
where LIST is the excluded variables, or (exclude . unknown) when the
reply is an error or has an unexpected form."
  (cl-loop
   for line in (split-string output "\n" t)
   for message = (ignore-errors
                   (json-parse-string line :object-type 'alist :array-type 'list
                                      :null-object nil :false-object nil))
   when (and (consp message) (equal (alist-get 'id message) 2))
   return (let* ((config (alist-get 'config (alist-get 'result message)))
                 (policy (alist-get 'shell_environment_policy config))
                 (exclude (alist-get 'exclude policy)))
            (cons 'exclude
                  (if (and config (listp exclude) (cl-every #'stringp exclude)
                           (not (alist-get 'error message)))
                      exclude
                    'unknown)))))

(defun claude-code-ide-codex--read-exclude (directory)
  "Return the effective `shell_environment_policy.exclude' of Codex.
DIRECTORY is the project, whose project config layers count.  The
value comes from the config/read call of `codex app-server', with the
-c words of `claude-code-ide-codex-extra-flags'.  The result is a list
of variable names (nil when the user excludes none), or `unknown'
when the value cannot be read within
`claude-code-ide-codex-config-read-timeout'.  This reads only."
  (let ((overrides (claude-code-ide-codex--config-overrides)))
    (if (eq overrides 'unknown)
        'unknown
      (let* ((output "")
             (found nil)
             (stderr (generate-new-buffer " *cci-codex-config-read*"))
             (deadline (+ (float-time) claude-code-ide-codex-config-read-timeout))
             (process nil))
        (unwind-protect
            (condition-case nil
                (let ((default-directory (file-name-as-directory directory))
                      (process-environment (claude-code-ide-codex--process-environment)))
                  (setq process
                        (make-process
                         :name "cci-codex-config-read"
                         :command (append (list claude-code-ide-codex-cli-path)
                                          overrides (list "app-server"))
                         :connection-type 'pipe
                         :noquery t
                         :stderr stderr
                         :filter (lambda (_process text) (setq output (concat output text)))))
                  (dolist (message
                           `(((id . 1) (method . "initialize")
                              (params . ((clientInfo . ((name . "claude-code-ide")
                                                        (version . "0"))))))
                             ((method . "initialized"))
                             ((id . 2) (method . "config/read")
                              (params . ((cwd . ,(expand-file-name directory))
                                         (includeLayers . :json-false))))))
                    (process-send-string process (concat (json-encode message) "\n")))
                  (while (and (not found)
                              (process-live-p process)
                              (< (float-time) deadline))
                    (accept-process-output process 0.05)
                    (setq found (claude-code-ide-codex--config-read-response output)))
                  (unless found
                    (setq found (claude-code-ide-codex--config-read-response output))))
              (error nil))
          (when (process-live-p process) (delete-process process))
          (let ((stderr-process (get-buffer-process stderr)))
            (when stderr-process (delete-process stderr-process)))
          (kill-buffer stderr))
        (if found (cdr found) 'unknown)))))

;;; MCP setup

(defun claude-code-ide-codex--header-variable (header)
  "Return the name of the variable that holds the value of HEADER.
The name has the header name and a short hash of it, so that two
headers whose names differ only in punctuation or case get two names."
  (format "%s%s_%s"
          claude-code-ide-codex--header-variable-prefix
          (upcase (replace-regexp-in-string "[^A-Za-z0-9]" "_" header))
          (upcase (substring (secure-hash 'sha1 header) 0 8))))

(defun claude-code-ide-codex--all-tool-names ()
  "Return the names of all registered MCP tools.
This reads the tool list itself, so that no advice of
`claude-code-ide-mcp-server-get-tool-names' removes a name."
  (mapcar (lambda (tool-spec)
            (let ((normalized (claude-code-ide--normalize-tool-spec tool-spec)))
              (or (plist-get normalized :name)
                  (symbol-name (plist-get normalized :function)))))
          claude-code-ide-mcp-server-tools))

(defun claude-code-ide-codex--coordinator-tool-names ()
  "Return the names of the registered MCP tools of the coordinator scope."
  (delq nil
        (mapcar (lambda (tool-spec)
                  (let ((normalized (claude-code-ide--normalize-tool-spec tool-spec)))
                    (when (eq (claude-code-ide-mcp-server-tool-scope normalized) 'coordinator)
                      (or (plist-get normalized :name)
                          (symbol-name (plist-get normalized :function))))))
                claude-code-ide-mcp-server-tools)))

(defun claude-code-ide-codex--coordinator-p (instance)
  "Return non-nil when INSTANCE has the role \"coordinator\"."
  (and instance
       (equal (format "%s" (claude-code-ide-instance-role instance)) "coordinator")))

(defun claude-code-ide-codex--approved-tool-names (&optional instance)
  "Return the MCP tools that Codex may call without approval.
This follows `claude-code-ide-mcp-allowed-tools', as for Claude Code:
`auto' gives the result of `claude-code-ide-mcp-server-get-tool-names',
after its advice (an advice can remove a tool, such as `emacs_eval'),
nil gives none, and a list or a string gives the tools that it names.
Only registered tools count.

A coordinator tool counts only when INSTANCE has the role
\"coordinator\" and the tool is in
`claude-code-ide-codex-coordinator-approved-tools'."
  (let* ((prefix "mcp__emacs-tools__")
         (all (claude-code-ide-codex--all-tool-names))
         (coordinator-tools (claude-code-ide-codex--coordinator-tool-names))
         (coordinator (claude-code-ide-codex--coordinator-p instance))
         (names (mapcar (lambda (name)
                          (if (string-prefix-p prefix name) (substring name (length prefix)) name))
                        (pcase claude-code-ide-mcp-allowed-tools
                          ('auto (claude-code-ide-mcp-server-get-tool-names))
                          ('nil nil)
                          ((pred stringp) (split-string claude-code-ide-mcp-allowed-tools nil t))
                          ((pred listp) claude-code-ide-mcp-allowed-tools)))))
    (delete-dups
     (cl-remove-if-not (lambda (name)
                         (and (member name all)
                              (or (not (member name coordinator-tools))
                                  (and coordinator
                                       (member name claude-code-ide-codex-coordinator-approved-tools)))))
                       names))))

(defun claude-code-ide-codex--approval-args (server &optional instance)
  "Return the -c arguments of the tool approvals of the MCP SERVER key.
Every tool needs an approval by default, so a tool that appears later
or that no rule names asks too.  Each tool of
`claude-code-ide-codex--approved-tool-names' for INSTANCE gets
approval_mode \"approve\", unless its name cannot be a part of a
dotted key."
  (append (claude-code-ide-codex--config-arg
           (concat server ".default_tools_approval_mode") "\"prompt\"")
          (mapcan (lambda (name)
                    (claude-code-ide-codex--config-arg
                     (format "%s.tools.%s.approval_mode" server name) "\"approve\""))
                  (cl-remove-if-not #'claude-code-ide-codex--bare-key-p
                                    (claude-code-ide-codex--approved-tool-names instance)))))

(defun claude-code-ide-codex--coordinator-header-p (name)
  "Return non-nil when the header NAME is that of the coordinator credential."
  (eq t (compare-strings name nil nil claude-code-ide-mcp-server-coordinator-header nil nil t)))

(defun claude-code-ide-codex--warn-plain-headers (dropped)
  "Warn that the MCP header values of this launch are in the argument list.
DROPPED non-nil says that the launch left out the coordinator
credential.  Each launch that puts the values there warns."
  (display-warning
   'claude-code-ide
   (concat "Codex: the shell environment policy of your Codex config could not be read, so the MCP header values are in the Codex argument list, which other local processes can read."
           (when dropped
             "  The coordinator credential is not in it: this Codex coordinator starts without the coordinator tools.")
           "  Remove -p or --profile from `claude-code-ide-codex-extra-flags', or check that `codex app-server' works.")))

(defun claude-code-ide-codex--mcp-setup (instance)
  "Return the MCP config of INSTANCE for Codex, or nil.
The result is (:args ARGS :environment ENTRIES).  ARGS are -c
arguments for the tools server of INSTANCE's MCP session.  The config
comes from `claude-code-ide-mcp-server-get-config', after its advice
ran, so headers that an advice adds stay.

Each header value goes into a variable of ENTRIES, which
`env_http_headers' names.  `shell_environment_policy.exclude' hides
the variables from the model's shell commands.  That -c value replaces
the user's own list, so it holds the user's effective list and the new
variables.  When the user's list cannot be read, the values go in
`http_headers' instead, in the argument list, with a warning at each
launch.  The coordinator credential never goes there: such a
coordinator starts without it."
  (when-let* (((claude-code-ide-mcp-server-ensure-server))
              (session (claude-code-ide-instance-session instance))
              (config (claude-code-ide-mcp-server-get-config
                       (claude-code-ide-mcp-session-session-id session)))
              (server (alist-get 'emacs-tools (alist-get 'mcpServers config)))
              (url (alist-get 'url server)))
    (let* ((key (concat "mcp_servers." claude-code-ide-codex--mcp-server-name))
           (headers (mapcar (lambda (header)
                              (let ((name (format "%s" (car header))))
                                (list name
                                      (claude-code-ide-codex--header-variable name)
                                      (format "%s" (cdr header)))))
                            (alist-get 'headers server)))
           (root (claude-code-ide-known-or-nil (claude-code-ide-instance-project-root instance)))
           (exclude (when headers
                      (claude-code-ide-codex--read-exclude
                       (if (and root (file-directory-p root)) root default-directory))))
           (url-args (claude-code-ide-codex--config-arg
                      (concat key ".url") (claude-code-ide-codex--toml-string url)))
           (approval-args (claude-code-ide-codex--approval-args key instance)))
      (cond
       ((null headers)
        (list :args (append url-args approval-args) :environment nil))
       ((eq exclude 'unknown)
        ;; The argument list is visible to all local users: never put
        ;; the coordinator credential in it
        (let ((plain (cl-remove-if #'claude-code-ide-codex--coordinator-header-p headers
                                   :key #'car)))
          (claude-code-ide-codex--warn-plain-headers (not (equal plain headers)))
          (list :args (append url-args
                              (when plain
                                (claude-code-ide-codex--config-arg
                                 (concat key ".http_headers")
                                 (claude-code-ide-codex--toml-table
                                  (mapcar (lambda (header) (cons (car header) (nth 2 header)))
                                          plain))))
                              approval-args)
                :environment nil)))
       (t
        (let ((variables (mapcar #'cadr headers)))
          (list :args (append
                       url-args
                       (claude-code-ide-codex--config-arg
                        (concat key ".env_http_headers")
                        (claude-code-ide-codex--toml-table
                         (mapcar (lambda (header) (cons (car header) (cadr header))) headers)))
                       (claude-code-ide-codex--config-arg
                        "shell_environment_policy.exclude"
                        (claude-code-ide-codex--toml-array
                         (append exclude
                                 (cl-remove-if (lambda (name) (member name exclude)) variables))))
                       approval-args)
                :environment (mapcar (lambda (header)
                                       (format "%s=%s" (cadr header) (nth 2 header)))
                                     headers))))))))

;;; Launch

(defun claude-code-ide-codex--launched-p (instance)
  "Return non-nil when INSTANCE has the launch generation of its start."
  (let ((generation (claude-code-ide-instance-generation instance)))
    (and (integerp generation) (> generation 0))))

(defun claude-code-ide-codex--hook-args (instance &optional interactive)
  "Return the status hook arguments of INSTANCE, or nil.
The `codex-status' part gives them, when it is loaded and INSTANCE has
its launch generation.  INTERACTIVE, the `interactive' slot of the
start spec, lets it ask the user to trust the hooks."
  (when (and (fboundp 'claude-code-ide-codex-status-hook-args)
             (claude-code-ide-codex--launched-p instance))
    (funcall 'claude-code-ide-codex-status-hook-args instance interactive)))

(defun claude-code-ide-codex--hook-env (instance)
  "Return the status hook environment entries of INSTANCE, or nil."
  (when (and (fboundp 'claude-code-ide-codex-status-hook-env)
             (claude-code-ide-codex--launched-p instance))
    (funcall 'claude-code-ide-codex-status-hook-env instance)))

(defun claude-code-ide-codex--removed-variables ()
  "Return the names of the variables that the Codex environment does not have."
  (append (when claude-code-ide-codex-remove-openai-api-key
            (list "OPENAI_API_KEY"))
          claude-code-ide-codex--nested-variables))

(defun claude-code-ide-codex--environment (instance mcp-environment)
  "Return the environment entries of the CLI of INSTANCE.
MCP-ENVIRONMENT holds the variables of the MCP headers."
  (append (claude-code-ide-codex--removed-variables)
          mcp-environment
          (claude-code-ide-codex--hook-env instance)))

(defun claude-code-ide-codex--common-args ()
  "Return the arguments that every Codex launch gets first."
  (append (list "--no-daemon")
          (when claude-code-ide-codex-no-alt-screen
            (list "--no-alt-screen"))
          (when claude-code-ide-codex-skip-update-check
            (claude-code-ide-codex--config-arg "check_for_update_on_startup" "false"))
          (claude-code-ide-codex--config-arg
           "developer_instructions"
           (claude-code-ide-codex--toml-string
            (claude-code-ide-codex--developer-instructions)))))

(defun claude-code-ide-codex--command (instance args subcommand positional &optional interactive)
  "Return (:command :environment) for INSTANCE.
SUBCOMMAND is a list of words after the program, such as (\"resume\").
Then come the common arguments, the hook arguments,
`claude-code-ide-codex-extra-flags' (as they are), ARGS, and the MCP
arguments, which come last so that they win over an earlier -c of the
same key.  POSITIONAL, a list of words such as a native ID and a
prompt, comes after \"--\", so that no option takes it as a value and
no word of it is a subcommand.  The model of INSTANCE becomes the one
of the extra flags.  INTERACTIVE is the `interactive' slot of the start
spec, for the hook trust."
  (let* ((mcp (claude-code-ide-codex--mcp-setup instance))
         (flags (string-trim (or claude-code-ide-codex-extra-flags "")))
         (words (append subcommand
                        (claude-code-ide-codex--common-args)
                        (claude-code-ide-codex--hook-args instance interactive))))
    (setf (claude-code-ide-instance-model instance)
          (claude-code-ide-or-unknown (claude-code-ide-codex--flags-model)))
    (list :command (concat
                    (mapconcat #'shell-quote-argument
                               (cons claude-code-ide-codex-cli-path words) " ")
                    (unless (string-empty-p flags) (concat " " flags))
                    (mapconcat (lambda (arg) (concat " " (shell-quote-argument arg)))
                               (append args (plist-get mcp :args)) "")
                    (when positional
                      (concat " --" (mapconcat (lambda (word)
                                                 (concat " " (shell-quote-argument word)))
                                               positional ""))))
          :environment (claude-code-ide-codex--environment
                        instance (plist-get mcp :environment)))))

(defun claude-code-ide-codex--launch (instance spec args)
  "Return the command and the environment of a new Codex conversation.
INSTANCE is the descriptor, SPEC the start spec, and ARGS the caller's
extra arguments.  SPEC's prompt is the first prompt.  SPEC's extra
flags are not used: they hold Claude Code flags."
  (let ((prompt (claude-code-ide-start-spec-prompt spec)))
    (claude-code-ide-codex--command instance args nil (and prompt (list prompt))
                                    (claude-code-ide-start-spec-interactive spec))))

(defun claude-code-ide-codex--resume (instance spec args)
  "Return the command that resumes a Codex conversation of INSTANCE.
SPEC's resume ID gives `codex resume ID', its continue flag `codex
resume --last', and its resume flag the picker of `codex resume'.
Only a resume of an ID can take SPEC's prompt: with --last or the
picker, Codex would read the prompt as a session ID."
  (let ((resume-id (claude-code-ide-start-spec-resume-id spec))
        (prompt (claude-code-ide-start-spec-prompt spec))
        (interactive (claude-code-ide-start-spec-interactive spec)))
    (cond
     (resume-id
      (claude-code-ide-codex--command instance args '("resume")
                                      (cons resume-id (and prompt (list prompt)))
                                      interactive))
     (prompt
      (user-error "Codex cannot take a first prompt with `codex resume --last' or the picker, because it reads the prompt as a session ID.  Resume a session ID, or type the prompt after the start"))
     ((claude-code-ide-start-spec-continue spec)
      (claude-code-ide-codex--command instance args '("resume" "--last") nil interactive))
     (t
      (claude-code-ide-codex--command instance args '("resume") nil interactive)))))

(defun claude-code-ide-codex--fork (instance spec args)
  "Return the command that starts INSTANCE in a fork of SPEC's resume ID.
Codex gives the fork a new native ID, which its first SessionStart
reports.  Until then, the native ID of INSTANCE is `unknown', so that
no prompt goes to the conversation that was forked."
  (let ((resume-id (claude-code-ide-start-spec-resume-id spec))
        (prompt (claude-code-ide-start-spec-prompt spec)))
    (unless resume-id
      (error "A fork needs the native ID of the conversation to fork"))
    (setf (claude-code-ide-instance-native-id instance) 'unknown)
    (claude-code-ide-codex--command instance args '("fork")
                                    (cons resume-id (and prompt (list prompt)))
                                    (claude-code-ide-start-spec-interactive spec))))

;;; Detection and exit

(defun claude-code-ide-codex--process-environment ()
  "Return `process-environment' for a Codex command that Emacs runs itself."
  (append (claude-code-ide-codex--removed-variables) process-environment))

(defun claude-code-ide-codex--detect (&optional with-version)
  "Find the Codex CLI; with WITH-VERSION, read `codex --version' too.
Return (:available BOOL :program PATH :version STRING-OR-unknown)."
  (let* ((found (executable-find claude-code-ide-codex-cli-path))
         (version (when (and found with-version)
                    (ignore-errors
                      (with-temp-buffer
                        (let ((process-environment (claude-code-ide-codex--process-environment)))
                          (call-process found nil t nil "--version"))
                        (string-trim (buffer-string)))))))
    (list :available (and found t)
          :program claude-code-ide-codex-cli-path
          :version (if (and (stringp version) (not (string-empty-p version)))
                       version
                     'unknown))))

(defun claude-code-ide-codex--exit-message (exit-code _spec program)
  "Return the message for a Codex CLI that ended with EXIT-CODE.
PROGRAM is the CLI that ran."
  (cond
   ((= exit-code 127)
    (format "Codex CLI not found (exit 127).  Ensure '%s' is in your PATH, or set `claude-code-ide-codex-cli-path'.  In Emacs, try: M-x exec-path-from-shell-initialize"
            program))
   ((= exit-code 126)
    (format "Codex CLI '%s' was found but is not executable (exit 126).  Check file permissions"
            program))
   (t
    (format "Codex ('%s') exited with error code %d" program exit-code))))

;;; Native ID

(defun claude-code-ide-codex--native-id (instance)
  "Return the native conversation ID of INSTANCE, or `unknown'.
A resume knows it at the start.  A new conversation and a fork get it
from the SessionStart hook, which Codex sends only at the first prompt."
  (claude-code-ide-or-unknown
   (claude-code-ide-known-or-nil (claude-code-ide-instance-native-id instance))))

(defun claude-code-ide-codex--note-session-start (event)
  "Take the native ID of a Codex instance from the SessionStart EVENT.
Each current SessionStart with a session ID sets it, so that a new
conversation in the same terminal (/new) gets the queued prompts.
Events of an earlier launch never arrive here, and the hook script
drops the events of nested sessions."
  (when (eq (plist-get event :event) 'session-start)
    (when-let* ((instance (claude-code-ide-instance-by-id (plist-get event :instance-id)))
                ((eq (claude-code-ide-instance-provider instance) 'codex))
                (id (claude-code-ide-codex--get (plist-get event :data) "session_id"))
                ((and (stringp id) (not (string-empty-p id)))))
      (setf (claude-code-ide-instance-native-id instance) id)
      (claude-code-ide-instance-set-property
       instance :codex-native-id-generation (plist-get event :generation)))))

;;; Transcripts

(defvar claude-code-ide-codex-rollout-recheck-seconds 60
  "Seconds after which a found rollout file is checked again.
`claude-code-ide-codex-rollout-file' then looks for a newer rollout
file of the same native ID, which Codex can write at a resume, and
takes the newest one by name.  It reads the day folders from the day
before the last check to today, and those of the creation time.")

(defvar claude-code-ide-codex-rollout-recheck-max-days 7
  "Days after which a recheck searches the whole sessions folder.
When more days passed since the last check of a found rollout file,
the recheck runs the full search one time, in place of a read of each
day folder; the cached file stays a candidate.  A value above 366
counts as 366, as the day folders of a recheck span at most a year.")

(defvar claude-code-ide-codex-rollout-miss-seconds 60
  "Seconds that a miss of the full search for a rollout file is kept.
In that time, `claude-code-ide-codex-rollout-file' searches the whole
sessions folder again for the same native ID only when the sessions
folder or the day folder of today changed.  The day folders are always
checked.")

(defvar claude-code-ide-codex-rollout-cache-limit 1000
  "Most entries of the rollout cache.
Each new entry first removes the oldest entries, a found file or a
miss, until there is room, also after the limit went down.  A limit of
0 or less keeps no entries.")

(defvar claude-code-ide-codex--rollout-cache (make-hash-table :test 'equal)
  "Rollout lookups by (SESSIONS-FOLDER . NATIVE-ID).
A value is (:file FILE :time TIME) for a found file, checked at TIME,
or (:miss TIME :stamp STAMP) after a full search that found no file;
STAMP is that of `claude-code-ide-codex--folders-stamp'.  Use
`claude-code-ide-codex--rollout-cache-put' to add an entry.")

(defun claude-code-ide-codex--rollout-cache-time (entry)
  "Return the time of the rollout cache ENTRY: its check or its miss."
  (or (plist-get entry :miss) (plist-get entry :time) 0))

(defun claude-code-ide-codex--rollout-cache-put (key value now)
  "Put VALUE under KEY in the rollout cache at time NOW.
First the misses that expired go.  Then the oldest entries go, a found
file or a miss, until the cache has room under
`claude-code-ide-codex-rollout-cache-limit', also when the limit went
down or the cache was too large before.  A limit of 0 or less keeps no
entries.  So the cache stays small however many IDs have no rollout."
  (let ((cache claude-code-ide-codex--rollout-cache)
        (limit claude-code-ide-codex-rollout-cache-limit))
    (if (<= limit 0)
        (clrhash cache)
      ;; The new value replaces the old one of KEY
      (remhash key cache)
      (maphash (lambda (other entry)
                 (when (and (plist-get entry :miss)
                            (>= (- now (plist-get entry :miss))
                                claude-code-ide-codex-rollout-miss-seconds))
                   (remhash other cache)))
               cache)
      (when (>= (hash-table-count cache) limit)
        (let ((entries nil))
          (maphash (lambda (other entry)
                     (push (cons (claude-code-ide-codex--rollout-cache-time entry) other) entries))
                   cache)
          (setq entries (sort entries (lambda (a b) (< (car a) (car b)))))
          (while (and entries (>= (hash-table-count cache) limit))
            (remhash (cdr (pop entries)) cache))))
      (puthash key value cache))))

(declare-function claude-code-ide-session-registry-cached "claude-code-ide-session-registry"
                  (kind file fn))
(declare-function claude-code-ide-session-registry-grep-last "claude-code-ide-session-registry"
                  (file &rest args))
(declare-function claude-code-ide-session-registry-grep-lines "claude-code-ide-session-registry"
                  (file &rest args))
(declare-function claude-code-ide-session-registry-line-field "claude-code-ide-session-registry"
                  (line field))

(defconst claude-code-ide-codex--uuid-regexp
  (concat "\\`[0-9a-fA-F]\\{8\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{4\\}"
          "-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{12\\}\\'")
  "A full UUID: the form of a Codex native conversation ID.")

(defun claude-code-ide-codex--uuid-p (native-id)
  "Return non-nil when NATIVE-ID is a full UUID."
  (and (stringp native-id) (string-match-p claude-code-ide-codex--uuid-regexp native-id)))

(defun claude-code-ide-codex--uuid7-time (native-id)
  "Return the creation time of NATIVE-ID in seconds, or nil.
Only a UUID version 7 holds a time: its first 48 bits are milliseconds
since the epoch."
  (when (and (stringp native-id)
             (string-match (concat "\\`\\([0-9a-fA-F]\\{8\\}\\)-\\([0-9a-fA-F]\\{4\\}\\)"
                                   "-7[0-9a-fA-F]\\{3\\}-[0-9a-fA-F]\\{4\\}-[0-9a-fA-F]\\{12\\}\\'")
                           native-id))
    (/ (string-to-number (concat (match-string 1 native-id) (match-string 2 native-id)) 16)
       1000.0)))

(defun claude-code-ide-codex--rollout-regexp (native-id)
  "Return the regexp of the name of the rollout file of NATIVE-ID.
The name is rollout-, the start time, -, the full native ID, .jsonl."
  (concat "\\`rollout-[0-9-]+T[0-9-]+-" (regexp-quote native-id) "\\.jsonl\\'"))

(defun claude-code-ide-codex--day-folder (sessions time)
  "Return the day folder of SESSIONS for TIME, in local time as Codex names it."
  (expand-file-name (format-time-string "%Y/%m/%d" time) sessions))

(defun claude-code-ide-codex--days (since now)
  "Return a time at noon of each day from the day before SINCE to the day of NOW.
Noon keeps each step of one day in its day, also at a change of the
daylight saving time."
  (let* ((day (decode-time (- since 86400)))
         (time (float-time (encode-time (list 0 0 12 (nth 3 day) (nth 4 day) (nth 5 day)
                                              nil -1 nil))))
         (today (format-time-string "%F" now))
         (times (list time)))
    (while (and (string< (format-time-string "%F" time) today) (< (length times) 400))
      (setq time (+ time 86400))
      (push time times))
    (nreverse times)))

(defun claude-code-ide-codex--day-folders (sessions native-id now &optional since)
  "Return the day folders of SESSIONS that can hold the rollout of NATIVE-ID.
They are the day before, the day of, and the day after the creation
time of a UUID version 7 ID, and the day of NOW, which holds the
rollout of a resume today.  With SINCE, the time of the last check,
they are also the folder of each day from the day before SINCE to the
day of NOW, so that a rollout of a day without a check counts."
  (delete-dups
   (append (when-let* ((time (claude-code-ide-codex--uuid7-time native-id)))
             (mapcar (lambda (offset)
                       (claude-code-ide-codex--day-folder sessions (+ time (* offset 86400))))
                     '(-1 0 1)))
           (mapcar (lambda (time) (claude-code-ide-codex--day-folder sessions time))
                   (if since (claude-code-ide-codex--days since now) (list now))))))

(defun claude-code-ide-codex--newest (files)
  "Return the last of FILES by name, or nil."
  (car (last (sort (delete-dups (delq nil (copy-sequence files))) #'string<))))

(defun claude-code-ide-codex--rollout-in-day-folders (sessions native-id now &optional since)
  "Return the newest rollout file of NATIVE-ID in its day folders, or nil.
The day folders are those of SESSIONS at NOW, after a check at SINCE;
see `claude-code-ide-codex--day-folders'."
  (let ((regexp (claude-code-ide-codex--rollout-regexp native-id)))
    (claude-code-ide-codex--newest
     (mapcan (lambda (dir)
               (and (file-directory-p dir) (directory-files dir t regexp t)))
             (claude-code-ide-codex--day-folders sessions native-id now since)))))

(defun claude-code-ide-codex--search-rollout (sessions native-id)
  "Return the newest rollout file of NATIVE-ID by name in all of SESSIONS, or nil."
  (claude-code-ide-codex--newest
   (directory-files-recursively sessions (claude-code-ide-codex--rollout-regexp native-id))))

(defun claude-code-ide-codex--folders-stamp (sessions now)
  "Return the modification times of SESSIONS and of its day folder at NOW."
  (mapcar (lambda (dir) (file-attribute-modification-time (file-attributes dir)))
          (list sessions (claude-code-ide-codex--day-folder sessions now))))

(defun claude-code-ide-codex--recent-miss-p (cached sessions now)
  "Return non-nil when CACHED is a miss that still holds at NOW.
A miss holds for `claude-code-ide-codex-rollout-miss-seconds', while
the folders of SESSIONS do not change."
  (and (plist-get cached :miss)
       (< (- now (plist-get cached :miss)) claude-code-ide-codex-rollout-miss-seconds)
       (equal (plist-get cached :stamp) (claude-code-ide-codex--folders-stamp sessions now))))

(defun claude-code-ide-codex-rollout-file (native-id &optional directory)
  "Return the absolute path of the rollout file of the conversation NATIVE-ID.
Return nil when NATIVE-ID is not a full UUID, or when no readable file
is found in the sessions folder of the Codex home.  DIRECTORY is the
working folder of the Codex session, for a relative CODEX_HOME; see
`claude-code-ide-codex-home'.  Codex writes the ID in lower case, so
an ID in upper case finds the same file.  Of several files, the newest
by name wins.  The lookup is cheap:
- The first lookup of NATIVE-ID (no cache entry) searches the whole
  sessions folder one time, and takes the newest match by name.
- After that, a found file is given from a cache.  After
  `claude-code-ide-codex-rollout-recheck-seconds', a recheck reads the
  day folders from the day before the last check to today, and the
  creation days of a UUID version 7 ID.  After more than
  `claude-code-ide-codex-rollout-recheck-max-days' days, it runs the
  full search one time instead.  The cached file stays a candidate.
- A miss of the full search is kept for
  `claude-code-ide-codex-rollout-miss-seconds', unless the sessions
  folder or the day folder of today changes.  In that time, only the
  day folders are checked.
- The cache is small: see `claude-code-ide-codex--rollout-cache-put'."
  (when (claude-code-ide-codex--uuid-p native-id)
    (let* ((native-id (downcase native-id))
           (sessions (expand-file-name "sessions" (claude-code-ide-codex-home directory)))
           (key (cons sessions native-id))
           (cached (gethash key claude-code-ide-codex--rollout-cache))
           (old (let ((file (plist-get cached :file)))
                  (and file (file-readable-p file) file)))
           (now (float-time)))
      (cond
       ((not (file-directory-p sessions)) nil)
       ((and old (< (- now (plist-get cached :time)) claude-code-ide-codex-rollout-recheck-seconds))
        old)
       (t
        (let* ((recent-miss (claude-code-ide-codex--recent-miss-p cached sessions now))
               (file (cond
                      ;; A recheck after a long time: the full search, and the old file
                      ((and old (> (- now (plist-get cached :time))
                                   (* (min claude-code-ide-codex-rollout-recheck-max-days 366)
                                      86400)))
                       (claude-code-ide-codex--newest
                        (list old (claude-code-ide-codex--search-rollout sessions native-id))))
                      ;; A recheck: the day folders since the day before the last check
                      (old (claude-code-ide-codex--newest
                            (list old (claude-code-ide-codex--rollout-in-day-folders
                                       sessions native-id now (plist-get cached :time)))))
                      ;; A miss that holds: only the cheap day folders
                      (recent-miss
                       (claude-code-ide-codex--rollout-in-day-folders sessions native-id now))
                      ;; The first lookup: the full search, so no older day folder wins
                      (t (claude-code-ide-codex--search-rollout sessions native-id)))))
          (cond
           ((and file (file-readable-p file))
            (claude-code-ide-codex--rollout-cache-put key (list :file file :time now) now)
            file)
           (t
            (unless recent-miss
              (claude-code-ide-codex--rollout-cache-put
               key (list :miss now :stamp (claude-code-ide-codex--folders-stamp sessions now)) now))
            nil))))))))

(defun claude-code-ide-codex--non-empty (value)
  "Return VALUE when it is a string that is not empty, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun claude-code-ide-codex--session-title (native-id &optional directory)
  "Return the last thread name of NATIVE-ID in the Codex session index, or nil.
The index is session_index.jsonl in the Codex home: one short line for
each name that a conversation gets.  DIRECTORY is as for
`claude-code-ide-codex-rollout-file'."
  (require 'claude-code-ide-session-registry)
  (let ((file (expand-file-name "session_index.jsonl" (claude-code-ide-codex-home directory)))
        (native-id (and (stringp native-id) (downcase native-id))))
    (when (and native-id (file-readable-p file))
      (claude-code-ide-session-registry-cached
       (list 'codex-title native-id) file
       (lambda (file)
         (let ((line (claude-code-ide-session-registry-grep-last
                      file "-F" (format "\"id\":\"%s\"" native-id))))
           (and (equal (claude-code-ide-session-registry-line-field line 'id) native-id)
                (claude-code-ide-codex--non-empty
                 (claude-code-ide-session-registry-line-field line 'thread_name)))))))))

(defun claude-code-ide-codex--model-of-matches (lines)
  "Return the model of the last turn_context record in the grep LINES, or nil.
LINES come from grep -n -o: \"N:\\\"type\\\":\\\"turn_context\\\"\" marks the
record on line N, and the first \"N:\\\"model\\\":\\\"M\\\"\" of that line
gives its model M."
  (let ((record nil) (model nil))
    (dolist (line lines)
      (when (string-match "\\`\\([0-9]+\\):\\(.*\\)\\'" line)
        (let ((number (match-string 1 line)) (match (match-string 2 line)))
          (cond
           ((string-prefix-p "\"type\"" match)
            (setq record number model nil))
           ((and (equal number record) (null model)
                 (string-match "\\`\"model\":\"\\([^\"]*\\)\"\\'" match))
            (setq model (match-string 1 match)))))))
    (claude-code-ide-codex--non-empty model)))

(defun claude-code-ide-codex--rollout-model (file)
  "Return the model of the last turn_context record of the rollout FILE, or nil.
grep prints only the short matches, never the whole records, which can
be large."
  (require 'claude-code-ide-session-registry)
  (claude-code-ide-session-registry-cached
   'codex-model file
   (lambda (file)
     (claude-code-ide-codex--model-of-matches
      (claude-code-ide-session-registry-grep-lines
       file "-n" "-o" "-E" "\"type\":\"turn_context\"|\"model\":\"[^\"]*\"")))))

(defun claude-code-ide-codex--transcript (instance what)
  "Return WHAT of the rollout of the conversation of INSTANCE, or `unknown'.
WHAT is `file' (the absolute path of the rollout file), `title' (from
the session index) or `model' (from the rollout file).  INSTANCE can be
a detached descriptor that holds only a native ID."
  (unless (memq what '(file title model))
    (error "Unknown transcript value: %S" what))
  (let ((native (claude-code-ide-known-or-nil (claude-code-ide-codex--native-id instance)))
        ;; The working folder of the session, for a relative CODEX_HOME
        (directory (or (claude-code-ide-known-or-nil (claude-code-ide-instance-worktree instance))
                       (claude-code-ide-known-or-nil
                        (claude-code-ide-instance-project-root instance)))))
    (claude-code-ide-or-unknown
     (and native
          (if (eq what 'title)
              (claude-code-ide-codex--session-title native directory)
            (when-let* ((file (claude-code-ide-codex-rollout-file native directory)))
              (if (eq what 'file) file (claude-code-ide-codex--rollout-model file))))))))

(defun claude-code-ide-codex--map-event (provider-event data)
  "Return the common event of the Codex hook event PROVIDER-EVENT with DATA.
The Codex event adapter of the `codex-status' part maps it, when it is
loaded."
  (if (fboundp 'claude-code-ide-codex-events-map-event)
      (funcall 'claude-code-ide-codex-events-map-event provider-event data)
    (cond
     ((cdr (assoc provider-event claude-code-ide-codex--event-map)))
     ((and (equal provider-event "PostModelRequest")
           (equal (claude-code-ide-codex--get data "status") "failed"))
      'turn-failed)
     (t 'other))))

;;; Prompts

(defun claude-code-ide-codex--queue-finished (instance result process buffer)
  "Record in RESULT how the `codex queue' PROCESS of INSTANCE ended.
BUFFER holds its output.  Then call `claude-code-ide-codex-queue-functions'."
  (let ((output (if (buffer-live-p buffer)
                    (with-current-buffer buffer (string-trim (buffer-string)))
                  "")))
    (cond
     ((process-get process 'claude-code-ide-codex-timeout)
      (plist-put result :outcome 'timeout))
     ((and (eq (process-status process) 'exit) (eq (process-exit-status process) 0))
      (plist-put result :outcome 'queued)
      (when (string-match "Queued message \\([^ \t\n]+\\)" output)
        (plist-put result :message-id (match-string 1 output))))
     (t
      (plist-put result :outcome 'failed)
      (plist-put result :exit (process-exit-status process))))
    (unless (eq (plist-get result :outcome) 'queued)
      (message "codex queue %s for thread %s: %s"
               (plist-get result :outcome) (plist-get result :thread) output))
    (when (buffer-live-p buffer) (kill-buffer buffer))
    (claude-code-ide--run-session-hook 'claude-code-ide-codex-queue-functions instance result)))

(defun claude-code-ide-codex--submit-prompt (instance text)
  "Queue TEXT for the conversation of INSTANCE with `codex queue'.
Codex delivers it when the conversation is idle, also after a running
turn or a dialog, and at the next resume when no CLI runs.

The command runs in the background, so Emacs does not wait for it.
Return (:status queued :thread ID :outcome pending :message-id unknown
:exit nil) at once.  When the command ends, :outcome becomes `queued'
\(with the :message-id), `failed' (with the :exit code) or `timeout'
\(after `claude-code-ide-codex-queue-timeout'), in the same list, and
`claude-code-ide-codex-queue-functions' run.

Return nil when the command cannot start, or when INSTANCE has no
native ID: a new conversation gets it only at its first prompt."
  (let ((thread (claude-code-ide-known-or-nil (claude-code-ide-codex--native-id instance))))
    (if (not thread)
        (progn
          (message "This Codex session has no conversation ID yet.  Type its first prompt in the terminal")
          nil)
      (let* ((result (list :status 'queued :thread thread :outcome 'pending
                           :message-id 'unknown :exit nil))
             (buffer (generate-new-buffer " *cci-codex-queue*"))
             (root (claude-code-ide-known-or-nil (claude-code-ide-instance-project-root instance)))
             (process
              (condition-case err
                  (let ((default-directory (if (and root (file-directory-p root))
                                               root
                                             default-directory))
                        (process-environment (claude-code-ide-codex--process-environment)))
                    ;; One word for each option value, so that a text that
                    ;; starts with "-" is not read as an option
                    (make-process :name "cci-codex-queue"
                                  :buffer buffer
                                  :command (list claude-code-ide-codex-cli-path "queue"
                                                 (concat "--thread=" thread)
                                                 (concat "--message=" text))
                                  :connection-type 'pipe
                                  :noquery t
                                  :sentinel #'ignore))
                (error
                 (kill-buffer buffer)
                 (message "codex queue could not start: %s" (error-message-string err))
                 nil))))
        (when process
          (process-send-eof process)
          (let ((timer (run-at-time claude-code-ide-codex-queue-timeout nil
                                    (lambda ()
                                      (when (process-live-p process)
                                        (process-put process 'claude-code-ide-codex-timeout t)
                                        (delete-process process))))))
            (set-process-sentinel
             process
             (lambda (proc _event)
               (unless (process-live-p proc)
                 (cancel-timer timer)
                 (claude-code-ide-codex--queue-finished instance result proc buffer)))))
          result)))))

;;; Dialogs on the screen

(defun claude-code-ide-codex--display-frame-p (frame)
  "Return non-nil when FRAME is on a display, visible or not.
The initial frame of a daemon, and the frame of batch Emacs, are on the
terminal \"initial_terminal\": they show nothing to anybody.  That
frame says that it is visible, so `frame-visible-p' cannot tell."
  (and (frame-live-p frame)
       (not (equal (terminal-name (frame-terminal frame)) "initial_terminal"))))

(defun claude-code-ide-codex--display-windows (buffer)
  "Return the windows of BUFFER on frames of a display, visible or not.
See `claude-code-ide-codex--display-frame-p'."
  (and (buffer-live-p buffer)
       (cl-remove-if-not (lambda (window)
                           (claude-code-ide-codex--display-frame-p (window-frame window)))
                         (get-buffer-window-list buffer nil t))))

(defun claude-code-ide-codex-screen-window (buffer)
  "Return a window of BUFFER on a frame of a display, or nil.
A frame that is not visible counts: the terminal keeps the size of its
window.  See `claude-code-ide-codex-screen-whole-p' for when a read of
the screen sees all of it."
  (car (claude-code-ide-codex--display-windows buffer)))

(defun claude-code-ide-codex--terminal-lines (buffer)
  "Return the number of lines of the terminal screen of BUFFER, or nil.
eat gives its terminal size (`eat-term-size' of `eat-terminal'), and
ghostel its rows (`ghostel--term-rows').  vterm keeps its size in its
module, so it gives nil."
  (with-current-buffer buffer
    (let ((lines (cond
                  ((and (local-variable-p 'eat-terminal) (fboundp 'eat-term-size))
                   (cdr-safe (ignore-errors
                               (funcall 'eat-term-size (buffer-local-value 'eat-terminal buffer)))))
                  ((local-variable-p 'ghostel--term-rows)
                   (buffer-local-value 'ghostel--term-rows buffer)))))
      (and (integerp lines) (> lines 0) lines))))

(defun claude-code-ide-codex--size-function (buffer)
  "Return the value of `window-adjust-process-window-size-function' in BUFFER."
  (buffer-local-value 'window-adjust-process-window-size-function buffer))

(defun claude-code-ide-codex--known-size-function-p (buffer)
  "Return non-nil when BUFFER sizes its terminal by the smallest or largest window."
  (memq (claude-code-ide-codex--size-function buffer)
        '(window-adjust-process-window-size-smallest
          window-adjust-process-window-size-largest)))

(defun claude-code-ide-codex--window-lines (windows)
  "Return the terminal height that the WINDOWS of a terminal give it, or nil.
Emacs sizes the terminal with `window-adjust-process-window-size-function'
of the buffer: the smallest window by default, the largest with
`window-adjust-process-window-size-largest'.  Another function counts
as the smallest."
  (when windows
    (let ((heights (mapcar #'window-body-height windows)))
      (apply (if (eq (claude-code-ide-codex--size-function (window-buffer (car windows)))
                     #'window-adjust-process-window-size-largest)
                 #'max
               #'min)
             heights))))

(defun claude-code-ide-codex-screen-whole-p (buffer)
  "Return non-nil when a read of BUFFER sees the whole terminal screen.
That needs a window of a display (`claude-code-ide-codex-screen-window'),
and a sure size of the screen: the size that the backend gives
\(`claude-code-ide-codex--terminal-lines'), else one height of all the
windows of a display.  Windows of other heights, without a size of the
backend, make the size unsure: the read can cover another part than
the terminal screen.  So does a `window-adjust-process-window-size-function'
other than the smallest or the largest: it can give the terminal more
lines than the windows have."
  (let ((windows (claude-code-ide-codex--display-windows buffer)))
    (and windows
         (or (claude-code-ide-codex--terminal-lines buffer)
             (and (claude-code-ide-codex--known-size-function-p buffer)
                  (null (cdr (delete-dups (mapcar #'window-body-height windows))))))
         t)))

(defun claude-code-ide-codex--screen-text (buffer)
  "Return the text of the terminal screen of BUFFER.
The screen is the last lines of the buffer: as many as the terminal has
when the backend says it (`claude-code-ide-codex--terminal-lines'),
else as many as the windows of a display give the terminal
\(`claude-code-ide-codex--window-lines'), else
`claude-code-ide-codex--screen-lines'."
  (with-current-buffer buffer
    (let ((lines (or (claude-code-ide-codex--terminal-lines buffer)
                     (claude-code-ide-codex--window-lines
                      (claude-code-ide-codex--display-windows buffer))
                     claude-code-ide-codex--screen-lines)))
      (save-excursion
        (goto-char (point-max))
        ;; Trailing empty lines of the buffer are part of the screen
        (forward-line (- 1 lines))
        (buffer-substring-no-properties (line-beginning-position) (point-max))))))

(defun claude-code-ide-codex-screen-dialog (buffer)
  "Return the kind of the Codex dialog that the terminal BUFFER shows, or nil.
The kind is `folder-trust', `update', `hooks-review', `approval', or
`other' for another list of numbered choices.  This reads only the
text of the screen.  It never sends keys."
  (when (buffer-live-p buffer)
    (let* ((text (claude-code-ide-codex--screen-text buffer))
           ;; A narrow terminal wraps the dialog text at spaces
           (flat (replace-regexp-in-string "[ \t\n]+" " " text))
           (case-fold-search nil))
      (or (car (cl-find-if (lambda (entry)
                             (cl-some (lambda (regexp) (string-match-p regexp flat))
                                      (cdr entry)))
                           claude-code-ide-codex--dialog-patterns))
          (and (string-match-p "^[ \t]*› [0-9]+\\. " text)
               (string-match-p "^[ \t]+[0-9]+\\. " text)
               'other)))))

;;; Commands

(defun claude-code-ide-codex--start (&optional continue resume interactive)
  "Start a Codex instance for the current project.
CONTINUE, RESUME and INTERACTIVE are as for
`claude-code-ide--start-session'.  Codex becomes the current provider,
as the menu toggle makes it."
  (claude-code-ide-set-current-provider 'codex)
  (let ((claude-code-ide-default-provider 'codex))
    (claude-code-ide--start-session continue resume nil interactive)))

;;;###autoload
(defun claude-code-ide-codex ()
  "Start a Codex instance for the current project.
A project can run Codex and Claude Code instances at the same time.
With a prefix argument, or when the project has instances, ask for an
instance name.  When the Codex status hooks are not trusted yet, the
start offers to trust them."
  (interactive)
  (claude-code-ide-codex--start nil nil (called-interactively-p 'any)))

;;;###autoload
(defun claude-code-ide-codex-continue ()
  "Start a Codex instance that continues the most recent conversation."
  (interactive)
  (claude-code-ide-codex--start t nil (called-interactively-p 'any)))

;;;###autoload
(defun claude-code-ide-codex-resume ()
  "Start a Codex instance with the picker of earlier conversations."
  (interactive)
  (claude-code-ide-codex--start nil t (called-interactively-p 'any)))

;;; The provider

(defconst claude-code-ide-codex--provider
  (claude-code-ide-register-provider
   (claude-code-ide-provider-create
    :name 'codex
    :display-name "Codex"
    :buffer-name-prefix "codex"
    :detect #'claude-code-ide-codex--detect
    :launch #'claude-code-ide-codex--launch
    :resume #'claude-code-ide-codex--resume
    :fork #'claude-code-ide-codex--fork
    :submit-prompt #'claude-code-ide-codex--submit-prompt
    ;; Killing the buffer ends `codex --no-daemon' and its children
    :stop #'claude-code-ide--claude-stop
    :native-id #'claude-code-ide-codex--native-id
    :map-event #'claude-code-ide-codex--map-event
    :mcp-setup #'claude-code-ide-codex--mcp-setup
    :transcript #'claude-code-ide-codex--transcript
    :exit-message #'claude-code-ide-codex--exit-message
    ;; A Codex restore gets no flags: the Codex options give the Codex
    ;; flags and the model, never the Claude Code --model and --name
    :restore-flags nil))
  "The provider of the Codex CLI.")

(add-hook 'claude-code-ide-event-functions #'claude-code-ide-codex--note-session-start)

(provide 'claude-code-ide-codex)

;;; claude-code-ide-codex.el ends here
