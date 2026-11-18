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

(defcustom claude-code-ide-codex-cli-extra-flags ""
  "Additional flags for the Codex CLI, as one string.
For example \"--model gpt-5.6-terra\".  The flags come after the
flags of the package.  The Codex commands use this option instead of
`claude-code-ide-cli-extra-flags', which holds Claude Code flags."
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
The launch removes them, so that an Emacs that runs inside a Codex
tool shell does not start sessions that look nested.")

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
              "Yes, just this once" "No, and tell Codex what to do differently"))
  "Text patterns of the Codex dialogs, as (KIND REGEXP...).
The first kind with a matching regexp wins.  The texts are those of
Codex 0.164.0.")

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

;;; Instructions

(defun claude-code-ide-codex--developer-instructions ()
  "Return the developer instructions: the Emacs prompt and the user's prompt.
The user's prompt is `claude-code-ide-system-prompt', as for Claude Code."
  (if claude-code-ide-system-prompt
      (concat claude-code-ide-codex--emacs-prompt "\n\n" claude-code-ide-system-prompt)
    claude-code-ide-codex--emacs-prompt))

;;; MCP setup

(defun claude-code-ide-codex--header-variable (header)
  "Return the name of the variable that holds the value of HEADER."
  (concat claude-code-ide-codex--header-variable-prefix
          (upcase (replace-regexp-in-string "[^A-Za-z0-9]" "_" header))))

(defun claude-code-ide-codex--all-tool-names ()
  "Return the names of all registered MCP tools.
This reads the tool list itself, so that no advice of
`claude-code-ide-mcp-server-get-tool-names' removes a name."
  (mapcar (lambda (tool-spec)
            (let ((normalized (claude-code-ide--normalize-tool-spec tool-spec)))
              (or (plist-get normalized :name)
                  (symbol-name (plist-get normalized :function)))))
          claude-code-ide-mcp-server-tools))

(defun claude-code-ide-codex--approved-tool-names ()
  "Return the MCP tools that Codex may call without approval.
This follows `claude-code-ide-mcp-allowed-tools', as for Claude Code:
`auto' gives the result of `claude-code-ide-mcp-server-get-tool-names',
after its advice (an advice can remove a tool, such as `emacs_eval'),
nil gives none, and a list or a string gives the tools that it names."
  (let ((prefix "mcp__emacs-tools__"))
    (mapcar (lambda (name)
              (if (string-prefix-p prefix name) (substring name (length prefix)) name))
            (pcase claude-code-ide-mcp-allowed-tools
              ('auto (claude-code-ide-mcp-server-get-tool-names))
              ('nil nil)
              ((pred stringp) (split-string claude-code-ide-mcp-allowed-tools nil t))
              ((pred listp) claude-code-ide-mcp-allowed-tools)))))

(defun claude-code-ide-codex--approval-args (server)
  "Return the -c arguments of the tool approvals of the MCP SERVER key.
Each tool that `claude-code-ide-codex--approved-tool-names' leaves out
gets approval_mode \"prompt\", and the other tools are approved.  When
no tool is approved, or when a tool to prompt for has a name that a
dotted key cannot hold, every tool needs an approval."
  (let* ((approved (claude-code-ide-codex--approved-tool-names))
         (prompted (cl-remove-if (lambda (name) (member name approved))
                                 (claude-code-ide-codex--all-tool-names))))
    (if (or (null approved)
            (cl-notevery #'claude-code-ide-codex--bare-key-p prompted))
        (claude-code-ide-codex--config-arg
         (concat server ".default_tools_approval_mode") "\"prompt\"")
      (append (claude-code-ide-codex--config-arg
               (concat server ".default_tools_approval_mode") "\"approve\"")
              (mapcan (lambda (name)
                        (claude-code-ide-codex--config-arg
                         (format "%s.tools.%s.approval_mode" server name) "\"prompt\""))
                      prompted)))))

(defun claude-code-ide-codex--mcp-setup (instance)
  "Return the MCP config of INSTANCE for Codex, or nil.
The result is (:args ARGS :environment ENTRIES).  ARGS are -c
arguments for the tools server of INSTANCE's MCP session.  The config
comes from `claude-code-ide-mcp-server-get-config', after its advice
ran, so headers that an advice adds stay.  Each header value goes
into a variable of ENTRIES, which `env_http_headers' names and
`shell_environment_policy.exclude' hides from the model's shell
commands, so that the value is not in the argument list."
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
           (variables (mapcar #'cadr headers)))
      (list :args (append
                   (claude-code-ide-codex--config-arg
                    (concat key ".url") (claude-code-ide-codex--toml-string url))
                   (when headers
                     (append
                      (claude-code-ide-codex--config-arg
                       (concat key ".env_http_headers")
                       (claude-code-ide-codex--toml-table
                        (mapcar (lambda (header) (cons (car header) (cadr header))) headers)))
                      (claude-code-ide-codex--config-arg
                       "shell_environment_policy.exclude"
                       (claude-code-ide-codex--toml-array variables))))
                   (claude-code-ide-codex--approval-args key))
            :environment (mapcar (lambda (header) (format "%s=%s" (cadr header) (nth 2 header)))
                                 headers)))))

;;; Launch

(defun claude-code-ide-codex--hook-args (instance)
  "Return the status hook arguments of INSTANCE, or nil.
The `codex-status' part gives them, when it is loaded."
  (when (fboundp 'claude-code-ide-codex-status-hook-args)
    (funcall 'claude-code-ide-codex-status-hook-args instance)))

(defun claude-code-ide-codex--hook-env (instance)
  "Return the status hook environment entries of INSTANCE, or nil."
  (when (fboundp 'claude-code-ide-codex-status-hook-env)
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

(defun claude-code-ide-codex--command (instance spec args subcommand positional)
  "Return (:command :environment) for INSTANCE as SPEC says.
SUBCOMMAND is a list of words after the program, such as (\"resume\").
Then come the common arguments, the MCP arguments, the hook arguments,
SPEC's extra flags (as they are), and ARGS.  POSITIONAL, a list of
words such as a native ID and a prompt, comes last after \"--\", so
that no option takes it as a value and no word of it is a subcommand."
  (let* ((mcp (claude-code-ide-codex--mcp-setup instance))
         (flags (claude-code-ide-start-spec-extra-flags spec))
         (words (append subcommand
                        (claude-code-ide-codex--common-args)
                        (plist-get mcp :args)
                        (claude-code-ide-codex--hook-args instance))))
    (list :command (concat
                    (mapconcat #'shell-quote-argument
                               (cons claude-code-ide-codex-cli-path words) " ")
                    (when (and flags (not (string-empty-p (string-trim flags))))
                      (concat " " (string-trim flags)))
                    (mapconcat (lambda (arg) (concat " " (shell-quote-argument arg))) args "")
                    (when positional
                      (concat " --" (mapconcat (lambda (word)
                                                 (concat " " (shell-quote-argument word)))
                                               positional ""))))
          :environment (claude-code-ide-codex--environment
                        instance (plist-get mcp :environment)))))

(defun claude-code-ide-codex--launch (instance spec args)
  "Return the command and the environment of a new Codex conversation.
INSTANCE is the descriptor, SPEC the start spec, and ARGS the caller's
extra arguments.  SPEC's prompt is the first prompt."
  (let ((prompt (claude-code-ide-start-spec-prompt spec)))
    (claude-code-ide-codex--command instance spec args nil (and prompt (list prompt)))))

(defun claude-code-ide-codex--resume (instance spec args)
  "Return the command that resumes a Codex conversation of INSTANCE.
SPEC's resume ID gives `codex resume ID', its continue flag `codex
resume --last', and its resume flag the picker of `codex resume'.
Only a resume of an ID can take SPEC's prompt: with --last or the
picker, Codex would read the prompt as a session ID."
  (let ((resume-id (claude-code-ide-start-spec-resume-id spec))
        (prompt (claude-code-ide-start-spec-prompt spec)))
    (cond
     (resume-id
      (claude-code-ide-codex--command instance spec args '("resume")
                                      (cons resume-id (and prompt (list prompt)))))
     (prompt
      (user-error "Codex takes a first prompt only with the session ID to resume"))
     ((claude-code-ide-start-spec-continue spec)
      (claude-code-ide-codex--command instance spec args '("resume" "--last") nil))
     (t
      (claude-code-ide-codex--command instance spec args '("resume") nil)))))

(defun claude-code-ide-codex--fork (instance spec args)
  "Return the command that starts INSTANCE in a fork of SPEC's resume ID.
Codex gives the fork a new native ID, which its SessionStart reports."
  (let ((resume-id (claude-code-ide-start-spec-resume-id spec))
        (prompt (claude-code-ide-start-spec-prompt spec)))
    (unless resume-id
      (error "A fork needs the native ID of the conversation to fork"))
    (claude-code-ide-codex--command instance spec args '("fork")
                                    (cons resume-id (and prompt (list prompt))))))

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
A resume knows it at the start.  A new conversation gets it from the
SessionStart hook, which Codex sends only at the first prompt."
  (claude-code-ide-or-unknown
   (claude-code-ide-known-or-nil (claude-code-ide-instance-native-id instance))))

(defun claude-code-ide-codex--note-session-start (event)
  "Take the native ID of a Codex instance from the SessionStart EVENT.
Only the first SessionStart of each launch generation counts, so that
a nested session that sends events cannot change the ID."
  (when (eq (plist-get event :event) 'session-start)
    (when-let* ((instance (claude-code-ide-instance-by-id (plist-get event :instance-id)))
                ((eq (claude-code-ide-instance-provider instance) 'codex))
                (generation (plist-get event :generation))
                (id (claude-code-ide-codex--get (plist-get event :data) "session_id"))
                ((and (stringp id) (not (string-empty-p id)))))
      (let ((seen (claude-code-ide-instance-property instance :codex-native-id-generation)))
        (unless (and (integerp seen) (>= seen generation))
          (setf (claude-code-ide-instance-native-id instance) id)
          (claude-code-ide-instance-set-property
           instance :codex-native-id-generation generation))))))

(defun claude-code-ide-codex--map-event (provider-event data)
  "Return the common event of the Codex hook event PROVIDER-EVENT with DATA."
  (cond
   ((cdr (assoc provider-event claude-code-ide-codex--event-map)))
   ((and (equal provider-event "PostModelRequest")
         (equal (claude-code-ide-codex--get data "status") "failed"))
    'turn-failed)
   (t 'other)))

;;; Prompts

(defun claude-code-ide-codex--submit-prompt (instance text)
  "Queue TEXT for the conversation of INSTANCE with `codex queue'.
Codex delivers it when the conversation is idle, also after a running
turn or a dialog, and at the next resume when no CLI runs.  Return
\(:status queued :thread ID :message-id ID-OR-unknown) when Codex took
the text, else nil.  A new conversation has no native ID before its
first prompt, so it cannot take a queued text yet."
  (let ((thread (claude-code-ide-known-or-nil (claude-code-ide-codex--native-id instance))))
    (if (not thread)
        (progn
          (message "This Codex session has no conversation ID yet.  Type its first prompt in the terminal")
          nil)
      (with-temp-buffer
        (let* ((root (claude-code-ide-known-or-nil (claude-code-ide-instance-project-root instance)))
               (default-directory (if (and root (file-directory-p root)) root default-directory))
               (process-environment (claude-code-ide-codex--process-environment))
               (status (condition-case err
                           (call-process claude-code-ide-codex-cli-path nil t nil
                                         "queue" "--thread" thread "--message" text)
                         (error (error-message-string err))))
               (output (string-trim (buffer-string))))
          (if (eq status 0)
              (list :status 'queued
                    :thread thread
                    :message-id (if (string-match "Queued message \\([^ \t\n]+\\)" output)
                                    (match-string 1 output)
                                  'unknown))
            (message "codex queue failed (%s): %s" status output)
            nil))))))

(defun claude-code-ide-codex--stop (instance)
  "End the CLI of INSTANCE by killing its terminal buffer.
With --no-daemon, this ends Codex and its child processes.  Return
non-nil when INSTANCE had a session."
  (when-let* ((session (claude-code-ide-instance-session instance)))
    (claude-code-ide--stop-session session)
    t))

;;; Dialogs on the screen

(defun claude-code-ide-codex--screen-text (buffer)
  "Return the text of the terminal screen of BUFFER.
The screen is the last lines of the buffer, as many as the window that
shows BUFFER has, else `claude-code-ide-codex--screen-lines'."
  (with-current-buffer buffer
    (let* ((window (get-buffer-window buffer t))
           (lines (if window (window-body-height window) claude-code-ide-codex--screen-lines)))
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

(defun claude-code-ide-codex--start (&optional continue resume)
  "Start a Codex instance for the current project.
CONTINUE and RESUME are as for `claude-code-ide--start-session'."
  (let ((claude-code-ide-default-provider 'codex)
        (claude-code-ide-cli-extra-flags claude-code-ide-codex-cli-extra-flags))
    (claude-code-ide--start-session continue resume)))

;;;###autoload
(defun claude-code-ide-codex ()
  "Start a Codex instance for the current project.
A project can run Codex and Claude Code instances at the same time.
With a prefix argument, or when the project has instances, ask for an
instance name."
  (interactive)
  (claude-code-ide-codex--start))

;;;###autoload
(defun claude-code-ide-codex-continue ()
  "Start a Codex instance that continues the most recent conversation."
  (interactive)
  (claude-code-ide-codex--start t))

;;;###autoload
(defun claude-code-ide-codex-resume ()
  "Start a Codex instance with the picker of earlier conversations."
  (interactive)
  (claude-code-ide-codex--start nil t))

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
    :stop #'claude-code-ide-codex--stop
    :native-id #'claude-code-ide-codex--native-id
    :map-event #'claude-code-ide-codex--map-event
    :mcp-setup #'claude-code-ide-codex--mcp-setup
    :exit-message #'claude-code-ide-codex--exit-message))
  "The provider of the Codex CLI.")

(add-hook 'claude-code-ide-event-functions #'claude-code-ide-codex--note-session-start)

(provide 'claude-code-ide-codex)

;;; claude-code-ide-codex.el ends here
