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

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'filenotify)
(require 'claude-code-ide)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-session-status)

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
  tries=0
  until mkdir \"$lock\"; do
    tries=$((tries + 1))
    # Break only the lock of a holder that died; Emacs removes old locks
    if [ \"$tries\" -eq 50 ]; then
      holder=$(cat \"$lock/pid\")
      if [ -n \"$holder\" ] && ! kill -0 \"$holder\"; then rm -rf \"$lock\"; fi
    fi
    if [ \"$tries\" -gt 400 ]; then rm -f \"$tmp\"; exit 0; fi
    sleep 0.01
  done
  echo $$ > \"$lock/pid\"
  seq=$(cat \"$dir/.$launch.seq\")
  case $seq in ''|*[!0-9]*) seq=0 ;; esac
  seq=$((seq + 1))
  echo \"$seq\" > \"$dir/.$launch.seq.tmp\" && mv -f \"$dir/.$launch.seq.tmp\" \"$dir/.$launch.seq\"
  mv \"$tmp\" \"$dir/$launch.$(printf %08d \"$seq\").$event.json\" || rm -f \"$tmp\"
  rm -rf \"$lock\"
)
exit 0
"
  "Script that each Codex status hook runs.")

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
  (failure nil :documentation "`error' or `quota-limit' in the `failed' phase.")
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
  (hooks t :documentation "Non-nil when the launch got the hook arguments.
A launch whose hooks are not trusted gets none, so that Codex shows no
\"Hooks need review\" dialog."))

(defvar claude-code-ide-codex-events--launches (make-hash-table :test 'equal)
  "The launch record of each Codex instance, by instance ID.
Only the current launch of an instance has a record.")

(defvar claude-code-ide-codex-events--tick-timer nil
  "Timer that reads events and the screens of Codex instances.")

(defvar claude-code-ide-codex-events--drain-timer nil
  "Timer that reads the event files soon.")

(defvar claude-code-ide-codex-events--watch nil
  "File notification descriptor of the Codex events folder.")

(defvar claude-code-ide-codex-events--trust-cache nil
  "(KEY . RESULT) of the last hook trust check.
KEY is the hash of the hook definitions; see
`claude-code-ide-codex-events--trust-key'.  RESULT is a plist with
:status, :message and :config-time, the time of the Codex config file
at the check.  A trusted result holds for all later starts.  An
untrusted one holds only while the config file keeps that time.")

(defvar claude-code-ide-codex-events--declined nil
  "Keys of hook definitions whose trust the user declined in this Emacs.
An interactive start does not ask again for them;
`claude-code-ide-codex-trust-hooks' still trusts them.")

(defconst claude-code-ide-codex-events--background-limit 30
  "Seconds after which a trust check that goes on in the background ends.")

(defvar claude-code-ide-codex-events--trust-check nil
  "The app-server of the running trust check, or nil.")

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
              claude-code-ide-codex-events--script)))

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
       file claude-code-ide-codex-events--script #o700))
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
                         (format "hooks.%s=[{hooks=[{type=\"command\",command=%s,timeout=5}]}]"
                                 event
                                 (json-encode-string (claude-code-ide-codex-events--command event)))))
                 claude-code-ide-codex-events--events)))

(defun claude-code-ide-codex-events--remove-launch-files (instance-id generation)
  "Delete the event, counter and lock files of the launch INSTANCE-ID GENERATION."
  (claude-code-ide-session-status--delete-matching-files
   (claude-code-ide-codex-events--events-directory)
   (concat "\\`\\.?" (regexp-quote (format "%s.%d." instance-id generation)))))

(defun claude-code-ide-codex-events--remove-stale-locks ()
  "Delete counter locks older than three seconds.
See `claude-code-ide-session-status--remove-old-locks'."
  (claude-code-ide-session-status--remove-old-locks
   (claude-code-ide-codex-events--events-directory) "\\`\\..+\\.lock\\'"))

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

(defun claude-code-ide-codex-events--track (instance)
  "Start to track the current launch of INSTANCE and return its record.
A record of an earlier launch of the same instance is replaced, and its
files are deleted.  The hook trust is settled here, before the start:
see `claude-code-ide-codex-events--settle-trust'."
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
        (claude-code-ide-codex-events--settle-trust launch instance)
        launch)))

(defun claude-code-ide-codex-events--track-safely (instance)
  "Track INSTANCE and return non-nil, or show the error and return nil.
A failure here must not stop the launch; the instance then has no
status events."
  (when (and claude-code-ide-session-status-tracking
             (claude-code-ide-instance-p instance)
             (stringp (claude-code-ide-instance-id instance)))
    (condition-case err
        (claude-code-ide-codex-events--track instance)
      (error
       (message "Codex status hooks are off for this launch: %s" (error-message-string err))
       nil))))

(defun claude-code-ide-codex-status-hook-args (instance)
  "Return the command-line arguments of the Codex status hooks of INSTANCE.
The list holds one \"-c\" and one \"hooks.<Event>=[...]\" string for
each event of `claude-code-ide-codex-events--events', always in the same
order: Codex keeps the trust of a hook under a key that has its
position.  The commands are the same for each instance; the identity
comes from `claude-code-ide-codex-status-hook-env'.  The call starts to
track the launch and settles the trust (it can ask the user when the
start is interactive).  Return nil when status tracking is off, the
hook script cannot be installed, or the hooks are not trusted."
  (let ((launch (claude-code-ide-codex-events--track-safely instance)))
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
See `claude-code-ide-session-status-quota-regexp'."
  (claude-code-ide-session-status--quota-text-p error))

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
                (text (if (stringp error) error "model request failed"))
                (quota (claude-code-ide-codex-events--quota-error-p error)))
           (claude-code-ide-codex-events--forget-agent launch nil)
           (claude-code-ide-codex-events--set-phase
            launch 'failed
            (claude-code-ide-session-status--one-line
             (format "%s: %s" (if quota "Quota limit" "Error") text))
            now)
           (setf (claude-code-ide-codex-events--launch-failure launch)
                 (if quota 'quota-limit 'error))))
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
  "Return the text of a trust problem of LAUNCH, or nil."
  (and (memq (claude-code-ide-codex-events--launch-trust launch) '(untrusted error))
       (claude-code-ide-codex-events--launch-trust-detail launch)))

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
      (list 'failed (or (claude-code-ide-codex-events--launch-failure launch) 'error)
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
       ;; Untrusted hooks never report; an unknown trust may still work
       ((eq (claude-code-ide-codex-events--launch-trust launch) 'untrusted)
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

(defun claude-code-ide-codex-events--detail (launch now)
  "Return the detail text of LAUNCH at NOW, with a trust problem."
  (let ((detail (nth 4 (claude-code-ide-codex-events--state launch now)))
        (problem (claude-code-ide-codex-events--trust-problem launch)))
    (if (and problem (not (equal detail problem)))
        (concat detail " · " problem)
      detail)))

(defun claude-code-ide-codex-events--instance-state (instance now)
  "Return the common state of the Codex INSTANCE at NOW, or nil.
A Codex instance whose launch has no status hooks is
`disconnected/untracked'.  This is a function of
`claude-code-ide-instance-state-functions'."
  (when (eq (claude-code-ide-instance-provider instance) 'codex)
    (if-let* ((launch (claude-code-ide-codex-events--launch-of instance)))
        (pcase-let ((`(,state ,reason ,since ,guess ,_detail)
                     (claude-code-ide-codex-events--state launch now)))
          (claude-code-ide-instance-make-state state reason since guess))
      (claude-code-ide-instance-make-state 'disconnected 'untracked))))

(defun claude-code-ide-codex-events--instance-detail (instance now)
  "Return the detail text of the Codex INSTANCE at NOW, or nil.
This is a function of `claude-code-ide-session-status-detail-functions'."
  (when (eq (claude-code-ide-instance-provider instance) 'codex)
    (if-let* ((launch (claude-code-ide-codex-events--launch-of instance)))
        (claude-code-ide-codex-events--detail launch now)
      "No status hooks")))

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
  "End SERVER."
  (let ((process (claude-code-ide-codex-events--server-process server)))
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

(defun claude-code-ide-codex-events--trust-result (answer)
  "Return the trust result of the `hooks/list' ANSWER.
The result is a plist: :status is `trusted', `untrusted' or `error';
:hooks holds the hooks of this package that Codex does not run;
:message explains it."
  (if-let* ((error (plist-get answer :error)))
      (list :status 'error :message (format "Hook trust unknown: %s" error))
    (let* ((hooks (claude-code-ide-codex-events--our-hooks (plist-get answer :result)))
           (bad (cl-remove-if #'claude-code-ide-codex-events--hook-trusted-p hooks))
           (expected (length claude-code-ide-codex-events--events)))
      (cond
       (bad
        (list :status 'untrusted :hooks bad
              :message (format "%d of %d Codex status hooks not trusted: M-x claude-code-ide-codex-trust-hooks"
                               (length bad) expected)))
       ((< (length hooks) expected)
        (list :status 'error
              :message (format "Codex lists %d of %d status hooks" (length hooks) expected)))
       (t (list :status 'trusted :message nil))))))

(defun claude-code-ide-codex-events--config-file ()
  "Return the Codex config file, where Codex keeps the hook trust."
  (expand-file-name "config.toml" (or (getenv "CODEX_HOME") "~/.codex")))

(defun claude-code-ide-codex-events--config-time ()
  "Return the modification time of the Codex config file, or nil."
  (file-attribute-modification-time
   (file-attributes (claude-code-ide-codex-events--config-file))))

(defun claude-code-ide-codex-events--trust-key ()
  "Return the key of the trust cache: a hash of the hook definitions.
A new package version with other definitions, or another script path,
gives another key, so its first interactive start asks again."
  (secure-hash 'sha256 (mapconcat #'identity (claude-code-ide-codex-events--hook-args) "\n")))

(defun claude-code-ide-codex-events--remember-trust (result)
  "Keep the trust RESULT of the current hook definitions in the cache.
A result that is neither trusted nor untrusted is not kept."
  (when (memq (plist-get result :status) '(trusted untrusted))
    (setq claude-code-ide-codex-events--trust-cache
          (cons (claude-code-ide-codex-events--trust-key)
                (append (list :config-time (claude-code-ide-codex-events--config-time))
                        result)))))

(defun claude-code-ide-codex-events--cached-trust ()
  "Return the cached trust result of the current hook definitions, or nil.
A trusted result is always valid.  An untrusted result is valid while
the Codex config file has the time of the check: /hooks in a terminal
can trust the hooks."
  (let ((cached claude-code-ide-codex-events--trust-cache))
    (when (and cached (equal (car cached) (claude-code-ide-codex-events--trust-key)))
      (pcase (plist-get (cdr cached) :status)
        ('trusted (cdr cached))
        ('untrusted (and (equal (plist-get (cdr cached) :config-time)
                                (claude-code-ide-codex-events--config-time))
                         (cdr cached)))))))

(defconst claude-code-ide-codex-events--restart-detail
  "Hooks were not trusted at the launch: restart to get status"
  "Detail of a launch that started before its hooks were trusted.")

(defconst claude-code-ide-codex-events--ask-detail
  "Hooks not trusted; the next interactive start asks"
  "Detail of a launch without hooks that no user started.")

(defconst claude-code-ide-codex-events--declined-detail
  "Hooks not trusted; M-x claude-code-ide-codex-trust-hooks trusts them"
  "Detail of a launch without hooks after the user declined the trust.")

(defun claude-code-ide-codex-events--set-trust (result)
  "Note the trust RESULT in each launch record and update the status.
A launch that started while its hooks were not trusted keeps the
state `untrusted': Codex read the trust at its start, so only a new
launch gets status events.  Its detail says so."
  (maphash (lambda (_id launch)
             (let ((status (plist-get result :status)))
               (if (and (eq (claude-code-ide-codex-events--launch-trust launch) 'untrusted)
                        (eq status 'trusted))
                   (setf (claude-code-ide-codex-events--launch-trust-detail launch)
                         claude-code-ide-codex-events--restart-detail)
                 (unless (eq (claude-code-ide-codex-events--launch-trust launch) 'trusted)
                   (setf (claude-code-ide-codex-events--launch-trust launch) status
                         (claude-code-ide-codex-events--launch-trust-detail launch)
                         (plist-get result :message))))))
           claude-code-ide-codex-events--launches)
  (claude-code-ide-session-status--refresh))

(defun claude-code-ide-codex-events--list-params (&optional directory)
  "Return the `hooks/list' parameters for DIRECTORY (default: home)."
  `((cwds . ,(vector (or directory (expand-file-name "~"))))))

(defun claude-code-ide-codex-events--start-trust-check (directory)
  "Check the trust of the hook definitions with the Codex app-server.
DIRECTORY is the folder of the start, or nil.  Wait at most
`claude-code-ide-codex-events-trust-timeout' seconds, and return the
trust result: a plist with :status `trusted', `untrusted' or `error',
and :message.  Return `:pending' when the app-server did not answer in
time: the check goes on in the background for
`claude-code-ide-codex-events--background-limit' seconds, and its
result goes to the cache and to the launch records."
  (condition-case err
      (let* ((dir (and directory (file-directory-p directory) directory))
             (server (claude-code-ide-codex-events--server-start
                      (claude-code-ide-codex-events--hook-args) dir))
             (process (claude-code-ide-codex-events--server-process server))
             (result nil)
             (timer nil)
             (finish (lambda (outcome)
                       (unless result
                         (setq result outcome)
                         (when (eq claude-code-ide-codex-events--trust-check server)
                           (setq claude-code-ide-codex-events--trust-check nil))
                         (when (timerp timer) (cancel-timer timer))
                         (claude-code-ide-codex-events--server-stop server)
                         (claude-code-ide-codex-events--remember-trust outcome)
                         (claude-code-ide-codex-events--set-trust outcome))))
             (deadline (+ (float-time) claude-code-ide-codex-events-trust-timeout)))
        (setq claude-code-ide-codex-events--trust-check server)
        (setq timer (run-with-timer
                     claude-code-ide-codex-events--background-limit nil
                     (lambda ()
                       (funcall finish (list :status 'error
                                             :message "Hook trust unknown: the Codex app-server did not answer")))))
        (claude-code-ide-codex-events--server-request
         server "hooks/list" (claude-code-ide-codex-events--list-params dir)
         (lambda (answer error)
           (funcall finish (claude-code-ide-codex-events--trust-result
                            (if error
                                (list :error (or (alist-get 'message error) (format "%S" error)))
                              (list :result answer))))))
        (while (and (null result) (< (float-time) deadline))
          (accept-process-output process 0.05))
        (or result :pending))
    (error
     (setq claude-code-ide-codex-events--trust-check nil)
     (list :status 'error
           :message (format "Hook trust unknown: %s" (error-message-string err))))))

(defun claude-code-ide-codex-events--interactive-p ()
  "Return non-nil when a command that the user called starts the instance.
The start commands bind `claude-code-ide-interactive-start'.  A
registry restore, a coordinator launch or a timer does not."
  (bound-and-true-p claude-code-ide-interactive-start))

(defun claude-code-ide-codex-events--result-status (result)
  "Return the :status of the trust RESULT, or nil for `:pending' or nil."
  (and (listp result) (plist-get result :status)))

(defun claude-code-ide-codex-events--settle-trust (launch instance)
  "Settle the hook trust for LAUNCH of INSTANCE before its start.
A cached trusted result needs no app-server.  Else the app-server lists
the hooks, waiting at most `claude-code-ide-codex-events-trust-timeout'
seconds.
- Trusted: the launch gets its hooks.
- Not trusted, and a command of the user starts the instance: the
  start offers the trust with `claude-code-ide-codex-events--offer-trust',
  unless the user declined it in this Emacs.  After a yes the launch
  gets its trusted hooks; after a no the user is not asked again.
- Not trusted otherwise: no question, and no hooks.  The detail says
  that the next interactive start asks.
- No answer in time, or no app-server: the launch gets its hooks, as
  they can be trusted, and the detail says that the trust is unknown.
LAUNCH gets the result in its `trust', `trust-detail' and `hooks'."
  (let* ((key (claude-code-ide-codex-events--trust-key))
         (result (or (claude-code-ide-codex-events--cached-trust)
                     (progn
                       (setf (claude-code-ide-codex-events--launch-trust launch) 'checking)
                       (claude-code-ide-codex-events--start-trust-check
                        (claude-code-ide-known-or-nil
                         (claude-code-ide-instance-project-root instance)))))))
    (when (and (eq (claude-code-ide-codex-events--result-status result) 'untrusted)
               (claude-code-ide-codex-events--interactive-p)
               (not (member key claude-code-ide-codex-events--declined)))
      (setq result (claude-code-ide-codex-events--offer-trust)))
    (pcase (claude-code-ide-codex-events--result-status result)
      ('trusted
       (setf (claude-code-ide-codex-events--launch-trust launch) 'trusted
             (claude-code-ide-codex-events--launch-trust-detail launch) nil
             (claude-code-ide-codex-events--launch-hooks launch) t))
      ('untrusted
       (setf (claude-code-ide-codex-events--launch-trust launch) 'untrusted
             (claude-code-ide-codex-events--launch-trust-detail launch)
             (cond
              ((member key claude-code-ide-codex-events--declined)
               claude-code-ide-codex-events--declined-detail)
              ((claude-code-ide-codex-events--interactive-p) (plist-get result :message))
              (t claude-code-ide-codex-events--ask-detail))
             (claude-code-ide-codex-events--launch-hooks launch) nil))
      ('error
       (setf (claude-code-ide-codex-events--launch-trust launch) 'error
             (claude-code-ide-codex-events--launch-trust-detail launch) (plist-get result :message)
             (claude-code-ide-codex-events--launch-hooks launch) t))
      (_
       (setf (claude-code-ide-codex-events--launch-hooks launch) t)
       (when (eq result :pending)
         (setf (claude-code-ide-codex-events--launch-trust launch) 'error
               (claude-code-ide-codex-events--launch-trust-detail launch)
               (format "Hook trust unknown: no answer in %s s; the check goes on"
                       claude-code-ide-codex-events-trust-timeout)))))))

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
                       (if (eq (alist-get 'enabled hook) :false)
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

(defun claude-code-ide-codex-events--offer-trust (&optional manual)
  "List the status hooks, offer their trust to the user, and return the result.
The hooks that Codex does not run are shown in *Codex status hooks*.
After a yes of `yes-or-no-p', their trust goes to the Codex config
file through the app-server (`config/batchWrite'), as /hooks in a
Codex terminal writes it, and a second list checks it.  Never without
the yes.  A no puts the hook definitions in
`claude-code-ide-codex-events--declined', so that a start does not ask
again in this Emacs.  C-g is a no for this start only.

MANUAL non-nil is the trust command: an error or a refusal signals a
`user-error', and the messages say each result.  Without MANUAL, a
start calls it: the result plist (:status, :message) is returned, and
nothing is signaled."
  (claude-code-ide-codex-events--install-script)
  (let ((key (claude-code-ide-codex-events--trust-key))
        (server (claude-code-ide-codex-events--server-start
                 (claude-code-ide-codex-events--hook-args)))
        (fail (lambda (text)
                (if manual
                    (user-error "%s" text)
                  (list :status 'error :message text)))))
    (unwind-protect
        (let* ((answer (claude-code-ide-codex-events--server-call
                        server "hooks/list" (claude-code-ide-codex-events--list-params)))
               (result (claude-code-ide-codex-events--trust-result answer))
               (bad (plist-get result :hooks))
               (untrusted (cl-remove-if (lambda (hook) (eq (alist-get 'enabled hook) :false)) bad))
               (disabled (cl-remove-if-not (lambda (hook) (eq (alist-get 'enabled hook) :false)) bad)))
          (cond
           ((eq (plist-get result :status) 'error)
            (funcall fail (plist-get result :message)))
           ((null bad)
            (claude-code-ide-codex-events--remember-trust result)
            (claude-code-ide-codex-events--set-trust result)
            (when manual
              (message "All %d Codex status hooks are trusted"
                       (length claude-code-ide-codex-events--events)))
            result)
           ((null untrusted)
            (funcall fail (format "%d Codex status hooks are disabled; enable them with /hooks in a Codex terminal"
                                  (length disabled))))
           (t
            (claude-code-ide-codex-events--show-hooks untrusted disabled)
            (let ((yes (condition-case nil
                           (yes-or-no-p
                            (format "Codex runs status hooks only when trusted.  Trust these %d hook commands in %s? "
                                    (length untrusted)
                                    (abbreviate-file-name (claude-code-ide-codex-events--config-file))))
                         (quit 'quit))))
              (cond
               ((eq yes 'quit)
                (if manual (signal 'quit nil) result))
               ((not yes)
                (cl-pushnew key claude-code-ide-codex-events--declined :test #'equal)
                (message "Codex status hooks not trusted: M-x claude-code-ide-codex-trust-hooks trusts them later")
                result)
               (t
                (let ((write (claude-code-ide-codex-events--server-call
                              server "config/batchWrite"
                              `((edits . ,(claude-code-ide-codex-events--trust-edits untrusted))))))
                  (if (plist-get write :error)
                      (funcall fail (format "Codex did not write the trust (%s): run /hooks in a Codex terminal and trust the claude-code-ide hooks"
                                            (plist-get write :error)))
                    (let ((check (claude-code-ide-codex-events--trust-result
                                  (claude-code-ide-codex-events--server-call
                                   server "hooks/list" (claude-code-ide-codex-events--list-params)))))
                      (setq claude-code-ide-codex-events--declined
                            (delete key claude-code-ide-codex-events--declined))
                      (claude-code-ide-codex-events--remember-trust check)
                      (claude-code-ide-codex-events--set-trust check)
                      (message "%s" (if (eq (plist-get check :status) 'trusted)
                                        (format "Trusted %d Codex status hooks" (length untrusted))
                                      (plist-get check :message)))
                      check)))))))))
      (claude-code-ide-codex-events--server-stop server))))

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
  (claude-code-ide-codex-events--offer-trust t)
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
