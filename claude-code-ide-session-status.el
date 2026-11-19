;;; claude-code-ide-session-status.el --- Live status of Claude Code sessions  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Raymond Peck
;; Keywords: ai, claude, tools

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

;; Shows what each running Claude Code session does: working, waiting
;; for the user (a permission dialog, a question menu, a plan approval,
;; an MCP elicitation), idle (its turn ended), or failed.
;;
;; `claude-code-ide-session-registry-mode' passes CLI hooks to each
;; instance it starts.  Each hook calls a small shell script that writes
;; the hook input to a file in a directory of this Emacs process, with a
;; sequence number per launch.  Emacs reads the files in order, deletes
;; them, and updates the status of the session.
;;
;; Each launch has its own nonce, and its status record holds the
;; instance ID and the launch generation of that launch.  The drain makes
;; a common event of each file (see `claude-code-ide-make-event'), skips
;; the events of a launch older than the current generation of its
;; instance, and passes the others to `claude-code-ide-dispatch-event'.
;;
;; `claude-code-ide-session-status-mode' shows the sessions in the buffer
;; *Coding Agents Sessions*, which updates itself, the ones that wait for
;; the user first.  RET in that buffer, or
;; `claude-code-ide-visit-waiting-session' from anywhere, goes to the
;; session.  Instances of other providers, such as Codex, are in the same
;; buffer: their state comes from `claude-code-ide-instance-state' and
;; their detail from `claude-code-ide-session-status-detail-functions'.
;; Each row shows the provider, the model (or "unknown") and the common
;; state with its reason.
;;
;; The status snapshot, <report directory>/status/<emacs-pid>.json,
;; gives the same states to programs outside Emacs; docs/status-schema.md
;; describes it.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'filenotify)
(require 'tabulated-list)
(require 'claude-code-ide)
(require 'claude-code-ide-session-registry)

;;; Customization

(defcustom claude-code-ide-session-status-tracking t
  "When non-nil, the session registry passes status hooks to new instances.
The hooks report each step of the CLI to Emacs; each costs one short
shell process.  The value is read at each start, so a change applies
to the instances started afterwards."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-session-status-start-timeout 15
  "Seconds after which a session that sent no event is shown as unobserved.
Such a session may wait on a dialog that runs before hooks, such as the
dialog that asks whether to trust the folder."
  :type 'number
  :group 'claude-code-ide)

(defcustom claude-code-ide-session-status-quiet-time 5
  "Seconds without events after which a working session's transcript is read.
An interrupt with Esc fires no hook; the transcript shows it."
  :type 'number
  :group 'claude-code-ide)

(defcustom claude-code-ide-session-status-ask-regexps '("\\?\\'")
  "Regexps for a line of a reply that asks the user something.
A reply that ends a turn with such a line shows the session as
ASKS YOU.  Each line is matched without list markers and Markdown
markup around it, and lines in code blocks are skipped.  The default
matches a line that ends with a question mark."
  :type '(repeat regexp)
  :group 'claude-code-ide)

(defcustom claude-code-ide-session-status-agent-quiet-time 600
  "Seconds without activity after which a background subagent is quiet.
This applies to a subagent that runs no tool.  A quiet task changes the
state of its session from WAITS ON TASKS to TASKS QUIET, which asks
the user to look."
  :type 'number
  :group 'claude-code-ide)

(defcustom claude-code-ide-session-status-task-quiet-time 900
  "Seconds after which a background shell, or a subagent in one tool, is quiet.
A shell reports no activity, so its time counts from its start.  A
server left running in the background shows TASKS QUIET after this
time, which is true: the agent no longer waits on it."
  :type 'number
  :group 'claude-code-ide)

(defcustom claude-code-ide-session-status-display-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . top)
    (slot . 0)
    (window-height . fit-window-to-buffer)
    (preserve-size . (nil . t)))
  "Display action for the status buffer of `claude-code-ide-session-status-mode'."
  :type 'sexp
  :group 'claude-code-ide)

(defcustom claude-code-ide-session-status-indent 2
  "Number of spaces that the session lines are indented under their project line."
  :type 'integer
  :group 'claude-code-ide)

(defcustom claude-code-ide-session-status-max-height 20
  "Maximum height in lines of the status window."
  :type 'integer
  :group 'claude-code-ide)

(defface claude-code-ide-session-status-waiting
  '((t :inherit error :weight bold))
  "Face for a session that waits for an answer of the user."
  :group 'claude-code-ide)

(defface claude-code-ide-session-status-idle
  '((t :inherit warning))
  "Face for a session whose turn ended."
  :group 'claude-code-ide)

(defface claude-code-ide-session-status-working
  '((t :inherit success))
  "Face for a session that works."
  :group 'claude-code-ide)

(defface claude-code-ide-session-status-quiet
  '((t :inherit shadow))
  "Face for a session that is starting or not tracked."
  :group 'claude-code-ide)

;;; Data

(cl-defstruct (claude-code-ide-session-status--blocker
               (:constructor claude-code-ide-session-status--blocker-create)
               (:copier nil))
  "Something that stops a session until the user answers."
  (kind 'permission :type symbol
        :documentation "`permission', `elicitation' or `notification'.")
  (tool nil :documentation "(AGENT-ID . TOOL-USE-ID) of the tool, or nil.")
  (name nil :type (or null string)
        :documentation "Tool name of a permission dialog, or type of a notification.")
  (detail "" :type string)
  (since 0.0 :type float))

(cl-defstruct (claude-code-ide-session-status--task
               (:constructor claude-code-ide-session-status--task-create)
               (:copier nil))
  "A subagent or shell that runs in the background of the main agent."
  (id "" :type string)
  (type 'subagent :type symbol :documentation "`subagent' or `shell'.")
  (description "" :type string)
  (first-seen 0.0 :type float))

(cl-defstruct (claude-code-ide-session-status
               (:constructor claude-code-ide-session-status-create)
               (:copier nil))
  "What one session does, as its hooks reported it."
  (session nil :documentation "The `claude-code-ide-mcp-session'.")
  (key nil :type (or null string) :documentation "Registry key.")
  (nonce "" :type string :documentation "Id of this launch in event file names.")
  (instance-id nil :type (or null string)
               :documentation "Instance ID of the launch, or nil without a descriptor.")
  (generation 0 :type integer :documentation "Launch generation of the launch.")
  (phase 'starting :type symbol
         :documentation "`starting', `working', `idle' or `error'.")
  (failure nil :type symbol
           :documentation "Reason of the `error' phase: `error' or `quota-limit'.")
  (detail "" :type string)
  (since 0.0 :type float :documentation "Time the phase started.")
  (registered 0.0 :type float)
  (last-event 0.0 :type float)
  (inflight (make-hash-table :test 'equal)
            :documentation "(AGENT-ID . TOOL-USE-ID) -> (SEQ NAME INPUT).")
  (tool-seq 0 :type integer)
  (blockers nil :type list :documentation "Open blockers, oldest first.")
  (tasks (make-hash-table :test 'equal)
         :documentation "Task id -> `claude-code-ide-session-status--task'.
The background tasks of the main agent, as its last Stop listed them.")
  (agent-activity 0.0 :type float
                  :documentation "Time of the last event of any subagent.")
  (questions nil :type list
             :documentation "Questions that the reply which ended the turn asks the user.")
  (guessed nil :type boolean
           :documentation "Non-nil when the idle phase is a guess of the interrupt check.
A sign of work, such as a tool event, ends it.")
  (transcript-path nil :type (or null string))
  (transcript-offset nil :type (or null integer)))

(defconst claude-code-ide-session-status--events
  '("SessionStart" "UserPromptSubmit" "PreToolUse" "PermissionRequest"
    "PostToolUse" "PostToolUseFailure" "Notification" "Stop" "StopFailure"
    "SubagentStart" "SubagentStop" "Elicitation" "ElicitationResult")
  "CLI hook events that the status is computed from.")

(defconst claude-code-ide-session-status--waiting-notifications
  '("permission_prompt" "worker_permission_prompt" "agent_needs_input"
    "elicitation_dialog" "elicitation_url_dialog")
  "Notification types that mean the session waits for the user.")

(defconst claude-code-ide-session-status--interrupt-marker
  "[Request interrupted by user"
  "Text that the CLI writes to the transcript after an interrupt.")

(defcustom claude-code-ide-session-status-hook-time-limit 10
  "Seconds of real time that a status hook waits at most for its lock.
The status hooks of Claude Code and of Codex number the events of a
launch under a lock.  A hook that does not get the lock in this time
gives up: it drops its event, writes one line to hook-errors.log in the
events folder, and exits 0, so it never fails or holds up a tool call
of the CLI for longer.  Emacs writes the value into the hook scripts
when it installs them, so a change applies to the next start."
  :type 'natnum
  :group 'claude-code-ide)

(defconst claude-code-ide-session-status--hook-break-after 2
  "Seconds after which a waiting hook checks whether the lock holder died.
A hook breaks the lock of a holder whose process is gone; it checks
once a second from then on.")

(defun claude-code-ide-session-status--hook-limit ()
  "Return the time limit of the status hooks as a whole number of seconds."
  (max 1 (round claude-code-ide-session-status-hook-time-limit)))

(defun claude-code-ide-session-status--lock-loop ()
  "Return the shell text that waits for the lock $lock of a status hook.
The text runs in the subshell of a hook script, which sets $dir, $tmp,
$lock and $event.  It measures real time with `date +%s', so a slow
machine does not make the wait longer: after more than
`claude-code-ide-session-status-hook-time-limit' seconds it removes
$tmp, writes one line to $dir/hook-errors.log (at most 64 KiB), and
exits 0.  From `claude-code-ide-session-status--hook-break-after'
seconds on (earlier for a short limit), it breaks the lock of a holder
whose process is gone, once a second.  When `date' gives no number, a
count of the tries stands in for the seconds."
  (let* ((limit (claude-code-ide-session-status--hook-limit))
         (break (max 0 (min claude-code-ide-session-status--hook-break-after (1- limit)))))
    (format "  # Wait for the lock at most %d s of real time, however slow the
  # machine is.  Break the lock of a holder that died; Emacs removes old
  # locks too.
  limit=%d
  start=$(date +%%s)
  case $start in ''|*[!0-9]*) start=0 ;; esac
  tries=0
  checked=-1
  until mkdir \"$lock\"; do
    tries=$((tries + 1))
    now=$(date +%%s)
    case $now in ''|*[!0-9]*) now=$((start + tries / 100)) ;; esac
    waited=$((now - start))
    if [ \"$waited\" -ge %d ] && [ \"$waited\" -ne \"$checked\" ]; then
      checked=$waited
      holder=$(cat \"$lock/pid\")
      if [ -n \"$holder\" ] && ! kill -0 \"$holder\"; then rm -rf \"$lock\"; continue; fi
    fi
    if [ \"$waited\" -gt \"$limit\" ]; then
      rm -f \"$tmp\"
      log=\"$dir/hook-errors.log\"
      size=$(wc -c < \"$log\" | tr -d ' ')
      case $size in ''|*[!0-9]*) size=0 ;; esac
      if [ \"$size\" -lt 65536 ]; then
        echo \"$(date +%%Y-%%m-%%dT%%H:%%M:%%S) $event: no lock after $waited s ($lock); event dropped\" >> \"$log\"
      fi
      exit 0
    fi
    sleep 0.01
  done
" limit limit break)))

(defun claude-code-ide-session-status--fill-script (template)
  "Return the hook script TEMPLATE with its lock loop and time limit.
TEMPLATE has the mark @LOCK_LOOP@ where the loop of
`claude-code-ide-session-status--lock-loop' goes."
  (replace-regexp-in-string "^@LOCK_LOOP@\n" (claude-code-ide-session-status--lock-loop)
                            template t t))

(defconst claude-code-ide-session-status--script
  "#!/bin/sh
# claude-code-ide session status: stores the input of one Claude Code hook
# for Emacs.  Arguments: EVENTS-DIR NONCE EVENT.  It prints nothing and
# always exits 0, so it never changes what the CLI does.
exec 2>/dev/null >/dev/null
(
  dir=$1
  nonce=$2
  event=$3
  mkdir -p \"$dir\" || exit 0
  tmp=$(mktemp \"$dir/.$nonce.in.XXXXXX\") || exit 0
  cat > \"$tmp\" || { rm -f \"$tmp\"; exit 0; }
  # Number the events of this launch in the order they are published
  lock=\"$dir/.$nonce.lock\"
@LOCK_LOOP@
  echo $$ > \"$lock/pid\"
  seq=$(cat \"$dir/.$nonce.seq\")
  case $seq in ''|*[!0-9]*) seq=0 ;; esac
  seq=$((seq + 1))
  echo \"$seq\" > \"$dir/.$nonce.seq.tmp\" && mv -f \"$dir/.$nonce.seq.tmp\" \"$dir/.$nonce.seq\"
  mv \"$tmp\" \"$dir/$nonce-$(printf %08d \"$seq\")-$event.json\" || rm -f \"$tmp\"
  rm -rf \"$lock\"
)
cat >/dev/null
exit 0
"
  "Template of the script that each status hook runs.
`claude-code-ide-session-status--script-text' fills in the lock loop.")

(defun claude-code-ide-session-status--script-text ()
  "Return the status hook script, with the current time limit."
  (claude-code-ide-session-status--fill-script claude-code-ide-session-status--script))

;;; State

(defvar claude-code-ide-session-status--by-nonce (make-hash-table :test 'equal)
  "Status of each tracked launch, by nonce.")

(defvar claude-code-ide-session-status--by-session
  (make-hash-table :test 'eq :weakness 'key)
  "Status of each tracked session.")

(defvar claude-code-ide-session-status--watch nil
  "File notification descriptor of the events directory.")

(defvar claude-code-ide-session-status--drain-timer nil
  "Timer that reads the event files soon.")

(defvar claude-code-ide-session-status--tick-timer nil
  "Timer that reads events, checks quiet sessions and updates the buffer.")

(defconst claude-code-ide-session-status--buffer-name "*Coding Agents Sessions*"
  "Name of the status buffer.")

(defvar claude-code-ide-session-status--urgent-count 0
  "Number of sessions that need the user, as of the last refresh.")

(defvar claude-code-ide-session-status-mode)

;;; Files

(defun claude-code-ide-session-status--events-directory (&optional pid)
  "Return the events directory of the Emacs process PID (default: this one)."
  (file-name-as-directory
   (expand-file-name (format "events-%d" (or pid (emacs-pid)))
                     (claude-code-ide-session-registry--report-directory))))

(defun claude-code-ide-session-status--script-file ()
  "Return the file of the hook script."
  (expand-file-name "claude-code-ide-status-hook.sh"
                    (claude-code-ide-session-registry--report-directory)))

(defun claude-code-ide-session-status--write-file-atomically (file text &optional file-mode dir-mode)
  "Write TEXT to FILE through a temporary file in its folder and a rename.
A reader sees the old file or the new one, never a part.  FILE-MODE is
the mode of the new file, or nil for the default.  A folder that this
call creates gets DIR-MODE, or the default mode when DIR-MODE is nil.
The temporary file has a name that starts with a dot."
  (let ((dir (file-name-directory file)))
    (unless (file-directory-p dir)
      (make-directory dir t)
      (when dir-mode
        (set-file-modes dir dir-mode)))
    (let ((tmp (make-temp-file (expand-file-name (concat "." (file-name-nondirectory file) "-") dir))))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region text nil tmp nil 'silent))
            (when file-mode
              (set-file-modes tmp file-mode))
            (rename-file tmp file t))
        (when (file-exists-p tmp)
          (delete-file tmp))))))

(defun claude-code-ide-session-status--delete-matching-files (dir regexp)
  "Delete the files and folders in DIR whose name matches REGEXP."
  (when (file-directory-p dir)
    (dolist (file (directory-files dir t regexp t))
      (ignore-errors
        (if (file-directory-p file)
            (delete-directory file t)
          (delete-file file))))))

(defun claude-code-ide-session-status--remove-old-locks (dir regexp &optional age)
  "Delete the lock folders in DIR whose name matches REGEXP, older than AGE.
AGE is in seconds and defaults to 3.  A hook holds its lock for
milliseconds; an older lock was left by a hook that the CLI killed,
and would stop the numbering of its launch."
  (when (file-directory-p dir)
    (dolist (lock (directory-files dir t regexp t))
      (when-let* ((attributes (file-attributes lock)))
        (when (> (float-time (time-subtract nil (file-attribute-modification-time attributes)))
                 (or age 3))
          (ignore-errors (delete-directory lock t)))))))

(defun claude-code-ide-session-status--parse-json (text &optional false-object)
  "Parse the JSON TEXT into alists with symbol keys and lists.
null is nil, and false is FALSE-OBJECT (default nil).  Emacs without
native JSON uses json.el.  An invalid TEXT signals an error."
  (if (and (fboundp 'json-available-p) (json-available-p))
      (json-parse-string text :object-type 'alist :array-type 'list
                         :null-object nil :false-object false-object)
    (let ((json-object-type 'alist)
          (json-array-type 'list)
          (json-key-type 'symbol)
          (json-false false-object)
          (json-null nil))
      (json-read-from-string text))))

(defun claude-code-ide-session-status--read-json-file (file)
  "Return the JSON in FILE as an alist, or nil when it cannot be read."
  (condition-case nil
      (claude-code-ide-session-status--parse-json
       (claude-code-ide-session-registry--file-string file))
    (error nil)))

(defun claude-code-ide-session-status--install-script ()
  "Write the hook script when it is missing or differs.
Several Emacs processes can share it, so it is written to a temporary
file and renamed."
  (let ((file (claude-code-ide-session-status--script-file)))
    (unless (and (file-exists-p file)
                 (equal (claude-code-ide-session-registry--file-string file)
                        (claude-code-ide-session-status--script-text)))
      (claude-code-ide-session-status--write-file-atomically
       file (claude-code-ide-session-status--script-text)))))

(defun claude-code-ide-session-status--command (nonce event)
  "Return the hook command that records EVENT for the launch NONCE."
  (mapconcat #'shell-quote-argument
             (list "sh" (claude-code-ide-session-status--script-file)
                   (claude-code-ide-session-status--events-directory) nonce event)
             " "))

(defun claude-code-ide-session-status--remove-launch-files (nonce)
  "Delete the event, counter and lock files of the launch NONCE."
  (claude-code-ide-session-status--delete-matching-files
   (claude-code-ide-session-status--events-directory)
   (concat "\\`\\.?" (regexp-quote nonce) "[-.]")))

(defun claude-code-ide-session-status--sweep-dead-directories ()
  "Delete the events directories of Emacs processes that no longer run."
  (let ((dir (claude-code-ide-session-registry--report-directory)))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\`events-[0-9]+\\'"))
        (let ((pid (string-to-number (substring (file-name-nondirectory file) 7))))
          (unless (or (= pid (emacs-pid))
                      (let ((command (alist-get 'comm (process-attributes pid))))
                        (and command (string-match-p "emacs" (downcase command)))))
            (ignore-errors (delete-directory file t))))))))

(defun claude-code-ide-session-status--read-event (file)
  "Return the hook input in FILE as an alist, or nil when it cannot be read."
  (claude-code-ide-session-status--read-json-file file))

(defun claude-code-ide-session-status--remove-stale-locks ()
  "Delete counter locks older than three seconds.
See `claude-code-ide-session-status--remove-old-locks'."
  (claude-code-ide-session-status--remove-old-locks
   (claude-code-ide-session-status--events-directory) "\\`\\.[0-9a-f]+\\.lock\\'"))

;;; State machine

(defun claude-code-ide-session-status--one-line (text &optional width)
  "Return the first non-empty line of TEXT, cut to WIDTH (default 100)."
  (let* ((line (or (cl-find-if (lambda (line) (not (string-blank-p line)))
                               (split-string (or text "") "\n"))
                   ""))
         (line (string-trim line)))
    (truncate-string-to-width line (or width 100) nil nil "...")))

(defun claude-code-ide-session-status--tool-detail (name input)
  "Return a short description of the tool NAME with INPUT."
  (let ((value (lambda (field) (let ((v (alist-get field input))) (and (stringp v) v)))))
    (claude-code-ide-session-status--one-line
     (pcase name
       ("AskUserQuestion"
        (concat "Question: "
                (or (let ((question (car-safe (alist-get 'questions input))))
                      (and (consp question) (alist-get 'question question)))
                    "")))
       ("ExitPlanMode" "Plan approval")
       ("Bash" (concat "Bash: " (or (funcall value 'command) "")))
       ((or "Edit" "MultiEdit" "Write" "Read" "NotebookEdit")
        (format "%s %s" name (abbreviate-file-name (or (funcall value 'file_path) ""))))
       ("WebFetch" (format "WebFetch %s" (or (funcall value 'url) "")))
       (_ (format "Permission: %s" (or name "a tool")))))))

(defun claude-code-ide-session-status--set-phase (status phase detail now)
  "Set the PHASE and DETAIL of STATUS; a new PHASE starts at NOW."
  (unless (eq (claude-code-ide-session-status-phase status) phase)
    (setf (claude-code-ide-session-status-since status) now))
  (setf (claude-code-ide-session-status-phase status) phase
        (claude-code-ide-session-status-detail status) detail
        (claude-code-ide-session-status-guessed status) nil
        (claude-code-ide-session-status-questions status) nil))

(defun claude-code-ide-session-status--questions (text)
  "Return the lines of the reply TEXT that ask the user something, in order.
A line counts when one of `claude-code-ide-session-status-ask-regexps'
matches it, without list markers and Markdown markup around it.  Lines
in code blocks do not count."
  (let ((in-code nil)
        (questions '()))
    (dolist (line (split-string (or text "") "\n"))
      (let ((trimmed (string-trim line)))
        (if (string-prefix-p "```" trimmed)
            (setq in-code (not in-code))
          (let ((bare (string-trim
                       (replace-regexp-in-string
                        "[*_`]+\\'" ""
                        (replace-regexp-in-string "\\`[-*>#[:digit:].) ]+" "" trimmed)))))
            (when (and (not in-code)
                       (not (string-empty-p bare))
                       (cl-some (lambda (regexp) (string-match-p regexp bare))
                                claude-code-ide-session-status-ask-regexps))
              (push bare questions))))))
    (nreverse questions)))

(defun claude-code-ide-session-status--end-main-turn (status)
  "Remove the blockers and tools in flight of STATUS's main agent.
Dialogs and tools of subagents can outlive the main turn."
  (claude-code-ide-session-status--remove-blockers
   status (lambda (blocker)
            (null (car-safe (claude-code-ide-session-status--blocker-tool blocker)))))
  (let ((inflight (claude-code-ide-session-status-inflight status)))
    (maphash (lambda (key _value)
               (unless (car key)
                 (remhash key inflight)))
             inflight)))

(defun claude-code-ide-session-status--add-blocker (status kind tool detail now &optional name)
  "Add a blocker of KIND for TOOL with DETAIL to STATUS at NOW.
NAME is the tool name of a permission dialog or the type of a
notification."
  (setf (claude-code-ide-session-status-blockers status)
        (append (claude-code-ide-session-status-blockers status)
                (list (claude-code-ide-session-status--blocker-create
                       :kind kind :tool tool :name name :detail detail :since now)))))

(defun claude-code-ide-session-status--remove-blockers (status predicate)
  "Remove the blockers of STATUS for which PREDICATE is non-nil."
  (setf (claude-code-ide-session-status-blockers status)
        (cl-remove-if predicate (claude-code-ide-session-status-blockers status))))

(defun claude-code-ide-session-status--tool-key (data)
  "Return the (AGENT-ID . TOOL-USE-ID) of the tool event DATA."
  (cons (alist-get 'agent_id data) (alist-get 'tool_use_id data)))

(defun claude-code-ide-session-status--match-tool (status data)
  "Return the key of the tool in flight that the permission request DATA is for.
The request has no tool use id, so the newest tool in flight of the same
agent with the same name and input that has no blocker yet is chosen."
  (let ((agent (alist-get 'agent_id data))
        (name (alist-get 'tool_name data))
        (input (alist-get 'tool_input data))
        (blocked (mapcar #'claude-code-ide-session-status--blocker-tool
                         (claude-code-ide-session-status-blockers status)))
        (best nil)
        (best-seq -1))
    (maphash (lambda (key value)
               (when (and (equal (car key) agent)
                          (equal (nth 1 value) name)
                          (equal (nth 2 value) input)
                          (not (member key blocked))
                          (> (car value) best-seq))
                 (setq best key best-seq (car value))))
             (claude-code-ide-session-status-inflight status))
    best))

(defun claude-code-ide-session-status--running-tasks (status)
  "Return the background tasks of STATUS's main agent, oldest first."
  (let ((tasks '()))
    (maphash (lambda (_id task) (push task tasks))
             (claude-code-ide-session-status-tasks status))
    (sort tasks (lambda (a b)
                  (< (claude-code-ide-session-status--task-first-seen a)
                     (claude-code-ide-session-status--task-first-seen b))))))

(defun claude-code-ide-session-status--forget-agent-work (status agent)
  "Remove the tools in flight and the blockers of the subagent AGENT of STATUS."
  (let ((inflight (claude-code-ide-session-status-inflight status)))
    (maphash (lambda (key _value)
               (when (equal (car key) agent)
                 (remhash key inflight)))
             inflight))
  (claude-code-ide-session-status--remove-blockers
   status (lambda (blocker)
            (equal (car-safe (claude-code-ide-session-status--blocker-tool blocker)) agent))))

(defun claude-code-ide-session-status--apply-snapshot (status items now)
  "Make ITEMS, the background_tasks of a Stop, the tasks of STATUS at NOW.
Tasks that stay keep their first time.  The list holds the main agent's
own tasks; a subagent's subagents are not in it, and need not be: the
main agent waits on the subagent that started them."
  (let ((old (claude-code-ide-session-status-tasks status))
        (new (make-hash-table :test 'equal)))
    (dolist (item items)
      (let ((id (and (consp item) (alist-get 'id item))))
        (when (and (stringp id) (equal (alist-get 'status item) "running"))
          (let ((known (gethash id old)))
            (puthash id (claude-code-ide-session-status--task-create
                         :id id
                         :type (if (equal (alist-get 'type item) "subagent") 'subagent 'shell)
                         :description (or (alist-get 'description item) (alist-get 'command item) "")
                         :first-seen (if known
                                         (claude-code-ide-session-status--task-first-seen known)
                                       now))
                     new)))))
    (setf (claude-code-ide-session-status-tasks status) new)))

(defcustom claude-code-ide-session-status-quota-regexp
  (concat "usage[_ ]?limit\\|plan[_ ]limit\\|quota"
          "\\|credits?[_ ]\\(?:depleted\\|exhausted\\)\\|out of credits\\|insufficient[_ ]credits"
          "\\|hit your limit\\|\\(?:5-hour\\|five-hour\\|weekly\\|daily\\|monthly\\) limit")
  "Regexp for an error text that reports the usage limit of the account.
It is matched without case.  It must not match a short rate limit,
such as \"Rate limit reached ... tokens per min\", which ends in
seconds.  A Claude Code rate limit or a failed Codex model request
whose text matches it is `failed/quota-limit'."
  :type 'regexp
  :group 'claude-code-ide)

(defun claude-code-ide-session-status--quota-text-p (text)
  "Return non-nil when TEXT reports the usage limit of the account."
  (and (stringp text)
       (let ((case-fold-search t))
         (string-match-p claude-code-ide-session-status-quota-regexp text))))

(defun claude-code-ide-session-status--quota-failure-p (data)
  "Return non-nil when the StopFailure input DATA reports a quota limit.
`billing_error' means that the account has no credits.  `rate_limit'
covers also short limits of a few seconds, so it counts only when
`error_details' or the last message says that a usage or plan limit
was reached; see `claude-code-ide-session-status-quota-regexp'."
  (pcase (alist-get 'error data)
    ("billing_error" t)
    ("rate_limit"
     (or (claude-code-ide-session-status--quota-text-p (alist-get 'error_details data))
         (claude-code-ide-session-status--quota-text-p (alist-get 'last_assistant_message data))))))

(defun claude-code-ide-session-status--failure-text (data)
  "Return the text that explains the StopFailure input DATA."
  (let ((value (lambda (field) (let ((v (alist-get field data)))
                                 (and (stringp v) (not (string-blank-p v)) v)))))
    (or (funcall value 'error_details)
        (funcall value 'last_assistant_message)
        (funcall value 'error)
        "API error")))

(defun claude-code-ide-session-status--apply (status event data &optional now)
  "Change STATUS for the hook EVENT with the input DATA, at time NOW.
A session waits for the user while it has blockers: a permission
dialog, a question menu, an elicitation or a waiting notification.
Each blocker ends only with its own answer, the end of its agent, the
user's next prompt (main agent only), the end of the main turn (main
agent only) or the idle notification.

The main agent's turn can end while subagents and background shells
run.  The tasks come only from the background_tasks of the main
agent's Stop: when a task ends, the CLI wakes the main agent, and its
next Stop lists the rest.  SubagentStop marks the end of a subagent's
turn, not of the subagent: a subagent that waits on its own subagents
ends many turns.  Events of subagents count as activity of the
background work; they never change the phase of the main agent and do
not count for the interrupt check.  A tool event of the main agent
turns an idle session into a working one: a turn that a queued prompt,
a cross-session message or a task notification started fires no
UserPromptSubmit, so the tool event is its first sign."
  (let* ((now (or now (float-time)))
         (phase (claude-code-ide-session-status-phase status))
         (guessed (claude-code-ide-session-status-guessed status))
         (agent (let ((id (alist-get 'agent_id data))) (and (stringp id) id)))
         (main (null agent))
         (subagent-event (let ((type (alist-get 'agent_type data)))
                           (and agent (stringp type) (not (string-empty-p type)))))
         (path (alist-get 'transcript_path data)))
    (when main
      (setf (claude-code-ide-session-status-last-event status) now))
    (when (stringp path)
      (setf (claude-code-ide-session-status-transcript-path status) path))
    ;; The CLI's own helper agents stop with an empty agent type
    (when (and agent (or subagent-event (not (equal event "SubagentStop"))))
      (setf (claude-code-ide-session-status-agent-activity status) now))
    (pcase event
      ("SessionStart"
       ;; Compaction happens inside a turn: the phase and the tasks stay
       (unless (equal (alist-get 'source data) "compact")
         (clrhash (claude-code-ide-session-status-inflight status))
         (clrhash (claude-code-ide-session-status-tasks status))
         (setf (claude-code-ide-session-status-blockers status) nil)
         (claude-code-ide-session-status--set-phase status 'idle "Ready" now)))
      ("UserPromptSubmit"
       ;; A wake by a finished task is no answer to a subagent's dialog
       (claude-code-ide-session-status--remove-blockers
        status (lambda (blocker)
                 (null (car-safe (claude-code-ide-session-status--blocker-tool blocker)))))
       (setf (claude-code-ide-session-status-transcript-offset status)
             (or (claude-code-ide-session-status--transcript-size status) 0))
       (claude-code-ide-session-status--set-phase status 'working "Working" now))
      ("PreToolUse"
       (let ((name (alist-get 'tool_name data)))
         (puthash (claude-code-ide-session-status--tool-key data)
                  (list (cl-incf (claude-code-ide-session-status-tool-seq status))
                        name (alist-get 'tool_input data))
                  (claude-code-ide-session-status-inflight status))
         (when main
           (claude-code-ide-session-status--set-phase
            status 'working (format "Working: %s" (or name "tool")) now))))
      ("PermissionRequest"
       (claude-code-ide-session-status--add-blocker
        status 'permission
        ;; An unmatched dialog still belongs to its agent
        (or (claude-code-ide-session-status--match-tool status data) (cons agent nil))
        (claude-code-ide-session-status--tool-detail (alist-get 'tool_name data)
                                                     (alist-get 'tool_input data))
        now
        (let ((name (alist-get 'tool_name data))) (and (stringp name) name))))
      ((or "PostToolUse" "PostToolUseFailure")
       (let ((key (claude-code-ide-session-status--tool-key data)))
         (remhash key (claude-code-ide-session-status-inflight status))
         (claude-code-ide-session-status--remove-blockers
          status (lambda (blocker)
                   (let ((tool (claude-code-ide-session-status--blocker-tool blocker)))
                     (or (equal tool key)
                         (and agent (equal tool (cons agent nil)))))))
         (when (and main (or guessed (eq phase 'starting)))
           (claude-code-ide-session-status--set-phase status 'working "Working" now))))
      ("Notification"
       (let ((type (alist-get 'notification_type data)))
         (cond
          ((member type claude-code-ide-session-status--waiting-notifications)
           (unless (claude-code-ide-session-status-blockers status)
             (claude-code-ide-session-status--add-blocker
              status 'notification nil
              (claude-code-ide-session-status--one-line
               (or (alist-get 'message data) "Waiting for you"))
              now type)))
          ((equal type "idle_prompt")
           ;; No dialog is open; an idle phase keeps the first line of the reply
           (setf (claude-code-ide-session-status-blockers status) nil)
           (if (eq phase 'idle)
               (setf (claude-code-ide-session-status-guessed status) nil)
             (claude-code-ide-session-status--set-phase
              status 'idle "Waiting for your input" now))))))
      ("Stop"
       (when (assq 'background_tasks data)
         (claude-code-ide-session-status--apply-snapshot
          status (alist-get 'background_tasks data) now))
       (claude-code-ide-session-status--end-main-turn status)
       (claude-code-ide-session-status--set-phase
        status 'idle
        (let ((text (claude-code-ide-session-status--one-line
                     (alist-get 'last_assistant_message data))))
          (if (string-empty-p text) "Turn ended" text))
        now)
       (setf (claude-code-ide-session-status-questions status)
             (claude-code-ide-session-status--questions
              (alist-get 'last_assistant_message data))))
      ("StopFailure"
       (when (assq 'background_tasks data)
         (claude-code-ide-session-status--apply-snapshot
          status (alist-get 'background_tasks data) now))
       (claude-code-ide-session-status--end-main-turn status)
       (let ((quota (claude-code-ide-session-status--quota-failure-p data)))
         (claude-code-ide-session-status--set-phase
          status 'error
          (claude-code-ide-session-status--one-line
           (cond
            (quota
             (format "Quota limit: %s" (claude-code-ide-session-status--failure-text data)))
            ((equal (alist-get 'error data) "rate_limit")
             (let ((details (alist-get 'error_details data)))
               (if (and (stringp details) (not (string-blank-p details)))
                   (format "Error: rate limit: %s" details)
                 "Error: rate limit")))
            (t
             (format "Error: %s" (or (alist-get 'error data) (alist-get 'message data) "API error")))))
          now)
         (setf (claude-code-ide-session-status-failure status)
               (if quota 'quota-limit 'error))))
      ("SubagentStop"
       ;; The end of the subagent's turn ends its tools and its dialogs
       (when subagent-event
         (claude-code-ide-session-status--forget-agent-work status agent)))
      ("Elicitation"
       (claude-code-ide-session-status--add-blocker
        status 'elicitation nil
        (claude-code-ide-session-status--one-line
         (format "Input for %s: %s"
                 (or (alist-get 'mcp_server_name data) (alist-get 'mcp_server data) "MCP")
                 (or (alist-get 'message data) "")))
        now))
      ("ElicitationResult"
       (claude-code-ide-session-status--remove-blockers
        status (lambda (blocker)
                 (eq (claude-code-ide-session-status--blocker-kind blocker) 'elicitation)))))))

;;; Interrupts

(defun claude-code-ide-session-status--transcript-size (status)
  "Return the size of STATUS's transcript, or nil."
  (when-let* ((path (claude-code-ide-session-status-transcript-path status)))
    (file-attribute-size (file-attributes path))))

(defun claude-code-ide-session-status--transcript-news (status)
  "Return the text added to STATUS's transcript since the last read, or nil.
At most the last megabyte is read."
  (when-let* ((path (claude-code-ide-session-status-transcript-path status))
              (size (claude-code-ide-session-status--transcript-size status)))
    (let ((offset (claude-code-ide-session-status-transcript-offset status)))
      (if (not (and offset (> size offset)))
          (progn
            (setf (claude-code-ide-session-status-transcript-offset status) size)
            nil)
        (prog1 (with-temp-buffer
                 (let ((coding-system-for-read 'utf-8))
                   (insert-file-contents path nil (max offset (- size 1048576)) size))
                 (buffer-string))
          (setf (claude-code-ide-session-status-transcript-offset status) size))))))

(defun claude-code-ide-session-status--interrupt-record-p (text)
  "Return non-nil when TEXT has the CLI's record of an interrupt.
That is a user message whose text starts with the interrupt marker.
The marker inside a tool result, for example a file that Claude read,
does not count."
  (cl-some
   (lambda (line)
     (when (string-search claude-code-ide-session-status--interrupt-marker line)
       (let* ((record (ignore-errors (claude-code-ide-session-registry--json-decode line)))
              (message (and (consp record) (alist-get 'message record)))
              (content (and (consp message) (alist-get 'content message))))
         (and (equal (alist-get 'type record) "user")
              (cl-some (lambda (text)
                         (and (stringp text)
                              (string-prefix-p claude-code-ide-session-status--interrupt-marker text)))
                       (if (stringp content)
                           (list content)
                         (mapcar (lambda (part)
                                   (and (consp part)
                                        (equal (alist-get 'type part) "text")
                                        (alist-get 'text part)))
                                 content)))))))
   (split-string text "\n" t)))

(defconst claude-code-ide-session-status--busy-regexp
  "^[[:space:]]*[^[:alnum:][:space:]][[:space:]]*[[:alpha:]]+…[[:space:]]*("
  "Regexp for the spinner line that the CLI shows while it works.
For example \"✢ Misting… (3s · ↓ 120 tokens)\" or
\"· Flambéing… (running PostToolUse hook · 1s)\".")

(defun claude-code-ide-session-status--terminal-busy-p (status)
  "Return non-nil when STATUS's terminal shows the CLI's spinner line.
The last 30 lines above the blank rows at the end are read.  When the
buffer is gone, the answer is nil, which shows the session as needing
attention."
  (let ((buffer (and (claude-code-ide-session-status-session status)
                     (claude-code-ide-mcp-session-buffer
                      (claude-code-ide-session-status-session status)))))
    (when (and buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-max))
          (skip-chars-backward " \t\r\n ")
          (forward-line -30)
          (re-search-forward claude-code-ide-session-status--busy-regexp nil t))))))

(defun claude-code-ide-session-status--prompt-record-p (text)
  "Return non-nil when TEXT has a user record that starts a turn.
That is a user message with text content: a typed or queued prompt, a
cross-session message (these are meta records) or a task notification.
Tool results, the interrupt record, local commands such as /rename
with their caveat, shell commands typed with ! and compaction
summaries start no turn and do not count."
  (cl-some
   (lambda (line)
     (let* ((record (ignore-errors (claude-code-ide-session-registry--json-decode line)))
            (message (and (consp record) (alist-get 'message record)))
            (content (and (consp message) (alist-get 'content message))))
       (and (equal (alist-get 'type record) "user")
            (not (alist-get 'isCompactSummary record))
            (cl-some (lambda (text)
                       (and (stringp text)
                            (not (string-empty-p text))
                            (not (string-prefix-p claude-code-ide-session-status--interrupt-marker text))
                            (not (string-prefix-p "<command-name>" text))
                            (not (string-prefix-p "<local-command" text))
                            (not (string-prefix-p "<bash-" text))))
                     (if (stringp content)
                         (list content)
                       (mapcar (lambda (part)
                                 (and (consp part)
                                      (equal (alist-get 'type part) "text")
                                      (alist-get 'text part)))
                               content))))))
   (split-string text "\n" t)))

(defun claude-code-ide-session-status--check-interrupt (status now)
  "Correct STATUS at NOW when it works or stopped although no hook said so.
An interrupt fires no hook.  When a working session is quiet for
`claude-code-ide-session-status-quiet-time' seconds, the CLI's interrupt
record in the new transcript text shows an interrupt during a tool.
An interrupt during an answer leaves no record, so a terminal without
the CLI's spinner line also counts.  Both checks err toward showing
the session as needing the user.  The result is a guess: when the
spinner shows again, or a tool event arrives, the session is working
again.  An idle session whose transcript gains a prompt record (a queued
prompt, a cross-session message, a task notification) is working too:
those turns fire no UserPromptSubmit.  Return non-nil when STATUS
changed."
  (let ((phase (claude-code-ide-session-status-phase status)))
    (cond
     ((and (eq phase 'idle)
           (claude-code-ide-session-status-guessed status))
      (when (claude-code-ide-session-status--terminal-busy-p status)
        (claude-code-ide-session-status--set-phase status 'working "Working" now)
        t))
     ;; A queued prompt, a cross-session message or a task notification
     ;; starts a turn without UserPromptSubmit; the transcript shows it
     ((and (eq phase 'idle)
           (null (claude-code-ide-session-status-blockers status)))
      (let ((news (claude-code-ide-session-status--transcript-news status)))
        (when (and news (claude-code-ide-session-status--prompt-record-p news))
          (claude-code-ide-session-status--set-phase status 'working "Working" now)
          t)))
     ((and (eq phase 'working)
           (null (claude-code-ide-session-status-blockers status))
           (> (- now (claude-code-ide-session-status-last-event status))
              claude-code-ide-session-status-quiet-time))
      (let* ((news (claude-code-ide-session-status--transcript-news status))
             (detail (cond
                      ((and news (claude-code-ide-session-status--interrupt-record-p news))
                       "Interrupted")
                      ((not (claude-code-ide-session-status--terminal-busy-p status))
                       "Interrupted?"))))
        (when detail
          (claude-code-ide-session-status--set-phase status 'idle detail now)
          (setf (claude-code-ide-session-status-guessed status) t)
          t))))))

;;; Reading events

(defun claude-code-ide-session-status--event-files ()
  "Return the event files of this Emacs, oldest first within each launch."
  (let ((dir (claude-code-ide-session-status--events-directory)))
    (when (file-directory-p dir)
      (sort (directory-files dir t "\\`[0-9a-f]+-[0-9]+-[A-Za-z]+\\.json\\'" t)
            #'string<))))

(defun claude-code-ide-session-status--drain ()
  "Apply and delete the waiting event files, at most 500 per call.
Files of launches that this Emacs does not track are deleted unread."
  (when (timerp claude-code-ide-session-status--drain-timer)
    (cancel-timer claude-code-ide-session-status--drain-timer))
  (setq claude-code-ide-session-status--drain-timer nil)
  (claude-code-ide-session-status--remove-stale-locks)
  (let ((files (claude-code-ide-session-status--event-files))
        (count 0)
        (changed nil))
    (while (and files (< count 500))
      (let* ((file (pop files))
             (name (file-name-nondirectory file)))
        (when (string-match "\\`\\([0-9a-f]+\\)-[0-9]+-\\([A-Za-z]+\\)\\.json\\'" name)
          (let ((status (gethash (match-string 1 name) claude-code-ide-session-status--by-nonce))
                (event (match-string 2 name)))
            (when status
              (when-let* ((data (claude-code-ide-session-status--read-event file))
                          (common (claude-code-ide-session-status--common-event status event data))
                          ((or (eq common 'none) (claude-code-ide-event-current-p common))))
                (condition-case err
                    (progn
                      (claude-code-ide-session-status--apply status event data)
                      (setq changed t))
                  (error
                   (message "Claude session status: %s event failed: %s"
                            event (error-message-string err))))
                (unless (eq common 'none)
                  (condition-case err
                      (claude-code-ide-dispatch-event common)
                    (error
                     (message "Claude session status: event function failed on %s: %s"
                              event (error-message-string err)))))))))
        (ignore-errors (delete-file file))
        (cl-incf count)))
    (when files
      (claude-code-ide-session-status--schedule-drain))
    (when changed
      (claude-code-ide-session-status--refresh))))

(defun claude-code-ide-session-status--common-event (status event data)
  "Return the common event of the hook EVENT with DATA, or `none'.
STATUS is the record of the launch that wrote the event; its instance
ID and generation go into the event.  The provider of the instance
maps EVENT.  A record without an instance ID gives `none': it has no
generation to check and no event to dispatch."
  (if-let* ((id (claude-code-ide-session-status-instance-id status)))
      (let* ((instance (claude-code-ide-instance-by-id id))
             (provider (if instance (claude-code-ide-instance-provider instance) 'claude))
             (common (and (claude-code-ide-get-provider provider)
                          (claude-code-ide-provider-call provider 'map-event event data))))
        (claude-code-ide-make-event
         id (claude-code-ide-session-status-generation status)
         (if (memq common claude-code-ide-event-names) common 'other)
         event data))
    'none))

(defun claude-code-ide-session-status--schedule-drain ()
  "Read the event files in a moment.
Later notifications do not move the time, so a stream of events is
still read at a steady rate."
  (unless (timerp claude-code-ide-session-status--drain-timer)
    (setq claude-code-ide-session-status--drain-timer
          (run-with-timer 0.1 nil #'claude-code-ide-session-status--drain))))

(defun claude-code-ide-session-status--on-file-change (_event)
  "Read the event files after a change in the events directory."
  (claude-code-ide-session-status--schedule-drain))

(defun claude-code-ide-session-status--tick ()
  "Read events, check quiet sessions for interrupts and update the buffer.
The reading also covers systems without file notification."
  (claude-code-ide-session-status--drain)
  (let ((now (float-time))
        (changed nil))
    (maphash (lambda (_nonce status)
               (when (ignore-errors (claude-code-ide-session-status--check-interrupt status now))
                 (setq changed t)))
             claude-code-ide-session-status--by-nonce)
    ;; Ages and the unobserved state change with time alone
    (when (or changed
              (> (hash-table-count claude-code-ide-session-status--by-nonce) 0)
              (get-buffer claude-code-ide-session-status--buffer-name))
      (claude-code-ide-session-status--refresh))))

(defun claude-code-ide-session-status--ensure-timers ()
  "Start the tick timer, the file watch and the snapshot timer."
  (claude-code-ide-session-status--ensure-snapshot-timer)
  (unless (timerp claude-code-ide-session-status--tick-timer)
    (setq claude-code-ide-session-status--tick-timer
          (run-with-timer 2 2 #'claude-code-ide-session-status--tick)))
  (unless claude-code-ide-session-status--watch
    (let ((dir (claude-code-ide-session-status--events-directory)))
      (ignore-errors
        (make-directory dir t)
        (setq claude-code-ide-session-status--watch
              (file-notify-add-watch dir '(change)
                                     #'claude-code-ide-session-status--on-file-change))))))

(defun claude-code-ide-session-status--stop-timers ()
  "Stop the timers and the file watch."
  (dolist (var '(claude-code-ide-session-status--tick-timer
                 claude-code-ide-session-status--drain-timer))
    (when (timerp (symbol-value var))
      (cancel-timer (symbol-value var)))
    (set var nil))
  (when claude-code-ide-session-status--watch
    (ignore-errors (file-notify-rm-watch claude-code-ide-session-status--watch))
    (setq claude-code-ide-session-status--watch nil)))

;;; Tracking

(defun claude-code-ide-session-status--hooks (session key)
  "Start to track SESSION, the registry entry KEY, and return its hooks.
Each hook of `claude-code-ide-session-status--events' runs the hook
script with a new nonce for this launch.  When
`claude-code-ide-session-status-tracking' is nil, return no hooks."
  (when claude-code-ide-session-status-tracking
    (let* ((nonce (substring (replace-regexp-in-string
                              "-" "" (claude-code-ide-session-registry--uuid))
                             0 12))
           (now (float-time))
           (instance (claude-code-ide-instance-of-session session))
           (status (claude-code-ide-session-status-create
                    :session session :key key :nonce nonce
                    :instance-id (and instance (claude-code-ide-instance-id instance))
                    :generation (if instance (claude-code-ide-instance-generation instance) 0)
                    :since now :registered now :last-event now)))
      (claude-code-ide-session-status--install-script)
      (puthash nonce status claude-code-ide-session-status--by-nonce)
      (puthash session status claude-code-ide-session-status--by-session)
      (claude-code-ide-session-status--ensure-timers)
      (mapcar (lambda (event)
                (list event (claude-code-ide-session-status--command nonce event)))
              claude-code-ide-session-status--events))))

(defun claude-code-ide-session-status--forget (session)
  "Stop tracking SESSION and delete the files of its launch."
  (when-let* ((status (gethash session claude-code-ide-session-status--by-session)))
    (remhash session claude-code-ide-session-status--by-session)
    (remhash (claude-code-ide-session-status-nonce status)
             claude-code-ide-session-status--by-nonce)
    (claude-code-ide-session-status--remove-launch-files
     (claude-code-ide-session-status-nonce status)))
  (when (and (zerop (hash-table-count claude-code-ide-session-status--by-nonce))
             (not claude-code-ide-session-status-mode))
    (claude-code-ide-session-status--stop-timers))
  (claude-code-ide-session-status--refresh))

(defun claude-code-ide-session-status--on-end (session _reason)
  "Stop tracking SESSION, which ended."
  (claude-code-ide-session-status--forget session))

(defun claude-code-ide-session-status--set-tracking (on)
  "Pass status hooks to new instances when ON is non-nil; stop otherwise.
The end hook stays installed, so that sessions tracked before are
still forgotten when they end."
  (add-hook 'claude-code-ide-session-end-functions
            #'claude-code-ide-session-status--on-end)
  (if on
      (progn
        (add-hook 'claude-code-ide-session-registry-hook-functions
                  #'claude-code-ide-session-status--hooks)
        (claude-code-ide-session-status--sweep-dead-directories))
    (remove-hook 'claude-code-ide-session-registry-hook-functions
                 #'claude-code-ide-session-status--hooks)))

;;; Status of a session

(defun claude-code-ide-session-status--task-quiet-since (status task)
  "Return the time from which TASK of STATUS counts as quiet.
A shell reports nothing, so its first time.  For a subagent, the last
event of any subagent, since the subagents of a subagent report under
their own ids."
  (if (eq (claude-code-ide-session-status--task-type task) 'subagent)
      (max (claude-code-ide-session-status-agent-activity status)
           (claude-code-ide-session-status--task-first-seen task))
    (claude-code-ide-session-status--task-first-seen task)))

(defun claude-code-ide-session-status--task-quiet-p (status task now)
  "Return non-nil when TASK of STATUS has been quiet too long at NOW.
Subagents are quiet after `claude-code-ide-session-status-agent-quiet-time'
seconds without an event of any subagent, or after
`claude-code-ide-session-status-task-quiet-time' while a subagent runs a
tool.  A shell is quiet `claude-code-ide-session-status-task-quiet-time'
seconds after its start."
  (let* ((in-tool (catch 'found
                    (maphash (lambda (key _value)
                               (when (car key)
                                 (throw 'found t)))
                             (claude-code-ide-session-status-inflight status))
                    nil))
         (limit (if (and (eq (claude-code-ide-session-status--task-type task) 'subagent)
                         (not in-tool))
                    claude-code-ide-session-status-agent-quiet-time
                  claude-code-ide-session-status-task-quiet-time)))
    (> (- now (claude-code-ide-session-status--task-quiet-since status task)) limit)))

(defun claude-code-ide-session-status--subagent-p (task)
  "Return non-nil when TASK is a subagent."
  (eq (claude-code-ide-session-status--task-type task) 'subagent))

(defun claude-code-ide-session-status--state (status now)
  "Return the state of STATUS at NOW.
`waiting' while it has blockers, `unobserved' when it sent no event
since it started, `quota' when the turn failed on a quota limit.
When the main turn ended: `asks' when its reply asks the user
questions, `tasks' while subagents run, `tasks-quiet' when they are
quiet too long, else `idle', also while background shells run.  Else
the phase.  A nil STATUS is `untracked'."
  (cond
   ((null status) 'untracked)
   ((claude-code-ide-session-status-blockers status) 'waiting)
   ((and (eq (claude-code-ide-session-status-phase status) 'starting)
         (> (- now (claude-code-ide-session-status-registered status))
            claude-code-ide-session-status-start-timeout))
    'unobserved)
   ((and (eq (claude-code-ide-session-status-phase status) 'error)
         (eq (claude-code-ide-session-status-failure status) 'quota-limit))
    'quota)
   ((eq (claude-code-ide-session-status-phase status) 'idle)
    (let ((running (claude-code-ide-session-status--running-tasks status)))
      (cond
       ;; A reply that asks questions waits for the user, whatever runs
       ((claude-code-ide-session-status-questions status) 'asks)
       ;; Background shells do not keep the agent from the user: tests,
       ;; watchers and servers run while the user answers.  The CLI also
       ;; reports idle input while shells run, but not while subagents do.
       ((not (cl-some #'claude-code-ide-session-status--subagent-p running)) 'idle)
       ((cl-some (lambda (task)
                   (and (claude-code-ide-session-status--subagent-p task)
                        (claude-code-ide-session-status--task-quiet-p status task now)))
                 running)
        'tasks-quiet)
       (t 'tasks))))
   (t (claude-code-ide-session-status-phase status))))

(defun claude-code-ide-session-status--tasks-summary (tasks)
  "Return a short count of TASKS, such as \"2 agents, 1 shell\"."
  (let ((agents (cl-count 'subagent tasks :key #'claude-code-ide-session-status--task-type))
        (shells (cl-count-if-not (lambda (task)
                                   (eq (claude-code-ide-session-status--task-type task) 'subagent))
                                 tasks)))
    (string-join
     (delq nil (list (and (> agents 0) (format "%d agent%s" agents (if (= agents 1) "" "s")))
                     (and (> shells 0) (format "%d shell%s" shells (if (= shells 1) "" "s")))))
     ", ")))

(defun claude-code-ide-session-status--detail (status state &optional now)
  "Return the detail of STATUS in STATE at NOW."
  (let ((now (or now (float-time))))
    (pcase state
      ('untracked "No status hooks: T restarts it with them")
      ('waiting (claude-code-ide-session-status--blocker-detail
                 (car (claude-code-ide-session-status-blockers status))))
      ('unobserved "No events since the start: check the terminal")
      ('starting "Starting")
      ('asks
       (let* ((questions (claude-code-ide-session-status-questions status))
              (running (claude-code-ide-session-status--running-tasks status)))
         (claude-code-ide-session-status--one-line
          (concat (if (cdr questions)
                      (format "Asks %d questions: " (length questions))
                    "Asks: ")
                  (car questions)
                  (if running
                      (format " · %s running"
                              (claude-code-ide-session-status--tasks-summary running))
                    ""))
          140)))
      ('tasks
       (let ((running (claude-code-ide-session-status--running-tasks status)))
         (claude-code-ide-session-status--one-line
          (format "%s: %s" (claude-code-ide-session-status--tasks-summary running)
                  (claude-code-ide-session-status--task-description (car running))))))
      ('tasks-quiet
       (let ((quiet (cl-find-if (lambda (task)
                                  (and (claude-code-ide-session-status--subagent-p task)
                                       (claude-code-ide-session-status--task-quiet-p status task now)))
                                (claude-code-ide-session-status--running-tasks status))))
         (claude-code-ide-session-status--one-line
          (format "No activity for %s: %s"
                  (claude-code-ide-session-status--age
                   (claude-code-ide-session-status--task-quiet-since status quiet) now)
                  (claude-code-ide-session-status--task-description quiet)))))
      ('idle
       (let ((running (claude-code-ide-session-status--running-tasks status)))
         (if running
             (claude-code-ide-session-status--one-line
              (format "%s · %s running" (claude-code-ide-session-status-detail status)
                      (claude-code-ide-session-status--tasks-summary running))
              140)
           (claude-code-ide-session-status-detail status))))
      (_ (claude-code-ide-session-status-detail status)))))

(defun claude-code-ide-session-status--state-since (status state)
  "Return the time STATUS entered STATE, or nil."
  (pcase state
    ('untracked nil)
    ('waiting (claude-code-ide-session-status--blocker-since
               (car (claude-code-ide-session-status-blockers status))))
    ('unobserved (claude-code-ide-session-status-registered status))
    (_ (claude-code-ide-session-status-since status))))

;;; Common states

(defconst claude-code-ide-session-status--approval-notifications
  '("permission_prompt" "worker_permission_prompt")
  "Notification types that ask the user for an approval.")

(defun claude-code-ide-session-status--blocker-reason (status blocker)
  "Return the common reason of BLOCKER of STATUS.
That is `approval', `question' or `dialog'.  A permission dialog of
AskUserQuestion is a question menu; the other permission dialogs ask
for an approval.  The tool name comes from the PermissionRequest, else
from the tool in flight.  A permission notification asks for an
approval.  An elicitation and the other notifications are dialogs."
  (let ((name (claude-code-ide-session-status--blocker-name blocker)))
    (pcase (claude-code-ide-session-status--blocker-kind blocker)
      ('permission
       (let* ((tool (claude-code-ide-session-status--blocker-tool blocker))
              (value (and tool (gethash tool (claude-code-ide-session-status-inflight status)))))
         (if (equal (or name (nth 1 value)) "AskUserQuestion") 'question 'approval)))
      ('notification
       (if (member name claude-code-ide-session-status--approval-notifications)
           'approval
         'dialog))
      (_ 'dialog))))

(defun claude-code-ide-session-status--common-state (status now)
  "Return the common state of STATUS at NOW.
See `claude-code-ide-instance-state' for the result.
A nil STATUS, a session without status hooks, is
`disconnected/untracked'; hooks without an event since the start give
`disconnected/no-signal', and a start `working/starting'."
  (let* ((state (claude-code-ide-session-status--state status now))
         (since (claude-code-ide-session-status--state-since status state)))
    (pcase state
      ('waiting
       (claude-code-ide-instance-make-state
        'waiting-for-user
        (claude-code-ide-session-status--blocker-reason
         status (car (claude-code-ide-session-status-blockers status)))
        since))
      ;; The reply ends with a question: a guess of the ask regexps
      ('asks (claude-code-ide-instance-make-state 'waiting-for-user 'question since t))
      ('error (claude-code-ide-instance-make-state 'failed 'error since))
      ('quota (claude-code-ide-instance-make-state 'failed 'quota-limit since))
      ((or 'tasks 'tasks-quiet)
       (claude-code-ide-instance-make-state 'waiting-for-task 'subagent since))
      ('idle (claude-code-ide-instance-make-state
              'idle nil since (claude-code-ide-session-status-guessed status)))
      ;; The CLI starts and takes no prompt yet
      ('starting (claude-code-ide-instance-make-state 'working 'starting since))
      ('working (claude-code-ide-instance-make-state 'working nil since))
      ;; Hooks, but no event since the start
      ('unobserved (claude-code-ide-instance-make-state 'disconnected 'no-signal since))
      ;; No status hooks
      (_ (claude-code-ide-instance-make-state 'disconnected 'untracked since)))))

(defun claude-code-ide-session-status--instance-state (instance now)
  "Return the common state of the Claude Code INSTANCE at NOW, or nil.
This is a function of `claude-code-ide-instance-state-functions'."
  (when (eq (claude-code-ide-instance-provider instance) 'claude)
    (claude-code-ide-session-status--common-state
     (gethash (claude-code-ide-instance-session instance)
              claude-code-ide-session-status--by-session)
     now)))

(add-hook 'claude-code-ide-instance-state-functions
          #'claude-code-ide-session-status--instance-state)

;;; Instances of other providers

(defvar claude-code-ide-session-status-detail-functions nil
  "Functions that give the detail text of an instance of another provider.
Each function is called with INSTANCE and NOW (a float time) and
returns a string, or nil when it does not know INSTANCE.  The first
non-nil result is used.  Claude Code instances get their detail from
this file.")

(defun claude-code-ide-session-status--other-provider-p (instance)
  "Return non-nil when INSTANCE runs a provider other than Claude Code."
  (and instance
       (claude-code-ide-instance-provider instance)
       (not (eq (claude-code-ide-instance-provider instance) 'claude))))

(defun claude-code-ide-session-status--item-instance (item)
  "Return the descriptor of the row ITEM, a session or a descriptor, or nil."
  (if (claude-code-ide-instance-p item)
      item
    (claude-code-ide-instance-of-session item)))

(defun claude-code-ide-session-status--item-buffer (item)
  "Return the terminal buffer of the row ITEM, a session or a descriptor."
  (if (claude-code-ide-instance-p item)
      (or (claude-code-ide-instance-buffer item)
          (let ((session (claude-code-ide-instance-session item)))
            (and session (claude-code-ide-mcp-session-buffer session))))
    (claude-code-ide-mcp-session-buffer item)))

(defun claude-code-ide-session-status--item-project-dir (item)
  "Return the project directory of the row ITEM, a session or a descriptor."
  (file-name-as-directory
   (expand-file-name
    (if (claude-code-ide-instance-p item)
        (or (claude-code-ide-known-or-nil (claude-code-ide-instance-project-root item))
            (let ((session (claude-code-ide-instance-session item)))
              (and session (claude-code-ide-mcp-session-project-dir session)))
            default-directory)
      (claude-code-ide-mcp-session-project-dir item)))))

(defun claude-code-ide-session-status--common-label-key (state)
  "Return the status buffer state for the common STATE plist.
Rows of other providers use it; their state comes from
`claude-code-ide-instance-state'."
  (let ((reason (plist-get state :reason)))
    (pcase (plist-get state :state)
      ('waiting-for-user (if (and (eq reason 'question) (plist-get state :guess)) 'asks 'waiting))
      ('failed (if (eq reason 'quota-limit) 'quota 'error))
      ('waiting-for-task 'tasks)
      ('idle 'idle)
      ('working (if (eq reason 'starting) 'starting 'working))
      (_ (pcase reason
           ('untracked 'untracked)
           ('no-signal 'unobserved)
           (_ 'disconnected))))))

(defun claude-code-ide-session-status--other-detail (instance now)
  "Return the detail text of INSTANCE of another provider at NOW."
  (or (run-hook-with-args-until-success 'claude-code-ide-session-status-detail-functions
                                        instance now)
      ""))

(defun claude-code-ide-session-status--format-state (state)
  "Return the common STATE plist as text, such as \"waiting-for-user/approval\".
A state that Emacs guesses ends with a question mark."
  (if (null state)
      "unknown"
    (concat (symbol-name (plist-get state :state))
            (if (plist-get state :reason) (format "/%s" (plist-get state :reason)) "")
            (if (plist-get state :guess) "?" ""))))

(defconst claude-code-ide-session-status--rank
  '((waiting . 0) (asks . 1) (quota . 2) (error . 3) (unobserved . 4) (disconnected . 5)
    (tasks-quiet . 6) (idle . 7) (tasks . 8) (starting . 9) (working . 10) (untracked . 11))
  "Order of the states in the status buffer: what needs the user first.")

(defconst claude-code-ide-session-status--labels
  '((waiting "NEEDS ANSWER" claude-code-ide-session-status-waiting)
    (asks "ASKS YOU" claude-code-ide-session-status-waiting)
    (quota "QUOTA LIMIT" claude-code-ide-session-status-waiting)
    (error "FAILED" claude-code-ide-session-status-waiting)
    (unobserved "NO SIGNAL" claude-code-ide-session-status-waiting)
    (disconnected "DISCONNECTED" claude-code-ide-session-status-waiting)
    (tasks-quiet "TASKS QUIET" claude-code-ide-session-status-idle)
    (idle "WAITS FOR YOU" claude-code-ide-session-status-idle)
    (tasks "WAITS ON TASKS" claude-code-ide-session-status-working)
    (starting "STARTING" claude-code-ide-session-status-quiet)
    (working "WORKING" claude-code-ide-session-status-working)
    (untracked "UNTRACKED" claude-code-ide-session-status-quiet))
  "Label and face of each state.
Each label says who waits for whom: the agent for the user's answer
or next message, or the agent for its own background tasks.")

(defun claude-code-ide-session-status--label-width ()
  "Return the width of the longest status label."
  (apply #'max (mapcar (lambda (entry) (string-width (nth 1 entry)))
                       claude-code-ide-session-status--labels)))

(defun claude-code-ide-session-status--urgent-p (state)
  "Return non-nil when STATE asks the user to act or look at once."
  (memq state '(waiting asks quota error unobserved disconnected tasks-quiet)))

(defun claude-code-ide-session-status--claude-row (session now)
  "Return the row of the Claude Code SESSION at NOW."
  (let* ((status (gethash session claude-code-ide-session-status--by-session))
         (state (claude-code-ide-session-status--state status now)))
    (list session state
          (claude-code-ide-session-status--state-since status state)
          (claude-code-ide-session-status--detail status state now)
          (claude-code-ide-session-status--common-state status now))))

(defun claude-code-ide-session-status--other-row (item instance now)
  "Return the row of ITEM, whose descriptor INSTANCE runs another provider, at NOW."
  (let ((common (claude-code-ide-instance-state instance now)))
    (list item (claude-code-ide-session-status--common-label-key common)
          (plist-get common :since)
          (claude-code-ide-session-status--other-detail instance now)
          common)))

(defun claude-code-ide-session-status--rows (&optional now)
  "Return (ITEM STATE SINCE DETAIL COMMON) for each live instance at NOW.
ITEM is the MCP session of the instance, or its descriptor when it has
no session.  STATE is a state of the status buffer, and COMMON is the
common state plist.  Claude Code sessions get their state from their
hooks; instances of other providers from `claude-code-ide-instance-state'.
The rows are in the order of `claude-code-ide-session-status--rank',
oldest first within a state."
  (let* ((now (or now (float-time)))
         (sessions (claude-code-ide-mcp--active-sessions))
         (rows
          (append
           (delq nil
                 (mapcar
                  (lambda (session)
                    (let ((buffer (claude-code-ide-mcp-session-buffer session))
                          (instance (claude-code-ide-instance-of-session session)))
                      (when (and buffer (buffer-live-p buffer))
                        (if (claude-code-ide-session-status--other-provider-p instance)
                            (claude-code-ide-session-status--other-row session instance now)
                          (claude-code-ide-session-status--claude-row session now)))))
                  sessions))
           ;; Instances of other providers that have no MCP session
           (delq nil
                 (mapcar
                  (lambda (instance)
                    (let ((buffer (claude-code-ide-session-status--item-buffer instance)))
                      (when (and (claude-code-ide-session-status--other-provider-p instance)
                                 (not (memq (claude-code-ide-instance-session instance) sessions))
                                 buffer (buffer-live-p buffer))
                        (claude-code-ide-session-status--other-row instance instance now))))
                  (claude-code-ide-instances))))))
    (sort rows
          (lambda (a b)
            (let ((rank-a (alist-get (nth 1 a) claude-code-ide-session-status--rank))
                  (rank-b (alist-get (nth 1 b) claude-code-ide-session-status--rank)))
              (if (/= rank-a rank-b)
                  (< rank-a rank-b)
                (< (or (nth 2 a) now) (or (nth 2 b) now))))))))

;;; Status snapshot

(defcustom claude-code-ide-session-status-snapshot t
  "When non-nil, write a status snapshot file for external coordinators.
The file is <report directory>/status/<emacs-pid>.json, with the
schema `claude-code-ide-status/v1' of docs/status-schema.md.  Emacs
writes it at each change and at least every
`claude-code-ide-session-status-snapshot-interval' seconds, while an
instance runs or a status mode is on."
  :type 'boolean
  :group 'claude-code-ide)

(defcustom claude-code-ide-session-status-snapshot-interval 10
  "Seconds after which the status snapshot is written again without a change.
A reader treats a snapshot older than 30 seconds as stale, so keep
this value well below 30."
  :type 'number
  :group 'claude-code-ide)

(defconst claude-code-ide-session-status-snapshot-schema "claude-code-ide-status/v1"
  "Schema name of the status snapshot file.")

(defconst claude-code-ide-session-status-snapshot-stale-after 30
  "Seconds after which a reader treats a status snapshot as stale.")

(defvar claude-code-ide-session-status--snapshot-timer nil
  "Timer that writes the status snapshot at least every interval.")

(defvar claude-code-ide-session-status--snapshot-last nil
  "(TIME . KEY) of the last snapshot write: its time and its content without ages.")

(defun claude-code-ide-session-status--snapshot-file (&optional pid)
  "Return the status snapshot file of the Emacs process PID (default: this one)."
  (expand-file-name (format "status/%d.json" (or pid (emacs-pid)))
                    (claude-code-ide-session-registry--report-directory)))

(defun claude-code-ide-session-status--iso-time (time)
  "Return the float TIME as an ISO 8601 UTC string, or nil for a nil TIME."
  (and time (format-time-string "%FT%T.%3NZ" time t)))

(defun claude-code-ide-session-status--json-value (value)
  "Return VALUE for the snapshot: `unknown' as \"unknown\", a symbol as its name."
  (cond
   ((null value) nil)
   ((stringp value) value)
   ((numberp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%s" value))))

(defun claude-code-ide-session-status--instance-detail (instance now)
  "Return the detail text of INSTANCE at NOW, of any provider."
  (if (claude-code-ide-session-status--other-provider-p instance)
      (claude-code-ide-session-status--other-detail instance now)
    (let* ((status (gethash (claude-code-ide-instance-session instance)
                            claude-code-ide-session-status--by-session))
           (state (claude-code-ide-session-status--state status now)))
      (or (claude-code-ide-session-status--detail status state now) ""))))

(defun claude-code-ide-session-status--snapshot-instance (instance now)
  "Return the snapshot record of INSTANCE at NOW, as an alist."
  (let* ((state (claude-code-ide-instance-state instance now))
         (buffer (claude-code-ide-session-status--item-buffer instance))
         (value #'claude-code-ide-session-status--json-value))
    `((instance_id . ,(claude-code-ide-instance-id instance))
      (provider . ,(funcall value (claude-code-ide-or-unknown (claude-code-ide-instance-provider instance))))
      (native_id . ,(funcall value (claude-code-ide-instance-native-id instance)))
      (display_name . ,(funcall value (claude-code-ide-instance-display-name instance)))
      (project_root . ,(funcall value (claude-code-ide-instance-project-root instance)))
      (worktree . ,(funcall value (claude-code-ide-instance-worktree instance)))
      (model . ,(funcall value (claude-code-ide-or-unknown (claude-code-ide-instance-model instance))))
      (role . ,(funcall value (claude-code-ide-instance-role instance)))
      (generation . ,(claude-code-ide-instance-generation instance))
      (pid . ,(funcall value (claude-code-ide-instance-pid instance)))
      (buffer . ,(if (buffer-live-p buffer) (buffer-name buffer) "unknown"))
      (state . ,(funcall value (plist-get state :state)))
      (reason . ,(funcall value (plist-get state :reason)))
      (guess . ,(if (plist-get state :guess) t :json-false))
      (since . ,(claude-code-ide-session-status--iso-time (plist-get state :since)))
      (age_seconds . ,(let ((age (plist-get state :age))) (and age (round age))))
      (detail . ,(claude-code-ide-session-status--instance-detail instance now)))))

(defun claude-code-ide-session-status--snapshot-data (now)
  "Return the status snapshot at NOW as an alist for `json-encode'."
  `((schema . ,claude-code-ide-session-status-snapshot-schema)
    (generated_at . ,(claude-code-ide-session-status--iso-time now))
    (producer_pid . ,(emacs-pid))
    (host . ,(system-name))
    (interval_seconds . ,claude-code-ide-session-status-snapshot-interval)
    (stale_after_seconds . ,claude-code-ide-session-status-snapshot-stale-after)
    (instances . ,(vconcat (mapcar (lambda (instance)
                                     (claude-code-ide-session-status--snapshot-instance instance now))
                                   (claude-code-ide-instances))))))

(defun claude-code-ide-session-status--snapshot-key (data)
  "Return the instances of the snapshot DATA without their ages.
Two snapshots with the same key differ only in values that change with
time alone."
  (mapcar (lambda (instance)
            (cl-remove 'age_seconds instance :key #'car))
          (append (alist-get 'instances data) nil)))

(defun claude-code-ide-session-status--write-snapshot (&optional force now)
  "Write the status snapshot when it changed, or when FORCE is non-nil.
NOW is the float time of the snapshot.  A snapshot without a change is
also written when the last write is
`claude-code-ide-session-status-snapshot-interval' seconds old.
Return non-nil when the file was written.  An error gives a message
and does not stop the caller."
  (when claude-code-ide-session-status-snapshot
    (condition-case err
        (let* ((now (or now (float-time)))
               (data (claude-code-ide-session-status--snapshot-data now))
               (key (claude-code-ide-session-status--snapshot-key data))
               (last claude-code-ide-session-status--snapshot-last))
          (when (or force
                    (null last)
                    (not (equal (cdr last) key))
                    (>= (- now (car last)) claude-code-ide-session-status-snapshot-interval))
            (claude-code-ide-session-status--write-file-atomically
             (claude-code-ide-session-status--snapshot-file)
             (concat (json-encode data) "\n") nil #o700)
            (setq claude-code-ide-session-status--snapshot-last (cons now key))
            (add-hook 'kill-emacs-hook #'claude-code-ide-session-status--remove-snapshot)
            t))
      (error
       (message "Session status: the snapshot could not be written: %s"
                (error-message-string err))
       nil))))

(defun claude-code-ide-session-status--remove-snapshot ()
  "Delete the status snapshot of this Emacs."
  (setq claude-code-ide-session-status--snapshot-last nil)
  (ignore-errors (delete-file (claude-code-ide-session-status--snapshot-file))))

(defun claude-code-ide-session-status--snapshot-wanted-p ()
  "Return non-nil while the status snapshot has something to report.
That is while an instance runs, a launch is tracked, or a status mode
is on."
  (and claude-code-ide-session-status-snapshot
       (or (claude-code-ide-instances)
           (> (hash-table-count claude-code-ide-session-status--by-nonce) 0)
           claude-code-ide-session-status-mode
           (bound-and-true-p claude-code-ide-session-registry-mode))))

(defun claude-code-ide-session-status--snapshot-tick ()
  "Write the status snapshot, or stop when there is nothing to report.
When the timer stops, the snapshot file is deleted: a missing file
means that this Emacs reports no instances."
  (if (claude-code-ide-session-status--snapshot-wanted-p)
      (claude-code-ide-session-status--write-snapshot t)
    (when (timerp claude-code-ide-session-status--snapshot-timer)
      (cancel-timer claude-code-ide-session-status--snapshot-timer))
    (setq claude-code-ide-session-status--snapshot-timer nil)
    (claude-code-ide-session-status--remove-snapshot)))

(defun claude-code-ide-session-status--ensure-snapshot-timer ()
  "Start the timer that writes the status snapshot, when it is wanted."
  (when (and claude-code-ide-session-status-snapshot
             (not (timerp claude-code-ide-session-status--snapshot-timer)))
    (setq claude-code-ide-session-status--snapshot-timer
          (run-with-timer claude-code-ide-session-status-snapshot-interval
                          claude-code-ide-session-status-snapshot-interval
                          #'claude-code-ide-session-status--snapshot-tick))))

;;; Status buffer

(defun claude-code-ide-session-status--age (since now)
  "Return the time from SINCE to NOW, short."
  (if (null since)
      ""
    (let ((seconds (max 0 (- now since))))
      (cond
       ((< seconds 60) (format "%ds" seconds))
       ((< seconds 3600) (format "%dm" (/ seconds 60)))
       (t (format "%dh" (/ seconds 3600)))))))

(defvar claude-code-ide-session-status--label-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'claude-code-ide-session-status-visit-click)
    (define-key map [mouse-2] #'claude-code-ide-session-status-visit-click)
    map)
  "Keymap of a status label: a click goes to the session of the line.")

(defconst claude-code-ide-session-status--session-width 30
  "Width of the Session column; longer names are cut.")

(defconst claude-code-ide-session-status--provider-width 8
  "Width of the Provider column.")

(defconst claude-code-ide-session-status--model-width 16
  "Width of the Model column; longer names are cut.")

(defconst claude-code-ide-session-status--state-width 26
  "Width of the State column, the common state and its reason.")

(defun claude-code-ide-session-status--provider-label (item)
  "Return the provider name of ITEM for its row, or \"unknown\".
ITEM is a session or a descriptor."
  (claude-code-ide-format-value
   (claude-code-ide-or-unknown
    (when-let* ((instance (claude-code-ide-session-status--item-instance item)))
      (claude-code-ide-instance-provider instance)))))

(defun claude-code-ide-session-status--model-label (item)
  "Return the model of ITEM for its row, or \"unknown\".
ITEM is a session or a descriptor.  A model that Emacs does not know,
also of a session without a descriptor, shows \"unknown\"."
  (let* ((instance (claude-code-ide-session-status--item-instance item))
         (model (and instance (claude-code-ide-instance-model instance))))
    (claude-code-ide-format-value
     (if (and (stringp model) (not (string-empty-p model))) model 'unknown))))

(cl-defstruct (claude-code-ide-session-status--group
               (:constructor claude-code-ide-session-status--group-create)
               (:copier nil))
  "A Claude project, its directory, and the rows of its sessions."
  (directory "" :type string)
  (rows nil :type list :documentation "Rows of `claude-code-ide-session-status--rows'."))

(defun claude-code-ide-session-status--group-by-project (rows)
  "Return ROWS grouped by the project directory of their session.
The groups keep the order of their first row, so the project with the
session that needs the user most comes first; rows keep their order."
  (let ((groups '()))
    (dolist (row rows)
      (let* ((directory (claude-code-ide-session-status--item-project-dir (car row)))
             (group (cl-find directory groups
                             :key #'claude-code-ide-session-status--group-directory
                             :test #'equal)))
        (if group
            (setf (claude-code-ide-session-status--group-rows group)
                  (append (claude-code-ide-session-status--group-rows group) (list row)))
          (setq groups (append groups (list (claude-code-ide-session-status--group-create
                                             :directory directory :rows (list row))))))))
    groups))

(defvar claude-code-ide-session-status--title-cache (make-hash-table :test 'eql)
  "PID -> (FILE-TIME . TITLE) of the CLI session files read last.")

(defun claude-code-ide-session-status--user-title (session)
  "Return the title that the user gave SESSION with /rename or --name, or nil.
It comes from the file that the CLI process keeps in ~/.claude/sessions."
  (when-let* ((pid (claude-code-ide-session-registry--session-pid session))
              (file (claude-code-ide-session-registry--cli-session-file pid))
              (attributes (file-attributes file)))
    (let ((time (file-attribute-modification-time attributes))
          (cached (gethash pid claude-code-ide-session-status--title-cache)))
      (if (and cached (equal (car cached) time))
          (cdr cached)
        (let* ((cli (claude-code-ide-session-registry--read-cli-session file))
               (title (and cli
                           (claude-code-ide-session-registry--cli-session-name-from-user cli)
                           (claude-code-ide-session-registry--cli-session-name cli))))
          (puthash pid (cons time title) claude-code-ide-session-status--title-cache)
          title)))))

(defun claude-code-ide-session-status--session-label (item)
  "Return the name of ITEM in its row, under its project line.
For a session: its instance name, else the title that the user gave
it, else the project name.  For a descriptor without a session: its
display name, else the project name."
  (if (claude-code-ide-instance-p item)
      (let ((name (claude-code-ide-known-or-nil (claude-code-ide-instance-display-name item))))
        (if (and (stringp name) (not (string-empty-p name)))
            name
          (file-name-nondirectory
           (directory-file-name (claude-code-ide-session-status--item-project-dir item)))))
    (or (claude-code-ide-mcp-session-instance-name item)
        (claude-code-ide-session-status--user-title item)
        (file-name-nondirectory
         (directory-file-name (claude-code-ide-mcp-session-project-dir item))))))

(defun claude-code-ide-session-status--group-header (group)
  "Return the header line text of GROUP."
  (let ((count (length (claude-code-ide-session-status--group-rows group)))
        (directory (claude-code-ide-session-status--group-directory group)))
    (concat (propertize (file-name-nondirectory (directory-file-name directory)) 'face 'bold)
            (propertize (format "  %d session%s · %s" count (if (= count 1) "" "s")
                                (abbreviate-file-name directory))
                        'face 'shadow))))

(defun claude-code-ide-session-status--entries (rows now)
  "Return the `tabulated-list-entries' for ROWS at NOW, grouped by project.
Each group starts with a header entry whose id is the group."
  (apply #'append
         (mapcar
          (lambda (group)
            (cons (list group (vector (claude-code-ide-session-status--group-header group)
                                      "" "" "" "" "" ""))
                  (mapcar (lambda (row)
                            (pcase-let* ((`(,item ,state ,since ,detail ,common) row)
                                         (`(,label ,face) (alist-get state claude-code-ide-session-status--labels)))
                              (list item
                                    (vector (propertize label
                                                        'face face
                                                        'mouse-face 'highlight
                                                        'help-echo "mouse-1: go to this session"
                                                        'follow-link t
                                                        'keymap claude-code-ide-session-status--label-map)
                                            (truncate-string-to-width
                                             (concat "  " (claude-code-ide-session-status--session-label item))
                                             claude-code-ide-session-status--session-width nil nil "…")
                                            (claude-code-ide-session-status--provider-label item)
                                            (truncate-string-to-width
                                             (claude-code-ide-session-status--model-label item)
                                             claude-code-ide-session-status--model-width nil nil "…")
                                            (claude-code-ide-session-status--format-state common)
                                            (claude-code-ide-session-status--age since now)
                                            (or detail "")))))
                          (claude-code-ide-session-status--group-rows group))))
          (claude-code-ide-session-status--group-by-project rows))))

(defun claude-code-ide-session-status--print-entry (id cols)
  "Print the entry ID with COLS: a project header as one whole line."
  (if (claude-code-ide-session-status--group-p id)
      (let ((start (point)))
        (insert (aref cols 0) "\n")
        (add-text-properties start (point) (list 'tabulated-list-id id
                                                 'tabulated-list-entry cols)))
    (tabulated-list-print-entry id cols)))

(defvar claude-code-ide-session-status-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'claude-code-ide-session-status-visit)
    (define-key map (kbd "w") #'claude-code-ide-visit-waiting-session)
    (define-key map (kbd "T") #'claude-code-ide-session-status-track)
    (define-key map (kbd "H") #'claude-code-ide-session-status-handover)
    map)
  "Keymap of `claude-code-ide-session-status-list-mode'.")

(define-derived-mode claude-code-ide-session-status-list-mode tabulated-list-mode
  "Claude Status"
  "Live status of the Claude Code sessions of this Emacs, by project.
The projects and sessions that need you come first.  RET on a project
line goes to its first session.  H offers a handover of the session on
the line, or of the first session at a quota limit.

\\{claude-code-ide-session-status-list-mode-map}"
  (setq tabulated-list-format
        (vector (list "Status" (claude-code-ide-session-status--label-width) nil)
                (list "Session" claude-code-ide-session-status--session-width nil)
                (list "Provider" claude-code-ide-session-status--provider-width nil)
                (list "Model" claude-code-ide-session-status--model-width nil)
                (list "State" claude-code-ide-session-status--state-width nil)
                '("For" 5 nil :right-align t)
                '("Detail" 0 nil)))
  (setq tabulated-list-sort-key nil)
  (setq tabulated-list-padding claude-code-ide-session-status-indent)
  (setq-local tabulated-list-printer #'claude-code-ide-session-status--print-entry)
  (add-hook 'tabulated-list-revert-hook #'claude-code-ide-session-status--refresh nil t)
  (tabulated-list-init-header))

(defun claude-code-ide-session-status--refresh ()
  "Update the status buffer, when it exists, and the mode line count."
  (let* ((now (float-time))
         (rows (claude-code-ide-session-status--rows now))
         (count (cl-count-if (lambda (row)
                               (claude-code-ide-session-status--urgent-p (nth 1 row)))
                             rows)))
    (when-let* ((buffer (get-buffer claude-code-ide-session-status--buffer-name)))
      (with-current-buffer buffer
        (setq tabulated-list-entries (claude-code-ide-session-status--entries rows now))
        (tabulated-list-print t))
      (dolist (window (get-buffer-window-list buffer nil t))
        (when (window-parameter window 'window-side)
          (fit-window-to-buffer window claude-code-ide-session-status-max-height))))
    (unless (= count claude-code-ide-session-status--urgent-count)
      (setq claude-code-ide-session-status--urgent-count count)
      (force-mode-line-update t))
    ;; Only while the snapshot timer runs, which owns the file
    (when (timerp claude-code-ide-session-status--snapshot-timer)
      (claude-code-ide-session-status--write-snapshot nil now))))

(defun claude-code-ide-session-status--visit-session (item)
  "Show the terminal buffer of ITEM and select its window.
ITEM is a session or a descriptor."
  (let ((buffer (claude-code-ide-session-status--item-buffer item))
        (session (if (claude-code-ide-instance-p item)
                     (claude-code-ide-instance-session item)
                   item)))
    (unless (and buffer (buffer-live-p buffer))
      (user-error "That session has ended"))
    (when session
      (claude-code-ide--touch-session session))
    (if-let* ((window (get-buffer-window buffer t)))
        (progn
          (select-frame-set-input-focus (window-frame window))
          (select-window window))
      (when-let* ((window (claude-code-ide--display-buffer-in-side-window buffer)))
        (select-window window)))))

(defun claude-code-ide-session-status-visit-click (event)
  "Go to the session whose status label the mouse EVENT clicked."
  (interactive "e")
  (mouse-set-point event)
  (claude-code-ide-session-status-visit))

(defun claude-code-ide-session-status-track (&optional force)
  "Restart the untracked session on this line, so that its CLI gets status hooks.
With a prefix argument FORCE, restart it also while it is busy."
  (interactive "P")
  (let ((session (tabulated-list-get-id)))
    (unless (and session (not (claude-code-ide-session-status--group-p session)))
      (user-error "No session on this line"))
    (when (claude-code-ide-instance-p session)
      (user-error "Only Claude Code sessions are restarted with status hooks"))
    (unless (memq session (claude-code-ide-session-registry--untracked-sessions))
      (user-error "%s has status hooks already" (claude-code-ide--session-display-name session)))
    (when (yes-or-no-p (format "Restart %s to add status tracking?  Its background tasks end.  "
                               (claude-code-ide--session-display-name session)))
      (claude-code-ide-session-registry--track-session
       session claude-code-ide-session-registry-track-note force))))

(defun claude-code-ide-session-status-visit ()
  "Go to the session on this line, or the first session of a project line."
  (interactive)
  (let ((id (or (tabulated-list-get-id) (user-error "No session on this line"))))
    (claude-code-ide-session-status--visit-session
     (if (claude-code-ide-session-status--group-p id)
         (car (car (claude-code-ide-session-status--group-rows id)))
       id))))

(declare-function claude-code-ide-handover "claude-code-ide-handover"
                  (instance-id target-provider &optional method context interrupt force))
(declare-function claude-code-ide-handover--read-args "claude-code-ide-handover"
                  (&optional instance-id))

(defun claude-code-ide-session-status--row-instance (item)
  "Return the instance descriptor of the row ITEM (a session or a descriptor)."
  (if (claude-code-ide-instance-p item)
      item
    (claude-code-ide-instance-of-session item)))

(defun claude-code-ide-session-status--handover-instance ()
  "Return the instance that the handover key offers, or nil.
That is the session on the current line, else the first session whose
state is a quota limit."
  (let ((id (tabulated-list-get-id)))
    (or (and id (not (claude-code-ide-session-status--group-p id))
             (claude-code-ide-session-status--row-instance id))
        (when-let* ((row (cl-find 'quota (claude-code-ide-session-status--rows)
                                  :key (lambda (row) (nth 1 row)))))
          (claude-code-ide-session-status--row-instance (car row))))))

(defun claude-code-ide-session-status-handover ()
  "Offer a handover of the session on this line to a new conversation.
Without a session on the line, offer the first session at a quota
limit.  Emacs asks for the target provider and the rest, and starts
nothing without your answers; see `claude-code-ide-handover'."
  (interactive)
  (unless (require 'claude-code-ide-handover nil t)
    (user-error "The handover file is not available"))
  (let ((instance (or (claude-code-ide-session-status--handover-instance)
                      (user-error "No session on this line, and none at a quota limit"))))
    (apply #'claude-code-ide-handover
           (claude-code-ide-handover--read-args (claude-code-ide-instance-id instance)))))

;;;###autoload
(defun claude-code-ide-visit-waiting-session ()
  "Go to the first session in the status list that needs you.
Sessions that need an answer come first, then failed and silent ones,
then those with quiet background tasks, then those that wait for your
next message; the longest wait first within each state."
  (interactive)
  (let ((row (cl-find-if (lambda (row)
                           (memq (nth 1 row) '(waiting asks quota error unobserved disconnected
                                                       tasks-quiet idle)))
                         (claude-code-ide-session-status--rows))))
    (if row
        (claude-code-ide-session-status--visit-session (car row))
      (message "No Claude Code session waits for you"))))

(defun claude-code-ide-session-status--lighter ()
  "Return the mode line text: the number of sessions that need you at once.
These need an answer, failed, sent no signal, or have quiet tasks."
  (if (> claude-code-ide-session-status--urgent-count 0)
      (propertize (format " Claude[%d need you]" claude-code-ide-session-status--urgent-count)
                  'face 'claude-code-ide-session-status-waiting)
    " Claude"))

(defun claude-code-ide-session-status--display ()
  "Create the status buffer when needed and display it."
  (let ((buffer (get-buffer-create claude-code-ide-session-status--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-code-ide-session-status-list-mode)
        (claude-code-ide-session-status-list-mode)))
    (claude-code-ide-session-status--refresh)
    (display-buffer buffer claude-code-ide-session-status-display-action)
    (claude-code-ide-session-status--refresh)))

;;;###autoload
(define-minor-mode claude-code-ide-session-status-mode
  "Show the live status of each Claude Code session in a buffer.
The buffer lists the sessions of this Emacs, the ones that wait for you
first, and updates itself.  RET goes to a session.  The mode line shows
how many sessions wait.  Turning the mode off closes the buffer.
The status comes from hooks that `claude-code-ide-session-registry-mode'
passes to the instances it starts, so this mode turns it on."
  :global t
  :group 'claude-code-ide
  :lighter (:eval (claude-code-ide-session-status--lighter))
  (if claude-code-ide-session-status-mode
      (progn
        (unless claude-code-ide-session-registry-mode
          (claude-code-ide-session-registry-mode 1))
        (claude-code-ide-session-status--ensure-timers)
        (claude-code-ide-session-status--display))
    (when-let* ((buffer (get-buffer claude-code-ide-session-status--buffer-name)))
      (dolist (window (get-buffer-window-list buffer nil t))
        (ignore-errors (delete-window window)))
      (kill-buffer buffer))
    (when (zerop (hash-table-count claude-code-ide-session-status--by-nonce))
      (claude-code-ide-session-status--stop-timers))
    (force-mode-line-update t)))

;;;###autoload
(defun claude-code-ide-show-session-status ()
  "Show the status buffer of the Claude Code sessions.
This turns on `claude-code-ide-session-status-mode'."
  (interactive)
  (if claude-code-ide-session-status-mode
      (claude-code-ide-session-status--display)
    (claude-code-ide-session-status-mode 1)))

(provide 'claude-code-ide-session-status)

;;; claude-code-ide-session-status.el ends here
