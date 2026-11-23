;;; claude-code-ide-control-tests.el --- Tests for the control operations  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the control operations, the prompt inbox, the request IDs,
;; the state rules, the acknowledgement and the MCP coordinator tools.
;; claude-code-ide-tests.el loads this file after its mocks.  The inbox
;; is a temporary folder, the instances use a stub provider, and all
;; projects and IDs are synthetic.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'claude-code-ide)
(require 'claude-code-ide-instance)
(require 'claude-code-ide-provider)
(require 'claude-code-ide-control)

(defvar claude-code-ide-tests--control-states nil
  "Alist of instance ID and the state that the test state function gives.")

(defvar claude-code-ide-tests--control-sent nil
  "List of (INSTANCE-ID TEXT) for each prompt that the stub provider got.
The newest comes first.")

(defvar claude-code-ide-tests--control-stopped nil
  "Instance IDs that the stub provider stopped, newest first.")

(defvar claude-code-ide-tests--control-registry nil
  "Alist of instance ID and the registry entry that the test registry gives.")

(defvar claude-code-ide-tests--control-buffers nil
  "Buffers that the control tests made.")

(defun claude-code-ide-tests--control-state-function (instance _now)
  "Return the test state of INSTANCE from `claude-code-ide-tests--control-states'."
  (cdr (assoc (claude-code-ide-instance-id instance) claude-code-ide-tests--control-states)))

(defun claude-code-ide-tests--control-set-state (instance-id state &optional reason)
  "Make the test state of INSTANCE-ID STATE with REASON."
  (setf (alist-get instance-id claude-code-ide-tests--control-states nil nil #'equal)
        (claude-code-ide-instance-make-state state reason (float-time))))

(defun claude-code-ide-tests--control-provider ()
  "Return the stub provider of the control tests."
  (claude-code-ide-provider-create
   :name 'cci-test-stub
   :display-name "Stub"
   :buffer-name-prefix "cci-stub"
   :submit-prompt (lambda (instance text)
                    (push (list (claude-code-ide-instance-id instance) text)
                          claude-code-ide-tests--control-sent)
                    t)
   :stop (lambda (instance)
           (push (claude-code-ide-instance-id instance) claude-code-ide-tests--control-stopped)
           (claude-code-ide-instance-unregister (claude-code-ide-instance-id instance))
           t)))

(defmacro claude-code-ide-tests--with-control (&rest body)
  "Run BODY with a temporary inbox, no instances, and the stub provider.
The state functions, the event functions, the registry and the timers
are those of the test."
  (declare (indent 0))
  `(let* ((inbox (make-temp-file "cci-test-inbox-" t))
          (claude-code-ide-control-inbox-directory inbox)
          (claude-code-ide-control-retry-interval nil)
          (claude-code-ide-control-ack-timeout 60)
          (claude-code-ide-control--timer nil)
          (claude-code-ide-control--scheduled nil)
          (claude-code-ide-control--index (make-hash-table :test 'equal))
          (claude-code-ide-control--warned-providers nil)
          (claude-code-ide-control-delivered-functions nil)
          (claude-code-ide-instance--all nil)
          (claude-code-ide-instance--generations (make-hash-table :test 'equal))
          (claude-code-ide-instance-state-functions
           (list #'claude-code-ide-tests--control-state-function))
          (claude-code-ide-event-functions (list #'claude-code-ide-control--on-event))
          (claude-code-ide-provider--registry (copy-alist claude-code-ide-provider--registry))
          (claude-code-ide-tests--control-states nil)
          (claude-code-ide-tests--control-sent nil)
          (claude-code-ide-tests--control-stopped nil)
          (claude-code-ide-tests--control-registry nil)
          (claude-code-ide-tests--control-buffers nil))
     (claude-code-ide-register-provider (claude-code-ide-tests--control-provider))
     (unwind-protect
         (cl-letf (((symbol-function 'claude-code-ide-control-registry-entry)
                    (lambda (id)
                      (cdr (assoc id claude-code-ide-tests--control-registry))))
                   ((symbol-function 'run-at-time)
                    (lambda (_time _repeat fn &rest args) (apply fn args) nil)))
           ,@body)
       (mapc #'kill-buffer (cl-remove-if-not #'buffer-live-p claude-code-ide-tests--control-buffers))
       (delete-directory inbox t))))

(defun claude-code-ide-tests--control-add (id &optional display-name state reason)
  "Register a running stub instance ID with DISPLAY-NAME in STATE with REASON.
Return the descriptor."
  (let ((buffer (generate-new-buffer (format "*cci-test-control-%s*" id))))
    (push buffer claude-code-ide-tests--control-buffers)
    (when state
      (claude-code-ide-tests--control-set-state id state reason))
    (claude-code-ide-instance-register
     (claude-code-ide-instance-create
      :id id
      :provider 'cci-test-stub
      :display-name (or display-name "proj")
      :project-root "/tmp/cci-test-control/proj/"
      :buffer buffer
      :generation (claude-code-ide-instance-candidate-generation id)))))

(defun claude-code-ide-tests--control-event (id event &optional data)
  "Dispatch the common EVENT of the current launch of ID with DATA."
  (claude-code-ide-dispatch-event
   (claude-code-ide-make-event id (claude-code-ide-instance-current-generation id)
                               event "cci-test" data)))

(defun claude-code-ide-tests--control-files (id)
  "Return the names of the files in the inbox folder of ID."
  (let ((dir (claude-code-ide-control-inbox-directory-of id)))
    (and (file-directory-p dir)
         (directory-files dir nil "\\`[^.]"))))

;;; Instance IDs, not display names

(ert-deftest claude-code-ide-test-control-same-display-name ()
  "Each operation reaches the instance ID that the caller gives.
The two instances have the same display name."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (claude-code-ide-tests--control-add "cci-test-b" "proj" 'idle)
    ;; list
    (let ((list (plist-get (claude-code-ide-control-list-instances) :instances)))
      (should (equal (mapcar (lambda (i) (plist-get i :instance-id)) list)
                     '("cci-test-a" "cci-test-b")))
      (should (equal (mapcar (lambda (i) (plist-get i :display-name)) list) '("proj" "proj"))))
    ;; inspect
    (should (equal (plist-get (claude-code-ide-control-inspect-instance "cci-test-b") :instance-id)
                   "cci-test-b"))
    (should (eq (plist-get (claude-code-ide-control-inspect-instance "proj") :reason) 'not-running))
    ;; submit
    (let ((result (claude-code-ide-control-submit "cci-test-b" "cci-test-hello" :request-id "r1")))
      (should (equal (plist-get result :destination) "cci-test-b"))
      (should (equal claude-code-ide-tests--control-sent '(("cci-test-b" "cci-test-hello")))))
    (should (eq (plist-get (claude-code-ide-control-submit "proj" "x") :reason) 'unknown-instance))
    ;; stop
    (should (eq (plist-get (claude-code-ide-control-stop "cci-test-a") :result) 'stopped))
    (should (equal claude-code-ide-tests--control-stopped '("cci-test-a")))
    (should (claude-code-ide-instance-by-id "cci-test-b"))
    (should (eq (plist-get (claude-code-ide-control-stop "cci-test-a") :reason) 'not-running))))

;;; State rules

(ert-deftest claude-code-ide-test-control-decide ()
  "The state rules of each state and each queue mode."
  (cl-flet ((decide (state reason queue)
              (claude-code-ide-control-decide
               (if (eq state 'stopped) 'stopped
                 (claude-code-ide-instance-make-state state reason))
               queue)))
    (dolist (queue '(auto always never))
      (should (equal (decide 'idle nil queue) '(deliver))))
    (should (equal (decide 'working nil 'auto) '(queue . working)))
    (should (equal (decide 'working nil 'never) '(reject . working)))
    (dolist (reason '(approval question dialog))
      (let ((name (intern (format "waiting-for-user/%s" reason))))
        (should (equal (decide 'waiting-for-user reason 'auto) (cons 'queue name)))
        (should (equal (decide 'waiting-for-user reason 'always) (cons 'queue name)))
        (should (equal (decide 'waiting-for-user reason 'never) (cons 'reject name)))))
    (should (equal (decide 'waiting-for-task 'subagent 'auto) '(queue . waiting-for-task/subagent)))
    (should (equal (decide 'disconnected nil 'auto) '(queue . disconnected)))
    (should (equal (decide 'failed 'quota-limit 'auto) '(reject . failed/quota-limit)))
    (should (equal (decide 'failed 'error 'always) '(queue . failed/error)))
    (should (equal (decide 'stopped nil 'auto) '(reject . stopped)))
    (should (equal (decide 'stopped nil 'always) '(queue . stopped)))))

(ert-deftest claude-code-ide-test-control-approval-dialog ()
  "A prompt during an approval dialog is queued, or rejected with :queue nil."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'waiting-for-user 'approval)
    (let ((queued (claude-code-ide-control-submit "cci-test-a" "cci-test-q" :request-id "q1"))
          (rejected (claude-code-ide-control-submit "cci-test-a" "cci-test-r"
                                                    :request-id "q2" :queue nil)))
      (should (eq (plist-get queued :result) 'queued))
      (should (eq (plist-get queued :reason) 'waiting-for-user/approval))
      (should-not (plist-get queued :sent-at))
      (should (eq (plist-get rejected :result) 'rejected))
      (should (eq (plist-get rejected :reason) 'waiting-for-user/approval))
      ;; Nothing went into the dialog
      (should-not claude-code-ide-tests--control-sent)
      ;; A dialog event does not deliver either
      (claude-code-ide-tests--control-event "cci-test-a" 'approval-request)
      (should-not claude-code-ide-tests--control-sent)
      ;; The rejected text is not kept
      (let ((record (claude-code-ide-control--find-record "cci-test-a" "q2")))
        (should (eq (claude-code-ide-control--record-result record) 'rejected))
        (should-not (claude-code-ide-control--record-text record))))))

(ert-deftest claude-code-ide-test-control-failed-and-stopped ()
  "A failed or stopped instance rejects, unless :queue is t."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'failed 'error)
    (should (eq (plist-get (claude-code-ide-control-submit "cci-test-a" "x" :request-id "f1")
                           :result)
                'rejected))
    (should (eq (plist-get (claude-code-ide-control-submit "cci-test-a" "x" :request-id "f2"
                                                           :queue t)
                           :result)
                'queued))
    ;; Not running here, closed in the registry: stopped
    (push (cons "cci-test-closed"
                (claude-code-ide-session-registry-entry-create :key "cci-test-closed" :state 'closed))
          claude-code-ide-tests--control-registry)
    (should (equal (claude-code-ide-control-submit "cci-test-closed" "x" :request-id "s1")
                   '(:destination "cci-test-closed" :request-id "s1" :result rejected
                                  :reason stopped :sent-at nil)))
    ;; Open in the registry, as after a crash: disconnected, queued
    (push (cons "cci-test-open"
                (claude-code-ide-session-registry-entry-create :key "cci-test-open" :state 'open))
          claude-code-ide-tests--control-registry)
    (let ((result (claude-code-ide-control-submit "cci-test-open" "x" :request-id "o1")))
      (should (eq (plist-get result :result) 'queued))
      (should (eq (plist-get result :reason) 'disconnected)))
    ;; Unknown: rejected, and no inbox folder
    (should (eq (plist-get (claude-code-ide-control-submit "cci-test-none" "x") :reason)
                'unknown-instance))
    (should-not (file-exists-p (claude-code-ide-control-inbox-directory-of "cci-test-none")))
    ;; Bad IDs never reach the file system
    (should (eq (plist-get (claude-code-ide-control-submit "../x" "x") :reason)
                'invalid-instance-id))
    (should (eq (plist-get (claude-code-ide-control-submit "cci-test-a" "  ") :reason)
                'empty-text))))

(ert-deftest claude-code-ide-test-control-stopped-instance-queues-as-disconnected ()
  "An instance that ended in this Emacs, without a registry, is disconnected."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (claude-code-ide-control-stop "cci-test-a")
    (let ((result (claude-code-ide-control-submit "cci-test-a" "cci-test-later" :request-id "d1")))
      (should (eq (plist-get result :result) 'queued))
      (should (eq (plist-get result :reason) 'disconnected)))
    (should-not claude-code-ide-tests--control-sent)
    ;; It runs again: the session-start event delivers the prompt
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (claude-code-ide-tests--control-event "cci-test-a" 'session-start)
    (should (equal claude-code-ide-tests--control-sent '(("cci-test-a" "cci-test-later"))))))

;;; Request IDs

(ert-deftest claude-code-ide-test-control-duplicate-request ()
  "A second request with the same request ID sends nothing."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (let ((first (claude-code-ide-control-submit "cci-test-a" "cci-test-once" :request-id "dup")))
      (should (eq (plist-get first :result) 'queued))
      (should (eq (plist-get first :reason) 'awaiting-acknowledgement))
      (should (plist-get first :sent-at))
      (should (= (length claude-code-ide-tests--control-sent) 1))
      (let ((second (claude-code-ide-control-submit "cci-test-a" "cci-test-once" :request-id "dup"))
            (other (claude-code-ide-control-submit "cci-test-a" "cci-test-other" :request-id "dup")))
        (should (plist-get second :duplicate))
        (should (equal (plist-get second :request-id) "dup"))
        (should (eq (plist-get second :result) 'queued))
        (should (plist-get other :duplicate))
        (should (= (length claude-code-ide-tests--control-sent) 1)))
      ;; After the acknowledgement, the duplicate gets the current result
      (claude-code-ide-tests--control-event "cci-test-a" 'prompt-submit
                                            '((prompt . "cci-test-once")))
      (should (eq (plist-get (claude-code-ide-control-submit "cci-test-a" "x" :request-id "dup")
                             :result)
                  'delivered))
      (should (= (length claude-code-ide-tests--control-sent) 1)))
    ;; A missing request ID gets a new one
    (let ((result (claude-code-ide-control-submit "cci-test-a" "cci-test-noid" :queue t)))
      (should (stringp (plist-get result :request-id)))
      (should (claude-code-ide-control--find-record "cci-test-a" (plist-get result :request-id))))))

;;; The inbox

(ert-deftest claude-code-ide-test-control-inbox-survives-reload ()
  "The inbox is on disk: it survives a reload of the package."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'working)
    (claude-code-ide-control-submit "cci-test-a" "cci-test-one" :request-id "k1")
    (claude-code-ide-control-submit "cci-test-a" "cci-test-two" :request-id "k2")
    ;; Clear the memory, and load the file again
    (setq claude-code-ide-control--scheduled nil
          claude-code-ide-control--timer nil
          claude-code-ide-control--index (make-hash-table :test 'equal))
    (load (locate-library "claude-code-ide-control") nil t)
    (should (= (hash-table-count claude-code-ide-control--index) 0))
    (let ((records (claude-code-ide-control--pending-records "cci-test-a")))
      (should (equal (mapcar #'claude-code-ide-control--record-request-id records) '("k1" "k2")))
      (should (equal (mapcar #'claude-code-ide-control--record-text records)
                     '("cci-test-one" "cci-test-two")))
      (should (equal (mapcar #'claude-code-ide-control--record-seq records) '(1 2))))
    (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-a" "k1") :result)
                'queued))
    ;; A duplicate after the reload still sends nothing
    (claude-code-ide-control-submit "cci-test-a" "cci-test-one" :request-id "k1")
    (should-not claude-code-ide-tests--control-sent)
    ;; One file for each request; no temporary files remain
    (should (= (length (claude-code-ide-tests--control-files "cci-test-a")) 2))
    (should-not (directory-files (claude-code-ide-control-inbox-directory-of "cci-test-a")
                                 nil "\\.tmp\\'"))
    ;; The folder is private
    (should (= (logand (file-modes (claude-code-ide-control-inbox-directory-of "cci-test-a"))
                       #o077)
               0))
    ;; The file has the request ID, the text hash, the time and the result
    (let* ((file (claude-code-ide-control--record-file "cci-test-a" "k1"))
           (json (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string))
                                    :object-type 'alist :null-object nil)))
      (should (equal (alist-get 'request_id json) "k1"))
      (should (equal (alist-get 'text_hash json) (claude-code-ide-control-text-hash "cci-test-one")))
      (should (stringp (alist-get 'created_at json)))
      (should (equal (alist-get 'result json) "queued")))))

(ert-deftest claude-code-ide-test-control-deliver-after-turn-end ()
  "A queued prompt goes out after turn-end, and is delivered after prompt-submit."
  (claude-code-ide-tests--with-control
    (let ((delivered nil))
      (add-hook 'claude-code-ide-control-delivered-functions
                (lambda (id request-id) (push (list id request-id) delivered)))
      (claude-code-ide-tests--control-add "cci-test-a" "proj" 'working)
      (claude-code-ide-control-submit "cci-test-a" "cci-test-first" :request-id "t1")
      (claude-code-ide-control-submit "cci-test-a" "cci-test-second" :request-id "t2")
      (should-not claude-code-ide-tests--control-sent)
      ;; The turn ends
      (claude-code-ide-tests--control-set-state "cci-test-a" 'idle)
      (claude-code-ide-tests--control-event "cci-test-a" 'turn-end)
      (should (equal claude-code-ide-tests--control-sent '(("cci-test-a" "cci-test-first"))))
      (let ((status (claude-code-ide-control-request-status "cci-test-a" "t1")))
        (should (eq (plist-get status :result) 'queued))
        (should (eq (plist-get status :reason) 'awaiting-acknowledgement)))
      ;; Not delivered yet: a second event sends nothing more
      (claude-code-ide-tests--control-event "cci-test-a" 'notification)
      (should (= (length claude-code-ide-tests--control-sent) 1))
      ;; Another prompt text is no acknowledgement
      (claude-code-ide-tests--control-event "cci-test-a" 'prompt-submit '((prompt . "typed by hand")))
      (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-a" "t1") :result)
                  'queued))
      ;; The acknowledgement: same text, other line ends and white space
      (claude-code-ide-tests--control-set-state "cci-test-a" 'working)
      (claude-code-ide-tests--control-event "cci-test-a" 'prompt-submit
                                            '((prompt . "cci-test-first\r\n")))
      (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-a" "t1") :result)
                  'delivered))
      (should (equal delivered '(("cci-test-a" "t1"))))
      (should-not (claude-code-ide-control--record-text
                   (claude-code-ide-control--find-record "cci-test-a" "t1")))
      ;; The second prompt waits for the next turn end
      (should (= (length claude-code-ide-tests--control-sent) 1))
      (claude-code-ide-tests--control-set-state "cci-test-a" 'idle)
      (claude-code-ide-tests--control-event "cci-test-a" 'turn-end)
      (should (equal (car claude-code-ide-tests--control-sent) '("cci-test-a" "cci-test-second"))))))

(ert-deftest claude-code-ide-test-control-idle-keeps-order ()
  "An idle instance with queued prompts sends the oldest first."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'disconnected)
    (claude-code-ide-control-submit "cci-test-a" "cci-test-old" :request-id "o1")
    (claude-code-ide-tests--control-set-state "cci-test-a" 'idle)
    (let ((result (claude-code-ide-control-submit "cci-test-a" "cci-test-new" :request-id "o2")))
      (should (eq (plist-get result :result) 'queued))
      (should (eq (plist-get result :reason) 'earlier-prompts-pending))
      (should (eq (plist-get (claude-code-ide-control-submit "cci-test-a" "cci-test-no"
                                                             :request-id "o3" :queue nil)
                             :reason)
                  'earlier-prompts-pending)))
    (should-not claude-code-ide-tests--control-sent)
    (should (equal (claude-code-ide-control-deliver-pending "cci-test-a") "o1"))
    (should (equal claude-code-ide-tests--control-sent '(("cci-test-a" "cci-test-old"))))))

(ert-deftest claude-code-ide-test-control-ack-timeout ()
  "A sent prompt without acknowledgement stops blocking after the timeout."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (claude-code-ide-control-submit "cci-test-a" "cci-test-lost" :request-id "a1")
    (claude-code-ide-control-submit "cci-test-a" "cci-test-next" :request-id "a2")
    (should (= (length claude-code-ide-tests--control-sent) 1))
    (should-not (claude-code-ide-control-deliver-pending "cci-test-a"))
    ;; The acknowledgement is overdue
    (let ((claude-code-ide-control-ack-timeout -1))
      (should (equal (claude-code-ide-control-deliver-pending "cci-test-a") "a2")))
    (should (equal (car claude-code-ide-tests--control-sent) '("cci-test-a" "cci-test-next")))
    (let ((status (claude-code-ide-control-request-status "cci-test-a" "a1")))
      (should (eq (plist-get status :result) 'unacknowledged))
      (should (eq (plist-get status :reason) 'no-acknowledgement)))
    ;; Final: in the done folder, never sent again, and a late
    ;; acknowledgement changes nothing
    (should (file-exists-p (claude-code-ide-control--record-file "cci-test-a" "a1" t)))
    (should-not (file-exists-p (claude-code-ide-control--record-file "cci-test-a" "a1")))
    (should (= (length claude-code-ide-tests--control-sent) 2))
    (claude-code-ide-tests--control-event "cci-test-a" 'prompt-submit '((prompt . "cci-test-lost")))
    (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-a" "a1") :result)
                'unacknowledged))
    (should (eq (plist-get (claude-code-ide-control-submit "cci-test-a" "cci-test-lost"
                                                           :request-id "a1")
                           :result)
                'unacknowledged))
    (should (= (length claude-code-ide-tests--control-sent) 2))))

(ert-deftest claude-code-ide-test-control-older-generation-expires ()
  "A prompt sent to an earlier launch is unacknowledged at once."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (claude-code-ide-control-submit "cci-test-a" "cci-test-gen1" :request-id "g1")
    (claude-code-ide-control-submit "cci-test-a" "cci-test-gen2" :request-id "g2")
    ;; The instance runs again as generation 2; the events of 1 are dropped
    (claude-code-ide-instance-unregister "cci-test-a")
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (should (= (claude-code-ide-instance-current-generation "cci-test-a") 2))
    (claude-code-ide-tests--control-event "cci-test-a" 'session-start)
    (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-a" "g1") :result)
                'unacknowledged))
    (should (equal (car claude-code-ide-tests--control-sent) '("cci-test-a" "cci-test-gen2")))))

(ert-deftest claude-code-ide-test-control-no-prompt-text ()
  "A prompt-submit event without prompt text gives a warning and no delivery."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (claude-code-ide-control-submit "cci-test-a" "cci-test-x" :request-id "n1")
    (let ((warnings nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (claude-code-ide-tests--control-event "cci-test-a" 'prompt-submit '((session_id . "s")))
        (claude-code-ide-tests--control-event "cci-test-a" 'prompt-submit nil))
      (should (= (length warnings) 1))
      (should (string-match-p "cci-test-stub" (car warnings))))
    (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-a" "n1") :result)
                'queued))))

(ert-deftest claude-code-ide-test-control-send-failure ()
  "A prompt that the provider does not send waits in the inbox again."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (cl-letf (((symbol-function 'claude-code-ide-provider-call) (lambda (&rest _) nil)))
      (let ((result (claude-code-ide-control-submit "cci-test-a" "cci-test-x" :request-id "e1")))
        (should (eq (plist-get result :result) 'queued))
        (should (eq (plist-get result :reason) 'send-failed))
        (should-not (plist-get result :sent-at))))
    (should (equal (claude-code-ide-control-deliver-pending "cci-test-a") "e1"))
    ;; A provider without submit-prompt rejects at once
    (setf (claude-code-ide-provider-submit-prompt (claude-code-ide-get-provider 'cci-test-stub)) nil)
    (should (equal (claude-code-ide-control-submit "cci-test-a" "y" :request-id "e2")
                   '(:destination "cci-test-a" :request-id "e2" :result rejected
                                  :reason no-submit :sent-at nil)))))

;;; Inbox place and retry timer

(ert-deftest claude-code-ide-test-control-inbox-place ()
  "The inbox is the folder inbox in the report directory by default."
  (let* ((reports (make-temp-file "cci-test-reports-" t))
         (claude-code-ide-session-registry-report-directory reports)
         (claude-code-ide-control-inbox-directory nil))
    (unwind-protect
        (progn
          (should (equal (claude-code-ide-control-inbox-directory-of "cci-test-a")
                         (file-name-as-directory
                          (expand-file-name "inbox/cci-test-a" reports))))
          (should-error (claude-code-ide-control-inbox-directory-of "../cci-test")))
      (delete-directory reports t))))

(ert-deftest claude-code-ide-test-control-retry-timer ()
  "A queued prompt starts the retry timer; the timer stops when nothing waits."
  (claude-code-ide-tests--with-control
    (let ((claude-code-ide-control-retry-interval 5)
          (timers nil))
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (&rest args) (push args timers) (timer-create)))
                ((symbol-function 'cancel-timer) #'ignore))
        (claude-code-ide-tests--control-add "cci-test-a" "proj" 'working)
        (claude-code-ide-control-submit "cci-test-a" "cci-test-wait" :request-id "w1")
        (claude-code-ide-control-submit "cci-test-a" "cci-test-wait2" :request-id "w2")
        (should (= (length timers) 1))
        (should (timerp claude-code-ide-control--timer))
        ;; The instance becomes idle without an event: the tick sends
        (claude-code-ide-tests--control-set-state "cci-test-a" 'idle)
        (claude-code-ide-control--tick)
        (should (equal claude-code-ide-tests--control-sent '(("cci-test-a" "cci-test-wait"))))
        (should (timerp claude-code-ide-control--timer))
        (claude-code-ide-tests--control-event "cci-test-a" 'prompt-submit '((prompt . "cci-test-wait")))
        (claude-code-ide-control--tick)
        (claude-code-ide-tests--control-event "cci-test-a" 'prompt-submit '((prompt . "cci-test-wait2")))
        (claude-code-ide-control--tick)
        (should-not claude-code-ide-control--timer)))))

;;; Review fixes

(ert-deftest claude-code-ide-test-control-line-ends ()
  "CR and CR LF become LF before the send, not only before the hash."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (claude-code-ide-control-submit "cci-test-a" "Fix A\r\nthen B\rthen C" :request-id "l1")
    (should (equal claude-code-ide-tests--control-sent
                   '(("cci-test-a" "Fix A\nthen B\nthen C"))))
    (claude-code-ide-tests--control-event "cci-test-a" 'prompt-submit
                                          '((prompt . "Fix A\nthen B\nthen C")))
    (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-a" "l1") :result)
                'delivered))))

(ert-deftest claude-code-ide-test-control-done-folder ()
  "Final records move to done at once, and old ones there are deleted."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'waiting-for-user 'question)
    (claude-code-ide-control-submit "cci-test-a" "cci-test-r" :request-id "x1" :queue nil)
    (claude-code-ide-control-submit "cci-test-a" "cci-test-q" :request-id "x2")
    (let ((done (claude-code-ide-control--done-directory "cci-test-a")))
      (should (equal (claude-code-ide-tests--control-files "cci-test-a")
                     (sort (list "done" (claude-code-ide-control--file-name "x2")) #'string<)))
      (should (equal (directory-files done nil "\\.json\\'")
                     (list (claude-code-ide-control--file-name "x1"))))
      ;; A final record older than the limit goes at the next move
      (set-file-times (claude-code-ide-control--record-file "cci-test-a" "x1" t)
                      (time-subtract nil (* 8 86400)))
      (claude-code-ide-tests--control-set-state "cci-test-a" 'idle)
      (claude-code-ide-control-deliver-pending "cci-test-a")
      (claude-code-ide-tests--control-event "cci-test-a" 'prompt-submit '((prompt . "cci-test-q")))
      (should (equal (directory-files done nil "\\.json\\'")
                     (list (claude-code-ide-control--file-name "x2"))))
      (should (equal (claude-code-ide-tests--control-files "cci-test-a") '("done")))
      ;; The duplicate of a final record is found in done
      (claude-code-ide-control-submit "cci-test-a" "cci-test-q" :request-id "x2")
      (should (= (length claude-code-ide-tests--control-sent) 1))
      ;; An interrupted move: the pending copy of a final record is dropped
      (copy-file (claude-code-ide-control--record-file "cci-test-a" "x2" t)
                 (claude-code-ide-control--record-file "cci-test-a" "x2"))
      (clrhash claude-code-ide-control--index)
      (should-not (claude-code-ide-control--pending-records "cci-test-a"))
      (should-not (file-exists-p (claude-code-ide-control--record-file "cci-test-a" "x2"))))))

(ert-deftest claude-code-ide-test-control-index-reads-no-files ()
  "Events and submits use the index; only the first use reads the folder."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'working)
    (claude-code-ide-control-submit "cci-test-a" "cci-test-1" :request-id "i1")
    (clrhash claude-code-ide-control--index)
    (let ((reads 0)
          (read-record (symbol-function 'claude-code-ide-control--read-record)))
      (cl-letf (((symbol-function 'claude-code-ide-control--read-record)
                 (lambda (file) (cl-incf reads) (funcall read-record file))))
        (claude-code-ide-tests--control-event "cci-test-a" 'tool-end)
        (should (= reads 1))
        (dotimes (_ 5) (claude-code-ide-tests--control-event "cci-test-a" 'tool-end))
        (claude-code-ide-control-submit "cci-test-a" "cci-test-2" :request-id "i2")
        (should (= reads 1))
        (should (equal (mapcar #'claude-code-ide-control--record-request-id
                               (claude-code-ide-control--pending-records "cci-test-a"))
                       '("i1" "i2")))))))

(ert-deftest claude-code-ide-test-control-reader-without-native-json ()
  "The inbox reads its files also when Emacs has no native JSON parser."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
    (claude-code-ide-control-submit "cci-test-a" "cci-test-once" :request-id "j1")
    (claude-code-ide-control-submit "cci-test-a" "cci-test-wait" :request-id "j2")
    (clrhash claude-code-ide-control--index)
    (cl-letf (((symbol-function 'json-available-p) #'ignore)
              ((symbol-function 'json-parse-string)
               (lambda (&rest _) (error "No native JSON"))))
      (let ((records (claude-code-ide-control--pending-records "cci-test-a")))
        (should (equal (mapcar #'claude-code-ide-control--record-request-id records) '("j1" "j2")))
        (should (eq (claude-code-ide-control--record-sent-guess (car records)) nil))
        (should (stringp (claude-code-ide-control--record-sent-at (car records)))))
      (should (plist-get (claude-code-ide-control-submit "cci-test-a" "cci-test-once"
                                                         :request-id "j1")
                         :duplicate))
      (should (= (length claude-code-ide-tests--control-sent) 1)))))

(ert-deftest claude-code-ide-test-control-guess-and-request-ids ()
  "A guessed idle state sends and is recorded; number request IDs work."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj")
    (setf (alist-get "cci-test-a" claude-code-ide-tests--control-states nil nil #'equal)
          (claude-code-ide-instance-make-state 'idle nil (float-time) t))
    (let ((result (claude-code-ide-control-submit "cci-test-a" "cci-test-g" :request-id 42)))
      (should (equal (plist-get result :request-id) "42")))
    (should (claude-code-ide-control--record-sent-guess
             (claude-code-ide-control--find-record "cci-test-a" "42")))
    (should (equal (plist-get (claude-code-ide-control-request-status "cci-test-a" 42) :request-id)
                   "42"))
    (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-a" 'bad) :reason)
                'unknown-request))))

(ert-deftest claude-code-ide-test-control-no-submit-is-final ()
  "Queued prompts of a provider without submit-prompt become final."
  (claude-code-ide-tests--with-control
    (let ((claude-code-ide-control-retry-interval 5))
      (cl-letf (((symbol-function 'run-with-timer) (lambda (&rest _) (timer-create)))
                ((symbol-function 'cancel-timer) #'ignore))
        (claude-code-ide-tests--control-add "cci-test-a" "proj" 'working)
        (claude-code-ide-control-submit "cci-test-a" "cci-test-n" :request-id "s1")
        (should (timerp claude-code-ide-control--timer))
        (setf (claude-code-ide-provider-submit-prompt (claude-code-ide-get-provider 'cci-test-stub))
              nil)
        (claude-code-ide-tests--control-set-state "cci-test-a" 'idle)
        (claude-code-ide-control--tick)
        (let ((status (claude-code-ide-control-request-status "cci-test-a" "s1")))
          (should (eq (plist-get status :result) 'rejected))
          (should (eq (plist-get status :reason) 'no-submit)))
        (should-not claude-code-ide-control--timer)))))

(ert-deftest claude-code-ide-test-control-unacknowledged-stops-timer ()
  "The timer stops when the last sent prompt becomes unacknowledged."
  (claude-code-ide-tests--with-control
    (let ((claude-code-ide-control-retry-interval 5))
      (cl-letf (((symbol-function 'run-with-timer) (lambda (&rest _) (timer-create)))
                ((symbol-function 'cancel-timer) #'ignore))
        (claude-code-ide-tests--control-add "cci-test-a" "proj" 'working)
        (claude-code-ide-control-submit "cci-test-a" "cci-test-u" :request-id "u1")
        (claude-code-ide-tests--control-set-state "cci-test-a" 'idle)
        (claude-code-ide-control--tick)
        (should (= (length claude-code-ide-tests--control-sent) 1))
        (should (timerp claude-code-ide-control--timer))
        (let ((claude-code-ide-control-ack-timeout -1))
          (claude-code-ide-control--tick))
        (should (eq (plist-get (claude-code-ide-control-request-status "cci-test-a" "u1") :result)
                    'unacknowledged))
        (should-not claude-code-ide-control--timer)))))

(ert-deftest claude-code-ide-test-control-resume-dead-descriptor ()
  "A descriptor whose terminal is gone does not block a resume."
  (claude-code-ide-tests--with-control
    (let ((dir (make-temp-file "cci-test-proj-" t))
          (started nil))
      (unwind-protect
          (progn
            (claude-code-ide-tests--control-add "cci-test-a" "proj" 'idle)
            (kill-buffer (claude-code-ide-instance-buffer (claude-code-ide-instance-by-id "cci-test-a")))
            (cl-letf (((symbol-function 'claude-code-ide--start-session)
                       (lambda (_c _r spec) (setq started spec))))
              (claude-code-ide-control-resume "cci-test-a" :directory dir :native-id "cci-test-n"))
            (should (equal (claude-code-ide-start-spec-instance-id started) "cci-test-a")))
        (delete-directory dir t)))))

(ert-deftest claude-code-ide-test-control-make-tool-keeps-scope ()
  "The :scope workaround changes nothing when make-tool keeps the key."
  (let ((claude-code-ide-mcp-server-tools nil))
    (cl-letf (((symbol-function 'claude-code-ide-make-tool)
               (lambda (&rest slots)
                 (let ((tool (copy-sequence slots)))
                   (push tool claude-code-ide-mcp-server-tools)
                   tool))))
      (let ((tool (claude-code-ide-control--make-tool
                   '(:name "cci-test-tool" :function ignore :description "x"))))
        (should (eq (plist-get tool :scope) 'coordinator))
        ;; One :scope only: the workaround did not add a second one
        (should (= (cl-count :scope tool) 1))))))

;;; Launch, resume and the Phase 3 operations

(ert-deftest claude-code-ide-test-control-launch-and-resume ()
  "Launch and resume start the instance ID that they return."
  (claude-code-ide-tests--with-control
    (let ((specs nil)
          (dir (make-temp-file "cci-test-proj-" t)))
      (unwind-protect
          (cl-letf (((symbol-function 'claude-code-ide--start-session)
                     (lambda (_continue _resume spec)
                       (push spec specs)
                       (claude-code-ide-tests--control-add
                        (claude-code-ide-start-spec-instance-id spec) "proj" 'working)))
                    ((symbol-function 'claude-code-ide-session-registry--start-entry)
                     (lambda (entry prompt)
                       (push (list entry prompt) specs)
                       (claude-code-ide-tests--control-add
                        (claude-code-ide-session-registry-entry-key entry) "proj" 'working))))
            (let* ((result (claude-code-ide-control-launch :directory dir :provider 'cci-test-stub
                                                           :name "cci-test" :role "worker"))
                   (id (plist-get result :instance-id))
                   (spec (car specs)))
              (should (eq (plist-get result :status) 'ok))
              (should (equal (claude-code-ide-start-spec-instance-id spec) id))
              (should (eq (claude-code-ide-start-spec-provider spec) 'cci-test-stub))
              (should (equal (claude-code-ide-start-spec-role spec) "worker"))
              (should (= (plist-get result :generation) 1))
              ;; A running instance does not resume
              (should (eq (plist-get (claude-code-ide-control-resume id) :reason) 'already-running))
              (claude-code-ide-control-stop id)
              ;; Without a registry entry, the caller gives the conversation
              (should (eq (plist-get (claude-code-ide-control-resume id) :reason) 'unknown-instance))
              (let ((resumed (claude-code-ide-control-resume id :directory dir :native-id "cci-test-native"
                                                             :provider 'cci-test-stub)))
                (should (equal (plist-get resumed :instance-id) id))
                (should (equal (claude-code-ide-start-spec-resume-id (car specs)) "cci-test-native"))
                (should (= (claude-code-ide-start-spec-last-generation (car specs)) 1)))
              ;; With a registry entry, the registry starts it
              (claude-code-ide-control-stop id)
              (push (cons id (claude-code-ide-session-registry-entry-create :key id :state 'open))
                    claude-code-ide-tests--control-registry)
              (should (eq (plist-get (claude-code-ide-control-resume id :prompt "cci-test-go") :status)
                          'ok))
              (should (equal (cadr (car specs)) "cci-test-go"))))
        (delete-directory dir t)))
    ;; Errors are results, not signals
    (should (eq (plist-get (claude-code-ide-control-launch :directory "/nonexistent/cci-test")
                           :reason)
                'no-directory))
    (should (eq (plist-get (claude-code-ide-control-launch :directory temporary-file-directory
                                                           :provider 'cci-test-none)
                           :reason)
                'unknown-provider))
    (cl-letf (((symbol-function 'claude-code-ide--start-session)
               (lambda (&rest _) (user-error "CLI not available"))))
      (let ((result (claude-code-ide-control-launch :directory temporary-file-directory)))
        (should (eq (plist-get result :reason) 'start-failed))
        (should (equal (plist-get result :message) "CLI not available"))))))

(ert-deftest claude-code-ide-test-control-public-helpers ()
  "The helpers for other files work, and the internal names that other files use stay."
  (should (claude-code-ide-control-valid-id-p "cci-test-a.b_c"))
  (should-not (claude-code-ide-control-valid-id-p "../x"))
  (should-not (claude-code-ide-control-valid-id-p 42))
  (should (equal (claude-code-ide-control-request-id-string 42) "42"))
  (should (equal (claude-code-ide-control-request-id-string "r") "r"))
  (should-not (claude-code-ide-control-request-id-string '(x)))
  (should (claude-code-ide-control-blank-p nil))
  (should (claude-code-ide-control-blank-p ""))
  (should-not (claude-code-ide-control-blank-p "x"))
  (should (string-match-p "\\`[0-9-]+T[0-9:]+Z\\'" (claude-code-ide-control-now)))
  (should (equal (claude-code-ide-control-json-decode "{\"a\":[1,null]}") '((a 1 nil))))
  (should (equal (claude-code-ide-control-json-decode (claude-code-ide-control-json '(:status ok)))
                 '((status . "ok"))))
  (let* ((dir (make-temp-file "cci-test-control-helpers-" t))
         (sub (expand-file-name "sub" dir))
         (file (expand-file-name "cci-test.json" sub)))
    (unwind-protect
        (progn
          (claude-code-ide-control-write-json-file file '((a . 1)))
          (should (equal (claude-code-ide-control-json-decode
                          (with-temp-buffer (insert-file-contents file) (buffer-string)))
                         '((a . 1))))
          (should (= (file-modes file) #o600))
          (should (= (file-modes sub) #o700))
          (should-not (directory-files sub nil "\\.tmp\\'"))
          (let ((young (expand-file-name "cci-test-young.json" sub)))
            (write-region "{}" nil young nil 'silent)
            (set-file-times file (time-subtract nil (* 3 86400)))
            (claude-code-ide-control-prune-folder sub 2 "\\`cci-test.*\\.json\\'")
            (should-not (file-exists-p file))
            (should (file-exists-p young))))
      (delete-directory dir t)))
  ;; The internal names are gone: every file calls the public ones
  (dolist (name '(claude-code-ide-control--now claude-code-ide-control--refresh
                                               claude-code-ide-control--valid-id-p
                                               claude-code-ide-control--json-decode
                                               claude-code-ide-control--state-of
                                               claude-code-ide-control--json
                                               claude-code-ide-control--blank-p
                                               claude-code-ide-control--registry-entry))
    (should-not (fboundp name)))
  (should (functionp (indirect-function 'claude-code-ide-control-registry-entry))))

(ert-deftest claude-code-ide-test-control-no-internal-calls-in-other-files ()
  "The handover file and its tests call no removed internal control name."
  (dolist (base '("claude-code-ide-handover" "claude-code-ide-handover-tests"))
    (let ((file (expand-file-name (concat base ".el")
                                  (file-name-directory (locate-library base))))
          (found nil))
      (with-temp-buffer
        (insert-file-contents file)
        (emacs-lisp-mode)
        (goto-char (point-min))
        (while (re-search-forward
                "claude-code-ide-control--\\(state-of\\|json\\|blank-p\\|registry-entry\\)\\_>" nil t)
          (unless (nth 8 (syntax-ppss))
            (push (match-string 0) found))))
      (should-not found))))

(ert-deftest claude-code-ide-test-control-operations-table ()
  "Each operation has a function; handover and track-review come later."
  (let ((claude-code-ide-control-operations (copy-tree claude-code-ide-control-operations)))
    (dolist (op '(list-instances inspect-instance launch resume submit-prompt stop))
      (should (functionp (alist-get op claude-code-ide-control-operations))))
    ;; The handover file fills the slot when it is loaded; test the empty slot
    (claude-code-ide-control-define-operation 'handover nil)
    (should (equal (claude-code-ide-control-call 'handover)
                   '(:status unavailable :capability handover)))
    (claude-code-ide-control-define-operation 'handover (lambda (&rest args) (cons 'done args)))
    (should (equal (claude-code-ide-control-call 'handover 1) '(done 1)))))

;;; MCP coordinator tools

(ert-deftest claude-code-ide-test-control-mcp-tools-scope ()
  "Each coordinator tool carries :scope coordinator."
  (let ((claude-code-ide-mcp-server-tools nil)
        (claude-code-ide-control--extra-tool-specs nil))
    (dolist (spec (claude-code-ide-control--tool-specs))
      (should (string-prefix-p "claude-code-ide-control-" (plist-get spec :name))))
    ;; Without the scope check of the server, the tools stay off
    (cl-letf (((symbol-function 'claude-code-ide-control-scope-enforced-p) #'ignore))
      (should-error (claude-code-ide-control-setup-mcp-tools) :type 'user-error)
      (should-not claude-code-ide-mcp-server-tools))
    (cl-letf (((symbol-function 'claude-code-ide-control-scope-enforced-p) (lambda () t)))
      (let ((tools (claude-code-ide-control-setup-mcp-tools)))
        (should (= (length tools) 7))
        (should (= (length claude-code-ide-mcp-server-tools) 7))
        (dolist (tool claude-code-ide-mcp-server-tools)
          (should (eq (plist-get tool :scope) 'coordinator)))
        ;; Setting up again does not add copies
        (claude-code-ide-control-setup-mcp-tools)
        (should (= (length claude-code-ide-mcp-server-tools) 7))
        ;; A later file adds its operation as a coordinator tool
        (claude-code-ide-control-define-tool
         :name "claude-code-ide-control-handover" :function #'ignore :description "Hand over.")
        (should (= (length claude-code-ide-mcp-server-tools) 8))
        (should (eq (plist-get (cl-find "claude-code-ide-control-handover"
                                        claude-code-ide-mcp-server-tools
                                        :key (lambda (tool) (plist-get tool :name)) :test #'equal)
                               :scope)
                    'coordinator))
        (claude-code-ide-control-remove-mcp-tools)
        (should-not claude-code-ide-mcp-server-tools)))))

(ert-deftest claude-code-ide-test-control-mcp-tool-results ()
  "The tool functions return JSON with instance IDs and the submit result."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-a" "proj" 'waiting-for-user 'approval)
    (let ((list (json-parse-string (claude-code-ide-control--mcp-list-instances)
                                   :object-type 'alist :array-type 'list
                                   :null-object nil :false-object nil)))
      (should (equal (alist-get 'status list) "ok"))
      (let ((instance (car (alist-get 'instances list))))
        (should (equal (alist-get 'instance_id instance) "cci-test-a"))
        (should (equal (alist-get 'state instance) "waiting-for-user"))
        (should (equal (alist-get 'state_reason instance) "approval"))
        (should (equal (alist-get 'native_id instance) "unknown"))))
    (should (equal (json-parse-string (claude-code-ide-control--mcp-list-instances "codex")
                                      :object-type 'alist :array-type 'list)
                   '((status . "ok") (instances))))
    (let ((result (json-parse-string
                   (claude-code-ide-control--mcp-submit "cci-test-a" "cci-test-x" "m1" "never")
                   :object-type 'alist :null-object nil :false-object nil)))
      (should (equal (alist-get 'destination result) "cci-test-a"))
      (should (equal (alist-get 'request_id result) "m1"))
      (should (equal (alist-get 'result result) "rejected"))
      (should (equal (alist-get 'reason result) "waiting-for-user/approval")))
    (let ((result (json-parse-string
                   (claude-code-ide-control--mcp-submit "cci-test-a" "cci-test-x" "m2" nil)
                   :object-type 'alist :null-object nil :false-object nil)))
      (should (equal (alist-get 'result result) "queued")))
    (let ((inspect (json-parse-string (claude-code-ide-control--mcp-inspect-instance "cci-test-a")
                                      :object-type 'alist :array-type 'list
                                      :null-object nil :false-object nil)))
      (should (equal (alist-get 'capabilities inspect) '("submit-prompt" "stop")))
      (should (equal (mapcar (lambda (r) (alist-get 'request_id r)) (alist-get 'inbox inspect))
                     '("m2")))
      (should-not (alist-get 'text (car (alist-get 'inbox inspect)))))
    (should (string-match-p "\"result\":\"stopped\""
                            (claude-code-ide-control--mcp-stop "cci-test-a")))))

(ert-deftest claude-code-ide-test-control-move-inbox-renamed-id-taken ()
  "A move whose renamed ID is taken by a record of TO that FROM did not make drops nothing."
  (claude-code-ide-tests--with-control
    (claude-code-ide-tests--control-add "cci-test-from" "proj" 'working)
    (claude-code-ide-tests--control-add "cci-test-to" "proj" 'working)
    (claude-code-ide-control-submit "cci-test-from" "cci-test-for-from" :request-id "q1")
    ;; TO has q1 and the renamed ID already, both its own
    (claude-code-ide-control-submit "cci-test-to" "cci-test-own" :request-id "q1")
    (claude-code-ide-control-submit "cci-test-to" "cci-test-own-renamed"
                                    :request-id "handover:cci-test-h:q1")
    (let* ((moved (claude-code-ide-control-move-inbox "cci-test-from" "cci-test-to" "cci-test-h"))
           (copy (and moved (claude-code-ide-control--find-record "cci-test-to" (car moved)))))
      (should (= (length moved) 1))
      (should copy)
      (should (equal (claude-code-ide-control--record-text copy) "cci-test-for-from"))
      (should (equal (claude-code-ide-control--record-moved-from copy) "cci-test-from:q1"))
      (should (equal (claude-code-ide-control--record-moved-to
                      (claude-code-ide-control--find-record "cci-test-from" "q1"))
                     (concat "cci-test-to:" (car moved))))
      ;; The records of TO are unchanged
      (should (equal (claude-code-ide-control--record-text
                      (claude-code-ide-control--find-record "cci-test-to" "handover:cci-test-h:q1"))
                     "cci-test-own-renamed"))
      ;; A second move moves nothing again
      (should-not (claude-code-ide-control-move-inbox "cci-test-from" "cci-test-to" "cci-test-h"))
      (should (= (length (claude-code-ide-control--pending-records "cci-test-to")) 3)))))

(provide 'claude-code-ide-control-tests)

;;; claude-code-ide-control-tests.el ends here
