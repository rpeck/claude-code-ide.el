;;; claude-code-ide-review.el --- External reviews that report to their instance  -*- lexical-binding: t; -*-

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

;; A review is an external process, for example a tool in which a
;; person reads a plan and writes comments, whose result belongs to one
;; instance: the owner.  `claude-code-ide-review-track' records the
;; review in a durable file.  When the process ends, Emacs reads the
;; result file and puts the result into the inbox of the owner (see
;; claude-code-ide-control.el), with the review ID as the request ID.
;; The state rules of the inbox then decide when the owner gets it, and
;; the result counts as delivered only when the owner's CLI reports the
;; same prompt.  So the owner gets the result one time, also when the
;; review ends while the owner works, waits, or does not run.
;;
;; The package knows no review tool.  The caller gives the command or
;; the process and the result file.  docs/review.md describes the
;; records, the states and the coordinator tool.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'claude-code-ide)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-session-registry)
(require 'claude-code-ide-control)

(defgroup claude-code-ide-review nil
  "External reviews whose results go to the instance that owns them."
  :group 'claude-code-ide
  :prefix "claude-code-ide-review-")

(defcustom claude-code-ide-review-directory nil
  "Directory that holds one record file for each tracked review.
nil means the folder \"reviews\" in the report directory of the session
registry (`claude-code-ide-session-registry-report-directory')."
  :type '(choice (const :tag "In the report directory" nil) directory)
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-check-interval 5
  "Seconds between two checks of the reviews that are not final.
A check finds the end of a review process that Emacs knows only by
its process ID, retries a result whose owner is not known yet, and
compares the submitted results with the owner's inbox."
  :type 'number
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-max-result-chars 50000
  "Characters of a result file that go into the owner's prompt.
A longer result is cut, and the prompt says where the full result is."
  :type 'integer
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-done-days 7
  "Days that the record of a final review stays.
A review is final when its result is delivered, unacknowledged or
rejected.  While the record stays, a review with its ID is a duplicate."
  :type 'number
  :group 'claude-code-ide-review)

(defcustom claude-code-ide-review-format-function #'claude-code-ide-review-format-result
  "Function that makes the prompt text of a review result.
It is called with a plist that has :review-id, :label, :owner,
:result-file, :exit-status (an integer, or nil when not known),
:content (the text of the result file, or nil), :error (nil, or a
symbol that says why the result file cannot be used), :message (the
text of the error), :length (the length of the full result, when it
was cut) and :output (the end of the output of a command that Emacs
started, or nil).  It returns a string."
  :type 'function
  :group 'claude-code-ide-review)

(defconst claude-code-ide-review--version 1
  "Version of the review record format.")

(defconst claude-code-ide-review--max-file-bytes (* 8 1024 1024)
  "Largest result file that Emacs reads.  A larger one is an error result.")

(defconst claude-code-ide-review--output-chars 2000
  "Characters at the end of the command output that an error result shows.")

;;; Records

(cl-defstruct (claude-code-ide-review--record
               (:constructor claude-code-ide-review--record-create)
               (:copier nil))
  "One tracked review."
  (review-id nil :type string)
  (owner nil :type string :documentation "Instance ID that owns the review.")
  (label nil :type string)
  (command nil :documentation "The command that Emacs started, a list of strings, or nil.")
  (directory nil :documentation "Working folder of the command.")
  (pid nil :documentation "Process ID of the review process, or nil.")
  (pid-start nil :documentation "Start time of that process as a float time, or nil.")
  (managed nil :documentation "Non-nil when Emacs started the process.")
  (interrupted nil :documentation "Non-nil when Emacs quit while its process ran.")
  (emacs-pid nil :documentation "Process ID of the Emacs that tracks the review.")
  (result-file nil :type string)
  (state 'running :type symbol
         :documentation "`running', `ended', `submitted', `delivered', `unacknowledged' or `rejected'.")
  (exit-status nil :documentation "Exit status of the process, or nil when not known.")
  (error nil :documentation "Symbol that says why the result file was not usable, or nil.")
  (text nil :documentation "The prompt text of the result, until it is delivered.")
  (destination nil :documentation "Instance ID whose inbox got the result, or nil.")
  (submit-result nil :documentation "The last :result of the inbox, a symbol, or nil.")
  (submit-reason nil :documentation "The last :reason of the inbox, a symbol, or nil.")
  (created-at nil)
  (ended-at nil)
  (submitted-at nil)
  (delivered-at nil)
  (updated-at nil))

(defconst claude-code-ide-review--fields
  '((review_id . review-id) (owner . owner) (label . label) (command . command)
    (directory . directory) (pid . pid) (pid_start . pid-start) (managed . managed)
    (interrupted . interrupted) (emacs_pid . emacs-pid) (result_file . result-file)
    (state . state) (exit_status . exit-status) (error . error) (text . text)
    (destination . destination) (submit_result . submit-result)
    (submit_reason . submit-reason) (created_at . created-at) (ended_at . ended-at)
    (submitted_at . submitted-at) (delivered_at . delivered-at) (updated_at . updated-at))
  "JSON key and struct slot of each field of a review file.")

(defconst claude-code-ide-review--symbol-slots '(state error submit-result submit-reason)
  "Slots whose value is a symbol, and a string in the file.")

(defconst claude-code-ide-review--boolean-slots '(managed interrupted)
  "Slots whose value is a boolean.")

(defconst claude-code-ide-review--final-states '(delivered unacknowledged rejected)
  "States after which nothing changes.")

(defvar claude-code-ide-review--records (make-hash-table :test 'equal)
  "The reviews that this Emacs tracks, by review ID.")

(defvar claude-code-ide-review--loaded nil
  "Non-nil when the review files were read into `claude-code-ide-review--records'.")

(defvar claude-code-ide-review--processes (make-hash-table :test 'equal)
  "The Emacs process object of each review that has one, by review ID.")

(defvar claude-code-ide-review--warned nil
  "Review IDs whose wait for an unknown owner was reported.")

(defun claude-code-ide-review--directory ()
  "Return the directory of the review records."
  (file-name-as-directory
   (expand-file-name
    (or claude-code-ide-review-directory
        (expand-file-name "reviews" (claude-code-ide-session-registry--report-directory))))))

(defun claude-code-ide-review--file (review-id)
  "Return the record file of REVIEW-ID: a hash, so any review ID is safe."
  (expand-file-name (concat (substring (secure-hash 'sha256 (encode-coding-string review-id 'utf-8))
                                       0 32)
                            ".json")
                    (claude-code-ide-review--directory)))

(defun claude-code-ide-review--final-p (record)
  "Return non-nil when RECORD is final."
  (memq (claude-code-ide-review--record-state record) claude-code-ide-review--final-states))

(defun claude-code-ide-review--to-alist (record)
  "Return RECORD as an alist for JSON."
  (cons (cons 'version claude-code-ide-review--version)
        (mapcar (lambda (field)
                  (let ((value (cl-struct-slot-value 'claude-code-ide-review--record
                                                     (cdr field) record)))
                    (cons (car field)
                          (cond
                           ((memq (cdr field) claude-code-ide-review--boolean-slots)
                            (if value t :json-false))
                           ((and value (memq (cdr field) claude-code-ide-review--symbol-slots))
                            (symbol-name value))
                           ((eq (cdr field) 'command) (and value (vconcat value)))
                           (t value)))))
                claude-code-ide-review--fields)))

(defun claude-code-ide-review--from-alist (alist)
  "Return the record of the JSON ALIST, or nil when it is not one."
  (when (and (equal (alist-get 'version alist) claude-code-ide-review--version)
             (stringp (alist-get 'review_id alist))
             (stringp (alist-get 'owner alist)))
    (let ((record (claude-code-ide-review--record-create)))
      (dolist (field claude-code-ide-review--fields)
        (let ((value (alist-get (car field) alist)))
          (setf (cl-struct-slot-value 'claude-code-ide-review--record (cdr field) record)
                (cond
                 ((memq (cdr field) claude-code-ide-review--boolean-slots) (eq value t))
                 ((and (memq (cdr field) claude-code-ide-review--symbol-slots) (stringp value))
                  (intern value))
                 ((eq (cdr field) 'command) (and value (append value nil)))
                 (t value)))))
      record)))

(defun claude-code-ide-review--read-file (file)
  "Return the record in FILE, or nil when FILE cannot be read."
  (condition-case nil
      (claude-code-ide-review--from-alist
       (claude-code-ide-control--json-decode
        (claude-code-ide-session-registry--file-string file)))
    (error nil)))

(defun claude-code-ide-review--write (record)
  "Write RECORD to its file atomically and return RECORD.
The text goes to a temporary file in the same folder, which is then
renamed over the file.  The folder is private (mode 0700) and the file
has mode 0600, because the result text can be private."
  (setf (claude-code-ide-review--record-updated-at record) (claude-code-ide-control--now))
  (let* ((file (claude-code-ide-review--file (claude-code-ide-review--record-review-id record)))
         (dir (file-name-directory file)))
    (with-file-modes #o700
      (make-directory dir t))
    (let ((tmp (with-file-modes #o600
                 (make-temp-file (expand-file-name ".review-" dir) nil ".tmp"))))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (json-encode (claude-code-ide-review--to-alist record))
                            nil tmp nil 'silent))
            (rename-file tmp file t))
        (when (file-exists-p tmp)
          (delete-file tmp)))))
  (puthash (claude-code-ide-review--record-review-id record) record
           claude-code-ide-review--records)
  record)

;;; Processes

(defun claude-code-ide-review--pid-start (pid)
  "Return the start time of the process PID as a float time, or nil."
  (when-let* ((attributes (and (natnump pid) (process-attributes pid)))
              (start (alist-get 'start attributes)))
    (float-time start)))

(defun claude-code-ide-review--pid-live-p (pid &optional start)
  "Return non-nil when the process PID runs.
START, when given, is its start time: a process with the same PID and
another start time is a new process, and does not count."
  (when-let* ((attributes (and (natnump pid) (process-attributes pid))))
    (let ((now-start (alist-get 'start attributes)))
      (and (not (equal (alist-get 'state attributes) "Z"))
           (or (null start) (null now-start)
               (< (abs (- (float-time now-start) start)) 2))))))

(defun claude-code-ide-review--emacs-live-p (pid)
  "Return non-nil when PID is this Emacs, or another running Emacs."
  (or (eql pid (emacs-pid))
      (when-let* ((attributes (and (natnump pid) (process-attributes pid))))
        (and (not (equal (alist-get 'state attributes) "Z"))
             (string-match-p "emacs" (downcase (or (alist-get 'comm attributes) "")))))))

(defun claude-code-ide-review--record-live-p (record)
  "Return non-nil when the process of RECORD still runs."
  (let ((process (gethash (claude-code-ide-review--record-review-id record)
                          claude-code-ide-review--processes)))
    (if (processp process)
        (process-live-p process)
      (claude-code-ide-review--pid-live-p (claude-code-ide-review--record-pid record)
                                          (claude-code-ide-review--record-pid-start record)))))

(defun claude-code-ide-review--output (process)
  "Return the end of the output buffer of PROCESS, or nil, and kill the buffer."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (prog1 (with-current-buffer buffer
               (let ((text (string-trim (buffer-string))))
                 (unless (string-empty-p text)
                   (substring text (max 0 (- (length text) claude-code-ide-review--output-chars))))))
        (kill-buffer buffer)))))

(defun claude-code-ide-review--process-ended (process &optional _event)
  "Handle the end of the review PROCESS, when it ended.
This runs after the sentinel of PROCESS."
  (when (memq (process-status process) '(exit signal))
    (when-let* ((review-id (process-get process 'claude-code-ide-review-id))
                (record (gethash review-id claude-code-ide-review--records)))
      (remhash review-id claude-code-ide-review--processes)
      (let ((output (and (claude-code-ide-review--record-managed record)
                         (claude-code-ide-review--output process))))
        (condition-case err
            (claude-code-ide-review--ended record (process-exit-status process) output)
          (error (message "Review %s: cannot handle the end of its process: %s"
                          review-id (error-message-string err))))))))

;;; The result

(defun claude-code-ide-review--json-p (text)
  "Return non-nil when TEXT is valid JSON."
  (condition-case nil
      (progn (claude-code-ide-control--json-decode text) t)
    (error nil)))

(defun claude-code-ide-review--read-result (file)
  "Read the result FILE.
Return (:content TEXT [:length N]) when it is usable; :length is the
full length of a result that was cut.  Return (:error REASON :message
TEXT) when it is not."
  (let ((size (and (file-exists-p file) (file-attribute-size (file-attributes file)))))
    (cond
     ((not (file-exists-p file))
      (list :error 'missing :message "The result file does not exist."))
     ((file-directory-p file)
      (list :error 'not-a-file :message "The result file is a directory."))
     ((not (file-readable-p file))
      (list :error 'unreadable :message "Emacs cannot read the result file."))
     ((and size (> size claude-code-ide-review--max-file-bytes))
      (list :error 'too-large
            :message (format "The result file has %d bytes; the limit is %d."
                             size claude-code-ide-review--max-file-bytes)))
     (t
      (condition-case err
          (let ((text (claude-code-ide-session-registry--file-string file)))
            (cond
             ((string-match-p "\0" text)
              (list :error 'not-text :message "The result file is not text."))
             ((cl-some (lambda (char) (>= char #x3fff80)) text)
              (list :error 'not-text :message "The result file is not UTF-8 text."))
             ((string-empty-p (string-trim text))
              (list :error 'empty :message "The result file is empty."))
             ((and (string-suffix-p ".json" file t) (not (claude-code-ide-review--json-p text)))
              (list :error 'invalid-json :message "The result file is not valid JSON."))
             ((> (length text) claude-code-ide-review-max-result-chars)
              (list :content (substring text 0 claude-code-ide-review-max-result-chars)
                    :length (length text)))
             (t (list :content text))))
        (error
         (list :error 'unreadable
               :message (format "Emacs cannot read the result file: %s"
                                (error-message-string err)))))))))

(defun claude-code-ide-review-format-result (info)
  "Return the prompt text of the review result INFO.
INFO is the plist that `claude-code-ide-review-format-function' gets.
The text names the review, the result file and the exit status, then
gives the result, or the error when the result file is not usable."
  (let* ((exit (plist-get info :exit-status))
         (header (format "Result of the review \"%s\" (review ID %s)\nResult file: %s\nExit status: %s"
                         (plist-get info :label) (plist-get info :review-id)
                         (plist-get info :result-file) (if exit exit "unknown"))))
    (if (plist-get info :error)
        (concat header
                (format "\n\nError: the review gave no usable result (%s). %s"
                        (plist-get info :error) (plist-get info :message))
                (when-let* ((output (plist-get info :output)))
                  (format "\n\nThe end of the output of the review command:\n%s" output)))
      (concat header "\n\n" (string-trim-right (plist-get info :content))
              (when-let* ((length (plist-get info :length)))
                (format "\n\n[The result is cut: these are the first %d of %d characters. Read the full result in the result file.]"
                        (length (plist-get info :content)) length))))))

(defun claude-code-ide-review--result-text (record output)
  "Read the result of RECORD and return its prompt text.
OUTPUT is the end of the command output, or nil.  Also set the error
of RECORD."
  (let* ((result (claude-code-ide-review--read-result
                  (claude-code-ide-review--record-result-file record)))
         (reason (plist-get result :error)))
    ;; A process that Emacs ended at its quit had no time to write
    (when (and (eq reason 'missing) (claude-code-ide-review--record-interrupted record))
      (setq result (list :error 'interrupted
                         :message "Emacs quit while the review ran, and the review wrote no result file.")
            reason 'interrupted))
    (setf (claude-code-ide-review--record-error record) reason)
    (funcall claude-code-ide-review-format-function
             (list :review-id (claude-code-ide-review--record-review-id record)
                   :label (claude-code-ide-review--record-label record)
                   :owner (claude-code-ide-review--record-owner record)
                   :result-file (claude-code-ide-review--record-result-file record)
                   :exit-status (claude-code-ide-review--record-exit-status record)
                   :content (plist-get result :content)
                   :error reason
                   :message (plist-get result :message)
                   :length (plist-get result :length)
                   :output output))))

(defun claude-code-ide-review--ended (record exit-status &optional output)
  "Handle the end of the process of RECORD with EXIT-STATUS and OUTPUT.
Read the result, save it in the record, and put it into the inbox of
the owner."
  (when (eq (claude-code-ide-review--record-state record) 'running)
    (setf (claude-code-ide-review--record-state record) 'ended
          (claude-code-ide-review--record-ended-at record) (claude-code-ide-control--now)
          (claude-code-ide-review--record-exit-status record) exit-status)
    (setf (claude-code-ide-review--record-text record)
          (claude-code-ide-review--result-text record output))
    (claude-code-ide-review--write record)
    (claude-code-ide-review--submit record)))

;;; Delivery

(defun claude-code-ide-review--current-owner (owner)
  "Return the instance ID that gets the results of OWNER now.
After a handover, that is the current instance of the chain of OWNER,
from `claude-code-ide-session-registry-chain-current' when the session
registry has it.  Otherwise it is OWNER."
  (or (and (fboundp 'claude-code-ide-session-registry-chain-current)
           (let ((current (ignore-errors
                            (funcall 'claude-code-ide-session-registry-chain-current owner))))
             (and (claude-code-ide-control--valid-id-p current) current)))
      owner))

(defun claude-code-ide-review--finish (record state &optional reason)
  "Make RECORD final with STATE and REASON, and write it.
Only a delivered record drops its text.  A rejected or unacknowledged
one keeps it, and the user gets a warning, so that the result is never
lost without a word."
  (setf (claude-code-ide-review--record-state record) state)
  (when reason
    (setf (claude-code-ide-review--record-submit-reason record) reason))
  (if (eq state 'delivered)
      (setf (claude-code-ide-review--record-text record) nil
            (claude-code-ide-review--record-delivered-at record)
            (or (claude-code-ide-review--record-delivered-at record) (claude-code-ide-control--now)))
    (display-warning
     'claude-code-ide
     (format "The result of the review \"%s\" (%s) was not delivered to %s: %s (%s).  The result file is %s; the record is %s"
             (claude-code-ide-review--record-label record)
             (claude-code-ide-review--record-review-id record)
             (or (claude-code-ide-review--record-destination record)
                 (claude-code-ide-review--record-owner record))
             state (claude-code-ide-review--record-submit-reason record)
             (claude-code-ide-review--record-result-file record)
             (claude-code-ide-review--file (claude-code-ide-review--record-review-id record)))))
  (claude-code-ide-review--write record))

(defun claude-code-ide-review--apply-result (record target result)
  "Apply the inbox RESULT of a submit or a status check to RECORD.
TARGET is the instance ID whose inbox gave RESULT.  Return the new
state of RECORD."
  (let ((answer (plist-get result :result))
        (reason (plist-get result :reason)))
    (setf (claude-code-ide-review--record-submit-result record) answer
          (claude-code-ide-review--record-submit-reason record) reason)
    (pcase answer
      ('queued
       (unless (eq (claude-code-ide-review--record-state record) 'submitted)
         (setf (claude-code-ide-review--record-state record) 'submitted
               (claude-code-ide-review--record-destination record) target
               (claude-code-ide-review--record-submitted-at record) (claude-code-ide-control--now))
         (claude-code-ide-review--write record)))
      ('delivered
       (setf (claude-code-ide-review--record-destination record) target)
       (claude-code-ide-review--finish record 'delivered))
      ('unacknowledged
       (setf (claude-code-ide-review--record-destination record) target)
       (claude-code-ide-review--finish record 'unacknowledged))
      ('rejected
       (if (memq reason '(unknown-instance submit-error))
           ;; The owner is not known yet, for example before its
           ;; restore: keep the result and try again later
           (let ((review-id (claude-code-ide-review--record-review-id record)))
             (unless (member review-id claude-code-ide-review--warned)
               (push review-id claude-code-ide-review--warned)
               (message "Review %s: the result waits until the instance %s is known"
                        review-id target))
             (when (eq (claude-code-ide-review--record-state record) 'submitted)
               (setf (claude-code-ide-review--record-state record) 'ended))
             (claude-code-ide-review--write record))
         (setf (claude-code-ide-review--record-destination record) target)
         (claude-code-ide-review--finish record 'rejected))))
    (claude-code-ide-review--record-state record)))

(defun claude-code-ide-review--submit (record)
  "Put the result of the ended RECORD into the inbox of its current owner.
The review ID is the request ID, so a second submit sends nothing.
Return the new state of RECORD."
  (let* ((review-id (claude-code-ide-review--record-review-id record))
         (target (claude-code-ide-review--current-owner (claude-code-ide-review--record-owner record)))
         (result (condition-case err
                     (claude-code-ide-control-submit
                      target (claude-code-ide-review--record-text record)
                      :request-id review-id :queue t)
                   (error
                    (message "Review %s: the submit to %s failed: %s"
                             review-id target (error-message-string err))
                    (list :result 'rejected :reason 'submit-error)))))
    (prog1 (claude-code-ide-review--apply-result record target result)
      (claude-code-ide-review--update-timer))))

(defun claude-code-ide-review--sync (record)
  "Compare the submitted RECORD with the inbox, and apply what changed.
The inbox may have acknowledged the result while no hook ran, or a
handover may have moved it to the current instance of the chain.  A
result that no inbox knows is submitted again.  Return the new state."
  (let* ((review-id (claude-code-ide-review--record-review-id record))
         (destination (claude-code-ide-review--record-destination record))
         (status (progn
                   ;; A sent result whose acknowledgement is overdue
                   ;; becomes unacknowledged here
                   (when (claude-code-ide-control--valid-id-p destination)
                     (claude-code-ide-control--refresh destination))
                   (claude-code-ide-control-request-status destination review-id))))
    (when (eq (plist-get status :status) 'error)
      (let ((current (claude-code-ide-review--current-owner
                      (claude-code-ide-review--record-owner record))))
        (unless (equal current destination)
          (setq status (claude-code-ide-control-request-status current review-id))
          (unless (eq (plist-get status :status) 'error)
            (setf (claude-code-ide-review--record-destination record) current
                  destination current)
            (claude-code-ide-review--write record)))))
    (if (eq (plist-get status :status) 'error)
        (progn
          (setf (claude-code-ide-review--record-state record) 'ended)
          (claude-code-ide-review--submit record))
      (claude-code-ide-review--apply-result record destination status))))

(defun claude-code-ide-review--on-delivered (_instance-id request-id)
  "Mark the review REQUEST-ID delivered, when it is one.
This runs from `claude-code-ide-control-delivered-functions'.  The
instance can be another one than the first owner after a handover, so
only the request ID counts."
  (when-let* ((record (gethash request-id claude-code-ide-review--records)))
    (when (eq (claude-code-ide-review--record-state record) 'submitted)
      (setf (claude-code-ide-review--record-submit-result record) 'delivered
            (claude-code-ide-review--record-submit-reason record) nil)
      (claude-code-ide-review--finish record 'delivered)
      (claude-code-ide-review--update-timer))))

(defun claude-code-ide-review--retry-for (instance-id)
  "Submit the waiting results whose current owner is INSTANCE-ID."
  (maphash (lambda (_id record)
             (when (and (eq (claude-code-ide-review--record-state record) 'ended)
                        (equal (claude-code-ide-review--current-owner
                                (claude-code-ide-review--record-owner record))
                               instance-id))
               (claude-code-ide-review--submit record)))
           claude-code-ide-review--records))

(defun claude-code-ide-review--on-session-start (session _spec)
  "Submit the waiting results of the instance of SESSION, which started."
  (when-let* ((instance (claude-code-ide-instance-of-session session)))
    (claude-code-ide-review--retry-for (claude-code-ide-instance-id instance))))

;;; Loading and checks

(defun claude-code-ide-review--prune (file record)
  "Delete FILE of the final RECORD when it is older than the limit.
Return non-nil when it was deleted."
  (when (claude-code-ide-review--final-p record)
    (when-let* ((attributes (file-attributes file)))
      (when (> (float-time (time-subtract nil (file-attribute-modification-time attributes)))
               (* claude-code-ide-review-done-days 86400))
        (ignore-errors (delete-file file))
        t))))

(defun claude-code-ide-review--ensure-loaded ()
  "Read the review files at the first use in this Emacs.
A review that another running Emacs tracks stays with it.  This Emacs
takes the other reviews that are not final, also those of an Emacs
that quit."
  (unless claude-code-ide-review--loaded
    (setq claude-code-ide-review--loaded t)
    (let ((dir (claude-code-ide-review--directory)))
      (when (file-directory-p dir)
        (dolist (file (directory-files dir t "\\`[0-9a-f]+\\.json\\'" t))
          (when-let* ((record (claude-code-ide-review--read-file file)))
            (unless (claude-code-ide-review--prune file record)
              (let ((emacs (claude-code-ide-review--record-emacs-pid record)))
                (cond
                 ((claude-code-ide-review--final-p record)
                  (puthash (claude-code-ide-review--record-review-id record) record
                           claude-code-ide-review--records))
                 ((and (natnump emacs) (not (eql emacs (emacs-pid)))
                       (claude-code-ide-review--emacs-live-p emacs))
                  nil)
                 (t
                  (setf (claude-code-ide-review--record-emacs-pid record) (emacs-pid))
                  (claude-code-ide-review--write record)))))))))))

(defun claude-code-ide-review--active ()
  "Return the reviews of this Emacs that are not final."
  (let ((records nil))
    (maphash (lambda (_id record)
               (unless (or (claude-code-ide-review--final-p record)
                           (not (eql (claude-code-ide-review--record-emacs-pid record) (emacs-pid))))
                 (push record records)))
             claude-code-ide-review--records)
    (nreverse records)))

(defun claude-code-ide-review--check (record)
  "Move RECORD on: find the end of its process, submit, or sync it."
  (pcase (claude-code-ide-review--record-state record)
    ('running
     (let ((process (gethash (claude-code-ide-review--record-review-id record)
                             claude-code-ide-review--processes)))
       (unless (claude-code-ide-review--record-live-p record)
         (claude-code-ide-review--ended
          record
          (and (processp process) (process-exit-status process))
          (and (processp process) (claude-code-ide-review--record-managed record)
               (claude-code-ide-review--output process))))))
    ('ended (claude-code-ide-review--submit record))
    ('submitted (claude-code-ide-review--sync record))))

(defvar claude-code-ide-review--timer nil
  "Timer of `claude-code-ide-review--tick'.")

(defun claude-code-ide-review--tick ()
  "Check each review of this Emacs that is not final."
  (dolist (record (claude-code-ide-review--active))
    (condition-case err
        (claude-code-ide-review--check record)
      (error (message "Review %s: check failed: %s"
                      (claude-code-ide-review--record-review-id record)
                      (error-message-string err)))))
  (claude-code-ide-review--update-timer))

(defun claude-code-ide-review--update-timer ()
  "Run the check timer while a review of this Emacs is not final."
  (if (and (claude-code-ide-review--active)
           (numberp claude-code-ide-review-check-interval)
           (> claude-code-ide-review-check-interval 0))
      (unless (timerp claude-code-ide-review--timer)
        (setq claude-code-ide-review--timer
              (run-with-timer claude-code-ide-review-check-interval
                              claude-code-ide-review-check-interval
                              #'claude-code-ide-review--tick)))
    (when (timerp claude-code-ide-review--timer)
      (cancel-timer claude-code-ide-review--timer))
    (setq claude-code-ide-review--timer nil)))

;;;###autoload
(defun claude-code-ide-review-recover ()
  "Take the reviews that are not final, and check each of them now.
A review that ended while Emacs did not run is found here: its result
goes to the inbox of its owner.  Emacs runs this once after the
package loads."
  (interactive)
  (claude-code-ide-review--ensure-loaded)
  (claude-code-ide-review--tick))

(defun claude-code-ide-review--on-kill-emacs ()
  "Mark the reviews whose process Emacs ends at its quit.
Emacs ends the processes that it started.  The next start then reads
their result file, or gives the owner the error result `interrupted'."
  (maphash (lambda (review-id process)
             (when-let* ((record (gethash review-id claude-code-ide-review--records)))
               (when (and (processp process) (process-live-p process)
                          (eq (claude-code-ide-review--record-state record) 'running))
                 (setf (claude-code-ide-review--record-interrupted record) t)
                 (ignore-errors (claude-code-ide-review--write record)))))
           claude-code-ide-review--processes))

;;; Tracking

(defun claude-code-ide-review--error (reason &optional review-id message)
  "Return the error result with REASON, REVIEW-ID and MESSAGE."
  (append (list :status 'error :reason reason)
          (when review-id (list :review-id review-id))
          (when message (list :message message))))

(defun claude-code-ide-review--owner-directory (owner)
  "Return the worktree or project folder of the running instance OWNER, or nil."
  (when-let* ((instance (claude-code-ide-instance-by-id owner)))
    (let ((dir (or (claude-code-ide-instance-worktree instance)
                   (claude-code-ide-instance-project-root instance))))
      (and (stringp dir) (file-directory-p dir) dir))))

(defun claude-code-ide-review-status (review-id)
  "Return the state of the review REVIEW-ID.
The result is (:status ok :review-id ID :owner OWNER :label LABEL
:state STATE :destination ID :submit-result R :submit-reason R :error E
:exit-status N :pid PID :result-file FILE :created-at T :ended-at T
:delivered-at T), or (:status error :reason unknown-review)."
  (claude-code-ide-review--ensure-loaded)
  (let* ((review-id (claude-code-ide-control--request-id-string review-id))
         (record (and review-id
                      (or (gethash review-id claude-code-ide-review--records)
                          (let ((file (claude-code-ide-review--file review-id)))
                            (and (file-exists-p file) (claude-code-ide-review--read-file file)))))))
    (if (not record)
        (claude-code-ide-review--error 'unknown-review review-id)
      (list :status 'ok
            :review-id (claude-code-ide-review--record-review-id record)
            :owner (claude-code-ide-review--record-owner record)
            :label (claude-code-ide-review--record-label record)
            :state (claude-code-ide-review--record-state record)
            :destination (claude-code-ide-review--record-destination record)
            :submit-result (claude-code-ide-review--record-submit-result record)
            :submit-reason (claude-code-ide-review--record-submit-reason record)
            :error (claude-code-ide-review--record-error record)
            :exit-status (claude-code-ide-review--record-exit-status record)
            :pid (claude-code-ide-review--record-pid record)
            :result-file (claude-code-ide-review--record-result-file record)
            :created-at (claude-code-ide-review--record-created-at record)
            :ended-at (claude-code-ide-review--record-ended-at record)
            :delivered-at (claude-code-ide-review--record-delivered-at record)))))

(defun claude-code-ide-review-process-ids ()
  "Return the process IDs of the review processes of this Emacs that run.
A review command runs in the worktree of its owner, so a scan of that
worktree for other processes finds it.  A handover leaves these
processes alone: their result goes to the next instance of the chain."
  (claude-code-ide-review--ensure-loaded)
  (let ((pids nil))
    (dolist (record (claude-code-ide-review--active))
      (let ((pid (claude-code-ide-review--record-pid record)))
        (when (and (eq (claude-code-ide-review--record-state record) 'running)
                   (natnump pid)
                   (claude-code-ide-review--record-live-p record))
          (push pid pids))))
    (nreverse pids)))

(defun claude-code-ide-review--start-command (review-id command directory)
  "Start COMMAND for REVIEW-ID in DIRECTORY and return its process."
  (let ((default-directory (file-name-as-directory directory))
        (buffer (generate-new-buffer (format " *cci-review %s*" review-id))))
    (condition-case err
        (make-process :name (format "cci-review-%s" review-id)
                      :buffer buffer
                      :command command
                      :connection-type 'pipe
                      :noquery t
                      :sentinel #'ignore)
      (error
       (kill-buffer buffer)
       (signal (car err) (cdr err))))))

(cl-defun claude-code-ide-review-track (owner &key process command result-file label review-id directory)
  "Track an external review whose result belongs to the instance OWNER.
Give the review process as PROCESS, an Emacs process object or a
process ID, or give COMMAND, a list of strings that Emacs starts in
DIRECTORY (default: the worktree of OWNER).  RESULT-FILE is the file
that the review writes; a relative name is relative to DIRECTORY.
LABEL names the review for people.  REVIEW-ID is a string that the
caller chooses; nil makes a new one.

When the process ends, Emacs reads RESULT-FILE and puts the result
into the inbox of OWNER (or of the current instance of its chain after
a handover), with REVIEW-ID as the request ID.  A missing or broken
result file gives an explicit error result.  The result counts as
delivered only when the owner's CLI reports it.

Return (:status ok :review-id ID :owner OWNER :state running :pid
PID), the state of the known review with :duplicate t when REVIEW-ID
was used before, or (:status error :reason R ...).  This never
signals."
  (claude-code-ide-review--ensure-loaded)
  (let ((review-id (or (claude-code-ide-control--request-id-string review-id)
                       (claude-code-ide-instance-new-id)))
        (directory (or directory (claude-code-ide-review--owner-directory owner) default-directory)))
    (cond
     ((string-empty-p review-id)
      (claude-code-ide-review--error 'invalid-review-id))
     ((or (gethash review-id claude-code-ide-review--records)
          (file-exists-p (claude-code-ide-review--file review-id)))
      (append (claude-code-ide-review-status review-id) (list :duplicate t)))
     ((not (claude-code-ide-control--valid-id-p owner))
      (claude-code-ide-review--error 'invalid-instance-id review-id))
     ((and process command)
      (claude-code-ide-review--error 'process-and-command review-id
                                     "Give a process or a command, not both"))
     ((not (or process command))
      (claude-code-ide-review--error 'no-process review-id "Give a process or a command"))
     ((and process (not (or (processp process) (natnump process))))
      (claude-code-ide-review--error 'invalid-process review-id
                                     "The process is a process object or a process ID"))
     ((and command (not (and (consp command) (proper-list-p command)
                             (cl-every #'stringp command)
                             (not (string-empty-p (car command))))))
      (claude-code-ide-review--error 'invalid-command review-id
                                     "The command is a list of strings"))
     ((not (and (stringp result-file) (not (string-empty-p result-file))))
      (claude-code-ide-review--error 'no-result-file review-id))
     ((not (and (stringp directory) (file-directory-p directory)))
      (claude-code-ide-review--error 'no-directory review-id
                                     (format "No such directory: %s" directory)))
     ((null (claude-code-ide-control--state-of owner))
      (claude-code-ide-review--error 'unknown-instance review-id
                                     (format "No instance %s is known" owner)))
     (t
      (condition-case err
          (claude-code-ide-review--track-new
           owner review-id
           (if command
               (claude-code-ide-review--start-command review-id command directory)
             process)
           (and command t) command directory
           (expand-file-name result-file directory)
           (if (and (stringp label) (not (string-empty-p label))) label "review"))
        (error
         (claude-code-ide-review--error 'start-failed review-id (error-message-string err))))))))

(defun claude-code-ide-review--track-new (owner review-id process managed command directory result-file label)
  "Record the new review REVIEW-ID of OWNER and return its result.
PROCESS is a process object or a process ID; MANAGED is non-nil when
Emacs started it from COMMAND in DIRECTORY.  RESULT-FILE and LABEL are
those of the review."
  (let* ((pid (if (processp process) (process-id process) process))
         (record (claude-code-ide-review--record-create
                  :review-id review-id
                  :owner owner
                  :label label
                  :command command
                  :directory directory
                  :pid pid
                  :pid-start (claude-code-ide-review--pid-start pid)
                  :managed managed
                  :emacs-pid (emacs-pid)
                  :result-file result-file
                  :state 'running
                  :created-at (claude-code-ide-control--now))))
    (claude-code-ide-review--write record)
    (when (processp process)
      (process-put process 'claude-code-ide-review-id review-id)
      (puthash review-id process claude-code-ide-review--processes)
      (add-function :after (process-sentinel process) #'claude-code-ide-review--process-ended))
    ;; A process that ended before the sentinel was added
    (unless (claude-code-ide-review--record-live-p record)
      (claude-code-ide-review--check record))
    (claude-code-ide-review--update-timer)
    (list :status 'ok
          :review-id review-id
          :owner owner
          :state (claude-code-ide-review--record-state record)
          :pid pid)))

;;; Control operation and coordinator tool

(defun claude-code-ide-review--mcp-track (instance-id result-file &optional label review-id pid command directory)
  "MCP tool: track a review of INSTANCE-ID that writes RESULT-FILE.
LABEL, REVIEW-ID, PID (a process ID), COMMAND (an array of strings) and
DIRECTORY are optional; give PID or COMMAND."
  (let ((blank (lambda (value) (or (null value) (and (stringp value) (string-empty-p value))))))
    (claude-code-ide-control--json
     (claude-code-ide-review-track
      instance-id
      :process (unless (funcall blank pid) pid)
      :command (when (or (vectorp command) (consp command)) (append command nil))
      :result-file result-file
      :label (unless (funcall blank label) label)
      :review-id (unless (funcall blank review-id) review-id)
      :directory (unless (funcall blank directory) directory)))))

(claude-code-ide-control-define-operation 'track-review #'claude-code-ide-review-track)

(claude-code-ide-control-define-tool
 :name "track_review"
 :function #'claude-code-ide-review--mcp-track
 :description "Track an external review process whose result belongs to an instance. When the process ends, Emacs reads the result file and puts the result into the instance's inbox, with the review ID as the request ID. The instance gets it once, when it can take it. A missing or broken result file gives an explicit error result. Give pid (a running process) or command (Emacs starts it). Returns the review ID."
 :args '((:name "instance_id" :type string
                :description "Instance ID of the owner of the review, from claude-code-ide-control-list-instances.")
         (:name "result_file" :type string
                :description "File that the review writes its result to. A relative name is relative to directory.")
         (:name "label" :type string :optional t
                :description "Name of the review for people.")
         (:name "review_id" :type string :optional t
                :description "ID that makes the call idempotent; also the request ID in the inbox. Default: a new ID.")
         (:name "pid" :type integer :optional t
                :description "Process ID of a running review process.")
         (:name "command" :type array :optional t :items (:type string)
                :description "Command and arguments that Emacs starts as the review process.")
         (:name "directory" :type string :optional t
                :description "Working folder of the command. Default: the worktree of the instance.")))

;;; Hooks

(add-hook 'claude-code-ide-control-delivered-functions #'claude-code-ide-review--on-delivered)
(add-hook 'claude-code-ide-session-start-functions #'claude-code-ide-review--on-session-start)
(add-hook 'kill-emacs-hook #'claude-code-ide-review--on-kill-emacs)

;; A review that ended while Emacs did not run is delivered after the
;; start.  A batch Emacs, such as a test run, reads no review file.
(unless noninteractive
  (run-with-idle-timer 2 nil #'claude-code-ide-review-recover))

(provide 'claude-code-ide-review)

;;; claude-code-ide-review.el ends here
