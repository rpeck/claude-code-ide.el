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
(require 'claude-code-ide-debug)

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

(defcustom claude-code-ide-process-lsof-timeout 30
  "Seconds that the scan of working folders may take.
lsof takes about 0.6 seconds on an idle Mac, and 20 to 30 seconds
under heavy load.  After this time the scan stops, and the stop
reports the status `error'."
  :type 'number
  :group 'claude-code-ide-process)

(defconst claude-code-ide-process--ps-timeout 10
  "Seconds that one ps run may take.")

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
this user) and returns a list of plists (:pid :cwd :command), or the
symbol `failed' when it cannot tell.")

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

(defun claude-code-ide-process--run (program args timeout &optional any-exit)
  "Run PROGRAM with ARGS in the folder /, and return its output, or nil.
Wait up to TIMEOUT seconds; after that, end PROGRAM (a child of this
Emacs) and return nil.  A non-zero exit gives nil, unless ANY-EXIT.
Process output and sentinels run during the wait."
  (let* ((default-directory "/")
         (process-environment (cons "LC_ALL=C" process-environment))
         (output (generate-new-buffer " *claude-code-ide-run*"))
         (errors (generate-new-buffer " *claude-code-ide-run-errors*"))
         (finished nil)
         (process (ignore-errors
                    (make-process :name "claude-code-ide-run"
                                  :buffer output
                                  :command (cons program args)
                                  :connection-type 'pipe
                                  :noquery t
                                  :stderr errors
                                  ;; The sentinel runs after the last output
                                  :sentinel (lambda (_process _event)
                                              (setq finished t))))))
    (unwind-protect
        (when process
          (when-let* ((pipe (get-buffer-process errors)))
            (set-process-query-on-exit-flag pipe nil))
          (claude-code-ide-process--wait (lambda () finished) timeout)
          (if (process-live-p process)
              (progn (delete-process process) nil)
            (when (and (eq (process-status process) 'exit)
                       (or any-exit (eql 0 (process-exit-status process))))
              (with-current-buffer output (buffer-string)))))
      (dolist (buffer (list output errors))
        (when (buffer-live-p buffer)
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buffer)))))))

(defun claude-code-ide-process--ps-list ()
  "Return the entries of all processes from ps, or nil when ps fails."
  (when-let* ((text (claude-code-ide-process--run
                     claude-code-ide-process-ps-program (claude-code-ide-process--ps-args)
                     claude-code-ide-process--ps-timeout)))
    (claude-code-ide-process--parse-ps text)))

(defun claude-code-ide-process--ps-list-async (callback)
  "Run ps without a wait, and call CALLBACK with the entries.
CALLBACK gets nil when ps fails.  The output and the error output go
to hidden buffers that the sentinel kills."
  (let* ((default-directory "/")
         (process-environment (cons "LC_ALL=C" process-environment))
         (buffer (generate-new-buffer " *claude-code-ide-ps*"))
         (errors (generate-new-buffer " *claude-code-ide-ps-errors*"))
         (cleanup (lambda ()
                    (dolist (b (list buffer errors))
                      (when (buffer-live-p b)
                        (let ((kill-buffer-query-functions nil))
                          (kill-buffer b)))))))
    (condition-case nil
        (progn
          (make-process
           :name "claude-code-ide-ps"
           :buffer buffer
           :command (cons claude-code-ide-process-ps-program
                          (claude-code-ide-process--ps-args))
           :connection-type 'pipe
           :noquery t
           :stderr errors
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (let ((entries (and (eq (process-status process) 'exit)
                                   (eql 0 (process-exit-status process))
                                   (buffer-live-p buffer)
                                   (with-current-buffer buffer
                                     (claude-code-ide-process--parse-ps (buffer-string))))))
                 (funcall cleanup)
                 (funcall callback entries)))))
          ;; The error output has its own pipe process; it must not ask
          ;; at the kill of its buffer
          (when-let* ((pipe (get-buffer-process errors)))
            (set-process-query-on-exit-flag pipe nil)))
      (error
       (funcall cleanup)
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
that it is never in a worktree itself.  Return the symbol `failed'
when lsof cannot run, or takes more than
`claude-code-ide-process-lsof-timeout' seconds.  lsof exits with 1
when a process of PIDS is gone, so its exit status does not count."
  (let ((text (claude-code-ide-process--run
               claude-code-ide-process-lsof-program
               (append (list "-n" "-P" "-w" "-a" "-d" "cwd" "-Fpcn")
                       (if pids
                           (list "-p" (mapconcat #'number-to-string pids ","))
                         (list "-u" (number-to-string (user-uid)))))
               claude-code-ide-process-lsof-timeout t)))
    (if text
        (claude-code-ide-process--parse-lsof text)
      'failed)))

(defun claude-code-ide-process--entry-alive-p (pid start)
  "Return the entry of PID when it runs and its start time is START.
START nil means that the process cannot be verified: the result is
then nil, so that it never gets a signal."
  (when-let* ((entry (and (integerp pid) (numberp start)
                          (funcall claude-code-ide-process-entry-function pid))))
    (when (claude-code-ide-process--same-start-p start (plist-get entry :start))
      entry)))

(defun claude-code-ide-process--still-there-p (pid start pgid)
  "Return non-nil when PID may still be the process that started at START.
It must also still be in the process group PGID.  Only for the end of
a wait: a nil start time on either side counts as the same, so that a
wait never ends too early.  No choice of a signal target may use it;
those use `claude-code-ide-process--classify', where nil never matches."
  (when-let* ((entry (and (integerp pid)
                          (funcall claude-code-ide-process-entry-function pid))))
    (and (eql (plist-get entry :pgid) pgid)
         (or (null start) (null (plist-get entry :start))
             (claude-code-ide-process--same-start-p start (plist-get entry :start))))))

;;; Snapshots
;;
;; A snapshot is the table of one ps run with the indexes that the
;; records and the stop need, built once: a plist (:table :index
;; :children :protected).  :protected is (PIDS . PGIDS) that never get
;; a signal: 0, 1, Emacs and all its ancestors, and their groups.

(defun claude-code-ide-process--emacs-protected (index)
  "Return (PIDS . PGIDS) of 0, 1, Emacs, its ancestors, and their groups.
INDEX maps a process ID to its entry.  A process that INDEX does not
hold is asked for with `claude-code-ide-process-entry-function'."
  (let ((pids (list 0 1))
        (pgids (list 0 1))
        (pid (emacs-pid))
        (guard 0))
    (while (and (integerp pid) (> pid 1) (< guard 200))
      (setq guard (1+ guard))
      (push pid pids)
      (let ((entry (or (and index (gethash pid index))
                       (funcall claude-code-ide-process-entry-function pid))))
        (when-let* ((pgid (plist-get entry :pgid)))
          (push pgid pgids))
        (setq pid (plist-get entry :ppid))))
    (cons (delete-dups pids) (delete-dups pgids))))

(defun claude-code-ide-process--snapshot (table)
  "Return the snapshot of TABLE, a list of entries."
  (let ((index (make-hash-table))
        (children (make-hash-table)))
    (dolist (entry table)
      (puthash (plist-get entry :pid) entry index)
      (push entry (gethash (plist-get entry :ppid) children)))
    (list :table table :index index :children children
          :protected (claude-code-ide-process--emacs-protected index))))

(defun claude-code-ide-process--entry-of (snapshot pid)
  "Return the entry of PID in SNAPSHOT, or nil."
  (gethash pid (plist-get snapshot :index)))

(defun claude-code-ide-process--descendant-start-p (start root-start)
  "Return non-nil when START can be the start time of a descendant.
ROOT-START is the start time of the root.  A real descendant never
starts before the root, so START must be known and not earlier than
ROOT-START minus the tolerance of `claude-code-ide-process--same-start-p'."
  (and (numberp start) (numberp root-start)
       (>= start (- root-start 1.5))))

(defun claude-code-ide-process--descendants (snapshot root)
  "Return the entries of ROOT and of all its descendants in SNAPSHOT.
ROOT is a process ID.  The result is empty when ROOT is not in SNAPSHOT,
or when its start time is unknown.

A process that started before ROOT, or whose start time is unknown,
is not a descendant, and the walk does not go through it.  On macOS a
debugger that attaches to a process becomes its parent: after `lldb
-p X' in the CLI's tree, ps shows X, and all its children, under the
CLI.  X can be any process, also Emacs itself."
  (let ((children (plist-get snapshot :children))
        (seen (make-hash-table))
        result queue)
    (when-let* ((root-entry (claude-code-ide-process--entry-of snapshot root))
                (root-start (plist-get root-entry :start)))
      (setq queue (list root-entry))
      (while queue
        (let ((entry (pop queue)))
          ;; A ppid loop cannot happen, but a broken table must not hang
          (unless (gethash (plist-get entry :pid) seen)
            (puthash (plist-get entry :pid) t seen)
            (push entry result)
            (setq queue (append queue
                                (cl-remove-if-not
                                 (lambda (child)
                                   (claude-code-ide-process--descendant-start-p
                                    (plist-get child :start) root-start))
                                 (gethash (plist-get entry :pid) children))))))))
    (nreverse result)))

;;; Records

(cl-defstruct (claude-code-ide-process--track
               (:constructor claude-code-ide-process--track-create)
               (:copier nil))
  "The process records of one instance."
  (instance nil :documentation "The descriptor.")
  (process nil :documentation "The process object of the terminal, or nil.")
  (pid nil :documentation "Process ID of the CLI (the root of the tree).")
  (start nil :documentation "Start time of the root as a float, or nil when it cannot be verified.")
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

(defun claude-code-ide-process--track-id (track)
  "Return the instance ID of TRACK."
  (claude-code-ide-instance-id (claude-code-ide-process--track-instance track)))

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

(defun claude-code-ide-process--root-alive-p (track &optional snapshot)
  "Return non-nil when the root of TRACK still runs with its start time.
With SNAPSHOT, look there; else ask for the one process.  A root
without a known start time cannot be verified and counts as gone."
  (let ((pid (claude-code-ide-process--track-pid track))
        (start (claude-code-ide-process--track-start track)))
    (and (numberp start)
         (if snapshot
             (when-let* ((entry (claude-code-ide-process--entry-of snapshot pid)))
               (claude-code-ide-process--same-start-p start (plist-get entry :start)))
           (claude-code-ide-process--entry-alive-p pid start)))))

(defun claude-code-ide-process--record (track snapshot now)
  "Add the descendants of the root of TRACK in SNAPSHOT to its records.
Drop the records of processes that are gone.  NOW is the time.  The
caller checks that the root runs with its recorded start time."
  (let* ((index (plist-get snapshot :index))
         (members (claude-code-ide-process--track-members track))
         (groups (claude-code-ide-process--track-groups track))
         (protected (cdr (plist-get snapshot :protected))))
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
      (dolist (entry (plist-get snapshot :table))
        (puthash (plist-get entry :pgid) t live-pgids))
      (maphash (lambda (pgid _group)
                 (unless (gethash pgid live-pgids)
                   (remhash pgid groups)))
               groups))
    (dolist (entry (claude-code-ide-process--descendants
                    snapshot (claude-code-ide-process--track-pid track)))
      (let ((pid (plist-get entry :pid))
            (pgid (plist-get entry :pgid))
            (start (plist-get entry :start)))
        ;; A process without a start time cannot be verified later
        (when (numberp start)
          (puthash pid start members))
        (unless (memq pgid protected)
          (let ((group (or (gethash pgid groups)
                           (list :pgid pgid :leader-start nil :first-seen now
                                 :command nil))))
            (when (and (eql pid pgid) (numberp start)
                       (null (plist-get group :leader-start)))
              (setq group (plist-put group :leader-start start))
              (setq group (plist-put group :command
                                     (funcall claude-code-ide-process-command-function
                                              pid))))
            (puthash pgid group groups)))))
    (setf (claude-code-ide-process--track-last-refresh track) now)
    track))

(defun claude-code-ide-process--record-if-alive (track snapshot now)
  "Record SNAPSHOT in TRACK when its root runs there.  Return non-nil then."
  (when (claude-code-ide-process--root-alive-p track snapshot)
    (claude-code-ide-process--record track snapshot now)
    t))

(defun claude-code-ide-process--record-all (table)
  "Record TABLE in each track whose root still runs.
Stop the timer only when no root of the current tracks runs now: a
track that was added after this ps run started is not in TABLE."
  (let ((snapshot (claude-code-ide-process--snapshot table))
        (now (float-time))
        (running nil))
    (maphash (lambda (_id track)
               (when (claude-code-ide-process--record-if-alive track snapshot now)
                 (setq running t)))
             claude-code-ide-process--tracks)
    (unless (or running
                (let (live)
                  (maphash (lambda (_id track)
                             (when (claude-code-ide-process--root-alive-p track)
                               (setq live t)))
                           claude-code-ide-process--tracks)
                  live))
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

(defun claude-code-ide-process--accept-process (instance process)
  "Return PROCESS when it belongs to INSTANCE, else nil.
PROCESS belongs to INSTANCE when it is the process of the instance's
terminal buffer, or when its PID is the PID in the descriptor.  Any
other process, also a live child of this Emacs, is ignored with a
debug message: it must never become the root of the records."
  (when process
    (let ((buffer (claude-code-ide-instance-buffer instance))
          (pid (claude-code-ide-process--process-pid process))
          (known-pid (claude-code-ide-known-or-nil (claude-code-ide-instance-pid instance))))
      (if (or (and (buffer-live-p buffer)
                   (or (eq (get-buffer-process buffer) process)
                       (eq (process-buffer process) buffer)))
              (and (integerp pid) (eql pid known-pid)))
          process
        (claude-code-ide-debug "Process tree: ignore process %s (PID %s) for instance %s: not its process"
                               (and (processp process) (process-name process)) pid
                               (claude-code-ide-instance-id instance))
        nil))))

(defun claude-code-ide-process--new-track (instance process)
  "Return new records for INSTANCE, whose terminal process is PROCESS.
PROCESS nil means the process of the descriptor's buffer, else its PID.
A PROCESS that does not belong to INSTANCE is ignored; see
`claude-code-ide-process--accept-process'.

The start time of the root comes from a record made at launch: the
descriptor, when it holds the same PID.  A live entry gives it only
when PROCESS is the real child: a live process object of this Emacs
whose own process ID is that PID.  Emacs has not reaped such a child,
so the PID cannot belong to another process.  A ghostel pipe is not
the real child: ghostel's native thread reaps the child before the
pipe closes, so a lookup of its PID can find an unrelated process.
Else the start time stays nil, and the root never gets a signal."
  (let* ((process (or (claude-code-ide-process--accept-process instance process)
                      (let ((buffer (claude-code-ide-instance-buffer instance)))
                        (and (buffer-live-p buffer) (get-buffer-process buffer)))))
         (process-pid (claude-code-ide-process--process-pid process))
         (known-pid (claude-code-ide-known-or-nil (claude-code-ide-instance-pid instance)))
         (pid (or process-pid known-pid))
         (known-start (claude-code-ide-known-or-nil
                       (claude-code-ide-instance-process-start-time instance))))
    (when (integerp pid)
      (claude-code-ide-process--track-create
       :instance instance
       :process process
       :pid pid
       :start (cond
               ((and (numberp known-start) (eql known-pid pid)) known-start)
               ((and (processp process)
                     (eql (process-id process) pid)
                     (process-live-p process))
                (plist-get (funcall claude-code-ide-process-entry-function pid) :start)))))))

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
    (claude-code-ide-process--record-if-alive
     track (claude-code-ide-process--snapshot table) (float-time))
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

;;; Signals

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

(defun claude-code-ide-process--signal-root (track signal snapshot)
  "Send SIGNAL to the process group of the root of TRACK.
The root must run with its recorded start time.  SNAPSHOT is a fresh
snapshot; its :protected set and its table decide:

- A protected root gets nothing.
- The root gets SIGNAL alone, never its group, when it is not the
  leader of its group, when its group is protected, when a member of
  its group has another (effective) user ID, for example a child that
  runs sudo, or when SNAPSHOT has no table to check the group."
  (when-let* ((pid (claude-code-ide-process--track-pid track))
              (entry (claude-code-ide-process--entry-alive-p
                      pid (claude-code-ide-process--track-start track))))
    (let ((protected (plist-get snapshot :protected))
          (uid (user-uid)))
      (unless (memq pid (car protected))
        (if (and (eql (plist-get entry :pgid) pid)
                 (not (memq pid (cdr protected)))
                 ;; Without a table the group cannot be checked
                 (plist-get snapshot :table)
                 (cl-every (lambda (e)
                             (or (not (eql (plist-get e :pgid) pid))
                                 (eql (plist-get e :uid) uid)))
                           (plist-get snapshot :table)))
            (claude-code-ide-process--send (- pid) signal)
          (claude-code-ide-process--send pid signal))))))

(defun claude-code-ide-process--soft-end (track end snapshot)
  "Run the soft end END for TRACK: a signal, a function, or `none'.
SNAPSHOT is as for `claude-code-ide-process--signal-root'."
  (cond
   ((eq end 'none) nil)
   ((functionp end)
    (condition-case err
        (funcall end (claude-code-ide-process--track-instance track)
                 (claude-code-ide-process--track-process track))
      (error (message "claude-code-ide-process: soft end failed: %s"
                      (error-message-string err)))))
   ((symbolp end)
    (claude-code-ide-process--signal-root track end snapshot))))

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
them never gets a signal, and protected processes are not listed."
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
           (setq unverified
                 (append (cl-remove-if (lambda (e) (memq (plist-get e :pid) (car protected)))
                                       entries)
                         unverified)))))
     by-group)
    (cons verified unverified)))

(defun claude-code-ide-process--groups-left (groups)
  "Return the groups of GROUPS, an alist (PGID . ENTRIES), that may still run.
Only for the end of a wait; see `claude-code-ide-process--still-there-p'."
  (cl-remove-if-not (lambda (group)
                      (cl-some (lambda (e)
                                 (claude-code-ide-process--still-there-p
                                  (plist-get e :pid) (plist-get e :start) (car group)))
                               (cdr group)))
                    groups))

;;; Worktree scan

(defun claude-code-ide-process--normal-dir (dir)
  "Return DIR as an absolute folder name, with the links resolved."
  (file-name-as-directory (file-truename (expand-file-name dir))))

(defun claude-code-ide-process--dirs-of (worktree)
  "Return the folder names that match WORKTREE, with a final slash."
  (delete-dups (list (claude-code-ide-process--normal-dir worktree)
                     (file-name-as-directory (expand-file-name worktree)))))

(defun claude-code-ide-process--in-dir-p (file dirs)
  "Return non-nil when FILE is one of DIRS or inside one of them.
DIRS are folder names with a final slash."
  (let ((name (file-name-as-directory file)))
    (cl-some (lambda (dir) (string-prefix-p dir name)) dirs)))

(defun claude-code-ide-process--owner-tags (pid trees emacs-pids)
  "Return the plist part that names the owner of PID.
TREES maps a process ID to the instance ID whose CLI tree holds it.
EMACS-PIDS maps a process ID to the name of an Emacs process object."
  (let ((instance-id (gethash pid trees))
        (emacs-process (gethash pid emacs-pids)))
    (append (when instance-id (list :instance-id instance-id))
            (when emacs-process (list :emacs-process emacs-process)))))

(defun claude-code-ide-process--emacs-pids ()
  "Return a hash table from process ID to name, for the processes of Emacs."
  (let ((table (make-hash-table)))
    (dolist (process (process-list))
      (when-let* ((pid (claude-code-ide-process--process-pid process)))
        (puthash pid (process-name process) table)))
    table))

(defun claude-code-ide-process--instance-trees (snapshot &optional except)
  "Return a hash table from process ID to instance ID, for the live CLIs.
It holds the tree in SNAPSHOT of each tracked instance whose CLI runs,
except the instance IDs in EXCEPT."
  (let ((trees (make-hash-table)))
    (maphash (lambda (id track)
               (unless (member id except)
                 (when (claude-code-ide-process--root-alive-p track snapshot)
                   (dolist (entry (claude-code-ide-process--descendants
                                   snapshot (claude-code-ide-process--track-pid track)))
                     (puthash (plist-get entry :pid) id trees)))))
             claude-code-ide-process--tracks)
    trees))

(defun claude-code-ide-process--strays-in (dirs cwds snapshot trees exclude)
  "Return the stray plists of the processes of CWDS inside DIRS.
SNAPSHOT gives the group IDs, TREES the owner instances, and EXCLUDE
the process IDs to leave out.  Emacs itself is always left out."
  (let ((emacs-pids (claude-code-ide-process--emacs-pids))
        strays)
    (dolist (item cwds)
      (let ((pid (plist-get item :pid)))
        (when (and (not (eql pid (emacs-pid)))
                   (not (memq pid exclude))
                   (stringp (plist-get item :cwd))
                   (claude-code-ide-process--in-dir-p (plist-get item :cwd) dirs))
          (let ((entry (claude-code-ide-process--entry-of snapshot pid)))
            (push (append (list :pid pid
                                :command (or (funcall claude-code-ide-process-command-function pid)
                                             (plist-get item :command))
                                :cwd (plist-get item :cwd)
                                :pgid (plist-get entry :pgid)
                                :ppid (plist-get entry :ppid)
                                :reason 'worktree)
                          (claude-code-ide-process--owner-tags pid trees emacs-pids))
                  strays)))))
    (sort strays (lambda (a b) (< (plist-get a :pid) (plist-get b :pid))))))

;;;###autoload
(defun claude-code-ide-process-worktree-strays (worktree &optional exclude)
  "Return the processes whose working folder is inside WORKTREE.
Each one is a plist (:pid :command :cwd :pgid :ppid :reason worktree).
A process of a running instance has :instance-id too, and a process
that Emacs runs has :emacs-process.  Emacs itself, and the process IDs
in EXCLUDE, are left out.  The function only reports; it never ends
a process.

Signal an error when the scan fails (lsof cannot run or takes too
long): an empty list would claim that nothing runs there."
  (when (and (stringp worktree) (file-directory-p worktree))
    (let ((snapshot (claude-code-ide-process--snapshot
                     (funcall claude-code-ide-process-list-function)))
          (cwds (funcall claude-code-ide-process-cwd-function)))
      (when (eq cwds 'failed)
        (error "The scan of working folders failed (lsof)"))
      (claude-code-ide-process--strays-in
       (claude-code-ide-process--dirs-of worktree)
       cwds snapshot
       (claude-code-ide-process--instance-trees snapshot) exclude))))

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

;;; Stop
;;
;; A stop is a job: a chain of steps.  Each step returns either
;; (:wait PREDICATE SECONDS NEXT), to wait until PREDICATE is non-nil
;; or SECONDS pass and then run the step NEXT, or (:done RESULTS).
;; `claude-code-ide-process-stop' runs the chain with waits;
;; `claude-code-ide-process-stop-later' runs it from timers, so the
;; command loop runs between the steps.

(cl-defstruct (claude-code-ide-process--job
               (:constructor claude-code-ide-process--job-create)
               (:copier nil))
  "The state of one stop of one or more instances."
  items options timeout kill-wait escalate scan exclude deadline
  snapshot escalated alive done ledger protected round ended
  live survivors unverified)

(defun claude-code-ide-process--job-tracks (job)
  "Return the tracks of JOB."
  (mapcar #'car (claude-code-ide-process--job-items job)))

(defun claude-code-ide-process--cap (job seconds)
  "Return SECONDS, cut to the time that is left before the deadline of JOB."
  (let ((deadline (claude-code-ide-process--job-deadline job)))
    (max 0 (if deadline (min seconds (- deadline (float-time))) seconds))))

(defun claude-code-ide-process--time-left-p (job)
  "Return non-nil when JOB has no deadline or has time left before it."
  (let ((deadline (claude-code-ide-process--job-deadline job)))
    (or (null deadline) (< (float-time) deadline))))

(defun claude-code-ide-process--running (job)
  "Return the tracks of JOB whose CLI still runs."
  (cl-remove-if-not #'claude-code-ide-process--root-alive-p
                    (claude-code-ide-process--job-tracks job)))

(defun claude-code-ide-process--error-done (job reason)
  "Return the step that ends JOB with the status `error' and REASON.
The records stay, so that a later stop can use them."
  (list :done
        (mapcar (lambda (item)
                  (cons (car item)
                        (list :status 'error :reason reason :strays nil
                              :ended (cl-remove-if-not
                                      (lambda (pgid)
                                        (gethash pgid (claude-code-ide-process--track-groups
                                                       (car item))))
                                      (claude-code-ide-process--job-ended job))
                              :escalated (and (claude-code-ide-process--job-escalated job)
                                              (gethash (car item)
                                                       (claude-code-ide-process--job-escalated job))))))
                (claude-code-ide-process--job-items job))))

(defun claude-code-ide-process--step-start (job)
  "Step 1 and 2 of JOB: the last record, and the soft end of each CLI."
  (let ((table (funcall claude-code-ide-process-list-function))
        (now (float-time)))
    (if (null table)
        (claude-code-ide-process--error-done job "ps failed: no process table")
      (let ((snapshot (claude-code-ide-process--snapshot table)))
        (setf (claude-code-ide-process--job-snapshot job) snapshot
              (claude-code-ide-process--job-escalated job) (make-hash-table :test 'eq))
        (dolist (track (claude-code-ide-process--job-tracks job))
          (when (claude-code-ide-process--record-if-alive track snapshot now)
            (claude-code-ide-process--soft-end
             track (claude-code-ide-process--soft-end-of
                    (claude-code-ide-process--track-instance track)
                    (plist-get (claude-code-ide-process--job-options job) :soft-end))
             snapshot)))
        (list :wait (lambda () (null (claude-code-ide-process--running job)))
              (claude-code-ide-process--job-timeout job)
              #'claude-code-ide-process--step-term)))))

(defun claude-code-ide-process--escalate (job signal)
  "Send SIGNAL to each CLI of JOB that still runs; return those CLIs.
A fresh table shows the members of each CLI's group now.  When ps
fails, the snapshot of step 1 gives the protected set, and each CLI
gets SIGNAL alone, because its group cannot be checked."
  (let* ((running (claude-code-ide-process--running job))
         (table (and running (funcall claude-code-ide-process-list-function)))
         (snapshot (if table
                       (claude-code-ide-process--snapshot table)
                     (list :table nil
                           :protected (plist-get (claude-code-ide-process--job-snapshot job)
                                                 :protected)))))
    (dolist (track running)
      (claude-code-ide-process--signal-root track signal snapshot)
      (puthash track signal (claude-code-ide-process--job-escalated job)))
    running))

(defun claude-code-ide-process--step-term (job)
  "Step 3a of JOB: SIGTERM to the CLIs that still run."
  (if (and (claude-code-ide-process--job-escalate job)
           (claude-code-ide-process--escalate job 'SIGTERM))
      (list :wait (lambda () (null (claude-code-ide-process--running job)))
            (claude-code-ide-process--job-kill-wait job)
            #'claude-code-ide-process--step-kill)
    (claude-code-ide-process--step-reap-start job)))

(defun claude-code-ide-process--step-kill (job)
  "Step 3b of JOB: SIGKILL to the CLIs that still run."
  (if (claude-code-ide-process--escalate job 'SIGKILL)
      (list :wait (lambda () (null (claude-code-ide-process--running job)))
            (min (claude-code-ide-process--job-kill-wait job) 1)
            #'claude-code-ide-process--step-reap-start)
    (claude-code-ide-process--step-reap-start job)))

(defun claude-code-ide-process--step-reap-start (job)
  "Step 4 of JOB: get ready to end the groups of the CLIs that are gone.
A CLI that still runs keeps its groups: they are its work."
  (let* ((alive (claude-code-ide-process--running job))
         (done (cl-remove-if (lambda (track) (memq track alive))
                             (claude-code-ide-process--job-tracks job)))
         (table (funcall claude-code-ide-process-list-function)))
    (if (null table)
        (claude-code-ide-process--error-done job "ps failed: no process table")
      (let* ((snapshot (claude-code-ide-process--snapshot table))
             (ids (mapcar #'claude-code-ide-process--track-id
                          (claude-code-ide-process--job-tracks job)))
             (protected (copy-tree (plist-get snapshot :protected))))
        ;; Never signal the tree of another running instance
        (maphash (lambda (pid _id)
                   (push pid (car protected))
                   (when-let* ((entry (claude-code-ide-process--entry-of snapshot pid)))
                     (push (plist-get entry :pgid) (cdr protected))))
                 (claude-code-ide-process--instance-trees snapshot ids))
        (setf (claude-code-ide-process--job-alive job) alive
              (claude-code-ide-process--job-done job) done
              (claude-code-ide-process--job-ledger job) (claude-code-ide-process--ledger done)
              (claude-code-ide-process--job-protected job) protected
              (claude-code-ide-process--job-round job) 0)
        (claude-code-ide-process--step-reap-round job)))))

(defun claude-code-ide-process--step-reap-round (job)
  "Step 4, one round of JOB: SIGTERM to each live recorded group."
  (cl-incf (claude-code-ide-process--job-round job))
  (let ((table (funcall claude-code-ide-process-list-function))
        (ledger (claude-code-ide-process--job-ledger job)))
    (if (null table)
        (claude-code-ide-process--error-done job "ps failed: no process table")
      (let* ((classes (claude-code-ide-process--classify
                       ledger table (claude-code-ide-process--job-protected job)))
             (live (car classes)))
        (setf (claude-code-ide-process--job-unverified job) (cdr classes)
              (claude-code-ide-process--job-live job) live)
        (if (null live)
            (progn (setf (claude-code-ide-process--job-survivors job) nil)
                   (claude-code-ide-process--step-finish job))
          ;; The ledger does not grow during a stop: only processes that
          ;; a record saw before the stop prove a group.  A member that
          ;; joined later could be a reused PID within the 1.5 s of
          ;; `claude-code-ide-process--same-start-p'.
          (dolist (group live)
            (when (claude-code-ide-process--send (- (car group)) 'SIGTERM)
              (cl-pushnew (car group) (claude-code-ide-process--job-ended job))))
          (list :wait (lambda () (null (claude-code-ide-process--groups-left live)))
                (claude-code-ide-process--job-kill-wait job)
                #'claude-code-ide-process--step-reap-kill))))))

(defun claude-code-ide-process--step-reap-kill (job)
  "Step 4, the end of a round of JOB: SIGKILL to the groups that still run.
Since the SIGTERM, a group can have ended and its group ID can belong
to an unrelated group.  So a fresh table checks each group again, in
full, right before the SIGKILL; only groups that pass get it."
  (let ((left (claude-code-ide-process--groups-left (claude-code-ide-process--job-live job))))
    (if (null left)
        (claude-code-ide-process--step-reap-next job)
      (let ((table (funcall claude-code-ide-process-list-function)))
        (if (null table)
            (claude-code-ide-process--error-done job "ps failed: no process table")
          (let ((targets (cl-remove-if-not
                          (lambda (group) (assq (car group) left))
                          (car (claude-code-ide-process--classify
                                (claude-code-ide-process--job-ledger job) table
                                (claude-code-ide-process--job-protected job))))))
            (dolist (group targets)
              (claude-code-ide-process--send (- (car group)) 'SIGKILL))
            (list :wait (lambda () (null (claude-code-ide-process--groups-left targets)))
                  (min (claude-code-ide-process--job-kill-wait job) 1)
                  #'claude-code-ide-process--step-reap-next)))))))

(defun claude-code-ide-process--step-reap-next (job)
  "Step 4 of JOB: run another round, up to three, while time is left."
  (if (and (< (claude-code-ide-process--job-round job) 3)
           (claude-code-ide-process--time-left-p job))
      (claude-code-ide-process--step-reap-round job)
    ;; The survivors and the unproven members, as the table shows them now
    (let ((table (funcall claude-code-ide-process-list-function)))
      (if (null table)
          (claude-code-ide-process--error-done job "ps failed: no process table")
        (let ((classes (claude-code-ide-process--classify
                        (claude-code-ide-process--job-ledger job) table
                        (claude-code-ide-process--job-protected job))))
          (setf (claude-code-ide-process--job-survivors job)
                (cl-mapcan (lambda (group) (copy-sequence (cdr group))) (car classes))
                (claude-code-ide-process--job-unverified job) (cdr classes))
          (claude-code-ide-process--step-finish job))))))

(defun claude-code-ide-process--stray (entry reason)
  "Return the stray plist of ENTRY with REASON; its folder comes later."
  (list :pid (plist-get entry :pid)
        :command (funcall claude-code-ide-process-command-function (plist-get entry :pid))
        :cwd nil
        :pgid (plist-get entry :pgid)
        :ppid (plist-get entry :ppid)
        :reason reason))

(defun claude-code-ide-process--step-finish (job)
  "Step 5 of JOB: scan the worktrees, and build the result of each instance."
  (let* ((items (claude-code-ide-process--job-items job))
         (ids (mapcar (lambda (item) (claude-code-ide-process--track-id (car item))) items))
         (scan (claude-code-ide-process--job-scan job))
         (scanned (cl-remove-if-not (lambda (item)
                                      (and scan (stringp (cdr item))
                                           (file-directory-p (cdr item))))
                                    items))
         ;; The full lsof scan only when some worktree exists
         (cwds (when scanned (funcall claude-code-ide-process-cwd-function)))
         (snapshot (claude-code-ide-process--snapshot
                    (funcall claude-code-ide-process-list-function)))
         (trees (claude-code-ide-process--instance-trees snapshot ids))
         (all-survivors (claude-code-ide-process--job-survivors job))
         (all-unverified (claude-code-ide-process--job-unverified job))
         (leftover (mapcar (lambda (e) (plist-get e :pid))
                           (append all-survivors all-unverified)))
         (results
          (mapcar
           (lambda (item)
             (let* ((track (car item))
                    (own-members (claude-code-ide-process--track-members track))
                    (own-groups (claude-code-ide-process--track-groups track))
                    (mine (lambda (entry)
                            (or (gethash (plist-get entry :pgid) own-groups)
                                (gethash (plist-get entry :pid) own-members))))
                    (root-alive (memq track (claude-code-ide-process--job-alive job)))
                    (survivors (cl-remove-if-not mine all-survivors))
                    (unverified (cl-remove-if-not mine all-unverified))
                    (root-pid (claude-code-ide-process--track-pid track))
                    (scan-failed (and (memq item scanned) (not (listp cwds))))
                    (strays
                     (append
                      (when root-alive
                        (list (claude-code-ide-process--stray (list :pid root-pid) 'cli)))
                      ;; A root without a start time got no signal; when its
                      ;; PID still runs, nobody knows whether it is the CLI
                      (when-let* (((null (claude-code-ide-process--track-start track)))
                                  (entry (claude-code-ide-process--entry-of snapshot root-pid)))
                        (list (claude-code-ide-process--stray entry 'unverified)))
                      (mapcar (lambda (e) (claude-code-ide-process--stray e 'survivor))
                              survivors)
                      (mapcar (lambda (e) (claude-code-ide-process--stray e 'unverified))
                              unverified)
                      (when (and (memq item scanned) (listp cwds))
                        (claude-code-ide-process--strays-in
                         (claude-code-ide-process--dirs-of (cdr item))
                         cwds snapshot trees
                         (append (claude-code-ide-process--job-exclude job)
                                 leftover
                                 (list root-pid)))))))
               (cons track
                     (append
                      (list :status (cond ((or root-alive survivors) 'timeout)
                                          (scan-failed 'error)
                                          (strays 'strays)
                                          (t 'stopped))
                            :strays strays)
                      (when scan-failed
                        (list :reason "the scan of working folders failed (lsof)"))
                      (list
                       :ended (cl-remove-if-not
                               (lambda (pgid) (gethash pgid own-groups))
                               (reverse (claude-code-ide-process--job-ended job)))
                       :escalated (gethash track (claude-code-ide-process--job-escalated job)))))))
           items))
         ;; The working folders of the strays that the records found: one
         ;; lsof call for all of them
         (missing (cl-mapcan (lambda (result)
                               (cl-remove-if (lambda (s) (plist-get s :cwd))
                                             (copy-sequence (plist-get (cdr result) :strays))))
                             results)))
    (when missing
      (let ((found (make-hash-table))
            (items (funcall claude-code-ide-process-cwd-function
                            (delete-dups (mapcar (lambda (s) (plist-get s :pid)) missing)))))
        (when (listp items)
          (dolist (item items)
            (puthash (plist-get item :pid) (plist-get item :cwd) found)))
        (dolist (stray missing)
          (plist-put stray :cwd (gethash (plist-get stray :pid) found)))))
    (list :done results)))

(defun claude-code-ide-process--make-job (items options)
  "Return the job that stops ITEMS, a list of (TRACK . WORKTREE), with OPTIONS."
  (let ((budget (plist-get options :budget)))
    (claude-code-ide-process--job-create
     :items items
     :options options
     :timeout (or (plist-get options :timeout) claude-code-ide-process-stop-timeout)
     :kill-wait (or (plist-get options :kill-wait) claude-code-ide-process-kill-wait)
     :escalate (if (plist-member options :escalate) (plist-get options :escalate) t)
     :scan (if (plist-member options :scan) (plist-get options :scan) t)
     :exclude (plist-get options :exclude)
     :deadline (and (numberp budget) (+ (float-time) budget)))))

(defun claude-code-ide-process--wait (predicate seconds)
  "Wait up to SECONDS until PREDICATE returns non-nil; return its value.
Process output and sentinels run during the wait."
  (let ((deadline (+ (float-time) (max 0 seconds)))
        (value (funcall predicate)))
    (while (and (not value) (< (float-time) deadline))
      (accept-process-output nil (min 0.05 (max 0.001 (- deadline (float-time)))))
      (setq value (funcall predicate)))
    value))

(defun claude-code-ide-process--run-sync (job)
  "Run JOB with waits, and return its results."
  (let ((step (claude-code-ide-process--step-start job)))
    (while (eq (car step) :wait)
      (claude-code-ide-process--wait (nth 1 step)
                                     (claude-code-ide-process--cap job (nth 2 step)))
      (setq step (funcall (nth 3 step) job)))
    (nth 1 step)))

(defconst claude-code-ide-process--poll-interval 0.05
  "Seconds between two checks of a stop that runs from timers.")

(defun claude-code-ide-process--run-async (job callback)
  "Run JOB from timers, and call CALLBACK with its results.
Return the first timer."
  (run-at-time 0 nil #'claude-code-ide-process--async-step
               job #'claude-code-ide-process--step-start callback))

(defun claude-code-ide-process--async-step (job step-function callback)
  "Run STEP-FUNCTION of JOB, then poll its wait from timers.
At the end call CALLBACK with the results."
  (let ((step (condition-case err
                  (funcall step-function job)
                (error (claude-code-ide-process--error-done
                        job (error-message-string err))))))
    (if (eq (car step) :done)
        (funcall callback (nth 1 step))
      (claude-code-ide-process--async-poll
       job (nth 1 step) (+ (float-time) (claude-code-ide-process--cap job (nth 2 step)))
       (nth 3 step) callback))))

(defun claude-code-ide-process--async-poll (job predicate deadline next callback)
  "Run NEXT of JOB when PREDICATE is non-nil or DEADLINE passed; else poll again."
  (if (or (ignore-errors (funcall predicate)) (>= (float-time) deadline))
      (claude-code-ide-process--async-step job next callback)
    (run-at-time claude-code-ide-process--poll-interval nil
                 #'claude-code-ide-process--async-poll
                 job predicate deadline next callback)))

(defun claude-code-ide-process--finish (track result)
  "Forget TRACK after its stop RESULT, unless its CLI or groups survive.
After `timeout' or `error', keep TRACK, so that a later stop can use it."
  (let ((id (claude-code-ide-process--track-id track)))
    (if (memq (plist-get result :status) '(timeout error))
        (puthash id track claude-code-ide-process--tracks)
      (when (eq (gethash id claude-code-ide-process--tracks) track)
        (claude-code-ide-process-untrack id)))))

(defun claude-code-ide-process--empty-result ()
  "Return the stop result for an instance without a known process."
  (list :status 'stopped :strays nil :ended nil :escalated nil))

(defun claude-code-ide-process--merge-track (old new)
  "Copy the records of OLD into NEW, and return NEW."
  (maphash (lambda (pgid group)
             (unless (gethash pgid (claude-code-ide-process--track-groups new))
               (puthash pgid group (claude-code-ide-process--track-groups new))))
           (claude-code-ide-process--track-groups old))
  (maphash (lambda (pid start)
             (unless (gethash pid (claude-code-ide-process--track-members new))
               (puthash pid start (claude-code-ide-process--track-members new))))
           (claude-code-ide-process--track-members old))
  new)

(defun claude-code-ide-process--resolve (instance process)
  "Return the records of INSTANCE for a stop, with PROCESS when given.
INSTANCE is a descriptor or an instance ID.  When PROCESS has another
PID than the records, the new records take over the old ones, so that
the stop also ends the old groups.  A PROCESS without a PID keeps the
records.  A PROCESS that does not belong to the instance is ignored,
and the records stay.  Without records, make new ones.  Return nil
when nothing is known."
  (let* ((track (claude-code-ide-process--track-of instance))
         (descriptor (cond ((claude-code-ide-instance-p instance) instance)
                           (track (claude-code-ide-process--track-instance track))
                           (t (claude-code-ide-instance-by-id instance))))
         (process (and descriptor
                       (claude-code-ide-process--accept-process descriptor process)))
         (process-pid (claude-code-ide-process--process-pid process)))
    (cond
     ((and track process-pid
           (not (eql process-pid (claude-code-ide-process--track-pid track))))
      (when-let* ((new (claude-code-ide-process--new-track descriptor process)))
        (claude-code-ide-process--merge-track track new)
        (puthash (claude-code-ide-process--track-id new) new
                 claude-code-ide-process--tracks)
        new))
     (track track)
     (descriptor (claude-code-ide-process--new-track descriptor process)))))

(defun claude-code-ide-process--items (instances options)
  "Return (TRACKS . ITEMS) for INSTANCES with OPTIONS.
TRACKS has one track or nil for each instance; ITEMS is the list of
(TRACK . WORKTREE) of the known ones."
  (let* ((tracks (mapcar (lambda (instance)
                           (claude-code-ide-process--resolve
                            instance (plist-get options :process)))
                         instances))
         (items (mapcar (lambda (track)
                          (cons track (claude-code-ide-process--worktree-of
                                       (claude-code-ide-process--track-instance track)
                                       (plist-get options :worktree))))
                        (delq nil (copy-sequence tracks)))))
    (cons tracks items)))

(defun claude-code-ide-process--collect (instances tracks results)
  "Return the alist (INSTANCE-ID . RESULT) for INSTANCES in order.
TRACKS has the track of each instance or nil; RESULTS is a list of
\(TRACK . RESULT).  Each track is finished."
  (dolist (pair results)
    (claude-code-ide-process--finish (car pair) (cdr pair)))
  (cl-mapcar (lambda (instance track)
               (cons (claude-code-ide-process--instance-id instance)
                     (if track
                         (cdr (assq track results))
                       (claude-code-ide-process--empty-result))))
             instances tracks))

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
- :budget    seconds for all waits together, or nil for no limit.
- :soft-end  a signal, a function of (INSTANCE PROCESS), or `none' (the
             caller already did the soft end).  Default: the provider's.
- :escalate  nil to skip SIGTERM and SIGKILL of the CLI in step 3.
- :scan      nil to skip step 5.
- :worktree  the folder for step 5 (default: the descriptor's worktree,
             else its project root).
- :process   the terminal process (default: the one of the buffer).
- :exclude   process IDs that step 5 leaves out.

Return a plist:

- :status   `stopped' (nothing is left), `strays' (only processes that
            the stop did not end are left), `timeout' (the CLI or a
            recorded process survived SIGKILL, or the CLI did not exit
            without :escalate), or `error' (ps failed; :reason says why,
            and the records stay).
- :strays   plists (:pid :command :cwd :reason ...).  :reason is `cli',
            `survivor', `unverified' (in a recorded group, but not proven
            to be the same group, so it got no signal) or `worktree'.
- :ended    the group IDs that got a signal in step 4.
- :escalated nil, SIGTERM or SIGKILL: the last signal of step 3.

Stray processes are only reported, never ended.  The call waits, so
do not call it from `kill-buffer-hook'; use
`claude-code-ide-process-stop-later' there."
  (cdar (apply #'claude-code-ide-process-stop-many (list instance) args)))

(defun claude-code-ide-process-stop-many (instances &rest args)
  "Stop each of INSTANCES at the same time, with one shared wait.
INSTANCES are descriptors or instance IDs.  ARGS are the keys of
`claude-code-ide-process-stop'; :process and :worktree apply to each
instance, so give them only for one.  Return an alist
\(INSTANCE-ID . RESULT) in the order of INSTANCES.  `kill-emacs-hook'
uses it with :budget `claude-code-ide-process-quit-timeout'."
  (let* ((resolved (claude-code-ide-process--items instances args))
         (results (when (cdr resolved)
                    (claude-code-ide-process--run-sync
                     (claude-code-ide-process--make-job (cdr resolved) args)))))
    (claude-code-ide-process--collect instances (car resolved) results)))

(defun claude-code-ide-process-stop-later (instance &rest args)
  "Record the groups of INSTANCE now, and stop it from timers.
For `kill-buffer-hook', which must not wait: the buffer kill itself
sends SIGHUP to the CLI after the hook, so :soft-end defaults to
`none' here.  The steps run from timers, and the command loop runs
between them.  ARGS are as for `claude-code-ide-process-stop', plus
:callback, a function called with the result.  Return the first timer."
  (let* ((args (if (plist-member args :soft-end) args
                 (append (list :soft-end 'none) args)))
         (callback (plist-get args :callback))
         (resolved (claude-code-ide-process--items (list instance) args))
         (track (caar resolved)))
    (when track
      ;; The records must exist after a buffer kill, also for a CLI
      ;; that was never tracked; keep them under the instance ID
      (puthash (claude-code-ide-process--track-id track) track
               claude-code-ide-process--tracks)
      (ignore-errors
        (when-let* ((table (funcall claude-code-ide-process-list-function)))
          (claude-code-ide-process--record-if-alive
           track (claude-code-ide-process--snapshot table) (float-time)))))
    (let ((deliver (lambda (results)
                     (let ((result (cdar (claude-code-ide-process--collect
                                          (list instance) (car resolved) results))))
                       (when callback
                         (condition-case err
                             (funcall callback result)
                           (error (message "claude-code-ide-process: callback failed: %s"
                                           (error-message-string err)))))))))
      (if (cdr resolved)
          (claude-code-ide-process--run-async
           (claude-code-ide-process--make-job (cdr resolved) args) deliver)
        (run-at-time 0 nil deliver nil)))))

(provide 'claude-code-ide-process)

;;; claude-code-ide-process.el ends here
