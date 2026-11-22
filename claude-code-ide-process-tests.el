;;; claude-code-ide-process-tests.el --- Tests for the process trees  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for claude-code-ide-process.el.  The unit tests use a synthetic
;; process table: the process functions of the file are bound to a
;; table in memory, and a signal changes that table.  No real process
;; gets a signal in them.  The live tests run only when
;; CLAUDE_CODE_IDE_LIVE_TESTS=1 is set.  They start their own shell,
;; which starts a background `sleep' in its own session, and they
;; signal only the processes that they started.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-process)

(declare-function claude-code-ide-tests--wait-until "claude-code-ide-tests")
(declare-function claude-code-ide-tests--call-with-clock "claude-code-ide-tests")
(defvar claude-code-ide-tests--wait-limit)

;;; The synthetic process table

(defvar claude-code-ide-process-tests--table nil
  "The synthetic process table: a list of entries.")

(defvar claude-code-ide-process-tests--signals nil
  "The signals of the test, newest first: (TARGET SIGNAL).")

(defvar claude-code-ide-process-tests--cwds nil
  "Alist (PID . CWD) of the synthetic working folders.")

(defvar claude-code-ide-process-tests--ignore nil
  "Alist (PID . SIGNALS): the signals that each process ignores.")

(defvar claude-code-ide-process-tests--reactions nil
  "Functions called with (TARGET SIGNAL) before the signal takes effect.")

(defconst claude-code-ide-process-tests--start 1000.0
  "Start time of the synthetic processes.")

(defun claude-code-ide-process-tests--entry (pid ppid pgid &optional start uid)
  "Return a synthetic entry for PID with PPID, PGID, START and UID."
  (list :pid pid :ppid ppid :pgid pgid
        :uid (or uid (user-uid))
        :start (or start claude-code-ide-process-tests--start)))

(defun claude-code-ide-process-tests--find (pid)
  "Return the synthetic entry of PID, or nil."
  (cl-find pid claude-code-ide-process-tests--table
           :key (lambda (e) (plist-get e :pid))))

(defun claude-code-ide-process-tests--remove (pid)
  "Remove PID from the table; its children get the parent 1."
  (setq claude-code-ide-process-tests--table
        (cl-remove pid claude-code-ide-process-tests--table
                   :key (lambda (e) (plist-get e :pid))))
  (dolist (entry claude-code-ide-process-tests--table)
    (when (eql (plist-get entry :ppid) pid)
      (plist-put entry :ppid 1))))

(defun claude-code-ide-process-tests--signal (target signal)
  "Apply SIGNAL to TARGET in the synthetic table, as `kill' does."
  (push (list target signal) claude-code-ide-process-tests--signals)
  (run-hook-with-args 'claude-code-ide-process-tests--reactions target signal)
  (let ((victims (if (< target 0)
                     (cl-remove-if-not (lambda (e) (eql (plist-get e :pgid) (- target)))
                                       claude-code-ide-process-tests--table)
                   (delq nil (list (claude-code-ide-process-tests--find target))))))
    (if (null victims)
        -1
      (unless (memq signal '(0 nil))
        (dolist (entry victims)
          (let ((pid (plist-get entry :pid)))
            (unless (memq signal (alist-get pid claude-code-ide-process-tests--ignore))
              (claude-code-ide-process-tests--remove pid)))))
      0)))

(defun claude-code-ide-process-tests--emacs-entries ()
  "Return entries for Emacs and its parent, in their own group."
  (list (claude-code-ide-process-tests--entry 50 1 50)
        (claude-code-ide-process-tests--entry (emacs-pid) 50 50)))

(defmacro claude-code-ide-process-tests--with-table (entries &rest body)
  "Run BODY with the synthetic process table ENTRIES and no records.
ENTRIES get the entries of Emacs and its parent in front."
  (declare (indent 1))
  `(let ((claude-code-ide-process-tests--table
          (append (claude-code-ide-process-tests--emacs-entries)
                  (mapcar #'copy-sequence ,entries)))
         (claude-code-ide-process-tests--signals nil)
         (claude-code-ide-process-tests--cwds nil)
         (claude-code-ide-process-tests--ignore nil)
         (claude-code-ide-process-tests--reactions nil)
         (claude-code-ide-process--tracks (make-hash-table :test 'equal))
         (claude-code-ide-process--timer nil)
         (claude-code-ide-process--refresh-running nil)
         (claude-code-ide-process-kill-wait 0.05)
         (claude-code-ide-process-stop-timeout 0.05)
         (claude-code-ide-process-list-function
          (lambda () (mapcar #'copy-sequence claude-code-ide-process-tests--table)))
         (claude-code-ide-process-list-async-function
          (lambda (callback)
            (funcall callback (mapcar #'copy-sequence claude-code-ide-process-tests--table))))
         (claude-code-ide-process-entry-function
          (lambda (pid) (copy-sequence (claude-code-ide-process-tests--find pid))))
         (claude-code-ide-process-command-function
          (lambda (pid)
            (and (claude-code-ide-process-tests--find pid) (format "cmd-%d" pid))))
         (claude-code-ide-process-cwd-function
          (lambda (&optional pids)
            (delq nil
                  (mapcar (lambda (pair)
                            (when (and (claude-code-ide-process-tests--find (car pair))
                                       (or (null pids) (memq (car pair) pids)))
                              (list :pid (car pair) :cwd (cdr pair) :command "c")))
                          claude-code-ide-process-tests--cwds))))
         (claude-code-ide-process-signal-function #'claude-code-ide-process-tests--signal))
     (unwind-protect
         (progn ,@body)
       (claude-code-ide-process--cancel-timer))))

(defun claude-code-ide-process-tests--instance (&rest args)
  "Return a synthetic descriptor; ARGS are its slots.
The default is provider `claude', pid 100 and ID cci-test-process."
  (apply #'claude-code-ide-instance-create
         (append args
                 (list :id "cci-test-process" :provider 'claude :pid 100
                       :process-start-time claude-code-ide-process-tests--start
                       :project-root "/nonexistent/cci-test-proj"
                       :worktree "/nonexistent/cci-test-proj"))))

(defun claude-code-ide-process-tests--cli-exits-on (signal)
  "Return a reaction: the CLI (pid 100) exits at SIGNAL to its group."
  (lambda (target sig)
    (when (and (eql target -100) (eq sig signal))
      (claude-code-ide-process-tests--remove 100))))

(defun claude-code-ide-process-tests--signal-list ()
  "Return the signals of the test, oldest first."
  (reverse claude-code-ide-process-tests--signals))

;;; Parsers

(ert-deftest claude-code-ide-test-process-parse-ps ()
  "The ps table gives entries with start times; short lines are skipped."
  (let* ((text (concat "  100     1   100   501 Wed Nov 18 13:23:54 2026\n"
                       "  201   100   200   501 Wed Nov 18 13:24:01 2026\n"
                       "garbage\n"))
         (entries (claude-code-ide-process--parse-ps text)))
    (should (equal (mapcar (lambda (e) (plist-get e :pid)) entries) '(100 201)))
    (should (equal (plist-get (cadr entries) :ppid) 100))
    (should (equal (plist-get (cadr entries) :pgid) 200))
    (should (equal (plist-get (cadr entries) :uid) 501))
    (should (= (- (plist-get (cadr entries) :start) (plist-get (car entries) :start)) 7))
    (should (= (plist-get (car entries) :start)
               (float-time (encode-time (list 54 23 13 18 11 2026 nil -1 nil)))))))

(ert-deftest claude-code-ide-test-process-parse-lsof ()
  "The lsof fields give one plist for each working folder."
  (should (equal (claude-code-ide-process--parse-lsof
                  "p300\ncbash\nfcwd\nn/tmp/cci-test wt\np301\ncsleep\nfcwd\nn/\n")
                 '((:pid 300 :cwd "/tmp/cci-test wt" :command "bash")
                   (:pid 301 :cwd "/" :command "sleep")))))

(ert-deftest claude-code-ide-test-process-same-start ()
  "Start times match within whole seconds of ps, and nil never matches."
  (should (claude-code-ide-process--same-start-p 1000.0 1000.9))
  (should-not (claude-code-ide-process--same-start-p 1000.0 1002.0))
  (should-not (claude-code-ide-process--same-start-p nil 1000.0)))

(ert-deftest claude-code-ide-test-process-ghostel-pid ()
  "The ghostel pipe gives the process ID of its native child."
  (let ((pipe (make-pipe-process :name "cci-test-ghostel-pipe" :noquery t)))
    (unwind-protect
        (progn
          (should-not (claude-code-ide-process--process-pid pipe))
          (process-put pipe 'ghostel--native-pid 4242)
          (should (eql (claude-code-ide-process--process-pid pipe) 4242)))
      (delete-process pipe))))

(defvar ghostel--pid)
(declare-function claude-code-ide--process-pid "claude-code-ide" (process))

(ert-deftest claude-code-ide-test-process-ghostel-native-child-pid ()
  "A newer ghostel gives the PID through its child handle, or the buffer.
ghostel 20261111 keeps the handle in the process property
`ghostel--native-child', and its PID comes from
`ghostel--native-child-pid'.  It also sets the buffer-local
`ghostel--pid' of the terminal buffer."
  (let* ((buffer (generate-new-buffer " *cci-test-ghostel*"))
         (pipe (make-pipe-process :name "cci-test-ghostel-pipe" :buffer buffer :noquery t)))
    (unwind-protect
        (progn
          (process-put pipe 'ghostel--native-child 'cci-test-handle)
          (cl-letf (((symbol-function 'ghostel--native-child-pid)
                     (lambda (handle) (and (eq handle 'cci-test-handle) 4242))))
            (should (eql (claude-code-ide-process--process-pid pipe) 4242)))
          ;; The buffer-local PID when the handle gives nothing
          (with-current-buffer buffer (setq-local ghostel--pid 4343))
          (cl-letf (((symbol-function 'ghostel--native-child-pid)
                     (lambda (_) (error "cci-test: no child"))))
            (should (eql (claude-code-ide-process--process-pid pipe) 4343))))
      (delete-process pipe)
      (kill-buffer buffer))))

(defun claude-code-ide-process-tests--ghostel-instance (provider buffer)
  "Return a live descriptor of PROVIDER whose terminal BUFFER is a ghostel pipe.
The descriptor has no PID, as a start that could not read it leaves."
  (claude-code-ide-instance-register
   (claude-code-ide-instance-create
    :id (format "cci-test-ghostel-%s" provider) :provider provider
    :buffer buffer
    :project-root "/nonexistent/cci-test-proj" :worktree "/nonexistent/cci-test-proj")))

(ert-deftest claude-code-ide-test-process-ghostel-track-and-stop ()
  "A ghostel CLI of each provider is tracked, and its stop ends it.
The live user Emacs had PID unknown for every ghostel instance, so a
stop found no process and still said stopped.  The start records the
PID and the start time in the descriptor, as `claude-code-ide--start-session'
does with `claude-code-ide--process-pid'; a ghostel pipe alone cannot
prove the start time of its child."
  (dolist (provider '(claude codex))
    (claude-code-ide-process-tests--with-table
        (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100))
      (let* ((claude-code-ide-instance--all nil)
             (buffer (generate-new-buffer " *cci-test-ghostel*"))
             (pipe (make-pipe-process :name "cci-test-ghostel-pipe" :buffer buffer :noquery t))
             (instance (claude-code-ide-process-tests--ghostel-instance provider buffer)))
        (unwind-protect
            (progn
              (process-put pipe 'ghostel--native-child 'cci-test-handle)
              (cl-letf (((symbol-function 'ghostel--native-child-pid)
                         (lambda (handle) (and (eq handle 'cci-test-handle) 100))))
                ;; What the start records
                (setf (claude-code-ide-instance-pid instance) (claude-code-ide--process-pid pipe)
                      (claude-code-ide-instance-process-start-time instance)
                      claude-code-ide-process-tests--start)
                (should (equal (list provider (claude-code-ide-instance-pid instance))
                               (list provider 100)))
                (should (eql (claude-code-ide-process-track instance pipe) 100))
                (add-hook 'claude-code-ide-process-tests--reactions
                          (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
                (let ((result (claude-code-ide-process-stop instance :scan nil)))
                  (should (equal (list provider (plist-get result :status))
                                 (list provider 'stopped))))
                (should-not (claude-code-ide-process-tests--find 100))))
          (delete-process pipe)
          (kill-buffer buffer))))))

(ert-deftest claude-code-ide-test-process-stop-live-cli-without-pid ()
  "A stop of a live terminal whose CLI has no known PID is no success.
Nothing can be signalled or checked, so the result is `error' with a
reason, never `stopped'.  This holds for each provider, and for the
stop from timers, which the handover uses."
  (dolist (provider '(claude codex))
    (claude-code-ide-process-tests--with-table nil
      (let* ((claude-code-ide-instance--all nil)
             (buffer (generate-new-buffer " *cci-test-ghostel*"))
             (pipe (make-pipe-process :name "cci-test-ghostel-pipe" :buffer buffer :noquery t))
             (instance (claude-code-ide-process-tests--ghostel-instance provider buffer))
             (later nil))
        (unwind-protect
            (progn
              (should (claude-code-ide-instance-live-p instance))
              (let ((result (claude-code-ide-process-stop instance)))
                (should (equal (list provider (plist-get result :status))
                               (list provider 'error)))
                (should (string-match-p "process ID" (plist-get result :reason))))
              (claude-code-ide-process-stop-later instance :callback (lambda (r) (setq later r)))
              (should (claude-code-ide-tests--wait-until (lambda () later) 5))
              (should (eq (plist-get later :status) 'error))
              (should-not claude-code-ide-process-tests--signals))
          (delete-process pipe)
          (kill-buffer buffer))))))

;;; Records

(ert-deftest claude-code-ide-test-process-parent-chain ()
  "The descendants follow the parent chain, also through other groups."
  (let ((table (list (claude-code-ide-process-tests--entry 100 50 100)
                     (claude-code-ide-process-tests--entry 110 100 100)
                     (claude-code-ide-process-tests--entry 200 110 200)
                     (claude-code-ide-process-tests--entry 201 200 200)
                     (claude-code-ide-process-tests--entry 900 1 900))))
    (should (equal (mapcar (lambda (e) (plist-get e :pid))
                           (claude-code-ide-process--descendants
                            (claude-code-ide-process--snapshot table) 100))
                   '(100 110 200 201)))
    (should-not (claude-code-ide-process--descendants
                 (claude-code-ide-process--snapshot table) 999))))

(ert-deftest claude-code-ide-test-process-track-records-groups ()
  "Tracking records each descendant group with its leader, never the group of Emacs."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            ;; A child that stayed in the group of Emacs
            (claude-code-ide-process-tests--entry 105 100 50)
            (claude-code-ide-process-tests--entry 200 100 200)
            (claude-code-ide-process-tests--entry 201 200 200)
            (claude-code-ide-process-tests--entry 900 1 900))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (should (eql (claude-code-ide-process-track instance nil) 100))
      (should (timerp claude-code-ide-process--timer))
      (should (equal (mapcar (lambda (g) (plist-get g :pgid))
                             (claude-code-ide-process-groups instance))
                     '(100 200)))
      (let ((group (cadr (claude-code-ide-process-groups instance))))
        (should (equal (plist-get group :command) "cmd-200"))
        (should (= (plist-get group :leader-start) claude-code-ide-process-tests--start)))
      ;; The group ends: the next record forgets it
      (claude-code-ide-process-tests--remove 201)
      (claude-code-ide-process-tests--remove 200)
      (claude-code-ide-process-refresh instance)
      (should (equal (mapcar (lambda (g) (plist-get g :pgid))
                             (claude-code-ide-process-groups instance))
                     '(100)))
      (claude-code-ide-process-untrack instance)
      (should-not (claude-code-ide-process-groups instance))
      (should-not claude-code-ide-process--timer))))

(ert-deftest claude-code-ide-test-process-timer-stops-with-cli ()
  "The record timer stops when no tracked CLI runs, and the records stay."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (claude-code-ide-process-tests--remove 100)
      (claude-code-ide-process--tick)
      (should-not claude-code-ide-process--timer)
      (should (equal (mapcar (lambda (g) (plist-get g :pgid))
                             (claude-code-ide-process-groups instance))
                     '(100 200))))))

(ert-deftest claude-code-ide-test-process-event-records ()
  "A tool event of a tracked instance records a new background group."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100))
    ;; On the virtual clock, no time passes between the record of the
    ;; track and the event, however slow the machine is
    (claude-code-ide-tests--call-with-clock
     (lambda ()
       (let ((instance (claude-code-ide-process-tests--instance)))
         (claude-code-ide-process-track instance nil)
         (push (claude-code-ide-process-tests--entry 300 100 300)
               claude-code-ide-process-tests--table)
         ;; Within one second of the last record, an event does not record
         (claude-code-ide-process--note-event
          (claude-code-ide-make-event "cci-test-process" 1 'tool-end "PostToolUse" nil))
         (should (equal (length (claude-code-ide-process-groups instance)) 1))
         (setf (claude-code-ide-process--track-last-refresh
                (claude-code-ide-process--track-of instance))
               (- (float-time) 5))
         ;; Other events do not record
         (claude-code-ide-process--note-event
          (claude-code-ide-make-event "cci-test-process" 1 'notification "Notification" nil))
         (should (equal (length (claude-code-ide-process-groups instance)) 1))
         (claude-code-ide-process--note-event
          (claude-code-ide-make-event "cci-test-process" 1 'tool-end "PostToolUse" nil))
         (should (equal (mapcar (lambda (g) (plist-get g :pgid))
                                (claude-code-ide-process-groups instance))
                        '(100 300))))))))

;;; Stop

(ert-deftest claude-code-ide-test-process-stop-ends-surviving-group ()
  "A background group that survives the CLI's end gets SIGTERM; the result is stopped."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            ;; A background shell in its own session, and its child
            (claude-code-ide-process-tests--entry 200 100 200)
            (claude-code-ide-process-tests--entry 201 200 200))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (add-hook 'claude-code-ide-process-tests--reactions
                (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
      (let ((result (claude-code-ide-process-stop instance)))
        (should (eq (plist-get result :status) 'stopped))
        (should-not (plist-get result :strays))
        (should (equal (plist-get result :ended) '(200)))
        (should-not (plist-get result :escalated)))
      (should (equal (claude-code-ide-process-tests--signal-list)
                     '((-100 SIGHUP) (-200 SIGTERM))))
      (should-not (claude-code-ide-process-tests--find 201))
      ;; The records are gone after a clean stop
      (should-not (claude-code-ide-process--track-of instance)))))

(ert-deftest claude-code-ide-test-process-stop-after-cli-cleanup ()
  "When the CLI ends its background work at the soft end, no group gets a signal."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (add-hook 'claude-code-ide-process-tests--reactions
                (lambda (target signal)
                  (when (and (eql target -100) (eq signal 'SIGHUP))
                    (claude-code-ide-process-tests--remove 200)
                    (claude-code-ide-process-tests--remove 100))))
      (let ((result (claude-code-ide-process-stop instance)))
        (should (eq (plist-get result :status) 'stopped))
        (should-not (plist-get result :ended)))
      (should (equal (claude-code-ide-process-tests--signal-list) '((-100 SIGHUP)))))))

(ert-deftest claude-code-ide-test-process-stop-escalates ()
  "A CLI that ignores its soft end gets SIGTERM, then SIGKILL."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (setq claude-code-ide-process-tests--ignore '((100 SIGHUP SIGTERM)))
    (let* ((instance (claude-code-ide-process-tests--instance))
           (result (claude-code-ide-process-stop instance)))
      (should (eq (plist-get result :status) 'stopped))
      (should (eq (plist-get result :escalated) 'SIGKILL))
      (should (equal (claude-code-ide-process-tests--signal-list)
                     '((-100 SIGHUP) (-100 SIGTERM) (-100 SIGKILL) (-200 SIGTERM)))))))

(ert-deftest claude-code-ide-test-process-stop-without-escalation ()
  "Without :escalate, a CLI that still runs keeps its groups: the result is timeout."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (setq claude-code-ide-process-tests--ignore '((100 SIGHUP)))
    (let* ((instance (claude-code-ide-process-tests--instance))
           (result (claude-code-ide-process-stop instance :escalate nil :scan nil)))
      (should (eq (plist-get result :status) 'timeout))
      (should (equal (mapcar (lambda (s) (plist-get s :reason)) (plist-get result :strays))
                     '(cli)))
      (should (equal (claude-code-ide-process-tests--signal-list) '((-100 SIGHUP))))
      (should (claude-code-ide-process-tests--find 200))
      ;; The records stay for a later stop
      (should (claude-code-ide-process--track-of instance)))))

(ert-deftest claude-code-ide-test-process-stop-survivor-is-timeout ()
  "A recorded process that survives SIGKILL makes the result timeout."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (setq claude-code-ide-process-tests--ignore '((200 SIGTERM SIGKILL)))
    (add-hook 'claude-code-ide-process-tests--reactions
              (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
    (let* ((instance (claude-code-ide-process-tests--instance))
           (result (claude-code-ide-process-stop instance :scan nil)))
      (should (eq (plist-get result :status) 'timeout))
      (should (equal (mapcar (lambda (s) (list (plist-get s :pid) (plist-get s :reason)))
                             (plist-get result :strays))
                     '((200 survivor))))
      (should (member '(-200 SIGKILL) claude-code-ide-process-tests--signals)))))

(ert-deftest claude-code-ide-test-process-stop-new-member-of-group ()
  "A member that joins a recorded group after the last record is ended with it."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (add-hook 'claude-code-ide-process-tests--reactions
                (lambda (target signal)
                  (when (and (eql target -100) (eq signal 'SIGHUP))
                    (claude-code-ide-process-tests--remove 100)
                    (push (claude-code-ide-process-tests--entry 202 200 200 1500.0)
                          claude-code-ide-process-tests--table))))
      (let ((result (claude-code-ide-process-stop instance :scan nil)))
        (should (eq (plist-get result :status) 'stopped))
        (should (equal (plist-get result :ended) '(200))))
      (should-not (claude-code-ide-process-tests--find 202)))))

(ert-deftest claude-code-ide-test-process-stop-unproven-group ()
  "A recorded group whose recorded processes are all gone is not proven: no signal."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (add-hook 'claude-code-ide-process-tests--reactions
                (lambda (target signal)
                  (when (and (eql target -100) (eq signal 'SIGHUP))
                    ;; The leader is gone; a child that was never recorded
                    ;; is left in the group
                    (claude-code-ide-process-tests--remove 100)
                    (push (claude-code-ide-process-tests--entry 202 1 200 1500.0)
                          claude-code-ide-process-tests--table)
                    (claude-code-ide-process-tests--remove 200))))
      (let ((result (claude-code-ide-process-stop instance :scan nil)))
        (should (eq (plist-get result :status) 'strays))
        (should (equal (mapcar (lambda (s) (list (plist-get s :pid) (plist-get s :reason)))
                               (plist-get result :strays))
                       '((202 unverified))))
        (should-not (member '(-200 SIGTERM) claude-code-ide-process-tests--signals))))))

(ert-deftest claude-code-ide-test-process-stop-reused-group-id ()
  "A group ID whose leader has another start time is a new group: no signal."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (add-hook 'claude-code-ide-process-tests--reactions
                (lambda (target signal)
                  (when (and (eql target -100) (eq signal 'SIGHUP))
                    (claude-code-ide-process-tests--remove 100)
                    ;; The old group ends, and the ID comes back for an
                    ;; unrelated process
                    (claude-code-ide-process-tests--remove 200)
                    (push (claude-code-ide-process-tests--entry 200 1 200 5000.0)
                          claude-code-ide-process-tests--table))))
      (let ((result (claude-code-ide-process-stop instance :scan nil)))
        (should (equal (claude-code-ide-process-tests--signal-list) '((-100 SIGHUP))))
        (should (equal (mapcar (lambda (s) (plist-get s :reason)) (plist-get result :strays))
                       '(unverified)))
        (should (claude-code-ide-process-tests--find 200))))))

(ert-deftest claude-code-ide-test-process-stop-never-signals-emacs ()
  "A recorded group that holds Emacs, or a process of another user, gets no signal."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200)
            (claude-code-ide-process-tests--entry 300 100 300)
            (claude-code-ide-process-tests--entry 301 300 300 nil 0))
    (let* ((instance (claude-code-ide-process-tests--instance))
           (track (claude-code-ide-process--new-track instance nil)))
      (puthash "cci-test-process" track claude-code-ide-process--tracks)
      (claude-code-ide-process--record
       track (claude-code-ide-process--snapshot (funcall claude-code-ide-process-list-function)) 1)
      ;; A forged record of the group of Emacs must not matter
      (puthash 50 (list :pgid 50 :leader-start claude-code-ide-process-tests--start)
               (claude-code-ide-process--track-groups track))
      (puthash (emacs-pid) claude-code-ide-process-tests--start
               (claude-code-ide-process--track-members track))
      (add-hook 'claude-code-ide-process-tests--reactions
                (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
      (claude-code-ide-process-stop instance :scan nil)
      (should-not (cl-find-if (lambda (s) (memq (car s) '(-50 50)))
                              claude-code-ide-process-tests--signals))
      (should-not (member '(-300 SIGTERM) claude-code-ide-process-tests--signals))
      (should (member '(-200 SIGTERM) claude-code-ide-process-tests--signals))
      (should (claude-code-ide-process-tests--find (emacs-pid))))))

(ert-deftest claude-code-ide-test-process-stop-double-fork-setsid ()
  "A double fork with setsid escapes the records; only the worktree scan finds it."
  (let ((worktree (make-temp-file "cci-test-wt-" t)))
    (unwind-protect
        (claude-code-ide-process-tests--with-table
            (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
                  ;; The first fork, still in the group of the CLI
                  (claude-code-ide-process-tests--entry 110 100 100))
          (let ((instance (claude-code-ide-process-tests--instance
                           :worktree worktree :project-root worktree)))
            (claude-code-ide-process-track instance nil)
            ;; Between two records: 110 forks 300, 300 calls setsid,
            ;; 110 exits, and 300 gets the parent 1
            (push (claude-code-ide-process-tests--entry 300 1 300 1200.0)
                  claude-code-ide-process-tests--table)
            (claude-code-ide-process-tests--remove 110)
            (setq claude-code-ide-process-tests--cwds
                  (list (cons 300 (expand-file-name "src" worktree))
                        (cons 100 worktree)
                        (cons (emacs-pid) worktree)))
            (add-hook 'claude-code-ide-process-tests--reactions
                      (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
            (let ((result (claude-code-ide-process-stop instance)))
              (should (eq (plist-get result :status) 'strays))
              (should (equal (mapcar (lambda (s) (list (plist-get s :pid) (plist-get s :reason)))
                                     (plist-get result :strays))
                             '((300 worktree))))
              (should (equal (plist-get (car (plist-get result :strays)) :command) "cmd-300")))
            ;; Strays are reported, never ended
            (should (claude-code-ide-process-tests--find 300))
            (should-not (cl-find-if (lambda (s) (memq (car s) '(300 -300)))
                                    claude-code-ide-process-tests--signals))))
      (delete-directory worktree t))))

(ert-deftest claude-code-ide-test-process-stop-spares-other-instance ()
  "The tree of another running instance in the worktree is tagged, never signaled."
  (let ((worktree (make-temp-file "cci-test-wt-" t)))
    (unwind-protect
        (claude-code-ide-process-tests--with-table
            (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
                  (claude-code-ide-process-tests--entry 400 (emacs-pid) 400)
                  (claude-code-ide-process-tests--entry 410 400 410))
          (let ((first (claude-code-ide-process-tests--instance
                        :worktree worktree :project-root worktree))
                (second (claude-code-ide-instance-create
                         :id "cci-test-process-2" :provider 'codex :pid 400
                         :process-start-time claude-code-ide-process-tests--start
                         :worktree worktree)))
            (claude-code-ide-process-track first nil)
            (claude-code-ide-process-track second nil)
            (setq claude-code-ide-process-tests--cwds
                  (list (cons 400 worktree) (cons 410 worktree)))
            (add-hook 'claude-code-ide-process-tests--reactions
                      (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
            (let ((result (claude-code-ide-process-stop first)))
              (should (eq (plist-get result :status) 'strays))
              (should (equal (mapcar (lambda (s) (list (plist-get s :pid)
                                                       (plist-get s :instance-id)))
                                     (plist-get result :strays))
                             '((400 "cci-test-process-2") (410 "cci-test-process-2")))))
            (should (equal (claude-code-ide-process-tests--signal-list) '((-100 SIGHUP))))
            (should (claude-code-ide-process--track-of second))))
      (delete-directory worktree t))))

(ert-deftest claude-code-ide-test-process-stop-soft-end-options ()
  "The soft end follows the provider, a function, or `none'."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100))
    (let ((claude-code-ide-process-soft-end '((codex . SIGTERM))))
      (claude-code-ide-process-stop
       (claude-code-ide-process-tests--instance :provider 'codex) :scan nil)
      (should (equal (car (claude-code-ide-process-tests--signal-list)) '(-100 SIGTERM)))))
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100))
    (let* ((called nil)
           (instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-stop
       instance :scan nil
       :soft-end (lambda (inst proc)
                   (setq called (list inst proc))
                   (claude-code-ide-process-tests--remove 100)))
      (should (eq (car called) instance))
      (should-not claude-code-ide-process-tests--signals)))
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100))
    (setq claude-code-ide-process-tests--ignore '((100 SIGTERM)))
    (let ((result (claude-code-ide-process-stop
                   (claude-code-ide-process-tests--instance) :soft-end 'none :scan nil)))
      ;; No soft end, so the first signal is the escalation
      (should (equal (car (claude-code-ide-process-tests--signal-list)) '(-100 SIGTERM)))
      (should (eq (plist-get result :escalated) 'SIGKILL)))))

(ert-deftest claude-code-ide-test-process-stop-unknown-instance ()
  "A stop of an instance without a process ID reports stopped and signals nothing."
  (claude-code-ide-process-tests--with-table nil
    (should (eq (plist-get (claude-code-ide-process-stop "cci-test-none") :status) 'stopped))
    (should (eq (plist-get (claude-code-ide-process-stop
                            (claude-code-ide-instance-create :id "cci-test-nopid"))
                           :status)
                'stopped))
    (should-not claude-code-ide-process-tests--signals)))

;;; Review fixes: no signal to a process that the package did not start

(ert-deftest claude-code-ide-test-process-stop-reused-root-pid ()
  "A reused PID with a new start time is another process: no signal, no record.
The entry function gives the start time of the process that holds the
PID now, as a real one does."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 1 100 9000.0)
            (claude-code-ide-process-tests--entry 200 100 200 9001.0))
    (let* ((instance (claude-code-ide-process-tests--instance))
           (result (claude-code-ide-process-stop instance :scan nil)))
      (should (eq (plist-get result :status) 'stopped))
      (should-not claude-code-ide-process-tests--signals)
      (should (claude-code-ide-process-tests--find 100))
      (should (claude-code-ide-process-tests--find 200)))
    ;; Tracking does not record the descendants of the other process
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (should-not (claude-code-ide-process-groups instance)))))

(ert-deftest claude-code-ide-test-process-stop-unverifiable-root ()
  "A root without a known start time cannot be verified: no signal, no record."
  (should-not (claude-code-ide-process--entry-alive-p (emacs-pid) nil))
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 1 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let ((instance (claude-code-ide-instance-create
                     :id "cci-test-process" :provider 'claude :pid 100)))
      (claude-code-ide-process-track instance nil)
      (should-not (claude-code-ide-process-groups instance))
      (let ((result (claude-code-ide-process-stop instance :scan nil)))
        ;; Its PID runs, but nobody can tell whether it is the CLI
        (should (eq (plist-get result :status) 'strays))
        (should (equal (mapcar (lambda (s) (list (plist-get s :pid) (plist-get s :reason)))
                               (plist-get result :strays))
                       '((100 unverified))))
        (should-not claude-code-ide-process-tests--signals)))))

(ert-deftest claude-code-ide-test-process-stop-spares-emacs-ancestor-root ()
  "A root that is an ancestor of Emacs, or in the group of one, gets no signal."
  ;; 50 is the parent of Emacs in the synthetic table, and 40 its parent
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 40 1 40))
    (plist-put (claude-code-ide-process-tests--find 50) :ppid 40)
    (dolist (pid '(40 50))
      (setq claude-code-ide-process-tests--signals nil)
      (let ((result (claude-code-ide-process-stop
                     (claude-code-ide-instance-create
                      :id "cci-test-ancestor" :provider 'claude :pid pid
                      :process-start-time claude-code-ide-process-tests--start)
                     :scan nil :timeout 0.01 :kill-wait 0.01)))
        (should-not claude-code-ide-process-tests--signals)
        (should (eq (plist-get result :status) 'timeout))
        (should (claude-code-ide-process-tests--find pid)))))
  ;; A root in the group of an ancestor gets the signal alone, never the group
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 50))
    (claude-code-ide-process-stop (claude-code-ide-process-tests--instance) :scan nil)
    (should (equal (car (claude-code-ide-process-tests--signal-list)) '(100 SIGHUP)))
    (should-not (cl-find -50 claude-code-ide-process-tests--signals :key #'car))))

(ert-deftest claude-code-ide-test-process-stop-ps-failure ()
  "When ps fails, the stop sends nothing, keeps the records, and reports error."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (let* ((claude-code-ide-process-list-function #'ignore)
             (result (claude-code-ide-process-stop instance :scan nil)))
        (should (eq (plist-get result :status) 'error))
        (should (stringp (plist-get result :reason))))
      (should-not claude-code-ide-process-tests--signals)
      (should (equal (mapcar (lambda (g) (plist-get g :pgid))
                             (claude-code-ide-process-groups instance))
                     '(100 200)))))
  ;; ps fails in the middle, before the groups are ended
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let* ((instance (claude-code-ide-process-tests--instance))
           (calls 0)
           (list-function claude-code-ide-process-list-function))
      (claude-code-ide-process-track instance nil)
      (add-hook 'claude-code-ide-process-tests--reactions
                (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
      (let* ((claude-code-ide-process-list-function
              (lambda () (when (<= (cl-incf calls) 1) (funcall list-function))))
             (result (claude-code-ide-process-stop instance :scan nil)))
        (should (eq (plist-get result :status) 'error)))
      (should (equal (claude-code-ide-process-tests--signal-list) '((-100 SIGHUP))))
      (should (claude-code-ide-process-tests--find 200))
      (should (claude-code-ide-process--track-of instance)))))

(ert-deftest claude-code-ide-test-process-timer-survives-old-ps ()
  "A ps run that started before a new CLI existed does not stop the timer."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100))
    (let* ((pending nil)
           (claude-code-ide-process-list-async-function
            (lambda (callback)
              (push (cons callback (mapcar #'copy-sequence
                                           claude-code-ide-process-tests--table))
                    pending))))
      (claude-code-ide-process-track (claude-code-ide-process-tests--instance) nil)
      ;; The first CLI ends; a new one starts while the old ps still runs
      (claude-code-ide-process-tests--remove 100)
      (let ((old-table (cl-remove 100 (cdar pending)
                                  :key (lambda (e) (plist-get e :pid)))))
        (push (claude-code-ide-process-tests--entry 300 (emacs-pid) 300)
              claude-code-ide-process-tests--table)
        (claude-code-ide-process-track
         (claude-code-ide-instance-create
          :id "cci-test-process-new" :provider 'claude :pid 300
          :process-start-time claude-code-ide-process-tests--start)
         nil)
        (funcall (caar pending) old-table))
      (should (timerp claude-code-ide-process--timer)))))

(ert-deftest claude-code-ide-test-process-stop-new-process-merges-records ()
  "A stop with a process of another PID also ends the groups of the old records."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200)
            (claude-code-ide-process-tests--entry 300 (emacs-pid) 300))
    (let ((instance (claude-code-ide-process-tests--instance))
          (pipe (make-pipe-process :name "cci-test-new-cli" :noquery t)))
      (unwind-protect
          (progn
            (claude-code-ide-process-track instance nil)
            ;; The old CLI is gone; its background group runs on.  The
            ;; new launch records its PID and start time in the descriptor.
            (claude-code-ide-process-tests--remove 100)
            (setf (claude-code-ide-instance-pid instance) 300)
            (process-put pipe 'ghostel--native-pid 300)
            (add-hook 'claude-code-ide-process-tests--reactions
                      (lambda (target signal)
                        (when (and (eql target -300) (eq signal 'SIGHUP))
                          (claude-code-ide-process-tests--remove 300))))
            (let ((result (claude-code-ide-process-stop instance :process pipe :scan nil)))
              (should (eq (plist-get result :status) 'stopped))
              (should (equal (plist-get result :ended) '(200))))
            (should (equal (claude-code-ide-process-tests--signal-list)
                           '((-300 SIGHUP) (-200 SIGTERM))))
            (should-not (claude-code-ide-process--track-of instance)))
        (delete-process pipe))))
  ;; A process without a PID keeps the records
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let ((instance (claude-code-ide-process-tests--instance))
          (pipe (make-pipe-process :name "cci-test-no-pid" :noquery t)))
      (unwind-protect
          (progn
            (claude-code-ide-process-track instance nil)
            (add-hook 'claude-code-ide-process-tests--reactions
                      (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
            (should (equal (plist-get (claude-code-ide-process-stop
                                       instance :process pipe :scan nil)
                                      :ended)
                           '(200))))
        (delete-process pipe)))))

(ert-deftest claude-code-ide-test-process-ps-async-buffers ()
  "The asynchronous ps leaves no buffer behind, and none named /dev/null."
  (when (get-buffer "/dev/null")
    (kill-buffer "/dev/null"))
  (let ((before (buffer-list))
        (entries 'pending))
    (claude-code-ide-process--ps-list-async (lambda (table) (setq entries table)))
    (should (claude-code-ide-tests--wait-until (lambda () (not (eq entries 'pending)))))
    (should (consp entries))
    (should (cl-find (emacs-pid) entries :key (lambda (e) (plist-get e :pid))))
    ;; At once after the sentinel: no buffer is left
    (should-not (get-buffer "/dev/null"))
    (should-not (cl-set-difference (buffer-list) before))
    ;; The error output pipe can close a moment after the sentinel; that
    ;; makes no buffer either
    (accept-process-output nil 0.2)
    (should-not (get-buffer "/dev/null"))
    (should-not (cl-set-difference (buffer-list) before))))

(ert-deftest claude-code-ide-test-process-stop-many-budget ()
  "With :budget, all waits together stay within it, and the signals still go out."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (setq claude-code-ide-process-tests--ignore '((100 SIGHUP SIGTERM) (200 SIGTERM)))
    (let* ((start nil)
           (elapsed nil)
           ;; On the virtual clock, only the waits take time
           (results (claude-code-ide-tests--call-with-clock
                     (lambda ()
                       (setq start (float-time))
                       (prog1 (claude-code-ide-process-stop-many
                               (list (claude-code-ide-process-tests--instance))
                               :budget 0.3 :timeout 5 :kill-wait 5 :scan nil)
                         (setq elapsed (- (float-time) start)))))))
      (should (< elapsed 0.6))
      (should (eq (plist-get (cdar results) :escalated) 'SIGKILL))
      (should-not (claude-code-ide-process-tests--find 100))
      (should (member '(-200 SIGKILL) claude-code-ide-process-tests--signals)))))

(ert-deftest claude-code-ide-test-process-stop-lsof-calls ()
  "No full lsof scan without a worktree; one lsof call for all missing folders."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200)
            (claude-code-ide-process-tests--entry 400 (emacs-pid) 400)
            (claude-code-ide-process-tests--entry 500 400 500))
    (setq claude-code-ide-process-tests--ignore '((200 SIGTERM SIGKILL) (500 SIGTERM SIGKILL)))
    (add-hook 'claude-code-ide-process-tests--reactions
              (lambda (target signal)
                (when (and (memq target '(-100 -400)) (eq signal 'SIGHUP))
                  (claude-code-ide-process-tests--remove (- target)))))
    (let* ((calls nil)
           (cwd-function claude-code-ide-process-cwd-function)
           (claude-code-ide-process-cwd-function
            (lambda (&optional pids)
              (push pids calls)
              (funcall cwd-function pids)))
           (results (claude-code-ide-process-stop-many
                     (list (claude-code-ide-process-tests--instance)
                           (claude-code-ide-instance-create
                            :id "cci-test-process-2" :provider 'codex :pid 400
                            :process-start-time claude-code-ide-process-tests--start
                            :worktree "/nonexistent/cci-test-2"))
                     :kill-wait 0.01)))
      (should (cl-every (lambda (r) (eq (plist-get (cdr r) :status) 'timeout)) results))
      ;; One call, for the two survivors, and no full scan
      (should (equal (length calls) 1))
      (should (equal (sort (copy-sequence (car calls)) #'<) '(200 500))))))

(ert-deftest claude-code-ide-test-process-record-all-one-snapshot ()
  "One record of all tracks builds one snapshot."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 400 (emacs-pid) 400))
    (claude-code-ide-process-track (claude-code-ide-process-tests--instance) nil)
    (claude-code-ide-process-track
     (claude-code-ide-instance-create
      :id "cci-test-process-2" :provider 'codex :pid 400
      :process-start-time claude-code-ide-process-tests--start)
     nil)
    (let ((count 0)
          (snapshot (symbol-function 'claude-code-ide-process--snapshot)))
      (cl-letf (((symbol-function 'claude-code-ide-process--snapshot)
                 (lambda (table) (cl-incf count) (funcall snapshot table))))
        (claude-code-ide-process--tick))
      (should (= count 1)))))

(ert-deftest claude-code-ide-test-process-stop-many ()
  "Several instances stop with one shared wait, each with its own result."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200)
            (claude-code-ide-process-tests--entry 400 (emacs-pid) 400)
            (claude-code-ide-process-tests--entry 500 400 500))
    (let ((first (claude-code-ide-process-tests--instance))
          (second (claude-code-ide-instance-create
                   :id "cci-test-process-2" :provider 'codex :pid 400
                   :process-start-time claude-code-ide-process-tests--start)))
      (claude-code-ide-process-track first nil)
      (claude-code-ide-process-track second nil)
      (add-hook 'claude-code-ide-process-tests--reactions
                (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
      (add-hook 'claude-code-ide-process-tests--reactions
                (lambda (target signal)
                  (when (and (eql target -400) (eq signal 'SIGHUP))
                    (claude-code-ide-process-tests--remove 400))))
      (let ((results (claude-code-ide-process-stop-many
                      (list first "cci-test-process-2" "cci-test-unknown")
                      :timeout 0.05 :scan nil)))
        (should (equal (mapcar #'car results)
                       '("cci-test-process" "cci-test-process-2" "cci-test-unknown")))
        (should (cl-every (lambda (r) (eq (plist-get (cdr r) :status) 'stopped)) results))
        (should (equal (plist-get (cdr (assoc "cci-test-process" results)) :ended) '(200)))
        (should (equal (plist-get (cdr (assoc "cci-test-process-2" results)) :ended) '(500))))
      ;; Both soft ends come before any group signal
      (should (equal (cl-subseq (claude-code-ide-process-tests--signal-list) 0 2)
                     '((-100 SIGHUP) (-400 SIGHUP))))
      (should-not (claude-code-ide-process-tests--find 200))
      (should-not (claude-code-ide-process-tests--find 500)))))

(ert-deftest claude-code-ide-test-process-stop-later ()
  "The kill-buffer path records at once and stops from timers, without its own soft end."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let* ((instance (claude-code-ide-process-tests--instance))
           (result 'pending)
           (timer (claude-code-ide-process-stop-later
                   instance :scan nil :callback (lambda (r) (setq result r)))))
      (should (timerp timer))
      (should (eq result 'pending))
      (should (equal (mapcar (lambda (g) (plist-get g :pgid))
                             (claude-code-ide-process-groups instance))
                     '(100 200)))
      ;; The buffer kill sends SIGHUP, and the CLI exits
      (claude-code-ide-process-tests--remove 100)
      (should (claude-code-ide-tests--wait-until (lambda () (not (eq result 'pending)))))
      (should (eq (plist-get result :status) 'stopped))
      (should (equal (claude-code-ide-process-tests--signal-list) '((-200 SIGTERM))))
      (should-not (claude-code-ide-process--track-of instance)))))

(ert-deftest claude-code-ide-test-process-stop-later-does-not-block ()
  "Each timer step of a later stop is short; the waits are between the timers."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (setq claude-code-ide-process-tests--ignore '((100 SIGTERM) (200 SIGTERM)))
    ;; On the virtual clock, only the waits take time: a step that does
    ;; not wait takes none, however slow the machine is
    (claude-code-ide-tests--call-with-clock
     (lambda ()
       (let* ((longest 0)
              (steps 0)
              (timing (lambda (fn &rest args)
                        (let ((start (float-time)))
                          (prog1 (apply fn args)
                            (cl-incf steps)
                            (setq longest (max longest (- (float-time) start)))))))
              (result 'pending)
              (start (float-time)))
         (advice-add 'claude-code-ide-process--async-poll :around timing)
         (unwind-protect
             (let ((returned
                    (progn
                      (claude-code-ide-process-stop-later
                       (claude-code-ide-process-tests--instance)
                       :scan nil :timeout 0.3 :kill-wait 0.2
                       :callback (lambda (r) (setq result r)))
                      (- (float-time) start))))
               (should (< returned 0.1))
               (should (claude-code-ide-tests--wait-until (lambda () (not (eq result 'pending)))))
               (should (> (- (float-time) start) 0.6))
               (should (> steps 5))
               ;; A step that polls again returns at once; the longest one
               ;; runs the next step without its wait
               (should (< longest 0.15))
               (should (eq (plist-get result :status) 'stopped))
               (should (eq (plist-get result :escalated) 'SIGKILL)))
           (advice-remove 'claude-code-ide-process--async-poll timing)))))))

;;; Worktree scan

(ert-deftest claude-code-ide-test-process-worktree-strays ()
  "The scan finds processes inside the worktree, through links, and leaves out Emacs."
  (let* ((worktree (make-temp-file "cci-test-wt-" t))
         (link (concat worktree "-link")))
    (unwind-protect
        (progn
          (make-symbolic-link worktree link)
          (claude-code-ide-process-tests--with-table
              (list (claude-code-ide-process-tests--entry 300 1 300)
                    (claude-code-ide-process-tests--entry 301 300 300)
                    (claude-code-ide-process-tests--entry 302 1 302)
                    (claude-code-ide-process-tests--entry 303 1 303))
            (setq claude-code-ide-process-tests--cwds
                  (list (cons 300 (file-truename worktree))
                        (cons 301 (expand-file-name "a/b" (file-truename worktree)))
                        ;; A sibling folder whose name starts the same
                        (cons 302 (concat (file-truename worktree) "-other"))
                        (cons 303 "/")
                        (cons (emacs-pid) (file-truename worktree))))
            (should (equal (mapcar (lambda (s) (plist-get s :pid))
                                   (claude-code-ide-process-worktree-strays link))
                           '(300 301)))
            (should (equal (mapcar (lambda (s) (plist-get s :pid))
                                   (claude-code-ide-process-worktree-strays worktree '(300)))
                           '(301)))
            (let ((stray (car (claude-code-ide-process-worktree-strays worktree))))
              (should (equal (plist-get stray :command) "cmd-300"))
              (should (eq (plist-get stray :reason) 'worktree))
              (should (equal (plist-get stray :pgid) 300)))
            (should-not (claude-code-ide-process-worktree-strays "/nonexistent/cci-test"))))
      (ignore-errors (delete-file link))
      (delete-directory worktree t))))

;;; Second review fixes: signal safety

(ert-deftest claude-code-ide-test-process-sigkill-rechecks-reused-group ()
  "After SIGTERM, a group ID that an unrelated group took gets no SIGKILL.
A recorded member left the group with setsid and still runs; the group
ID then belongs to an unrelated process."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200)
            (claude-code-ide-process-tests--entry 203 200 200))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (add-hook 'claude-code-ide-process-tests--reactions
                (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
      (add-hook 'claude-code-ide-process-tests--reactions
                (lambda (target signal)
                  (when (and (eql target -200) (eq signal 'SIGTERM))
                    ;; 203 left the group; the group ends; the ID comes back
                    (plist-put (claude-code-ide-process-tests--find 203) :pgid 203)
                    (claude-code-ide-process-tests--remove 200)
                    (push (claude-code-ide-process-tests--entry 200 1 200 5000.0)
                          claude-code-ide-process-tests--table)
                    (push '(200 SIGTERM) claude-code-ide-process-tests--ignore))))
      (claude-code-ide-process-stop instance :scan nil)
      (should (member '(-200 SIGTERM) claude-code-ide-process-tests--signals))
      (should-not (member '(-200 SIGKILL) claude-code-ide-process-tests--signals))
      (should (claude-code-ide-process-tests--find 200))
      (should (claude-code-ide-process-tests--find 203)))))

(ert-deftest claude-code-ide-test-process-sigkill-needs-start-time ()
  "A process without a start time never makes a group a SIGKILL target."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (add-hook 'claude-code-ide-process-tests--reactions
                (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
      (add-hook 'claude-code-ide-process-tests--reactions
                (lambda (target signal)
                  (when (and (eql target -200) (eq signal 'SIGTERM))
                    ;; The group ends; an unrelated process with that ID
                    ;; and no readable start time comes
                    (claude-code-ide-process-tests--remove 200)
                    (push (list :pid 200 :ppid 1 :pgid 200 :uid (user-uid) :start nil)
                          claude-code-ide-process-tests--table)
                    (push '(200 SIGTERM) claude-code-ide-process-tests--ignore))))
      (claude-code-ide-process-stop instance :scan nil)
      (should-not (member '(-200 SIGKILL) claude-code-ide-process-tests--signals))
      (should (claude-code-ide-process-tests--find 200)))))

(ert-deftest claude-code-ide-test-process-ghostel-pipe-gives-no-start ()
  "A ghostel pipe is not the real child: its PID gives no start time."
  (claude-code-ide-process-tests--with-table
      ;; The PID of the pipe's child belongs to an unrelated process now
      (list (claude-code-ide-process-tests--entry 300 1 300 7000.0)
            (claude-code-ide-process-tests--entry 310 300 310 7001.0))
    ;; The launch recorded the native PID, but no start time
    (let ((instance (claude-code-ide-instance-create
                     :id "cci-test-ghostel" :provider 'claude :pid 300))
          (pipe (make-pipe-process :name "cci-test-ghostel-pipe" :noquery t)))
      (unwind-protect
          (progn
            (process-put pipe 'ghostel--native-pid 300)
            (claude-code-ide-process-track instance pipe)
            (should-not (claude-code-ide-process-groups instance))
            (let ((result (claude-code-ide-process-stop instance :process pipe :scan nil)))
              (should (eq (plist-get result :status) 'strays))
              (should (equal (mapcar (lambda (s) (plist-get s :reason))
                                     (plist-get result :strays))
                             '(unverified))))
            (should-not claude-code-ide-process-tests--signals))
        (delete-process pipe)))))

(ert-deftest claude-code-ide-test-process-cli-group-with-other-uid ()
  "When a member of the CLI's group has another user ID, only the CLI gets a signal."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            ;; A child that runs sudo: effective user ID 0
            (claude-code-ide-process-tests--entry 110 100 100 nil 0))
    (setq claude-code-ide-process-tests--ignore '((100 SIGHUP SIGTERM)))
    (let ((result (claude-code-ide-process-stop
                   (claude-code-ide-process-tests--instance) :scan nil)))
      (should (equal (cl-subseq (claude-code-ide-process-tests--signal-list) 0 3)
                     '((100 SIGHUP) (100 SIGTERM) (100 SIGKILL))))
      (should-not (cl-find -100 claude-code-ide-process-tests--signals :key #'car))
      (should (claude-code-ide-process-tests--find 110))
      ;; 110 is in a recorded group with a process of another user: no signal
      (should (eq (plist-get result :status) 'strays)))))

(ert-deftest claude-code-ide-test-process-ledger-does-not-grow ()
  "A process that joined a group after the records never proves the group.
Round one ends the recorded leader; the unrecorded member is left, and
gets no SIGKILL, because nothing that a record saw proves its group."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (add-hook 'claude-code-ide-process-tests--reactions
                (lambda (target signal)
                  (when (and (eql target -100) (eq signal 'SIGHUP))
                    (claude-code-ide-process-tests--remove 100)
                    ;; A member that no record saw
                    (push (claude-code-ide-process-tests--entry 202 200 200 1500.0)
                          claude-code-ide-process-tests--table)
                    (push '(202 SIGTERM) claude-code-ide-process-tests--ignore))))
      (let ((result (claude-code-ide-process-stop instance :scan nil)))
        (should (member '(-200 SIGTERM) claude-code-ide-process-tests--signals))
        (should-not (member '(-200 SIGKILL) claude-code-ide-process-tests--signals))
        (should (claude-code-ide-process-tests--find 202))
        (should (eq (plist-get result :status) 'strays))
        (should (equal (mapcar (lambda (s) (list (plist-get s :pid) (plist-get s :reason)))
                               (plist-get result :strays))
                       '((202 unverified))))))))

(ert-deftest claude-code-ide-test-process-reap-spares-other-instance-tree ()
  "With two tracked instances, a stop never reaps a group of the other's tree.
The records of the first instance hold a group that is now in the
tree of the second, running instance."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 400 (emacs-pid) 400)
            (claude-code-ide-process-tests--entry 410 400 410))
    (let ((first (claude-code-ide-process-tests--instance))
          (second (claude-code-ide-instance-create
                   :id "cci-test-process-2" :provider 'codex :pid 400
                   :process-start-time claude-code-ide-process-tests--start)))
      (claude-code-ide-process-track first nil)
      (claude-code-ide-process-track second nil)
      (should (equal (mapcar (lambda (g) (plist-get g :pgid))
                             (claude-code-ide-process-groups second))
                     '(400 410)))
      ;; The first instance's records also name group 410 and process 410
      (let ((track (claude-code-ide-process--track-of first)))
        (puthash 410 (list :pgid 410 :leader-start claude-code-ide-process-tests--start)
                 (claude-code-ide-process--track-groups track))
        (puthash 410 claude-code-ide-process-tests--start
                 (claude-code-ide-process--track-members track)))
      (add-hook 'claude-code-ide-process-tests--reactions
                (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
      (claude-code-ide-process-stop first :scan nil)
      (should (equal (claude-code-ide-process-tests--signal-list) '((-100 SIGHUP))))
      (should (claude-code-ide-process-tests--find 410))
      ;; Without the guard, the same records would end the group
      (claude-code-ide-process-untrack second)
      (puthash "cci-test-process"
               (let ((track (claude-code-ide-process--new-track first nil)))
                 (puthash 410 (list :pgid 410 :leader-start claude-code-ide-process-tests--start)
                          (claude-code-ide-process--track-groups track))
                 track)
               claude-code-ide-process--tracks)
      (claude-code-ide-process-stop first :scan nil)
      (should (member '(-410 SIGTERM) claude-code-ide-process-tests--signals)))))

;;; Third review fixes: older processes, and foreign process objects

(ert-deftest claude-code-ide-test-process-attached-older-process-is-not-recorded ()
  "A process that started before the CLI, under a descendant, is never recorded.
On macOS a debugger that attaches to a process becomes its parent, so
ps shows the target, and its children, under the CLI's tree."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            ;; shell -> lldb -> debugserver
            (claude-code-ide-process-tests--entry 110 100 110 1001.0)
            (claude-code-ide-process-tests--entry 120 110 110 1002.0)
            (claude-code-ide-process-tests--entry 130 120 110 1003.0)
            ;; The target: a server in Terminal, started long before the CLI
            (claude-code-ide-process-tests--entry 900 130 900 500.0)
            ;; Its child started after the CLI, but only through the target
            (claude-code-ide-process-tests--entry 901 900 900 1200.0)
            ;; A process with no readable start time
            (list :pid 140 :ppid 110 :pgid 140 :uid (user-uid) :start nil))
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      (should (equal (mapcar (lambda (g) (plist-get g :pgid))
                             (claude-code-ide-process-groups instance))
                     '(100 110)))
      (let ((members (claude-code-ide-process--track-members
                      (claude-code-ide-process--track-of instance))))
        (dolist (pid '(900 901 140))
          (should-not (gethash pid members))))
      ;; The debugger detaches; the target gets its old parent again
      (plist-put (claude-code-ide-process-tests--find 900) :ppid 1)
      (add-hook 'claude-code-ide-process-tests--reactions
                (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
      (claude-code-ide-process-stop instance :scan nil)
      (should-not (cl-find-if (lambda (s) (memq (car s) '(900 -900 901 140 -140)))
                              claude-code-ide-process-tests--signals))
      (should (claude-code-ide-process-tests--find 900))
      (should (claude-code-ide-process-tests--find 901)))))

(ert-deftest claude-code-ide-test-process-attached-emacs-children-not-recorded ()
  "With Emacs attached under a descendant, none of Emacs's children are recorded."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 110 100 110 1001.0)
            (claude-code-ide-process-tests--entry 130 110 110 1003.0)
            ;; Other children of Emacs: an LSP server and another CLI
            (claude-code-ide-process-tests--entry 600 (emacs-pid) 600 1500.0)
            (claude-code-ide-process-tests--entry 700 (emacs-pid) 700 2000.0))
    ;; Emacs started before the CLI, and a debugserver in the CLI's tree
    ;; is now its parent
    (plist-put (claude-code-ide-process-tests--find (emacs-pid)) :start 100.0)
    (plist-put (claude-code-ide-process-tests--find (emacs-pid)) :ppid 130)
    (let ((instance (claude-code-ide-process-tests--instance)))
      (claude-code-ide-process-track instance nil)
      ;; The CLI is now an ancestor of Emacs, so its own groups are
      ;; protected too; no group of an Emacs child is recorded
      (should-not (cl-intersection (mapcar (lambda (g) (plist-get g :pgid))
                                           (claude-code-ide-process-groups instance))
                                   (list 50 600 700)))
      (let ((members (claude-code-ide-process--track-members
                      (claude-code-ide-process--track-of instance))))
        (dolist (pid (list (emacs-pid) 600 700))
          (should-not (gethash pid members))))
      (claude-code-ide-process-stop instance :scan nil :timeout 0.01 :kill-wait 0.01)
      (should-not (cl-find-if (lambda (s) (memq (car s) (list 600 -600 700 -700 (emacs-pid))))
                              claude-code-ide-process-tests--signals)))))

(ert-deftest claude-code-ide-test-process-foreign-process-is-ignored ()
  "A live child of Emacs that is not the instance's process never becomes the root."
  (let ((foreign (make-process :name "cci-test-foreign" :command '("/bin/sleep" "30")
                               :noquery t :connection-type 'pipe)))
    (unwind-protect
        (claude-code-ide-process-tests--with-table
            (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
                  (claude-code-ide-process-tests--entry 200 100 200)
                  ;; The foreign child, in the synthetic table
                  (claude-code-ide-process-tests--entry (process-id foreign) (emacs-pid)
                                                        (process-id foreign)))
          (let ((instance (claude-code-ide-process-tests--instance))
                (fpid (process-id foreign)))
            (claude-code-ide-process-track instance nil)
            ;; track with the foreign process uses the descriptor's PID
            (should (eql (claude-code-ide-process-track
                          (claude-code-ide-instance-create :id "cci-test-other" :pid 4242)
                          foreign)
                         4242))
            (add-hook 'claude-code-ide-process-tests--reactions
                      (claude-code-ide-process-tests--cli-exits-on 'SIGHUP))
            (let ((result (claude-code-ide-process-stop instance :process foreign :scan nil)))
              (should (eq (plist-get result :status) 'stopped))
              (should (equal (plist-get result :ended) '(200))))
            ;; The stop used the instance's own records, and never the foreign child
            (should (equal (claude-code-ide-process-tests--signal-list)
                           '((-100 SIGHUP) (-200 SIGTERM))))
            (should-not (cl-find-if (lambda (s) (memq (car s) (list fpid (- fpid))))
                                    claude-code-ide-process-tests--signals))))
      (delete-process foreign))))

;;; Bounded runs of ps and lsof

(ert-deftest claude-code-ide-test-process-run-timeout ()
  "A program that takes too long is ended, and gives nil; output comes whole."
  ;; On the virtual clock, only the wait for the program takes time
  (claude-code-ide-tests--call-with-clock
   (lambda ()
     (let ((before (length (process-list)))
           (start (float-time)))
       (should-not (claude-code-ide-process--run "/bin/sleep" (list "300") 0.2))
       (should (< (- (float-time) start) 2))
       (should (= (length (process-list)) before)))))
  ;; A loaded machine can start a program slowly
  (should (equal (claude-code-ide-process--run "/bin/echo" (list "cci-test") claude-code-ide-tests--wait-limit)
                 "cci-test\n"))
  (should-not (claude-code-ide-process--run "/usr/bin/false" nil claude-code-ide-tests--wait-limit))
  (should (equal (claude-code-ide-process--run "/usr/bin/false" nil claude-code-ide-tests--wait-limit t) "")))

(ert-deftest claude-code-ide-test-process-scan-failure ()
  "A failed scan of working folders gives error, never a false stopped."
  (let ((worktree (make-temp-file "cci-test-wt-" t)))
    (unwind-protect
        (claude-code-ide-process-tests--with-table
            (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100))
          (let ((claude-code-ide-process-cwd-function (lambda (&optional _pids) (quote failed))))
            (add-hook (quote claude-code-ide-process-tests--reactions)
                      (claude-code-ide-process-tests--cli-exits-on (quote SIGHUP)))
            (let ((result (claude-code-ide-process-stop
                           (claude-code-ide-process-tests--instance
                            :worktree worktree :project-root worktree))))
              (should (eq (plist-get result :status) (quote error)))
              (should (stringp (plist-get result :reason))))
            (should-error (claude-code-ide-process-worktree-strays worktree))))
      (delete-directory worktree t))))

;;; Live tests

(defun claude-code-ide-process-tests--live-p ()
  "Return non-nil when the live tests may run."
  (equal (getenv "CLAUDE_CODE_IDE_LIVE_TESTS") "1"))

(defun claude-code-ide-process-tests--pid-runs-p (pid)
  "Return non-nil when PID runs and is not a zombie."
  (claude-code-ide-process--attributes-entry pid))

(defun claude-code-ide-process-tests--read-pids (file)
  "Return the process IDs in FILE, one per line."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (mapcar #'string-to-number (split-string (buffer-string) nil t)))))

(defun claude-code-ide-process-tests--live-kill (pids marker)
  "Send SIGKILL to each of PIDS whose command line has MARKER.
The check makes sure that the test signals only its own processes."
  (dolist (pid pids)
    (let ((command (claude-code-ide-process--attributes-command pid)))
      (when (and (stringp command) (string-match-p (regexp-quote marker) command))
        (signal-process pid 'SIGKILL)))))

(defun claude-code-ide-process-tests--live-shell (dir script)
  "Start /bin/sh with SCRIPT in DIR on a pty, as a terminal starts a CLI."
  (let ((default-directory (file-name-as-directory dir)))
    (make-process :name "cci-test-live-cli"
                  :command (list "/bin/sh" "-c" script)
                  :connection-type 'pty
                  :noquery t)))

(ert-deftest claude-code-ide-test-process-live-background-sleep ()
  "Live: a shell starts a background sleep in its own session; a stop leaves nothing."
  (skip-unless (claude-code-ide-process-tests--live-p))
  (let* ((dir (file-truename (make-temp-file "cci-test-live-" t)))
         (marker (format "cci-test-live-%d" (random 1000000)))
         (pids-file (expand-file-name "pids" dir))
         ;; The background command: a new session, as CC and Codex start
         ;; theirs, so the end of the shell does not reach it
         (script (format "perl -MPOSIX -e 'POSIX::setsid(); exec {\"/bin/sleep\"} \"%s\", \"300\"' & echo $! > %s; wait"
                         marker (shell-quote-argument pids-file)))
         (process (claude-code-ide-process-tests--live-shell dir script))
         (instance (claude-code-ide-instance-create
                    :id "cci-test-live-1" :provider 'claude
                    :pid (process-id process)
                    :worktree dir :project-root dir))
         (claude-code-ide-process--tracks (make-hash-table :test 'equal))
         (claude-code-ide-process--timer nil)
         (claude-code-ide-process--refresh-running nil)
         ;; A full lsof scan can take 30 s on a busy Mac
         (claude-code-ide-process-lsof-timeout 120)
         (claude-code-ide-process-track-interval 0.3)
         bg-pid)
    (unwind-protect
        (progn
          (should (claude-code-ide-tests--wait-until
                   (lambda () (claude-code-ide-process-tests--read-pids pids-file))))
          (setq bg-pid (car (claude-code-ide-process-tests--read-pids pids-file)))
          (claude-code-ide-process-track instance process)
          ;; Wait for a record of the background group
          (should (claude-code-ide-tests--wait-until
                   (lambda ()
                     (memq bg-pid (mapcar (lambda (g) (plist-get g :pgid))
                                          (claude-code-ide-process-groups instance))))))
          (let ((result (claude-code-ide-process-stop instance :timeout 30 :kill-wait 10)))
            (message "live stop result: %S" result)
            (should (eq (plist-get result :status) 'stopped))
            (should (memq bg-pid (plist-get result :ended))))
          (should-not (process-live-p process))
          (should-not (claude-code-ide-process-tests--pid-runs-p bg-pid))
          (should-not (claude-code-ide-process-worktree-strays dir)))
      (when bg-pid
        (claude-code-ide-process-tests--live-kill (list bg-pid) marker))
      (when (process-live-p process)
        (delete-process process))
      (claude-code-ide-process--cancel-timer)
      (delete-directory dir t))))

(ert-deftest claude-code-ide-test-process-live-double-fork ()
  "Live: a double fork with setsid escapes the records, and the worktree scan reports it."
  (skip-unless (claude-code-ide-process-tests--live-p))
  (let* ((dir (file-truename (make-temp-file "cci-test-live-" t)))
         (marker (format "cci-test-live-%d" (random 1000000)))
         (pids-file (expand-file-name "pids" dir))
         ;; The child forks, the grandchild calls setsid and writes its
         ;; PID, and the child exits at once
         (script (format "perl -MPOSIX -e 'exit 0 if fork; POSIX::setsid(); exit 0 if fork; open(F, \">\", \"%s\"); print F \"$$\\n\"; close F; exec {\"/bin/sleep\"} \"%s\", \"300\"'; sleep 300"
                         pids-file marker))
         (process (claude-code-ide-process-tests--live-shell dir script))
         (instance (claude-code-ide-instance-create
                    :id "cci-test-live-2" :provider 'claude
                    :pid (process-id process)
                    :worktree dir :project-root dir))
         (claude-code-ide-process--tracks (make-hash-table :test 'equal))
         (claude-code-ide-process--timer nil)
         (claude-code-ide-process--refresh-running nil)
         ;; A full lsof scan can take 30 s on a busy Mac
         (claude-code-ide-process-lsof-timeout 120)
         escaped)
    (unwind-protect
        (progn
          (should (claude-code-ide-tests--wait-until
                   (lambda () (claude-code-ide-process-tests--read-pids pids-file))))
          (setq escaped (car (claude-code-ide-process-tests--read-pids pids-file)))
          (claude-code-ide-process-track instance process)
          (let ((result (claude-code-ide-process-stop instance :timeout 30 :kill-wait 10)))
            (message "live double fork result: %S" result)
            (should (eq (plist-get result :status) 'strays))
            (should (member escaped (mapcar (lambda (s) (plist-get s :pid))
                                            (plist-get result :strays))))
            (should (eq (plist-get (cl-find escaped (plist-get result :strays)
                                            :key (lambda (s) (plist-get s :pid)))
                                   :reason)
                        'worktree)))
          ;; The stop reported it and left it alone
          (should (claude-code-ide-process-tests--pid-runs-p escaped)))
      (when escaped
        (claude-code-ide-process-tests--live-kill (list escaped) marker))
      (when (process-live-p process)
        (delete-process process))
      (claude-code-ide-process--cancel-timer)
      (delete-directory dir t))))

(provide 'claude-code-ide-process-tests)

;;; claude-code-ide-process-tests.el ends here
