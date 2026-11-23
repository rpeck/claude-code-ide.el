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
;; tools, and the helpers that other files of the package (such as
;; the review file) use: `claude-code-ide-control-valid-id-p',
;; `claude-code-ide-control-state-of', `claude-code-ide-control-refresh'
;; and the others of its section "Helpers for other files".

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
with the same text.  After this time, the sent prompt gets the final
result `unacknowledged': it is never sent again, and the next queued
prompt can go out."
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

(defcustom claude-code-ide-control-done-days 7
  "Days that a final inbox record stays in the done folder.
A record is final when it is delivered, rejected or unacknowledged.
While it stays, a request with its request ID is a duplicate."
  :type 'number
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

(defun claude-code-ide-control-valid-id-p (id)
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
and :inbox (the requests that wait in its inbox, without their
text).  An
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
                                     (claude-code-ide-control--pending-records instance-id)))))
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

(defun claude-code-ide-control-registry-entry (instance-id)
  "Return the session registry entry of INSTANCE-ID, or nil.
The registry is read only while `claude-code-ide-session-registry-mode'
is on, because otherwise its file is not kept up to date."
  (when (bound-and-true-p claude-code-ide-session-registry-mode)
    (ignore-errors
      (claude-code-ide-session-registry--find
       (claude-code-ide-session-registry--entries) instance-id))))

(defun claude-code-ide-control--native-id-of (instance)
  "Return the native conversation ID of the descriptor INSTANCE, or nil."
  (let ((id (ignore-errors
              (claude-code-ide-provider-call
               (claude-code-ide-instance-provider instance) 'native-id instance))))
    (if (stringp id)
        id
      (let ((slot (claude-code-ide-known-or-nil (claude-code-ide-instance-native-id instance))))
        (and (stringp slot) slot)))))

(defun claude-code-ide-control--native-id-runner (native-id instance-id)
  "Return a live instance other than INSTANCE-ID that runs NATIVE-ID, or nil."
  (cl-find-if (lambda (instance)
                (and (not (equal (claude-code-ide-instance-id instance) instance-id))
                     (claude-code-ide-instance-live-p instance)
                     (equal (claude-code-ide-control--native-id-of instance) native-id)))
              (claude-code-ide-instances)))

(cl-defun claude-code-ide-control-resume (instance-id &key prompt directory native-id provider)
  "Start the instance INSTANCE-ID again and resume its conversation.
The session registry gives the directory, the provider and the native
ID of the instance.  Without a registry entry, DIRECTORY, NATIVE-ID
and PROVIDER give them; when another live instance of this Emacs runs
NATIVE-ID, the result is an error with the reason `native-id-running'.
PROMPT is the first message.  The instance keeps its instance ID and
gets the next launch generation.  The result is that of
`claude-code-ide-control-launch'."
  (let* ((entry (and (claude-code-ide-control-valid-id-p instance-id)
                     (claude-code-ide-control-registry-entry instance-id)))
         (runner (and (not entry) (stringp native-id)
                      (claude-code-ide-control--native-id-runner native-id instance-id))))
    (cond
     ((not (claude-code-ide-control-valid-id-p instance-id))
      (claude-code-ide-control--error 'invalid-instance-id instance-id))
     ((when-let* ((instance (claude-code-ide-instance-by-id instance-id)))
        (claude-code-ide-instance-live-p instance))
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
     (runner
      (claude-code-ide-control--error
       'native-id-running instance-id
       (format "The instance %s runs the conversation %s"
               (claude-code-ide-instance-id runner) native-id)))
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

(defun claude-code-ide-control--current-generation (instance-id)
  "Return the generation of the last launch of INSTANCE-ID, or nil.
This Emacs knows it after a launch; else the session registry gives it."
  (or (claude-code-ide-instance-current-generation instance-id)
      (when-let* ((entry (claude-code-ide-control-registry-entry instance-id)))
        (claude-code-ide-session-registry-entry-generation entry))))

(defun claude-code-ide-control--generation-changed-p (instance-id generation)
  "Return non-nil when GENERATION is given and is not that of INSTANCE-ID.
The generation of INSTANCE-ID is that of its last launch."
  (and generation
       (not (eql generation (claude-code-ide-control--current-generation instance-id)))))

(cl-defun claude-code-ide-control-stop (instance-id &key generation)
  "End the instance INSTANCE-ID with the stop operation of its provider.
GENERATION, when given, is the launch generation that the caller saw:
when INSTANCE-ID runs another launch now, nothing stops, and the
result is an error with the reason `generation-changed'.
The result is (:status ok :instance-id ID :result stopped), the
unavailable result when the provider cannot stop, or an error result.
The prompts in its inbox stay there."
  (if-let* ((instance (claude-code-ide-instance-by-id instance-id)))
      (let ((result (if (and generation
                             (not (eql generation (claude-code-ide-instance-generation instance))))
                        (claude-code-ide-control--error
                         'generation-changed instance-id
                         (format "The instance runs launch generation %s, not %s"
                                 (claude-code-ide-instance-generation instance) generation))
                      (condition-case err
                          (claude-code-ide-provider-call
                           (claude-code-ide-instance-provider instance) 'stop instance)
                        (error (claude-code-ide-control--error
                                'stop-failed instance-id (error-message-string err)))))))
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
  (text nil :documentation "The prompt while it waits; nil in a final record.")
  (result 'queued :type symbol
          :documentation "`queued', `delivered', `rejected' or `unacknowledged'.")
  (reason nil :documentation "Symbol that says why, or nil.")
  (created-at nil :type string)
  (updated-at nil :type string)
  (sent-at nil :documentation "Time when the prompt went to the provider, or nil.")
  (sent-generation nil :documentation "Launch generation that got the prompt, or nil.")
  (sent-guess nil :documentation "Non-nil when the idle state at the send was a guess.")
  (delivered-at nil)
  (requested-by nil :documentation "Instance ID of the MCP request, or nil.")
  (moved-from nil :documentation "INSTANCE:REQUEST-ID of the record that a handover moved here, or nil.")
  (moved-to nil :documentation "INSTANCE:REQUEST-ID of the record that a handover moved this one to, or nil.")
  (note nil :documentation "Text for people about the record, or nil."))

(defconst claude-code-ide-control--record-fields
  '((request_id . request-id) (instance_id . instance-id) (seq . seq)
    (text_hash . text-hash) (text . text) (result . result) (reason . reason)
    (created_at . created-at) (updated_at . updated-at) (sent_at . sent-at)
    (sent_generation . sent-generation) (sent_guess . sent-guess)
    (delivered_at . delivered-at) (requested_by . requested-by)
    (moved_from . moved-from) (moved_to . moved-to) (note . note))
  "JSON key and struct slot of each field of an inbox file.")

(defconst claude-code-ide-control--symbol-slots '(result reason)
  "Slots whose value is a symbol, and a string in the file.")

(defconst claude-code-ide-control--inbox-version 1
  "Version of the inbox file format.")

(defvar claude-code-ide-control--index (make-hash-table :test 'equal)
  "Pending records of each inbox folder, oldest first.
The key is the inbox folder of an instance.  The first use of a folder
reads its files; after that, the writes of this file keep the index
current, and the events read no files.")

(defun claude-code-ide-control-now ()
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
Its pending requests are files in it; the final ones are in its
subfolder done.  Signal an error for an ID that cannot name a folder."
  (unless (claude-code-ide-control-valid-id-p instance-id)
    (error "Not a valid instance ID: %S" instance-id))
  (file-name-as-directory (expand-file-name instance-id (claude-code-ide-control--inbox-root))))

(defun claude-code-ide-control--done-directory (instance-id)
  "Return the folder of the final records of INSTANCE-ID."
  (file-name-as-directory
   (expand-file-name "done" (claude-code-ide-control-inbox-directory-of instance-id))))

(defun claude-code-ide-control--file-name (request-id)
  "Return the file name of REQUEST-ID: a hash, so any request ID is safe."
  (concat (substring (secure-hash 'sha256 (encode-coding-string request-id 'utf-8)) 0 32)
          ".json"))

(defun claude-code-ide-control--record-file (instance-id request-id &optional done)
  "Return the file of REQUEST-ID in the inbox of INSTANCE-ID.
With DONE, return its file in the done folder."
  (expand-file-name (claude-code-ide-control--file-name request-id)
                    (if done
                        (claude-code-ide-control--done-directory instance-id)
                      (claude-code-ide-control-inbox-directory-of instance-id))))

(defun claude-code-ide-control--final-p (record)
  "Return non-nil when RECORD is delivered, rejected or unacknowledged."
  (not (eq (claude-code-ide-control--record-result record) 'queued)))

(defun claude-code-ide-control--line-ends (text)
  "Return TEXT with each CR LF and each lone CR replaced by LF."
  (replace-regexp-in-string "\r\n?" "\n" text))

(defun claude-code-ide-control--normalize (text)
  "Return TEXT as the acknowledgement compares it.
Line ends become LF, and white space at the start and the end goes."
  (string-trim (claude-code-ide-control--line-ends text)))

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
                    (cons (car field)
                          (if (and value (memq (cdr field) claude-code-ide-control--symbol-slots))
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
                (if (and (memq (cdr field) claude-code-ide-control--symbol-slots)
                         (stringp value))
                    (intern value)
                  value))))
      record)))

(defun claude-code-ide-control-json-decode (text)
  "Parse the JSON TEXT into an alist with symbol keys.
Use the native parser when this Emacs has one, else json.el."
  (if (and (fboundp 'json-available-p) (json-available-p))
      (json-parse-string text :object-type 'alist :array-type 'list
                         :null-object nil :false-object nil)
    (claude-code-ide-session-registry--json-decode text)))

(defun claude-code-ide-control--read-record (file)
  "Return the record in FILE, or nil when FILE cannot be read."
  (condition-case nil
      (claude-code-ide-control--record-from-alist
       (claude-code-ide-control-json-decode
        (claude-code-ide-session-registry--file-string file)))
    (error nil)))

(defun claude-code-ide-control-write-json-file (file data)
  "Write DATA, a value for `json-encode', to FILE atomically.
The text goes to a temporary file (mode 0600) in the same folder, which
is then renamed over FILE.  The folder is private (mode 0700).  Other
files of the package, such as the review file, use it too."
  (let ((dir (file-name-directory file)))
    (with-file-modes #o700
      (make-directory dir t))
    (let ((tmp (with-file-modes #o600
                 (make-temp-file (expand-file-name ".req-" dir) nil ".tmp"))))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (json-encode data) nil tmp nil 'silent))
            (rename-file tmp file t))
        (when (file-exists-p tmp)
          (delete-file tmp))))))

(defun claude-code-ide-control--write-file (file record)
  "Write RECORD to FILE atomically; see `claude-code-ide-control-write-json-file'."
  (claude-code-ide-control-write-json-file
   file (claude-code-ide-control--record-to-alist record)))

(defun claude-code-ide-control--pending-records (instance-id)
  "Return the pending records of INSTANCE-ID, oldest first.
The first call for an inbox folder reads its files; later calls read
the index.  A pending file whose final copy exists in done is a
left-over of an interrupted move, and is deleted."
  (when (claude-code-ide-control-valid-id-p instance-id)
    (let* ((dir (claude-code-ide-control-inbox-directory-of instance-id))
           (cell (gethash dir claude-code-ide-control--index 'none)))
      (if (not (eq cell 'none))
          cell
        (let ((records nil))
          (when (file-directory-p dir)
            (dolist (file (directory-files dir t "\\`[0-9a-f]+\\.json\\'" t))
              (let ((record (claude-code-ide-control--read-record file)))
                (cond
                 ((file-exists-p (expand-file-name (file-name-nondirectory file)
                                                   (claude-code-ide-control--done-directory
                                                    instance-id)))
                  (ignore-errors (delete-file file)))
                 ((and record (not (claude-code-ide-control--final-p record)))
                  (push record records))))))
          (puthash dir (sort records (lambda (a b)
                                       (< (claude-code-ide-control--record-seq a)
                                          (claude-code-ide-control--record-seq b))))
                   claude-code-ide-control--index))))))

(defun claude-code-ide-control-prune-folder (dir days &optional regexp)
  "Delete the files in DIR whose names match REGEXP and that are older than DAYS.
REGEXP defaults to the names of the inbox files (hex digits and
\".json\").  Other files of the package, such as the review file, use
it too."
  (when (file-directory-p dir)
    (dolist (file (directory-files dir t (or regexp "\\`[0-9a-f]+\\.json\\'") t))
      (claude-code-ide-control-prune-file file days))))

(defun claude-code-ide-control-prune-file (file days)
  "Delete FILE when it is older than DAYS, and return non-nil then.
The age is that of its last change.  A file that does not exist gives
nil.  A delete that fails is ignored; the result is still non-nil."
  (when-let* ((attributes (file-attributes file)))
    (when (> (float-time (time-subtract nil (file-attribute-modification-time attributes)))
             (* days 86400))
      (ignore-errors (delete-file file))
      t)))

(defun claude-code-ide-control--prune-done (instance-id)
  "Delete the final records of INSTANCE-ID that are too old.
See `claude-code-ide-control-done-days'."
  (claude-code-ide-control-prune-folder (claude-code-ide-control--done-directory instance-id)
                                        claude-code-ide-control-done-days))

(defun claude-code-ide-control--write-record (record)
  "Write RECORD to its inbox file and update the index.  Return RECORD.
A pending record is a file in the inbox folder.  A final record moves
to the done folder: the final copy is written first, then the pending
file is deleted, so that an interrupted move loses nothing."
  (let* ((instance-id (claude-code-ide-control--record-instance-id record))
         (request-id (claude-code-ide-control--record-request-id record))
         (pending (claude-code-ide-control--pending-records instance-id))
         (others (cl-remove request-id pending
                            :key #'claude-code-ide-control--record-request-id :test #'equal))
         (file (claude-code-ide-control--record-file instance-id request-id)))
    (setf (claude-code-ide-control--record-updated-at record) (claude-code-ide-control-now))
    (if (claude-code-ide-control--final-p record)
        (progn
          (setf (claude-code-ide-control--record-text record) nil)
          (claude-code-ide-control--write-file
           (claude-code-ide-control--record-file instance-id request-id t) record)
          (when (file-exists-p file)
            (delete-file file))
          (puthash (claude-code-ide-control-inbox-directory-of instance-id) others
                   claude-code-ide-control--index)
          (claude-code-ide-control--prune-done instance-id))
      (claude-code-ide-control--write-file file record)
      (puthash (claude-code-ide-control-inbox-directory-of instance-id)
               (sort (cons record (copy-sequence others))
                     (lambda (a b)
                       (< (claude-code-ide-control--record-seq a)
                          (claude-code-ide-control--record-seq b))))
               claude-code-ide-control--index))
    record))

(defun claude-code-ide-control--find-record (instance-id request-id &optional pending)
  "Return the record of REQUEST-ID in the inbox of INSTANCE-ID, or nil.
PENDING, when given, is the list of the pending records of INSTANCE-ID."
  (or (cl-find request-id (or pending (claude-code-ide-control--pending-records instance-id))
               :key #'claude-code-ide-control--record-request-id :test #'equal)
      (let ((file (claude-code-ide-control--record-file instance-id request-id t)))
        (when-let* ((record (and (file-exists-p file)
                                 (claude-code-ide-control--read-record file))))
          (and (equal (claude-code-ide-control--record-request-id record) request-id)
               record)))))

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

(defun claude-code-ide-control-request-id-string (request-id)
  "Return REQUEST-ID as a string: a number becomes its decimal text.
Return nil for another value."
  (cond ((stringp request-id) request-id)
        ((numberp request-id) (number-to-string request-id))))

(defun claude-code-ide-control-request-status (instance-id request-id)
  "Return the current result of REQUEST-ID in the inbox of INSTANCE-ID.
REQUEST-ID is a string or a number, as for `claude-code-ide-control-submit'.
The result has the keys of `claude-code-ide-control-submit'.  An
unknown request gives (:status error :reason unknown-request)."
  (let ((request-id (claude-code-ide-control-request-id-string request-id)))
    (if-let* ((record (and (claude-code-ide-control-valid-id-p instance-id)
                           request-id
                           (claude-code-ide-control--find-record instance-id request-id))))
        (claude-code-ide-control--result record)
      (claude-code-ide-control--error 'unknown-request instance-id))))

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
symbol `stopped' for an instance that the session registry marks
closed.  QUEUE is `auto' (the rules of each state), `always' or
`never'.  The result is (ACTION . REASON): ACTION is `deliver',
`queue' or `reject'.  Only an idle instance takes a prompt at once.
Every other state queues, because a provider does not yet report each
of its dialogs.  A failed or stopped instance rejects, unless QUEUE is
`always'."
  (let ((name (if (eq state 'stopped) 'stopped (plist-get state :state)))
        (reason (if (eq state 'stopped)
                    'stopped
                  (claude-code-ide-control--state-reason state))))
    (cond
     ((eq name 'idle) (cons 'deliver nil))
     ((eq queue 'never) (cons 'reject reason))
     ((and (memq name '(failed stopped)) (not (eq queue 'always))) (cons 'reject reason))
     (t (cons 'queue reason)))))

(defvar claude-code-ide-control-guess-safe-providers '(codex)
  "Providers whose submit-prompt never types into the terminal.
An idle state that is a guess (:guess t) can be a dialog that no event
reports.  Typed text and Return could answer that dialog, so the inbox
sends to a guessed idle instance only when its provider is in this
list.  The `codex' provider uses `codex queue', which Codex delivers
only when the conversation is idle.  Claude Code types the prompt.")

(defun claude-code-ide-control--guess-blocks-p (instance state)
  "Return non-nil when the guessed idle STATE of INSTANCE must not get a prompt.
See `claude-code-ide-control-guess-safe-providers'."
  (and (eq (plist-get state :state) 'idle)
       (plist-get state :guess)
       (not (and instance
                 (memq (claude-code-ide-instance-provider instance)
                       claude-code-ide-control-guess-safe-providers)))))

(defun claude-code-ide-control--failed-state (entry)
  "Return the `failed' state of the failed registry ENTRY.
The reason is `exit-code' when the CLI exited with an error code, else
`error'.  The state plist also has :detail, the failure of ENTRY."
  (let ((failure (claude-code-ide-session-registry-entry-failure entry)))
    (append (claude-code-ide-instance-make-state
             'failed
             (if (and (stringp failure)
                      (string-prefix-p "The CLI exited with code" failure))
                 'exit-code
               'error))
            (list :detail failure))))

(defun claude-code-ide-control-state-of (instance-id)
  "Return the state of INSTANCE-ID for the state rules, or nil when unknown.
A running instance gives its state plist.  For an instance that does
not run, the session registry decides:
- closed or archived: the symbol `stopped';
- failed: the `failed' state, with the failure of the entry as :detail;
- pending: `working' with the reason `starting', because its start
  has not ended;
- open, or an instance that this Emacs knows without an entry: the
  `disconnected' state."
  (let ((state (claude-code-ide-instance-state instance-id))
        (instance (claude-code-ide-instance-by-id instance-id)))
    (if (and instance (claude-code-ide-instance-live-p instance))
        state
      (let* ((entry (claude-code-ide-control-registry-entry instance-id))
             (entry-state (and entry (claude-code-ide-session-registry-entry-state entry))))
        (cond
         ((memq entry-state '(closed archived)) 'stopped)
         ((eq entry-state 'failed) (claude-code-ide-control--failed-state entry))
         ((eq entry-state 'pending) (claude-code-ide-instance-make-state 'working 'starting))
         ((or state entry)
          (claude-code-ide-instance-make-state 'disconnected)))))))

;;; Submit and delivery

(defvar claude-code-ide-control--held nil
  "Instance IDs whose inbox delivery is held.
A handover holds the delivery to its source while it quiesces and
stops it, so that no queued prompt is sent to the source then.")

(defun claude-code-ide-control-hold (instance-id)
  "Hold the inbox delivery to INSTANCE-ID: its prompts are only queued."
  (unless (member instance-id claude-code-ide-control--held)
    (push instance-id claude-code-ide-control--held))
  instance-id)

(defun claude-code-ide-control-release (instance-id)
  "End the hold of the inbox delivery to INSTANCE-ID, and deliver its prompts."
  (when (member instance-id claude-code-ide-control--held)
    (setq claude-code-ide-control--held (delete instance-id claude-code-ide-control--held))
    (when (claude-code-ide-control--pending-records instance-id)
      (claude-code-ide-control--schedule-delivery instance-id)))
  instance-id)

(defun claude-code-ide-control-held-p (instance-id)
  "Return non-nil when the inbox delivery to INSTANCE-ID is held."
  (and (member instance-id claude-code-ide-control--held) t))

(defun claude-code-ide-control--requester ()
  "Return the instance ID of the current MCP request, or nil."
  (and (fboundp 'claude-code-ide-mcp-request-instance-id)
       (ignore-errors (funcall 'claude-code-ide-mcp-request-instance-id))))

(defun claude-code-ide-control--rejected (instance-id request-id reason)
  "Return a rejected submit result that has no inbox file.
INSTANCE-ID, REQUEST-ID and REASON go into the result."
  (list :destination instance-id :request-id request-id :result 'rejected :reason reason))

(defun claude-code-ide-control--age (time)
  "Return the seconds since the ISO 8601 TIME, or nil."
  (when (stringp time)
    (ignore-errors (- (float-time) (float-time (parse-iso8601-time-string time))))))

(defun claude-code-ide-control--expired-p (record)
  "Return non-nil when the sent RECORD can no longer be acknowledged in time.
That is when `claude-code-ide-control-ack-timeout' passed since the
send, or when a later launch of the instance runs: the events of the
launch that got the prompt are dropped."
  (when (claude-code-ide-control--record-sent-at record)
    (let ((age (claude-code-ide-control--age (claude-code-ide-control--record-sent-at record)))
          (generation (claude-code-ide-control--record-sent-generation record))
          (current (claude-code-ide-instance-current-generation
                    (claude-code-ide-control--record-instance-id record))))
      (or (and age (>= age claude-code-ide-control-ack-timeout))
          (and (integerp generation) (integerp current) (< generation current))))))

(defun claude-code-ide-control--finish (record result reason)
  "Make RECORD final with RESULT and REASON, and write it."
  (setf (claude-code-ide-control--record-result record) result
        (claude-code-ide-control--record-reason record) reason)
  (claude-code-ide-control--write-record record))

(defun claude-code-ide-control-refresh (instance-id)
  "Make the overdue sent records of INSTANCE-ID final, and return the rest.
An overdue record gets the result `unacknowledged'.  It is never sent
again and no longer blocks the queue.  The result is the list of the
pending records, oldest first."
  (let ((pending (claude-code-ide-control--pending-records instance-id)))
    (if (not (cl-some #'claude-code-ide-control--expired-p pending))
        pending
      (dolist (record pending)
        (when (claude-code-ide-control--expired-p record)
          (claude-code-ide-control--finish record 'unacknowledged 'no-acknowledgement)))
      (claude-code-ide-control--pending-records instance-id))))

(defun claude-code-ide-control--provider-can-submit-p (instance)
  "Return nil when the provider of the descriptor INSTANCE has no submit-prompt.
A nil INSTANCE (one that does not run) gives t: its provider decides later."
  (or (null instance)
      (let ((provider (claude-code-ide-get-provider (claude-code-ide-instance-provider instance))))
        (and provider (claude-code-ide-provider-supports-p provider 'submit-prompt)))))

(cl-defun claude-code-ide-control-submit (instance-id text &key request-id (queue nil queue-given)
                                                      generation)
  "Submit the prompt TEXT to the instance INSTANCE-ID through its inbox.
REQUEST-ID is a string or a number that the caller chooses; nil makes
a new one.  A second request with the same REQUEST-ID returns the
result of the first one, with :duplicate t, and sends nothing.

QUEUE says what happens when the instance cannot take TEXT now:
without the key, the rules of each state apply (queue, but reject a
failed or stopped instance); t always queues; nil rejects.

GENERATION, when given, is the launch generation of INSTANCE-ID that
the caller saw.  When the last launch of INSTANCE-ID has another
generation, a new request is rejected with the reason
`generation-changed', and no inbox file is made.

After a committed handover of INSTANCE-ID, the prompt goes to the
current instance of its chain; see
`claude-code-ide-session-registry-chain-current'.

Return a plist with :destination (the instance that gets TEXT),
:request-id, :result, :reason and :sent-at.  :result is one of these:
- `delivered': a `prompt-submit' event of the instance had the same text.
- `queued': TEXT waits in the inbox, or it was sent and waits for its
  acknowledgement; then :sent-at is non-nil and :reason is
  `awaiting-acknowledgement'.
- `unacknowledged': TEXT was sent, but no acknowledgement came in time.
- `rejected': TEXT does not go out; :reason says why."
  (let* ((request-id (or (claude-code-ide-control-request-id-string request-id)
                         (claude-code-ide-instance-new-id)))
         (queue (cond ((not queue-given) 'auto)
                      ((memq queue '(auto always never)) queue)
                      (queue 'always)
                      (t 'never)))
         (given-id instance-id))
    (when (claude-code-ide-control-valid-id-p instance-id)
      (setq instance-id (claude-code-ide-control--chain-current instance-id)))
    (if (not (claude-code-ide-control-valid-id-p instance-id))
        (claude-code-ide-control--rejected instance-id request-id 'invalid-instance-id)
      (let* ((pending (claude-code-ide-control-refresh instance-id))
             (known (claude-code-ide-control--find-record instance-id request-id pending)))
        (cond
         (known (claude-code-ide-control--result known t))
         ((claude-code-ide-control--generation-changed-p given-id generation)
          (claude-code-ide-control--rejected instance-id request-id 'generation-changed))
         ((not (and (stringp text) (not (string-empty-p (string-trim text)))))
          (claude-code-ide-control--rejected instance-id request-id 'empty-text))
         (t
          (let ((state (claude-code-ide-control-state-of instance-id)))
            (if (null state)
                (claude-code-ide-control--rejected instance-id request-id 'unknown-instance)
              (claude-code-ide-control--submit-new
               instance-id text request-id queue state pending)))))))))

(defun claude-code-ide-control--chain-current (instance-id)
  "Return the current instance of the handover chain of INSTANCE-ID.
After a committed handover, a prompt for the old instance goes to the
new one.  Without a chain, or without the registry, it is INSTANCE-ID."
  (or (and (bound-and-true-p claude-code-ide-session-registry-mode)
           (fboundp 'claude-code-ide-session-registry-chain-current)
           (let ((current (ignore-errors
                            (funcall 'claude-code-ide-session-registry-chain-current instance-id))))
             (and (claude-code-ide-control-valid-id-p current) current)))
      instance-id))

(defun claude-code-ide-control--submit-new (instance-id text request-id queue state pending)
  "Record and handle a new request REQUEST-ID with TEXT for INSTANCE-ID.
QUEUE is `auto', `always' or `never', STATE the state for the rules,
and PENDING the pending records of INSTANCE-ID."
  (let* ((decision (claude-code-ide-control-decide state queue))
         (action (car decision))
         (reason (cdr decision))
         (instance (claude-code-ide-instance-by-id instance-id)))
    (cond
     ((not (claude-code-ide-control--provider-can-submit-p instance))
      (setq action 'reject reason 'no-submit))
     ;; A handover holds the delivery: queue (or reject without a queue)
     ((and (eq action 'deliver) (claude-code-ide-control-held-p instance-id))
      (if (eq queue 'never)
          (setq action 'reject reason 'held)
        (setq action 'queue reason 'held)))
     ;; A handover stops the source that it holds, and its commit moves
     ;; the queued prompts to the target: a stopped or failed source
     ;; queues too, unless QUEUE is nil
     ((and (eq action 'reject) (not (eq queue 'never))
           (claude-code-ide-control-held-p instance-id))
      (setq action 'queue reason 'held))
     ;; A guessed idle state can be a dialog: never type into it
     ((and (eq action 'deliver) (claude-code-ide-control--guess-blocks-p instance state))
      (if (eq queue 'never)
          (setq action 'reject reason 'guessed-idle)
        (setq action 'queue reason 'guessed-idle)))
     ;; Earlier prompts go first
     ((and (eq action 'deliver) pending)
      (if (eq queue 'never)
          (setq action 'reject reason 'earlier-prompts-pending)
        (setq action 'queue reason 'earlier-prompts-pending))))
    (let ((record (claude-code-ide-control--record-create
                   :request-id request-id
                   :instance-id instance-id
                   :seq (1+ (apply #'max 0 (mapcar #'claude-code-ide-control--record-seq pending)))
                   :text-hash (claude-code-ide-control-text-hash text)
                   :text (claude-code-ide-control--line-ends text)
                   :result (if (eq action 'reject) 'rejected 'queued)
                   :reason reason
                   :created-at (claude-code-ide-control-now)
                   :requested-by (claude-code-ide-control--requester))))
      (claude-code-ide-control--write-record record)
      (pcase action
        ('deliver (claude-code-ide-control--send record (plist-get state :guess)))
        ('queue (claude-code-ide-control--start-timer)))
      (claude-code-ide-control--result record))))

(defvar claude-code-ide-control--pending-sends (make-hash-table :test 'eq :weakness 'key)
  "The result list of each send whose provider command still runs.
The value is (INSTANCE-ID . REQUEST-ID).  `codex queue' ends after the
send, and then changes the :outcome of the list.")

(defun claude-code-ide-control--send (record guess)
  "Give the prompt of RECORD to the provider of its instance.
GUESS non-nil says that the idle state of the instance is a guess; the
record keeps it.  The record is marked sent before the call, so that a
crash during the call never sends the prompt twice.  When the provider
does not send it, the record waits in the inbox again.  Return non-nil
when sent."
  (let* ((instance-id (claude-code-ide-control--record-instance-id record))
         (instance (claude-code-ide-instance-by-id instance-id))
         (text (claude-code-ide-control--record-text record)))
    (when (and instance (stringp text))
      (setf (claude-code-ide-control--record-sent-at record) (claude-code-ide-control-now)
            (claude-code-ide-control--record-sent-generation record)
            (claude-code-ide-instance-generation instance)
            (claude-code-ide-control--record-sent-guess record) (and guess t)
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
        (cond
         ((claude-code-ide-provider-unavailable-p sent)
          (claude-code-ide-control--finish record 'rejected 'no-submit)
          nil)
         (sent
          ;; A command that ends later, such as `codex queue', reports
          ;; its outcome in this list
          (when (and (consp sent) (eq (plist-get sent :outcome) 'pending))
            (puthash sent (cons instance-id (claude-code-ide-control--record-request-id record))
                     claude-code-ide-control--pending-sends))
          t)
         ;; Only when the acknowledgement did not come during the call
         ((not (claude-code-ide-control--final-p record))
          (claude-code-ide-control--unsend record)
          nil))))))

(defun claude-code-ide-control--unsend (record)
  "Put the sent RECORD back in the queue with the reason `send-failed'.
The next try sends it again."
  (setf (claude-code-ide-control--record-sent-at record) nil
        (claude-code-ide-control--record-sent-generation record) nil
        (claude-code-ide-control--record-sent-guess record) nil
        (claude-code-ide-control--record-reason record) 'send-failed)
  (claude-code-ide-control--write-record record)
  (claude-code-ide-control--start-timer))

(defun claude-code-ide-control--on-queue-end (_instance result)
  "Put the prompt of RESULT back in the queue when its command failed.
RESULT is the list that `submit-prompt' returned, with its final
:outcome.  With `failed', the provider did not store the prompt, so the
retry sends it again.  With `timeout', the provider may have stored
it: the record waits for its acknowledgement."
  (when-let* ((sent (gethash result claude-code-ide-control--pending-sends)))
    (remhash result claude-code-ide-control--pending-sends)
    (when (eq (plist-get result :outcome) 'failed)
      (when-let* ((record (cl-find (cdr sent) (claude-code-ide-control--pending-records (car sent))
                                   :key #'claude-code-ide-control--record-request-id
                                   :test #'equal)))
        (when (claude-code-ide-control--record-sent-at record)
          (claude-code-ide-control--unsend record))))))

(add-hook 'claude-code-ide-codex-queue-functions #'claude-code-ide-control--on-queue-end)

(defun claude-code-ide-control-deliver-pending (instance-id)
  "Send the oldest queued prompt of INSTANCE-ID when the instance can take it.
It can take it when it runs, is idle, is not held (see
`claude-code-ide-control-hold'), and has no sent prompt that still
waits for its acknowledgement (see
`claude-code-ide-control-ack-timeout').  Send at most one prompt.
When the provider of the instance has no submit-prompt, the queued
prompts become final with the reason `no-submit'.  Return the request
ID of the prompt that was sent, or nil."
  (let* ((pending (claude-code-ide-control-refresh instance-id))
         (instance (claude-code-ide-instance-by-id instance-id))
         (state (and instance (claude-code-ide-instance-live-p instance)
                     (claude-code-ide-instance-state instance)))
         (next (cl-find-if-not #'claude-code-ide-control--record-sent-at pending)))
    (cond
     ((or (null next) (null state)) nil)
     ((claude-code-ide-control-held-p instance-id) nil)
     ((not (claude-code-ide-control--provider-can-submit-p instance))
      (dolist (record pending)
        (claude-code-ide-control--finish record 'rejected 'no-submit))
      (claude-code-ide-control--maybe-stop-timer)
      nil)
     ;; A sent prompt is still within its time: it blocks the queue
     ((cl-some #'claude-code-ide-control--record-sent-at pending) nil)
     ((and (eq (car (claude-code-ide-control-decide state 'never)) 'deliver)
           (not (claude-code-ide-control--guess-blocks-p instance state))
           (claude-code-ide-control--send next (plist-get state :guess)))
      (claude-code-ide-control--record-request-id next)))))

;;; Moving an inbox

(defun claude-code-ide-control--move-target-id (from to record pending handover-id)
  "Return (ID . DONE) for the copy of RECORD of FROM in the inbox of TO.
ID is the request ID of the copy: the same one, or
\"handover:HANDOVER-ID:ID\" when TO has another record with that ID.
When TO has another record with that ID too, a number follows:
\"handover:HANDOVER-ID:ID:2\", then 3, and so on.  DONE is non-nil
when an earlier move made the copy already: a record of TO with the
ID whose `moved_from' names RECORD.  PENDING is the list of the
pending records of TO."
  (let* ((id (claude-code-ide-control--record-request-id record))
         (from-ref (concat from ":" id))
         (renamed (format "handover:%s:%s" (or handover-id from) id))
         (candidate id)
         (count 1)
         (result nil))
    (while (not result)
      (let ((found (claude-code-ide-control--find-record to candidate pending)))
        (cond
         ((null found) (setq result (cons candidate nil)))
         ((equal (claude-code-ide-control--record-moved-from found) from-ref)
          (setq result (cons candidate t)))
         (t
          (setq count (1+ count)
                candidate (if (= count 2) renamed (format "%s:%d" renamed (1- count))))))))
    result))

(defun claude-code-ide-control-move-inbox (from to &optional handover-id)
  "Move the queued prompts of the instance FROM into the inbox of TO.
A handover calls this at its commit, so that the prompts and the
review results for the old instance go to the new one (plan section
4.8).  Each pending record of FROM gets a queued copy in the inbox of
TO, with the same text and creation time, after the records that TO
has already:
- The copy keeps the request ID.  When TO has another record with that
  ID, the copy gets the ID \"handover:HANDOVER-ID:ID\" instead (FROM
  when HANDOVER-ID is nil); no record is dropped.
- The copy records where it came from (`moved_from': FROM:ID), and the
  record of FROM where it went (`moved_to': TO:NEW-ID).  The record of
  FROM then becomes final: `rejected' with the reason `handed-over'.
- A record that FROM received, and whose acknowledgement did not come,
  moves too, with a note that it may have reached FROM.
A second call moves nothing again.  Return the request IDs of the
copies, oldest first."
  (when (and (claude-code-ide-control-valid-id-p from)
             (claude-code-ide-control-valid-id-p to)
             (not (equal from to)))
    (let ((moved nil))
      (dolist (record (claude-code-ide-control--pending-records from))
        (let* ((request-id (claude-code-ide-control--record-request-id record))
               (pending (claude-code-ide-control--pending-records to))
               (target (claude-code-ide-control--move-target-id from to record pending handover-id))
               (new-id (car target))
               (sent (claude-code-ide-control--record-sent-at record)))
          (unless (cdr target)
            ;; The copy first, so that a crash loses no prompt
            (claude-code-ide-control--write-record
             (claude-code-ide-control--record-create
              :request-id new-id
              :instance-id to
              :seq (1+ (apply #'max 0 (mapcar #'claude-code-ide-control--record-seq pending)))
              :text-hash (claude-code-ide-control--record-text-hash record)
              :text (claude-code-ide-control--record-text record)
              :result 'queued
              :reason 'handed-over
              :created-at (claude-code-ide-control--record-created-at record)
              :requested-by (claude-code-ide-control--record-requested-by record)
              :moved-from (concat from ":" request-id)
              :note (when sent
                      (format "Sent to %s at %s without an acknowledgement; it may have reached that instance before the handover"
                              from sent))))
            (push new-id moved))
          (setf (claude-code-ide-control--record-moved-to record) (concat to ":" new-id))
          (claude-code-ide-control--finish record 'rejected 'handed-over)))
      (when moved
        (claude-code-ide-control--start-timer)
        (claude-code-ide-control--schedule-delivery to))
      (nreverse moved))))

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
        (let* ((instance (claude-code-ide-instance-by-id instance-id))
               (provider (and instance (claude-code-ide-instance-provider instance))))
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
          (setf (claude-code-ide-control--record-delivered-at record)
                (claude-code-ide-control-now))
          (claude-code-ide-control--finish record 'delivered nil)
          (claude-code-ide-control--maybe-stop-timer)
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
`session-start', starts a delivery.  The index gives the queued
prompts, so an event reads no file."
  (let ((instance-id (plist-get event :instance-id)))
    (when (claude-code-ide-control-valid-id-p instance-id)
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

(defun claude-code-ide-control--live-pending-p ()
  "Return non-nil when a running instance has a pending record."
  (cl-some (lambda (instance)
             (claude-code-ide-control--pending-records (claude-code-ide-instance-id instance)))
           (claude-code-ide-instances)))

(defun claude-code-ide-control--maybe-stop-timer ()
  "Stop the retry timer when no running instance has a pending record."
  (when (and (timerp claude-code-ide-control--timer)
             (not (claude-code-ide-control--live-pending-p)))
    (claude-code-ide-control--stop-timer)))

(defun claude-code-ide-control--tick ()
  "Try to deliver the queued prompts of each running instance.
Stop the timer when no running instance has a pending record."
  (dolist (instance (claude-code-ide-instances))
    (let ((id (claude-code-ide-instance-id instance)))
      (when (claude-code-ide-control--pending-records id)
        (condition-case err
            (claude-code-ide-control-deliver-pending id)
          (error (message "Control inbox: delivery to %s failed: %s"
                          id (error-message-string err)))))))
  (claude-code-ide-control--maybe-stop-timer))

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

(defun claude-code-ide-control-json (result)
  "Return the plist RESULT as JSON text for an MCP tool."
  (json-encode (claude-code-ide-control--to-json result)))

(defun claude-code-ide-control-blank-p (value)
  "Return non-nil when the MCP argument VALUE is missing or empty."
  (or (null value) (and (stringp value) (string-empty-p value))))

(defun claude-code-ide-control--provider-arg (value)
  "Return the provider name of the MCP argument VALUE, or nil."
  (unless (claude-code-ide-control-blank-p value) (intern value)))

(defun claude-code-ide-control--mcp-list-instances (&optional provider)
  "MCP tool: list the instances, of PROVIDER only when it is given."
  (claude-code-ide-control-json
   (claude-code-ide-control-list-instances (claude-code-ide-control--provider-arg provider))))

(defun claude-code-ide-control--mcp-inspect-instance (instance-id)
  "MCP tool: describe the instance INSTANCE-ID."
  (claude-code-ide-control-json (claude-code-ide-control-inspect-instance instance-id)))

(defun claude-code-ide-control--mcp-launch (directory &optional provider name prompt role)
  "MCP tool: start an instance in DIRECTORY with PROVIDER, NAME, PROMPT and ROLE."
  (claude-code-ide-control-json
   (claude-code-ide-control-launch
    :directory directory
    :provider (claude-code-ide-control--provider-arg provider)
    :name (unless (claude-code-ide-control-blank-p name) name)
    :prompt (unless (claude-code-ide-control-blank-p prompt) prompt)
    :role (unless (claude-code-ide-control-blank-p role) role))))

(defun claude-code-ide-control--mcp-resume (instance-id &optional prompt)
  "MCP tool: start INSTANCE-ID again with the first message PROMPT."
  (claude-code-ide-control-json
   (claude-code-ide-control-resume
    instance-id :prompt (unless (claude-code-ide-control-blank-p prompt) prompt))))

(defun claude-code-ide-control--generation-arg (value)
  "Return the launch generation of the MCP argument VALUE, or nil.
VALUE is a whole number, its decimal text, or missing.  Another value
gives -1, which matches no launch."
  (cond ((integerp value) value)
        ((claude-code-ide-control-blank-p value) nil)
        ((and (stringp value) (string-match-p "\\`[0-9]+\\'" value)) (string-to-number value))
        (t -1)))

(defun claude-code-ide-control--mcp-submit (instance-id text &optional request-id queue generation)
  "MCP tool: submit TEXT to INSTANCE-ID with REQUEST-ID.
QUEUE is \"auto\" (the default), \"always\" or \"never\".  GENERATION,
when given, is the launch generation that the caller saw."
  (let ((mode (pcase queue
                ("always" 'always)
                ("never" 'never)
                (_ 'auto))))
    (claude-code-ide-control-json
     (claude-code-ide-control-submit
      instance-id text
      :request-id (unless (claude-code-ide-control-blank-p request-id) request-id)
      :queue mode
      :generation (claude-code-ide-control--generation-arg generation)))))

(defun claude-code-ide-control--mcp-request-status (instance-id request-id)
  "MCP tool: return the result of REQUEST-ID in the inbox of INSTANCE-ID."
  (claude-code-ide-control-json
   (claude-code-ide-control-request-status instance-id request-id)))

(defun claude-code-ide-control--mcp-stop (instance-id &optional generation)
  "MCP tool: end the instance INSTANCE-ID.
GENERATION, when given, is the launch generation that the caller saw."
  (claude-code-ide-control-json
   (claude-code-ide-control-stop
    instance-id :generation (claude-code-ide-control--generation-arg generation))))

(defconst claude-code-ide-control--instance-id-arg
  '(:name "instance_id" :type string
          :description "Instance ID of the target, from claude-code-ide-control-list-instances. Never a display name.")
  "The instance ID argument of the coordinator tools.")

(defconst claude-code-ide-control--generation-arg-spec
  '(:name "generation" :type number :optional t
          :description "Launch generation from claude-code-ide-control-list-instances. When the instance ID runs another launch now, the tool does nothing and gives the reason generation-changed.")
  "The optional launch generation argument of the coordinator tools.")

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
                               :description "auto (default): queue while the instance is busy, reject a failed or stopped instance. always: always queue. never: reject unless the instance is idle.")
                       claude-code-ide-control--generation-arg-spec))
     (list :name "claude-code-ide-control-request-status"
           :function #'claude-code-ide-control--mcp-request-status
           :description "Return the current result of a submitted prompt: delivered, queued or rejected."
           :args (list id
                       '(:name "request_id" :type string
                               :description "Request ID of the submitted prompt.")))
     (list :name "claude-code-ide-control-stop"
           :function #'claude-code-ide-control--mcp-stop
           :description "End an instance by its instance ID. Its queued prompts stay in its inbox."
           :args (list id claude-code-ide-control--generation-arg-spec)))))

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
The tool always carries :scope coordinator."
  (let ((tool (apply #'claude-code-ide-make-tool
                     (append spec (list :scope 'coordinator)))))
    ;; Workaround until feat/mcp-routing is merged: that branch makes
    ;; `claude-code-ide-make-tool' keep :scope.  The current one drops
    ;; it, so put it on the spec in the tools list; plist-put changes
    ;; the list in place.  Remove this when make-tool keeps :scope.
    (unless (plist-member tool :scope)
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
