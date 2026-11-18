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

;;; Records

(ert-deftest claude-code-ide-test-process-parent-chain ()
  "The descendants follow the parent chain, also through other groups."
  (let ((table (list (claude-code-ide-process-tests--entry 100 50 100)
                     (claude-code-ide-process-tests--entry 110 100 100)
                     (claude-code-ide-process-tests--entry 200 110 200)
                     (claude-code-ide-process-tests--entry 201 200 200)
                     (claude-code-ide-process-tests--entry 900 1 900))))
    (should (equal (mapcar (lambda (e) (plist-get e :pid))
                           (claude-code-ide-process--descendants table 100))
                   '(100 110 200 201)))
    (should-not (claude-code-ide-process--descendants table 999))))

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
                     '(100 300))))))

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
      (claude-code-ide-process--record track (funcall claude-code-ide-process-list-function) 1)
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

(ert-deftest claude-code-ide-test-process-stop-wrong-start-time ()
  "A PID whose start time differs from the descriptor's is another process: no signal."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 1 100 9000.0))
    (let ((claude-code-ide-process-entry-function
           ;; The entry function gives no start time, so the descriptor's counts
           (lambda (pid)
             (when-let* ((e (copy-sequence (claude-code-ide-process-tests--find pid))))
               (if (eql pid 100) (plist-put e :start nil) e)))))
      (let ((result (claude-code-ide-process-stop
                     (claude-code-ide-process-tests--instance) :scan nil)))
        (should (eq (plist-get result :status) 'stopped))
        (should-not claude-code-ide-process-tests--signals)))))

(ert-deftest claude-code-ide-test-process-stop-many ()
  "Several instances stop with one shared wait, each with its own result."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200)
            (claude-code-ide-process-tests--entry 400 (emacs-pid) 400)
            (claude-code-ide-process-tests--entry 500 400 500))
    (let ((first (claude-code-ide-process-tests--instance))
          (second (claude-code-ide-instance-create
                   :id "cci-test-process-2" :provider 'codex :pid 400)))
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
  "The kill-buffer path records at once and stops from a timer, without its own soft end."
  (claude-code-ide-process-tests--with-table
      (list (claude-code-ide-process-tests--entry 100 (emacs-pid) 100)
            (claude-code-ide-process-tests--entry 200 100 200))
    (let* ((instance (claude-code-ide-process-tests--instance))
           (timer (claude-code-ide-process-stop-later instance :scan nil)))
      (should (timerp timer))
      (should (equal (mapcar (lambda (g) (plist-get g :pgid))
                             (claude-code-ide-process-groups instance))
                     '(100 200)))
      ;; The buffer kill sends SIGHUP, and the CLI exits
      (claude-code-ide-process-tests--remove 100)
      (cancel-timer timer)
      (funcall (timer--function timer))
      (should (equal (claude-code-ide-process-tests--signal-list) '((-200 SIGTERM))))
      (should-not (claude-code-ide-process--track-of instance)))))

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
         (claude-code-ide-process-track-interval 0.3)
         bg-pid)
    (unwind-protect
        (progn
          (should (claude-code-ide-process--wait
                   (lambda () (claude-code-ide-process-tests--read-pids pids-file)) 5))
          (setq bg-pid (car (claude-code-ide-process-tests--read-pids pids-file)))
          (claude-code-ide-process-track instance process)
          ;; Wait for a record of the background group
          (should (claude-code-ide-process--wait
                   (lambda ()
                     (memq bg-pid (mapcar (lambda (g) (plist-get g :pgid))
                                          (claude-code-ide-process-groups instance))))
                   5))
          (let ((result (claude-code-ide-process-stop instance :timeout 3 :kill-wait 1)))
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
         escaped)
    (unwind-protect
        (progn
          (should (claude-code-ide-process--wait
                   (lambda () (claude-code-ide-process-tests--read-pids pids-file)) 5))
          (setq escaped (car (claude-code-ide-process-tests--read-pids pids-file)))
          (claude-code-ide-process-track instance process)
          (let ((result (claude-code-ide-process-stop instance :timeout 3 :kill-wait 1)))
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
