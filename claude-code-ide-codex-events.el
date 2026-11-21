;;; claude-code-ide-codex-events.el --- Status events of Codex instances  -*- lexical-binding: t; -*-

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

;; The Codex event adapter: it gives each Codex instance its status
;; hooks, reads the events that they record, and maps them to the
;; common events and the common states.
;;
;; A Codex launch passes the hooks with `-c hooks.<Event>=[...]'
;; (`claude-code-ide-codex-status-hook-args').  Each hook runs one fixed
;; command: the hook script and the event name.  The instance ID, the
;; launch generation and the events folder come from the environment of
;; the terminal (`claude-code-ide-codex-status-hook-env').  Codex trusts
;; a hook by a hash of its definition and its position, so the commands
;; and their order never change.
;;
;; Codex runs a hook only after the user trusts it, and skips an
;; untrusted hook without a message.  So each start settles the trust
;; before the spawn: a cached trusted result, else the app-server call
;; `hooks/list'.  An interactive start with untrusted hooks shows the
;; hook commands and, after a yes, writes the trust through the
;; app-server; other starts never ask, and run without hooks.
;; `claude-code-ide-codex-trust-hooks' trusts the hooks by hand.
;;
;; The hook script is in a private folder (mode 0700).  Codex does not
;; hash the script, so Emacs writes it atomically and checks its
;; content at each launch.  docs/status-events.md describes the script,
;; the event files and the mapping of each event.
;;
;; An instance without hooks gets its state from the rollout file of
;; its conversation, which the Codex provider finds: the last turn
;; record tells whether a turn runs, ended, or failed.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'filenotify)
(require 'claude-code-ide)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-session-status)
(require 'claude-code-ide-transcript)

;;; Customization

(defcustom claude-code-ide-codex-events-program "codex"
  "Codex program that runs the app-server for the hook trust check."
  :type 'string
  :group 'claude-code-ide)

(defcustom claude-code-ide-codex-events-trust-timeout 5
  "Seconds that a start waits for the hook trust check of the Codex app-server.
When the app-server does not answer in time, the start goes on
without waiting, with the status detail \"Hook trust unknown\", and
the check goes on in the background."
  :type 'number
  :group 'claude-code-ide)

(defcustom claude-code-ide-codex-events-startup-grace 3
  "Seconds after a launch before the screen is read for a startup dialog."
  :type 'number
  :group 'claude-code-ide)

(defcustom claude-code-ide-codex-events-approval-guess-time 10
  "Seconds after which an approval that no screen read confirms is a guess.
No hook event shows that the user allowed a command; the next event
comes when the command ends.  So a long approved command looks like a
pending approval."
  :type 'number
  :group 'claude-code-ide)

;;; Constants

(defconst claude-code-ide-codex-events--events
  '("SessionStart" "SessionEnd" "UserPromptSubmit" "Stop" "Interrupt"
    "PreToolUse" "PermissionRequest" "PostToolUse" "PostModelRequest"
    "SubagentStart" "SubagentStop")
  "Codex hook events that the status uses, in the order of the hook arguments.
Codex keeps the trust of a hook under a key with its event and its
position, so the definition of each event must never change.")

(defconst claude-code-ide-codex-events--event-map
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
PostModelRequest is `turn-failed' when its status is \"failed\".")

(defconst claude-code-ide-codex-events--question-tool "request_user_input"
  "Codex tool that asks the user structured questions.")

(defconst claude-code-ide-codex-events--script-name "claude-code-ide-codex-status-hook.sh"
  "File name of the Codex hook script.")

(defconst claude-code-ide-codex-events--script
  "#!/bin/sh
# claude-code-ide Codex status hook: stores the input of one Codex hook
# for Emacs.  Argument: EVENT.  Environment: CCI_INSTANCE_ID,
# CCI_GENERATION and CCI_EVENTS_DIR.  It prints nothing and always
# exits 0, so it never changes what Codex does.
exec 2>/dev/null >/dev/null
# A nested Codex session has CODEX_THREAD_ID; it is not the instance
if [ -n \"${CODEX_THREAD_ID:-}\" ] || [ -z \"${CCI_INSTANCE_ID:-}\" ]; then
  cat >/dev/null
  exit 0
fi
event=$1
id=$CCI_INSTANCE_ID
gen=${CCI_GENERATION:-}
dir=${CCI_EVENTS_DIR:-}
case $id in ''|*[!A-Za-z0-9-]*) cat >/dev/null; exit 0 ;; esac
case $gen in ''|*[!0-9]*) cat >/dev/null; exit 0 ;; esac
case $event in ''|*[!A-Za-z]*) cat >/dev/null; exit 0 ;; esac
if [ ! -d \"$dir\" ]; then cat >/dev/null; exit 0; fi
launch=\"$id.$gen\"
(
  umask 077
  tmp=$(mktemp \"$dir/.$launch.in.XXXXXX\") || exit 0
  {
    printf '{\"event\":\"%s\",\"instance_id\":\"%s\",\"generation\":\"%s\",\"input\":' \"$event\" \"$id\" \"$gen\"
    cat
    printf '}\\n'
  } > \"$tmp\" || { rm -f \"$tmp\"; exit 0; }
  # Number the events of this launch in the order they are published
  lock=\"$dir/.$launch.lock\"
  seqfile=\"$dir/.$launch.seq\"
  prefix=\"$dir/$launch.\"
  suffix=\".$event.json\"
@LOCK_LOOP@
)
exit 0
"
  "Template of the script that each Codex status hook runs.
`claude-code-ide-codex-events--script-text' fills in the lock loop.")

(defun claude-code-ide-codex-events--script-text ()
  "Return the Codex hook script, with the current time limit.
The limit is in the script, not in the hook command, so a change of it
needs no new trust: Codex trusts the hook command."
  (claude-code-ide-session-status--fill-script claude-code-ide-codex-events--script))

;;; Data

(cl-defstruct (claude-code-ide-codex-events--blocker
               (:constructor claude-code-ide-codex-events--blocker-create)
               (:copier nil))
  "Something that stops a Codex instance until the user answers."
  (kind 'approval :type symbol :documentation "`approval' or `question'.")
  (tool nil :documentation "(AGENT-ID . TOOL-USE-ID) of the tool, or nil.")
  (detail "" :type string)
  (since 0.0 :type float)
  (answered nil :documentation "Time when a screen read found no dialog for it, or nil.
The user answered the approval then, or a reviewer did."))

(cl-defstruct (claude-code-ide-codex-events--launch
               (:constructor claude-code-ide-codex-events--launch-create)
               (:copier nil))
  "What one launch of a Codex instance does, as its hooks reported it."
  (instance-id nil :type string)
  (generation 0 :type integer)
  (session-id nil :documentation "The first `session_id' of the launch.
Events with another session ID come from a nested session.")
  (phase 'starting :type symbol
         :documentation "`starting', `working', `idle', `failed' or `ended'.")
  (failure nil :documentation "`error', `quota-limit' or `not-included' in the `failed' phase.
`not-included': the plan of the account does not include Codex; its
state is `failed/quota-limit'.")
  (detail "" :type string)
  (since 0.0 :type float :documentation "Time the phase started.")
  (registered 0.0 :type float)
  (last-event nil :documentation "Time of the last event, or nil before the first.")
  (tools (make-hash-table :test 'equal)
         :documentation "(AGENT-ID . TOOL-USE-ID) -> (SEQ NAME INPUT).")
  (tool-seq 0 :type integer)
  (blockers nil :type list :documentation "Open blockers, oldest first.")
  (subagents (make-hash-table :test 'equal) :documentation "Agent ID -> start time.")
  (questions nil :type list
             :documentation "Lines of the reply that ended the turn that ask the user.")
  (dialog nil :documentation "Dialog that the last screen read found, or nil.")
  (dialog-checked nil :documentation "Time of the last screen read, or nil.")
  (trust 'unknown :documentation "`unknown', `checking', `trusted', `untrusted' or `error'.")
  (trust-detail nil :documentation "Text that explains the trust, or nil.")
  (hooks nil :documentation "Non-nil when the launch got the hook arguments.
Only a launch whose hooks are confirmed as trusted gets them, so that
Codex shows no \"Hooks need review\" dialog for the others."))

(defvar claude-code-ide-codex-events--launches (make-hash-table :test 'equal)
  "The launch record of each Codex instance, by instance ID.
Only the current launch of an instance has a record.")

(defvar claude-code-ide-codex-events--tick-timer nil
  "Timer that reads events and the screens of Codex instances.")

(defvar claude-code-ide-codex-events--drain-timer nil
  "Timer that reads the event files soon.")

(defvar claude-code-ide-codex-events--watch nil
  "File notification descriptor of the Codex events folder.")

(defvar claude-code-ide-codex-events--trust-cache (make-hash-table :test 'equal)
  "Trust results by key; see `claude-code-ide-codex-events--trust-key'.
Each value is a plist with :status (`trusted', `untrusted' or
`disabled'), :message, :hooks (the hooks that Codex does not run),
:trust (for `trusted': the (STATE-KEY . HASH) of each of our hooks
that `hooks/list' called trusted) and :config-stamp, the modification
time and size of the Codex config file at the check.  See
`claude-code-ide-codex-events--cached-trust' for when it is valid.")

(defvar claude-code-ide-codex-events--checks (make-hash-table :test 'equal)
  "The running trust check of each key, a `claude-code-ide-codex-events--check'.
Starts of the same key share it.")

(defvar claude-code-ide-codex-events--declined nil
  "Keys of hook definitions whose trust the user declined in this Emacs.
No start asks again for them; `claude-code-ide-codex-trust-hooks'
still trusts them.")

(defconst claude-code-ide-codex-events--background-limit 30
  "Seconds after which a trust check that nobody waits for ends.")

;;; Files

(defun claude-code-ide-codex-events--hooks-directory ()
  "Return the private folder of the Codex hook script."
  (file-name-as-directory
   (expand-file-name "codex-hooks" (claude-code-ide-session-registry--report-directory))))

(defun claude-code-ide-codex-events--script-file ()
  "Return the file of the Codex hook script."
  (expand-file-name claude-code-ide-codex-events--script-name
                    (claude-code-ide-codex-events--hooks-directory)))

(defun claude-code-ide-codex-events--events-directory ()
  "Return the folder where the Codex hooks of this Emacs record events."
  (file-name-as-directory
   (expand-file-name "codex" (claude-code-ide-session-status--events-directory))))

(defun claude-code-ide-codex-events--private-directory (dir)
  "Make DIR, a folder only the user can use, and return it.
An existing folder gets mode 0700.  A symbolic link signals an error."
  (when (file-symlink-p (directory-file-name dir))
    (error "%s is a symbolic link; Emacs does not use it for hooks" dir))
  (unless (file-directory-p dir)
    (make-directory dir t))
  (unless (= (file-modes dir) #o700)
    (set-file-modes dir #o700))
  dir)

(defun claude-code-ide-codex-events--script-ok-p (file)
  "Return non-nil when FILE is the current hook script.
It must be a regular file that only the user can write."
  (and (file-regular-p file)
       (not (file-symlink-p file))
       (zerop (logand (file-modes file) #o022))
       (equal (claude-code-ide-session-registry--file-string file)
              (claude-code-ide-codex-events--script-text))))

(defun claude-code-ide-codex-events--install-script ()
  "Write the hook script when it is missing or differs, and return its file.
The folder is private (mode 0700).  The script is written to a
temporary file in that folder and renamed, so Codex never runs a part
of it.  The content is checked at each launch, because Codex trusts
the hook command, not the script."
  (claude-code-ide-codex-events--private-directory
   (claude-code-ide-codex-events--hooks-directory))
  (let ((file (claude-code-ide-codex-events--script-file)))
    (unless (claude-code-ide-codex-events--script-ok-p file)
      (claude-code-ide-session-status--write-file-atomically
       file (claude-code-ide-codex-events--script-text) #o700))
    file))

(defun claude-code-ide-codex-events--command (event)
  "Return the fixed hook command of the Codex hook EVENT."
  (mapconcat #'shell-quote-argument
             (list "sh" (claude-code-ide-codex-events--script-file) event)
             " "))

(defun claude-code-ide-codex-events--hook-args ()
  "Return the `-c' arguments that define the Codex status hooks.
They do not depend on the instance, so one trust covers all launches."
  (apply #'append
         (mapcar (lambda (event)
                   (list "-c"
                         (format "hooks.%s=[{hooks=[{type=\"command\",command=%s,timeout=%d}]}]"
                                 event
                                 (json-encode-string (claude-code-ide-codex-events--command event))
                                 (claude-code-ide-session-status--hook-cli-timeout))))
                 claude-code-ide-codex-events--events)))

(defun claude-code-ide-codex-events--remove-launch-files (instance-id generation)
  "Delete the event, counter and lock files of the launch INSTANCE-ID GENERATION."
  (claude-code-ide-session-status--delete-matching-files
   (claude-code-ide-codex-events--events-directory)
   (concat "\\`\\.?" (regexp-quote (format "%s.%d." instance-id generation)))))

(defun claude-code-ide-codex-events--remove-stale-locks ()
  "Delete counter locks and break tokens older than three seconds.
See `claude-code-ide-session-status--remove-old-locks'."
  (claude-code-ide-session-status--remove-old-locks
   (claude-code-ide-codex-events--events-directory) "\\`\\..+\\.lock\\(?:\\.break\\)?\\'"))

;;; Hook arguments

;; The Codex launch appends the result of
;; `claude-code-ide-codex-status-hook-args' to its command and the result
;; of `claude-code-ide-codex-status-hook-env' to the terminal environment.
;; It calls them only when they are bound.

(defun claude-code-ide-codex-events--launch-of (instance)
  "Return the launch record of the current launch of INSTANCE, or nil."
  (let ((launch (gethash (claude-code-ide-instance-id instance)
                         claude-code-ide-codex-events--launches)))
    (and launch
         (= (claude-code-ide-codex-events--launch-generation launch)
            (claude-code-ide-instance-generation instance))
         launch)))

(defun claude-code-ide-codex-events--track (instance &optional interactive)
  "Start to track the current launch of INSTANCE and return its record.
A record of an earlier launch of the same instance is replaced, and its
files are deleted.  The hook trust is settled here, before the start:
see `claude-code-ide-codex-events--settle-trust'.  INTERACTIVE is the
`interactive' slot of the start spec."
  (or (claude-code-ide-codex-events--launch-of instance)
      (let* ((id (claude-code-ide-instance-id instance))
             (old (gethash id claude-code-ide-codex-events--launches))
             (now (float-time))
             (launch (claude-code-ide-codex-events--launch-create
                      :instance-id id
                      :generation (claude-code-ide-instance-generation instance)
                      :since now :registered now)))
        (when old
          (claude-code-ide-codex-events--remove-launch-files
           id (claude-code-ide-codex-events--launch-generation old)))
        (claude-code-ide-codex-events--install-script)
        (claude-code-ide-codex-events--private-directory
         (claude-code-ide-codex-events--events-directory))
        (puthash id launch claude-code-ide-codex-events--launches)
        (claude-code-ide-codex-events--ensure-timers)
        (claude-code-ide-codex-events--settle-trust launch instance interactive)
        launch)))

(defun claude-code-ide-codex-events--track-safely (instance &optional interactive)
  "Track INSTANCE and return its launch record, or show the error and return nil.
A failure here must not stop the launch; the instance then has no
status events.  INTERACTIVE is as for `claude-code-ide-codex-events--track'."
  (when (and claude-code-ide-session-status-tracking
             (claude-code-ide-instance-p instance)
             (stringp (claude-code-ide-instance-id instance)))
    (condition-case err
        (claude-code-ide-codex-events--track instance interactive)
      (error
       (message "Codex status hooks are off for this launch: %s" (error-message-string err))
       nil))))

(defun claude-code-ide-codex-status-hook-args (instance &optional interactive)
  "Return the command-line arguments of the Codex status hooks of INSTANCE.
The list holds one \"-c\" and one \"hooks.<Event>=[...]\" string for
each event of `claude-code-ide-codex-events--events', always in the same
order: Codex keeps the trust of a hook under a key that has its
position.  The commands are the same for each instance; the identity
comes from `claude-code-ide-codex-status-hook-env'.  The call starts to
track the launch and settles the trust.  INTERACTIVE is the
`interactive' slot of the start spec: non-nil for a start that the user
asked for, which may ask the user to trust the hooks.  Return nil when
status tracking is off, the hook script cannot be installed, or the
hooks are not confirmed as trusted."
  (let ((launch (claude-code-ide-codex-events--track-safely instance interactive)))
    (when (and launch (claude-code-ide-codex-events--launch-hooks launch))
      (claude-code-ide-codex-events--hook-args))))

(defun claude-code-ide-codex-status-hook-env (instance)
  "Return the environment entries of the Codex status hooks of INSTANCE.
They are \"CCI_INSTANCE_ID=...\", \"CCI_GENERATION=...\" and
\"CCI_EVENTS_DIR=...\", the folder where the hooks record events.
Return nil when `claude-code-ide-codex-status-hook-args' returns nil."
  (let ((launch (claude-code-ide-codex-events--track-safely instance)))
    (when (and launch (claude-code-ide-codex-events--launch-hooks launch))
      (list (concat "CCI_INSTANCE_ID=" (claude-code-ide-instance-id instance))
            (format "CCI_GENERATION=%d" (claude-code-ide-instance-generation instance))
            (concat "CCI_EVENTS_DIR="
                    (directory-file-name (claude-code-ide-codex-events--events-directory)))))))

;;; Common events

(defun claude-code-ide-codex-events-map-event (provider-event data)
  "Return the common event of the Codex hook event PROVIDER-EVENT with DATA.
The Codex provider can use this function as its `map-event' operation."
  (cond
   ((equal provider-event "PostModelRequest")
    (if (equal (alist-get 'status data) "failed") 'turn-failed 'other))
   ((cdr (assoc provider-event claude-code-ide-codex-events--event-map)))
   (t 'other)))

;;; State machine

(defun claude-code-ide-codex-events--string (data field)
  "Return the non-empty string FIELD of DATA, or nil."
  (let ((value (alist-get field data)))
    (and (stringp value) (not (string-empty-p value)) value)))

(defun claude-code-ide-codex-events--set-phase (launch phase detail now)
  "Set the PHASE and DETAIL of LAUNCH; a new PHASE starts at NOW."
  (unless (eq (claude-code-ide-codex-events--launch-phase launch) phase)
    (setf (claude-code-ide-codex-events--launch-since launch) now))
  (setf (claude-code-ide-codex-events--launch-phase launch) phase
        (claude-code-ide-codex-events--launch-detail launch) detail
        (claude-code-ide-codex-events--launch-questions launch) nil))

(defun claude-code-ide-codex-events--tool-key (data)
  "Return the (AGENT-ID . TOOL-USE-ID) of the tool event DATA."
  (cons (claude-code-ide-codex-events--string data 'agent_id)
        (alist-get 'tool_use_id data)))

(defun claude-code-ide-codex-events--question-detail (input)
  "Return the detail of a structured question with the tool INPUT."
  (let ((question (car-safe (alist-get 'questions input))))
    (claude-code-ide-session-status--one-line
     (concat "Question: "
             (or (and (consp question)
                      (or (claude-code-ide-codex-events--string question 'question)
                          (claude-code-ide-codex-events--string question 'header)))
                 "")))))

(defun claude-code-ide-codex-events--remove-blockers (launch predicate)
  "Remove the blockers of LAUNCH for which PREDICATE is non-nil."
  (setf (claude-code-ide-codex-events--launch-blockers launch)
        (cl-remove-if predicate (claude-code-ide-codex-events--launch-blockers launch))))

(defun claude-code-ide-codex-events--add-blocker (launch kind tool detail now)
  "Add a blocker of KIND for TOOL with DETAIL to LAUNCH at NOW."
  (setf (claude-code-ide-codex-events--launch-blockers launch)
        (append (claude-code-ide-codex-events--launch-blockers launch)
                (list (claude-code-ide-codex-events--blocker-create
                       :kind kind :tool tool :detail detail :since now)))))

(defun claude-code-ide-codex-events--forget-agent (launch agent)
  "Remove the tools in flight and the blockers of the agent AGENT of LAUNCH.
AGENT nil is the main agent."
  (let ((tools (claude-code-ide-codex-events--launch-tools launch)))
    (maphash (lambda (key _value)
               (when (equal (car key) agent)
                 (remhash key tools)))
             tools))
  (claude-code-ide-codex-events--remove-blockers
   launch (lambda (blocker)
            (equal (car-safe (claude-code-ide-codex-events--blocker-tool blocker)) agent))))

(defun claude-code-ide-codex-events--input-matches-p (request-input tool-input)
  "Return non-nil when REQUEST-INPUT of a PermissionRequest fits TOOL-INPUT.
TOOL-INPUT is the input of the PreToolUse.  Each of its fields must
have the same value in REQUEST-INPUT; fields that only the request has,
such as `description', do not count."
  (if (and (consp tool-input) (consp (car tool-input)))
      (and (listp request-input)
           (cl-every (lambda (field)
                       (equal (alist-get (car field) request-input) (cdr field)))
                     tool-input))
    (equal request-input tool-input)))

(defun claude-code-ide-codex-events--match-tool (launch data)
  "Return the key of the tool in flight that the PermissionRequest DATA is for.
A request with a `tool_use_id' of a tool in flight is for that tool.
Codex 0.164.0 sends none: then the newest tool in flight of the same
agent with the same name, whose input fits the request, and that has
no blocker yet is chosen."
  (let* ((agent (claude-code-ide-codex-events--string data 'agent_id))
         (id (alist-get 'tool_use_id data))
         (tools (claude-code-ide-codex-events--launch-tools launch)))
    (if (and id (gethash (cons agent id) tools))
        (cons agent id)
      (let ((name (alist-get 'tool_name data))
            (input (alist-get 'tool_input data))
            (blocked (mapcar #'claude-code-ide-codex-events--blocker-tool
                             (claude-code-ide-codex-events--launch-blockers launch)))
            (best nil)
            (best-seq -1))
        (maphash (lambda (key value)
                   (when (and (equal (car key) agent)
                              (equal (nth 1 value) name)
                              (claude-code-ide-codex-events--input-matches-p input (nth 2 value))
                              (not (member key blocked))
                              (> (car value) best-seq))
                     (setq best key best-seq (car value))))
                 tools)
        best))))

(defun claude-code-ide-codex-events--quota-error-p (error)
  "Return non-nil when the model request ERROR text reports a quota limit.
See `claude-code-ide-session-status-quota-regexp'.  A failed
`PostModelRequest' has only this text, not the error kind."
  (claude-code-ide-session-status--quota-text-p error))

(defcustom claude-code-ide-codex-events-error-kind-states
  '(("usage_limit_exceeded" . quota-limit)
    ("session_budget_exceeded" . quota-limit)
    ("usage_not_included" . quota-limit)
    ("rate_limit_exceeded" . error)
    ("server_overloaded" . error)
    ("response_too_many_failed_attempts" . error)
    ("http_connection_failed" . error)
    ("response_stream_connection_failed" . error)
    ("response_stream_disconnected" . error)
    ("internal_server_error" . error)
    ("flex_unavailable" . error)
    ("context_window_exceeded" . error)
    ("cyber_policy" . error)
    ("misalignment_policy_violation" . error)
    ("too_many_denials" . error)
    ("unauthorized" . error)
    ("bad_request" . error)
    ("thread_rollback_failed" . error)
    ("sandbox_error" . error)
    ("active_turn_not_steerable" . error))
  "The state of a failed Codex turn for each error kind.
Each element is (KIND . STATE).  KIND is a `codex_error_info' of the
rollout file, in snake case, such as \"usage_limit_exceeded\".  STATE
is `quota-limit' (the state `failed/quota-limit') or `error' (the
state `failed/error').  For a kind that is not in the list, such as
\"other\", or for no kind, the error text decides; see
`claude-code-ide-session-status-quota-regexp'.  The hooks give no
kind, only the text."
  :type '(alist :key-type (string :tag "Error kind")
                :value-type (choice (const :tag "failed/quota-limit" quota-limit)
                                    (const :tag "failed/error" error)))
  :group 'claude-code-ide)

(defcustom claude-code-ide-codex-events-not-included-regexp
  "usage[_ ]not[_ ]included\\|with your chatgpt plan, upgrade to"
  "Regexp for a Codex error text that says the plan does not include Codex.
It is matched without case.  Such a failure is `failed/quota-limit'
with the detail \"Not included in the plan\", and
`claude-code-ide-codex-events-not-included-action' decides what a
visit of the session does."
  :type 'regexp
  :group 'claude-code-ide)

(defun claude-code-ide-codex-events--error-kind (info)
  "Return the name of the Codex error kind INFO, or nil.
INFO is a string such as \"usage_limit_exceeded\", or an object with
one key such as ((http_connection_failed (http_status_code . 429)))."
  (cond
   ((and (stringp info) (not (string-empty-p info))) info)
   ((and (consp info) (consp (car info)) (symbolp (caar info)))
    (symbol-name (caar info)))))

(defun claude-code-ide-codex-events--failure-kind (info text)
  "Return the failure of a turn error of kind INFO with the TEXT.
The result is `not-included' (the plan does not include Codex),
`quota-limit' or `error'.  A kind in
`claude-code-ide-codex-events-error-kind-states' decides first;
another kind, or none, leaves it to the text."
  (let* ((kind (claude-code-ide-codex-events--error-kind info))
         (state (cdr (assoc kind claude-code-ide-codex-events-error-kind-states)))
         (not-included (or (equal kind "usage_not_included")
                           (and (stringp text)
                                (let ((case-fold-search t))
                                  (string-match-p claude-code-ide-codex-events-not-included-regexp
                                                  text))))))
    (pcase state
      ('error 'error)
      ('quota-limit (if not-included 'not-included 'quota-limit))
      (_ (cond
          (not-included 'not-included)
          ((claude-code-ide-codex-events--quota-error-p text) 'quota-limit)
          (t 'error))))))

(defun claude-code-ide-codex-events--quota-failure-p (info message)
  "Return non-nil when a turn error of kind INFO with MESSAGE is a quota limit.
See `claude-code-ide-codex-events--failure-kind'."
  (and (memq (claude-code-ide-codex-events--failure-kind info message)
             '(quota-limit not-included))
       t))

(defun claude-code-ide-codex-events--failure-detail (failure text &optional prefix)
  "Return the detail of a FAILURE (see `--failure-kind') with the error TEXT.
PREFIX, when non-nil, comes first."
  (claude-code-ide-session-status--one-line
   (format "%s%s: %s"
           (or prefix "")
           (pcase failure
             ('not-included "Not included in the plan")
             ('quota-limit "Quota limit")
             (_ "Error"))
           text)))

(defun claude-code-ide-codex-events--apply (launch event data &optional now)
  "Change LAUNCH for the Codex hook EVENT with the input DATA, at time NOW.
Events with an `agent_id' come from a subagent: they never change the
turn of the main agent, but a subagent's approval or question waits
for the user too."
  (let* ((now (or now (float-time)))
         (agent (claude-code-ide-codex-events--string data 'agent_id))
         (main (null agent)))
    (setf (claude-code-ide-codex-events--launch-last-event launch) now)
    (when main
      ;; A screen read is valid until the next event of the main agent
      (setf (claude-code-ide-codex-events--launch-dialog launch) nil))
    (pcase event
      ("SessionStart"
       (clrhash (claude-code-ide-codex-events--launch-tools launch))
       (clrhash (claude-code-ide-codex-events--launch-subagents launch))
       (setf (claude-code-ide-codex-events--launch-blockers launch) nil
             (claude-code-ide-codex-events--launch-failure launch) nil)
       (claude-code-ide-codex-events--set-phase launch 'idle "Ready" now))
      ("UserPromptSubmit"
       (claude-code-ide-codex-events--forget-agent launch nil)
       (setf (claude-code-ide-codex-events--launch-failure launch) nil)
       (claude-code-ide-codex-events--set-phase launch 'working "Working" now))
      ("PreToolUse"
       (let ((name (alist-get 'tool_name data))
             (key (claude-code-ide-codex-events--tool-key data)))
         (puthash key (list (cl-incf (claude-code-ide-codex-events--launch-tool-seq launch))
                            name (alist-get 'tool_input data))
                  (claude-code-ide-codex-events--launch-tools launch))
         (when (equal name claude-code-ide-codex-events--question-tool)
           (claude-code-ide-codex-events--add-blocker
            launch 'question key
            (claude-code-ide-codex-events--question-detail (alist-get 'tool_input data))
            now))
         (when main
           (claude-code-ide-codex-events--set-phase
            launch 'working (format "Working: %s" (or name "tool")) now))))
      ("PermissionRequest"
       (claude-code-ide-codex-events--add-blocker
        launch 'approval
        (or (claude-code-ide-codex-events--match-tool launch data) (cons agent nil))
        (claude-code-ide-session-status--tool-detail (alist-get 'tool_name data)
                                                     (alist-get 'tool_input data))
        now))
      ("PostToolUse"
       (let ((key (claude-code-ide-codex-events--tool-key data)))
         (remhash key (claude-code-ide-codex-events--launch-tools launch))
         (claude-code-ide-codex-events--remove-blockers
          launch (lambda (blocker)
                   (let ((tool (claude-code-ide-codex-events--blocker-tool blocker)))
                     (or (equal tool key) (equal tool (cons agent nil))))))
         (when (and main (memq (claude-code-ide-codex-events--launch-phase launch)
                               '(starting idle)))
           (claude-code-ide-codex-events--set-phase launch 'working "Working" now))))
      ("Interrupt"
       ;; An Esc and the denial of an approval both give only Interrupt
       (when main
         (claude-code-ide-codex-events--forget-agent launch nil)
         (claude-code-ide-codex-events--set-phase launch 'idle "Interrupted" now)))
      ("Stop"
       (when main
         (claude-code-ide-codex-events--forget-agent launch nil)
         (let ((message (alist-get 'last_assistant_message data)))
           (claude-code-ide-codex-events--set-phase
            launch 'idle
            (let ((text (claude-code-ide-session-status--one-line message)))
              (if (string-empty-p text) "Turn ended" text))
            now)
           (setf (claude-code-ide-codex-events--launch-questions launch)
                 (claude-code-ide-session-status--questions message)))))
      ("PostModelRequest"
       (cond
        ((and main (equal (alist-get 'status data) "failed"))
         ;; No Stop follows a failed request
         (let* ((error (alist-get 'error data))
                (text (if (and (stringp error) (not (string-blank-p error)))
                          error
                        "model request failed"))
                (failure (claude-code-ide-codex-events--failure-kind nil error)))
           (claude-code-ide-codex-events--forget-agent launch nil)
           (claude-code-ide-codex-events--set-phase
            launch 'failed (claude-code-ide-codex-events--failure-detail failure text) now)
           (setf (claude-code-ide-codex-events--launch-failure launch) failure)))
        ;; Codex retries a failed request: a later answer ends the failure
        ((and main (memq (claude-code-ide-codex-events--launch-phase launch) '(starting failed)))
         (setf (claude-code-ide-codex-events--launch-failure launch) nil)
         (claude-code-ide-codex-events--set-phase launch 'working "Working" now))))
      ("SubagentStart"
       (when agent
         (puthash agent now (claude-code-ide-codex-events--launch-subagents launch))))
      ("SubagentStop"
       (when agent
         (remhash agent (claude-code-ide-codex-events--launch-subagents launch))
         (claude-code-ide-codex-events--forget-agent launch agent)))
      ("SessionEnd"
       (clrhash (claude-code-ide-codex-events--launch-tools launch))
       (clrhash (claude-code-ide-codex-events--launch-subagents launch))
       (setf (claude-code-ide-codex-events--launch-blockers launch) nil)
       (claude-code-ide-codex-events--set-phase launch 'ended "Session ended" now)))))

;;; States

(defconst claude-code-ide-codex-events--dialog-details
  '((folder-trust . "Codex asks whether to trust this folder: answer in the terminal")
    (update . "Codex offers an update: answer in the terminal")
    (hooks-review . "Codex asks to review hooks: answer in the terminal")
    (approval . "Codex asks for an approval")
    (other . "A Codex dialog waits: answer in the terminal"))
  "Detail text of each dialog that the screen read finds.")

(defun claude-code-ide-codex-events--trust-problem (launch)
  "Return the text of a trust problem of LAUNCH, or nil.
Only a launch without hooks has one: a launch with hooks runs them."
  (and (not (claude-code-ide-codex-events--launch-hooks launch))
       (or (claude-code-ide-codex-events--launch-trust-detail launch)
           "No status hooks")))

(defun claude-code-ide-codex-events--state (launch now)
  "Return (STATE REASON SINCE GUESS DETAIL) of LAUNCH at NOW.
STATE and REASON are a common state; GUESS is non-nil when no event
reports the state."
  (let* ((phase (claude-code-ide-codex-events--launch-phase launch))
         (since (claude-code-ide-codex-events--launch-since launch))
         (detail (claude-code-ide-codex-events--launch-detail launch))
         (dialog (claude-code-ide-codex-events--launch-dialog launch))
         (blocker (car (claude-code-ide-codex-events--launch-blockers launch)))
         (subagents (claude-code-ide-codex-events--launch-subagents launch))
         (registered (claude-code-ide-codex-events--launch-registered launch))
         (problem (claude-code-ide-codex-events--trust-problem launch)))
    (cond
     ((eq phase 'ended) (list 'disconnected nil since nil detail))
     ((eq phase 'failed)
      (list 'failed (pcase (claude-code-ide-codex-events--launch-failure launch)
                      ((or 'quota-limit 'not-included) 'quota-limit)
                      (_ 'error))
            since nil detail))
     ((and blocker (eq (claude-code-ide-codex-events--blocker-kind blocker) 'question))
      (list 'waiting-for-user 'question (claude-code-ide-codex-events--blocker-since blocker)
            nil (claude-code-ide-codex-events--blocker-detail blocker)))
     (blocker
      (let ((answered (claude-code-ide-codex-events--blocker-answered blocker))
            (start (claude-code-ide-codex-events--blocker-since blocker))
            (text (claude-code-ide-codex-events--blocker-detail blocker)))
        (cond
         ((eq dialog 'approval) (list 'waiting-for-user 'approval start nil text))
         ;; The screen shows no dialog: the command was approved and runs
         (answered (list 'working nil answered t (concat "Approved, runs? " text)))
         (t (list 'waiting-for-user 'approval start
                  (> (- now start) claude-code-ide-codex-events-approval-guess-time)
                  text)))))
     ((memq dialog '(folder-trust update hooks-review other approval))
      (list 'waiting-for-user (if (eq dialog 'approval) 'approval 'dialog)
            (or (claude-code-ide-codex-events--launch-dialog-checked launch) now) nil
            (alist-get dialog claude-code-ide-codex-events--dialog-details)))
     ((> (hash-table-count subagents) 0)
      (let ((count (hash-table-count subagents))
            (first now))
        (maphash (lambda (_agent start) (setq first (min first start))) subagents)
        (list 'waiting-for-task 'subagent first nil
              (format "%d subagent%s running" count (if (= count 1) "" "s")))))
     ((null (claude-code-ide-codex-events--launch-last-event launch))
      ;; Codex sends SessionStart only with the first prompt
      (cond
       ;; A launch without hooks never reports
       ((not (claude-code-ide-codex-events--launch-hooks launch))
        (list 'disconnected 'untracked registered nil problem))
       ((< (- now registered) claude-code-ide-codex-events-startup-grace)
        (list 'working 'starting registered t "Starting"))
       ((claude-code-ide-codex-events--launch-dialog-checked launch)
        (list 'idle nil registered t "Ready: Codex reports no event before the first prompt"))
       (t (list 'working 'starting registered t "Starting: no event yet"))))
     ((eq phase 'idle)
      (let ((questions (claude-code-ide-codex-events--launch-questions launch)))
        (if questions
            (list 'waiting-for-user 'question since t
                  (claude-code-ide-session-status--one-line
                   (concat (if (cdr questions)
                               (format "Asks %d questions: " (length questions))
                             "Asks: ")
                           (car questions))
                   140))
          (list 'idle nil since nil detail))))
     (t (list 'working nil since nil detail)))))

(defun claude-code-ide-codex-events--detail (launch state)
  "Return the detail text of LAUNCH with a trust problem.
STATE is the result of `claude-code-ide-codex-events--state' for LAUNCH."
  (let ((detail (nth 4 state))
        (problem (claude-code-ide-codex-events--trust-problem launch)))
    (if (and problem (not (equal detail problem)))
        (concat detail " · " problem)
      detail)))

;;; The rollout file of an instance without hooks

;; Codex keeps no status file for each process.  But it appends each
;; turn to the rollout file of the conversation,
;; <CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<time>-<native id>.jsonl: an
;; `event_msg' record `task_started' at the start of a turn, and
;; `task_complete' (with `error' when the turn failed) or `turn_aborted'
;; at its end.  For a Codex instance without status hooks, the last of
;; these records gives the state, as a guess: the terminal can show
;; another conversation than the native ID of the instance, after /new
;; or a fork.  The Codex provider finds the file (its `transcript'
;; operation); this file reads it, only when it changed, and never
;; writes it.

(defconst claude-code-ide-codex-events--turn-regexp
  "\"type\":\"\\(?:task_started\\|task_complete\\|turn_aborted\\)\""
  "Regexp for a line of a rollout file that can be a turn record.
A quote inside a JSON string is escaped, so the regexp matches only a
key and a value.  The parsed line must still be an `event_msg'.")

(defvar claude-code-ide-codex-events--rollout-chunk 65536
  "Bytes of a rollout file that one read takes.")

(defvar claude-code-ide-codex-events--rollout-line-limit (* 8 1024 1024)
  "Longest line of a rollout file that the reader reads, in bytes.
A longer line is skipped; a turn record is much shorter.")

(defvar claude-code-ide-codex-events--rollout-cache (make-hash-table :test 'eq :weakness 'key)
  "INSTANCE -> plist of what its rollout file gave, weak in INSTANCE.
:native and :file are the conversation and its rollout file.  :stamp is
\(MTIME SIZE INODE DEVICE) of the file at the last read, or nil.
:owner is `yes' when the session record of the file is of :native,
`no' when it is of another conversation, and nil when the file has no
whole session record yet.  :end is the byte after the last whole line
read, where the next read starts.  :turn is the last turn record (see
`claude-code-ide-codex-events--turn-of-record').  :pid and :start are
the terminal PID and the start of its process.  :switch is the rollout
file of another conversation that the terminal shows, or nil, as found
for the inputs and folders of :switch-key.")

(defvar claude-code-ide-codex-events--state-cache (make-hash-table :test 'eq :weakness 'key)
  "INSTANCE -> the state and detail of one refresh; weak in INSTANCE.
See `claude-code-ide-codex-events--state-and-detail'.")

(defconst claude-code-ide-codex-events--input-limit 32
  "Number of RET times that each Codex terminal buffer keeps.")

(defvar-local claude-code-ide-codex-events--inputs nil
  "Float times of the last RETs in this Codex terminal buffer, newest first.")

(defun claude-code-ide-codex-events--note-input ()
  "Note the time of a RET in the Codex terminal buffer.
This is a function of the local `post-command-hook' of the buffer."
  (when (memq last-command-event '(?\r ?\n return))
    (setq claude-code-ide-codex-events--inputs
          (seq-take (cons (float-time) claude-code-ide-codex-events--inputs)
                    claude-code-ide-codex-events--input-limit))))

(defun claude-code-ide-codex-events--watch-input (buffer)
  "Note each RET in the terminal BUFFER from now on."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (add-hook 'post-command-hook #'claude-code-ide-codex-events--note-input nil t))))

(defun claude-code-ide-codex-events--rollout-file (instance)
  "Return the rollout file of the conversation of INSTANCE, or nil.
The `transcript' operation of the Codex provider finds it.  Without a
known native ID, without the provider or its operation, or on an
error, there is no file."
  (when-let* (((claude-code-ide-known-or-nil (claude-code-ide-instance-native-id instance)))
              (provider (claude-code-ide-get-provider 'codex))
              ((claude-code-ide-provider-supports-p provider 'transcript)))
    (let ((file (claude-code-ide-known-or-nil
                 (condition-case nil
                     (claude-code-ide-provider-call provider 'transcript instance 'file)
                   (error nil)))))
      (and (stringp file) (file-name-absolute-p file) file))))

(defun claude-code-ide-codex-events--rollout-line ()
  "Return the JSON object of the line at point, in a buffer of file bytes, or nil."
  (claude-code-ide-transcript--parse-line
   (decode-coding-string
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))
    'utf-8)))

(defun claude-code-ide-codex-events--turn-of-record (record)
  "Return the turn record RECORD of a rollout file as a plist, or nil.
The plist has :kind (`started', `complete' or `aborted') and :time
\(the float time of the start or the end, or nil).  A failed turn also
has :error t, :error-kind (the error kind, or nil) and :error-message
\(a non-blank text, or nil).  Other records give nil."
  (let ((payload (alist-get 'payload record)))
    (when (and (equal (alist-get 'type record) "event_msg") (consp payload))
      (let ((number (lambda (field)
                      (let ((value (alist-get field payload)))
                        (and (numberp value) (float value))))))
        (pcase (alist-get 'type payload)
          ("task_started" (list :kind 'started :time (funcall number 'started_at)))
          ("task_complete"
           (let ((error (alist-get 'error payload)))
             (append (list :kind 'complete :time (funcall number 'completed_at))
                     (when error
                       (let ((message (if (consp error) (alist-get 'message error) error)))
                         (list :error t
                               :error-kind (and (consp error)
                                                (claude-code-ide-codex-events--error-kind
                                                 (alist-get 'codex_error_info error)))
                               :error-message (and (stringp message)
                                                   (not (string-blank-p message))
                                                   message)))))))
          ("turn_aborted" (list :kind 'aborted :time (funcall number 'completed_at))))))))

(defun claude-code-ide-codex-events--rollout-scan (file from to)
  "Return (TURN . END) for the bytes FROM to TO of the rollout FILE.
FROM is the start of a line.  TURN is the last turn record of a whole
line in that range, from `claude-code-ide-codex-events--turn-of-record',
or nil.  END is the byte after the last whole line, or FROM: a line
without its newline is still being written.  The file is read from TO
backward, one chunk at a time, until the turn record is found."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((pos to)
          (size claude-code-ide-codex-events--rollout-chunk)
          (end nil)
          (turn nil))
      (while (and (not turn) (> pos from))
        (let ((start (max from (- pos size))))
          (erase-buffer)
          (insert-file-contents-literally file nil start pos)
          (unless end
            (goto-char (point-max))
            (when (search-backward "\n" nil t)
              (setq end (+ start (point)))))
          (goto-char (point-min))
          ;; The first line of a chunk can be cut, unless it starts at FROM
          (let ((first (if (= start from)
                           (point-min)
                         (and (search-forward "\n" nil t) (point)))))
            (if (or (null first) (= first (point-max)))
                ;; No whole line after the cut one: read more of it, or skip it
                (if (< size claude-code-ide-codex-events--rollout-line-limit)
                    (setq size (* 2 size))
                  (setq pos start
                        size claude-code-ide-codex-events--rollout-chunk))
              (goto-char (point-max))
              ;; Lines from FIRST to the last newline are whole
              (when (search-backward "\n" first t)
                (while (and (not turn)
                            (re-search-backward claude-code-ide-codex-events--turn-regexp first t))
                  (setq turn (claude-code-ide-codex-events--turn-of-record
                              (claude-code-ide-codex-events--rollout-line)))
                  (goto-char (line-beginning-position))))
              (setq pos (+ start (1- first)))))))
      (cons turn (or end from)))))

(defconst claude-code-ide-codex-events--meta-limit 4194304
  "Bytes at the start of a rollout file in which its first line must end.
`claude-code-ide-transcript-codex-meta' reads as much.")

(defun claude-code-ide-codex-events--first-line-whole-p (file)
  "Return non-nil when the first line of FILE is a whole session record.
That line must end with a newline.  Codex writes the `session_meta'
record first.  A first line without its
newline is still being written, also when it is valid JSON already.  The
check reads the bytes of FILE up to the first newline, and parses
nothing."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((size claude-code-ide-codex-events--rollout-chunk)
          (end nil)
          (done nil))
      (while (not done)
        (erase-buffer)
        (let ((read (cadr (insert-file-contents-literally file nil 0 size))))
          (goto-char (point-min))
          (cond
           ((search-forward "\n" nil t)
            (setq end (point) done t))
           ((or (< read size) (>= size claude-code-ide-codex-events--meta-limit))
            (setq done t))
           (t (setq size (min (* 2 size) claude-code-ide-codex-events--meta-limit))))))
      (and end
           (progn (goto-char (point-min))
                  (search-forward "\"type\":\"session_meta\"" end t))))))

(defun claude-code-ide-codex-events--rollout-owner (file native)
  "Return whose session the rollout FILE is: `yes' for NATIVE, else `no'.
Return nil when FILE has no whole session record yet: its first line
must be the `session_meta' record, with its newline.  The record is
read by `claude-code-ide-transcript-codex-meta'."
  (when-let* (((claude-code-ide-codex-events--first-line-whole-p file))
              (meta (claude-code-ide-transcript-codex-meta file)))
    (if (equal (plist-get meta :id) native) 'yes 'no)))

(defun claude-code-ide-codex-events--rollout-stamp (attributes)
  "Return (MTIME SIZE INODE DEVICE) of the file ATTRIBUTES."
  (list (file-attribute-modification-time attributes)
        (file-attribute-size attributes)
        (file-attribute-inode-number attributes)
        (file-attribute-device-number attributes)))

(defun claude-code-ide-codex-events--rollout-read (entry file)
  "Bring ENTRY up to date with the rollout FILE, and return ENTRY.
The file is read only when its stamp changed since the last read.  A
file of the conversation that grew, with the same inode, is read only
from the end of the last read on.  Any other change (a new file, a
new inode, the same or a smaller size, another owner) checks the owner
again and reads the file again from the start."
  (let* ((attributes (file-attributes file))
         (stamp (and attributes (claude-code-ide-codex-events--rollout-stamp attributes)))
         (old (plist-get entry :stamp)))
    (cond
     ((null stamp)
      (plist-put entry :stamp nil)
      (plist-put entry :file nil)
      (plist-put entry :owner nil))
     ((equal stamp old))
     (t
      (let* ((size (nth 1 stamp))
             (grew (and (eq (plist-get entry :owner) 'yes)
                        (equal file (plist-get entry :file))
                        old
                        (equal (nthcdr 2 stamp) (nthcdr 2 old))
                        (> size (nth 1 old))
                        (<= (or (plist-get entry :end) 0) size))))
        (condition-case nil
            (progn
              (unless grew
                (plist-put entry :file file)
                (plist-put entry :turn nil)
                (plist-put entry :end 0)
                (plist-put entry :owner (claude-code-ide-codex-events--rollout-owner
                                         file (plist-get entry :native))))
              (when (eq (plist-get entry :owner) 'yes)
                (let ((scan (claude-code-ide-codex-events--rollout-scan
                             file (plist-get entry :end) size)))
                  (when (car scan)
                    (plist-put entry :turn (car scan)))
                  (plist-put entry :end (cdr scan))))
              (plist-put entry :stamp stamp))
          ;; The file went away, or cannot be read now: try again next time
          (file-error (plist-put entry :stamp nil)
                      (plist-put entry :file nil)
                      (plist-put entry :owner nil))))))
    entry))

(defun claude-code-ide-codex-events--rollout-entry (instance native)
  "Return the cache entry of INSTANCE for the conversation NATIVE.
A new conversation starts a new entry."
  (let ((entry (gethash instance claude-code-ide-codex-events--rollout-cache)))
    (unless (equal (plist-get entry :native) native)
      (setq entry (list :native native))
      (puthash instance entry claude-code-ide-codex-events--rollout-cache))
    entry))

(defun claude-code-ide-codex-events--launch-start (instance launch entry)
  "Return the start of the current launch of INSTANCE as a float time, or nil.
That is the time when Emacs tracked LAUNCH, else the start of the
terminal process.  ENTRY keeps the start of each PID that Emacs asked."
  (or (and launch (claude-code-ide-codex-events--launch-registered launch))
      (let ((start (claude-code-ide-known-or-nil (claude-code-ide-instance-process-start-time instance))))
        (and (numberp start) (float start)))
      (let ((pid (claude-code-ide-known-or-nil (claude-code-ide-instance-pid instance))))
        (when (integerp pid)
          (unless (equal (plist-get entry :pid) pid)
            (plist-put entry :pid pid)
            (plist-put entry :start (claude-code-ide-session-registry--process-start-time pid)))
          (plist-get entry :start)))))

(defconst claude-code-ide-codex-events--rollout-name-regexp
  (concat "\\`rollout-\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)"
          "T\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)-\\([A-Za-z0-9-]+\\)\\.jsonl\\'")
  "Regexp for the name of a rollout file.
The groups are the local time when Codex made the file (year, month,
day, hour, minute, second) and the conversation ID.")

(defun claude-code-ide-codex-events--rollout-name (name)
  "Return (TIME . ID) of the rollout file NAME, or nil.
TIME is the float time when Codex made the file, in whole seconds of
local time; ID is the conversation ID."
  (when (string-match claude-code-ide-codex-events--rollout-name-regexp name)
    (let ((part (lambda (n) (string-to-number (match-string n name)))))
      (cons (float-time (encode-time (list (funcall part 6) (funcall part 5) (funcall part 4)
                                           (funcall part 3) (funcall part 2) (funcall part 1)
                                           nil -1 nil)))
            (match-string 7 name)))))

(defun claude-code-ide-codex-events--day-folders (file now)
  "Return the folders where Codex makes a new rollout next to FILE, at NOW.
That is the folder of FILE and, when FILE is in a day folder
YYYY/MM/DD of the sessions folder, the day folder of NOW."
  (let* ((dir (file-name-directory (expand-file-name file)))
         (root (and (string-match-p "/[0-9]\\{4\\}/[0-9]\\{2\\}/[0-9]\\{2\\}/\\'" dir)
                    (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (directory-file-name
                        (file-name-directory (directory-file-name dir)))))))))
    (delete-dups (delq nil (list dir (and root (expand-file-name
                                                (format-time-string "%Y/%m/%d/" (seconds-to-time now))
                                                root)))))))

(defun claude-code-ide-codex-events--instance-folder (instance)
  "Return the folder of INSTANCE (its worktree, else its project root), or nil."
  (let ((dir (or (claude-code-ide-known-or-nil (claude-code-ide-instance-worktree instance))
                 (claude-code-ide-known-or-nil (claude-code-ide-instance-project-root instance)))))
    (and (stringp dir) (file-name-as-directory (expand-file-name dir)))))

(defun claude-code-ide-codex-events--known-conversations (instance)
  "Return the conversation IDs of INSTANCE and of the other Codex instances."
  (delq nil (mapcar (lambda (other)
                      (and (eq (claude-code-ide-instance-provider other) 'codex)
                           (claude-code-ide-known-or-nil (claude-code-ide-instance-native-id other))))
                    (cons instance (claude-code-ide-instances)))))

(defun claude-code-ide-codex-events--find-new-conversation (instance file folders inputs)
  "Return the rollout of a new conversation in the terminal of INSTANCE, or nil.
FILE is the rollout of INSTANCE, FOLDERS are the day folders to look
in, and INPUTS are the times of the RETs after the last record of FILE.
A file counts when Codex made it at most a second before or after one
of INPUTS, its conversation is of no instance of this Emacs, and its
session record has the folder of INSTANCE."
  (let ((own (expand-file-name file))
        (folder (claude-code-ide-codex-events--instance-folder instance))
        (known (claude-code-ide-codex-events--known-conversations instance)))
    (when folder
      (catch 'found
        (dolist (dir folders)
          (when (file-directory-p dir)
            (dolist (name (directory-files dir nil "\\`rollout-.*\\.jsonl\\'" t))
              (let ((path (expand-file-name name dir))
                    (made (claude-code-ide-codex-events--rollout-name name)))
                (when (and made
                           (not (equal path own))
                           (not (member (cdr made) known))
                           (cl-some (lambda (input) (<= input (+ (car made) 1.0))) inputs)
                           (let ((cwd (plist-get (ignore-errors
                                                   (claude-code-ide-transcript-codex-meta path))
                                                 :cwd)))
                             (and (stringp cwd)
                                  (equal (file-name-as-directory (expand-file-name cwd)) folder))))
                  (throw 'found path))))))
        nil))))

(defun claude-code-ide-codex-events--new-conversation (instance entry file now)
  "Return the rollout of another conversation in the terminal of INSTANCE.
Return nil when the terminal shows the conversation of INSTANCE.
After /new or a fork in the terminal, the native ID of INSTANCE
stays, but Codex writes a new rollout file.  So a RET in the terminal after
the last record of FILE, and a new rollout of another conversation in
the same folder after that RET, mean that the terminal shows another
conversation.  A RET without such a file (an empty prompt, a slash
command such as /status, the answer to an approval) changes nothing.
ENTRY is the cache entry of INSTANCE; the search runs again only when
the RETs, the folders or the other conversations change.  NOW gives
the day folder of today."
  (let* ((buffer (claude-code-ide-instance-buffer instance))
         (written (float-time (car (plist-get entry :stamp))))
         (inputs (and (buffer-live-p buffer)
                      (cl-remove-if-not
                       (lambda (input) (> input (+ written 1.0)))
                       (buffer-local-value 'claude-code-ide-codex-events--inputs buffer)))))
    (when inputs
      (let* ((folders (claude-code-ide-codex-events--day-folders file now))
             (key (list written inputs
                        (mapcar (lambda (dir) (file-attribute-modification-time (file-attributes dir)))
                                folders)
                        (claude-code-ide-codex-events--known-conversations instance))))
        (if (equal key (plist-get entry :switch-key))
            (plist-get entry :switch)
          (let ((found (claude-code-ide-codex-events--find-new-conversation
                        instance file folders inputs)))
            (plist-put entry :switch-key key)
            (plist-put entry :switch found)
            found))))))

(defun claude-code-ide-codex-events--rollout-turn-state (turn start)
  "Return (STATE . DETAIL) of the last TURN record of a rollout file.
TURN nil is a conversation without a turn yet.  START is the start of
the launch, or nil.  Each state is a guess, with :source `rollout'."
  (let ((since (plist-get turn :time))
        (make (lambda (state reason since detail &optional extra)
                (cons (append (claude-code-ide-instance-make-state state reason since t)
                              (list :source 'rollout)
                              extra)
                      detail))))
    (pcase (plist-get turn :kind)
      ('started
       ;; The time has whole seconds.  A turn that started before the
       ;; launch did not end: its process was killed.
       (if (and start since (< (+ since 1.0) start))
           (funcall make 'idle nil nil "From rollout: a turn of an earlier run did not end")
         (funcall make 'working nil since "From rollout: a turn runs")))
      ('aborted (funcall make 'idle nil since "From rollout: interrupted"))
      ('complete
       (if (plist-get turn :error)
           (let* ((message (plist-get turn :error-message))
                  (kind (plist-get turn :error-kind))
                  (failure (claude-code-ide-codex-events--failure-kind kind message)))
             (funcall make 'failed (if (eq failure 'error) 'error 'quota-limit) since
                      (claude-code-ide-codex-events--failure-detail
                       failure (or message kind "unknown error") "From rollout: ")
                      (and (eq failure 'not-included) (list :not-included t))))
         (funcall make 'idle nil since "From rollout: turn ended")))
      (_ (funcall make 'idle nil nil "From rollout: no turn yet")))))

(defun claude-code-ide-codex-events--rollout-state (instance launch now)
  "Return (STATE . DETAIL) of INSTANCE, without status hooks, from its rollout.
LAUNCH is the launch record of INSTANCE, or nil.  STATE is a common
state plist.  The last turn record of the rollout file of the
conversation gives it, as a guess, with :source `rollout':

- `task_started': `working'.  A turn that started before the launch
  did not end, because its process was killed: `idle'.
- `task_complete' without an error, or `turn_aborted': `idle'.
- `task_complete' with an error: `failed/quota-limit' or
  `failed/error'; see `claude-code-ide-codex-events--failure-kind'.
- No turn record: `idle'.

An approval or a question shows as `working': the rollout has no
record of them.  These cases are `disconnected/untracked' without
:source: a file that cannot be read, a file without a whole session
record yet, a file whose session record is of another conversation,
and a terminal that shows another conversation (see
`claude-code-ide-codex-events--new-conversation').  Without a known
conversation or rollout file, return nil.  DETAIL does not say that
the hooks are missing; the caller adds that."
  (when-let* ((native (claude-code-ide-known-or-nil (claude-code-ide-instance-native-id instance)))
              (file (claude-code-ide-codex-events--rollout-file instance)))
    (let* ((entry (claude-code-ide-codex-events--rollout-read
                   (claude-code-ide-codex-events--rollout-entry instance native) file))
           (stamp (plist-get entry :stamp))
           (untracked (lambda (detail)
                        (cons (claude-code-ide-instance-make-state 'disconnected 'untracked) detail))))
      (cond
       ((null stamp) (funcall untracked "rollout file not readable"))
       ((null (plist-get entry :owner)) (funcall untracked "rollout file not readable yet"))
       ((eq (plist-get entry :owner) 'no)
        (funcall untracked "the rollout file is of another conversation"))
       ((claude-code-ide-codex-events--new-conversation instance entry file now)
        (funcall untracked "the terminal shows another conversation (/new or a fork)"))
       (t (claude-code-ide-codex-events--rollout-turn-state
           (plist-get entry :turn)
           (claude-code-ide-codex-events--launch-start instance launch entry)))))))

;;; The state of an instance

(defun claude-code-ide-codex-events--launch-state (launch now source)
  "Return (STATE . DETAIL) of LAUNCH at NOW; STATE has :source SOURCE.
A nil SOURCE gives no :source.  A launch whose plan does not include
Codex has :not-included t."
  (let ((state (claude-code-ide-codex-events--state launch now)))
    (pcase-let ((`(,common ,reason ,since ,guess ,_detail) state))
      (cons (append (claude-code-ide-instance-make-state common reason since guess)
                    (and source (list :source source))
                    (and (eq common 'failed)
                         (eq (claude-code-ide-codex-events--launch-failure launch) 'not-included)
                         (list :not-included t)))
            (claude-code-ide-codex-events--detail launch state)))))

(defun claude-code-ide-codex-events--compute-state (instance now)
  "Return (STATE . DETAIL) of the Codex INSTANCE at NOW.
See `claude-code-ide-codex-events--state-and-detail'."
  (let ((launch (claude-code-ide-codex-events--launch-of instance)))
    (cond
     ((and launch (claude-code-ide-codex-events--launch-hooks launch))
      (claude-code-ide-codex-events--launch-state launch now 'hooks))
     ((and launch (assq (claude-code-ide-codex-events--launch-dialog launch)
                        claude-code-ide-codex-events--dialog-details))
      (claude-code-ide-codex-events--launch-state launch now 'screen))
     (t
      (let ((problem (or (and launch (claude-code-ide-codex-events--trust-problem launch))
                         "No status hooks"))
            (rollout (progn
                       (claude-code-ide-codex-events--watch-input
                        (claude-code-ide-instance-buffer instance))
                       (claude-code-ide-codex-events--rollout-state instance launch now))))
        (cond
         ((and rollout (plist-get (car rollout) :source))
          (cons (car rollout) (concat (cdr rollout) " · " problem)))
         (rollout (cons (car rollout) (concat problem "; " (cdr rollout))))
         (launch (claude-code-ide-codex-events--launch-state launch now nil))
         (t (cons (claude-code-ide-instance-make-state 'disconnected 'untracked) problem))))))))

(defun claude-code-ide-codex-events--state-and-detail (instance now)
  "Return (STATE . DETAIL) of the Codex INSTANCE at NOW.
STATE is a common state plist.  Its :source tells what gave it:

- A launch with status hooks: the hooks (`hooks').
- A launch without hooks whose screen shows a dialog: the screen
  (`screen').
- Else the rollout file of the conversation (`rollout'), when one is
  known; see `claude-code-ide-codex-events--rollout-state'.
- Else `disconnected/untracked', without :source.

The result is computed once for each NOW (one refresh), while the
launch record, the conversation and the last input do not change."
  (let ((launch (claude-code-ide-codex-events--launch-of instance))
        (buffer (claude-code-ide-instance-buffer instance)))
    (claude-code-ide-session-status--once-per-refresh
     claude-code-ide-codex-events--state-cache instance now
     (lambda () (claude-code-ide-codex-events--compute-state instance now))
     (list (and launch (copy-sequence launch))
           (claude-code-ide-instance-native-id instance)
           (claude-code-ide-instance-generation instance)
           (and (buffer-live-p buffer)
                (car (buffer-local-value 'claude-code-ide-codex-events--inputs buffer)))))))

(defun claude-code-ide-codex-events--instance-state (instance now)
  "Return the common state of the Codex INSTANCE at NOW, or nil.
A Codex instance whose launch has no status hooks gets its state from
the rollout file of its conversation, else it is
`disconnected/untracked'.  See
`claude-code-ide-codex-events--state-and-detail'.  This is a function
of `claude-code-ide-instance-state-functions'."
  (when (eq (claude-code-ide-instance-provider instance) 'codex)
    (car (claude-code-ide-codex-events--state-and-detail instance now))))

(defun claude-code-ide-codex-events--instance-detail (instance now)
  "Return the detail text of the Codex INSTANCE at NOW, or nil.
This is a function of `claude-code-ide-session-status-detail-functions'."
  (when (eq (claude-code-ide-instance-provider instance) 'codex)
    (cdr (claude-code-ide-codex-events--state-and-detail instance now))))

;;; A plan without Codex

(declare-function claude-code-ide-handover "claude-code-ide-handover"
                  (instance-id target-provider &optional method context interrupt force))
(declare-function claude-code-ide-handover--read-args "claude-code-ide-handover"
                  (&optional instance-id))
(declare-function claude-code-ide-control-stop "claude-code-ide-control" (instance-id))

(defcustom claude-code-ide-codex-events-not-included-action 'ask
  "What Emacs does when you act on a Codex session whose plan lacks Codex.
Such a session is `failed/quota-limit' with the detail \"Not included
in the plan\".  You act on it with RET or a click on its row, with
`claude-code-ide-visit-waiting-session', or with the handover key of
the status buffer.  The values:

- `ask': ask, with c (continue), h (hand over) and s (stop).
- `continue': keep the session and send nothing.  A visit shows its
  terminal; the handover key does nothing.
- `handover': hand the work over to a new conversation
  (`claude-code-ide-handover', which asks for the target).
- `stop': end the session (`claude-code-ide-control-stop').

A coordinator never gets this question: it reads the state and the
detail."
  :type '(choice (const :tag "Ask each time" ask)
                 (const :tag "Continue" continue)
                 (const :tag "Hand over" handover)
                 (const :tag "Stop" stop))
  :group 'claude-code-ide)

(defun claude-code-ide-codex-events--not-included-choice ()
  "Return the action for a session whose plan lacks Codex.
See `claude-code-ide-codex-events-not-included-action'."
  (if (eq claude-code-ide-codex-events-not-included-action 'ask)
      (pcase (car (read-multiple-choice
                   "The plan of this account does not include Codex"
                   '((?c "continue" "Keep the session and send nothing")
                     (?h "hand over" "Hand the work over to a new conversation")
                     (?s "stop" "End the session"))))
        (?h 'handover)
        (?s 'stop)
        (_ 'continue))
    claude-code-ide-codex-events-not-included-action))

(defun claude-code-ide-codex-events--act (instance command)
  "Take over COMMAND of the user on INSTANCE when its plan lacks Codex.
COMMAND is `visit' or `handover'.  Return non-nil when this function
did the action.  This is a function of
`claude-code-ide-session-status-act-functions'."
  (when (and (eq (claude-code-ide-instance-provider instance) 'codex)
             (plist-get (claude-code-ide-instance-state instance) :not-included))
    (let ((id (claude-code-ide-instance-id instance)))
      (pcase (claude-code-ide-codex-events--not-included-choice)
        ('handover
         (unless (and (require 'claude-code-ide-handover nil t)
                      (fboundp 'claude-code-ide-handover))
           (user-error "The handover file is not available"))
         (apply #'claude-code-ide-handover (claude-code-ide-handover--read-args id))
         t)
        ('stop
         (unless (and (require 'claude-code-ide-control nil t)
                      (fboundp 'claude-code-ide-control-stop))
           (user-error "The control file is not available"))
         (let ((result (claude-code-ide-control-stop id)))
           (message "Codex session %s: %s" (claude-code-ide-format-value
                                            (claude-code-ide-instance-display-name instance))
                    (if (eq (plist-get result :status) 'ok)
                        "stopped"
                      (or (plist-get result :message) (format "%s" (plist-get result :status))))))
         t)
        ;; Continue: a visit shows the terminal, the handover key does nothing
        (_ (and (eq command 'handover)
                (progn (message "The Codex session stays") t)))))))

(add-hook 'claude-code-ide-session-status-act-functions #'claude-code-ide-codex-events--act)

(add-hook 'claude-code-ide-instance-state-functions
          #'claude-code-ide-codex-events--instance-state)
(add-hook 'claude-code-ide-session-status-detail-functions
          #'claude-code-ide-codex-events--instance-detail)

;;; Reading events

(defconst claude-code-ide-codex-events--file-regexp
  "\\`\\([A-Za-z0-9-]+\\)\\.\\([0-9]+\\)\\.\\([0-9]+\\)\\.\\([A-Za-z]+\\)\\.json\\'"
  "Regexp for an event file: INSTANCE.GENERATION.SEQUENCE.EVENT.json.")

(defun claude-code-ide-codex-events--event-files ()
  "Return the event files of this Emacs, oldest first within each launch."
  (let ((dir (claude-code-ide-codex-events--events-directory)))
    (when (file-directory-p dir)
      (sort (directory-files dir t claude-code-ide-codex-events--file-regexp t)
            #'string<))))

(defun claude-code-ide-codex-events--read-file (file)
  "Return the record in the event FILE as an alist, or nil when it cannot be read."
  (claude-code-ide-session-status--read-json-file file))

(defun claude-code-ide-codex-events--note-identity (instance data &optional switch)
  "Copy the model and the conversation ID of the event DATA to INSTANCE.
The conversation ID replaces an unknown one, or any one when SWITCH is
non-nil: the launch moved to another conversation."
  (when instance
    (when-let* ((model (claude-code-ide-codex-events--string data 'model)))
      (setf (claude-code-ide-instance-model instance) model))
    (when-let* ((native (claude-code-ide-codex-events--string data 'session_id)))
      (when (or switch (claude-code-ide-unknown-p (claude-code-ide-instance-native-id instance)))
        (setf (claude-code-ide-instance-native-id instance) native)))))

(defun claude-code-ide-codex-events--handle (instance-id generation event data &optional now)
  "Apply the hook EVENT with DATA of the launch INSTANCE-ID GENERATION.
The event counts only for the current launch of a running instance,
and only for the conversation ID of that launch.  A SessionStart of
the main agent with another conversation ID (after /new, or a switch
to another thread in the terminal) moves the launch, and the
descriptor, to that conversation.  Other events with another
conversation ID are dropped.  Return the common event when the event
was applied, else nil."
  (let ((launch (gethash instance-id claude-code-ide-codex-events--launches)))
    (when (and launch (= generation (claude-code-ide-codex-events--launch-generation launch)))
      (let ((common (claude-code-ide-make-event
                     instance-id generation
                     (claude-code-ide-codex-events-map-event event data)
                     event data now))
            (native (claude-code-ide-codex-events--string data 'session_id))
            (known (claude-code-ide-codex-events--launch-session-id launch)))
        (let ((switch (and native known (not (equal native known))
                           (equal event "SessionStart")
                           (null (claude-code-ide-codex-events--string data 'agent_id)))))
          (when (and (claude-code-ide-event-current-p common)
                     (or (null native) (null known) (equal native known) switch))
            (when (or switch (null known))
              (setf (claude-code-ide-codex-events--launch-session-id launch) native))
            (claude-code-ide-codex-events--apply launch event data now)
            (claude-code-ide-codex-events--note-identity
             (claude-code-ide-instance-by-id instance-id) data switch)
            common))))))

(defun claude-code-ide-codex-events--drain ()
  "Apply and delete the waiting Codex event files, at most 500 per call.
Files of launches that this Emacs does not track are deleted unread."
  (when (timerp claude-code-ide-codex-events--drain-timer)
    (cancel-timer claude-code-ide-codex-events--drain-timer))
  (setq claude-code-ide-codex-events--drain-timer nil)
  (claude-code-ide-codex-events--remove-stale-locks)
  (let ((files (claude-code-ide-codex-events--event-files))
        (count 0)
        (changed nil))
    (while (and files (< count 500))
      (let* ((file (pop files))
             (name (file-name-nondirectory file)))
        (when (string-match claude-code-ide-codex-events--file-regexp name)
          (let* ((id (match-string 1 name))
                 (generation (string-to-number (match-string 2 name)))
                 (event (match-string 4 name))
                 (launch (gethash id claude-code-ide-codex-events--launches))
                 (record (and launch (claude-code-ide-codex-events--read-file file))))
            (when (and record
                       (equal (alist-get 'instance_id record) id)
                       (equal (alist-get 'generation record) (number-to-string generation))
                       (equal (alist-get 'event record) event))
              (let ((common (condition-case err
                                (claude-code-ide-codex-events--handle
                                 id generation event (alist-get 'input record))
                              (error
                               (message "Codex status: %s event failed: %s"
                                        event (error-message-string err))
                               nil))))
                (when common
                  (setq changed t)
                  (condition-case err
                      (claude-code-ide-dispatch-event common)
                    (error
                     (message "Codex status: event function failed on %s: %s"
                              event (error-message-string err)))))))))
        (ignore-errors (delete-file file))
        (cl-incf count)))
    (when files
      (claude-code-ide-codex-events--schedule-drain))
    (when changed
      (claude-code-ide-session-status--refresh))))

(defun claude-code-ide-codex-events--schedule-drain ()
  "Read the event files in a moment."
  (unless (timerp claude-code-ide-codex-events--drain-timer)
    (setq claude-code-ide-codex-events--drain-timer
          (run-with-timer 0.1 nil #'claude-code-ide-codex-events--drain))))

;;; Startup dialogs

;; The Codex launch defines `claude-code-ide-codex-screen-dialog' (BUFFER):
;; it returns nil, or one of `folder-trust', `update', `hooks-review',
;; `approval' and `other', from the visible text of the terminal only,
;; and it never sends keys.  This file calls it only when it is bound.

(defun claude-code-ide-codex-events--needs-screen-p (launch now)
  "Return non-nil when the screen of LAUNCH is to be read at NOW.
That is while no hook event came yet, after the startup grace time, and
while an approval of the main agent waits, a moment after its request,
because Codex draws the dialog after the event."
  (or (and (null (claude-code-ide-codex-events--launch-last-event launch))
           (>= (- now (claude-code-ide-codex-events--launch-registered launch))
               claude-code-ide-codex-events-startup-grace))
      (cl-some (lambda (blocker)
                 (and (eq (claude-code-ide-codex-events--blocker-kind blocker) 'approval)
                      (null (car-safe (claude-code-ide-codex-events--blocker-tool blocker)))
                      (>= (- now (claude-code-ide-codex-events--blocker-since blocker)) 1.5)))
               (claude-code-ide-codex-events--launch-blockers launch))))

(defun claude-code-ide-codex-events--read-screen (launch instance now)
  "Read the terminal of INSTANCE for a dialog and note it in LAUNCH at NOW.
The reader `claude-code-ide-codex-screen-dialog' belongs to the Codex
launch; without it nothing happens.  It never sends keys.  Return
non-nil when the state of LAUNCH changed."
  (let ((buffer (claude-code-ide-instance-buffer instance)))
    (when (and (fboundp 'claude-code-ide-codex-screen-dialog)
               (buffer-live-p buffer)
               (claude-code-ide-codex-events--needs-screen-p launch now))
      (let* ((before (claude-code-ide-codex-events--state launch now))
             (dialog (funcall 'claude-code-ide-codex-screen-dialog buffer)))
        (setf (claude-code-ide-codex-events--launch-dialog launch) dialog
              (claude-code-ide-codex-events--launch-dialog-checked launch) now)
        ;; The screen shows the dialogs of the main agent only
        (dolist (blocker (claude-code-ide-codex-events--launch-blockers launch))
          (when (and (eq (claude-code-ide-codex-events--blocker-kind blocker) 'approval)
                     (null (car-safe (claude-code-ide-codex-events--blocker-tool blocker))))
            (setf (claude-code-ide-codex-events--blocker-answered blocker)
                  (if dialog
                      nil
                    (or (claude-code-ide-codex-events--blocker-answered blocker) now)))))
        (not (equal (butlast (claude-code-ide-codex-events--state launch now) 3)
                    (butlast before 3)))))))

;;; Hook trust: the Codex app-server

(cl-defstruct (claude-code-ide-codex-events--server
               (:constructor claude-code-ide-codex-events--server-create)
               (:copier nil))
  "A Codex app-server process that Emacs talks to over stdio with JSON-RPC."
  (process nil)
  (output "" :type string :documentation "Output that is not a whole line yet.")
  (next-id 1 :type integer)
  (ready nil :documentation "Non-nil after the initialize answer.")
  (queue nil :documentation "Requests that wait for the initialize answer.")
  (pending (make-hash-table :test 'eql) :documentation "Request ID -> callback."))

(defun claude-code-ide-codex-events--server-send (server message)
  "Send MESSAGE, an alist, to SERVER as one JSON line."
  (let ((process (claude-code-ide-codex-events--server-process server)))
    (when (process-live-p process)
      (process-send-string process (concat (json-encode message) "\n")))))

(defun claude-code-ide-codex-events--server-answer (server message)
  "Pass the answer MESSAGE of SERVER to the callback of its request."
  (let* ((id (alist-get 'id message))
         (pending (claude-code-ide-codex-events--server-pending server))
         (callback (and (integerp id) (gethash id pending))))
    (when callback
      (remhash id pending)
      (funcall callback (alist-get 'result message) (alist-get 'error message)))))

(defun claude-code-ide-codex-events--server-filter (server string)
  "Read the JSON lines of STRING, the output of SERVER."
  (let* ((text (concat (claude-code-ide-codex-events--server-output server) string))
         (lines (split-string text "\n")))
    (setf (claude-code-ide-codex-events--server-output server) (car (last lines)))
    (dolist (line (butlast lines))
      (let ((message (ignore-errors
                       (claude-code-ide-session-status--parse-json line :false))))
        (when (and (consp message) (assq 'id message)
                   (or (assq 'result message) (assq 'error message)))
          (claude-code-ide-codex-events--server-answer server message))))))

(defun claude-code-ide-codex-events--server-fail-all (server reason)
  "Call each waiting callback of SERVER with the error REASON."
  (let ((pending (claude-code-ide-codex-events--server-pending server))
        (callbacks nil))
    (maphash (lambda (_id callback) (push callback callbacks)) pending)
    (clrhash pending)
    (dolist (request (claude-code-ide-codex-events--server-queue server))
      (push (nth 2 request) callbacks))
    (setf (claude-code-ide-codex-events--server-queue server) nil)
    (dolist (callback callbacks)
      (funcall callback nil `((message . ,reason))))))

(defun claude-code-ide-codex-events--server-request (server method params callback)
  "Send the request METHOD with PARAMS to SERVER.
CALLBACK is called with RESULT and ERROR when the answer comes.
Requests wait until SERVER answered its initialize request."
  (if (not (claude-code-ide-codex-events--server-ready server))
      (setf (claude-code-ide-codex-events--server-queue server)
            (append (claude-code-ide-codex-events--server-queue server)
                    (list (list method params callback))))
    (let ((id (cl-incf (claude-code-ide-codex-events--server-next-id server))))
      (puthash id callback (claude-code-ide-codex-events--server-pending server))
      (claude-code-ide-codex-events--server-send
       server `((jsonrpc . "2.0") (id . ,id) (method . ,method) (params . ,params))))))

(defun claude-code-ide-codex-events--server-start (args &optional directory)
  "Start `codex app-server' with the extra ARGS in DIRECTORY and return it.
The API key variable is removed, as for each Codex process of the
package, so the app-server uses the login of the user.  The server
gets its initialize request at once."
  (let* ((server (claude-code-ide-codex-events--server-create))
         (default-directory (file-name-as-directory (or directory (expand-file-name "~"))))
         (process-environment (cons "OPENAI_API_KEY" process-environment))
         (process (make-process
                   :name "cci-codex-app-server"
                   :command (append (list claude-code-ide-codex-events-program "app-server") args)
                   :connection-type 'pipe
                   :coding 'utf-8-unix
                   :noquery t
                   :stderr (get-buffer-create " *cci-codex-app-server-stderr*")
                   :filter (lambda (_process string)
                             (claude-code-ide-codex-events--server-filter server string))
                   :sentinel (lambda (process _event)
                               (unless (process-live-p process)
                                 (claude-code-ide-codex-events--server-fail-all
                                  server "the Codex app-server ended"))))))
    (setf (claude-code-ide-codex-events--server-process server) process)
    (puthash 1 (lambda (_result error)
                 (if error
                     (claude-code-ide-codex-events--server-fail-all
                      server (format "initialize failed: %s" (alist-get 'message error)))
                   (claude-code-ide-codex-events--server-send
                    server '((jsonrpc . "2.0") (method . "initialized")))
                   (setf (claude-code-ide-codex-events--server-ready server) t)
                   (let ((queue (claude-code-ide-codex-events--server-queue server)))
                     (setf (claude-code-ide-codex-events--server-queue server) nil)
                     (dolist (request queue)
                       (apply #'claude-code-ide-codex-events--server-request server request)))))
             (claude-code-ide-codex-events--server-pending server))
    (claude-code-ide-codex-events--server-send
     server `((jsonrpc . "2.0") (id . 1) (method . "initialize")
              (params . ((clientInfo . ((name . "claude-code-ide") (version . "1")))))))
    server))

(defun claude-code-ide-codex-events--server-stop (server)
  "End SERVER.  A nil SERVER, of a check whose app-server did not start, is fine."
  (when-let* ((process (and server (claude-code-ide-codex-events--server-process server))))
    (when (process-live-p process)
      (delete-process process))))

(defun claude-code-ide-codex-events--server-call (server method params &optional timeout)
  "Send METHOD with PARAMS to SERVER and wait for the answer.
Return (:result RESULT) or (:error MESSAGE).  The wait ends after
TIMEOUT seconds (default `claude-code-ide-codex-events-trust-timeout')."
  (let ((done nil)
        (answer nil)
        (deadline (+ (float-time) (or timeout claude-code-ide-codex-events-trust-timeout))))
    (claude-code-ide-codex-events--server-request
     server method params
     (lambda (result error)
       (setq done t
             answer (if error
                        (list :error (or (alist-get 'message error) (format "%S" error)))
                      (list :result result)))))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output (claude-code-ide-codex-events--server-process server) 0.1))
    (or answer (list :error "the Codex app-server did not answer in time"))))

(defun claude-code-ide-codex-events--our-hooks (result)
  "Return the status hooks of this package in the `hooks/list' RESULT.
They are the hooks of the session flags whose command runs the hook
script."
  (let ((script (claude-code-ide-codex-events--script-file))
        (hooks nil))
    (dolist (entry (alist-get 'data result))
      (dolist (hook (alist-get 'hooks entry))
        (let ((command (alist-get 'command hook)))
          (when (and (equal (alist-get 'source hook) "sessionFlags")
                     (stringp command)
                     (string-search script (replace-regexp-in-string "\\\\" "" command)))
            (push hook hooks)))))
    (nreverse hooks)))

(defun claude-code-ide-codex-events--hook-trusted-p (hook)
  "Return non-nil when Codex runs HOOK: it is trusted (or managed) and enabled."
  (and (member (alist-get 'trustStatus hook) '("trusted" "managed"))
       (not (eq (alist-get 'enabled hook) :false))))

(defconst claude-code-ide-codex-events--disabled-detail
  "Hooks disabled in Codex (/hooks)"
  "Detail of a launch whose hooks the user disabled with /hooks.")

(defun claude-code-ide-codex-events--hook-disabled-p (hook)
  "Return non-nil when the user disabled HOOK with /hooks."
  (eq (alist-get 'enabled hook) :false))

(defun claude-code-ide-codex-events--trust-result (answer)
  "Return the trust result of the `hooks/list' ANSWER.
The result is a plist: :status is `trusted', `untrusted' (some hooks
are enabled and not trusted), `disabled' (the hooks that Codex does
not run are all disabled with /hooks) or `error'; :hooks holds the
hooks of this package that Codex does not run; :message explains it."
  (if-let* ((error (plist-get answer :error)))
      (list :status 'error :message (format "Hook trust unknown: %s" error))
    (let* ((hooks (claude-code-ide-codex-events--our-hooks (plist-get answer :result)))
           (bad (cl-remove-if #'claude-code-ide-codex-events--hook-trusted-p hooks))
           (expected (length claude-code-ide-codex-events--events)))
      (cond
       ((and bad (cl-every #'claude-code-ide-codex-events--hook-disabled-p bad))
        (list :status 'disabled :hooks bad :message claude-code-ide-codex-events--disabled-detail))
       (bad
        (list :status 'untrusted :hooks bad
              :message (format "%d of %d Codex status hooks not trusted: M-x claude-code-ide-codex-trust-hooks"
                               (length bad) expected)))
       ((< (length hooks) expected)
        (list :status 'error
              :message (format "Codex lists %d of %d status hooks" (length hooks) expected)))
       (t (let ((pairs (mapcar (lambda (hook)
                                 (cons (alist-get 'key hook) (alist-get 'currentHash hook)))
                               (cl-remove-if-not
                                (lambda (hook) (equal (alist-get 'trustStatus hook) "trusted"))
                                hooks))))
            (list :status 'trusted :message nil :trust pairs
                  :cache (cond
                          ;; A trusted hook without its key or hash cannot be checked
                          ((not (cl-every #'claude-code-ide-codex-events--trust-pair-p pairs)) nil)
                          ;; Managed hooks have no record in config.toml
                          ((or (null pairs) (< (length pairs) (length hooks))) 'ttl)
                          (t 'records)))))))))

(defun claude-code-ide-codex-events--trust-pair-p (pair)
  "Return non-nil when PAIR is (STATE-KEY . HASH) of two non-empty strings."
  (and (consp pair)
       (stringp (car pair)) (not (string-empty-p (car pair)))
       (stringp (cdr pair)) (not (string-empty-p (cdr pair)))))

(defun claude-code-ide-codex-events--config-stamp ()
  "Return (TIME SIZE) of the Codex config file, or nil when it is missing."
  (when-let* ((attributes (file-attributes (claude-code-ide-transcript--codex-config-file))))
    (list (file-attribute-modification-time attributes)
          (file-attribute-size attributes))))

(defun claude-code-ide-codex-events--program-identity ()
  "Return a text that names the Codex program and its version.
That is the true path of `claude-code-ide-codex-events-program' and
the modification time and size of that file: an update of Codex
changes them.  No process runs."
  (let* ((found (executable-find claude-code-ide-codex-events-program))
         (true (and found (file-truename found)))
         (attributes (and true (file-attributes true))))
    (if attributes
        (format "%s@%s:%s" true
                (float-time (file-attribute-modification-time attributes))
                (file-attribute-size attributes))
      (format "%s@missing" claude-code-ide-codex-events-program))))

(defun claude-code-ide-codex-events--trust-key ()
  "Return the key of the trust cache.
It holds a hash of the hook definitions, the path of the Codex config
file, and the Codex program with its version
\(`claude-code-ide-codex-events--program-identity').  New hook
definitions (a new package version, another script path), another
CODEX_HOME, or another Codex give another key, so their first
interactive start asks again."
  (concat (secure-hash 'sha256 (mapconcat #'identity (claude-code-ide-codex-events--hook-args) "\n"))
          "|" (claude-code-ide-transcript--codex-config-file)
          "|" (claude-code-ide-codex-events--program-identity)))

(defconst claude-code-ide-codex-events--unverifiable-ttl 60
  "Seconds that a trusted result without records in config.toml stays valid.
Managed hooks have no trust record that Emacs can read, so such a
result is checked again through `hooks/list' at most once a minute.")

(defun claude-code-ide-codex-events--remember-trust (key result)
  "Keep the trust RESULT of KEY in the cache, with the config stamp of now.
A result that is not `trusted', `untrusted' or `disabled' is not kept,
and neither is a trusted result that cannot be checked later (its
:cache is nil)."
  (when (and (memq (claude-code-ide-codex-events--result-status result) '(trusted untrusted disabled))
             (or (not (eq (plist-get result :status) 'trusted))
                 (plist-get result :cache)))
    (puthash key (append (list :config-stamp (claude-code-ide-codex-events--config-stamp)
                               :checked-at (float-time))
                         result)
             claude-code-ide-codex-events--trust-cache)))

(defun claude-code-ide-codex-events--config-trusts-p (trust)
  "Return non-nil when the Codex config file still trusts TRUST.
TRUST is a non-empty list of (STATE-KEY . HASH) of non-empty strings.
Each STATE-KEY must have `trusted_hash' equal to HASH in the table
`hooks.state', and must not have `enabled = false'.  The file is only
read, with `claude-code-ide-transcript--codex-config-entries'.  An
empty TRUST, a pair with a missing key or hash, a missing or
unreadable file, and a form that the reader does not know give nil."
  (when (and trust (cl-every #'claude-code-ide-codex-events--trust-pair-p trust))
    (when-let* ((entries (claude-code-ide-transcript--codex-config-entries)))
      (cl-every (lambda (pair)
                  (and (equal (cdr (assoc (list "hooks" "state" (car pair) "trusted_hash") entries))
                              (cdr pair))
                       (not (eq (cdr (assoc (list "hooks" "state" (car pair) "enabled") entries))
                                :false))))
                trust))))

(defun claude-code-ide-codex-events--cached-trust (key)
  "Return the cached trust result of KEY, or nil.
A `trusted' result is valid while the Codex config file still has the
trust records that `hooks/list' reported (see
`claude-code-ide-codex-events--config-trusts-p'), whatever else in the
file changed: Codex writes the file at each terminal start.  A trusted
result with managed hooks, which have no record, is valid for
`claude-code-ide-codex-events--unverifiable-ttl' seconds.  An
`untrusted' or `disabled' result is valid while the file keeps the
time and the size of the check, because /hooks in a terminal can trust
or enable the hooks.  An invalid result leaves the cache."
  (when-let* ((cached (gethash key claude-code-ide-codex-events--trust-cache)))
    (if (if (eq (plist-get cached :status) 'trusted)
            (pcase (plist-get cached :cache)
              ('records (claude-code-ide-codex-events--config-trusts-p (plist-get cached :trust)))
              ;; Managed hooks: at most a minute, and the records that there are
              ('ttl (and (< (- (float-time) (or (plist-get cached :checked-at) 0))
                            claude-code-ide-codex-events--unverifiable-ttl)
                         (or (null (plist-get cached :trust))
                             (claude-code-ide-codex-events--config-trusts-p
                              (plist-get cached :trust)))))
              (_ nil))
          (equal (plist-get cached :config-stamp) (claude-code-ide-codex-events--config-stamp)))
        cached
      (remhash key claude-code-ide-codex-events--trust-cache)
      nil)))

(defun claude-code-ide-codex-events--result-status (result)
  "Return the :status of the trust RESULT, or nil for `:pending' or nil."
  (and (consp result) (plist-get result :status)))

(defconst claude-code-ide-codex-events--restart-detail
  "Hooks were not trusted at the launch: restart to get status"
  "Detail of a launch that started before its hooks were trusted.")

(defconst claude-code-ide-codex-events--ask-detail
  "Hooks not trusted; the next interactive start asks"
  "Detail of a launch without hooks that no user started.")

(defconst claude-code-ide-codex-events--declined-detail
  "Hooks not trusted; M-x claude-code-ide-codex-trust-hooks trusts them"
  "Detail of a launch without hooks after the user declined the trust.")

(defconst claude-code-ide-codex-events--unchecked-detail
  "Hook trust not known at the start; a check runs for the next start"
  "Detail of a launch without hooks whose trust was not known yet.")

(defun claude-code-ide-codex-events--no-hooks-detail (status key interactive &optional message)
  "Return the detail of a launch without hooks for the trust STATUS of KEY.
INTERACTIVE is non-nil for a start of the user; MESSAGE is the text of
the result."
  (pcase status
    ('trusted claude-code-ide-codex-events--restart-detail)
    ('disabled claude-code-ide-codex-events--disabled-detail)
    ('untrusted (cond
                 ((member key claude-code-ide-codex-events--declined)
                  claude-code-ide-codex-events--declined-detail)
                 ((and interactive message) message)
                 (t claude-code-ide-codex-events--ask-detail)))
    (_ (or message claude-code-ide-codex-events--unchecked-detail))))

(defun claude-code-ide-codex-events--set-trust (key result)
  "Note the trust RESULT of KEY in the launch records without hooks.
A launch with hooks runs them: Codex read the trust at its start.  A
launch without hooks gets status events only after a restart; its
detail says what the next start does."
  (let ((status (claude-code-ide-codex-events--result-status result)))
    (maphash (lambda (_id launch)
               (unless (claude-code-ide-codex-events--launch-hooks launch)
                 (when status
                   (setf (claude-code-ide-codex-events--launch-trust launch) status))
                 (setf (claude-code-ide-codex-events--launch-trust-detail launch)
                       (claude-code-ide-codex-events--no-hooks-detail
                        status key nil (plist-get result :message)))))
             claude-code-ide-codex-events--launches))
  (claude-code-ide-session-status--refresh))

(defun claude-code-ide-codex-events--list-params (&optional directory)
  "Return the `hooks/list' parameters for DIRECTORY (default: home)."
  `((cwds . ,(vector (or directory (expand-file-name "~"))))))

(cl-defstruct (claude-code-ide-codex-events--check
               (:constructor claude-code-ide-codex-events--check-create)
               (:copier nil))
  "One trust check of the hook definitions with a Codex app-server."
  (key nil :type string)
  (directory nil :documentation "Folder of the `hooks/list' call, or nil for home.")
  (server nil :documentation "The app-server, or nil.")
  (result nil :documentation "The trust result, or nil while the check runs.")
  (timer nil :documentation "Timer that ends a check that nobody waits for.")
  (keep nil :documentation "Non-nil while a start waits and wants the server after the answer."))

(defun claude-code-ide-codex-events--finish-check (check result)
  "End CHECK with RESULT: cache it, tell the launches, and free the app-server.
The app-server stays when a waiting start keeps it for a trust write."
  (unless (claude-code-ide-codex-events--check-result check)
    (let ((key (claude-code-ide-codex-events--check-key check)))
      (setf (claude-code-ide-codex-events--check-result check) result)
      (when (eq (gethash key claude-code-ide-codex-events--checks) check)
        (remhash key claude-code-ide-codex-events--checks))
      (when (timerp (claude-code-ide-codex-events--check-timer check))
        (cancel-timer (claude-code-ide-codex-events--check-timer check)))
      (unless (claude-code-ide-codex-events--check-keep check)
        (claude-code-ide-codex-events--server-stop (claude-code-ide-codex-events--check-server check)))
      (claude-code-ide-codex-events--remember-trust key result)
      (claude-code-ide-codex-events--set-trust key result))))

(defun claude-code-ide-codex-events--start-trust-check (key directory)
  "Return the running trust check of KEY, or start one in DIRECTORY.
Starts of the same key share one check and one app-server.  The check
calls `hooks/list' and ends with its answer, or after
`claude-code-ide-codex-events--background-limit' seconds.  Its result
goes to the cache and to the launch records.  When the app-server
cannot start, the check has an error result at once."
  (or (gethash key claude-code-ide-codex-events--checks)
      (let* ((dir (and directory (file-directory-p directory) directory))
             (check (claude-code-ide-codex-events--check-create :key key :directory dir)))
        (condition-case err
            (let ((server (claude-code-ide-codex-events--server-start
                           (claude-code-ide-codex-events--hook-args) dir)))
              (setf (claude-code-ide-codex-events--check-server check) server
                    (claude-code-ide-codex-events--check-timer check)
                    (run-with-timer claude-code-ide-codex-events--background-limit nil
                                    (lambda ()
                                      (setf (claude-code-ide-codex-events--check-keep check) nil)
                                      (claude-code-ide-codex-events--finish-check
                                       check (list :status 'error
                                                   :message "Hook trust unknown: the Codex app-server did not answer")))))
              (puthash key check claude-code-ide-codex-events--checks)
              (claude-code-ide-codex-events--server-request
               server "hooks/list" (claude-code-ide-codex-events--list-params dir)
               (lambda (answer error)
                 (claude-code-ide-codex-events--finish-check
                  check (claude-code-ide-codex-events--trust-result
                         (if error
                             (list :error (or (alist-get 'message error) (format "%S" error)))
                           (list :result answer)))))))
          (error
           (setf (claude-code-ide-codex-events--check-result check)
                 (list :status 'error
                       :message (format "Hook trust unknown: %s" (error-message-string err))))))
        check)))

(defun claude-code-ide-codex-events--wait-check (check deadline)
  "Wait for the result of CHECK until the float time DEADLINE.
Return the result, or `:pending' when it did not come in time."
  (let ((process (and (claude-code-ide-codex-events--check-server check)
                      (claude-code-ide-codex-events--server-process
                       (claude-code-ide-codex-events--check-server check)))))
    (while (and (null (claude-code-ide-codex-events--check-result check))
                (< (float-time) deadline))
      (accept-process-output process 0.05))
    (or (claude-code-ide-codex-events--check-result check) :pending)))

(defun claude-code-ide-codex-events--release-check (check)
  "Let CHECK free its app-server: now when it has its result, else at its end."
  (when check
    (setf (claude-code-ide-codex-events--check-keep check) nil)
    (when (claude-code-ide-codex-events--check-result check)
      (claude-code-ide-codex-events--server-stop (claude-code-ide-codex-events--check-server check)))))

(defun claude-code-ide-codex-events--settle-trust (launch instance interactive)
  "Settle the hook trust for LAUNCH of INSTANCE before its start.
INTERACTIVE is the `interactive' slot of the start spec.

- A valid cached result needs no app-server.
- On a cache miss, the start shares the running check of the key, or
  starts one, in the project folder.  An interactive start waits for
  it, at most `claude-code-ide-codex-events-trust-timeout' seconds in
  all.  Any other start never waits: it goes on without hooks, and the
  check fills the cache for the next start.
- Trusted: the launch gets its hooks.  Only then.
- Not trusted, in an interactive start that the user did not decline in
  this Emacs: `claude-code-ide-codex-events--offer-trust' shows the
  hooks and asks.  After a yes, the launch gets its trusted hooks.
- Disabled with /hooks, declined, not interactive, or not known in
  time: no hooks, and no question.  The detail says why.
LAUNCH gets the result in its `trust', `trust-detail' and `hooks'."
  (let* ((key (claude-code-ide-codex-events--trust-key))
         (directory (claude-code-ide-known-or-nil (claude-code-ide-instance-project-root instance)))
         (deadline (+ (float-time) claude-code-ide-codex-events-trust-timeout))
         (result (claude-code-ide-codex-events--cached-trust key))
         (check nil))
    ;; A C-g in the wait or in the question still frees the check
    (unwind-protect
        (progn
          (unless result
            (setf (claude-code-ide-codex-events--launch-trust launch) 'checking)
            (setq check (claude-code-ide-codex-events--start-trust-check key directory))
            (cond
             ((null check))
             (interactive
              (unless (claude-code-ide-codex-events--check-result check)
                (setf (claude-code-ide-codex-events--check-keep check) t))
              (setq result (claude-code-ide-codex-events--wait-check check deadline)))
             ;; Another start never waits, but uses a result that is there
             (t (setq result (claude-code-ide-codex-events--check-result check)))))
          (when (and interactive
                     (eq (claude-code-ide-codex-events--result-status result) 'untrusted)
                     (not (member key claude-code-ide-codex-events--declined)))
            (setq result (claude-code-ide-codex-events--offer-trust
                          result (or (and check (claude-code-ide-codex-events--check-directory check))
                                     (and directory (file-directory-p directory) directory))
                          (and check (claude-code-ide-codex-events--check-server check))))))
      (claude-code-ide-codex-events--release-check check))
    (let ((status (claude-code-ide-codex-events--result-status result)))
      (setf (claude-code-ide-codex-events--launch-hooks launch) (eq status 'trusted)
            (claude-code-ide-codex-events--launch-trust launch) (or status 'checking)
            (claude-code-ide-codex-events--launch-trust-detail launch)
            (cond
             ((eq status 'trusted) nil)
             ((eq result :pending)
              (format "Hook trust unknown: no answer in %s s; the check goes on for the next start"
                      claude-code-ide-codex-events-trust-timeout))
             (t (claude-code-ide-codex-events--no-hooks-detail
                 status key interactive (plist-get result :message))))))))

(defun claude-code-ide-codex-events--trust-edits (hooks)
  "Return the `config/batchWrite' edits that trust HOOKS.
Each edit merges { KEY: { trusted_hash: HASH } } into `hooks.state',
the same record that /hooks in the Codex terminal writes."
  (vconcat
   (mapcar (lambda (hook)
             `((keyPath . "hooks.state")
               (mergeStrategy . "upsert")
               (value . ((,(alist-get 'key hook)
                          . ((trusted_hash . ,(alist-get 'currentHash hook))))))))
           hooks)))

(defun claude-code-ide-codex-events--describe-hooks (hooks)
  "Return a text that lists HOOKS with their command and trust."
  (mapconcat (lambda (hook)
               (format "  %-18s %-9s %s\n      key %s\n"
                       (alist-get 'eventName hook)
                       (if (claude-code-ide-codex-events--hook-disabled-p hook)
                           "disabled"
                         (alist-get 'trustStatus hook))
                       (alist-get 'command hook)
                       (alist-get 'key hook)))
             hooks ""))

(defun claude-code-ide-codex-events--show-hooks (untrusted disabled)
  "Show the UNTRUSTED and DISABLED hooks in the buffer *Codex status hooks*."
  (let ((buffer (get-buffer-create "*Codex status hooks*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Codex runs these status hooks of claude-code-ide only after you trust them.\n"
                "Each one records the event for Emacs and changes nothing else.\n\n"
                (claude-code-ide-codex-events--describe-hooks untrusted)
                (if disabled
                    (concat "\nDisabled with /hooks (not changed):\n"
                            (claude-code-ide-codex-events--describe-hooks disabled))
                  ""))
        (special-mode)))
    (display-buffer buffer)))

(defun claude-code-ide-codex-events--offer-trust (result directory &optional server manual)
  "Offer the trust of the hooks in the `untrusted' RESULT; return the result.
RESULT comes from `hooks/list' in DIRECTORY; it is used as it is, so
nothing lists the hooks again before the question.  The hooks that
Codex does not run are shown in *Codex status hooks*, and
`yes-or-no-p' asks.  After a yes, their trust goes to the Codex config
file through the app-server (`config/batchWrite'), as /hooks in a
Codex terminal writes it, and `hooks/list' in DIRECTORY checks it.
Never without the yes.  A no puts the hook definitions in
`claude-code-ide-codex-events--declined', so that no start asks again
in this Emacs.  C-g is a no for this question only.

SERVER is the app-server of the check, when it still runs; else one
starts for the write.  After the question, the write and the second
list each get the full time limit
`claude-code-ide-codex-events-trust-timeout'.  MANUAL non-nil is the
trust command: an error signals a `user-error' and C-g quits.  Else
the result plist is returned, also for an error."
  (let* ((key (claude-code-ide-codex-events--trust-key))
         (bad (plist-get result :hooks))
         (untrusted (cl-remove-if #'claude-code-ide-codex-events--hook-disabled-p bad))
         (disabled (cl-remove-if-not #'claude-code-ide-codex-events--hook-disabled-p bad))
         (fail (lambda (text)
                 (if manual
                     (user-error "%s" text)
                   (list :status 'error :message text)))))
    (if (null untrusted)
        result
      (claude-code-ide-codex-events--show-hooks untrusted disabled)
      (let* ((yes (condition-case nil
                      (yes-or-no-p
                       (format "Codex runs status hooks only when trusted.  Trust these %d hook commands in %s? "
                               (length untrusted)
                               (abbreviate-file-name (claude-code-ide-transcript--codex-config-file))))
                    (quit 'quit))))
        (cond
         ((eq yes 'quit)
          (if manual (signal 'quit nil) result))
         ((not yes)
          (cl-pushnew key claude-code-ide-codex-events--declined :test #'equal)
          (message "Codex status hooks not trusted: M-x claude-code-ide-codex-trust-hooks trusts them later")
          result)
         (t
          (claude-code-ide-codex-events--install-script)
          (let* ((own (not (and server (process-live-p
                                        (claude-code-ide-codex-events--server-process server)))))
                 (server (if own
                             (claude-code-ide-codex-events--server-start
                              (claude-code-ide-codex-events--hook-args) directory)
                           server)))
            (unwind-protect
                (let ((write (claude-code-ide-codex-events--server-call
                              server "config/batchWrite"
                              `((edits . ,(claude-code-ide-codex-events--trust-edits untrusted)))
                              claude-code-ide-codex-events-trust-timeout)))
                  (if (plist-get write :error)
                      (funcall fail (format "Codex did not write the trust (%s): run /hooks in a Codex terminal and trust the claude-code-ide hooks"
                                            (plist-get write :error)))
                    (let ((check (claude-code-ide-codex-events--trust-result
                                  (claude-code-ide-codex-events--server-call
                                   server "hooks/list" (claude-code-ide-codex-events--list-params directory)
                                   claude-code-ide-codex-events-trust-timeout))))
                      (setq claude-code-ide-codex-events--declined
                            (delete key claude-code-ide-codex-events--declined))
                      (claude-code-ide-codex-events--remember-trust key check)
                      (claude-code-ide-codex-events--set-trust key check)
                      (message "%s" (if (eq (plist-get check :status) 'trusted)
                                        (format "Trusted %d Codex status hooks" (length untrusted))
                                      (plist-get check :message)))
                      check)))
              (when own
                (claude-code-ide-codex-events--server-stop server))))))))))

(defun claude-code-ide-codex-events--ask-trust (directory &optional manual)
  "List the hooks in DIRECTORY, and offer their trust when they are not trusted.
This is the interactive flow without a launch: one check, at most one
question.  MANUAL is as for `claude-code-ide-codex-events--offer-trust'.
Return the trust result."
  (claude-code-ide-codex-events--install-script)
  (let* ((key (claude-code-ide-codex-events--trust-key))
         (dir (and directory (file-directory-p directory) directory))
         (server (claude-code-ide-codex-events--server-start
                  (claude-code-ide-codex-events--hook-args) dir)))
    (unwind-protect
        (let ((result (claude-code-ide-codex-events--trust-result
                       (claude-code-ide-codex-events--server-call
                        server "hooks/list" (claude-code-ide-codex-events--list-params dir)
                        claude-code-ide-codex-events-trust-timeout))))
          (claude-code-ide-codex-events--remember-trust key result)
          (pcase (plist-get result :status)
            ('untrusted
             (if (and (not manual) (member key claude-code-ide-codex-events--declined))
                 result
               (claude-code-ide-codex-events--offer-trust result dir server manual)))
            ((and status (guard manual))
             (pcase status
               ('error (user-error "%s" (plist-get result :message)))
               ('disabled
                (user-error "%d Codex status hooks are disabled; enable them with /hooks in a Codex terminal"
                            (length (plist-get result :hooks))))
               (_ (claude-code-ide-codex-events--set-trust key result)
                  (message "All %d Codex status hooks are trusted"
                           (length claude-code-ide-codex-events--events))
                  result)))
            (_ result)))
      (claude-code-ide-codex-events--server-stop server))))

(defun claude-code-ide-codex-prepare-trust (&optional directory)
  "Settle the trust of the Codex status hooks one time for a group of starts.
A restore that the user started calls it once before its starts, when
it starts at least one Codex instance.  It checks the trust in
DIRECTORY (default: home) and, when the hooks are not trusted and the
user did not decline them in this Emacs, asks one time.  Return
non-nil when the hooks are trusted: the restore then passes that value
as the `interactive' slot of each start spec, so that its starts check
again when needed but never ask again.  A nil value gives starts that
never ask.  A key that the user declined in this Emacs gives nil at
once, with no app-server."
  (let ((key (claude-code-ide-codex-events--trust-key)))
    (cond
     ((member key claude-code-ide-codex-events--declined) nil)
     ((eq (claude-code-ide-codex-events--result-status
           (claude-code-ide-codex-events--cached-trust key))
          'trusted))
     (t
      (condition-case err
          (eq (claude-code-ide-codex-events--result-status
               (claude-code-ide-codex-events--ask-trust directory))
              'trusted)
        (error
         (message "Codex hook trust unknown: %s" (error-message-string err))
         nil))))))

;;;###autoload
(defun claude-code-ide-codex-trust-hooks ()
  "Show the Codex status hooks of this package and trust them after a confirmation.
Codex runs a hook only after the user trusts it.  An interactive Codex
start offers the trust by itself; this command trusts the hooks later,
also after a no.  It lists the hooks with the Codex app-server, shows
the commands that Codex does not run yet, and after `yes-or-no-p'
writes their trust to the Codex config file through the app-server, as
/hooks in a Codex terminal does.  A hook that /hooks disabled stays
disabled.  The instances that run already get status only after a
restart."
  (interactive)
  (claude-code-ide-codex-events--ask-trust nil t)
  nil)

;;; Timers

(defun claude-code-ide-codex-events--prune ()
  "Forget the launches whose instance no longer runs this launch."
  (let ((gone nil))
    (maphash (lambda (id launch)
               (let ((instance (claude-code-ide-instance-by-id id)))
                 (unless (and instance
                              (= (claude-code-ide-instance-generation instance)
                                 (claude-code-ide-codex-events--launch-generation launch)))
                   (push (cons id launch) gone))))
             claude-code-ide-codex-events--launches)
    (dolist (entry gone)
      (remhash (car entry) claude-code-ide-codex-events--launches)
      (claude-code-ide-codex-events--remove-launch-files
       (car entry) (claude-code-ide-codex-events--launch-generation (cdr entry))))
    gone))

(defun claude-code-ide-codex-events--tick ()
  "Read events and screens, forget ended launches and update the status."
  (claude-code-ide-codex-events--drain)
  (let ((now (float-time))
        (changed (claude-code-ide-codex-events--prune)))
    (maphash (lambda (id launch)
               (let ((instance (claude-code-ide-instance-by-id id)))
                 (when (and instance
                            (ignore-errors
                              (claude-code-ide-codex-events--read-screen launch instance now)))
                   (setq changed t))))
             claude-code-ide-codex-events--launches)
    (if (zerop (hash-table-count claude-code-ide-codex-events--launches))
        (claude-code-ide-codex-events--stop-timers)
      ;; Ages and guesses change with time alone
      (setq changed t))
    (when changed
      (claude-code-ide-session-status--refresh))))

(defun claude-code-ide-codex-events--ensure-timers ()
  "Start the tick timer, the file watch and the status snapshot."
  (claude-code-ide-session-status--ensure-snapshot-timer)
  (unless (timerp claude-code-ide-codex-events--tick-timer)
    (setq claude-code-ide-codex-events--tick-timer
          (run-with-timer 2 2 #'claude-code-ide-codex-events--tick)))
  (unless claude-code-ide-codex-events--watch
    (ignore-errors
      (setq claude-code-ide-codex-events--watch
            (file-notify-add-watch (claude-code-ide-codex-events--events-directory) '(change)
                                   (lambda (_event)
                                     (claude-code-ide-codex-events--schedule-drain)))))))

(defun claude-code-ide-codex-events--stop-timers ()
  "Stop the timers and the file watch."
  (dolist (var '(claude-code-ide-codex-events--tick-timer
                 claude-code-ide-codex-events--drain-timer))
    (when (timerp (symbol-value var))
      (cancel-timer (symbol-value var)))
    (set var nil))
  (when claude-code-ide-codex-events--watch
    (ignore-errors (file-notify-rm-watch claude-code-ide-codex-events--watch))
    (setq claude-code-ide-codex-events--watch nil)))

(provide 'claude-code-ide-codex-events)

;;; claude-code-ide-codex-events.el ends here
