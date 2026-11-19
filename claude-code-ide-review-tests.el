;;; claude-code-ide-review-tests.el --- Tests for review tracking and ediff frames  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the tracked reviews (the record, the end of the process,
;; the result file, the delivery through the inbox, the acknowledgement,
;; the recovery after a restart and the owner after a handover) and for
;; the dedicated ediff frames (their queue, and launches, resumes,
;; restores and provider changes while a frame is selected).
;; claude-code-ide-tests.el loads this file after its mocks.  The
;; review folder, the inbox and the projects are temporary folders, the
;; instances use a stub provider, and all IDs are synthetic.
;;
;; Batch Emacs cannot make frames.  There the initial frame plays the
;; dedicated diff frame.  The tests with two real frames run only in an
;; Emacs that can make frames.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'claude-code-ide)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-control)
(require 'claude-code-ide-review)
(require 'claude-code-ide-mcp-handlers)
(require 'claude-code-ide-control-tests)
(require 'claude-code-ide-session-registry-tests)
(require 'claude-code-ide-provider-tests)

(declare-function claude-code-ide-tests--make-session "claude-code-ide-tests")
(declare-function claude-code-ide-tests--clear-processes "claude-code-ide-tests")
(declare-function claude-code-ide-tests--wait-until "claude-code-ide-tests")

;;; Helpers

(defvar claude-code-ide-review-tests--warnings nil
  "Texts of the warnings of the current test, newest first.")

(defmacro claude-code-ide-review-tests--with-review (&rest body)
  "Run BODY with a temporary review folder, inbox and the stub provider.
BODY can refer to the folder of the result files as `results'."
  (declare (indent 0))
  `(claude-code-ide-tests--with-control
     (let* ((results (make-temp-file "cci-test-review-results-" t))
            (claude-code-ide-review-directory (make-temp-file "cci-test-reviews-" t))
            (claude-code-ide-review-check-interval nil)
            (claude-code-ide-review--records (make-hash-table :test 'equal))
            (claude-code-ide-review--processes (make-hash-table :test 'equal))
            (claude-code-ide-review--loaded nil)
            (claude-code-ide-review--foreign (make-hash-table :test 'equal))
            (claude-code-ide-review--scan-time nil)
            (claude-code-ide-review--warned nil)
            (claude-code-ide-review--timer nil)
            (claude-code-ide-review-retry-seconds 600)
            (claude-code-ide-review-tests--warnings nil)
            (claude-code-ide-session-start-functions
             (list #'claude-code-ide-review--on-session-start)))
       (add-hook 'claude-code-ide-control-delivered-functions
                 #'claude-code-ide-review--on-delivered)
       (unwind-protect
           (cl-letf (((symbol-function 'display-warning)
                      (lambda (_type text &rest _)
                        (push text claude-code-ide-review-tests--warnings)))
                     ((symbol-function 'message) #'ignore))
             ,@body)
         (maphash (lambda (_id process)
                    (when (process-live-p process) (delete-process process)))
                  claude-code-ide-review--processes)
         (delete-directory results t)
         (delete-directory claude-code-ide-review-directory t)))))

(defun claude-code-ide-review-tests--wait (predicate)
  "Run the process filters and sentinels until PREDICATE is true.
Signal an error after `claude-code-ide-tests--wait-limit' seconds.  A
deadline, not `with-timeout': the control tests mock `run-at-time'."
  (unless (claude-code-ide-tests--wait-until predicate)
    (error "Timeout in a review test")))

(defun claude-code-ide-review-tests--state (review-id)
  "Return the state of REVIEW-ID."
  (plist-get (claude-code-ide-review-status review-id) :state))

(defun claude-code-ide-review-tests--write (file text)
  "Write TEXT to FILE."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region text nil file nil 'silent)))

(defun claude-code-ide-review-tests--restart ()
  "Forget the reviews in memory, as a new Emacs that has not read the files."
  (setq claude-code-ide-review--records (make-hash-table :test 'equal)
        claude-code-ide-review--processes (make-hash-table :test 'equal)
        claude-code-ide-review--loaded nil
        claude-code-ide-review--foreign (make-hash-table :test 'equal)
        claude-code-ide-review--scan-time nil
        claude-code-ide-review--warned nil
        claude-code-ide-control--index (make-hash-table :test 'equal)))

(defun claude-code-ide-review-tests--request (review-id)
  "Return the inbox request ID of REVIEW-ID."
  (concat "review:" review-id))

(defun claude-code-ide-review-tests--inbox (instance-id review-id)
  "Return the inbox result of the review REVIEW-ID at INSTANCE-ID."
  (plist-get (claude-code-ide-control-request-status
              instance-id (claude-code-ide-review-tests--request review-id))
             :result))

(defun claude-code-ide-review-tests--ack (instance-id text)
  "Send the prompt-submit event of INSTANCE-ID for TEXT."
  (claude-code-ide-tests--control-event instance-id 'prompt-submit (list (cons 'prompt text))))

(defun claude-code-ide-review-tests--command-review (owner results name text &rest args)
  "Track a review of OWNER whose command writes TEXT to the file NAME in RESULTS.
ARGS go to `claude-code-ide-review-track'.  Wait until the process
ends and return the result of the track."
  (let ((result (apply #'claude-code-ide-review-track owner
                       :command (list "sh" "-c" (format "printf '%%s' %s > %s"
                                                        (shell-quote-argument text)
                                                        (shell-quote-argument name)))
                       :directory results
                       :result-file name
                       args)))
    (claude-code-ide-review-tests--wait
     (lambda () (not (eq (claude-code-ide-review-tests--state (plist-get result :review-id))
                         'running))))
    result))

;;; Acceptance check 7: one delivery, with an acknowledgement

(ert-deftest claude-code-ide-test-review-delivered-once-with-ack ()
  "A review that ends while the owner works reaches the owner one time.
The end of the process is not a delivery: the result waits in the
inbox, goes out after the turn, and is delivered at the acknowledgement."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (let* ((track (claude-code-ide-review-tests--command-review
                   "cci-test-owner" results "result.md" "cci-test review comments"
                   :label "cci-test plan" :review-id "cci-test-review-1"))
           (id (plist-get track :review-id)))
      (should (eq (plist-get track :status) 'ok))
      (should (equal id "cci-test-review-1"))
      ;; Ended while the owner works: in the inbox, nothing sent
      (should (eq (claude-code-ide-review-tests--state id) 'submitted))
      (should-not claude-code-ide-tests--control-sent)
      (should (eq (claude-code-ide-review-tests--inbox "cci-test-owner" id) 'queued))
      ;; The turn ends: the result goes out one time
      (claude-code-ide-tests--control-set-state "cci-test-owner" 'idle)
      (claude-code-ide-tests--control-event "cci-test-owner" 'turn-end)
      (should (= (length claude-code-ide-tests--control-sent) 1))
      (let ((text (nth 1 (car claude-code-ide-tests--control-sent))))
        (should (string-match-p "cci-test review comments" text))
        (should (string-match-p "cci-test plan" text))
        (should (string-match-p "Exit status: 0" text))
        ;; Sent is not delivered
        (should (eq (claude-code-ide-review-tests--state id) 'submitted))
        ;; The acknowledgement
        (claude-code-ide-tests--control-set-state "cci-test-owner" 'working)
        (claude-code-ide-review-tests--ack "cci-test-owner" text)
        (should (eq (claude-code-ide-review-tests--state id) 'delivered))
        (should (plist-get (claude-code-ide-review-status id) :delivered-at))
        ;; Later turns, checks and a second acknowledgement send nothing more
        (claude-code-ide-tests--control-set-state "cci-test-owner" 'idle)
        (claude-code-ide-tests--control-event "cci-test-owner" 'turn-end)
        (claude-code-ide-review--tick)
        (claude-code-ide-review-tests--ack "cci-test-owner" text)
        (should (= (length claude-code-ide-tests--control-sent) 1))
        (should (eq (claude-code-ide-review-tests--state id) 'delivered))
        ;; The delivered record has no text left
        (should-not (claude-code-ide-review--record-text
                     (gethash id claude-code-ide-review--records)))))))

(ert-deftest claude-code-ide-test-review-delivered-hook-misses ()
  "A check finds an acknowledgement that the delivered hook did not report."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (let ((id (plist-get (claude-code-ide-review-tests--command-review
                          "cci-test-owner" results "r.md" "cci-test text")
                         :review-id)))
      (claude-code-ide-tests--control-set-state "cci-test-owner" 'idle)
      (claude-code-ide-tests--control-event "cci-test-owner" 'turn-end)
      (let ((claude-code-ide-control-delivered-functions nil))
        (claude-code-ide-review-tests--ack "cci-test-owner"
                                           (nth 1 (car claude-code-ide-tests--control-sent))))
      (should (eq (claude-code-ide-review-tests--state id) 'submitted))
      (claude-code-ide-review--tick)
      (should (eq (claude-code-ide-review-tests--state id) 'delivered)))))

;;; The owner does not run

(ert-deftest claude-code-ide-test-review-owner-disconnected ()
  "A review that ends while the owner does not run waits until it runs again."
  (claude-code-ide-review-tests--with-review
    ;; The owner is open in the registry, but does not run
    (setf (alist-get "cci-test-owner" claude-code-ide-tests--control-registry nil nil #'equal)
          (claude-code-ide-session-registry-entry-create :key "cci-test-owner" :state 'open))
    (let ((id (plist-get (claude-code-ide-review-tests--command-review
                          "cci-test-owner" results "r.md" "cci-test while away")
                         :review-id)))
      (should (eq (claude-code-ide-review-tests--state id) 'submitted))
      (should (eq (claude-code-ide-review-tests--inbox "cci-test-owner" id) 'queued))
      (should-not claude-code-ide-tests--control-sent)
      ;; The owner runs again and becomes idle
      (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle)
      (claude-code-ide-tests--control-event "cci-test-owner" 'session-start)
      (should (= (length claude-code-ide-tests--control-sent) 1))
      (claude-code-ide-review-tests--ack "cci-test-owner"
                                         (nth 1 (car claude-code-ide-tests--control-sent)))
      (should (eq (claude-code-ide-review-tests--state id) 'delivered)))))

(ert-deftest claude-code-ide-test-review-owner-unknown-after-restart ()
  "A result for an owner that a new Emacs does not know yet waits for its start."
  (claude-code-ide-review-tests--with-review
    (let ((id (plist-get (progn
                           (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
                           (claude-code-ide-review-track
                            "cci-test-owner" :command '("sleep" "30") :directory results
                            :result-file "r.md" :review-id "cci-test-restart"))
                         :review-id)))
      (should (equal id "cci-test-restart"))
      ;; Emacs quits while the review runs: the review is marked, and
      ;; Emacs ends its process, with no sentinel of this Emacs
      (claude-code-ide-review--on-kill-emacs)
      (let* ((process (gethash id claude-code-ide-review--processes))
             (pid (process-id process)))
        (claude-code-ide-review-tests--restart)
        (set-process-sentinel process #'ignore)
        (delete-process process)
        ;; The signal takes effect later on a loaded machine
        (claude-code-ide-review-tests--wait
         (lambda () (not (claude-code-ide-review--pid-live-p pid)))))
      (claude-code-ide-review-tests--write (expand-file-name "r.md" results) "cci-test saved")
      ;; A new Emacs, which knows no instance yet
      (setq claude-code-ide-instance--all nil
            claude-code-ide-instance--generations (make-hash-table :test 'equal))
      (claude-code-ide-review-recover)
      (should (eq (claude-code-ide-review-tests--state id) 'ended))
      (should (eq (plist-get (claude-code-ide-review-status id) :submit-reason) 'unknown-instance))
      ;; The owner starts: the session start hook submits the result
      (let ((instance (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle))
            (session (claude-code-ide-tests--make-session results)))
        (setf (claude-code-ide-instance-session instance) session)
        (run-hook-with-args 'claude-code-ide-session-start-functions session nil))
      (should (eq (claude-code-ide-review-tests--state id) 'submitted))
      (let ((text (nth 1 (car claude-code-ide-tests--control-sent))))
        ;; The result file was there, so the owner gets it, not an error
        (should (string-match-p "cci-test saved" text))
        (claude-code-ide-review-tests--ack "cci-test-owner" text))
      (should (eq (claude-code-ide-review-tests--state id) 'delivered)))))

;;; Emacs does not run when the review ends

(ert-deftest claude-code-ide-test-review-ends-while-emacs-down ()
  "A review process that ends while Emacs is down is found at the next start."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (let* ((external (start-process "cci-test-external-review" nil "sleep" "30"))
           (track (claude-code-ide-review-track
                   "cci-test-owner" :process (process-id external)
                   :result-file (expand-file-name "out.json" results)
                   :label "cci-test external"))
           (id (plist-get track :review-id)))
      (should (eq (plist-get track :state) 'running))
      (should (equal (plist-get track :pid) (process-id external)))
      ;; Emacs is down; the review writes its result and ends
      (claude-code-ide-review-tests--restart)
      (claude-code-ide-review-tests--write (expand-file-name "out.json" results)
                                           "{\"verdict\": \"cci-test approve\"}")
      (delete-process external)
      (claude-code-ide-review-tests--wait
       (lambda () (not (claude-code-ide-review--pid-live-p (plist-get track :pid)))))
      ;; The next start
      (claude-code-ide-review-recover)
      (should (eq (claude-code-ide-review-tests--state id) 'submitted))
      (claude-code-ide-tests--control-set-state "cci-test-owner" 'idle)
      (claude-code-ide-tests--control-event "cci-test-owner" 'turn-end)
      (let ((text (nth 1 (car claude-code-ide-tests--control-sent))))
        (should (string-match-p "cci-test approve" text))
        (should (string-match-p "Exit status: unknown" text))
        (claude-code-ide-review-tests--ack "cci-test-owner" text))
      (should (eq (claude-code-ide-review-tests--state id) 'delivered)))))

(ert-deftest claude-code-ide-test-review-interrupted-at-quit ()
  "A review that Emacs ended at its quit gives the owner an explicit error."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle)
    (let ((id (plist-get (claude-code-ide-review-track
                          "cci-test-owner" :command '("sleep" "30") :directory results
                          :result-file "never.md")
                         :review-id)))
      (claude-code-ide-review--on-kill-emacs)
      (let* ((process (gethash id claude-code-ide-review--processes))
             (pid (process-id process)))
        (claude-code-ide-review-tests--restart)
        (set-process-sentinel process #'ignore)
        (delete-process process)
        ;; The signal takes effect later on a loaded machine
        (claude-code-ide-review-tests--wait
         (lambda () (not (claude-code-ide-review--pid-live-p pid)))))
      (should (eq (claude-code-ide-review-tests--state id) 'running))
      (claude-code-ide-review-recover)
      (let ((text (nth 1 (car claude-code-ide-tests--control-sent))))
        (should (string-match-p "Error: the review gave no usable result (interrupted)" text))
        (should (string-match-p "Emacs quit while the review ran" text)))
      (should (eq (plist-get (claude-code-ide-review-status id) :error) 'interrupted)))))

(defun claude-code-ide-review-tests--foreign-record (id emacs-pid emacs-start results)
  "Write a running review ID of the Emacs EMACS-PID with EMACS-START.
Its process is gone and its result file in RESULTS exists."
  (claude-code-ide-review-tests--write (expand-file-name (concat id ".md") results)
                                       "cci-test foreign result")
  (claude-code-ide-review--write
   (claude-code-ide-review--record-create
    :review-id id :owner "cci-test-owner" :label "x"
    :pid 999999 :pid-start 1.0 :emacs-pid emacs-pid :emacs-start emacs-start
    :result-file (expand-file-name (concat id ".md") results)
    :state 'running :created-at "2026-11-18T00:00:00Z")))

(ert-deftest claude-code-ide-test-review-other-emacs-keeps-its-review ()
  "A review of another live Emacs stays with it, and is taken when it is gone.
A live Emacs is a process with the recorded ID and start time, also
when its name has no \"emacs\"; a reused process ID does not count."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle)
    (let* ((other (start-process "cci-test-other-emacs" nil "sleep" "30"))
           (pid (process-id other))
           (start (claude-code-ide-review--pid-start pid)))
      (unwind-protect
          (progn
            (claude-code-ide-review-tests--foreign-record "cci-test-other" pid start results)
            ;; The same process ID with another start time: a reused ID
            (claude-code-ide-review-tests--foreign-record "cci-test-reused" pid (- start 100) results)
            (claude-code-ide-review-tests--restart)
            (claude-code-ide-review-recover)
            (should-not (gethash "cci-test-other" claude-code-ide-review--records))
            (should (eq (claude-code-ide-review-tests--state "cci-test-reused") 'submitted))
            (should (= (length claude-code-ide-tests--control-sent) 1))
            ;; Later checks keep the review while that Emacs runs
            (claude-code-ide-review--tick)
            (should-not (gethash "cci-test-other" claude-code-ide-review--records))
            ;; That Emacs quits: the next check takes the review over
            (delete-process other)
            (claude-code-ide-review-tests--wait
             (lambda () (not (claude-code-ide-review--pid-live-p pid start))))
            (claude-code-ide-review--tick)
            (should (eq (claude-code-ide-review-tests--state "cci-test-other") 'submitted))
            (let ((record (gethash "cci-test-other" claude-code-ide-review--records)))
              (should (eql (claude-code-ide-review--record-emacs-pid record) (emacs-pid)))
              (should (equal (claude-code-ide-review--record-emacs-start record)
                             (claude-code-ide-review--emacs-start)))))
        (when (process-live-p other) (delete-process other))))))

;;; Missing or broken result files

(ert-deftest claude-code-ide-test-review-read-result ()
  "Each kind of broken result file gives an explicit error reason."
  (let ((dir (make-temp-file "cci-test-review-read-" t))
        (claude-code-ide-review-max-result-chars 20))
    (unwind-protect
        (cl-flet ((file (name text)
                    (let ((path (expand-file-name name dir)))
                      (when text
                        (let ((coding-system-for-write 'no-conversion))
                          (write-region text nil path nil 'silent)))
                      path)))
          (should (eq (plist-get (claude-code-ide-review--read-result (file "none.md" nil)) :error)
                      'missing))
          (should (eq (plist-get (claude-code-ide-review--read-result dir) :error) 'not-a-file))
          (should (eq (plist-get (claude-code-ide-review--read-result (file "e.md" "  \n")) :error)
                      'empty))
          (should (eq (plist-get (claude-code-ide-review--read-result (file "b.md" "a\0b")) :error)
                      'not-text))
          (should (eq (plist-get (claude-code-ide-review--read-result (file "l.md" "caf\351")) :error)
                      'not-text))
          (should (eq (plist-get (claude-code-ide-review--read-result (file "j.json" "{\"a\": "))
                                 :error)
                      'invalid-json))
          (should (equal (claude-code-ide-review--read-result (file "ok.json" "{\"a\": 1}"))
                         '(:content "{\"a\": 1}")))
          (should (equal (claude-code-ide-review--read-result
                          (file "u.md" (encode-coding-string "café ok" 'utf-8)))
                         '(:content "café ok")))
          (let ((long (claude-code-ide-review--read-result (file "long.md" (make-string 30 ?x)))))
            (should (equal (plist-get long :content) (make-string 20 ?x)))
            (should (= (plist-get long :length) 30))))
      (delete-directory dir t))))

(ert-deftest claude-code-ide-test-review-missing-result-gives-error ()
  "A review without a result file gives the owner an explicit error result.
The output and the arguments of the command never reach the prompt or
the record: only the program name, the exit code and the record path."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle)
    (let* ((track (claude-code-ide-review-track
                   "cci-test-owner"
                   :command '("sh" "-c" "echo cci-test-out-secret; echo cci-test-err-secret >&2; exit 3"
                              "cci-test-arg-secret")
                   :directory results :result-file "missing.md" :label "cci-test crash"))
           (id (plist-get track :review-id))
           (record-file (claude-code-ide-review--file id)))
      (claude-code-ide-review-tests--wait
       (lambda () (not (eq (claude-code-ide-review-tests--state id) 'running))))
      (let ((text (nth 1 (car claude-code-ide-tests--control-sent))))
        (should (string-match-p "Error: the review gave no usable result (missing)" text))
        (should (string-match-p "exited without a result file (exit code 3)" text))
        (should (string-match-p "Exit status: 3" text))
        (should (string-match-p (regexp-quote record-file) text))
        (should (string-match-p (regexp-quote (expand-file-name "missing.md" results)) text))
        (should-not (string-match-p "secret" text))
        (claude-code-ide-review-tests--ack "cci-test-owner" text))
      (should (eq (claude-code-ide-review-tests--state id) 'delivered))
      (should (eq (plist-get (claude-code-ide-review-status id) :error) 'missing))
      (let ((saved (claude-code-ide-session-registry--file-string record-file)))
        (should-not (string-match-p "secret" saved))
        (should-not (string-match-p "echo" saved)))
      (should (equal (claude-code-ide-review--record-program
                      (claude-code-ide-review--read-file record-file))
                     "sh")))))

(ert-deftest claude-code-ide-test-review-cut-result ()
  "A long result is cut, and the prompt says where the full result is."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle)
    (let ((claude-code-ide-review-max-result-chars 10))
      (claude-code-ide-review-tests--command-review
       "cci-test-owner" results "r.md" "0123456789abcdef")
      (let ((text (nth 1 (car claude-code-ide-tests--control-sent))))
        (should (string-match-p "0123456789" text))
        (should-not (string-match-p "abcdef" text))
        (should (string-match-p "the first 10 of 16 characters" text))))))

;;; After a handover

(ert-deftest claude-code-ide-test-review-goes-to-chain-current ()
  "After a handover, the result goes to the current instance of the chain."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-target" "proj" 'idle)
    ;; The source was handed over: it is closed in the registry
    (setf (alist-get "cci-test-source" claude-code-ide-tests--control-registry nil nil #'equal)
          (claude-code-ide-session-registry-entry-create :key "cci-test-source" :state 'closed))
    (cl-letf (((symbol-function 'claude-code-ide-session-registry-chain-current)
               (lambda (id) (and (equal id "cci-test-source") "cci-test-target"))))
      (let ((id (plist-get (claude-code-ide-review-tests--command-review
                            "cci-test-source" results "r.md" "cci-test for the chain")
                           :review-id)))
        (should (equal (plist-get (claude-code-ide-review-status id) :destination)
                       "cci-test-target"))
        (should (equal (car (car claude-code-ide-tests--control-sent)) "cci-test-target"))
        (claude-code-ide-review-tests--ack "cci-test-target"
                                           (nth 1 (car claude-code-ide-tests--control-sent)))
        (should (eq (claude-code-ide-review-tests--state id) 'delivered))
        (should (equal (plist-get (claude-code-ide-review-status id) :owner) "cci-test-source"))))))

(defun claude-code-ide-review-tests--move-inbox (from to)
  "Move the queued prompts of FROM to TO as the handover does.
This is `claude-code-ide-control-move-inbox' of feat/handover: TO gets
a queued copy with the same request ID, and the record of FROM becomes
final, `rejected' with the reason `handed-over'."
  (dolist (record (claude-code-ide-control--pending-records from))
    (unless (claude-code-ide-control--record-sent-at record)
      (let ((pending (claude-code-ide-control--pending-records to)))
        (claude-code-ide-control--write-record
         (claude-code-ide-control--record-create
          :request-id (claude-code-ide-control--record-request-id record)
          :instance-id to
          :seq (1+ (apply #'max 0 (mapcar #'claude-code-ide-control--record-seq pending)))
          :text-hash (claude-code-ide-control--record-text-hash record)
          :text (claude-code-ide-control--record-text record)
          :result 'queued :reason 'handed-over
          :created-at (claude-code-ide-control--record-created-at record))))
      (claude-code-ide-control--finish record 'rejected 'handed-over))))

(ert-deftest claude-code-ide-test-review-follows-moved-inbox ()
  "A result in the inbox of the source follows the inbox move of a handover.
The final `rejected'/`handed-over' record of the source is not a
rejection of the review: the review tracks the copy at the target."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-source" "proj" 'working)
    (let* ((id (plist-get (claude-code-ide-review-tests--command-review
                           "cci-test-source" results "r.md" "cci-test moved")
                          :review-id))
           (text (claude-code-ide-review--record-text (gethash id claude-code-ide-review--records))))
      (should (equal (plist-get (claude-code-ide-review-status id) :destination) "cci-test-source"))
      ;; The handover commits and moves the inbox
      (claude-code-ide-tests--control-add "cci-test-target" "proj" 'working)
      (claude-code-ide-review-tests--move-inbox "cci-test-source" "cci-test-target")
      (should (eq (claude-code-ide-review-tests--inbox "cci-test-source" id) 'rejected))
      (cl-letf (((symbol-function 'claude-code-ide-session-registry-chain-current)
                 (lambda (id) (and (equal id "cci-test-source") "cci-test-target"))))
        (claude-code-ide-review--tick)
        (should (eq (claude-code-ide-review-tests--state id) 'submitted))
        (should (equal (plist-get (claude-code-ide-review-status id) :destination)
                       "cci-test-target"))
        (should-not claude-code-ide-review-tests--warnings)
        (claude-code-ide-tests--control-set-state "cci-test-target" 'idle)
        (claude-code-ide-tests--control-event "cci-test-target" 'turn-end)
        (claude-code-ide-review-tests--ack "cci-test-target" text)
        (should (eq (claude-code-ide-review-tests--state id) 'delivered))
        (should (= (length claude-code-ide-tests--control-sent) 1))))))

(ert-deftest claude-code-ide-test-review-handed-over-at-submit ()
  "A submit that meets the handed-over record of the old owner follows the chain."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-source" "proj" 'working)
    (claude-code-ide-tests--control-add "cci-test-target" "proj" 'working)
    (let ((id (plist-get (claude-code-ide-review-track
                          "cci-test-source" :command '("sleep" "30") :directory results
                          :result-file "r.md")
                         :review-id)))
      ;; A copy of the result was submitted and handed over before the
      ;; record knew it (for example, a crash after the submit)
      (claude-code-ide-control-submit "cci-test-source" "cci-test early"
                                      :request-id (claude-code-ide-review-tests--request id)
                                      :queue t)
      (claude-code-ide-review-tests--move-inbox "cci-test-source" "cci-test-target")
      (let ((record (gethash id claude-code-ide-review--records)))
        (setf (claude-code-ide-review--record-text record) "cci-test early"
              (claude-code-ide-review--record-state record) 'ended)
        (cl-letf (((symbol-function 'claude-code-ide-session-registry-chain-current)
                   (lambda (_id) nil)))
          ;; The chain does not know the target yet: the review waits
          (claude-code-ide-review--submit record)
          (should (eq (claude-code-ide-review-tests--state id) 'submitted))
          (should-not claude-code-ide-review-tests--warnings))
        (cl-letf (((symbol-function 'claude-code-ide-session-registry-chain-current)
                   (lambda (id) (and (equal id "cci-test-source") "cci-test-target"))))
          (claude-code-ide-review--tick)
          (should (equal (plist-get (claude-code-ide-review-status id) :destination)
                         "cci-test-target"))
          (should (eq (claude-code-ide-review-tests--inbox "cci-test-target" id) 'queued)))))))

(ert-deftest claude-code-ide-test-review-lost-inbox-record-is-sent-again ()
  "A submitted result that no inbox knows is submitted again, not lost."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (let ((id (plist-get (claude-code-ide-review-tests--command-review
                          "cci-test-owner" results "r.md" "cci-test again")
                         :review-id)))
      (delete-file (claude-code-ide-control--record-file
                    "cci-test-owner" (claude-code-ide-review-tests--request id)))
      (remhash (claude-code-ide-control-inbox-directory-of "cci-test-owner")
               claude-code-ide-control--index)
      (claude-code-ide-review--tick)
      (should (eq (claude-code-ide-review-tests--state id) 'submitted))
      (should (eq (claude-code-ide-review-tests--inbox "cci-test-owner" id) 'queued)))))

(ert-deftest claude-code-ide-test-review-request-id-namespace ()
  "The inbox request ID is review:ID, and only that ID delivers the review."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (let ((id (plist-get (claude-code-ide-review-tests--command-review
                          "cci-test-owner" results "r.md" "cci-test ns" :review-id "cci-test-ns")
                         :review-id)))
      (should (eq (claude-code-ide-review-tests--inbox "cci-test-owner" id) 'queued))
      (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-owner" id) :status)
                  'error))
      ;; Another prompt whose request ID is the bare review ID
      (claude-code-ide-review--on-delivered "cci-test-owner" "cci-test-ns")
      (should (eq (claude-code-ide-review-tests--state id) 'submitted))
      (claude-code-ide-review--on-delivered "cci-test-owner" "other:cci-test-ns")
      (should (eq (claude-code-ide-review-tests--state id) 'submitted))
      (claude-code-ide-review--on-delivered "cci-test-owner" "review:cci-test-ns")
      (should (eq (claude-code-ide-review-tests--state id) 'delivered)))))

(ert-deftest claude-code-ide-test-review-text-failure-keeps-running ()
  "A result text that cannot be made never submits nil text; a later check retries."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle)
    (let* ((fail t)
           (claude-code-ide-review-format-function
            (lambda (info)
              (if fail (error "cci-test format failed")
                (claude-code-ide-review-format-result info))))
           (track (claude-code-ide-review-track
                   "cci-test-owner"
                   :command (list "sh" "-c" "printf 'cci-test retry' > r.md")
                   :directory results :result-file "r.md"))
           (id (plist-get track :review-id))
           (record (gethash id claude-code-ide-review--records)))
      (claude-code-ide-review-tests--wait
       (lambda () (claude-code-ide-review--record-ended-at record)))
      (should (eq (claude-code-ide-review-tests--state id) 'running))
      (should (eql (claude-code-ide-review--record-exit-status record) 0))
      (should-not claude-code-ide-tests--control-sent)
      (should (eq (plist-get (claude-code-ide-control-request-status
                              "cci-test-owner" (claude-code-ide-review-tests--request id))
                             :status)
                  'error))
      ;; The record on disk also says running
      (claude-code-ide-review--tick)
      (should (eq (claude-code-ide-review--record-state
                   (claude-code-ide-review--read-file (claude-code-ide-review--file id)))
                  'running))
      ;; The next check after the fix submits the result
      (setq fail nil)
      (claude-code-ide-review--tick)
      (should (eq (claude-code-ide-review-tests--state id) 'submitted))
      (should (string-match-p "cci-test retry" (nth 1 (car claude-code-ide-tests--control-sent))))
      (should (string-match-p "Exit status: 0" (nth 1 (car claude-code-ide-tests--control-sent)))))))

(ert-deftest claude-code-ide-test-review-retry-limit ()
  "A result whose owner stays unknown becomes final after the time limit, with a warning."
  (claude-code-ide-review-tests--with-review
    (let ((record (claude-code-ide-review--record-create
                   :review-id "cci-test-limit" :owner "cci-test-gone" :label "cci-test limit"
                   :emacs-pid (emacs-pid) :result-file "/nonexistent/cci-test/r.md"
                   :state 'ended :text "cci-test waiting" :created-at "2026-11-18T00:00:00Z")))
      (claude-code-ide-review--write record)
      ;; Within the limit: it waits
      (claude-code-ide-review--tick)
      (should (eq (claude-code-ide-review-tests--state "cci-test-limit") 'ended))
      (should (= (claude-code-ide-review--record-attempts record) 1))
      (claude-code-ide-review--tick)
      (should (= (claude-code-ide-review--record-attempts record) 2))
      (should-not claude-code-ide-review-tests--warnings)
      ;; After the limit: final, with a warning that names both files
      (let ((claude-code-ide-review-retry-seconds 0))
        (claude-code-ide-review--tick))
      (should (eq (claude-code-ide-review-tests--state "cci-test-limit") 'rejected))
      (should (eq (plist-get (claude-code-ide-review-status "cci-test-limit") :submit-reason)
                  'unknown-instance))
      (let ((warning (car claude-code-ide-review-tests--warnings)))
        (should (string-match-p "/nonexistent/cci-test/r.md" warning))
        (should (string-match-p (regexp-quote (claude-code-ide-review--file "cci-test-limit"))
                                warning)))
      (should (equal (claude-code-ide-review--record-text record) "cci-test waiting"))
      ;; Nothing retries a final review
      (claude-code-ide-review--tick)
      (should (= (length claude-code-ide-review-tests--warnings) 1)))))

(ert-deftest claude-code-ide-test-review-owner-worktree-when-not-running ()
  "A command of an owner that does not run starts in the owner's recorded worktree."
  (claude-code-ide-review-tests--with-review
    (let ((worktree (file-name-as-directory (make-temp-file "cci-test-review-wt-" t)))
          (default-directory results))
      (unwind-protect
          (progn
            (setf (alist-get "cci-test-owner" claude-code-ide-tests--control-registry nil nil #'equal)
                  (claude-code-ide-session-registry-entry-create
                   :key "cci-test-owner" :state 'open :worktree worktree
                   :project-dir "/nonexistent/cci-test/"))
            (let* ((id (plist-get (claude-code-ide-review-track
                                   "cci-test-owner" :command '("sh" "-c" "pwd > r.md")
                                   :result-file "r.md")
                                  :review-id))
                   (record (gethash id claude-code-ide-review--records)))
              (should (equal (claude-code-ide-review--record-directory record) worktree))
              (should (equal (claude-code-ide-review--record-result-file record)
                             (expand-file-name "r.md" worktree)))
              (claude-code-ide-review-tests--wait
               (lambda () (not (eq (claude-code-ide-review-tests--state id) 'running))))
              (should (file-exists-p (expand-file-name "r.md" worktree)))))
        (delete-directory worktree t)))))

;;; Final results that are not deliveries

(ert-deftest claude-code-ide-test-review-unacknowledged-warns ()
  "A result without an acknowledgement is final, keeps its text and warns."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle)
    (let ((id (plist-get (claude-code-ide-review-tests--command-review
                          "cci-test-owner" results "r.md" "cci-test lost ack")
                         :review-id))
          (claude-code-ide-control-ack-timeout 0))
      (should (= (length claude-code-ide-tests--control-sent) 1))
      (claude-code-ide-review--tick)
      (should (eq (claude-code-ide-review-tests--state id) 'unacknowledged))
      (should (string-match-p "cci-test lost ack"
                              (claude-code-ide-review--record-text
                               (gethash id claude-code-ide-review--records))))
      (should (cl-some (lambda (w) (string-match-p (regexp-quote id) w))
                       claude-code-ide-review-tests--warnings))
      ;; It is never sent again
      (claude-code-ide-review--tick)
      (should (= (length claude-code-ide-tests--control-sent) 1)))))

(ert-deftest claude-code-ide-test-review-no-submit-is-rejected ()
  "A provider without submit-prompt rejects the result, with a warning."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-register-provider
     (claude-code-ide-provider-create :name 'cci-test-mute :display-name "Mute"
                                      :buffer-name-prefix "cci-mute"))
    (let ((instance (claude-code-ide-tests--control-add "cci-test-mute-owner" "proj" 'idle)))
      (setf (claude-code-ide-instance-provider instance) 'cci-test-mute))
    (let ((id (plist-get (claude-code-ide-review-tests--command-review
                          "cci-test-mute-owner" results "r.md" "cci-test mute")
                         :review-id)))
      (should (eq (claude-code-ide-review-tests--state id) 'rejected))
      (should (eq (plist-get (claude-code-ide-review-status id) :submit-reason) 'no-submit))
      (should claude-code-ide-review-tests--warnings)
      (should (claude-code-ide-review--record-text (gethash id claude-code-ide-review--records))))))

;;; Records, arguments and the control slot

(ert-deftest claude-code-ide-test-review-record-file ()
  "The record is a private JSON file that a new Emacs reads back."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (let* ((id (plist-get (claude-code-ide-review-track
                           "cci-test-owner" :command '("sleep" "30") :directory results
                           :result-file "r.md" :label "cci-test label" :review-id "../x y")
                          :review-id))
           (file (claude-code-ide-review--file id)))
      (should (equal id "../x y"))
      (should (equal (file-name-directory file)
                     (file-name-as-directory claude-code-ide-review-directory)))
      (should (= (file-modes file) #o600))
      (should (= (file-modes claude-code-ide-review-directory) #o700))
      (should-not (directory-files claude-code-ide-review-directory nil "\\.tmp\\'"))
      (claude-code-ide-review-tests--restart)
      (let ((status (claude-code-ide-review-status id)))
        (should (equal (plist-get status :label) "cci-test label"))
        (should (eq (plist-get status :state) 'running))
        (should (equal (plist-get status :result-file) (expand-file-name "r.md" results))))
      (let ((record (claude-code-ide-review--read-file file)))
        (should (equal (claude-code-ide-review--record-program record) "sleep"))
        (should (eq (claude-code-ide-review--record-managed record) t))
        (should (null (claude-code-ide-review--record-interrupted record)))))))

(ert-deftest claude-code-ide-test-review-arguments ()
  "Bad arguments give error results, a known review ID is a duplicate."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (cl-flet ((reason (&rest args)
                (plist-get (apply #'claude-code-ide-review-track args) :reason)))
      (should (eq (reason "../bad" :command '("true") :result-file "r" :directory results)
                  'invalid-instance-id))
      (should (eq (reason "cci-test-owner" :result-file "r" :directory results) 'no-process))
      (should (eq (reason "cci-test-owner" :process 1 :command '("true") :result-file "r")
                  'process-and-command))
      (should (eq (reason "cci-test-owner" :command "true" :result-file "r") 'invalid-command))
      (should (eq (reason "cci-test-owner" :process "12" :result-file "r") 'invalid-process))
      (should (eq (reason "cci-test-owner" :command '("true")) 'no-result-file))
      (should (eq (reason "cci-test-owner" :command '("true") :result-file "r"
                          :directory "/nonexistent/cci-test")
                  'no-directory))
      (should (eq (reason "cci-test-nobody" :command '("true") :result-file "r" :directory results)
                  'unknown-instance))
      (should (eq (reason "cci-test-owner" :command '("/nonexistent/cci-test-tool")
                          :result-file "r" :directory results)
                  'start-failed)))
    (let ((first (claude-code-ide-review-track "cci-test-owner" :command '("sleep" "30")
                                               :directory results :result-file "r"
                                               :review-id "cci-test-dup"))
          (second (claude-code-ide-review-track "cci-test-owner" :command '("sleep" "31")
                                                :directory results :result-file "r"
                                                :review-id "cci-test-dup")))
      (should (eq (plist-get first :status) 'ok))
      (should (plist-get second :duplicate))
      (should (eq (plist-get second :state) 'running))
      (should (= (hash-table-count claude-code-ide-review--processes) 1)))))

(ert-deftest claude-code-ide-test-review-control-slot-and-tool ()
  "The track-review operation and its coordinator tool work."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (should (eq (alist-get 'track-review claude-code-ide-control-operations)
                #'claude-code-ide-review-track))
    (let ((result (claude-code-ide-control-call 'track-review "cci-test-owner"
                                                :command '("sleep" "30") :directory results
                                                :result-file "r.md")))
      (should (eq (plist-get result :status) 'ok)))
    (should-not (cl-find "track_review" claude-code-ide-control--extra-tool-specs
                         :key (lambda (s) (plist-get s :name)) :test #'equal))
    (let ((spec (cl-find "claude-code-ide-control-track-review"
                         claude-code-ide-control--extra-tool-specs
                         :key (lambda (s) (plist-get s :name)) :test #'equal)))
      (should spec)
      (should (equal (mapcar (lambda (arg) (plist-get arg :name)) (plist-get spec :args))
                     '("instance_id" "result_file" "label" "review_id" "pid" "command" "directory"))))
    ;; The MCP function: JSON out, an array command in
    (let ((json (json-read-from-string
                 (claude-code-ide-review--mcp-track "cci-test-owner" "r2.md" "cci-test mcp"
                                                    "cci-test-mcp" nil ["sleep" "30"] results))))
      (should (equal (alist-get 'status json) "ok"))
      (should (equal (alist-get 'review_id json) "cci-test-mcp"))
      (should (equal (claude-code-ide-review--record-program
                      (gethash "cci-test-mcp" claude-code-ide-review--records))
                     "sleep")))
    ;; Without the scope check, the setup of the coordinator tools adds it with the scope
    (let ((claude-code-ide-mcp-server-tools nil))
      (let ((tools (claude-code-ide-control-setup-mcp-tools t)))
        (should (eq (plist-get (cl-find "claude-code-ide-control-track-review" tools
                                        :key (lambda (s) (plist-get s :name)) :test #'equal)
                               :scope)
                    'coordinator))))))

(ert-deftest claude-code-ide-test-review-process-ids ()
  "The process IDs of the running reviews are known, for the stray scan."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (should-not (claude-code-ide-review-process-ids))
    (let* ((id (plist-get (claude-code-ide-review-track
                           "cci-test-owner" :command '("sleep" "30") :directory results
                           :result-file "r.md")
                          :review-id))
           (process (gethash id claude-code-ide-review--processes)))
      (should (equal (claude-code-ide-review-process-ids) (list (process-id process))))
      (delete-process process)
      (claude-code-ide-review-tests--wait
       (lambda () (not (eq (claude-code-ide-review-tests--state id) 'running))))
      (should-not (claude-code-ide-review-process-ids)))))

(ert-deftest claude-code-ide-test-review-given-process-object ()
  "A process object that the caller started counts as the review process."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle)
    (let* ((file (expand-file-name "p.md" results))
           (process (make-process :name "cci-test-given" :connection-type 'pipe :noquery t
                                  :command (list "sh" "-c" (format "printf given > %s"
                                                                   (shell-quote-argument file)))))
           (id (plist-get (claude-code-ide-review-track "cci-test-owner" :process process
                                                        :result-file file)
                          :review-id)))
      (claude-code-ide-review-tests--wait
       (lambda () (not (eq (claude-code-ide-review-tests--state id) 'running))))
      (should (string-match-p "given" (nth 1 (car claude-code-ide-tests--control-sent)))))))

;;; Ediff frames

(defvar claude-code-ide-review-tests--ediff-calls nil
  "The calls of the mocked `ediff-files', newest first.")

(defmacro claude-code-ide-review-tests--with-ediff-tables (&rest body)
  "Run BODY with empty tables of the dedicated diff frames."
  (declare (indent 0))
  `(let ((claude-code-ide-mcp--ediff-frames (make-hash-table :test 'equal))
         (claude-code-ide-mcp--ediff-controls (make-hash-table :test 'equal))
         (claude-code-ide-mcp--ediff-queue (make-hash-table :test 'equal))
         (claude-code-ide-mcp--ediff-frame nil)
         (claude-code-ide-mcp--ediff-generation 0)
         (claude-code-ide-mcp--ediff-queue-timer nil)
         (claude-code-ide-review-tests--ediff-calls nil)
         (frame (selected-frame)))
     (unwind-protect
         (progn ,@body)
       (when (timerp claude-code-ide-mcp--ediff-queue-timer)
         (cancel-timer claude-code-ide-mcp--ediff-queue-timer))
       (set-frame-parameter frame 'claude-code-ide-ediff nil))))

(defun claude-code-ide-review-tests--fake-control (name)
  "Return a new buffer NAME that stands for an ediff control buffer."
  (generate-new-buffer name))

(ert-deftest claude-code-ide-test-ediff-files-in-frame-queue ()
  "A diff for a frame with an open ediff waits, then opens in order."
  (claude-code-ide-review-tests--with-ediff-tables
    (let ((controls nil))
      (cl-letf (((symbol-function 'ediff-files)
                 (lambda (a b hooks)
                   (push (list a b) claude-code-ide-review-tests--ediff-calls)
                   ;; ediff runs the startup hooks in its control buffer
                   (let ((control (claude-code-ide-review-tests--fake-control "*cci-test-control*")))
                     (push control controls)
                     (with-current-buffer control
                       (mapc #'funcall hooks)))))
                ((symbol-function 'make-frame)
                 (lambda (&optional parameters)
                   (set-frame-parameter frame 'claude-code-ide-ediff
                                        (alist-get 'claude-code-ide-ediff parameters))
                   frame))
                ((symbol-function 'select-frame-set-input-focus) #'ignore)
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args) (apply fn args) nil))
                ((symbol-function 'message) #'ignore))
        (claude-code-ide-ediff-files-in-frame "cci-test-L" "/tmp/a1" "/tmp/b1")
        (should (equal claude-code-ide-review-tests--ediff-calls '(("/tmp/a1" "/tmp/b1"))))
        (should (equal (frame-parameter frame 'claude-code-ide-ediff) "cci-test-L"))
        (should (claude-code-ide-mcp-ediff-frame-p frame))
        ;; Two more diffs wait; the open one stays
        (claude-code-ide-ediff-files-in-frame "cci-test-L" "/tmp/a2" "/tmp/b2")
        (claude-code-ide-ediff-files-in-frame "cci-test-L" "/tmp/a3" "/tmp/b3")
        (should (= (length claude-code-ide-review-tests--ediff-calls) 1))
        (should (= (length (gethash "cci-test-L" claude-code-ide-mcp--ediff-queue)) 2))
        ;; The cleanup keeps a frame with an open ediff or a waiting diff
        (let ((deleted nil))
          (cl-letf (((symbol-function 'frame-list) (lambda () (list frame frame)))
                    ((symbol-function 'delete-frame) (lambda (f) (push f deleted))))
            (claude-code-ide-mcp--maybe-delete-ediff-frame)
            (should-not deleted)
            ;; The first ediff ends: the second opens
            (kill-buffer (car controls))
            (should (equal (car claude-code-ide-review-tests--ediff-calls) '("/tmp/a2" "/tmp/b2")))
            (claude-code-ide-mcp--maybe-delete-ediff-frame)
            (should-not deleted)
            (kill-buffer (car controls))
            (should (equal (car claude-code-ide-review-tests--ediff-calls) '("/tmp/a3" "/tmp/b3")))
            (kill-buffer (car controls))
            (should (= (length claude-code-ide-review-tests--ediff-calls) 3))
            ;; Nothing open and nothing waits: the frame can go
            (claude-code-ide-mcp--maybe-delete-ediff-frame)
            (should (equal deleted (list frame)))))))))

(ert-deftest claude-code-ide-test-ediff-open-diff-takes-free-frame ()
  "An openDiff never takes a frame that has an open ediff."
  (claude-code-ide-review-tests--with-ediff-tables
    (let ((session (claude-code-ide-tests--make-session "/tmp/cci-test-proj/"))
          (control (claude-code-ide-review-tests--fake-control "*cci-test-control*")))
      (unwind-protect
          (progn
            (should (equal (claude-code-ide-mcp--free-ediff-label session) "cci-test-proj"))
            (puthash "cci-test-proj" frame claude-code-ide-mcp--ediff-frames)
            (claude-code-ide-mcp--register-ediff-control "cci-test-proj" control)
            (should (equal (claude-code-ide-mcp--free-ediff-label session) "cci-test-proj <2>"))
            ;; A waiting diff also keeps the frame
            (kill-buffer control)
            (should (equal (claude-code-ide-mcp--free-ediff-label session) "cci-test-proj"))
            (puthash "cci-test-proj" '(("/tmp/a" "/tmp/b" nil)) claude-code-ide-mcp--ediff-queue)
            (should (equal (claude-code-ide-mcp--free-ediff-label session) "cci-test-proj <2>")))
        (when (buffer-live-p control) (kill-buffer control))))))

(ert-deftest claude-code-ide-test-ediff-queue-after-unregistered-ediff ()
  "A diff that waits behind an ediff that this file did not start opens after it.
The end of any ediff control buffer starts the next waiting diff, and
the queue timer opens a waiting diff whose frame became free."
  (claude-code-ide-review-tests--with-ediff-tables
    (let ((foreign (generate-new-buffer "*cci-test-foreign-ediff*"))
          (scheduled nil)
          (timers nil))
      (unwind-protect
          (cl-letf (((symbol-function 'ediff-files)
                     (lambda (a b _hooks) (push (list a b) claude-code-ide-review-tests--ediff-calls)))
                    ((symbol-function 'select-frame-set-input-focus) #'ignore)
                    ((symbol-function 'run-at-time)
                     (lambda (_time _repeat fn &rest args) (push (cons fn args) scheduled) nil))
                    ((symbol-function 'run-with-timer)
                     (lambda (&rest args) (push args timers) nil))
                    ((symbol-function 'message) #'ignore))
            (puthash "cci-test-U" frame claude-code-ide-mcp--ediff-frames)
            (delete-other-windows)
            ;; An ediff that another command started shows in the frame
            (with-current-buffer foreign (setq major-mode 'ediff-mode))
            (set-window-buffer (selected-window) foreign)
            (claude-code-ide-ediff-files-in-frame "cci-test-U" "/tmp/u-a" "/tmp/u-b")
            (should-not claude-code-ide-review-tests--ediff-calls)
            (should (gethash "cci-test-U" claude-code-ide-mcp--ediff-queue))
            (should timers)
            ;; That ediff quits: its control buffer dies
            (setq scheduled nil)
            (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
            (kill-buffer foreign)
            (should scheduled)
            (dolist (call scheduled) (apply (car call) (cdr call)))
            (should (equal claude-code-ide-review-tests--ediff-calls '(("/tmp/u-a" "/tmp/u-b"))))
            ;; The queue timer opens a diff whose frame is free
            (puthash "cci-test-U" '(("/tmp/v-a" "/tmp/v-b" nil)) claude-code-ide-mcp--ediff-queue)
            (claude-code-ide-mcp--ediff-queue-tick)
            (should (equal (car claude-code-ide-review-tests--ediff-calls) '("/tmp/v-a" "/tmp/v-b")))
            (should-not (gethash "cci-test-U" claude-code-ide-mcp--ediff-queue)))
        (when (buffer-live-p foreign) (kill-buffer foreign))))))

(ert-deftest claude-code-ide-test-ediff-frame-needs-the-table ()
  "Only a frame of the table is a diff frame; a copied frame parameter is not."
  (claude-code-ide-review-tests--with-ediff-tables
    (set-frame-parameter frame 'claude-code-ide-ediff "cci-test-copy")
    (should-not (claude-code-ide-mcp-ediff-frame-p frame))
    (should (eq (claude-code-ide-mcp-call-outside-ediff-frame #'selected-frame) frame))
    (puthash "cci-test-copy" frame claude-code-ide-mcp--ediff-frames)
    (should (claude-code-ide-mcp-ediff-frame-p frame))))

(defmacro claude-code-ide-review-tests--with-open-diff (&rest body)
  "Run BODY with a session, a file, and the selected frame as a diff frame.
BODY can refer to `session', `file' and `arguments', the arguments of
an openDiff of `file'."
  (declare (indent 0))
  `(claude-code-ide-review-tests--with-ediff-tables
     (let* ((file (make-temp-file "cci-test-diff-" nil ".txt" "old\n"))
            (session (claude-code-ide-tests--make-session "/tmp/cci-test-proj/"))
            (arguments `((old_file_path . ,file) (new_file_path . ,file)
                         (new_file_contents . "new\n") (tab_name . "cci-test-tab-name")))
            (claude-code-ide-ediff-frame nil))
       (puthash "cci-test-L" frame claude-code-ide-mcp--ediff-frames)
       (unwind-protect
           (progn ,@body)
         ;; The cleanup deletes the diff frames without an ediff: the
         ;; selected frame of the test is not one any more
         (clrhash claude-code-ide-mcp--ediff-frames)
         (ignore-errors (claude-code-ide-mcp--cleanup-diff "cci-test-tab-name" session))
         (when-let* ((buffer (find-buffer-visiting file)))
           (kill-buffer buffer))
         (delete-file file)))))

(ert-deftest claude-code-ide-test-ediff-open-diff-leaves-diff-frame-first ()
  "openDiff leaves the diff frame before it switches the tab, in the target frame."
  (claude-code-ide-review-tests--with-open-diff
    (let ((steps nil)
          (claude-code-ide-switch-tab-on-ediff t)
          (tab-bar-mode t))
      (setf (claude-code-ide-mcp-session-original-tab session) '((name . "cci-test-tab")))
      (cl-letf (((symbol-function 'claude-code-ide-mcp--frame-outside-ediff) (lambda () frame))
                ((symbol-function 'claude-code-ide-mcp--other-frame) (lambda () frame))
                ((symbol-function 'select-frame-set-input-focus)
                 (lambda (&rest _) (push 'leave-diff-frame steps)))
                ((symbol-function 'tab-bar--current-tab) (lambda () '((name . "cci-test-other"))))
                ((symbol-function 'tab-bar-select-tab-by-name)
                 (lambda (&rest _) (push 'switch-tab steps)))
                ((symbol-function 'ediff-buffers) (lambda (&rest _) (push 'ediff steps))))
        (claude-code-ide-mcp-handle-open-diff arguments session)
        (should (equal (reverse steps) '(leave-diff-frame switch-tab ediff)))))))

(ert-deftest claude-code-ide-test-ediff-open-diff-makes-frame-outside ()
  "Without another frame, openDiff makes one, and never uses the busy diff frame."
  (claude-code-ide-review-tests--with-open-diff
    (let ((made nil)
          (ediffs nil))
      (cl-letf (((symbol-function 'claude-code-ide-mcp--other-frame) #'ignore)
                ((symbol-function 'make-frame)
                 (lambda (&rest _) (setq made t) (error "cci-test: no frame")))
                ((symbol-function 'select-frame-set-input-focus) #'ignore)
                ((symbol-function 'ediff-buffers) (lambda (&rest _) (setq ediffs t))))
        (should-error (claude-code-ide-mcp-handle-open-diff arguments session) :type 'mcp-error)
        (should made)
        (should-not ediffs)
        (should-not (gethash "cci-test-tab-name"
                             (claude-code-ide-mcp-session-active-diffs session)))))))

(defun claude-code-ide-review-tests--frame-terminal ()
  "Return the terminal of a graphic frame, on which a test can make frames, or nil."
  (when-let* ((graphic (cl-find-if (lambda (f) (frame-parameter f 'window-system))
                                   (frame-list))))
    (frame-terminal graphic)))

(defun claude-code-ide-review-tests--make-frame (name &rest parameters)
  "Make an invisible frame NAME with PARAMETERS on a graphic terminal."
  (make-frame (append `((terminal . ,(claude-code-ide-review-tests--frame-terminal))
                        (visibility . nil)
                        (name . ,name))
                      parameters)))

(cl-defun claude-code-ide-review-tests--start (spec &key call)
  "Start an instance as SPEC says, with the real display of its buffer.
The terminal and the MCP server are mocked.  CALL, when non-nil, runs
in place of the start.  Return the terminal buffer."
  (let* ((buffer (generate-new-buffer "*cci-test-review-cli*"))
         (process (start-process "cci-test-review-cli" nil "sleep" "30"))
         (claude-code-ide-session-start-functions nil)
         (claude-code-ide-session-prepare-functions nil)
         (claude-code-ide-cli-args-functions nil))
    (with-current-buffer buffer (set-process-buffer process buffer))
    (cl-letf (((symbol-function 'claude-code-ide--ensure-cli) (lambda () t))
              ((symbol-function 'claude-code-ide--terminal-ensure-backend) #'ignore)
              ((symbol-function 'claude-code-ide-mcp-create-session)
               (lambda (dir session-id &optional instance-name _no-ide-server)
                 (claude-code-ide-tests--make-session
                  dir :session-id session-id :instance-name instance-name)))
              ((symbol-function 'claude-code-ide--create-terminal-session)
               (lambda (&rest _) (cons buffer process)))
              ((symbol-function 'claude-code-ide-mcp-server-session-started) #'ignore)
              ((symbol-function 'claude-code-ide-mcp-server-session-ended) #'ignore)
              ((symbol-function 'claude-code-ide-mcp-server-update-session-buffer) #'ignore)
              ((symbol-function 'claude-code-ide--setup-terminal-keybindings) #'ignore)
              ((symbol-function 'claude-code-ide--maybe-install-global-advice) #'ignore)
              ((symbol-function 'claude-code-ide--sync-terminal-dimensions) #'ignore)
              ((symbol-function 'claude-code-ide--sync-all-session-windows) #'ignore)
              ((symbol-function 'run-with-timer) #'ignore)
              ((symbol-function 'sleep-for) #'ignore)
              ((symbol-function 'claude-code-ide-log) #'ignore)
              ((symbol-function 'message) #'ignore))
      (let ((claude-code-ide-terminal-backend 'ghostel)
            (claude-code-ide-use-side-window t)
            (claude-code-ide-focus-on-open t))
        (if call
            (funcall call)
          (claude-code-ide--start-session nil nil spec))))
    buffer))

(defmacro claude-code-ide-review-tests--with-starts (&rest body)
  "Run BODY with no instances, a stub and a second stub provider, and clean up.
BODY can refer to the project folder as `project'."
  (declare (indent 0))
  `(claude-code-ide-tests--with-instances
     (claude-code-ide-tests--clear-processes)
     (claude-code-ide-tests--with-registry
       (let* ((project (file-name-as-directory (make-temp-file "cci-test-review-proj-" t)))
              (claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry))
              (command (lambda (&rest _) (list :command "cci-stub" :environment nil))))
         (claude-code-ide-register-provider
          (claude-code-ide-tests--stub-provider :launch command :resume command :fork command))
         (claude-code-ide-register-provider
          (claude-code-ide-provider-create
           :name 'cci-test-other :display-name "Other" :buffer-name-prefix "cci-other"
           :detect (lambda (&optional _) '(:available t :program "/x/cci-other" :version unknown))
           :launch command :resume command :fork command))
         (unwind-protect
             (progn ,@body)
           (dolist (buffer (buffer-list))
             (when (string-prefix-p "*cci-test-review-cli*" (buffer-name buffer))
               (let ((kill-buffer-hook nil) (kill-buffer-query-functions nil))
                 (kill-buffer buffer))))
           (claude-code-ide-tests--clear-processes)
           (delete-directory project t))))))

(defun claude-code-ide-review-tests--each-start (project)
  "Return the starts of the tests: a list of (NAME . THUNK) in PROJECT.
Each thunk starts an instance and returns its terminal buffer: a
launch, a resume, a restore of a registry entry, and a handover target
with another provider (a fork, then a fresh start)."
  (list
   (cons 'launch
         (lambda ()
           (claude-code-ide-review-tests--start
            (claude-code-ide-start-spec-create :directory project :provider 'cci-test-stub
                                               :instance-name "launch"))))
   (cons 'resume
         (lambda ()
           (claude-code-ide-review-tests--start
            (claude-code-ide-start-spec-create :directory project :provider 'cci-test-stub
                                               :instance-name "resume"
                                               :resume-id "cci-test-native-resume"))))
   (cons 'restore
         (lambda ()
           (claude-code-ide-review-tests--start
            nil
            :call (lambda ()
                    (claude-code-ide-session-registry--start-entry
                     (claude-code-ide-tests--registry-entry
                      "cci-test-restore" :provider 'cci-test-stub :project-dir project
                      :instance-name "restore" :emacs-pid nil)
                     nil)))))
   (cons 'handover-fork
         (lambda ()
           (claude-code-ide-review-tests--start
            (claude-code-ide-start-spec-create :directory project :provider 'cci-test-other
                                               :instance-name "target-fork"
                                               :resume-id "cci-test-native-old" :fork t))))
   (cons 'handover-fresh
         (lambda ()
           (claude-code-ide-review-tests--start
            (claude-code-ide-start-spec-create :directory project :provider 'cci-test-other
                                               :instance-name "target"
                                               :prompt "cci-test handover document"))))))

(ert-deftest claude-code-ide-test-ediff-frame-keeps-out-cli-windows ()
  "A launch, a resume, a restore or a handover target never uses the diff frame.
In batch Emacs the selected frame is the diff frame and no other frame
can be made: the CLI buffer is then not shown, and the windows and the
open ediff of the frame stay as they were."
  (claude-code-ide-review-tests--with-starts
    (claude-code-ide-review-tests--with-ediff-tables
      (let ((control (claude-code-ide-review-tests--fake-control "*cci-test-control*")))
        (unwind-protect
            (cl-letf (((symbol-function 'make-frame)
                       (lambda (&rest _) (error "cci-test: no frame"))))
              (delete-other-windows)
              (set-frame-parameter frame 'claude-code-ide-ediff "cci-test-L")
              (puthash "cci-test-L" frame claude-code-ide-mcp--ediff-frames)
              (claude-code-ide-mcp--register-ediff-control "cci-test-L" control)
              (set-window-buffer (selected-window) control)
              (let ((before (window-list frame 'never)))
                (dolist (start (claude-code-ide-review-tests--each-start project))
                  (let ((buffer (funcall (cdr start))))
                    (should (buffer-live-p buffer))
                    (should-not (get-buffer-window buffer frame))
                    (should (equal (window-list frame 'never) before))
                    (should (eq (window-buffer (car before)) control))
                    (should (eq (selected-frame) frame))))
                ;; The open ediff and its queue are still there
                (should (equal (claude-code-ide-mcp--ediff-live-controls "cci-test-L")
                               (list control)))
                (should (eq (gethash "cci-test-L" claude-code-ide-mcp--ediff-frames) frame))))
          (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
          (kill-buffer control))))))

(ert-deftest claude-code-ide-test-ediff-frame-keeps-out-cli-windows-real-frames ()
  "With real frames, each start shows its CLI in another frame, not the diff frame.
The diff frame stays selected, keeps its windows and its open ediff."
  (skip-unless (claude-code-ide-review-tests--frame-terminal))
  (claude-code-ide-review-tests--with-starts
    (claude-code-ide-review-tests--with-ediff-tables
      (let* ((main (claude-code-ide-review-tests--make-frame "cci-test-main"))
             (diff (claude-code-ide-review-tests--make-frame
                    "ediff cci-test-L" '(claude-code-ide-ediff . "cci-test-L")))
             (control (claude-code-ide-review-tests--fake-control "*cci-test-control*")))
        (unwind-protect
            (progn
              (puthash "cci-test-L" diff claude-code-ide-mcp--ediff-frames)
              (claude-code-ide-mcp--register-ediff-control "cci-test-L" control)
              (select-frame diff)
              (set-window-buffer (frame-selected-window diff) control)
              (let ((before (window-list diff 'never)))
                (dolist (start (claude-code-ide-review-tests--each-start project))
                  (let ((buffer (funcall (cdr start))))
                    (should-not (get-buffer-window buffer diff))
                    (should (get-buffer-window buffer t))
                    (should-not (claude-code-ide-mcp-ediff-frame-p
                                 (window-frame (get-buffer-window buffer t))))
                    (should (equal (window-list diff 'never) before))
                    (should (eq (selected-frame) diff))))
                (should (equal (claude-code-ide-mcp--ediff-live-controls "cci-test-L")
                               (list control)))))
          (kill-buffer control)
          (select-frame frame)
          (dolist (f (list main diff))
            (when (frame-live-p f) (delete-frame f t))))))))

(ert-deftest claude-code-ide-test-ediff-real-queue ()
  "With real frames and ediff, a waiting diff opens when the open one quits."
  (skip-unless (and (claude-code-ide-review-tests--frame-terminal)
                    (executable-find ediff-diff-program)))
  (claude-code-ide-review-tests--with-ediff-tables
    (let* ((dir (make-temp-file "cci-test-ediff-" t))
           (files (mapcar (lambda (name)
                            (let ((file (expand-file-name name dir)))
                              (with-temp-file file (insert name "\nline\n"))
                              file))
                          '("a1" "b1" "a2" "b2")))
           (diff (claude-code-ide-review-tests--make-frame
                  "ediff cci-test-Q" '(claude-code-ide-ediff . "cci-test-Q"))))
      (unwind-protect
          ;; An invisible test frame must not be raised onto the screen
          (cl-letf (((symbol-function 'select-frame-set-input-focus) #'select-frame)
                    ((symbol-function 'message) #'ignore))
            (puthash "cci-test-Q" diff claude-code-ide-mcp--ediff-frames)
            (claude-code-ide-ediff-files-in-frame "cci-test-Q" (nth 0 files) (nth 1 files))
            (let ((first (car (claude-code-ide-mcp--ediff-live-controls "cci-test-Q"))))
              (should (buffer-live-p first))
              (should (eq (window-frame (get-buffer-window first t)) diff))
              (claude-code-ide-ediff-files-in-frame "cci-test-Q" (nth 2 files) (nth 3 files))
              (should (= (length (gethash "cci-test-Q" claude-code-ide-mcp--ediff-queue)) 1))
              ;; The first ediff is untouched by the waiting one
              (should (equal (claude-code-ide-mcp--ediff-live-controls "cci-test-Q") (list first)))
              (with-current-buffer first
                (ediff-really-quit nil))
              (claude-code-ide-review-tests--wait
               (lambda () (let ((controls (claude-code-ide-mcp--ediff-live-controls "cci-test-Q")))
                            (and controls (not (memq first controls))))))
              (let ((second (car (claude-code-ide-mcp--ediff-live-controls "cci-test-Q"))))
                (should (equal (buffer-local-value 'ediff-buffer-B second)
                               (find-buffer-visiting (nth 3 files))))
                (should-not (gethash "cci-test-Q" claude-code-ide-mcp--ediff-queue))
                (should (frame-live-p diff))
                (with-current-buffer second
                  (ediff-really-quit nil)))))
        (dolist (file files)
          (when-let* ((buffer (find-buffer-visiting file))) (kill-buffer buffer)))
        (when (frame-live-p diff) (delete-frame diff t))
        (delete-directory dir t)))))

(ert-deftest claude-code-ide-test-ediff-call-outside-ordinary-frame ()
  "Outside a diff frame, the helper calls the function in the selected frame."
  (claude-code-ide-review-tests--with-ediff-tables
    (should (eq (claude-code-ide-mcp-call-outside-ediff-frame
                 (lambda () (selected-frame)))
                frame))
    (should-not (claude-code-ide-mcp-ediff-frame-p frame))))

(provide 'claude-code-ide-review-tests)

;;; claude-code-ide-review-tests.el ends here
