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
            (claude-code-ide-review--warned nil)
            (claude-code-ide-review--timer nil)
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
  "Run the process filters and sentinels until PREDICATE is true, up to 10 s.
A deadline, not `with-timeout': the control tests mock `run-at-time'."
  (let ((deadline (+ (float-time) 10)))
    (while (not (funcall predicate))
      (when (> (float-time) deadline)
        (error "Timeout in a review test"))
      (accept-process-output nil 0.05))))

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
        claude-code-ide-review--warned nil
        claude-code-ide-control--index (make-hash-table :test 'equal)))

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
      (let ((inbox (claude-code-ide-control-request-status "cci-test-owner" id)))
        (should (eq (plist-get inbox :result) 'queued)))
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
      (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-owner" id) :result)
                  'queued))
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
      (let ((process (gethash id claude-code-ide-review--processes)))
        (claude-code-ide-review-tests--restart)
        (set-process-sentinel process #'ignore)
        (delete-process process))
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
      (let ((process (gethash id claude-code-ide-review--processes)))
        (claude-code-ide-review-tests--restart)
        (set-process-sentinel process #'ignore)
        (delete-process process))
      (should (eq (claude-code-ide-review-tests--state id) 'running))
      (claude-code-ide-review-recover)
      (let ((text (nth 1 (car claude-code-ide-tests--control-sent))))
        (should (string-match-p "Error: the review gave no usable result (interrupted)" text))
        (should (string-match-p "Emacs quit while the review ran" text)))
      (should (eq (plist-get (claude-code-ide-review-status id) :error) 'interrupted)))))

(ert-deftest claude-code-ide-test-review-other-emacs-keeps-its-review ()
  "A review that another running Emacs tracks is not taken."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle)
    (let ((record (claude-code-ide-review--record-create
                   :review-id "cci-test-other" :owner "cci-test-owner" :label "x"
                   :pid 999999 :emacs-pid 424242 :result-file "/nonexistent/cci-test"
                   :state 'running :created-at "2026-11-18T00:00:00Z")))
      (claude-code-ide-review--write record)
      (claude-code-ide-review-tests--restart)
      (cl-letf (((symbol-function 'claude-code-ide-review--emacs-live-p)
                 (lambda (pid) (memql pid (list 424242 (emacs-pid))))))
        (claude-code-ide-review-recover))
      (should-not (gethash "cci-test-other" claude-code-ide-review--records))
      (should-not claude-code-ide-tests--control-sent)
      ;; When that Emacs is gone, this Emacs takes the review
      (claude-code-ide-review-tests--restart)
      (cl-letf (((symbol-function 'claude-code-ide-review--emacs-live-p)
                 (lambda (pid) (eql pid (emacs-pid)))))
        (claude-code-ide-review-recover))
      (should (eq (claude-code-ide-review-tests--state "cci-test-other") 'submitted))
      (should (eql (claude-code-ide-review--record-emacs-pid
                    (gethash "cci-test-other" claude-code-ide-review--records))
                   (emacs-pid))))))

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
  "A review without a result file gives the owner an explicit error result."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'idle)
    (let* ((track (claude-code-ide-review-track
                   "cci-test-owner" :command '("sh" "-c" "echo cci-test-crash >&2; exit 3")
                   :directory results :result-file "missing.md" :label "cci-test crash"))
           (id (plist-get track :review-id)))
      (claude-code-ide-review-tests--wait
       (lambda () (not (eq (claude-code-ide-review-tests--state id) 'running))))
      (let ((text (nth 1 (car claude-code-ide-tests--control-sent))))
        (should (string-match-p "Error: the review gave no usable result (missing)" text))
        (should (string-match-p "Exit status: 3" text))
        (should (string-match-p "cci-test-crash" text))
        (should (string-match-p (regexp-quote (expand-file-name "missing.md" results)) text))
        (claude-code-ide-review-tests--ack "cci-test-owner" text))
      (should (eq (claude-code-ide-review-tests--state id) 'delivered))
      (should (eq (plist-get (claude-code-ide-review-status id) :error) 'missing)))))

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

(ert-deftest claude-code-ide-test-review-follows-moved-inbox ()
  "A result in the inbox of the source follows the inbox move of a handover."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-source" "proj" 'working)
    (let* ((id (plist-get (claude-code-ide-review-tests--command-review
                           "cci-test-source" results "r.md" "cci-test moved")
                          :review-id))
           (record (claude-code-ide-control--find-record "cci-test-source" id))
           (text (claude-code-ide-control--record-text record)))
      (should (equal (plist-get (claude-code-ide-review-status id) :destination) "cci-test-source"))
      ;; The handover moves the queued result to the target's inbox
      (claude-code-ide-tests--control-add "cci-test-target" "proj" 'working)
      (claude-code-ide-control-submit "cci-test-target" text :request-id id :queue t)
      (delete-file (claude-code-ide-control--record-file "cci-test-source" id))
      (remhash (claude-code-ide-control-inbox-directory-of "cci-test-source")
               claude-code-ide-control--index)
      (cl-letf (((symbol-function 'claude-code-ide-session-registry-chain-current)
                 (lambda (id) (and (equal id "cci-test-source") "cci-test-target"))))
        (claude-code-ide-review--tick)
        (should (equal (plist-get (claude-code-ide-review-status id) :destination)
                       "cci-test-target"))
        (claude-code-ide-tests--control-set-state "cci-test-target" 'idle)
        (claude-code-ide-tests--control-event "cci-test-target" 'turn-end)
        (claude-code-ide-review-tests--ack "cci-test-target" text)
        (should (eq (claude-code-ide-review-tests--state id) 'delivered))
        (should (= (length claude-code-ide-tests--control-sent) 1))))))

(ert-deftest claude-code-ide-test-review-lost-inbox-record-is-sent-again ()
  "A submitted result that no inbox knows is submitted again, not lost."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (let ((id (plist-get (claude-code-ide-review-tests--command-review
                          "cci-test-owner" results "r.md" "cci-test again")
                         :review-id)))
      (delete-file (claude-code-ide-control--record-file "cci-test-owner" id))
      (remhash (claude-code-ide-control-inbox-directory-of "cci-test-owner")
               claude-code-ide-control--index)
      (claude-code-ide-review--tick)
      (should (eq (claude-code-ide-review-tests--state id) 'submitted))
      (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-owner" id) :result)
                  'queued)))))

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
        (should (equal (claude-code-ide-review--record-command record) '("sleep" "30")))
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
  "The track-review operation and the track_review coordinator tool work."
  (claude-code-ide-review-tests--with-review
    (claude-code-ide-tests--control-add "cci-test-owner" "proj" 'working)
    (should (eq (alist-get 'track-review claude-code-ide-control-operations)
                #'claude-code-ide-review-track))
    (let ((result (claude-code-ide-control-call 'track-review "cci-test-owner"
                                                :command '("sleep" "30") :directory results
                                                :result-file "r.md")))
      (should (eq (plist-get result :status) 'ok)))
    (let ((spec (cl-find "track_review" claude-code-ide-control--extra-tool-specs
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
      (should (equal (claude-code-ide-review--record-command
                      (gethash "cci-test-mcp" claude-code-ide-review--records))
                     '("sleep" "30"))))
    ;; Without the scope check, the setup of the coordinator tools adds it with the scope
    (let ((claude-code-ide-mcp-server-tools nil))
      (let ((tools (claude-code-ide-control-setup-mcp-tools t)))
        (should (eq (plist-get (cl-find "track_review" tools
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
         (claude-code-ide-review-tests--ediff-calls nil)
         (frame (selected-frame)))
     (unwind-protect
         (progn ,@body)
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
