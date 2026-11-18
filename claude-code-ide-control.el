;;; claude-code-ide-control.el --- Control operations for coordinators  -*- lexical-binding: t; -*-

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

;; Control operations let a coordinator (a program or an agent session)
;; list, inspect, launch, resume, prompt and stop a specific instance.
;; Each operation takes or returns instance IDs, never display names.
;;
;; A prompt goes through a durable inbox: one folder for each instance
;; in the report directory, and one JSON file for each request.  A
;; request ID that the caller chooses makes a request idempotent: a
;; second request with the same ID returns the first result and sends
;; nothing.  The state of the instance decides whether a prompt goes
;; out at once, waits in the inbox, or is rejected.  A prompt counts as
;; delivered only when a `prompt-submit' event of the instance carries
;; the same text.
;;
;; Each operation is also an MCP tool with the coordinator scope.
;; docs/api-control.md describes the operations, the inbox and the
;; tools.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'parse-time)
(require 'subr-x)
(require 'claude-code-ide)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-mcp-server)
(require 'claude-code-ide-session-registry)

(defvar claude-code-ide-session-registry-mode)

(defgroup claude-code-ide-control nil
  "Control operations and prompt inboxes for coordinators."
  :group 'claude-code-ide
  :prefix "claude-code-ide-control-")

(defcustom claude-code-ide-control-inbox-directory nil
  "Directory that holds the prompt inbox of each instance.
nil means the folder \"inbox\" in the report directory of the session
registry (`claude-code-ide-session-registry-report-directory')."
  :type '(choice (const :tag "In the report directory" nil) directory)
  :group 'claude-code-ide-control)

(defcustom claude-code-ide-control-ack-timeout 60
  "Seconds that a sent prompt blocks the next prompt of its instance.
A sent prompt waits for its acknowledgement, a `prompt-submit' event
with the same text.  After this time, the next queued prompt can go
out, and the sent prompt gets the reason `unacknowledged'.  It is never
sent again, and a late acknowledgement still makes it delivered."
  :type 'number
  :group 'claude-code-ide-control)

(defcustom claude-code-ide-control-retry-interval 5
  "Seconds between two checks of the queued prompts of running instances.
Events start a delivery too; this check finds the instances that
became idle without an event.  nil turns the check off."
  :type '(choice (const :tag "Off" nil) number)
  :group 'claude-code-ide-control)

(defcustom claude-code-ide-control-enable-mcp-tools t
  "When non-nil, add the control operations as MCP coordinator tools.
The tools are added only when the MCP server enforces the coordinator
scope; see `claude-code-ide-control-setup-mcp-tools'."
  :type 'boolean
  :group 'claude-code-ide-control)

;;; Operations

(defvar claude-code-ide-control-operations
  '((list-instances . claude-code-ide-control-list-instances)
    (inspect-instance . claude-code-ide-control-inspect-instance)
    (launch . claude-code-ide-control-launch)
    (resume . claude-code-ide-control-resume)
    (submit-prompt . claude-code-ide-control-submit)
    (stop . claude-code-ide-control-stop)
    ;; Phase 3: the handover and review files define these with
    ;; `claude-code-ide-control-define-operation'
    (handover . nil)
    (track-review . nil))
  "Alist of the control operations and the functions that do them.
An operation without a function is not available yet.")

(defun claude-code-ide-control-define-operation (operation function)
  "Make FUNCTION do the control OPERATION, a symbol, and return OPERATION."
  (if-let* ((cell (assq operation claude-code-ide-control-operations)))
      (setcdr cell function)
    (setq claude-code-ide-control-operations
          (append claude-code-ide-control-operations (list (cons operation function)))))
  operation)

(defun claude-code-ide-control-call (operation &rest args)
  "Call the control OPERATION with ARGS and return its result.
An operation without a function returns (:status unavailable
:capability OPERATION)."
  (if-let* ((function (alist-get operation claude-code-ide-control-operations)))
      (apply function args)
    (claude-code-ide-provider-unavailable operation)))

(defun claude-code-ide-control--error (reason &optional instance-id message)
  "Return the error result with REASON, INSTANCE-ID and MESSAGE."
  (append (list :status 'error :reason reason)
          (when instance-id (list :instance-id instance-id))
          (when message (list :message message))))

(defun claude-code-ide-control--valid-id-p (id)
  "Return non-nil when ID can name an instance or a folder of the inbox."
  (and (stringp id)
       (<= 1 (length id) 128)
       (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'" id)))

(defun claude-code-ide-control--describe (instance)
  "Return the summary plist of the descriptor INSTANCE."
  (let* ((id (claude-code-ide-instance-id instance))
         (state (claude-code-ide-instance-state instance)))
    (list :instance-id id
          :provider (claude-code-ide-instance-provider instance)
          :native-id (claude-code-ide-instance-native-id instance)
          :display-name (claude-code-ide-instance-display-name instance)
          :project-root (claude-code-ide-instance-project-root instance)
          :worktree (claude-code-ide-instance-worktree instance)
          :generation (claude-code-ide-instance-generation instance)
          :model (claude-code-ide-instance-model instance)
          :role (claude-code-ide-instance-role instance)
          :live (and (claude-code-ide-instance-live-p instance) t)
          :state (plist-get state :state)
          :state-reason (plist-get state :reason)
          :state-age (plist-get state :age)
          :state-guess (plist-get state :guess)
          :queued (length (claude-code-ide-control--pending-records id)))))

(defun claude-code-ide-control-list-instances (&optional provider)
  "Return the instances that run in this Emacs.
With PROVIDER, a provider name, return only its instances.  The result
is (:status ok :instances LIST), where each element is a plist with
:instance-id, :provider, :native-id, :display-name, :project-root,
:worktree, :generation, :model, :role, :live, :state, :state-reason,
:state-age, :state-guess and :queued (the number of prompts that wait
in the inbox)."
  (list :status 'ok
        :instances (mapcar #'claude-code-ide-control--describe
                           (claude-code-ide-instances provider))))

(defun claude-code-ide-control-inspect-instance (instance-id)
  "Return the details of the instance INSTANCE-ID.
The result has the keys of `claude-code-ide-control-list-instances',
plus :status ok, :buffer (the buffer name), :pid,
:process-start-time, :capabilities (the operations of its provider)
and :inbox (the requests in its inbox, without their text).  An
instance that does not run gives (:status error :reason not-running)."
  (if-let* ((instance (claude-code-ide-instance-by-id instance-id)))
      (let* ((provider (claude-code-ide-get-provider
                        (claude-code-ide-instance-provider instance)))
             (buffer (claude-code-ide-instance-buffer instance)))
        (append (list :status 'ok)
                (claude-code-ide-control--describe instance)
                (list :buffer (and (buffer-live-p buffer) (buffer-name buffer))
                      :pid (claude-code-ide-instance-pid instance)
                      :process-start-time (claude-code-ide-instance-process-start-time instance)
                      :capabilities (and provider (claude-code-ide-provider-capabilities provider))
                      :inbox (mapcar #'claude-code-ide-control--record-summary
                                     (claude-code-ide-control--records instance-id)))))
    (claude-code-ide-control--error 'not-running instance-id)))

(defun claude-code-ide-control--started (instance-id)
  "Return the result of a launch or a resume that started INSTANCE-ID."
  (if-let* ((instance (claude-code-ide-instance-by-id instance-id)))
      (list :status 'ok
            :instance-id instance-id
            :provider (claude-code-ide-instance-provider instance)
            :generation (claude-code-ide-instance-generation instance)
            :display-name (claude-code-ide-instance-display-name instance)
            :native-id (claude-code-ide-instance-native-id instance))
    (claude-code-ide-control--error 'start-failed instance-id
                                    "The instance did not start")))

(defun claude-code-ide-control--start (instance-id thunk)
  "Call THUNK, which starts INSTANCE-ID, and return the result of the start."
  (condition-case err
      (progn
        (funcall thunk)
        (claude-code-ide-control--started instance-id))
    ((error quit)
     (claude-code-ide-control--error 'start-failed instance-id
                                     (error-message-string err)))))

(cl-defun claude-code-ide-control-launch (&key directory provider name prompt role extra-flags)
  "Start a new instance in DIRECTORY and return its instance ID.
PROVIDER is a provider name (nil means the default provider), NAME the
instance name, PROMPT the first message, ROLE the optional role and
EXTRA-FLAGS the CLI flags (nil keeps the current flags).  The result
is (:status ok :instance-id ID :provider P :generation N
:display-name NAME :native-id ID-OR-unknown), or an error result."
  (cond
   ((not (and (stringp directory) (file-directory-p directory)))
    (claude-code-ide-control--error 'no-directory nil
                                    (format "No such directory: %s" directory)))
   ((and provider (not (claude-code-ide-get-provider provider)))
    (claude-code-ide-control--error 'unknown-provider nil
                                    (format "No provider named %s" provider)))
   (t
    (let ((instance-id (claude-code-ide-instance-new-id)))
      (claude-code-ide-control--start
       instance-id
       (lambda ()
         (claude-code-ide--start-session
          nil nil
          (claude-code-ide-start-spec-create
           :directory (file-name-as-directory (expand-file-name directory))
           :instance-name name
           :prompt prompt
           :extra-flags extra-flags
           :provider provider
           :instance-id instance-id
           :role role))))))))

(defun claude-code-ide-control--registry-entry (instance-id)
  "Return the session registry entry of INSTANCE-ID, or nil.
The registry is read only while `claude-code-ide-session-registry-mode'
is on, because otherwise its file is not kept up to date."
  (when (bound-and-true-p claude-code-ide-session-registry-mode)
    (ignore-errors
      (claude-code-ide-session-registry--find
       (claude-code-ide-session-registry--entries) instance-id))))

(cl-defun claude-code-ide-control-resume (instance-id &key prompt directory native-id provider)
  "Start the instance INSTANCE-ID again and resume its conversation.
The session registry gives the directory, the provider and the native
ID of the instance.  Without a registry entry, DIRECTORY, NATIVE-ID
and PROVIDER give them.  PROMPT is the first message.  The instance
keeps its instance ID and gets the next launch generation.  The result
is that of `claude-code-ide-control-launch'."
  (let ((entry (and (claude-code-ide-control--valid-id-p instance-id)
                    (claude-code-ide-control--registry-entry instance-id))))
    (cond
     ((not (claude-code-ide-control--valid-id-p instance-id))
      (claude-code-ide-control--error 'invalid-instance-id instance-id))
     ((claude-code-ide-instance-by-id instance-id)
      (claude-code-ide-control--error 'already-running instance-id))
     ((and entry (eq (claude-code-ide-session-registry-entry-state entry) 'archived))
      (claude-code-ide-control--error 'archived instance-id))
     (entry
      (claude-code-ide-control--start
       instance-id
       (lambda () (claude-code-ide-session-registry--start-entry entry prompt))))
     ((not (and (stringp native-id) (stringp directory)))
      (claude-code-ide-control--error 'unknown-instance instance-id
                                      "No registry entry; give the directory and the native ID"))
     ((not (file-directory-p directory))
      (claude-code-ide-control--error 'no-directory instance-id
                                      (format "No such directory: %s" directory)))
     ((and provider (not (claude-code-ide-get-provider provider)))
      (claude-code-ide-control--error 'unknown-provider instance-id
                                      (format "No provider named %s" provider)))
     (t
      (claude-code-ide-control--start
       instance-id
       (lambda ()
         (claude-code-ide--start-session
          nil nil
          (claude-code-ide-start-spec-create
           :directory (file-name-as-directory (expand-file-name directory))
           :resume-id native-id
           :prompt prompt
           :provider provider
           :instance-id instance-id
           :last-generation (claude-code-ide-instance-current-generation instance-id)))))))))

(defun claude-code-ide-control-stop (instance-id)
  "End the instance INSTANCE-ID with the stop operation of its provider.
The result is (:status ok :instance-id ID :result stopped), the
unavailable result when the provider cannot stop, or an error result.
The prompts in its inbox stay there."
  (if-let* ((instance (claude-code-ide-instance-by-id instance-id)))
      (let ((result (condition-case err
                        (claude-code-ide-provider-call
                         (claude-code-ide-instance-provider instance) 'stop instance)
                      (error (claude-code-ide-control--error
                              'stop-failed instance-id (error-message-string err))))))
        (cond
         ((claude-code-ide-provider-unavailable-p result) result)
         ((eq (plist-get result :status) 'error) result)
         (result (list :status 'ok :instance-id instance-id :result 'stopped))
         (t (claude-code-ide-control--error 'stop-failed instance-id))))
    (claude-code-ide-control--error 'not-running instance-id)))

;;; The inbox

(cl-defstruct (claude-code-ide-control--record
               (:constructor claude-code-ide-control--record-create)
               (:copier nil))
  "One request in the inbox of an instance."
  (request-id nil :type string)
  (instance-id nil :type string)
  (seq 0 :type integer :documentation "Order of the request in its inbox.")
  (text-hash nil :type string)
  (text nil :documentation "The prompt while it waits; nil after delivery or rejection.")
  (result 'queued :type symbol :documentation "`queued', `delivered' or `rejected'.")
  (reason nil :documentation "Symbol that says why, or nil.")
  (created-at nil :type string)
  (updated-at nil :type string)
  (sent-at nil :documentation "Time when the prompt went to the provider, or nil.")
  (sent-generation nil :documentation "Launch generation that got the prompt, or nil.")
  (delivered-at nil)
  (requested-by nil :documentation "Instance ID of the MCP request, or nil."))

(defconst claude-code-ide-control--record-fields
  '((request_id . request-id) (instance_id . instance-id) (seq . seq)
    (text_hash . text-hash) (text . text) (result . result) (reason . reason)
    (created_at . created-at) (updated_at . updated-at) (sent_at . sent-at)
    (sent_generation . sent-generation) (delivered_at . delivered-at)
    (requested_by . requested-by))
  "JSON key and struct slot of each field of an inbox file.")

(defconst claude-code-ide-control--inbox-version 1
  "Version of the inbox file format.")

(defun claude-code-ide-control--now ()
  "Return the current time as an ISO 8601 string in UTC."
  (format-time-string "%FT%TZ" nil t))

(defun claude-code-ide-control--inbox-root ()
  "Return the directory that holds the inbox of each instance."
  (file-name-as-directory
   (expand-file-name
    (or claude-code-ide-control-inbox-directory
        (expand-file-name "inbox" (claude-code-ide-session-registry--report-directory))))))

(defun claude-code-ide-control-inbox-directory-of (instance-id)
  "Return the inbox folder of INSTANCE-ID.
Signal an error for an ID that cannot name a folder."
  (unless (claude-code-ide-control--valid-id-p instance-id)
    (error "Not a valid instance ID: %S" instance-id))
  (file-name-as-directory (expand-file-name instance-id (claude-code-ide-control--inbox-root))))

(defun claude-code-ide-control--record-file (instance-id request-id)
  "Return the inbox file of REQUEST-ID in the inbox of INSTANCE-ID.
The name is a hash of the request ID, so any request ID is safe."
  (expand-file-name (concat (substring (secure-hash 'sha256 (encode-coding-string
                                                             request-id 'utf-8))
                                       0 32)
                            ".json")
                    (claude-code-ide-control-inbox-directory-of instance-id)))

(defun claude-code-ide-control--normalize (text)
  "Return TEXT as the acknowledgement compares it.
Line ends become LF, and white space at the start and the end goes."
  (string-trim (replace-regexp-in-string "\r\n?" "\n" text)))

(defun claude-code-ide-control-text-hash (text)
  "Return the hash of the prompt TEXT that the acknowledgement compares."
  (secure-hash 'sha256 (encode-coding-string (claude-code-ide-control--normalize text)
                                             'utf-8)))

(defun claude-code-ide-control--record-to-alist (record)
  "Return RECORD as an alist for JSON."
  (cons (cons 'version claude-code-ide-control--inbox-version)
        (mapcar (lambda (field)
                  (let ((value (cl-struct-slot-value 'claude-code-ide-control--record
                                                     (cdr field) record)))
                    (cons (car field) (if (and value (symbolp value))
                                          (symbol-name value)
                                        value))))
                claude-code-ide-control--record-fields)))

(defun claude-code-ide-control--record-from-alist (alist)
  "Return the record of the JSON ALIST, or nil when it is not one."
  (when (and (equal (alist-get 'version alist) claude-code-ide-control--inbox-version)
             (stringp (alist-get 'request_id alist)))
    (let ((record (claude-code-ide-control--record-create)))
      (dolist (field claude-code-ide-control--record-fields)
        (let ((value (alist-get (car field) alist)))
          (setf (cl-struct-slot-value 'claude-code-ide-control--record (cdr field) record)
                (if (and (memq (cdr field) '(result reason)) (stringp value))
                    (intern value)
                  value))))
      record)))

(defun claude-code-ide-control--read-record (file)
  "Return the record in FILE, or nil when FILE cannot be read."
  (condition-case nil
      (claude-code-ide-control--record-from-alist
       (json-parse-string (with-temp-buffer
                            (let ((coding-system-for-read 'utf-8))
                              (insert-file-contents file))
                            (buffer-string))
                          :object-type 'alist :array-type 'list
                          :null-object nil :false-object nil))
    (error nil)))

(defun claude-code-ide-control--write-record (record)
  "Write RECORD to its inbox file atomically and return RECORD.
The text goes to a temporary file in the same folder, which is then
renamed over the inbox file.  The folder is private (mode 0700)."
  (let* ((instance-id (claude-code-ide-control--record-instance-id record))
         (dir (claude-code-ide-control-inbox-directory-of instance-id))
         (file (claude-code-ide-control--record-file
                instance-id (claude-code-ide-control--record-request-id record))))
    (setf (claude-code-ide-control--record-updated-at record) (claude-code-ide-control--now))
    (with-file-modes #o700
      (make-directory dir t))
    (let ((tmp (with-file-modes #o600
                 (make-temp-file (expand-file-name ".req-" dir) nil ".tmp"))))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (json-encode (claude-code-ide-control--record-to-alist record))
                            nil tmp nil 'silent))
            (rename-file tmp file t))
        (when (file-exists-p tmp)
          (delete-file tmp))))
    record))

(defun claude-code-ide-control--find-record (instance-id request-id)
  "Return the record of REQUEST-ID in the inbox of INSTANCE-ID, or nil."
  (let ((file (claude-code-ide-control--record-file instance-id request-id)))
    (when-let* ((record (and (file-exists-p file)
                             (claude-code-ide-control--read-record file))))
      (and (equal (claude-code-ide-control--record-request-id record) request-id)
           record))))

(defun claude-code-ide-control--records (instance-id)
  "Return the records in the inbox of INSTANCE-ID, oldest first."
  (let ((dir (and (claude-code-ide-control--valid-id-p instance-id)
                  (claude-code-ide-control-inbox-directory-of instance-id))))
    (when (and dir (file-directory-p dir))
      (sort (delq nil (mapcar #'claude-code-ide-control--read-record
                              (directory-files dir t "\\`[0-9a-f]+\\.json\\'" t)))
            (lambda (a b)
              (< (claude-code-ide-control--record-seq a)
                 (claude-code-ide-control--record-seq b)))))))

(defun claude-code-ide-control--pending-records (instance-id)
  "Return the records of INSTANCE-ID that are not delivered or rejected."
  (cl-remove-if-not (lambda (record)
                      (eq (claude-code-ide-control--record-result record) 'queued))
                    (claude-code-ide-control--records instance-id)))

(defun claude-code-ide-control--age (time)
  "Return the seconds since the ISO 8601 TIME, or nil."
  (when (stringp time)
    (ignore-errors (- (float-time) (float-time (parse-iso8601-time-string time))))))

(defun claude-code-ide-control--expired-p (record)
  "Return non-nil when RECORD was sent and its acknowledgement is overdue.
See `claude-code-ide-control-ack-timeout'."
  (let ((age (claude-code-ide-control--age (claude-code-ide-control--record-sent-at record))))
    (and age (>= age claude-code-ide-control-ack-timeout))))

(defun claude-code-ide-control--blocking-records (instance-id)
  "Return the records that keep a new prompt of INSTANCE-ID from going out.
They are the queued records and the sent records whose
acknowledgement is not yet overdue."
  (cl-remove-if #'claude-code-ide-control--expired-p
                (claude-code-ide-control--pending-records instance-id)))

(defun claude-code-ide-control--next-seq (instance-id)
  "Return the order number of the next request of INSTANCE-ID."
  (1+ (apply #'max 0 (mapcar #'claude-code-ide-control--record-seq
                             (claude-code-ide-control--records instance-id)))))

(defun claude-code-ide-control--record-summary (record)
  "Return the plist of RECORD without its text."
  (list :request-id (claude-code-ide-control--record-request-id record)
        :result (claude-code-ide-control--record-result record)
        :reason (claude-code-ide-control--record-reason record)
        :text-hash (claude-code-ide-control--record-text-hash record)
        :created-at (claude-code-ide-control--record-created-at record)
        :sent-at (claude-code-ide-control--record-sent-at record)
        :delivered-at (claude-code-ide-control--record-delivered-at record)))

(defun claude-code-ide-control--result (record &optional duplicate)
  "Return the submit result of RECORD.
DUPLICATE non-nil adds :duplicate t: the request ID was known."
  (append (list :destination (claude-code-ide-control--record-instance-id record)
                :request-id (claude-code-ide-control--record-request-id record)
                :result (claude-code-ide-control--record-result record)
                :reason (claude-code-ide-control--record-reason record)
                :sent-at (claude-code-ide-control--record-sent-at record))
          (when duplicate (list :duplicate t))))

(defun claude-code-ide-control-request-status (instance-id request-id)
  "Return the current result of REQUEST-ID in the inbox of INSTANCE-ID.
The result has the keys of `claude-code-ide-control-submit'.  An
unknown request gives (:status error :reason unknown-request)."
  (if-let* ((record (and (claude-code-ide-control--valid-id-p instance-id)
                         (stringp request-id)
                         (claude-code-ide-control--find-record instance-id request-id))))
      (claude-code-ide-control--result record)
    (claude-code-ide-control--error 'unknown-request instance-id)))

;;; State rules

(defun claude-code-ide-control--state-reason (state)
  "Return a symbol that names STATE and its reason.
An example is waiting-for-user/approval."
  (let ((name (plist-get state :state))
        (reason (plist-get state :reason)))
    (if reason (intern (format "%s/%s" name reason)) name)))

(defun claude-code-ide-control-decide (state queue)
  "Return what to do with a prompt for an instance in STATE.
STATE is a state plist of `claude-code-ide-instance-state', or the
symbol `stopped' for an instance that ended normally.  QUEUE is `auto'
\(the rules of each state), `always' or `never'.  The result is
\(ACTION . REASON): ACTION is `deliver', `queue' or `reject'.
Only an idle instance takes a prompt at once.  Every other state
queues, because a provider does not yet report each of its dialogs.
A failed or stopped instance rejects, unless QUEUE is `always'."
  (let ((name (if (eq state 'stopped) 'stopped (plist-get state :state)))
        (reason (if (eq state 'stopped)
                    'stopped
                  (claude-code-ide-control--state-reason state))))
    (cond
     ((eq name 'idle) (cons 'deliver nil))
     ((eq queue 'never) (cons 'reject reason))
     ((and (memq name '(failed stopped)) (not (eq queue 'always))) (cons 'reject reason))
     (t (cons 'queue reason)))))

(defun claude-code-ide-control--state-of (instance-id)
  "Return the state of INSTANCE-ID for the state rules, or nil when unknown.
A running instance gives its state plist.  An instance that does not
run gives the symbol `stopped' when the session registry marks it
closed, else the `disconnected' state, when the registry or this
Emacs knows it."
  (let ((state (claude-code-ide-instance-state instance-id))
        (instance (claude-code-ide-instance-by-id instance-id)))
    (if (and instance (claude-code-ide-instance-live-p instance))
        state
      (let ((entry (claude-code-ide-control--registry-entry instance-id)))
        (cond
         ((and entry (memq (claude-code-ide-session-registry-entry-state entry)
                           '(closed archived)))
          'stopped)
         ((or state entry)
          (claude-code-ide-instance-make-state 'disconnected)))))))

;;; Submit and delivery

(defun claude-code-ide-control--requester ()
  "Return the instance ID of the current MCP request, or nil."
  (and (fboundp 'claude-code-ide-mcp-request-instance-id)
       (ignore-errors (funcall 'claude-code-ide-mcp-request-instance-id))))

(defun claude-code-ide-control--rejected (instance-id request-id reason)
  "Return a rejected submit result that has no inbox file.
INSTANCE-ID, REQUEST-ID and REASON go into the result."
  (list :destination instance-id :request-id request-id :result 'rejected :reason reason))

(cl-defun claude-code-ide-control-submit (instance-id text &key request-id (queue nil queue-given))
  "Submit the prompt TEXT to the instance INSTANCE-ID through its inbox.
REQUEST-ID is a string that the caller chooses; nil makes a new one.
A second request with the same REQUEST-ID returns the result of the
first one, with :duplicate t, and sends nothing.

QUEUE says what happens when the instance cannot take TEXT now:
without the key, the rules of each state apply (queue, but reject a
failed or stopped instance); t always queues; nil rejects.

Return a plist with :destination (INSTANCE-ID), :request-id, :result
and :reason.  :result is `delivered' (a `prompt-submit' event of the
instance had the same text), `queued' (TEXT waits in the inbox, or it
was sent and waits for its acknowledgement; then :sent-at is non-nil
and :reason is `awaiting-acknowledgement'), or `rejected'."
  (let* ((request-id (cond ((stringp request-id) request-id)
                           ((numberp request-id) (number-to-string request-id))
                           (t (claude-code-ide-instance-new-id))))
         (queue (cond ((not queue-given) 'auto)
                      ((memq queue '(auto always never)) queue)
                      (queue 'always)
                      (t 'never))))
    (cond
     ((not (claude-code-ide-control--valid-id-p instance-id))
      (claude-code-ide-control--rejected instance-id request-id 'invalid-instance-id))
     ((claude-code-ide-control--find-record instance-id request-id)
      (claude-code-ide-control--result
       (claude-code-ide-control--find-record instance-id request-id) t))
     ((not (and (stringp text) (not (string-empty-p (string-trim text)))))
      (claude-code-ide-control--rejected instance-id request-id 'empty-text))
     (t
      (let ((state (claude-code-ide-control--state-of instance-id)))
        (if (null state)
            (claude-code-ide-control--rejected instance-id request-id 'unknown-instance)
          (claude-code-ide-control--submit-new instance-id text request-id queue state)))))))

(defun claude-code-ide-control--provider-can-submit-p (instance-id)
  "Return nil when the provider of the instance INSTANCE-ID has no submit-prompt.
An instance that does not run gives t: its provider decides later."
  (let* ((instance (claude-code-ide-instance-by-id instance-id))
         (provider (and instance (claude-code-ide-get-provider
                                  (claude-code-ide-instance-provider instance)))))
    (or (null instance)
        (and provider (claude-code-ide-provider-supports-p provider 'submit-prompt)))))

(defun claude-code-ide-control--submit-new (instance-id text request-id queue state)
  "Record and handle a new request REQUEST-ID with TEXT for INSTANCE-ID.
QUEUE is `auto', `always' or `never', and STATE the state for the rules."
  (let* ((decision (claude-code-ide-control-decide state queue))
         (action (car decision))
         (reason (cdr decision))
         (blocked (and (eq action 'deliver)
                       (claude-code-ide-control--blocking-records instance-id))))
    (cond
     ((not (claude-code-ide-control--provider-can-submit-p instance-id))
      (setq action 'reject reason 'submit-prompt-unavailable))
     ;; Earlier prompts go first
     (blocked
      (if (eq queue 'never)
          (setq action 'reject reason 'earlier-prompts-pending)
        (setq action 'queue reason 'earlier-prompts-pending))))
    (let ((record (claude-code-ide-control--record-create
                   :request-id request-id
                   :instance-id instance-id
                   :seq (claude-code-ide-control--next-seq instance-id)
                   :text-hash (claude-code-ide-control-text-hash text)
                   :text (unless (eq action 'reject) text)
                   :result (if (eq action 'reject) 'rejected 'queued)
                   :reason reason
                   :created-at (claude-code-ide-control--now)
                   :requested-by (claude-code-ide-control--requester))))
      (claude-code-ide-control--write-record record)
      (pcase action
        ('deliver (claude-code-ide-control--send record))
        ('queue (claude-code-ide-control--start-timer)))
      (claude-code-ide-control--result
       (claude-code-ide-control--find-record instance-id request-id)))))

(defun claude-code-ide-control--send (record)
  "Give the prompt of RECORD to the provider of its instance.
The record is marked sent before the call, so that a crash during the
call never sends the prompt twice.  When the provider does not send
it, the record waits in the inbox again.  Return non-nil when sent."
  (let* ((instance-id (claude-code-ide-control--record-instance-id record))
         (instance (claude-code-ide-instance-by-id instance-id))
         (text (claude-code-ide-control--record-text record)))
    (when (and instance (stringp text))
      (setf (claude-code-ide-control--record-sent-at record) (claude-code-ide-control--now)
            (claude-code-ide-control--record-sent-generation record)
            (claude-code-ide-instance-generation instance)
            (claude-code-ide-control--record-reason record) 'awaiting-acknowledgement)
      (claude-code-ide-control--write-record record)
      (let ((sent (condition-case err
                      (claude-code-ide-provider-call
                       (claude-code-ide-instance-provider instance)
                       'submit-prompt instance text)
                    (error
                     (message "Control inbox: submit to %s failed: %s"
                              instance-id (error-message-string err))
                     nil))))
        (if (and sent (not (claude-code-ide-provider-unavailable-p sent)))
            t
          (setf (claude-code-ide-control--record-sent-at record) nil
                (claude-code-ide-control--record-sent-generation record) nil
                (claude-code-ide-control--record-reason record) 'send-failed)
          (claude-code-ide-control--write-record record)
          (claude-code-ide-control--start-timer)
          nil)))))

(defun claude-code-ide-control-deliver-pending (instance-id)
  "Send the oldest queued prompt of INSTANCE-ID when the instance can take it.
It can take it when it runs, is idle, and has no sent prompt that
still waits for its acknowledgement (see
`claude-code-ide-control-ack-timeout').  Send at most one prompt.
Return the request ID of the prompt that was sent, or nil."
  (let ((pending (claude-code-ide-control--pending-records instance-id))
        (blocked nil)
        (next nil))
    (dolist (record pending)
      (cond
       ((not (claude-code-ide-control--record-sent-at record))
        (unless next (setq next record)))
       ((not (claude-code-ide-control--expired-p record))
        (setq blocked t))
       ((not (eq (claude-code-ide-control--record-reason record) 'unacknowledged))
        (setf (claude-code-ide-control--record-reason record) 'unacknowledged)
        (claude-code-ide-control--write-record record))))
    (when (and next (not blocked))
      (let ((instance (claude-code-ide-instance-by-id instance-id)))
        (when (and instance
                   (claude-code-ide-instance-live-p instance)
                   (eq (car (claude-code-ide-control-decide
                             (claude-code-ide-instance-state instance) 'never))
                       'deliver)
                   (claude-code-ide-control--send next))
          (claude-code-ide-control--record-request-id next))))))

;;; Acknowledgement

(defvar claude-code-ide-control-delivered-functions nil
  "Functions called when a prompt of the inbox is acknowledged.
Each function is called with INSTANCE-ID and REQUEST-ID.")

(defvar claude-code-ide-control--warned-providers nil
  "Providers whose `prompt-submit' events had no prompt text.")

(defun claude-code-ide-control--event-prompt (event)
  "Return the prompt text in the data of the common EVENT, or nil."
  (let ((data (plist-get event :data)))
    (when (listp data)
      (let ((prompt (or (alist-get 'prompt data)
                        (alist-get "prompt" data nil nil #'equal))))
        (and (stringp prompt) prompt)))))

(defun claude-code-ide-control--acknowledge (event)
  "Mark the sent prompt that the `prompt-submit' EVENT reports as delivered.
Return the request ID of that prompt, or nil."
  (let* ((instance-id (plist-get event :instance-id))
         (prompt (claude-code-ide-control--event-prompt event)))
    (if (not prompt)
        (let ((provider (and (claude-code-ide-instance-by-id instance-id)
                             (claude-code-ide-instance-provider
                              (claude-code-ide-instance-by-id instance-id)))))
          (unless (memq provider claude-code-ide-control--warned-providers)
            (push provider claude-code-ide-control--warned-providers)
            (display-warning 'claude-code-ide
                             (format "The prompt-submit events of the %s provider have no prompt text, so the control inbox cannot acknowledge its prompts"
                                     provider)))
          nil)
      (let* ((hash (claude-code-ide-control-text-hash prompt))
             (record (cl-find-if (lambda (record)
                                   (and (claude-code-ide-control--record-sent-at record)
                                        (equal (claude-code-ide-control--record-text-hash record)
                                               hash)))
                                 (claude-code-ide-control--pending-records instance-id))))
        (when record
          (setf (claude-code-ide-control--record-result record) 'delivered
                (claude-code-ide-control--record-reason record) nil
                (claude-code-ide-control--record-text record) nil
                (claude-code-ide-control--record-delivered-at record)
                (claude-code-ide-control--now))
          (claude-code-ide-control--write-record record)
          (let ((request-id (claude-code-ide-control--record-request-id record)))
            (claude-code-ide--run-session-hook 'claude-code-ide-control-delivered-functions
                                               instance-id request-id)
            request-id))))))

(defvar claude-code-ide-control--scheduled nil
  "Instance IDs whose delivery is scheduled.")

(defun claude-code-ide-control--schedule-delivery (instance-id)
  "Try to deliver the queued prompts of INSTANCE-ID in a moment.
The delay lets the status apply all the events that came together,
so that the state is current when the delivery checks it."
  (unless (member instance-id claude-code-ide-control--scheduled)
    (push instance-id claude-code-ide-control--scheduled)
    (run-at-time 0 nil
                 (lambda ()
                   (setq claude-code-ide-control--scheduled
                         (delete instance-id claude-code-ide-control--scheduled))
                   (condition-case err
                       (claude-code-ide-control-deliver-pending instance-id)
                     (error (message "Control inbox: delivery to %s failed: %s"
                                     instance-id (error-message-string err))))))))

(defun claude-code-ide-control--on-event (event)
  "Handle the common EVENT for the inboxes.
A `prompt-submit' event acknowledges a sent prompt.  Another event of
an instance with queued prompts, such as `turn-end' or
`session-start', starts a delivery."
  (let ((instance-id (plist-get event :instance-id)))
    (when (claude-code-ide-control--valid-id-p instance-id)
      (if (eq (plist-get event :event) 'prompt-submit)
          (claude-code-ide-control--acknowledge event)
        (when (claude-code-ide-control--pending-records instance-id)
          (claude-code-ide-control--schedule-delivery instance-id))))))

(add-hook 'claude-code-ide-event-functions #'claude-code-ide-control--on-event)

;;; Retry timer

(defvar claude-code-ide-control--timer nil
  "Timer that checks the queued prompts of running instances.")

(defun claude-code-ide-control--start-timer ()
  "Start the retry timer when it does not run."
  (when (and (numberp claude-code-ide-control-retry-interval)
             (> claude-code-ide-control-retry-interval 0)
             (not (timerp claude-code-ide-control--timer)))
    (setq claude-code-ide-control--timer
          (run-with-timer claude-code-ide-control-retry-interval
                          claude-code-ide-control-retry-interval
                          #'claude-code-ide-control--tick))))

(defun claude-code-ide-control--stop-timer ()
  "Stop the retry timer."
  (when (timerp claude-code-ide-control--timer)
    (cancel-timer claude-code-ide-control--timer))
  (setq claude-code-ide-control--timer nil))

(defun claude-code-ide-control--tick ()
  "Try to deliver the queued prompts of each running instance.
Stop the timer when no running instance has a queued prompt."
  (let ((pending nil))
    (dolist (instance (claude-code-ide-instances))
      (let ((id (claude-code-ide-instance-id instance)))
        (when (and (claude-code-ide-control--valid-id-p id)
                   (claude-code-ide-control--pending-records id))
          (setq pending t)
          (condition-case err
              (claude-code-ide-control-deliver-pending id)
            (error (message "Control inbox: delivery to %s failed: %s"
                            id (error-message-string err)))))))
    (unless pending
      (claude-code-ide-control--stop-timer))))

;;; MCP coordinator tools

(defun claude-code-ide-control--json-key (key)
  "Return the JSON name of the plist KEY, such as instance_id."
  (intern (replace-regexp-in-string "-" "_" (substring (symbol-name key) 1))))

(defconst claude-code-ide-control--json-booleans '(:live :state-guess :duplicate)
  "Plist keys whose nil value is false in JSON, not null.")

(defconst claude-code-ide-control--json-arrays '(:instances :inbox :capabilities)
  "Plist keys whose value is a JSON array, also when it is empty.")

(defun claude-code-ide-control--to-json (value &optional key)
  "Return VALUE, the value of the plist KEY, in the form that `json-encode' takes."
  (cond
   ((memq key claude-code-ide-control--json-arrays)
    (vconcat (mapcar #'claude-code-ide-control--to-json value)))
   ((memq key claude-code-ide-control--json-booleans)
    (if value t :json-false))
   ((and (consp value) (keywordp (car value)))
    (let ((alist nil))
      (while value
        (let ((k (pop value)) (v (pop value)))
          (push (cons (claude-code-ide-control--json-key k)
                      (claude-code-ide-control--to-json v k))
                alist)))
      (nreverse alist)))
   ((consp value) (vconcat (mapcar #'claude-code-ide-control--to-json value)))
   ((eq value t) t)
   ((and value (symbolp value)) (symbol-name value))
   (t value)))

(defun claude-code-ide-control--json (result)
  "Return the plist RESULT as JSON text for an MCP tool."
  (json-encode (claude-code-ide-control--to-json result)))

(defun claude-code-ide-control--blank-p (value)
  "Return non-nil when the MCP argument VALUE is missing or empty."
  (or (null value) (and (stringp value) (string-empty-p value))))

(defun claude-code-ide-control--provider-arg (value)
  "Return the provider name of the MCP argument VALUE, or nil."
  (unless (claude-code-ide-control--blank-p value) (intern value)))

(defun claude-code-ide-control--mcp-list-instances (&optional provider)
  "MCP tool: list the instances, of PROVIDER only when it is given."
  (claude-code-ide-control--json
   (claude-code-ide-control-list-instances (claude-code-ide-control--provider-arg provider))))

(defun claude-code-ide-control--mcp-inspect-instance (instance-id)
  "MCP tool: describe the instance INSTANCE-ID."
  (claude-code-ide-control--json (claude-code-ide-control-inspect-instance instance-id)))

(defun claude-code-ide-control--mcp-launch (directory &optional provider name prompt role)
  "MCP tool: start an instance in DIRECTORY with PROVIDER, NAME, PROMPT and ROLE."
  (claude-code-ide-control--json
   (claude-code-ide-control-launch
    :directory directory
    :provider (claude-code-ide-control--provider-arg provider)
    :name (unless (claude-code-ide-control--blank-p name) name)
    :prompt (unless (claude-code-ide-control--blank-p prompt) prompt)
    :role (unless (claude-code-ide-control--blank-p role) role))))

(defun claude-code-ide-control--mcp-resume (instance-id &optional prompt)
  "MCP tool: start INSTANCE-ID again with the first message PROMPT."
  (claude-code-ide-control--json
   (claude-code-ide-control-resume
    instance-id :prompt (unless (claude-code-ide-control--blank-p prompt) prompt))))

(defun claude-code-ide-control--mcp-submit (instance-id text &optional request-id queue)
  "MCP tool: submit TEXT to INSTANCE-ID with REQUEST-ID.
QUEUE is \"auto\" (the default), \"always\" or \"never\"."
  (let ((mode (pcase queue
                ("always" 'always)
                ("never" 'never)
                (_ 'auto))))
    (claude-code-ide-control--json
     (claude-code-ide-control-submit
      instance-id text
      :request-id (unless (claude-code-ide-control--blank-p request-id) request-id)
      :queue mode))))

(defun claude-code-ide-control--mcp-request-status (instance-id request-id)
  "MCP tool: return the result of REQUEST-ID in the inbox of INSTANCE-ID."
  (claude-code-ide-control--json
   (claude-code-ide-control-request-status instance-id request-id)))

(defun claude-code-ide-control--mcp-stop (instance-id)
  "MCP tool: end the instance INSTANCE-ID."
  (claude-code-ide-control--json (claude-code-ide-control-stop instance-id)))

(defconst claude-code-ide-control--instance-id-arg
  '(:name "instance_id" :type string
          :description "Instance ID of the target, from claude-code-ide-control-list-instances. Never a display name.")
  "The instance ID argument of the coordinator tools.")

(defun claude-code-ide-control--tool-specs ()
  "Return the `claude-code-ide-make-tool' arguments of each coordinator tool.
Each has :scope coordinator."
  (let ((id claude-code-ide-control--instance-id-arg))
    (list
     (list :name "claude-code-ide-control-list-instances"
           :function #'claude-code-ide-control--mcp-list-instances
           :description "List the coding-agent instances that run in Emacs, with instance ID, provider, display name, project, state and the number of queued prompts."
           :args '((:name "provider" :type string :optional t
                          :description "Only the instances of this provider, such as claude or codex.")))
     (list :name "claude-code-ide-control-inspect-instance"
           :function #'claude-code-ide-control--mcp-inspect-instance
           :description "Describe one instance by its instance ID: state, native conversation ID, buffer, process, provider capabilities and the requests in its inbox."
           :args (list id))
     (list :name "claude-code-ide-control-launch"
           :function #'claude-code-ide-control--mcp-launch
           :description "Start a new instance in a directory and return its instance ID."
           :args '((:name "directory" :type string
                          :description "Project directory of the new instance.")
                   (:name "provider" :type string :optional t
                          :description "Provider name, such as claude or codex. Default: the Emacs default provider.")
                   (:name "name" :type string :optional t
                          :description "Instance name, shown in the buffer name.")
                   (:name "prompt" :type string :optional t
                          :description "First message of the conversation.")
                   (:name "role" :type string :optional t
                          :description "Optional role of the instance.")))
     (list :name "claude-code-ide-control-resume"
           :function #'claude-code-ide-control--mcp-resume
           :description "Start a stopped instance again by its instance ID and resume its conversation."
           :args (list id
                       '(:name "prompt" :type string :optional t
                               :description "First message after the resume.")))
     (list :name "claude-code-ide-control-submit-prompt"
           :function #'claude-code-ide-control--mcp-submit
           :description "Submit a prompt to an instance through its inbox. Returns the destination, the request ID and the result: delivered, queued or rejected, with a reason. A request ID that was used before returns the first result and sends nothing."
           :args (list id
                       '(:name "text" :type string :description "The prompt text.")
                       '(:name "request_id" :type string :optional t
                               :description "ID that makes the request idempotent. Default: a new ID.")
                       '(:name "queue" :type string :optional t
                               :description "auto (default): queue while the instance is busy, reject a failed or stopped instance. always: always queue. never: reject unless the instance is idle.")))
     (list :name "claude-code-ide-control-request-status"
           :function #'claude-code-ide-control--mcp-request-status
           :description "Return the current result of a submitted prompt: delivered, queued or rejected."
           :args (list id
                       '(:name "request_id" :type string
                               :description "Request ID of the submitted prompt.")))
     (list :name "claude-code-ide-control-stop"
           :function #'claude-code-ide-control--mcp-stop
           :description "End an instance by its instance ID. Its queued prompts stay in its inbox."
           :args (list id)))))

(defvar claude-code-ide-control--extra-tool-specs nil
  "Coordinator tools that other files add.
See `claude-code-ide-control-define-tool'.")

(defun claude-code-ide-control-scope-enforced-p ()
  "Return non-nil when the MCP server enforces the coordinator scope.
The routing code that checks the coordinator credential also defines
`claude-code-ide-mcp-request-instance-id'."
  (fboundp 'claude-code-ide-mcp-request-instance-id))

(defun claude-code-ide-control--tool-names ()
  "Return the names of all coordinator tools of this file and its users."
  (mapcar (lambda (spec) (plist-get spec :name))
          (append (claude-code-ide-control--tool-specs)
                  claude-code-ide-control--extra-tool-specs)))

(defun claude-code-ide-control--make-tool (spec)
  "Add the coordinator tool SPEC to the MCP tools and return the tool.
The tool always carries :scope coordinator, also when
`claude-code-ide-make-tool' does not keep that key."
  (let ((tool (apply #'claude-code-ide-make-tool
                     (append spec (list :scope 'coordinator)))))
    (unless (eq (plist-get tool :scope) 'coordinator)
      ;; plist-put changes the list in place, also in the tools list
      (plist-put tool :scope 'coordinator))
    tool))

(defun claude-code-ide-control-remove-mcp-tools ()
  "Remove the coordinator tools from the MCP tools."
  (let ((names (claude-code-ide-control--tool-names)))
    (setq claude-code-ide-mcp-server-tools
          (cl-remove-if (lambda (tool)
                          (and (consp tool) (keywordp (car tool))
                               (member (plist-get tool :name) names)))
                        claude-code-ide-mcp-server-tools))))

(defun claude-code-ide-control-setup-mcp-tools (&optional force)
  "Add the control operations to the MCP tools, as coordinator tools.
Return the list of the added tools.  Without FORCE, signal a
`user-error' when the MCP server does not enforce the coordinator
scope, because then every instance could control every other one."
  (interactive "P")
  (unless (or force (claude-code-ide-control-scope-enforced-p))
    (user-error "The MCP server does not check the coordinator scope; the control tools stay off"))
  (claude-code-ide-control-remove-mcp-tools)
  (mapcar #'claude-code-ide-control--make-tool
          (append (claude-code-ide-control--tool-specs)
                  claude-code-ide-control--extra-tool-specs)))

(defun claude-code-ide-control-define-tool (&rest spec)
  "Add a coordinator tool from SPEC, the arguments of `claude-code-ide-make-tool'.
The handover and review files use this for their operations.  The
tool is added to the MCP tools when the control tools are set up."
  (setq claude-code-ide-control--extra-tool-specs
        (append (cl-remove (plist-get spec :name) claude-code-ide-control--extra-tool-specs
                           :key (lambda (s) (plist-get s :name)) :test #'equal)
                (list spec)))
  (when (cl-find-if (lambda (tool)
                      (and (consp tool) (keywordp (car tool))
                           (member (plist-get tool :name) (claude-code-ide-control--tool-names))))
                    claude-code-ide-mcp-server-tools)
    (claude-code-ide-control-setup-mcp-tools t))
  spec)

(when (and claude-code-ide-control-enable-mcp-tools
           (claude-code-ide-control-scope-enforced-p))
  (claude-code-ide-control-setup-mcp-tools))

(provide 'claude-code-ide-control)

;;; claude-code-ide-control.el ends here
