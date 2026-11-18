;;; claude-code-ide-process.el --- Process trees of agent CLIs  -*- lexical-binding: t; -*-

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

;; A coding-agent CLI starts each background command in its own session
;; and process group.  A kill of the CLI, or of its process group, does
;; not reach that command, and after the CLI ends the command has the
;; parent process 1.  So this file records, while the CLI runs, the
;; process groups of all its descendants.  At a stop it ends the CLI
;; with the soft end of its provider, waits, and then ends the recorded
;; process groups that still run.  Last, it lists the other processes
;; whose working folder is in the worktree: a double fork with `setsid'
;; escapes every record, and only that scan finds it.
;;
;; Public functions:
;;
;; - `claude-code-ide-process-track': start to record the groups of a CLI.
;; - `claude-code-ide-process-stop': soft end, wait, end the groups, scan.
;; - `claude-code-ide-process-stop-many': the same for several instances
;;   at once, with one shared wait (for the quit of Emacs).
;; - `claude-code-ide-process-stop-later': record now, stop from a timer
;;   (for `kill-buffer-hook', which must not wait).
;; - `claude-code-ide-process-worktree-strays': processes in a worktree.
;;
;; The functions only report stray processes.  They never end a process
;; that they did not record as a descendant of the CLI.  docs/process-tree.md
;; describes the steps and the calls that the start and the cleanup make.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'claude-code-ide-instance)

;;; Options

(defgroup claude-code-ide-process nil
  "Process trees of the agent CLIs."
  :group 'claude-code-ide)

(defcustom claude-code-ide-process-track-interval 2
  "Seconds between two records of the process groups of each CLI."
  :type 'number
  :group 'claude-code-ide-process)

(defcustom claude-code-ide-process-stop-timeout 5
  "Seconds that a stop waits for the CLI to exit after its soft end."
  :type 'number
  :group 'claude-code-ide-process)

(defcustom claude-code-ide-process-quit-timeout 1.5
  "Seconds that a stop waits for the CLIs when Emacs quits.
Keep it short: Emacs waits this long before it exits."
  :type 'number
  :group 'claude-code-ide-process)

(defcustom claude-code-ide-process-kill-wait 2
  "Seconds between SIGTERM and SIGKILL, and after SIGKILL."
  :type 'number
  :group 'claude-code-ide-process)

(defcustom claude-code-ide-process-soft-end
  '((claude . SIGHUP)
    (codex . SIGHUP))
  "The soft end of each provider: an alist (PROVIDER . END).
END is a signal symbol, which goes to the process group of the CLI,
or a function called with the instance and the process object, or
`none'.  A provider that is not in the list gets SIGHUP.

Claude Code stops its background shells at SIGHUP.  Codex stops its
background terminals only at its /quit command, but this package never
types into the Codex terminal; after SIGHUP the stop ends the recorded
process groups of those terminals."
  :type '(alist :key-type symbol
                :value-type (choice (const :tag "No soft end" none)
                                    (symbol :tag "Signal")
                                    (function :tag "Function")))
  :group 'claude-code-ide-process)

(defcustom claude-code-ide-process-ps-program "ps"
  "The ps program, for the table of all processes."
  :type 'string
  :group 'claude-code-ide-process)

(defcustom claude-code-ide-process-lsof-program "lsof"
  "The lsof program, for the working folders of processes."
  :type 'string
  :group 'claude-code-ide-process)

;;; Process data
;;
;; An entry is a plist (:pid :ppid :pgid :uid :start), where :start is
;; the start time as a float or nil.  The variables below give the
;; entries; tests bind them to a synthetic table.

(defvar claude-code-ide-process-list-function #'claude-code-ide-process--ps-list
  "Function without arguments that returns the entries of all processes.")

(defvar claude-code-ide-process-list-async-function
  #'claude-code-ide-process--ps-list-async
  "Function that calls its one argument with the entries of all processes.
It may call it later; it returns at once.")

(defvar claude-code-ide-process-entry-function
  #'claude-code-ide-process--attributes-entry
  "Function that returns the entry of one live process ID, or nil.")

(defvar claude-code-ide-process-command-function
  #'claude-code-ide-process--attributes-command
  "Function that returns the command line of a process ID, or nil.")

(defvar claude-code-ide-process-cwd-function #'claude-code-ide-process--lsof-cwds
  "Function that returns the working folders of processes.
It takes an optional list of process IDs (nil means all processes of
this user) and returns a list of plists (:pid :cwd :command).")

(defvar claude-code-ide-process-signal-function #'signal-process
  "Function that sends a signal: (TARGET SIGNAL), as `signal-process'.
TARGET is a process ID, or the negative ID of a process group.  The
result 0 means success.")

(defun claude-code-ide-process--same-start-p (a b)
  "Return non-nil when the start times A and B are the same.
ps gives whole seconds, so a difference below 1.5 seconds counts as
the same."
  (and (numberp a) (numberp b) (< (abs (- a b)) 1.5)))

(defun claude-code-ide-process--parse-lstart (text)
  "Return the start time TEXT of ps (lstart, C locale) as a float, or nil."
  (ignore-errors (float-time (encode-time (parse-time-string text)))))

(defun claude-code-ide-process--parse-ps (text)
  "Return the entries of TEXT, the output of `claude-code-ide-process--ps-args'."
  (let (entries)
    (dolist (line (split-string text "\n" t))
      (let ((fields (split-string line)))
        (when (>= (length fields) 9)
          (let ((pid (string-to-number (nth 0 fields))))
            (when (> pid 0)
              (push (list :pid pid
                          :ppid (string-to-number (nth 1 fields))
                          :pgid (string-to-number (nth 2 fields))
                          :uid (string-to-number (nth 3 fields))
                          :start (claude-code-ide-process--parse-lstart
                                  (string-join (nthcdr 4 fields) " ")))
                    entries))))))
    (nreverse entries)))

(defun claude-code-ide-process--ps-args ()
  "Return the arguments of ps for the table of all processes."
  (list "-A" "-o" "pid=,ppid=,pgid=,uid=,lstart="))

(defun claude-code-ide-process--ps-list ()
  "Return the entries of all processes from ps, or nil when ps fails."
  (with-temp-buffer
    (let ((default-directory "/")
          (process-environment (cons "LC_ALL=C" process-environment)))
      (when (eql 0 (ignore-errors
                     (apply #'call-process claude-code-ide-process-ps-program nil
                            '(t nil) nil (claude-code-ide-process--ps-args))))
        (claude-code-ide-process--parse-ps (buffer-string))))))

(defun claude-code-ide-process--ps-list-async (callback)
  "Run ps without a wait, and call CALLBACK with the entries.
CALLBACK gets nil when ps fails."
  (let* ((default-directory "/")
         (process-environment (cons "LC_ALL=C" process-environment))
         (buffer (generate-new-buffer " *claude-code-ide-ps*")))
    (condition-case nil
        (make-process
         :name "claude-code-ide-ps"
         :buffer buffer
         :command (cons claude-code-ide-process-ps-program
                        (claude-code-ide-process--ps-args))
         :connection-type 'pipe
         :noquery t
         :stderr null-device
         :sentinel
         (lambda (process _event)
           (unless (process-live-p process)
             (let ((entries (and (eq (process-status process) 'exit)
                                 (eql 0 (process-exit-status process))
                                 (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (claude-code-ide-process--parse-ps (buffer-string))))))
               (when (buffer-live-p buffer)
                 (kill-buffer buffer))
               (funcall callback entries)))))
      (error
       (kill-buffer buffer)
       (funcall callback nil)))))

(defun claude-code-ide-process--attributes-entry (pid)
  "Return the entry of the live process PID, or nil.
A zombie counts as gone."
  (when-let* ((attrs (and (integerp pid) (> pid 0)
                          (ignore-errors (process-attributes pid)))))
    (unless (equal (alist-get 'state attrs) "Z")
      (list :pid pid
            :ppid (alist-get 'ppid attrs)
            :pgid (alist-get 'pgrp attrs)
            :uid (alist-get 'euid attrs)
            :start (when-let* ((start (alist-get 'start attrs)))
                     (float-time start))))))

(defun claude-code-ide-process--attributes-command (pid)
  "Return the command line of PID, or nil."
  (when-let* ((attrs (ignore-errors (process-attributes pid))))
    (let ((args (alist-get 'args attrs)))
      (if (and (stringp args) (not (string-empty-p args)))
          args
        (alist-get 'comm attrs)))))

(defun claude-code-ide-process--parse-lsof (text)
  "Return the plists (:pid :cwd :command) of TEXT, lsof -Fpcn output."
  (let (result pid command)
    (dolist (line (split-string text "\n" t))
      (pcase (aref line 0)
        (?p (setq pid (string-to-number (substring line 1))
                  command nil))
        (?c (setq command (substring line 1)))
        (?n (when pid
              (push (list :pid pid :cwd (substring line 1) :command command)
                    result)))))
    (nreverse result)))

(defun claude-code-ide-process--lsof-cwds (&optional pids)
  "Return the plists (:pid :cwd :command) of the processes of this user.
With PIDS, only of those processes.  lsof runs in the folder /, so
that it is never in a worktree itself."
  (with-temp-buffer
    (let ((default-directory "/")
          (process-environment (cons "LC_ALL=C" process-environment)))
      (ignore-errors
        (apply #'call-process claude-code-ide-process-lsof-program nil '(t nil) nil
               (append (list "-w" "-a" "-d" "cwd" "-Fpcn")
                       (if pids
                           (list "-p" (mapconcat #'number-to-string pids ","))
                         (list "-u" (number-to-string (user-uid)))))))
      (claude-code-ide-process--parse-lsof (buffer-string)))))

(defun claude-code-ide-process--entry-alive-p (pid start)
  "Return the entry of PID when it runs and its start time is START.
START nil accepts any start time."
  (when-let* ((entry (and (integerp pid)
                          (funcall claude-code-ide-process-entry-function pid))))
    (when (or (null start)
              (claude-code-ide-process--same-start-p start (plist-get entry :start)))
      entry)))

;;; Tables

(defun claude-code-ide-process--index (table)
  "Return a hash table from process ID to entry, for TABLE."
  (let ((index (make-hash-table)))
    (dolist (entry table)
      (puthash (plist-get entry :pid) entry index))
    index))

(defun claude-code-ide-process--descendants (table root)
  "Return the entries of ROOT and of all its descendants in TABLE.
ROOT is a process ID.  The result is empty when ROOT is not in TABLE."
  (let ((children (make-hash-table))
        (index (claude-code-ide-process--index table))
        result queue)
    (dolist (entry table)
      (push entry (gethash (plist-get entry :ppid) children)))
    (when-let* ((root-entry (gethash root index)))
      (setq queue (list root-entry))
      (while queue
        (let ((entry (pop queue)))
          (push entry result)
          (dolist (child (gethash (plist-get entry :pid) children))
            ;; A ppid loop cannot happen, but a broken table must not hang
            (unless (memq child result)
              (setq queue (append queue (list child))))))))
    (nreverse result)))

(defun claude-code-ide-process--emacs-protected (table)
  "Return (PIDS . PGIDS) that a stop must never signal, from TABLE.
These are 0, 1, Emacs and its ancestors, and their process groups."
  (let* ((index (claude-code-ide-process--index table))
         (pids (list 0 1))
         (pgids (list 0 1))
         (pid (emacs-pid))
         (guard 0))
    (when-let* ((own (funcall claude-code-ide-process-entry-function pid)))
      (push (plist-get own :pgid) pgids))
    (while (and pid (> pid 1) (< guard 100))
      (setq guard (1+ guard))
      (push pid pids)
      (let ((entry (gethash pid index)))
        (when entry
          (push (plist-get entry :pgid) pgids))
        (setq pid (and entry (plist-get entry :ppid)))))
    (cons (delete-dups pids) (delete-dups pgids))))

;;; Records

(cl-defstruct (claude-code-ide-process--track
               (:constructor claude-code-ide-process--track-create)
               (:copier nil))
  "The process records of one instance."
  (instance nil :documentation "The descriptor.")
  (process nil :documentation "The process object of the terminal, or nil.")
  (pid nil :documentation "Process ID of the CLI (the root of the tree).")
  (start nil :documentation "Start time of the root as a float, or nil.")
  (groups (make-hash-table) :documentation "PGID -> plist (:pgid :leader-start :first-seen :command).")
  (members (make-hash-table) :documentation "PID -> start time of each recorded descendant.")
  (last-refresh nil :documentation "Time of the last record, or nil."))

(defvar claude-code-ide-process--tracks (make-hash-table :test 'equal)
  "Records of each instance ID.")

(defvar claude-code-ide-process--timer nil
  "The timer that records the groups of all tracked instances.")

(defvar claude-code-ide-process--refresh-running nil
  "Non-nil while an asynchronous ps runs for the records.")

(defun claude-code-ide-process--instance-id (instance)
  "Return the instance ID of INSTANCE, a descriptor or an ID."
  (if (claude-code-ide-instance-p instance)
      (claude-code-ide-instance-id instance)
    instance))

(defun claude-code-ide-process--track-of (instance)
  "Return the records of INSTANCE, a descriptor or an ID, or nil."
  (gethash (claude-code-ide-process--instance-id instance)
           claude-code-ide-process--tracks))

(defun claude-code-ide-process--process-pid (process)
  "Return the process ID of the CLI of PROCESS, or nil.
The ghostel backend gives a pipe that stands for its native child; the
pipe holds the process ID of the child."
  (when (processp process)
    (or (process-get process 'ghostel--native-pid)
        (process-id process))))

(defun claude-code-ide-process--record (track table now)
  "Add the descendants of the root of TRACK in TABLE to its records.
Drop the records of processes that are gone.  NOW is the time."
  (let* ((index (claude-code-ide-process--index table))
         (members (claude-code-ide-process--track-members track))
         (groups (claude-code-ide-process--track-groups track))
         (protected (cdr (claude-code-ide-process--emacs-protected table))))
    ;; Forget processes and groups that are gone.  A process group
    ;; cannot get new members after its last member is gone.
    (maphash (lambda (pid start)
               (let ((entry (gethash pid index)))
                 (unless (and entry
                              (claude-code-ide-process--same-start-p
                               start (plist-get entry :start)))
                   (remhash pid members))))
             members)
    (let ((live-pgids (make-hash-table)))
      (dolist (entry table)
        (puthash (plist-get entry :pgid) t live-pgids))
      (maphash (lambda (pgid _group)
                 (unless (gethash pgid live-pgids)
                   (remhash pgid groups)))
               groups))
    (dolist (entry (claude-code-ide-process--descendants
                    table (claude-code-ide-process--track-pid track)))
      (let ((pid (plist-get entry :pid))
            (pgid (plist-get entry :pgid)))
        (puthash pid (plist-get entry :start) members)
        (unless (memq pgid protected)
          (let ((group (or (gethash pgid groups)
                           (list :pgid pgid :leader-start nil :first-seen now
                                 :command nil))))
            (when (and (eql pid pgid) (null (plist-get group :leader-start)))
              (setq group (plist-put group :leader-start (plist-get entry :start)))
              (setq group (plist-put group :command
                                     (funcall claude-code-ide-process-command-function
                                              pid))))
            (puthash pgid group groups)))))
    (setf (claude-code-ide-process--track-last-refresh track) now)
    track))

(defun claude-code-ide-process--root-alive-p (track &optional table)
  "Return non-nil when the root of TRACK still runs.
With TABLE, look there; else ask for the one process."
  (let ((pid (claude-code-ide-process--track-pid track))
        (start (claude-code-ide-process--track-start track)))
    (if table
        (when-let* ((entry (cl-find pid table :key (lambda (e) (plist-get e :pid)))))
          (or (null start)
              (claude-code-ide-process--same-start-p start (plist-get entry :start))))
      (claude-code-ide-process--entry-alive-p pid start))))

(defun claude-code-ide-process--record-all (table)
  "Record TABLE in each track whose root still runs.
Stop the timer when no root runs."
  (let ((now (float-time))
        (running nil))
    (maphash (lambda (_id track)
               (when (claude-code-ide-process--root-alive-p track table)
                 (setq running t)
                 (claude-code-ide-process--record track table now)))
             claude-code-ide-process--tracks)
    (unless running
      (claude-code-ide-process--cancel-timer))))

(defun claude-code-ide-process--tick ()
  "Record the groups of all tracked instances, without a wait."
  (unless claude-code-ide-process--refresh-running
    (setq claude-code-ide-process--refresh-running t)
    (condition-case err
        (funcall claude-code-ide-process-list-async-function
                 (lambda (table)
                   (setq claude-code-ide-process--refresh-running nil)
                   (when table
                     (condition-case err
                         (claude-code-ide-process--record-all table)
                       (error (message "claude-code-ide-process: record failed: %s"
                                       (error-message-string err)))))))
      (error
       (setq claude-code-ide-process--refresh-running nil)
       (message "claude-code-ide-process: ps failed: %s" (error-message-string err))))))

(defun claude-code-ide-process--ensure-timer ()
  "Start the record timer when it does not run."
  (unless (timerp claude-code-ide-process--timer)
    (setq claude-code-ide-process--timer
          (run-with-timer claude-code-ide-process-track-interval
                          claude-code-ide-process-track-interval
                          #'claude-code-ide-process--tick))))

(defun claude-code-ide-process--cancel-timer ()
  "Stop the record timer."
  (when (timerp claude-code-ide-process--timer)
    (cancel-timer claude-code-ide-process--timer))
  (setq claude-code-ide-process--timer nil))

(defun claude-code-ide-process--new-track (instance process)
  "Return new records for INSTANCE, whose terminal process is PROCESS.
PROCESS nil means the process of the descriptor's buffer, else its PID."
  (let* ((process (or process
                      (let ((buffer (claude-code-ide-instance-buffer instance)))
                        (and (buffer-live-p buffer) (get-buffer-process buffer)))))
         (pid (or (claude-code-ide-process--process-pid process)
                  (claude-code-ide-known-or-nil (claude-code-ide-instance-pid instance))))
         (entry (and pid (funcall claude-code-ide-process-entry-function pid)))
         (known-start (claude-code-ide-known-or-nil
                       (claude-code-ide-instance-process-start-time instance))))
    (when pid
      (claude-code-ide-process--track-create
       :instance instance
       :process process
       :pid pid
       :start (or (plist-get entry :start)
                  (and (numberp known-start) known-start))))))

;;;###autoload
(defun claude-code-ide-process-track (instance process)
  "Start to record the descendant process groups of PROCESS for INSTANCE.
INSTANCE is a descriptor.  PROCESS is the terminal process of its CLI.
A timer records the groups every `claude-code-ide-process-track-interval'
seconds while the CLI runs, and each tool event of the instance adds a
record.  Return non-nil when the CLI has a process ID."
  (when-let* ((track (claude-code-ide-process--new-track instance process)))
    (puthash (claude-code-ide-instance-id instance) track
             claude-code-ide-process--tracks)
    (claude-code-ide-process--ensure-timer)
    (claude-code-ide-process--tick)
    (claude-code-ide-process--track-pid track)))

(defun claude-code-ide-process-untrack (instance)
  "Forget the records of INSTANCE, a descriptor or an instance ID."
  (remhash (claude-code-ide-process--instance-id instance)
           claude-code-ide-process--tracks)
  (when (= (hash-table-count claude-code-ide-process--tracks) 0)
    (claude-code-ide-process--cancel-timer)))

(defun claude-code-ide-process-refresh (instance)
  "Record the descendant groups of INSTANCE now, with a wait for ps.
Return the list of recorded groups, as `claude-code-ide-process-groups'."
  (when-let* ((track (claude-code-ide-process--track-of instance))
              (table (funcall claude-code-ide-process-list-function)))
    (when (claude-code-ide-process--root-alive-p track table)
      (claude-code-ide-process--record track table (float-time)))
    (claude-code-ide-process-groups instance)))

(defun claude-code-ide-process-groups (instance)
  "Return the recorded process groups of INSTANCE, by group ID.
Each one is a plist (:pgid :leader-start :first-seen :command)."
  (when-let* ((track (claude-code-ide-process--track-of instance)))
    (let (groups)
      (maphash (lambda (_pgid group) (push (copy-sequence group) groups))
               (claude-code-ide-process--track-groups track))
      (sort groups (lambda (a b) (< (plist-get a :pgid) (plist-get b :pgid)))))))

(defconst claude-code-ide-process--record-events
  '(prompt-submit tool-start tool-end turn-end subagent-start subagent-end)
  "Common events after which the records of the instance are updated.")

(defun claude-code-ide-process--note-event (event)
  "Update the records of the instance of EVENT, a common event.
At most one record per second; the record runs without a wait."
  (when-let* (((memq (plist-get event :event) claude-code-ide-process--record-events))
              (track (claude-code-ide-process--track-of (plist-get event :instance-id))))
    (let ((last (claude-code-ide-process--track-last-refresh track)))
      (when (or (null last) (> (- (float-time) last) 1))
        (claude-code-ide-process--tick)))))

(add-hook 'claude-code-ide-event-functions #'claude-code-ide-process--note-event)

;;; Stop

(defun claude-code-ide-process--wait (predicate seconds)
  "Wait up to SECONDS until PREDICATE returns non-nil; return its value.
Process output and sentinels run during the wait."
  (let ((deadline (+ (float-time) (max 0 seconds)))
        (value (funcall predicate)))
    (while (and (not value) (< (float-time) deadline))
      (accept-process-output nil (min 0.05 (max 0.001 (- deadline (float-time)))))
      (setq value (funcall predicate)))
    value))

(defun claude-code-ide-process--send (target signal)
  "Send SIGNAL to TARGET, a process ID or a negative group ID.
Return non-nil on success."
  (eql 0 (ignore-errors (funcall claude-code-ide-process-signal-function target signal))))

(defun claude-code-ide-process--soft-end-of (instance option)
  "Return the soft end for INSTANCE: OPTION, else the provider default."
  (or option
      (alist-get (claude-code-ide-instance-provider instance)
                 claude-code-ide-process-soft-end)
      'SIGHUP))

(defun claude-code-ide-process--signal-root (track signal)
  "Send SIGNAL to the process group of the root of TRACK.
When the root is not the leader of its own group, send SIGNAL to the
root only.  The root must still run with its recorded start time."
  (when-let* ((pid (claude-code-ide-process--track-pid track))
              (entry (claude-code-ide-process--entry-alive-p
                      pid (claude-code-ide-process--track-start track))))
    (let ((protected (claude-code-ide-process--emacs-protected
                      (list entry))))
      (unless (memq pid (car protected))
        (if (and (eql (plist-get entry :pgid) pid)
                 (not (memq pid (cdr protected))))
            (claude-code-ide-process--send (- pid) signal)
          (claude-code-ide-process--send pid signal))))))

(defun claude-code-ide-process--soft-end (track end)
  "Run the soft end END for TRACK: a signal, a function, or `none'."
  (cond
   ((eq end 'none) nil)
   ((functionp end)
    (condition-case err
        (funcall end (claude-code-ide-process--track-instance track)
                 (claude-code-ide-process--track-process track))
      (error (message "claude-code-ide-process: soft end failed: %s"
                      (error-message-string err)))))
   ((symbolp end)
    (claude-code-ide-process--signal-root track end))))

(defun claude-code-ide-process--ledger (tracks)
  "Return (GROUPS . MEMBERS), the union of the records of TRACKS.
GROUPS maps a group ID to its leader start time or t; MEMBERS maps a
process ID to its start time."
  (let ((groups (make-hash-table))
        (members (make-hash-table)))
    (dolist (track tracks)
      (maphash (lambda (pgid group)
                 (puthash pgid (or (plist-get group :leader-start) t) groups))
               (claude-code-ide-process--track-groups track))
      (maphash (lambda (pid start) (puthash pid start members))
               (claude-code-ide-process--track-members track)))
    (cons groups members)))

(defun claude-code-ide-process--classify (ledger table protected)
  "Return (VERIFIED . UNVERIFIED) for the recorded groups of LEDGER in TABLE.
VERIFIED is an alist (PGID . ENTRIES) of the groups that may get a
signal.  A group is verified when its live leader has the recorded
start time, or a live member is a recorded process with the same
start time.  UNVERIFIED lists the entries of the other live members of
recorded groups.  PROTECTED is (PIDS . PGIDS); a group with one of
them never gets a signal."
  (let ((by-group (make-hash-table))
        (groups (car ledger))
        (members (cdr ledger))
        (uid (user-uid))
        verified unverified)
    (dolist (entry table)
      (let ((pgid (plist-get entry :pgid)))
        (when (gethash pgid groups)
          (push entry (gethash pgid by-group)))))
    (maphash
     (lambda (pgid entries)
       (let* ((leader-start (gethash pgid groups))
              (safe (and (not (memq pgid (cdr protected)))
                         (cl-notany (lambda (e) (memq (plist-get e :pid) (car protected)))
                                    entries)
                         (cl-every (lambda (e) (eql (plist-get e :uid) uid)) entries)))
              (proven
               (cl-some
                (lambda (e)
                  (let ((pid (plist-get e :pid))
                        (start (plist-get e :start)))
                    (or (and (eql pid pgid) (numberp leader-start)
                             (claude-code-ide-process--same-start-p leader-start start))
                        (claude-code-ide-process--same-start-p
                         (gethash pid members) start))))
                entries)))
         (if (and safe proven)
             (push (cons pgid entries) verified)
           ;; Report them, but never Emacs or its ancestors
           (setq unverified
                 (append (cl-remove-if (lambda (e) (memq (plist-get e :pid) (car protected)))
                                       entries)
                         unverified)))))
     by-group)
    (cons verified unverified)))

(defun claude-code-ide-process--group-gone-p (entries)
  "Return non-nil when no process of ENTRIES runs any more."
  (cl-notany (lambda (e)
               (claude-code-ide-process--entry-alive-p (plist-get e :pid)
                                                       (plist-get e :start)))
             entries))

(defun claude-code-ide-process--reap (ledger protected kill-wait)
  "End the live groups of LEDGER: SIGTERM, then SIGKILL after KILL-WAIT.
Up to three rounds catch members that start during a round.
PROTECTED is as for `claude-code-ide-process--classify'.  Return a
plist (:ended PGIDS :survivors ENTRIES :unverified ENTRIES)."
  (let ((round 0) ended survivors unverified done)
    (while (and (not done) (< round 3))
      (setq round (1+ round))
      (let* ((table (funcall claude-code-ide-process-list-function))
             (classes (claude-code-ide-process--classify ledger table protected))
             (live (car classes)))
        (setq unverified (cdr classes))
        (if (null live)
            (setq done t survivors nil)
          ;; Live members of a verified group belong to it; remember
          ;; them, so the next round still verifies the group after its
          ;; recorded members are gone
          (dolist (group live)
            (dolist (entry (cdr group))
              (puthash (plist-get entry :pid) (plist-get entry :start) (cdr ledger))))
          (dolist (group live)
            (when (claude-code-ide-process--send (- (car group)) 'SIGTERM)
              (cl-pushnew (car group) ended)))
          (let ((left (lambda ()
                        (cl-remove-if (lambda (group)
                                        (claude-code-ide-process--group-gone-p (cdr group)))
                                      live))))
            (unless (claude-code-ide-process--wait
                     (lambda () (null (funcall left))) kill-wait)
              (dolist (group (funcall left))
                (claude-code-ide-process--send (- (car group)) 'SIGKILL))
              (claude-code-ide-process--wait
               (lambda () (null (funcall left))) (min kill-wait 1)))
            (setq survivors (cl-mapcan (lambda (group) (copy-sequence (cdr group)))
                                       (funcall left)))))))
    (when (and (not done) (= round 3))
      ;; The last round's survivors, as the table shows them now
      (let* ((table (funcall claude-code-ide-process-list-function))
             (classes (claude-code-ide-process--classify ledger table protected)))
        (setq survivors (cl-mapcan (lambda (group) (copy-sequence (cdr group)))
                                   (car classes))
              unverified (cdr classes))))
    (list :ended (nreverse ended) :survivors survivors :unverified unverified)))

(defun claude-code-ide-process--normal-dir (dir)
  "Return DIR as an absolute folder name, with the links resolved."
  (file-name-as-directory (file-truename (expand-file-name dir))))

(defun claude-code-ide-process--in-dir-p (file dirs)
  "Return non-nil when FILE is one of DIRS or inside one of them.
DIRS are folder names with a final slash."
  (let ((name (file-name-as-directory file)))
    (cl-some (lambda (dir) (string-prefix-p dir name)) dirs)))

(defun claude-code-ide-process--owner-tags (pid trees)
  "Return the plist part that names the owner of PID.
TREES maps a process ID to the instance ID whose CLI tree holds it."
  (let ((instance-id (gethash pid trees))
        (emacs-process (cl-find pid (process-list)
                                :key #'claude-code-ide-process--process-pid)))
    (append (when instance-id (list :instance-id instance-id))
            (when emacs-process (list :emacs-process (process-name emacs-process))))))

(defun claude-code-ide-process--instance-trees (table &optional except)
  "Return a hash table from process ID to instance ID, for the live CLIs.
It holds the tree in TABLE of each tracked instance whose CLI runs,
except the instance IDs in EXCEPT."
  (let ((trees (make-hash-table)))
    (maphash (lambda (id track)
               (unless (member id except)
                 (when (claude-code-ide-process--root-alive-p track table)
                   (dolist (entry (claude-code-ide-process--descendants
                                   table (claude-code-ide-process--track-pid track)))
                     (puthash (plist-get entry :pid) id trees)))))
             claude-code-ide-process--tracks)
    trees))

(defun claude-code-ide-process--strays-in (dirs cwds table trees exclude)
  "Return the stray plists of the processes of CWDS inside DIRS.
TABLE gives the group IDs, TREES the owner instances, and EXCLUDE
the process IDs to leave out.  Emacs itself is always left out."
  (let ((index (claude-code-ide-process--index table))
        strays)
    (dolist (item cwds)
      (let ((pid (plist-get item :pid)))
        (when (and (not (eql pid (emacs-pid)))
                   (not (memq pid exclude))
                   (stringp (plist-get item :cwd))
                   (claude-code-ide-process--in-dir-p (plist-get item :cwd) dirs))
          (let ((entry (gethash pid index)))
            (push (append (list :pid pid
                                :command (or (funcall claude-code-ide-process-command-function pid)
                                             (plist-get item :command))
                                :cwd (plist-get item :cwd)
                                :pgid (plist-get entry :pgid)
                                :ppid (plist-get entry :ppid)
                                :reason 'worktree)
                          (claude-code-ide-process--owner-tags pid trees))
                  strays)))))
    (sort strays (lambda (a b) (< (plist-get a :pid) (plist-get b :pid))))))

;;;###autoload
(defun claude-code-ide-process-worktree-strays (worktree &optional exclude)
  "Return the processes whose working folder is inside WORKTREE.
Each one is a plist (:pid :command :cwd :pgid :ppid :reason worktree).
A process of a running instance has :instance-id too, and a process
that Emacs runs has :emacs-process.  Emacs itself, and the process IDs
in EXCLUDE, are left out.  The function only reports; it never ends
a process."
  (when (and (stringp worktree) (file-directory-p worktree))
    (let* ((dirs (delete-dups
                  (list (claude-code-ide-process--normal-dir worktree)
                        (file-name-as-directory (expand-file-name worktree)))))
           (table (funcall claude-code-ide-process-list-function)))
      (claude-code-ide-process--strays-in
       dirs (funcall claude-code-ide-process-cwd-function) table
       (claude-code-ide-process--instance-trees table) exclude))))

(defun claude-code-ide-process--worktree-of (instance option)
  "Return the folder that a stop of INSTANCE scans, or nil.
OPTION, when it is a string, wins.  Else the worktree of the
descriptor, else its project root."
  (or (and (stringp option) option)
      (let ((worktree (claude-code-ide-known-or-nil
                       (claude-code-ide-instance-worktree instance))))
        (and (stringp worktree) worktree))
      (let ((root (claude-code-ide-known-or-nil
                   (claude-code-ide-instance-project-root instance))))
        (and (stringp root) root))))

(defun claude-code-ide-process--resolve (instance process)
  "Return the records of INSTANCE for a stop, with PROCESS when given.
INSTANCE is a descriptor or an instance ID.  Without records, make
new ones that only this stop uses.  Return nil when nothing is known."
  (let* ((track (claude-code-ide-process--track-of instance))
         (descriptor (cond ((claude-code-ide-instance-p instance) instance)
                           (track (claude-code-ide-process--track-instance track))
                           (t (claude-code-ide-instance-by-id instance)))))
    (cond
     ((and track process
           (not (eql (claude-code-ide-process--process-pid process)
                     (claude-code-ide-process--track-pid track))))
      ;; A new process of the same instance: start new records
      (claude-code-ide-process--new-track descriptor process))
     (track track)
     (descriptor (claude-code-ide-process--new-track descriptor process)))))

(defun claude-code-ide-process--stop-tracks (items options)
  "Stop the instances of ITEMS with OPTIONS, and return the results.
ITEMS is a list of (TRACK . WORKTREE).  OPTIONS is the plist of
`claude-code-ide-process-stop'.  Return a list of (TRACK . RESULT)."
  (let* ((timeout (or (plist-get options :timeout) claude-code-ide-process-stop-timeout))
         (kill-wait (or (plist-get options :kill-wait) claude-code-ide-process-kill-wait))
         (escalate (if (plist-member options :escalate) (plist-get options :escalate) t))
         (scan (if (plist-member options :scan) (plist-get options :scan) t))
         (exclude (plist-get options :exclude))
         (tracks (mapcar #'car items))
         (ids (mapcar (lambda (track)
                        (claude-code-ide-instance-id
                         (claude-code-ide-process--track-instance track)))
                      tracks))
         (table (funcall claude-code-ide-process-list-function))
         (now (float-time)))
    ;; 1. The last record, while the CLIs still run
    (dolist (track tracks)
      (when (claude-code-ide-process--root-alive-p track table)
        (claude-code-ide-process--record track table now)))
    ;; 2. The soft end of each provider
    (dolist (track tracks)
      (when (claude-code-ide-process--root-alive-p track)
        (claude-code-ide-process--soft-end
         track (claude-code-ide-process--soft-end-of
                (claude-code-ide-process--track-instance track)
                (plist-get options :soft-end)))))
    ;; 3. Wait for the CLIs to exit
    (let* ((running (lambda ()
                      (cl-remove-if-not #'claude-code-ide-process--root-alive-p tracks)))
           (escalated (make-hash-table :test 'eq)))
      (claude-code-ide-process--wait (lambda () (null (funcall running))) timeout)
      (when (and escalate (funcall running))
        (dolist (track (funcall running))
          (claude-code-ide-process--signal-root track 'SIGTERM)
          (puthash track 'SIGTERM escalated))
        (unless (claude-code-ide-process--wait (lambda () (null (funcall running)))
                                               kill-wait)
          (dolist (track (funcall running))
            (claude-code-ide-process--signal-root track 'SIGKILL)
            (puthash track 'SIGKILL escalated))
          (claude-code-ide-process--wait (lambda () (null (funcall running)))
                                         (min kill-wait 1))))
      (let* ((alive (funcall running))
             (done (cl-remove-if (lambda (track) (memq track alive)) tracks))
             ;; 4. End the recorded groups of the CLIs that are gone.  A
             ;; CLI that still runs keeps its groups: they are its work.
             (table (funcall claude-code-ide-process-list-function))
             (other-trees (claude-code-ide-process--instance-trees table ids))
             (protected (let ((p (claude-code-ide-process--emacs-protected table)))
                          ;; Never signal the tree of another running instance
                          (maphash (lambda (pid _id)
                                     (push pid (car p))
                                     (when-let* ((e (cl-find pid table :key (lambda (e) (plist-get e :pid)))))
                                       (push (plist-get e :pgid) (cdr p))))
                                   other-trees)
                          p))
             (reaped (claude-code-ide-process--reap
                      (claude-code-ide-process--ledger done) protected kill-wait))
             ;; 5. Scan the worktrees
             (cwds (when (and scan items) (funcall claude-code-ide-process-cwd-function)))
             (final (funcall claude-code-ide-process-list-function))
             (trees (claude-code-ide-process--instance-trees final ids))
             (leftover (append (plist-get reaped :survivors) (plist-get reaped :unverified))))
        (mapcar
         (lambda (item)
           (let* ((track (car item))
                  (worktree (cdr item))
                  (own-members (claude-code-ide-process--track-members track))
                  (own-groups (claude-code-ide-process--track-groups track))
                  (mine (lambda (entry)
                          (or (gethash (plist-get entry :pgid) own-groups)
                              (gethash (plist-get entry :pid) own-members))))
                  (root-alive (memq track alive))
                  (survivors (cl-remove-if-not mine (plist-get reaped :survivors)))
                  (unverified (cl-remove-if-not mine (plist-get reaped :unverified)))
                  (listed (append survivors unverified))
                  (strays
                   (append
                    (when root-alive
                      (list (list :pid (claude-code-ide-process--track-pid track)
                                  :command (funcall claude-code-ide-process-command-function
                                                    (claude-code-ide-process--track-pid track))
                                  :cwd nil :reason 'cli)))
                    (mapcar (lambda (e)
                              (list :pid (plist-get e :pid)
                                    :command (funcall claude-code-ide-process-command-function
                                                      (plist-get e :pid))
                                    :cwd nil
                                    :pgid (plist-get e :pgid)
                                    :ppid (plist-get e :ppid)
                                    :reason (if (memq e survivors) 'survivor 'unverified)))
                            listed)
                    (when (and scan worktree (file-directory-p worktree))
                      (claude-code-ide-process--strays-in
                       (delete-dups
                        (list (claude-code-ide-process--normal-dir worktree)
                              (file-name-as-directory (expand-file-name worktree))))
                       cwds final trees
                       (append exclude
                               (mapcar (lambda (e) (plist-get e :pid)) leftover)
                               (list (claude-code-ide-process--track-pid track)))))))
                  (status (cond ((or root-alive survivors) 'timeout)
                                (strays 'strays)
                                (t 'stopped))))
             ;; Fill in the working folders of the processes found by the records
             (let ((missing (cl-remove-if (lambda (s) (plist-get s :cwd)) strays)))
               (when missing
                 (let ((found (funcall claude-code-ide-process-cwd-function
                                       (mapcar (lambda (s) (plist-get s :pid)) missing))))
                   (dolist (stray missing)
                     (when-let* ((item (cl-find (plist-get stray :pid) found
                                                :key (lambda (i) (plist-get i :pid)))))
                       (plist-put stray :cwd (plist-get item :cwd)))))))
             (cons track
                   (list :status status
                         :strays strays
                         :ended (cl-remove-if-not
                                 (lambda (pgid) (gethash pgid own-groups))
                                 (plist-get reaped :ended))
                         :escalated (gethash track escalated)))))
         items)))))

(defun claude-code-ide-process--finish (track result)
  "Forget TRACK after its stop RESULT, unless its CLI or groups survive.
When they survive, keep TRACK, so that a later stop can end them."
  (let ((id (claude-code-ide-instance-id (claude-code-ide-process--track-instance track))))
    (if (eq (plist-get result :status) 'timeout)
        (puthash id track claude-code-ide-process--tracks)
      (when (eq (gethash id claude-code-ide-process--tracks) track)
        (claude-code-ide-process-untrack id)))))

(defun claude-code-ide-process--empty-result ()
  "Return the stop result for an instance without a known process."
  (list :status 'stopped :strays nil :ended nil :escalated nil))

;;;###autoload
(defun claude-code-ide-process-stop (instance &rest args)
  "End the CLI of INSTANCE and its background work, and report what is left.
INSTANCE is a descriptor or an instance ID.  The steps:

1. Record the descendant process groups of the CLI one last time.
2. Send the soft end of the provider (`claude-code-ide-process-soft-end').
3. Wait up to the timeout for the CLI to exit.  Then send SIGTERM
   to its process group, and SIGKILL after the kill wait.
4. End the recorded process groups that still run: SIGTERM, then
   SIGKILL after the kill wait.  Only groups whose recorded processes
   prove that they are the same groups get a signal.
5. List the other processes whose working folder is in the worktree.

ARGS is a plist:

- :timeout   seconds for step 3 (`claude-code-ide-process-stop-timeout').
- :kill-wait seconds between the signals (`claude-code-ide-process-kill-wait').
- :soft-end  a signal, a function of (INSTANCE PROCESS), or `none' (the
             caller already did the soft end).  Default: the provider's.
- :escalate  nil to skip SIGTERM and SIGKILL of the CLI in step 3.
- :scan      nil to skip step 5.
- :worktree  the folder for step 5 (default: the descriptor's worktree,
             else its project root).
- :process   the terminal process (default: the one of the buffer).
- :exclude   process IDs that step 5 leaves out.

Return a plist:

- :status   `stopped' (nothing is left), `strays' (only step 5 found
            processes), or `timeout' (the CLI or a recorded process
            survived SIGKILL, or the CLI did not exit without :escalate).
- :strays   plists (:pid :command :cwd :reason ...).  :reason is `cli',
            `survivor', `unverified' (in a recorded group, but not proven
            to be the same group, so it got no signal) or `worktree'.
- :ended    the group IDs that got a signal in step 4.
- :escalated nil, SIGTERM or SIGKILL: the last signal of step 3.

Stray processes are only reported, never ended.  The call waits, so
do not call it from `kill-buffer-hook'; use
`claude-code-ide-process-stop-later' there."
  (if-let* ((track (claude-code-ide-process--resolve instance (plist-get args :process))))
      (let* ((worktree (claude-code-ide-process--worktree-of
                        (claude-code-ide-process--track-instance track)
                        (plist-get args :worktree)))
             (result (cdar (claude-code-ide-process--stop-tracks
                            (list (cons track worktree)) args))))
        (claude-code-ide-process--finish track result)
        result)
    (claude-code-ide-process--empty-result)))

(defun claude-code-ide-process-stop-many (instances &rest args)
  "Stop each of INSTANCES at the same time, with one shared wait.
INSTANCES are descriptors or instance IDs.  ARGS are the keys of
`claude-code-ide-process-stop', except :process and :worktree (each
instance uses its own).  Return an alist (INSTANCE-ID . RESULT).
`kill-emacs-hook' uses it with a short :timeout and :scan nil."
  (let* ((tracks (mapcar (lambda (instance)
                           (claude-code-ide-process--resolve instance nil))
                         instances))
         (items (mapcar (lambda (track)
                          (cons track (claude-code-ide-process--worktree-of
                                       (claude-code-ide-process--track-instance track) nil)))
                        (delq nil (copy-sequence tracks))))
         (stopped (when items
                    (claude-code-ide-process--stop-tracks items args))))
    (dolist (pair stopped)
      (claude-code-ide-process--finish (car pair) (cdr pair)))
    (cl-mapcar (lambda (instance track)
                 (cons (claude-code-ide-process--instance-id instance)
                       (if track
                           (cdr (assq track stopped))
                         (claude-code-ide-process--empty-result))))
               instances tracks)))

(defun claude-code-ide-process-stop-later (instance &rest args)
  "Record the groups of INSTANCE now, and stop it from a timer.
For `kill-buffer-hook': the buffer kill itself sends SIGHUP to the CLI
after the hook, so :soft-end defaults to `none' here.  ARGS are as
for `claude-code-ide-process-stop'.  Return the timer."
  (let ((track (claude-code-ide-process--resolve instance (plist-get args :process))))
    (when track
      ;; The record must exist after a buffer kill, also for a CLI that
      ;; was never tracked; keep it under its instance ID
      (puthash (claude-code-ide-instance-id (claude-code-ide-process--track-instance track))
               track claude-code-ide-process--tracks)
      (ignore-errors
        (when-let* ((table (funcall claude-code-ide-process-list-function)))
          (when (claude-code-ide-process--root-alive-p track table)
            (claude-code-ide-process--record track table (float-time))))))
    (let ((args (if (plist-member args :soft-end) args
                  (append (list :soft-end 'none) args))))
      (run-at-time 0 nil
                   (lambda ()
                     (condition-case err
                         (apply #'claude-code-ide-process-stop instance args)
                       (error (message "claude-code-ide-process: stop failed: %s"
                                       (error-message-string err)))))))))

(provide 'claude-code-ide-process)

;;; claude-code-ide-process.el ends here
